/* Hand-written config.h for building the vendored libFLAC subset with the
 * Zig build system.
 *
 * Upstream generates this file from config.cmake.h.in / configure.ac; the
 * defines below are the ones actually consulted by the sources under
 * src/libFLAC. Everything that is not needed by the stream encoder/decoder
 * (Ogg, threads, x86/ARM asm, gettext, ...) is turned off.
 */

#ifndef ZFLAC_CONFIG_H
#define ZFLAC_CONFIG_H

/* ------------------------------------------------------------------------ *
 * Package identity (used for FLAC__VERSION_STRING / FLAC__VENDOR_STRING)
 * ------------------------------------------------------------------------ */
#define PACKAGE "flac"
#define PACKAGE_NAME "FLAC"
#define PACKAGE_TARNAME "flac"
#define PACKAGE_BUGREPORT "flac-dev@xiph.org"
#define PACKAGE_URL "https://xiph.org/flac/"
#define PACKAGE_VERSION "1.5.0"
#define PACKAGE_STRING "FLAC " PACKAGE_VERSION

/* GIT_COMMIT_* deliberately left undefined: format.c then falls back to
 * PACKAGE_VERSION, which keeps build output reproducible. */

/* ------------------------------------------------------------------------ *
 * Containers
 * ------------------------------------------------------------------------ */
/* Tested with `#if`, so it must always be defined. */
#define FLAC__HAS_OGG 0

/* ------------------------------------------------------------------------ *
 * Host byte order
 * ------------------------------------------------------------------------ */
#if defined(__BYTE_ORDER__) && defined(__ORDER_BIG_ENDIAN__) && \
    __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#define CPU_IS_BIG_ENDIAN 1
#else
#define CPU_IS_BIG_ENDIAN 0
#endif

/* Tested with `#if`, so it must always be defined. */
#define WORDS_BIGENDIAN CPU_IS_BIG_ENDIAN

/* ------------------------------------------------------------------------ *
 * Word size used by the bit reader / bit writer
 *
 * 32-bit words keep the internal buffers small, which is what we want on
 * embedded targets. Define ENABLE_64_BIT_WORDS to 1 for throughput on
 * 64-bit hosts.
 * ------------------------------------------------------------------------ */
#ifndef ENABLE_64_BIT_WORDS
#define ENABLE_64_BIT_WORDS 0
#endif

/* ------------------------------------------------------------------------ *
 * CPU / SIMD
 *
 * FLAC__CPU_X86_64, FLAC__CPU_IA32 and FLAC__CPU_ARM64 are auto-detected by
 * private/cpu.h from compiler predefines. FLAC__NO_ASM is added by build.zig
 * when the optional intrinsics are disabled.
 *
 * All three of the macros below are tested with `#if` and must be defined.
 * ------------------------------------------------------------------------ */
#define FLAC__HAS_X86INTRIN 0
#define FLAC__HAS_NEONINTRIN 0
#define FLAC__HAS_A64NEONINTRIN 0

/* ------------------------------------------------------------------------ *
 * libc features
 * ------------------------------------------------------------------------ */
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LROUND 1

/* fseeko()/ftello() are only reached by libFLAC's file-based init functions,
 * which the bindings never call, but they still have to compile.  glibc,
 * musl, bionic and newlib all provide them; build with -DFLAC__NO_FSEEKO for
 * a minimal libc that does not (the fallback is fseek/ftell, which caps the
 * addressable stream at LONG_MAX bytes). */
#ifndef FLAC__NO_FSEEKO
#define HAVE_FSEEKO 1
#endif

/* Not used by the vendored subset: HAVE_CPUID_H, HAVE_SYS_AUXV_H,
 * HAVE_GETOPT_LONG, ... */

/* ------------------------------------------------------------------------ *
 * Threading
 *
 * HAVE_PTHREAD / HAVE_C11THREADS are intentionally not defined, which keeps
 * FLAC__USE_THREADS out of stream_encoder.c: the encoder stays single
 * threaded and needs no OS threading primitives.
 * ------------------------------------------------------------------------ */

#endif /* ZFLAC_CONFIG_H */
