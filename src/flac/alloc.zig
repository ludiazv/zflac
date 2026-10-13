//! libFLAC calls `malloc`, `realloc`, `calloc` and `free` directly.  When the
//! package is built with `-Dflac-alloc-hooks=true` (the default) build.zig
//! renames those calls to the symbols defined here, so every byte libFLAC
//! touches comes from a Zig allocator of your choosing — including a fixed
//! buffer arena on a bare-metal target.
//!
//! Unless `setAllocator` says otherwise the Zig allocator is the C library's,
//! i.e. exactly what stock libFLAC does.
//!
//! Each block carries a small header so `realloc`/`free` can recover the
//! length, which Zig allocators need and C allocators hide.

const std = @import("std");

const builtin = @import("builtin");
const config = @import("config");

const magic: u32 = 0x5a464143; // "ZFAC"

const Header = extern struct {
    magic: u32 = magic,
    size: usize,
};

/// libFLAC's allocator.  It defaults to the C library's `malloc` — the same
/// thing stock libFLAC does — and `setAllocator` overrides it.  On a target
/// with no C library there is nothing sensible to default to, so it starts
/// out empty and libFLAC's first allocation fails with `error.OutOfMemory`
/// until you install one.
var allocator: ?std.mem.Allocator = if (builtin.link_libc) std.heap.c_allocator else null;

/// Blocks libFLAC currently holds.
///
/// Tracked whenever the build has runtime safety — Debug and ReleaseSafe —
/// so `setAllocator` can refuse to swap the allocator out from under live
/// buffers.  The header magic cannot catch that mistake: a block made by the
/// old allocator carries our magic just like one made by the new one, so the
/// swap would hand a foreign pointer to the new allocator.
///
/// The counter is atomic because nothing in this package stops two threads
/// driving two instances; `std.atomic` needs no OS, and allocation happens per
/// init and per frame, never per sample, so the cost is nil.  In ReleaseFast
/// the counter is not touched and the compiler drops it entirely.
var live_blocks: std.atomic.Value(usize) = .init(0);

inline fn countAlloc() void {
    if (builtin.mode.runtimeSafety()) _ = live_blocks.fetchAdd(1, .monotonic);
}

inline fn countFree() void {
    if (builtin.mode.runtimeSafety()) _ = live_blocks.fetchSub(1, .monotonic);
}

/// Sets the allocator used for libFLAC's internal buffers.
///
/// Call this once, before creating any `Encoder` or `Decoder`.  The value is
/// process wide: libFLAC gives an allocation no way back to the instance it
/// belongs to.
///
/// Swapping it later is only safe when no encoder or decoder is still alive.
/// In Debug and ReleaseSafe this panics if libFLAC still holds a block;
/// ReleaseFast trusts you, and freeing such a block through the new allocator
/// is undefined behaviour.
pub fn setAllocator(value: std.mem.Allocator) void {
    if (!config.alloc_hooks) {
        @compileError("zflac was built with -Dflac-alloc-hooks=false; libFLAC uses libc malloc() directly");
    }
    if (builtin.mode.runtimeSafety()) {
        const held = live_blocks.load(.monotonic);
        if (held != 0) {
            std.debug.panic(
                "zflac: setAllocator called while libFLAC still holds {d} block(s)",
                .{held},
            );
        }
    }
    allocator = value;
}

/// The allocator currently in use, or `null` when libFLAC has none.
pub fn getAllocator() ?std.mem.Allocator {
    return allocator;
}

/// How many blocks libFLAC holds right now.
///
/// A cheap leak check: it is non-zero between an `Encoder`/`Decoder` init and
/// its `deinit`, and back to zero afterwards.  Always zero in ReleaseFast,
/// where the counter does not exist at all.
pub fn liveBlocks() usize {
    return live_blocks.load(.monotonic);
}

/// A block is `[header][payload]`, returned to C with the header hidden.
fn block(base: *Header, size: usize) []align(@alignOf(Header)) u8 {
    const bytes: [*]align(@alignOf(Header)) u8 = @ptrCast(base);
    return bytes[0 .. size + @sizeOf(Header)];
}

fn headerOf(ptr: *anyopaque) *Header {
    return @ptrFromInt(@intFromPtr(ptr) - @sizeOf(Header));
}

fn payloadOf(base: *Header, size: usize) *anyopaque {
    base.* = .{ .size = size };
    return @ptrFromInt(@intFromPtr(base) + @sizeOf(Header));
}

fn allocate(size: usize) ?*anyopaque {
    const a = allocator orelse return null;
    const buf = a.alignedAlloc(u8, .of(Header), size + @sizeOf(Header)) catch return null;
    countAlloc();
    return payloadOf(@ptrCast(buf.ptr), size);
}

fn deallocate(ptr: ?*anyopaque) void {
    const p = ptr orelse return;
    const a = allocator orelse return;
    const base = headerOf(p);
    if (base.magic != magic) return; // not ours; leave it alone
    base.magic = 0;
    countFree();
    a.free(block(base, base.size));
}

pub export fn zflac_malloc(size: usize) callconv(.c) ?*anyopaque {
    return allocate(size);
}

pub export fn zflac_calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    const total = count * size;
    if (count != 0 and total / count != size) return null;
    const p = allocate(total) orelse return null;
    @memset(@as([*]u8, @ptrCast(p))[0..total], 0);
    return p;
}

pub export fn zflac_realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (ptr == null) return allocate(size);
    if (size == 0) {
        deallocate(ptr);
        return null;
    }
    const a = allocator orelse return null;
    const base = headerOf(ptr.?);
    if (base.magic != magic) return null;

    const grown = a.realloc(block(base, base.size), size + @sizeOf(Header)) catch return null;
    return payloadOf(@ptrCast(grown.ptr), size);
}

pub export fn zflac_free(ptr: ?*anyopaque) callconv(.c) void {
    deallocate(ptr);
}
