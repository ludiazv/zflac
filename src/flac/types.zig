//! Zig-flavoured mirrors of the libFLAC data types that cross the API
//! boundary.  The C enums are re-exported as proper Zig enums with a
//! `fromC` conversion so that no `FLAC__*` name leaks into user code.

const c = @import("c.zig").c;

/// FLAC never carries more than eight channels.
pub const max_channels = 8;

pub const SubframeType = enum {
    constant,
    verbatim,
    fixed,
    lpc,

    pub fn fromC(value: c.FLAC__SubframeType) SubframeType {
        return switch (value) {
            c.FLAC__SUBFRAME_TYPE_CONSTANT => .constant,
            c.FLAC__SUBFRAME_TYPE_VERBATIM => .verbatim,
            c.FLAC__SUBFRAME_TYPE_FIXED => .fixed,
            c.FLAC__SUBFRAME_TYPE_LPC => .lpc,
            else => unreachable,
        };
    }
};

pub const ChannelAssignment = enum {
    independent,
    left_side,
    right_side,
    mid_side,

    pub fn fromC(value: c.FLAC__ChannelAssignment) ChannelAssignment {
        return switch (value) {
            c.FLAC__CHANNEL_ASSIGNMENT_INDEPENDENT => .independent,
            c.FLAC__CHANNEL_ASSIGNMENT_LEFT_SIDE => .left_side,
            c.FLAC__CHANNEL_ASSIGNMENT_RIGHT_SIDE => .right_side,
            c.FLAC__CHANNEL_ASSIGNMENT_MID_SIDE => .mid_side,
            else => unreachable,
        };
    }
};

/// How `Frame.number` should be interpreted.
pub const NumberType = enum {
    frame_number,
    sample_number,

    pub fn fromC(value: c.FLAC__FrameNumberType) NumberType {
        return switch (value) {
            c.FLAC__FRAME_NUMBER_TYPE_FRAME_NUMBER => .frame_number,
            c.FLAC__FRAME_NUMBER_TYPE_SAMPLE_NUMBER => .sample_number,
            else => unreachable,
        };
    }
};

pub const MetadataType = enum {
    streaminfo,
    padding,
    application,
    seektable,
    vorbis_comment,
    cuesheet,
    picture,
    /// Anything this binding does not know about.
    other,

    pub fn fromC(value: c.FLAC__MetadataType) MetadataType {
        return switch (value) {
            c.FLAC__METADATA_TYPE_STREAMINFO => .streaminfo,
            c.FLAC__METADATA_TYPE_PADDING => .padding,
            c.FLAC__METADATA_TYPE_APPLICATION => .application,
            c.FLAC__METADATA_TYPE_SEEKTABLE => .seektable,
            c.FLAC__METADATA_TYPE_VORBIS_COMMENT => .vorbis_comment,
            c.FLAC__METADATA_TYPE_CUESHEET => .cuesheet,
            c.FLAC__METADATA_TYPE_PICTURE => .picture,
            else => .other,
        };
    }
};

/// The state machine of `Decoder`.
pub const DecoderState = enum {
    search_for_metadata,
    read_metadata,
    search_for_frame_sync,
    read_frame,
    end_of_stream,
    ogg_error,
    seek_error,
    aborted,
    memory_allocation_error,
    uninitialized,
    end_of_link,

    pub fn fromC(value: c.FLAC__StreamDecoderState) DecoderState {
        return switch (value) {
            c.FLAC__STREAM_DECODER_SEARCH_FOR_METADATA => .search_for_metadata,
            c.FLAC__STREAM_DECODER_READ_METADATA => .read_metadata,
            c.FLAC__STREAM_DECODER_SEARCH_FOR_FRAME_SYNC => .search_for_frame_sync,
            c.FLAC__STREAM_DECODER_READ_FRAME => .read_frame,
            c.FLAC__STREAM_DECODER_END_OF_STREAM => .end_of_stream,
            c.FLAC__STREAM_DECODER_OGG_ERROR => .ogg_error,
            c.FLAC__STREAM_DECODER_SEEK_ERROR => .seek_error,
            c.FLAC__STREAM_DECODER_ABORTED => .aborted,
            c.FLAC__STREAM_DECODER_MEMORY_ALLOCATION_ERROR => .memory_allocation_error,
            c.FLAC__STREAM_DECODER_UNINITIALIZED => .uninitialized,
            c.FLAC__STREAM_DECODER_END_OF_LINK => .end_of_link,
            else => unreachable,
        };
    }
};

/// The state machine of `Encoder`.
pub const EncoderState = enum {
    ok,
    uninitialized,
    ogg_error,
    verify_decoder_error,
    verify_mismatch_in_audio_data,
    client_error,
    io_error,
    framing_error,
    memory_allocation_error,

    pub fn fromC(value: c.FLAC__StreamEncoderState) EncoderState {
        return switch (value) {
            c.FLAC__STREAM_ENCODER_OK => .ok,
            c.FLAC__STREAM_ENCODER_UNINITIALIZED => .uninitialized,
            c.FLAC__STREAM_ENCODER_OGG_ERROR => .ogg_error,
            c.FLAC__STREAM_ENCODER_VERIFY_DECODER_ERROR => .verify_decoder_error,
            c.FLAC__STREAM_ENCODER_VERIFY_MISMATCH_IN_AUDIO_DATA => .verify_mismatch_in_audio_data,
            c.FLAC__STREAM_ENCODER_CLIENT_ERROR => .client_error,
            c.FLAC__STREAM_ENCODER_IO_ERROR => .io_error,
            c.FLAC__STREAM_ENCODER_FRAMING_ERROR => .framing_error,
            c.FLAC__STREAM_ENCODER_MEMORY_ALLOCATION_ERROR => .memory_allocation_error,
            else => unreachable,
        };
    }
};

