import { RGBA, parseColor, type ColorInput } from "./RGBA.js"
import type { TerminalColors } from "./terminal-palette.js"

export const COLOR_TAG_RGB = 256
export const COLOR_TAG_DEFAULT = 257

export type ColorTag = number
export type ColorKind = "rgb" | "indexed" | "default"

export interface RGBColorValue {
  kind: "rgb"
  rgba: ColorInput
}

export interface IndexedColorValue {
  kind: "indexed"
  index: number
  rgba?: ColorInput
}

export interface DefaultColorValue {
  kind: "default"
  rgba?: ColorInput
}

export type ColorValue = RGBColorValue | IndexedColorValue | DefaultColorValue
export type ColorValueInput = ColorInput | ColorValue

type PreparedRGBColorValue = {
  kind: "rgb"
  rgba: RGBA
}

type PreparedIndexedColorValue = {
  kind: "indexed"
  index: number
  rgba?: RGBA
}

type PreparedDefaultColorValue = {
  kind: "default"
  rgba?: RGBA
}

type PreparedColorValueInput = RGBA | PreparedRGBColorValue | PreparedIndexedColorValue | PreparedDefaultColorValue

export interface NormalizedColorValue {
  rgba: RGBA
  tag: ColorTag
}

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

const ANSI_256_CUBE_LEVELS = [0, 95, 135, 175, 215, 255] as const
const DEFAULT_FOREGROUND_FALLBACK = RGBA.fromInts(255, 255, 255)
const DEFAULT_BACKGROUND_FALLBACK = RGBA.fromInts(0, 0, 0)

let fallbackAnsi256Palette: RGBA[] | null = null

function cloneRgba(rgba: RGBA): RGBA {
  return RGBA.fromValues(rgba.r, rgba.g, rgba.b, rgba.a)
}

function buildFallbackAnsi256Palette(): RGBA[] {
  const palette = ANSI16_HEX.map((hex) => RGBA.fromHex(hex))

  for (const r of ANSI_256_CUBE_LEVELS) {
    for (const g of ANSI_256_CUBE_LEVELS) {
      for (const b of ANSI_256_CUBE_LEVELS) {
        palette.push(RGBA.fromInts(r, g, b))
      }
    }
  }

  for (let i = 0; i < 24; i++) {
    const value = 8 + i * 10
    palette.push(RGBA.fromInts(value, value, value))
  }

  return palette
}

function normalizeIndexedColorIndex(index: number): number {
  if (!Number.isInteger(index) || index < 0 || index > 255) {
    throw new RangeError(`Indexed color must be an integer in the range 0..255, got ${index}`)
  }

  return index
}

function resolvePreparedColorInput(value: ColorValueInput): PreparedColorValueInput {
  if (typeof value === "string" || value instanceof RGBA) {
    return parseColor(value)
  }

  if (value.kind === "rgb") {
    return {
      kind: "rgb",
      rgba: parseColor(value.rgba),
    }
  }

  if (value.kind === "indexed") {
    return {
      kind: "indexed",
      index: normalizeIndexedColorIndex(value.index),
      rgba: value.rgba ? parseColor(value.rgba) : undefined,
    }
  }

  return {
    kind: "default",
    rgba: value.rgba ? parseColor(value.rgba) : undefined,
  }
}

function isColorValue(value: unknown): value is ColorValue {
  if (!value || typeof value !== "object") return false
  const maybeColor = value as Partial<ColorValue>
  return maybeColor.kind === "rgb" || maybeColor.kind === "indexed" || maybeColor.kind === "default"
}

export function prepareColorValueInput(value: ColorValueInput | null | undefined): PreparedColorValueInput | null | undefined {
  if (value == null) return value
  return resolvePreparedColorInput(value)
}

export function getFallbackAnsi256Palette(): readonly RGBA[] {
  if (!fallbackAnsi256Palette) {
    fallbackAnsi256Palette = buildFallbackAnsi256Palette()
  }

  return fallbackAnsi256Palette
}

