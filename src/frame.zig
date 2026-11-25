//! Per-frame work: drain PTYs, honor mode 2026 (hold the frame while the
//! child repaints atomically), paint the background, tab bar, selection
//! highlight and the focused grid's glyphs, and account the frame.
const std = @import("std");
const term = @import("term");
const app_mod = @import("app.zig");
const bench = @import("bench.zig");
const select = @import("select.zig");
const input_mod = @import("input.zig");
const util = @import("util.zig");

const runtime = term.runtime;
const render = term.render;
const pty_mod = term.pty;

const App = app_mod.App;

const BAR_HEIGHT: f32 = 34;
const GRID_Y: f32 = BAR_HEIGHT + 4;

pub fn onFrame(app: *App, rt: *runtime.Runtime) !void {
    const t0 = pty_mod.nowNs();
    app.drainPanes();

    // Synchronized output (mode 2026): hold the frame while the child
    // repaints atomically; force-release after 2s if it never closes.
    if (app.focusGrid()) |g| {
        if (g.sync_output) {
            if (g.sync_since_ns != 0 and t0 - g.sync_since_ns > 2_000_000_000) {
                g.sync_output = false;
            } else {
                bench.noteFrame(app, t0);
                return;
            }
        }
    }
    if (app.panes.items.len == 0) rt.requestQuit();
    if (rt.atlas == null) {
        bench.noteFrame(app, t0);
        return;
    }
    const atlas = rt.atlas.?;
    const cm = render.cellMetrics(atlas);
    const theme = render.THEMES[app.theme_idx % render.THEMES.len];

    var n: usize = 0;
    // full-window background (theme)
    app.quads[0] = .{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(rt.width),
        .h = @floatFromInt(rt.height),
        .u0 = 0,
        .v0 = 0,
        .u1 = 0,
        .v1 = 0,
        .color = runtime.rgba01(theme.bg),
    };
    n = 1;

    try chrome(app, rt, theme);

    // selection highlight (under the glyphs)
    if (app.sel_active) n = select.emitHighlightQuads(app, app.quads, n, GRID_Y, cm.w, cm.h, theme);

    const focused_grid = app.focusGrid() orelse {
        bench.noteFrame(app, t0);
        return;
    };
    n = try render.renderGridT(atlas, focused_grid, app.quads, n, 0, GRID_Y, cm.w, cm.h, theme);
    rt.extra_quads = app.quads[0..n];
    bench.noteFrame(app, t0);
}

/// Tab bar (pane chips, theme cycler, new-pane button) + status bar (RSS,
/// bytes consumed, pane count) + right-click context menu. Framework UI
/// widgets; paints into the same quad stream as everything else.
fn chrome(app: *App, rt: *runtime.Runtime, theme: anytype) !void {
    const u = rt.ui() orelse return;
    const pn = @min(app.panes.items.len, 32);
    try u.panel(.{ .fixed = @floatFromInt(rt.width) }, .{ .fixed = BAR_HEIGHT }, 6, 4);
    u.current().dir = .row;
    var i: usize = 0;
    while (i < pn) : (i += 1) {
        var tbuf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tbuf, "pane {d}", .{app.panes.items[i].id}) catch "pane";
        if (try u.button(s)) {
            if (i != app.focused) app.focused = i;
        }
    }
    var tbuf: [64]u8 = undefined;
    const ts = std.fmt.bufPrint(&tbuf, "theme: {s}", .{theme.name}) catch "theme";
    if (try u.button(ts)) app.theme_idx +%= 1;
    if (try u.button("+")) app.spawnShell() catch {};
    var sbuf: [160]u8 = undefined;
    const alive_count = blk: {
        var a: usize = 0;
        for (app.panes.items) |p| {
            if (p.alive) a += 1;
        }
        break :blk a;
    };
    const ss = std.fmt.bufPrint(&sbuf, "rss {d} MB  in {d} KB  {d}/{d} panes", .{ util.rssKb() / 1024, app.bytes_in / 1024, alive_count, app.panes.items.len }) catch "rss";
    try u.label(ss, term.ui.COLOR_TEXT_DIM);
    u.endPanel();

    // context menu: right-click anywhere; declared last so it paints on top
    const menu_anchor = term.layout.Rect{ .x = 0, .y = 0, .w = @floatFromInt(rt.width), .h = @floatFromInt(rt.height) };
    const items = [_]term.widgets.MenuItem{
        .{ .label = "Copy" },
        .{ .label = "Paste" },
        .{ .label = "New pane" },
        .{ .label = "Close pane" },
    };
    if (try term.widgets.contextMenu(u, menu_anchor, &items)) |choice| {
        switch (choice) {
            0 => select.copySelection(app, rt),
            1 => if (rt.clipboard_text) |t| input_mod.handlePasteText(app, t),
            2 => app.spawnShell() catch {},
            3 => {
                app.closeFocusedPane();
                if (app.panes.items.len == 0) rt.requestQuit();
            },
            else => {},
        }
    }
}
