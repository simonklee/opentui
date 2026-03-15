const std = @import("std");
const uucode = @import("uucode");

/// The method to use when calculating the width of a grapheme
pub const WidthMethod = enum {
    wcwidth,
    unicode,
    no_zwj,
};

/// Check if a byte slice contains only printable ASCII (32..126)
/// Uses SIMD16 for fast checking
pub fn isAsciiOnly(text: []const u8) bool {
    if (text.len == 0) return false;

    const vector_len = 16;
    const Vec = @Vector(vector_len, u8);

    const min_printable: Vec = @splat(32);
    const max_printable: Vec = @splat(126);

    var pos: usize = 0;

    // Process full 16-byte vectors
    while (pos + vector_len <= text.len) {
        const chunk: Vec = text[pos..][0..vector_len].*;

        // Check if all bytes are in [32, 126]
        const too_low = chunk < min_printable;
        const too_high = chunk > max_printable;

        // Check if any byte is out of range
        if (@reduce(.Or, too_low) or @reduce(.Or, too_high)) {
            return false;
        }

        pos += vector_len;
    }

    // Handle remaining bytes with scalar code
    while (pos < text.len) : (pos += 1) {
        const b = text[pos];
        if (b < 32 or b > 126) {
            return false;
        }
    }

    return true;
}

pub const LineBreakKind = enum {
    LF, // \n (Unix/Linux)
    CR, // \r (Old Mac)
    CRLF, // \r\n (Windows)
};

pub const LineBreak = struct {
    pos: usize,
    kind: LineBreakKind,
};

