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

interface InternalPalettePublisher {
  publishPalette(colors: TerminalColors | null): void
  _cachedPalette?: TerminalColors | null
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
let rgbSnapshotLineText: TextRenderable | null = null
let explicitIndexedLineText: TextRenderable | null = null
let defaultIntentLineText: TextRenderable | null = null
let paletteTopText: TextRenderable | null = null
let paletteBottomText: TextRenderable | null = null
let footerText: TextRenderable | null = null
let keyListener: ((key: KeyEvent) => void) | null = null

let scenarioMode: ScenarioMode = "reused"
let palettePreset: PalettePresetName = "xterm"
let swatchGlyph = "█"
let fullPalette: RGBA[] = normalizeTerminalPalette(null).palette
let visiblePalette: RGBA[] = fullPalette.slice(0, 16)
let paletteGeneration = 0
let previousPublishedPalette: TerminalColors | null | undefined = undefined

function publishPalette(renderer: CliRenderer, colors: TerminalColors | null): void {
  ;(renderer as unknown as InternalPalettePublisher).publishPalette(colors)
}

function getPublishedPalette(renderer: CliRenderer): TerminalColors | null {
  return (renderer as unknown as InternalPalettePublisher)._cachedPalette ?? null
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
    return Array.from({ length: count }, (_, index) => palette[index % palette.length])
  }

  return Array.from({ length: count }, (_, index) => {
    const t = count <= 1 ? 0 : index / (count - 1)
    return RGBA.fromInts(Math.round(255 * t), Math.round(255 * (1 - Math.abs(0.5 - t) * 2)), Math.round(255 * (1 - t)))
  })
}

function buildRgbSnapshotLine(label: string, colors: RGBA[]): StyledText {
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

function refreshView(renderer: CliRenderer): void {
  if (
    !rgbSnapshotLineText ||
    !explicitIndexedLineText ||
    !defaultIntentLineText ||
    !paletteTopText ||
    !paletteBottomText
  ) {
    return
  }

  const sourceColors = buildSourceColors(scenarioMode, SWATCH_COUNT)
  rgbSnapshotLineText.content = buildRgbSnapshotLine("RGB snapshot", sourceColors)
  explicitIndexedLineText.content = buildIndexedIntentLine("Explicit index", sourceColors)
  defaultIntentLineText.content = buildDefaultIntentLine()
  paletteTopText.content = buildPaletteLine("Palette 0-7", 0, 7)
  paletteBottomText.content = buildPaletteLine("Palette 8-F", 8, 15)

  if (footerText) {
    const scenarioLabel =
      scenarioMode === "reused" ? "eight repeated RGB swatches" : "a unique RGB gradient across the row"
    footerText.content = `Palette basis: ${palettePreset} | Scenario: ${scenarioLabel}`
  }

  renderer.requestRender()
}

function applyPresetPalette(renderer: CliRenderer, name: Exclude<PalettePresetName, "detected">): void {
  paletteGeneration += 1
  const colors = buildPresetPalette(name)
  applyPalette(colors, name)
  publishPalette(renderer, colors)
  updateTerminalInfo(renderer)
  setStatus(`Published ${name} palette preset.`, COLOR_SUCCESS)
  refreshView(renderer)
}

async function detectPalette(renderer: CliRenderer): Promise<void> {
  const generation = ++paletteGeneration
  setStatus("Detecting terminal palette via OSC queries...", COLOR_WARNING)

  try {
    renderer.clearPaletteCache()
    const colors = await renderer.getPalette({ size: 256 })

    if (!rootContainer || generation !== paletteGeneration) return

    applyPalette(colors, "detected")
    publishPalette(renderer, colors)
    updateTerminalInfo(renderer)
    setStatus("Published detected terminal palette.", COLOR_SUCCESS)
    refreshView(renderer)
  } catch (error) {
    if (!rootContainer || generation !== paletteGeneration) return

    const message = error instanceof Error ? error.message : String(error)
    setStatus(`Palette detection failed (${message}). Keeping current palette basis.`, COLOR_ERROR)
    updateTerminalInfo(renderer)
    refreshView(renderer)
  }
}

function toggleSwatchGlyph(): void {
  swatchGlyph = swatchGlyph === "█" ? "▓" : "█"
}

export function run(renderer: CliRenderer): void {
  renderer.start()
  renderer.setBackgroundColor(COLOR_BG)

  previousPublishedPalette = getPublishedPalette(renderer)

  const xtermPalette = buildPresetPalette("xterm")
  applyPalette(xtermPalette, "xterm")
  publishPalette(renderer, xtermPalette)

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
    content: "RGBA+A Indexed Color Demo",
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
    content: "Keys: space glyph, u scenario, 1/2 presets, p detect palette, Esc menu",
    fg: COLOR_MUTED,
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(instructions)

  rgbSnapshotLineText = new TextRenderable(renderer, {
    id: "rgbaa-rgb-snapshot-line",
    content: "",
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(rgbSnapshotLineText)

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

  keyListener = async (key: KeyEvent) => {
    if (key.name === "space") {
      toggleSwatchGlyph()
      refreshView(renderer)
      return
    }

    if (key.name === "u") {
      scenarioMode = scenarioMode === "reused" ? "unique" : "reused"
      setStatus(`Scenario switched to ${scenarioMode}.`, COLOR_SUCCESS)
      refreshView(renderer)
      return
    }

    if (key.name === "1") {
      applyPresetPalette(renderer, "xterm")
      return
    }

    if (key.name === "2") {
      applyPresetPalette(renderer, "solarized-dark")
      return
    }

    if (key.name === "p") {
      await detectPalette(renderer)
    }
  }

  renderer.keyInput.on("keypress", keyListener)
  void detectPalette(renderer)
}

export function destroy(renderer: CliRenderer): void {
  if (keyListener) {
    renderer.keyInput.off("keypress", keyListener)
    keyListener = null
  }

  if (previousPublishedPalette !== undefined) {
    publishPalette(renderer, previousPublishedPalette)
    previousPublishedPalette = undefined
  }

  if (rootContainer) {
    renderer.root.remove(rootContainer.id)
    rootContainer.destroyRecursively()
    rootContainer = null
  }

  terminalInfoText = null
  statusText = null
  rgbSnapshotLineText = null
  explicitIndexedLineText = null
  defaultIntentLineText = null
  paletteTopText = null
  paletteBottomText = null
  footerText = null

  scenarioMode = "reused"
  palettePreset = "xterm"
  swatchGlyph = "█"
  fullPalette = normalizeTerminalPalette(null).palette
  visiblePalette = fullPalette.slice(0, 16)
  paletteGeneration = 0
}

if (import.meta.main) {
  const renderer = await createCliRenderer({
    exitOnCtrlC: true,
  })
  run(renderer)
  setupCommonDemoKeys(renderer)
}
