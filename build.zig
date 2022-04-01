const std = @import("std");

const config_format =
    \\/*
    \\* Copyright (c) 2015 Andrew Kelley
    \\*
    \\* This file is part of libsoundio, which is MIT licensed.
    \\* See http://opensource.org/licenses/MIT
    \\*/
    \\
    \\ #ifndef SOUNDIO_CONFIG_H
    \\ #define SOUNDIO_CONFIG_H
    \\ 
    \\ #define SOUNDIO_VERSION_MAJOR {d}
    \\ #define SOUNDIO_VERSION_MINOR {d}
    \\ #define SOUNDIO_VERSION_PATCH {d}
    \\ #define SOUNDIO_VERSION_STRING "{d}.{d}.{d}"
    \\
;

const info_build = "Installation Summary\n" ++
    "--------------------\n" ++
    "* Install Directory            : {s}\n" ++
    "* Build Type                   : {s}\n" ++
    "* Build static libs            : {s}\n" ++
    "* Build examples               : {s}\n" ++
    "* Build tests                  : {s}\n" ++
    "System Dependencies\n" ++
    "-------------------\n" ++
    "* threads                      : {s}\n" ++
    "* JACK       (optional)        : {s}\n" ++
    "* PulseAudio (optional)        : {s}\n" ++
    "* ALSA       (optional)        : {s}\n" ++
    "* CoreAudio  (optional)        : {s}\n" ++
    "* WASAPI     (optional)        : {s}\n";

var soundio_cache_path: []const u8 = "";
pub var use_jack: bool = false;
pub var use_pulse: bool = false;
pub var use_alsa: bool = false;
pub var use_coreaudio: bool = false;
pub var use_wasapi: bool = false;
var has_run_link = false;
var version = std.builtin.Version{ .major = 2, .minor = 0, .patch = 0 };

/// Builds the soundio library on your own terms and installs it to your project directory.
/// It defaults to the ubication of this file, but you can specify a different project directory.
/// if it all fails, that shouldn't it will default to the relative path (".")
pub fn buildLib(b: *std.build.Builder, target: std.zig.CrossTarget, mode: std.builtin.Mode, is_shared: bool, is_static: bool, path_to_soundio: ?[]const u8) void {
    var path = path_to_soundio orelse std.fs.path.dirname(@src().file) orelse ".";
    if (is_shared) {
        const lib = b.addSharedLibrary("soundio", null, std.build.LibExeObjStep.SharedLibKind{ .versioned = version });
        linkLibSoundio(b, lib, path, target, mode);
        lib.install();
    }
    if (is_static) {
        const lib = b.addStaticLibrary("soundio", null);
        linkLibSoundio(b, lib, path, target, mode);
        lib.install();
    }
    var includeDir = b.pathJoin(&.{ path, "soundio" });
    defer b.allocator.free(includeDir);
    b.installDirectory(std.build.InstallDirectoryOptions{ .source_dir = includeDir, .install_dir = .header, .install_subdir = "soundio" });
}

/// Build file in case that it goes to the library repository.
pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const is_shared = b.option(bool, "build_shared", "Build shared libraries") orelse true;
    const is_static = b.option(bool, "build_static", "Build static libraries") orelse true;
    const have_examples = b.option(bool, "build_examples", "Build examples") orelse true;
    const have_tests = b.option(bool, "build_tests", "Build tests") orelse true;
    buildLib(b, target, mode, is_shared, is_static, null);
    if (have_examples) {
        const example_flags = getFlags(mode, true, false);
        const examples = [_][]const u8{ "sio_sine", "sio_microphone", "sio_record", "sio_list_devices" };
        inline for (examples) |example| {
            var ex = b.addExecutable(example, null);
            ex.addCSourceFile("example/" ++ example ++ ".c", example_flags);
            ex.linkLibC();
            ex.addLibraryPath(b.lib_dir);
            ex.addIncludePath(b.h_dir);
            linkDependencies(ex, target);
            ex.linkSystemLibrary("soundio");
            if (target.abi) |abi| {
                if (abi != .msvc and std.mem.eql(u8, example, "sio_sine")) {
                    ex.linkSystemLibrary("m");
                }
            }
            ex.install();
        }
    }
    if (have_tests) {
        const test_flags = getFlags(mode, false, true);
        const tests = [_][]const u8{ "latency", "overflow", "underflow", "unit_tests", "backend_disconnect_recover" };
        inline for (tests) |ts| {
            var tst = b.addExecutable("test_" ++ ts, null);
            tst.addCSourceFile("test/" ++ ts ++ ".c", test_flags);
            tst.linkLibC();
            tst.addLibraryPath(b.lib_dir);
            tst.addIncludePath(b.h_dir);
            tst.addIncludePath("src");
            tst.addIncludePath(soundio_cache_path);
            linkDependencies(tst, target);
            tst.linkSystemLibrary("soundio");
            if (target.abi) |abi| {
                if (abi != .msvc and (std.mem.eql(u8, ts, "latency") or std.mem.eql(u8, ts, "underflow"))) {
                    tst.linkSystemLibrary("m");
                }
            }
            tst.install();
        }
        // TODO: Add coverage with lconv like the original build script does.
    }

    formatMessage(b, target, mode, is_static, have_tests, have_examples);
    b.allocator.free(soundio_cache_path);
}