pub const LineBreakResult = struct {
    breaks: std.ArrayListUnmanaged(LineBreak),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LineBreakResult {
        return .{
            .breaks = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LineBreakResult) void {
        self.breaks.deinit(self.allocator);
    }

    pub fn reset(self: *LineBreakResult) void {
        self.breaks.clearRetainingCapacity();
    }
};

pub const TabStopResult = struct {
    positions: std.ArrayListUnmanaged(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TabStopResult {
        return .{
            .positions = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TabStopResult) void {
        self.positions.deinit(self.allocator);
    }

    pub fn reset(self: *TabStopResult) void {
        self.positions.clearRetainingCapacity();
    }
};

pub const WrapBreak = struct {
    // byte_offset points at the grapheme that creates this break opportunity.
    // For whitespace and punctuation, this is the delimiter grapheme.
    // For CJK<->ASCII transitions, this is the last grapheme in the previous run.
    byte_offset: u32,

    // char_offset is grapheme-count based and retained for legacy-only helpers/tests.
    char_offset: u32,
};

pub const WrapBreakResult = struct {
    breaks: std.ArrayListUnmanaged(WrapBreak),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WrapBreakResult {
        return .{
            .breaks = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WrapBreakResult) void {
        self.breaks.deinit(self.allocator);
    }

    pub fn reset(self: *WrapBreakResult) void {
        self.breaks.clearRetainingCapacity();
    }
};

// Helper function to check if an ASCII byte is a wrap break point (CR/LF excluded)
inline fn isAsciiWrapBreak(b: u8) bool {
    return switch (b) {
        ' ', '\t' => true, // Whitespace (no CR/LF in inputs)
        '-' => true, // Dash
        '/', '\\' => true, // Slashes
        '.', ',', ';', ':', '!', '?' => true, // Punctuation
        '(', ')', '[', ']', '{', '}' => true, // Brackets
        else => false,
    };
}

// Decode a UTF-8 codepoint starting at pos. Assumes valid UTF-8 input.
// Returns (codepoint, length). If the remaining bytes are insufficient, returns length 1.
pub inline fn decodeUtf8Unchecked(text: []const u8, pos: usize) struct { cp: u21, len: u3 } {
    const b0 = text[pos];
    if (b0 < 0x80) return .{ .cp = @intCast(b0), .len = 1 };

    if (pos + 1 >= text.len) return .{ .cp = 0xFFFD, .len = 1 };
    const b1 = text[pos + 1];

    if ((b0 & 0xE0) == 0xC0) {
        const cp2: u21 = @intCast((@as(u32, b0 & 0x1F) << 6) | @as(u32, b1 & 0x3F));
        return .{ .cp = cp2, .len = 2 };
    }

    if (pos + 2 >= text.len) return .{ .cp = 0xFFFD, .len = 1 };
    const b2 = text[pos + 2];

    if ((b0 & 0xF0) == 0xE0) {
        const cp3: u21 = @intCast((@as(u32, b0 & 0x0F) << 12) | (@as(u32, b1 & 0x3F) << 6) | @as(u32, b2 & 0x3F));
        return .{ .cp = cp3, .len = 3 };
    }

    if (pos + 3 >= text.len) return .{ .cp = 0xFFFD, .len = 1 };
    const b3 = text[pos + 3];
    const cp4: u21 = @intCast((@as(u32, b0 & 0x07) << 18) | (@as(u32, b1 & 0x3F) << 12) | (@as(u32, b2 & 0x3F) << 6) | @as(u32, b3 & 0x3F));
    return .{ .cp = cp4, .len = 4 };
}

const DecodedUtf8 = struct {
    cp: u21,
    len: usize,
};

// Unicode wrap-break codepoints
inline fn isUnicodeWrapBreak(cp: u21) bool {
    return switch (cp) {
        0x00A0, // NBSP
        0x1680, // OGHAM SPACE MARK
        0x2000...0x200A, // En quad..Hair space
        0x202F, // NARROW NO-BREAK SPACE
        0x205F, // MEDIUM MATHEMATICAL SPACE
        0x3000, // IDEOGRAPHIC SPACE
        0x200B, // ZERO WIDTH SPACE
        0x00AD, // SOFT HYPHEN
        0x2010, // HYPHEN
        0x3001, // IDEOGRAPHIC COMMA
        0x3002, // IDEOGRAPHIC FULL STOP
        0xFF01, // FULLWIDTH EXCLAMATION MARK
        0xFF1F, // FULLWIDTH QUESTION MARK
        => true,
        else => false,
    };
}

// WordClass keeps word-boundary behavior predictable in mixed-script text.
// We split between ASCII word runs and CJK word runs, and we keep each
// CJK run grouped as one unit.
pub const WordClass = enum {
    ascii_word,
    cjk_word,
    other,
};

pub const BreakKind = enum(u8) {
    none,
    whitespace,
    punctuation,
    script_transition,
};

pub const GraphemeSpan = struct {
    byte_start: u32,
    byte_len: u32,
    col_start: u32,
    col_width: u16,
    break_after: BreakKind,

    pub fn byteEnd(self: @This()) u32 {
        return self.byte_start + self.byte_len;
    }

    pub fn colEnd(self: @This()) u32 {
        return self.col_start + self.col_width;
    }
};

pub inline fn graphemeCountForLayoutSpan(span: GraphemeSpan, is_ascii_only: bool) u32 {
    if (is_ascii_only and span.byte_len == span.col_width) {
        return span.byte_len;
    }
    return 1;
}

pub const LayoutScanResult = struct {
    spans: std.ArrayListUnmanaged(GraphemeSpan),
    allocator: std.mem.Allocator,
    total_bytes: u32,
    total_cols: u32,

    pub fn init(allocator: std.mem.Allocator) LayoutScanResult {
        return .{
            .spans = .{},
            .allocator = allocator,
            .total_bytes = 0,
            .total_cols = 0,
        };
    }

    pub fn deinit(self: *LayoutScanResult) void {
        self.spans.deinit(self.allocator);
        self.total_bytes = 0;
        self.total_cols = 0;
    }

    pub fn reset(self: *LayoutScanResult) void {
        self.spans.clearRetainingCapacity();
        self.total_bytes = 0;
        self.total_cols = 0;
    }
};

pub const LayoutScanCursor = struct {
    byte_offset: u32 = 0,
    col_offset: u32 = 0,
    prev_cp: ?u21 = null,
    break_state: uucode.grapheme.BreakState = .default,

    pub fn init() LayoutScanCursor {
        return .{};
    }

    pub fn reset(self: *LayoutScanCursor) void {
        self.* = .{};
    }
};

pub const LayoutSpanBatch = struct {
    spans: []const GraphemeSpan,
    consumed_bytes: u32,
    consumed_cols: u32,
    done: bool,
};

pub const LayoutScanError = std.mem.Allocator.Error || error{InvalidCursorOffset};
pub const LAYOUT_SCAN_MAX_LOOKAHEAD_CODEPOINTS: u8 = 1;

inline fn isAsciiWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or
        (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or
        b == '_';
}

inline fn isPrintableAsciiByte(b: u8) bool {
    return b >= 32 and b <= 126;
}

inline fn classifyAsciiWordClass(byte: u8) WordClass {
    return if (isAsciiWordByte(byte)) .ascii_word else .other;
}

inline fn breakKindForAsciiByte(byte: u8) BreakKind {
    return switch (byte) {
        ' ', '\t' => .whitespace,
        '-', '/', '\\', '.', ',', ';', ':', '!', '?', '(', ')', '[', ']', '{', '}' => .punctuation,
        else => .none,
    };
}

inline fn isCjkWordCodepoint(cp: u21) bool {
    return
    // Han ideographs
    (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0x20000 and cp <= 0x2A6DF) or
        (cp >= 0x2A700 and cp <= 0x2B73F) or
        (cp >= 0x2B740 and cp <= 0x2B81F) or
        (cp >= 0x2B820 and cp <= 0x2CEAF) or
        (cp >= 0x2CEB0 and cp <= 0x2EBEF) or
        (cp >= 0x2EBF0 and cp <= 0x2EE5D) or
        (cp >= 0x2F800 and cp <= 0x2FA1F) or
        // Hiragana + Katakana
        (cp >= 0x3040 and cp <= 0x309F) or
        (cp >= 0x30A0 and cp <= 0x30FF) or
        (cp >= 0x31F0 and cp <= 0x31FF) or
        (cp >= 0xFF66 and cp <= 0xFF9D) or
        // Hangul
        (cp >= 0x1100 and cp <= 0x11FF) or
        (cp >= 0x3130 and cp <= 0x318F) or
        (cp >= 0xA960 and cp <= 0xA97F) or
        (cp >= 0xAC00 and cp <= 0xD7AF) or
        (cp >= 0xD7B0 and cp <= 0xD7FF);
}

inline fn classifyWordClass(cp: u21) WordClass {
    if (cp <= 0x7F) {
        return classifyAsciiWordClass(@intCast(cp));
    }
    if (isCjkWordCodepoint(cp)) return .cjk_word;
    return .other;
}

pub inline fn isWordCodepoint(cp: u21) bool {
    return classifyWordClass(cp) != .other;
}

inline fn isCjkAsciiTransition(prev_class: WordClass, curr_class: WordClass) bool {
    return (prev_class == .cjk_word and curr_class == .ascii_word) or
        (prev_class == .ascii_word and curr_class == .cjk_word);
}

inline fn mergeBreakKind(lhs: BreakKind, rhs: BreakKind) BreakKind {
    if (lhs == .whitespace or rhs == .whitespace) return .whitespace;
    if (lhs == .punctuation or rhs == .punctuation) return .punctuation;
    if (lhs == .script_transition or rhs == .script_transition) return .script_transition;
    return .none;
}

inline fn breakKindForCodepoint(byte: u8, cp: u21) BreakKind {
    if (byte < 0x80) {
        return breakKindForAsciiByte(byte);
    }

    return switch (cp) {
        0x00A0,
        0x1680,
        0x2000...0x200A,
        0x202F,
        0x205F,
        0x3000,
        0x200B,
        => .whitespace,
        0x00AD,
        0x2010,
        0x3001,
        0x3002,
        0xFF01,
        0xFF1F,
        => .punctuation,
        else => .none,
    };
}

inline fn finalizedBreakKind(cluster_kind: BreakKind, cluster_class: WordClass, next_class: ?WordClass, include_breaks: bool) BreakKind {
    if (!include_breaks) return .none;
    if (cluster_kind != .none) return cluster_kind;
    if (next_class) |curr_class| {
        if (isCjkAsciiTransition(cluster_class, curr_class)) {
            return .script_transition;
        }
    }
    return .none;
}

fn appendGraphemeSpan(
    spans: *std.ArrayListUnmanaged(GraphemeSpan),
    allocator: std.mem.Allocator,
    byte_start: usize,
    byte_end: usize,
    col_start: u32,
    col_width: u32,
    break_after: BreakKind,
) LayoutScanError!void {
    try spans.append(allocator, .{
        .byte_start = @intCast(byte_start),
        .byte_len = @intCast(byte_end - byte_start),
        .col_start = col_start,
        .col_width = @intCast(col_width),
        .break_after = break_after,
    });
}

inline fn nextAsciiLayoutSpan(text: []const u8, start: u32, limit: u32, include_breaks: bool) GraphemeSpan {
    const max_span_len: u32 = std.math.maxInt(u16);

    if (!include_breaks) {
        const span_len = @min(limit - start, max_span_len);
        return .{
            .byte_start = start,
            .byte_len = span_len,
            .col_start = start,
            .col_width = @intCast(span_len),
            .break_after = .none,
        };
    }

    const first_byte = text[start];
    const first_break_kind = breakKindForAsciiByte(first_byte);
    if (first_break_kind != .none) {
        return .{
            .byte_start = start,
            .byte_len = 1,
            .col_start = start,
            .col_width = 1,
            .break_after = first_break_kind,
        };
    }

    const run_limit = @min(limit, start + max_span_len);
    var end = start + 1;
    while (end < run_limit) : (end += 1) {
        const b = text[end];
        if (breakKindForAsciiByte(b) != .none) break;
    }

    const span_len = end - start;
    return .{
        .byte_start = start,
        .byte_len = span_len,
        .col_start = start,
        .col_width = @intCast(span_len),
        .break_after = .none,
    };
}

fn scanLayoutInto(
    text: []const u8,
    tab_width: u8,
    is_ascii_only: bool,
    width_method: WidthMethod,
    allocator: std.mem.Allocator,
    spans: *std.ArrayListUnmanaged(GraphemeSpan),
    include_breaks: bool,
) LayoutScanError!u32 {
    if (text.len == 0) return 0;

    if (is_ascii_only) {
        const text_len_u32: u32 = @intCast(text.len);
        var pos: u32 = 0;
        while (pos < text_len_u32) {
            const span = nextAsciiLayoutSpan(text, pos, text_len_u32, include_breaks);
            try spans.append(allocator, span);
            pos = span.byteEnd();
        }
        return text_len_u32;
    }

    var pos: usize = 0;
    var col: u32 = 0;
    var prev_cp: ?u21 = null;
    var break_state: uucode.grapheme.BreakState = .default;

    var cluster_started = false;
    var cluster_start: usize = 0;
    var cluster_col_start: u32 = 0;
    var cluster_width_state: GraphemeWidthState = undefined;
    var cluster_break_kind: BreakKind = .none;
    var cluster_class: WordClass = .other;

    while (pos < text.len) {
        const b0 = text[pos];
        var curr_cp: u21 = undefined;
        var cp_len: usize = undefined;
        var curr_class: WordClass = undefined;
        var cp_width: u32 = undefined;
        var cp_break_kind: BreakKind = undefined;
        var is_break: bool = undefined;

        if (isPrintableAsciiByte(b0)) {
            curr_cp = b0;
            cp_len = 1;
            curr_class = classifyAsciiWordClass(b0);
            cp_width = 1;
            cp_break_kind = breakKindForAsciiByte(b0);

            if (prev_cp == null) {
                is_break = true;
            } else if (prev_cp.? <= 0x7F and break_state == .default) {
                is_break = true;
            } else {
                is_break = isGraphemeBreak(prev_cp, curr_cp, &break_state, width_method);
            }
        } else {
            const decoded: DecodedUtf8 = if (b0 < 0x80)
                .{ .cp = @as(u21, b0), .len = 1 }
            else blk: {
                const dec = decodeUtf8Unchecked(text, pos);
                break :blk .{ .cp = dec.cp, .len = dec.len };
            };

            curr_cp = decoded.cp;
            cp_len = decoded.len;
            curr_class = classifyWordClass(curr_cp);
            is_break = isGraphemeBreak(prev_cp, curr_cp, &break_state, width_method);
            cp_width = charWidth(b0, curr_cp, tab_width);
            cp_break_kind = breakKindForCodepoint(b0, curr_cp);
        }

        if (!cluster_started) {
            cluster_started = true;
            cluster_start = pos;
            cluster_col_start = col;
            cluster_width_state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
            cluster_break_kind = cp_break_kind;
            cluster_class = curr_class;
        } else if (is_break) {
            try appendGraphemeSpan(
                spans,
                allocator,
                cluster_start,
                pos,
                cluster_col_start,
                cluster_width_state.width,
                finalizedBreakKind(cluster_break_kind, cluster_class, curr_class, include_breaks),
            );
            col += cluster_width_state.width;

            cluster_start = pos;
            cluster_col_start = col;
            cluster_width_state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
            cluster_break_kind = cp_break_kind;
            cluster_class = curr_class;
        } else {
            cluster_width_state.addCodepoint(curr_cp, cp_width);
            cluster_break_kind = mergeBreakKind(cluster_break_kind, cp_break_kind);
        }

        prev_cp = curr_cp;
        pos += cp_len;
    }

    if (cluster_started) {
        try appendGraphemeSpan(
            spans,
            allocator,
            cluster_start,
            text.len,
            cluster_col_start,
            cluster_width_state.width,
            finalizedBreakKind(cluster_break_kind, cluster_class, null, include_breaks),
        );
        col += cluster_width_state.width;
    }

    return col;
}

pub fn scanLayout(
    text: []const u8,
    tab_width: u8,
    is_ascii_only: bool,
    width_method: WidthMethod,
    result: *LayoutScanResult,
) LayoutScanError!void {
    result.reset();
    errdefer result.reset();

    result.total_cols = try scanLayoutInto(text, tab_width, is_ascii_only, width_method, result.allocator, &result.spans, true);
    result.total_bytes = @intCast(text.len);
}

inline fn setLayoutScanCursor(
    cursor: *LayoutScanCursor,
    byte_offset: u32,
    col_offset: u32,
    prev_cp: ?u21,
    break_state: uucode.grapheme.BreakState,
) void {
    cursor.byte_offset = byte_offset;
    cursor.col_offset = col_offset;
    cursor.prev_cp = prev_cp;
    cursor.break_state = break_state;
}

fn scanLayoutBatchInternal(
    text: []const u8,
    tab_width: u8,
    is_ascii_only: bool,
    width_method: WidthMethod,
    cursor: *LayoutScanCursor,
    scratch: []GraphemeSpan,
    max_bytes: ?u32,
    include_breaks: bool,
) LayoutScanError!LayoutSpanBatch {
    if (cursor.byte_offset > text.len) return error.InvalidCursorOffset;
    if (cursor.byte_offset == 0 and cursor.col_offset != 0) return error.InvalidCursorOffset;
    if (cursor.byte_offset != 0 and cursor.prev_cp == null) return error.InvalidCursorOffset;

    if (cursor.byte_offset == text.len or scratch.len == 0) {
        return .{
            .spans = scratch[0..0],
            .consumed_bytes = 0,
            .consumed_cols = 0,
            .done = cursor.byte_offset == text.len,
        };
    }

    const start_byte = cursor.byte_offset;
    const start_col = cursor.col_offset;

    if (is_ascii_only) {
        if (cursor.col_offset != cursor.byte_offset) return error.InvalidCursorOffset;

        const text_len_u32: u32 = @intCast(text.len);
        const batch_end = if (max_bytes) |byte_limit|
            @min(text_len_u32, start_byte + byte_limit)
        else
            text_len_u32;

        var pos: u32 = start_byte;
        var count: usize = 0;

        while (pos < batch_end and count < scratch.len) {
            const span = nextAsciiLayoutSpan(text, pos, batch_end, include_breaks);
            scratch[count] = span;
            pos = span.byteEnd();
            count += 1;
        }

        const prev_cp: ?u21 = if (pos > 0) @as(u21, text[pos - 1]) else null;
        setLayoutScanCursor(cursor, pos, pos, prev_cp, .default);

        return .{
            .spans = scratch[0..count],
            .consumed_bytes = cursor.byte_offset - start_byte,
            .consumed_cols = cursor.col_offset - start_col,
            .done = cursor.byte_offset == text.len,
        };
    }

    var pos: usize = start_byte;
    var col = start_col;
    var prev_cp = cursor.prev_cp;
    var break_state = cursor.break_state;

    var cluster_started = false;
    var cluster_start: usize = pos;
    var cluster_col_start = col;
    var cluster_width_state: GraphemeWidthState = undefined;
    var cluster_break_kind: BreakKind = .none;
    var cluster_class: WordClass = .other;
    var count: usize = 0;

    while (pos < text.len) {
        const b0 = text[pos];
        var curr_cp: u21 = undefined;
        var cp_len: usize = undefined;
        var curr_class: WordClass = undefined;
        var cp_width: u32 = undefined;
        var cp_break_kind: BreakKind = undefined;

        const pre_break_state = break_state;
        const pre_prev_cp = prev_cp;
        var is_break: bool = undefined;

        if (isPrintableAsciiByte(b0)) {
            curr_cp = b0;
            cp_len = 1;
            curr_class = classifyAsciiWordClass(b0);
            cp_width = 1;
            cp_break_kind = breakKindForAsciiByte(b0);

            if (prev_cp == null) {
                is_break = true;
            } else if (prev_cp.? <= 0x7F and break_state == .default) {
                is_break = true;
            } else {
                is_break = isGraphemeBreak(prev_cp, curr_cp, &break_state, width_method);
            }
        } else {
            const decoded: DecodedUtf8 = if (b0 < 0x80)
                .{ .cp = @as(u21, b0), .len = 1 }
            else blk: {
                const dec = decodeUtf8Unchecked(text, pos);
                break :blk .{ .cp = dec.cp, .len = dec.len };
            };

            curr_cp = decoded.cp;
            cp_len = decoded.len;
            curr_class = classifyWordClass(curr_cp);
            is_break = isGraphemeBreak(prev_cp, curr_cp, &break_state, width_method);
            cp_width = charWidth(b0, curr_cp, tab_width);
            cp_break_kind = breakKindForCodepoint(b0, curr_cp);
        }

        if (!cluster_started) {
            if (prev_cp != null and !is_break) {
                return error.InvalidCursorOffset;
            }

            cluster_started = true;
            cluster_start = pos;
            cluster_col_start = col;
            cluster_width_state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
            cluster_break_kind = cp_break_kind;
            cluster_class = curr_class;
        } else if (is_break) {
            scratch[count] = .{
                .byte_start = @intCast(cluster_start),
                .byte_len = @intCast(pos - cluster_start),
                .col_start = cluster_col_start,
                .col_width = @intCast(cluster_width_state.width),
                .break_after = finalizedBreakKind(cluster_break_kind, cluster_class, curr_class, include_breaks),
            };
            count += 1;
            col += cluster_width_state.width;

            if (count == scratch.len or if (max_bytes) |byte_limit| count > 0 and pos < text.len and @as(u32, @intCast(pos)) - start_byte >= byte_limit else false) {
                setLayoutScanCursor(cursor, @intCast(pos), col, pre_prev_cp, pre_break_state);
                return .{
                    .spans = scratch[0..count],
                    .consumed_bytes = cursor.byte_offset - start_byte,
                    .consumed_cols = cursor.col_offset - start_col,
                    .done = false,
                };
            }

            cluster_start = pos;
            cluster_col_start = col;
            cluster_width_state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
            cluster_break_kind = cp_break_kind;
            cluster_class = curr_class;
        } else {
            cluster_width_state.addCodepoint(curr_cp, cp_width);
            cluster_break_kind = mergeBreakKind(cluster_break_kind, cp_break_kind);
        }

        prev_cp = curr_cp;
        pos += cp_len;
    }

    if (cluster_started) {
        scratch[count] = .{
            .byte_start = @intCast(cluster_start),
            .byte_len = @intCast(text.len - cluster_start),
            .col_start = cluster_col_start,
            .col_width = @intCast(cluster_width_state.width),
            .break_after = finalizedBreakKind(cluster_break_kind, cluster_class, null, include_breaks),
        };
        count += 1;
        col += cluster_width_state.width;
    }

    setLayoutScanCursor(cursor, @intCast(text.len), col, prev_cp, break_state);

    return .{
        .spans = scratch[0..count],
        .consumed_bytes = cursor.byte_offset - start_byte,
        .consumed_cols = cursor.col_offset - start_col,
        .done = true,
    };
}

pub fn scanLayoutNextBatch(
    text: []const u8,
    tab_width: u8,
    is_ascii_only: bool,
    width_method: WidthMethod,
    cursor: *LayoutScanCursor,
    scratch: []GraphemeSpan,
) LayoutScanError!LayoutSpanBatch {
    return scanLayoutBatchInternal(text, tab_width, is_ascii_only, width_method, cursor, scratch, null, true);
}

pub fn scanLayoutNextBatchNoBreaks(
    text: []const u8,
    tab_width: u8,
    is_ascii_only: bool,
    width_method: WidthMethod,
    cursor: *LayoutScanCursor,
    scratch: []GraphemeSpan,
) LayoutScanError!LayoutSpanBatch {
    return scanLayoutBatchInternal(text, tab_width, is_ascii_only, width_method, cursor, scratch, null, false);
}

pub fn scanLayoutNextWindowBatch(
    text: []const u8,
    tab_width: u8,
    is_ascii_only: bool,
    width_method: WidthMethod,
    cursor: *LayoutScanCursor,
    scratch: []GraphemeSpan,
    max_bytes: u32,
) LayoutScanError!LayoutSpanBatch {
    return scanLayoutBatchInternal(text, tab_width, is_ascii_only, width_method, cursor, scratch, max_bytes, true);
}

pub fn scanLayoutNextWindowBatchNoBreaks(
    text: []const u8,
    tab_width: u8,
    is_ascii_only: bool,
    width_method: WidthMethod,
    cursor: *LayoutScanCursor,
    scratch: []GraphemeSpan,
    max_bytes: u32,
) LayoutScanError!LayoutSpanBatch {
    return scanLayoutBatchInternal(text, tab_width, is_ascii_only, width_method, cursor, scratch, max_bytes, false);
}

// Nothing needed here - using uucode.grapheme.isBreak directly

pub fn collectWrapBreaks(text: []const u8, result: *WrapBreakResult, width_method: WidthMethod) !void {
    // This function clears previous results and writes fresh break points.
    // Callers should treat `result.breaks` as replaced after the call.
    _ = width_method; // Currently unused, but kept for API consistency
    result.reset();
    const vector_len = 16;

    var pos: usize = 0;
    var char_offset: u32 = 0;
    var prev_cp: ?u21 = null; // Track previous codepoint for grapheme detection
    var break_state: uucode.grapheme.BreakState = .default;
    // We keep track of the current grapheme so we can add a break at
    // CJK<->ASCII transitions. The break is emitted at the previous grapheme,
    // so callers that add grapheme width land exactly at the run boundary.
    var have_current_grapheme = false;
    var current_grapheme_byte_offset: u32 = 0;
    var current_grapheme_char_offset: u32 = 0;
    var current_grapheme_class: WordClass = .other;

    while (pos + vector_len <= text.len) {
        const chunk: @Vector(vector_len, u8) = text[pos..][0..vector_len].*;
        const ascii_threshold: @Vector(vector_len, u8) = @splat(0x80);
        const is_non_ascii = chunk >= ascii_threshold;

        // Fast path: all ASCII
        if (!@reduce(.Or, is_non_ascii)) {
            const first_class = classifyAsciiWordClass(text[pos]);
            if (have_current_grapheme and isCjkAsciiTransition(current_grapheme_class, first_class)) {
                try result.breaks.append(result.allocator, .{
                    .byte_offset = current_grapheme_byte_offset,
                    .char_offset = current_grapheme_char_offset,
                });
            }

            // Use SIMD to find break characters
            var match_mask: @Vector(vector_len, bool) = @splat(false);

            // Check whitespace
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat(' ')));
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat('\t')));

            // Check dashes and slashes
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat('-')));
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat('/')));
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat('\\')));

            // Check punctuation
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat('.')));
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat(',')));
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat(';')));
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat(':')));
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat('!')));
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat('?')));

            // Check brackets
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat('(')));
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat(')')));
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat('[')));
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat(']')));
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat('{')));
            match_mask = match_mask | (chunk == @as(@Vector(vector_len, u8), @splat('}')));

            // Convert boolean mask to integer bitmask for faster iteration
            var bitmask: u16 = 0;
            inline for (0..vector_len) |i| {
                if (match_mask[i]) {
                    bitmask |= @as(u16, 1) << @intCast(i);
                }
            }

            // Use bit manipulation to extract positions
            while (bitmask != 0) {
                const bit_pos = @ctz(bitmask);
                try result.breaks.append(result.allocator, .{
                    .byte_offset = @intCast(pos + bit_pos),
                    .char_offset = char_offset + @as(u32, @intCast(bit_pos)),
                });
                bitmask &= bitmask - 1;
            }

            pos += vector_len;
            const block_start_char_offset = char_offset;
            char_offset += vector_len;
            prev_cp = text[pos - 1]; // Last ASCII char
            break_state = .default;
            have_current_grapheme = true;
            current_grapheme_byte_offset = @intCast(pos - 1);
            current_grapheme_char_offset = block_start_char_offset + (vector_len - 1);
            current_grapheme_class = classifyAsciiWordClass(text[pos - 1]);
            continue;
        }

        // Slow path: mixed ASCII/non-ASCII - need grapheme-aware counting
        var i: usize = 0;
        while (i < vector_len) {
            const b0 = text[pos + i];
            if (b0 < 0x80) {
                const curr_cp: u21 = b0;

                // Check if this starts a new grapheme cluster
                // Skip invalid/replacement codepoints or codepoints that might be outside the grapheme table range
                const is_break = if (curr_cp == 0xFFFD or curr_cp > 0x10FFFF) true else if (prev_cp) |p| blk: {
                    if (p == 0xFFFD or p > 0x10FFFF) break :blk true;
                    break :blk uucode.grapheme.isBreak(p, curr_cp, &break_state);
                } else true;

                if (is_break) {
                    const curr_class = classifyAsciiWordClass(b0);
                    if (have_current_grapheme and isCjkAsciiTransition(current_grapheme_class, curr_class)) {
                        try result.breaks.append(result.allocator, .{
                            .byte_offset = current_grapheme_byte_offset,
                            .char_offset = current_grapheme_char_offset,
                        });
                    }
                    have_current_grapheme = true;
                    current_grapheme_byte_offset = @intCast(pos + i);
                    current_grapheme_char_offset = char_offset;
                    current_grapheme_class = curr_class;
                }

                if (isAsciiWrapBreak(b0)) {
                    try result.breaks.append(result.allocator, .{
                        .byte_offset = @intCast(pos + i),
                        .char_offset = char_offset,
                    });
                }
                i += 1;
                if (is_break) {
                    char_offset += 1;
                }
                prev_cp = curr_cp;
            } else {
                const dec = decodeUtf8Unchecked(text, pos + i);
                if (pos + i + dec.len > text.len) break;
                if (pos + i + dec.len > pos + vector_len) break;

                // Check if this starts a new grapheme cluster
                // Skip invalid/replacement codepoints or codepoints that might be outside the grapheme table range
                const is_break = if (dec.cp == 0xFFFD or dec.cp > 0x10FFFF) true else if (prev_cp) |p| blk: {
                    if (p == 0xFFFD or p > 0x10FFFF) break :blk true;
                    break :blk uucode.grapheme.isBreak(p, dec.cp, &break_state);
                } else true;

                if (is_break) {
                    const curr_class = classifyWordClass(dec.cp);
                    if (have_current_grapheme and isCjkAsciiTransition(current_grapheme_class, curr_class)) {
                        try result.breaks.append(result.allocator, .{
                            .byte_offset = current_grapheme_byte_offset,
                            .char_offset = current_grapheme_char_offset,
                        });
                    }
                    have_current_grapheme = true;
                    current_grapheme_byte_offset = @intCast(pos + i);
                    current_grapheme_char_offset = char_offset;
                    current_grapheme_class = curr_class;
                }

                if (isUnicodeWrapBreak(dec.cp)) {
                    try result.breaks.append(result.allocator, .{
                        .byte_offset = @intCast(pos + i),
                        .char_offset = char_offset,
                    });
                }
                i += dec.len;
                if (is_break) {
                    char_offset += 1;
                }
                prev_cp = dec.cp;
            }
        }
        pos += i;
    }

    // Tail
    var i: usize = pos;
    while (i < text.len) {
        const b0 = text[i];
        if (b0 < 0x80) {
            const curr_cp: u21 = b0;
            const is_break = if (prev_cp) |p| blk: {
                if (p == 0xFFFD or p > 0x10FFFF) break :blk true;
                break :blk uucode.grapheme.isBreak(p, curr_cp, &break_state);
            } else true;

            if (is_break) {
                const curr_class = classifyWordClass(curr_cp);
                if (have_current_grapheme and isCjkAsciiTransition(current_grapheme_class, curr_class)) {
                    try result.breaks.append(result.allocator, .{
                        .byte_offset = current_grapheme_byte_offset,
                        .char_offset = current_grapheme_char_offset,
                    });
                }
                have_current_grapheme = true;
                current_grapheme_byte_offset = @intCast(i);
                current_grapheme_char_offset = char_offset;
                current_grapheme_class = curr_class;
            }

            if (isAsciiWrapBreak(b0)) {
                try result.breaks.append(result.allocator, .{
                    .byte_offset = @intCast(i),
                    .char_offset = char_offset,
                });
            }
            i += 1;
            if (is_break) {
                char_offset += 1;
            }
            prev_cp = curr_cp;
        } else {
            const dec = decodeUtf8Unchecked(text, i);
            if (i + dec.len > text.len) break;

            const is_break = if (dec.cp == 0xFFFD or dec.cp > 0x10FFFF) true else if (prev_cp) |p| blk: {
                if (p == 0xFFFD or p > 0x10FFFF) break :blk true;
                break :blk uucode.grapheme.isBreak(p, dec.cp, &break_state);
            } else true;

            if (is_break) {
                const curr_class = classifyWordClass(dec.cp);
                if (have_current_grapheme and isCjkAsciiTransition(current_grapheme_class, curr_class)) {
                    try result.breaks.append(result.allocator, .{
                        .byte_offset = current_grapheme_byte_offset,
                        .char_offset = current_grapheme_char_offset,
                    });
                }
                have_current_grapheme = true;
                current_grapheme_byte_offset = @intCast(i);
                current_grapheme_char_offset = char_offset;
                current_grapheme_class = curr_class;
            }

            if (isUnicodeWrapBreak(dec.cp)) {
                try result.breaks.append(result.allocator, .{
                    .byte_offset = @intCast(i),
                    .char_offset = char_offset,
                });
            }
            i += dec.len;
            if (is_break) {
                char_offset += 1;
            }
            prev_cp = dec.cp;
        }
    }
}

