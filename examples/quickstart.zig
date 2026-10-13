//! The README's Quick Start, kept honest: if this stops compiling, the
//! README is wrong.
const std = @import("std");
const flac = @import("zflac");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Route libFLAC's own buffers through this allocator instead of malloc().
    flac.setAllocator(arena.allocator());

    // 512 stereo frames of 16-bit PCM, interleaved: l r l r ...
    var pcm: [1024]i32 = .{0} ** 1024;
    var encoded: [4096]u8 = undefined;

    var sink = flac.MemorySink{ .buffer = &encoded };
    var encoder = flac.Encoder{};
    try encoder.init(sink.sink(), .{
        .channels = 2,
        .bits_per_sample = 16,
        .sample_rate = 44100,
        .block_size = 256, // keeps libFLAC's own heap under ~76 KiB
    });
    defer encoder.deinit();

    try encoder.encode(&pcm);
    try encoder.finish();

    var source = flac.MemorySource{ .data = sink.bytes() };
    var collected: [1024]i32 = undefined;
    var collector = flac.PcmCollector(i32){ .samples = &collected };

    var decoder = flac.Decoder{};
    try decoder.init(source.source(), collector.output(), .{});
    defer decoder.deinit();

    try decoder.decode();
    std.debug.print("{d} frames, {d} samples, {d} bytes\n", .{
        collector.frames,
        collector.length,
        sink.bytes().len,
    });
}