/// makes all the build process for the library and binds it to the libExeObj you decide, this is more of an internal function but be free to use it.
pub fn linkLibSoundio(b: *std.build.Builder, libExeObj: *std.build.LibExeObjStep, path_to_lib: []const u8, target: std.zig.CrossTarget, mode: std.builtin.Mode) void {
    if (!has_run_link) {
        has_run_link = true;
        use_jack = b.option(bool, "enable_jack", "Use Jack for audio output") orelse if (target.isLinux()) true else false;
        use_pulse = b.option(bool, "enable_pulse", "Use PulseAudio for audio output") orelse if (target.isLinux()) true else false;
        use_alsa = b.option(bool, "enable_alsa", "Use ALSA for audio output") orelse false; // Bug in my pc
        use_coreaudio = b.option(bool, "enable_coreaudio", "Use CoreAudio for audio output") orelse if (target.isDarwin()) true else false;
        use_wasapi = b.option(bool, "enable_wasapi", "Use WASAPI for audio output") orelse if (target.isWindows()) true else false;
    }
    const flags = getFlags(mode,false,false);
    libExeObj.setTarget(target);
    libExeObj.setBuildMode(mode);
    libExeObj.linkLibC();
    var file_names = [_][]const u8{ "src/soundio.c", "src/util.c", "src/os.c", "src/dummy.c", "src/channel_layout.c", "src/ring_buffer.c" };
    for (file_names) |v| {
        var filename = b.pathJoin(&.{ path_to_lib, v });
        defer b.allocator.free(filename);
        libExeObj.addCSourceFile(filename, flags);
    }
    linkDependencies(libExeObj, target);
    if (target.isWindows()) {
        if (use_wasapi) {
            var filename = b.pathJoin(&.{ path_to_lib, "src/wasapi.c" });
            defer b.allocator.free(filename);
            libExeObj.addCSourceFile(filename, flags);
        }
    } else if (target.isLinux()) {
        if (use_alsa) {
            var filename = b.pathJoin(&.{ path_to_lib, "src/alsa.c" });
            defer b.allocator.free(filename);
            libExeObj.addCSourceFile(filename, flags);
        }
        if (use_jack) {
            var filename = b.pathJoin(&.{ path_to_lib, "src/jack.c" });
            defer b.allocator.free(filename);
            libExeObj.addCSourceFile(filename, flags);
        }
        if (use_pulse) {
            var filename = b.pathJoin(&.{ path_to_lib, "src/pulseaudio.c" });
            defer b.allocator.free(filename);
            libExeObj.addCSourceFile(filename, flags);
        }
    } else if (target.isDarwin()) {
        // TODO: Test this on mac
        if (use_coreaudio) {
            var filename = b.pathJoin(&.{ path_to_lib, "src/coreaudio.c" });
            defer b.allocator.free(filename);
            libExeObj.addCSourceFile(filename, flags);
        }
    } else @panic("Unsupported target");
    var src_include_dir = b.pathJoin(&.{ path_to_lib, "src" });
    defer b.allocator.free(src_include_dir);

    var hash = std.crypto.hash.blake2.Blake2b384.init(.{});

    hash.update("C9XVU4MxSDFZz2to");

    hash.update("soundio_cache");
    if (use_jack) {
        hash.update("jack");
    }
    if (use_pulse) {
        hash.update("pulse");
    }
    if (use_alsa) {
        hash.update("alsa");
    }
    if (use_coreaudio) {
        hash.update("coreaudio");
    }
    if (use_wasapi) {
        hash.update("wasapi");
    }
    var digest: [48]u8 = undefined;
    hash.final(&digest);
    var hash_basename: [64]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&hash_basename, &digest);
    soundio_cache_path = b.pathJoin(&.{ b.build_root, b.cache_root, "o", &hash_basename });
    _ = std.fs.openDirAbsolute(soundio_cache_path, .{}) catch {
        std.fs.makeDirAbsolute(soundio_cache_path) catch @panic("Could not create soundio cache directory");
    };
    configureConfigHeader(b, soundio_cache_path, version);
    libExeObj.addIncludePath(std.fs.path.dirname(@src().file) orelse ".");
    libExeObj.addIncludePath(src_include_dir);
    libExeObj.addIncludePath(soundio_cache_path);
}

