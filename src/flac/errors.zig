//! The single error set used by this package, plus the mappings from
//! libFLAC's status enums.

const c = @import("c.zig").c;
const types = @import("types.zig");

pub const Error = error{
    // --- container / setup -------------------------------------------------
    UnsupportedContainer,
    InvalidCallbacks,
    AlreadyInitialized,

    // --- stream properties -------------------------------------------------
    InvalidChannels,
    /// The number of samples handed to `Encoder.encode`/`encodePlanar` does
    /// not match the encoder's channel count.
    InvalidSampleCount,
    InvalidBitsPerSample,
    InvalidSampleRate,
    InvalidBlockSize,
    InvalidCompressionLevel,
    InvalidMaxLpcOrder,
    InvalidQlpCoeffPrecision,
    InvalidPartitionOrder,
    InvalidMetadata,
    BlockSizeTooSmallForLpcOrder,
    NotStreamable,

    // --- decoding ----------------------------------------------------------
    LostSync,
    BadHeader,
    BadMetadata,
    FrameCrcMismatch,
    UnparseableStream,
    MissingFrame,
    OutOfBounds,
    SeekError,
    TellError,
    LengthError,
    ReadError,

    // --- encoding ----------------------------------------------------------
    FramingError,
    IoError,
    /// libFLAC rejected the input, or a `Sink` callback returned `.stop`.
    /// The usual cause is a sample outside the range of `bits_per_sample`.
    ClientError,
    VerifyDecoderError,
    VerifyMismatch,

    // --- common ------------------------------------------------------------
    /// The application's callback asked the library to stop.
    Aborted,
    /// libFLAC could not allocate its internal buffers.
    OutOfMemory,
    /// No more specific reason is available.
    Unrecoverable,
};

pub fn decoderInit(status: c.FLAC__StreamDecoderInitStatus) Error!void {
    return switch (status) {
        c.FLAC__STREAM_DECODER_INIT_STATUS_OK => {},
        c.FLAC__STREAM_DECODER_INIT_STATUS_UNSUPPORTED_CONTAINER => error.UnsupportedContainer,
        c.FLAC__STREAM_DECODER_INIT_STATUS_INVALID_CALLBACKS => error.InvalidCallbacks,
        c.FLAC__STREAM_DECODER_INIT_STATUS_MEMORY_ALLOCATION_ERROR => error.OutOfMemory,
        c.FLAC__STREAM_DECODER_INIT_STATUS_ERROR_OPENING_FILE => error.IoError,
        c.FLAC__STREAM_DECODER_INIT_STATUS_ALREADY_INITIALIZED => error.AlreadyInitialized,
        else => error.Unrecoverable,
    };
}

/// Maps a fatal decoder failure.  `status` is whatever the error callback
/// last reported, which may be `null` when the failure was not stream
/// related.
pub fn decoderFailure(status: ?types.DecoderError, state: types.DecoderState) Error {
    if (status) |s| return switch (s) {
        .lost_sync => error.LostSync,
        .bad_header => error.BadHeader,
        .frame_crc_mismatch => error.FrameCrcMismatch,
        .unparseable_stream => error.UnparseableStream,
        .bad_metadata => error.BadMetadata,
        .missing_frame => error.MissingFrame,
        .out_of_bounds => error.OutOfBounds,
    };
    return switch (state) {
        .seek_error => error.SeekError,
        .memory_allocation_error => error.OutOfMemory,
        .aborted => error.Aborted,
        .ogg_error => error.UnsupportedContainer,
        else => error.Unrecoverable,
    };
}

pub fn encoderInit(status: c.FLAC__StreamEncoderInitStatus) Error!void {
    return switch (status) {
        c.FLAC__STREAM_ENCODER_INIT_STATUS_OK => {},
        c.FLAC__STREAM_ENCODER_INIT_STATUS_UNSUPPORTED_CONTAINER => error.UnsupportedContainer,
        c.FLAC__STREAM_ENCODER_INIT_STATUS_INVALID_CALLBACKS => error.InvalidCallbacks,
        c.FLAC__STREAM_ENCODER_INIT_STATUS_ALREADY_INITIALIZED => error.AlreadyInitialized,
        c.FLAC__STREAM_ENCODER_INIT_STATUS_INVALID_NUMBER_OF_CHANNELS => error.InvalidChannels,
        c.FLAC__STREAM_ENCODER_INIT_STATUS_INVALID_BITS_PER_SAMPLE => error.InvalidBitsPerSample,
        c.FLAC__STREAM_ENCODER_INIT_STATUS_INVALID_SAMPLE_RATE => error.InvalidSampleRate,
        c.FLAC__STREAM_ENCODER_INIT_STATUS_INVALID_BLOCK_SIZE => error.InvalidBlockSize,
        c.FLAC__STREAM_ENCODER_INIT_STATUS_INVALID_MAX_LPC_ORDER => error.InvalidMaxLpcOrder,
        c.FLAC__STREAM_ENCODER_INIT_STATUS_INVALID_QLP_COEFF_PRECISION => error.InvalidQlpCoeffPrecision,
        c.FLAC__STREAM_ENCODER_INIT_STATUS_INVALID_METADATA => error.InvalidMetadata,
        c.FLAC__STREAM_ENCODER_INIT_STATUS_BLOCK_SIZE_TOO_SMALL_FOR_LPC_ORDER => error.BlockSizeTooSmallForLpcOrder,
        c.FLAC__STREAM_ENCODER_INIT_STATUS_NOT_STREAMABLE => error.NotStreamable,
        else => error.Unrecoverable,
    };
}

/// Maps the terminal state left behind by a failed encoder call.
pub fn encoderFailure(state: types.EncoderState) Error {
    return switch (state) {
        .ogg_error => error.UnsupportedContainer,
        .verify_decoder_error => error.VerifyDecoderError,
        .verify_mismatch_in_audio_data => error.VerifyMismatch,
        .client_error => error.ClientError,
        .io_error => error.IoError,
        .framing_error => error.FramingError,
        .memory_allocation_error => error.OutOfMemory,
        else => error.Unrecoverable,
    };
}
