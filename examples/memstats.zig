//! How much heap libFLAC takes, per configuration.
//!
//! Run with `zig build memstats`.  Every number is measured through a
//! metering allocator wrapped around the C allocator, so it covers exactly
//! what libFLAC asks `setAllocator` for and nothing else: the `Decoder` and
//! `Encoder` structs themselves, the `Source`/`Sink` buffers and the PCM you
//! hand to the encoder are all yours to size.

const std = @import("std");
const flac = @import("zflac");

var peak: usize = 0;
var live: usize = 0;
var base: std.mem.Allocator = undefined;

fn alloc(_: *anyopaque, n: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
    live += n;
    if (live > peak) peak = live;
    return base.vtable.alloc(base.ptr, n, a, ra);
}

fn resize(_: *anyopaque, b: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
    live +|= n - b.len;
    if (live > peak) peak = live;
    return base.vtable.resize(base.ptr, b, a, n, ra);
}

fn remap(_: *anyopaque, b: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
    live +|= n - b.len;
    if (live > peak) peak = live;
    return base.vtable.remap(base.ptr, b, a, n, ra);
}

fn free(_: *anyopaque, b: []u8, a: std.mem.Alignment, ra: usize) void {
    live -= b.len;
    base.vtable.free(base.ptr, b, a, ra);
}

const meter_vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn reset() void {
    peak = 0;
    live = 0;
}

pub fn main() !void {
    base = std.heap.c_allocator;
    flac.setAllocator(.{ .ptr = undefined, .vtable = &meter_vtable });

    // Deterministic noise, kept inside 16 bits: incompressible input is what
    // makes the encoder allocate its worst-case residual buffers.
    var pcm: [4096 * 8]i32 = undefined;
    for (&pcm, 0..) |*sample, i| {
        const h: u32 = @truncate(@as(u64, i) *% 0x9E3779B1);
        const noise: i16 = @bitCast(@as(u16, @truncate(h)));
        sample.* = noise;
    }

    var out: [4 << 20]u8 = undefined;

    const cases = .{
        .{ .ch = 1, .bps = 16, .rate = 8000, .block = 256, .level = 5 },
        .{ .ch = 1, .bps = 16, .rate = 44100, .block = 256, .level = 5 },
        .{ .ch = 2, .bps = 16, .rate = 44100, .block = 256, .level = 5 },
        .{ .ch = 2, .bps = 16, .rate = 44100, .block = 1024, .level = 5 },
        .{ .ch = 2, .bps = 16, .rate = 44100, .block = 4096, .level = 5 },
        .{ .ch = 2, .bps = 24, .rate = 48000, .block = 4096, .level = 8 },
        .{ .ch = 2, .bps = 16, .rate = 44100, .block = 4096, .level = 0 },
    };

    std.debug.print("encoder\n", .{});
    inline for (cases) |case| {
        var sink = flac.MemorySink{ .buffer = &out };
        var encoder = flac.Encoder{};
        try encoder.init(sink.sink(), .{
            .channels = case.ch,
            .bits_per_sample = case.bps,
            .sample_rate = case.rate,
            .block_size = case.block,
            .compression_level = case.level,
        });
        const at_init = peak;
        try encoder.encode(pcm[0 .. case.block * case.ch]);
        try encoder.finish();
        encoder.deinit();

        const label = std.fmt.comptimePrint("{d}ch {d}bit {d}Hz block {d} level {d}", .{
            case.ch, case.bps, case.rate, case.block, case.level,
        });
        std.debug.print("  {s: <34} after init {d:>7}  peak {d:>7}\n", .{ label, at_init, peak });
        reset();
    }

    std.debug.print("\ndecoder (stereo 16 bit, MD5 checking on)\n", .{});
    inline for (.{ 256, 1024, 4096 }) |block| {
        var sink = flac.MemorySink{ .buffer = &out };
        var encoder = flac.Encoder{};
        try encoder.init(sink.sink(), .{
            .channels = 2,
            .bits_per_sample = 16,
            .sample_rate = 44100,
            .block_size = block,
        });
        try encoder.encode(pcm[0 .. block * 2]);
        try encoder.finish();
        encoder.deinit();
        reset();

        var samples: [4096 * 2]i32 = undefined;
        var source = flac.MemorySource{ .data = out[0..sink.length] };
        var collected = flac.PcmCollector(i32){ .samples = &samples };
        var decoder = flac.Decoder{};
        try decoder.init(source.source(), collected.output(), .{});
        const at_init = peak;
        try decoder.decode();
        decoder.deinit();

        std.debug.print("  block {d:<6}                      after init {d:>7}  peak {d:>7}\n", .{ block, at_init, peak });
        reset();
    }

    std.debug.print("\nunfreed at exit: {d} bytes\n", .{live});
}
