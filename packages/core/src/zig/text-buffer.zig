const std = @import("std");
const Allocator = std.mem.Allocator;
const seg_mod = @import("text-buffer-segment.zig");
const iter_mod = @import("text-buffer-iterators.zig");
const mem_registry_mod = @import("mem-registry.zig");
const highlight_mod = @import("text-buffer-highlights.zig");
const shared = @import("text-buffer-shared.zig");
const ss = @import("syntax-style.zig");
const gp = @import("grapheme.zig");

const utf8 = @import("utf8.zig");

const logger = @import("logger.zig");

const Segment = seg_mod.Segment;
const UnifiedRope = seg_mod.UnifiedRope;
const LineInfo = iter_mod.LineInfo;

// Re-export types from segment module
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

pub const SyntaxStyle = ss.SyntaxStyle;

pub const TextBuffer = UnifiedTextBuffer;

pub const StyledChunk = shared.StyledChunk;

pub const UnifiedTextBuffer = struct {
    const Self = @This();

    mem_registry: MemRegistry,
    default_fg: ?RGBA,
    default_bg: ?RGBA,
    default_attributes: ?u32,

    arena_allocator: Allocator,
    global_allocator: Allocator,
    arena: *std.heap.ArenaAllocator,

    rope: UnifiedRope,
    syntax_style: ?*const SyntaxStyle,

    pool: *gp.GraphemePool,

    width_method: utf8.WidthMethod,

    view_registry: shared.ViewRegistry,
    highlights: highlight_mod.HighlightRegistry,

    styled_text_mem_id: ?u8,
    styled_buffer: ?[]u8,
    styled_capacity: usize,

    tab_width: u8,

    pub fn init(
        global_allocator: Allocator,
        pool: *gp.GraphemePool,
        width_method: utf8.WidthMethod,
    ) TextBufferError!*Self {
        const self = global_allocator.create(Self) catch return TextBufferError.OutOfMemory;
        errdefer global_allocator.destroy(self);

        const internal_arena = global_allocator.create(std.heap.ArenaAllocator) catch return TextBufferError.OutOfMemory;
        errdefer global_allocator.destroy(internal_arena);
        internal_arena.* = std.heap.ArenaAllocator.init(global_allocator);

        const internal_allocator = internal_arena.allocator();

        const rope = UnifiedRope.init(internal_allocator) catch return TextBufferError.OutOfMemory;

        var mem_registry = MemRegistry.init(global_allocator);
        errdefer mem_registry.deinit();

        var view_registry = shared.ViewRegistry{};
        errdefer view_registry.deinit(global_allocator);

        var highlights = highlight_mod.HighlightRegistry.init(global_allocator);
        errdefer highlights.deinit();

        self.* = .{
            .mem_registry = mem_registry,
            .default_fg = null,
            .default_bg = null,
            .default_attributes = null,
            .arena_allocator = internal_allocator,
            .global_allocator = global_allocator,
            .arena = internal_arena,
            .rope = rope,
            .syntax_style = null,
            .pool = pool,
            .width_method = width_method,
            .view_registry = view_registry,
            .highlights = highlights,
            .styled_text_mem_id = null,
            .styled_buffer = null,
            .styled_capacity = 0,
            .tab_width = 2,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.syntax_style) |style| {
            (@constCast(style)).offDestroy(@ptrCast(self), onSyntaxStyleDestroyed);
        }

        self.view_registry.deinit(self.global_allocator);
        self.highlights.deinit();

        // Free persistent styled text buffer
        if (self.styled_buffer) |buf| {
            self.global_allocator.free(buf);
        }

        self.mem_registry.deinit();
        self.arena.deinit();
        self.global_allocator.destroy(self.arena);
        self.global_allocator.destroy(self);
    }

    pub const Defaults = struct {
        fg: ?RGBA,
        bg: ?RGBA,
        attributes: ?u32,
    };

    pub fn defaults(self: *const Self) Defaults {
        return .{
            .fg = self.default_fg,
            .bg = self.default_bg,
            .attributes = self.default_attributes,
        };
    }

    pub fn memRegistry(self: *const Self) *const MemRegistry {
        return &self.mem_registry;
    }

    pub fn allocator(self: *const Self) Allocator {
        return self.arena_allocator;
    }

    pub fn widthMethod(self: *const Self) utf8.WidthMethod {
        return self.width_method;
    }

    pub fn maxLineWidth(self: *const Self) u32 {
        return iter_mod.getMaxLineWidth(&self.rope);
    }

    pub fn lineWidthAt(self: *Self, row: u32) u32 {
        return iter_mod.lineWidthAt(&self.rope, row);
    }

    pub fn walkLinesAndSegments(
        self: *const Self,
        ctx: *anyopaque,
        segment_callback: *const fn (ctx: *anyopaque, line_idx: u32, chunk: *const TextChunk, chunk_idx_in_line: u32) void,
        line_end_callback: *const fn (ctx: *anyopaque, line_info: iter_mod.LineInfo) void,
    ) void {
        iter_mod.walkLinesAndSegments(&self.rope, ctx, segment_callback, line_end_callback);
    }

    // View registration (same as original)
    pub fn registerView(self: *Self) TextBufferError!u32 {
        return self.view_registry.registerView(self.global_allocator);
    }

    pub fn unregisterView(self: *Self, view_id: u32) void {
        self.view_registry.unregisterView(self.global_allocator, view_id);
    }

    pub fn isViewDirty(self: *const Self, view_id: u32) bool {
        return self.view_registry.isViewDirty(view_id);
    }

    pub fn clearViewDirty(self: *Self, view_id: u32) void {
        self.view_registry.clearViewDirty(view_id);
    }

    /// Returns the current content epoch. Use this to detect buffer changes
    /// independent of the dirty flag (other code paths may clear dirty).
    pub fn getContentEpoch(self: *const Self) u64 {
        return self.view_registry.getContentEpoch();
    }

    fn markAllViewsDirty(self: *Self) void {
        // Increment epoch first so views see the new value when checking caches.
        // Use wrapping add for safety, though u64 won't overflow in practice.
        self.view_registry.markAllViewsDirty();
    }

    pub fn markViewsDirty(self: *Self) void {
        self.markAllViewsDirty();
    }

    // Basic queries using unified rope
    pub fn getLength(self: *const Self) u32 {
        const metrics = self.rope.root.metrics();
        return metrics.custom.total_width;
    }

    pub fn getByteSize(self: *const Self) u32 {
        const metrics = self.rope.root.metrics();
        const total_bytes = metrics.custom.total_bytes;

        // Add newlines between lines (line_count - 1)
        const line_count = iter_mod.getLineCount(&self.rope);
        if (line_count > 0) {
            return total_bytes + (line_count - 1); // newlines
        }
        return total_bytes;
    }

    pub fn measureText(self: *const Self, text: []const u8) u32 {
        // For grapheme-accurate width calculation (used by highlighting system),
        // use utf8.calculateTextWidth which properly handles grapheme clusters
        return shared.measureText(self.width_method, self.tab_width, text);
    }

    /// Clear the text content without resetting arena or memory registry.
    /// Preserves highlights, memory buffers, and arena allocations.
    /// Use this for frequent text updates where undo/redo history should be preserved.
    pub fn clear(self: *Self) void {
        self.rope.clear();
        self.markAllViewsDirty();
    }

    pub fn reset(self: *Self) void {
        // Free highlight/span arrays (they use global_allocator, not arena)
        self.highlights.clearRetainingCapacity();

        // Free persistent styled text buffer
        if (self.styled_buffer) |buf| {
            self.global_allocator.free(buf);
        }
        self.styled_buffer = null;
        self.styled_text_mem_id = null;
        self.styled_capacity = 0;

        // Now reset the arena (frees all the internal memory)
        _ = self.arena.reset(if (self.arena.queryCapacity() > 0) .retain_capacity else .free_all);

        self.mem_registry.clear();

        self.rope = UnifiedRope.init(self.arena_allocator) catch return;

        self.markAllViewsDirty();
    }

    // Default colors/attributes
    pub fn setDefaultFg(self: *Self, fg: ?RGBA) void {
        self.default_fg = fg;
    }

    pub fn setDefaultBg(self: *Self, bg: ?RGBA) void {
        self.default_bg = bg;
    }

    pub fn setDefaultAttributes(self: *Self, attributes: ?u32) void {
        self.default_attributes = attributes;
    }

    pub fn resetDefaults(self: *Self) void {
        self.default_fg = null;
        self.default_bg = null;
        self.default_attributes = null;
    }

    fn onSyntaxStyleDestroyed(ctx_ptr: *anyopaque) void {
        const self = @as(*Self, @ptrCast(@alignCast(ctx_ptr)));
        self.syntax_style = null;
    }

    pub fn setSyntaxStyle(self: *Self, syntax_style: ?*const SyntaxStyle) void {
        if (self.syntax_style) |prev| {
            (@constCast(prev)).offDestroy(@ptrCast(self), onSyntaxStyleDestroyed);
        }
        self.syntax_style = syntax_style;
        if (syntax_style) |style| {
            _ = (@constCast(style)).onDestroy(@ptrCast(self), onSyntaxStyleDestroyed) catch {};
        }
    }

    pub fn getSyntaxStyle(self: *const Self) ?*const SyntaxStyle {
        return self.syntax_style;
    }

    /// Set the text content using SIMD-optimized line break detection
    pub fn setText(self: *Self, text: []const u8) TextBufferError!void {
        self.clear();
        const mem_id = try self.mem_registry.register(text, false);
        try self.setTextInternal(mem_id, text);
    }

    /// Set text from a pre-registered memory ID
    pub fn setTextFromMemId(self: *Self, mem_id: u8) TextBufferError!void {
        const text = self.mem_registry.get(mem_id) orelse return TextBufferError.InvalidMemId;
        self.clear();
        try self.setTextInternal(mem_id, text);
    }

    /// Append text to the end of the buffer without clearing
    pub fn append(self: *Self, text: []const u8) TextBufferError!void {
        if (text.len == 0) {
            return;
        }

        const mem_id = try self.mem_registry.register(text, false);
        try self.appendInternal(mem_id, text);
    }

    /// Append text from a pre-registered memory ID
    pub fn appendFromMemId(self: *Self, mem_id: u8) TextBufferError!void {
        const text = self.mem_registry.get(mem_id) orelse return TextBufferError.InvalidMemId;
        try self.appendInternal(mem_id, text);
    }

    /// Internal append that doesn't register memory
    fn appendInternal(self: *Self, mem_id: u8, text: []const u8) TextBufferError!void {
        if (text.len == 0) {
            return;
        }

        // The rope's boundary rewrite will handle normalization at join points
        var result = try self.textToSegments(self.global_allocator, text, mem_id, 0, false);
        defer result.segments.deinit(result.allocator);

        const insert_pos = self.rope.count();
        try self.rope.insert_slice(insert_pos, result.segments.items);

        self.markAllViewsDirty();
    }

    /// Internal setText that doesn't call clear (for use by setStyledText)
    fn setTextInternal(self: *Self, mem_id: u8, text: []const u8) TextBufferError!void {
        if (text.len == 0) {
            self.markAllViewsDirty();
            return;
        }

        var result = try self.textToSegments(self.global_allocator, text, mem_id, 0, true);
        defer result.segments.deinit(result.allocator);

        try self.rope.setSegments(result.segments.items);

        self.markAllViewsDirty();
    }

    /// Create a TextChunk from a memory buffer range
    pub fn createChunk(
        self: *const Self,
        mem_id: u8,
        byte_start: u32,
        byte_end: u32,
    ) TextChunk {
        return shared.createChunk(&self.mem_registry, self.tab_width, self.width_method, mem_id, byte_start, byte_end);
    }

    /// Convert text to segments with line breaks
    /// Returns segments array and total width
    pub fn textToSegments(
        self: *const Self,
        alloc: Allocator,
        text: []const u8,
        mem_id: u8,
        byte_offset: u32,
        prepend_linestart: bool,
    ) TextBufferError!struct { segments: std.ArrayListUnmanaged(Segment), total_width: u32, allocator: Allocator } {
        var break_result = utf8.LineBreakResult.init(alloc);
        defer break_result.deinit();
        try utf8.findLineBreaks(text, &break_result);

        var segments: std.ArrayListUnmanaged(Segment) = .{};
        errdefer segments.deinit(alloc);

        if (prepend_linestart) {
            try segments.append(alloc, Segment{ .linestart = {} });
        }

        var local_start: u32 = 0;
        var total_width: u32 = 0;

        for (break_result.breaks.items) |line_break| {
            const break_pos: u32 = @intCast(line_break.pos);
            const local_end: u32 = switch (line_break.kind) {
                .CRLF => break_pos - 1,
                .CR, .LF => break_pos,
            };

            if (local_end > local_start) {
                const chunk = self.createChunk(mem_id, byte_offset + local_start, byte_offset + local_end);
                try segments.append(alloc, Segment{ .text = chunk });
                total_width += chunk.width;
            }

            try segments.append(alloc, Segment{ .brk = {} });
            try segments.append(alloc, Segment{ .linestart = {} });

            local_start = break_pos + 1;
        }

        if (local_start < text.len) {
            const chunk = self.createChunk(mem_id, byte_offset + local_start, byte_offset + @as(u32, @intCast(text.len)));
            try segments.append(alloc, Segment{ .text = chunk });
            total_width += chunk.width;
        }

        return .{ .segments = segments, .total_width = total_width, .allocator = alloc };
    }

    pub fn getLineCount(self: *const Self) u32 {
        const count = self.rope.count();
        if (count == 0) return 0; // Truly empty (after reset)
        return iter_mod.getLineCount(&self.rope);
    }

    pub fn lineCount(self: *const Self) u32 {
        return self.getLineCount();
    }

    /// Register a memory buffer
    pub fn registerMemBuffer(self: *Self, data: []const u8, owned: bool) TextBufferError!u8 {
        return try self.mem_registry.register(data, owned);
    }

    pub fn getMemBuffer(self: *const Self, mem_id: u8) ?[]const u8 {
        return self.mem_registry.get(mem_id);
    }

    /// Add a line from a memory buffer (for compatibility with old API)
    /// Note: This is not as efficient as setText for bulk operations
    /// Adds text segment with a break separator before it (if not the first line)
    pub fn addLine(
        self: *Self,
        mem_id: u8,
        byte_start: u32,
        byte_end: u32,
    ) TextBufferError!void {
        _ = self.mem_registry.get(mem_id) orelse return TextBufferError.InvalidMemId;

        const chunk = self.createChunk(mem_id, byte_start, byte_end);

        const had_content = self.rope.count() > 1;

        if (had_content) {
            try self.rope.append(Segment{ .brk = {} });
            try self.rope.append(Segment{ .linestart = {} });
        }

        try self.rope.append(Segment{ .text = chunk });

        self.markAllViewsDirty();
    }

    pub fn getArenaAllocatedBytes(self: *const Self) usize {
        return self.arena.queryCapacity();
    }

    /// Extract all text as UTF-8 bytes into provided output buffer
    pub fn getPlainTextIntoBuffer(self: *const Self, out_buffer: []u8) usize {
        var out_index: usize = 0;

        const line_count = self.getLineCount();

        const Context = struct {
            buffer: *const UnifiedTextBuffer,
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
                // Add newline between lines (not after last line)
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
        iter_mod.walkLinesAndSegments(&self.rope, &ctx, Context.segmentCallback, Context.lineEndCallback);

        return out_index;
    }

    fn lineWidthForHighlights(ctx_ptr: *anyopaque, line_idx: usize) u32 {
        const self = @as(*Self, @ptrCast(@alignCast(ctx_ptr)));
        return iter_mod.lineWidthAt(&self.rope, @intCast(line_idx));
    }

    pub fn startHighlightsTransaction(self: *Self) void {
        self.highlights.startTransaction();
    }

    pub fn endHighlightsTransaction(self: *Self) void {
        self.highlights.endTransaction(self, lineWidthForHighlights);
    }

    // Highlight system
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
        if (line_idx >= line_count) {
            return TextBufferError.InvalidIndex;
        }

        if (col_start >= col_end) {
            return; // Empty range
        }

        const hl = Highlight{
            .col_start = col_start,
            .col_end = col_end,
            .style_id = style_id,
            .priority = priority,
            .hl_ref = hl_ref,
        };

        try self.highlights.addHighlight(self, lineWidthForHighlights, line_idx, hl);
    }

    pub fn getLineHighlights(self: *const Self, line_idx: usize) []const Highlight {
        return self.highlights.getLineHighlights(line_idx);
    }

    pub fn getLineSpans(self: *Self, line_idx: usize) []const StyleSpan {
        return self.highlights.getLineSpans(self, lineWidthForHighlights, line_idx);
    }

    /// Add highlight by row/col coordinates
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
        const char_start = iter_mod.coordsToOffset(&self.rope, start_row, start_col) orelse return TextBufferError.InvalidIndex;
        const char_end = iter_mod.coordsToOffset(&self.rope, end_row, end_col) orelse return TextBufferError.InvalidIndex;
        return self.addHighlightByCharRange(char_start, char_end, style_id, priority, hl_ref);
    }

    /// Add highlight by character range
    pub fn addHighlightByCharRange(
        self: *Self,
        char_start: u32,
        char_end: u32,
        style_id: u32,
        priority: u8,
        hl_ref: u16,
    ) TextBufferError!void {
        const line_count = self.getLineCount();
        if (char_start >= char_end or line_count == 0) {
            return;
        }

        // Walk lines to find which lines this highlight affects
        const Context = struct {
            buffer: *Self,
            char_start: u32,
            char_end: u32,
            style_id: u32,
            priority: u8,
            hl_ref: u16,
            start_line_idx: ?usize = null,

            fn callback(ctx_ptr: *anyopaque, line_info: LineInfo) void {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_ptr)));
                const line_start_char = line_info.char_offset;
                const line_end_char = line_info.char_offset + line_info.width;

                // Skip lines before the highlight
                if (line_end_char <= ctx.char_start) return;
                // Stop after the highlight ends
                if (line_start_char >= ctx.char_end) return;

                // This line overlaps with the highlight
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
            .char_end = char_end,
            .style_id = style_id,
            .priority = priority,
            .hl_ref = hl_ref,
        };
        iter_mod.walkLines(&self.rope, &ctx, Context.callback, false);
    }

    /// Remove all highlights with a specific reference ID
    pub fn removeHighlightsByRef(self: *Self, hl_ref: u16) void {
        self.highlights.removeHighlightsByRef(self, lineWidthForHighlights, hl_ref);
    }

    /// Clear all highlights from a specific line
    pub fn clearLineHighlights(self: *Self, line_idx: usize) void {
        self.highlights.clearLineHighlights(line_idx);
    }

    /// Clear all highlights
    pub fn clearAllHighlights(self: *Self) void {
        self.highlights.clearAllHighlights();
    }

    /// Get highlights for a specific line
    pub fn getLineHighlightsSlice(self: *const Self, line_idx: usize) []const Highlight {
        return self.highlights.getLineHighlights(line_idx);
    }

    /// Get total number of highlights across all lines
    pub fn getHighlightCount(self: *const Self) u32 {
        return self.highlights.getHighlightCount();
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

    /// Set styled text from chunks with individual styling
    /// Accepts StyledChunk array for FFI compatibility
    /// TODO: This is for backward compatibility, there should be a better way to do this.
    pub fn setStyledText(
        self: *Self,
        chunks: []const StyledChunk,
    ) TextBufferError!void {
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

        self.clear();
        self.clearAllHighlights();

        _ = self.arena.reset(.retain_capacity);

        self.rope = UnifiedRope.init(self.arena_allocator) catch return TextBufferError.OutOfMemory;

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

    /// Load text from a file path (relative to cwd)
    /// The file content is allocated in the arena and will be freed when the buffer is destroyed
    pub fn loadFile(self: *Self, path: []const u8) TextBufferError!void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => TextBufferError.InvalidIndex,
                error.AccessDenied => TextBufferError.InvalidIndex,
                else => TextBufferError.OutOfMemory,
            };
        };
        defer file.close();

        const file_size = file.getEndPos() catch return TextBufferError.OutOfMemory;

        self.clear();

        const content = self.arena_allocator.alloc(u8, file_size) catch return TextBufferError.OutOfMemory;
        const bytes_read = file.readAll(content) catch return TextBufferError.OutOfMemory;
        const text = content[0..bytes_read];
        const mem_id = try self.mem_registry.register(text, false);

        try self.setTextInternal(mem_id, text);
    }

    pub fn tabWidth(self: *const Self) u8 {
        return self.tab_width;
    }

    /// Set tab width, rounding up to nearest multiple of 2 (minimum 2).
    /// Marks all views dirty if the width actually changes, since tab width
    /// affects measured line widths and virtual line calculations.
    pub fn setTabWidth(self: *Self, width: u8) void {
        const clamped_width = @max(2, width);
        const new_width = if (clamped_width % 2 == 0) clamped_width else clamped_width + 1;
        if (self.tab_width == new_width) return;
        self.tab_width = new_width;
        self.markAllViewsDirty();
    }

    /// Debug log the rope structure using rope.toText
    pub fn debugLogRope(self: *const Self) void {
        logger.debug("=== TextBuffer Rope Debug ===", .{});
        logger.debug("Line count: {}", .{self.getLineCount()});
        logger.debug("Char count: {}", .{self.getLength()});
        logger.debug("Byte size: {}", .{self.getByteSize()});

        const rope_text = self.rope.toText(self.arena_allocator) catch {
            logger.debug("Failed to generate rope text representation", .{});
            return;
        };
        logger.debug("Rope structure: {s}", .{rope_text});
        logger.debug("=== End Rope Debug ===", .{});
    }

    /// Get text within a range of display-width offsets
    /// Automatically snaps to grapheme boundaries:
    /// Returns number of bytes written to out_buffer
    pub fn getTextRange(self: *const Self, start_offset: u32, end_offset: u32, out_buffer: []u8) usize {
        if (start_offset >= end_offset) return 0;
        if (out_buffer.len == 0) return 0;

        const total_weight = self.rope.totalWeight();
        if (start_offset >= total_weight) return 0;

        const clamped_end = @min(end_offset, total_weight);

        return iter_mod.extractTextBetweenOffsets(
            &self.rope,
            &self.mem_registry,
            self.tab_width,
            start_offset,
            clamped_end,
            out_buffer,
            self.width_method,
        );
    }

    /// Get text within a range specified by row/col coordinates
    /// Automatically snaps to grapheme boundaries:
    /// Returns number of bytes written to out_buffer
    pub fn getTextRangeByCoords(self: *Self, start_row: u32, start_col: u32, end_row: u32, end_col: u32, out_buffer: []u8) usize {
        const start_offset = iter_mod.coordsToOffset(&self.rope, start_row, start_col) orelse return 0;
        const end_offset = iter_mod.coordsToOffset(&self.rope, end_row, end_col) orelse return 0;
        return self.getTextRange(start_offset, end_offset, out_buffer);
    }
};