/// Recoverable problems reported while decoding.  The decoder keeps going
/// after most of them; the value is only informational.
pub const DecoderError = enum {
    lost_sync,
    bad_header,
    frame_crc_mismatch,
    unparseable_stream,
    bad_metadata,
    missing_frame,
    out_of_bounds,

    pub fn fromC(value: c.FLAC__StreamDecoderErrorStatus) DecoderError {
        return switch (value) {
            c.FLAC__STREAM_DECODER_ERROR_STATUS_LOST_SYNC => .lost_sync,
            c.FLAC__STREAM_DECODER_ERROR_STATUS_BAD_HEADER => .bad_header,
            c.FLAC__STREAM_DECODER_ERROR_STATUS_FRAME_CRC_MISMATCH => .frame_crc_mismatch,
            c.FLAC__STREAM_DECODER_ERROR_STATUS_UNPARSEABLE_STREAM => .unparseable_stream,
            c.FLAC__STREAM_DECODER_ERROR_STATUS_BAD_METADATA => .bad_metadata,
            c.FLAC__STREAM_DECODER_ERROR_STATUS_MISSING_FRAME => .missing_frame,
            c.FLAC__STREAM_DECODER_ERROR_STATUS_OUT_OF_BOUNDS => .out_of_bounds,
            else => unreachable,
        };
    }
};

/// The STREAMINFO metadata block, which every FLAC stream starts with.
pub const StreamInfo = struct {
    min_block_size: u16,
    max_block_size: u16,
    min_frame_size: u32,
    max_frame_size: u32,
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    /// 0 when the stream does not know its length up front.
    total_samples: u64,
    /// MD5 of the raw decoded PCM, all zeroes when the encoder did not
    /// compute one.
    md5: [16]u8,

    pub fn fromC(info: c.FLAC__StreamMetadata_StreamInfo) StreamInfo {
        return .{
            .min_block_size = @intCast(info.min_blocksize),
            .max_block_size = @intCast(info.max_blocksize),
            .min_frame_size = info.min_framesize,
            .max_frame_size = info.max_framesize,
            .sample_rate = info.sample_rate,
            .channels = @intCast(info.channels),
            .bits_per_sample = @intCast(info.bits_per_sample),
            .total_samples = info.total_samples,
            .md5 = info.md5sum,
        };
    }
};

/// What the decoder hands to the application for every metadata block.
pub const Metadata = union(MetadataType) {
    streaminfo: StreamInfo,
    /// Body size in bytes.
    padding: u32,
    application: void,
    seektable: void,
    vorbis_comment: void,
    cuesheet: void,
    picture: void,
    other: void,

    pub fn fromC(metadata: c.FLAC__StreamMetadata) Metadata {
        return switch (metadata.type) {
            c.FLAC__METADATA_TYPE_STREAMINFO => .{
                .streaminfo = StreamInfo.fromC(metadata.data.stream_info),
            },
            c.FLAC__METADATA_TYPE_PADDING => .{ .padding = metadata.length },
            c.FLAC__METADATA_TYPE_SEEKTABLE => .seektable,
            c.FLAC__METADATA_TYPE_APPLICATION => .application,
            c.FLAC__METADATA_TYPE_VORBIS_COMMENT => .vorbis_comment,
            c.FLAC__METADATA_TYPE_CUESHEET => .cuesheet,
            c.FLAC__METADATA_TYPE_PICTURE => .picture,
            else => .other,
        };
    }
};

/// The header of one decoded frame.
pub const FrameHeader = struct {
    /// Samples per channel in this frame.
    block_size: u16,
    sample_rate: u32,
    channels: u8,
    channel_assignment: ChannelAssignment,
    bits_per_sample: u8,
    number_type: NumberType,
    /// Frame index or index of the first sample, depending on `number_type`.
    number: u64,
    crc: u8,

    pub fn fromC(header: c.FLAC__FrameHeader) FrameHeader {
        return .{
            .block_size = @intCast(header.blocksize),
            .sample_rate = header.sample_rate,
            .channels = @intCast(header.channels),
            .channel_assignment = ChannelAssignment.fromC(header.channel_assignment),
            .bits_per_sample = @intCast(header.bits_per_sample),
            .number_type = NumberType.fromC(header.number_type),
            .number = if (header.number_type == c.FLAC__FRAME_NUMBER_TYPE_FRAME_NUMBER)
                header.number.frame_number
            else
                header.number.sample_number,
            .crc = header.crc,
        };
    }
};

/// One decoded audio frame.
///
/// The frame and the samples it points at are only valid for the duration of
/// the callback they were delivered to; copy them out if you need them
/// afterwards.
pub const Frame = struct {
    header: FrameHeader,
    /// Planar samples: `samples[channel][i]`, `header.block_size` per channel.
    samples: []const []const i32,
};
