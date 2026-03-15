const std = @import("std");
const Allocator = std.mem.Allocator;
const rope_mod = @import("rope.zig");
const buffer = @import("buffer.zig");
const mem_registry_mod = @import("mem-registry.zig");

const gp = @import("grapheme.zig");

const utf8 = @import("utf8.zig");

pub const RGBA = buffer.RGBA;
pub const TextSelection = buffer.TextSelection;

pub const TextBufferError = error{
    OutOfMemory,
    InvalidDimensions,
    InvalidIndex,
    InvalidId,
    InvalidMemId,
};

const MemRegistry = mem_registry_mod.MemRegistry;

pub const WrapMode = enum {
    none,
    char,
    word,
};

pub const ChunkFitResult = struct {
    char_count: u32,
    width: u32,
};

pub const GraphemeInfo = utf8.GraphemeInfo;
pub const GraphemeSpan = utf8.GraphemeSpan;

pub const LayoutCacheMode = enum {
    full_cache,
    windowed,
};

pub const LAYOUT_FULL_CACHE_MAX_CHUNK_BYTES: u32 = 8 * 1024;
pub const LAYOUT_FULL_CACHE_MAX_SPANS: u32 = 2048;
pub const LAYOUT_ASCII_FULL_CACHE_MAX_CHUNK_BYTES: u32 = 256;
pub const LAYOUT_WINDOW_BYTES: u32 = 2 * 1024;
pub const LAYOUT_WINDOW_MAX_SPANS: usize = 512;
pub const LAYOUT_WINDOW_SLOTS: usize = 2;

pub const SpanConsumer = *const fn (ctx: *anyopaque, span: GraphemeSpan) anyerror!void;

pub const LayoutSpanRange = struct {
    byte_start: u32,
    byte_end: u32,
    col_start: u32,
    col_end: u32,

    pub fn init(byte_start: u32, byte_len: u32, col_start: u32, width_cols: u32) LayoutSpanRange {
        return .{
            .byte_start = byte_start,
            .byte_end = byte_start + byte_len,
            .col_start = col_start,
            .col_end = col_start + width_cols,
        };
    }

    pub fn isEmpty(self: LayoutSpanRange) bool {
        return self.byte_start >= self.byte_end or self.col_start >= self.col_end;
    }
};

pub const LayoutSpanScratch = struct {
    pub const RangeCursor = struct {
        active: bool = false,
        mem_id: u8 = 0,
        chunk_byte_start: u32 = 0,
        chunk_byte_end: u32 = 0,
        tabwidth: u8 = 0,
        width_method: utf8.WidthMethod = .unicode,
        cursor: utf8.LayoutScanCursor = utf8.LayoutScanCursor.init(),
    };

    pub const Slot = struct {
        index: usize,
        spans: []GraphemeSpan,
    };

    slots: [LAYOUT_WINDOW_SLOTS][LAYOUT_WINDOW_MAX_SPANS]GraphemeSpan = undefined,
    next_slot: usize = 0,
    range_cursor: RangeCursor = .{},

    pub fn init() LayoutSpanScratch {
        return .{};
    }

    pub fn reset(self: *LayoutSpanScratch) void {
        self.next_slot = 0;
        self.range_cursor = .{};
    }

    pub fn acquire(self: *LayoutSpanScratch) Slot {
        const slot_index = self.next_slot;
        self.next_slot = (self.next_slot + 1) % LAYOUT_WINDOW_SLOTS;
        return .{
            .index = slot_index,
            .spans = self.slots[slot_index][0..],
        };
    }
};

