//! zflac — a small, embedding-oriented Zig binding for the reference
//! [libFLAC](https://github.com/xiph/flac) stream encoder and decoder.
//!
//! The surface is deliberately narrow:
//!
//!   * `Decoder` — FLAC stream → interleaved or planar PCM
//!   * `Encoder` — PCM → FLAC stream
//!   * `Source`/`Sink`/`Output` — callback interfaces, so the library never
//!     opens a file or allocates a buffer for you, and the audio path needs
//!     no OS services.  (The vendored C sources still need a libc to compile;
//!     see the README.)
//!
//! Not covered on purpose: Ogg containers, the metadata object API, cue
//! sheets, pictures, replay gain, and everything else in libFLAC that a
//! small device has no business carrying.
//!
//! ```zig
//! var decoder = flac.Decoder{};
//! try decoder.init(source, output, .{});
//! defer decoder.deinit();
//! try decoder.decode();
//! ```

const std = @import("std");

const c = @import("flac/c.zig").c;
const config = @import("config");

pub const Decoder = @import("flac/decoder.zig").Decoder;
pub const Encoder = @import("flac/encoder.zig").Encoder;

pub const Error = @import("flac/errors.zig").Error;

pub const ChannelAssignment = @import("flac/types.zig").ChannelAssignment;
pub const DecoderError = @import("flac/types.zig").DecoderError;
pub const DecoderState = @import("flac/types.zig").DecoderState;
pub const EncoderState = @import("flac/types.zig").EncoderState;
pub const Frame = @import("flac/types.zig").Frame;
pub const FrameHeader = @import("flac/types.zig").FrameHeader;
pub const Metadata = @import("flac/types.zig").Metadata;
pub const MetadataType = @import("flac/types.zig").MetadataType;
pub const NumberType = @import("flac/types.zig").NumberType;
pub const StreamInfo = @import("flac/types.zig").StreamInfo;
pub const SubframeType = @import("flac/types.zig").SubframeType;

/// FLAC never carries more than this many channels.
pub const max_channels = @import("flac/types.zig").max_channels;
/// Block size limits, in samples per channel.
pub const min_block_size = c.FLAC__MIN_BLOCK_SIZE;
pub const max_block_size = c.FLAC__MAX_BLOCK_SIZE;
/// Sample depth limits, in bits.
pub const min_bits_per_sample = c.FLAC__MIN_BITS_PER_SAMPLE;
pub const max_bits_per_sample = c.FLAC__MAX_BITS_PER_SAMPLE;

pub const Action = @import("flac/interfaces.zig").Action;
pub const MemorySink = @import("flac/interfaces.zig").MemorySink;
pub const MemorySource = @import("flac/interfaces.zig").MemorySource;
pub const Output = @import("flac/interfaces.zig").Output;
pub const ReadOutcome = @import("flac/interfaces.zig").ReadOutcome;
pub const ReadResult = @import("flac/interfaces.zig").ReadResult;
pub const Sink = @import("flac/interfaces.zig").Sink;
pub const Source = @import("flac/interfaces.zig").Source;

pub const PcmCollector = @import("flac/pcm.zig").PcmCollector;
pub const readInterleaved = @import("flac/pcm.zig").readInterleaved;
pub const writeInterleaved = @import("flac/pcm.zig").writeInterleaved;

pub const getAllocator = @import("flac/alloc.zig").getAllocator;
pub const setAllocator = @import("flac/alloc.zig").setAllocator;
pub const liveBlocks = @import("flac/alloc.zig").liveBlocks;

comptime {
    // libFLAC reaches the allocator hooks by symbol name, so nothing in Zig
    // has to reference them.  Force them into the binary anyway, otherwise an
    // application that never calls `setAllocator` fails to link.
    if (config.alloc_hooks) {
        _ = @import("flac/alloc.zig").zflac_malloc;
        _ = @import("flac/alloc.zig").zflac_calloc;
        _ = @import("flac/alloc.zig").zflac_realloc;
        _ = @import("flac/alloc.zig").zflac_free;
    }
}

/// How this copy of libFLAC was configured at build time.
pub const build = Build{
    .alloc_hooks = config.alloc_hooks,
    .system_library = config.system_library,
};

pub const Build = struct {
    /// libFLAC's allocations go through `setAllocator`.
    alloc_hooks: bool,
    /// Linked against a system libFLAC instead of the vendored sources.
    system_library: bool,
};

/// Version of the underlying libFLAC, e.g. `"1.5.0"`.
pub fn flacVersion() []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(c.FLAC__VERSION_STRING)));
}
