const std = @import("std");
const posix = std.posix;

var running = true;

// vt100
const escape_character = "\x1b";

const EditorConfig = struct {
    original_termios: posix.termios,
    window_size: std.posix.system.winsize,
};

var editor_config: EditorConfig = undefined;

pub fn main() !void {
    if (enableRawMode()) |_| {} else |err| switch (err) {
        error.NotATerminal => {
            std.debug.print("Not a terminal\r\n", .{});
            return;
        },
        else => |leftover_err| return leftover_err,
    }
    defer resetRawMode();

    initEditor();

    while (running) {
        try editorRefreshScreen();
        editorProcessKeypress() catch |err| {
            try editorRefreshScreen();
            return err;
        };
    }
}

fn initEditor() void {
    editor_config.window_size = getWindowSize();
}

fn getWindowSize() std.posix.system.winsize {
    var buf: std.posix.system.winsize = undefined;
    const return_code = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&buf));
    if (return_code != 0) {
        std.debug.print("ioctl failed, return code {d}\r\n", .{return_code});
    }
    return buf;
}

fn editorDrawRows() !void {
    for (0..editor_config.window_size.ws_row) |_| {
        const stdout = std.io.getStdOut().writer();
        _ = try stdout.write("~\r\n");
    }
}

fn editorRefreshScreen() !void {
    const stdout = std.io.getStdOut().writer();
    // ANSI escape sequences
    // https://vt100.net/docs/vt100-ug/chapter3.html#ED
    const clear_screen_escape_code = "[2J";
    const erase_screen_seq = escape_character ++ clear_screen_escape_code;
    _ = try stdout.write(erase_screen_seq);
    _ = try resetCursorPosition();
    _ = try editorDrawRows();
    _ = try resetCursorPosition();
}

/// Reset cursor position to top-left of screen
fn resetCursorPosition() !void {
    const stdout = std.io.getStdOut().writer();
    const reset_cursor_position_seq = escape_character ++ "[H";
    _ = try stdout.write(reset_cursor_position_seq);
}

fn editorReadKey() !u8 {
    const stdin = std.io.getStdIn().reader();
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
    const stdin = posix.STDIN_FILENO;
    editor_config.original_termios = try posix.tcgetattr(stdin);
    var new_termios: posix.termios = editor_config.original_termios;
    new_termios.lflag.ICANON = false; // disable canonical processing (i.e. read directly from input queue)
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

    try posix.tcsetattr(stdin, posix.TCSA.FLUSH, new_termios);
}

fn resetRawMode() void {
    const stdin = posix.STDIN_FILENO;
    posix.tcsetattr(stdin, posix.TCSA.FLUSH, editor_config.original_termios) catch return;
}
