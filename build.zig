const std = @import("std");

/// The libFLAC translation units needed by the stream encoder and decoder.
/// Everything else (Ogg, metadata iterators, SIMD kernels, ...) is left out.
const c_sources = [_][]const u8{
    "src/libFLAC/bitmath.c",
    "src/libFLAC/bitreader.c",
    "src/libFLAC/bitwriter.c",
    "src/libFLAC/cpu.c",
    "src/libFLAC/crc.c",
    "src/libFLAC/fixed.c",
    "src/libFLAC/float.c",
    "src/libFLAC/format.c",
    "src/libFLAC/lpc.c",
    "src/libFLAC/md5.c",
    "src/libFLAC/memory.c",
    "src/libFLAC/stream_decoder.c",
    "src/libFLAC/stream_encoder.c",
    "src/libFLAC/stream_encoder_framing.c",
    "src/libFLAC/window.c",
};

/// Windows only: compat.h routes libFLAC's file helpers through the UTF-8
/// wrappers, so those symbols have to exist even though the bindings never
/// touch the file-based init functions.
const win_sources = [_][]const u8{"src/share/win_utf8_io/win_utf8_io.c"};

/// Everything that shapes the compiled libFLAC.
const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    assertions: bool,
    alloc_hooks: bool,
    use_system: bool,
    fseeko: bool,
    link_libm: bool,
    link_libc: bool,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Bare-metal targets have no libc, no libm and nothing to run a test on.
    const hosted = target.result.os.tag != .freestanding;

    const use_system = b.option(
        bool,
        "flac-system",
        "Link a system libFLAC instead of compiling the vendored sources",
    ) orelse false;

    const alloc_hooks = b.option(
        bool,
        "flac-alloc-hooks",
        "Route libFLAC's malloc/free/realloc/calloc through a Zig allocator",
    ) orelse !use_system;

    const assertions = b.option(
        bool,
        "flac-assertions",
        "Keep libFLAC's internal assertions and debug output enabled",
    ) orelse (optimize == .debug);

    // libFLAC calls log() and lround() from the encoder's entropy model.
    // Windows keeps them in the CRT; there is no separate libm to name.
    const link_libm = b.option(
        bool,
        "flac-libm",
        "Link libm (needed by the encoder's entropy estimation)",
    );

    const link_libc = b.option(
        bool,
        "flac-libc",
        "Link a C standard library; the vendored libFLAC sources need stdio/stdlib/math headers",
    );

    // Only libFLAC's file-based init functions use fseeko(), which the bindings
    // never call, but the code still has to compile. A libc without fseeko()
    // (some newlib configurations) needs the fallback in share/compat.h.
    const fseeko = b.option(
        bool,
        "flac-fseeko",
        "Assume the C library provides fseeko()/ftello() (turn off for a libc that lacks them)",
    ) orelse true;

    // libFLAC gates its debug prints under the same NDEBUG as its assertions,
    // so a quiet test run costs the assertions. They stay on by default: for a
    // C-FFI wrapper the assertion build is the one most likely to catch
    // handle-state misuse. Turn this off in CI to get a run without the
    // spurious `failed command:` block that ziglang/zig#35202 prints whenever a
    // test binary writes anything to stderr.
    const test_assertions = b.option(
        bool,
        "test-flac-assertions",
        "Keep libFLAC's assertions in the test build; off gives quieter test output",
    ) orelse assertions;

    const base = Config{
        .target = target,
        .optimize = optimize,
        .assertions = assertions,
        .alloc_hooks = alloc_hooks,
        .use_system = use_system,
        .fseeko = fseeko,
        .link_libm = link_libm orelse (hosted and target.result.os.tag != .windows),
        .link_libc = link_libc orelse hosted,
    };

    // The C bindings are generated once per build by the translate-c
    // package from src/flac/flac.h and shared by every module (see
    // src/flac/c.zig).  They track the same target, optimize mode and libc
    // setting as the library; only the assertion state differs between the
    // public and the private test module, and the headers do not see it.
    // When linking a system libFLAC the headers come from that library
    // instead of the vendored copy, so the bindings cannot skew from it.
    const translate_c = b.dependency("translate_c", .{});
    const Translator = @import("translate_c").Translator;
    const bindings: Translator = .init(translate_c, .{
        .name = "flac_c",
        .c_source_file = b.path("src/flac/flac.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = base.link_libc,
        .link_system_libs = if (base.use_system) &.{.{ .name = "FLAC" }} else &.{},
    });
    if (!base.use_system) bindings.addIncludePath(b.path("vendor/flac/include"));

    // Exposed to dependents as `b.dependency("zflac", ...).module("zflac")`.
    const flac = flacModule(b, "zflac", base, bindings.mod);

    // `zig build` produces a static library that already contains libFLAC.
    const lib = b.addLibrary(.{ .name = "zflac", .root_module = flac });
    b.installArtifact(lib);

    // ---------------------------------------------------------------- tests
    if (!hosted) return;

    const test_flac = if (test_assertions == assertions)
        flac
    else blk: {
        var cfg = base;
        cfg.assertions = test_assertions;
        break :blk flacModule(b, null, cfg, bindings.mod);
    };

    const test_module = makeModule(b, test_flac, "tests/tests.zig", target, optimize);
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // -------------------------------------------------------------- examples
    const example = b.addExecutable(.{
        .name = "roundtrip",
        .root_module = makeModule(b, flac, "examples/roundtrip.zig", target, optimize),
    });
    b.installArtifact(example);
    b.step("example", "Run the encode/decode round trip").dependOn(&b.addRunArtifact(example).step);

    const memstats = b.addExecutable(.{
        .name = "memstats",
        .root_module = makeModule(b, flac, "examples/memstats.zig", target, optimize),
    });
    b.step("memstats", "Report libFLAC's heap usage per configuration").dependOn(&b.addRunArtifact(memstats).step);

    // A wav <-> flac converter; `zig build` puts it in zig-out/bin.
    const convert = b.addExecutable(.{
        .name = "convert",
        .root_module = makeModule(b, flac, "examples/convert.zig", target, optimize),
    });
    b.installArtifact(convert);

    // The README's Quick Start; compiling it keeps the README honest.
    const quickstart = b.addExecutable(.{
        .name = "quickstart",
        .root_module = makeModule(b, flac, "examples/quickstart.zig", target, optimize),
    });
    b.step("quickstart", "Run the README Quick Start").dependOn(&b.addRunArtifact(quickstart).step);
}