pub fn findTabStops(text: []const u8, result: *TabStopResult) !void {
    result.reset();
    const vector_len = 16;
    const Vec = @Vector(vector_len, u8);

    const vTab: Vec = @splat('\t');

    var pos: usize = 0;

    while (pos + vector_len <= text.len) {
        const chunk: Vec = text[pos..][0..vector_len].*;
        const cmp_tab = chunk == vTab;

        if (@reduce(.Or, cmp_tab)) {
            var i: usize = 0;
            while (i < vector_len) : (i += 1) {
                if (text[pos + i] == '\t') {
                    try result.positions.append(result.allocator, pos + i);
                }
            }
        }
        pos += vector_len;
    }

    while (pos < text.len) : (pos += 1) {
        if (text[pos] == '\t') {
            try result.positions.append(result.allocator, pos);
        }
    }
}

pub fn findLineBreaks(text: []const u8, result: *LineBreakResult) !void {
    result.reset();
    const vector_len = 16; // Use 16-byte vectors (SSE2/NEON compatible)
    const Vec = @Vector(vector_len, u8);

    // Prepare vector constants for '\n' and '\r'
    const vNL: Vec = @splat('\n');
    const vCR: Vec = @splat('\r');

    var pos: usize = 0;
    var prev_was_cr = false; // Track if previous chunk ended with \r

    // Process full vector chunks
    while (pos + vector_len <= text.len) {
        const chunk: Vec = text[pos..][0..vector_len].*;
        const cmp_nl = chunk == vNL;
        const cmp_cr = chunk == vCR;

        // Check if any newline or CR found
        if (@reduce(.Or, cmp_nl) or @reduce(.Or, cmp_cr)) {
            // Found a match, process this chunk
            var i: usize = 0;
            while (i < vector_len) : (i += 1) {
                const absolute_index = pos + i;
                const b = text[absolute_index];
                if (b == '\n') {
                    // Skip if this is the \n part of a CRLF split across chunks
                    if (i == 0 and prev_was_cr) {
                        prev_was_cr = false;
                        continue;
                    }
                    // Check if this is part of CRLF
                    const kind: LineBreakKind = if (absolute_index > 0 and text[absolute_index - 1] == '\r') .CRLF else .LF;
                    try result.breaks.append(result.allocator, .{ .pos = absolute_index, .kind = kind });
                } else if (b == '\r') {
                    // Check for CRLF
                    if (absolute_index + 1 < text.len and text[absolute_index + 1] == '\n') {
                        try result.breaks.append(result.allocator, .{ .pos = absolute_index + 1, .kind = .CRLF });
                        i += 1; // Skip the \n in next iteration
                    } else {
                        try result.breaks.append(result.allocator, .{ .pos = absolute_index, .kind = .CR });
                    }
                }
            }
            // Update prev_was_cr for next chunk
            prev_was_cr = (text[pos + vector_len - 1] == '\r');
        } else {
            prev_was_cr = false;
        }
        pos += vector_len;
    }

    // Handle remaining bytes with scalar code
    while (pos < text.len) : (pos += 1) {
        const b = text[pos];
        if (b == '\n') {
            // Handle CRLF split at chunk boundary
            if (pos > 0 and text[pos - 1] == '\r') {
                // Already recorded at pos - 1 or will be skipped
                if (prev_was_cr) {
                    prev_was_cr = false;
                    continue;
                }
            }
            const kind: LineBreakKind = if (pos > 0 and text[pos - 1] == '\r') .CRLF else .LF;
            try result.breaks.append(result.allocator, .{ .pos = pos, .kind = kind });
        } else if (b == '\r') {
            if (pos + 1 < text.len and text[pos + 1] == '\n') {
                try result.breaks.append(result.allocator, .{ .pos = pos + 1, .kind = .CRLF });
                pos += 1;
            } else {
                try result.breaks.append(result.allocator, .{ .pos = pos, .kind = .CR });
            }
        }
        prev_was_cr = false;
    }
}

