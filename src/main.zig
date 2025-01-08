const std = @import("std");
const term_util = @import("term_utils.zig");

const Cursor = struct {
    x: i32,
    y: i32,
};

const FileInfo = struct {
    file_name: []const u8,
    buffer: []const u8,
    file_size: usize,
};

const Row = struct {
    buffer: []const u8,
    index: usize = 0,

    fn next(self: *Row) ?u8 {
        const index = self.index;
        var in_ansi_code = false;

        if (index >= self.buffer.len) return null;

        for (self.buffer[index..]) |byte| {
            if (byte == 0x1B) in_ansi_code = true;

            self.index += 1;

            if (!in_ansi_code) {
                return byte;
            }

            if (in_ansi_code and (byte >= 0x41 and byte <= 0x5A) or (byte >= 0x61 and byte <= 0x7A)) {
                in_ansi_code = false;
            }
        }
        return null;
    }

    fn filter_ansi_codes(self: *Row, allocator: std.mem.Allocator) ![]const u8 {
        var filtered_buffer = std.ArrayList(u8).init(allocator);

        while (self.next()) |byte| {
            try filtered_buffer.append(byte);
        }

        self.index = 0;

        return try filtered_buffer.toOwnedSlice();
    }
};

var cursor: Cursor = .{ .x = 1, .y = 2 };

var top_page_index: usize = 1;
var bottom_page_index: usize = 0;

pub fn main() !void {
    try ui_printer(try handle_args());
}

fn input_handler(page: *std.ArrayList(Row), size: term_util.TermSize) !void {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator.deinit();

    var term = try std.posix.tcgetattr(std.io.getStdIn().handle);
    term.lflag.ICANON = false;
    term.lflag.ECHO = false;
    try std.posix.tcsetattr(std.io.getStdIn().handle, .NOW, term);

    const out = std.io.getStdOut().writer();

    while (true) {
        const k: u8 = std.io.getStdIn().reader().readByte() catch break;

        if (k == '\n') break;

        switch (k) {
            'j' => {
                try step_cursor_down(page, size);
            },
            'k' => {
                try step_cursor_up(page);
            },
            'h' => {
                try step_cursor_left();

                while (try get_byte_at_cursor(page.items[top_page_index..bottom_page_index]) == 0x20) {
                    try step_cursor_left();
                }
            },
            'l' => {
                try step_cursor_right(size);

                while (try get_byte_at_cursor(page.items[top_page_index..bottom_page_index]) == 0x20) {
                    try step_cursor_right(size);
                }
            },
            'q' => {
                const by: []const u8 =
                    try get_word_at_cursor(page.items[top_page_index..bottom_page_index], allocator.allocator());
                defer allocator.allocator().free(by);
                var split_val = std.mem.splitBackwards(u8, by, "x");
                const hex_string = split_val.next().?;

                const decimal = try std.fmt.parseInt(u8, hex_string, 16);

                try out.print("\x1B[{d};{d}H\x1B[2K Hex:{s} | Dec:{d} | Oct:{o} | Char:{c}", .{ size.height + 2, 1, by, decimal, decimal, decimal });
                try out.print("\x1B[{d};{d}H", .{ cursor.y, cursor.x });
            },
            else => {},
        }
    }
}

