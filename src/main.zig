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

        //TODO: Find a better way to read the file?
        var data = try file.readToEndAlloc(gpa.allocator(), 1000000);

        defer gpa.allocator().free(data);

        var decoder = try png.decoder(data[8..]);
        const imageData = try decoder.collectAllData(gpa.allocator());
        defer gpa.allocator().free(imageData);

        var imageDataFixedStream = std.io.fixedBufferStream(imageData);

        const uncompressedData = try png.Decoder.decompress(imageDataFixedStream.reader(), gpa.allocator());
        defer gpa.allocator().free(uncompressedData);

        std.debug.print("Heder: {any}\n", .{decoder.header});

        const dd = try decoder.displayData(gpa.allocator(), uncompressedData);
        defer gpa.allocator().free(dd);

        const output_ppf_f = try std.fs.cwd().createFile("output.ppm", .{});
        defer output_ppf_f.close();
        const writer = output_ppf_f.writer();
        try writer.print(
            \\P6
            \\{d} {d}
            \\255
            \\
        , .{ decoder.header.?.width, decoder.header.?.height });

        try writer.writeAll(dd);
    }
}

fn print_help() !void {
    _ = try std.io.getStdOut().write("Usage:\nPass file path to read\n");
}
