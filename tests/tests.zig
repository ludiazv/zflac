//! Round-trip tests: encode synthetic PCM, decode it again, compare.

const std = @import("std");
const flac = @import("zflac");

/// A deterministic, compressible signal so the tests do not depend on libm.
fn fill(pcm: []i32, seed: u32) void {
    for (pcm, 0..) |*sample, i| {
        const t: i32 = @intCast((i + seed) & 0xffff);
        sample.* = ((t *% 7919) & 0x3ff) -% 512;
    }
}

test "flac package tests" {
    _ = @import("zflac");
}

/// Incompressible noise, for tests that need the frames to be big.
fn fillNoise(pcm: []i32, seed: u32) void {
    var state: u32 = if (seed == 0) 0x9e3779b9 else seed;
    for (pcm) |*sample| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        sample.* = @as(i16, @truncate(@as(i32, @bitCast(state))));
    }
}

test "mono 16-bit round trip" {
    var pcm: [1024]i32 = undefined;
    fill(&pcm, 0);

    var encoded: [8192]u8 = undefined;
    const written = try encode(&encoded, .{
        .channels = 1,
        .bits_per_sample = 16,
        .sample_rate = 44100,
    }, &pcm);
    try checkHeader(&encoded, written);

    var decoded: [1024]i32 = undefined;
    const got = try decode(encoded[0..written], &decoded);
    try std.testing.expectEqualSlices(i32, &pcm, decoded[0..got]);
}

test "stereo 24-bit round trip with mid/side" {
    var pcm: [2048]i32 = undefined; // 1024 sample frames, 2 channels
    fill(&pcm, 0);

    var encoded: [16384]u8 = undefined;
    const written = try encode(&encoded, .{
        .channels = 2,
        .bits_per_sample = 24,
        .sample_rate = 48000,
        .mid_side_stereo = true,
        .compression_level = 8,
    }, &pcm);
    try checkHeader(&encoded, written);

    var decoded: [2048]i32 = undefined;
    const got = try decode(encoded[0..written], &decoded);
    try std.testing.expectEqualSlices(i32, &pcm, decoded[0..got]);
}

test "STREAMINFO is reported" {
    var pcm: [512]i32 = undefined;
    fill(&pcm, 0);

    var encoded: [8192]u8 = undefined;
    const written = try encode(&encoded, .{
        .channels = 1,
        .bits_per_sample = 16,
        .sample_rate = 44100,
        .block_size = 128,
        .padding = 512,
    }, &pcm);

    var source = flac.MemorySource{ .data = encoded[0..written] };
    var collector = flac.PcmCollector(i32){ .samples = &pcm };
    var info: ?flac.StreamInfo = null;
    var observer = Observer(@TypeOf(collector)){ .info = &info, .inner = &collector };

    var decoder = flac.Decoder{};
    try decoder.init(source.source(), observer.output(), .{});
    defer decoder.deinit();

    try decoder.decodeMetadata();
    const stream_info = info.?;
    try std.testing.expectEqual(@as(u32, 44100), stream_info.sample_rate);
    try std.testing.expectEqual(@as(u8, 1), stream_info.channels);
    try std.testing.expectEqual(@as(u8, 16), stream_info.bits_per_sample);
    try std.testing.expectEqual(@as(u16, 128), stream_info.max_block_size);
    // MemorySink is seekable, so the encoder can patch the sample count.
    try std.testing.expectEqual(@as(u64, 512), stream_info.total_samples);

    try decoder.decode();
    try std.testing.expectEqual(@as(usize, 512), collector.length);
}

test "seeking" {
    var pcm: [4096]i32 = undefined;
    fill(&pcm, 0);

    var encoded: [16384]u8 = undefined;
    const written = try encode(&encoded, .{
        .channels = 1,
        .bits_per_sample = 16,
        .sample_rate = 44100,
        .block_size = 256,
    }, &pcm);

    var source = flac.MemorySource{ .data = encoded[0..written] };
    var collector = flac.PcmCollector(i32){ .samples = &pcm };

    var decoder = flac.Decoder{};
    try decoder.init(source.source(), collector.output(), .{});
    defer decoder.deinit();

    try decoder.seek(2048);
    try decoder.decode();

    // Decoding restarts at the frame boundary at or before sample 2048.
    const expected = pcm[2048 .. 2048 + collector.length];
    try std.testing.expectEqualSlices(i32, expected, collector.pcm());
}

