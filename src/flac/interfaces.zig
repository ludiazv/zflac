//! The erased callback interfaces the application plugs into the decoder and
//! the encoder, plus ready-made implementations for working out of a fixed
//! memory buffer.
//!
//! Every interface is a context pointer plus a small table of functions, so
//! plugging one in allocates nothing.  Dispatch is one indirect call per
//! callback — per read chunk, per frame — not per sample.

const types = @import("types.zig");

/// What a `Source.read` call achieved.
pub const ReadOutcome = enum {
    /// `bytes_read` bytes were copied into the buffer.
    ok,
    /// The source is exhausted.
    end_of_stream,
    /// An I/O failure; decoding stops.
    failure,
};

pub const ReadResult = struct {
    bytes_read: usize = 0,
    outcome: ReadOutcome = .ok,
};

/// Return value of an output callback: `.stop` aborts the library.
pub const Action = enum { ok, stop };

// ------------------------------------------------------------- adapters
//
// The three interfaces below differ only in which methods are required, what
// they are called, and what they return, so the boilerplate is written once
// here instead of three times over.

/// Recovers the application object from an erased callback context.
inline fn selfOf(comptime T: type, ctx: *anyopaque) *T {
    return @ptrCast(@alignCast(ctx));
}

/// Adapts `T`'s single-argument method `name` into an erased callback.
fn unary(
    comptime T: type,
    comptime name: []const u8,
    comptime Arg: type,
    comptime Result: type,
) *const fn (context: *anyopaque, arg: Arg) Result {
    return &struct {
        fn impl(ctx: *anyopaque, arg: Arg) Result {
            // Method call syntax desugars to exactly this.
            return @field(T, name)(selfOf(T, ctx), arg);
        }
    }.impl;
}

/// Adapts `T`'s zero-argument method `name` into an erased callback.
fn nullary(
    comptime T: type,
    comptime name: []const u8,
    comptime Result: type,
) *const fn (context: *anyopaque) Result {
    return &struct {
        fn impl(ctx: *anyopaque) Result {
            return @field(T, name)(selfOf(T, ctx));
        }
    }.impl;
}

/// `seek` is the one method whose signature really does differ: the
/// application reports failure by returning nothing or an error, while the
/// callback has to answer with a bool.
fn seekAdapter(comptime T: type) *const fn (context: *anyopaque, absolute_byte_offset: u64) bool {
    return &struct {
        fn impl(ctx: *anyopaque, offset: u64) bool {
            @field(T, "seek")(selfOf(T, ctx), offset);
            return true;
        }
    }.impl;
}

/// A byte source the decoder reads a FLAC stream from.
pub const Source = struct {
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque, buffer: []u8) ReadResult,
    /// Optional: without it the stream cannot be seeked or re-read.
    seekFn: ?*const fn (context: *anyopaque, absolute_byte_offset: u64) bool = null,
    /// Optional: current byte offset.
    tellFn: ?*const fn (context: *anyopaque) ?u64 = null,
    /// Optional: total size in bytes.
    lengthFn: ?*const fn (context: *anyopaque) ?u64 = null,
    /// Optional: whether the source is exhausted.
    eofFn: ?*const fn (context: *anyopaque) bool = null,

    /// Builds a `Source` from any type exposing `read`, and optionally
    /// `seek`, `tell`, `length` and `eof`.
    pub fn from(comptime T: type, context: *T) Source {
        return .{
            .context = context,
            .readFn = unary(T, "read", []u8, ReadResult),
            .seekFn = if (@hasDecl(T, "seek")) seekAdapter(T) else null,
            .tellFn = if (@hasDecl(T, "tell")) nullary(T, "tell", ?u64) else null,
            .lengthFn = if (@hasDecl(T, "length")) nullary(T, "length", ?u64) else null,
            .eofFn = if (@hasDecl(T, "eof")) nullary(T, "eof", bool) else null,
        };
    }
};

