const std = @import("std");
const Allocator = std.mem.Allocator;
const tb = @import("text-buffer.zig");
const seg_mod = @import("text-buffer-segment.zig");
const iter_mod = @import("text-buffer-iterators.zig");
const gp = @import("grapheme.zig");
const utf8 = @import("utf8.zig");

const logger = @import("logger.zig");

const UnifiedTextBuffer = tb.UnifiedTextBuffer;
const RGBA = tb.RGBA;
const TextSelection = tb.TextSelection;
pub const WrapMode = tb.WrapMode;
const TextChunk = seg_mod.TextChunk;
const StyleSpan = tb.StyleSpan;

pub const TextBufferViewError = error{
    OutOfMemory,
};

/// Viewport defines a rectangular window into the virtual line space
pub const Viewport = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const LineInfo = struct {
    line_start_cols: []const u32,
    line_width_cols: []const u32,
    line_sources: []const u32,
    line_wraps: []const u32,
    line_width_cols_max: u32,
};

pub const WrapInfo = struct {
    line_first_vline: []const u32,
    line_vline_counts: []const u32,
};

/// Output structure for virtual line calculation
pub const VirtualLineOutput = struct {
    virtual_lines: *std.ArrayListUnmanaged(VirtualLine),
    cached_line_starts: *std.ArrayListUnmanaged(u32),
    cached_line_widths: *std.ArrayListUnmanaged(u32),
    cached_line_sources: *std.ArrayListUnmanaged(u32),
    cached_line_wrap_indices: *std.ArrayListUnmanaged(u32),
    cached_line_first_vline: *std.ArrayListUnmanaged(u32),
    cached_line_vline_counts: *std.ArrayListUnmanaged(u32),
};

/// Result from measuring dimensions without modifying cache
pub const MeasureResult = struct {
    line_count: u32,
    width_cols_max: u32,
};

const MeasureTailAnchor = struct {
    line_idx: u32,
    seg_start: u32,
    prefix_line_count: u32,
    prefix_width_cols_max: u32,
};

const MeasureComputation = struct {
    result: MeasureResult,
    tail_anchor: ?MeasureTailAnchor = null,
};

pub const VirtualLineSpanInfo = struct {
    spans: []const StyleSpan,
    source_line: usize,
    col_offset: u32,
};

pub const VirtualChunk = struct {
    grapheme_start: u32,
    width: u32,
    byte_start: u32 = 0,
    byte_len: u32 = 0,
    // Direct reference to source chunk for rendering
    chunk: *const TextChunk,
};

pub const VirtualLine = struct {
    chunks: std.ArrayListUnmanaged(VirtualChunk),
    width_cols: u32,
    col_offset: u32,
    source_line: usize,
    source_col_offset: u32,
    is_truncated: bool,
    ellipsis_pos: u32,
    truncation_suffix_start: u32,

    pub fn init() VirtualLine {
        return .{
            .chunks = .{},
            .width_cols = 0,
            .col_offset = 0,
            .source_line = 0,
            .source_col_offset = 0,
            .is_truncated = false,
            .ellipsis_pos = 0,
            .truncation_suffix_start = 0,
        };
    }

    pub fn deinit(self: *VirtualLine, allocator: Allocator) void {
        self.chunks.deinit(allocator);
    }
};

pub const LocalSelection = struct {
    anchorX: i32,
    anchorY: i32,
    focusX: i32,
    focusY: i32,
    isActive: bool,
};

pub const TextBufferView = UnifiedTextBufferView;

