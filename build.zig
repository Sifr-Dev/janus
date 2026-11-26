const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const framework = b.option([]const u8, "cipher-root", "Cipher framework checkout") orelse "../Cipher";

    const term = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.fmt("{s}/src/term_api.zig", .{framework}) },
        .target = target,
        .optimize = optimize,
    });
    term.link_libc = true;
    term.addAnonymousImport("resources", .{
        .root_source_file = .{ .cwd_relative = b.fmt("{s}/resources.zig", .{framework}) },
    });

    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app.link_libc = true;
    app.addImport("term", term);
    const exe = b.addExecutable(.{ .name = "janus", .root_module = app });
    b.installArtifact(exe);

    const dist = b.step("dist", "Create the standalone release directory");
    const install_dist = b.addInstallBinFile(exe.getEmittedBin(), "janus");
    dist.dependOn(&install_dist.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run Janus").dependOn(&run.step);

    const tests = b.addTest(.{
        .name = "janus-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/app_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run Janus application and input tests");
    const run_tests = b.addRunArtifact(tests);
    tests.root_module.addImport("term", term);
    tests.root_module.addImport("janus-app", b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "term", .module = term }},
    }));
    test_step.dependOn(&run_tests.step);

    // Input-to-PTY fidelity suite: pure key translation plus real-PTY
    // assertions about the exact bytes a child receives.
    const input_tests = b.addTest(.{
        .name = "janus-input-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/input_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_input_tests = b.addRunArtifact(input_tests);
    input_tests.root_module.addImport("term", term);
    input_tests.root_module.addImport("janus-app", b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "term", .module = term }},
    }));
    test_step.dependOn(&run_input_tests.step);
}
