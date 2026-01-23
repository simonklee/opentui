const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const seg_mod = @import("text-buffer-segment.zig");
const iter_mod = @import("text-buffer-iterators.zig");
const mem_registry_mod = @import("mem-registry.zig");
const highlight_mod = @import("text-buffer-highlights.zig");
const shared = @import("text-buffer-shared.zig");
const ss = @import("syntax-style.zig");
const gp = @import("grapheme.zig");
const unified_backend = @import("text-buffer-backend-unified.zig");
const static_backend = @import("text-buffer-backend-static.zig");

const utf8 = @import("utf8.zig");
const logger = @import("logger.zig");
const Limits = static_backend.StaticBackend.Limits;

const Segment = seg_mod.Segment;
const UnifiedRope = seg_mod.UnifiedRope;
const LineInfo = iter_mod.LineInfo;

pub const TextChunk = seg_mod.TextChunk;
pub const MemRegistry = mem_registry_mod.MemRegistry;
pub const RGBA = seg_mod.RGBA;
pub const TextSelection = seg_mod.TextSelection;
pub const TextBufferError = seg_mod.TextBufferError;
pub const Highlight = seg_mod.Highlight;
pub const StyleSpan = seg_mod.StyleSpan;
pub const WrapMode = seg_mod.WrapMode;
pub const ChunkFitResult = seg_mod.ChunkFitResult;
pub const GraphemeInfo = seg_mod.GraphemeInfo;
pub const SegmentsResult = unified_backend.SegmentsResult;

pub const SyntaxStyle = ss.SyntaxStyle;

pub const StyledChunk = shared.StyledChunk;

