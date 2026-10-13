//! Minimal FLAC stream decoder.

const c = @import("c.zig").c;
const errors = @import("errors.zig");
const interfaces = @import("interfaces.zig");
const types = @import("types.zig");

pub const Decoder = struct {
    handle: *c.FLAC__StreamDecoder = undefined,
    source: interfaces.Source = undefined,
    output: interfaces.Output = undefined,
    /// Parsed from the STREAMINFO block, available once metadata has been
    /// read (see `decodeMetadata`).
    stream_info: ?types.StreamInfo = null,
    /// Last recoverable problem reported by libFLAC.
    last_error: ?types.DecoderError = null,

    pub const Options = struct {
        /// Compare the MD5 signature stored in STREAMINFO against the
        /// decoded audio.  Costs one extra pass worth of bookkeeping, no
        /// extra memory.
        md5_checking: bool = true,
    };

    /// Prepares `self` for decoding.
    ///
    /// The decoder keeps a pointer to `self` for its callbacks, so `self`
    /// must not be copied or moved after this call, and must stay alive
    /// until `deinit`.
    pub fn init(
        self: *Decoder,
        source: interfaces.Source,
        output: interfaces.Output,
        options: Options,
    ) !void {
        const handle = c.FLAC__stream_decoder_new() orelse return error.OutOfMemory;
        errdefer c.FLAC__stream_decoder_delete(handle);

        self.* = .{ .handle = handle, .source = source, .output = output };

        if (options.md5_checking) {
            if (c.FLAC__stream_decoder_set_md5_checking(handle, 1) == 0)
                return error.Unrecoverable;
        }
        // libFLAC otherwise hands over every metadata block it finds.  When
        // nobody listens, keep only STREAMINFO so that `stream_info` is still
        // filled in, and drop the rest.
        if (output.metadataFn == null) {
            if (c.FLAC__stream_decoder_set_metadata_ignore_all(handle) == 0)
                return error.Unrecoverable;
            if (c.FLAC__stream_decoder_set_metadata_respond(handle, c.FLAC__METADATA_TYPE_STREAMINFO) == 0)
                return error.Unrecoverable;
        }

        try errors.decoderInit(c.FLAC__stream_decoder_init_stream(
            handle,
            readCallback,
            if (source.seekFn != null) seekCallback else null,
            if (source.tellFn != null) tellCallback else null,
            if (source.lengthFn != null) lengthCallback else null,
            if (source.eofFn != null) eofCallback else null,
            writeCallback,
            metadataCallback,
            errorCallback,
            self,
        ));
    }

    /// Releases everything libFLAC allocated.  Safe to call on an `init`
    /// that failed only if you obtained the handle yourself.
    pub fn deinit(self: *Decoder) void {
        _ = c.FLAC__stream_decoder_finish(self.handle);
        c.FLAC__stream_decoder_delete(self.handle);
        self.* = undefined;
    }

    /// Closes the current stream.  Returns `false` when MD5 checking is on
    /// and the signature did not match.  `deinit` calls this for you.
    pub fn finish(self: *Decoder) bool {
        return c.FLAC__stream_decoder_finish(self.handle) != 0;
    }

    /// Decodes frames until the stream is exhausted.
    pub fn decode(self: *Decoder) errors.Error!void {
        return self.process("FLAC__stream_decoder_process_until_end_of_stream");
    }

    /// Decodes exactly one frame.
    ///
    /// At end of stream this succeeds without calling `Output.frameFn`: once
    /// libFLAC is in the `end_of_stream` or `aborted` state,
    /// `process_single` returns immediately. Count frames in your callback,
    /// or check `state()`, if you need to tell "decoded one" from "nothing
    /// left".
    pub fn decodeFrame(self: *Decoder) errors.Error!void {
        return self.process("FLAC__stream_decoder_process_single");
    }

    /// Reads metadata blocks (including STREAMINFO) but no audio.
    pub fn decodeMetadata(self: *Decoder) errors.Error!void {
        return self.process("FLAC__stream_decoder_process_until_end_of_metadata");
    }

    /// Skips the next frame without decoding it.
    pub fn skipFrame(self: *Decoder) errors.Error!void {
        return self.process("FLAC__stream_decoder_skip_single_frame");
    }

    /// Jumps to the frame containing `sample`.  Needs a seekable `Source`;
    /// `error.SeekError` is returned when the source cannot seek or the seek
    /// itself failed.
    pub fn seek(self: *Decoder, sample: u64) errors.Error!void {
        if (self.source.seekFn == null) return error.SeekError;
        self.last_error = null;
        if (c.FLAC__stream_decoder_seek_absolute(self.handle, sample) != 0) return;
        if (self.last_error) |status| return errors.decoderFailure(status, self.state());
        return error.SeekError;
    }

    /// Discards the decoder's internal state so the stream can be read from
    /// the beginning again.  The `Source` is not rewound; do that yourself.
    pub fn reset(self: *Decoder) errors.Error!void {
        if (c.FLAC__stream_decoder_reset(self.handle) != 0) return;
        return throw(self);
    }

    /// Drops whatever the decoder has buffered; useful after a `Source`
    /// seek that the decoder does not know about.
    pub fn flush(self: *Decoder) void {
        _ = c.FLAC__stream_decoder_flush(self.handle);
    }

    pub fn state(self: *Decoder) types.DecoderState {
        return types.DecoderState.fromC(c.FLAC__stream_decoder_get_state(self.handle));
    }

    pub fn channels(self: *Decoder) u8 {
        return @intCast(c.FLAC__stream_decoder_get_channels(self.handle));
    }

    pub fn bitsPerSample(self: *Decoder) u8 {
        return @intCast(c.FLAC__stream_decoder_get_bits_per_sample(self.handle));
    }

    pub fn sampleRate(self: *Decoder) u32 {
        return c.FLAC__stream_decoder_get_sample_rate(self.handle);
    }

    /// Block size of the most recently decoded frame.
    pub fn blockSize(self: *Decoder) u16 {
        return @intCast(c.FLAC__stream_decoder_get_blocksize(self.handle));
    }

    pub fn channelAssignment(self: *Decoder) types.ChannelAssignment {
        return types.ChannelAssignment.fromC(c.FLAC__stream_decoder_get_channel_assignment(self.handle));
    }

    /// Total sample count from STREAMINFO, 0 when unknown.
    pub fn totalSamples(self: *Decoder) u64 {
        return c.FLAC__stream_decoder_get_total_samples(self.handle);
    }

    pub fn md5Checking(self: *Decoder) bool {
        return c.FLAC__stream_decoder_get_md5_checking(self.handle) != 0;
    }

    fn process(self: *Decoder, comptime step: []const u8) errors.Error!void {
        self.last_error = null;
        if (@field(c, step)(self.handle) != 0) return;
        return throw(self);
    }

    fn throw(self: *Decoder) errors.Error {
        return errors.decoderFailure(self.last_error, self.state());
    }

    // ------------------------------------------------------------------ C callbacks

    fn readCallback(
        _: [*c]const c.FLAC__StreamDecoder,
        buffer: [*c]c.FLAC__byte,
        bytes: [*c]usize,
        client_data: ?*anyopaque,
    ) callconv(.c) c.FLAC__StreamDecoderReadStatus {
        const self: *Decoder = @ptrCast(@alignCast(client_data));
        const result = self.source.readFn(self.source.context, buffer[0..bytes.*]);
        bytes.* = result.bytes_read;
        return switch (result.outcome) {
            .ok => c.FLAC__STREAM_DECODER_READ_STATUS_CONTINUE,
            .end_of_stream => c.FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM,
            .failure => c.FLAC__STREAM_DECODER_READ_STATUS_ABORT,
        };
    }

    fn seekCallback(
        _: [*c]const c.FLAC__StreamDecoder,
        absolute_byte_offset: c.FLAC__uint64,
        client_data: ?*anyopaque,
    ) callconv(.c) c.FLAC__StreamDecoderSeekStatus {
        const self: *Decoder = @ptrCast(@alignCast(client_data));
        const seek_to = self.source.seekFn.?;
        return if (seek_to(self.source.context, absolute_byte_offset))
            c.FLAC__STREAM_DECODER_SEEK_STATUS_OK
        else
            c.FLAC__STREAM_DECODER_SEEK_STATUS_ERROR;
    }

    fn tellCallback(
        _: [*c]const c.FLAC__StreamDecoder,
        absolute_byte_offset: [*c]c.FLAC__uint64,
        client_data: ?*anyopaque,
    ) callconv(.c) c.FLAC__StreamDecoderTellStatus {
        const self: *Decoder = @ptrCast(@alignCast(client_data));
        const tell = self.source.tellFn.?;
        const offset = tell(self.source.context) orelse
            return c.FLAC__STREAM_DECODER_TELL_STATUS_ERROR;
        absolute_byte_offset.* = offset;
        return c.FLAC__STREAM_DECODER_TELL_STATUS_OK;
    }

    fn lengthCallback(
        _: [*c]const c.FLAC__StreamDecoder,
        stream_length: [*c]c.FLAC__uint64,
        client_data: ?*anyopaque,
    ) callconv(.c) c.FLAC__StreamDecoderLengthStatus {
        const self: *Decoder = @ptrCast(@alignCast(client_data));
        const length = self.source.lengthFn.?;
        const size = length(self.source.context) orelse
            return c.FLAC__STREAM_DECODER_LENGTH_STATUS_ERROR;
        stream_length.* = size;
        return c.FLAC__STREAM_DECODER_LENGTH_STATUS_OK;
    }

    fn eofCallback(
        _: [*c]const c.FLAC__StreamDecoder,
        client_data: ?*anyopaque,
    ) callconv(.c) c.FLAC__bool {
        const self: *Decoder = @ptrCast(@alignCast(client_data));
        return @intFromBool(self.source.eofFn.?(self.source.context));
    }

    fn writeCallback(
        _: [*c]const c.FLAC__StreamDecoder,
        frame: [*c]const c.FLAC__Frame,
        buffer: [*c]const [*c]const c.FLAC__int32,
        client_data: ?*anyopaque,
    ) callconv(.c) c.FLAC__StreamDecoderWriteStatus {
        const self: *Decoder = @ptrCast(@alignCast(client_data));

        const header = frame[0].header;
        const subframes: usize = @intCast(header.channels);
        const block_size: usize = @intCast(header.blocksize);

        var planes: [types.max_channels][]const i32 = undefined;
        for (planes[0..subframes], 0..) |*plane, i| {
            plane.* = buffer[i][0..block_size];
        }

        const action = self.output.frameFn(self.output.context, .{
            .header = types.FrameHeader.fromC(frame[0].header),
            .samples = planes[0..subframes],
        });

        return switch (action) {
            .ok => c.FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE,
            .stop => c.FLAC__STREAM_DECODER_WRITE_STATUS_ABORT,
        };
    }

    fn metadataCallback(
        _: [*c]const c.FLAC__StreamDecoder,
        metadata: [*c]const c.FLAC__StreamMetadata,
        client_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Decoder = @ptrCast(@alignCast(client_data));
        const parsed = types.Metadata.fromC(metadata[0]);
        if (parsed == .streaminfo) self.stream_info = parsed.streaminfo;
        if (self.output.metadataFn) |f| f(self.output.context, parsed);
    }

    fn errorCallback(
        _: [*c]const c.FLAC__StreamDecoder,
        status: c.FLAC__StreamDecoderErrorStatus,
        client_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Decoder = @ptrCast(@alignCast(client_data));
        self.last_error = types.DecoderError.fromC(status);
    }
};
