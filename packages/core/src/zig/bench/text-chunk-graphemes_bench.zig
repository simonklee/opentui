const std = @import("std");
const bench_utils = @import("../bench-utils.zig");
const seg_mod = @import("../text-buffer-segment.zig");
const mem_registry_mod = @import("../mem-registry.zig");
const gp = @import("../grapheme.zig");

const TextChunk = seg_mod.TextChunk;
const MemRegistry = mem_registry_mod.MemRegistry;
const BenchResult = bench_utils.BenchResult;
const BenchStats = bench_utils.BenchStats;
const MemStat = bench_utils.MemStat;

pub const benchName = "TextChunk Layout Spans";

const TextType = enum { ascii, mixed, heavy_unicode };

const CountSpansContext = struct {
    count: usize = 0,
};

fn countSpans(ctx_ptr: *anyopaque, _: seg_mod.GraphemeSpan) anyerror!void {
    const ctx = @as(*CountSpansContext, @ptrCast(@alignCast(ctx_ptr)));
    ctx.count += 1;
}

fn textTypeLabel(text_type: TextType) []const u8 {
    return switch (text_type) {
        .ascii => "ASCII",
        .mixed => "Mixed",
        .heavy_unicode => "Heavy Unicode",
    };
}

fn layoutModeLabel(mode: seg_mod.LayoutCacheMode) []const u8 {
    return switch (mode) {
        .full_cache => "full_cache",
        .windowed => "windowed",
    };
}

fn generateTestText(allocator: std.mem.Allocator, size: usize, text_type: TextType) ![]u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    errdefer buffer.deinit(allocator);

    switch (text_type) {
        .ascii => {
            const patterns = [_][]const u8{
                "The quick brown fox jumps over the lazy dog. ",
                "Lorem ipsum dolor sit amet, consectetur elit. ",
                "function test() {\n\tconst x = 10;\n\treturn x;\n}\n",
                "Programming: Rust, Zig, Go, Python, JavaScript. ",
            };
            var pos: usize = 0;
            while (pos < size) {
                const pattern = patterns[pos % patterns.len];
                const to_add = @min(pattern.len, size - pos);
                try buffer.appendSlice(allocator, pattern[0..to_add]);
                pos += to_add;
            }
        },
        .mixed => {
            const patterns = [_][]const u8{
                "Hello, 世界! Unicode test. ",
                "Mixed: ASCII 中文 emoji 🌍 text. ",
                "Code: const x = 10; // comment\n",
                "Αυτό είναι ελληνικό. Это русский. ",
                "Numbers: 12345 symbols: !@#$% ",
                "\tTab\tseparated\tvalues\there. ",
            };
            var pos: usize = 0;
            while (pos < size) {
                const pattern = patterns[pos % patterns.len];
                const to_add = @min(pattern.len, size - pos);
                try buffer.appendSlice(allocator, pattern[0..to_add]);
                pos += to_add;
            }
        },
        .heavy_unicode => {
            const patterns = [_][]const u8{
                "世界中文字符測試文本。",
                "こんにちは、日本語テキスト。",
                "🌍🎉🚀🔥💻✨🌟⭐",
                "👋🏿👩‍🚀🇺🇸❤️",
                "café\u{0301} naïve résumé",
                "Ελληνικά Русский العربية",
            };
            var pos: usize = 0;
            while (pos < size) {
                const pattern = patterns[pos % patterns.len];
                const to_add = @min(pattern.len, size - pos);
                try buffer.appendSlice(allocator, pattern[0..to_add]);
                pos += to_add;
            }
        },
    }

    return try buffer.toOwnedSlice(allocator);
}

