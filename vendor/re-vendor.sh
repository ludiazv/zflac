#!/bin/sh
# Re-copy the vendored libFLAC subset from an upstream checkout.
#
#   ./vendor/re-vendor.sh /path/to/flac
#
# The upstream tree is expected to be at the revision recorded in
# vendor/flac/README.md.  Nothing here is automatic: read the new release's
# notes, then diff vendor/flac against the result before committing.
set -eu

upstream="${1:?usage: $0 <path to an flac checkout>}"
dest="$(dirname "$0")/flac"

copy() { # <path relative to the upstream tree>
	mkdir -p "$dest/$(dirname "$1")"
	[ -f "$upstream/$1" ] || { echo "missing: $1" >&2; exit 1; }
	cp "$upstream/$1" "$dest/$1"
	echo "copied $1"
}

# Public headers the bindings include, plus the share/ headers they pull in.
for f in \
	FLAC/assert.h FLAC/callback.h FLAC/export.h FLAC/format.h \
	FLAC/ordinals.h FLAC/stream_decoder.h FLAC/stream_encoder.h \
	share/alloc.h share/compat.h share/compat_threads.h share/endswap.h \
	share/macros.h share/private.h share/win_utf8_io.h
do
	copy "include/$f"
done

# Internal headers, taken as needed: the .c files below include them by hand.
# metadata.h and the ogg_*.h headers are deliberately left out.
for f in \
	private/all.h private/bitmath.h private/bitreader.h private/bitwriter.h \
	private/cpu.h private/crc.h private/fixed.h private/float.h \
	private/format.h private/lpc.h private/macros.h private/md5.h \
	private/memory.h private/stream_encoder.h private/stream_encoder_framing.h \
	private/window.h \
	protected/stream_decoder.h protected/stream_encoder.h
do
	copy "src/libFLAC/include/$f"
done

# The translation units needed by the stream encoder and decoder.  Everything
# else in src/libFLAC (Ogg, the metadata object API, the SIMD kernels) is left
# out on purpose.  The two deduplication/*.c files are #included by
# bitreader.c and lpc.c even in a portable build.
for f in \
	bitmath.c bitreader.c bitwriter.c cpu.c crc.c fixed.c float.c format.c \
	lpc.c md5.c memory.c stream_decoder.c stream_encoder.c \
	stream_encoder_framing.c window.c \
	deduplication/bitreader_read_rice_signed_block.c \
	deduplication/lpc_compute_autocorrelation_intrin.c
do
	copy "src/libFLAC/$f"
done

# Windows only: compat.h maps libFLAC's file helpers onto the UTF-8 wrappers
# in src/share/win_utf8_io, and the file-based init functions still have to
# link even though the bindings never call them.
if [ -f "$upstream/src/share/win_utf8_io/win_utf8_io.c" ]; then
	copy "src/share/win_utf8_io/win_utf8_io.c"
fi

copy COPYING.Xiph

# config.h is ours, not upstream's generated one.  Bump PACKAGE_VERSION there
# by hand if the version changed.
echo
echo "Done.  vendor/flac/config.h is not touched; update PACKAGE_VERSION in it."
echo "Then run: zig build test"
