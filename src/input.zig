//! Input translation: framework input events → Janus semantics. Kitty
//! keyboard protocol when the child enabled it, otherwise classic terminal
//! byte mapping. Owns shortcut handling (new pane, close pane, cycle, copy).
//!
//! Esc is deliberately *not* an application chord: it is forwarded to the
//! focused child as 0x1b in legacy mode and encoded per the kitty protocol
//! when the child enabled it. Vim, less, and readline depend on that byte.
//! Janus-level actions use modifier-gated chords instead:
//!   Ctrl+Shift+Q         quit Janus          (was: plain Esc at the bottom)
//!   Ctrl+Shift+End       jump to live output (was: plain Esc when scrolled)
//!   Ctrl+T               new pane
//!   Ctrl+W               close pane
//!   Ctrl+Tab             cycle panes (Ctrl+Shift+Tab reverses)
//!   Ctrl+Shift+C         copy selection
//!   Ctrl+Shift+V         paste (arrives as a `.paste` event)
//! Plain Esc, arrows, Home/End, Backspace, printable and Alt+key always reach
//! the child; the wheel owns scrollback.
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

/// What one key event means, with no side effects attached. Keeping the
/// translation pure makes input-to-PTY behavior testable without a Wayland
/// runtime: a test asserts the bytes and can feed them to a real child.
/// A `forward` slice is either a string literal or a slice of the caller's
/// scratch buffer passed to `translateKey`.
pub const KeyAction = union(enum) {
    /// Nothing to do (modifier press, unsupported key, swallowed chord).
    none,
    /// Bytes to write to the focused pane's PTY.
    forward: []const u8,
    copy_selection,
    spawn_pane,
    close_pane,
    cycle_focus: i8,
    scroll_to_bottom,
    request_quit,
};

fn isCtrlShiftQ(k: input.KeyEvent) bool {
    return k.mods.ctrl() and k.mods.shift() and k.key == .printable and k.char != null and
        (k.char.? == 'Q' or k.char.? == 'q');
}

fn isJumpToLive(k: input.KeyEvent) bool {
    return k.mods.ctrl() and k.mods.shift() and k.key == .end;
}

/// Translate one key event for the focused pane. Kitty-encoded bytes are
/// written into `out`; the returned action may slice `out`.
pub fn translateKey(app: *App, k: input.KeyEvent, out: []u8) KeyAction {
    // Reserved Janus chords, checked first so they work with or without a
    // pane and even while the child has enabled kitty keyboard enhancement.
    // Both are modifier-gated: nothing here can steal plain Esc.
    if (isCtrlShiftQ(k)) return .request_quit;
    if (isJumpToLive(k)) return .scroll_to_bottom;

    const pane = app.focusedPane() orelse return .none;
    const flags = pane.grid.kbd_flags;

    // Releases are meaningful only to a child that enabled kitty event types;
    // otherwise forwarding one would duplicate the press byte.
    if (!k.pressed and (flags & kitty.KBD_EVENT_TYPES) == 0) return .none;

    // Kitty keyboard protocol: encoded keys when the child enabled it.
    if (flags != 0) {
        if (kitty.encode(k, flags, out)) |n| return .{ .forward = out[0..n] };
    }
    if (!k.pressed) return .none;

    if (k.key == .esc) {
        // Alt+Esc is ESC ESC, the xterm convention; plain Esc is a bare ESC
        // so Vim/less see the key they expect.
        return .{ .forward = if (k.mods.alt()) "\x1b\x1b" else "\x1b" };
    }
    if (k.mods.ctrl() and k.key == .printable and k.char != null) {
        const c = k.char.?;
        if (k.mods.shift() and (c == 'C' or c == 'c')) return .copy_selection;
        if (k.mods.shift() and (c == 'V' or c == 'v')) return .none; // paste arrives as .paste
        if (k.code == 20) return .spawn_pane; // ctrl+t — new pane
        if (k.code == 17) return .close_pane; // ctrl+w — close pane
        const b: u8 = @as(u8, @truncate(c | 0x20)) & 0x1f;
        out[0] = b;
        return .{ .forward = out[0..1] };
    }
    switch (k.key) {
        .enter, .keypad_enter => return .{ .forward = "\r" },
        .backspace => return .{ .forward = "\x7f" },
        .tab => {
            if (k.mods.ctrl()) return .{ .cycle_focus = if (k.mods.shift()) -1 else 1 };
            return .{ .forward = if (k.mods.shift()) "\x1b[Z" else "\t" };
        },
        .up => return .{ .forward = "\x1b[A" },
        .down => return .{ .forward = "\x1b[B" },
        .right => return .{ .forward = "\x1b[C" },
        .left => return .{ .forward = "\x1b[D" },
        .home => return .{ .forward = "\x1b[H" },
        .end => return .{ .forward = "\x1b[F" },
        .page_up => return .{ .forward = "\x1b[5~" },
        .page_down => return .{ .forward = "\x1b[6~" },
        .insert => return .{ .forward = "\x1b[2~" },
        .delete => return .{ .forward = "\x1b[3~" },
        .printable => {
            if (k.char) |c| {
                if (k.mods.alt()) {
                    // Alt+key = ESC prefix + UTF-8 of the key.
                    out[0] = 0x1b;
                    const n: usize = @intCast(std.unicode.utf8Encode(c, out[1..]) catch return .none);
                    return .{ .forward = out[0 .. 1 + n] };
                }
                const n: usize = @intCast(std.unicode.utf8Encode(c, out) catch return .none);
                return .{ .forward = out[0..n] };
            }
            return .none;
        },
        else => return .none,
    }
}

/// Framework-level requests produced by an input event. `onEvent` performs
/// them; keeping them as data is what lets tests run the production
/// translation + PTY path with no Wayland runtime (`rt == null`).
pub const Outcome = struct {
    quit: bool = false,
};

fn applyAction(app: *App, rt: ?*runtime.Runtime, action: KeyAction) Outcome {
    switch (action) {
        .none => {},
        .forward => |bytes| {
            if (app.focusedPane()) |pane| pane.pty.write(bytes) catch {};
        },
        .copy_selection => if (rt) |r| select.copySelection(app, r),
        .spawn_pane => app.spawnShell() catch {},
        .close_pane => {
            app.closeFocusedPane();
            if (app.panes.items.len == 0) return .{ .quit = true };
        },
        .cycle_focus => |dir| app.cycleFocus(dir),
        .scroll_to_bottom => if (app.focusGrid()) |g| g.scrollToBottom(),
        .request_quit => return .{ .quit = true },
    }
    return .{};
}

/// Apply one key event to the app. Exposed so tests can drive the exact
/// production path (translation + PTY write) without a Wayland runtime.
/// `rt == null` means "no framework attached": clipboard and quit are then
/// only reported, never performed.
pub fn handleKey(app: *App, rt: ?*runtime.Runtime, k: input.KeyEvent) Outcome {
    var buf: [64]u8 = undefined;
    return applyAction(app, rt, translateKey(app, k, &buf));
}

pub fn onEvent(app: *App, rt: *runtime.Runtime, ev: input.Event) void {
    switch (ev) {
        .key => |k| {
            const outcome = handleKey(app, rt, k);
            if (outcome.quit) rt.requestQuit();
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
        .ime => {},
    }
}
