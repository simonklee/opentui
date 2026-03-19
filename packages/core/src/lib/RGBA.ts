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
const COLOR_TAG_DEFAULT = 257
const RGBA_INTENT_TAG = Symbol("@opentui/core/RGBA.intent-tag")

type IntentfulRGBA = RGBA & {
  [RGBA_INTENT_TAG]?: number
}

function normalizeIndexedColorIndex(index: number): number {
  if (!Number.isInteger(index) || index < 0 || index > 255) {
    throw new RangeError(`Indexed color must be an integer in the range 0..255, got ${index}`)
  }

  return index
}

function setIntentTag(rgba: RGBA, tag: number | undefined): RGBA {
  const intentful = rgba as IntentfulRGBA

  if (tag === undefined) {
    delete intentful[RGBA_INTENT_TAG]
    return rgba
  }

  intentful[RGBA_INTENT_TAG] = tag
  return rgba
}

function rgbaForAnsi256Index(index: number): RGBA {
  const normalizedIndex = normalizeIndexedColorIndex(index)

  if (normalizedIndex < 16) {
    return RGBA.fromHex(ANSI16_HEX[normalizedIndex])
  }

  if (normalizedIndex < 232) {
    const cubeIndex = normalizedIndex - 16
    const r = Math.floor(cubeIndex / 36)
    const g = Math.floor(cubeIndex / 6) % 6
    const b = cubeIndex % 6
    return RGBA.fromInts(ANSI_256_CUBE_LEVELS[r], ANSI_256_CUBE_LEVELS[g], ANSI_256_CUBE_LEVELS[b])
  }

  const value = 8 + (normalizedIndex - 232) * 10
  return RGBA.fromInts(value, value, value)
}

export class RGBA {
  buffer: Float32Array

  constructor(buffer: Float32Array) {
    this.buffer = buffer
  }

  static fromArray(array: Float32Array) {
    return new RGBA(array)
  }

  static fromValues(r: number, g: number, b: number, a: number = 1.0) {
    return new RGBA(new Float32Array([r, g, b, a]))
  }

  static fromInts(r: number, g: number, b: number, a: number = 255) {
    return new RGBA(new Float32Array([r / 255, g / 255, b / 255, a / 255]))
  }

  static fromHex(hex: string): RGBA {
    return hexToRgb(hex)
  }

  static fromIndex(index: number, snapshot?: ColorInput): RGBA {
    return setIntentTag(snapshot ? parseColor(snapshot) : rgbaForAnsi256Index(index), normalizeIndexedColorIndex(index))
  }

  static defaultForeground(snapshot?: ColorInput): RGBA {
    return setIntentTag(snapshot ? parseColor(snapshot) : RGBA.fromInts(255, 255, 255), COLOR_TAG_DEFAULT)
  }

  static defaultBackground(snapshot?: ColorInput): RGBA {
    return setIntentTag(snapshot ? parseColor(snapshot) : RGBA.fromInts(0, 0, 0), COLOR_TAG_DEFAULT)
  }

  static getIntentTag(rgba: RGBA): number | undefined {
    return (rgba as IntentfulRGBA)[RGBA_INTENT_TAG]
  }

  static setIntentTag(rgba: RGBA, tag: number | undefined): RGBA {
    return setIntentTag(rgba, tag)
  }

  toInts(): [number, number, number, number] {
    return [Math.round(this.r * 255), Math.round(this.g * 255), Math.round(this.b * 255), Math.round(this.a * 255)]
  }

  get r(): number {
    return this.buffer[0]
  }

  set r(value: number) {
    this.buffer[0] = value
  }

  get g(): number {
    return this.buffer[1]
  }

  set g(value: number) {
    this.buffer[1] = value
  }

  get b(): number {
    return this.buffer[2]
  }

  set b(value: number) {
    this.buffer[2] = value
  }

  get a(): number {
    return this.buffer[3]
  }

  set a(value: number) {
    this.buffer[3] = value
  }

