//! Application state and the pane list. Knows nothing about rendering or
//! input translation — those live in `frame.zig` and `input.zig` and reach
//! the state through this type.
const std = @import("std");
const term = @import("term");
const pane_mod = @import("pane.zig");
const input_mod = @import("input.zig");
const frame_mod = @import("frame.zig");
const util = @import("util.zig");

const runtime = term.runtime;
const input = term.input;
const gpu_text = term.gpu_text;
const grid_mod = term.grid;

pub const MAX_QUADS: usize = 65536;

pub const Pane = pane_mod.Pane;

pub const App = struct {
    alloc: std.mem.Allocator,
    panes: std.ArrayList(Pane) = .empty,
    focused: usize = 0,
    next_pane_id: u32 = 1,
    quads: []gpu_text.Quad = &.{},
    sel_active: bool = false,
    sel_x0: i32 = 0,
    sel_y0: i32 = 0,
    sel_x1: i32 = 0,
    sel_y1: i32 = 0,
    theme_idx: usize = 0,
    frames: u64 = 0,
    frame_ns: u64 = 0,
    win_frames: u32 = 0,
    win_ns: u64 = 0,
    bytes_in: u64 = 0,
    /// Fallback geometry before the first window-configured resize settles;
    /// replaced as soon as onEvent computes cells from font metrics.
    first_cols: u32 = 100,
    first_rows: u32 = 30,
    /// Shell for the first pane; $SHELL when null.
    startup_shell: ?[]const u8 = null,

    pub fn deinit(self: *App) void {
        for (self.panes.items) |*p| p.deinit();
        self.panes.deinit(self.alloc);
    }

    pub fn focusGrid(self: *App) ?*grid_mod.Grid {
        if (self.panes.items.len == 0) return null;
        return &self.panes.items[self.focused].grid;
    }

    pub fn focusedPane(self: *App) ?*Pane {
        if (self.panes.items.len == 0) return null;
        return &self.panes.items[self.focused];
    }

    /// Fallback geometry used only before the window reports its real size.
    fn cellGeometry(self: *const App) [2]u32 {
        if (self.panes.items.len == 0) return .{ self.first_cols, self.first_rows };
        return .{ self.panes.items[0].grid.cols, self.panes.items[0].grid.rows };
    }

    pub fn spawnPane(self: *App, cmd: []const []const u8) !void {
        const cr = self.cellGeometry();
        const p = try Pane.spawn(self.alloc, self.next_pane_id, cmd, cr[0], cr[1]);
        self.next_pane_id += 1;
        try self.panes.append(self.alloc, p);
        self.focused = self.panes.items.len - 1;
        std.debug.print("JANUS_PANE_SPAWN id={d} cmd={s} cols={d} rows={d}\n", .{ p.id, cmd[0], cr[0], cr[1] });
    }

    pub fn spawnShell(self: *App) !void {
        const shell = self.startup_shell orelse util.defaultShell();
        try self.spawnPane(&[_][]const u8{shell});
    }

    pub fn closePaneAt(self: *App, idx: usize) void {
        if (idx >= self.panes.items.len) return;
        var p = self.panes.orderedRemove(idx);
        p.deinit(); // SIGHUP to the foreground process group
        if (self.focused > idx) {
            self.focused -= 1;
        } else if (self.panes.items.len == 0 or self.focused >= self.panes.items.len) {
            self.focused = if (self.panes.items.len == 0) 0 else self.panes.items.len - 1;
        }
        std.debug.print("JANUS_PANE_CLOSED left={d}\n", .{self.panes.items.len});
    }

    pub fn closeFocusedPane(self: *App) void {
        if (self.panes.items.len == 0) return;
        self.closePaneAt(self.focused);
    }

    pub fn cycleFocus(self: *App, dir: i64) void {
        if (self.panes.items.len == 0) return;
        const n: i64 = @intCast(self.panes.items.len);
        const next = @mod(@as(i64, @intCast(self.focused)) + dir, n);
        self.focused = @intCast(next);
    }

    /// Drain every pane's PTY into its VT parser, answering the child's
    /// progressive-enhancement queries.
    pub fn drainPanes(self: *App) void {
        var i: usize = 0;
        while (i < self.panes.items.len) : (i += 1) {
            const p = &self.panes.items[i];
            if (!p.alive) continue;
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = p.pty.read(&buf) catch |e| switch (e) {
                    error.WouldBlock => break,
                    else => {
                        p.alive = false;
                        std.debug.print("JANUS_PANE_EXIT pane={d} err={s}\n", .{ p.id, @errorName(e) });
                        break;
                    },
                };
                if (n == 0) { // child closed the pty
                    p.alive = false;
                    std.debug.print("JANUS_PANE_EXIT pane={d} status=closed\n", .{p.id});
                    break;
                }
                self.bytes_in += n;
                p.feed(buf[0..n]);
            }
        }
    }

    /// Framework entry points: kept thin and wired straight to the concern
    /// modules, so `runWith(App, ...)` stays the only coupling to the
    /// framework's dispatch.
    pub fn onInit(self: *App, rt: *runtime.Runtime) !void {
        _ = rt;
        if (self.panes.items.len == 0) try self.spawnShell();
    }

    pub fn onEvent(self: *App, rt: *runtime.Runtime, ev: input.Event) void {
        input_mod.onEvent(self, rt, ev);
    }

    pub fn onFrame(self: *App, rt: *runtime.Runtime) !void {
        try frame_mod.onFrame(self, rt);
    }
};
