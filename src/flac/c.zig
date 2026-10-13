//! Raw C bindings to libFLAC.
//!
//! Everything in this package is built on top of this single translation
//! unit; the rest of the library never names a `FLAC__*` symbol directly.
//!
//! The bindings are generated at build time by the translate-c package from
//! `flac.h` (see build.zig) and imported here as the `flac_c` module.

pub const c = @import("flac_c");