/// A chunk represents a contiguous sequence of UTF-8 bytes from a specific memory buffer
pub const TextChunk = struct {
    mem_id: u8,
    byte_start: u32,
    byte_end: u32,
    width: u16,
    flags: u8 = 0,
    layout_spans: ?[]const GraphemeSpan = null,
    layout_cache_tab_width: u8 = 0,
    layout_cache_width_method: utf8.WidthMethod = .unicode,
    layout_cache_valid: bool = false,
    layout_cache_mode: LayoutCacheMode = .windowed,

    pub const Flags = struct {
        pub const ASCII_ONLY: u8 = 0b00000001; // Printable ASCII only (32..126).
    };

    pub fn isAsciiOnly(self: *const TextChunk) bool {
        return (self.flags & Flags.ASCII_ONLY) != 0;
    }

    pub fn empty() TextChunk {
        return .{
            .mem_id = 0,
            .byte_start = 0,
            .byte_end = 0,
            .width = 0,
        };
    }

    pub fn is_empty(self: *const TextChunk) bool {
        return self.width == 0;
    }

    pub fn getBytes(self: *const TextChunk, mem_registry: *const MemRegistry) []const u8 {
        const mem_buf = mem_registry.get(self.mem_id) orelse return &[_]u8{};
        return mem_buf[self.byte_start..self.byte_end];
    }

    fn layoutCacheMatches(self: *const TextChunk, tabwidth: u8, width_method: utf8.WidthMethod) bool {
        return self.layout_cache_valid and
            self.layout_cache_tab_width == tabwidth and
            self.layout_cache_width_method == width_method;
    }

    fn chooseLayoutCacheMode(self: *const TextChunk) LayoutCacheMode {
        const byte_len = self.byte_end - self.byte_start;
        if (self.isAsciiOnly() and byte_len > LAYOUT_ASCII_FULL_CACHE_MAX_CHUNK_BYTES) {
            return .windowed;
        }
        if (byte_len > LAYOUT_FULL_CACHE_MAX_CHUNK_BYTES or byte_len > LAYOUT_FULL_CACHE_MAX_SPANS) {
            return .windowed;
        }
        return .full_cache;
    }

    fn resetLayoutCache(self: *TextChunk) void {
        self.layout_spans = null;
        self.layout_cache_valid = false;
        self.layout_cache_mode = .windowed;
    }

    fn ensureLayoutCacheState(self: *const TextChunk, tabwidth: u8, width_method: utf8.WidthMethod) LayoutCacheMode {
        const mut_self = @constCast(self);
        if (!self.layoutCacheMatches(tabwidth, width_method)) {
            mut_self.resetLayoutCache();
            mut_self.layout_cache_tab_width = tabwidth;
            mut_self.layout_cache_width_method = width_method;
            mut_self.layout_cache_valid = true;
            mut_self.layout_cache_mode = self.chooseLayoutCacheMode();
        }
        return mut_self.layout_cache_mode;
    }

    fn buildOwnedLayoutSpans(
        self: *const TextChunk,
        mem_registry: *const MemRegistry,
        allocator: Allocator,
        tabwidth: u8,
        width_method: utf8.WidthMethod,
    ) TextBufferError![]const GraphemeSpan {
        const chunk_bytes = self.getBytes(mem_registry);
        var scan_result = utf8.LayoutScanResult.init(allocator);
        defer scan_result.deinit();

        utf8.scanLayout(chunk_bytes, tabwidth, self.isAsciiOnly(), width_method, &scan_result) catch |err| switch (err) {
            error.InvalidCursorOffset => unreachable,
            error.OutOfMemory => return TextBufferError.OutOfMemory,
        };

        return scan_result.spans.toOwnedSlice(allocator) catch return TextBufferError.OutOfMemory;
    }

    fn ensureFullLayoutSpans(
        self: *const TextChunk,
        mem_registry: *const MemRegistry,
        allocator: Allocator,
        tabwidth: u8,
        width_method: utf8.WidthMethod,
    ) TextBufferError![]const GraphemeSpan {
        _ = self.ensureLayoutCacheState(tabwidth, width_method);

        const mut_self = @constCast(self);
        if (self.layout_spans) |cached| {
            mut_self.layout_cache_mode = .full_cache;
            return cached;
        }

        const layout_spans = try self.buildOwnedLayoutSpans(mem_registry, allocator, tabwidth, width_method);
        mut_self.layout_spans = layout_spans;
        mut_self.layout_cache_tab_width = tabwidth;
        mut_self.layout_cache_width_method = width_method;
        mut_self.layout_cache_valid = true;
        mut_self.layout_cache_mode = .full_cache;
        return layout_spans;
    }

    fn forEachLayoutSpansInternal(
        self: *const TextChunk,
        mem_registry: *const MemRegistry,
        allocator: Allocator,
        tabwidth: u8,
        width_method: utf8.WidthMethod,
        force_mode: ?LayoutCacheMode,
        include_breaks: bool,
        scratch: *LayoutSpanScratch,
        ctx: *anyopaque,
        consumer: SpanConsumer,
    ) anyerror!void {
        const default_mode = self.ensureLayoutCacheState(tabwidth, width_method);
        const effective_mode = force_mode orelse default_mode;

        if (effective_mode == .full_cache) {
            const spans = try self.ensureFullLayoutSpans(mem_registry, allocator, tabwidth, width_method);
            for (spans) |cached_span| {
                if (include_breaks) {
                    try consumer(ctx, cached_span);
                } else {
                    var span = cached_span;
                    span.break_after = .none;
                    try consumer(ctx, span);
                }
            }
            return;
        }

        scratch.reset();

        const chunk_bytes = self.getBytes(mem_registry);
        var cursor = utf8.LayoutScanCursor.init();

        while (true) {
            const slot = scratch.acquire();
            const batch = if (include_breaks)
                try utf8.scanLayoutNextWindowBatch(chunk_bytes, tabwidth, self.isAsciiOnly(), width_method, &cursor, slot.spans, LAYOUT_WINDOW_BYTES)
            else
                try utf8.scanLayoutNextWindowBatchNoBreaks(chunk_bytes, tabwidth, self.isAsciiOnly(), width_method, &cursor, slot.spans, LAYOUT_WINDOW_BYTES);

            for (batch.spans) |span| {
                try consumer(ctx, span);
            }

            if (batch.done) break;
        }
    }

    fn lowerBoundSpanByByte(spans: []const GraphemeSpan, byte_start: u32) usize {
        var lo: usize = 0;
        var hi: usize = spans.len;

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const span = spans[mid];
            const span_end = span.byte_start + span.byte_len;
            if (span_end <= byte_start) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        return lo;
    }

    fn clipSpanToRangeNoBreaks(span_in: GraphemeSpan, range: LayoutSpanRange) ?GraphemeSpan {
        const span_byte_start = span_in.byte_start;
        const span_byte_end = span_in.byte_start + span_in.byte_len;
        if (span_byte_end <= range.byte_start or span_byte_start >= range.byte_end) {
            return null;
        }

        var span = span_in;
        span.break_after = .none;

        const span_col_end = span.col_start + span.col_width;
        if (span_byte_start >= range.byte_start and
            span_byte_end <= range.byte_end and
            span.col_start >= range.col_start and
            span_col_end <= range.col_end)
        {
            return span;
        }

        // Partial clipping is only safe for 1:1 spans.
        if (span.byte_len != span.col_width) {
            return null;
        }

        const clipped_byte_start = @max(span_byte_start, range.byte_start);
        const clipped_byte_end = @min(span_byte_end, range.byte_end);
        if (clipped_byte_start >= clipped_byte_end) {
            return null;
        }

        const drop_cols = clipped_byte_start - span_byte_start;
        const clipped_byte_len = clipped_byte_end - clipped_byte_start;

        span.byte_start = clipped_byte_start;
        span.byte_len = clipped_byte_len;
        span.col_start += drop_cols;
        span.col_width = @intCast(clipped_byte_len);

        if (span.col_start < range.col_start or span.col_start + span.col_width > range.col_end) {
            return null;
        }

        return span;
    }

    fn forEachLayoutSpansRangeNoBreaksFullCache(
        self: *const TextChunk,
        mem_registry: *const MemRegistry,
        allocator: Allocator,
        tabwidth: u8,
        width_method: utf8.WidthMethod,
        range: LayoutSpanRange,
        ctx: *anyopaque,
        consumer: SpanConsumer,
    ) anyerror!void {
        const spans = try self.ensureFullLayoutSpans(mem_registry, allocator, tabwidth, width_method);
        var idx = lowerBoundSpanByByte(spans, range.byte_start);

        while (idx < spans.len) : (idx += 1) {
            const cached_span = spans[idx];
            if (cached_span.byte_start >= range.byte_end) {
                break;
            }

            if (clipSpanToRangeNoBreaks(cached_span, range)) |span| {
                try consumer(ctx, span);
            }
        }
    }

    fn forEachLayoutSpansRangeNoBreaksWindowed(
        self: *const TextChunk,
        mem_registry: *const MemRegistry,
        allocator: Allocator,
        tabwidth: u8,
        width_method: utf8.WidthMethod,
        range: LayoutSpanRange,
        scratch: *LayoutSpanScratch,
        ctx: *anyopaque,
        consumer: SpanConsumer,
    ) anyerror!void {
        const chunk_bytes = self.getBytes(mem_registry);
        const state = &scratch.range_cursor;

        const key_matches = state.active and
            state.mem_id == self.mem_id and
            state.chunk_byte_start == self.byte_start and
            state.chunk_byte_end == self.byte_end and
            state.tabwidth == tabwidth and
            state.width_method == width_method;

        if (!key_matches) {
            state.* = .{
                .active = true,
                .mem_id = self.mem_id,
                .chunk_byte_start = self.byte_start,
                .chunk_byte_end = self.byte_end,
                .tabwidth = tabwidth,
                .width_method = width_method,
                .cursor = utf8.LayoutScanCursor.init(),
            };
        } else if (state.cursor.byte_offset > range.byte_start or state.cursor.col_offset > range.col_start) {
            state.cursor.reset();
        }

        while (state.cursor.byte_offset < range.byte_start) {
            const before = state.cursor.byte_offset;
            const remaining = range.byte_start - state.cursor.byte_offset;
            const window_bytes = @max(@as(u32, 1), @min(remaining, @as(u32, LAYOUT_WINDOW_BYTES)));

            const slot = scratch.acquire();
            const batch = try utf8.scanLayoutNextWindowBatchNoBreaks(
                chunk_bytes,
                tabwidth,
                self.isAsciiOnly(),
                width_method,
                &state.cursor,
                slot.spans,
                window_bytes,
            );

            if (state.cursor.byte_offset == before) {
                break;
            }

            if (batch.done and state.cursor.byte_offset < range.byte_start) {
                return;
            }
        }

        if (state.cursor.byte_offset != range.byte_start or state.cursor.col_offset != range.col_start) {
            try self.forEachLayoutSpansRangeNoBreaksFullCache(
                mem_registry,
                allocator,
                tabwidth,
                width_method,
                range,
                ctx,
                consumer,
            );
            return;
        }

        while (state.cursor.byte_offset < range.byte_end) {
            const before = state.cursor.byte_offset;
            const remaining = range.byte_end - state.cursor.byte_offset;
            if (remaining == 0) break;

            const window_bytes = @max(@as(u32, 1), @min(remaining, @as(u32, LAYOUT_WINDOW_BYTES)));

            const slot = scratch.acquire();
            const batch = try utf8.scanLayoutNextWindowBatchNoBreaks(
                chunk_bytes,
                tabwidth,
                self.isAsciiOnly(),
                width_method,
                &state.cursor,
                slot.spans,
                window_bytes,
            );

            for (batch.spans) |batch_span| {
                if (clipSpanToRangeNoBreaks(batch_span, range)) |span| {
                    try consumer(ctx, span);
                }
            }

            if (state.cursor.byte_offset == before or batch.done) {
                break;
            }
        }
    }

    pub fn getGraphemes(
        self: *const TextChunk,
        mem_registry: *const MemRegistry,
        allocator: Allocator,
        tabwidth: u8,
        width_method: utf8.WidthMethod,
    ) TextBufferError![]const GraphemeInfo {
        if (self.isAsciiOnly()) {
            return &[_]GraphemeInfo{};
        }

        const chunk_bytes = self.getBytes(mem_registry);
        const ProjectionContext = struct {
            allocator: Allocator,
            chunk_bytes: []const u8,
            graphemes: std.ArrayListUnmanaged(GraphemeInfo) = .{},

            fn deinit(projection_ctx: *@This()) void {
                projection_ctx.graphemes.deinit(projection_ctx.allocator);
            }

            fn consume(ctx_ptr: *anyopaque, span: GraphemeSpan) anyerror!void {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_ptr)));
                const byte_start: usize = @intCast(span.byte_start);
                const is_tab = span.byte_len == 1 and byte_start < ctx.chunk_bytes.len and ctx.chunk_bytes[byte_start] == '\t';
                if (!is_tab and span.byte_len == 1) return;

                try ctx.graphemes.append(ctx.allocator, .{
                    .byte_offset = span.byte_start,
                    .byte_len = @intCast(span.byte_len),
                    .width = @intCast(span.col_width),
                    .col_offset = span.col_start,
                });
            }
        };

        var scratch = LayoutSpanScratch.init();
        var ctx = ProjectionContext{
            .allocator = allocator,
            .chunk_bytes = chunk_bytes,
        };
        errdefer ctx.deinit();

        self.forEachLayoutSpans(mem_registry, allocator, tabwidth, width_method, &scratch, &ctx, ProjectionContext.consume) catch |err| switch (err) {
            error.OutOfMemory => return TextBufferError.OutOfMemory,
            else => unreachable,
        };

        return ctx.graphemes.toOwnedSlice(allocator) catch TextBufferError.OutOfMemory;
    }

    pub fn getWrapOffsets(
        self: *const TextChunk,
        mem_registry: *const MemRegistry,
        allocator: Allocator,
        tabwidth: u8,
        width_method: utf8.WidthMethod,
    ) TextBufferError![]const utf8.WrapBreak {
        const ProjectionContext = struct {
            allocator: Allocator,
            breaks: std.ArrayListUnmanaged(utf8.WrapBreak) = .{},
            is_ascii_only: bool,
            grapheme_index: u32 = 0,

            fn deinit(projection_ctx: *@This()) void {
                projection_ctx.breaks.deinit(projection_ctx.allocator);
            }

            fn consume(ctx_ptr: *anyopaque, span: GraphemeSpan) anyerror!void {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_ptr)));
                if (span.break_after != .none) {
                    try ctx.breaks.append(ctx.allocator, .{
                        .byte_offset = span.byte_start,
                        .char_offset = ctx.grapheme_index,
                    });
                }
                ctx.grapheme_index += utf8.graphemeCountForLayoutSpan(span, ctx.is_ascii_only);
            }
        };

        var scratch = LayoutSpanScratch.init();
        var ctx = ProjectionContext{
            .allocator = allocator,
            .is_ascii_only = self.isAsciiOnly(),
        };
        errdefer ctx.deinit();

        self.forEachLayoutSpans(mem_registry, allocator, tabwidth, width_method, &scratch, &ctx, ProjectionContext.consume) catch |err| switch (err) {
            error.OutOfMemory => return TextBufferError.OutOfMemory,
            else => unreachable,
        };

        return ctx.breaks.toOwnedSlice(allocator) catch TextBufferError.OutOfMemory;
    }

    pub fn getLayoutSpans(
        self: *const TextChunk,
        mem_registry: *const MemRegistry,
        allocator: Allocator,
        tabwidth: u8,
        width_method: utf8.WidthMethod,
    ) TextBufferError![]const GraphemeSpan {
        return self.ensureFullLayoutSpans(mem_registry, allocator, tabwidth, width_method);
    }

    pub fn forEachLayoutSpans(
        self: *const TextChunk,
        mem_registry: *const MemRegistry,
        allocator: Allocator,
        tabwidth: u8,
        width_method: utf8.WidthMethod,
        scratch: *LayoutSpanScratch,
        ctx: *anyopaque,
        consumer: SpanConsumer,
    ) anyerror!void {
        return self.forEachLayoutSpansInternal(mem_registry, allocator, tabwidth, width_method, null, true, scratch, ctx, consumer);
    }

    pub fn forEachLayoutSpansNoBreaks(
        self: *const TextChunk,
        mem_registry: *const MemRegistry,
        allocator: Allocator,
        tabwidth: u8,
        width_method: utf8.WidthMethod,
        scratch: *LayoutSpanScratch,
        ctx: *anyopaque,
        consumer: SpanConsumer,
    ) anyerror!void {
        return self.forEachLayoutSpansInternal(mem_registry, allocator, tabwidth, width_method, null, false, scratch, ctx, consumer);
    }

    pub fn forEachLayoutSpansRangeNoBreaks(
        self: *const TextChunk,
        mem_registry: *const MemRegistry,
        allocator: Allocator,
        tabwidth: u8,
        width_method: utf8.WidthMethod,
        range: LayoutSpanRange,
        scratch: *LayoutSpanScratch,
        ctx: *anyopaque,
        consumer: SpanConsumer,
    ) anyerror!void {
        const chunk_byte_len = self.byte_end - self.byte_start;
        const chunk_col_len: u32 = self.width;

        const clamped_range = LayoutSpanRange{
            .byte_start = @min(range.byte_start, chunk_byte_len),
            .byte_end = @min(range.byte_end, chunk_byte_len),
            .col_start = @min(range.col_start, chunk_col_len),
            .col_end = @min(range.col_end, chunk_col_len),
        };

        if (clamped_range.isEmpty()) {
            return;
        }

        const default_mode = self.ensureLayoutCacheState(tabwidth, width_method);
        if (default_mode == .full_cache) {
            return self.forEachLayoutSpansRangeNoBreaksFullCache(
                mem_registry,
                allocator,
                tabwidth,
                width_method,
                clamped_range,
                ctx,
                consumer,
            );
        }

        return self.forEachLayoutSpansRangeNoBreaksWindowed(
            mem_registry,
            allocator,
            tabwidth,
            width_method,
            clamped_range,
            scratch,
            ctx,
            consumer,
        );
    }

};

