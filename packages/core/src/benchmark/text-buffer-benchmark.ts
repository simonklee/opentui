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
import { UnifiedTextBuffer, type TextChunk } from "../text-buffer"

interface BenchmarkResult {
  name: string
  iterations: number
  totalTimeMs: number
  averageTimeMs: number
  minTimeMs: number
  maxTimeMs: number
  opsPerSecond: number
}

interface BenchmarkSuite {
  scenario: string
  staticBuffer: BenchmarkResult
  unifiedBuffer: BenchmarkResult
  speedup: number
}

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

async function runBenchmark(
  name: string,
  iterations: number,
  setup: () => Promise<void>,
  fn: () => Promise<void>,
  teardown: () => Promise<void>,
): Promise<BenchmarkResult> {
  const times: number[] = []

  // Warmup
  for (let i = 0; i < Math.min(5, iterations / 10); i++) {
    await setup()
    await fn()
    await teardown()
  }

  // Actual benchmark
  for (let i = 0; i < iterations; i++) {
    await setup()

    const start = performance.now()
    await fn()
    const end = performance.now()

    times.push(end - start)
    await teardown()
  }

  const totalTimeMs = times.reduce((a, b) => a + b, 0)
  const averageTimeMs = totalTimeMs / times.length
  const minTimeMs = Math.min(...times)
  const maxTimeMs = Math.max(...times)
  const opsPerSecond = 1000 / averageTimeMs

  return {
    name,
    iterations,
    totalTimeMs,
    averageTimeMs,
    minTimeMs,
    maxTimeMs,
    opsPerSecond,
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

function printResult(result: BenchmarkResult, indent = "  ") {
  console.log(`${indent}${result.name}:`)
  console.log(`${indent}  Iterations: ${result.iterations}`)
  console.log(`${indent}  Average: ${result.averageTimeMs.toFixed(3)}ms`)
  console.log(`${indent}  Min: ${result.minTimeMs.toFixed(3)}ms`)
  console.log(`${indent}  Max: ${result.maxTimeMs.toFixed(3)}ms`)
  console.log(`${indent}  Ops/sec: ${result.opsPerSecond.toFixed(2)}`)
}

function printSuite(suite: BenchmarkSuite) {
  console.log(`\n--- ${suite.scenario} ---`)
  printResult(suite.staticBuffer)
  printResult(suite.unifiedBuffer)
  console.log(`  Speedup: ${suite.speedup.toFixed(2)}x ${suite.speedup > 1 ? "(static faster)" : "(unified faster)"}`)
}

function printSummary(label: string, results: BenchmarkSuite[]) {
  if (results.length === 0) return
  const avgSpeedup = results.reduce((sum, r) => sum + r.speedup, 0) / results.length
  console.log(`${label} average speedup: ${avgSpeedup.toFixed(2)}x`)
  console.log(`${label} best speedup: ${Math.max(...results.map((r) => r.speedup)).toFixed(2)}x`)
  console.log(`${label} worst speedup: ${Math.min(...results.map((r) => r.speedup)).toFixed(2)}x`)
}

async function main() {
  console.log("=== Text Buffer Benchmark ===")
  console.log("Comparing StaticTextBuffer vs UnifiedTextBuffer performance")
  console.log("Buffer-only benches isolate TextBuffer ops; renderable benches include layout/render.\n")

  const widthMethod: "wcwidth" | "unicode" = "wcwidth"
  const bufferResults: BenchmarkSuite[] = []
  const renderableResults: BenchmarkSuite[] = []

  // Buffer-only benchmarks
  {
    const content = generateContent(10, 60)
    const iterations = 200

    console.log("Running: TextBuffer - Small Content (10 lines)...")
    const staticResult = await benchmarkTextBufferSetText(widthMethod, false, content, iterations)
    const unifiedResult = await benchmarkTextBufferSetText(widthMethod, true, content, iterations)

    bufferResults.push({
      scenario: "TextBuffer - Small Content (10 lines)",
      staticBuffer: staticResult,
      unifiedBuffer: unifiedResult,
      speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
    })
  }

  {
    const content = generateContent(100, 60)
    const iterations = 100

    console.log("Running: TextBuffer - Medium Content (100 lines)...")
    const staticResult = await benchmarkTextBufferSetText(widthMethod, false, content, iterations)
    const unifiedResult = await benchmarkTextBufferSetText(widthMethod, true, content, iterations)

    bufferResults.push({
      scenario: "TextBuffer - Medium Content (100 lines)",
      staticBuffer: staticResult,
      unifiedBuffer: unifiedResult,
      speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
    })
  }

  {
    const content = generateContent(1000, 60)
    const iterations = 50

    console.log("Running: TextBuffer - Large Content (1000 lines)...")
    const staticResult = await benchmarkTextBufferSetText(widthMethod, false, content, iterations)
    const unifiedResult = await benchmarkTextBufferSetText(widthMethod, true, content, iterations)

    bufferResults.push({
      scenario: "TextBuffer - Large Content (1000 lines)",
      staticBuffer: staticResult,
      unifiedBuffer: unifiedResult,
      speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
    })
  }

  {
    const content = generateStyledContent(100, 60)
    const iterations = 100

    console.log("Running: TextBuffer - Styled Content (100 lines)...")
    const staticResult = await benchmarkTextBufferSetStyledText(widthMethod, false, content, iterations)
    const unifiedResult = await benchmarkTextBufferSetStyledText(widthMethod, true, content, iterations)

    bufferResults.push({
      scenario: "TextBuffer - Styled Content (100 lines)",
      staticBuffer: staticResult,
      unifiedBuffer: unifiedResult,
      speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
    })
  }

  {
    const contents = [
      generateContent(50, 60),
      generateContent(100, 60),
      generateContent(75, 60),
      generateContent(150, 60),
      generateContent(25, 60),
    ]
    const iterations = 50

    console.log("Running: TextBuffer - Content Updates (5 updates per iteration)...")
    const staticResult = await benchmarkTextBufferContentUpdate(widthMethod, false, contents, iterations)
    const unifiedResult = await benchmarkTextBufferContentUpdate(widthMethod, true, contents, iterations)

    bufferResults.push({
      scenario: "TextBuffer - Content Updates (5 updates)",
      staticBuffer: staticResult,
      unifiedBuffer: unifiedResult,
      speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
    })
  }

  const { renderer, renderOnce } = await createTestRenderer({
    width: 80,
    height: 24,
  })

  try {
    // Benchmark 1: Small text content (10 lines)
    {
      const content = generateContent(10, 60)
      const iterations = 100

      console.log("Running: TextRenderable - Small Content (10 lines)...")
      const staticResult = await benchmarkTextRenderable(renderer, renderOnce, false, content, iterations)
      const unifiedResult = await benchmarkTextRenderable(renderer, renderOnce, true, content, iterations)

      renderableResults.push({
        scenario: "TextRenderable - Small Content (10 lines)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
      })
    }

    // Benchmark 2: Medium text content (100 lines)
    {
      const content = generateContent(100, 60)
      const iterations = 50

      console.log("Running: TextRenderable - Medium Content (100 lines)...")
      const staticResult = await benchmarkTextRenderable(renderer, renderOnce, false, content, iterations)
      const unifiedResult = await benchmarkTextRenderable(renderer, renderOnce, true, content, iterations)

      renderableResults.push({
        scenario: "TextRenderable - Medium Content (100 lines)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
      })
    }

    // Benchmark 3: Large text content (1000 lines)
    {
      const content = generateContent(1000, 60)
      const iterations = 20

      console.log("Running: TextRenderable - Large Content (1000 lines)...")
      const staticResult = await benchmarkTextRenderable(renderer, renderOnce, false, content, iterations)
      const unifiedResult = await benchmarkTextRenderable(renderer, renderOnce, true, content, iterations)

      renderableResults.push({
        scenario: "TextRenderable - Large Content (1000 lines)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
      })
    }

    // Benchmark 4: Styled text content
    {
      const content = generateStyledContent(100, 60)
      const iterations = 50

      console.log("Running: TextRenderable - Styled Content (100 lines)...")
      const staticResult = await benchmarkTextRenderable(renderer, renderOnce, false, content, iterations)
      const unifiedResult = await benchmarkTextRenderable(renderer, renderOnce, true, content, iterations)

      renderableResults.push({
        scenario: "TextRenderable - Styled Content (100 lines)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
      })
    }

    // Benchmark 5: Content updates
    {
      const contents = [
        generateContent(50, 60),
        generateContent(100, 60),
        generateContent(75, 60),
        generateContent(150, 60),
        generateContent(25, 60),
      ]
      const iterations = 30

      console.log("Running: TextRenderable - Content Updates (5 updates per iteration)...")
      const staticResult = await benchmarkTextContentUpdate(renderer, renderOnce, false, contents, iterations)
      const unifiedResult = await benchmarkTextContentUpdate(renderer, renderOnce, true, contents, iterations)

      renderableResults.push({
        scenario: "TextRenderable - Content Updates (5 updates)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
      })
    }

    // Benchmark 6: CodeRenderable - Small
    {
      const content = generateCodeContent(10)
      const iterations = 100

      console.log("Running: CodeRenderable - Small Content (10 lines)...")
      const staticResult = await benchmarkCodeRenderable(renderer, renderOnce, false, content, iterations)
      const unifiedResult = await benchmarkCodeRenderable(renderer, renderOnce, true, content, iterations)

      renderableResults.push({
        scenario: "CodeRenderable - Small Content (10 lines)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
      })
    }

    // Benchmark 7: CodeRenderable - Medium
    {
      const content = generateCodeContent(100)
      const iterations = 50

      console.log("Running: CodeRenderable - Medium Content (100 lines)...")
      const staticResult = await benchmarkCodeRenderable(renderer, renderOnce, false, content, iterations)
      const unifiedResult = await benchmarkCodeRenderable(renderer, renderOnce, true, content, iterations)

      renderableResults.push({
        scenario: "CodeRenderable - Medium Content (100 lines)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
      })
    }

    // Benchmark 8: CodeRenderable - Large
    {
      const content = generateCodeContent(500)
      const iterations = 20

      console.log("Running: CodeRenderable - Large Content (500 lines)...")
      const staticResult = await benchmarkCodeRenderable(renderer, renderOnce, false, content, iterations)
      const unifiedResult = await benchmarkCodeRenderable(renderer, renderOnce, true, content, iterations)

      renderableResults.push({
        scenario: "CodeRenderable - Large Content (500 lines)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
      })
    }

    // Benchmark 9: CodeRenderable - Content Updates
    {
      const contents = [
        generateCodeContent(50),
        generateCodeContent(100),
        generateCodeContent(75),
        generateCodeContent(150),
        generateCodeContent(25),
      ]
      const iterations = 20

      console.log("Running: CodeRenderable - Content Updates (5 updates per iteration)...")
      const staticResult = await benchmarkCodeContentUpdate(renderer, renderOnce, false, contents, iterations)
      const unifiedResult = await benchmarkCodeContentUpdate(renderer, renderOnce, true, contents, iterations)

      renderableResults.push({
        scenario: "CodeRenderable - Content Updates (5 updates)",
        staticBuffer: staticResult,
        unifiedBuffer: unifiedResult,
        speedup: unifiedResult.averageTimeMs / staticResult.averageTimeMs,
      })
    }

    // Print results
    console.log("\n\n========== RESULTS ==========")
    if (bufferResults.length > 0) {
      console.log("\nBuffer-only benchmarks:")
      for (const suite of bufferResults) {
        printSuite(suite)
      }
    }
    if (renderableResults.length > 0) {
      console.log("\nRenderable benchmarks:")
      for (const suite of renderableResults) {
        printSuite(suite)
      }
    }

    // Summary
    console.log("\n\n========== SUMMARY ==========")
    printSummary("Buffer-only", bufferResults)
    printSummary("Renderable", renderableResults)
  } finally {
    renderer.destroy()
  }
}

main().catch(console.error)
