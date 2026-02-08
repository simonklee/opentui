#!/usr/bin/env bun
/**
 * Benchmark comparing StaticTextBuffer vs UnifiedTextBuffer performance
 * for Text and Code renderables.
 *
 * Run: bun src/benchmark/text-buffer-benchmark.ts
 */

import { createTestRenderer, type TestRenderer } from "../testing/test-renderer"
import { TextRenderable } from "../renderables/Text"
import { CodeRenderable } from "../renderables/Code"
import { SyntaxStyle } from "../syntax-style"
import { RGBA } from "../lib/RGBA"
import { StyledText } from "../lib/styled-text"
import { TextBufferView } from "../text-buffer-view"
import { UnifiedTextBuffer, type TextChunk } from "../text-buffer"

interface BenchmarkResult {
  name: string
  iterations: number
  totalTimeMs: number
  averageTimeMs: number
  medianTimeMs: number
  p95TimeMs: number
  minTimeMs: number
  maxTimeMs: number
  opsPerSecond: number
  timeSource: "cpu" | "wall"
}

interface BenchmarkSuite {
  scenario: string
  staticBuffer: BenchmarkResult
  unifiedBuffer: BenchmarkResult
  speedup: number
}

interface MemorySnapshot {
  rss: number
  heapUsed: number
  external: number
  arrayBuffers: number
}

interface MemoryStats {
  minBytes: number
  maxBytes: number
  averageBytes: number
  medianBytes: number
}

type MemoryKey = "rss" | "heapUsed" | "external" | "arrayBuffers"

interface MemoryResult {
  name: string
  iterations: number
  stats: Record<MemoryKey, MemoryStats>
}

interface MemorySuite {
  scenario: string
  staticBuffer: MemoryResult
  unifiedBuffer: MemoryResult
  rssDeltaBytes: number
  rssRatio: number
}

const memoryKeys: MemoryKey[] = ["rss", "heapUsed", "external", "arrayBuffers"]

const memoryLabels: Record<MemoryKey, string> = {
  rss: "RSS",
  heapUsed: "Heap",
  external: "External",
  arrayBuffers: "ArrayBuffers",
}

const cpuTimeAvailable = typeof process?.cpuUsage === "function"
const bunGc = typeof Bun !== "undefined" ? (Bun as { gc?: () => void }).gc : undefined
const globalGc = (globalThis as { gc?: () => void }).gc
const gcAvailable = typeof bunGc === "function" || typeof globalGc === "function"

// Generate test content
function generateContent(lines: number, charsPerLine: number): string {
  const result: string[] = []
  for (let i = 0; i < lines; i++) {
    result.push(`Line ${i.toString().padStart(4, "0")}: ${"x".repeat(charsPerLine - 15)}`)
  }
  return result.join("\n")
}

function generateStyledContent(lines: number, charsPerLine: number): StyledText {
  const chunks: TextChunk[] = []
  for (let i = 0; i < lines; i++) {
    chunks.push({
      __isChunk: true,
      text: `Line ${i.toString().padStart(4, "0")}: `,
      fg: RGBA.fromValues(1, 0.5, 0, 1), // Orange
    })
    chunks.push({
      __isChunk: true,
      text: `${"x".repeat(charsPerLine - 15)}`,
      fg: RGBA.fromValues(0.5, 0.5, 1, 1), // Light blue
    })
    if (i < lines - 1) {
      chunks.push({
        __isChunk: true,
        text: "\n",
      })
    }
  }
  return new StyledText(chunks)
}

function generateCodeContent(lines: number): string {
  const result: string[] = []
  for (let i = 0; i < lines; i++) {
    const code = [
      `const variable${i} = "value${i}";`,
      `function fn${i}(x: number): number { return x * ${i}; }`,
      `if (condition${i}) { console.log("message ${i}"); }`,
      `for (let j = 0; j < ${i}; j++) { array.push(j); }`,
      `const obj${i} = { key: ${i}, value: "str" };`,
    ]
    result.push(code[i % code.length])
  }
  return result.join("\n")
}

function maybeGc(): void {
  if (typeof bunGc === "function") {
    bunGc()
    return
  }
  if (typeof globalGc === "function") {
    globalGc()
  }
}

function getCpuTimeMs(): number {
  const usage = process.cpuUsage()
  return (usage.user + usage.system) / 1000
}

function getMemorySnapshot(): MemorySnapshot {
  const usage = process.memoryUsage()
  return {
    rss: usage.rss,
    heapUsed: usage.heapUsed,
    external: usage.external ?? 0,
    arrayBuffers: usage.arrayBuffers ?? 0,
  }
}

