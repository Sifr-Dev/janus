//! Janus — the Cipher framework's GPU-native terminal. Not an xterm fork;
//! not a client to someone else's multiplexer daemon. Panes live in-process:
//! each pane spawns a PTY, owns a live VT parser and a cell grid, and is
//! rendered per vsync as GPU quads through the framework's extra_quads hook.
//! Zero runtime dependencies beyond the system Wayland loader and Vulkan.
//!
//!   janus [--shell /path/to/shell]
//!
//! Shortcuts: Ctrl+T new pane · Ctrl+Tab / Ctrl+Shift+Tab cycle · Ctrl+W close pane
//! · Ctrl+Shift+C copy · wheel scrollback · drag-select clipboard · paste/file-drop.
const std = @import("std");
const term = @import("term");

const runtime = term.runtime;
const gpu_text = term.gpu_text;

const app_mod = @import("app.zig");
const util = @import("util.zig");

const App = app_mod.App;

fn printHelp() void {
    const msg =
        \\janus — native terminal built with Cipher
        \\  janus [--shell /path/to/shell]
        \\
        \\Options:
        \\  --shell PATH   use PATH instead of $SHELL or /bin/sh
        \\  --help         show this help
        \\  --version      show the application version
        \\
        \\A Wayland compositor and a supported GPU or software renderer are
        \\required to run the terminal. No separate Cipher runtime is needed.
        \\
    ;
    _ = std.c.write(1, msg.ptr, msg.len);
}

fn printVersion() void {
    _ = std.c.write(1, "janus 0.1.0\n", 12);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;

    var shell: ?[]const u8 = null;
    const argv = init.args.vector;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "--shell")) {
            if (i + 1 >= argv.len) {
                std.debug.print("janus: --shell requires a path\n", .{});
                std.process.exit(2);
            }
            shell = std.mem.span(argv[i + 1]);
            i += 1;
        } else {
            std.debug.print("janus: unknown argument '{s}' (expected --shell <path>)\n", .{arg});
            std.process.exit(2);
        }
    }

    var app = App{
        .alloc = alloc,
        .quads = try alloc.alloc(gpu_text.Quad, app_mod.MAX_QUADS),
        .startup_shell = shell,
    };
    defer app.deinit();
    defer alloc.free(app.quads);

    try runtime.runWith(App, &app, .{
        .title = "janus",
        .app_id = "janus",
        .font_data = term.runtime.default_font_data,
        .fallback_font_paths = &.{},
        .ui_px = 18,
        .width = 1120,
        .height = 700,
    });
    std.debug.print("JANUS_EXIT frames={d} total_onframe_ms={d:.1} rss_kb={d} bytes_in={d}\n", .{ app.frames, @as(f64, @floatFromInt(app.frame_ns)) / 1e6, util.rssKb(), app.bytes_in });
}
