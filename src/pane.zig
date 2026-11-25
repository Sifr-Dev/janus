//! A Janus pane: one PTY child, one VT parser, one cell grid. Panes live
//! in-process — Janus is the terminal; the multiplexer is a feature, not a
//! second daemon. Pane lifecycle is owned by `app.App`; this module owns what
//! a pane *is* and how it talks to its child.
const std = @import("std");
const term = @import("term");

const grid_mod = term.grid;
const pty_mod = term.pty;
const vt = term.vt;

pub const Pane = struct {
    id: u32,
    pty: pty_mod.Pty,
    parser: vt.Parser = .{},
    grid: grid_mod.Grid,
    alive: bool = true,

    /// Spawn `cmd` on a fresh PTY sized `cols`x`rows`.
    pub fn spawn(alloc: std.mem.Allocator, id: u32, cmd: []const []const u8, cols: u32, rows: u32) !Pane {
        var p: Pane = undefined;
        p.id = id;
        p.pty = try pty_mod.Pty.spawn(alloc, cmd, .{ .cols = cols, .rows = rows });
        errdefer p.pty.deinit();
        p.parser = .{};
        p.grid = try grid_mod.Grid.init(alloc, cols, rows);
        errdefer p.grid.deinit();
        p.alive = true;
        return p;
    }

    /// SIGHUP to the foreground process group and release the grid.
    pub fn deinit(self: *Pane) void {
        self.pty.deinit();
        self.grid.deinit();
    }

    /// Feed child output into this pane's VT parser, then answer any
    /// progressive-enhancement queries the child issued (kitty keyboard
    /// flags, mode 2026 synchronized output).
    pub fn feed(self: *Pane, raw: []const u8) void {
        self.parser.feed(&self.grid, raw) catch return;
        if (self.parser.kbd_query) {
            self.parser.kbd_query = false;
            var buf: [32]u8 = undefined;
            const reply = std.fmt.bufPrint(&buf, "\x1b[?{d}u", .{self.grid.kbd_flags}) catch return;
            self.pty.write(reply) catch {};
        }
        if (self.parser.mode_2026_query) {
            self.parser.mode_2026_query = false;
            const ps: u32 = if (self.grid.sync_output) 1 else 2;
            var buf: [32]u8 = undefined;
            const reply = std.fmt.bufPrint(&buf, "\x1b[?2026;{d}$y", .{ps}) catch return;
            self.pty.write(reply) catch {};
        }
    }
};
