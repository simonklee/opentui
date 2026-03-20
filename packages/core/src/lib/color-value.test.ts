import { describe, expect, it } from "bun:test"

import { PACKED_COLOR_STRIDE, RGBA, normalizeColorValue, packColorValueToF32 } from "./RGBA.js"
import { COLOR_TAG_DEFAULT, COLOR_TAG_RGB, decodeColorTag } from "./ansi-palette.js"
import { buildTerminalPaletteSignature, normalizeTerminalPalette } from "./terminal-palette.js"

describe("color-value", () => {
  it("distinguishes unset from explicit default", () => {
    expect(normalizeColorValue(null)).toBeNull()

    const normalized = normalizeColorValue(RGBA.defaultForeground())
    expect(normalized).not.toBeNull()
    expect(normalized!.tag).toBe(COLOR_TAG_DEFAULT)
  })

  it("preserves explicit indexed tags and snapshots", () => {
    const snapshot = RGBA.fromHex("#112233")
    const normalized = normalizeColorValue(RGBA.fromIndex(6, snapshot))

    expect(normalized).not.toBeNull()
    expect(normalized!.tag).toBe(6)
    expect(normalized!.rgba).not.toBe(snapshot)
    expect(normalized!.rgba.toInts()).toEqual(snapshot.toInts())
  })

  it("packs normalized colors into a 5-float boundary buffer", () => {
    const snapshot = RGBA.fromHex("#112233")
    const packed = new Float32Array(PACKED_COLOR_STRIDE)

    expect(packColorValueToF32(RGBA.fromIndex(6, snapshot), packed)).toBe(packed)
    expect(Array.from(packed)).toEqual([snapshot.r, snapshot.g, snapshot.b, snapshot.a, 6])
    expect(packColorValueToF32(null, packed)).toBeNull()
  })

  it("preserves indexed and default intent on RGBA instances", () => {
    const indexed = RGBA.fromIndex(12)
    const defaultFg = RGBA.defaultForeground()
    const defaultBg = RGBA.defaultBackground()

    expect(normalizeColorValue(indexed)?.tag).toBe(12)
    expect(normalizeColorValue(defaultFg)?.tag).toBe(COLOR_TAG_DEFAULT)
    expect(normalizeColorValue(defaultBg)?.tag).toBe(COLOR_TAG_DEFAULT)
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

  it("uses fallback snapshots for implicit intentful RGBA values", () => {
    const indexed = normalizeColorValue(RGBA.fromIndex(6))
    const defaultFg = normalizeColorValue(RGBA.defaultForeground())
    const defaultBg = normalizeColorValue(RGBA.defaultBackground())

    expect(indexed?.tag).toBe(6)
    expect(indexed?.rgba.toInts()).toEqual([0, 128, 128, 255])
    expect(defaultFg?.rgba.toInts()).toEqual([255, 255, 255, 255])
    expect(defaultBg?.rgba.toInts()).toEqual([0, 0, 0, 255])
  })

  it("packs implicit indexed intent using fallback snapshots", () => {
    const packed = new Float32Array(PACKED_COLOR_STRIDE)
    packColorValueToF32(RGBA.fromIndex(6), packed)

    expect(packed[0]).toBeCloseTo(0, 6)
    expect(packed[1]).toBeCloseTo(128 / 255, 6)
    expect(packed[2]).toBeCloseTo(128 / 255, 6)
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
