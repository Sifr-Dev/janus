//! Input translation: framework input events → Janus semantics. Kitty
//! keyboard protocol when the child enabled it, otherwise classic terminal
//! byte mapping. Owns shortcut handling (new pane, close pane, cycle, copy).
const std = @import("std");
const term = @import("term");
const app_mod = @import("app.zig");
const select = @import("select.zig");

const runtime = term.runtime;
const input = term.input;
const render = term.render;
const kitty = term.kitty;

const App = app_mod.App;

/// Paste text into the focused pane, honoring bracketed paste and the
/// file-drop convention (all-paths text is pasted bare).
pub fn handlePasteText(app: *App, text: []const u8) void {
    const pane = app.focusedPane() orelse return;
    var all_paths = text.len > 0 and text[0] == '/';
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(app.alloc);
    if (all_paths) {
        var it = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (it.next()) |ln| {
            const t = std.mem.trim(u8, ln, " \t\r");
            if (t.len == 0) continue;
            if (t[0] != '/') {
                all_paths = false;
                break;
            }
            if (!first) joined.append(app.alloc, ' ') catch {};
            joined.appendSlice(app.alloc, t) catch {};
            first = false;
        }
    }
    const target: []const u8 = if (all_paths and joined.items.len > 0) joined.items else text;
    if (pane.grid.bracketed_paste and !all_paths) {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(app.alloc);
        buf.appendSlice(app.alloc, "\x1b[200~") catch return;
        buf.appendSlice(app.alloc, target) catch return;
        buf.appendSlice(app.alloc, "\x1b[201~") catch return;
        pane.pty.write(buf.items) catch {};
    } else {
        pane.pty.write(target) catch {};
    }
}

fn onKey(app: *App, rt: *runtime.Runtime, k: input.KeyEvent) void {
    const pane = app.focusedPane() orelse return;
    // Kitty keyboard protocol: encoded keys when the child enabled it.
    if (pane.grid.kbd_flags != 0) {
        var buf: [48]u8 = undefined;
        if (kitty.encode(k, pane.grid.kbd_flags, &buf)) |n| {
            pane.pty.write(buf[0..n]) catch {};
            return;
        }
    }
    const g = &pane.grid;
    if (k.key == .esc) {
        if (!g.atBottom()) g.scrollToBottom() else rt.requestQuit();
        return;
    }
    if (k.mods.ctrl() and k.key == .printable and k.char != null) {
        const c = k.char.?;
        if (k.mods.shift() and (c == 'C' or c == 'c')) {
            select.copySelection(app, rt);
            return;
        }
        if (k.mods.shift() and (c == 'V' or c == 'v')) return; // paste arrives as .paste
        if (k.code == 20) { // ctrl+t — new pane
            app.spawnShell() catch {};
            return;
        }
        if (k.code == 17) { // ctrl+w — close pane
            app.closeFocusedPane();
            if (app.panes.items.len == 0) rt.requestQuit();
            return;
        }
        const b: u8 = @as(u8, @truncate(c | 0x20)) & 0x1f;
        const arr = [_]u8{b};
        pane.pty.write(arr[0..]) catch {};
        return;
    }
    switch (k.key) {
        .enter, .keypad_enter => pane.pty.write("\r") catch {},
        .backspace => pane.pty.write("\x7f") catch {},
        .tab => {
            if (k.mods.ctrl()) {
                app.cycleFocus(if (k.mods.shift()) -1 else 1);
            } else {
                pane.pty.write(if (k.mods.shift()) "\x1b[Z" else "\t") catch {};
            }
        },
        .up => pane.pty.write("\x1b[A") catch {},
        .down => pane.pty.write("\x1b[B") catch {},
        .right => pane.pty.write("\x1b[C") catch {},
        .left => pane.pty.write("\x1b[D") catch {},
        .home => pane.pty.write("\x1b[H") catch {},
        .end => pane.pty.write("\x1b[F") catch {},
        .page_up => pane.pty.write("\x1b[5~") catch {},
        .page_down => pane.pty.write("\x1b[6~") catch {},
        .insert => pane.pty.write("\x1b[2~") catch {},
        .delete => pane.pty.write("\x1b[3~") catch {},
        .printable => {
            if (k.char) |c| {
                var buf: [4]u8 = undefined;
                const n: usize = @intCast(std.unicode.utf8Encode(c, &buf) catch return);
                if (k.mods.alt()) {
                    var both: [5]u8 = undefined;
                    both[0] = 0x1b;
                    @memcpy(both[1..][0..n], buf[0..n]);
                    pane.pty.write(both[0 .. 1 + n]) catch {};
                } else {
                    pane.pty.write(buf[0..n]) catch {};
                }
            }
        },
        else => {},
    }
}

pub fn onEvent(app: *App, rt: *runtime.Runtime, ev: input.Event) void {
    switch (ev) {
        .key => |k| {
            if (k.pressed) onKey(app, rt, k);
        },
        .wheel => |w| {
            if (w.dy != 0) {
                var n: usize = @intFromFloat(@abs(w.dy));
                if (n == 0) n = 1;
                if (app.focusGrid()) |g| {
                    if (w.dy < 0) g.viewScrollUp(n) else g.viewScrollDown(n);
                }
            }
        },
        .mouse_button => |b| {
            if (b.button == 0x110) { // BTN_LEFT
                if (b.pressed) {
                    app.sel_active = true;
                    const c = select.cellAt(app, rt, rt.mouse_x, rt.mouse_y);
                    app.sel_x0 = c[0];
                    app.sel_y0 = c[1];
                    app.sel_x1 = c[0];
                    app.sel_y1 = c[1];
                } else {
                    if (app.sel_active) select.copySelection(app, rt);
                    app.sel_active = false;
                }
            }
        },
        .mouse_move => |m| {
            if (app.sel_active) {
                const c = select.cellAt(app, rt, m.x, m.y);
                app.sel_x1 = c[0];
                app.sel_y1 = c[1];
            }
        },
        .resize => |r| {
            // Reflow every pane; the child gets SIGWINCH via the PTY.
            const atlas = rt.atlas orelse return;
            const cm = render.cellMetrics(atlas);
            const cols = @max(@as(u32, 10), @as(u32, @intFromFloat(@as(f32, @floatFromInt(r.w)) / cm.w)));
            const rows = @max(@as(u32, 4), @as(u32, @intFromFloat(@as(f32, @floatFromInt(r.h)) / cm.h)));
            for (app.panes.items) |*p| {
                if (!p.alive) continue;
                p.pty.resize(cols, rows);
                p.grid.resize(app.alloc, cols, rows) catch continue;
            }
        },
        .paste => |text| handlePasteText(app, text),
        .close => rt.requestQuit(),
        .focus => {},
    }
}
