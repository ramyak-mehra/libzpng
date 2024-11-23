const std = @import("std");
const png = @import("png.zig");

const Endian = std.builtin.Endian;
const fs = std.fs;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub fn main() !void {
    const config = .{ .safety = true };
    var gpa = std.heap.GeneralPurposeAllocator(config){};
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(gpa.allocator());
    _ = args.skip();
    const file_path = args.next();
    if (file_path == null) {
        try print_help();
    } else {
        std.debug.print("Reading file args: {s}\n", .{file_path.?});

        const file = try fs.openFileAbsolute(file_path.?, fs.File.OpenFlags{});

        var bufReader = std.io.bufferedReader(file.reader());
        const reader = bufReader.reader();

        var buf: [8]u8 = undefined;
        const headerSize = try reader.read(
            &buf,
        );
        std.debug.print("Bytes read: {d}\n", .{headerSize});
        std.debug.print("{X}\n", .{buf});

        const decoder = try png.Decoder.decode(reader, gpa.allocator());
        std.debug.print("sdsd dsd: {d}\n", .{decoder.data.items.len});
        try png.Decoder.display(decoder.header.?, decoder.data.items);

        defer decoder.deinit();
    }
}

fn print_help() !void {
    _ = try std.io.getStdOut().write("Usage\nPass file path to read");
}
