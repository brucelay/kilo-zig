const std = @import("std");
const posix = std.posix;

var running = true;

// vt100
const escape_character = "\x1b";

const Config = struct { original_termios: posix.termios, window_size: std.posix.system.winsize };
var config: Config = undefined;

const stdout = std.io.getStdOut().writer();
const stdin = std.io.getStdIn().reader();

const CursorPosition = struct {
    rows: @TypeOf(config.window_size.ws_row),
    cols: @TypeOf(config.window_size.ws_col),
};

pub fn main() !void {
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

fn editorDrawRows(allocator: std.mem.Allocator, arr: *std.ArrayListUnmanaged(u8)) !void {
    for (0..config.window_size.ws_row - 1) |_| {
        try arr.appendSlice(allocator, "~\r\n");
    }

    try arr.appendSlice(allocator, "~");
    _ = try stdout.write(arr.items);
}

fn clearScreen() !void {
    const clear_screen_escape_code = "[2J";
    const erase_screen_seq = escape_character ++ clear_screen_escape_code;
    _ = try stdout.write(erase_screen_seq);
}

/// Redraw editor
fn editorRefreshScreen() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var arr = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 1024);

    // ANSI escape sequences
    // https://vt100.net/docs/vt100-ug/chapter3.html#ED
    try clearScreen();
    _ = try resetCursorPosition();
    _ = try editorDrawRows(allocator, &arr);
    _ = try resetCursorPosition();
}

/// Reset cursor position to top-left of screen
fn resetCursorPosition() !void {
    const reset_cursor_position_seq = escape_character ++ "[H";
    _ = try stdout.write(reset_cursor_position_seq);
}

fn editorReadKey() !u8 {
    var c: u8 = 0;
    if (stdin.readByte()) |char| {
        c = char;
    } else |err| switch (err) {
        error.EndOfStream => {}, // ignore as likely just read timeout
        else => |leftover_err| return leftover_err,
    }
    return c;
}

fn editorProcessKeypress() !void {
    const c = try editorReadKey();
    if (c == ctrlModifier('q')) {
        running = false;
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
