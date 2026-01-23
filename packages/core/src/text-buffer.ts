import type { StyledText } from "./lib/styled-text"
import { RGBA } from "./lib/RGBA"
import { resolveRenderLib, type LineInfo, type RenderLib } from "./zig"
import { type Pointer } from "bun:ffi"
import { type WidthMethod, type Highlight } from "./types"
import type { SyntaxStyle } from "./syntax-style"

export interface TextChunk {
  __isChunk: true
  text: string
  fg?: RGBA
  bg?: RGBA
  attributes?: number
  link?: { url: string }
}

export interface TextBufferCreateOptions {
  /** When true, creates a full rope-backed buffer with edit capabilities (default: true) */
  editable?: boolean
}

export class TextBuffer {
  private lib: RenderLib
  private bufferPtr: Pointer
  private _editable: boolean
  private _length: number = 0
  private _byteSize: number = 0
  private _lineInfo?: LineInfo
  private _destroyed: boolean = false
  private _syntaxStyle?: SyntaxStyle
  private _textBytes?: Uint8Array
  private _memId?: number
  private _appendedChunks: Uint8Array[] = []

  constructor(lib: RenderLib, ptr: Pointer, editable: boolean) {
    this.lib = lib
    this.bufferPtr = ptr
    this._editable = editable
  }

  /**
   * Create a TextBuffer.
   * @param widthMethod - Width calculation method ("wcwidth" or "unicode")
   * @param options - Optional configuration
   * @param options.editable - When false, creates static read-only buffer (default: true for full editing support)
   */
  static create(widthMethod: WidthMethod, options?: TextBufferCreateOptions): TextBuffer {
    const lib = resolveRenderLib()
    const editable = options?.editable ?? true
    const ptr = lib.createTextBuffer(widthMethod, editable)
    return new TextBuffer(lib, ptr, editable)
  }

  /** Throws an error if called on a non-editable buffer */
  private requireEditable(operation: string): void {
    if (!this._editable) {
      throw new Error(`TextBuffer.${operation} requires editable: true`)
    }
  }

  // Fail loud and clear
  // Instead of trying to return values that could work or not,
  // this at least will show a stack trace to know where the call to a destroyed TextBuffer was made
  private guard(): void {
    if (this._destroyed) throw new Error("TextBuffer is destroyed")
  }

  public setText(text: string): void {
    this.guard()
    this._textBytes = this.lib.encoder.encode(text)

    if (this._memId === undefined) {
      this._memId = this.lib.textBufferRegisterMemBuffer(this.bufferPtr, this._textBytes, false)
    } else {
      this.lib.textBufferReplaceMemBuffer(this.bufferPtr, this._memId, this._textBytes, false)
    }

    this.lib.textBufferSetTextFromMem(this.bufferPtr, this._memId)
    this._length = this.lib.textBufferGetLength(this.bufferPtr)
    this._byteSize = this.lib.textBufferGetByteSize(this.bufferPtr)
    this._lineInfo = undefined
    this._appendedChunks = [] // Clear any previously appended chunks
  }

  public append(text: string): void {
    this.guard()
    this.requireEditable("append")
    const textBytes = this.lib.encoder.encode(text)
    // Keep the bytes alive to prevent garbage collection
    this._appendedChunks.push(textBytes)
    this.lib.textBufferAppend(this.bufferPtr, textBytes)
    this._length = this.lib.textBufferGetLength(this.bufferPtr)
    this._byteSize = this.lib.textBufferGetByteSize(this.bufferPtr)
    this._lineInfo = undefined
  }

  public loadFile(path: string): void {
    this.guard()
    const success = this.lib.textBufferLoadFile(this.bufferPtr, path)
    if (!success) {
      throw new Error(`Failed to load file: ${path}`)
    }
    this._length = this.lib.textBufferGetLength(this.bufferPtr)
    this._byteSize = this.lib.textBufferGetByteSize(this.bufferPtr)
    this._lineInfo = undefined
    this._textBytes = undefined
  }

  public setStyledText(text: StyledText): void {
    this.guard()

    // TODO: This should not be necessary anymore, the struct packing should take care of this
    const chunks = text.chunks.map((chunk) => ({
      text: chunk.text,
      fg: chunk.fg || null,
      bg: chunk.bg || null,
      attributes: chunk.attributes ?? 0,
      link: chunk.link,
    }))

    this.lib.textBufferSetStyledText(this.bufferPtr, chunks)

    this._length = this.lib.textBufferGetLength(this.bufferPtr)
    this._byteSize = this.lib.textBufferGetByteSize(this.bufferPtr)
    this._lineInfo = undefined
  }

