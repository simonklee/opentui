#!/usr/bin/env bun

import {
  BoxRenderable,
  CliRenderer,
  createCliRenderer,
  RGBA,
  TextAttributes,
  TextRenderable,
  type KeyEvent,
} from "../index.js"
import { normalizeTerminalPalette } from "../lib/color-value.js"
import { StyledText } from "../lib/styled-text.js"
import type { TerminalColors } from "../lib/terminal-palette.js"
import type { TextChunk } from "../text-buffer.js"
import { setupCommonDemoKeys } from "./lib/standalone-keys.js"

type ScenarioMode = "reused" | "unique"
type PalettePresetName = "detected" | "xterm" | "solarized-dark"
type RunOptions = {
  autoDetectPalette?: boolean
}

interface InternalColorDebugStats {
  conversions: number
  cache_hits: number
  cache_misses: number
  cache_size: number
  palette_epoch: number
}

interface InternalPaletteDebugRenderer {
  publishPalette(colors: TerminalColors | null): void
  resetColorDebugStats(options?: { clearCache?: boolean }): void
  getColorDebugStats(): InternalColorDebugStats
}

const SWATCH_COUNT = 32
const XTERM_16_HEX = [
  "#000000",
  "#800000",
  "#008000",
  "#808000",
  "#000080",
  "#800080",
  "#008080",
  "#c0c0c0",
  "#808080",
  "#ff0000",
  "#00ff00",
  "#ffff00",
  "#0000ff",
  "#ff00ff",
  "#00ffff",
  "#ffffff",
] as const
const SOLARIZED_DARK_16_HEX = [
  "#073642",
  "#dc322f",
  "#859900",
  "#b58900",
  "#268bd2",
  "#d33682",
  "#2aa198",
  "#eee8d5",
  "#002b36",
  "#cb4b16",
  "#586e75",
  "#657b83",
  "#839496",
  "#6c71c4",
  "#93a1a1",
  "#fdf6e3",
] as const
const REUSED_BASE_HEX = [
  "#ef4444",
  "#f59e0b",
  "#84cc16",
  "#06b6d4",
  "#3b82f6",
  "#a855f7",
  "#ec4899",
  "#f8fafc",
] as const

const COLOR_BG = RGBA.fromHex("#0b1220")
const COLOR_TITLE = RGBA.fromHex("#7dd3fc")
const COLOR_LABEL = RGBA.fromHex("#cbd5e1")
const COLOR_MUTED = RGBA.fromHex("#94a3b8")
const COLOR_SUCCESS = RGBA.fromHex("#4ade80")
const COLOR_WARNING = RGBA.fromHex("#fbbf24")
const COLOR_ERROR = RGBA.fromHex("#f87171")

let rootContainer: BoxRenderable | null = null
let terminalInfoText: TextRenderable | null = null
let statusText: TextRenderable | null = null
let rgbFallbackLineText: TextRenderable | null = null
let explicitIndexedLineText: TextRenderable | null = null
let defaultIntentLineText: TextRenderable | null = null
let paletteTopText: TextRenderable | null = null
let paletteBottomText: TextRenderable | null = null
let cacheStatsText: TextRenderable | null = null
let footerText: TextRenderable | null = null
let keyListener: ((key: KeyEvent) => void) | null = null
let frameCallback: ((deltaTime: number) => Promise<void>) | null = null

let scenarioMode: ScenarioMode = "reused"
let palettePreset: PalettePresetName = "xterm"
let swatchGlyph = "█"
let fullPalette: RGBA[] = normalizeTerminalPalette(null).palette
let visiblePalette: RGBA[] = fullPalette.slice(0, 16)
let lastStatsLabel = ""
let visualChecklistRunning = false

function publishPalette(renderer: CliRenderer, colors: TerminalColors | null): void {
  ;(renderer as unknown as InternalPaletteDebugRenderer).publishPalette(colors)
}

function resetRendererColorDebugStats(renderer: CliRenderer, options?: { clearCache?: boolean }): void {
  ;(renderer as unknown as InternalPaletteDebugRenderer).resetColorDebugStats(options)
}

