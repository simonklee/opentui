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
import { StyledText } from "../lib/styled-text.js"
import type { TerminalColors } from "../lib/terminal-palette.js"
import type { TextChunk } from "../text-buffer.js"
import { setupCommonDemoKeys } from "./lib/standalone-keys.js"

type ScenarioMode = "reused" | "unique"

const SWATCH_COUNT = 32
const ANSI16_HEX = [
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
let sourceLineText: TextRenderable | null = null
let mappedLineText: TextRenderable | null = null
let mappedIndexText: TextRenderable | null = null
let paletteTopText: TextRenderable | null = null
let paletteBottomText: TextRenderable | null = null
let cacheStatsText: TextRenderable | null = null
let keyListener: ((key: KeyEvent) => void) | null = null

let scenarioMode: ScenarioMode = "reused"
let paletteEpoch = 0
let activePalette: RGBA[] = ANSI16_HEX.map((hex) => RGBA.fromHex(hex))

const conversionCache = new Map<string, number>()
let cacheHits = 0
let cacheMisses = 0
let conversionCount = 0

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

function resetConversionCache(): void {
  conversionCache.clear()
  cacheHits = 0
  cacheMisses = 0
  conversionCount = 0
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
  const key = colorKey(rgb)
  const cached = conversionCache.get(key)
  if (cached !== undefined) {
    cacheHits++
    return cached
  }

  cacheMisses++
  conversionCount++

  let bestIndex = 0
  let bestDistance = Number.POSITIVE_INFINITY

  for (let i = 0; i < activePalette.length; i++) {
    const distance = rgbDistanceSquared(rgb, activePalette[i])
    if (distance < bestDistance) {
      bestDistance = distance
      bestIndex = i
    }
  }

  conversionCache.set(key, bestIndex)
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

function buildSwatchLine(label: string, colors: RGBA[]): StyledText {
  const chunks: TextChunk[] = [
    chunk(label.padEnd(14), { fg: COLOR_LABEL, attributes: TextAttributes.BOLD }),
    chunk(" "),
  ]

  for (let i = 0; i < colors.length; i++) {
    chunks.push(chunk("█", { fg: colors[i] }))
    if ((i + 1) % 8 === 0) {
      chunks.push(chunk(" "))
    }
  }

  return new StyledText(chunks)
}

function buildIndexLine(indices: number[]): StyledText {
  const chunks: TextChunk[] = [
    chunk("Palette index".padEnd(14), { fg: COLOR_LABEL, attributes: TextAttributes.BOLD }),
    chunk(" "),
  ]

  for (let i = 0; i < indices.length; i++) {
    chunks.push(chunk(indices[i].toString(16).toUpperCase(), { fg: COLOR_MUTED }))
    if ((i + 1) % 8 === 0) {
      chunks.push(chunk(" "))
    }
  }

  return new StyledText(chunks)
}

function buildPaletteLine(label: string, start: number, end: number): StyledText {
  const chunks: TextChunk[] = [
    chunk(label.padEnd(14), { fg: COLOR_LABEL, attributes: TextAttributes.BOLD }),
    chunk(" "),
  ]

  for (let i = start; i <= end; i++) {
    const color = activePalette[i]
    const fg = getContrastForBackground(color)
    chunks.push(chunk(` ${i.toString(16).toUpperCase()} `, { fg, bg: color }))
    chunks.push(chunk(" "))
  }

  return new StyledText(chunks)
}

function applyDetectedPalette(colors: TerminalColors): void {
  const fallback = ANSI16_HEX.map((hex) => RGBA.fromHex(hex))

  activePalette = fallback.map((fallbackColor, i) => {
    const detectedHex = colors.palette[i]
    return detectedHex ? RGBA.fromHex(detectedHex) : fallbackColor
  })
}

function updateTerminalInfo(renderer: CliRenderer): void {
  if (!terminalInfoText) return

  const caps = renderer.capabilities as
    | {
        rgb?: boolean
        terminal?: { name?: string; version?: string; from_xtversion?: boolean }
      }
    | null
    | undefined

  const termName = caps?.terminal?.name || "unknown"
  const termVersion = caps?.terminal?.version ? ` ${caps.terminal.version}` : ""
  const rgb = caps?.rgb ? "rgb=true" : "rgb=false"
  const source = caps?.terminal?.from_xtversion ? "xtversion" : "env/caps"

  terminalInfoText.content = `Terminal: ${termName}${termVersion} | ${rgb} | detected via ${source}`
}

function setStatus(message: string, color: RGBA): void {
  if (!statusText) return
  statusText.content = message
  statusText.fg = color
}

function refreshView(renderer: CliRenderer): void {
  if (
    !sourceLineText ||
    !mappedLineText ||
    !mappedIndexText ||
    !paletteTopText ||
    !paletteBottomText ||
    !cacheStatsText
  ) {
    return
  }

  const sourceColors = buildSourceColors(scenarioMode, SWATCH_COUNT)
  const mappedIndices: number[] = []
  const mappedColors = sourceColors.map((color) => {
    const idx = nearestPaletteIndex(color)
    mappedIndices.push(idx)
    return activePalette[idx] ?? color
  })

  sourceLineText.content = buildSwatchLine("RGB input", sourceColors)
  mappedLineText.content = buildSwatchLine("Indexed map", mappedColors)
  mappedIndexText.content = buildIndexLine(mappedIndices)
  paletteTopText.content = buildPaletteLine("Palette 0-7", 0, 7)
  paletteBottomText.content = buildPaletteLine("Palette 8-F", 8, 15)

  cacheStatsText.content =
    `Scenario=${scenarioMode} | palette_epoch=${paletteEpoch} | cache_size=${conversionCache.size} | ` +
    `conversions=${conversionCount} hits=${cacheHits} misses=${cacheMisses}`

  renderer.requestRender()
}

async function refreshPalette(renderer: CliRenderer, clearRendererCache: boolean): Promise<void> {
  try {
    setStatus("Palette: detecting via OSC queries...", COLOR_WARNING)

    if (clearRendererCache) {
      renderer.clearPaletteCache()
    }

    const colors = await renderer.getPalette({ size: 16 })
    applyDetectedPalette(colors)
    paletteEpoch += 1
    resetConversionCache()
    setStatus(`Palette: detected/updated (epoch=${paletteEpoch}). Cache reset.`, COLOR_SUCCESS)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    setStatus(`Palette: detection failed (${message}). Using ANSI fallback palette.`, COLOR_ERROR)
  }

  updateTerminalInfo(renderer)
  refreshView(renderer)
}

export function run(renderer: CliRenderer): void {
  renderer.start()
  renderer.setBackgroundColor(COLOR_BG)

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
    content: "RGBA+A Indexed Color Demo (current branch simulation)",
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
    content: "Palette: pending detection",
    fg: COLOR_WARNING,
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(statusText)

  const instructions = new TextRenderable(renderer, {
    id: "rgbaa-instructions",
    content:
      "Keys: p=refresh palette, r=clear palette cache + refresh, c=clear conversion cache, u=toggle reused/unique, space=replay frame",
    fg: COLOR_MUTED,
    height: 2,
  })
  rootContainer.add(instructions)

  sourceLineText = new TextRenderable(renderer, {
    id: "rgbaa-source-line",
    content: "",
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(sourceLineText)

  mappedLineText = new TextRenderable(renderer, {
    id: "rgbaa-mapped-line",
    content: "",
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(mappedLineText)

  mappedIndexText = new TextRenderable(renderer, {
    id: "rgbaa-index-line",
    content: "",
    height: 1,
    wrapMode: "none",
  })
  rootContainer.add(mappedIndexText)

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
    wrapMode: "none",
  })
  rootContainer.add(cacheStatsText)

  updateTerminalInfo(renderer)
  resetConversionCache()
  refreshView(renderer)

  keyListener = async (key: KeyEvent) => {
    if (key.name === "u") {
      scenarioMode = scenarioMode === "reused" ? "unique" : "reused"
      resetConversionCache()
      setStatus(`Scenario switched to ${scenarioMode}. Conversion cache reset.`, COLOR_SUCCESS)
      refreshView(renderer)
      return
    }

    if (key.name === "c") {
      resetConversionCache()
      setStatus("Conversion cache cleared.", COLOR_SUCCESS)
      refreshView(renderer)
      return
    }

    if (key.name === "space") {
      refreshView(renderer)
      return
    }

    if (key.name === "p") {
      await refreshPalette(renderer, false)
      return
    }

    if (key.name === "r") {
      await refreshPalette(renderer, true)
    }
  }

  renderer.keyInput.on("keypress", keyListener)

  void refreshPalette(renderer, false)
}

export function destroy(renderer: CliRenderer): void {
  if (keyListener) {
    renderer.keyInput.off("keypress", keyListener)
    keyListener = null
  }

  if (rootContainer) {
    renderer.root.remove(rootContainer.id)
    rootContainer.destroyRecursively()
    rootContainer = null
  }

  terminalInfoText = null
  statusText = null
  sourceLineText = null
  mappedLineText = null
  mappedIndexText = null
  paletteTopText = null
  paletteBottomText = null
  cacheStatsText = null

  scenarioMode = "reused"
  paletteEpoch = 0
  activePalette = ANSI16_HEX.map((hex) => RGBA.fromHex(hex))
  resetConversionCache()
}

if (import.meta.main) {
  const renderer = await createCliRenderer({
    exitOnCtrlC: true,
  })
  run(renderer)
  setupCommonDemoKeys(renderer)
}