function diffMemory(after: MemorySnapshot, before: MemorySnapshot): MemorySnapshot {
  return {
    rss: after.rss - before.rss,
    heapUsed: after.heapUsed - before.heapUsed,
    external: after.external - before.external,
    arrayBuffers: after.arrayBuffers - before.arrayBuffers,
  }
}

function getMedian(sorted: number[]): number {
  if (sorted.length === 0) return 0
  const mid = Math.floor(sorted.length / 2)
  if (sorted.length % 2 === 0) {
    return (sorted[mid - 1] + sorted[mid]) / 2
  }
  return sorted[mid]
}

function getPercentile(sorted: number[], percentile: number): number {
  if (sorted.length === 0) return 0
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil(percentile * sorted.length) - 1))
  return sorted[index]
}

function calculateMemoryStats(values: number[]): MemoryStats {
  if (values.length === 0) {
    return { minBytes: 0, maxBytes: 0, averageBytes: 0, medianBytes: 0 }
  }
  const sorted = [...values].sort((a, b) => a - b)
  const total = sorted.reduce((sum, value) => sum + value, 0)
  return {
    minBytes: sorted[0],
    maxBytes: sorted[sorted.length - 1],
    averageBytes: total / sorted.length,
    medianBytes: getMedian(sorted),
  }
}

function summarizeMemory(deltas: MemorySnapshot[]): Record<MemoryKey, MemoryStats> {
  const stats = {} as Record<MemoryKey, MemoryStats>
  for (const key of memoryKeys) {
    stats[key] = calculateMemoryStats(deltas.map((delta) => delta[key]))
  }
  return stats
}

async function benchmarkTextBufferSetText(
  widthMethod: "wcwidth" | "unicode",
  editable: boolean,
  content: string,
  iterations: number,
): Promise<BenchmarkResult> {
  let buffer: UnifiedTextBuffer | null = null

  return runBenchmark(
    editable ? "UnifiedBuffer" : "StaticBuffer",
    iterations,
    async () => {
      buffer = UnifiedTextBuffer.create(widthMethod, { editable })
    },
    async () => {
      buffer!.setText(content)
      buffer!.getLineCount()
    },
    async () => {
      if (buffer) {
        buffer.destroy()
        buffer = null
      }
    },
  )
}

async function benchmarkTextBufferSetStyledText(
  widthMethod: "wcwidth" | "unicode",
  editable: boolean,
  content: StyledText,
  iterations: number,
): Promise<BenchmarkResult> {
  let buffer: UnifiedTextBuffer | null = null

  return runBenchmark(
    editable ? "UnifiedBuffer" : "StaticBuffer",
    iterations,
    async () => {
      buffer = UnifiedTextBuffer.create(widthMethod, { editable })
    },
    async () => {
      buffer!.setStyledText(content)
      buffer!.getLineCount()
    },
    async () => {
      if (buffer) {
        buffer.destroy()
        buffer = null
      }
    },
  )
}

async function benchmarkTextBufferContentUpdate(
  widthMethod: "wcwidth" | "unicode",
  editable: boolean,
  contents: string[],
  iterations: number,
): Promise<BenchmarkResult> {
  let buffer: UnifiedTextBuffer | null = null

  return runBenchmark(
    editable ? "UnifiedBuffer" : "StaticBuffer",
    iterations,
    async () => {
      buffer = UnifiedTextBuffer.create(widthMethod, { editable })
    },
    async () => {
      for (const content of contents) {
        buffer!.setText(content)
      }
      buffer!.getLineCount()
    },
    async () => {
      if (buffer) {
        buffer.destroy()
        buffer = null
      }
    },
  )
}

async function benchmarkTextBufferViewWrap(
  widthMethod: "wcwidth" | "unicode",
  editable: boolean,
  content: string,
  wrapWidth: number,
  iterations: number,
): Promise<BenchmarkResult> {
  let buffer: UnifiedTextBuffer | null = null
  let view: TextBufferView | null = null

  return runBenchmark(
    editable ? "UnifiedBuffer" : "StaticBuffer",
    iterations,
    async () => {
      buffer = UnifiedTextBuffer.create(widthMethod, { editable })
      buffer.setText(content)
      view = TextBufferView.create(buffer)
      view.setWrapMode("word")
      view.setWrapWidth(wrapWidth)
    },
    async () => {
      view!.getVirtualLineCount()
    },
    async () => {
      if (view) {
        view.destroy()
        view = null
      }
      if (buffer) {
        buffer.destroy()
        buffer = null
      }
    },
  )
}

