const std = @import("std");
const mem_registry_mod = @import("mem-registry.zig");
const seg_mod = @import("text-buffer-segment.zig");
const syntax_style_mod = @import("syntax-style.zig");
const utf8 = @import("utf8.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;
const MemRegistry = mem_registry_mod.MemRegistry;
const TextChunk = seg_mod.TextChunk;
const TextBufferError = seg_mod.TextBufferError;
const SyntaxStyle = syntax_style_mod.SyntaxStyle;

pub const StyledChunk = extern struct {
    text_ptr: [*]const u8,
    text_len: usize,
    fg_ptr: ?[*]const f32,
    bg_ptr: ?[*]const f32,
    attributes: u32,
};

pub const ViewRegistry = struct {
    view_dirty_flags: std.ArrayListUnmanaged(bool) = .{},
    next_view_id: u32 = 0,
    free_view_ids: std.ArrayListUnmanaged(u32) = .{},
    /// Monotonic counter that increments on every content change. Views use this
    /// to detect stale caches even after clearViewDirty() runs.
    content_epoch: u64 = 0,

    pub fn deinit(self: *ViewRegistry, allocator: Allocator) void {
        self.view_dirty_flags.deinit(allocator);
        self.free_view_ids.deinit(allocator);
    }

    pub fn registerView(self: *ViewRegistry, allocator: Allocator) TextBufferError!u32 {
        if (self.free_view_ids.items.len > 0) {
            const id = self.free_view_ids.items[self.free_view_ids.items.len - 1];
            _ = self.free_view_ids.pop();
            self.view_dirty_flags.items[id] = true;
            return id;
        }

        const id = self.next_view_id;
        self.next_view_id += 1;
        try self.view_dirty_flags.append(allocator, true);
        return id;
    }

    pub fn unregisterView(self: *ViewRegistry, allocator: Allocator, view_id: u32) void {
        if (view_id < self.view_dirty_flags.items.len) {
            self.free_view_ids.append(allocator, view_id) catch {};
        }
    }

    pub fn isViewDirty(self: *const ViewRegistry, view_id: u32) bool {
        if (view_id < self.view_dirty_flags.items.len) {
            return self.view_dirty_flags.items[view_id];
        }
        return false;
    }

    pub fn clearViewDirty(self: *ViewRegistry, view_id: u32) void {
        if (view_id < self.view_dirty_flags.items.len) {
            self.view_dirty_flags.items[view_id] = false;
        }
    }

    pub fn getContentEpoch(self: *const ViewRegistry) u64 {
        return self.content_epoch;
    }

    pub fn markAllViewsDirty(self: *ViewRegistry) void {
        self.content_epoch +%= 1;
        for (self.view_dirty_flags.items) |*flag| {
            flag.* = true;
        }
    }
};

pub fn measureText(width_method: utf8.WidthMethod, tab_width: u8, text: []const u8) u32 {
    const is_ascii = utf8.isAsciiOnly(text);
    return utf8.calculateTextWidth(text, tab_width, is_ascii, width_method);
}

pub fn createChunk(
    mem_registry: *const MemRegistry,
    tab_width: u8,
    width_method: utf8.WidthMethod,
    mem_id: u8,
    byte_start: u32,
    byte_end: u32,
) TextChunk {
    const mem_buf = mem_registry.get(mem_id).?;
    const chunk_bytes = mem_buf[byte_start..byte_end];
    const is_ascii = utf8.isAsciiOnly(chunk_bytes);

    var flags: u8 = 0;
    if (chunk_bytes.len > 0 and is_ascii) {
        flags |= TextChunk.Flags.ASCII_ONLY;
    }

    const chunk_width: u16 = @intCast(@min(65535, utf8.calculateTextWidth(chunk_bytes, tab_width, is_ascii, width_method)));

    return TextChunk{
        .mem_id = mem_id,
        .byte_start = byte_start,
        .byte_end = byte_end,
        .width = chunk_width,
        .flags = flags,
    };
}

pub const ExtractChunkResult = struct {
    has_content: bool,
    new_offset: u32,
};

pub fn extractChunkBetweenOffsets(
    chunk: *const TextChunk,
    mem_registry: *const MemRegistry,
    tab_width: u8,
    start_offset: u32,
    end_offset: u32,
    chunk_start_offset: u32,
    out_buffer: []u8,
    out_index: *usize,
) ExtractChunkResult {
    const chunk_end_offset = chunk_start_offset + chunk.width;

    if (chunk_end_offset <= start_offset or chunk_start_offset >= end_offset) {
        return .{ .has_content = false, .new_offset = chunk_end_offset };
    }

    const chunk_bytes = chunk.getBytes(mem_registry);
    const is_ascii_only = (chunk.flags & TextChunk.Flags.ASCII_ONLY) != 0;

    const local_start_col: u32 = if (start_offset > chunk_start_offset) start_offset - chunk_start_offset else 0;
    const local_end_col: u32 = @min(end_offset - chunk_start_offset, chunk.width);

    var byte_start: u32 = 0;
    var byte_end: u32 = @intCast(chunk_bytes.len);

    if (local_start_col > 0) {
        const start_result = utf8.findPosByWidth(chunk_bytes, local_start_col, tab_width, is_ascii_only, false, .unicode);
        byte_start = start_result.byte_offset;
    }

    if (local_end_col < chunk.width) {
        const end_result = utf8.findPosByWidth(chunk_bytes, local_end_col, tab_width, is_ascii_only, true, .unicode);
        byte_end = end_result.byte_offset;
    }

    if (byte_start < byte_end and byte_start < chunk_bytes.len) {
        const actual_end = @min(byte_end, @as(u32, @intCast(chunk_bytes.len)));
        const selected_bytes = chunk_bytes[byte_start..actual_end];
        const copy_len = @min(selected_bytes.len, out_buffer.len - out_index.*);
        if (copy_len > 0) {
            @memcpy(out_buffer[out_index.* .. out_index.* + copy_len], selected_bytes[0..copy_len]);
            out_index.* += copy_len;
        }
    }

    return .{ .has_content = true, .new_offset = chunk_end_offset };
}

pub const StyledTextParams = struct {
    global_allocator: Allocator,
    mem_registry: *MemRegistry,
    styled_text_mem_id: *?u8,
    styled_buffer: *?[]u8,
    styled_capacity: *usize,
    syntax_style: ?*const SyntaxStyle,
    setTextInternal: *const fn (ctx: *anyopaque, mem_id: u8, text: []const u8) TextBufferError!void,
    setTextCtx: *anyopaque,
    measureText: *const fn (ctx: *anyopaque, text: []const u8) u32,
    measureCtx: *anyopaque,
    addHighlightByCharRange: *const fn (ctx: *anyopaque, start: u32, end: u32, style_id: u32, priority: u8, hl_ref: u16) TextBufferError!void,
    highlightCtx: *anyopaque,
    startHighlightsTransaction: *const fn (ctx: *anyopaque) void,
    endHighlightsTransaction: *const fn (ctx: *anyopaque) void,
};

pub fn totalStyledTextLength(chunks: []const StyledChunk) usize {
    var total_len: usize = 0;
    for (chunks) |chunk| {
        total_len += chunk.text_len;
    }
    return total_len;
}

pub fn applyStyledText(
    params: StyledTextParams,
    chunks: []const StyledChunk,
    total_len: usize,
) TextBufferError!void {
    if (total_len == 0) {
        return;
    }

    if (total_len > params.styled_capacity.*) {
        if (params.styled_buffer.*) |old_buf| {
            params.global_allocator.free(old_buf);
        }
        const new_buf = params.global_allocator.alloc(u8, total_len) catch return TextBufferError.OutOfMemory;
        params.styled_buffer.* = new_buf;
        params.styled_capacity.* = total_len;
    }

    const full_text = params.styled_buffer.*.?[0..total_len];

    var offset: usize = 0;
    for (chunks) |chunk| {
        if (chunk.text_len > 0) {
            const chunk_text = chunk.text_ptr[0..chunk.text_len];
            @memcpy(full_text[offset .. offset + chunk.text_len], chunk_text);
            offset += chunk.text_len;
        }
    }

    if (params.styled_text_mem_id.*) |mem_id| {
        try params.mem_registry.replace(mem_id, full_text, false);
    } else {
        const mem_id = try params.mem_registry.register(full_text, false);
        params.styled_text_mem_id.* = mem_id;
    }

    try params.setTextInternal(params.setTextCtx, params.styled_text_mem_id.*.?, full_text);

    if (params.syntax_style) |style| {
        params.startHighlightsTransaction(params.highlightCtx);
        defer params.endHighlightsTransaction(params.highlightCtx);

        var char_pos: u32 = 0;
        for (chunks, 0..) |chunk, i| {
            const chunk_text = chunk.text_ptr[0..chunk.text_len];
            const chunk_len = params.measureText(params.measureCtx, chunk_text);

            if (chunk_len > 0) {
                const fg = if (chunk.fg_ptr) |fgPtr| utils.f32PtrToRGBA(fgPtr) else null;
                const bg = if (chunk.bg_ptr) |bgPtr| utils.f32PtrToRGBA(bgPtr) else null;

                var style_name_buf: [64]u8 = undefined;
                const style_name = std.fmt.bufPrint(&style_name_buf, "chunk{d}", .{i}) catch continue;
                const style_id = (@constCast(style)).registerStyle(style_name, fg, bg, chunk.attributes) catch continue;

                params.addHighlightByCharRange(params.highlightCtx, char_pos, char_pos + chunk_len, style_id, 1, 0) catch {};
            }

            char_pos += chunk_len;
        }
    }
}
