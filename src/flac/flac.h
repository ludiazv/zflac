/* Root of the C bindings for zflac.
 *
 * The translate-c package (see build.zig) translates this file into the
 * `flac_c` module that src/flac/c.zig re-exports.  It is a stub: only
 * preprocessor directives and includes, no declarations of its own.
 *
 * Keep the includes in sync with the vendored libFLAC headers in
 * vendor/flac/include/FLAC.
 */
#ifndef ZFLAC_FLAC_H
#define ZFLAC_FLAC_H

/* The bindings target a static link; skip the DLL import decorations on
 * Windows.  Harmless everywhere else. */
#define FLAC__NO_DLL 1

#include "FLAC/format.h"
#include "FLAC/stream_decoder.h"
#include "FLAC/stream_encoder.h"

#endif