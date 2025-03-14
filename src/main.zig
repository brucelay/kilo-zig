const std = @import("std");
const posix = std.posix;

const KILO_ZIG_VERSION = "0.0.1";

// vt100
const escape_character = "\x1b";

const Config = struct {
    // cursor pos
    cx: u16,
    cy: u16, // cursor position in file
    original_termios: posix.termios,
    window_size: std.posix.system.winsize,
    lines: std.ArrayListUnmanaged([]const u8),
    line_offset: u16, // offset of the line in the file to start drawing
    column_offset: u16, // offset of the column to start drawing
};
var config: Config = undefined;

const stdout = std.io.getStdOut().writer();
const stdin = std.io.getStdIn().reader();

var running = true;

const CursorPosition = struct {
    rows: @TypeOf(config.window_size.ws_row),
    cols: @TypeOf(config.window_size.ws_col),
};

const editorKey = enum(u16) {
    UP = 1000,
    DOWN,
    LEFT,
    RIGHT,
    HOME,
    END,
    DEL,
    PAGE_UP,
    PAGE_DOWN,
};

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn main() !void {
    defer arena.deinit();
    if (enableRawMode()) |_| {} else |err| switch (err) {
        error.NotATerminal => {
            std.debug.print("Not a terminal\r\n", .{});
            return;
        },
        else => |leftover_err| return leftover_err,
    }
    defer cleanup();

    initEditor() catch |err| {
        cleanup();
        return err;
    };

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next();
    const filename = args.next();
    try editorOpen(filename);

    mainLoop() catch |err| {
        cleanup();
        return err;
    };
}

/// Cleanup and exit with error message
fn cleanupAndExit(comptime fmt: []const u8, args: anytype) void {
    cleanup();
    std.debug.print(fmt ++ "\r\n\r\n", args);
    std.process.exit(1);
}

fn mainLoop() !void {
    while (running) {
        try editorRefreshScreen();
        try editorProcessKeypress();
    }
}

fn initEditor() !void {
    config.lines = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, 128);
    config.window_size = try getWindowSize();
}

fn getCursorPosition() !CursorPosition {
    // https://vt100.net/docs/vt100-ug/chapter3.html#DSR
    const report_active_position = escape_character ++ "[6n";
    _ = try stdout.write(report_active_position);

    var cursor_report: [32]u8 = undefined;

    try resetCursorPosition();

    var i: usize = 0;
    var separator: usize = 0;
    for (&cursor_report) |*report_char| {
        if (stdin.readByte()) |char| {
            report_char.* = char;
            if (char == ';') separator = i;
            i += 1;
            if (char == 'R') break;
        } else |err| switch (err) {
            error.EndOfStream => break,
            else => |leftover_err| {
                std.debug.print("Error reading byte: {}\r\n", .{leftover_err});
            },
        }
    }
    cursor_report[i] = 0;

    const row_type = @TypeOf(config.window_size.ws_row);
    const col_type = @TypeOf(config.window_size.ws_col);
    const row_string = cursor_report[2..separator]; // skip \x1b
    const rows: row_type = std.fmt.parseInt(row_type, row_string, 10) catch |err| {
        cleanupAndExit("Failed to parse window row size '{s}': {}", .{ row_string, err });
        unreachable;
    };
    const col_string = cursor_report[separator + 1 .. i - 1];
    const cols: col_type = std.fmt.parseInt(col_type, col_string, 10) catch |err| {
        cleanupAndExit("Failed to parse window column size: {}", .{err});
        unreachable;
    };
    return CursorPosition{ .rows = rows, .cols = cols };
}

fn getWindowSize() !std.posix.system.winsize {
    var window_size: std.posix.system.winsize = std.posix.system.winsize{
        .ws_row = 0,
        .ws_col = 0,
        .ws_ypixel = 0,
        .ws_xpixel = 0,
    };
    const return_code = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&window_size));
    if (true or return_code == -1) { // failure
        // move the cursor right and down
        // vt100 behaviour limits the cursor from going beyond the limits of the window size
        // https://vt100.net/docs/vt100-ug/chapter3.html#VT52CUF
        const move_cursor_right = escape_character ++ "[999C";
        const move_cursor_down = escape_character ++ "[999B";
        _ = stdout.write(move_cursor_right ++ move_cursor_down) catch {};
        const cursor_position = try getCursorPosition();
        window_size.ws_col = cursor_position.cols;
        window_size.ws_row = cursor_position.rows;
    }
    return window_size;
}

fn editorOpen(filename: ?[]const u8) !void {
    if (filename == null) {
        return;
    }
    const file = std.fs.cwd().openFile(filename.?, .{ .mode = .read_only }) catch |err| {
        cleanupAndExit("Error opening file: {}", .{err});
        unreachable;
    };
    defer std.fs.File.close(file);
    const file_reader = file.reader();

    while (true) {
        var line = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 128);
        const line_writer = line.writer(allocator);
        file_reader.streamUntilDelimiter(line_writer, '\n', null) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try editorAppendRow(line.items);
    }
}

