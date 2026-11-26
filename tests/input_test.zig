//! Input-to-PTY fidelity tests.
//!
//! Two layers:
//!   1. `input.translateKey` / `input.handleKey` unit tests: the production
//!      translation is pure, so its result is asserted directly.
//!   2. A real-PTY integration harness: a child (`od -An -tx1 -w1` after
//!      `stty raw -echo`) prints the exact bytes it received, and the test
//!      drives the same `handleKey` path the running terminal uses. These
//!      tests need no Wayland compositor, GPU, or Cipher runtime.
const std = @import("std");
const term = @import("term");
const app_mod = @import("janus-app");

const App = app_mod.App;
const input = app_mod.input_translation;
const KeyEvent = term.input.KeyEvent;
const KeyAction = input.KeyAction;

fn testApp(allocator: std.mem.Allocator) App {
    return .{ .alloc = allocator };
}

fn key(k: term.input.Key, mods_raw: u32, ch: ?u21, code: u32) KeyEvent {
    return .{ .code = code, .key = k, .char = ch, .mods = .{ .raw = mods_raw }, .pressed = true };
}

const CTRL: u32 = 0x4;
const SHIFT: u32 = 0x1;
const ALT: u32 = 0x8;

fn expectForward(action: KeyAction, expected: []const u8) !void {
    switch (action) {
        .forward => |bytes| try std.testing.expectEqualStrings(expected, bytes),
        else => return error.ExpectedForward,
    }
}

// ---- layer 1: pure translation ----

test "plain Esc forwards 0x1b to the child instead of quitting or scrolling" {
    var app = testApp(std.testing.allocator);
    defer app.deinit();
    try app.spawnPane(&.{"/bin/sh"});

    var buf: [64]u8 = undefined;
    const action = input.translateKey(&app, key(.esc, 0, null, 1), &buf);
    try expectForward(action, "\x1b");
}

test "Esc still forwards and never quits while the view is scrolled up" {
    var app = testApp(std.testing.allocator);
    defer app.deinit();
    try app.spawnPane(&.{"/bin/sh"});
    // Generate scrollback, then leave the viewport above the live tail.
    var i: usize = 0;
    while (i < 80) : (i += 1) app.panes.items[0].feed("scroll line\r\n");
    app.panes.items[0].grid.viewScrollUp(10);
    try std.testing.expect(!app.panes.items[0].grid.atBottom());

    var buf: [64]u8 = undefined;
    try expectForward(input.translateKey(&app, key(.esc, 0, null, 1), &buf), "\x1b");
    // Translation is side-effect free: the viewport did not jump.
    try std.testing.expect(!app.panes.items[0].grid.atBottom());
}

test "Alt+Esc forwards the xterm ESC ESC sequence" {
    var app = testApp(std.testing.allocator);
    defer app.deinit();
    try app.spawnPane(&.{"/bin/sh"});
    var buf: [64]u8 = undefined;
    try expectForward(input.translateKey(&app, key(.esc, ALT, null, 1), &buf), "\x1b\x1b");
}

test "Ctrl+Shift+Q is the documented quit chord and writes nothing to the child" {
    var app = testApp(std.testing.allocator);
    defer app.deinit();
    try app.spawnPane(&.{"/bin/sh"});
    var buf: [64]u8 = undefined;
    const action = input.translateKey(&app, key(.printable, CTRL | SHIFT, 'Q', 16), &buf);
    try std.testing.expect(action == .request_quit);
}

test "Ctrl+Shift+Q quits even when the child enabled kitty enhancement" {
    var app = testApp(std.testing.allocator);
    defer app.deinit();
    try app.spawnPane(&.{"/bin/sh"});
    app.panes.items[0].grid.kbd_flags = term.kitty.KBD_DISAMBIGUATE | term.kitty.KBD_REPORT_ALL_KEYS;
    var buf: [64]u8 = undefined;
    const action = input.translateKey(&app, key(.printable, CTRL | SHIFT, 'Q', 16), &buf);
    try std.testing.expect(action == .request_quit);
}

test "Ctrl+Shift+End replaces Esc as the jump-to-live shortcut" {
    var app = testApp(std.testing.allocator);
    defer app.deinit();
    try app.spawnPane(&.{"/bin/sh"});
    var buf: [64]u8 = undefined;
    const action = input.translateKey(&app, key(.end, CTRL | SHIFT, null, 107), &buf);
    try std.testing.expect(action == .scroll_to_bottom);
    // Plain End still belongs to the child.
    try expectForward(input.translateKey(&app, key(.end, 0, null, 107), &buf), "\x1b[F");
}