async function benchmarkTextBufferSetTextMemory(
  widthMethod: "wcwidth" | "unicode",
  editable: boolean,
  content: string,
  iterations: number,
): Promise<MemoryResult> {
  let buffer: UnifiedTextBuffer | null = null

  return runMemoryBenchmark(
    editable ? "UnifiedBuffer" : "StaticBuffer",
    iterations,
    async () => {
      buffer = UnifiedTextBuffer.create(widthMethod, { editable })
    },
    async () => {
      buffer!.setText(content)
      buffer!.getLineCount()
    },
    async () => {
      if (buffer) {
        buffer.destroy()
        buffer = null
      }
    },
  )
}

async function benchmarkTextBufferSetStyledTextMemory(
  widthMethod: "wcwidth" | "unicode",
  editable: boolean,
  content: StyledText,
  iterations: number,
): Promise<MemoryResult> {
  let buffer: UnifiedTextBuffer | null = null

  return runMemoryBenchmark(
    editable ? "UnifiedBuffer" : "StaticBuffer",
    iterations,
    async () => {
      buffer = UnifiedTextBuffer.create(widthMethod, { editable })
    },
    async () => {
      buffer!.setStyledText(content)
      buffer!.getLineCount()
    },
    async () => {
      if (buffer) {
        buffer.destroy()
        buffer = null
      }
    },
  )
}

async function benchmarkTextBufferContentUpdateMemory(
  widthMethod: "wcwidth" | "unicode",
  editable: boolean,
  contents: string[],
  iterations: number,
): Promise<MemoryResult> {
  let buffer: UnifiedTextBuffer | null = null

  return runMemoryBenchmark(
    editable ? "UnifiedBuffer" : "StaticBuffer",
    iterations,
    async () => {
      buffer = UnifiedTextBuffer.create(widthMethod, { editable })
    },
    async () => {
      for (const content of contents) {
        buffer!.setText(content)
      }
      buffer!.getLineCount()
    },
    async () => {
      if (buffer) {
        buffer.destroy()
        buffer = null
      }
    },
  )
}

async function benchmarkTextBufferViewWrapMemory(
  widthMethod: "wcwidth" | "unicode",
  editable: boolean,
  content: string,
  wrapWidth: number,
  iterations: number,
): Promise<MemoryResult> {
  let buffer: UnifiedTextBuffer | null = null
  let view: TextBufferView | null = null

  return runMemoryBenchmark(
    editable ? "UnifiedBuffer" : "StaticBuffer",
    iterations,
    async () => {
      buffer = UnifiedTextBuffer.create(widthMethod, { editable })
      buffer.setText(content)
      view = TextBufferView.create(buffer)
      view.setWrapMode("word")
      view.setWrapWidth(wrapWidth)
    },
    async () => {
      view!.getVirtualLineCount()
    },
    async () => {
      if (view) {
        view.destroy()
        view = null
      }
      if (buffer) {
        buffer.destroy()
        buffer = null
      }
    },
  )
}

async function runBenchmark(
  name: string,
  iterations: number,
  setup: () => Promise<void>,
  fn: () => Promise<void>,
  teardown: () => Promise<void>,
): Promise<BenchmarkResult> {
  const times: number[] = []
  const timeSource: "cpu" | "wall" = cpuTimeAvailable ? "cpu" : "wall"

  // Warmup
  for (let i = 0; i < Math.min(5, iterations / 10); i++) {
    await setup()
    await fn()
    await teardown()
  }

  // Actual benchmark
  for (let i = 0; i < iterations; i++) {
    await setup()

    const startWall = performance.now()
    const startCpu = cpuTimeAvailable ? getCpuTimeMs() : 0
    await fn()
    const endWall = performance.now()
    const endCpu = cpuTimeAvailable ? getCpuTimeMs() : 0

    times.push(cpuTimeAvailable ? endCpu - startCpu : endWall - startWall)
    await teardown()
  }

  const sortedTimes = [...times].sort((a, b) => a - b)
  const totalTimeMs = times.reduce((a, b) => a + b, 0)
  const averageTimeMs = totalTimeMs / times.length
  const minTimeMs = sortedTimes[0] ?? 0
  const maxTimeMs = sortedTimes[sortedTimes.length - 1] ?? 0
  const medianTimeMs = getMedian(sortedTimes)
  const p95TimeMs = getPercentile(sortedTimes, 0.95)
  const opsPerSecond = averageTimeMs > 0 ? 1000 / averageTimeMs : 0

  return {
    name,
    iterations,
    totalTimeMs,
    averageTimeMs,
    medianTimeMs,
    p95TimeMs,
    minTimeMs,
    maxTimeMs,
    opsPerSecond,
    timeSource,
  }
}