pub const UnifiedTextBufferView = struct {
    const Self = @This();

    text_buffer: *UnifiedTextBuffer,
    original_text_buffer: *UnifiedTextBuffer,
    view_id: u32,
    selection: ?TextSelection,
    selection_anchor_offset: ?u32,
    viewport: ?Viewport,
    wrap_width: ?u32,
    wrap_mode: WrapMode,
    virtual_lines: std.ArrayListUnmanaged(VirtualLine),
    virtual_lines_dirty: bool,
    cached_line_starts: std.ArrayListUnmanaged(u32),
    cached_line_widths: std.ArrayListUnmanaged(u32),
    cached_line_sources: std.ArrayListUnmanaged(u32),
    cached_line_wrap_indices: std.ArrayListUnmanaged(u32),
    cached_line_first_vline: std.ArrayListUnmanaged(u32),
    cached_line_vline_counts: std.ArrayListUnmanaged(u32),
    global_allocator: Allocator,
    virtual_lines_arena: *std.heap.ArenaAllocator,

    /// Persistent arena for measureForDimensions. Each call resets it with
    /// retain_capacity to avoid mmap/munmap churn during streaming.
    measure_arena: std.heap.ArenaAllocator,
    tab_indicator: ?u32,
    tab_indicator_color: ?RGBA,
    truncate: bool,
    ellipsis_chunk: TextChunk,
    ellipsis_mem_id: u8,

    // Measurement cache for Yoga layout. Keyed by (buffer, epoch, width, wrap_mode).
    // Using epoch instead of dirty flag prevents stale returns when unrelated
    // code paths clear dirty (e.g., updateVirtualLines).
    cached_measure_width: ?u32,
    cached_measure_wrap_mode: WrapMode,
    cached_measure_result: ?MeasureResult,
    cached_measure_epoch: u64,
    cached_measure_buffer: ?*UnifiedTextBuffer,
    cached_measure_tail_anchor: ?MeasureTailAnchor,

    truncation_applied: bool,
    truncation_epoch: u64,
    truncation_viewport: ?Viewport,

    pub fn init(global_allocator: Allocator, text_buffer: *UnifiedTextBuffer) TextBufferViewError!*Self {
        const self = global_allocator.create(Self) catch return TextBufferViewError.OutOfMemory;
        errdefer global_allocator.destroy(self);

        const virtual_lines_internal_arena = global_allocator.create(std.heap.ArenaAllocator) catch return TextBufferViewError.OutOfMemory;
        errdefer global_allocator.destroy(virtual_lines_internal_arena);
        virtual_lines_internal_arena.* = std.heap.ArenaAllocator.init(global_allocator);

        const view_id = text_buffer.registerView() catch return TextBufferViewError.OutOfMemory;

        const ellipsis_text = "...";
        const ellipsis_mem_id = text_buffer.registerMemBuffer(ellipsis_text, false) catch return TextBufferViewError.OutOfMemory;
        const ellipsis_chunk = text_buffer.createChunk(ellipsis_mem_id, 0, 3);

        self.* = .{
            .text_buffer = text_buffer,
            .original_text_buffer = text_buffer,
            .view_id = view_id,
            .selection = null,
            .selection_anchor_offset = null,
            .viewport = null,
            .wrap_width = null,
            .wrap_mode = .none,
            .virtual_lines = .{},
            .virtual_lines_dirty = true,
            .cached_line_starts = .{},
            .cached_line_widths = .{},
            .cached_line_sources = .{},
            .cached_line_wrap_indices = .{},
            .cached_line_first_vline = .{},
            .cached_line_vline_counts = .{},
            .global_allocator = global_allocator,
            .virtual_lines_arena = virtual_lines_internal_arena,
            .measure_arena = std.heap.ArenaAllocator.init(global_allocator),
            .tab_indicator = null,
            .tab_indicator_color = null,
            .truncate = false,
            .ellipsis_chunk = ellipsis_chunk,
            .ellipsis_mem_id = ellipsis_mem_id,
            .cached_measure_width = null,
            .cached_measure_wrap_mode = .none,
            .cached_measure_result = null,
            .cached_measure_epoch = 0,
            .cached_measure_buffer = null,
            .cached_measure_tail_anchor = null,
            .truncation_applied = false,
            .truncation_epoch = 0,
            .truncation_viewport = null,
        };

        return self;
    }

    /// IMPORTANT: Views must be destroyed BEFORE their associated TextBuffer.
    /// Destroying the TextBuffer first will cause use-after-free when calling deinit.
    /// The TypeScript wrappers enforce this order via the destroy() methods.
    pub fn deinit(self: *Self) void {
        self.original_text_buffer.unregisterView(self.view_id);
        self.virtual_lines_arena.deinit();
        self.global_allocator.destroy(self.virtual_lines_arena);
        self.measure_arena.deinit();
        self.global_allocator.destroy(self);
    }

    pub fn setViewport(self: *Self, vp: ?Viewport) void {
        self.viewport = vp;

        // If viewport has width, set wrap width (wrapping behavior depends on wrap_mode)
        if (vp) |viewport| {
            if (self.wrap_width != viewport.width) {
                self.wrap_width = viewport.width;
                self.virtual_lines_dirty = true;
                self.truncation_applied = false;
            }
        } else {
            self.truncation_applied = false;
        }
    }

    pub fn getViewport(self: *const Self) ?Viewport {
        return self.viewport;
    }

    // This is a convenience method that preserves existing offset
    pub fn setViewportSize(self: *Self, width: u32, height: u32) void {
        if (self.viewport) |vp| {
            self.setViewport(Viewport{
                .x = vp.x,
                .y = vp.y,
                .width = width,
                .height = height,
            });
        } else {
            self.setViewport(Viewport{
                .x = 0,
                .y = 0,
                .width = width,
                .height = height,
            });
        }
    }

    pub fn setWrapWidth(self: *Self, width: ?u32) void {
        if (self.wrap_width != width) {
            self.wrap_width = width;
            self.virtual_lines_dirty = true;
            self.truncation_applied = false;
        }
    }

    pub fn setWrapMode(self: *Self, mode: WrapMode) void {
        if (self.wrap_mode != mode) {
            self.wrap_mode = mode;
            self.virtual_lines_dirty = true;
            self.truncation_applied = false;
        }
    }

    pub fn updateVirtualLines(self: *Self) void {
        const buffer_dirty = self.text_buffer.isViewDirty(self.view_id);
        if (!self.virtual_lines_dirty and !buffer_dirty) return;

        _ = self.virtual_lines_arena.reset(.free_all);
        self.virtual_lines = .{};
        self.cached_line_starts = .{};
        self.cached_line_widths = .{};
        self.cached_line_sources = .{};
        self.cached_line_wrap_indices = .{};
        self.cached_line_first_vline = .{};
        self.cached_line_vline_counts = .{};
        self.truncation_applied = false;
        const virtual_allocator = self.virtual_lines_arena.allocator();

        // Create output structure for the generic function
        const output = VirtualLineOutput{
            .virtual_lines = &self.virtual_lines,
            .cached_line_starts = &self.cached_line_starts,
            .cached_line_widths = &self.cached_line_widths,
            .cached_line_sources = &self.cached_line_sources,
            .cached_line_wrap_indices = &self.cached_line_wrap_indices,
            .cached_line_first_vline = &self.cached_line_first_vline,
            .cached_line_vline_counts = &self.cached_line_vline_counts,
        };

        // Call the generic calculation function
        calculateVirtualLinesGeneric(
            self.text_buffer,
            self.wrap_mode,
            self.wrap_width,
            virtual_allocator,
            output,
        );

        self.virtual_lines_dirty = false;
        self.text_buffer.clearViewDirty(self.view_id);
    }

    pub fn getVirtualLineCount(self: *Self) u32 {
        self.updateVirtualLines();
        return @intCast(self.virtual_lines.items.len);
    }

    pub fn getVirtualLines(self: *Self) []const VirtualLine {
        self.updateVirtualLines();

        const all_vlines = self.virtual_lines.items;

        if (self.truncate and self.viewport != null) {
            self.ensureTruncation();
        }

        if (self.viewport) |vp| {
            const start_idx = @min(vp.y, @as(u32, @intCast(all_vlines.len)));
            const end_idx = @min(start_idx + vp.height, @as(u32, @intCast(all_vlines.len)));
            return all_vlines[start_idx..end_idx];
        }

        return all_vlines;
    }

    pub fn getCachedLineInfo(self: *Self) LineInfo {
        self.updateVirtualLines();

        // If viewport is set, return only the visible lines' info
        if (self.viewport) |vp| {
            const start_idx = @min(vp.y, @as(u32, @intCast(self.cached_line_starts.items.len)));
            const end_idx = @min(start_idx + vp.height, @as(u32, @intCast(self.cached_line_starts.items.len)));

            const viewport_line_start_cols = self.cached_line_starts.items[start_idx..end_idx];
            const viewport_line_width_cols = self.cached_line_widths.items[start_idx..end_idx];
            const viewport_line_sources = self.cached_line_sources.items[start_idx..end_idx];
            const viewport_line_wraps = self.cached_line_wrap_indices.items[start_idx..end_idx];

            var width_cols_max: u32 = 0;
            for (viewport_line_width_cols) |w| {
                width_cols_max = @max(width_cols_max, w);
            }

            return LineInfo{
                .line_start_cols = viewport_line_start_cols,
                .line_width_cols = viewport_line_width_cols,
                .line_sources = viewport_line_sources,
                .line_wraps = viewport_line_wraps,
                .line_width_cols_max = width_cols_max,
            };
        }

        return LineInfo{
            .line_start_cols = self.cached_line_starts.items,
            .line_width_cols = self.cached_line_widths.items,
            .line_sources = self.cached_line_sources.items,
            .line_wraps = self.cached_line_wrap_indices.items,
            .line_width_cols_max = self.text_buffer.lineWidthColsMax(),
        };
    }

    pub fn getLogicalLineInfo(self: *Self) LineInfo {
        self.updateVirtualLines();

        return LineInfo{
            .line_start_cols = self.cached_line_starts.items,
            .line_width_cols = self.cached_line_widths.items,
            .line_sources = self.cached_line_sources.items,
            .line_wraps = self.cached_line_wrap_indices.items,
            .line_width_cols_max = self.text_buffer.lineWidthColsMax(),
        };
    }

    pub fn getWrapInfo(self: *Self) WrapInfo {
        self.updateVirtualLines();
        return WrapInfo{
            .line_first_vline = self.cached_line_first_vline.items,
            .line_vline_counts = self.cached_line_vline_counts.items,
        };
    }

    pub fn findVisualLineIndex(self: *Self, logical_row: u32, logical_col: u32) u32 {
        self.updateVirtualLines();

        const vlines = self.virtual_lines.items;
        if (vlines.len == 0) return 0;

        const wrap_info = self.getWrapInfo();

        // Clamp logical_row to valid range
        const clamped_row = if (logical_row >= wrap_info.line_first_vline.len)
            if (wrap_info.line_first_vline.len > 0) wrap_info.line_first_vline.len - 1 else 0
        else
            logical_row;

        if (clamped_row >= wrap_info.line_first_vline.len) return 0;

        const first_vline_idx = wrap_info.line_first_vline[clamped_row];
        const vline_count = wrap_info.line_vline_counts[clamped_row];

        if (vline_count == 0) return first_vline_idx;

        var i: u32 = 0;
        while (i < vline_count) : (i += 1) {
            const vline_idx = first_vline_idx + i;
            if (vline_idx >= vlines.len) break;

            const vline = &vlines[vline_idx];
            const vline_start_col = vline.source_col_offset;
            const vline_end_col = vline_start_col + vline.width_cols;

            const is_last_vline = (i == vline_count - 1);

            // For the end check: use < for all lines except the last line where we use <=
            // This ensures that a position exactly at vline_end_col goes to the NEXT line
            // unless this is the last line (where there is no next line)
            const end_check = if (is_last_vline) logical_col <= vline_end_col else logical_col < vline_end_col;

            if (logical_col >= vline_start_col and end_check) {
                return vline_idx;
            }
        }

        // If not found, return last virtual line for this logical line
        const last_vline_idx = first_vline_idx + vline_count - 1;
        if (last_vline_idx < vlines.len) {
            return last_vline_idx;
        }

        return first_vline_idx;
    }

    pub fn getPlainTextIntoBuffer(self: *const Self, out_buffer: []u8) usize {
        return self.text_buffer.getPlainTextIntoBuffer(out_buffer);
    }

    pub fn getArenaAllocatedBytes(self: *const Self) usize {
        return self.virtual_lines_arena.queryCapacity();
    }

    pub fn setSelection(self: *Self, start: u32, end: u32, bgColor: ?RGBA, fgColor: ?RGBA) void {
        self.selection = TextSelection{
            .start = start,
            .end = end,
            .bgColor = bgColor,
            .fgColor = fgColor,
        };
    }

    pub fn updateSelection(self: *Self, end: u32, bgColor: ?RGBA, fgColor: ?RGBA) void {
        if (self.selection) |sel| {
            self.selection = TextSelection{
                .start = sel.start,
                .end = end,
                .bgColor = bgColor,
                .fgColor = fgColor,
            };
        }
    }

    pub fn resetSelection(self: *Self) void {
        self.selection = null;
    }

    pub fn getSelection(self: *const Self) ?TextSelection {
        return self.selection;
    }

    pub fn getTextBuffer(self: *const Self) *UnifiedTextBuffer {
        return self.text_buffer;
    }

    pub fn switchToBuffer(self: *Self, buffer: *UnifiedTextBuffer) void {
        self.text_buffer = buffer;
        self.virtual_lines_dirty = true;
    }

    pub fn switchToOriginalBuffer(self: *Self) void {
        if (self.text_buffer != self.original_text_buffer) {
            self.text_buffer = self.original_text_buffer;
            self.virtual_lines_dirty = true;
        }
    }

    pub fn setLocalSelection(self: *Self, anchorX: i32, anchorY: i32, focusX: i32, focusY: i32, bgColor: ?RGBA, fgColor: ?RGBA) bool {
        self.updateVirtualLines();
        if (self.truncate and self.viewport != null) {
            self.ensureTruncation();
        }

        const anchor_above = anchorY < 0;
        const focus_above = focusY < 0;
        const max_y = @as(i32, @intCast(self.virtual_lines.items.len)) - 1;
        const anchor_below = anchorY > max_y;
        const focus_below = focusY > max_y;

        if ((anchor_above and focus_above) or (anchor_below and focus_below)) {
            const had_selection = self.selection != null;
            self.selection = null;
            self.selection_anchor_offset = null;
            return had_selection;
        }

        const text_end_offset = self.getTextEndOffset();

        const anchor_offset = if (anchor_above or anchorX < 0)
            0
        else if (anchor_below)
            text_end_offset
        else
            self.coordsToCharOffset(anchorX, anchorY) orelse {
                const had_selection = self.selection != null;
                self.selection = null;
                self.selection_anchor_offset = null;
                return had_selection;
            };

        const focus_offset = if (focus_above or focusX < 0)
            0
        else if (focus_below)
            text_end_offset
        else
            self.coordsToCharOffset(focusX, focusY) orelse {
                const had_selection = self.selection != null;
                self.selection = null;
                self.selection_anchor_offset = null;
                return had_selection;
            };

        self.selection_anchor_offset = anchor_offset;

        const new_start = @min(anchor_offset, focus_offset);
        const new_end = @max(anchor_offset, focus_offset);

        // Always store selection, even if zero-width, to preserve anchor for updateLocalSelection
        const new_selection = TextSelection{
            .start = new_start,
            .end = new_end,
            .bgColor = bgColor,
            .fgColor = fgColor,
        };

        const selection_changed = if (self.selection) |old_sel|
            old_sel.start != new_selection.start or old_sel.end != new_selection.end
        else
            true;

        self.selection = new_selection;
        return selection_changed;
    }

    pub fn updateLocalSelection(self: *Self, anchorX: i32, anchorY: i32, focusX: i32, focusY: i32, bgColor: ?RGBA, fgColor: ?RGBA) bool {
        if (self.selection_anchor_offset) |_| {
            return self.updateLocalSelectionFocusOnly(focusX, focusY, bgColor, fgColor);
        } else {
            return self.setLocalSelection(anchorX, anchorY, focusX, focusY, bgColor, fgColor);
        }
    }

    fn updateLocalSelectionFocusOnly(self: *Self, focusX: i32, focusY: i32, bgColor: ?RGBA, fgColor: ?RGBA) bool {
        const anchor_offset = self.selection_anchor_offset orelse return false;

        self.updateVirtualLines();
        if (self.truncate and self.viewport != null) {
            self.applyTruncation();
        }

        const focus_above = focusY < 0;
        const max_y = @as(i32, @intCast(self.virtual_lines.items.len)) - 1;
        const focus_below = focusY > max_y;

        const text_end_offset = self.getTextEndOffset();

        const focus_col_offset = if (focus_above or focusX < 0)
            0
        else if (focus_below)
            text_end_offset
        else
            self.coordsToCharOffset(focusX, focusY) orelse return false;

        const new_start = @min(anchor_offset, focus_col_offset);
        var new_end = @max(anchor_offset, focus_col_offset);

        if (focus_col_offset < anchor_offset) {
            new_end = @min(new_end + 1, text_end_offset);
        }

        self.selection = TextSelection{
            .start = new_start,
            .end = new_end,
            .bgColor = bgColor,
            .fgColor = fgColor,
        };

        return true;
    }

    pub fn resetLocalSelection(self: *Self) void {
        self.selection = null;
        self.selection_anchor_offset = null;
    }

    fn getTextEndOffset(self: *Self) u32 {
        if (self.truncate and self.viewport != null) {
            self.ensureTruncation();
        }

        if (self.virtual_lines.items.len == 0) return 0;
        const last_line_idx = self.virtual_lines.items.len - 1;
        const last_vline = &self.virtual_lines.items[last_line_idx];

        if (last_vline.is_truncated) {
            return last_vline.col_offset + last_vline.truncation_suffix_start + (last_vline.width_cols - last_vline.ellipsis_pos - 3);
        }

        return last_vline.col_offset + last_vline.width_cols;
    }

    fn coordsToCharOffset(self: *Self, x: i32, y: i32) ?u32 {
        self.updateVirtualLines();
        if (self.truncate and self.viewport != null) {
            self.ensureTruncation();
        }

        const y_offset: i32 = if (self.viewport) |vp| @intCast(vp.y) else 0;
        const x_offset: i32 = if (self.viewport) |vp|
            (if (self.wrap_mode == .none) @intCast(vp.x) else 0)
        else
            0;

        if (self.virtual_lines.items.len == 0) {
            return 0;
        }

        const abs_y = y + y_offset;
        const abs_x = x + x_offset;

        const clamped_y = @max(0, @min(abs_y, @as(i32, @intCast(self.virtual_lines.items.len)) - 1));

        const vline_idx: usize = @intCast(clamped_y);
        const vline = &self.virtual_lines.items[vline_idx];
        const lineStart = vline.col_offset;
        const lineWidth = vline.width_cols;

        var localX = @max(0, @min(abs_x, @as(i32, @intCast(lineWidth))));

        if (vline.is_truncated) {
            const ellipsis_width: u32 = 3;
            const localX_u32: u32 = @intCast(localX);

            if (localX_u32 >= vline.ellipsis_pos and localX_u32 < vline.ellipsis_pos + ellipsis_width) {
                localX = @intCast(vline.ellipsis_pos);
            } else if (localX_u32 >= vline.ellipsis_pos + ellipsis_width) {
                const suffix_offset = localX_u32 - vline.ellipsis_pos - ellipsis_width;
                localX = @intCast(vline.truncation_suffix_start + suffix_offset);
            }
        }

        const result = lineStart + @as(u32, @intCast(localX));

        return result;
    }

    /// Pack selection info into u64 for efficient passing
    /// Returns 0xFFFF_FFFF_FFFF_FFFF for no selection or zero-width selection
    pub fn packSelectionInfo(self: *const Self) u64 {
        if (self.selection) |sel| {
            if (sel.start == sel.end) {
                return 0xFFFF_FFFF_FFFF_FFFF;
            }
            return (@as(u64, sel.start) << 32) | @as(u64, sel.end);
        } else {
            return 0xFFFF_FFFF_FFFF_FFFF;
        }
    }

    /// Get selected text into buffer - using efficient single-pass API
    pub fn getSelectedTextIntoBuffer(self: *Self, out_buffer: []u8) usize {
        const selection = self.selection orelse return 0;
        if (selection.start == selection.end) return 0;
        return self.text_buffer.getTextRange(selection.start, selection.end, out_buffer);
    }

    pub fn getVirtualLineSpans(self: *const Self, vline_idx: usize) VirtualLineSpanInfo {
        if (vline_idx >= self.virtual_lines.items.len) {
            return VirtualLineSpanInfo{ .spans = &[_]StyleSpan{}, .source_line = 0, .col_offset = 0 };
        }

        const vline = &self.virtual_lines.items[vline_idx];
        const spans = self.text_buffer.getLineSpans(vline.source_line);

        return VirtualLineSpanInfo{
            .spans = spans,
            .source_line = vline.source_line,
            .col_offset = vline.source_col_offset,
        };
    }

    pub fn setTabIndicator(self: *Self, indicator: ?u32) void {
        self.tab_indicator = indicator;
    }

    pub fn getTabIndicator(self: *const Self) ?u32 {
        return self.tab_indicator;
    }

    pub fn setTabIndicatorColor(self: *Self, color: ?RGBA) void {
        self.tab_indicator_color = color;
    }

    pub fn getTabIndicatorColor(self: *const Self) ?RGBA {
        return self.tab_indicator_color;
    }

    pub fn setTruncate(self: *Self, truncate: bool) void {
        if (self.truncate != truncate) {
            self.truncate = truncate;
            self.virtual_lines_dirty = true;
            self.truncation_applied = false;
        }
    }

    pub fn getTruncate(self: *const Self) bool {
        return self.truncate;
    }

    fn ensureTruncation(self: *Self) void {
        if (!self.truncate or self.viewport == null) return;

        const epoch = self.text_buffer.getContentEpoch();
        if (self.truncation_applied and self.truncation_epoch == epoch and
            self.truncation_viewport != null and self.viewport != null and
            self.truncation_viewport.?.x == self.viewport.?.x and
            self.truncation_viewport.?.y == self.viewport.?.y and
            self.truncation_viewport.?.width == self.viewport.?.width and
            self.truncation_viewport.?.height == self.viewport.?.height)
        {
            return;
        }

        self.applyTruncation();
        self.truncation_applied = true;
        self.truncation_epoch = epoch;
        self.truncation_viewport = self.viewport;
    }

    fn applyTruncation(self: *Self) void {
        const vp = self.viewport orelse return;
        if (vp.width == 0) return;

        const ellipsis_width: u32 = 3;

        for (self.virtual_lines.items) |*vline| {
            if (vline.width_cols <= vp.width) continue;

            if (vp.width <= ellipsis_width) {
                vline.chunks.clearRetainingCapacity();
                vline.width_cols = 0;
                vline.is_truncated = true;
                vline.ellipsis_pos = 0;
                vline.truncation_suffix_start = vline.width_cols;
                continue;
            }

            const available_width = vp.width - ellipsis_width;
            const prefix_width = available_width / 2;
            const suffix_width = available_width - prefix_width;

            var new_chunks: std.ArrayListUnmanaged(VirtualChunk) = .{};

            var prefix_accumulated: u32 = 0;
            for (vline.chunks.items) |chunk| {
                if (prefix_accumulated >= prefix_width) break;

                const space_left = prefix_width - prefix_accumulated;
                if (chunk.width <= space_left) {
                    new_chunks.append(self.virtual_lines_arena.allocator(), chunk) catch return;
                    prefix_accumulated += chunk.width;
                } else {
                    var partial = chunk;
                    partial.width = space_left;
                    new_chunks.append(self.virtual_lines_arena.allocator(), partial) catch return;
                    prefix_accumulated += space_left;
                    break;
                }
            }

            new_chunks.append(self.virtual_lines_arena.allocator(), VirtualChunk{
                .grapheme_start = 0,
                .width = ellipsis_width,
                .chunk = &self.ellipsis_chunk,
            }) catch return;

            const suffix_start_pos = vline.width_cols - suffix_width;

            var pos_accumulated: u32 = 0;
            for (vline.chunks.items) |chunk| {
                const chunk_end = pos_accumulated + chunk.width;

                if (chunk_end <= suffix_start_pos) {
                    pos_accumulated += chunk.width;
                    continue;
                }

                if (pos_accumulated >= suffix_start_pos) {
                    new_chunks.append(self.virtual_lines_arena.allocator(), chunk) catch return;
                } else {
                    const offset_in_chunk = suffix_start_pos - pos_accumulated;
                    var partial = chunk;
                    partial.grapheme_start += offset_in_chunk;
                    partial.width = chunk.width - offset_in_chunk;
                    new_chunks.append(self.virtual_lines_arena.allocator(), partial) catch return;
                }

                pos_accumulated += chunk.width;
            }

            vline.chunks.clearRetainingCapacity();
            vline.chunks.appendSlice(self.virtual_lines_arena.allocator(), new_chunks.items) catch return;
            vline.width_cols = vp.width;
            vline.is_truncated = true;
            vline.ellipsis_pos = prefix_width;
            vline.truncation_suffix_start = suffix_start_pos;
        }
    }

    fn isCoalescedAsciiRunSpan(span: utf8.GraphemeSpan) bool {
        if (span.break_after != .none) {
            return false;
        }

        if (span.col_width == 0) {
            return false;
        }

        return span.byte_len == span.col_width;
    }

    fn splitCoalescedAsciiRunSpan(span: utf8.GraphemeSpan, take_cols: u32) struct { head: utf8.GraphemeSpan, tail: ?utf8.GraphemeSpan } {
        const clamped_take = @min(take_cols, @as(u32, span.col_width));
        const remaining_cols = @as(u32, span.col_width) - clamped_take;

        const head = utf8.GraphemeSpan{
            .byte_start = span.byte_start,
            .byte_len = clamped_take,
            .col_start = span.col_start,
            .col_width = @intCast(clamped_take),
            .break_after = if (remaining_cols == 0) span.break_after else .none,
        };

        if (remaining_cols == 0) {
            return .{ .head = head, .tail = null };
        }

        const tail = utf8.GraphemeSpan{
            .byte_start = span.byte_start + clamped_take,
            .byte_len = span.byte_len - clamped_take,
            .col_start = span.col_start + clamped_take,
            .col_width = @intCast(remaining_cols),
            .break_after = span.break_after,
        };

        return .{ .head = head, .tail = tail };
    }

    fn layoutWidthMethodForSpanWrap(width_method: utf8.WidthMethod) utf8.WidthMethod {
        return switch (width_method) {
            .wcwidth => .unicode,
            else => width_method,
        };
    }

    fn shouldUseFullLayoutCache(chunk: *const TextChunk) bool {
        const byte_len = chunk.byte_end - chunk.byte_start;
        if (byte_len > 64 * 1024) {
            return false;
        }
        return true;
    }

    fn runWordWrapSpans(comptime Context: type, ctx: *Context, chunk: *const TextChunk, spans: []const utf8.GraphemeSpan) void {
        var span_idx: usize = 0;
        var pending_span: ?utf8.GraphemeSpan = null;

        while (true) {
            const span = blk: {
                if (pending_span) |p| {
                    pending_span = null;
                    break :blk p;
                }

                if (span_idx >= spans.len) {
                    break;
                }

                const next = spans[span_idx];
                span_idx += 1;
                break :blk next;
            };

            const span_width: u32 = span.col_width;
            const fits = ctx.line_position + span_width <= ctx.wrap_w;

            if (fits and span.break_after == .none) {
                const available = ctx.wrap_w - ctx.line_position;
                const max_col_width: u32 = std.math.maxInt(u16);
                var run_width: u32 = 0;
                var run_byte_len: u32 = 0;
                var consumed_current = false;

                while (true) {
                    const candidate = if (!consumed_current)
                        span
                    else if (span_idx < spans.len)
                        spans[span_idx]
                    else
                        break;

                    const candidate_width: u32 = candidate.col_width;
                    if (candidate.break_after != .none) break;
                    if (run_width + candidate_width > available) break;
                    if (run_width + candidate_width > max_col_width) break;

                    run_width += candidate_width;
                    run_byte_len += candidate.byte_len;

                    if (!consumed_current) {
                        consumed_current = true;
                    } else {
                        span_idx += 1;
                    }

                    if (run_width == available and available != 0) break;
                }

                if (run_width > 0) {
                    ctx.appendSpan(chunk, .{
                        .byte_start = span.byte_start,
                        .byte_len = run_byte_len,
                        .col_start = span.col_start,
                        .col_width = @intCast(run_width),
                        .break_after = .none,
                    }, true);
                    continue;
                }
            }

            if (fits) {
                ctx.appendSpan(chunk, span, true);
                continue;
            }

            if (ctx.line_position == 0) {
                if (ctx.wrap_w > 0 and isCoalescedAsciiRunSpan(span) and span_width > ctx.wrap_w) {
                    const split = splitCoalescedAsciiRunSpan(span, ctx.wrap_w);
                    ctx.appendSpan(chunk, split.head, true);
                    pending_span = split.tail;
                    ctx.commitLine();
                    continue;
                }

                ctx.appendSpan(chunk, span, true);
                ctx.commitLine();
                continue;
            }

            if (span.break_after == .whitespace) {
                if (ctx.rewindToLastWrap()) {
                    pending_span = span;
                    continue;
                }
                ctx.commitLine();
                ctx.dropOverflowSpan(span);
                continue;
            }

            if (ctx.rewindToLastWrap()) {
                pending_span = span;
                continue;
            }

            pending_span = span;
            ctx.commitLine();
        }
    }

    fn runCharWrapSpans(comptime Context: type, ctx: *Context, chunk: *const TextChunk, spans: []const utf8.GraphemeSpan) void {
        var span_idx: usize = 0;
        var pending_span: ?utf8.GraphemeSpan = null;

        while (true) {
            const span = blk: {
                if (pending_span) |p| {
                    pending_span = null;
                    break :blk p;
                }

                if (span_idx >= spans.len) {
                    break;
                }

                const next = spans[span_idx];
                span_idx += 1;
                break :blk next;
            };

            const span_width: u32 = span.col_width;
            const fits = ctx.line_position + span_width <= ctx.wrap_w;

            if (fits) {
                const available = ctx.wrap_w - ctx.line_position;
                const max_col_width: u32 = std.math.maxInt(u16);
                var run_width: u32 = 0;
                var run_byte_len: u32 = 0;
                var consumed_current = false;

                while (true) {
                    const candidate = if (!consumed_current)
                        span
                    else if (span_idx < spans.len)
                        spans[span_idx]
                    else
                        break;

                    const candidate_width: u32 = candidate.col_width;
                    if (run_width + candidate_width > available) break;
                    if (run_width + candidate_width > max_col_width) break;

                    run_width += candidate_width;
                    run_byte_len += candidate.byte_len;

                    if (!consumed_current) {
                        consumed_current = true;
                    } else {
                        span_idx += 1;
                    }

                    if (run_width == available and available != 0) break;
                }

                if (run_width > 0) {
                    ctx.appendSpan(chunk, .{
                        .byte_start = span.byte_start,
                        .byte_len = run_byte_len,
                        .col_start = span.col_start,
                        .col_width = @intCast(run_width),
                        .break_after = .none,
                    }, false);
                    continue;
                }
            }

            if (ctx.wrap_w > 0 and isCoalescedAsciiRunSpan(span)) {
                const available = if (ctx.line_position < ctx.wrap_w) ctx.wrap_w - ctx.line_position else 0;
                if (available > 0 and span_width > available) {
                    const split = splitCoalescedAsciiRunSpan(span, available);
                    ctx.appendSpan(chunk, split.head, false);
                    pending_span = split.tail;
                    ctx.commitLine();
                    continue;
                }
            }

            if (ctx.line_position == 0) {
                if (ctx.wrap_w > 0 and isCoalescedAsciiRunSpan(span) and span_width > ctx.wrap_w) {
                    const split = splitCoalescedAsciiRunSpan(span, ctx.wrap_w);
                    ctx.appendSpan(chunk, split.head, false);
                    pending_span = split.tail;
                    ctx.commitLine();
                    continue;
                }

                ctx.appendSpan(chunk, span, false);
                ctx.commitLine();
                continue;
            }

            pending_span = span;
            ctx.commitLine();
        }
    }

    fn processWrapChunkSpans(comptime Context: type, ctx: *Context, chunk: *const TextChunk) void {
        const chunk_bytes = chunk.getBytes(ctx.text_buffer.memRegistry());
        var cursor = utf8.LayoutScanCursor.init();

        const base_width_method = ctx.text_buffer.widthMethod();
        const word_width_method = layoutWidthMethodForSpanWrap(base_width_method);

        if (ctx.wrap_mode == .word and shouldUseFullLayoutCache(chunk)) {
            const spans = chunk.getLayoutSpans(
                ctx.text_buffer.memRegistry(),
                ctx.text_buffer.getAllocator(),
                ctx.text_buffer.tabWidth(),
                word_width_method,
            ) catch return;
            runWordWrapSpans(Context, ctx, chunk, spans);
            return;
        }

        ctx.layout_scratch.reset();

        while (true) {
            const slot = ctx.layout_scratch.acquire();
            const batch = if (ctx.wrap_mode == .char)
                utf8.scanLayoutNextWindowBatchNoBreaks(
                    chunk_bytes,
                    ctx.text_buffer.tabWidth(),
                    chunk.isAsciiOnly(),
                    base_width_method,
                    &cursor,
                    slot.spans,
                    seg_mod.LAYOUT_WINDOW_BYTES,
                ) catch break
            else
                utf8.scanLayoutNextWindowBatch(
                    chunk_bytes,
                    ctx.text_buffer.tabWidth(),
                    chunk.isAsciiOnly(),
                    word_width_method,
                    &cursor,
                    slot.spans,
                    seg_mod.LAYOUT_WINDOW_BYTES,
                ) catch break;

            if (ctx.wrap_mode == .char) {
                runCharWrapSpans(Context, ctx, chunk, batch.spans);
            } else {
                runWordWrapSpans(Context, ctx, chunk, batch.spans);
            }

            if (batch.done) break;
        }
    }

    fn measureWrappedSpanStateMachine(
        text_buffer: *UnifiedTextBuffer,
        wrap_mode: WrapMode,
        wrap_width: u32,
    ) MeasureComputation {
        if (wrap_mode == .none or wrap_width == 0) {
            return .{ .result = .{ .line_count = 0, .width_cols_max = 0 } };
        }

        const MetricsContext = struct {
            text_buffer: *UnifiedTextBuffer,
            wrap_mode: WrapMode,
            wrap_w: u32,
            line_position: u32 = 0,
            line_count: u32 = 0,
            width_cols_max: u32 = 0,
            last_wrap_line_position: ?u32 = null,
            layout_scratch: tb.LayoutSpanScratch = .{},

            source_line_started: bool = false,
            source_line_start_line_count: u32 = 0,
            source_line_start_width_cols_max: u32 = 0,
            last_tail_anchor: ?MeasureTailAnchor = null,

            fn clearLastWrap(ctx: *@This()) void {
                ctx.last_wrap_line_position = null;
            }

            fn rememberLastWrap(ctx: *@This()) void {
                ctx.last_wrap_line_position = ctx.line_position;
            }

            fn beginSourceLine(ctx: *@This()) void {
                if (ctx.source_line_started) return;
                ctx.source_line_started = true;
                ctx.source_line_start_line_count = ctx.line_count;
                ctx.source_line_start_width_cols_max = ctx.width_cols_max;
            }

            fn appendSpan(ctx: *@This(), _: *const TextChunk, span: utf8.GraphemeSpan, track_wrap_breaks: bool) void {
                const span_width: u32 = span.col_width;
                ctx.line_position += span_width;
                if (track_wrap_breaks and span.break_after != .none) {
                    ctx.rememberLastWrap();
                }
            }

            fn commitLine(ctx: *@This()) void {
                ctx.width_cols_max = @max(ctx.width_cols_max, ctx.line_position);
                ctx.line_count += 1;
                ctx.line_position = 0;
                ctx.clearLastWrap();
            }

            fn rewindToLastWrap(ctx: *@This()) bool {
                if (ctx.last_wrap_line_position == null) {
                    return false;
                }

                const break_col = ctx.last_wrap_line_position.?;
                const suffix_width = ctx.line_position - break_col;
                ctx.width_cols_max = @max(ctx.width_cols_max, break_col);
                ctx.line_count += 1;
                ctx.line_position = suffix_width;
                ctx.clearLastWrap();
                return true;
            }

            fn dropOverflowSpan(ctx: *@This(), _: utf8.GraphemeSpan) void {
                ctx.clearLastWrap();
            }

            fn segment_callback(ctx_ptr: *anyopaque, _: u32, chunk: *const TextChunk, chunk_idx_in_line: u32) void {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_ptr)));
                if (chunk_idx_in_line == 0) {
                    ctx.beginSourceLine();
                }
                processWrapChunkSpans(@This(), ctx, chunk);
            }

            fn line_end_callback(ctx_ptr: *anyopaque, line_info: iter_mod.LineInfo) void {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_ptr)));

                if (!ctx.source_line_started) {
                    ctx.beginSourceLine();
                }

                if (ctx.line_position > 0 or line_info.width_cols == 0) {
                    ctx.commitLine();
                }

                ctx.last_tail_anchor = .{
                    .line_idx = line_info.line_idx,
                    .seg_start = line_info.seg_start,
                    .prefix_line_count = ctx.source_line_start_line_count,
                    .prefix_width_cols_max = ctx.source_line_start_width_cols_max,
                };

                ctx.source_line_started = false;
            }
        };

        var ctx = MetricsContext{
            .text_buffer = text_buffer,
            .wrap_mode = wrap_mode,
            .wrap_w = wrap_width,
        };

        text_buffer.walkLinesAndSegments(&ctx, MetricsContext.segment_callback, MetricsContext.line_end_callback);
        return .{
            .result = .{ .line_count = ctx.line_count, .width_cols_max = ctx.width_cols_max },
            .tail_anchor = ctx.last_tail_anchor,
        };
    }

    fn measureWrappedSpanStateMachineFromAnchor(
        text_buffer: *UnifiedTextBuffer,
        wrap_mode: WrapMode,
        wrap_width: u32,
        anchor: MeasureTailAnchor,
    ) MeasureComputation {
        if (wrap_mode == .none or wrap_width == 0) {
            return .{ .result = .{ .line_count = 0, .width_cols_max = 0 } };
        }

        const MetricsContext = struct {
            text_buffer: *UnifiedTextBuffer,
            wrap_mode: WrapMode,
            wrap_w: u32,
            line_position: u32 = 0,
            line_count: u32,
            width_cols_max: u32,
            last_wrap_line_position: ?u32 = null,
            layout_scratch: tb.LayoutSpanScratch = .{},

            source_line_started: bool = false,
            source_line_start_line_count: u32,
            source_line_start_width_cols_max: u32,
            last_tail_anchor: ?MeasureTailAnchor = null,

            current_line_idx: u32,
            current_line_seg_start: u32,
            current_line_width_cols: u32 = 0,
            current_line_chunk_idx: u32 = 0,
            current_seg_idx: u32,
            saw_break: bool = false,

            fn clearLastWrap(ctx: *@This()) void {
                ctx.last_wrap_line_position = null;
            }

            fn rememberLastWrap(ctx: *@This()) void {
                ctx.last_wrap_line_position = ctx.line_position;
            }

            fn beginSourceLine(ctx: *@This()) void {
                if (ctx.source_line_started) return;
                ctx.source_line_started = true;
                ctx.source_line_start_line_count = ctx.line_count;
                ctx.source_line_start_width_cols_max = ctx.width_cols_max;
            }

            fn appendSpan(ctx: *@This(), _: *const TextChunk, span: utf8.GraphemeSpan, track_wrap_breaks: bool) void {
                const span_width: u32 = span.col_width;
                ctx.line_position += span_width;
                if (track_wrap_breaks and span.break_after != .none) {
                    ctx.rememberLastWrap();
                }
            }

            fn commitLine(ctx: *@This()) void {
                ctx.width_cols_max = @max(ctx.width_cols_max, ctx.line_position);
                ctx.line_count += 1;
                ctx.line_position = 0;
                ctx.clearLastWrap();
            }

            fn rewindToLastWrap(ctx: *@This()) bool {
                if (ctx.last_wrap_line_position == null) {
                    return false;
                }

                const break_col = ctx.last_wrap_line_position.?;
                const suffix_width = ctx.line_position - break_col;
                ctx.width_cols_max = @max(ctx.width_cols_max, break_col);
                ctx.line_count += 1;
                ctx.line_position = suffix_width;
                ctx.clearLastWrap();
                return true;
            }

            fn dropOverflowSpan(ctx: *@This(), _: utf8.GraphemeSpan) void {
                ctx.clearLastWrap();
            }

            fn finishCurrentSourceLine(ctx: *@This(), is_break: bool, seg_end: u32) void {
                if (!ctx.source_line_started) {
                    ctx.beginSourceLine();
                }

                if (ctx.line_position > 0 or ctx.current_line_width_cols == 0) {
                    ctx.commitLine();
                }

                ctx.last_tail_anchor = .{
                    .line_idx = ctx.current_line_idx,
                    .seg_start = ctx.current_line_seg_start,
                    .prefix_line_count = ctx.source_line_start_line_count,
                    .prefix_width_cols_max = ctx.source_line_start_width_cols_max,
                };

                ctx.source_line_started = false;

                if (is_break) {
                    ctx.current_line_idx += 1;
                    ctx.current_line_seg_start = seg_end + 1;
                    ctx.current_line_width_cols = 0;
                    ctx.current_line_chunk_idx = 0;
                }
            }
        };

        var ctx = MetricsContext{
            .text_buffer = text_buffer,
            .wrap_mode = wrap_mode,
            .wrap_w = wrap_width,
            .line_count = anchor.prefix_line_count,
            .width_cols_max = anchor.prefix_width_cols_max,
            .source_line_start_line_count = anchor.prefix_line_count,
            .source_line_start_width_cols_max = anchor.prefix_width_cols_max,
            .current_line_idx = anchor.line_idx,
            .current_line_seg_start = anchor.seg_start,
            .current_seg_idx = anchor.seg_start,
        };

        const WalkContext = struct {
            metrics: *MetricsContext,
            start_seg_idx: u32,

            fn walker(wctx_ptr: *anyopaque, seg: *const seg_mod.Segment, rel_idx: u32) seg_mod.UnifiedRope.Node.WalkerResult {
                const wctx = @as(*@This(), @ptrCast(@alignCast(wctx_ptr)));
                const mctx = wctx.metrics;
                const seg_idx = wctx.start_seg_idx + rel_idx;

                if (seg.asText()) |chunk| {
                    if (mctx.current_line_chunk_idx == 0) {
                        mctx.beginSourceLine();
                    }
                    processWrapChunkSpans(MetricsContext, mctx, chunk);
                    mctx.current_line_chunk_idx += 1;
                    mctx.current_line_width_cols += chunk.width;
                } else if (seg.isBreak()) {
                    mctx.saw_break = true;
                    mctx.finishCurrentSourceLine(true, seg_idx);
                }

                mctx.current_seg_idx = seg_idx + 1;
                return .{};
            }
        };

        const rope = text_buffer.rope();
        if (anchor.seg_start < rope.count()) {
            var walk_ctx = WalkContext{ .metrics = &ctx, .start_seg_idx = anchor.seg_start };
            rope.walk_from(anchor.seg_start, &walk_ctx, WalkContext.walker) catch {};
        }

        const has_content_after_break = ctx.current_line_seg_start < ctx.current_seg_idx;
        if (has_content_after_break or ctx.saw_break) {
            ctx.finishCurrentSourceLine(false, ctx.current_seg_idx);
        }

        return .{
            .result = .{ .line_count = ctx.line_count, .width_cols_max = ctx.width_cols_max },
            .tail_anchor = ctx.last_tail_anchor,
        };
    }

    /// Measure dimensions for given width/height WITHOUT modifying virtual lines cache
    /// This is useful for Yoga measure functions that need to know dimensions without committing changes
    /// Special case: width=0 or wrap_mode=.none means "measure intrinsic/max-content width" (no wrapping)
    pub fn measureForDimensions(self: *Self, width: u32, height: u32) TextBufferViewError!MeasureResult {
        _ = height; // Height is for future use, currently only width affects layout
        const epoch = self.text_buffer.getContentEpoch();

        if (self.cached_measure_result) |result| {
            if (self.cached_measure_epoch == epoch and self.cached_measure_buffer == self.text_buffer) {
                if (self.cached_measure_width) |cached_width| {
                    if (cached_width == width and self.cached_measure_wrap_mode == self.wrap_mode) {
                        return result;
                    }
                }
            }
        }

        // No-wrap path avoids allocations by using marker-based line widths.
        if (width == 0 or self.wrap_mode == .none) {
            const line_count = self.text_buffer.lineCount();
            var width_cols_max: u32 = 0;
            var row: u32 = 0;
            while (row < line_count) : (row += 1) {
                width_cols_max = @max(width_cols_max, self.text_buffer.lineWidthAt(row));
            }

            const result = MeasureResult{
                .line_count = line_count,
                .width_cols_max = width_cols_max,
            };

            self.cached_measure_width = width;
            self.cached_measure_wrap_mode = self.wrap_mode;
            self.cached_measure_result = result;
            self.cached_measure_epoch = epoch;
            self.cached_measure_buffer = self.text_buffer;
            self.cached_measure_tail_anchor = null;

            return result;
        }

        _ = self.measure_arena.reset(.retain_capacity);
        const wrap_width_for_measure = if (self.wrap_mode != .none and width > 0) width else 0;

        if (self.cached_measure_tail_anchor) |prev_anchor| {
            if (self.cached_measure_buffer == self.text_buffer and
                self.cached_measure_wrap_mode == self.wrap_mode and
                self.cached_measure_width != null and
                self.cached_measure_width.? == width and
                self.cached_measure_epoch +% 1 == epoch)
            {
                if (self.text_buffer.getAppendAnchorForEpoch(epoch)) |append_anchor| {
                    if (append_anchor.line_idx == prev_anchor.line_idx and append_anchor.seg_start == prev_anchor.seg_start) {
                        const rope = self.text_buffer.rope();
                        if (append_anchor.seg_start < rope.count()) {
                            const incremental = measureWrappedSpanStateMachineFromAnchor(
                                self.text_buffer,
                                self.wrap_mode,
                                wrap_width_for_measure,
                                prev_anchor,
                            );
                            const result = incremental.result;

                            self.cached_measure_width = width;
                            self.cached_measure_wrap_mode = self.wrap_mode;
                            self.cached_measure_result = result;
                            self.cached_measure_epoch = epoch;
                            self.cached_measure_buffer = self.text_buffer;
                            self.cached_measure_tail_anchor = incremental.tail_anchor;

                            return result;
                        }
                    }
                }
            }
        }

        const full = measureWrappedSpanStateMachine(
            self.text_buffer,
            self.wrap_mode,
            wrap_width_for_measure,
        );
        const result = full.result;

        self.cached_measure_width = width;
        self.cached_measure_wrap_mode = self.wrap_mode;
        self.cached_measure_result = result;
        self.cached_measure_epoch = epoch;
        self.cached_measure_buffer = self.text_buffer;
        self.cached_measure_tail_anchor = full.tail_anchor;

        return result;
    }

    /// Generic virtual line calculation that writes to provided output structures
    fn calculateVirtualLinesGeneric(
        text_buffer: *UnifiedTextBuffer,
        wrap_mode: WrapMode,
        wrap_width: ?u32,
        allocator: Allocator,
        output: VirtualLineOutput,
    ) void {
        const BreakByteResolver = struct {
            fn infer(buffer: *UnifiedTextBuffer, line_info: iter_mod.LineInfo) u32 {
                const rope = buffer.rope();
                if (line_info.seg_end >= rope.count()) {
                    return 0;
                }

                const break_seg = rope.get(line_info.seg_end) orelse return 0;
                if (!break_seg.isBreak()) {
                    return 0;
                }

                if (line_info.seg_end == 0) {
                    return 1;
                }

                const prev_seg = rope.get(line_info.seg_end - 1) orelse return 1;
                const chunk = prev_seg.asText() orelse return 1;
                const mem = buffer.memRegistry().get(chunk.mem_id) orelse return 1;
                const break_pos: usize = @intCast(chunk.byte_end);
                if (break_pos >= mem.len) {
                    return 1;
                }

                const b0 = mem[break_pos];
                if (b0 == '\r') {
                    if (break_pos + 1 < mem.len and mem[break_pos + 1] == '\n') {
                        return 2;
                    }
                    return 1;
                }

                return 1;
            }
        };

        if (wrap_mode == .none or wrap_width == null) {
            // No wrapping - create 1:1 mapping to real lines
            const Context = struct {
                text_buffer: *UnifiedTextBuffer,
                allocator: Allocator,
                output: VirtualLineOutput,
                current_vline: ?VirtualLine = null,
                global_byte_offset: u32 = 0,
                line_start_byte_offset: u32 = 0,

                fn segment_callback(ctx_ptr: *anyopaque, _: u32, chunk: *const TextChunk, _: u32) void {
                    const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_ptr)));

                    if (ctx.current_vline) |*vline| {
                        vline.chunks.append(ctx.allocator, VirtualChunk{
                            .grapheme_start = 0,
                            .width = chunk.width,
                            .byte_start = 0,
                            .byte_len = chunk.byte_end - chunk.byte_start,
                            .chunk = chunk,
                        }) catch {};
                    }

                    ctx.global_byte_offset += chunk.byte_end - chunk.byte_start;
                }

                fn line_end_callback(ctx_ptr: *anyopaque, line_info: iter_mod.LineInfo) void {
                    const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_ptr)));

                    const first_vline_idx: u32 = @intCast(ctx.output.virtual_lines.items.len);
                    ctx.output.cached_line_first_vline.append(ctx.allocator, first_vline_idx) catch {};
                    ctx.output.cached_line_vline_counts.append(ctx.allocator, 1) catch {};

                    var vline = if (ctx.current_vline) |v| v else VirtualLine.init();
                    vline.width_cols = line_info.width_cols;
                    vline.col_offset = line_info.col_offset;
                    vline.source_line = line_info.line_idx;
                    vline.source_col_offset = 0;

                    ctx.output.virtual_lines.append(ctx.allocator, vline) catch {};
                    ctx.output.cached_line_starts.append(ctx.allocator, ctx.line_start_byte_offset) catch {};
                    ctx.output.cached_line_widths.append(ctx.allocator, vline.width_cols) catch {};
                    ctx.output.cached_line_sources.append(ctx.allocator, @intCast(line_info.line_idx)) catch {};
                    ctx.output.cached_line_wrap_indices.append(ctx.allocator, 0) catch {};

                    ctx.current_vline = VirtualLine.init();
                    ctx.global_byte_offset += BreakByteResolver.infer(ctx.text_buffer, line_info);
                    ctx.line_start_byte_offset = ctx.global_byte_offset;
                }
            };

            var ctx = Context{
                .text_buffer = text_buffer,
                .allocator = allocator,
                .output = output,
                .current_vline = VirtualLine.init(),
            };

            text_buffer.walkLinesAndSegments(&ctx, Context.segment_callback, Context.line_end_callback);
        } else {
            const wrap_w = wrap_width.?;

            const WrapContext = struct {
                text_buffer: *UnifiedTextBuffer,
                allocator: Allocator,
                output: VirtualLineOutput,
                wrap_mode: WrapMode,
                wrap_w: u32,
                global_byte_offset: u32 = 0,
                global_col_offset: u32 = 0,
                line_start_byte_offset: u32 = 0,
                line_idx: u32 = 0,
                line_col_offset: u32 = 0,
                line_position: u32 = 0,
                current_vline: VirtualLine = VirtualLine.init(),
                current_line_first_vline_idx: u32 = 0,
                current_line_vline_count: u32 = 0,
                layout_scratch: tb.LayoutSpanScratch = .{},

                last_wrap_active: bool = false,
                last_wrap_chunk_idx: u32 = 0,
                last_wrap_chunk_byte_len: u32 = 0,
                last_wrap_chunk_width: u32 = 0,
                last_wrap_line_position: u32 = 0,
                last_wrap_global_col_offset: u32 = 0,
                last_wrap_global_byte_offset: u32 = 0,

                fn clearLastWrap(wctx: *@This()) void {
                    wctx.last_wrap_active = false;
                    wctx.last_wrap_chunk_idx = 0;
                    wctx.last_wrap_chunk_byte_len = 0;
                    wctx.last_wrap_chunk_width = 0;
                    wctx.last_wrap_line_position = 0;
                    wctx.last_wrap_global_col_offset = 0;
                    wctx.last_wrap_global_byte_offset = 0;
                }

                fn rememberLastWrap(wctx: *@This()) void {
                    if (wctx.current_vline.chunks.items.len == 0) {
                        wctx.clearLastWrap();
                        return;
                    }

                    const last_idx = wctx.current_vline.chunks.items.len - 1;
                    const last_chunk = wctx.current_vline.chunks.items[last_idx];

                    wctx.last_wrap_active = true;
                    wctx.last_wrap_chunk_idx = @intCast(last_idx);
                    wctx.last_wrap_chunk_byte_len = last_chunk.byte_len;
                    wctx.last_wrap_chunk_width = last_chunk.width;
                    wctx.last_wrap_line_position = wctx.line_position;
                    wctx.last_wrap_global_col_offset = wctx.global_col_offset;
                    wctx.last_wrap_global_byte_offset = wctx.global_byte_offset;
                }

                fn canExtendLastChunk(wctx: *@This(), chunk: *const TextChunk, span: utf8.GraphemeSpan) bool {
                    if (wctx.current_vline.chunks.items.len == 0) return false;

                    const last_idx = wctx.current_vline.chunks.items.len - 1;
                    const last_chunk = wctx.current_vline.chunks.items[last_idx];
                    if (last_chunk.chunk != chunk) return false;

                    return last_chunk.grapheme_start + last_chunk.width == span.col_start and
                        last_chunk.byte_start + last_chunk.byte_len == span.byte_start;
                }

                fn appendSpan(wctx: *@This(), chunk: *const TextChunk, span: utf8.GraphemeSpan, track_wrap_breaks: bool) void {
                    const span_width: u32 = span.col_width;
                    const span_byte_len: u32 = span.byte_len;

                    if (wctx.canExtendLastChunk(chunk, span)) {
                        const last_idx = wctx.current_vline.chunks.items.len - 1;
                        wctx.current_vline.chunks.items[last_idx].width += span_width;
                        wctx.current_vline.chunks.items[last_idx].byte_len += span_byte_len;
                    } else {
                        wctx.current_vline.chunks.append(wctx.allocator, VirtualChunk{
                            .grapheme_start = span.col_start,
                            .width = span_width,
                            .byte_start = span.byte_start,
                            .byte_len = span_byte_len,
                            .chunk = chunk,
                        }) catch {};
                    }

                    wctx.global_byte_offset += span_byte_len;
                    wctx.global_col_offset += span_width;
                    wctx.line_position += span_width;

                    if (track_wrap_breaks and span.break_after != .none) {
                        wctx.rememberLastWrap();
                    }
                }

                fn dropOverflowSpan(wctx: *@This(), span: utf8.GraphemeSpan) void {
                    wctx.global_byte_offset += span.byte_len;
                    wctx.global_col_offset += span.col_width;
                    wctx.line_col_offset += span.col_width;
                    wctx.line_start_byte_offset += span.byte_len;
                    wctx.current_vline.col_offset = wctx.global_col_offset;
                    wctx.clearLastWrap();
                }

                fn commitLine(wctx: *@This()) void {
                    wctx.current_vline.width_cols = wctx.line_position;
                    wctx.current_vline.source_line = wctx.line_idx;
                    wctx.current_vline.source_col_offset = wctx.line_col_offset;
                    wctx.output.virtual_lines.append(wctx.allocator, wctx.current_vline) catch {};
                    wctx.output.cached_line_starts.append(wctx.allocator, wctx.line_start_byte_offset) catch {};
                    wctx.output.cached_line_widths.append(wctx.allocator, wctx.current_vline.width_cols) catch {};
                    wctx.output.cached_line_sources.append(wctx.allocator, wctx.line_idx) catch {};
                    wctx.output.cached_line_wrap_indices.append(wctx.allocator, wctx.current_line_vline_count) catch {};

                    wctx.current_line_vline_count += 1;

                    wctx.line_col_offset += wctx.line_position;
                    wctx.line_start_byte_offset = wctx.global_byte_offset;
                    wctx.current_vline = VirtualLine.init();
                    wctx.current_vline.col_offset = wctx.global_col_offset;
                    wctx.line_position = 0;

                    wctx.clearLastWrap();
                }

                fn rewindToLastWrap(wctx: *@This()) bool {
                    if (!wctx.last_wrap_active) {
                        return false;
                    }

                    const wrap_idx: usize = @intCast(wctx.last_wrap_chunk_idx);
                    if (wrap_idx >= wctx.current_vline.chunks.items.len) {
                        wctx.clearLastWrap();
                        return false;
                    }

                    const saved_byte_len = wctx.last_wrap_chunk_byte_len;
                    const saved_width = wctx.last_wrap_chunk_width;

                    var split_tail: ?VirtualChunk = null;
                    const wrap_chunk = wctx.current_vline.chunks.items[wrap_idx];
                    if (saved_byte_len < wrap_chunk.byte_len and saved_width < wrap_chunk.width) {
                        split_tail = .{
                            .chunk = wrap_chunk.chunk,
                            .grapheme_start = wrap_chunk.grapheme_start + saved_width,
                            .width = wrap_chunk.width - saved_width,
                            .byte_start = wrap_chunk.byte_start + saved_byte_len,
                            .byte_len = wrap_chunk.byte_len - saved_byte_len,
                        };
                    }

                    const suffix_chunks = wctx.current_vline.chunks.items[wrap_idx + 1 ..];

                    wctx.current_vline.chunks.items[wrap_idx].byte_len = saved_byte_len;
                    wctx.current_vline.chunks.items[wrap_idx].width = saved_width;
                    wctx.current_vline.chunks.items.len = wrap_idx + 1;

                    if (saved_byte_len == 0 or saved_width == 0) {
                        wctx.current_vline.chunks.items.len = wrap_idx;
                    }

                    wctx.line_position = wctx.last_wrap_line_position;
                    wctx.global_col_offset = wctx.last_wrap_global_col_offset;
                    wctx.global_byte_offset = wctx.last_wrap_global_byte_offset;

                    wctx.commitLine();

                    if (split_tail) |tail_chunk| {
                        wctx.current_vline.chunks.append(wctx.allocator, tail_chunk) catch {};
                        wctx.global_byte_offset += tail_chunk.byte_len;
                        wctx.global_col_offset += tail_chunk.width;
                        wctx.line_position += tail_chunk.width;
                    }

                    var moved_idx: usize = 0;
                    while (moved_idx < suffix_chunks.len) : (moved_idx += 1) {
                        const moved_chunk = suffix_chunks[moved_idx];

                        wctx.current_vline.chunks.append(wctx.allocator, moved_chunk) catch {};

                        wctx.global_byte_offset += moved_chunk.byte_len;
                        wctx.global_col_offset += moved_chunk.width;
                        wctx.line_position += moved_chunk.width;
                    }

                    return true;
                }

                fn segment_callback(ctx_ptr: *anyopaque, _: u32, chunk: *const TextChunk, _: u32) void {
                    const wctx = @as(*@This(), @ptrCast(@alignCast(ctx_ptr)));
                    const chunk_bytes = chunk.getBytes(wctx.text_buffer.memRegistry());
                    var cursor = utf8.LayoutScanCursor.init();

                    const base_width_method = wctx.text_buffer.widthMethod();
                    const word_width_method = layoutWidthMethodForSpanWrap(base_width_method);

                    wctx.layout_scratch.reset();

                    while (true) {
                        const slot = wctx.layout_scratch.acquire();
                        const batch = if (wctx.wrap_mode == .char)
                            utf8.scanLayoutNextWindowBatchNoBreaks(
                                chunk_bytes,
                                wctx.text_buffer.tabWidth(),
                                chunk.isAsciiOnly(),
                                base_width_method,
                                &cursor,
                                slot.spans,
                                seg_mod.LAYOUT_WINDOW_BYTES,
                            ) catch break
                        else
                            utf8.scanLayoutNextWindowBatch(
                                chunk_bytes,
                                wctx.text_buffer.tabWidth(),
                                chunk.isAsciiOnly(),
                                word_width_method,
                                &cursor,
                                slot.spans,
                                seg_mod.LAYOUT_WINDOW_BYTES,
                            ) catch break;

                        if (wctx.wrap_mode == .char) {
                            runCharWrapSpans(@This(), wctx, chunk, batch.spans);
                        } else {
                            runWordWrapSpans(@This(), wctx, chunk, batch.spans);
                        }

                        if (batch.done) break;
                    }
                }

                fn line_end_callback(ctx_ptr: *anyopaque, line_info: iter_mod.LineInfo) void {
                    const wctx = @as(*@This(), @ptrCast(@alignCast(ctx_ptr)));

                    if (wctx.current_vline.chunks.items.len > 0 or line_info.width_cols == 0) {
                        wctx.commitLine();
                    }

                    wctx.output.cached_line_first_vline.append(wctx.allocator, wctx.current_line_first_vline_idx) catch {};
                    wctx.output.cached_line_vline_counts.append(wctx.allocator, wctx.current_line_vline_count) catch {};

                    wctx.global_col_offset += 1;
                    wctx.global_byte_offset += BreakByteResolver.infer(wctx.text_buffer, line_info);

                    wctx.line_idx += 1;
                    wctx.line_col_offset = 0;
                    wctx.line_position = 0;
                    wctx.line_start_byte_offset = wctx.global_byte_offset;
                    wctx.current_vline = VirtualLine.init();
                    wctx.current_vline.col_offset = wctx.global_col_offset;
                    wctx.current_line_first_vline_idx = @intCast(wctx.output.virtual_lines.items.len);
                    wctx.current_line_vline_count = 0;

                    wctx.clearLastWrap();
                }
            };

            var wrap_ctx = WrapContext{
                .text_buffer = text_buffer,
                .allocator = allocator,
                .output = output,
                .wrap_mode = wrap_mode,
                .wrap_w = wrap_w,
            };

            text_buffer.walkLinesAndSegments(&wrap_ctx, WrapContext.segment_callback, WrapContext.line_end_callback);
        }
    }
};
