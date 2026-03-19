import { describe, expect, it } from "bun:test"

import { RGBA } from "./RGBA.js"
import {
  COLOR_TAG_DEFAULT,
  COLOR_TAG_RGB,
  PACKED_COLOR_STRIDE,
  buildTerminalPaletteSignature,
  decodeColorTag,
  defaultColor,
  indexedColor,
  normalizeColorValue,
  normalizeTerminalPalette,
  packColorValueToF32,
} from "./color-value.js"

describe("color-value", () => {
  it("distinguishes unset from explicit default", () => {
    expect(normalizeColorValue(null, { role: "fg" })).toBeNull()

    const normalized = normalizeColorValue(defaultColor(), { role: "fg" })
    expect(normalized).not.toBeNull()
    expect(normalized!.tag).toBe(COLOR_TAG_DEFAULT)
  })

  it("preserves explicit indexed tags and snapshots", () => {
    const snapshot = RGBA.fromHex("#112233")
    const normalized = normalizeColorValue(indexedColor(6, snapshot), { role: "fg" })

    expect(normalized).not.toBeNull()
    expect(normalized!.tag).toBe(6)
    expect(normalized!.rgba).toBe(snapshot)
  })

  it("packs normalized colors into a 5-float boundary buffer", () => {
    const snapshot = RGBA.fromHex("#112233")
    const packed = new Float32Array(PACKED_COLOR_STRIDE)

    expect(packColorValueToF32(indexedColor(6, snapshot), "fg", packed)).toBe(packed)
    expect(Array.from(packed)).toEqual([snapshot.r, snapshot.g, snapshot.b, snapshot.a, 6])
    expect(packColorValueToF32(null, "bg", packed)).toBeNull()
  })

  it("preserves indexed and default intent on RGBA instances", () => {
    const indexed = RGBA.fromIndex(12)
    const defaultFg = RGBA.defaultForeground()
    const defaultBg = RGBA.defaultBackground()

    expect(normalizeColorValue(indexed, { role: "fg" })?.tag).toBe(12)
    expect(normalizeColorValue(defaultFg, { role: "fg" })?.tag).toBe(COLOR_TAG_DEFAULT)
    expect(normalizeColorValue(defaultBg, { role: "bg" })?.tag).toBe(COLOR_TAG_DEFAULT)
  })

  it("decodes rgb, indexed, and default tags", () => {
    expect(decodeColorTag(COLOR_TAG_RGB)).toEqual({ kind: "rgb" })
    expect(decodeColorTag(COLOR_TAG_DEFAULT)).toEqual({ kind: "default" })
    expect(decodeColorTag(42)).toEqual({ kind: "indexed", index: 42 })
  })

  it("normalizes partial terminal palettes to a full 256-color basis", () => {
    const normalized = normalizeTerminalPalette({
      palette: ["#ff0000"],
      defaultForeground: "#123456",
      defaultBackground: null,
      cursorColor: null,
      mouseForeground: null,
      mouseBackground: null,
      tekForeground: null,
      tekBackground: null,
      highlightBackground: null,
      highlightForeground: null,
    })

    expect(normalized.palette).toHaveLength(256)
    expect(normalized.palette[0].toInts()).toEqual([255, 0, 0, 255])
    expect(normalized.defaultForeground.toInts()).toEqual([18, 52, 86, 255])
    expect(normalized.defaultBackground.toInts()).toEqual([0, 0, 0, 255])
  })

  it("changes palette signatures when the basis changes", () => {
    const base = buildTerminalPaletteSignature(null)
    const changed = buildTerminalPaletteSignature({
      palette: ["#00ff00"],
      defaultForeground: null,
      defaultBackground: null,
      cursorColor: null,
      mouseForeground: null,
      mouseBackground: null,
      tekForeground: null,
      tekBackground: null,
      highlightBackground: null,
      highlightForeground: null,
    })

    expect(changed).not.toBe(base)
  })
})