/// Where the decoder hands the application the frames it produces.
pub const Output = struct {
    context: *anyopaque,
    frameFn: *const fn (context: *anyopaque, frame: types.Frame) Action,
    /// Optional: called once per metadata block, before any frame.
    metadataFn: ?*const fn (context: *anyopaque, metadata: types.Metadata) void = null,

    /// Builds an `Output` from any type exposing `writeFrame` and,
    /// optionally, `writeMetadata`.
    pub fn from(comptime T: type, context: *T) Output {
        return .{
            .context = context,
            .frameFn = unary(T, "writeFrame", types.Frame, Action),
            .metadataFn = if (@hasDecl(T, "writeMetadata"))
                unary(T, "writeMetadata", types.Metadata, void)
            else
                null,
        };
    }
};

/// Where the encoder writes the FLAC stream it produces.
pub const Sink = struct {
    context: *anyopaque,
    writeFn: *const fn (context: *anyopaque, bytes: []const u8) Action,
    /// Optional: without it the STREAMINFO block cannot be patched up at the
    /// end of encoding, and `StreamInfo.total_samples` stays zero.
    seekFn: ?*const fn (context: *anyopaque, absolute_byte_offset: u64) bool = null,
    /// Optional: current byte offset.
    tellFn: ?*const fn (context: *anyopaque) ?u64 = null,

    /// Builds a `Sink` from any type exposing `write` and, optionally,
    /// `seek` and `tell`.
    pub fn from(comptime T: type, context: *T) Sink {
        return .{
            .context = context,
            .writeFn = unary(T, "write", []const u8, Action),
            .seekFn = if (@hasDecl(T, "seek")) seekAdapter(T) else null,
            .tellFn = if (@hasDecl(T, "tell")) nullary(T, "tell", ?u64) else null,
        };
    }
};

/// A seekable FLAC stream held entirely in memory.
pub const MemorySource = struct {
    data: []const u8,
    offset: usize = 0,

    pub fn read(self: *MemorySource, buffer: []u8) ReadResult {
        if (self.offset >= self.data.len) return .{ .outcome = .end_of_stream };
        const n = @min(buffer.len, self.data.len - self.offset);
        @memcpy(buffer[0..n], self.data[self.offset .. self.offset + n]);
        self.offset += n;
        return .{ .bytes_read = n };
    }

    pub fn seek(self: *MemorySource, offset: u64) void {
        self.offset = @min(offset, self.data.len);
    }

    pub fn tell(self: *MemorySource) u64 {
        return self.offset;
    }

    pub fn length(self: *MemorySource) u64 {
        return self.data.len;
    }

    pub fn eof(self: *MemorySource) bool {
        return self.offset >= self.data.len;
    }

    pub fn source(self: *MemorySource) Source {
        return Source.from(MemorySource, self);
    }
};

/// A fixed-size buffer the encoder writes a FLAC stream into.
pub const MemorySink = struct {
    buffer: []u8,
    /// Write position, which the encoder moves backwards to patch STREAMINFO.
    position: usize = 0,
    /// Number of valid bytes in `buffer`.
    length: usize = 0,

    pub fn write(self: *MemorySink, chunk: []const u8) Action {
        if (self.position + chunk.len > self.buffer.len) return .stop;
        @memcpy(self.buffer[self.position..][0..chunk.len], chunk);
        self.position += chunk.len;
        self.length = @max(self.length, self.position);
        return .ok;
    }

    pub fn seek(self: *MemorySink, offset: u64) void {
        self.position = @min(offset, self.buffer.len);
    }

    pub fn tell(self: *MemorySink) u64 {
        return self.position;
    }

    /// The encoded stream written so far.
    pub fn bytes(self: *const MemorySink) []const u8 {
        return self.buffer[0..self.length];
    }

    pub fn sink(self: *MemorySink) Sink {
        return Sink.from(MemorySink, self);
    }
};
