const tb = @import("text-buffer.zig");

/// StaticTextBuffer is an alias for UnifiedTextBuffer until
/// we have a dedicated implementation.
pub const StaticTextBuffer = tb.UnifiedTextBuffer;
