//! Raw C bindings to libFLAC.
//!
//! Everything in this package is built on top of this single translation
//! unit; the rest of the library never names a `FLAC__*` symbol directly.

pub const c = @cImport({
    @cInclude("FLAC/format.h");
    @cInclude("FLAC/stream_decoder.h");
    @cInclude("FLAC/stream_encoder.h");
});
