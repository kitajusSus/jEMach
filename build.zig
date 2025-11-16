const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Install dependencies step
    const install_deps_step = b.step("install-deps", "Install dependencies using bun");
    const install_cmd = b.addSystemCommand(&[_][]const u8{
        "bun",
        "install",
    });
    install_deps_step.dependOn(&install_cmd.step);

    const build_ts_step = b.step("build-ts", "Build TypeScript utilities using bun");
    const build_ts_cmd = b.addSystemCommand(&[_][]const u8{
        "bun",
        "run",
        "build",
    });
    build_ts_step.dependOn(&build_ts_cmd.step);

    // Build C++ native module (preferred, compiled with zig c++)
    const build_cpp_step = b.step("build-cpp", "Build C++ native module using zig c++");
    const build_cpp_cmd = b.addSystemCommand(&[_][]const u8{
        "sh",
        "-c",
        "cd native && make clean && make install",
    });
    build_cpp_step.dependOn(&build_cpp_cmd.step);

    // Build Zig native module (alternative, pure Zig implementation)
    const build_native_step = b.step("build-native", "Build Zig native module");
    const native_lib = b.addLibrary(.{
        .name = "jemach_julia_native",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(native_lib);
    build_native_step.dependOn(&native_lib.step);

    const test_native_step = b.step("test-native", "Run native module tests");
    const native_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_native_tests = b.addRunArtifact(native_tests);
    test_native_step.dependOn(&run_native_tests.step);

    const test_ts_step = b.step("test-ts", "Run TypeScript tests");
    const test_ts_cmd = b.addSystemCommand(&[_][]const u8{
        "bun",
        "run",
        "lint",
    });
    test_ts_step.dependOn(&test_ts_cmd.step);

    // Combined test step
    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(test_ts_step);
    test_all_step.dependOn(test_native_step);

    // Clean step
    const clean_all_step = b.step("clean-all", "Clean build artifacts");
    const clean_cmd = b.addSystemCommand(&[_][]const u8{
        "sh",
        "-c",
        "rm -rf node_modules dist zig-out zig-cache zig/zig-cache zig/zig-out .zig-cache lib native/build",
    });
    clean_all_step.dependOn(&clean_cmd.step);

    // Development mode step
    const dev_step = b.step("dev", "Start TypeScript watch mode");
    const dev_cmd = b.addSystemCommand(&[_][]const u8{
        "bun",
        "run",
        "dev",
    });
    dev_step.dependOn(&dev_cmd.step);

    const build_all_step = b.step("build-all", "Install dependencies and build everything");
    build_all_step.dependOn(install_deps_step);
    build_all_step.dependOn(build_ts_step);
    build_all_step.dependOn(build_cpp_step);

    b.default_step.dependOn(build_all_step);
}