  public setDefaultFg(fg: RGBA | null): void {
    this.guard()
    this.lib.textBufferSetDefaultFg(this.bufferPtr, fg)
  }

  public setDefaultBg(bg: RGBA | null): void {
    this.guard()
    this.lib.textBufferSetDefaultBg(this.bufferPtr, bg)
  }

  public setDefaultAttributes(attributes: number | null): void {
    this.guard()
    this.lib.textBufferSetDefaultAttributes(this.bufferPtr, attributes)
  }

  public resetDefaults(): void {
    this.guard()
    this.lib.textBufferResetDefaults(this.bufferPtr)
  }

  public getLineCount(): number {
    this.guard()
    return this.lib.textBufferGetLineCount(this.bufferPtr)
  }

  public get length(): number {
    this.guard()
    return this._length
  }

  public get byteSize(): number {
    this.guard()
    return this._byteSize
  }

  public get ptr(): Pointer {
    this.guard()
    return this.bufferPtr
  }

  public getPlainText(): string {
    this.guard()
    if (this._byteSize === 0) return ""
    // Use byteSize for accurate buffer allocation (includes newlines in byte count)
    const plainBytes = this.lib.getPlainTextBytes(this.bufferPtr, this._byteSize)

    if (!plainBytes) return ""

    return this.lib.decoder.decode(plainBytes)
  }

  public getTextRange(startOffset: number, endOffset: number): string {
    this.guard()
    if (startOffset >= endOffset) return ""
    if (this._byteSize === 0) return ""

    const rangeBytes = this.lib.textBufferGetTextRange(this.bufferPtr, startOffset, endOffset, this._byteSize)

    if (!rangeBytes) return ""

    return this.lib.decoder.decode(rangeBytes)
  }

  /**
   * Add a highlight using character offsets into the full text.
   * start/end in highlight represent absolute character positions.
   * Note: Only available on editable buffers.
   */
  public addHighlightByCharRange(highlight: Highlight): void {
    this.guard()
    this.lib.textBufferAddHighlightByCharRange(this.bufferPtr, highlight)
  }

  /**
   * Add a highlight to a specific line by column positions.
   * start/end in highlight represent column offsets.
   * Note: Only available on editable buffers.
   */
  public addHighlight(lineIdx: number, highlight: Highlight): void {
    this.guard()
    this.lib.textBufferAddHighlight(this.bufferPtr, lineIdx, highlight)
  }

  public removeHighlightsByRef(hlRef: number): void {
    this.guard()
    this.lib.textBufferRemoveHighlightsByRef(this.bufferPtr, hlRef)
  }

  public clearLineHighlights(lineIdx: number): void {
    this.guard()
    this.lib.textBufferClearLineHighlights(this.bufferPtr, lineIdx)
  }

  public clearAllHighlights(): void {
    this.guard()
    this.lib.textBufferClearAllHighlights(this.bufferPtr)
  }

  public getLineHighlights(lineIdx: number): Array<Highlight> {
    this.guard()
    // Read operation - works on both static and unified buffers
    return this.lib.textBufferGetLineHighlights(this.bufferPtr, lineIdx)
  }

  public getHighlightCount(): number {
    this.guard()
    // Read operation - works on both static and unified buffers
    return this.lib.textBufferGetHighlightCount(this.bufferPtr)
  }

  public setSyntaxStyle(style: SyntaxStyle | null): void {
    this.guard()
    this._syntaxStyle = style ?? undefined
    this.lib.textBufferSetSyntaxStyle(this.bufferPtr, style?.ptr ?? null)
  }

  public getSyntaxStyle(): SyntaxStyle | null {
    this.guard()
    return this._syntaxStyle ?? null
  }

  public setTabWidth(width: number): void {
    this.guard()
    this.lib.textBufferSetTabWidth(this.bufferPtr, width)
  }

  public getTabWidth(): number {
    this.guard()
    return this.lib.textBufferGetTabWidth(this.bufferPtr)
  }

  public clear(): void {
    this.guard()
    this.lib.textBufferClear(this.bufferPtr)
    this._length = 0
    this._byteSize = 0
    this._lineInfo = undefined
    this._textBytes = undefined
    this._appendedChunks = []
    // Note: _memId is NOT cleared - it can be reused for next setText
  }

  public reset(): void {
    this.guard()
    this.lib.textBufferReset(this.bufferPtr)
    this._length = 0
    this._byteSize = 0
    this._lineInfo = undefined
    this._textBytes = undefined
    this._memId = undefined // Reset clears the registry, so clear our ID
    this._appendedChunks = []
  }

  public destroy(): void {
    if (this._destroyed) return
    this._destroyed = true
    this.lib.destroyTextBuffer(this.bufferPtr)
  }
}
