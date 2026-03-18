#!/usr/bin/env bun

import {
  BoxRenderable,
  CliRenderer,
  createCliRenderer,
  RGBA,
  TextAttributes,
  TextRenderable,
  defaultColor,
  indexedColor,
  normalizeTerminalPalette,
  type ColorValueInput,
  type KeyEvent,
} from "../index.js"
import { StyledText } from "../lib/styled-text.js"
import type { TerminalColors } from "../lib/terminal-palette.js"
import type { TextChunk } from "../text-buffer.js"
import { setupCommonDemoKeys } from "./lib/standalone-keys.js"

type ScenarioMode = "reused" | "unique"
type PalettePresetName = "detected" | "xterm" | "solarized-dark"

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

function chunk(
  text: string,
  options: { fg?: ColorValueInput; bg?: ColorValueInput; attributes?: number } = {},
): TextChunk {
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
    chunks.push(chunk(swatchGlyph, { fg: indexedColor(index, colors[i]) }))
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
    chunk(" Header ", { fg: indexedColor(15, bright), bg: indexedColor(4, primary), attributes: TextAttributes.BOLD }),
    chunk("  "),
    chunk(" Button ", { fg: indexedColor(15, bright), bg: indexedColor(6, accent), attributes: TextAttributes.BOLD }),
    chunk("  "),
    chunk(" Warning ", { fg: warningFg, bg: indexedColor(3, warning), attributes: TextAttributes.BOLD }),
    chunk("  "),
    chunk(" defaults ", { fg: defaultColor(defaultSurfaceFg), bg: defaultColor(surface) }),
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
    chunks.push(chunk(` ${i.toString(16).toUpperCase()} `, { fg, bg: indexedColor(i, color) }))
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

  const stats = renderer.getColorDebugStats()
  const label =
    `palette=${palettePreset} mode=${colorModeLabel(renderer)} scenario=${scenarioMode}` +
    `\n` +
    `epoch=${stats.palette_epoch} cache=${stats.cache_size} conv=${stats.conversions} hits=${stats.cache_hits} misses=${stats.cache_misses}`

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
    process.env.OPENTUI_FORCE_COLOR_MODE === "256"
      ? "Forced ANSI256 mode active - press space to repaint swatches and watch cache hits climb."
      : "Tip: run with OPENTUI_FORCE_COLOR_MODE=256 to exercise RGB->index fallback and cache reuse."

  updateStatsLabel(renderer)
  renderer.requestRender()
}

function resetColorStats(renderer: CliRenderer, clearCache: boolean): void {
  renderer.resetColorDebugStats({ clearCache })
  lastStatsLabel = ""
}

function publishPresetPalette(renderer: CliRenderer, name: Exclude<PalettePresetName, "detected">): void {
  const colors = buildPresetPalette(name)
  applyPalette(colors, name)
  renderer.publishPalette(colors)
  resetColorStats(renderer, true)
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
    renderer.publishPalette(colors)
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

export function run(renderer: CliRenderer): void {
  renderer.start()
  renderer.setBackgroundColor(COLOR_BG)

  applyPalette(buildPresetPalette("xterm"), "xterm")
  renderer.publishPalette(buildPresetPalette("xterm"))
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
    content:
      "Keys: space=repaint swatches, u=toggle reused/unique RGB, 1=xterm palette, 2=solarized-dark, p=detect palette, r=redetect, c=reset stats/cache",
    fg: COLOR_MUTED,
    height: 2,
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
    height: 2,
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
  void detectPalette(renderer, false)
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
}

if (import.meta.main) {
  const renderer = await createCliRenderer({
    exitOnCtrlC: true,
  })
  run(renderer)
  setupCommonDemoKeys(renderer)
}
