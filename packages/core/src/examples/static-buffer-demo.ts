#!/usr/bin/env bun
/**
 * Static Buffer Demo
 *
 * Demonstrates the difference between StaticTextBuffer (read-only, flat storage)
 * and UnifiedTextBuffer (editable, rope-backed).
 *
 * Key differences:
 * - Static: Optimized for read-only display (Text, Code renderables)
 * - Unified: Full editing capabilities with undo/redo (TextareaRenderable)
 *
 * This example lets you compare behavior and observe any differences.
 */

import {
  CliRenderer,
  createCliRenderer,
  BoxRenderable,
  TextRenderable,
  t,
  bold,
  underline,
  green,
  yellow,
  cyan,
  red,
  fg,
  blue,
  type KeyEvent,
} from ".."
import { TextBuffer } from "../text-buffer"
import { TextBufferView } from "../text-buffer-view"
import { setupCommonDemoKeys } from "./lib/standalone-keys"

let mainContainer: BoxRenderable | null = null
let staticBox: BoxRenderable | null = null
let unifiedBox: BoxRenderable | null = null
let instructionsText: TextRenderable | null = null
let statusText: TextRenderable | null = null
let metricsText: TextRenderable | null = null

// Direct buffer references for metrics
let staticBuffer: TextBuffer | null = null
let unifiedBuffer: TextBuffer | null = null
let staticView: TextBufferView | null = null
let unifiedView: TextBufferView | null = null

let updateInterval: Timer | null = null
let currentExample = 1
let updateCounter = 0

const SAMPLE_TEXTS = {
  simple: `Hello, World!
This is a simple test.
Line 3 here.
And line 4.`,

  medium: `# Static vs Unified Buffer Demo

This demonstrates the difference between:
- StaticTextBuffer: Read-only, flat storage
- UnifiedTextBuffer: Editable, rope-backed

Both should render identically for display purposes.
The static buffer is optimized for:
- Lower memory usage
- Better cache locality
- Faster setText operations

The unified buffer supports:
- Incremental editing (insert/delete)
- Undo/redo history
- Marker tracking`,

  long: Array.from(
    { length: 100 },
    (_, i) => `Line ${(i + 1).toString().padStart(3, "0")}: Lorem ipsum dolor sit amet, consectetur adipiscing elit.`,
  ).join("\n"),

  styled: `{colors}
Red text here
Green text here
Blue text here
Yellow background
{/colors}`,

  unicode: `Unicode test:
日本語テスト (Japanese)
한국어 테스트 (Korean)
中文测试 (Chinese)
🎉 Emoji: 🚀🔥💯
Wide chars: ００１２
Combining: e\u0301 (é)`,
}

function clearUpdateInterval(): void {
  if (updateInterval) {
    clearInterval(updateInterval)
    updateInterval = null
  }
}

function createBufferPair(renderer: CliRenderer): void {
  // Create static buffer (default)
  staticBuffer = TextBuffer.create(renderer.widthMethod, { editable: false })

  // Create unified buffer (editable)
  unifiedBuffer = TextBuffer.create(renderer.widthMethod, { editable: true })

  // Create views for both
  staticView = TextBufferView.create(staticBuffer)
  unifiedView = TextBufferView.create(unifiedBuffer)

  // Configure both views identically
  staticView.setWrapMode("word")
  unifiedView.setWrapMode("word")
}

function destroyBufferPair(): void {
  staticView?.destroy()
  unifiedView?.destroy()
  staticBuffer?.destroy()
  unifiedBuffer?.destroy()
  staticView = null
  unifiedView = null
  staticBuffer = null
  unifiedBuffer = null
}

function setTextOnBoth(text: string): void {
  if (!staticBuffer || !unifiedBuffer) return

  staticBuffer.setText(text)
  unifiedBuffer.setText(text)
}

function getMetrics(): { static: BufferMetrics; unified: BufferMetrics } {
  return {
    static: {
      kind: staticBuffer?.bufferKind ?? "unknown",
      lineCount: staticBuffer?.getLineCount() ?? 0,
      byteSize: staticBuffer?.byteSize ?? 0,
      length: staticBuffer?.length ?? 0,
    },
    unified: {
      kind: unifiedBuffer?.bufferKind ?? "unknown",
      lineCount: unifiedBuffer?.getLineCount() ?? 0,
      byteSize: unifiedBuffer?.byteSize ?? 0,
      length: unifiedBuffer?.length ?? 0,
    },
  }
}

interface BufferMetrics {
  kind: string
  lineCount: number
  byteSize: number
  length: number
}