pub const WrapByWidthResult = struct {
    byte_offset: u32,
    grapheme_count: u32,
    columns_used: u32,
};

pub const PosByWidthResult = struct {
    byte_offset: u32,
    grapheme_count: u32,
    columns_used: u32,
};

pub inline fn eastAsianWidth(cp: u21) u32 {
    if (cp > 0x10FFFF) return 0;
    const eaw = uucode.get(.east_asian_width, cp);
    const width = eawToWidth(cp, eaw);
    return if (width > 0) @intCast(width) else 0;
}

/// Calculate width from east asian width property and Unicode properties
/// Returns -1 for control characters (they don't contribute to width)
inline fn eawToWidth(cp: u21, eaw: uucode.types.EastAsianWidth) i16 {
    if (cp == 0) return 0;
    if (cp < 32 or (cp >= 0x7F and cp < 0xA0)) return -1;

    const gc = uucode.get(.general_category, cp);
    switch (gc) {
        .mark_nonspacing, .mark_spacing_combining, .mark_enclosing => return 0,
        else => {},
    }

    if (cp == 0x200B) return 0;
    if (cp == 0x200C) return 0;
    if (cp == 0x200D) return 0;
    if (cp == 0x2060) return 0;
    if (cp == 0x034F) return 0;
    if (cp == 0xFEFF) return 0;
    if (cp >= 0x180B and cp <= 0x180D) return 0;
    if (cp >= 0xFE00 and cp <= 0xFE0F) return 0;
    if (cp >= 0xE0100 and cp <= 0xE01EF) return 0;

    if (eaw == .fullwidth or eaw == .wide) return 2;

    if (cp >= 0x1F000 and cp <= 0x1F02B) return 2;
    if (cp >= 0x1F030 and cp <= 0x1F093) return 2;
    if (cp >= 0x1F0A0 and cp <= 0x1F0AE) return 2;
    if (cp >= 0x1F0B1 and cp <= 0x1F0BF) return 2;
    if (cp >= 0x1F0C1 and cp <= 0x1F0CF) return 2;
    if (cp >= 0x1F0D1 and cp <= 0x1F0F5) return 2;

    if (cp == 0x231A or cp == 0x231B) return 2;
    if (cp == 0x2329 or cp == 0x232A) return 2;
    if (cp >= 0x23E9 and cp <= 0x23EC) return 2;
    if (cp == 0x23F0 or cp == 0x23F3) return 2;
    if (cp >= 0x25FD and cp <= 0x25FE) return 2;

    if (cp >= 0x2614 and cp <= 0x2615) return 2;
    if (cp == 0x2622 or cp == 0x2623) return 2;
    if (cp >= 0x2630 and cp <= 0x2637) return 2;
    if (cp >= 0x2648 and cp <= 0x2653) return 2;
    if (cp == 0x267F or cp == 0x2693 or cp == 0x269B) return 2;
    if (cp == 0x26A0 or cp == 0x26A1) return 2;
    if (cp >= 0x26AA and cp <= 0x26AB) return 2;
    if (cp >= 0x26BD and cp <= 0x26BE) return 2;
    if (cp >= 0x26C4 and cp <= 0x26C5) return 2;
    if (cp == 0x26CE or cp == 0x26D1 or cp == 0x26D4) return 2;
    if (cp == 0x26EA or cp == 0x26F2 or cp == 0x26F3) return 2;
    if (cp == 0x26F5 or cp == 0x26FA or cp == 0x26FD) return 2;

    if (cp == 0x203C or cp == 0x2049) return 2;
    if (cp == 0x2705 or cp >= 0x270A and cp <= 0x270B) return 2;
    if (cp == 0x2728 or cp == 0x274C or cp == 0x274E) return 2;
    if (cp >= 0x2753 and cp <= 0x2755) return 2;
    if (cp == 0x2757) return 2;
    if (cp >= 0x2760 and cp <= 0x2767) return 2;
    if (cp >= 0x2795 and cp <= 0x2797) return 2;
    if (cp == 0x27B0 or cp == 0x27BF) return 2;
    if (cp >= 0x2B1B and cp <= 0x2B1C) return 2;
    if (cp >= 0x2B50 and cp <= 0x2B50) return 2;
    if (cp >= 0x2B55 and cp <= 0x2B55) return 2;

    if (cp >= 0x1F300 and cp <= 0x1F320) return 2;
    if (cp >= 0x1F32D and cp <= 0x1F335) return 2;
    if (cp >= 0x1F337 and cp <= 0x1F37C) return 2;
    if (cp >= 0x1F37E and cp <= 0x1F393) return 2;
    if (cp >= 0x1F3A0 and cp <= 0x1F3CA) return 2;
    if (cp >= 0x1F3CF and cp <= 0x1F3D3) return 2;
    if (cp >= 0x1F3E0 and cp <= 0x1F3F0) return 2;
    if (cp == 0x1F3F4) return 2;
    if (cp >= 0x1F3F8 and cp <= 0x1F3FF) return 2;
    if (cp >= 0x1F400 and cp <= 0x1F43E) return 2;
    if (cp == 0x1F440) return 2;
    if (cp >= 0x1F442 and cp <= 0x1F4FC) return 2;
    if (cp >= 0x1F4FF and cp <= 0x1F6C5) return 2;
    if (cp == 0x1F6CC) return 2;
    if (cp >= 0x1F6D0 and cp <= 0x1F6D2) return 2;
    if (cp >= 0x1F6D5 and cp <= 0x1F6D7) return 2;
    if (cp >= 0x1F6DC and cp <= 0x1F6DF) return 2;
    if (cp >= 0x1F6EB and cp <= 0x1F6EC) return 2;
    if (cp >= 0x1F6F4 and cp <= 0x1F6FC) return 2;
    if (cp >= 0x1F700 and cp <= 0x1F773) return 2;
    if (cp >= 0x1F780 and cp <= 0x1F7D8) return 2;
    if (cp >= 0x1F7E0 and cp <= 0x1F7EB) return 2;
    if (cp >= 0x1F800 and cp <= 0x1F80B) return 2;
    if (cp >= 0x1F810 and cp <= 0x1F847) return 2;
    if (cp >= 0x1F850 and cp <= 0x1F859) return 2;
    if (cp >= 0x1F860 and cp <= 0x1F887) return 2;
    if (cp >= 0x1F890 and cp <= 0x1F8AD) return 2;
    if (cp >= 0x1F8B0 and cp <= 0x1F8B1) return 2;
    if (cp >= 0x1F90C and cp <= 0x1F93A) return 2;
    if (cp >= 0x1F93C and cp <= 0x1F945) return 2;
    if (cp >= 0x1F947 and cp <= 0x1FA53) return 2;
    if (cp >= 0x1FA60 and cp <= 0x1FA6D) return 2;
    if (cp >= 0x1FA70 and cp <= 0x1FA74) return 2;
    if (cp >= 0x1FA78 and cp <= 0x1FA7C) return 2;
    if (cp >= 0x1FA80 and cp <= 0x1FA86) return 2;
    if (cp >= 0x1FA90 and cp <= 0x1FAAC) return 2;
    if (cp >= 0x1FAB0 and cp <= 0x1FABA) return 2;
    if (cp >= 0x1FAC0 and cp <= 0x1FAC5) return 2;
    if (cp >= 0x1FAD0 and cp <= 0x1FAD9) return 2;
    if (cp >= 0x1FAE0 and cp <= 0x1FAE7) return 2;
    if (cp >= 0x1FAF0 and cp <= 0x1FAF8) return 2;

    return 1;
}

