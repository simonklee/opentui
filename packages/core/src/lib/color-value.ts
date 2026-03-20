import { RGBA, parseColor, type ColorInput } from "./RGBA.js"
import {
  COLOR_TAG_DEFAULT,
  COLOR_TAG_RGB,
  DEFAULT_BACKGROUND_RGB,
  DEFAULT_FOREGROUND_RGB,
  ansi256IndexToRgb,
  normalizeIndexedColorIndex,
} from "./ansi-palette.js"
import type { TerminalColors } from "./terminal-palette.js"

export { COLOR_TAG_DEFAULT, COLOR_TAG_RGB }
export const PACKED_COLOR_STRIDE = 5

export type ColorTag = number
export type ColorKind = "rgb" | "indexed" | "default"

export interface NormalizedColorValue {
  rgba: RGBA
  tag: ColorTag
}

interface NormalizedTerminalPalette {
  palette: RGBA[]
  defaultForeground: RGBA
  defaultBackground: RGBA
}

const DEFAULT_FOREGROUND_FALLBACK = RGBA.fromInts(...DEFAULT_FOREGROUND_RGB)
const DEFAULT_BACKGROUND_FALLBACK = RGBA.fromInts(...DEFAULT_BACKGROUND_RGB)

let fallbackAnsi256Palette: RGBA[] | null = null

function buildFallbackAnsi256Palette(): RGBA[] {
  return Array.from({ length: 256 }, (_, index) => {
    const [r, g, b] = ansi256IndexToRgb(index)
    return RGBA.fromInts(r, g, b)
  })
}

function getNormalizedRGBAIntentTag(rgba: RGBA): ColorTag | undefined {
  const tag = RGBA.getIntentTag(rgba)

  if (tag === undefined) return undefined
  if (tag === COLOR_TAG_RGB || tag === COLOR_TAG_DEFAULT) return tag
  if (Number.isInteger(tag) && tag >= 0 && tag <= 255) return tag

  return undefined
}

export function getFallbackAnsi256Palette(): readonly RGBA[] {
  if (!fallbackAnsi256Palette) {
    fallbackAnsi256Palette = buildFallbackAnsi256Palette()
  }

  return fallbackAnsi256Palette
}

export function decodeColorTag(tag: ColorTag): { kind: ColorKind; index?: number } {
  if (tag === COLOR_TAG_DEFAULT) {
    return { kind: "default" }
  }

  if (tag === COLOR_TAG_RGB) {
    return { kind: "rgb" }
  }

  return { kind: "indexed", index: normalizeIndexedColorIndex(tag) }
}

export function normalizeColorValue(value: ColorInput | null | undefined): NormalizedColorValue | null {
  if (value == null) return null

  const rgba = parseColor(value)
  const tag = getNormalizedRGBAIntentTag(rgba) ?? COLOR_TAG_RGB

  return { rgba, tag }
}

export function packColorValueToF32(
  value: ColorInput | null | undefined,
  _role: "fg" | "bg",
  out: Float32Array,
): Float32Array | null {
  const normalized = normalizeColorValue(value)
  if (!normalized) return null

  out[0] = normalized.rgba.r
  out[1] = normalized.rgba.g
  out[2] = normalized.rgba.b
  out[3] = normalized.rgba.a
  out[4] = normalized.tag

  return out
}

export function normalizeTerminalPalette(colors?: TerminalColors | null): NormalizedTerminalPalette {
  const fallbackPalette = getFallbackAnsi256Palette()

  return {
    palette: Array.from({ length: 256 }, (_, index) => {
      const detected = colors?.palette[index]
      return detected ? RGBA.fromHex(detected) : fallbackPalette[index]
    }),
    defaultForeground: colors?.defaultForeground
      ? RGBA.fromHex(colors.defaultForeground)
      : RGBA.clone(DEFAULT_FOREGROUND_FALLBACK),
    defaultBackground: colors?.defaultBackground
      ? RGBA.fromHex(colors.defaultBackground)
      : RGBA.clone(DEFAULT_BACKGROUND_FALLBACK),
  }
}

export function buildTerminalPaletteSignature(colors?: TerminalColors | null): string {
  const normalized = normalizeTerminalPalette(colors)
  const paletteSignature = normalized.palette.map((color) => color.toInts().join(",")).join(";")

  return [
    paletteSignature,
    normalized.defaultForeground.toInts().join(","),
    normalized.defaultBackground.toInts().join(","),
  ].join("|")
}