test "kitty-enabled child receives Esc as CSI 27u" {
    var app = testApp(std.testing.allocator);
    defer app.deinit();
    try app.spawnPane(&.{"/bin/sh"});
    app.panes.items[0].grid.kbd_flags = term.kitty.KBD_DISAMBIGUATE;
    var buf: [64]u8 = undefined;
    try expectForward(input.translateKey(&app, key(.esc, 0, null, 1), &buf), "\x1b[27u");
}

test "existing navigation and Ctrl shortcuts keep their bytes" {
    var app = testApp(std.testing.allocator);
    defer app.deinit();
    try app.spawnPane(&.{"/bin/sh"});
    var buf: [64]u8 = undefined;

    try expectForward(input.translateKey(&app, key(.up, 0, null, 103), &buf), "\x1b[A");
    try expectForward(input.translateKey(&app, key(.down, 0, null, 108), &buf), "\x1b[B");
    try expectForward(input.translateKey(&app, key(.left, 0, null, 105), &buf), "\x1b[D");
    try expectForward(input.translateKey(&app, key(.right, 0, null, 106), &buf), "\x1b[C");
    try expectForward(input.translateKey(&app, key(.home, 0, null, 102), &buf), "\x1b[H");
    try expectForward(input.translateKey(&app, key(.page_up, 0, null, 104), &buf), "\x1b[5~");
    try expectForward(input.translateKey(&app, key(.page_down, 0, null, 109), &buf), "\x1b[6~");
    try expectForward(input.translateKey(&app, key(.insert, 0, null, 110), &buf), "\x1b[2~");
    try expectForward(input.translateKey(&app, key(.delete, 0, null, 111), &buf), "\x1b[3~");
    try expectForward(input.translateKey(&app, key(.enter, 0, 0x0D, 28), &buf), "\r");
    try expectForward(input.translateKey(&app, key(.backspace, 0, 0x08, 14), &buf), "\x7f");
    try expectForward(input.translateKey(&app, key(.tab, 0, 0x09, 15), &buf), "\t");
    try expectForward(input.translateKey(&app, key(.tab, SHIFT, 0x09, 15), &buf), "\x1b[Z");
    try expectForward(input.translateKey(&app, key(.printable, 0, 'a', 30), &buf), "a");
    try expectForward(input.translateKey(&app, key(.printable, ALT, 'b', 48), &buf), "\x1bb");
    try expectForward(input.translateKey(&app, key(.printable, CTRL, 'c', 46), &buf), "\x03");

    // Application chords are not forwarded.
    try std.testing.expect(input.translateKey(&app, key(.printable, CTRL, 't', 20), &buf) == .spawn_pane);
    try std.testing.expect(input.translateKey(&app, key(.printable, CTRL, 'w', 17), &buf) == .close_pane);
    try std.testing.expect(input.translateKey(&app, key(.printable, CTRL | SHIFT, 'c', 46), &buf) == .copy_selection);
    try std.testing.expect(input.translateKey(&app, key(.printable, CTRL | SHIFT, 'v', 47), &buf) == .none);
    try std.testing.expectEqual(@as(i8, 1), input.translateKey(&app, key(.tab, CTRL, 0x09, 15), &buf).cycle_focus);
    try std.testing.expectEqual(@as(i8, -1), input.translateKey(&app, key(.tab, CTRL | SHIFT, 0x09, 15), &buf).cycle_focus);
}

test "key release without kitty event types is not forwarded twice" {
    var app = testApp(std.testing.allocator);
    defer app.deinit();
    try app.spawnPane(&.{"/bin/sh"});
    var buf: [64]u8 = undefined;
    var release = key(.printable, 0, 'a', 30);
    release.pressed = false;
    try std.testing.expect(input.translateKey(&app, release, &buf) == .none);
}

// ---- layer 2: real PTY child receives the bytes ----

/// A child that reports every raw byte it reads as one hex line.
/// `stty raw -echo` first, then announce READY so the test never races the
/// line discipline (ICANON would otherwise buffer a lone Esc).
const RECORDER_CMD = [_][]const u8{
    "/bin/sh",
    "-c",
    "stty raw -echo; printf 'READY\\n'; exec od -An -tx1 -v -w1",
};