/// Calculate the display width of a byte in columns
/// Used for ASCII-only fast paths
inline fn asciiCharWidth(byte: u8, tab_width: u8) u32 {
    if (byte == '\t') {
        return tab_width;
    } else if (byte >= 32 and byte <= 126) {
        return 1;
    }
    return 0;
}

/// Calculate the display width of a character (byte or codepoint) in columns
inline fn charWidth(byte: u8, codepoint: u21, tab_width: u8) u32 {
    if (byte == '\t') {
        return tab_width;
    } else if (byte < 0x80 and byte >= 32 and byte <= 126) {
        return 1;
    } else if (byte >= 0x80) {
        const eaw = uucode.get(.east_asian_width, codepoint);
        const w = eawToWidth(codepoint, eaw);
        return if (w > 0) @intCast(w) else 0;
    }
    return 0;
}

/// Check if a codepoint is valid for grapheme break detection
inline fn isValidCodepoint(cp: u21) bool {
    return cp != 0xFFFD and cp <= 0x10FFFF;
}

/// Check if there's a grapheme break between two codepoints
/// - wcwidth mode: use Unicode grapheme clustering for proper rendering,
///   but calculate width using wcwidth (sum of codepoint widths)
/// - no_zwj mode: use grapheme breaks but treat ZWJ as a break (ignore joining)
/// - unicode mode: use standard grapheme cluster segmentation
inline fn isGraphemeBreak(prev_cp: ?u21, curr_cp: u21, break_state: *uucode.grapheme.BreakState, width_method: WidthMethod) bool {
    // wcwidth mode uses Unicode grapheme clustering for proper rendering
    // (ZWJ sequences, skin tone modifiers stay together), but width is
    // calculated using wcwidth semantics (sum of codepoint widths)
    if (width_method == .wcwidth) {
        if (prev_cp == null) return true;

        if (!isValidCodepoint(curr_cp)) return true;
        if (!isValidCodepoint(prev_cp.?)) return true;
        return uucode.grapheme.isBreak(prev_cp.?, curr_cp, break_state);
    }

    if (!isValidCodepoint(curr_cp)) return true;

    // In no_zwj mode, treat ZWJ (U+200D) as NOT joining characters
    // When we see ZWJ after a character, it's part of that character's grapheme
    // But when we see a character after ZWJ, it starts a new grapheme
    if (width_method == .no_zwj) {
        const ZWJ: u21 = 0x200D;
        if (prev_cp) |p| {
            // If previous was ZWJ, current starts a new grapheme
            // Don't call uucode.grapheme.isBreak because it will say no break
            if (p == ZWJ) {
                // Reset break state since we're forcing a break
                break_state.* = .default;
                return true;
            }
        }
        // If current is ZWJ, don't break yet - it's part of previous grapheme
        // (will have width 0 anyway)
    }

    if (prev_cp) |p| {
        if (!isValidCodepoint(p)) return true;
        return uucode.grapheme.isBreak(p, curr_cp, break_state);
    }
    return true;
}

/// State for accumulating grapheme cluster width
const GraphemeWidthState = struct {
    width: u32 = 0,
    has_width: bool = false,
    is_regional_indicator_pair: bool = false,
    has_vs16: bool = false,
    has_indic_virama: bool = false,
    width_method: WidthMethod,

    /// Initialize state with the first codepoint of a grapheme cluster
    inline fn init(first_cp: u21, first_width: u32, width_method: WidthMethod) GraphemeWidthState {
        return .{
            .width = first_width,
            .has_width = (first_width > 0),
            .is_regional_indicator_pair = (first_cp >= 0x1F1E6 and first_cp <= 0x1F1FF),
            .has_vs16 = false,
            .has_indic_virama = false,
            .width_method = width_method,
        };
    }

    /// Add a codepoint to the current grapheme cluster
    inline fn addCodepoint(self: *GraphemeWidthState, cp: u21, cp_width: u32) void {
        // wcwidth mode: sum all codepoint widths (tmux-style)
        if (self.width_method == .wcwidth) {
            const eaw = uucode.get(.east_asian_width, cp);
            const w = eawToWidth(cp, eaw);
            if (w > 0) {
                self.width += @intCast(w);
                self.has_width = true;
            }
            return;
        }

        // unicode and no_zwj modes: use grapheme-aware width
        const is_ri = (cp >= 0x1F1E6 and cp <= 0x1F1FF);
        const is_vs16 = (cp == 0xFE0F); // Variation Selector-16 (emoji presentation)

        const gc = uucode.get(.general_category, cp);
        const is_virama = gc == .mark_nonspacing;

        const is_devanagari_ra = (cp == 0x0930);

        const is_devanagari_base = (cp >= 0x0915 and cp <= 0x0939) or (cp >= 0x0958 and cp <= 0x095F);

        if (is_vs16) {
            self.has_vs16 = true;
            if (self.has_width and self.width == 1) {
                self.width = 2;
            }
            return;
        }

        if (is_virama) {
            self.has_indic_virama = true;
            return;
        }

        if (self.is_regional_indicator_pair and is_ri) {
            self.width += cp_width;
            self.has_width = true;
        } else if (!self.has_width and cp_width > 0) {
            self.width = cp_width;
            self.has_width = true;
        } else if (self.has_width and self.has_indic_virama and is_devanagari_base and cp_width > 0) {
            if (!is_devanagari_ra) {
                self.width += cp_width;
            }
            self.has_indic_virama = false;
        }
    }
};

const ClusterState = struct {
    columns_used: u32,
    grapheme_count: u32,
    cluster_width: u32,
    cluster_start: usize,
    prev_cp: ?u21,
    break_state: uucode.grapheme.BreakState,
    width_state: GraphemeWidthState,
    width_method: WidthMethod,
    cluster_started: bool,

    fn init(width_method: WidthMethod) ClusterState {
        const dummy_width_state = GraphemeWidthState.init(0, 0, width_method);
        return .{
            .columns_used = 0,
            .grapheme_count = 0,
            .cluster_width = 0,
            .cluster_start = 0,
            .prev_cp = null,
            .break_state = .default,
            .width_state = dummy_width_state,
            .width_method = width_method,
            .cluster_started = false,
        };
    }
};

/// Handle grapheme cluster boundary when wrapping by width (stops BEFORE exceeding limit)
/// Returns true if we should stop (limit exceeded)
inline fn handleClusterForWrap(
    state: *ClusterState,
    is_break: bool,
    new_cluster_start: usize,
    max_columns: u32,
) bool {
    if (is_break) {
        if (state.prev_cp != null) {
            if (state.columns_used + state.cluster_width > max_columns) {
                return true; // Signal to stop
            }
            state.columns_used += state.cluster_width;
            state.grapheme_count += 1;
        }
        state.cluster_width = 0;
        state.cluster_start = new_cluster_start;
        state.cluster_started = false;
    }
    return false;
}

/// Handle grapheme cluster boundary when finding position (snaps to grapheme boundaries)
/// Returns true if we should stop
///
/// Snapping behavior:
/// - include_start_before=true (for selection end): Include graphemes that START at or before max_columns
///   If max_columns=3 and grapheme occupies columns [2-3], include it (starts at 2 <= 3)
///   This snaps forward to include the whole grapheme even if max_columns points to its middle
/// - include_start_before=false (for selection start): Only include graphemes that END before max_columns
///   If max_columns=3 and grapheme occupies columns [2-3], exclude it (ends at 4 > 3)
///   This snaps backward to exclude wide graphemes that would cross max_columns
inline fn handleClusterForPos(
    state: *ClusterState,
    is_break: bool,
    new_cluster_start: usize,
    max_columns: u32,
    include_start_before: bool,
) bool {
    if (is_break) {
        if (state.prev_cp != null) {
            const cluster_start_col = state.columns_used;
            const cluster_end_col = state.columns_used + state.cluster_width;

            if (include_start_before) {
                if (cluster_start_col >= max_columns) {
                    return true;
                }
                state.columns_used = cluster_end_col;
                state.grapheme_count += 1;
            } else {
                if (cluster_end_col > max_columns) {
                    return true; // Signal to stop (don't include this grapheme)
                }
                state.columns_used = cluster_end_col;
            }
        }
        state.cluster_width = 0;
        state.cluster_start = new_cluster_start;
        state.cluster_started = false;
    }
    return false;
}

/// Find wrap position by width - proxy function that dispatches based on width_method
pub fn measureWrapFitByWidth(
    text: []const u8,
    max_columns: u32,
    tab_width: u8,
    isASCIIOnly: bool,
    width_method: WidthMethod,
) WrapByWidthResult {
    switch (width_method) {
        .unicode, .no_zwj => return findWrapPosByWidthUnicode(text, max_columns, tab_width, isASCIIOnly, width_method),
        .wcwidth => return findWrapPosByWidthWCWidth(text, max_columns, tab_width, isASCIIOnly),
    }
}

