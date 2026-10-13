//! Encode a synthetic tone to FLAC and decode it back again.
//!
//! The audio and the encoded stream both live in fixed buffers in .bss; the
//! only heap traffic is libFLAC's own, which is routed through
//! `flac.setAllocator`.

const std = @import("std");
const flac = @import("zflac");

const sample_rate: u32 = 44100;
const channels: usize = 2;
const bits_per_sample: u8 = 16;
/// 0.1 s of stereo audio.
const sample_frames = 4410;

var source_pcm: [sample_frames * channels]i16 = undefined;
var pcm: [sample_frames * channels]i32 = undefined;
var encoded: [256 * 1024]u8 = undefined;
var decoded_pcm: [sample_frames * channels]i16 = undefined;

pub fn main() !void {
    // libFLAC mallocs its internal buffers; point them wherever you like.
    if (flac.build.alloc_hooks) flac.setAllocator(std.heap.c_allocator);

    writeTone();

    // ---- encode ----------------------------------------------------------
    var sink = flac.MemorySink{ .buffer = &encoded };
    var encoder = flac.Encoder{};
    try encoder.init(sink.sink(), .{
        .channels = @intCast(channels),
        .bits_per_sample = bits_per_sample,
        .sample_rate = sample_rate,
        .compression_level = 5,
        .mid_side_stereo = true,
        .padding = 1024,
    });
    defer encoder.deinit();

    try encoder.encode(&pcm);
    try encoder.finish();

    const encoded_bytes = sink.bytes();
    const pcm_bytes = source_pcm.len * @sizeOf(i16);
    std.debug.print("encoded {d} sample frames ({d} KiB) -> {d} bytes\n", .{
        sample_frames,
        pcm_bytes / 1024,
        encoded_bytes.len,
    });
    std.debug.print("compression ratio: {d:.2}:1\n", .{
        @as(f64, @floatFromInt(pcm_bytes)) / @as(f64, @floatFromInt(encoded_bytes.len)),
    });

    // ---- decode ----------------------------------------------------------
    var source = flac.MemorySource{ .data = encoded_bytes };
    var collector = flac.PcmCollector(i16){ .samples = &decoded_pcm };
    var decoder = flac.Decoder{};
    try decoder.init(source.source(), collector.output(), .{ .md5_checking = true });
    defer decoder.deinit();

    // Metadata first, so the stream properties are known before any audio.
    try decoder.decodeMetadata();
    const info = decoder.stream_info orelse return error.NoStreamInfo;
    std.debug.print(
        "stream: {d} Hz, {d} bit, {d} ch, {d} samples, block {d}..{d}\n",
        .{
            info.sample_rate,
            info.bits_per_sample,
            info.channels,
            info.total_samples,
            info.min_block_size,
            info.max_block_size,
        },
    );

    try decoder.decode();
    if (!decoder.finish()) return error.Md5Mismatch;

    if (!std.mem.eql(i16, collector.pcm(), &source_pcm)) return error.RoundTripMismatch;
    std.debug.print("round trip verified: {d} samples in {d} frames\n", .{
        collector.length,
        collector.frames,
    });

    // ---- keep the file around for inspection -----------------------------
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const file = try std.Io.Dir.cwd().createFile(io, "roundtrip.flac", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, encoded_bytes);
    std.debug.print("wrote roundtrip.flac\n", .{});
}

/// A4 and a fifth, one per channel, so mid/side stereo has something to do.
fn writeTone() void {
    const rate: f32 = @floatFromInt(sample_rate);
    for (0..sample_frames) |i| {
        const t: f32 = @floatFromInt(i);
        const note: [channels]f32 = .{
            @sin(std.math.tau * 440.0 * t / rate),
            @sin(std.math.tau * 660.0 * t / rate),
        };
        for (note, 0..) |sample, channel| {
            const index = i * channels + channel;
            const scaled: i32 = @intFromFloat(sample * 12000.0);
            source_pcm[index] = @truncate(scaled);
            pcm[index] = source_pcm[index];
        }
    }
}
