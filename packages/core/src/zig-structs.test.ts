import { describe, expect, test } from "bun:test"

import { COLOR_TAG_DEFAULT, COLOR_TAG_RGB, RGBA } from "./lib/RGBA.js"
import { StyledChunkStruct } from "./zig-structs.js"

describe("StyledChunkStruct", () => {
  test("packs intent tags into fg_tag and bg_tag fields", () => {
    const packed = StyledChunkStruct.pack({
      text: "A",
      fg: RGBA.fromIndex(6),
      bg: RGBA.defaultBackground(),
    })

    const unpacked = StyledChunkStruct.unpack(packed)

    expect(unpacked.fg_tag).toBe(6)
    expect(unpacked.bg_tag).toBe(COLOR_TAG_DEFAULT)
  })

  test("keeps rgb tags for plain RGBA colors", () => {
    const packed = StyledChunkStruct.pack({
      text: "B",
      fg: RGBA.fromHex("#112233"),
      bg: null,
    })

    const unpacked = StyledChunkStruct.unpack(packed)

    expect(unpacked.fg_tag).toBe(COLOR_TAG_RGB)
    expect(unpacked.bg_tag).toBe(COLOR_TAG_RGB)
  })
})