/// Makes the config part happen, this install config.h to the chache directory.
fn configureConfigHeader(b: *std.build.Builder, install_path: []const u8, current_version: std.builtin.Version) void {
    var path_to_config = b.pathJoin(&.{ install_path, "config.h" });
    defer b.allocator.free(path_to_config);

    var file = std.fs.createFileAbsolute(path_to_config, .{}) catch @panic("Error creating config file");
    defer file.close();
    var writer = file.writer();
    writer.print(config_format, .{ current_version.major, current_version.minor, version.patch, current_version.major, current_version.minor, version.patch }) catch @panic("Error writing config file");
    if (use_jack) {
        writer.writeAll(" #define SOUNDIO_HAVE_JACK \n") catch @panic("Error writing config file");
    }
    if (use_alsa) {
        writer.writeAll(" #define SOUNDIO_HAVE_ALSA \n") catch @panic("Error writing config file");
    }
    if (use_pulse) {
        writer.writeAll(" #define SOUNDIO_HAVE_PULSEAUDIO \n") catch @panic("Error writing config file");
    }
    if (use_wasapi) {
        writer.writeAll(" #define SOUNDIO_HAVE_WASAPI \n") catch @panic("Error writing config file");
    }
    if (use_coreaudio) {
        writer.writeAll(" #define SOUNDIO_HAVE_COREAUDIO \n") catch @panic("Error writing config file");
    }

    writer.writeAll(" #endif\n") catch @panic("Error writing config file");
    b.installLibFile(path_to_config, "config.h");
}
/// Link dependencies for the library
pub fn linkDependencies(libExeObj: *std.build.LibExeObjStep, target: std.zig.CrossTarget) void {
    if (target.isWindows()) {
        //TODO: MSVC have dependencies here? 
        libExeObj.linkSystemLibrary("Threads");
        if (use_wasapi) {
            libExeObj.linkSystemLibrary("ole32");
        }
    } else if (target.isLinux()) {
        libExeObj.linkSystemLibrary("pthread");
        if (use_alsa) {
            libExeObj.linkSystemLibrary("alsa");
        }
        if (use_jack) {
            libExeObj.linkSystemLibrary("jack");
        }
        if (use_pulse) {
            libExeObj.linkSystemLibrary("libpulse");
        }
    } else if (target.isDarwin()) {
        // TODO: Test this on mac
        libExeObj.linkSystemLibrary("pthread");
        if (use_coreaudio) {
            libExeObj.linkFramework("CoreAudio");
        }
    }
}
/// Defines some macros that could fail to be there. This is just a safety measure.
pub fn translateCHelper(step: *std.build.TranslateCStep) void {
    if (!has_run_link) @panic("You must run link before translateC");
    if (use_alsa) {
        step.defineCMacro("SOUNDIO_HAVE_ALSA", null);
    }
    if (use_jack) {
        step.defineCMacro("SOUNDIO_HAVE_JACK", null);
    }
    if (use_pulse) {
        step.defineCMacro("SOUNDIO_HAVE_PULSEAUDIO", null);
    }
    if (use_wasapi) {
        step.defineCMacro("SOUNDIO_HAVE_WASAPI", null);
    }
    if (use_coreaudio) {
        step.defineCMacro("SOUNDIO_HAVE_COREAUDIO", null);
    }
}
/// The same message on the CMAKE but this time we do this after build, weird right
fn formatMessage(b: *std.build.Builder, target: std.zig.CrossTarget, mode: std.builtin.Mode, is_static: bool, build_test: bool, build_example: bool) void {
    if (!has_run_link) @panic("You must run link before formatMessage");
    var triple = target.zigTriple(b.allocator) catch @panic("Error getting target triple");
    defer b.allocator.free(triple);
    std.log.info("Build Target is {s}", .{triple});
    var mode_str = @tagName(mode);
    var static = if (is_static) "ON" else "OFF";
    var example = if (build_example) "ON" else "OFF";
    var btest = if (build_test) "ON" else "OFF";
    var jack = if (use_jack) "OK" else "not set";
    var pulse = if (use_pulse) "OK" else "not set";
    var alsa = if (use_alsa) "OK" else "not set";
    var coreaudio = if (use_coreaudio) "OK" else "not set";
    var wasapi = if (use_wasapi) "OK" else "not set";
    std.log.info(info_build, .{ b.install_path, mode_str, static, example, btest, "OK", jack, pulse, alsa, coreaudio, wasapi });
}

fn getFlags(mode: std.builtin.Mode, is_example: bool, is_test: bool) [][]const u8 {
    comptime var flags = [_][]const u8{ "-std=c11", "-fvisibility=hidden", "-Wall", "-Werror=strict-prototypes", "-Werror=old-style-definition", "-Werror=missing-prototypes", "-D_REENTRANT", "-D_POSIX_C_SOURCE=200809L", "-Wno-missing-braces" };
    if (mode == .Debug) {
        comptime var flags_debug = flags ++ [_][]const u8{ "-pedantic", "-Werror" };
        comptime var flags_example = flags_debug ++ [_][]const u8{ "-std=c99", "-Wall" };
            // TODO: See why this fails
        comptime var flags_test = flags_debug ;// ++ [_][]const u8{ "-fprofile-arcs", "-ftest-coverage"};
        if (is_example) {
            return &flags_example;
        } else if (is_test) {
            return &flags_test;
        } else {
            return &flags_debug;
        }
    }
    comptime var flags_example = flags ++ [_][]const u8{ "-std=c99", "-Wall" };
    // TODO: See why this fails
    comptime var flags_test = flags ;// ++ [_][]const u8{ "-fprofile-arcs", "-ftest-coverage"};
    if (is_example) {
        return &flags_example;
    } else if (is_test) {
        return &flags_test;
    } else {
        return &flags;
    }
}