/// A highlight represents a styled region on a line
pub const Highlight = struct {
    col_start: u32,
    col_end: u32,
    style_id: u32,
    priority: u8,
    hl_ref: u16 = 0,
};

/// Pre-computed style span for efficient rendering
/// Represents a contiguous region with a single style
pub const StyleSpan = struct {
    col: u32,
    style_id: u32,
    next_col: u32,
};

/// A segment in the unified rope - either text content or a line break marker
pub const Segment = union(enum) {
    text: TextChunk,
    brk: void,
    linestart: void,

    /// Define which union tags are markers (for O(1) line lookup)
    pub const MarkerTypes = &[_]std.meta.Tag(Segment){ .brk, .linestart };

    /// Metrics for aggregation in the rope tree
    /// These enable O(log n) row/col coordinate mapping and efficient line queries
    pub const Metrics = struct {
        total_width: u32 = 0,
        total_bytes: u32 = 0,
        linestart_count: u32 = 0,
        newline_count: u32 = 0,
        max_line_width: u32 = 0,
        /// Whether all text segments in subtree are ASCII-only (for fast wrapping paths)
        ascii_only: bool = true,

        pub fn add(self: *Metrics, other: Metrics) void {
            self.total_width += other.total_width;
            self.total_bytes += other.total_bytes;
            self.linestart_count += other.linestart_count;
            self.newline_count += other.newline_count;

            self.max_line_width = @max(self.max_line_width, other.max_line_width);

            self.ascii_only = self.ascii_only and other.ascii_only;
        }

        /// Get the balancing weight for the rope
        /// We use total_width + newline_count to give each break a weight of 1
        /// This eliminates boundary ambiguity in coordinate/offset conversions
        pub fn weight(self: *const Metrics) u32 {
            return self.total_width + self.newline_count;
        }
    };

    /// Measure this segment to produce its metrics
    pub fn measure(self: *const Segment) Metrics {
        return switch (self.*) {
            .text => |chunk| blk: {
                const is_ascii = (chunk.flags & TextChunk.Flags.ASCII_ONLY) != 0;
                const byte_len = chunk.byte_end - chunk.byte_start;
                break :blk Metrics{
                    .total_width = chunk.width,
                    .total_bytes = byte_len,
                    .linestart_count = 0,
                    .newline_count = 0,
                    .max_line_width = chunk.width,
                    .ascii_only = is_ascii,
                };
            },
            .brk => Metrics{
                .total_width = 0,
                .total_bytes = 0,
                .linestart_count = 0,
                .newline_count = 1,
                .max_line_width = 0,
                .ascii_only = true,
            },
            .linestart => Metrics{
                .total_width = 0,
                .total_bytes = 0,
                .linestart_count = 1,
                .newline_count = 0,
                .max_line_width = 0,
                .ascii_only = true,
            },
        };
    }

    pub fn empty() Segment {
        return .{ .text = TextChunk.empty() };
    }

    pub fn is_empty(self: *const Segment) bool {
        return switch (self.*) {
            .text => |chunk| chunk.is_empty(),
            .brk => false,
            .linestart => false,
        };
    }

    pub fn getBytes(self: *const Segment, mem_registry: *const MemRegistry) []const u8 {
        return switch (self.*) {
            .text => |chunk| chunk.getBytes(mem_registry),
            .brk => &[_]u8{},
            .linestart => &[_]u8{},
        };
    }

    pub fn isBreak(self: *const Segment) bool {
        return switch (self.*) {
            .brk => true,
            else => false,
        };
    }

    pub fn isLineStart(self: *const Segment) bool {
        return switch (self.*) {
            .linestart => true,
            else => false,
        };
    }

    pub fn isText(self: *const Segment) bool {
        return switch (self.*) {
            .text => true,
            else => false,
        };
    }

    pub fn asText(self: *const Segment) ?*const TextChunk {
        return switch (self.*) {
            .text => |*chunk| chunk,
            else => null,
        };
    }

    /// Two text chunks can be merged if they reference contiguous memory in the same buffer
    pub fn canMerge(left: *const Segment, right: *const Segment) bool {
        if (!left.isText() or !right.isText()) return false;

        const left_chunk = left.asText() orelse return false;
        const right_chunk = right.asText() orelse return false;

        if (left_chunk.mem_id != right_chunk.mem_id) return false;
        if (left_chunk.byte_end != right_chunk.byte_start) return false;
        if (left_chunk.flags != right_chunk.flags) return false;

        return true;
    }

    pub fn merge(allocator: Allocator, left: *const Segment, right: *const Segment) Segment {
        _ = allocator;

        const left_chunk = left.asText().?;
        const right_chunk = right.asText().?;

        // TODO: could clear the caches on the original chunks,
        // as the original chunks are only kept for history purposes.

        return Segment{
            .text = TextChunk{
                .mem_id = left_chunk.mem_id,
                .byte_start = left_chunk.byte_start,
                .byte_end = right_chunk.byte_end,
                .width = left_chunk.width + right_chunk.width,
                .flags = left_chunk.flags,
                .layout_spans = null,
                .layout_cache_tab_width = 0,
                .layout_cache_width_method = .unicode,
                .layout_cache_valid = false,
                .layout_cache_mode = .windowed,
            },
        };
    }

    /// Boundary normalization action
    pub const BoundaryAction = struct {
        delete_left: bool = false,
        delete_right: bool = false,
        insert_between: []const Segment = &[_]Segment{},
    };

    /// Rewrite boundary between two adjacent segments to enforce invariants
    ///
    /// Document invariants enforced at join boundaries:
    /// - Every line starts with a linestart marker
    /// - Line breaks must be followed by linestart markers
    /// - No duplicate linestart markers (deduplicated automatically)
    /// - When joining lines, orphaned linestart markers are removed
    /// - Empty lines are represented as [linestart, brk] with no text, or [linestart] if final
    /// - Consecutive breaks [brk, brk] get a linestart inserted between (empty line)
    ///
    /// Rules applied locally at O(log n) join points:
    /// - [linestart, linestart] → delete right (dedup)
    /// - [brk, text] → insert linestart between (ensure line starts with marker)
    /// - [brk, brk] → insert linestart between (represents empty line)
    /// - [text, linestart] → delete right (remove orphaned linestart when joining lines)
    ///
    /// Valid patterns (no action needed):
    /// - [text, brk] (line content followed by break)
    /// - [linestart, text] (line marker followed by content)
    /// - [linestart, brk] (empty line before another line)
    /// - [linestart] alone (empty final line or empty buffer)
    /// - [brk, linestart, brk] (empty line between two lines, normalized from [brk, brk])
    ///
    /// These rules preserve linestart markers when deleting at col=0 within a line,
    /// since the deletion splits around the marker, and [text, linestart] only triggers
    /// when actually joining lines (deleting the break between them).
    pub fn rewriteBoundary(allocator: Allocator, left: ?*const Segment, right: ?*const Segment) !BoundaryAction {
        _ = allocator;

        if (left == null or right == null) return .{};

        const left_seg = left.?;
        const right_seg = right.?;

        // [linestart, linestart] -> delete right (dedup)
        if (left_seg.isLineStart() and right_seg.isLineStart()) {
            return .{ .delete_right = true };
        }

        // [brk, brk] -> insert linestart between (represents empty line)
        if (left_seg.isBreak() and right_seg.isBreak()) {
            const linestart_segment = Segment{ .linestart = {} };
            const insert_slice = &[_]Segment{linestart_segment};
            return .{ .insert_between = insert_slice };
        }

        // [brk, text] -> insert linestart between
        if (left_seg.isBreak() and right_seg.isText()) {
            const linestart_segment = Segment{ .linestart = {} };
            const insert_slice = &[_]Segment{linestart_segment};
            return .{ .insert_between = insert_slice };
        }

        // [text, linestart] -> delete right (remove orphaned linestart when joining lines)
        if (left_seg.isText() and right_seg.isLineStart()) {
            return .{ .delete_right = true };
        }

        return .{};
    }

    /// Rewrite rope ends to enforce invariants
    /// Rules:
    /// - Rope must start with linestart (even when empty - ensures at least one line)
    pub fn rewriteEnds(allocator: Allocator, first: ?*const Segment, last: ?*const Segment) !BoundaryAction {
        _ = allocator;
        _ = last;

        // Ensure rope starts with linestart (insert even if empty)
        if (first) |first_seg| {
            if (!first_seg.isLineStart()) {
                const linestart_segment = Segment{ .linestart = {} };
                const insert_slice = &[_]Segment{linestart_segment};
                return .{ .insert_between = insert_slice };
            }
        } else {
            // Empty rope - insert linestart to ensure at least one line
            const linestart_segment = Segment{ .linestart = {} };
            const insert_slice = &[_]Segment{linestart_segment};
            return .{ .insert_between = insert_slice };
        }

        return .{};
    }
};

pub const UnifiedRope = rope_mod.Rope(Segment);
