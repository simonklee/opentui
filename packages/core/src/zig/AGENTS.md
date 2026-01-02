# Zig Development Guide

## Running Benchmarks

```bash
# From packages/core directory (recommended)
bun bench:native                     # All benchmarks (ReleaseFast)
bun bench:native --mem               # Include memory statistics

# From packages/core/src/zig directory
zig build bench -Doptimize=ReleaseFast              # All benchmarks
zig build bench -Doptimize=ReleaseFast -- --mem     # Include memory stats
zig build bench -Doptimize=ReleaseFast -- --filter "UTF-8"  # Filter by name
zig build bench -Doptimize=ReleaseFast -- --help    # List available benchmarks
```

## Running Tests

```bash
cd packages/core/src/zig
zig build test                              # All tests
zig build test -- -Dtest-filter="test name" # Filter tests
```

## Performance Work Context

### Key Zig Files

| File              | Purpose                                                                 |
| ----------------- | ----------------------------------------------------------------------- |
| `lib.zig`         | FFI entry point for TypeScript bindings                                 |
| `renderer.zig`    | CliRenderer with double-buffered terminal output                        |
| `buffer.zig`      | OptimizedBuffer (2D cell grid with alpha, scissor, opacity)             |
| `rope.zig`        | Generic persistent/immutable rope with undo/redo                        |
| `utf8.zig`        | SIMD UTF-8 processing (isAsciiOnly, findLineBreaks, calculateTextWidth) |
| `grapheme.zig`    | GraphemePool slab allocator with refcounting                            |
| `text-buffer.zig` | UnifiedTextBuffer using rope                                            |
| `bench.zig`       | Benchmark runner CLI                                                    |
| `bench/*.zig`     | Individual benchmark suites                                             |

### Performance-Critical Paths

1. **UTF-8/grapheme processing** - Heavy `uucode.grapheme.isBreak` usage
2. **Rope operations** - Frequent node creation
3. **Buffer rendering** - Per-cell processing in `drawTextBufferInternal`
4. **ANSI generation** - String formatting in `prepareRenderFrame`
5. **GraphemePool** - Hash map lookups in `GraphemeTracker`

### Continuous Benchmark Loop

The benchmark system supports automated regression detection for performance work.

### Quick Start: The Perf Loop

```bash
# 1. Establish baseline before making changes
cd packages/core/src/zig
zig build bench -- --save-baseline baseline.txt

# 2. Make your performance changes
# ... edit code ...

# 3. Compare against baseline (fails on regression)
zig build bench -- --baseline baseline.txt --threshold 5

# 4. If successful, update baseline
zig build bench -- --save-baseline baseline.txt
```

### CLI Options

| Flag                   | Description                          |
| ---------------------- | ------------------------------------ |
| `--mem`                | Show memory statistics               |
| `--json`               | Machine-readable JSON output         |
| `--filter NAME`        | Run only benchmarks matching NAME    |
| `--save-baseline FILE` | Save results to FILE                 |
| `--baseline FILE`      | Compare against baseline FILE        |
| `--threshold N`        | Regression tolerance % (default: 10) |

### Exit Codes

- `0` - Success (no regressions)
- `1` - Performance regression detected

### JSON Output

For CI/scripting, use `--json` for machine-readable output:

```bash
# Results only
zig build bench -- --json --filter "UTF-8"

# With comparison
zig build bench -- --json --baseline baseline.txt
```

JSON comparison format:

```json
{
  "comparisons": [
    {
      "name": "...",
      "baseline_ns": 420,
      "current_ns": 450,
      "change_percent": 7.14,
      "is_regression": false,
      "mem_comparisons": [
        {
          "name": "heap",
          "baseline_bytes": 1024,
          "current_bytes": 1100,
          "change_percent": 7.42,
          "is_regression": false
        }
      ]
    }
  ],
  "has_regression": false,
  "has_mem_regression": false
}
```

### Baseline File Format

Each line contains timing and optional memory stats:

```
name=avg_ns
name=avg_ns|mem:stat_name=bytes|mem:stat_name2=bytes2
```

Example:

```
isAsciiOnly: ASCII text (1KB)=420
calculateTextWidth: ASCII (100KB)=495586
TextBuffer setText large=7759505|mem:heap=1048576|mem:pool=2048
```

The format is backward-compatible: old baselines without memory stats still work.

### Tips for Reliable Benchmarking

1. **Warm up**: Run benchmarks twice; first run may have cold cache effects
2. **Consistent environment**: Close other apps, use same machine
3. **Threshold tuning**: Start with 10%, tighten to 5% for stable benchmarks
4. **Filter for focus**: Use `--filter` when iterating on specific code