fn editorAppendRow(data: []const u8) !void {
    try config.lines.append(allocator, data);
}

fn editorScroll() void {
    // if cursor is above the current line offset, scroll up
    if (config.cy < config.line_offset) {
        config.line_offset = config.cy;
    }
    // if cursor is past the window size, scroll down
    if (config.cy >= config.line_offset + config.window_size.ws_row) {
        config.line_offset = (config.cy - config.window_size.ws_row) + 1;
    }
}

fn editorDrawRows(arr: *std.ArrayListUnmanaged(u8)) !void {
    _ = try resetCursorPosition();
    const writer = arr.writer(allocator);
    const clear_right = escape_character ++ "[K"; // clear right of cursor

    for (0..config.window_size.ws_row) |i| {
        // draw editor lines
        const file_line = i + config.line_offset;
        const file_lines_remain = file_line < config.lines.items.len;
        if (file_lines_remain) {
            // draw file contents

            // calculate line width if scrolled horizontally
            const line_length = config.lines.items[file_line].len;
            var display_length = line_length;
            if (config.column_offset > line_length) { // moved past end of line
                display_length = 0;
            } else {
                display_length = line_length - config.column_offset;
                // truncate line if too long
                if (display_length > config.window_size.ws_col) {
                    display_length = config.window_size.ws_col;
                }
            }

            if (display_length == 0) {
                // moved past end of line so display nothing
                _ = try writer.write("");
            } else {
                const start_index = config.column_offset;
                const end_index = config.column_offset + display_length;
                _ = try writer.print("{s}", .{config.lines.items[file_line][start_index..end_index]});
            }
        } else {
            const should_draw_welcome = config.lines.items.len == 0 and i == config.window_size.ws_row / 3;
            if (should_draw_welcome) {
                // draw welcome message
                const welcome = std.fmt.comptimePrint("kilo-zig -- version {s}", .{KILO_ZIG_VERSION});
                if (welcome.len > config.window_size.ws_col) {
                    // truncate if too long
                    _ = try writer.write(welcome[0..config.window_size.ws_col]);
                    continue;
                }
                var left_padding = (config.window_size.ws_col - welcome.len) / 2; // center text
                if (left_padding > 0) {
                    _ = try writer.write("~");
                    left_padding -= 1;
                }
                for (0..left_padding) |_| {
                    _ = try writer.write(" ");
                }
                _ = try writer.write(welcome);
            } else {
                // draw empty lines (~)
                _ = try writer.write("~");
            }
        }
        _ = try writer.write(clear_right);
        if (i < config.window_size.ws_row - 1) {
            _ = try writer.write("\r\n");
        }
    }

    _ = try stdout.write(arr.items);
}

fn clearScreen() !void {
    // ANSI escape sequences
    // https://vt100.net/docs/vt100-ug/chapter3.html#ED
    const clear_screen_escape_code = "[2J";
    const erase_screen_seq = escape_character ++ clear_screen_escape_code;
    _ = try resetCursorPosition();
    _ = try stdout.write(erase_screen_seq);
}

/// Redraw editor
fn editorRefreshScreen() !void {
    editorScroll();
    var arr = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 1024);
    defer arr.deinit(allocator);

    _ = try stdout.write(escape_character ++ "[?25l"); // hide cursor
    _ = try editorDrawRows(&arr);
    // move cursor to position
    const cursor_line = config.cy - config.line_offset;
    _ = try stdout.print("{s}[{d};{d}H", .{ escape_character, cursor_line + 1, config.cx + 1 });
    _ = try stdout.write(escape_character ++ "[?25h"); // show cursor
}

/// Reset cursor position to top-left of screen
fn resetCursorPosition() !void {
    const reset_cursor_position_seq = escape_character ++ "[H";
    _ = try stdout.write(reset_cursor_position_seq);
}