/// Find wrap position by width using Unicode grapheme cluster segmentation
fn findWrapPosByWidthUnicode(
    text: []const u8,
    max_columns: u32,
    tab_width: u8,
    isASCIIOnly: bool,
    width_method: WidthMethod,
) WrapByWidthResult {
    if (text.len == 0 or max_columns == 0) {
        return .{ .byte_offset = 0, .grapheme_count = 0, .columns_used = 0 };
    }

    // ASCII-only fast path
    if (isASCIIOnly) {
        if (max_columns >= text.len) {
            return .{ .byte_offset = @intCast(text.len), .grapheme_count = @intCast(text.len), .columns_used = @intCast(text.len) };
        } else {
            return .{ .byte_offset = max_columns, .grapheme_count = max_columns, .columns_used = max_columns };
        }
    }

    const vector_len = 16;
    var pos: usize = 0;
    var state = ClusterState.init(width_method);

    while (pos + vector_len <= text.len) {
        const chunk: @Vector(vector_len, u8) = text[pos..][0..vector_len].*;
        const ascii_threshold: @Vector(vector_len, u8) = @splat(0x80);
        const is_non_ascii = chunk >= ascii_threshold;

        if (!@reduce(.Or, is_non_ascii)) {
            // All ASCII
            var i: usize = 0;
            while (i < vector_len) : (i += 1) {
                const b = text[pos + i];
                const curr_cp: u21 = b;
                const is_break = isGraphemeBreak(state.prev_cp, curr_cp, &state.break_state, state.width_method);

                if (handleClusterForWrap(&state, is_break, pos + i, max_columns)) {
                    return .{ .byte_offset = @intCast(state.cluster_start), .grapheme_count = state.grapheme_count, .columns_used = state.columns_used };
                }

                const cp_width = asciiCharWidth(b, tab_width);
                if (!state.cluster_started) {
                    state.width_state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
                    state.cluster_width = cp_width;
                    state.cluster_started = true;
                } else {
                    state.width_state.addCodepoint(curr_cp, cp_width);
                    state.cluster_width = state.width_state.width;
                }
                state.prev_cp = curr_cp;
            }
            pos += vector_len;
            continue;
        }

        // Mixed ASCII/non-ASCII - process rest of chunk
        var i: usize = 0;
        while (i < vector_len and pos + i < text.len) {
            const b0 = text[pos + i];
            const curr_cp: u21 = if (b0 < 0x80) b0 else decodeUtf8Unchecked(text, pos + i).cp;
            const cp_len: usize = if (b0 < 0x80) 1 else decodeUtf8Unchecked(text, pos + i).len;

            if (pos + i + cp_len > text.len) break;

            const is_break = isGraphemeBreak(state.prev_cp, curr_cp, &state.break_state, state.width_method);

            if (handleClusterForWrap(&state, is_break, pos + i, max_columns)) {
                return .{ .byte_offset = @intCast(state.cluster_start), .grapheme_count = state.grapheme_count, .columns_used = state.columns_used };
            }

            const cp_width = charWidth(b0, curr_cp, tab_width);
            if (!state.cluster_started) {
                state.width_state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
                state.cluster_width = cp_width;
                state.cluster_started = true;
            } else {
                state.width_state.addCodepoint(curr_cp, cp_width);
                state.cluster_width = state.width_state.width;
            }
            state.prev_cp = curr_cp;
            i += cp_len;
        }
        pos += i; // Advance by how much we actually processed
    }

    // Tail
    while (pos < text.len) {
        const b0 = text[pos];
        const curr_cp: u21 = if (b0 < 0x80) b0 else decodeUtf8Unchecked(text, pos).cp;
        const cp_len: usize = if (b0 < 0x80) 1 else decodeUtf8Unchecked(text, pos).len;

        const is_break = isGraphemeBreak(state.prev_cp, curr_cp, &state.break_state, state.width_method);

        if (handleClusterForWrap(&state, is_break, pos, max_columns)) {
            return .{ .byte_offset = @intCast(state.cluster_start), .grapheme_count = state.grapheme_count, .columns_used = state.columns_used };
        }

        const cp_width = charWidth(b0, curr_cp, tab_width);
        if (!state.cluster_started) {
            state.width_state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
            state.cluster_width = cp_width;
            state.cluster_started = true;
        } else {
            state.width_state.addCodepoint(curr_cp, cp_width);
            state.cluster_width = state.width_state.width;
        }
        state.prev_cp = curr_cp;
        pos += cp_len;
    }

    // Final cluster
    if (state.prev_cp != null and state.cluster_width > 0) {
        if (state.columns_used + state.cluster_width > max_columns) {
            return .{ .byte_offset = @intCast(state.cluster_start), .grapheme_count = state.grapheme_count, .columns_used = state.columns_used };
        }
        state.columns_used += state.cluster_width;
        state.grapheme_count += 1;
    }

    return .{ .byte_offset = @intCast(text.len), .grapheme_count = state.grapheme_count, .columns_used = state.columns_used };
}

/// Find wrap position by width using wcwidth-style codepoint-by-codepoint processing
fn findWrapPosByWidthWCWidth(
    text: []const u8,
    max_columns: u32,
    tab_width: u8,
    isASCIIOnly: bool,
) WrapByWidthResult {
    if (text.len == 0 or max_columns == 0) {
        return .{ .byte_offset = 0, .grapheme_count = 0, .columns_used = 0 };
    }

    // ASCII-only fast path
    if (isASCIIOnly) {
        if (max_columns >= text.len) {
            return .{ .byte_offset = @intCast(text.len), .grapheme_count = @intCast(text.len), .columns_used = @intCast(text.len) };
        } else {
            return .{ .byte_offset = max_columns, .grapheme_count = max_columns, .columns_used = max_columns };
        }
    }

    // Unicode path - process each codepoint independently
    var pos: usize = 0;
    var columns_used: u32 = 0;
    var codepoint_count: u32 = 0;

    while (pos < text.len) {
        const b0 = text[pos];
        const curr_cp: u21 = if (b0 < 0x80) b0 else blk: {
            const dec = decodeUtf8Unchecked(text, pos);
            if (pos + dec.len > text.len) break :blk 0xFFFD;
            break :blk dec.cp;
        };
        const cp_len: usize = if (b0 < 0x80) 1 else decodeUtf8Unchecked(text, pos).len;

        if (pos + cp_len > text.len) break;

        const cp_width = charWidth(b0, curr_cp, tab_width);

        // In wcwidth mode, stop if we've already used max_columns
        // (don't continue adding zero-width chars after reaching limit)
        if (columns_used >= max_columns) {
            return .{ .byte_offset = @intCast(pos), .grapheme_count = codepoint_count, .columns_used = columns_used };
        }

        // Stop if adding this codepoint would exceed max_columns
        if (columns_used + cp_width > max_columns) {
            return .{ .byte_offset = @intCast(pos), .grapheme_count = codepoint_count, .columns_used = columns_used };
        }

        columns_used += cp_width;
        codepoint_count += 1;
        pos += cp_len;
    }

    return .{ .byte_offset = @intCast(text.len), .grapheme_count = codepoint_count, .columns_used = columns_used };
}

/// Find position by column width - proxy function that dispatches based on width_method
/// - If include_start_before: include graphemes that START before max_columns (snap forward for selection end)
///   This ensures that if max_columns points to the middle of a width=2 grapheme, we include the whole grapheme
/// - If !include_start_before: exclude graphemes that START at or after max_columns (snap backward for selection start)
///   This ensures that if max_columns points to the middle of a width=2 grapheme, we snap back to exclude it
pub fn resolveDisplayPosByWidth(
    text: []const u8,
    max_columns: u32,
    tab_width: u8,
    isASCIIOnly: bool,
    include_start_before: bool,
    width_method: WidthMethod,
) PosByWidthResult {
    switch (width_method) {
        .unicode, .no_zwj => return findPosByWidthUnicode(text, max_columns, tab_width, isASCIIOnly, include_start_before, width_method),
        .wcwidth => return findPosByWidthWCWidth(text, max_columns, tab_width, isASCIIOnly, include_start_before),
    }
}

/// Find position by column width using Unicode grapheme cluster segmentation
fn findPosByWidthUnicode(
    text: []const u8,
    max_columns: u32,
    tab_width: u8,
    isASCIIOnly: bool,
    include_start_before: bool,
    width_method: WidthMethod,
) PosByWidthResult {
    if (text.len == 0 or max_columns == 0) {
        return .{ .byte_offset = 0, .grapheme_count = 0, .columns_used = 0 };
    }

    // ASCII-only fast path
    if (isASCIIOnly) {
        if (max_columns >= text.len) {
            return .{ .byte_offset = @intCast(text.len), .grapheme_count = @intCast(text.len), .columns_used = @intCast(text.len) };
        } else {
            return .{ .byte_offset = max_columns, .grapheme_count = max_columns, .columns_used = max_columns };
        }
    }

    const vector_len = 16;
    var pos: usize = 0;
    var state = ClusterState.init(width_method);

    while (pos + vector_len <= text.len) {
        const chunk: @Vector(vector_len, u8) = text[pos..][0..vector_len].*;
        const ascii_threshold: @Vector(vector_len, u8) = @splat(0x80);
        const is_non_ascii = chunk >= ascii_threshold;

        if (!@reduce(.Or, is_non_ascii)) {
            // All ASCII
            var i: usize = 0;
            while (i < vector_len) : (i += 1) {
                const b = text[pos + i];
                const curr_cp: u21 = b;
                const is_break = isGraphemeBreak(state.prev_cp, curr_cp, &state.break_state, state.width_method);

                if (handleClusterForPos(&state, is_break, pos + i, max_columns, include_start_before)) {
                    return .{ .byte_offset = @intCast(state.cluster_start), .grapheme_count = state.grapheme_count, .columns_used = state.columns_used };
                }

                const cp_width = asciiCharWidth(b, tab_width);
                if (!state.cluster_started) {
                    state.width_state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
                    state.cluster_width = cp_width;
                    state.cluster_started = true;
                } else {
                    state.width_state.addCodepoint(curr_cp, cp_width);
                    state.cluster_width = state.width_state.width;
                }
                state.prev_cp = curr_cp;
            }
            pos += vector_len;
            continue;
        }

        // Mixed ASCII/non-ASCII - process rest of chunk
        var i: usize = 0;
        while (i < vector_len and pos + i < text.len) {
            const b0 = text[pos + i];
            const curr_cp: u21 = if (b0 < 0x80) b0 else decodeUtf8Unchecked(text, pos + i).cp;
            const cp_len: usize = if (b0 < 0x80) 1 else decodeUtf8Unchecked(text, pos + i).len;

            if (pos + i + cp_len > text.len) break;

            const is_break = isGraphemeBreak(state.prev_cp, curr_cp, &state.break_state, state.width_method);

            if (handleClusterForPos(&state, is_break, pos + i, max_columns, include_start_before)) {
                return .{ .byte_offset = @intCast(state.cluster_start), .grapheme_count = state.grapheme_count, .columns_used = state.columns_used };
            }

            const cp_width = charWidth(b0, curr_cp, tab_width);
            if (!state.cluster_started) {
                state.width_state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
                state.cluster_width = cp_width;
                state.cluster_started = true;
            } else {
                state.width_state.addCodepoint(curr_cp, cp_width);
                state.cluster_width = state.width_state.width;
            }
            state.prev_cp = curr_cp;
            i += cp_len;
        }
        pos += i; // Advance by how much we actually processed
    }

    // Tail
    while (pos < text.len) {
        const b0 = text[pos];
        const curr_cp: u21 = if (b0 < 0x80) b0 else decodeUtf8Unchecked(text, pos).cp;
        const cp_len: usize = if (b0 < 0x80) 1 else decodeUtf8Unchecked(text, pos).len;

        const is_break = isGraphemeBreak(state.prev_cp, curr_cp, &state.break_state, state.width_method);

        if (handleClusterForPos(&state, is_break, pos, max_columns, include_start_before)) {
            return .{ .byte_offset = @intCast(state.cluster_start), .grapheme_count = state.grapheme_count, .columns_used = state.columns_used };
        }

        const cp_width = charWidth(b0, curr_cp, tab_width);
        if (!state.cluster_started) {
            state.width_state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
            state.cluster_width = cp_width;
            state.cluster_started = true;
        } else {
            state.width_state.addCodepoint(curr_cp, cp_width);
            state.cluster_width = state.width_state.width;
        }
        state.prev_cp = curr_cp;
        pos += cp_len;
    }

    // Final cluster
    if (state.prev_cp != null and state.cluster_width > 0) {
        if (state.columns_used >= max_columns) {
            return .{ .byte_offset = @intCast(state.cluster_start), .grapheme_count = state.grapheme_count, .columns_used = state.columns_used };
        }
        state.columns_used += state.cluster_width;
        if (include_start_before) {
            state.grapheme_count += 1;
        }
    }

    return .{ .byte_offset = @intCast(text.len), .grapheme_count = state.grapheme_count, .columns_used = state.columns_used };
}