test "MD5 checking rejects a corrupted stream" {
    var pcm: [1024]i32 = undefined;
    fill(&pcm, 0);

    var encoded: [8192]u8 = undefined;
    const written = try encode(&encoded, .{
        .channels = 1,
        .bits_per_sample = 16,
        .sample_rate = 44100,
    }, &pcm);

    // Flip a bit in the last frame's payload.
    encoded[written - 4] ^= 0x01;

    var source = flac.MemorySource{ .data = encoded[0..written] };
    var collector = flac.PcmCollector(i32){ .samples = &pcm };

    var decoder = flac.Decoder{};
    try decoder.init(source.source(), collector.output(), .{ .md5_checking = true });
    _ = decoder.decode() catch {};
    const ok = decoder.finish();
    decoder.deinit();

    try std.testing.expect(!ok);
}

test "a source without seek support still decodes" {
    var pcm: [1024]i32 = undefined;
    fill(&pcm, 0);

    var encoded: [8192]u8 = undefined;
    const written = try encode(&encoded, .{
        .channels = 1,
        .bits_per_sample = 16,
        .sample_rate = 44100,
    }, &pcm);

    var stream = Stream{ .data = encoded[0..written] };
    var collector = flac.PcmCollector(i32){ .samples = &pcm };

    var decoder = flac.Decoder{};
    try decoder.init(flac.Source.from(Stream, &stream), collector.output(), .{});
    defer decoder.deinit();

    try decoder.decode();
    try std.testing.expectEqual(@as(usize, 1024), collector.length);
    try std.testing.expectError(error.SeekError, decoder.seek(10));
}

test "garbage in, error out" {
    const garbage = "this is not a flac stream at all, just noise 1234567890";
    var source = flac.MemorySource{ .data = garbage };
    var collector = flac.PcmCollector(i32){ .samples = &[_]i32{} };

    var decoder = flac.Decoder{};
    try decoder.init(source.source(), collector.output(), .{});
    defer decoder.deinit();

    try std.testing.expectError(error.LostSync, decoder.decode());
}

test "a sample wider than bits_per_sample is rejected" {
    var pcm: [256]i32 = undefined;
    fill(&pcm, 0);
    pcm[10] = 0x8000; // one bit too wide for 16-bit input

    var encoded: [4096]u8 = undefined;
    try std.testing.expectError(
        error.ClientError,
        encode(&encoded, .{ .channels = 1, .bits_per_sample = 16, .sample_rate = 8000 }, &pcm),
    );
}

test "a full sink stops the encoder" {
    // More than one block, so the encoder has something to write before
    // `finish` flushes the tail.
    var pcm: [8192]i32 = undefined;
    fillNoise(&pcm, 1);

    // Big enough for the header that `init` writes (a STREAMINFO block plus
    // a small VORBIS_COMMENT), too small for the first audio frame.
    var encoded: [128]u8 = undefined;
    var sink = flac.MemorySink{ .buffer = &encoded };
    var encoder = flac.Encoder{};
    try encoder.init(sink.sink(), .{
        .channels = 1,
        .bits_per_sample = 16,
        .sample_rate = 44100,
    });
    defer encoder.deinit();

    try std.testing.expectError(error.ClientError, encoder.encode(&pcm));
}

test "sample counts that do not match the channel count" {
    var pcm: [257]i32 = undefined; // not a whole number of stereo frames
    fill(&pcm, 0);

    var encoded: [4096]u8 = undefined;
    var sink = flac.MemorySink{ .buffer = &encoded };
    var encoder = flac.Encoder{};
    try encoder.init(sink.sink(), .{
        .channels = 2,
        .bits_per_sample = 16,
        .sample_rate = 8000,
        .block_size = 256,
    });
    defer encoder.deinit();

    try std.testing.expectError(error.InvalidSampleCount, encoder.encode(&pcm));

    // The wrong number of planes is a channel problem; planes of different
    // lengths are a sample-count problem.
    var left: [128]i32 = undefined;
    var right: [127]i32 = undefined;
    fill(&left, 0);
    fill(&right, 1);

    const ragged = [_][]const i32{ &left, &right };
    try std.testing.expectError(error.InvalidSampleCount, encoder.encodePlanar(&ragged));

    const too_few = [_][]const i32{&left};
    try std.testing.expectError(error.InvalidChannels, encoder.encodePlanar(&too_few));

    // The other side of the same comparison: an extra plane is still a channel
    // problem, not a sample-count one.
    const too_many = [_][]const i32{ &left, &left, &left };
    try std.testing.expectError(error.InvalidChannels, encoder.encodePlanar(&too_many));
}

