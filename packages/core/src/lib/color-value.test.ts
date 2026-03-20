import { afterEach, beforeEach, describe, expect, it } from "bun:test"

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
  setCurrentColorBasis,
} from "./color-value.js"

describe("color-value", () => {
  beforeEach(() => {
    setCurrentColorBasis(null)
  })

  afterEach(() => {
    setCurrentColorBasis(null)
  })

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

  it("does not mutate caller-owned snapshots when constructing intentful RGBA values", () => {
    const indexedSnapshot = RGBA.fromHex("#112233")
    const defaultSnapshot = RGBA.fromHex("#abcdef")

    const indexed = RGBA.fromIndex(6, indexedSnapshot)
    const defaultFg = RGBA.defaultForeground(defaultSnapshot)

    expect(indexed).not.toBe(indexedSnapshot)
    expect(defaultFg).not.toBe(defaultSnapshot)
    expect(RGBA.getIntentTag(indexedSnapshot)).toBeUndefined()
    expect(RGBA.getIntentTag(defaultSnapshot)).toBeUndefined()
    expect(RGBA.getIntentTag(indexed)).toBe(6)
    expect(RGBA.getIntentTag(defaultFg)).toBe(COLOR_TAG_DEFAULT)
    expect(indexed.toInts()).toEqual(indexedSnapshot.toInts())
    expect(defaultFg.toInts()).toEqual(defaultSnapshot.toInts())
  })

  it("resolves implicit intentful RGBA snapshots against the current published basis", () => {
    setCurrentColorBasis({
      palette: Array.from({ length: 16 }, (_, index) => (index === 6 ? "#123456" : "#000000")),
      defaultForeground: "#abcdef",
      defaultBackground: "#654321",
      cursorColor: null,
      mouseForeground: null,
      mouseBackground: null,
      tekForeground: null,
      tekBackground: null,
      highlightBackground: null,
      highlightForeground: null,
    })

    const indexed = normalizeColorValue(RGBA.fromIndex(6), { role: "fg" })
    const defaultFg = normalizeColorValue(RGBA.defaultForeground(), { role: "fg" })
    const defaultBg = normalizeColorValue(RGBA.defaultBackground(), { role: "bg" })

    expect(indexed?.tag).toBe(6)
    expect(indexed?.rgba.toInts()).toEqual([18, 52, 86, 255])
    expect(defaultFg?.rgba.toInts()).toEqual([171, 205, 239, 255])
    expect(defaultBg?.rgba.toInts()).toEqual([101, 67, 33, 255])
  })

  it("packs implicit indexed intent using the current published basis", () => {
    setCurrentColorBasis({
      palette: Array.from({ length: 16 }, (_, index) => (index === 6 ? "#224466" : "#000000")),
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

    const packed = new Float32Array(PACKED_COLOR_STRIDE)
    packColorValueToF32(RGBA.fromIndex(6), "fg", packed)

    expect(packed[0]).toBeCloseTo(34 / 255, 6)
    expect(packed[1]).toBeCloseTo(68 / 255, 6)
    expect(packed[2]).toBeCloseTo(102 / 255, 6)
    expect(packed[3]).toBe(1)
    expect(packed[4]).toBe(6)
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