/// Find position by column width using wcwidth-style codepoint-by-codepoint processing
fn findPosByWidthWCWidth(
    text: []const u8,
    max_columns: u32,
    tab_width: u8,
    isASCIIOnly: bool,
    include_start_before: bool,
) PosByWidthResult {
    if (text.len == 0 or max_columns == 0) {
        return .{ .byte_offset = 0, .grapheme_count = 0, .columns_used = 0 };
    }

    // ASCII-only fast path
    if (isASCIIOnly) {
        if (max_columns >= text.len) {
            return .{ .byte_offset = @intCast(text.len), .grapheme_count = @intCast(text.len), .columns_used = @intCast(text.len) };
        } else {
            return .{ .byte_offset = max_columns, .grapheme_count = max_columns, .columns_used = max_columns };
        }
    }

    // Unicode path - process each codepoint independently
    var pos: usize = 0;
    var columns_used: u32 = 0;
    var codepoint_count: u32 = 0;

    while (pos < text.len) {
        const b0 = text[pos];
        const curr_cp: u21 = if (b0 < 0x80) b0 else blk: {
            const dec = decodeUtf8Unchecked(text, pos);
            if (pos + dec.len > text.len) break :blk 0xFFFD;
            break :blk dec.cp;
        };
        const cp_len: usize = if (b0 < 0x80) 1 else decodeUtf8Unchecked(text, pos).len;

        if (pos + cp_len > text.len) break;

        const cp_width = charWidth(b0, curr_cp, tab_width);
        const cp_start_col = columns_used;
        const cp_end_col = columns_used + cp_width;

        // Apply boundary behavior
        if (include_start_before) {
            // Selection end: include codepoints that START before max_columns
            if (cp_start_col >= max_columns) {
                return .{ .byte_offset = @intCast(pos), .grapheme_count = codepoint_count, .columns_used = columns_used };
            }
        } else {
            // Selection start: only include codepoints that END before or at max_columns
            // So exclude (stop) if end > max_columns
            if (cp_end_col > max_columns) {
                return .{ .byte_offset = @intCast(pos), .grapheme_count = codepoint_count, .columns_used = columns_used };
            }
        }

        columns_used = cp_end_col;
        codepoint_count += 1;
        pos += cp_len;
    }

    return .{ .byte_offset = @intCast(text.len), .grapheme_count = codepoint_count, .columns_used = columns_used };
}

/// Get width at byte offset - proxy function that dispatches based on width_method
pub fn getWidthAt(text: []const u8, byte_offset: usize, tab_width: u8, width_method: WidthMethod) u32 {
    switch (width_method) {
        .unicode, .no_zwj => return getWidthAtUnicode(text, byte_offset, tab_width, width_method),
        .wcwidth => return getWidthAtWCWidth(text, byte_offset, tab_width),
    }
}

/// Get width at byte offset using Unicode grapheme cluster segmentation
fn getWidthAtUnicode(text: []const u8, byte_offset: usize, tab_width: u8, width_method: WidthMethod) u32 {
    if (byte_offset >= text.len) return 0;

    const b0 = text[byte_offset];

    const first_cp: u21 = if (b0 < 0x80) b0 else blk: {
        const dec = decodeUtf8Unchecked(text, byte_offset);
        if (byte_offset + dec.len > text.len) return 1;
        break :blk dec.cp;
    };

    const first_len: usize = if (b0 < 0x80) 1 else decodeUtf8Unchecked(text, byte_offset).len;

    var break_state: uucode.grapheme.BreakState = .default;
    var prev_cp: ?u21 = first_cp;
    const first_width = charWidth(b0, first_cp, tab_width);
    var state = GraphemeWidthState.init(first_cp, first_width, width_method);

    var pos = byte_offset + first_len;

    while (pos < text.len) {
        const b = text[pos];
        const curr_cp: u21 = if (b < 0x80) b else decodeUtf8Unchecked(text, pos).cp;
        const cp_len: usize = if (b < 0x80) 1 else decodeUtf8Unchecked(text, pos).len;

        if (pos + cp_len > text.len) break;

        const is_break = isGraphemeBreak(prev_cp, curr_cp, &break_state, width_method);
        if (is_break) break;

        const cp_width = charWidth(b, curr_cp, tab_width);
        state.addCodepoint(curr_cp, cp_width);

        prev_cp = curr_cp;
        pos += cp_len;
    }

    return state.width;
}

/// Get width at byte offset using wcwidth-style codepoint-by-codepoint processing
/// In wcwidth mode, each codepoint is treated independently - return its width directly
fn getWidthAtWCWidth(text: []const u8, byte_offset: usize, tab_width: u8) u32 {
    if (byte_offset >= text.len) return 0;

    const b0 = text[byte_offset];

    const first_cp: u21 = if (b0 < 0x80) b0 else blk: {
        const dec = decodeUtf8Unchecked(text, byte_offset);
        if (byte_offset + dec.len > text.len) return 1;
        break :blk dec.cp;
    };

    const first_width = charWidth(b0, first_cp, tab_width);
    return first_width;
}

pub const PrevGraphemeResult = struct {
    start_offset: usize,
    width: u32,
};

/// Get previous grapheme start - proxy function that dispatches based on width_method
pub fn getPrevGraphemeStart(text: []const u8, byte_offset: usize, tab_width: u8, width_method: WidthMethod) ?PrevGraphemeResult {
    switch (width_method) {
        .unicode, .no_zwj => return getPrevGraphemeStartUnicode(text, byte_offset, tab_width, width_method),
        .wcwidth => return getPrevGraphemeStartWCWidth(text, byte_offset, tab_width),
    }
}

/// Get previous grapheme start using wcwidth-style codepoint-by-codepoint processing
fn getPrevGraphemeStartWCWidth(text: []const u8, byte_offset: usize, tab_width: u8) ?PrevGraphemeResult {
    if (byte_offset == 0 or text.len == 0) return null;
    if (byte_offset > text.len) return null;

    var pos: usize = 0;
    var last_result: ?PrevGraphemeResult = null;

    while (pos < byte_offset) {
        const b = text[pos];
        const curr_cp: u21 = if (b < 0x80) b else blk: {
            const dec = decodeUtf8Unchecked(text, pos);
            if (pos + dec.len > text.len) break :blk 0xFFFD;
            break :blk dec.cp;
        };
        const cp_len: usize = if (b < 0x80) 1 else decodeUtf8Unchecked(text, pos).len;
        const cp_width = charWidth(b, curr_cp, tab_width);

        if (cp_width > 0) {
            last_result = .{
                .start_offset = pos,
                .width = cp_width,
            };
        }
        pos += cp_len;
    }

    return last_result;
}

/// Get previous grapheme start using Unicode grapheme cluster segmentation
fn getPrevGraphemeStartUnicode(text: []const u8, byte_offset: usize, tab_width: u8, width_method: WidthMethod) ?PrevGraphemeResult {
    if (byte_offset == 0 or text.len == 0) return null;
    if (byte_offset > text.len) return null;

    // For unicode/no_zwj modes, use grapheme cluster detection
    var break_state: uucode.grapheme.BreakState = .default;
    var pos: usize = 0;
    var prev_cp: ?u21 = null;
    var prev_grapheme_start: usize = 0;
    var second_to_last_grapheme_start: usize = 0;

    while (pos < byte_offset) {
        const b = text[pos];
        const curr_cp: u21 = if (b < 0x80) b else blk: {
            const dec = decodeUtf8Unchecked(text, pos);
            if (pos + dec.len > text.len) break :blk 0xFFFD;
            break :blk dec.cp;
        };

        const cp_len: usize = if (b < 0x80) 1 else decodeUtf8Unchecked(text, pos).len;

        if (isValidCodepoint(curr_cp)) {
            const is_break = if (prev_cp) |p| blk: {
                if (!isValidCodepoint(p)) break :blk true;
                break :blk uucode.grapheme.isBreak(p, curr_cp, &break_state);
            } else true;

            if (is_break) {
                second_to_last_grapheme_start = prev_grapheme_start;
                prev_grapheme_start = pos;
            }

            prev_cp = curr_cp;
        }

        pos += cp_len;
    }

    if (prev_grapheme_start == 0 and byte_offset == 0) {
        return null;
    }

    const start_offset = if (prev_grapheme_start < byte_offset) prev_grapheme_start else second_to_last_grapheme_start;
    const width = getWidthAt(text, start_offset, tab_width, width_method);

    return .{
        .start_offset = start_offset,
        .width = width,
    };
}

/// Calculate the display width of text - proxy function that dispatches based on width_method
pub fn calculateTextWidth(text: []const u8, tab_width: u8, isASCIIOnly: bool, width_method: WidthMethod) u32 {
    switch (width_method) {
        .unicode, .no_zwj => return calculateTextWidthUnicode(text, tab_width, isASCIIOnly, width_method),
        .wcwidth => return calculateTextWidthWCWidth(text, tab_width, isASCIIOnly),
    }
}

/// Calculate text width using Unicode grapheme cluster segmentation
fn calculateTextWidthUnicode(text: []const u8, tab_width: u8, isASCIIOnly: bool, width_method: WidthMethod) u32 {
    if (text.len == 0) return 0;

    // ASCII-only fast path
    if (isASCIIOnly) {
        return @intCast(text.len);
    }

    // General case with Unicode support and grapheme cluster handling
    var total_width: u32 = 0;
    var pos: usize = 0;
    var prev_cp: ?u21 = null;
    var break_state: uucode.grapheme.BreakState = .default;
    var state: GraphemeWidthState = undefined;

    while (pos < text.len) {
        const b0 = text[pos];
        const decoded = if (b0 < 0x80)
            DecodedUtf8{ .cp = @as(u21, b0), .len = @as(usize, 1) }
        else blk: {
            const dec = decodeUtf8Unchecked(text, pos);
            break :blk DecodedUtf8{ .cp = dec.cp, .len = dec.len };
        };

        const curr_cp: u21 = decoded.cp;
        const cp_len: usize = decoded.len;
        const is_break = if (prev_cp == null)
            true
        else if (curr_cp <= 0x7F and prev_cp.? <= 0x7F and break_state == .default and isPrintableAsciiByte(b0))
            true
        else
            isGraphemeBreak(prev_cp, curr_cp, &break_state, width_method);

        const cp_width = if (curr_cp <= 0x7F)
            asciiCharWidth(b0, tab_width)
        else
            charWidth(b0, curr_cp, tab_width);

        if (is_break) {
            if (prev_cp != null) {
                total_width += state.width;
            }

            state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
        } else {
            state.addCodepoint(curr_cp, cp_width);
        }

        prev_cp = curr_cp;
        pos += cp_len;
    }

    if (prev_cp != null) {
        total_width += state.width;
    }

    return total_width;
}

/// Calculate text width using wcwidth-style codepoint-by-codepoint processing
fn calculateTextWidthWCWidth(text: []const u8, tab_width: u8, isASCIIOnly: bool) u32 {
    if (text.len == 0) return 0;

    // ASCII-only fast path
    if (isASCIIOnly) {
        return @intCast(text.len);
    }

    // Unicode path - sum width of all codepoints
    var total_width: u32 = 0;
    var pos: usize = 0;

    while (pos < text.len) {
        const b0 = text[pos];
        const decoded = if (b0 < 0x80)
            DecodedUtf8{ .cp = @as(u21, b0), .len = @as(usize, 1) }
        else blk: {
            const dec = decodeUtf8Unchecked(text, pos);
            break :blk DecodedUtf8{ .cp = dec.cp, .len = dec.len };
        };

        const curr_cp: u21 = decoded.cp;
        const cp_len: usize = decoded.len;

        const cp_width = charWidth(b0, curr_cp, tab_width);
        total_width += cp_width;

        pos += cp_len;
    }

    return total_width;
}

