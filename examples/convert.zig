//! A command-line converter built on the streaming API: WAV to FLAC, and FLAC
//! back to WAV.
//!
//! This is an example, not part of the library — zflac deliberately ships no
//! CLI.  It is here because a file-to-file tool is the smallest program that
//! uses all three callback interfaces at once: a seekable `Source` to decode
//! from, an `Output` that serialises each frame the moment it arrives, and a
//! seekable `Sink` that lets libFLAC go back and patch STREAMINFO once the
//! sample count is known.
//!
//! Neither direction ever holds a whole file: audio moves in chunks of
//! `chunk_frames` sample frames, and the only heap traffic is libFLAC's own.
//!
//!     zig-out/bin/convert input.wav output.flac
//!     zig-out/bin/convert input.flac output.wav

const std = @import("std");
const flac = @import("zflac");

/// Sample frames per chunk on the encode side, and the largest block the
/// decode side can hold.  4096 is libFLAC's default block size, so a stream
/// encoded with the defaults works here at any channel count; one with bigger
/// blocks gets a clear message telling you to raise this.
const chunk_frames = 4096;

/// Interleaved scratch, wide enough for FLAC's 8 channels.
var pcm_chunk: [chunk_frames * flac.max_channels]i32 = undefined;
/// The same samples in WAV byte order.
var byte_chunk: [chunk_frames * flac.max_channels * 4]u8 = undefined;

const wav_header_len = 44;

pub fn main(init: std.process.Init) void {
    // libFLAC mallocs its internal buffers; point them at the process arena so
    // there is nothing to clean up by hand.
    if (flac.build.alloc_hooks) flac.setAllocator(init.gpa);

    run(init) catch |err| {
        std.debug.print("convert: {t}\n", .{err});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    // Windows keeps its command line in UTF-16, so the only iterator that
    // works on every platform is the allocating one.
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next(); // the program name
    const input = args.next() orelse usage();
    const output = args.next() orelse usage();
    const io = init.io;

    if (std.mem.endsWith(u8, input, ".wav") and std.mem.endsWith(u8, output, ".flac")) {
        try wavToFlac(io, input, output);
    } else if (std.mem.endsWith(u8, input, ".flac") and std.mem.endsWith(u8, output, ".wav")) {
        try flacToWav(io, input, output);
    } else {
        std.debug.print("convert: cannot guess a conversion from '{s}' to '{s}'\n", .{ input, output });
        usage();
    }
}

fn usage() noreturn {
    std.debug.print("usage: convert input.wav output.flac\n", .{});
    std.debug.print("       convert input.flac output.wav\n", .{});
    std.process.exit(2);
}

// ------------------------------------------------------------------- encode

fn wavToFlac(io: std.Io, input_path: []const u8, output_path: []const u8) !void {
    const in = std.Io.Dir.cwd().openFile(io, input_path, .{}) catch |err| {
        std.debug.print("convert: cannot open '{s}': {}\n", .{ input_path, err });
        return err;
    };
    defer in.close(io);

    const wav = try readWav(in, io);
    const frames = wav.frameCount();
    const frame_bytes = wav.frameBytes();
    const pcm_bytes = frames * frame_bytes;

    var out = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("convert: cannot create '{s}': {}\n", .{ output_path, err });
        return err;
    };
    defer out.close(io);

    var sink = FileSink{ .file = out, .io = io };
    var encoder = flac.Encoder{};
    try encoder.init(sink.sink(), .{
        .channels = @intCast(wav.channels),
        .bits_per_sample = wav.bits,
        .sample_rate = wav.sample_rate,
        .total_samples_estimate = frames,
        // Mid/side only makes sense for exactly two channels; libFLAC rejects
        // it otherwise.
        .mid_side_stereo = if (wav.channels == 2) true else null,
    });
    defer encoder.deinit();

    var done: u64 = 0;
    while (done < frames) {
        const batch: usize = @intCast(@min(@as(u64, chunk_frames), frames - done));
        const samples = batch * wav.channels;
        const bytes = samples * wav.bits / 8;
        const at = wav.data_at + done * frame_bytes;
        if (try readAt(in, io, byte_chunk[0..bytes], at) != bytes) return error.Truncated;
        try encoder.encode(widen(pcm_chunk[0..samples], byte_chunk[0..bytes], wav.bits, samples));
        done += batch;
    }
    try encoder.finish();
    if (sink.failed) return error.WriteFailed;

    printSummary("wav -> flac", wav.channels, wav.bits, wav.sample_rate, frames, pcm_bytes, sink.end);
}

