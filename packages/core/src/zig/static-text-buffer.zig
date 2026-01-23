const std = @import("std");
const Allocator = std.mem.Allocator;
const seg_mod = @import("text-buffer-segment.zig");
const iter_mod = @import("text-buffer-iterators.zig");
const gp = @import("grapheme.zig");
const utf8 = @import("utf8.zig");
const tb = @import("text-buffer.zig");
const highlight_mod = @import("text-buffer-highlights.zig");
const shared = @import("text-buffer-shared.zig");
const handle = @import("text-buffer-handle.zig");
const assert = std.debug.assert;

const Segment = seg_mod.Segment;
const TextChunk = seg_mod.TextChunk;
const LineInfo = iter_mod.LineInfo;

/// StaticTextBuffer is the flat implementation backed by StaticTextBufferDraft.
/// Historically this was an alias for UnifiedTextBuffer.
pub const StaticTextBuffer = StaticTextBufferDraft;

/// StaticTextBufferDraft is the flat static buffer implementation.
pub const StaticTextBufferDraft = struct {
    const Self = @This();

    pub const Defaults = tb.UnifiedTextBuffer.Defaults;

    // Hard limits for fail-fast bounds checks. These should be tuned to match
    // expected workloads; all loops must assert against these caps.
    pub const Limits = struct {
        // Max lines in the buffer. Line metadata uses 4 * u32 per line
        // (16 bytes/line), so 4,000,000 lines is ~64 MB for line_* alone.
        pub const max_lines: u32 = 4_000_000;
        // Max segments (.linestart/.brk/.text). Segment storage alone costs
        // max_segments * @sizeOf(Segment) bytes (TextChunk is the dominant case).
        // On 64-bit, @sizeOf(Segment) is typically tens of bytes, so this is
        // hundreds of MB at the current cap.
        pub const max_segments: u32 = 16_000_000;
        // Max total text bytes in input/output buffers and aggregates.
        // 512 * 1024 * 1024 bytes = 512 MiB.
        pub const max_bytes: u32 = 512 * 1024 * 1024;
        // Max registered views. view_dirty_flags is one bool per view
        // (1 byte/view => ~1 MB at max_views).
        pub const max_views: u32 = 1_000_000;
        // Max highlight entries stored for a single line. Storage per line is
        // max_highlights_per_line * @sizeOf(Highlight) bytes (typically 16 bytes each).
        pub const max_highlights_per_line: u32 = 65_535;
        // Max mem_registry buffers (u8 ids, 255 usable entries). Each buffer
        // is a slice in MemRegistry with its own backing storage; this limit
        // caps count, not total bytes.
        pub const max_mem_buffers: u32 = 255;
        // Max tab width (columns) to bound width recomputation costs.
        pub const max_tab_width: u32 = 64;
    };

    comptime {
        // Verify integer type sizes for serialization and storage assumptions.
        assert(@sizeOf(u8) == 1);
        assert(@sizeOf(u16) == 2);
        assert(@sizeOf(u32) == 4);
        // Limits sanity: must allow at least one line and non-empty segments.
        assert(Limits.max_lines > 0);
        // Segment capacity must be >= line capacity (each line has a linestart).
        assert(Limits.max_segments >= Limits.max_lines);
        // Mem registry ids are u8, so the cap must fit in u8 space.
        assert(Limits.max_mem_buffers <= std.math.maxInt(u8));
        // Tab width must be at least 2 for layout parity with UnifiedTextBuffer.
        assert(Limits.max_tab_width >= 2);
    }

    // ---------------------------------------------------------------------
    // Data layout + invariants (design notes)
    // ---------------------------------------------------------------------
    // - Flat contiguous segment storage for cache locality and zero tree nodes.
    // - Precomputed line index arrays for O(1) lineCount/lineWidthAt and cheap
    //   walkLinesAndSegments iteration.
    // - Offsets include newline weight; line widths exclude newline.
    // - Empty buffer still reports one line (linestart invariant).
    // - We keep the same Segment/TextChunk representation so the view and
    //   renderer can stay generic and reuse existing logic.
    //
    // Invariants (must hold after any mutation: setText, setStyledText, clear,
    // reset, setTabWidth, setSyntaxStyle affecting spans):
    // - If segments.len > 0, segments[0] is .linestart.
    // - Each .brk is followed by a .linestart (if not at end).
    // - line_count == line_starts.len == line_widths.len ==
    //   line_seg_start.len == line_seg_end.len, and line_count >= 1.
    // - line_starts[0] == 0 and line_starts is strictly increasing.
    // - For i < line_count - 1:
    //   line_starts[i + 1] == line_starts[i] + line_widths[i] + 1.
    //   (newline contributes +1 to offsets but not to line_widths.)
    // - line_seg_start[i] <= line_seg_end[i] <= segments.len.
    //   For non-final lines, line_seg_end[i] is the index of the .brk segment.
    //   For the final line, line_seg_end[i] == segments.len.
    // - total_width == sum(line_widths) and total_bytes == sum(text chunk bytes).
    // - max_line_width == max(line_widths), or 0 when line_count == 0
    //   (which should not occur after normalization).
    // - total_weight == total_width + (line_count - 1).
    // - Empty text yields one empty line (width 0). segments is either empty
    //   or contains only a leading .linestart (both are acceptable as long as
    //   line_* arrays represent one empty line).
    // - TextChunk.width uses width_method + tab_width at creation time.
    //   Changing either requires recomputing chunk widths and line_widths.
    // - mem_registry contains every mem_id referenced by segments.
    // - view_dirty_flags.len == next_view_id; free_view_ids entries are unique
    //   and always < view_dirty_flags.len.
    // - content_epoch increments exactly once per content change; markAllViewsDirty
    //   sets all view_dirty_flags to true.
    // - line_spans cover [0..line_width] for their line and the final span
    //   resets to defaults (matching UnifiedTextBuffer behavior).

    // Shared infrastructure from UnifiedTextBuffer.
    header: handle.TextBufferHeader,
    mem_registry: tb.MemRegistry,
    default_fg: ?tb.RGBA,
    default_bg: ?tb.RGBA,
    default_attributes: ?u32,
    syntax_style: ?*const tb.SyntaxStyle,
    pool: *gp.GraphemePool,

    width_method: utf8.WidthMethod,
    tab_width: u8,

    // Allocators: keep a small arena for transient allocations used by view
    // wrapping and grapheme/offset caching; reset it on setText/reset.
    global_allocator: Allocator,
    arena: *std.heap.ArenaAllocator,
    arena_allocator: Allocator,

    // Core flat storage of segments. We can either:
    // - store the same Segment stream as the segmentation pipeline (linestart/brk/text),
    //   which makes line indexing and debugging straightforward, or
    // - store only text segments and rely on line index arrays to represent
    //   breaks (lower memory, but more bookkeeping).
    // The draft assumes the full Segment stream for parity with the rope path.
    segments: std.ArrayListUnmanaged(Segment),

    // Line index arrays (all u32 for compactness).
    // line_starts[i] = display-width offset of the start of line i
    // line_widths[i] = display width of line i (no newline)
    // line_seg_start[i] = index into segments where this line starts
    // line_seg_end[i] = index into segments where this line ends (brk excluded)
    // These arrays enable O(1) lineWidthAt and O(log n) offset->line via
    // binary search on line_starts.
    // Alternative: use std.MultiArrayList(LineMeta) to keep these fields in
    // lockstep and reduce length-invariant asserts, at the cost of an extra
    // abstraction and usize-based indexing.
    line_starts: std.ArrayListUnmanaged(u32),
    line_widths: std.ArrayListUnmanaged(u32),
    line_seg_start: std.ArrayListUnmanaged(u32),
    line_seg_end: std.ArrayListUnmanaged(u32),

    // Aggregate metrics for quick queries.
    max_line_width: u32,
    total_width: u32,
    total_bytes: u32,

    // View dirty tracking (same semantics as UnifiedTextBuffer).
    view_registry: shared.ViewRegistry,

    // Highlight/span pipeline mirrors UnifiedTextBuffer so TextBufferView can
    // reuse its styling logic without special cases.
    highlights: highlight_mod.HighlightRegistry,

    styled_text_mem_id: ?u8,
    styled_buffer: ?[]u8,
    styled_capacity: usize,

    // Optional speedups to consider during implementation:
    // - Store line_byte_starts/line_byte_lengths for O(1) line slicing when
    //   generating plain text or textRange outputs.
    // - Cache a contiguous plain_text buffer (with newlines) to make
    //   getPlainTextIntoBuffer a single memcpy when content_epoch matches.
    // - Track per-line chunk prefix widths to allow binary search within a line
    //   when mapping display offsets to byte offsets for textRange.
    // - Store per-line chunk ranges or counts to avoid scanning for break
    //   segments during walkLinesAndSegments.
    // - Store a parallel array of just TextChunk indices per line to skip
    //   linestart/brk markers during hot iteration.
    // - If incremental updates are needed, precompute tail-line state to avoid a full
    //   rebuild (last line width, last seg index, last byte offsets).
    // - Consider a single "text arena" for setText to keep mem_registry to
    //   one buffer, simplifying textRange fast-paths.

    fn draftStub() noreturn {
        @panic("StaticTextBufferDraft is a design-only stub");
    }

    // ---------------------------------------------------------------------
    // Init / teardown
    // ---------------------------------------------------------------------
    pub fn init(
        global_allocator: Allocator,
        pool: *gp.GraphemePool,
        width_method: utf8.WidthMethod,
    ) tb.TextBufferError!*Self {
        // Plan:
        // - allocate Self + arena allocator (for transient allocations)
        // - init mem_registry, highlight caches, view tracking arrays
        // - initialize line index arrays with a single empty line
        assert(@intFromPtr(pool) != 0);
        assert(@intFromPtr(global_allocator.ptr) != 0);
        assert(@intFromPtr(global_allocator.vtable) != 0);
        assert(@intFromEnum(width_method) <= @intFromEnum(utf8.WidthMethod.no_zwj));
        const self = global_allocator.create(Self) catch return tb.TextBufferError.OutOfMemory;
        errdefer global_allocator.destroy(self);

        const internal_arena = global_allocator.create(std.heap.ArenaAllocator) catch return tb.TextBufferError.OutOfMemory;
        errdefer global_allocator.destroy(internal_arena);
        internal_arena.* = std.heap.ArenaAllocator.init(global_allocator);

        const internal_allocator = internal_arena.allocator();

        var mem_registry = tb.MemRegistry.init(global_allocator);
        errdefer mem_registry.deinit();

        var view_registry = shared.ViewRegistry{};
        errdefer view_registry.deinit(global_allocator);

        var highlights = highlight_mod.HighlightRegistry.init(global_allocator);
        errdefer highlights.deinit();

        var line_starts: std.ArrayListUnmanaged(u32) = .{};
        errdefer line_starts.deinit(global_allocator);
        var line_widths: std.ArrayListUnmanaged(u32) = .{};
        errdefer line_widths.deinit(global_allocator);
        var line_seg_start: std.ArrayListUnmanaged(u32) = .{};
        errdefer line_seg_start.deinit(global_allocator);
        var line_seg_end: std.ArrayListUnmanaged(u32) = .{};
        errdefer line_seg_end.deinit(global_allocator);

        try line_starts.append(global_allocator, 0);
        try line_widths.append(global_allocator, 0);
        try line_seg_start.append(global_allocator, 0);
        try line_seg_end.append(global_allocator, 0);

        self.* = .{
            .header = .{ .kind = .static },
            .mem_registry = mem_registry,
            .default_fg = null,
            .default_bg = null,
            .default_attributes = null,
            .syntax_style = null,
            .pool = pool,
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
            .max_line_width = 0,
            .total_width = 0,
            .total_bytes = 0,
            .view_registry = view_registry,
            .highlights = highlights,
            .styled_text_mem_id = null,
            .styled_buffer = null,
            .styled_capacity = 0,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Plan:
        // - detach syntax_style callbacks
        // - deinit view tracking arrays, line caches, highlight caches
        // - free styled_buffer if owned
        // - deinit mem_registry + arena + self
        const line_count: u32 = @intCast(self.line_widths.items.len);
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

        self.segments.deinit(self.global_allocator);
        self.line_starts.deinit(self.global_allocator);
        self.line_widths.deinit(self.global_allocator);
        self.line_seg_start.deinit(self.global_allocator);
        self.line_seg_end.deinit(self.global_allocator);

        self.mem_registry.deinit();
        self.arena.deinit();
        self.global_allocator.destroy(self.arena);
        self.global_allocator.destroy(self);
    }

    // ---------------------------------------------------------------------
    // Accessors used by the comptime TextBufferView + renderer
    // ---------------------------------------------------------------------
    pub fn defaults(self: *const Self) Defaults {
        // Just return the stored defaults as a struct.
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        return .{
            .fg = self.default_fg,
            .bg = self.default_bg,
            .attributes = self.default_attributes,
        };
    }

    pub fn memRegistry(self: *const Self) *const tb.MemRegistry {
        // Returns pointer for TextChunk.getBytes and view ellipsis chunk.
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        return &self.mem_registry;
    }

    pub fn allocator(self: *const Self) Allocator {
        // Use arena_allocator for transient per-view allocations.
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        return self.arena_allocator;
    }

    pub fn widthMethod(self: *const Self) utf8.WidthMethod {
        const line_count: u32 = @intCast(self.line_widths.items.len);
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
        // Plan:
        // - clamp to >=2 and even (same as UnifiedTextBuffer)
        // - if changed, recompute TextChunk widths + line_widths/max_line_width
        //   OR rebuild from stored text buffer
        // - mark all views dirty and bump content_epoch
        assert(width >= 2);
        assert(@as(u32, width) <= Limits.max_tab_width);
        assert(self.tab_width >= 2);
        assert(@as(u32, self.tab_width) <= Limits.max_tab_width);
        const clamped_width: u8 = if (width < 2) 2 else width;
        const new_width: u8 = if (clamped_width % 2 == 0) clamped_width else clamped_width + 1;
        if (self.tab_width == new_width) return;
        self.tab_width = new_width;

        for (self.segments.items) |*seg| {
            if (seg.asText()) |chunk_const| {
                const chunk = @constCast(chunk_const);
                const bytes = chunk.getBytes(&self.mem_registry);
                const is_ascii = chunk.isAsciiOnly();
                chunk.width = @intCast(@min(65535, utf8.calculateTextWidth(bytes, self.tab_width, is_ascii, self.width_method)));
                chunk.graphemes = null;
            }
        }

        self.rebuildLineIndex();
        self.markAllViewsDirty();
    }

    pub fn lineCount(self: *const Self) u32 {
        // O(1): return line_widths.len (ensure it is >= 1).
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        return line_count;
    }

    pub fn getLineCount(self: *const Self) u32 {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        return line_count;
    }

    pub fn lineWidthAt(self: *Self, row: u32) u32 {
        // O(1): return line_widths[row] with bounds checks.
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(row < line_count);
        return self.line_widths.items[@intCast(row)];
    }

    pub fn maxLineWidth(self: *const Self) u32 {
        // O(1): cached max_line_width.
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
        // Planned algorithm:
        // - iterate lines using line_seg_start/line_seg_end
        // - for each line, scan segments in [start, end) and call segment_callback
        //   only for .text segments, tracking chunk_idx_in_line
        // - emit line_end_callback with LineInfo that mirrors rope semantics:
        //   char_offset == line_starts[i], width == line_widths[i],
        //   seg_start/seg_end align to the underlying Segment indices
        // - use a single forward loop with u32 indices bounded by Limits; no recursion
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
                .width = self.line_widths.items[@intCast(line_idx)],
                .seg_start = seg_start,
                .seg_end = seg_end,
            });
        }
    }

    // ---------------------------------------------------------------------
    // View tracking (same semantics as UnifiedTextBuffer)
    // ---------------------------------------------------------------------
    pub fn registerView(self: *Self) tb.TextBufferError!u32 {
        const view_count: u32 = @intCast(self.view_registry.view_dirty_flags.items.len);
        assert(view_count <= Limits.max_views);
        assert(self.view_registry.next_view_id <= Limits.max_views);
        return self.view_registry.registerView(self.global_allocator);
    }

    pub fn unregisterView(self: *Self, view_id: u32) void {
        assert(view_id < self.view_registry.next_view_id);
        const view_count: u32 = @intCast(self.view_registry.view_dirty_flags.items.len);
        assert(view_count <= Limits.max_views);
        self.view_registry.unregisterView(self.global_allocator, view_id);
    }

    pub fn isViewDirty(self: *const Self, view_id: u32) bool {
        assert(view_id < self.view_registry.next_view_id);
        const view_count: u32 = @intCast(self.view_registry.view_dirty_flags.items.len);
        assert(view_count <= Limits.max_views);
        return self.view_registry.isViewDirty(view_id);
    }

    pub fn clearViewDirty(self: *Self, view_id: u32) void {
        assert(view_id < self.view_registry.next_view_id);
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

    pub fn markViewsDirty(self: *Self) void {
        const view_count: u32 = @intCast(self.view_registry.view_dirty_flags.items.len);
        assert(view_count <= Limits.max_views);
        assert(self.view_registry.next_view_id <= Limits.max_views);
        self.markAllViewsDirty();
    }

    fn markAllViewsDirty(self: *Self) void {
        // Bumps content_epoch and sets all dirty flags.
        const view_count: u32 = @intCast(self.view_registry.view_dirty_flags.items.len);
        assert(view_count <= Limits.max_views);
        assert(self.view_registry.next_view_id <= Limits.max_views);
        self.view_registry.markAllViewsDirty();
    }

    // ---------------------------------------------------------------------
    // Core metrics + buffer lifecycle
    // ---------------------------------------------------------------------
    pub fn getLength(self: *const Self) u32 {
        // Total display width without newline weight (sum of TextChunk.width).
        assert(self.total_width <= Limits.max_bytes);
        assert(self.max_line_width <= self.total_width);
        return self.total_width;
    }

    pub fn getByteSize(self: *const Self) u32 {
        // Total bytes including newline separators (line_count - 1).
        assert(self.total_bytes <= Limits.max_bytes);
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        return self.total_bytes + (line_count - 1);
    }

    pub fn measureText(self: *const Self, text: []const u8) u32 {
        // Use utf8.calculateTextWidth with width_method + tab_width.
        const text_len: u32 = @intCast(text.len);
        assert(text_len <= Limits.max_bytes);
        assert(@as(u32, self.tab_width) <= Limits.max_tab_width);
        return shared.measureText(self.width_method, self.tab_width, text);
    }

    pub fn clear(self: *Self) void {
        // Clear segments + line index but keep mem_registry and arrays.
        // Preserves highlights if we want to reuse spans on same text.
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        self.segments.clearRetainingCapacity();
        self.line_starts.clearRetainingCapacity();
        self.line_widths.clearRetainingCapacity();
        self.line_seg_start.clearRetainingCapacity();
        self.line_seg_end.clearRetainingCapacity();

        self.line_starts.append(self.global_allocator, 0) catch {};
        self.line_widths.append(self.global_allocator, 0) catch {};
        self.line_seg_start.append(self.global_allocator, 0) catch {};
        self.line_seg_end.append(self.global_allocator, 0) catch {};

        self.max_line_width = 0;
        self.total_width = 0;
        self.total_bytes = 0;

        self.markAllViewsDirty();
    }

    pub fn reset(self: *Self) void {
        // Full reset: clear highlights/spans, mem_registry, arena, segments.
        const seg_count: u32 = @intCast(self.segments.items.len);
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(seg_count <= Limits.max_segments);
        assert(line_count <= Limits.max_lines);
        self.highlights.clearRetainingCapacity();

        if (self.styled_buffer) |buf| {
            self.global_allocator.free(buf);
        }
        self.styled_buffer = null;
        self.styled_text_mem_id = null;
        self.styled_capacity = 0;

        _ = self.arena.reset(if (self.arena.queryCapacity() > 0) .retain_capacity else .free_all);
        self.mem_registry.clear();

        self.segments.clearRetainingCapacity();
        self.line_starts.clearRetainingCapacity();
        self.line_widths.clearRetainingCapacity();
        self.line_seg_start.clearRetainingCapacity();
        self.line_seg_end.clearRetainingCapacity();

        self.line_starts.append(self.global_allocator, 0) catch {};
        self.line_widths.append(self.global_allocator, 0) catch {};
        self.line_seg_start.append(self.global_allocator, 0) catch {};
        self.line_seg_end.append(self.global_allocator, 0) catch {};

        self.max_line_width = 0;
        self.total_width = 0;
        self.total_bytes = 0;

        self.markAllViewsDirty();
    }

    // ---------------------------------------------------------------------
    // Defaults + syntax style
    // ---------------------------------------------------------------------
    pub fn setDefaultFg(self: *Self, fg: ?tb.RGBA) void {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        if (fg) |rgba| assert(!std.math.isNan(rgba[0]));
        if (fg) |rgba| assert(!std.math.isNan(rgba[3]));
        self.default_fg = fg;
    }

    pub fn setDefaultBg(self: *Self, bg: ?tb.RGBA) void {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        if (bg) |rgba| assert(!std.math.isNan(rgba[1]));
        if (bg) |rgba| assert(!std.math.isNan(rgba[3]));
        self.default_bg = bg;
    }

    pub fn setDefaultAttributes(self: *Self, attributes: ?u32) void {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        if (attributes) |value| assert(value <= std.math.maxInt(u32));
        if (attributes) |value| assert(value >= 0);
        self.default_attributes = attributes;
    }

    pub fn resetDefaults(self: *Self) void {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        self.default_fg = null;
        self.default_bg = null;
        self.default_attributes = null;
    }

    fn onSyntaxStyleDestroyed(ctx_ptr: *anyopaque) void {
        const self = @as(*Self, @ptrCast(@alignCast(ctx_ptr)));
        self.syntax_style = null;
    }

    pub fn setSyntaxStyle(self: *Self, syntax_style: ?*const tb.SyntaxStyle) void {
        // Plan: mirror UnifiedTextBuffer, register offDestroy callback.
        const line_count: u32 = @intCast(self.line_widths.items.len);
        if (syntax_style) |style| assert(@intFromPtr(style) != 0);
        assert(@intFromPtr(self) != 0);
        assert(line_count >= 1);
        if (self.syntax_style) |prev| {
            (@constCast(prev)).offDestroy(@ptrCast(self), onSyntaxStyleDestroyed);
        }
        self.syntax_style = syntax_style;
        if (syntax_style) |style| {
            _ = (@constCast(style)).onDestroy(@ptrCast(self), onSyntaxStyleDestroyed) catch {};
        }
    }

    pub fn getSyntaxStyle(self: *const Self) ?*const tb.SyntaxStyle {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        if (self.syntax_style) |style| assert(@intFromPtr(style) != 0);
        assert(@intFromPtr(self) != 0);
        assert(line_count >= 1);
        return self.syntax_style;
    }

    // ---------------------------------------------------------------------
    // Text input + segmentation
    // ---------------------------------------------------------------------
    pub fn setText(self: *Self, text: []const u8) tb.TextBufferError!void {
        // Plan:
        // - clear or reset segments/line index arrays (retain capacity)
        // - register text in mem_registry (owned=false)
        // - build segments (text/brk/linestart) and line index in one pass
        // - update total_width/total_bytes/max_line_width
        // - mark views dirty and bump content_epoch
        const text_len: u32 = @intCast(text.len);
        assert(text_len <= Limits.max_bytes);
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        _ = self.arena.reset(if (self.arena.queryCapacity() > 0) .retain_capacity else .free_all);
        const mem_id = try self.mem_registry.register(text, false);
        try self.setTextInternal(mem_id, text);
    }

    pub fn setTextFromMemId(self: *Self, mem_id: u8) tb.TextBufferError!void {
        // Plan: lookup bytes in mem_registry and forward to setTextInternal.
        assert(mem_id <= @as(u8, @intCast(Limits.max_mem_buffers)));
        assert(self.mem_registry.get(mem_id) != null);
        const text = self.mem_registry.get(mem_id) orelse return tb.TextBufferError.InvalidMemId;
        _ = self.arena.reset(if (self.arena.queryCapacity() > 0) .retain_capacity else .free_all);
        try self.setTextInternal(mem_id, text);
    }

    pub fn append(self: *Self, text: []const u8) tb.TextBufferError!void {
        _ = self;
        _ = text;
        return;
    }

    pub fn appendFromMemId(self: *Self, mem_id: u8) tb.TextBufferError!void {
        _ = self;
        _ = mem_id;
        return;
    }

    fn setTextInternal(self: *Self, mem_id: u8, text: []const u8) tb.TextBufferError!void {
        // Single-pass rebuild:
        // - produce segments + line index + aggregates in one scan
        // - guarantee linestart invariant for empty input
        // - use simple loops with explicit upper bounds; no recursion
        const text_len: u32 = @intCast(text.len);
        assert(text_len <= Limits.max_bytes);
        assert(self.mem_registry.get(mem_id) != null);
        self.segments.clearRetainingCapacity();
        self.line_starts.clearRetainingCapacity();
        self.line_widths.clearRetainingCapacity();
        self.line_seg_start.clearRetainingCapacity();
        self.line_seg_end.clearRetainingCapacity();

        self.max_line_width = 0;
        self.total_width = 0;
        self.total_bytes = 0;

        var break_result = utf8.LineBreakResult.init(self.global_allocator);
        defer break_result.deinit();
        try utf8.findLineBreaks(text, &break_result);

        var seg_count: u32 = 0;
        var line_start_offset: u32 = 0;
        var current_line_width: u32 = 0;
        var current_line_seg_start: u32 = 0;

        try self.segments.append(self.global_allocator, Segment{ .linestart = {} });
        seg_count += 1;

        var local_start: u32 = 0;
        var built_lines: u32 = 0;

        for (break_result.breaks.items) |line_break| {
            const break_pos: u32 = @intCast(line_break.pos);
            const local_end: u32 = switch (line_break.kind) {
                .CRLF => break_pos - 1,
                .CR, .LF => break_pos,
            };

            if (local_end > local_start) {
                const chunk = self.createChunk(mem_id, local_start, local_end);
                try self.segments.append(self.global_allocator, Segment{ .text = chunk });
                seg_count += 1;
                const chunk_width: u32 = chunk.width;
                current_line_width += chunk_width;
                self.total_width += chunk_width;
                self.total_bytes += chunk.byte_end - chunk.byte_start;
            }

            try self.segments.append(self.global_allocator, Segment{ .brk = {} });
            const brk_index = seg_count;
            seg_count += 1;

            try self.segments.append(self.global_allocator, Segment{ .linestart = {} });
            seg_count += 1;

            try self.line_starts.append(self.global_allocator, line_start_offset);
            try self.line_widths.append(self.global_allocator, current_line_width);
            try self.line_seg_start.append(self.global_allocator, current_line_seg_start);
            try self.line_seg_end.append(self.global_allocator, brk_index);
            if (current_line_width > self.max_line_width) self.max_line_width = current_line_width;
            built_lines += 1;

            line_start_offset += current_line_width + 1;
            current_line_width = 0;
            current_line_seg_start = brk_index + 1;

            local_start = break_pos + 1;
        }

        if (local_start < text_len) {
            const chunk = self.createChunk(mem_id, local_start, text_len);
            try self.segments.append(self.global_allocator, Segment{ .text = chunk });
            seg_count += 1;
            const chunk_width: u32 = chunk.width;
            current_line_width += chunk_width;
            self.total_width += chunk_width;
            self.total_bytes += chunk.byte_end - chunk.byte_start;
        }

        const had_breaks = built_lines > 0;
        const has_content_after_break = current_line_seg_start < seg_count;

        if (has_content_after_break or had_breaks) {
            try self.line_starts.append(self.global_allocator, line_start_offset);
            try self.line_widths.append(self.global_allocator, current_line_width);
            try self.line_seg_start.append(self.global_allocator, current_line_seg_start);
            try self.line_seg_end.append(self.global_allocator, seg_count);
            if (current_line_width > self.max_line_width) self.max_line_width = current_line_width;
        }

        self.markAllViewsDirty();
    }

    pub fn createChunk(self: *const Self, mem_id: u8, byte_start: u32, byte_end: u32) TextChunk {
        // Plan: read bytes from mem_registry, compute width + ASCII flag,
        // clamp width to u16, and return TextChunk like UnifiedTextBuffer.
        assert(self.mem_registry.get(mem_id) != null);
        assert(byte_start <= byte_end);
        return shared.createChunk(&self.mem_registry, self.tab_width, self.width_method, mem_id, byte_start, byte_end);
    }

    fn rebuildLineIndex(self: *Self) void {
        // Plan:
        // - clear line_* arrays but retain capacity
        // - iterate segments once:
        //   - track current line width, byte count, seg_start
        //   - on .text: add chunk.width and byte length
        //   - on .brk: push line info, advance char_offset by width + 1
        // - emit final line if content after last break or if there were breaks
        // - update max_line_width and aggregate totals
        // Use a single bounded loop over segments; no recursion.
        const seg_count: u32 = @intCast(self.segments.items.len);
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(seg_count <= Limits.max_segments);
        assert(line_count <= Limits.max_lines);
        if (self.segments.items.len > 0) assert(self.segments.items[0].isLineStart());
        self.line_starts.clearRetainingCapacity();
        self.line_widths.clearRetainingCapacity();
        self.line_seg_start.clearRetainingCapacity();
        self.line_seg_end.clearRetainingCapacity();

        self.max_line_width = 0;
        self.total_width = 0;
        self.total_bytes = 0;

        if (seg_count == 0) {
            self.line_starts.append(self.global_allocator, 0) catch {};
            self.line_widths.append(self.global_allocator, 0) catch {};
            self.line_seg_start.append(self.global_allocator, 0) catch {};
            self.line_seg_end.append(self.global_allocator, 0) catch {};
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
                    self.line_starts.append(self.global_allocator, line_start_offset) catch {};
                    self.line_widths.append(self.global_allocator, current_line_width) catch {};
                    self.line_seg_start.append(self.global_allocator, current_line_seg_start) catch {};
                    self.line_seg_end.append(self.global_allocator, seg_idx) catch {};
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
            self.line_starts.append(self.global_allocator, line_start_offset) catch {};
            self.line_widths.append(self.global_allocator, current_line_width) catch {};
            self.line_seg_start.append(self.global_allocator, current_line_seg_start) catch {};
            self.line_seg_end.append(self.global_allocator, seg_count) catch {};
            if (current_line_width > self.max_line_width) self.max_line_width = current_line_width;
        }
    }

    pub fn registerMemBuffer(self: *Self, data: []const u8, owned: bool) tb.TextBufferError!u8 {
        // Keep mem_registry semantics identical to UnifiedTextBuffer so views
        // can register ellipsis text and other short-lived buffers.
        const data_len: u32 = @intCast(data.len);
        assert(data_len <= Limits.max_bytes);
        assert(owned == true or owned == false);
        assert(@intFromPtr(self) != 0);
        return try self.mem_registry.register(data, owned);
    }

    pub fn replaceMemBuffer(self: *Self, mem_id: u8, data: []const u8, owned: bool) tb.TextBufferError!void {
        const data_len: u32 = @intCast(data.len);
        assert(data_len <= Limits.max_bytes);
        assert(owned == true or owned == false);
        assert(@intFromPtr(self) != 0);
        try self.mem_registry.replace(mem_id, data, owned);
    }

    pub fn clearMemRegistry(self: *Self) void {
        self.mem_registry.clear();
    }

    // ---------------------------------------------------------------------
    // Text extraction
    // ---------------------------------------------------------------------
    pub fn getPlainTextIntoBuffer(self: *const Self, out_buffer: []u8) usize {
        // Plan:
        // - iterate lines + segments, copy bytes into out_buffer
        // - insert '\n' between lines (not after final line)
        // - optionally use cached plain text buffer if content_epoch matches
        // Postcondition: return value <= out_buffer.len.
        // Loop bounds must use line_count and seg_count, both <= Limits.
        const line_count: u32 = @intCast(self.line_widths.items.len);
        const out_len: u32 = @intCast(out_buffer.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        assert(out_len <= Limits.max_bytes);
        var out_index: usize = 0;

        const Context = struct {
            buffer: *const Self,
            out_buffer: []u8,
            out_index: *usize,
            line_count: u32,

            fn segmentCallback(ctx_ptr: *anyopaque, line_idx: u32, chunk: *const TextChunk, chunk_idx_in_line: u32) void {
                _ = line_idx;
                _ = chunk_idx_in_line;
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_ptr)));
                const chunk_bytes = chunk.getBytes(&ctx.buffer.mem_registry);
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
            .out_buffer = out_buffer,
            .out_index = &out_index,
            .line_count = line_count,
        };
        self.walkLinesAndSegments(&ctx, Context.segmentCallback, Context.lineEndCallback);

        return out_index;
    }

    pub fn getTextRange(self: *const Self, start_offset: u32, end_offset: u32, out_buffer: []u8) usize {
        // Planned algorithm:
        // - clamp to total_weight (total_width + line_count - 1)
        // - binary search line_starts to find first overlapping line
        // - iterate segments in that line, mapping local display offsets to byte
        //   offsets via utf8.findPosByWidth (same as rope path)
        // - copy bytes into out_buffer and insert '\n' if range spans a break
        // - snap to grapheme boundaries: start excludes graphemes that begin
        //   before start_offset, end includes graphemes that begin before end_offset
        // Postcondition: return value <= out_buffer.len.
        // Use explicit loop bounds (line_count <= Limits.max_lines).
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
                    const result = shared.extractChunkBetweenOffsets(
                        chunk,
                        &self.mem_registry,
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
        self: *Self,
        start_row: u32,
        start_col: u32,
        end_row: u32,
        end_col: u32,
        out_buffer: []u8,
    ) usize {
        // Plan: map coords -> offsets using line_starts + per-line walk, then
        // delegate to getTextRange.
        const line_count: u32 = @intCast(self.line_widths.items.len);
        const out_len: u32 = @intCast(out_buffer.len);
        assert(start_row < line_count);
        assert(end_row < line_count);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        if (start_row == end_row) assert(start_col <= end_col);
        assert(out_len <= Limits.max_bytes);
        if (start_row >= line_count or end_row >= line_count) return 0;

        const start_line_width = self.line_widths.items[@intCast(start_row)];
        const end_line_width = self.line_widths.items[@intCast(end_row)];
        if (start_col > start_line_width or end_col > end_line_width) return 0;

        const start_offset = self.line_starts.items[@intCast(start_row)] + start_col;
        const end_offset = self.line_starts.items[@intCast(end_row)] + end_col;
        return self.getTextRange(start_offset, end_offset, out_buffer);
    }

    fn lineWidthForHighlights(ctx_ptr: *anyopaque, line_idx: usize) u32 {
        const self = @as(*Self, @ptrCast(@alignCast(ctx_ptr)));
        return self.line_widths.items[line_idx];
    }

    // ---------------------------------------------------------------------
    // Highlight + span pipeline (parity with UnifiedTextBuffer)
    // ---------------------------------------------------------------------
    pub fn startHighlightsTransaction(self: *Self) void {
        const span_count: u32 = @intCast(self.highlights.line_spans.items.len);
        assert(self.highlights.highlight_batch_depth < std.math.maxInt(u32));
        assert(span_count <= Limits.max_lines);
        self.highlights.startTransaction();
    }

    pub fn endHighlightsTransaction(self: *Self) void {
        // Plan: if batch depth hits 0, rebuild dirty spans.
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
    ) tb.TextBufferError!void {
        // Plan: append Highlight to line_highlights and mark line spans dirty.
        const line_count: u32 = @intCast(self.line_widths.items.len);
        const line_idx_u32: u32 = @intCast(line_idx);
        assert(line_idx_u32 < line_count);
        assert(col_start <= col_end);
        assert(col_end <= self.line_widths.items[line_idx]);
        assert(hl_ref <= std.math.maxInt(u16));
        if (line_idx_u32 >= line_count) return tb.TextBufferError.InvalidIndex;
        if (col_start >= col_end) return;

        const hl = tb.Highlight{
            .col_start = col_start,
            .col_end = col_end,
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
    ) tb.TextBufferError!void {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(start_row < line_count);
        assert(end_row < line_count);
        if (start_row == end_row) assert(start_col <= end_col);
        assert(hl_ref <= std.math.maxInt(u16));
        if (start_row >= line_count or end_row >= line_count) return tb.TextBufferError.InvalidIndex;
        const start_offset = self.line_starts.items[@intCast(start_row)] + start_col;
        const end_offset = self.line_starts.items[@intCast(end_row)] + end_col;
        return self.addHighlightByCharRange(start_offset, end_offset, style_id, priority, hl_ref);
    }

    pub fn addHighlightByCharRange(
        self: *Self,
        start_offset: u32,
        end_offset: u32,
        style_id: u32,
        priority: u8,
        hl_ref: u16,
    ) tb.TextBufferError!void {
        // Plan: walk lines using line_starts/line_widths and split into per-line
        // highlight ranges with cols derived from offsets.
        // Use a simple bounded loop over lines; no recursion.
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        const total_weight: u32 = self.total_width + (line_count - 1);
        assert(start_offset <= end_offset);
        assert(end_offset <= total_weight);
        assert(hl_ref <= std.math.maxInt(u16));
        if (start_offset >= end_offset or line_count == 0) return;

        var line_idx: u32 = 0;
        while (line_idx < line_count) : (line_idx += 1) {
            const line_start = self.line_starts.items[@intCast(line_idx)];
            const line_width = self.line_widths.items[@intCast(line_idx)];
            const line_end = line_start + line_width;

            if (line_end <= start_offset) continue;
            if (line_start >= end_offset) break;

            const col_start = if (start_offset > line_start) start_offset - line_start else 0;
            const col_end = if (end_offset < line_end) end_offset - line_start else line_width;

            if (col_start < col_end) {
                self.addHighlight(@intCast(line_idx), col_start, col_end, style_id, priority, hl_ref) catch {};
            }
        }
    }

    pub fn removeHighlightsByRef(self: *Self, hl_ref: u16) void {
        const hl_count: u32 = @intCast(self.highlights.line_highlights.items.len);
        assert(hl_ref >= 0);
        assert(hl_count <= Limits.max_lines);
        self.highlights.removeHighlightsByRef(self, lineWidthForHighlights, hl_ref);
    }

    pub fn clearLineHighlights(self: *Self, line_idx: usize) void {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        const line_idx_u32: u32 = @intCast(line_idx);
        const hl_count: u32 = @intCast(self.highlights.line_highlights.items.len);
        assert(line_idx_u32 < line_count);
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

    pub fn getLineHighlightsSlice(self: *const Self, line_idx: usize) []const tb.Highlight {
        const line_count: u32 = @intCast(self.line_widths.items.len);
        const line_idx_u32: u32 = @intCast(line_idx);
        const hl_count: u32 = @intCast(self.highlights.line_highlights.items.len);
        assert(line_idx_u32 < line_count);
        assert(hl_count <= Limits.max_lines);
        return self.highlights.getLineHighlights(line_idx);
    }

    pub fn getHighlightCount(self: *const Self) u32 {
        const hl_count: u32 = @intCast(self.highlights.line_highlights.items.len);
        const span_count: u32 = @intCast(self.highlights.line_spans.items.len);
        assert(hl_count <= Limits.max_lines);
        assert(span_count <= Limits.max_lines);
        return self.highlights.getHighlightCount();
    }

    pub fn getLineSpans(self: *Self, line_idx: usize) []const tb.StyleSpan {
        // Plan: rebuild spans for this line if dirty, otherwise return cached.
        const line_count: u32 = @intCast(self.line_widths.items.len);
        const line_idx_u32: u32 = @intCast(line_idx);
        const span_count: u32 = @intCast(self.highlights.line_spans.items.len);
        assert(line_idx_u32 < line_count);
        assert(span_count <= Limits.max_lines);
        return self.highlights.getLineSpans(self, lineWidthForHighlights, line_idx);
    }

    fn setTextInternalForStyledText(ctx_ptr: *anyopaque, mem_id: u8, text: []const u8) tb.TextBufferError!void {
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
    ) tb.TextBufferError!void {
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

    // ---------------------------------------------------------------------
    // Styled text input
    // ---------------------------------------------------------------------
    pub fn setStyledText(self: *Self, chunks: []const tb.StyledChunk) tb.TextBufferError!void {
        // Plan:
        // - flatten chunks into styled_buffer (reuse capacity)
        // - register or replace styled_text_mem_id in mem_registry
        // - rebuild segments + line index using setTextInternal
        // - if syntax_style is set, convert chunks to highlight ranges by
        //   measuring each chunk and adding highlights by char range
        const chunk_count: u32 = @intCast(chunks.len);
        const line_count: u32 = @intCast(self.line_widths.items.len);
        assert(chunk_count <= Limits.max_segments);
        assert(line_count >= 1);
        assert(line_count <= Limits.max_lines);
        if (chunks.len == 0) {
            self.clear();
            self.clearAllHighlights();
            return;
        }

        // Calculate total text length
        const total_len = shared.totalStyledTextLength(chunks);

        if (total_len == 0) {
            self.clear();
            self.clearAllHighlights();
            return;
        }

        self.clearAllHighlights();

        _ = self.arena.reset(if (self.arena.queryCapacity() > 0) .retain_capacity else .free_all);

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

    // ---------------------------------------------------------------------
    // File loading (optional parity with UnifiedTextBuffer)
    // ---------------------------------------------------------------------
    pub fn loadFile(self: *Self, path: []const u8) tb.TextBufferError!void {
        // Plan: read file into owned buffer, register buffer, setTextInternal.
        const path_len: u32 = @intCast(path.len);
        assert(path_len > 0);
        assert(path_len <= Limits.max_bytes);
        assert(@intFromPtr(self) != 0);
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => tb.TextBufferError.InvalidIndex,
                error.AccessDenied => tb.TextBufferError.InvalidIndex,
                else => tb.TextBufferError.OutOfMemory,
            };
        };
        defer file.close();

        const file_size = file.getEndPos() catch return tb.TextBufferError.OutOfMemory;
        if (file_size > @as(u64, Limits.max_bytes)) return tb.TextBufferError.OutOfMemory;
        const file_size_usize: usize = @intCast(file_size);

        _ = self.arena.reset(if (self.arena.queryCapacity() > 0) .retain_capacity else .free_all);

        const content = self.global_allocator.alloc(u8, file_size_usize) catch return tb.TextBufferError.OutOfMemory;
        errdefer self.global_allocator.free(content);
        const bytes_read = file.readAll(content) catch return tb.TextBufferError.OutOfMemory;
        const text = content[0..bytes_read];
        const mem_id = try self.mem_registry.register(text, true);

        try self.setTextInternal(mem_id, text);
    }
};