fn ui_printer(fi: FileInfo) !void {
    const buffer = fi.buffer;
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const out = std.io.getStdOut().writer();

    var size = try term_util.termSize(std.io.getStdOut());
    size.?.height -= 3;

    var page: std.ArrayList(Row) = std.ArrayList(Row).init(allocator.allocator());
    defer page.deinit();

    var row_buffer: std.ArrayList(u8) = std.ArrayList(u8).init(allocator.allocator());
    defer row_buffer.deinit();

    var row_size: usize = 0;
    var in_ansi_code = false;

    for (buffer) |byte| {
        if (byte == '\n') {
            row_size = 0;
            try page.append(.{ .buffer = try row_buffer.toOwnedSlice() });
        } else if (row_size >= size.?.width) {
            row_size = 0;
            try page.append(.{ .buffer = try row_buffer.toOwnedSlice() });
        }

        try row_buffer.append(byte);

        if (byte == 0x1B) {
            in_ansi_code = true;
        }

        if (!in_ansi_code) {
            row_size += 1;
        }

        if (in_ansi_code and (byte >= 0x41 and byte <= 0x5A) or (byte >= 0x61 and byte <= 0x7A)) {
            in_ansi_code = false;
        }
    }

    if (row_size != 0) {
        try page.append(.{ .buffer = try row_buffer.toOwnedSlice() });
    }

    bottom_page_index = size.?.height;
    if (bottom_page_index >= page.items.len) {
        bottom_page_index = page.items.len;
    }

    try out.print("\x1B[2J\x1B[1;1H", .{});

    var screen_page = page.items[top_page_index..bottom_page_index];
    try refresh_page(&screen_page);

    try out.print("\x1B[{d};{d}H\x1B[30;44m Editing File {s} \x1B[34;40m File Size({d}) \x1B[0m", .{ size.?.height + 1, 1, fi.file_name, fi.file_size });

    try out.print("\x1B[{d};{d}H", .{ cursor.y, cursor.x });

    const thread = try std.Thread.spawn(.{}, input_handler, .{ &page, size.? });
    _ = thread;

    while (true) {
        std.time.sleep(1 * std.time.ns_per_s);
    }
}

fn update_screen(page: ?*std.ArrayList(Row), full_update: bool) !void {
    const out = std.io.getStdOut().writer();
    if (full_update) {
        var screen_page = page.?.items[top_page_index..bottom_page_index];
        try refresh_page(&screen_page);
    }
    try out.print("\x1B[{d};{d}H", .{ cursor.y, cursor.x });
}

fn step_cursor_right(size: term_util.TermSize) !void {
    cursor.x += 1;

    if (cursor.x > size.width) {
        cursor.x -= 1;
    }
    try update_screen(null, false);
}

fn step_cursor_left() !void {
    cursor.x -= 1;

    if (cursor.x <= 0) {
        cursor.x += 1;
    }
    try update_screen(null, false);
}

fn step_cursor_down(page: *std.ArrayList(Row), size: term_util.TermSize) !void {
    var full_update = false;
    cursor.y += 1;
    if (cursor.y > size.height) {
        cursor.y -= 1;
        if (bottom_page_index < page.items.len) {
            top_page_index += 1;
            bottom_page_index += 1;
            full_update = true;
        }
    }
    try update_screen(page, full_update);
}

fn step_cursor_up(page: *std.ArrayList(Row)) !void {
    var full_update = false;
    cursor.y -= 1;
    if (cursor.y <= 1) {
        if (top_page_index > 1) {
            top_page_index -= 1;
            bottom_page_index -= 1;
            full_update = true;
        }
        cursor.y += 1;
    }

    try update_screen(page, full_update);
}

fn refresh_page(page: *[]Row) !void {
    const out = std.io.getStdOut().writer();
    try out.print("\x1B[1;1H\x1B[?25l", .{});
    for (page.*) |row| {
        for (row.buffer) |by| {
            try out.print("{c}", .{by});
            if (by == '\n') {
                try out.print("\x1B[2K", .{});
            }
        }
    }

    try out.print("\x1B[?25h", .{});
}