fn waitForText(app: *App, needle: []const u8, timeout_ns: i64) !void {
    const deadline = term.pty.nowNs() + timeout_ns;
    while (term.pty.nowNs() < deadline) {
        app.drainPanes();
        const text = try app.panes.items[0].grid.captureText(app.alloc, false);
        defer app.alloc.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return;
        var delay = std.os.linux.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&delay, null);
    }
    return error.Timeout;
}

/// Drain until the child has emitted `want` hex pairs; returns what it saw.
fn collectHex(app: *App, want: usize, timeout_ns: i64) ![]u8 {
    var seen = std.ArrayList(u8).empty;
    errdefer seen.deinit(app.alloc);
    const deadline = term.pty.nowNs() + timeout_ns;
    while (term.pty.nowNs() < deadline) {
        app.drainPanes();
        // Include scrollback: a scrolled-up viewport must not hide the bytes
        // the child actually emitted.
        const text = try app.panes.items[0].grid.captureText(app.alloc, true);
        defer app.alloc.free(text);
        seen.clearRetainingCapacity();
        var it = std.mem.tokenizeAny(u8, text, " \r\n\t");
        while (it.next()) |tok| {
            if (tok.len == 2 and std.ascii.isHex(tok[0]) and std.ascii.isHex(tok[1])) {
                try seen.appendSlice(app.alloc, tok);
            }
        }
        if (seen.items.len >= want * 2) return try seen.toOwnedSlice(app.alloc);
        var delay = std.os.linux.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&delay, null);
    }
    return error.Timeout;
}

/// Spawn the recorder child, clear its READY banner, and return the app.
fn recorderApp(allocator: std.mem.Allocator) !App {
    var app = testApp(allocator);
    errdefer app.deinit();
    try app.spawnPane(&RECORDER_CMD);
    try waitForText(&app, "READY", 5 * std.time.ns_per_s);
    // Reset the grid so only the bytes under test remain, and make sure the
    // cursor starts clean for the next capture.
    try app.panes.items[0].grid.reset();
    return app;
}

/// Clear the recorder's grid so a capture contains only the next key's
/// bytes, then measure what the child printed. Without this, a capture would
/// also match hex lines emitted by earlier keys in the same test.
fn captureAfter(app: *App, ev: KeyEvent, want: usize) ![]u8 {
    try app.panes.items[0].grid.reset();
    return capturePreservingScroll(app, ev, want);
}

/// Same, but leaves scrollback and viewport position untouched so a test can
/// assert that a key caused no scroll side effect.
fn capturePreservingScroll(app: *App, ev: KeyEvent, want: usize) ![]u8 {
    const outcome = input.handleKey(app, null, ev);
    try std.testing.expect(!outcome.quit);
    return collectHex(app, want, 5 * std.time.ns_per_s);
}

/// Feed one key through the production path and return the child's bytes.
fn childBytesFor(app: *App, ev: KeyEvent) ![]u8 {
    return captureAfter(app, ev, 1);
}

test "PTY: a lone Esc reaches the child as exactly one 0x1b byte" {
    var app = try recorderApp(std.testing.allocator);
    defer app.deinit();
    try std.testing.expectEqual(@as(usize, 1), app.panes.items.len);

    const bytes = try childBytesFor(&app, key(.esc, 0, null, 1));
    defer app.alloc.free(bytes);
    try std.testing.expectEqualStrings("1b", bytes);
    // The application did not quit and the pane is intact: no shortcut stole
    // the key the way the old bottom-of-buffer / quit branches did.
    try std.testing.expectEqual(@as(usize, 1), app.panes.items.len);
}

test "PTY: Esc while scrolled up is forwarded, not consumed for scroll-to-bottom" {
    var app = try recorderApp(std.testing.allocator);
    defer app.deinit();
    var i: usize = 0;
    while (i < 80) : (i += 1) app.panes.items[0].feed("x\r\n");
    app.panes.items[0].grid.viewScrollUp(10);
    try std.testing.expect(!app.panes.items[0].grid.atBottom());

    const bytes = try capturePreservingScroll(&app, key(.esc, 0, null, 1), 1);
    defer app.alloc.free(bytes);
    try std.testing.expectEqualStrings("1b", bytes);
    // Still scrolled: Esc produced no scroll side effect.
    try std.testing.expect(!app.panes.items[0].grid.atBottom());
}

