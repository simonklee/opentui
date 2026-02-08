const std = @import("std");
const Allocator = std.mem.Allocator;
const seg_mod = @import("text-buffer-segment.zig");
const iter_mod = @import("text-buffer-iterators.zig");
const mem_registry_mod = @import("mem-registry.zig");
const utf8 = @import("utf8.zig");
const assert = std.debug.assert;

const Segment = seg_mod.Segment;
const TextChunk = seg_mod.TextChunk;
const LineInfo = iter_mod.LineInfo;
const TextBufferError = seg_mod.TextBufferError;
const MemRegistry = mem_registry_mod.MemRegistry;

pub const StaticBackend = struct {
    const Self = @This();

    pub const Limits = struct {
        pub const max_lines: u32 = 4_000_000;
        pub const max_segments: u32 = 16_000_000;
        pub const max_bytes: u32 = 512 * 1024 * 1024;
        pub const max_views: u32 = 1_000_000;
        pub const max_highlights_per_line: u32 = 65_535;
        pub const max_mem_buffers: u32 = 255;
        pub const max_tab_width: u32 = 64;
    };

    comptime {
        assert(@sizeOf(u8) == 1);
        assert(@sizeOf(u16) == 2);
        assert(@sizeOf(u32) == 4);
        assert(Limits.max_lines > 0);
        assert(Limits.max_segments >= Limits.max_lines);
        assert(Limits.max_mem_buffers <= std.math.maxInt(u8));
        assert(Limits.max_tab_width >= 2);
    }

    width_method: utf8.WidthMethod,
    tab_width: u8,

    global_allocator: Allocator,
    arena: *std.heap.ArenaAllocator,
    arena_allocator: Allocator,

    segments: std.ArrayListUnmanaged(Segment),

    line_starts: std.ArrayListUnmanaged(u32),
    line_widths: std.ArrayListUnmanaged(u32),
    line_seg_start: std.ArrayListUnmanaged(u32),
    line_seg_end: std.ArrayListUnmanaged(u32),

    line_break_scratch: utf8.LineBreakResult,

    max_line_width: u32,
    total_width: u32,
    total_bytes: u32,

    pub fn init(global_allocator: Allocator, width_method: utf8.WidthMethod) TextBufferError!Self {
        assert(@intFromPtr(global_allocator.ptr) != 0);
        assert(@intFromPtr(global_allocator.vtable) != 0);
        assert(@intFromEnum(width_method) <= @intFromEnum(utf8.WidthMethod.no_zwj));
        const internal_arena = global_allocator.create(std.heap.ArenaAllocator) catch return TextBufferError.OutOfMemory;
        errdefer global_allocator.destroy(internal_arena);
        internal_arena.* = std.heap.ArenaAllocator.init(global_allocator);

        const internal_allocator = internal_arena.allocator();

        var line_starts: std.ArrayListUnmanaged(u32) = .{};
        errdefer line_starts.deinit(global_allocator);
        var line_widths: std.ArrayListUnmanaged(u32) = .{};
        errdefer line_widths.deinit(global_allocator);
        var line_seg_start: std.ArrayListUnmanaged(u32) = .{};
        errdefer line_seg_start.deinit(global_allocator);
        var line_seg_end: std.ArrayListUnmanaged(u32) = .{};
        errdefer line_seg_end.deinit(global_allocator);
        var line_break_scratch = utf8.LineBreakResult.init(global_allocator);
        errdefer line_break_scratch.deinit();

        try line_starts.append(global_allocator, 0);
        try line_widths.append(global_allocator, 0);
        try line_seg_start.append(global_allocator, 0);
        try line_seg_end.append(global_allocator, 0);

        return .{
            .width_method = width_method,
            .tab_width = 2,
            .global_allocator = global_allocator,
            .arena = internal_arena,
            .arena_allocator = internal_allocator,
            .segments = .{},
            .line_starts = line_starts,
            .line_widths = line_widths,
            .line_seg_start = line_seg_start,
            .line_seg_end = line_seg_end,
            .line_break_scratch = line_break_scratch,
            .max_line_width = 0,
            .total_width = 0,
            .total_bytes = 0,
        };
    }

    pub fn deinit(self: *Self, _: Allocator) void {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        self.segments.deinit(self.global_allocator);
        self.line_starts.deinit(self.global_allocator);
        self.line_widths.deinit(self.global_allocator);
        self.line_seg_start.deinit(self.global_allocator);
        self.line_seg_end.deinit(self.global_allocator);
        self.line_break_scratch.deinit();
        self.arena.deinit();
        self.global_allocator.destroy(self.arena);
    }

    pub fn allocator(self: *const Self) Allocator {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        return self.arena_allocator;
    }

    pub fn setTabWidth(self: *Self, mem_registry: *const MemRegistry, width: u8) bool {
        assert(width >= 2);
        assert(@as(u32, width) <= Limits.max_tab_width);
        assert(self.tab_width >= 2);
        assert(@as(u32, self.tab_width) <= Limits.max_tab_width);
        const clamped_width: u8 = if (width < 2) 2 else width;
        const new_width: u8 = if (clamped_width % 2 == 0) clamped_width else clamped_width + 1;
        if (self.tab_width == new_width) return false;
        self.tab_width = new_width;

        for (self.segments.items) |*seg| {
            if (seg.asText()) |chunk_const| {
                const chunk = @constCast(chunk_const);
                const bytes = chunk.getBytes(mem_registry);
                const is_ascii = chunk.isAsciiOnly();
                chunk.width = @intCast(@min(65535, utf8.calculateTextWidth(bytes, self.tab_width, is_ascii, self.width_method)));
                chunk.graphemes = null;
            }
        }

        self.rebuildLineIndex() catch return false;
        return true;
    }

    pub fn tabWidth(self: *const Self) u8 {
        assert(self.tab_width >= 2);
        assert(@as(u32, self.tab_width) <= Limits.max_tab_width);
        return self.tab_width;
    }

    fn requiredLineSlots(self: *const Self) u32 {
        if (self.segments.items.len == 0) return 1;

        var break_count: u32 = 0;
        for (self.segments.items) |seg| {
            if (seg.isBreak()) {
                break_count += 1;
            }
        }

        return break_count + 1;
    }

    fn ensureLineIndexCapacity(self: *Self, line_slots: u32) TextBufferError!void {
        try self.line_starts.ensureTotalCapacity(self.global_allocator, line_slots);
        try self.line_widths.ensureTotalCapacity(self.global_allocator, line_slots);
        try self.line_seg_start.ensureTotalCapacity(self.global_allocator, line_slots);
        try self.line_seg_end.ensureTotalCapacity(self.global_allocator, line_slots);
    }

    pub fn clear(self: *Self) void {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);

        self.segments.clearRetainingCapacity();
        self.line_starts.clearRetainingCapacity();
        self.line_widths.clearRetainingCapacity();
        self.line_seg_start.clearRetainingCapacity();
        self.line_seg_end.clearRetainingCapacity();

        self.line_starts.appendAssumeCapacity(0);
        self.line_widths.appendAssumeCapacity(0);
        self.line_seg_start.appendAssumeCapacity(0);
        self.line_seg_end.appendAssumeCapacity(0);

        self.max_line_width = 0;
        self.total_width = 0;
        self.total_bytes = 0;
    }

    pub fn reset(self: *Self) void {
        const seg_count: u32 = @intCast(self.segments.items.len);
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(seg_count <= Limits.max_segments);
        assert(line_count <= Limits.max_lines);
        _ = self.arena.reset(if (self.arena.queryCapacity() > 0) .retain_capacity else .free_all);

        self.segments.clearRetainingCapacity();
        self.line_starts.clearRetainingCapacity();
        self.line_widths.clearRetainingCapacity();
        self.line_seg_start.clearRetainingCapacity();
        self.line_seg_end.clearRetainingCapacity();
        self.line_break_scratch.reset();

        self.line_starts.appendAssumeCapacity(0);
        self.line_widths.appendAssumeCapacity(0);
        self.line_seg_start.appendAssumeCapacity(0);
        self.line_seg_end.appendAssumeCapacity(0);

        self.max_line_width = 0;
        self.total_width = 0;
        self.total_bytes = 0;
    }

    const SetTextPreparation = struct {
        text_len: u32,
        break_count: u32,
        required_line_slots: u32,
        required_segment_slots: u32,
    };

    fn prepareSetText(self: *Self, text: []const u8) TextBufferError!SetTextPreparation {
        const text_len: u32 = @intCast(text.len);
        assert(text_len <= Limits.max_bytes);

        self.line_break_scratch.reset();
        try utf8.findLineBreaks(text, &self.line_break_scratch);

        const break_count_usize = self.line_break_scratch.breaks.items.len;
        if (break_count_usize >= std.math.maxInt(u32)) return TextBufferError.OutOfMemory;
        const break_count: u32 = @intCast(break_count_usize);
        const required_line_slots: u32 = break_count + 1;
        const required_segment_slots_u64: u64 = 2 + (@as(u64, break_count) * 3);
        if (required_line_slots > Limits.max_lines) return TextBufferError.OutOfMemory;
        if (required_segment_slots_u64 > Limits.max_segments) return TextBufferError.OutOfMemory;
        const required_segment_slots: u32 = @intCast(required_segment_slots_u64);

        try self.segments.ensureTotalCapacity(self.global_allocator, required_segment_slots);
        try self.ensureLineIndexCapacity(required_line_slots);

        return .{
            .text_len = text_len,
            .break_count = break_count,
            .required_line_slots = required_line_slots,
            .required_segment_slots = required_segment_slots,
        };
    }

    fn beginSetTextCommit(self: *Self) void {
        _ = self.arena.reset(if (self.arena.queryCapacity() > 0) .retain_capacity else .free_all);

        self.segments.clearRetainingCapacity();
        self.line_starts.clearRetainingCapacity();
        self.line_widths.clearRetainingCapacity();
        self.line_seg_start.clearRetainingCapacity();
        self.line_seg_end.clearRetainingCapacity();

        self.max_line_width = 0;
        self.total_width = 0;
        self.total_bytes = 0;
    }

    pub fn getLength(self: *const Self) u32 {
        assert(self.total_width <= Limits.max_bytes);
        assert(self.max_line_width <= self.total_width);
        return self.total_width;
    }

    pub fn getByteSize(self: *const Self) u32 {
        assert(self.total_bytes <= Limits.max_bytes);
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        return self.total_bytes + (line_count - 1);
    }

    pub fn getLineCount(self: *const Self) u32 {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        return line_count;
    }

    pub fn lineWidthAt(self: *const Self, row: u32) u32 {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(row < line_count);
        return self.line_widths.items[@intCast(row)];
    }

    pub fn maxLineWidth(self: *const Self) u32 {
        assert(self.max_line_width <= self.total_width);
        assert(self.total_width <= Limits.max_bytes);
        return self.max_line_width;
    }

    pub fn walkLinesAndSegments(
        self: *const Self,
        ctx: *anyopaque,
        segment_callback: *const fn (ctx: *anyopaque, line_idx: u32, chunk: *const TextChunk, chunk_idx_in_line: u32) void,
        line_end_callback: *const fn (ctx: *anyopaque, line_info: LineInfo) void,
    ) void {
        assert(self.line_widths.items.len == self.line_starts.items.len);
        assert(self.line_widths.items.len == self.line_seg_start.items.len);
        assert(self.line_widths.items.len == self.line_seg_end.items.len);
        const seg_count: u32 = @intCast(self.segments.items.len);
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(seg_count <= Limits.max_segments);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        assert(@intFromPtr(ctx) != 0);
        assert(@intFromPtr(segment_callback) != 0);
        assert(@intFromPtr(line_end_callback) != 0);
        var line_idx: u32 = 0;
        while (line_idx < line_count) : (line_idx += 1) {
            const seg_start: u32 = self.line_seg_start.items[@intCast(line_idx)];
            const seg_end: u32 = self.line_seg_end.items[@intCast(line_idx)];
            var seg_idx: u32 = seg_start;
            var chunk_idx_in_line: u32 = 0;

            while (seg_idx < seg_end) : (seg_idx += 1) {
                const seg = &self.segments.items[@intCast(seg_idx)];
                if (seg.asText()) |chunk| {
                    segment_callback(ctx, line_idx, chunk, chunk_idx_in_line);
                    chunk_idx_in_line += 1;
                }
            }

            line_end_callback(ctx, LineInfo{
                .line_idx = line_idx,
                .char_offset = self.line_starts.items[@intCast(line_idx)],
                .width = self.lineWidthAt(line_idx),
                .seg_start = seg_start,
                .seg_end = seg_end,
            });
        }
    }

    pub fn setTextFromMemId(self: *Self, mem_registry: *const MemRegistry, mem_id: u8) TextBufferError!void {
        assert(mem_id <= @as(u8, @intCast(Limits.max_mem_buffers)));
        assert(mem_registry.get(mem_id) != null);
        const text = mem_registry.get(mem_id) orelse return TextBufferError.InvalidMemId;
        try self.setTextInternal(mem_registry, mem_id, text);
    }

    pub fn appendFromMemId(self: *Self, mem_registry: *const MemRegistry, mem_id: u8) TextBufferError!void {
        _ = self;
        _ = mem_registry;
        _ = mem_id;
        return TextBufferError.Unsupported;
    }

    fn setTextInternal(self: *Self, mem_registry: *const MemRegistry, mem_id: u8, text: []const u8) TextBufferError!void {
        assert(mem_id <= @as(u8, @intCast(Limits.max_mem_buffers)));
        assert(mem_registry.get(mem_id) != null);

        const prep = try self.prepareSetText(text);
        assert(prep.required_segment_slots <= Limits.max_segments);
        assert(prep.required_line_slots <= Limits.max_lines);
        assert(prep.break_count <= prep.required_line_slots);

        self.beginSetTextCommit();

        var seg_count: u32 = 0;
        var line_start_offset: u32 = 0;
        var current_line_width: u32 = 0;
        var current_line_seg_start: u32 = 0;

        self.segments.appendAssumeCapacity(Segment{ .linestart = {} });
        seg_count += 1;

        var local_start: u32 = 0;
        var built_lines: u32 = 0;

        for (self.line_break_scratch.breaks.items) |line_break| {
            const break_pos: u32 = @intCast(line_break.pos);
            const local_end: u32 = switch (line_break.kind) {
                .CRLF => break_pos - 1,
                .CR, .LF => break_pos,
            };

            if (local_end > local_start) {
                const chunk = self.createChunk(mem_registry, mem_id, local_start, local_end);
                self.segments.appendAssumeCapacity(Segment{ .text = chunk });
                seg_count += 1;
                const chunk_width: u32 = chunk.width;
                current_line_width += chunk_width;
                self.total_width += chunk_width;
                self.total_bytes += chunk.byte_end - chunk.byte_start;
            }

            self.segments.appendAssumeCapacity(Segment{ .brk = {} });
            const brk_index = seg_count;
            seg_count += 1;

            self.segments.appendAssumeCapacity(Segment{ .linestart = {} });
            seg_count += 1;

            self.line_starts.appendAssumeCapacity(line_start_offset);
            self.line_widths.appendAssumeCapacity(current_line_width);
            self.line_seg_start.appendAssumeCapacity(current_line_seg_start);
            self.line_seg_end.appendAssumeCapacity(brk_index);
            if (current_line_width > self.max_line_width) self.max_line_width = current_line_width;
            built_lines += 1;

            line_start_offset += current_line_width + 1;
            current_line_width = 0;
            current_line_seg_start = brk_index + 1;

            local_start = break_pos + 1;
        }

        if (local_start < prep.text_len) {
            const chunk = self.createChunk(mem_registry, mem_id, local_start, prep.text_len);
            self.segments.appendAssumeCapacity(Segment{ .text = chunk });
            seg_count += 1;
            const chunk_width: u32 = chunk.width;
            current_line_width += chunk_width;
            self.total_width += chunk_width;
            self.total_bytes += chunk.byte_end - chunk.byte_start;
        }

        const had_breaks = built_lines > 0;
        const has_content_after_break = current_line_seg_start < seg_count;

        if (has_content_after_break or had_breaks) {
            self.line_starts.appendAssumeCapacity(line_start_offset);
            self.line_widths.appendAssumeCapacity(current_line_width);
            self.line_seg_start.appendAssumeCapacity(current_line_seg_start);
            self.line_seg_end.appendAssumeCapacity(seg_count);
            if (current_line_width > self.max_line_width) self.max_line_width = current_line_width;
        }
    }

    fn createChunk(self: *const Self, mem_registry: *const MemRegistry, mem_id: u8, byte_start: u32, byte_end: u32) TextChunk {
        assert(mem_registry.get(mem_id) != null);
        assert(byte_start <= byte_end);
        const mem_buf = mem_registry.get(mem_id).?;
        const chunk_bytes = mem_buf[byte_start..byte_end];
        const is_ascii = utf8.isAsciiOnly(chunk_bytes);

        var flags: u8 = 0;
        if (chunk_bytes.len > 0 and is_ascii) {
            flags |= TextChunk.Flags.ASCII_ONLY;
        }

        const chunk_width: u16 =
            @intCast(@min(65535, utf8.calculateTextWidth(chunk_bytes, self.tab_width, is_ascii, self.width_method)));

        return TextChunk{
            .mem_id = mem_id,
            .byte_start = byte_start,
            .byte_end = byte_end,
            .width = chunk_width,
            .flags = flags,
        };
    }

    const ExtractChunkResult = struct {
        has_content: bool,
        new_offset: u32,
    };

    fn extractChunkBetweenOffsets(
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
            const start_result =
                utf8.findPosByWidth(chunk_bytes, local_start_col, tab_width, is_ascii_only, false, .unicode);
            byte_start = start_result.byte_offset;
        }

        if (local_end_col < chunk.width) {
            const end_result =
                utf8.findPosByWidth(chunk_bytes, local_end_col, tab_width, is_ascii_only, true, .unicode);
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

    fn rebuildLineIndex(self: *Self) TextBufferError!void {
        const seg_count: u32 = @intCast(self.segments.items.len);
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(seg_count <= Limits.max_segments);
        assert(line_count <= Limits.max_lines);
        if (self.segments.items.len > 0) assert(self.segments.items[0].isLineStart());

        const required_line_slots = self.requiredLineSlots();
        try self.ensureLineIndexCapacity(required_line_slots);

        self.line_starts.clearRetainingCapacity();
        self.line_widths.clearRetainingCapacity();
        self.line_seg_start.clearRetainingCapacity();
        self.line_seg_end.clearRetainingCapacity();

        self.max_line_width = 0;
        self.total_width = 0;
        self.total_bytes = 0;

        if (seg_count == 0) {
            self.line_starts.appendAssumeCapacity(0);
            self.line_widths.appendAssumeCapacity(0);
            self.line_seg_start.appendAssumeCapacity(0);
            self.line_seg_end.appendAssumeCapacity(0);
            return;
        }

        var line_start_offset: u32 = 0;
        var current_line_width: u32 = 0;
        var current_line_seg_start: u32 = 0;
        var seg_idx: u32 = 0;
        var built_lines: u32 = 0;

        while (seg_idx < seg_count) : (seg_idx += 1) {
            const seg = &self.segments.items[@intCast(seg_idx)];
            switch (seg.*) {
                .text => |chunk| {
                    const chunk_width: u32 = chunk.width;
                    current_line_width += chunk_width;
                    self.total_width += chunk_width;
                    self.total_bytes += chunk.byte_end - chunk.byte_start;
                },
                .brk => {
                    self.line_starts.appendAssumeCapacity(line_start_offset);
                    self.line_widths.appendAssumeCapacity(current_line_width);
                    self.line_seg_start.appendAssumeCapacity(current_line_seg_start);
                    self.line_seg_end.appendAssumeCapacity(seg_idx);
                    if (current_line_width > self.max_line_width) self.max_line_width = current_line_width;
                    built_lines += 1;

                    line_start_offset += current_line_width + 1;
                    current_line_width = 0;
                    current_line_seg_start = seg_idx + 1;
                },
                .linestart => {},
            }
        }

        const had_breaks = built_lines > 0;
        const has_content_after_break = current_line_seg_start < seg_count;

        if (has_content_after_break or had_breaks) {
            self.line_starts.appendAssumeCapacity(line_start_offset);
            self.line_widths.appendAssumeCapacity(current_line_width);
            self.line_seg_start.appendAssumeCapacity(current_line_seg_start);
            self.line_seg_end.appendAssumeCapacity(seg_count);
            if (current_line_width > self.max_line_width) self.max_line_width = current_line_width;
        }
    }

    pub fn getPlainTextIntoBuffer(self: *const Self, mem_registry: *const MemRegistry, out_buffer: []u8) usize {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        const out_len: u32 = @intCast(out_buffer.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        assert(out_len <= Limits.max_bytes);
        var out_index: usize = 0;

        const Context = struct {
            buffer: *const Self,
            mem_registry: *const MemRegistry,
            out_buffer: []u8,
            out_index: *usize,
            line_count: u32,

            fn segmentCallback(ctx_ptr: *anyopaque, line_idx: u32, chunk: *const TextChunk, chunk_idx_in_line: u32) void {
                _ = line_idx;
                _ = chunk_idx_in_line;
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_ptr)));
                const chunk_bytes = chunk.getBytes(ctx.mem_registry);
                const copy_len = @min(chunk_bytes.len, ctx.out_buffer.len - ctx.out_index.*);
                if (copy_len > 0) {
                    @memcpy(ctx.out_buffer[ctx.out_index.* .. ctx.out_index.* + copy_len], chunk_bytes[0..copy_len]);
                    ctx.out_index.* += copy_len;
                }
            }

            fn lineEndCallback(ctx_ptr: *anyopaque, line_info: LineInfo) void {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_ptr)));
                if (ctx.line_count > 0 and line_info.line_idx < ctx.line_count - 1 and ctx.out_index.* < ctx.out_buffer.len) {
                    ctx.out_buffer[ctx.out_index.*] = '\n';
                    ctx.out_index.* += 1;
                }
            }
        };

        var ctx = Context{
            .buffer = self,
            .mem_registry = mem_registry,
            .out_buffer = out_buffer,
            .out_index = &out_index,
            .line_count = line_count,
        };
        self.walkLinesAndSegments(&ctx, Context.segmentCallback, Context.lineEndCallback);

        return out_index;
    }

    pub fn getTextRange(
        self: *const Self,
        mem_registry: *const MemRegistry,
        start_offset: u32,
        end_offset: u32,
        out_buffer: []u8,
    ) usize {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        const out_len: u32 = @intCast(out_buffer.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        const total_weight: u32 = self.total_width + (line_count - 1);
        var clamped_end = end_offset;
        if (clamped_end > total_weight) clamped_end = total_weight;
        assert(start_offset <= clamped_end);
        assert(clamped_end <= total_weight);
        assert(out_len <= Limits.max_bytes);
        if (start_offset >= clamped_end) return 0;
        if (out_buffer.len == 0) return 0;
        if (start_offset >= total_weight) return 0;

        var left: u32 = 0;
        var right: u32 = line_count;
        while (left < right) {
            const mid = left + (right - left) / 2;
            const line_start = self.line_starts.items[@intCast(mid)];
            if (start_offset < line_start) {
                right = mid;
            } else {
                left = mid + 1;
            }
        }
        const start_line_idx: u32 = if (left == 0) 0 else left - 1;

        var out_index: usize = 0;
        var char_offset: u32 = self.line_starts.items[@intCast(start_line_idx)];
        var line_idx: u32 = start_line_idx;
        var line_had_content = false;

        while (line_idx < line_count and char_offset < clamped_end and out_index < out_buffer.len) {
            const seg_start: u32 = self.line_seg_start.items[@intCast(line_idx)];
            const seg_end: u32 = self.line_seg_end.items[@intCast(line_idx)];

            var seg_idx: u32 = seg_start;
            while (seg_idx < seg_end) : (seg_idx += 1) {
                const seg = &self.segments.items[@intCast(seg_idx)];
                if (seg.asText()) |chunk| {
                    const result = extractChunkBetweenOffsets(
                        chunk,
                        mem_registry,
                        self.tab_width,
                        start_offset,
                        clamped_end,
                        char_offset,
                        out_buffer,
                        &out_index,
                    );
                    if (result.has_content) {
                        line_had_content = true;
                    }
                    char_offset = result.new_offset;
                }
            }

            if (line_had_content and line_idx < line_count - 1 and char_offset + 1 < clamped_end and out_index < out_buffer.len) {
                out_buffer[out_index] = '\n';
                out_index += 1;
            }

            char_offset += 1;
            line_had_content = false;
            line_idx += 1;
        }

        return out_index;
    }

    pub fn getTextRangeByCoords(
        self: *const Self,
        mem_registry: *const MemRegistry,
        start_row: u32,
        start_col: u32,
        end_row: u32,
        end_col: u32,
        out_buffer: []u8,
    ) usize {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        const out_len: u32 = @intCast(out_buffer.len);
        assert(start_row < line_count);
        assert(end_row < line_count);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        if (start_row == end_row) assert(start_col <= end_col);
        assert(out_len <= Limits.max_bytes);
        if (start_row >= line_count or end_row >= line_count) return 0;

        const start_line_width = self.lineWidthAt(start_row);
        const end_line_width = self.lineWidthAt(end_row);
        if (start_col > start_line_width or end_col > end_line_width) return 0;

        const start_offset = self.line_starts.items[@intCast(start_row)] + start_col;
        const end_offset = self.line_starts.items[@intCast(end_row)] + end_col;
        return self.getTextRange(mem_registry, start_offset, end_offset, out_buffer);
    }

    pub fn getArenaAllocatedBytes(self: *const Self) usize {
        return self.arena.queryCapacity();
    }

    pub fn getAllocatedBytes(self: *const Self) usize {
        var total = self.arena.queryCapacity();
        total += self.segments.capacity * @sizeOf(Segment);
        total += self.line_starts.capacity * @sizeOf(u32);
        total += self.line_widths.capacity * @sizeOf(u32);
        total += self.line_seg_start.capacity * @sizeOf(u32);
        total += self.line_seg_end.capacity * @sizeOf(u32);
        total += self.line_break_scratch.breaks.capacity * @sizeOf(utf8.LineBreak);
        return total;
    }
};