async function runMemoryBenchmark(
  name: string,
  iterations: number,
  setup: () => Promise<void>,
  fn: () => Promise<void>,
  teardown: () => Promise<void>,
): Promise<MemoryResult> {
  const deltas: MemorySnapshot[] = []
  const warmupIterations = Math.min(2, Math.max(1, Math.floor(iterations / 3)))

  for (let i = 0; i < warmupIterations; i++) {
    await setup()
    await fn()
    await teardown()
  }

  for (let i = 0; i < iterations; i++) {
    await setup()
    maybeGc()
    const before = getMemorySnapshot()
    await fn()
    maybeGc()
    const after = getMemorySnapshot()
    deltas.push(diffMemory(after, before))
    await teardown()
    maybeGc()
  }

  return {
    name,
    iterations,
    stats: summarizeMemory(deltas),
  }
}

async function benchmarkTextRenderable(
  renderer: TestRenderer,
  renderOnce: () => Promise<void>,
  editable: boolean,
  content: StyledText | string,
  iterations: number,
): Promise<BenchmarkResult> {
  let textRenderable: TextRenderable | null = null

  return runBenchmark(
    editable ? "UnifiedBuffer" : "StaticBuffer",
    iterations,
    async () => {
      // Setup: create renderable
    },
    async () => {
      textRenderable = new TextRenderable(renderer, {
        content,
        editable,
        width: 80,
        height: 24,
      })
      renderer.root.add(textRenderable)
      await renderOnce()
    },
    async () => {
      if (textRenderable) {
        renderer.root.remove(textRenderable.id)
        textRenderable.destroy()
        textRenderable = null
      }
    },
  )
}

async function benchmarkTextContentUpdate(
  renderer: TestRenderer,
  renderOnce: () => Promise<void>,
  editable: boolean,
  contents: (StyledText | string)[],
  iterations: number,
): Promise<BenchmarkResult> {
  let textRenderable: TextRenderable | null = null

  return runBenchmark(
    editable ? "UnifiedBuffer" : "StaticBuffer",
    iterations,
    async () => {
      textRenderable = new TextRenderable(renderer, {
        content: "",
        editable,
        width: 80,
        height: 24,
      })
      renderer.root.add(textRenderable)
      await renderOnce()
    },
    async () => {
      // Update content multiple times
      for (const content of contents) {
        textRenderable!.content = content
        await renderOnce()
      }
    },
    async () => {
      if (textRenderable) {
        renderer.root.remove(textRenderable.id)
        textRenderable.destroy()
        textRenderable = null
      }
    },
  )
}

async function benchmarkCodeRenderable(
  renderer: TestRenderer,
  renderOnce: () => Promise<void>,
  editable: boolean,
  content: string,
  iterations: number,
): Promise<BenchmarkResult> {
  let codeRenderable: CodeRenderable | null = null
  const syntaxStyle = SyntaxStyle.fromStyles({
    default: { fg: RGBA.fromValues(1, 1, 1, 1) },
    keyword: { fg: RGBA.fromValues(0, 0, 1, 1) },
    string: { fg: RGBA.fromValues(0, 1, 0, 1) },
  })

  return runBenchmark(
    editable ? "UnifiedBuffer" : "StaticBuffer",
    iterations,
    async () => {
      // Setup
    },
    async () => {
      codeRenderable = new CodeRenderable(renderer, {
        content,
        editable,
        syntaxStyle,
        filetype: "typescript",
        drawUnstyledText: true,
        width: 80,
        height: 24,
      })
      renderer.root.add(codeRenderable)
      await renderOnce()
    },
    async () => {
      if (codeRenderable) {
        renderer.root.remove(codeRenderable.id)
        codeRenderable.destroy()
        codeRenderable = null
      }
    },
  )
}

async function benchmarkCodeContentUpdate(
  renderer: TestRenderer,
  renderOnce: () => Promise<void>,
  editable: boolean,
  contents: string[],
  iterations: number,
): Promise<BenchmarkResult> {
  let codeRenderable: CodeRenderable | null = null
  const syntaxStyle = SyntaxStyle.fromStyles({
    default: { fg: RGBA.fromValues(1, 1, 1, 1) },
    keyword: { fg: RGBA.fromValues(0, 0, 1, 1) },
    string: { fg: RGBA.fromValues(0, 1, 0, 1) },
  })

  return runBenchmark(
    editable ? "UnifiedBuffer" : "StaticBuffer",
    iterations,
    async () => {
      codeRenderable = new CodeRenderable(renderer, {
        content: "",
        editable,
        syntaxStyle,
        filetype: "typescript",
        drawUnstyledText: true,
        width: 80,
        height: 24,
      })
      renderer.root.add(codeRenderable)
      await renderOnce()
    },
    async () => {
      // Update content multiple times
      for (const content of contents) {
        codeRenderable!.content = content
        await renderOnce()
      }
    },
    async () => {
      if (codeRenderable) {
        renderer.root.remove(codeRenderable.id)
        codeRenderable.destroy()
        codeRenderable = null
      }
    },
  )
}

