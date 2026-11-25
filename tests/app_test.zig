const std = @import("std");
const app_mod = @import("janus-app");

fn testApp(allocator: std.mem.Allocator) app_mod.App {
    return .{ .alloc = allocator };
}

test "Janus creates and closes a real pane without a display or engine" {
    var app = testApp(std.testing.allocator);
    defer app.deinit();
    try app.spawnPane(&.{ "/bin/sh", "-c", "printf JANUS_TEST_OUTPUT; sleep 1" });
    try std.testing.expectEqual(@as(usize, 1), app.panes.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.focused);
    try std.testing.expect(app.focusGrid() != null);

    const deadline = @import("term").pty.nowNs() + 3 * std.time.ns_per_s;
    while (@import("term").pty.nowNs() < deadline) {
        app.drainPanes();
        if (app.bytes_in > 0) break;
        var delay = std.os.linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&delay, null);
    }
    try std.testing.expect(app.bytes_in > 0);
    app.closeFocusedPane();
    try std.testing.expectEqual(@as(usize, 0), app.panes.items.len);
}

test "focus cycles across panes and closing one preserves a valid focus" {
    var app = testApp(std.testing.allocator);
    try app.spawnPane(&.{"/bin/sh"});
    try app.spawnPane(&.{"/bin/sh"});
    defer app.deinit();
    app.cycleFocus(1);
    try std.testing.expectEqual(@as(usize, 0), app.focused);
    app.closeFocusedPane();
    try std.testing.expectEqual(@as(usize, 0), app.focused);
    app.closeFocusedPane();
    try std.testing.expectEqual(@as(usize, 0), app.panes.items.len);
    try std.testing.expect(app.focusGrid() == null);
}
