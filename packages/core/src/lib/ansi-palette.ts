export type RGBTriplet = readonly [number, number, number]
export type ColorKind = "rgb" | "indexed" | "default"

export const COLOR_TAG_RGB = 256
export const COLOR_TAG_DEFAULT = 257

const ANSI16_RGB: readonly RGBTriplet[] = [
  [0x00, 0x00, 0x00],
  [0x80, 0x00, 0x00],
  [0x00, 0x80, 0x00],
  [0x80, 0x80, 0x00],
  [0x00, 0x00, 0x80],
  [0x80, 0x00, 0x80],
  [0x00, 0x80, 0x80],
  [0xc0, 0xc0, 0xc0],
  [0x80, 0x80, 0x80],
  [0xff, 0x00, 0x00],
  [0x00, 0xff, 0x00],
  [0xff, 0xff, 0x00],
  [0x00, 0x00, 0xff],
  [0xff, 0x00, 0xff],
  [0x00, 0xff, 0xff],
  [0xff, 0xff, 0xff],
]

const ANSI_256_CUBE_LEVELS = [0, 95, 135, 175, 215, 255] as const

export const DEFAULT_FOREGROUND_RGB: RGBTriplet = [255, 255, 255]
export const DEFAULT_BACKGROUND_RGB: RGBTriplet = [0, 0, 0]

export function normalizeIndexedColorIndex(index: number): number {
  if (!Number.isInteger(index) || index < 0 || index > 255) {
    throw new RangeError(`Indexed color must be an integer in the range 0..255, got ${index}`)
  }

  return index
}

export function ansi256IndexToRgb(index: number): RGBTriplet {
  const normalizedIndex = normalizeIndexedColorIndex(index)

  if (normalizedIndex < ANSI16_RGB.length) {
    return ANSI16_RGB[normalizedIndex]
  }

  if (normalizedIndex < 232) {
    const cubeIndex = normalizedIndex - 16
    const r = Math.floor(cubeIndex / 36)
    const g = Math.floor(cubeIndex / 6) % 6
    const b = cubeIndex % 6
    return [ANSI_256_CUBE_LEVELS[r], ANSI_256_CUBE_LEVELS[g], ANSI_256_CUBE_LEVELS[b]]
  }

  const value = 8 + (normalizedIndex - 232) * 10
  return [value, value, value]
}

export function decodeColorTag(tag: number): { kind: ColorKind; index?: number } {
  if (tag === COLOR_TAG_DEFAULT) {
    return { kind: "default" }
  }

  if (tag === COLOR_TAG_RGB) {
    return { kind: "rgb" }
  }

  return { kind: "indexed", index: normalizeIndexedColorIndex(tag) }
}