function printResult(result: BenchmarkResult, indent = "  "): void {
  console.log(`${indent}${result.name} (${result.timeSource}):`)
  console.log(`${indent}  Iterations: ${result.iterations}`)
  console.log(`${indent}  Average: ${result.averageTimeMs.toFixed(3)}ms`)
  console.log(`${indent}  Median: ${result.medianTimeMs.toFixed(3)}ms`)
  console.log(`${indent}  P95: ${result.p95TimeMs.toFixed(3)}ms`)
  console.log(`${indent}  Min: ${result.minTimeMs.toFixed(3)}ms`)
  console.log(`${indent}  Max: ${result.maxTimeMs.toFixed(3)}ms`)
  console.log(`${indent}  Ops/sec: ${result.opsPerSecond.toFixed(2)}`)
}

function printSuite(suite: BenchmarkSuite): void {
  console.log(`\n--- ${suite.scenario} ---`)
  printResult(suite.staticBuffer)
  printResult(suite.unifiedBuffer)
  console.log(`  Speedup: ${suite.speedup.toFixed(2)}x ${suite.speedup > 1 ? "(static faster)" : "(unified faster)"}`)
}

function printSummary(label: string, results: BenchmarkSuite[]): void {
  if (results.length === 0) return
  const avgSpeedup = results.reduce((sum, r) => sum + r.speedup, 0) / results.length
  console.log(`${label} average speedup: ${avgSpeedup.toFixed(2)}x`)
  console.log(`${label} best speedup: ${Math.max(...results.map((r) => r.speedup)).toFixed(2)}x`)
  console.log(`${label} worst speedup: ${Math.min(...results.map((r) => r.speedup)).toFixed(2)}x`)
}

function formatBytes(bytes: number): string {
  const sign = bytes < 0 ? "-" : ""
  const abs = Math.abs(bytes)
  return `${sign}${(abs / (1024 * 1024)).toFixed(2)} MiB`
}

function formatMemoryStats(stats: MemoryStats): string {
  return `${formatBytes(stats.medianBytes)} (min ${formatBytes(stats.minBytes)}, max ${formatBytes(stats.maxBytes)})`
}

function printMemoryResult(result: MemoryResult, indent = "  "): void {
  console.log(`${indent}${result.name}:`)
  console.log(`${indent}  Iterations: ${result.iterations}`)
  for (const key of memoryKeys) {
    const stats = result.stats[key]
    console.log(`${indent}  ${memoryLabels[key]}: ${formatMemoryStats(stats)}`)
  }
}

function printMemorySuite(suite: MemorySuite): void {
  console.log(`\n--- ${suite.scenario} ---`)
  printMemoryResult(suite.staticBuffer)
  printMemoryResult(suite.unifiedBuffer)
  const deltaLabel = suite.rssDeltaBytes >= 0 ? "(static smaller)" : "(unified smaller)"
  const ratioLabel = Number.isFinite(suite.rssRatio) ? `${suite.rssRatio.toFixed(2)}x` : "n/a"
  console.log(`  RSS delta: ${formatBytes(suite.rssDeltaBytes)} ${deltaLabel}`)
  console.log(`  RSS ratio: ${ratioLabel}`)
}

function printMemorySummary(label: string, results: MemorySuite[]): void {
  if (results.length === 0) return
  const ratios = results.map((result) => result.rssRatio).filter((ratio) => Number.isFinite(ratio))
  if (ratios.length === 0) return
  const avgRatio = ratios.reduce((sum, ratio) => sum + ratio, 0) / ratios.length
  console.log(`${label} average RSS ratio: ${avgRatio.toFixed(2)}x`)
  console.log(`${label} best RSS ratio: ${Math.max(...ratios).toFixed(2)}x`)
  console.log(`${label} worst RSS ratio: ${Math.min(...ratios).toFixed(2)}x`)
}

function getSpeedup(staticResult: BenchmarkResult, unifiedResult: BenchmarkResult): number {
  return unifiedResult.medianTimeMs / staticResult.medianTimeMs
}

function buildMemorySuite(scenario: string, staticResult: MemoryResult, unifiedResult: MemoryResult): MemorySuite {
  const staticRss = staticResult.stats.rss.medianBytes
  const unifiedRss = unifiedResult.stats.rss.medianBytes
  return {
    scenario,
    staticBuffer: staticResult,
    unifiedBuffer: unifiedResult,
    rssDeltaBytes: unifiedRss - staticRss,
    rssRatio: staticRss > 0 ? unifiedRss / staticRss : Number.POSITIVE_INFINITY,
  }
}

