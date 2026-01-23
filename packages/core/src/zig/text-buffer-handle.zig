pub const TextBufferKind = enum(u8) {
    unified,
    static,
};

pub const TextBufferHeader = extern struct {
    kind: TextBufferKind,
};

pub const TextBufferViewKind = enum(u8) {
    unified,
    static,
};

pub const TextBufferViewHeader = extern struct {
    kind: TextBufferViewKind,
};
