#!/usr/bin/env bun

import { writeFileSync } from "node:fs"

import { RGBA, StyledText, TextRenderable, indexedColor, type ColorValueInput } from "../index.js"
import type { TerminalColors } from "../lib/terminal-palette.js"
import type { TextChunk } from "../text-buffer.js"
import { createTestRenderer } from "../testing/test-renderer.js"

type BenchmarkTextChunk = Omit<TextChunk, "fg" | "bg"> & {
  fg?: ColorValueInput
}

interface ColorDebugStats {
  conversions: number
  cache_hits: number
  cache_misses: number
  cache_size: number
  palette_epoch: number
}

interface InternalPaletteDebugRenderer {
  publishPalette(colors: TerminalColors | null): void
  resetColorDebugStats(options?: { clearCache?: boolean }): void
  getColorDebugStats(): ColorDebugStats
}

function publishPalette(renderer: unknown, colors: TerminalColors | null): void {
  ;(renderer as InternalPaletteDebugRenderer).publishPalette(colors)
}

function resetColorDebugStats(renderer: unknown, options?: { clearCache?: boolean }): void {
  ;(renderer as InternalPaletteDebugRenderer).resetColorDebugStats(options)
}

function getColorDebugStats(renderer: unknown): ColorDebugStats {
  return (renderer as InternalPaletteDebugRenderer).getColorDebugStats()
}

type ScenarioName = "reused-rgb" | "unique-rgb" | "explicit-indexed"

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

const DEFAULT_FRAMES = 24
const DEFAULT_SWATCHES = 128
const DEFAULT_ROWS = 3

function getArg(name: string): string | null {
  const prefix = `--${name}=`
  for (const arg of process.argv.slice(2)) {
    if (arg.startsWith(prefix)) return arg.slice(prefix.length)
  }
  return null
}

function buildPalette(): TerminalColors {
  return {
    palette: [...XTERM_16_HEX],
    defaultForeground: "#ffffff",
    defaultBackground: "#000000",
    cursorColor: null,
    mouseForeground: null,
    mouseBackground: null,
    tekForeground: null,
    tekBackground: null,
    highlightBackground: null,
    highlightForeground: null,
  }
}

function chunk(text: string, options: { fg?: ColorValueInput; attributes?: number } = {}): BenchmarkTextChunk {
  return {
    __isChunk: true,
    text,
    fg: options.fg,
    attributes: options.attributes,
  }
}

function buildScenarioColors(name: ScenarioName, swatches: number): RGBA[] {
  if (name === "reused-rgb") {
    const palette = REUSED_BASE_HEX.map((hex) => RGBA.fromHex(hex))
    return Array.from({ length: swatches }, (_, index) => palette[index % palette.length])
  }

  if (name === "unique-rgb") {
    return Array.from({ length: swatches }, (_, index) => {
      const t = swatches <= 1 ? 0 : index / (swatches - 1)
      return RGBA.fromInts(
        Math.round(255 * t),
        Math.round(255 * (1 - Math.abs(0.5 - t) * 2)),
        Math.round(255 * (1 - t)),
      )
    })
  }

  return Array.from({ length: swatches }, (_, index) => RGBA.fromHex(XTERM_16_HEX[index % XTERM_16_HEX.length]))
}

function buildLine(name: ScenarioName, glyph: string, swatches: number): StyledText {
  const colors = buildScenarioColors(name, swatches)
  const chunks: BenchmarkTextChunk[] = []

  for (let index = 0; index < colors.length; index++) {
    const color = colors[index]
    const fg = name === "explicit-indexed" ? indexedColor(index % 16, color) : color
    chunks.push(chunk(glyph, { fg }))
  }

  return new StyledText(chunks as TextChunk[])
}

function buildBenchmarkFrame(glyph: string, swatches: number, rows: number, scenario: ScenarioName): StyledText {
  const chunks: BenchmarkTextChunk[] = []

  for (let row = 0; row < rows; row++) {
    chunks.push(...buildLine(scenario, glyph, swatches).chunks)
    if (row < rows - 1) chunks.push(chunk("\n"))
  }

  return new StyledText(chunks as TextChunk[])
}

function diffStats(a: ColorDebugStats, b: ColorDebugStats): ColorDebugStats {
  return {
    conversions: b.conversions - a.conversions,
    cache_hits: b.cache_hits - a.cache_hits,
    cache_misses: b.cache_misses - a.cache_misses,
    cache_size: b.cache_size,
    palette_epoch: b.palette_epoch,
  }
}

async function main(): Promise<void> {
  const frames = Number(getArg("frames") ?? DEFAULT_FRAMES)
  const swatches = Number(getArg("swatches") ?? DEFAULT_SWATCHES)
  const rows = Number(getArg("rows") ?? DEFAULT_ROWS)
  const outputJson = getArg("json")

  process.env.OPENTUI_FORCE_COLOR_MODE ??= "256"

  const { renderer, renderOnce } = await createTestRenderer({
    width: Math.max(swatches + 20, 120),
    height: Math.max(rows + 4, 8),
    useThread: false,
  })

  publishPalette(renderer, buildPalette())

  const renderable = new TextRenderable(renderer, {
    id: "rgbaa-indexed-benchmark",
    width: "100%",
    height: rows,
    content: "",
  })
  renderer.root.add(renderable)

  const scenarioResults: Array<Record<string, unknown>> = []

  for (const scenario of ["reused-rgb", "unique-rgb", "explicit-indexed"] as const) {
    resetColorDebugStats(renderer, { clearCache: true })

    renderable.content = buildBenchmarkFrame("█", swatches, rows, scenario)
    const firstStart = performance.now()
    await renderOnce()
    const firstElapsedMs = performance.now() - firstStart
    const firstStats = getColorDebugStats(renderer)

    const steadyStart = performance.now()
    for (let frame = 1; frame < frames; frame++) {
      const glyph = frame % 2 === 0 ? "█" : "▓"
      renderable.content = buildBenchmarkFrame(glyph, swatches, rows, scenario)
      await renderOnce()
    }
    const steadyElapsedMs = performance.now() - steadyStart
    const finalStats = getColorDebugStats(renderer)
    const steadyStats = diffStats(firstStats, finalStats)

    scenarioResults.push({
      scenario,
      frames,
      swatchesPerRow: swatches,
      rows,
      cellsPerFrame: swatches * rows,
      firstFrame: {
        elapsedMs: Number(firstElapsedMs.toFixed(3)),
        conversions: firstStats.conversions,
        cacheHits: firstStats.cache_hits,
        cacheMisses: firstStats.cache_misses,
      },
      steadyState: {
        totalElapsedMs: Number(steadyElapsedMs.toFixed(3)),
        avgElapsedMs: Number((steadyElapsedMs / Math.max(frames - 1, 1)).toFixed(3)),
        conversions: steadyStats.conversions,
        cacheHits: steadyStats.cache_hits,
        cacheMisses: steadyStats.cache_misses,
      },
      final: finalStats,
    })
  }

  renderer.destroy()

  const payload = {
    forcedColorMode: process.env.OPENTUI_FORCE_COLOR_MODE ?? null,
    frames,
    swatches,
    rows,
    results: scenarioResults,
  }

  console.log(JSON.stringify(payload, null, 2))

  if (outputJson) {
    writeFileSync(outputJson, JSON.stringify(payload, null, 2))
  }
}

await main()