/// Grapheme cluster information for caching
pub const GraphemeInfo = struct {
    byte_offset: u32,
    byte_len: u8,
    width: u8,
    col_offset: u32,
};

/// Find all grapheme clusters in text and return info for multi-byte graphemes and tabs
/// This is a proxy function that dispatches to the appropriate implementation based on width_method
pub fn collectGraphemeInfo(
    text: []const u8,
    tab_width: u8,
    isASCIIOnly: bool,
    width_method: WidthMethod,
    allocator: std.mem.Allocator,
    result: *std.ArrayListUnmanaged(GraphemeInfo),
) !void {
    switch (width_method) {
        .unicode, .no_zwj => try findGraphemeInfoUnicode(text, tab_width, isASCIIOnly, width_method, allocator, result),
        .wcwidth => try findGraphemeInfoWCWidth(text, tab_width, isASCIIOnly, allocator, result),
    }
}

/// Find all grapheme clusters using Unicode grapheme cluster segmentation
/// This version treats grapheme clusters as single units for width calculation
fn findGraphemeInfoUnicode(
    text: []const u8,
    tab_width: u8,
    isASCIIOnly: bool,
    width_method: WidthMethod,
    allocator: std.mem.Allocator,
    result: *std.ArrayListUnmanaged(GraphemeInfo),
) !void {
    // In wcwidth mode, always process to capture combining marks on ASCII
    if (isASCIIOnly and width_method != .wcwidth) {
        return;
    }

    if (text.len == 0) {
        return;
    }

    const vector_len = 16;
    var pos: usize = 0;
    var col: u32 = 0;
    var prev_cp: ?u21 = null;
    var break_state: uucode.grapheme.BreakState = .default;

    // Track current grapheme cluster
    var cluster_start: usize = 0;
    var cluster_start_col: u32 = 0;
    var cluster_width_state: GraphemeWidthState = undefined;
    var cluster_is_multibyte: bool = false;
    var cluster_is_tab: bool = false;

    while (pos + vector_len <= text.len) {
        const chunk: @Vector(vector_len, u8) = text[pos..][0..vector_len].*;
        const ascii_threshold: @Vector(vector_len, u8) = @splat(0x80);
        const is_non_ascii = chunk >= ascii_threshold;

        // Fast path: all ASCII
        if (!@reduce(.Or, is_non_ascii)) {
            var i: usize = 0;
            while (i < vector_len) : (i += 1) {
                const b = text[pos + i];
                const curr_cp: u21 = b;
                const is_break = isGraphemeBreak(prev_cp, curr_cp, &break_state, width_method);

                if (is_break) {
                    if (prev_cp != null and (cluster_is_multibyte or cluster_is_tab)) {
                        if (cluster_width_state.width > 0 or width_method == .wcwidth) {
                            const cluster_byte_len = (pos + i) - cluster_start;
                            try result.append(allocator, GraphemeInfo{
                                .byte_offset = @intCast(cluster_start),
                                .byte_len = @intCast(cluster_byte_len),
                                .width = @intCast(cluster_width_state.width),
                                .col_offset = cluster_start_col,
                            });
                        }
                        col += cluster_width_state.width;
                    } else if (prev_cp != null) {
                        col += cluster_width_state.width;
                    }

                    cluster_start = pos + i;
                    cluster_start_col = col;
                    cluster_is_tab = (b == '\t');
                    cluster_is_multibyte = false;

                    const cp_width = asciiCharWidth(b, tab_width);
                    cluster_width_state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
                } else {
                    // Continuing cluster (shouldn't happen for ASCII, but handle it)
                    const cp_width = asciiCharWidth(b, tab_width);
                    cluster_width_state.addCodepoint(curr_cp, cp_width);
                }

                prev_cp = curr_cp;
            }
            pos += vector_len;
            continue;
        }

        // Slow path: mixed ASCII/non-ASCII
        var i: usize = 0;
        while (i < vector_len and pos + i < text.len) {
            const b0 = text[pos + i];
            const curr_cp: u21 = if (b0 < 0x80) b0 else decodeUtf8Unchecked(text, pos + i).cp;
            const cp_len: usize = if (b0 < 0x80) 1 else decodeUtf8Unchecked(text, pos + i).len;

            if (pos + i + cp_len > text.len) break;

            const is_break = isGraphemeBreak(prev_cp, curr_cp, &break_state, width_method);

            if (is_break) {
                if (prev_cp != null and (cluster_is_multibyte or cluster_is_tab)) {
                    if (cluster_width_state.width > 0 or width_method == .wcwidth) {
                        const cluster_byte_len = (pos + i) - cluster_start;
                        try result.append(allocator, GraphemeInfo{
                            .byte_offset = @intCast(cluster_start),
                            .byte_len = @intCast(cluster_byte_len),
                            .width = @intCast(cluster_width_state.width),
                            .col_offset = cluster_start_col,
                        });
                    }
                    col += cluster_width_state.width;
                } else if (prev_cp != null) {
                    col += cluster_width_state.width;
                }

                cluster_start = pos + i;
                cluster_start_col = col;
                cluster_is_tab = (b0 == '\t');
                cluster_is_multibyte = (cp_len != 1);

                const cp_width = charWidth(b0, curr_cp, tab_width);
                cluster_width_state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
            } else {
                cluster_is_multibyte = cluster_is_multibyte or (cp_len != 1);
                const cp_width = charWidth(b0, curr_cp, tab_width);
                cluster_width_state.addCodepoint(curr_cp, cp_width);
            }

            prev_cp = curr_cp;
            i += cp_len;
        }
        pos += i;
    }

    // Tail processing
    while (pos < text.len) {
        const b0 = text[pos];
        const curr_cp: u21 = if (b0 < 0x80) b0 else decodeUtf8Unchecked(text, pos).cp;
        const cp_len: usize = if (b0 < 0x80) 1 else decodeUtf8Unchecked(text, pos).len;

        if (pos + cp_len > text.len) break;

        const is_break = isGraphemeBreak(prev_cp, curr_cp, &break_state, width_method);

        if (is_break) {
            if (prev_cp != null and (cluster_is_multibyte or cluster_is_tab)) {
                if (cluster_width_state.width > 0 or width_method == .wcwidth) {
                    const cluster_byte_len = pos - cluster_start;
                    try result.append(allocator, GraphemeInfo{
                        .byte_offset = @intCast(cluster_start),
                        .byte_len = @intCast(cluster_byte_len),
                        .width = @intCast(cluster_width_state.width),
                        .col_offset = cluster_start_col,
                    });
                }
                col += cluster_width_state.width;
            } else if (prev_cp != null) {
                col += cluster_width_state.width;
            }

            cluster_start = pos;
            cluster_start_col = col;
            cluster_is_tab = (b0 == '\t');
            cluster_is_multibyte = (cp_len != 1);

            const cp_width = charWidth(b0, curr_cp, tab_width);
            cluster_width_state = GraphemeWidthState.init(curr_cp, cp_width, width_method);
        } else {
            cluster_is_multibyte = cluster_is_multibyte or (cp_len != 1);
            const cp_width = charWidth(b0, curr_cp, tab_width);
            cluster_width_state.addCodepoint(curr_cp, cp_width);
        }

        prev_cp = curr_cp;
        pos += cp_len;
    }

    if (prev_cp != null and (cluster_is_multibyte or cluster_is_tab)) {
        if (cluster_width_state.width > 0 or width_method == .wcwidth) {
            const cluster_byte_len = text.len - cluster_start;
            try result.append(allocator, GraphemeInfo{
                .byte_offset = @intCast(cluster_start),
                .byte_len = @intCast(cluster_byte_len),
                .width = @intCast(cluster_width_state.width),
                .col_offset = cluster_start_col,
            });
        }
    }
}

/// Find all grapheme clusters using wcwidth-style codepoint-by-codepoint processing
/// This version treats each codepoint as a separate character (tmux/wcwidth behavior)
fn findGraphemeInfoWCWidth(
    text: []const u8,
    tab_width: u8,
    isASCIIOnly: bool,
    allocator: std.mem.Allocator,
    result: *std.ArrayListUnmanaged(GraphemeInfo),
) !void {
    // wcwidth mode should still produce the same grapheme cluster boundaries as Unicode
    // (so ZWJ sequences and combining marks stay together), but the width of each cluster
    // is calculated using wcwidth (sum of codepoint widths). This keeps rendering coherent
    // while preserving tmux-style widths.
    if (isASCIIOnly) {
        return;
    }

    if (text.len == 0) {
        return;
    }

    var pos: usize = 0;
    var col: u32 = 0;
    var prev_cp: ?u21 = null;
    var break_state: uucode.grapheme.BreakState = .default;

    // Track current cluster
    var cluster_start: usize = 0;
    var cluster_start_col: u32 = 0;
    var cluster_width_state: GraphemeWidthState = undefined;
    var cluster_is_multibyte: bool = false;
    var cluster_is_tab: bool = false;
    var cluster_started = false;

    while (pos < text.len) {
        const b0 = text[pos];
        const curr_cp: u21 = if (b0 < 0x80) b0 else blk: {
            const dec = decodeUtf8Unchecked(text, pos);
            if (pos + dec.len > text.len) break :blk 0xFFFD;
            break :blk dec.cp;
        };
        const cp_len: usize = if (b0 < 0x80) 1 else decodeUtf8Unchecked(text, pos).len;

        if (pos + cp_len > text.len) break;

        // Use wcwidth break detection (each codepoint is separate, tmux-style)
        const is_break = isGraphemeBreak(prev_cp, curr_cp, &break_state, .wcwidth);

        if (is_break) {
            if (cluster_started and (cluster_is_multibyte or cluster_is_tab)) {
                try result.append(allocator, GraphemeInfo{
                    .byte_offset = @intCast(cluster_start),
                    .byte_len = @intCast(pos - cluster_start),
                    .width = @intCast(cluster_width_state.width),
                    .col_offset = cluster_start_col,
                });
                col += cluster_width_state.width;
            } else if (cluster_started) {
                // Still need to advance col by cluster width even if not emitted
                col += cluster_width_state.width;
            }

            // Start a new cluster
            cluster_start = pos;
            cluster_start_col = col;
            cluster_is_tab = (b0 == '\t');
            cluster_is_multibyte = (cp_len != 1);
            const cp_width = charWidth(b0, curr_cp, tab_width);
            cluster_width_state = GraphemeWidthState.init(curr_cp, cp_width, .wcwidth);
            cluster_started = true;
        } else {
            // Continuing cluster
            cluster_is_multibyte = cluster_is_multibyte or (cp_len != 1);
            const cp_width = charWidth(b0, curr_cp, tab_width);
            cluster_width_state.addCodepoint(curr_cp, cp_width);
        }

        prev_cp = curr_cp;
        pos += cp_len;
    }

    // Commit final cluster
    if (cluster_started) {
        if (cluster_is_multibyte or cluster_is_tab) {
            try result.append(allocator, GraphemeInfo{
                .byte_offset = @intCast(cluster_start),
                .byte_len = @intCast(text.len - cluster_start),
                .width = @intCast(cluster_width_state.width),
                .col_offset = cluster_start_col,
            });
            col += cluster_width_state.width;
        } else {
            col += cluster_width_state.width;
        }
    }
}
