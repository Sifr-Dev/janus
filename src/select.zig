//! Selection & clipboard: drag-select cells, extract text, copy to the
//! system clipboard, and emit the highlight quads the frame renderer
//! paints under the glyphs.
const std = @import("std");
const term = @import("term");
const app_mod = @import("app.zig");

const runtime = term.runtime;
const gpu_text = term.gpu_text;
const render = term.render;

const App = app_mod.App;

/// Map pixel coordinates to grid cell coordinates (clamped).
pub fn cellAt(app: *App, rt: *runtime.Runtime, x: f32, y: f32) [2]i32 {
    const grid = app.focusGrid() orelse return .{ 0, 0 };
    const atlas = rt.atlas orelse return .{ 0, 0 };
    const cm = render.cellMetrics(atlas);
    var cx = @as(i32, @intFromFloat(x / cm.w));
    var cy = @as(i32, @intFromFloat((y - 38) / cm.h));
    cx = @max(@as(i32, 0), @min(cx, @as(i32, @intCast(grid.cols)) - 1));
    cy = @max(@as(i32, 0), @min(cy, @as(i32, @intCast(grid.rows)) - 1));
    return .{ cx, cy };
}

/// Ordering helper: ensure (x0,y0) <= (x1,y1) in reading order.
fn normalized(x0: i32, y0: i32, x1: i32, y1: i32) [4]i32 {
    if (y1 < y0 or (y1 == y0 and x1 < x0)) return .{ x1, y1, x0, y0 };
    return .{ x0, y0, x1, y1 };
}

/// Extract the selected text from the focused pane's live screen.
pub fn selectionText(app: *App) ![]u8 {
    const grid = app.focusGrid() orelse return error.NoPane;
    const r = normalized(app.sel_x0, app.sel_y0, app.sel_x1, app.sel_y1);
    const x0 = r[0];
    const y0 = r[1];
    const x1 = r[2];
    const y1 = r[3];
    const lines = grid.screenLines();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(app.alloc);
    var y: usize = @intCast(@max(@as(i32, 0), y0));
    const yend: usize = @intCast(@max(@as(i32, 0), y1));
    while (y <= yend and y < lines.len) : (y += 1) {
        const line = lines[y];
        const line_start = out.items.len;
        const start: usize = if (y == @as(usize, @intCast(@max(@as(i32, 0), y0)))) @intCast(@max(@as(i32, 0), @min(x0, @as(i32, @intCast(line.cells.len)) - 1))) else 0;
        const end: usize = if (y == yend) @intCast(@max(@as(i32, 0), @min(x1 + 1, @as(i32, @intCast(line.cells.len))))) else line.cells.len;
        var col = start;
        while (col < end and col < line.cells.len) : (col += 1) {
            const cp = line.cells[col].cp;
            var buf: [4]u8 = undefined;
            const n: usize = @intCast(std.unicode.utf8Encode(if (cp == 0) ' ' else @as(u21, @intCast(cp)), &buf) catch continue);
            try out.appendSlice(app.alloc, buf[0..n]);
        }
        while (out.items.len > line_start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        if (y < yend) try out.append(app.alloc, '\n');
    }
    return out.toOwnedSlice(app.alloc);
}

/// Copy the current selection to the system clipboard.
pub fn copySelection(app: *App, rt: *runtime.Runtime) void {
    const text = selectionText(app) catch return;
    defer app.alloc.free(text);
    if (text.len > 0) rt.setClipboard(text) catch {};
}

/// Emit one highlight quad per selected screen row starting at `quad_index`.
/// Returns the next free quad index.
pub fn emitHighlightQuads(app: *App, quads: []gpu_text.Quad, quad_index: usize, grid_y: f32, cell_w: f32, cell_h: f32, theme: render.Theme) usize {
    const grid = app.focusGrid() orelse return quad_index;
    const r = normalized(app.sel_x0, app.sel_y0, app.sel_x1, app.sel_y1);
    const cols_i: i32 = @intCast(grid.cols);
    const rows_i: i32 = @intCast(grid.rows);
    const x0 = @max(@as(i32, 0), @min(r[0], cols_i - 1));
    const x1 = @max(@as(i32, 0), @min(r[2], cols_i - 1));
    const y0 = @max(@as(i32, 0), @min(r[1], rows_i - 1));
    const y1 = @max(@as(i32, 0), @min(r[3], rows_i - 1));
    var n = quad_index;
    var y: i32 = y0;
    while (y <= y1) : (y += 1) {
        const sx: i32 = if (y == y0) x0 else 0;
        const ex: i32 = if (y == y1) x1 + 1 else cols_i;
        if (n < quads.len) {
            quads[n] = .{
                .x = @as(f32, @floatFromInt(sx)) * cell_w,
                .y = grid_y + @as(f32, @floatFromInt(y)) * cell_h,
                .w = @as(f32, @floatFromInt(ex - sx)) * cell_w,
                .h = cell_h,
                .u0 = 0,
                .v0 = 0,
                .u1 = 0,
                .v1 = 0,
                .color = runtime.rgba01(theme.sel),
            };
            n += 1;
        }
    }
    return n;
}