// ------------------------------------------------------------------- decode

fn flacToWav(io: std.Io, input_path: []const u8, output_path: []const u8) !void {
    const in = std.Io.Dir.cwd().openFile(io, input_path, .{}) catch |err| {
        std.debug.print("convert: cannot open '{s}': {}\n", .{ input_path, err });
        return err;
    };
    defer in.close(io);
    const in_size = try in.length(io);

    var source = FileSource{ .file = in, .io = io, .size = in_size };
    var out = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        std.debug.print("convert: cannot create '{s}': {}\n", .{ output_path, err });
        return err;
    };
    defer out.close(io);

    var writer = WavOut{ .file = out, .io = io, .bits = 0 };
    var decoder = flac.Decoder{};
    try decoder.init(source.source(), writer.output(), .{ .md5_checking = true });
    defer decoder.deinit();

    // Metadata comes first: the WAV header needs the stream properties, and a
    // frame can be as large as the stream's biggest block.
    try decoder.decodeMetadata();
    const info = decoder.stream_info orelse return error.NoStreamInfo;
    if (info.bits_per_sample < 8 or info.bits_per_sample > 32 or
        info.bits_per_sample % 8 != 0)
    {
        std.debug.print(
            "convert: this example writes 8, 16, 24 or 32-bit PCM WAV, " ++
                "but '{s}' is {} bit\n",
            .{ input_path, info.bits_per_sample },
        );
        return error.UnsupportedDepth;
    }
    const needed = @as(usize, info.max_block_size) * info.channels;
    if (needed > pcm_chunk.len) {
        std.debug.print(
            "convert: '{s}' carries blocks of {} frames x {} channels; " ++
                "raise `chunk_frames` past {} and rebuild\n",
            .{ input_path, info.max_block_size, info.channels, chunk_frames },
        );
        return error.ChunkTooSmall;
    }

    var header: [wav_header_len]u8 = undefined;
    wavHeader(&header, info.channels, info.sample_rate, info.bits_per_sample, 0);
    try out.writePositionalAll(io, &header, 0);

    writer.bits = info.bits_per_sample;
    try decoder.decode();
    if (!decoder.finish()) return error.Md5Mismatch;
    if (writer.failed) return error.WriteFailed;

    // Go back and fill in the sizes now that the length is known.
    wavHeader(&header, info.channels, info.sample_rate, info.bits_per_sample, @intCast(writer.bytes));
    try out.writePositionalAll(io, &header, 0);

    printSummary(
        "flac -> wav",
        info.channels,
        info.bits_per_sample,
        info.sample_rate,
        info.total_samples,
        writer.bytes,
        in_size,
    );
}

// ------------------------------------------------------- callback interfaces

/// A seekable FLAC stream on disk.  Positional reads mean the file's own offset
/// is never touched, so `seek` and `tell` are just a counter.
const FileSource = struct {
    file: std.Io.File,
    io: std.Io,
    size: u64,
    at: u64 = 0,

    pub fn read(self: *FileSource, buffer: []u8) flac.ReadResult {
        const n = self.file.readPositionalAll(self.io, buffer, self.at) catch
            return .{ .outcome = .failure };
        self.at += n;
        if (n == 0) return .{ .outcome = .end_of_stream };
        return .{ .bytes_read = n };
    }

    pub fn seek(self: *FileSource, offset: u64) void {
        self.at = offset;
    }

    pub fn tell(self: *FileSource) ?u64 {
        return self.at;
    }

    pub fn length(self: *FileSource) ?u64 {
        return self.size;
    }

    pub fn eof(self: *FileSource) bool {
        return self.at >= self.size;
    }

    pub fn source(self: *FileSource) flac.Source {
        return flac.Source.from(FileSource, self);
    }
};

/// A seekable FLAC stream on disk, written by the encoder.  Seeking is what
/// lets libFLAC rewrite STREAMINFO with the real sample count at `finish`.
const FileSink = struct {
    file: std.Io.File,
    io: std.Io,
    at: u64 = 0,
    /// How far the stream reaches.  Not the same as `at`: libFLAC rewinds to
    /// patch STREAMINFO at `finish`, and does not seek forward again.
    end: u64 = 0,
    failed: bool = false,

    pub fn write(self: *FileSink, bytes: []const u8) flac.Action {
        self.file.writePositionalAll(self.io, bytes, self.at) catch {
            self.failed = true;
            return .stop;
        };
        self.at += bytes.len;
        self.end = @max(self.end, self.at);
        return .ok;
    }

    pub fn seek(self: *FileSink, offset: u64) void {
        self.at = offset;
    }

    pub fn tell(self: *FileSink) ?u64 {
        return self.at;
    }

    pub fn sink(self: *FileSink) flac.Sink {
        return flac.Sink.from(FileSink, self);
    }
};

