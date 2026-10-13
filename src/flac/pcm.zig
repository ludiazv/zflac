//! Helpers for moving samples between FLAC's planar `i32` layout and the
//! interleaved layout most applications work with.

const interfaces = @import("interfaces.zig");
const types = @import("types.zig");

/// Copies the samples of a decoded frame into `dst` in interleaved order and
/// returns the number of samples written.
///
/// `T` must be a signed integer type.  FLAC samples always fit in `i32`;
/// narrower types are truncated, which is exact as long as `T` is at least
/// as wide as the stream's `bits_per_sample`.
pub fn writeInterleaved(comptime T: type, dst: []T, frame: types.Frame) usize {
    comptime {
        if (@typeInfo(T) != .int) @compileError("T must be a signed integer, got " ++ @typeName(T));
    }
    const channels = frame.samples.len;
    if (channels == 0) return 0;

    const per_channel = @min(@as(usize, frame.header.block_size), dst.len / channels);
    for (frame.samples, 0..) |plane, channel| {
        for (plane[0..per_channel], 0..) |sample, i| {
            dst[i * channels + channel] = @truncate(sample);
        }
    }
    return per_channel * channels;
}

/// Widens interleaved samples of type `T` into the `i32` buffer the encoder
/// expects and returns the number of samples written.
pub fn readInterleaved(comptime T: type, dst: []i32, src: []const T) usize {
    comptime {
        if (@typeInfo(T) != .int) @compileError("T must be a signed integer, got " ++ @typeName(T));
    }
    const n = @min(dst.len, src.len);
    for (dst[0..n], src[0..n]) |*slot, sample| slot.* = sample;
    return n;
}

/// An `interfaces.Output` implementation that collects decoded frames as one
/// interleaved buffer.
///
/// A frame that does not fit in the remaining space is refused, which makes
/// the decoder stop with `error.Aborted`.
pub fn PcmCollector(comptime T: type) type {
    return struct {
        /// Backing store for the collected samples.
        samples: []T,
        /// Samples collected so far, interleaved.
        length: usize = 0,
        /// Channels of the most recently seen frame.
        channels: u8 = 0,
        /// Frames collected so far.
        frames: usize = 0,

        const Self = @This();

        pub fn writeFrame(self: *Self, frame: types.Frame) interfaces.Action {
            if (self.length != 0 and frame.samples.len != self.channels) return .stop;
            self.channels = @intCast(frame.samples.len);

            const needed = frame.samples.len * @as(usize, frame.header.block_size);
            if (needed > self.samples.len - self.length) return .stop;

            self.length += writeInterleaved(T, self.samples[self.length..], frame);
            self.frames += 1;
            return .ok;
        }

        /// The collected samples.
        pub fn pcm(self: *const Self) []const T {
            return self.samples[0..self.length];
        }

        /// Samples still missing to reach `total`.
        pub fn remaining(self: *const Self, total: usize) usize {
            return total -| self.length;
        }

        pub fn output(self: *Self) interfaces.Output {
            return interfaces.Output.from(Self, self);
        }
    };
}