function readColorDebugStats(renderer: CliRenderer): InternalColorDebugStats {
  return (renderer as unknown as InternalPaletteDebugRenderer).getColorDebugStats()
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function chunk(text: string, options: { fg?: RGBA; bg?: RGBA; attributes?: number } = {}): TextChunk {
  return {
    __isChunk: true,
    text,
    fg: options.fg,
    bg: options.bg,
    attributes: options.attributes,
  }
}

function getContrastForBackground(color: RGBA): RGBA {
  const luminance = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b
  return luminance > 0.5 ? RGBA.fromInts(0, 0, 0) : RGBA.fromInts(255, 255, 255)
}

function buildPresetPalette(name: Exclude<PalettePresetName, "detected">): TerminalColors {
  const palette = name === "solarized-dark" ? [...SOLARIZED_DARK_16_HEX] : [...XTERM_16_HEX]
  const defaultForeground = name === "solarized-dark" ? "#93a1a1" : "#ffffff"
  const defaultBackground = name === "solarized-dark" ? "#002b36" : "#000000"

  return {
    palette,
    defaultForeground,
    defaultBackground,
    cursorColor: null,
    mouseForeground: null,
    mouseBackground: null,
    tekForeground: null,
    tekBackground: null,
    highlightBackground: null,
    highlightForeground: null,
  }
}

function applyPalette(colors: TerminalColors | null, source: PalettePresetName): void {
  const normalized = normalizeTerminalPalette(colors)
  fullPalette = normalized.palette
  visiblePalette = normalized.palette.slice(0, 16)
  palettePreset = source
}

function colorKey(color: RGBA): string {
  const [r, g, b] = color.toInts()
  return `${r},${g},${b}`
}

function rgbDistanceSquared(a: RGBA, b: RGBA): number {
  const dr = a.r - b.r
  const dg = a.g - b.g
  const db = a.b - b.b
  return dr * dr + dg * dg + db * db
}

function nearestPaletteIndex(rgb: RGBA): number {
  let bestIndex = 0
  let bestDistance = Number.POSITIVE_INFINITY

  for (let i = 0; i < fullPalette.length; i++) {
    const distance = rgbDistanceSquared(rgb, fullPalette[i])
    if (distance < bestDistance) {
      bestDistance = distance
      bestIndex = i
    }
  }

  return bestIndex
}

function buildSourceColors(mode: ScenarioMode, count: number): RGBA[] {
  if (mode === "reused") {
    const palette = REUSED_BASE_HEX.map((hex) => RGBA.fromHex(hex))
    return Array.from({ length: count }, (_, i) => palette[i % palette.length])
  }

  return Array.from({ length: count }, (_, i) => {
    const t = count <= 1 ? 0 : i / (count - 1)
    const r = Math.round(255 * t)
    const g = Math.round(255 * (1 - Math.abs(0.5 - t) * 2))
    const b = Math.round(255 * (1 - t))
    return RGBA.fromInts(r, g, b)
  })
}

function buildRgbFallbackLine(label: string, colors: RGBA[]): StyledText {
  const chunks: TextChunk[] = [
    chunk(label.padEnd(15), { fg: COLOR_LABEL, attributes: TextAttributes.BOLD }),
    chunk(" "),
  ]

  for (let i = 0; i < colors.length; i++) {
    chunks.push(chunk(swatchGlyph, { fg: colors[i] }))
    if ((i + 1) % 8 === 0) chunks.push(chunk(" "))
  }

  return new StyledText(chunks)
}

function buildIndexedIntentLine(label: string, colors: RGBA[]): StyledText {
  const chunks: TextChunk[] = [
    chunk(label.padEnd(15), { fg: COLOR_LABEL, attributes: TextAttributes.BOLD }),
    chunk(" "),
  ]

  for (let i = 0; i < colors.length; i++) {
    const index = nearestPaletteIndex(colors[i])
    chunks.push(chunk(swatchGlyph, { fg: RGBA.fromIndex(index, colors[i]) }))
    if ((i + 1) % 8 === 0) chunks.push(chunk(" "))
  }

  return new StyledText(chunks)
}

function buildDefaultIntentLine(): StyledText {
  const surface = visiblePalette[0] ?? RGBA.fromHex(XTERM_16_HEX[0])
  const primary = visiblePalette[4] ?? RGBA.fromHex(XTERM_16_HEX[4])
  const accent = visiblePalette[6] ?? RGBA.fromHex(XTERM_16_HEX[6])
  const warning = visiblePalette[3] ?? RGBA.fromHex(XTERM_16_HEX[3])
  const bright = visiblePalette[15] ?? RGBA.fromHex(XTERM_16_HEX[15])
  const warningFg = getContrastForBackground(warning)
  const defaultSurfaceFg = getContrastForBackground(surface)

  return new StyledText([
    chunk("Theme usage".padEnd(15), { fg: COLOR_LABEL, attributes: TextAttributes.BOLD }),
    chunk(" "),
    chunk(" Header ", {
      fg: RGBA.fromIndex(15, bright),
      bg: RGBA.fromIndex(4, primary),
      attributes: TextAttributes.BOLD,
    }),
    chunk("  "),
    chunk(" Button ", {
      fg: RGBA.fromIndex(15, bright),
      bg: RGBA.fromIndex(6, accent),
      attributes: TextAttributes.BOLD,
    }),
    chunk("  "),
    chunk(" Warning ", { fg: warningFg, bg: RGBA.fromIndex(3, warning), attributes: TextAttributes.BOLD }),
    chunk("  "),
    chunk(" defaults ", { fg: RGBA.defaultForeground(defaultSurfaceFg), bg: RGBA.defaultBackground(surface) }),
  ])
}

function buildPaletteLine(label: string, start: number, end: number): StyledText {
  const chunks: TextChunk[] = [
    chunk(label.padEnd(15), { fg: COLOR_LABEL, attributes: TextAttributes.BOLD }),
    chunk(" "),
  ]

  for (let i = start; i <= end; i++) {
    const color = visiblePalette[i] ?? RGBA.fromHex(XTERM_16_HEX[i])
    const fg = getContrastForBackground(color)
    chunks.push(chunk(` ${i.toString(16).toUpperCase()} `, { fg, bg: RGBA.fromIndex(i, color) }))
    chunks.push(chunk(" "))
  }

  return new StyledText(chunks)
}

function colorModeLabel(renderer: CliRenderer): string {
  const caps = renderer.capabilities as { rgb?: boolean; ansi256?: boolean } | null
  if (caps?.rgb) return "truecolor"
  if (caps?.ansi256) return "ansi256"
  return "fallback"
}

function updateTerminalInfo(renderer: CliRenderer): void {
  if (!terminalInfoText) return

  const caps = renderer.capabilities as
    | {
        rgb?: boolean
        ansi256?: boolean
        terminal?: { name?: string; version?: string; from_xtversion?: boolean }
      }
    | null
    | undefined

  const termName = caps?.terminal?.name || "unknown"
  const termVersion = caps?.terminal?.version ? ` ${caps.terminal.version}` : ""
  const detectedFrom = caps?.terminal?.from_xtversion ? "xtversion" : "env/caps"

  terminalInfoText.content =
    `Terminal: ${termName}${termVersion} | mode=${colorModeLabel(renderer)} | rgb=${caps?.rgb ? "true" : "false"}` +
    ` | ansi256=${caps?.ansi256 ? "true" : "false"} | source=${detectedFrom}`
}

function setStatus(message: string, color: RGBA): void {
  if (!statusText) return
  statusText.content = message
  statusText.fg = color
}

function updateStatsLabel(renderer: CliRenderer): void {
  if (!cacheStatsText) return

  const stats = readColorDebugStats(renderer)
  const label =
    `palette=${palettePreset} mode=${colorModeLabel(renderer)} scenario=${scenarioMode} glyph=${swatchGlyph}` +
    `\n` +
    `hits=${stats.cache_hits} misses=${stats.cache_misses} conv=${stats.conversions} cache=${stats.cache_size} epoch=${stats.palette_epoch}`

  if (label === lastStatsLabel) return
  lastStatsLabel = label
  cacheStatsText.content = label
}

function refreshView(renderer: CliRenderer): void {
  if (
    !rgbFallbackLineText ||
    !explicitIndexedLineText ||
    !defaultIntentLineText ||
    !paletteTopText ||
    !paletteBottomText ||
    !footerText
  ) {
    return
  }

  const sourceColors = buildSourceColors(scenarioMode, SWATCH_COUNT)
  rgbFallbackLineText.content = buildRgbFallbackLine("RGB fallback", sourceColors)
  explicitIndexedLineText.content = buildIndexedIntentLine("Explicit index", sourceColors)
  defaultIntentLineText.content = buildDefaultIntentLine()
  paletteTopText.content = buildPaletteLine("Palette 0-7", 0, 7)
  paletteBottomText.content = buildPaletteLine("Palette 8-F", 8, 15)

  footerText.content =
    colorModeLabel(renderer) === "truecolor"
      ? "Truecolor mode: fallback stats stay 0. Set OPENTUI_FORCE_COLOR_MODE=256. Press v for visual e2e."
      : process.env.OPENTUI_FORCE_COLOR_MODE === "256"
        ? "ANSI256 fallback active: press space repaint or v to run visual e2e checklist."
        : "Tip: set OPENTUI_FORCE_COLOR_MODE=256. Press v for visual e2e checklist."

  updateStatsLabel(renderer)
  renderer.requestRender()
}

function resetColorStats(renderer: CliRenderer, clearCache: boolean): void {
  resetRendererColorDebugStats(renderer, { clearCache })
  lastStatsLabel = ""
}

function applyPresetPalette(
  renderer: CliRenderer,
  name: Exclude<PalettePresetName, "detected">,
  options: { resetStats?: boolean } = {},
): void {
  const colors = buildPresetPalette(name)
  applyPalette(colors, name)
  publishPalette(renderer, colors)
  if (options.resetStats ?? true) {
    resetColorStats(renderer, true)
  }
}

function publishPresetPalette(renderer: CliRenderer, name: Exclude<PalettePresetName, "detected">): void {
  applyPresetPalette(renderer, name, { resetStats: true })
  setStatus(`Published ${name} palette preset and cleared RGB->index stats.`, COLOR_SUCCESS)
  refreshView(renderer)
}

async function detectPalette(renderer: CliRenderer, clearRendererCache: boolean): Promise<void> {
  try {
    setStatus("Detecting terminal palette via OSC queries...", COLOR_WARNING)

    if (clearRendererCache) {
      renderer.clearPaletteCache()
    }

    const colors = await renderer.getPalette({ size: 256 })
    applyPalette(colors, "detected")
    publishPalette(renderer, colors)
    resetColorStats(renderer, true)
    setStatus("Published detected terminal palette and reset RGB->index stats.", COLOR_SUCCESS)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    setStatus(`Palette detection failed (${message}). Keeping current palette basis.`, COLOR_ERROR)
  }

  updateTerminalInfo(renderer)
  refreshView(renderer)
}

function toggleSwatchGlyph(): void {
  swatchGlyph = swatchGlyph === "█" ? "▓" : "█"
}

async function runVisualChecklist(renderer: CliRenderer): Promise<void> {
  if (visualChecklistRunning) {
    setStatus("Visual checklist already running.", COLOR_WARNING)
    return
  }

  visualChecklistRunning = true

  try {
    const total = 5

    scenarioMode = "reused"
    swatchGlyph = "█"
    applyPresetPalette(renderer, "xterm", { resetStats: true })
    setStatus(`E2E 1/${total}: baseline (xterm + stats reset).`, COLOR_WARNING)
    refreshView(renderer)
    await sleep(750)

    toggleSwatchGlyph()
    setStatus(`E2E 2/${total}: first repaint (misses/conversions rise).`, COLOR_WARNING)
    refreshView(renderer)
    await sleep(750)

    toggleSwatchGlyph()
    setStatus(`E2E 3/${total}: steady repaint (hits rise, conversions flatten).`, COLOR_WARNING)
    refreshView(renderer)
    await sleep(750)

    applyPresetPalette(renderer, "solarized-dark", { resetStats: false })
    setStatus(`E2E 4/${total}: palette switch (epoch and misses rise).`, COLOR_WARNING)
    refreshView(renderer)
    await sleep(850)

    toggleSwatchGlyph()
    setStatus(`E2E 5/${total}: post-switch repaint (hits rise again).`, COLOR_WARNING)
    refreshView(renderer)
    await sleep(850)

    setStatus("Visual checklist complete. Press c to reset or rerun with v.", COLOR_SUCCESS)
    refreshView(renderer)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    setStatus(`Visual checklist failed (${message}).`, COLOR_ERROR)
    refreshView(renderer)
  } finally {
    visualChecklistRunning = false
  }
}

type ChecklistSnapshot = {
  label: string
  mode: string
  palette: PalettePresetName
  scenario: ScenarioMode
  glyph: string
  conversions: number
  cache_hits: number
  cache_misses: number
  cache_size: number
  palette_epoch: number
}

function snapshotStats(renderer: CliRenderer, label: string): ChecklistSnapshot {
  const stats = readColorDebugStats(renderer)
  return {
    label,
    mode: colorModeLabel(renderer),
    palette: palettePreset,
    scenario: scenarioMode,
    glyph: swatchGlyph,
    conversions: stats.conversions,
    cache_hits: stats.cache_hits,
    cache_misses: stats.cache_misses,
    cache_size: stats.cache_size,
    palette_epoch: stats.palette_epoch,
  }
}

type ChecklistReport = {
  passed: boolean
  checks: {
    nonTruecolorMode: boolean
    firstPassMissesGrow: boolean
    steadyHitsGrow: boolean
    steadyConversionsFlat: boolean
    paletteEpochIncrements: boolean
    paletteSwitchMissesGrow: boolean
    postSwitchHitsGrow: boolean
    postSwitchConversionsFlat: boolean
  }
  samples: ChecklistSnapshot[]
  notes: {
    forceColorMode: string | null
    rendererMode: string
  }
}

export async function runChecklistCase(): Promise<ChecklistReport> {
  process.env.OPENTUI_FORCE_COLOR_MODE ??= "256"

  const { createTestRenderer } = await import("../testing/test-renderer.js")
  const { renderer, renderOnce } = await createTestRenderer({
    width: 120,
    height: 28,
    useThread: false,
  })

  try {
    run(renderer, { autoDetectPalette: false })
    await renderOnce()
    await renderOnce()

    resetColorStats(renderer, true)
    refreshView(renderer)
    await renderOnce()
    await renderOnce()
    const baseline = snapshotStats(renderer, "baseline")

    toggleSwatchGlyph()
    refreshView(renderer)
    await renderOnce()
    await renderOnce()
    const firstRepaint = snapshotStats(renderer, "first_repaint")

    toggleSwatchGlyph()
    refreshView(renderer)
    await renderOnce()
    await renderOnce()
    const steadyRepaint = snapshotStats(renderer, "steady_repaint")

    const beforePaletteSwitch = snapshotStats(renderer, "before_palette_switch")
    publishPresetPalette(renderer, "solarized-dark")
    await renderOnce()
    await renderOnce()
    const afterPaletteSwitch = snapshotStats(renderer, "after_palette_switch")

    toggleSwatchGlyph()
    refreshView(renderer)
    await renderOnce()
    await renderOnce()
    const afterPaletteRepaint = snapshotStats(renderer, "after_palette_repaint")

    const checks = {
      nonTruecolorMode: afterPaletteRepaint.mode !== "truecolor",
      firstPassMissesGrow: firstRepaint.cache_misses > baseline.cache_misses,
      steadyHitsGrow: steadyRepaint.cache_hits > firstRepaint.cache_hits,
      steadyConversionsFlat: steadyRepaint.conversions === firstRepaint.conversions,
      paletteEpochIncrements: afterPaletteSwitch.palette_epoch > beforePaletteSwitch.palette_epoch,
      paletteSwitchMissesGrow: afterPaletteSwitch.cache_misses > beforePaletteSwitch.cache_misses,
      postSwitchHitsGrow: afterPaletteRepaint.cache_hits > afterPaletteSwitch.cache_hits,
      postSwitchConversionsFlat: afterPaletteRepaint.conversions === afterPaletteSwitch.conversions,
    }

    const passed = Object.values(checks).every(Boolean)
    const report: ChecklistReport = {
      passed,
      checks,
      samples: [baseline, firstRepaint, steadyRepaint, beforePaletteSwitch, afterPaletteSwitch, afterPaletteRepaint],
      notes: {
        forceColorMode: process.env.OPENTUI_FORCE_COLOR_MODE ?? null,
        rendererMode: "test-renderer",
      },
    }

    return report
  } finally {
    destroy(renderer)
    renderer.destroy()
  }
}

export function run(renderer: CliRenderer, options: RunOptions = {}): void {
  const autoDetectPalette = options.autoDetectPalette ?? true

  renderer.start()
  renderer.setBackgroundColor(COLOR_BG)

  applyPalette(buildPresetPalette("xterm"), "xterm")
  publishPalette(renderer, buildPresetPalette("xterm"))
  resetColorStats(renderer, true)

  rootContainer = new BoxRenderable(renderer, {
    id: "rgbaa-indexed-demo",
    width: "100%",
    height: "100%",
    flexDirection: "column",
    padding: 1,
    gap: 1,
  })
  renderer.root.add(rootContainer)

  const titleText = new TextRenderable(renderer, {
    id: "rgbaa-title",
    content: "RGBA+A Indexed Color Demo (native routing)",
    fg: COLOR_TITLE,
    attributes: TextAttributes.BOLD,
    height: 1,
  })
  rootContainer.add(titleText)

  terminalInfoText = new TextRenderable(renderer, {
    id: "rgbaa-terminal-info",
    content: "Terminal: detecting...",
    fg: COLOR_MUTED,
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(terminalInfoText)

  statusText = new TextRenderable(renderer, {
    id: "rgbaa-status",
    content: "Palette: xterm preset published",
    fg: COLOR_SUCCESS,
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(statusText)

  const instructions = new TextRenderable(renderer, {
    id: "rgbaa-instructions",
    content: "Keys: space repaint, u scenario, 1/2 preset, p/r detect, c reset, v e2e",
    fg: COLOR_MUTED,
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(instructions)

  rgbFallbackLineText = new TextRenderable(renderer, {
    id: "rgbaa-rgb-fallback-line",
    content: "",
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(rgbFallbackLineText)

  explicitIndexedLineText = new TextRenderable(renderer, {
    id: "rgbaa-indexed-line",
    content: "",
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(explicitIndexedLineText)

  defaultIntentLineText = new TextRenderable(renderer, {
    id: "rgbaa-default-line",
    content: "",
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(defaultIntentLineText)

  paletteTopText = new TextRenderable(renderer, {
    id: "rgbaa-palette-top",
    content: "",
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(paletteTopText)

  paletteBottomText = new TextRenderable(renderer, {
    id: "rgbaa-palette-bottom",
    content: "",
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(paletteBottomText)

  cacheStatsText = new TextRenderable(renderer, {
    id: "rgbaa-cache-stats",
    content: "",
    fg: COLOR_MUTED,
    height: 2,
    wrapMode: "word",
  })
  rootContainer.add(cacheStatsText)

  footerText = new TextRenderable(renderer, {
    id: "rgbaa-footer",
    content: "",
    fg: COLOR_MUTED,
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(footerText)

  updateTerminalInfo(renderer)
  refreshView(renderer)

  frameCallback = async () => {
    updateStatsLabel(renderer)
  }
  renderer.setFrameCallback(frameCallback)

  keyListener = async (key: KeyEvent) => {
    if (key.name === "space") {
      toggleSwatchGlyph()
      refreshView(renderer)
      return
    }

    if (key.name === "v") {
      void runVisualChecklist(renderer)
      return
    }

    if (key.name === "u") {
      scenarioMode = scenarioMode === "reused" ? "unique" : "reused"
      resetColorStats(renderer, true)
      setStatus(`Scenario switched to ${scenarioMode}. Repaint with space to compare cache reuse.`, COLOR_SUCCESS)
      refreshView(renderer)
      return
    }

    if (key.name === "c") {
      resetColorStats(renderer, true)
      setStatus("Renderer RGB->index stats and cache cleared.", COLOR_SUCCESS)
      refreshView(renderer)
      return
    }

    if (key.name === "1") {
      publishPresetPalette(renderer, "xterm")
      return
    }

    if (key.name === "2") {
      publishPresetPalette(renderer, "solarized-dark")
      return
    }

    if (key.name === "p") {
      await detectPalette(renderer, false)
      return
    }

    if (key.name === "r") {
      await detectPalette(renderer, true)
    }
  }

  renderer.keyInput.on("keypress", keyListener)
  if (autoDetectPalette) {
    void detectPalette(renderer, false)
  }
}

export function destroy(renderer: CliRenderer): void {
  if (keyListener) {
    renderer.keyInput.off("keypress", keyListener)
    keyListener = null
  }

  if (frameCallback) {
    renderer.removeFrameCallback(frameCallback)
    frameCallback = null
  }

  if (rootContainer) {
    renderer.root.remove(rootContainer.id)
    rootContainer.destroyRecursively()
    rootContainer = null
  }

  terminalInfoText = null
  statusText = null
  rgbFallbackLineText = null
  explicitIndexedLineText = null
  defaultIntentLineText = null
  paletteTopText = null
  paletteBottomText = null
  cacheStatsText = null
  footerText = null

  scenarioMode = "reused"
  palettePreset = "xterm"
  swatchGlyph = "█"
  fullPalette = normalizeTerminalPalette(null).palette
  visiblePalette = fullPalette.slice(0, 16)
  lastStatsLabel = ""
  visualChecklistRunning = false
}

if (import.meta.main) {
  if (process.argv.includes("--checklist") || process.env.RGBAA_DEMO_CHECKLIST === "1") {
    const report = await runChecklistCase()
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`)
    if (!report.passed) {
      process.exitCode = 1
    }
  } else {
    process.env.OPENTUI_FORCE_COLOR_MODE ??= "256"

    const renderer = await createCliRenderer({
      exitOnCtrlC: true,
    })
    run(renderer)
    setupCommonDemoKeys(renderer)
  }
}