/// Turns each decoded frame straight into WAV bytes, so the audio never
/// accumulates: at any moment only one frame is in memory.
const WavOut = struct {
    file: std.Io.File,
    io: std.Io,
    bits: u8,
    bytes: u64 = 0,
    failed: bool = false,

    pub fn writeFrame(self: *WavOut, frame: flac.Frame) flac.Action {
        const count = flac.writeInterleaved(i32, &pcm_chunk, frame);
        const produced = narrow(&byte_chunk, pcm_chunk[0..count], self.bits);
        self.file.writePositionalAll(self.io, byte_chunk[0..produced], wav_header_len + self.bytes) catch {
            self.failed = true;
            return .stop;
        };
        self.bytes += produced;
        return .ok;
    }

    pub fn output(self: *WavOut) flac.Output {
        return flac.Output.from(WavOut, self);
    }
};

// -------------------------------------------------------------- WAV plumbing

const Wav = struct {
    channels: u16,
    sample_rate: u32,
    bits: u8,
    data_at: u64,
    data_len: u64,

    /// Bytes per sample frame.
    fn frameBytes(self: Wav) u64 {
        return @as(u64, self.channels) * self.bits / 8;
    }

    fn frameCount(self: Wav) u64 {
        return self.data_len / self.frameBytes();
    }
};

fn readAt(file: std.Io.File, io: std.Io, buffer: []u8, offset: u64) !usize {
    return file.readPositionalAll(io, buffer, offset);
}

fn readWav(file: std.Io.File, io: std.Io) !Wav {
    var riff: [12]u8 = undefined;
    if (try readAt(file, io, &riff, 0) != riff.len) return error.NotWav;
    if (!std.mem.eql(u8, riff[0..4], "RIFF") or !std.mem.eql(u8, riff[8..12], "WAVE")) {
        return error.NotWav;
    }

    var wav = Wav{ .channels = 0, .sample_rate = 0, .bits = 0, .data_at = 0, .data_len = 0 };
    var have_fmt = false;
    var at: u64 = 12;
    while (true) {
        var chunk: [8]u8 = undefined;
        if (try readAt(file, io, &chunk, at) != chunk.len) break;
        const size = std.mem.readInt(u32, chunk[4..8], .little);
        const id = chunk[0..4];

        if (std.mem.eql(u8, id, "fmt ")) {
            var fmt: [16]u8 = undefined;
            if (try readAt(file, io, &fmt, at + 8) < fmt.len) return error.Truncated;
            // 1 is integer PCM; 3 is IEEE float and 0xFFFE is WAVE_FORMAT_EXTENSIBLE,
            // neither of which has a place in a FLAC stream.
            if (std.mem.readInt(u16, fmt[0..2], .little) != 1) return error.NotPcm;
            wav.channels = std.mem.readInt(u16, fmt[2..4], .little);
            wav.sample_rate = std.mem.readInt(u32, fmt[4..8], .little);
            // block_align sits at 12; the bit depth is at 14.
            wav.bits = @intCast(std.mem.readInt(u16, fmt[14..16], .little));
            have_fmt = true;
        } else if (std.mem.eql(u8, id, "data")) {
            wav.data_at = at + 8;
            wav.data_len = size;
            break;
        }

        // Chunks are word aligned, so an odd size is followed by a pad byte.
        at += 8 + size + (size & 1);
    }

    if (!have_fmt) return error.NotWav;
    if (wav.channels == 0 or wav.channels > flac.max_channels) return error.BadChannelCount;
    if (wav.bits % 8 != 0 or wav.bits < 8 or wav.bits > 32) return error.UnsupportedDepth;

    // A streamed WAV often carries a placeholder data size, and a truncated one
    // claims more than it holds.  The reverse is normal: chunks may follow
    // `data`, so a file longer than the chunk is not a problem.
    const available = (try file.length(io)) -| wav.data_at;
    if (wav.data_len > available) {
        std.debug.print(
            "warning: 'data' claims {} bytes but {} are present; converting what is there\n",
            .{ wav.data_len, available },
        );
        wav.data_len = available;
    }
    if (wav.data_len == 0) return error.NotWav;

    // A `data` length that is not a whole number of sample frames means the
    // file ends mid-frame.  Those last few bytes cannot become a sample, so
    // they are dropped — say so rather than quietly converting less.
    const leftover = wav.data_len % wav.frameBytes();
    if (leftover != 0) {
        std.debug.print("warning: {} trailing bytes do not fill a sample frame; ignored\n", .{leftover});
    }
    return wav;
}

