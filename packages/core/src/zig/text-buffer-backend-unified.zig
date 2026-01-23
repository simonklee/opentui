const std = @import("std");
const Allocator = std.mem.Allocator;
const seg_mod = @import("text-buffer-segment.zig");
const iter_mod = @import("text-buffer-iterators.zig");
const mem_registry_mod = @import("mem-registry.zig");
const shared = @import("text-buffer-shared.zig");
const utf8 = @import("utf8.zig");
const logger = @import("logger.zig");

const Segment = seg_mod.Segment;
const UnifiedRope = seg_mod.UnifiedRope;
const TextChunk = seg_mod.TextChunk;
const TextBufferError = seg_mod.TextBufferError;
const MemRegistry = mem_registry_mod.MemRegistry;
const LineInfo = iter_mod.LineInfo;

pub const SegmentsResult = struct {
    segments: std.ArrayListUnmanaged(Segment),
    total_width: u32,
    allocator: Allocator,
};

pub const UnifiedBackend = struct {
    const Self = @This();

    arena_allocator: Allocator,
    global_allocator: Allocator,
    arena: *std.heap.ArenaAllocator,
    rope: UnifiedRope,
    width_method: utf8.WidthMethod,
    tab_width: u8,

    pub fn init(global_allocator: Allocator, width_method: utf8.WidthMethod) TextBufferError!Self {
        const internal_arena = global_allocator.create(std.heap.ArenaAllocator) catch return TextBufferError.OutOfMemory;
        errdefer global_allocator.destroy(internal_arena);
        internal_arena.* = std.heap.ArenaAllocator.init(global_allocator);

        const internal_allocator = internal_arena.allocator();
        const rope = UnifiedRope.init(internal_allocator) catch return TextBufferError.OutOfMemory;

        return .{
            .arena_allocator = internal_allocator,
            .global_allocator = global_allocator,
            .arena = internal_arena,
            .rope = rope,
            .width_method = width_method,
            .tab_width = 2,
        };
    }

    pub fn deinit(self: *Self, _: Allocator) void {
        self.arena.deinit();
        self.global_allocator.destroy(self.arena);
    }

    pub fn allocator(self: *const Self) Allocator {
        return self.arena_allocator;
    }

    pub fn setTabWidth(self: *Self, width: u8) bool {
        const clamped_width = @max(2, width);
        const new_width = if (clamped_width % 2 == 0) clamped_width else clamped_width + 1;
        if (self.tab_width == new_width) return false;
        self.tab_width = new_width;
        return true;
    }

    pub fn tabWidth(self: *const Self) u8 {
        return self.tab_width;
    }

    pub fn clear(self: *Self) void {
        self.rope.clear();
    }

    pub fn reset(self: *Self) void {
        _ = self.arena.reset(if (self.arena.queryCapacity() > 0) .retain_capacity else .free_all);
        self.rope = UnifiedRope.init(self.arena_allocator) catch return;
    }

    pub fn getLength(self: *const Self) u32 {
        const metrics = self.rope.root.metrics();
        return metrics.custom.total_width;
    }

    pub fn getByteSize(self: *const Self) u32 {
        const metrics = self.rope.root.metrics();
        const total_bytes = metrics.custom.total_bytes;

        const line_count = iter_mod.getLineCount(&self.rope);
        if (line_count > 0) {
            return total_bytes + (line_count - 1);
        }
        return total_bytes;
    }

    pub fn getLineCount(self: *const Self) u32 {
        const count = self.rope.count();
        if (count == 0) return 0;
        return iter_mod.getLineCount(&self.rope);
    }

    pub fn lineWidthAt(self: *const Self, row: u32) u32 {
        return iter_mod.lineWidthAt(@constCast(&self.rope), row);
    }

    pub fn maxLineWidth(self: *const Self) u32 {
        return iter_mod.getMaxLineWidth(&self.rope);
    }

    pub fn walkLinesAndSegments(
        self: *const Self,
        ctx: *anyopaque,
        segment_callback: *const fn (ctx: *anyopaque, line_idx: u32, chunk: *const TextChunk, chunk_idx_in_line: u32) void,
        line_end_callback: *const fn (ctx: *anyopaque, line_info: LineInfo) void,
    ) void {
        iter_mod.walkLinesAndSegments(&self.rope, ctx, segment_callback, line_end_callback);
    }

    pub fn getPlainTextIntoBuffer(self: *const Self, mem_registry: *const MemRegistry, out_buffer: []u8) usize {
        var out_index: usize = 0;

        const line_count = self.getLineCount();

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
        iter_mod.walkLinesAndSegments(&self.rope, &ctx, Context.segmentCallback, Context.lineEndCallback);

        return out_index;
    }

    pub fn getTextRange(
        self: *const Self,
        mem_registry: *const MemRegistry,
        start_offset: u32,
        end_offset: u32,
        out_buffer: []u8,
    ) usize {
        if (start_offset >= end_offset) return 0;
        if (out_buffer.len == 0) return 0;

        const total_weight = self.rope.totalWeight();
        if (start_offset >= total_weight) return 0;

        const clamped_end = @min(end_offset, total_weight);

        return iter_mod.extractTextBetweenOffsets(
            &self.rope,
            mem_registry,
            self.tab_width,
            start_offset,
            clamped_end,
            out_buffer,
            self.width_method,
        );
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
        const start_offset = iter_mod.coordsToOffset(@constCast(&self.rope), start_row, start_col) orelse return 0;
        const end_offset = iter_mod.coordsToOffset(@constCast(&self.rope), end_row, end_col) orelse return 0;
        return self.getTextRange(mem_registry, start_offset, end_offset, out_buffer);
    }

    pub fn setTextFromMemId(self: *Self, mem_registry: *const MemRegistry, mem_id: u8) TextBufferError!void {
        const text = mem_registry.get(mem_id) orelse return TextBufferError.InvalidMemId;
        self.clear();
        try self.setTextInternal(mem_registry, mem_id, text);
    }

    pub fn appendFromMemId(self: *Self, mem_registry: *const MemRegistry, mem_id: u8) TextBufferError!void {
        const text = mem_registry.get(mem_id) orelse return TextBufferError.InvalidMemId;
        try self.appendInternal(mem_registry, mem_id, text);
    }

    fn appendInternal(self: *Self, mem_registry: *const MemRegistry, mem_id: u8, text: []const u8) TextBufferError!void {
        if (text.len == 0) {
            return;
        }

        var result = try self.textToSegments(self.global_allocator, mem_registry, text, mem_id, 0, false);
        defer result.segments.deinit(result.allocator);

        const insert_pos = self.rope.count();
        try self.rope.insert_slice(insert_pos, result.segments.items);
    }

    fn setTextInternal(self: *Self, mem_registry: *const MemRegistry, mem_id: u8, text: []const u8) TextBufferError!void {
        if (text.len == 0) {
            return;
        }

        var result = try self.textToSegments(self.global_allocator, mem_registry, text, mem_id, 0, true);
        defer result.segments.deinit(result.allocator);

        try self.rope.setSegments(result.segments.items);
    }

    fn createChunk(
        self: *const Self,
        mem_registry: *const MemRegistry,
        mem_id: u8,
        byte_start: u32,
        byte_end: u32,
    ) TextChunk {
        return shared.createChunk(mem_registry, self.tab_width, self.width_method, mem_id, byte_start, byte_end);
    }

    pub fn textToSegments(
        self: *const Self,
        alloc: Allocator,
        mem_registry: *const MemRegistry,
        text: []const u8,
        mem_id: u8,
        byte_offset: u32,
        prepend_linestart: bool,
    ) TextBufferError!SegmentsResult {
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
                const chunk = self.createChunk(mem_registry, mem_id, byte_offset + local_start, byte_offset + local_end);
                try segments.append(alloc, Segment{ .text = chunk });
                total_width += chunk.width;
            }

            try segments.append(alloc, Segment{ .brk = {} });
            try segments.append(alloc, Segment{ .linestart = {} });

            local_start = break_pos + 1;
        }

        if (local_start < text.len) {
            const chunk = self.createChunk(mem_registry, mem_id, byte_offset + local_start, byte_offset + @as(u32, @intCast(text.len)));
            try segments.append(alloc, Segment{ .text = chunk });
            total_width += chunk.width;
        }

        return .{ .segments = segments, .total_width = total_width, .allocator = alloc };
    }

    pub fn getArenaAllocatedBytes(self: *const Self) usize {
        return self.arena.queryCapacity();
    }

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
};