fn handle_args() !FileInfo {
    var args = std.process.args();
    defer args.deinit();

    // skips prog name
    _ = args.skip();

    var index: usize = 0;
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    var file_list = std.ArrayList(u8).init(allocator.allocator());
    try file_list.append('\n');
    const out = file_list.writer();

    while (args.next()) |arg| {
        if (index == 0) {
            const file = try std.fs.cwd().openFile(arg, .{ .mode = .read_only });
            defer file.close();

            const len = try file.getEndPos();

            const file_bytes: []const u8 = try file.readToEndAlloc(allocator.allocator(), @intCast(len));
            defer allocator.allocator().free(file_bytes);

            var row: usize = 0;
            var col: usize = 0;
            for (file_bytes) |byte| {
                if (col > 0 and 5 % col == 5) {
                    try print_byte_chars(file_bytes[(row * 6)..], out);
                    try out.print("\n", .{});
                    col = 0;
                    row += 1;
                }
                if (col == 0) {
                    try out.print("\x1B[1m{d:0>4}\x1B[0m   ", .{row});
                }

                switch (col) {
                    0 => {
                        try out.print("\x1B[91m", .{});
                    },
                    1 => {
                        try out.print("\x1B[93m", .{});
                    },
                    2 => {
                        try out.print("\x1B[94m", .{});
                    },
                    3 => {
                        try out.print("\x1B[95m", .{});
                    },
                    4 => {
                        try out.print("\x1B[96m", .{});
                    },
                    5 => {
                        try out.print("\x1B[97m", .{});
                    },
                    else => {},
                }

                try out.print("0x{X:0<2} ", .{byte});
                try out.print("\x1B[0m", .{});
                col += 1;
            }

            try print_byte_chars(file_bytes[(row * 6)..], out);

            return .{ .file_name = arg, .file_size = file_list.items.len - 1, .buffer = try file_list.toOwnedSlice() };
        }
        index += 1;
    }

    return error.NoFileFound;
}

fn print_byte_chars(row: []const u8, out: anytype) !void {
    try out.print("   ", .{});
    var col: usize = 0;
    for (row) |byte| {
        if (col > 0 and 5 % col == 5) {
            break;
        }
        switch (col) {
            0 => {
                try out.print("\x1B[91m", .{});
            },
            1 => {
                try out.print("\x1B[93m", .{});
            },
            2 => {
                try out.print("\x1B[94m", .{});
            },
            3 => {
                try out.print("\x1B[95m", .{});
            },
            4 => {
                try out.print("\x1B[96m", .{});
            },
            5 => {
                try out.print("\x1B[97m", .{});
            },
            else => {},
        }
        switch (byte) {
            0x21...0x7E => {
                try out.print("{c:.<1} ", .{byte});
            },
            else => {
                try out.print(". ", .{});
            },
        }
        try out.print("\x1B[0m", .{});
        col += 1;
    }
}

fn get_word_at_cursor(page: []Row, allocator: std.mem.Allocator) ![]const u8 {
    const current_byte = try get_byte_at_cursor(page);
    var row = page[@intCast(cursor.y - 2)];

    const filtered_row = try row.filter_ansi_codes(allocator);
    defer allocator.free(filtered_row);

    var starting_index: usize = @intCast(cursor.x);
    var ending_index: usize = starting_index;

    if (current_byte == 0x20) {
        for (filtered_row[@intCast(cursor.x)..]) |byte| {
            if (byte >= 0x21 and byte <= 0x7E) {
                break;
            }
            starting_index += 1;
        }
    } else {
        while (starting_index > 0) {
            if (filtered_row[starting_index] == 0x20) {
                starting_index += 1;
                break;
            }
            starting_index -= 1;
        }
    }

    ending_index = starting_index;

    for (filtered_row[starting_index..]) |byte| {
        if (byte == 0x20) {
            break;
        }
        ending_index += 1;
    }

    const cpy_word = try allocator.alloc(u8, ending_index - starting_index);
    @memcpy(cpy_word, filtered_row[starting_index..ending_index]);

    return cpy_word;
}

fn get_byte_at_cursor(page: []Row) !u8 {
    var row = page[@intCast(cursor.y - 2)];
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator.deinit();

    const filtered_row = try row.filter_ansi_codes(allocator.allocator());
    defer allocator.allocator().free(filtered_row);

    if (cursor.x >= filtered_row.len) return 0x0;

    const col = filtered_row[@intCast(cursor.x)];

    return col;
}