  map<R>(fn: (value: number) => R) {
    return [fn(this.r), fn(this.g), fn(this.b), fn(this.a)]
  }

  toString() {
    return `rgba(${this.r.toFixed(2)}, ${this.g.toFixed(2)}, ${this.b.toFixed(2)}, ${this.a.toFixed(2)})`
  }

  equals(other?: RGBA): boolean {
    if (!other) return false
    return this.r === other.r && this.g === other.g && this.b === other.b && this.a === other.a
  }
}

export type ColorInput = string | RGBA

export function hexToRgb(hex: string): RGBA {
  hex = hex.replace(/^#/, "")

  if (hex.length === 3) {
    hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2]
  } else if (hex.length === 4) {
    hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2] + hex[3] + hex[3]
  }

  if (!/^[0-9A-Fa-f]{6}$/.test(hex) && !/^[0-9A-Fa-f]{8}$/.test(hex)) {
    console.warn(`Invalid hex color: ${hex}, defaulting to magenta`)
    return RGBA.fromValues(1, 0, 1, 1)
  }

  const r = parseInt(hex.substring(0, 2), 16) / 255
  const g = parseInt(hex.substring(2, 4), 16) / 255
  const b = parseInt(hex.substring(4, 6), 16) / 255
  const a = hex.length === 8 ? parseInt(hex.substring(6, 8), 16) / 255 : 1

  return RGBA.fromValues(r, g, b, a)
}

export function rgbToHex(rgb: RGBA): string {
  const components = rgb.a === 1 ? [rgb.r, rgb.g, rgb.b] : [rgb.r, rgb.g, rgb.b, rgb.a]
  return (
    "#" +
    components
      .map((x) => {
        const hex = Math.floor(Math.max(0, Math.min(1, x) * 255)).toString(16)
        return hex.length === 1 ? "0" + hex : hex
      })
      .join("")
  )
}

export function hsvToRgb(h: number, s: number, v: number): RGBA {
  let r = 0,
    g = 0,
    b = 0

  const i = Math.floor(h / 60) % 6
  const f = h / 60 - Math.floor(h / 60)
  const p = v * (1 - s)
  const q = v * (1 - f * s)
  const t = v * (1 - (1 - f) * s)

  switch (i) {
    case 0:
      r = v
      g = t
      b = p
      break
    case 1:
      r = q
      g = v
      b = p
      break
    case 2:
      r = p
      g = v
      b = t
      break
    case 3:
      r = p
      g = q
      b = v
      break
    case 4:
      r = t
      g = p
      b = v
      break
    case 5:
      r = v
      g = p
      b = q
      break
  }

  return RGBA.fromValues(r, g, b, 1)
}

const CSS_COLOR_NAMES: Record<string, string> = {
  black: "#000000",
  white: "#FFFFFF",
  red: "#FF0000",
  green: "#008000",
  blue: "#0000FF",
  yellow: "#FFFF00",
  cyan: "#00FFFF",
  magenta: "#FF00FF",
  silver: "#C0C0C0",
  gray: "#808080",
  grey: "#808080",
  maroon: "#800000",
  olive: "#808000",
  lime: "#00FF00",
  aqua: "#00FFFF",
  teal: "#008080",
  navy: "#000080",
  fuchsia: "#FF00FF",
  purple: "#800080",
  orange: "#FFA500",
  brightblack: "#666666",
  brightred: "#FF6666",
  brightgreen: "#66FF66",
  brightblue: "#6666FF",
  brightyellow: "#FFFF66",
  brightcyan: "#66FFFF",
  brightmagenta: "#FF66FF",
  brightwhite: "#FFFFFF",
}

export function parseColor(color: ColorInput): RGBA {
  if (typeof color === "string") {
    const lowerColor = color.toLowerCase()

    if (lowerColor === "transparent") {
      return RGBA.fromValues(0, 0, 0, 0)
    }

    if (CSS_COLOR_NAMES[lowerColor]) {
      return hexToRgb(CSS_COLOR_NAMES[lowerColor])
    }

    return hexToRgb(color)
  }
  return color
}
