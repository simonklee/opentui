import {
  COLOR_TAG_DEFAULT,
  DEFAULT_BACKGROUND_RGB,
  DEFAULT_FOREGROUND_RGB,
  ansi256IndexToRgb,
  normalizeIndexedColorIndex,
} from "./ansi-palette.js"

const RGBA_INTENT = Symbol("@opentui/core/RGBA.intent")

type IntentSnapshotMode = "explicit" | "implicit"
type IntentMetadata = {
  tag: number
  snapshotMode: IntentSnapshotMode
}

type IntentfulRGBA = RGBA & {
  [RGBA_INTENT]?: IntentMetadata
}

function withIntent(rgba: RGBA, tag: number | undefined, snapshotMode: IntentSnapshotMode = "explicit"): RGBA {
  const intentful = RGBA.clone(rgba) as IntentfulRGBA

  if (tag === undefined) {
    delete intentful[RGBA_INTENT]
    return intentful
  }

  intentful[RGBA_INTENT] = { tag, snapshotMode }
  return intentful
}

function rgbaForAnsi256Index(index: number): RGBA {
  const [r, g, b] = ansi256IndexToRgb(index)
  return RGBA.fromInts(r, g, b)
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

  static clone(rgba: RGBA) {
    return RGBA.fromValues(rgba.r, rgba.g, rgba.b, rgba.a)
  }

  static fromInts(r: number, g: number, b: number, a: number = 255) {
    return new RGBA(new Float32Array([r / 255, g / 255, b / 255, a / 255]))
  }

  static fromHex(hex: string): RGBA {
    return hexToRgb(hex)
  }

  static fromIndex(index: number, snapshot?: ColorInput): RGBA {
    const normalizedIndex = normalizeIndexedColorIndex(index)
    return withIntent(
      snapshot ? parseColor(snapshot) : rgbaForAnsi256Index(normalizedIndex),
      normalizedIndex,
      snapshot ? "explicit" : "implicit",
    )
  }

  static defaultForeground(snapshot?: ColorInput): RGBA {
    return withIntent(
      snapshot ? parseColor(snapshot) : RGBA.fromInts(...DEFAULT_FOREGROUND_RGB),
      COLOR_TAG_DEFAULT,
      snapshot ? "explicit" : "implicit",
    )
  }

  static defaultBackground(snapshot?: ColorInput): RGBA {
    return withIntent(
      snapshot ? parseColor(snapshot) : RGBA.fromInts(...DEFAULT_BACKGROUND_RGB),
      COLOR_TAG_DEFAULT,
      snapshot ? "explicit" : "implicit",
    )
  }

  static getIntentTag(rgba: RGBA): number | undefined {
    return (rgba as IntentfulRGBA)[RGBA_INTENT]?.tag
  }

  static getIntentMetadata(rgba: RGBA): { tag: number; snapshotMode: "explicit" | "implicit" } | undefined {
    const metadata = (rgba as IntentfulRGBA)[RGBA_INTENT]
    if (!metadata) return undefined

    return {
      tag: metadata.tag,
      snapshotMode: metadata.snapshotMode,
    }
  }

  static setIntentTag(rgba: RGBA, tag: number | undefined, snapshotMode: "explicit" | "implicit" = "explicit"): RGBA {
    return withIntent(rgba, tag, snapshotMode)
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