test "PTY: Vim-style Esc then :q<Enter> arrives byte-exact" {
    var app = try recorderApp(std.testing.allocator);
    defer app.deinit();
    const esc = try childBytesFor(&app, key(.esc, 0, null, 1));
    defer app.alloc.free(esc);
    try std.testing.expectEqualStrings("1b", esc);

    const colon = try childBytesFor(&app, key(.printable, SHIFT, ':', 39));
    defer app.alloc.free(colon);
    try std.testing.expectEqualStrings("3a", colon);

    const q = try childBytesFor(&app, key(.printable, 0, 'q', 16));
    defer app.alloc.free(q);
    try std.testing.expectEqualStrings("71", q);

    const enter = try childBytesFor(&app, key(.enter, 0, 0x0D, 28));
    defer app.alloc.free(enter);
    try std.testing.expectEqualStrings("0d", enter);
}

test "PTY: Alt+Esc delivers the two-byte ESC ESC prefix" {
    var app = try recorderApp(std.testing.allocator);
    defer app.deinit();
    const bytes = try captureAfter(&app, key(.esc, ALT, null, 1), 2);
    defer app.alloc.free(bytes);
    try std.testing.expectEqualStrings("1b1b", bytes);
}

test "PTY: Ctrl+Shift+Q does not reach the child and reports quit once" {
    var app = try recorderApp(std.testing.allocator);
    defer app.deinit();
    const outcome = input.handleKey(&app, null, key(.printable, CTRL | SHIFT, 'Q', 16));
    try std.testing.expect(outcome.quit);
    // Nothing was written: the recorder would otherwise print a hex line.
    var delay = std.os.linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&delay, null);
    const text = try app.panes.items[0].grid.captureText(app.alloc, false);
    defer app.alloc.free(text);
    var it = std.mem.tokenizeAny(u8, text, " \r\n\t");
    while (it.next()) |tok| {
        if (tok.len == 2 and std.ascii.isHex(tok[0]) and std.ascii.isHex(tok[1])) {
            return error.UnexpectedChildOutput;
        }
    }
}

test "PTY: kitty-enabled child receives Esc on the wire as CSI 27u" {
    var app = try recorderApp(std.testing.allocator);
    defer app.deinit();
    app.panes.items[0].grid.kbd_flags = term.kitty.KBD_DISAMBIGUATE;
    // ESC [ 2 7 u  → 1b 5b 32 37 75
    const bytes = try captureAfter(&app, key(.esc, 0, null, 1), 5);
    defer app.alloc.free(bytes);
    try std.testing.expectEqualStrings("1b5b323775", bytes);
}

test "PTY: quitting still works after Esc, so the terminal is not wedged" {
    var app = try recorderApp(std.testing.allocator);
    defer app.deinit();
    const esc = try childBytesFor(&app, key(.esc, 0, null, 1));
    defer app.alloc.free(esc);
    try std.testing.expectEqualStrings("1b", esc);

    const outcome = input.handleKey(&app, null, key(.printable, CTRL | SHIFT, 'Q', 16));
    try std.testing.expect(outcome.quit);
}

test "PTY: a child that only advances on Esc actually advances" {
    // Behavioural, not just byte-level: the child blocks reading one raw byte
    // and reports ESCAPED_OK only when that byte is 0x1b. This mirrors what
    // Vim does when leaving insert mode — if Janus swallowed the key the child
    // would hang here, which is exactly the reported bug.
    var app = testApp(std.testing.allocator);
    defer app.deinit();
    try app.spawnPane(&.{
        "/bin/sh",
        "-c",
        "stty raw -echo; printf 'READY\\n'; " ++
            "b=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \\n'); " ++
            "if [ \"$b\" = 1b ]; then printf 'ESCAPED_OK\\n'; else printf 'OTHER:%s\\n' \"$b\"; fi; " ++
            "exec sleep 5",
    });
    try waitForText(&app, "READY", 5 * std.time.ns_per_s);

    const outcome = input.handleKey(&app, null, key(.esc, 0, null, 1));
    try std.testing.expect(!outcome.quit);

    try waitForText(&app, "ESCAPED_OK", 5 * std.time.ns_per_s);
    const text = try app.panes.items[0].grid.captureText(app.alloc, true);
    defer app.alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "ESCAPED_OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "OTHER:") == null);
}