export function getDefaultForegroundFallback(): RGBA {
  return DEFAULT_FOREGROUND_FALLBACK
}

export function getDefaultBackgroundFallback(): RGBA {
  return DEFAULT_BACKGROUND_FALLBACK
}

export function rgbColor(rgba: ColorInput): RGBColorValue {
  return { kind: "rgb", rgba }
}

export function indexedColor(index: number, rgba?: ColorInput): IndexedColorValue {
  return { kind: "indexed", index, rgba }
}

export function defaultColor(rgba?: ColorInput): DefaultColorValue {
  return { kind: "default", rgba }
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

export function normalizeColorValue(
  value: ColorValueInput | null | undefined,
  options: {
    palette?: readonly RGBA[]
    defaultFg?: RGBA
    defaultBg?: RGBA
    role?: "fg" | "bg"
  } = {},
): NormalizedColorValue | null {
  if (value == null) return null

  const preparedValue = resolvePreparedColorInput(value)
  if (preparedValue instanceof RGBA) {
    return {
      rgba: preparedValue,
      tag: COLOR_TAG_RGB,
    }
  }

  if (preparedValue.kind === "rgb") {
    return {
      rgba: preparedValue.rgba as RGBA,
      tag: COLOR_TAG_RGB,
    }
  }

  if (preparedValue.kind === "indexed") {
    const palette = options.palette ?? getFallbackAnsi256Palette()
    const index = normalizeIndexedColorIndex(preparedValue.index)
    const snapshot = preparedValue.rgba
      ? (preparedValue.rgba as RGBA)
      : cloneRgba(palette[index] ?? getFallbackAnsi256Palette()[index] ?? DEFAULT_FOREGROUND_FALLBACK)

    return {
      rgba: snapshot,
      tag: index,
    }
  }

  const fallbackSnapshot = options.role === "bg" ? options.defaultBg ?? DEFAULT_BACKGROUND_FALLBACK : options.defaultFg ?? DEFAULT_FOREGROUND_FALLBACK
  const snapshot = preparedValue.rgba ? (preparedValue.rgba as RGBA) : cloneRgba(fallbackSnapshot)

  return {
    rgba: snapshot,
    tag: COLOR_TAG_DEFAULT,
  }
}

export function colorValuesEqual(a: NormalizedColorValue | null | undefined, b: NormalizedColorValue | null | undefined): boolean {
  if (a === b) return true
  if (!a || !b) return false

  return a.tag === b.tag && a.rgba.equals(b.rgba)
}

export function normalizeTerminalPalette(colors?: TerminalColors | null): {
  palette: RGBA[]
  defaultForeground: RGBA
  defaultBackground: RGBA
} {
  const fallbackPalette = getFallbackAnsi256Palette()

  return {
    palette: Array.from({ length: 256 }, (_, index) => {
      const detected = colors?.palette[index]
      return detected ? RGBA.fromHex(detected) : fallbackPalette[index]
    }),
    defaultForeground: colors?.defaultForeground ? RGBA.fromHex(colors.defaultForeground) : cloneRgba(DEFAULT_FOREGROUND_FALLBACK),
    defaultBackground: colors?.defaultBackground ? RGBA.fromHex(colors.defaultBackground) : cloneRgba(DEFAULT_BACKGROUND_FALLBACK),
  }
}

export function buildTerminalPaletteSignature(colors?: TerminalColors | null): string {
  const normalized = normalizeTerminalPalette(colors)
  const paletteSignature = normalized.palette.map((color) => color.toInts().join(",")).join(";")
  return [paletteSignature, normalized.defaultForeground.toInts().join(","), normalized.defaultBackground.toInts().join(",")].join("|")
}

export function colorValueToRgba(value: ColorValueInput | null | undefined, role: "fg" | "bg" = "fg"): RGBA | null {
  return normalizeColorValue(value, { role })?.rgba ?? null
}

export { isColorValue }