fn benchForEachLayoutSpans(
    allocator: std.mem.Allocator,
    size: usize,
    text_type: TextType,
    mode: seg_mod.LayoutCacheMode,
    iterations: usize,
    show_mem: bool,
) !BenchResult {
    const text = try generateTestText(allocator, size, text_type);
    defer allocator.free(text);

    var registry = MemRegistry.init(allocator);
    defer registry.deinit();

    const mem_id = try registry.register(text, false);
    const is_ascii = text_type == .ascii;
    const approx_width: u16 = @intCast(@min(text.len, std.math.maxInt(u16)));
    var chunk = TextChunk{
        .mem_id = mem_id,
        .byte_start = 0,
        .byte_end = @intCast(text.len),
        .width = approx_width,
        .flags = if (is_ascii) TextChunk.Flags.ASCII_ONLY else 0,
    };

    var stats = BenchStats{};
    var span_count: usize = 0;
    var final_mem: usize = 0;

    for (0..iterations) |i| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        chunk.layout_spans = null;
        chunk.layout_cache_allocator = null;
        chunk.layout_cache_valid = true;
        chunk.layout_cache_tab_width = 4;
        chunk.layout_cache_width_method = .unicode;
        chunk.layout_cache_mode = mode;

        var scratch = seg_mod.LayoutSpanScratch.init();
        var ctx = CountSpansContext{};

        var timer = try std.time.Timer.start();
        try chunk.forEachLayoutSpans(&registry, arena_alloc, 4, .unicode, &scratch, &ctx, countSpans);
        stats.record(timer.read());

        if (i == 0) {
            span_count = ctx.count;
        }

        if (i == iterations - 1 and show_mem) {
            final_mem = switch (mode) {
                .full_cache => if (chunk.layout_spans) |spans| spans.len * @sizeOf(seg_mod.GraphemeSpan) else 0,
                .windowed => @sizeOf(seg_mod.LayoutSpanScratch),
            };
        }
    }

    const name = try std.fmt.allocPrint(
        allocator,
        "forEachLayoutSpans {s} {s} ({d} bytes, {d} spans)",
        .{ layoutModeLabel(mode), textTypeLabel(text_type), size, span_count },
    );

    const mem_stats: ?[]const MemStat = if (show_mem) blk: {
        const stats_slice = try allocator.alloc(MemStat, 1);
        stats_slice[0] = .{
            .name = if (mode == .full_cache) "LayoutSpans" else "LayoutSpanScratch",
            .bytes = final_mem,
        };
        break :blk stats_slice;
    } else null;

    return BenchResult{
        .name = name,
        .min_ns = stats.min_ns,
        .avg_ns = stats.avg(),
        .max_ns = stats.max_ns,
        .total_ns = stats.total_ns,
        .iterations = iterations,
        .mem_stats = mem_stats,
    };
}

fn computeBenchName(
    allocator: std.mem.Allocator,
    size: usize,
    text_type: TextType,
    mode: seg_mod.LayoutCacheMode,
) ![]const u8 {
    var temp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer temp_arena.deinit();
    const temp_alloc = temp_arena.allocator();

    const text = try generateTestText(temp_alloc, size, text_type);
    var registry = MemRegistry.init(temp_alloc);
    defer registry.deinit();

    const mem_id = try registry.register(text, false);
    const is_ascii = text_type == .ascii;
    const approx_width: u16 = @intCast(@min(text.len, std.math.maxInt(u16)));
    var chunk = TextChunk{
        .mem_id = mem_id,
        .byte_start = 0,
        .byte_end = @intCast(text.len),
        .width = approx_width,
        .flags = if (is_ascii) TextChunk.Flags.ASCII_ONLY else 0,
    };

    chunk.layout_cache_valid = true;
    chunk.layout_cache_tab_width = 4;
    chunk.layout_cache_width_method = .unicode;
    chunk.layout_cache_mode = mode;

    var scratch = seg_mod.LayoutSpanScratch.init();
    var ctx = CountSpansContext{};
    try chunk.forEachLayoutSpans(&registry, temp_alloc, 4, .unicode, &scratch, &ctx, countSpans);

    return try std.fmt.allocPrint(
        allocator,
        "forEachLayoutSpans {s} {s} ({d} bytes, {d} spans)",
        .{ layoutModeLabel(mode), textTypeLabel(text_type), size, ctx.count },
    );
}

pub fn run(
    allocator: std.mem.Allocator,
    show_mem: bool,
    bench_filter: ?[]const u8,
) ![]BenchResult {
    _ = gp.initGlobalPool(allocator);

    var results: std.ArrayListUnmanaged(BenchResult) = .{};
    errdefer results.deinit(allocator);

    const iterations: usize = 100;
    const sizes = [_]usize{ 100, 1024, 4 * 1024, 16 * 1024, 64 * 1024 };
    const text_types = [_]TextType{ .ascii, .mixed, .heavy_unicode };
    const modes = [_]seg_mod.LayoutCacheMode{ .full_cache, .windowed };

    if (bench_filter == null) {
        for (modes) |mode| {
            for (text_types) |text_type| {
                for (sizes) |size| {
                    const result = try benchForEachLayoutSpans(allocator, size, text_type, mode, iterations, show_mem);
                    try results.append(allocator, result);
                }
            }
        }
    } else {
        for (modes) |mode| {
            for (text_types) |text_type| {
                for (sizes) |size| {
                    const benchmark_name = try computeBenchName(allocator, size, text_type, mode);
                    if (bench_utils.matchesBenchFilter(benchmark_name, bench_filter)) {
                        var result = try benchForEachLayoutSpans(allocator, size, text_type, mode, iterations, show_mem);
                        allocator.free(result.name);
                        result.name = benchmark_name;
                        try results.append(allocator, result);
                    } else {
                        allocator.free(benchmark_name);
                    }
                }
            }
        }
    }

    return try results.toOwnedSlice(allocator);
}