function updateMetricsDisplay(): void {
  if (!metricsText) return

  const metrics = getMetrics()

  const parityOk =
    metrics.static.lineCount === metrics.unified.lineCount && metrics.static.byteSize === metrics.unified.byteSize

  metricsText.content = t`${bold(cyan("Buffer Metrics"))} ${fg("#666")(`(update #${updateCounter})`)}

${bold("Static Buffer")} ${fg("#888")(`(${metrics.static.kind})`)}
  Lines: ${green(metrics.static.lineCount.toString())}
  Bytes: ${yellow(metrics.static.byteSize.toString())}
  Chars: ${blue(metrics.static.length.toString())}

${bold("Unified Buffer")} ${fg("#888")(`(${metrics.unified.kind})`)}
  Lines: ${green(metrics.unified.lineCount.toString())}
  Bytes: ${yellow(metrics.unified.byteSize.toString())}
  Chars: ${blue(metrics.unified.length.toString())}

${parityOk ? green(bold("Parity: OK")) : red(bold("Parity: MISMATCH"))}`
}

function showExample(num: number): void {
  currentExample = num
  clearUpdateInterval()
  updateCounter = 0

  let text: string
  let title: string

  switch (num) {
    case 1:
      text = SAMPLE_TEXTS.simple
      title = "Simple Text"
      break
    case 2:
      text = SAMPLE_TEXTS.medium
      title = "Medium Text (Markdown-like)"
      break
    case 3:
      text = SAMPLE_TEXTS.long
      title = "Long Text (100 lines)"
      break
    case 4:
      text = SAMPLE_TEXTS.unicode
      title = "Unicode & CJK"
      break
    case 5:
      // Dynamic updates
      text = "Dynamic content: 0"
      title = "Dynamic Updates"
      updateInterval = setInterval(() => {
        updateCounter++
        const dynamicText = `Dynamic content: ${updateCounter}
Time: ${new Date().toLocaleTimeString()}
Random: ${Math.floor(Math.random() * 1000)}`
        setTextOnBoth(dynamicText)
        updateMetricsDisplay()
      }, 100)
      break
    default:
      text = SAMPLE_TEXTS.simple
      title = "Simple Text"
  }

  setTextOnBoth(text)
  updateMetricsDisplay()
  updateInstructions(title)

  if (staticBox) {
    staticBox.title = `Static: ${title}`
  }
  if (unifiedBox) {
    unifiedBox.title = `Unified: ${title}`
  }
}

function updateInstructions(current: string): void {
  if (!instructionsText) return

  instructionsText.content = t`${bold(cyan("Static Buffer Demo"))}

${yellow("1")} Simple text
${yellow("2")} Medium text
${yellow("3")} Long text (100 lines)
${yellow("4")} Unicode & CJK
${yellow("5")} Dynamic updates

${underline("Current:")} ${current}

${fg("#666")("Press ESC to exit")}`
}

export function run(renderer: CliRenderer): void {
  renderer.setBackgroundColor("#0d1117")

  // Create buffer pair first
  createBufferPair(renderer)

  // Main container
  mainContainer = new BoxRenderable(renderer, {
    id: "mainContainer",
    width: "100%",
    height: "100%",
    flexDirection: "column",
    padding: 1,
  })
  renderer.root.add(mainContainer)

  // Top row: instructions + metrics
  const topRow = new BoxRenderable(renderer, {
    id: "topRow",
    width: "100%",
    height: 18,
    flexDirection: "row",
    flexShrink: 0,
  })
  mainContainer.add(topRow)

  // Instructions panel
  instructionsText = new TextRenderable(renderer, {
    id: "instructions",
    width: 30,
    fg: "#c9d1d9",
  })
  topRow.add(instructionsText)

  // Metrics panel
  metricsText = new TextRenderable(renderer, {
    id: "metrics",
    width: 35,
    fg: "#c9d1d9",
  })
  topRow.add(metricsText)

  // Status panel
  statusText = new TextRenderable(renderer, {
    id: "status",
    flexGrow: 1,
    fg: "#58a6ff",
  })
  topRow.add(statusText)

  // Buffer comparison row
  const bufferRow = new BoxRenderable(renderer, {
    id: "bufferRow",
    width: "100%",
    flexGrow: 1,
    flexDirection: "row",
    gap: 1,
  })
  mainContainer.add(bufferRow)

  // Static buffer box
  staticBox = new BoxRenderable(renderer, {
    id: "staticBox",
    flexGrow: 1,
    backgroundColor: "#161b22",
    borderColor: "#238636",
    title: "Static Buffer",
    titleAlignment: "center",
    border: true,
    overflow: "scroll",
  })
  bufferRow.add(staticBox)

  // Create a renderable that uses our static buffer directly
  const staticDisplay = new TextRenderable(renderer, {
    id: "staticDisplay",
    width: "100%",
    height: "100%",
    fg: "#c9d1d9",
  })
  staticBox.add(staticDisplay)

  // Unified buffer box
  unifiedBox = new BoxRenderable(renderer, {
    id: "unifiedBox",
    flexGrow: 1,
    backgroundColor: "#161b22",
    borderColor: "#1f6feb",
    title: "Unified Buffer",
    titleAlignment: "center",
    border: true,
    overflow: "scroll",
  })
  bufferRow.add(unifiedBox)

  // Create a renderable that uses our unified buffer directly
  const unifiedDisplay = new TextRenderable(renderer, {
    id: "unifiedDisplay",
    width: "100%",
    height: "100%",
    fg: "#c9d1d9",
  })
  unifiedBox.add(unifiedDisplay)

  // Note: TextRenderable creates its own internal buffer.
  // For this demo, we sync content to the displays and show metrics
  // from our separate buffer pair.

  // Override to sync content
  const originalSetTextOnBoth = setTextOnBoth
  const syncedSetTextOnBoth = (text: string) => {
    originalSetTextOnBoth(text)
    staticDisplay.content = text
    unifiedDisplay.content = text
  }
  // Replace the function
  ;(globalThis as any).__setTextOnBoth = syncedSetTextOnBoth

  // Patch setTextOnBoth to use synced version
  const patchedSetText = (text: string) => {
    if (staticBuffer && unifiedBuffer) {
      staticBuffer.setText(text)
      unifiedBuffer.setText(text)
    }
    staticDisplay.content = text
    unifiedDisplay.content = text
  }

  // Re-define showExample to use patched version
  const showExamplePatched = (num: number) => {
    currentExample = num
    clearUpdateInterval()
    updateCounter = 0

    let text: string
    let title: string

    switch (num) {
      case 1:
        text = SAMPLE_TEXTS.simple
        title = "Simple Text"
        break
      case 2:
        text = SAMPLE_TEXTS.medium
        title = "Medium Text (Markdown-like)"
        break
      case 3:
        text = SAMPLE_TEXTS.long
        title = "Long Text (100 lines)"
        break
      case 4:
        text = SAMPLE_TEXTS.unicode
        title = "Unicode & CJK"
        break
      case 5:
        text = "Dynamic content: 0"
        title = "Dynamic Updates"
        updateInterval = setInterval(() => {
          updateCounter++
          const dynamicText = `Dynamic content: ${updateCounter}
Time: ${new Date().toLocaleTimeString()}
Random: ${Math.floor(Math.random() * 1000)}`
          patchedSetText(dynamicText)
          updateMetricsDisplay()
        }, 100)
        break
      default:
        text = SAMPLE_TEXTS.simple
        title = "Simple Text"
    }

    patchedSetText(text)
    updateMetricsDisplay()
    updateInstructions(title)

    if (staticBox) {
      staticBox.title = `Static: ${title}`
    }
    if (unifiedBox) {
      unifiedBox.title = `Unified: ${title}`
    }
  }

  // Initialize with first example
  showExamplePatched(1)

  statusText.content = t`${bold("Static Buffer Demo")}

Both panels show identical content.
The left uses ${green("StaticTextBuffer")} (read-only, flat storage).
The right uses ${blue("UnifiedTextBuffer")} (editable, rope-backed).

For display purposes, they should be identical.
Metrics panel shows buffer internals.`

  // Keyboard controls
  renderer.keyInput.on("keypress", (event: KeyEvent) => {
    const key = event.sequence
    if (key === "1") showExamplePatched(1)
    else if (key === "2") showExamplePatched(2)
    else if (key === "3") showExamplePatched(3)
    else if (key === "4") showExamplePatched(4)
    else if (key === "5") showExamplePatched(5)
  })
}

export function destroy(renderer: CliRenderer): void {
  clearUpdateInterval()
  destroyBufferPair()

  if (mainContainer) {
    mainContainer.destroyRecursively()
    mainContainer = null
  }

  staticBox = null
  unifiedBox = null
  instructionsText = null
  statusText = null
  metricsText = null
}

if (import.meta.main) {
  const renderer = await createCliRenderer({
    targetFps: 30,
    enableMouseMovement: true,
    exitOnCtrlC: true,
  })
  run(renderer)
  setupCommonDemoKeys(renderer)
}
