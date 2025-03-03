const std = @import("std");
const posix = std.posix;

var original_termios: posix.termios = undefined;

pub fn main() !void {
    if (enableRawMode()) |_| {} else |err| switch (err) {
        error.NotATerminal => {
            std.debug.print("Not a terminal", .{});
            return;
        },
        else => |leftover_err| return leftover_err,
    }
    defer resetRawMode();

    const stdin = std.io.getStdIn().reader();
    var c: u8 = 0;
    while (true) {
        c = stdin.readByte() catch continue;
        if (c == 'q') {
            break;
        }
        if (std.ascii.isControl(c)) {
            std.debug.print("{d}\r\n", .{c});
        } else {
            std.debug.print("{d} ('{c}')\r\n", .{ c, c });
        }
    }
}

fn enableRawMode() !void {
    const stdin = posix.STDIN_FILENO;
    original_termios = try posix.tcgetattr(stdin);
    var new_termios: posix.termios = original_termios;
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
    posix.tcsetattr(stdin, posix.TCSA.FLUSH, original_termios) catch return;
}