fn editorReadKey() !u16 {
    var c: u8 = 0;
    c = try readKeyIgnoreEOF();

    if (c == '\x1b') {
        // \x1b[A etc.
        var seq: [3]u8 = undefined;
        seq[0] = stdin.readByte() catch |err| switch (err) {
            error.EndOfStream => return c,
            else => return err,
        };
        seq[1] = stdin.readByte() catch |err| switch (err) {
            error.EndOfStream => return c,
            else => return err,
        };

        switch (seq[0]) {
            '[' => {
                if (seq[1] >= '0' and seq[1] <= '9') {
                    seq[2] = stdin.readByte() catch |err| switch (err) {
                        error.EndOfStream => return c,
                        else => return err,
                    };
                    if (seq[2] == '~') {
                        switch (seq[1]) {
                            '1' => return @intFromEnum(editorKey.HOME),
                            '3' => return @intFromEnum(editorKey.DEL),
                            '4' => return @intFromEnum(editorKey.END),
                            '5' => return @intFromEnum(editorKey.PAGE_UP),
                            '6' => return @intFromEnum(editorKey.PAGE_DOWN),
                            '7' => return @intFromEnum(editorKey.HOME),
                            '8' => return @intFromEnum(editorKey.END),
                            else => {},
                        }
                    }
                } else {
                    switch (seq[1]) {
                        'A' => return @intFromEnum(editorKey.UP),
                        'B' => return @intFromEnum(editorKey.DOWN),
                        'C' => return @intFromEnum(editorKey.RIGHT),
                        'D' => return @intFromEnum(editorKey.LEFT),
                        'H' => return @intFromEnum(editorKey.HOME),
                        'F' => return @intFromEnum(editorKey.END),
                        else => {},
                    }
                }
            },
            'O' => {
                switch (seq[1]) {
                    'H' => return @intFromEnum(editorKey.HOME),
                    'F' => return @intFromEnum(editorKey.END),
                    else => {},
                }
            },
            else => {},
        }
    }

    return c;
}

fn readKeyIgnoreEOF() !u8 {
    if (stdin.readByte()) |char| {
        return char;
    } else |err| switch (err) {
        error.EndOfStream => return 0, // ignore as likely just read timeout
        else => return err,
    }
}

fn editorMoveCursor(key: u16) void {
    switch (key) {
        @intFromEnum(editorKey.UP) => {
            if (config.cy > 0) config.cy -= 1;
        },
        @intFromEnum(editorKey.LEFT) => {
            if (config.cx > 0) config.cx -= 1;
        },
        @intFromEnum(editorKey.DOWN) => {
            if (config.cy < config.lines.items.len) config.cy += 1;
        },
        @intFromEnum(editorKey.RIGHT) => {
            if (config.cx < config.window_size.ws_col - 1) config.cx += 1;
        },
        else => {},
    }
}

fn editorProcessKeypress() !void {
    const c = try editorReadKey();
    switch (c) {
        ctrlModifier('q') => running = false,
        @intFromEnum(editorKey.UP),
        @intFromEnum(editorKey.LEFT),
        @intFromEnum(editorKey.DOWN),
        @intFromEnum(editorKey.RIGHT),
        => editorMoveCursor(c),
        @intFromEnum(editorKey.PAGE_UP), @intFromEnum(editorKey.PAGE_DOWN) => {
            const times: @TypeOf(config.window_size.ws_row) = config.window_size.ws_row;
            for (0..times) |_| {
                editorMoveCursor(if (c == @intFromEnum(editorKey.PAGE_UP))
                    @intFromEnum(editorKey.UP)
                else
                    @intFromEnum(editorKey.DOWN));
            }
        },
        @intFromEnum(editorKey.HOME) => {
            config.cx = 0;
        },
        @intFromEnum(editorKey.END) => {
            config.cx = config.window_size.ws_col - 1;
        },
        else => {},
    }
}

/// Get corresponding control character for a given character
fn ctrlModifier(c: u8) u8 {
    // emulate VT100 behaviour used by many terminals
    return c & 0x1f;
}

fn enableRawMode() !void {
    config.original_termios = try posix.tcgetattr(posix.STDIN_FILENO);
    var new_termios: posix.termios = config.original_termios;
    new_termios.lflag.ICANON = false; // disable canonical processing (line-by-line)
    new_termios.lflag.ECHO = false; // do not echo input characters
    new_termios.lflag.ISIG = false; // ignore signals (e.g. SIGINT)
    new_termios.lflag.IEXTEN = false; // disable 'verbatim insert' (e.g. Ctrl-V)

    new_termios.iflag.IXON = false; // disable software flow control (pausing and resuming input)
    new_termios.iflag.ICRNL = false; // disable carriage return to newline translation
    new_termios.iflag.BRKINT = false; // disable signal interrupt on break
    new_termios.iflag.INPCK = false; // disable input parity checking
    new_termios.iflag.ISTRIP = false; // disable stripping of 8th input bit

    new_termios.cflag.CSIZE = posix.CSIZE.CS8; // character size

    new_termios.oflag.OPOST = false; // disable output post-processing

    const V_MIN = @intFromEnum(posix.V.MIN);
    const V_TIME = @intFromEnum(posix.V.TIME);
    new_termios.cc[V_MIN] = 0; // min bytes for read() to return
    const return_timeout: posix.cc_t = 1; // * 100ms
    new_termios.cc[V_TIME] = return_timeout;

    try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.FLUSH, new_termios);
}

/// Reset terminal to original state
/// and clear the screen
fn cleanup() void {
    resetRawMode();
    clearScreen() catch {};
}

fn resetRawMode() void {
    posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.FLUSH, config.original_termios) catch return;
}