/// Builds the `zflac` module: the Zig surface plus the compiled libFLAC.
/// `name` is `null` for a private copy, used when the test step wants a
/// different assertion setting than the shipped module.  `flac_c` is the
/// shared translate-c bindings module (see `build`).
fn flacModule(
    b: *std.Build,
    name: ?[]const u8,
    cfg: Config,
    flac_c: *std.Build.Module,
) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "alloc_hooks", cfg.alloc_hooks);
    options.addOption(bool, "system_library", cfg.use_system);

    const create: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/flac.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,
        .link_libc = cfg.link_libc,
    };
    const m = if (name) |n| b.addModule(n, create) else b.createModule(create);
    m.addOptions("config", options);
    m.addImport("flac_c", flac_c);

    // With `-Dflac-system` the system libFLAC is already linked: the shared
    // bindings module links it, and the link propagates through the import
    // above.  Only the vendored sources need adding here.
    if (!cfg.use_system) {
        m.addIncludePath(b.path("vendor/flac"));
        m.addIncludePath(b.path("vendor/flac/include"));
        m.addIncludePath(b.path("vendor/flac/src/libFLAC/include"));

        m.addCMacro("HAVE_CONFIG_H", "1");
        m.addCMacro("FLAC__NO_DLL", "1");
        // The SIMD kernels are not part of the vendored subset.
        m.addCMacro("FLAC__NO_ASM", "1");
        if (!cfg.assertions) m.addCMacro("NDEBUG", "1");
        if (!cfg.fseeko) m.addCMacro("FLAC__NO_FSEEKO", "1");

        // libFLAC calls malloc() directly, so the only portable way to keep it
        // inside an embedded budget is to rename the allocator at compile time.
        // The replacements live in src/flac/alloc.zig.
        if (cfg.alloc_hooks) {
            m.addCMacro("malloc", "zflac_malloc");
            m.addCMacro("calloc", "zflac_calloc");
            m.addCMacro("realloc", "zflac_realloc");
            m.addCMacro("free", "zflac_free");
        }

        m.addCSourceFiles(.{
            .root = b.path("vendor/flac"),
            .files = &c_sources,
            .flags = &.{ "-std=gnu99", "-fno-strict-aliasing" },
        });
        if (cfg.target.result.os.tag == .windows) m.addCSourceFiles(.{
            .root = b.path("vendor/flac"),
            .files = &win_sources,
            .flags = &.{ "-std=gnu99", "-fno-strict-aliasing" },
        });
    }

    if (cfg.link_libm) m.linkSystemLibrary("m", .{});
    return m;
}

/// A test or example module that can `@import("zflac")`.
fn makeModule(
    b: *std.Build,
    flac: *std.Build.Module,
    comptime file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(file),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zflac", .module = flac }},
    });
}
