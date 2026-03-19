import { describe, expect, it, beforeEach, afterEach } from "bun:test"
import { toArrayBuffer, type Pointer } from "bun:ffi"
import { OptimizedBuffer } from "./buffer.js"
import { RGBA } from "./lib/RGBA.js"
import { COLOR_TAG_DEFAULT, COLOR_TAG_RGB } from "./lib/color-value.js"

interface InternalBufferTagLib {
  bufferGetFgTagPtr(buffer: Pointer): Pointer
  bufferGetBgTagPtr(buffer: Pointer): Pointer
}

function getTagBuffers(buffer: OptimizedBuffer): { fgTag: Uint16Array; bgTag: Uint16Array } {
  const size = buffer.width * buffer.height
  const lib = buffer.lib as unknown as InternalBufferTagLib

  return {
    fgTag: new Uint16Array(toArrayBuffer(lib.bufferGetFgTagPtr(buffer.ptr), 0, size * 2)),
    bgTag: new Uint16Array(toArrayBuffer(lib.bufferGetBgTagPtr(buffer.ptr), 0, size * 2)),
  }
}

describe("OptimizedBuffer", () => {
  let buffer: OptimizedBuffer

  beforeEach(() => {
    buffer = OptimizedBuffer.create(20, 5, "unicode", { id: "test-buffer" })
  })

  afterEach(() => {
    buffer.destroy()
  })

  describe("encodeUnicode", () => {
    it("should encode simple ASCII text", () => {
      const encoded = buffer.encodeUnicode("Hello")
      expect(encoded).not.toBeNull()
      expect(encoded!.data.length).toBe(5)
      expect(encoded!.data[0]).toEqual({ width: 1, char: 72 }) // 'H'
      expect(encoded!.data[1]).toEqual({ width: 1, char: 101 }) // 'e'
      expect(encoded!.data[2]).toEqual({ width: 1, char: 108 }) // 'l'
      expect(encoded!.data[3]).toEqual({ width: 1, char: 108 }) // 'l'
      expect(encoded!.data[4]).toEqual({ width: 1, char: 111 }) // 'o'

      buffer.freeUnicode(encoded!)
    })

    it("should encode emoji with correct width", () => {
      const encoded = buffer.encodeUnicode("👋")
      expect(encoded).not.toBeNull()
      expect(encoded!.data.length).toBe(1)
      expect(encoded!.data[0].width).toBe(2)
      // Should be a packed grapheme (has high bit set)
      expect(encoded!.data[0].char).toBeGreaterThan(0x80000000)

      buffer.freeUnicode(encoded!)
    })

    it("should encode mixed ASCII and emoji", () => {
      const encoded = buffer.encodeUnicode("Hi 👋 World")
      expect(encoded).not.toBeNull()
      expect(encoded!.data.length).toBe(10) // H, i, space, emoji, space, W, o, r, l, d

      // Check ASCII chars
      expect(encoded!.data[0].width).toBe(1)
      expect(encoded!.data[0].char).toBe(72) // 'H'

      // Check emoji
      expect(encoded!.data[3].width).toBe(2)
      expect(encoded!.data[3].char).toBeGreaterThan(0x80000000)

      buffer.freeUnicode(encoded!)
    })

    it("should handle empty string", () => {
      const encoded = buffer.encodeUnicode("")
      expect(encoded).not.toBeNull()
      expect(encoded!.data.length).toBe(0)

      buffer.freeUnicode(encoded!)
    })

    it("should encode monkey emoji frames and draw in a line", () => {
      const frames = ["🙈 ", "🙈 ", "🙉 ", "🙊 "]
      const fg = RGBA.fromValues(1, 1, 1, 1)
      const bg = RGBA.fromValues(0, 0, 0, 1)

      buffer.clear(bg)

      let x = 0
      for (const frame of frames) {
        const encoded = buffer.encodeUnicode(frame)
        expect(encoded).not.toBeNull()

        for (const encodedChar of encoded!.data) {
          buffer.drawChar(encodedChar.char, x, 0, fg, bg)
          x += encodedChar.width
        }

        buffer.freeUnicode(encoded!)
      }

      const frameBytes = buffer.getRealCharBytes(false)
      const frameText = new TextDecoder().decode(frameBytes)
      expect(frameText).toContain("🙈")
      expect(frameText).toContain("🙉")
      expect(frameText).toContain("🙊")
    })
  })

  describe("drawChar", () => {
    it("should draw a simple ASCII character", () => {
      const fg = RGBA.fromValues(1, 1, 1, 1)
      const bg = RGBA.fromValues(0, 0, 0, 1)

      buffer.drawChar(72, 0, 0, fg, bg) // 'H'

      const chars = buffer.buffers.char
      expect(chars[0]).toBe(72)
    })

    it("should draw encoded characters from encodeUnicode", () => {
      const encoded = buffer.encodeUnicode("Hello")
      expect(encoded).not.toBeNull()

      const fg = RGBA.fromValues(1, 1, 1, 1)
      const bg = RGBA.fromValues(0, 0, 0, 1)

      // Draw each character
      for (let i = 0; i < encoded!.data.length; i++) {
        buffer.drawChar(encoded!.data[i].char, i, 0, fg, bg)
      }

      // Verify buffer content
      const frameBytes = buffer.getRealCharBytes(false)
      const frameText = new TextDecoder().decode(frameBytes)
      expect(frameText).toContain("Hello")

      buffer.freeUnicode(encoded!)
    })

    it("should draw emoji using encoded char", () => {
      const encoded = buffer.encodeUnicode("👋")
      expect(encoded).not.toBeNull()

      const fg = RGBA.fromValues(1, 1, 1, 1)
      const bg = RGBA.fromValues(0, 0, 0, 1)

      buffer.drawChar(encoded!.data[0].char, 0, 0, fg, bg)

      const frameBytes = buffer.getRealCharBytes(false)
      const frameText = new TextDecoder().decode(frameBytes)
      expect(frameText).toContain("👋")

      buffer.freeUnicode(encoded!)
    })

    it("should preserve raw color tags and split captured spans when tags differ", () => {
      const fgSnapshot = RGBA.fromHex("#ffffff")
      const bg = RGBA.fromHex("#000000")

      buffer.clear(bg)
      buffer.setCell(0, 0, "A", fgSnapshot, bg)
      buffer.setCell(1, 0, "B", RGBA.defaultForeground(fgSnapshot), bg)

      const firstLine = buffer.getSpanLines()[0]
      const taggedSpans = firstLine.spans.filter((span) => span.text.includes("A") || span.text.includes("B")) as Array<
        (typeof firstLine.spans)[number] & { fgTag: number; bgTag: number }
      >
      const tags = getTagBuffers(buffer)

      expect(taggedSpans).toHaveLength(2)
      expect(taggedSpans[0].fgTag).not.toBe(taggedSpans[1].fgTag)
      expect(tags.fgTag[0]).not.toBe(tags.fgTag[1])
    })

    it("should preserve intentful RGBA constructors through draw APIs", () => {
      const bg = RGBA.fromHex("#000000")

      buffer.clear(bg)
      buffer.setCell(0, 0, "A", RGBA.defaultForeground(RGBA.fromHex("#ffffff")), bg)
      buffer.setCell(1, 0, "B", RGBA.fromIndex(6), bg)
      const tags = getTagBuffers(buffer)

      expect(tags.fgTag[0]).toBe(COLOR_TAG_DEFAULT)
      expect(tags.fgTag[1]).toBe(6)
    })
  })

  describe("snapshot tests with unicode encoding", () => {
    it("should render ASCII text correctly", () => {
      buffer.clear(RGBA.fromValues(0, 0, 0, 1))

      const encoded = buffer.encodeUnicode("Hello")
      expect(encoded).not.toBeNull()

      const fg = RGBA.fromValues(1, 1, 1, 1)
      const bg = RGBA.fromValues(0, 0, 0, 1)

      let x = 0
      for (const encodedChar of encoded!.data) {
        buffer.drawChar(encodedChar.char, x, 0, fg, bg)
        x += encodedChar.width
      }

      const frameBytes = buffer.getRealCharBytes(true)
      const frameText = new TextDecoder().decode(frameBytes)
      expect(frameText).toMatchSnapshot("ASCII text rendering")

      buffer.freeUnicode(encoded!)
    })

    it("should render emoji text correctly", () => {
      buffer.clear(RGBA.fromValues(0, 0, 0, 1))

      const encoded = buffer.encodeUnicode("Hi 👋 🌍")
      expect(encoded).not.toBeNull()

      const fg = RGBA.fromValues(1, 1, 1, 1)
      const bg = RGBA.fromValues(0, 0, 0, 1)

      let x = 0
      for (const encodedChar of encoded!.data) {
        buffer.drawChar(encodedChar.char, x, 0, fg, bg)
        x += encodedChar.width
      }

      const frameBytes = buffer.getRealCharBytes(true)
      const frameText = new TextDecoder().decode(frameBytes)
      expect(frameText).toMatchSnapshot("Emoji text rendering")

      buffer.freeUnicode(encoded!)
    })

    it("should handle multiline text with unicode", () => {
      buffer.clear(RGBA.fromValues(0, 0, 0, 1))

      const lines = ["Hi 世界", "🌟 Star"]
      const fg = RGBA.fromValues(1, 1, 1, 1)
      const bg = RGBA.fromValues(0, 0, 0, 1)

      for (let y = 0; y < lines.length; y++) {
        const encoded = buffer.encodeUnicode(lines[y])
        expect(encoded).not.toBeNull()

        let x = 0
        for (const encodedChar of encoded!.data) {
          buffer.drawChar(encodedChar.char, x, y, fg, bg)
          x += encodedChar.width
        }

        buffer.freeUnicode(encoded!)
      }

      const frameBytes = buffer.getRealCharBytes(true)
      const frameText = new TextDecoder().decode(frameBytes)
      expect(frameText).toMatchSnapshot("Multiline unicode rendering")
    })

    it("should respect character widths in positioning", () => {
      const encoded = buffer.encodeUnicode("A👋B")
      expect(encoded).not.toBeNull()

      const fg = RGBA.fromValues(1, 1, 1, 1)
      const bg = RGBA.fromValues(0, 0, 0, 1)

      // 'A' at x=0, emoji at x=1 (width 2), 'B' at x=3
      buffer.drawChar(encoded!.data[0].char, 0, 0, fg, bg) // 'A'
      buffer.drawChar(encoded!.data[1].char, 1, 0, fg, bg) // emoji
      buffer.drawChar(encoded!.data[2].char, 3, 0, fg, bg) // 'B'

      const frameBytes = buffer.getRealCharBytes(false)
      const frameText = new TextDecoder().decode(frameBytes)
      expect(frameText).toContain("A👋B")

      buffer.freeUnicode(encoded!)
    })
  })

  describe("drawChar with alpha blending", () => {
    it("should blend semi-transparent foreground", () => {
      const fg = RGBA.fromValues(1, 0, 0, 0.5)
      const bg = RGBA.fromValues(0, 0, 0, 1)

      buffer.drawChar(65, 0, 0, fg, bg) // 'A'

      const fgBuffer = buffer.buffers.fg
      // Should have blended the color
      expect(fgBuffer[0]).toBeLessThan(1.0)
    })

    it("should blend semi-transparent background", () => {
      buffer.setRespectAlpha(true)

      const fg = RGBA.fromValues(1, 1, 1, 1)
      const bg = RGBA.fromValues(1, 0, 0, 0.5)

      buffer.drawChar(65, 0, 0, fg, bg) // 'A'

      const bgBuffer = buffer.buffers.bg
      // Background should reflect the alpha
      expect(bgBuffer[3]).toBeLessThan(1.0)
    })

    it("downgrades indexed fg tags to rgb when fg blending occurs", () => {
      const baseFg = RGBA.fromValues(1, 1, 1, 1)
      const baseBg = RGBA.fromValues(0, 0, 0, 1)
      buffer.clear(baseBg)
      buffer.setCell(0, 0, "A", baseFg, baseBg)

      const blendedFgSnapshot = RGBA.fromValues(1, 0, 0, 0.5)
      const opaqueBgSnapshot = RGBA.fromValues(0, 0, 0, 1)
      buffer.setCellWithAlphaBlending(
        0,
        0,
        "B",
        RGBA.fromIndex(2, blendedFgSnapshot),
        RGBA.fromIndex(4, opaqueBgSnapshot),
      )
      const tags = getTagBuffers(buffer)

      expect(tags.fgTag[0]).toBe(COLOR_TAG_RGB)
      expect(tags.bgTag[0]).toBe(4)
    })

    it("downgrades indexed bg tags to rgb when bg blending occurs", () => {
      const baseFg = RGBA.fromValues(1, 1, 1, 1)
      const baseBg = RGBA.fromValues(0, 0, 0, 1)
      buffer.clear(baseBg)
      buffer.setCell(0, 0, "A", baseFg, baseBg)

      const opaqueFgSnapshot = RGBA.fromValues(1, 0, 0, 1)
      const blendedBgSnapshot = RGBA.fromValues(0, 1, 0, 0.5)
      buffer.setCellWithAlphaBlending(
        0,
        0,
        "C",
        RGBA.fromIndex(3, opaqueFgSnapshot),
        RGBA.fromIndex(5, blendedBgSnapshot),
      )
      const tags = getTagBuffers(buffer)

      expect(tags.fgTag[0]).toBe(3)
      expect(tags.bgTag[0]).toBe(COLOR_TAG_RGB)
    })
  })

  describe("drawFrameBuffer tag transport", () => {
    it("preserves explicit default and indexed tags on opaque copy", () => {
      const source = OptimizedBuffer.create(2, 1, "unicode", { id: "source-buffer" })
      const dest = OptimizedBuffer.create(2, 1, "unicode", { id: "dest-buffer" })

      try {
        const bg = RGBA.fromValues(0, 0, 0, 1)
        source.clear(bg)
        dest.clear(bg)

        source.setCell(
          0,
          0,
          "X",
          RGBA.defaultForeground(RGBA.fromHex("#f8fafc")),
          RGBA.fromIndex(6, RGBA.fromHex("#008080")),
        )

        dest.drawFrameBuffer(0, 0, source)
        const tags = getTagBuffers(dest)

        expect(tags.fgTag[0]).toBe(COLOR_TAG_DEFAULT)
        expect(tags.bgTag[0]).toBe(6)
      } finally {
        source.destroy()
        dest.destroy()
      }
    })

    it("downgrades indexed tags to rgb when copied through alpha-respecting source", () => {
      const source = OptimizedBuffer.create(2, 1, "unicode", { id: "source-alpha-buffer" })
      const dest = OptimizedBuffer.create(2, 1, "unicode", { id: "dest-alpha-buffer" })

      try {
        const baseFg = RGBA.fromValues(1, 1, 1, 1)
        const baseBg = RGBA.fromValues(0, 0, 0, 1)

        source.setRespectAlpha(true)
        source.clear(baseBg)
        source.setCell(0, 0, "Y", RGBA.fromIndex(2, RGBA.fromValues(1, 0, 0, 0.5)), RGBA.fromIndex(4, baseBg))

        dest.clear(baseBg)
        dest.setCell(0, 0, "A", baseFg, baseBg)

        dest.drawFrameBuffer(0, 0, source)
        const tags = getTagBuffers(dest)

        expect(tags.fgTag[0]).toBe(COLOR_TAG_RGB)
        expect(tags.bgTag[0]).toBe(4)
      } finally {
        source.destroy()
        dest.destroy()
      }
    })
  })

  describe("grapheme pool churn across drawFrameBuffer", () => {
    it("should not crash with WrongGeneration after many grapheme alloc cycles", () => {
      const parent = OptimizedBuffer.create(40, 5, "unicode", { id: "parent" })
      const child = OptimizedBuffer.create(40, 5, "unicode", { id: "child", respectAlpha: true })

      const fg = RGBA.fromValues(1, 1, 1, 1)
      const bg = RGBA.fromValues(0, 0, 0, 1)

      for (let cycle = 0; cycle < 50; cycle++) {
        parent.clear(bg)

        if (cycle % 2 === 0) {
          child.drawText("╭────────────────────────────────────╮", 0, 0, fg, bg)
          child.drawText("│ ◇ Select Files ▫ src/ ▪ file.ts   │", 0, 1, fg, bg)
          child.drawText("│ ↑↓ navigate  ⏎ select  esc close  │", 0, 2, fg, bg)
          child.drawText("╰────────────────────────────────────╯", 0, 3, fg, bg)
        } else {
          child.drawText("  Your Name                              ", 0, 0, fg, bg)
          child.drawText("  John Doe                               ", 0, 1, fg, bg)
          child.drawText("                                         ", 0, 2, fg, bg)
          child.drawText("  Select Files                           ", 0, 3, fg, bg)
        }

        parent.drawFrameBuffer(0, 0, child)

        const frameBytes = parent.getRealCharBytes(true)
        const text = new TextDecoder().decode(frameBytes)
        expect(text.length).toBeGreaterThan(0)
      }

      child.destroy()
      parent.destroy()
    })
  })
})
