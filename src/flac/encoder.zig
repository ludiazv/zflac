//! Minimal FLAC stream encoder.

const std = @import("std");

const c = @import("c.zig").c;
const errors = @import("errors.zig");
const interfaces = @import("interfaces.zig");
const types = @import("types.zig");

pub const Encoder = struct {
    handle: *c.FLAC__StreamEncoder = undefined,
    sink: interfaces.Sink = undefined,
    channels: u8 = undefined,
    /// Kept here because libFLAC writes into the blocks it is handed and the
    /// pointers must stay valid until `finish`.
    padding_block: c.FLAC__StreamMetadata = undefined,
    padding_blocks: [1]?*c.FLAC__StreamMetadata = undefined,

    pub const Options = struct {
        channels: u8,
        /// 4..32 bits.  Input samples must lie in `-2^(n-1)..2^(n-1)-1`;
        /// libFLAC rejects anything wider with `error.ClientError`.
        bits_per_sample: u8,
        sample_rate: u32,

        /// 16..65535 sample frames per block.  `null` or `0` lets libFLAC
        /// choose: 1152 when `max_lpc_order` is 0, otherwise 4096.  Anything
        /// else outside 16..65535 is rejected with `error.InvalidBlockSize`.
        /// This is the main lever on the encoder's heap use.
        block_size: ?u16 = null,
        /// 0 (fastest) .. 8 (smallest).
        compression_level: ?u4 = null,
        /// 0 disables LPC; up to 32 outside the FLAC subset.
        max_lpc_order: ?u8 = null,
        qlp_coeff_precision: ?u8 = null,
        min_residual_partition_order: ?u8 = null,
        max_residual_partition_order: ?u8 = null,

        mid_side_stereo: ?bool = null,
        loose_mid_side_stereo: ?bool = null,
        exhaustive_model_search: ?bool = null,
        escape_coding: ?bool = null,
        qlp_coeff_precision_search: ?bool = null,

        /// Restrict the output to the fixed FLAC subset.  Leave this on
        /// unless you know why you would turn it off.
        streamable_subset: bool = true,
        /// Decode the output again and compare it with the input.  Catches
        /// encoder bugs at the cost of a second decoder instance.
        verify: bool = false,
        /// Written into STREAMINFO when the total length is known up front.
        total_samples_estimate: ?u64 = null,
        /// Append a PADDING block of this many bytes, so that metadata can
        /// be inserted later without re-encoding.
        padding: ?u32 = null,
    };

    /// Prepares `self` for encoding.
    ///
    /// The encoder keeps a pointer to `self` for its callbacks, so `self`
    /// must not be copied or moved after this call, and must stay alive
    /// until `deinit`.
    pub fn init(self: *Encoder, sink: interfaces.Sink, options: Options) !void {
        const handle = c.FLAC__stream_encoder_new() orelse return error.OutOfMemory;
        errdefer c.FLAC__stream_encoder_delete(handle);

        self.* = .{
            .handle = handle,
            .sink = sink,
            .channels = options.channels,
        };

        try setU32(handle, "FLAC__stream_encoder_set_channels", error.InvalidChannels, options.channels);
        try setU32(handle, "FLAC__stream_encoder_set_bits_per_sample", error.InvalidBitsPerSample, options.bits_per_sample);
        try setU32(handle, "FLAC__stream_encoder_set_sample_rate", error.InvalidSampleRate, options.sample_rate);

        if (options.block_size) |v| try setU32(handle, "FLAC__stream_encoder_set_blocksize", error.InvalidBlockSize, v);
        if (options.compression_level) |v| try setU32(handle, "FLAC__stream_encoder_set_compression_level", error.InvalidCompressionLevel, v);
        if (options.max_lpc_order) |v| try setU32(handle, "FLAC__stream_encoder_set_max_lpc_order", error.InvalidMaxLpcOrder, v);
        if (options.qlp_coeff_precision) |v| try setU32(handle, "FLAC__stream_encoder_set_qlp_coeff_precision", error.InvalidQlpCoeffPrecision, v);
        if (options.min_residual_partition_order) |v| try setU32(handle, "FLAC__stream_encoder_set_min_residual_partition_order", error.InvalidPartitionOrder, v);
        if (options.max_residual_partition_order) |v| try setU32(handle, "FLAC__stream_encoder_set_max_residual_partition_order", error.InvalidPartitionOrder, v);

        try setBool(handle, "FLAC__stream_encoder_set_streamable_subset", options.streamable_subset);
        try setBool(handle, "FLAC__stream_encoder_set_verify", options.verify);
        if (options.mid_side_stereo) |v| try setBool(handle, "FLAC__stream_encoder_set_do_mid_side_stereo", v);
        if (options.loose_mid_side_stereo) |v| try setBool(handle, "FLAC__stream_encoder_set_loose_mid_side_stereo", v);
        if (options.exhaustive_model_search) |v| try setBool(handle, "FLAC__stream_encoder_set_do_exhaustive_model_search", v);
        if (options.escape_coding) |v| try setBool(handle, "FLAC__stream_encoder_set_do_escape_coding", v);
        if (options.qlp_coeff_precision_search) |v| try setBool(handle, "FLAC__stream_encoder_set_do_qlp_coeff_prec_search", v);

        if (options.total_samples_estimate) |v| {
            if (c.FLAC__stream_encoder_set_total_samples_estimate(handle, v) == 0)
                return error.Unrecoverable;
        }

        if (options.padding) |bytes| {
            self.padding_block = std.mem.zeroes(c.FLAC__StreamMetadata);
            self.padding_block.type = c.FLAC__METADATA_TYPE_PADDING;
            self.padding_block.length = bytes;
            self.padding_blocks[0] = &self.padding_block;
            if (c.FLAC__stream_encoder_set_metadata(handle, &self.padding_blocks, 1) == 0)
                return error.InvalidMetadata;
        }

        const status = c.FLAC__stream_encoder_init_stream(
            handle,
            writeCallback,
            if (sink.seekFn != null) seekCallback else null,
            if (sink.tellFn != null) tellCallback else null,
            null,
            self,
        );
        errors.encoderInit(status) catch |err| {
            // ENCODER_ERROR only says that writing the metadata failed; the
            // encoder state carries the real reason.
            if (status == c.FLAC__STREAM_ENCODER_INIT_STATUS_ENCODER_ERROR)
                return errors.encoderFailure(self.state());
            return err;
        };
    }

    /// Flushes the last frame and releases everything libFLAC allocated.
    pub fn deinit(self: *Encoder) void {
        _ = c.FLAC__stream_encoder_finish(self.handle);
        c.FLAC__stream_encoder_delete(self.handle);
        self.* = undefined;
    }

    /// Writes the trailing frame and patches STREAMINFO.  Call this before
    /// looking at the encoded bytes; `deinit` calls it too.
    pub fn finish(self: *Encoder) errors.Error!void {
        if (c.FLAC__stream_encoder_finish(self.handle) != 0) return;
        return throw(self);
    }

    /// Encodes `interleaved` samples, channel samples packed as
    /// `l r l r ...`.
    ///
    /// Every sample must already fit in `bits_per_sample` — for 16 bit that
    /// means `-32768..32767`.  libFLAC rejects the whole call with
    /// `error.ClientError` if one is out of range; it does not clamp.
    ///
    /// `error.InvalidSampleCount` means `interleaved.len` is not a whole number
    /// of sample frames for this encoder's channel count.
    pub fn encode(self: *Encoder, interleaved: []const i32) errors.Error!void {
        if (interleaved.len == 0) return;
        if (interleaved.len % self.channels != 0) return error.InvalidSampleCount;
        const samples: u32 = @intCast(interleaved.len / self.channels);
        if (c.FLAC__stream_encoder_process_interleaved(self.handle, interleaved.ptr, samples) != 0) return;
        return throw(self);
    }

    /// Encodes planar samples, one slice per channel.  Same range rule as
    /// `encode`.
    ///
    /// `error.InvalidChannels` means `planes` does not have exactly one slice
    /// per channel; `error.InvalidSampleCount` means the slices differ in
    /// length.
    pub fn encodePlanar(self: *Encoder, planes: []const []const i32) errors.Error!void {
        if (planes.len != self.channels) return error.InvalidChannels;
        if (planes.len == 0 or planes[0].len == 0) return;
        for (planes) |plane| {
            if (plane.len != planes[0].len) return error.InvalidSampleCount;
        }

        var pointers: [types.max_channels][*c]const c.FLAC__int32 = undefined;
        for (pointers[0..planes.len], planes) |*slot, plane| slot.* = plane.ptr;

        const samples: u32 = @intCast(planes[0].len);
        const status = c.FLAC__stream_encoder_process(self.handle, @ptrCast(&pointers), samples);
        if (status != 0) return;
        return throw(self);
    }

    /// Updates the sample count written into STREAMINFO.  Useful when the
    /// total length is only known once encoding is under way.
    pub fn setTotalSamplesEstimate(self: *Encoder, samples: u64) void {
        _ = c.FLAC__stream_encoder_set_total_samples_estimate(self.handle, samples);
    }

    pub fn state(self: *Encoder) types.EncoderState {
        return types.EncoderState.fromC(c.FLAC__stream_encoder_get_state(self.handle));
    }

    fn throw(self: *Encoder) errors.Error {
        return errors.encoderFailure(self.state());
    }

    fn setU32(
        handle: *c.FLAC__StreamEncoder,
        comptime name: []const u8,
        comptime failure: errors.Error,
        value: anytype,
    ) !void {
        if (@field(c, name)(handle, value) == 0) return failure;
    }

    fn setBool(
        handle: *c.FLAC__StreamEncoder,
        comptime name: []const u8,
        value: bool,
    ) !void {
        if (@field(c, name)(handle, @intFromBool(value)) == 0) return error.Unrecoverable;
    }

    // ------------------------------------------------------------------ C callbacks

    fn writeCallback(
        _: [*c]const c.FLAC__StreamEncoder,
        buffer: [*c]const c.FLAC__byte,
        bytes: usize,
        _: u32,
        _: u32,
        client_data: ?*anyopaque,
    ) callconv(.c) c.FLAC__StreamEncoderWriteStatus {
        const self: *Encoder = @ptrCast(@alignCast(client_data));
        const action = self.sink.writeFn(self.sink.context, buffer[0..bytes]);
        return switch (action) {
            .ok => c.FLAC__STREAM_ENCODER_WRITE_STATUS_OK,
            .stop => c.FLAC__STREAM_ENCODER_WRITE_STATUS_FATAL_ERROR,
        };
    }

    fn seekCallback(
        _: [*c]const c.FLAC__StreamEncoder,
        absolute_byte_offset: c.FLAC__uint64,
        client_data: ?*anyopaque,
    ) callconv(.c) c.FLAC__StreamEncoderSeekStatus {
        const self: *Encoder = @ptrCast(@alignCast(client_data));
        const seek_to = self.sink.seekFn.?;
        return if (seek_to(self.sink.context, absolute_byte_offset))
            c.FLAC__STREAM_ENCODER_SEEK_STATUS_OK
        else
            c.FLAC__STREAM_ENCODER_SEEK_STATUS_ERROR;
    }

    fn tellCallback(
        _: [*c]const c.FLAC__StreamEncoder,
        absolute_byte_offset: [*c]c.FLAC__uint64,
        client_data: ?*anyopaque,
    ) callconv(.c) c.FLAC__StreamEncoderTellStatus {
        const self: *Encoder = @ptrCast(@alignCast(client_data));
        const tell = self.sink.tellFn.?;
        const offset = tell(self.sink.context) orelse
            return c.FLAC__STREAM_ENCODER_TELL_STATUS_ERROR;
        absolute_byte_offset.* = offset;
        return c.FLAC__STREAM_ENCODER_TELL_STATUS_OK;
    }
};