async function main(): Promise<void> {
  const args = new Set(Bun.argv.slice(2))
  const runCpu = !args.has("--memory-only")
  const runMemory = !args.has("--cpu-only")
  const modes: string[] = []
  if (runCpu) modes.push("cpu")
  if (runMemory) modes.push("memory")

  console.log("=== Text Buffer Benchmark ===")
  console.log("Comparing StaticTextBuffer vs UnifiedTextBuffer performance")
  console.log(`Time source: ${cpuTimeAvailable ? "cpu (process.cpuUsage)" : "wall (performance.now)"}`)
  console.log(`GC: ${gcAvailable ? "available" : "unavailable"}${gcAvailable ? "" : " (memory deltas may be noisy)"}`)
  console.log(`Modes: ${modes.join(" + ") || "none"}`)
  console.log("Buffer-only benches isolate TextBuffer ops; view benches cover wrapping.")
  console.log("Renderables include layout/render.")
  console.log("Flags: --cpu-only or --memory-only to isolate runs.\n")

  if (!runCpu && !runMemory) return

  const widthMethod: "wcwidth" | "unicode" = "wcwidth"
  const bufferResults: BenchmarkSuite[] = []
  const viewResults: BenchmarkSuite[] = []
  const renderableResults: BenchmarkSuite[] = []
  const memoryBufferResults: MemorySuite[] = []
  const memoryViewResults: MemorySuite[] = []

  const contentSmall = generateContent(10, 60)
  const contentMedium = generateContent(100, 60)
  const contentLarge = generateContent(1000, 60)
  const styledContent = generateStyledContent(100, 60)
  const updateContents = [
    generateContent(50, 60),
    generateContent(100, 60),
    generateContent(75, 60),
    generateContent(150, 60),
    generateContent(25, 60),
  ]
  const codeSmall = generateCodeContent(10)
  const codeMedium = generateCodeContent(100)
  const codeLarge = generateCodeContent(500)
  const codeUpdateContents = [
    generateCodeContent(50),
    generateCodeContent(100),
    generateCodeContent(75),
    generateCodeContent(150),
    generateCodeContent(25),
  ]
  const wrapWidth = 80

  if (runMemory) {
    const memoryIterations = 6
    console.log("Running memory benchmarks...")
    maybeGc()

    {
      console.log("Running: Memory - TextBuffer Large Content (1000 lines)...")
      const staticResult = await benchmarkTextBufferSetTextMemory(widthMethod, false, contentLarge, memoryIterations)
      const unifiedResult = await benchmarkTextBufferSetTextMemory(widthMethod, true, contentLarge, memoryIterations)
      memoryBufferResults.push(
        buildMemorySuite("TextBuffer Memory - Large Content (1000 lines)", staticResult, unifiedResult),
      )
    }

    {
      console.log("Running: Memory - TextBuffer Styled Content (100 lines)...")
      const staticResult = await benchmarkTextBufferSetStyledTextMemory(
        widthMethod,
        false,
        styledContent,
        memoryIterations,
      )
      const unifiedResult = await benchmarkTextBufferSetStyledTextMemory(
        widthMethod,
        true,
        styledContent,
        memoryIterations,
      )
      memoryBufferResults.push(
        buildMemorySuite("TextBuffer Memory - Styled Content (100 lines)", staticResult, unifiedResult),
      )
    }

    {
      console.log("Running: Memory - TextBuffer Content Updates (5 updates per iteration)...")
      const staticResult = await benchmarkTextBufferContentUpdateMemory(
        widthMethod,
        false,
        updateContents,
        memoryIterations,
      )
      const unifiedResult = await benchmarkTextBufferContentUpdateMemory(
        widthMethod,
        true,
        updateContents,
        memoryIterations,
      )
      memoryBufferResults.push(
        buildMemorySuite("TextBuffer Memory - Content Updates (5 updates)", staticResult, unifiedResult),
      )
    }

    {
      console.log("Running: Memory - TextBufferView Wrap (1000 lines, width 80)...")
      const staticResult = await benchmarkTextBufferViewWrapMemory(
        widthMethod,
        false,
        contentLarge,
        wrapWidth,
        memoryIterations,
      )
      const unifiedResult = await benchmarkTextBufferViewWrapMemory(
        widthMethod,
        true,
        contentLarge,
        wrapWidth,
        memoryIterations,
      )
      memoryViewResults.push(
        buildMemorySuite("TextBufferView Memory - Wrap (1000 lines, width 80)", staticResult, unifiedResult),
      )
    }
  }

  if (runCpu) {
    console.log("Running cpu benchmarks...")

    {
      const iterations = 200
      console.log("Running: TextBuffer - Small Content (10 lines)...")
      const staticResult = await benchmarkTextBufferSetText(widthMethod, false, contentSmall, iterations)
      const unifiedResult = await benchmarkTextBufferSetText(widthMethod, true, contentSmall, iterations)
      bufferResults.push({
        scenario: "TextBuffer - Small Content (10 lines)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: getSpeedup(staticResult, unifiedResult),
      })
    }

    {
      const iterations = 100
      console.log("Running: TextBuffer - Medium Content (100 lines)...")
      const staticResult = await benchmarkTextBufferSetText(widthMethod, false, contentMedium, iterations)
      const unifiedResult = await benchmarkTextBufferSetText(widthMethod, true, contentMedium, iterations)
      bufferResults.push({
        scenario: "TextBuffer - Medium Content (100 lines)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: getSpeedup(staticResult, unifiedResult),
      })
    }

    {
      const iterations = 50
      console.log("Running: TextBuffer - Large Content (1000 lines)...")
      const staticResult = await benchmarkTextBufferSetText(widthMethod, false, contentLarge, iterations)
      const unifiedResult = await benchmarkTextBufferSetText(widthMethod, true, contentLarge, iterations)
      bufferResults.push({
        scenario: "TextBuffer - Large Content (1000 lines)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: getSpeedup(staticResult, unifiedResult),
      })
    }

    {
      const iterations = 100
      console.log("Running: TextBuffer - Styled Content (100 lines)...")
      const staticResult = await benchmarkTextBufferSetStyledText(widthMethod, false, styledContent, iterations)
      const unifiedResult = await benchmarkTextBufferSetStyledText(widthMethod, true, styledContent, iterations)
      bufferResults.push({
        scenario: "TextBuffer - Styled Content (100 lines)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: getSpeedup(staticResult, unifiedResult),
      })
    }

    {
      const iterations = 50
      console.log("Running: TextBuffer - Content Updates (5 updates per iteration)...")
      const staticResult = await benchmarkTextBufferContentUpdate(widthMethod, false, updateContents, iterations)
      const unifiedResult = await benchmarkTextBufferContentUpdate(widthMethod, true, updateContents, iterations)
      bufferResults.push({
        scenario: "TextBuffer - Content Updates (5 updates)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: getSpeedup(staticResult, unifiedResult),
      })
    }

    {
      const iterations = 30
      console.log("Running: TextBufferView - Wrap (1000 lines, width 80)...")
      const staticResult = await benchmarkTextBufferViewWrap(widthMethod, false, contentLarge, wrapWidth, iterations)
      const unifiedResult = await benchmarkTextBufferViewWrap(widthMethod, true, contentLarge, wrapWidth, iterations)
      viewResults.push({
        scenario: "TextBufferView - Wrap (1000 lines, width 80)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: getSpeedup(staticResult, unifiedResult),
      })
    }

    const { renderer, renderOnce } = await createTestRenderer({
      width: 80,
      height: 24,
    })

    try {
      {
        const iterations = 100
        console.log("Running: TextRenderable - Small Content (10 lines)...")
        const staticResult = await benchmarkTextRenderable(renderer, renderOnce, false, contentSmall, iterations)
        const unifiedResult = await benchmarkTextRenderable(renderer, renderOnce, true, contentSmall, iterations)
        renderableResults.push({
          scenario: "TextRenderable - Small Content (10 lines)",
          staticBuffer: staticResult,
          unifiedBuffer: unifiedResult,
          speedup: getSpeedup(staticResult, unifiedResult),
        })
      }

      {
        const iterations = 50
        console.log("Running: TextRenderable - Medium Content (100 lines)...")
        const staticResult = await benchmarkTextRenderable(renderer, renderOnce, false, contentMedium, iterations)
        const unifiedResult = await benchmarkTextRenderable(renderer, renderOnce, true, contentMedium, iterations)
        renderableResults.push({
          scenario: "TextRenderable - Medium Content (100 lines)",
          staticBuffer: staticResult,
          unifiedBuffer: unifiedResult,
          speedup: getSpeedup(staticResult, unifiedResult),
        })
      }

      {
        const iterations = 20
        console.log("Running: TextRenderable - Large Content (1000 lines)...")
        const staticResult = await benchmarkTextRenderable(renderer, renderOnce, false, contentLarge, iterations)
        const unifiedResult = await benchmarkTextRenderable(renderer, renderOnce, true, contentLarge, iterations)
        renderableResults.push({
          scenario: "TextRenderable - Large Content (1000 lines)",
          staticBuffer: staticResult,
          unifiedBuffer: unifiedResult,
          speedup: getSpeedup(staticResult, unifiedResult),
        })
      }

      {
        const iterations = 50
        console.log("Running: TextRenderable - Styled Content (100 lines)...")
        const staticResult = await benchmarkTextRenderable(renderer, renderOnce, false, styledContent, iterations)
        const unifiedResult = await benchmarkTextRenderable(renderer, renderOnce, true, styledContent, iterations)
        renderableResults.push({
          scenario: "TextRenderable - Styled Content (100 lines)",
          staticBuffer: staticResult,
          unifiedBuffer: unifiedResult,
          speedup: getSpeedup(staticResult, unifiedResult),
        })
      }

      {
        const iterations = 30
        console.log("Running: TextRenderable - Content Updates (5 updates per iteration)...")
        const staticResult = await benchmarkTextContentUpdate(renderer, renderOnce, false, updateContents, iterations)
        const unifiedResult = await benchmarkTextContentUpdate(renderer, renderOnce, true, updateContents, iterations)
        renderableResults.push({
          scenario: "TextRenderable - Content Updates (5 updates)",
          staticBuffer: staticResult,
          unifiedBuffer: unifiedResult,
          speedup: getSpeedup(staticResult, unifiedResult),
        })
      }

      {
        const iterations = 100
        console.log("Running: CodeRenderable - Small Content (10 lines)...")
        const staticResult = await benchmarkCodeRenderable(renderer, renderOnce, false, codeSmall, iterations)
        const unifiedResult = await benchmarkCodeRenderable(renderer, renderOnce, true, codeSmall, iterations)
        renderableResults.push({
          scenario: "CodeRenderable - Small Content (10 lines)",
          staticBuffer: staticResult,
          unifiedBuffer: unifiedResult,
          speedup: getSpeedup(staticResult, unifiedResult),
        })
      }

      {
        const iterations = 50
        console.log("Running: CodeRenderable - Medium Content (100 lines)...")
        const staticResult = await benchmarkCodeRenderable(renderer, renderOnce, false, codeMedium, iterations)
        const unifiedResult = await benchmarkCodeRenderable(renderer, renderOnce, true, codeMedium, iterations)
        renderableResults.push({
          scenario: "CodeRenderable - Medium Content (100 lines)",
          staticBuffer: staticResult,
          unifiedBuffer: unifiedResult,
          speedup: getSpeedup(staticResult, unifiedResult),
        })
      }

      {
        const iterations = 20
        console.log("Running: CodeRenderable - Large Content (500 lines)...")
        const staticResult = await benchmarkCodeRenderable(renderer, renderOnce, false, codeLarge, iterations)
        const unifiedResult = await benchmarkCodeRenderable(renderer, renderOnce, true, codeLarge, iterations)
        renderableResults.push({
          scenario: "CodeRenderable - Large Content (500 lines)",
          staticBuffer: staticResult,
          unifiedBuffer: unifiedResult,
          speedup: getSpeedup(staticResult, unifiedResult),
        })
      }

      {
        const iterations = 20
        console.log("Running: CodeRenderable - Content Updates (5 updates per iteration)...")
        const staticResult = await benchmarkCodeContentUpdate(
          renderer,
          renderOnce,
          false,
          codeUpdateContents,
          iterations,
        )
        const unifiedResult = await benchmarkCodeContentUpdate(
          renderer,
          renderOnce,
          true,
          codeUpdateContents,
          iterations,
        )
        renderableResults.push({
          scenario: "CodeRenderable - Content Updates (5 updates)",
          staticBuffer: staticResult,
          unifiedBuffer: unifiedResult,
          speedup: getSpeedup(staticResult, unifiedResult),
        })
      }
    } finally {
      renderer.destroy()
    }
  }

  if (runCpu) {
    console.log("\n\n========== CPU RESULTS ==========")
    if (bufferResults.length > 0) {
      console.log("\nBuffer-only benchmarks:")
      for (const suite of bufferResults) {
        printSuite(suite)
      }
    }
    if (viewResults.length > 0) {
      console.log("\nView benchmarks:")
      for (const suite of viewResults) {
        printSuite(suite)
      }
    }
    if (renderableResults.length > 0) {
      console.log("\nRenderable benchmarks:")
      for (const suite of renderableResults) {
        printSuite(suite)
      }
    }

    console.log("\n\n========== CPU SUMMARY ==========")
    printSummary("Buffer-only", bufferResults)
    printSummary("View", viewResults)
    printSummary("Renderable", renderableResults)
  }

  if (runMemory) {
    console.log("\n\n========== MEMORY RESULTS ==========")
    if (memoryBufferResults.length > 0) {
      console.log("\nBuffer memory benchmarks:")
      for (const suite of memoryBufferResults) {
        printMemorySuite(suite)
      }
    }
    if (memoryViewResults.length > 0) {
      console.log("\nView memory benchmarks:")
      for (const suite of memoryViewResults) {
        printMemorySuite(suite)
      }
    }

    console.log("\n\n========== MEMORY SUMMARY ==========")
    printMemorySummary("Buffer memory", memoryBufferResults)
    printMemorySummary("View memory", memoryViewResults)
  }
}

main().catch(console.error)