fn wavHeader(dst: *[wav_header_len]u8, channels: u16, rate: u32, bits: u8, data_len: u32) void {
    const frame_bytes = @as(u32, channels) * bits / 8;
    @memcpy(dst[0..4], "RIFF");
    std.mem.writeInt(u32, dst[4..8], 36 + data_len, .little);
    @memcpy(dst[8..12], "WAVE");
    @memcpy(dst[12..16], "fmt ");
    std.mem.writeInt(u32, dst[16..20], 16, .little);
    std.mem.writeInt(u16, dst[20..22], 1, .little); // integer PCM
    std.mem.writeInt(u16, dst[22..24], channels, .little);
    std.mem.writeInt(u32, dst[24..28], rate, .little);
    std.mem.writeInt(u32, dst[28..32], rate *% frame_bytes, .little);
    std.mem.writeInt(u16, dst[32..34], @intCast(frame_bytes), .little);
    std.mem.writeInt(u16, dst[34..36], bits, .little);
    @memcpy(dst[36..40], "data");
    std.mem.writeInt(u32, dst[40..44], data_len, .little);
}

/// Widens `count` interleaved PCM samples from WAV byte order into the `i32`
/// layout the encoder wants.
fn widen(dst: []i32, src: []const u8, bits: u8, count: usize) []const i32 {
    for (0..count) |i| {
        dst[i] = switch (bits) {
            // WAV 8-bit samples are unsigned; FLAC wants them signed.
            8 => @as(i32, src[i]) -% 128,
            16 => std.mem.readInt(i16, src[i * 2 ..][0..2], .little),
            24 => signExtend24(src[i * 3 ..][0..3]),
            else => std.mem.readInt(i32, src[i * 4 ..][0..4], .little),
        };
    }
    return dst[0..count];
}

fn signExtend24(b: *const [3]u8) i32 {
    const v: i32 = (@as(i32, b[2]) << 16) | (@as(i32, b[1]) << 8) | @as(i32, b[0]);
    return if (v & 0x800000 != 0) v -| 0x1000000 else v;
}

/// The inverse of `widen`, for writing PCM back out.
fn narrow(dst: []u8, src: []const i32, bits: u8) usize {
    for (src, 0..) |sample, i| {
        switch (bits) {
            // Back to WAV's unsigned 8-bit; `@intCast` traps in a safety build
            // if the stream carried samples that do not fit in 8 bits.
            8 => dst[i] = @intCast(sample +% 128),
            16 => {
                // 0.16 will not truncate signed to unsigned, so narrow within
                // the signed range first and then reinterpret the bits.
                const v: i16 = @truncate(sample);
                std.mem.writeInt(u16, dst[i * 2 ..][0..2], @bitCast(v), .little);
            },
            24 => {
                const raw: u32 = @bitCast(sample);
                dst[i * 3] = @truncate(raw);
                dst[i * 3 + 1] = @truncate(raw >> 8);
                dst[i * 3 + 2] = @truncate(raw >> 16);
            },
            else => std.mem.writeInt(u32, dst[i * 4 ..][0..4], @bitCast(sample), .little),
        }
    }
    return src.len * bits / 8;
}

fn printSummary(
    what: []const u8,
    channels: u16,
    bits: u8,
    rate: u32,
    frames: u64,
    pcm_bytes: u64,
    flac_bytes: u64,
) void {
    std.debug.print("{s}: {} Hz, {} bit, {} ch, {} sample frames\n", .{
        what, rate, bits, channels, frames,
    });
    std.debug.print("  {} bytes <-> {} bytes, ratio {d:.2}:1\n", .{
        pcm_bytes,
        flac_bytes,
        @as(f64, @floatFromInt(pcm_bytes)) / @as(f64, @floatFromInt(flac_bytes)),
    });
}
