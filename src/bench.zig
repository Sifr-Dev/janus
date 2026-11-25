//! Frame accounting for both render paths (GPU WSI and software-shm).
const std = @import("std");
const app_mod = @import("app.zig");
const util = @import("util.zig");
const pty_mod = @import("term").pty;

pub const App = app_mod.App;

/// Constant-ish per-frame accounting windows (120).
const WINDOW: u64 = 120;

/// Record one frame; prints JANUS_BENCH every WINDOW frames.
pub fn noteFrame(app: *App, t0: i64) void {
    const dt: u64 = @intCast(pty_mod.nowNs() - t0);
    app.frames += 1;
    app.frame_ns += dt;
    app.win_frames += 1;
    app.win_ns += dt;
    if (app.win_frames >= WINDOW) {
        std.debug.print("JANUS_BENCH frames={d} avg_onframe_ms={d:.3} rss_kb={d} bytes_in={d}\n", .{ app.frames, @as(f64, @floatFromInt(app.win_ns)) / @as(f64, @floatFromInt(app.win_frames)) / 1e6, util.rssKb(), app.bytes_in });
        app.win_frames = 0;
        app.win_ns = 0;
    }
}