test "deinit gives back every block libFLAC took" {
    if (!flac.build.alloc_hooks) return; // libFLAC is on libc malloc here
    if (!std.debug.runtime_safety) return; // the counter is compiled out

    // `setAllocator` refuses to swap while libFLAC holds anything, which is
    // only sound if every teardown path — including one that ended in an
    // error — really does release everything.
    var pcm: [16384]i32 = undefined; // two stereo blocks, so a frame is written
    fillNoise(&pcm, 2);

    var encoded: [128]u8 = undefined; // header fits, the first frame does not
    var sink = flac.MemorySink{ .buffer = &encoded };
    var encoder = flac.Encoder{};
    try encoder.init(sink.sink(), .{
        .channels = 2,
        .bits_per_sample = 16,
        .sample_rate = 44100,
    });
    try std.testing.expect(flac.liveBlocks() > 0);
    try std.testing.expectError(error.ClientError, encoder.encode(&pcm));
    encoder.deinit();
    try std.testing.expectEqual(@as(usize, 0), flac.liveBlocks());

    var source = flac.MemorySource{ .data = encoded[0..sink.length] };
    var collector = flac.PcmCollector(i32){ .samples = &pcm };
    var decoder = flac.Decoder{};
    try decoder.init(source.source(), collector.output(), .{});
    try std.testing.expect(flac.liveBlocks() > 0);
    decoder.deinit();
    try std.testing.expectEqual(@as(usize, 0), flac.liveBlocks());
}

test "everything fits in a fixed buffer" {
    if (!flac.build.alloc_hooks) return; // libFLAC is on libc malloc here

    var backing: [256 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    // `backing` is a stack array that dies with this test, so put libFLAC back
    // on the testing allocator on the way out; otherwise the next test that
    // inits an encoder or decoder would allocate into freed memory.
    defer flac.setAllocator(std.testing.allocator);
    flac.setAllocator(fixed.allocator());

    var pcm: [4096]i32 = undefined;
    fill(&pcm, 0);

    var encoded: [16384]u8 = undefined;
    var sink = flac.MemorySink{ .buffer = &encoded };
    var encoder = flac.Encoder{};
    try encoder.init(sink.sink(), .{
        .channels = 2,
        .bits_per_sample = 16,
        .sample_rate = 44100,
        .block_size = 1024,
    });
    try encoder.encode(&pcm);
    try encoder.finish();
    encoder.deinit();

    var source = flac.MemorySource{ .data = encoded[0..sink.length] };
    var collector = flac.PcmCollector(i32){ .samples = &pcm };
    var decoder = flac.Decoder{};
    try decoder.init(source.source(), collector.output(), .{});
    try decoder.decode();
    try std.testing.expect(decoder.finish());
    decoder.deinit();

    try std.testing.expectEqualSlices(i32, &pcm, collector.pcm());
    // High-water mark of the arena, pinned here so regressions show up.
    // libFLAC's encoder is the memory-hungry half of the pair: it reserves
    // one residual workspace per LPC order, so the block size dominates.
    try std.testing.expect(fixed.end_index < 192 * 1024);
}

// ------------------------------------------------------------------ helpers

fn encode(buffer: []u8, options: flac.Encoder.Options, pcm: []const i32) !usize {
    if (flac.build.alloc_hooks) flac.setAllocator(std.testing.allocator);

    var sink = flac.MemorySink{ .buffer = buffer };
    var encoder = flac.Encoder{};
    try encoder.init(sink.sink(), options);
    errdefer encoder.deinit();
    try encoder.encode(pcm);
    try encoder.finish();
    const written = sink.length;
    encoder.deinit();
    return written;
}

fn decode(encoded: []const u8, pcm: []i32) !usize {
    if (flac.build.alloc_hooks) flac.setAllocator(std.testing.allocator);

    var source = flac.MemorySource{ .data = encoded };
    var collector = flac.PcmCollector(i32){ .samples = pcm };
    var decoder = flac.Decoder{};
    try decoder.init(source.source(), collector.output(), .{});
    defer decoder.deinit();
    try decoder.decode();
    return collector.length;
}

fn checkHeader(buffer: []const u8, written: usize) !void {
    try std.testing.expect(written > 4);
    try std.testing.expectEqualStrings("fLaC", buffer[0..4]);
}

/// A byte source with no seek support at all.
const Stream = struct {
    data: []const u8,
    offset: usize = 0,

    pub fn read(self: *Stream, buffer: []u8) flac.ReadResult {
        if (self.offset >= self.data.len) return .{ .outcome = .end_of_stream };
        const n = @min(buffer.len, self.data.len - self.offset);
        @memcpy(buffer[0..n], self.data[self.offset .. self.offset + n]);
        self.offset += n;
        return .{ .bytes_read = n };
    }
};

/// An `Output` that records the STREAMINFO block and forwards frames on.
fn Observer(comptime T: type) type {
    return struct {
        info: *?flac.StreamInfo,
        inner: *T,

        const Self = @This();

        pub fn writeFrame(self: *Self, frame: flac.Frame) flac.Action {
            return self.inner.writeFrame(frame);
        }

        pub fn writeMetadata(self: *Self, metadata: flac.Metadata) void {
            if (metadata == .streaminfo) self.info.* = metadata.streaminfo;
        }

        fn output(self: *Self) flac.Output {
            return flac.Output.from(Self, self);
        }
    };
}