pub const TextBuffer = struct {
    const Self = @This();

    pub const BackendKind = enum { unified, static };
    pub const Backend = union(BackendKind) {
        unified: unified_backend.UnifiedBackend,
        static: static_backend.StaticBackend,
    };

    global_allocator: Allocator,
    pool: *gp.GraphemePool,
    width_method: utf8.WidthMethod,
    tab_width: u8,

    mem_registry: MemRegistry,
    default_values: Defaults,
    highlights: highlight_mod.HighlightRegistry,
    view_registry: shared.ViewRegistry,
    syntax_style: ?*const SyntaxStyle,
    styled_text_mem_id: ?u8,
    styled_buffer: ?[]u8,
    styled_capacity: usize,

    backend: Backend,

    pub const Defaults = struct {
        fg: ?RGBA,
        bg: ?RGBA,
        attributes: ?u32,
    };

    pub fn init(
        global_allocator: Allocator,
        pool: *gp.GraphemePool,
        width_method: utf8.WidthMethod,
        kind: BackendKind,
    ) TextBufferError!*Self {
        assert(@intFromPtr(pool) != 0);
        assert(@intFromPtr(global_allocator.ptr) != 0);
        assert(@intFromPtr(global_allocator.vtable) != 0);
        assert(@intFromEnum(width_method) <= @intFromEnum(utf8.WidthMethod.no_zwj));
        const self = global_allocator.create(Self) catch return TextBufferError.OutOfMemory;
        errdefer global_allocator.destroy(self);

        var mem_registry = MemRegistry.init(global_allocator);
        errdefer mem_registry.deinit();

        var view_registry = shared.ViewRegistry{};
        errdefer view_registry.deinit(global_allocator);

        var highlights = highlight_mod.HighlightRegistry.init(global_allocator);
        errdefer highlights.deinit();

        var backend: Backend = switch (kind) {
            .unified => .{ .unified = try unified_backend.UnifiedBackend.init(global_allocator, width_method) },
            .static => .{ .static = try static_backend.StaticBackend.init(global_allocator, width_method) },
        };
        errdefer switch (backend) {
            .unified => |*backend_unified| backend_unified.deinit(global_allocator),
            .static => |*backend_static| backend_static.deinit(global_allocator),
        };

        self.* = .{
            .global_allocator = global_allocator,
            .pool = pool,
            .width_method = width_method,
            .tab_width = 2,
            .mem_registry = mem_registry,
            .default_values = .{ .fg = null, .bg = null, .attributes = null },
            .highlights = highlights,
            .view_registry = view_registry,
            .syntax_style = null,
            .styled_text_mem_id = null,
            .styled_buffer = null,
            .styled_capacity = 0,
            .backend = backend,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        if (self.syntax_style) |style| {
            (@constCast(style)).offDestroy(@ptrCast(self), onSyntaxStyleDestroyed);
        }

        self.view_registry.deinit(self.global_allocator);
        self.highlights.deinit();

        if (self.styled_buffer) |buf| {
            self.global_allocator.free(buf);
        }

        self.mem_registry.deinit();

        switch (self.backend) {
            .unified => |*backend| backend.deinit(self.global_allocator),
            .static => |*backend| backend.deinit(self.global_allocator),
        }

        self.global_allocator.destroy(self);
    }

    pub fn defaults(self: *const Self) Defaults {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        return self.default_values;
    }

    pub fn memRegistry(self: *const Self) *const MemRegistry {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        return &self.mem_registry;
    }

    pub fn allocator(self: *const Self) Allocator {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        return switch (self.backend) {
            .unified => |*backend| backend.allocator(),
            .static => |*backend| backend.allocator(),
        };
    }

    pub fn widthMethod(self: *const Self) utf8.WidthMethod {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        return self.width_method;
    }

    pub fn tabWidth(self: *const Self) u8 {
        assert(self.tab_width >= 2);
        assert(@as(u32, self.tab_width) <= Limits.max_tab_width);
        return self.tab_width;
    }

    pub fn setTabWidth(self: *Self, width: u8) void {
        assert(width >= 2);
        assert(@as(u32, width) <= Limits.max_tab_width);
        assert(self.tab_width >= 2);
        assert(@as(u32, self.tab_width) <= Limits.max_tab_width);
        const clamped_width = @max(2, width);
        const new_width = if (clamped_width % 2 == 0) clamped_width else clamped_width + 1;
        if (self.tab_width == new_width) return;

        self.tab_width = new_width;

        switch (self.backend) {
            .unified => |*backend| {
                _ = backend.setTabWidth(new_width);
            },
            .static => |*backend| {
                _ = backend.setTabWidth(&self.mem_registry, new_width);
            },
        }

        self.markAllViewsDirty();
    }

    pub fn setDefaultFg(self: *Self, fg: ?RGBA) void {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        if (fg) |rgba| assert(!std.math.isNan(rgba[0]));
        if (fg) |rgba| assert(!std.math.isNan(rgba[3]));
        self.default_values.fg = fg;
    }

    pub fn setDefaultBg(self: *Self, bg: ?RGBA) void {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        if (bg) |rgba| assert(!std.math.isNan(rgba[1]));
        if (bg) |rgba| assert(!std.math.isNan(rgba[3]));
        self.default_values.bg = bg;
    }

    pub fn setDefaultAttributes(self: *Self, attributes: ?u32) void {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        if (attributes) |value| assert(value <= std.math.maxInt(u32));
        if (attributes) |value| assert(value >= 0);
        self.default_values.attributes = attributes;
    }

    pub fn resetDefaults(self: *Self) void {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        self.default_values.fg = null;
        self.default_values.bg = null;
        self.default_values.attributes = null;
    }

    fn onSyntaxStyleDestroyed(ctx_ptr: *anyopaque) void {
        const self = @as(*Self, @ptrCast(@alignCast(ctx_ptr)));
        self.syntax_style = null;
    }

    pub fn setSyntaxStyle(self: *Self, syntax_style: ?*const SyntaxStyle) void {
        const line_count = self.getLineCount();
        if (syntax_style) |style| assert(@intFromPtr(style) != 0);
        assert(@intFromPtr(self) != 0);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        if (self.syntax_style) |prev| {
            (@constCast(prev)).offDestroy(@ptrCast(self), onSyntaxStyleDestroyed);
        }
        self.syntax_style = syntax_style;
        if (syntax_style) |style| {
            _ = (@constCast(style)).onDestroy(@ptrCast(self), onSyntaxStyleDestroyed) catch {};
        }
    }

    pub fn getSyntaxStyle(self: *const Self) ?*const SyntaxStyle {
        const line_count = self.getLineCount();
        if (self.syntax_style) |style| assert(@intFromPtr(style) != 0);
        assert(@intFromPtr(self) != 0);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        return self.syntax_style;
    }

    pub fn registerView(self: *Self) TextBufferError!u32 {
        const view_count: u32 = @intCast(self.view_registry.view_dirty_flags.items.len);
        assert(view_count <= Limits.max_views);
        assert(self.view_registry.next_view_id <= Limits.max_views);
        return self.view_registry.registerView(self.global_allocator);
    }

    pub fn unregisterView(self: *Self, view_id: u32) void {
        const view_count: u32 = @intCast(self.view_registry.view_dirty_flags.items.len);
        assert(view_count <= Limits.max_views);
        self.view_registry.unregisterView(self.global_allocator, view_id);
    }

    pub fn isViewDirty(self: *const Self, view_id: u32) bool {
        const view_count: u32 = @intCast(self.view_registry.view_dirty_flags.items.len);
        assert(view_count <= Limits.max_views);
        return self.view_registry.isViewDirty(view_id);
    }

    pub fn clearViewDirty(self: *Self, view_id: u32) void {
        const view_count: u32 = @intCast(self.view_registry.view_dirty_flags.items.len);
        assert(view_count <= Limits.max_views);
        self.view_registry.clearViewDirty(view_id);
    }

    pub fn getContentEpoch(self: *const Self) u64 {
        const epoch = self.view_registry.getContentEpoch();
        assert(epoch < std.math.maxInt(u64));
        assert(epoch >= 0);
        return epoch;
    }

    fn markAllViewsDirty(self: *Self) void {
        const view_count: u32 = @intCast(self.view_registry.view_dirty_flags.items.len);
        assert(view_count <= Limits.max_views);
        assert(self.view_registry.next_view_id <= Limits.max_views);
        self.view_registry.markAllViewsDirty();
    }

    pub fn markViewsDirty(self: *Self) void {
        const view_count: u32 = @intCast(self.view_registry.view_dirty_flags.items.len);
        assert(view_count <= Limits.max_views);
        assert(self.view_registry.next_view_id <= Limits.max_views);
        self.markAllViewsDirty();
    }

    pub fn getLength(self: *const Self) u32 {
        return switch (self.backend) {
            .unified => |*backend| backend.getLength(),
            .static => |*backend| backend.getLength(),
        };
    }

    pub fn getByteSize(self: *const Self) u32 {
        return switch (self.backend) {
            .unified => |*backend| backend.getByteSize(),
            .static => |*backend| backend.getByteSize(),
        };
    }

    pub fn getLineCount(self: *const Self) u32 {
        const line_count = switch (self.backend) {
            .unified => |*backend| backend.getLineCount(),
            .static => |*backend| backend.getLineCount(),
        };
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        return line_count;
    }

    pub fn lineCount(self: *const Self) u32 {
        return self.getLineCount();
    }

    pub fn lineWidthAt(self: *const Self, row: u32) u32 {
        const line_count = self.getLineCount();
        assert(row < line_count);
        return switch (self.backend) {
            .unified => |*backend| backend.lineWidthAt(row),
            .static => |*backend| backend.lineWidthAt(row),
        };
    }

    pub fn maxLineWidth(self: *const Self) u32 {
        return switch (self.backend) {
            .unified => |*backend| backend.maxLineWidth(),
            .static => |*backend| backend.maxLineWidth(),
        };
    }

    pub fn clear(self: *Self) void {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        switch (self.backend) {
            .unified => |*backend| backend.clear(),
            .static => |*backend| backend.clear(),
        }
        self.markAllViewsDirty();
    }

    pub fn reset(self: *Self) void {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        self.highlights.clearRetainingCapacity();

        if (self.styled_buffer) |buf| {
            self.global_allocator.free(buf);
        }
        self.styled_buffer = null;
        self.styled_text_mem_id = null;
        self.styled_capacity = 0;

        self.mem_registry.clear();

        switch (self.backend) {
            .unified => |*backend| backend.reset(),
            .static => |*backend| backend.reset(),
        }

        self.markAllViewsDirty();
    }

    pub fn setText(self: *Self, text: []const u8) TextBufferError!void {
        const text_len: u32 = @intCast(text.len);
        const line_count = self.getLineCount();
        assert(text_len <= Limits.max_bytes);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        const mem_id = try self.mem_registry.register(text, false);
        try self.setTextInternal(mem_id, text);
    }

    pub fn setTextFromMemId(self: *Self, mem_id: u8) TextBufferError!void {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        const text = self.mem_registry.get(mem_id) orelse return TextBufferError.InvalidMemId;
        try self.setTextInternal(mem_id, text);
    }

    pub fn append(self: *Self, text: []const u8) TextBufferError!void {
        const text_len: u32 = @intCast(text.len);
        assert(text_len <= Limits.max_bytes);
        if (text.len == 0) {
            return;
        }

        const mem_id = try self.mem_registry.register(text, false);
        try self.appendInternal(mem_id, text);
    }

    pub fn appendFromMemId(self: *Self, mem_id: u8) TextBufferError!void {
        const text = self.mem_registry.get(mem_id) orelse return TextBufferError.InvalidMemId;
        if (text.len == 0) {
            return;
        }
        try self.appendInternal(mem_id, text);
    }

    fn appendInternal(self: *Self, mem_id: u8, text: []const u8) TextBufferError!void {
        _ = text;
        switch (self.backend) {
            .unified => |*backend| try backend.appendFromMemId(&self.mem_registry, mem_id),
            .static => |*backend| try backend.appendFromMemId(&self.mem_registry, mem_id),
        }
        self.markAllViewsDirty();
    }

    fn setTextInternal(self: *Self, mem_id: u8, text: []const u8) TextBufferError!void {
        const text_len: u32 = @intCast(text.len);
        assert(text_len <= Limits.max_bytes);
        assert(self.mem_registry.get(mem_id) != null);
        switch (self.backend) {
            .unified => |*backend| try backend.setTextFromMemId(&self.mem_registry, mem_id),
            .static => |*backend| try backend.setTextFromMemId(&self.mem_registry, mem_id),
        }
        self.markAllViewsDirty();
    }

    pub fn textToSegments(
        self: *const Self,
        alloc: Allocator,
        text: []const u8,
        mem_id: u8,
        byte_offset: u32,
        prepend_linestart: bool,
    ) TextBufferError!SegmentsResult {
        return switch (self.backend) {
            .unified => |*backend| backend.textToSegments(alloc, &self.mem_registry, text, mem_id, byte_offset, prepend_linestart),
            .static => TextBufferError.Unsupported,
        };
    }

    pub fn loadFile(self: *Self, path: []const u8) TextBufferError!void {
        const path_len: u32 = @intCast(path.len);
        assert(path_len > 0);
        assert(path_len <= Limits.max_bytes);
        assert(@intFromPtr(self) != 0);
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => TextBufferError.InvalidIndex,
                error.AccessDenied => TextBufferError.InvalidIndex,
                else => TextBufferError.OutOfMemory,
            };
        };
        defer file.close();

        const file_size = file.getEndPos() catch return TextBufferError.OutOfMemory;
        if (file_size > @as(u64, Limits.max_bytes)) return TextBufferError.OutOfMemory;
        const file_size_usize: usize = @intCast(file_size);

        const content = self.global_allocator.alloc(u8, file_size_usize) catch return TextBufferError.OutOfMemory;
        errdefer self.global_allocator.free(content);
        const bytes_read = file.readAll(content) catch return TextBufferError.OutOfMemory;
        const text = content[0..bytes_read];
        const mem_id = try self.mem_registry.register(text, true);

        try self.setTextInternal(mem_id, text);
    }

    pub fn getPlainTextIntoBuffer(self: *const Self, out_buffer: []u8) usize {
        const line_count = self.getLineCount();
        const out_len: u32 = @intCast(out_buffer.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        assert(out_len <= Limits.max_bytes);
        return switch (self.backend) {
            .unified => |*backend| backend.getPlainTextIntoBuffer(&self.mem_registry, out_buffer),
            .static => |*backend| backend.getPlainTextIntoBuffer(&self.mem_registry, out_buffer),
        };
    }

    pub fn getTextRange(self: *const Self, start_offset: u32, end_offset: u32, out_buffer: []u8) usize {
        const line_count = self.getLineCount();
        const out_len: u32 = @intCast(out_buffer.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        assert(start_offset <= end_offset);
        assert(out_len <= Limits.max_bytes);
        return switch (self.backend) {
            .unified => |*backend| backend.getTextRange(&self.mem_registry, start_offset, end_offset, out_buffer),
            .static => |*backend| backend.getTextRange(&self.mem_registry, start_offset, end_offset, out_buffer),
        };
    }

    pub fn getTextRangeByCoords(
        self: *const Self,
        start_row: u32,
        start_col: u32,
        end_row: u32,
        end_col: u32,
        out_buffer: []u8,
    ) usize {
        const line_count = self.getLineCount();
        const out_len: u32 = @intCast(out_buffer.len);
        assert(start_row < line_count);
        assert(end_row < line_count);
        if (start_row == end_row) assert(start_col <= end_col);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        assert(out_len <= Limits.max_bytes);
        return switch (self.backend) {
            .unified => |*backend| backend.getTextRangeByCoords(&self.mem_registry, start_row, start_col, end_row, end_col, out_buffer),
            .static => |*backend| backend.getTextRangeByCoords(&self.mem_registry, start_row, start_col, end_row, end_col, out_buffer),
        };
    }

    pub fn registerMemBuffer(self: *Self, data: []const u8, owned: bool) TextBufferError!u8 {
        const data_len: u32 = @intCast(data.len);
        assert(data_len <= Limits.max_bytes);
        assert(owned == true or owned == false);
        assert(@intFromPtr(self) != 0);
        return try self.mem_registry.register(data, owned);
    }

    pub fn replaceMemBuffer(self: *Self, mem_id: u8, data: []const u8, owned: bool) TextBufferError!void {
        const data_len: u32 = @intCast(data.len);
        assert(data_len <= Limits.max_bytes);
        assert(owned == true or owned == false);
        assert(@intFromPtr(self) != 0);
        try self.mem_registry.replace(mem_id, data, owned);
    }

    pub fn clearMemRegistry(self: *Self) void {
        self.mem_registry.clear();
    }

    pub fn getMemBuffer(self: *const Self, mem_id: u8) ?[]const u8 {
        return self.mem_registry.get(mem_id);
    }

    pub fn createChunk(
        self: *const Self,
        mem_id: u8,
        byte_start: u32,
        byte_end: u32,
    ) TextChunk {
        assert(self.mem_registry.get(mem_id) != null);
        assert(byte_start <= byte_end);
        return shared.createChunk(&self.mem_registry, self.tab_width, self.width_method, mem_id, byte_start, byte_end);
    }

    pub fn addLine(
        self: *Self,
        mem_id: u8,
        byte_start: u32,
        byte_end: u32,
    ) TextBufferError!void {
        _ = self.mem_registry.get(mem_id) orelse return TextBufferError.InvalidMemId;

        switch (self.backend) {
            .unified => |*backend| {
                const chunk = self.createChunk(mem_id, byte_start, byte_end);
                const had_content = backend.rope.count() > 1;

                if (had_content) {
                    try backend.rope.append(Segment{ .brk = {} });
                    try backend.rope.append(Segment{ .linestart = {} });
                }

                try backend.rope.append(Segment{ .text = chunk });
            },
            .static => {
                return TextBufferError.Unsupported;
            },
        }

        self.markAllViewsDirty();
    }

    pub fn getArenaAllocatedBytes(self: *const Self) usize {
        return switch (self.backend) {
            .unified => |*backend| backend.getArenaAllocatedBytes(),
            .static => |*backend| backend.getArenaAllocatedBytes(),
        };
    }

    pub fn debugLogRope(self: *const Self) void {
        switch (self.backend) {
            .unified => |*backend| backend.debugLogRope(),
            .static => logger.debug("Static backend has no rope to dump", .{}),
        }
    }

    pub fn walkLinesAndSegments(
        self: *const Self,
        ctx: *anyopaque,
        segment_callback: *const fn (ctx: *anyopaque, line_idx: u32, chunk: *const TextChunk, chunk_idx_in_line: u32) void,
        line_end_callback: *const fn (ctx: *anyopaque, line_info: LineInfo) void,
    ) void {
        switch (self.backend) {
            .unified => |*backend| backend.walkLinesAndSegments(ctx, segment_callback, line_end_callback),
            .static => |*backend| backend.walkLinesAndSegments(ctx, segment_callback, line_end_callback),
        }
    }

    fn coordsToOffset(self: *const Self, row: u32, col: u32) ?u32 {
        return switch (self.backend) {
            .unified => |*backend| iter_mod.coordsToOffset(@constCast(&backend.rope), row, col),
            .static => |*backend| blk: {
                const line_count = backend.getLineCount();
                if (row >= line_count) break :blk null;
                const line_width = backend.lineWidthAt(row);
                if (col > line_width) break :blk null;
                break :blk backend.line_starts.items[@intCast(row)] + col;
            },
        };
    }

    fn lineWidthForHighlights(ctx_ptr: *anyopaque, line_idx: usize) u32 {
        const self = @as(*Self, @ptrCast(@alignCast(ctx_ptr)));
        return self.lineWidthAt(@intCast(line_idx));
    }

    pub fn startHighlightsTransaction(self: *Self) void {
        const span_count: u32 = @intCast(self.highlights.line_spans.items.len);
        assert(self.highlights.highlight_batch_depth < std.math.maxInt(u32));
        assert(span_count <= Limits.max_lines);
        self.highlights.startTransaction();
    }

    pub fn endHighlightsTransaction(self: *Self) void {
        const span_count: u32 = @intCast(self.highlights.line_spans.items.len);
        assert(self.highlights.highlight_batch_depth <= std.math.maxInt(u32));
        assert(span_count <= Limits.max_lines);
        self.highlights.endTransaction(self, lineWidthForHighlights);
    }

    pub fn addHighlight(
        self: *Self,
        line_idx: usize,
        col_start: u32,
        col_end: u32,
        style_id: u32,
        priority: u8,
        hl_ref: u16,
    ) TextBufferError!void {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        assert(hl_ref <= std.math.maxInt(u16));
        if (line_idx >= line_count) {
            return TextBufferError.InvalidIndex;
        }

        const line_width = self.lineWidthAt(@intCast(line_idx));
        const clamped_start = if (col_start > line_width) line_width else col_start;
        const clamped_end = if (col_end > line_width) line_width else col_end;

        if (clamped_start >= clamped_end) {
            return;
        }

        const hl = Highlight{
            .col_start = clamped_start,
            .col_end = clamped_end,
            .style_id = style_id,
            .priority = priority,
            .hl_ref = hl_ref,
        };

        try self.highlights.addHighlight(self, lineWidthForHighlights, line_idx, hl);
    }

    pub fn addHighlightByCoords(
        self: *Self,
        start_row: u32,
        start_col: u32,
        end_row: u32,
        end_col: u32,
        style_id: u32,
        priority: u8,
        hl_ref: u16,
    ) TextBufferError!void {
        assert(hl_ref <= std.math.maxInt(u16));
        const char_start = self.coordsToOffset(start_row, start_col) orelse return TextBufferError.InvalidIndex;
        const char_end = self.coordsToOffset(end_row, end_col) orelse return TextBufferError.InvalidIndex;
        return self.addHighlightByCharRange(char_start, char_end, style_id, priority, hl_ref);
    }

    pub fn addHighlightByCharRange(
        self: *Self,
        char_start: u32,
        char_end: u32,
        style_id: u32,
        priority: u8,
        hl_ref: u16,
    ) TextBufferError!void {
        const line_count = self.getLineCount();
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        assert(hl_ref <= std.math.maxInt(u16));
        if (line_count == 0) {
            return;
        }

        switch (self.backend) {
            .unified => |*backend| {
                const total_weight = backend.rope.totalWeight();
                const clamped_end = if (char_end > total_weight) total_weight else char_end;
                if (char_start >= clamped_end) return;
                const Context = struct {
                    buffer: *Self,
                    char_start: u32,
                    char_end: u32,
                    style_id: u32,
                    priority: u8,
                    hl_ref: u16,

                    fn callback(ctx_ptr: *anyopaque, line_info: LineInfo) void {
                        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_ptr)));
                        const line_start_char = line_info.char_offset;
                        const line_end_char = line_info.char_offset + line_info.width;

                        if (line_end_char <= ctx.char_start) return;
                        if (line_start_char >= ctx.char_end) return;

                        const col_start = if (ctx.char_start > line_start_char)
                            ctx.char_start - line_start_char
                        else
                            0;

                        const col_end = if (ctx.char_end < line_end_char)
                            ctx.char_end - line_start_char
                        else
                            line_info.width;

                        ctx.buffer.addHighlight(
                            line_info.line_idx,
                            col_start,
                            col_end,
                            ctx.style_id,
                            ctx.priority,
                            ctx.hl_ref,
                        ) catch {};
                    }
                };

                var ctx = Context{
                    .buffer = self,
                    .char_start = char_start,
                    .char_end = clamped_end,
                    .style_id = style_id,
                    .priority = priority,
                    .hl_ref = hl_ref,
                };
                iter_mod.walkLines(&backend.rope, &ctx, Context.callback, false);
            },
            .static => |*backend| {
                const total_weight: u32 = backend.total_width + (line_count - 1);
                const clamped_end = if (char_end > total_weight) total_weight else char_end;
                if (char_start >= clamped_end) return;

                var line_idx: u32 = 0;
                while (line_idx < line_count) : (line_idx += 1) {
                    const line_start = backend.line_starts.items[@intCast(line_idx)];
                    const line_width = backend.line_widths.items[@intCast(line_idx)];
                    const line_end = line_start + line_width;

                    if (line_end <= char_start) continue;
                    if (line_start >= clamped_end) break;

                    const col_start = if (char_start > line_start) char_start - line_start else 0;
                    const col_end = if (clamped_end < line_end) clamped_end - line_start else line_width;

                    if (col_start < col_end) {
                        self.addHighlight(@intCast(line_idx), col_start, col_end, style_id, priority, hl_ref) catch {};
                    }
                }
            },
        }
    }

    pub fn removeHighlightsByRef(self: *Self, hl_ref: u16) void {
        const hl_count: u32 = @intCast(self.highlights.line_highlights.items.len);
        assert(hl_ref >= 0);
        assert(hl_count <= Limits.max_lines);
        self.highlights.removeHighlightsByRef(self, lineWidthForHighlights, hl_ref);
    }

    pub fn clearLineHighlights(self: *Self, line_idx: usize) void {
        const hl_count: u32 = @intCast(self.highlights.line_highlights.items.len);
        assert(hl_count <= Limits.max_lines);
        self.highlights.clearLineHighlights(line_idx);
    }

    pub fn clearAllHighlights(self: *Self) void {
        const hl_count: u32 = @intCast(self.highlights.line_highlights.items.len);
        const span_count: u32 = @intCast(self.highlights.line_spans.items.len);
        assert(hl_count <= Limits.max_lines);
        assert(span_count <= Limits.max_lines);
        self.highlights.clearAllHighlights();
    }

    pub fn getLineHighlights(self: *const Self, line_idx: usize) []const Highlight {
        const hl_count: u32 = @intCast(self.highlights.line_highlights.items.len);
        assert(hl_count <= Limits.max_lines);
        return self.highlights.getLineHighlights(line_idx);
    }

    pub fn getLineHighlightsSlice(self: *const Self, line_idx: usize) []const Highlight {
        return self.getLineHighlights(line_idx);
    }

    pub fn getHighlightCount(self: *const Self) u32 {
        const hl_count: u32 = @intCast(self.highlights.line_highlights.items.len);
        const span_count: u32 = @intCast(self.highlights.line_spans.items.len);
        assert(hl_count <= Limits.max_lines);
        assert(span_count <= Limits.max_lines);
        return self.highlights.getHighlightCount();
    }

    pub fn getLineSpans(self: *Self, line_idx: usize) []const StyleSpan {
        const span_count: u32 = @intCast(self.highlights.line_spans.items.len);
        assert(span_count <= Limits.max_lines);
        return self.highlights.getLineSpans(self, lineWidthForHighlights, line_idx);
    }

    fn setTextInternalForStyledText(ctx_ptr: *anyopaque, mem_id: u8, text: []const u8) TextBufferError!void {
        const self = @as(*Self, @ptrCast(@alignCast(ctx_ptr)));
        return self.setTextInternal(mem_id, text);
    }

    fn measureTextForStyledText(ctx_ptr: *anyopaque, text: []const u8) u32 {
        const self = @as(*Self, @ptrCast(@alignCast(ctx_ptr)));
        return self.measureText(text);
    }

    fn addHighlightByCharRangeForStyledText(
        ctx_ptr: *anyopaque,
        start: u32,
        end: u32,
        style_id: u32,
        priority: u8,
        hl_ref: u16,
    ) TextBufferError!void {
        const self = @as(*Self, @ptrCast(@alignCast(ctx_ptr)));
        return self.addHighlightByCharRange(start, end, style_id, priority, hl_ref);
    }

    fn startHighlightsTransactionForStyledText(ctx_ptr: *anyopaque) void {
        const self = @as(*Self, @ptrCast(@alignCast(ctx_ptr)));
        self.startHighlightsTransaction();
    }

    fn endHighlightsTransactionForStyledText(ctx_ptr: *anyopaque) void {
        const self = @as(*Self, @ptrCast(@alignCast(ctx_ptr)));
        self.endHighlightsTransaction();
    }

    pub fn setStyledText(self: *Self, chunks: []const StyledChunk) TextBufferError!void {
        const chunk_count: u32 = @intCast(chunks.len);
        const line_count = self.getLineCount();
        assert(chunk_count <= Limits.max_segments);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        if (chunks.len == 0) {
            self.clear();
            self.clearAllHighlights();
            return;
        }

        const total_len = shared.totalStyledTextLength(chunks);
        if (total_len == 0) {
            self.clear();
            self.clearAllHighlights();
            return;
        }

        self.clear();
        self.clearAllHighlights();

        switch (self.backend) {
            .unified => |*backend| {
                _ = backend.arena.reset(.retain_capacity);
                backend.rope = UnifiedRope.init(backend.arena_allocator) catch return TextBufferError.OutOfMemory;
            },
            .static => |*backend| {
                _ = backend.arena.reset(.retain_capacity);
            },
        }

        const params = shared.StyledTextParams{
            .global_allocator = self.global_allocator,
            .mem_registry = &self.mem_registry,
            .styled_text_mem_id = &self.styled_text_mem_id,
            .styled_buffer = &self.styled_buffer,
            .styled_capacity = &self.styled_capacity,
            .syntax_style = self.syntax_style,
            .setTextInternal = setTextInternalForStyledText,
            .setTextCtx = self,
            .measureText = measureTextForStyledText,
            .measureCtx = self,
            .addHighlightByCharRange = addHighlightByCharRangeForStyledText,
            .highlightCtx = self,
            .startHighlightsTransaction = startHighlightsTransactionForStyledText,
            .endHighlightsTransaction = endHighlightsTransactionForStyledText,
        };

        try shared.applyStyledText(params, chunks, total_len);
    }

    pub fn measureText(self: *const Self, text: []const u8) u32 {
        const text_len: u32 = @intCast(text.len);
        assert(text_len <= Limits.max_bytes);
        assert(@as(u32, self.tab_width) <= Limits.max_tab_width);
        return shared.measureText(self.width_method, self.tab_width, text);
    }

    pub fn rope(self: *Self) *UnifiedRope {
        return switch (self.backend) {
            .unified => |*backend| &backend.rope,
            .static => @panic("Static backend has no rope"),
        };
    }
};
