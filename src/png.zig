const std = @import("std");
const assert = std.debug.assert;
const inflate = std.compress.flate.inflate;
const mem = std.mem;
const debug = std.debug;

const Allocator = std.mem.Allocator;

pub const Decoder = struct {
    const Self = @This();
    chunks: std.ArrayList(Chunk),
    data: std.ArrayList(u8),
    header: ?Header,
    palette: ?Palette,

    pub fn decode(reader: anytype, allocator: Allocator) !Self {
        var chunks = std.ArrayList(Chunk).init(allocator);
        var data = std.ArrayList(u8).init(allocator);
        defer data.deinit();
        var header: ?Header = null;
        var palette: ?Palette = null;

        while (true) {
            const chunk = try Chunk.init(reader, allocator);

            try chunks.append(chunk);

            std.debug.print("Length: {}, Type: {}\n", .{ chunk.length, chunk.chunkType });

            switch (chunk.chunkType) {
                .IHDR => {
                    header = try Header.unmarshal(chunk.data.allocatedSlice());
                    std.debug.print("header: {any}\n", .{header});
                },
                .IEND => {
                    break;
                },
                .IDAT => {
                    try data.appendSlice(chunk.data.allocatedSlice());
                },
                .PLTE => {
                    palette = Palette.unmarshal(chunk.data.allocatedSlice());
                },
                .Ancillary => {},
            }
        }
        std.debug.print("Total IDT Data len: {}\n", .{data.items.len});

        var dataBuffer = std.io.fixedBufferStream(data.allocatedSlice());

        const uncompressed = decompress(dataBuffer.reader(), allocator).?;

        std.log.info("Uncompressed Length: {}", .{uncompressed.items.len});

        return Self{ .chunks = chunks, .data = uncompressed, .header = header, .palette = palette };
    }

    fn decompress(reader: anytype, allocator: Allocator) ?std.ArrayList(u8) {
        var buf = std.ArrayList(u8).init(allocator);

        var d = inflate.decompressor(.zlib, reader);
        d.decompress(buf.writer()) catch |err| {
            std.log.err("Failed to decompress: {}", .{err});
            buf.deinit();
            return null;
        };
        return buf;
    }

    // pub fn display(header: Header, palette: Palette, data: []u8) !void {
    //     const output_ppf_f = try std.fs.cwd().createFile("output.ppm", .{});
    //     defer output_ppf_f.close();
    //     const writer = output_ppf_f.writer();
    //     try writer.print(
    //         \\P6
    //         \\{d} {d}
    //         \\255
    //         \\
    //     , .{ header.width, header.height });

    //     for (data) |px| {
    //         // debug.print("{} ", .{px});
    //         try writer.writeByte(palette.data[px % 6]);
    //     }
    // }

    pub fn display(header: Header, data: []u8) !void {
        const output_ppf_f = try std.fs.cwd().createFile("output.ppm", .{});
        defer output_ppf_f.close();
        const writer = output_ppf_f.writer();
        try writer.print(
            \\P6
            \\{d} {d}
            \\255
            \\
        , .{ header.width, header.height });
        const bytesPerPixel = 3;
        const bytesPerScanLine = (header.width * bytesPerPixel) + 1;

        for (0..header.height) |y| {
            const filter: Filter = @enumFromInt(data[y * bytesPerScanLine]);
            debug.print("Filter: {}, height: {}\n", .{ filter, y });

            const start = y * bytesPerScanLine + 1;
            const end = start + bytesPerScanLine - 1;

            var previousScanLine: ?[]const u8 = null;

            if (y != 0) {
                const pstart = (y - 1) * bytesPerScanLine + 1;
                const pend = pstart + bytesPerScanLine - 1;
                previousScanLine = data[pstart..pend];
            }

            switch (filter) {
                .None => {},
                .Sub => {
                    for (0..bytesPerScanLine - 1) |i| {
                        const sub: u8 = if (i < bytesPerPixel) 0 else data[start + (i - bytesPerPixel)];
                        data[start + i] = @truncate(try std.math.add(usize, data[start + i], sub) % 256);
                    }
                },

                .Up => {
                    for (0..bytesPerScanLine - 1) |i| {
                        data[start + i] = @truncate(try std.math.add(usize, data[start + i], previousScanLine.?[i]) % 256);
                    }
                },
                .Average => {
                    for (0..bytesPerScanLine - 1) |i| {
                        const prior_val = previousScanLine.?[i];

                        const sub: usize = std.math.sub(usize, i, bytesPerPixel) catch 0;
                        const sub_val = data[sub];

                        const average: usize = @divFloor((sub_val + prior_val), 2);

                        data[start + i] = @truncate(try std.math.add(usize, data[start + i], average) % 256);
                    }
                },
                .Paeth => {
                    for (0..bytesPerScanLine - 1) |i| {
                        const sub_val: isize = if (i < bytesPerPixel) 0 else data[start + (i - bytesPerPixel)];

                        const prior_val: isize = previousScanLine.?[i];

                        const prior_bpp_val: isize = if (i < bytesPerPixel) 0 else previousScanLine.?[i - bytesPerPixel];

                        const val = paethPredictor(isize, sub_val, prior_val, prior_bpp_val);

                        const valf: usize = @intCast(try std.math.add(isize, data[start + i], val));

                        const final_val: u8 = @truncate(valf % 256);
                        data[start + i] = final_val;
                    }
                },
            }

            try writer.writeAll(data[start..end]);

            // for (data[start .. end + 1]) |px| {
            // try writer.writeByte(@truncate(px >> 16));
            // try writer.writeByte(@truncate(px >> 8));
            // }
        }
    }

    const Filter = enum { None, Sub, Up, Average, Paeth };

    pub fn deinit(self: Self) void {
        for (self.chunks.items) |item| {
            item.deinit();
        }
        self.chunks.deinit();
        self.data.deinit();
    }

    fn paethPredictor(comptime T: type, a: T, b: T, c: T) T {
        const p = a + b - c;
        const pa: usize = @abs(p - a);
        const pb: usize = @abs(p - b);
        const pc: usize = @abs(p - c);
        var lowest = a;
        if (pa <= pb and pa <= pc) {
            lowest = a;
        } else if (pb <= pc) {
            lowest = b;
        } else {
            lowest = c;
        }
        return lowest;
    }
};

// crc is calculated over chunk type and data and not length
pub const Chunk = struct {
    const Self = @This();
    length: u32,
    chunkType: ChunkType,
    data: std.ArrayList(u8),
    crc: u32,

    pub fn init(reader: anytype, allocator: Allocator) !Self {
        var buf: [4]u8 = undefined;
        var bytes_read = try reader.read(&buf);
        if (bytes_read != 4) {
            return ReadError.NotEnoughData;
        }

        const length = try readBe(u32, &buf);

        var crcHasher = std.hash.crc.Crc32.init();

        var chunkTypeBuf: [4]u8 = undefined;

        bytes_read = try reader.read(&chunkTypeBuf);
        if (bytes_read != 4) {
            return ReadError.NotEnoughData;
        }

        crcHasher.update(&chunkTypeBuf);

        var dataArrayList = try std.ArrayList(u8).initCapacity(allocator, length);

        bytes_read = try reader.read(dataArrayList.allocatedSlice());
        if (bytes_read != length) {
            return ReadError.NotEnoughData;
        }

        crcHasher.update(dataArrayList.allocatedSlice());

        bytes_read = try reader.read(&buf);
        if (bytes_read != 4) {
            return ReadError.NotEnoughData;
        }

        const crc = try readBe(u32, &buf);

        const calculatedCrc32: u32 = crcHasher.final();

        if (calculatedCrc32 != crc) {
            @panic("invalid crc");
        }

        const chunkType = std.meta.stringToEnum(ChunkType, &chunkTypeBuf) orelse ChunkType.Ancillary;

        return Self{ .length = length, .chunkType = chunkType, .data = dataArrayList, .crc = crc };
    }

    /// Release all allocated memory.
    pub fn deinit(self: Self) void {
        self.data.deinit();
    }
};

pub const Data = struct {
    const Self = @This();
    pub fn unmarshal(data: []u8) void {
        const identifier = data[0];
        std.debug.print("{any}\n", .{identifier});
    }
};

pub const Palette = struct {
    const Self = @This();
    data: []const u8,

    pub fn unmarshal(data: []const u8) Self {
        std.debug.print("Palette, Len: {} {any}\n", .{ data.len, data });
        return Self{ .data = data };
    }
};

pub const Header = struct {
    const Self = @This();

    width: u32,
    height: u32,
    bitDepth: u8,
    colorType: u8,
    compressionMethod: u8, //  only accepted value is 0
    filterMethod: u8, // only accepted value is 0,
    interlaceMethod: InterlaceMethod,

    pub fn unmarshal(data: []u8) !Self {
        assert(data.len == 13);
        var offset: usize = 0;

        const width = try readBe(u32, data[offset .. offset + 4]);
        offset += 4;

        const height = try readBe(u32, data[offset .. offset + 4]);
        offset += 4;

        const bitDepth = try readBe(u8, data[offset .. offset + 1]);
        offset += 1;

        const colorType = data[offset];
        offset += 1;

        const compressionMethod = data[offset];
        offset += 1;
        assert(compressionMethod == 0);

        const filterMethod = data[offset];
        offset += 1;
        assert(filterMethod == 0);

        const interlaceMethod: InterlaceMethod = @enumFromInt(@intFromPtr(&data[offset .. offset + 1]));
        offset += 1;
        return Self{ .width = width, .height = height, .bitDepth = bitDepth, .colorType = colorType, .compressionMethod = compressionMethod, .filterMethod = filterMethod, .interlaceMethod = interlaceMethod };
    }

    const InterlaceMethod = enum { Adam7, NoInterlace };
};

const ReadError = error{NotEnoughData};

fn readBe(comptime T: type, buf: []u8) ReadError!T {
    if (@sizeOf(T) > buf.len) {
        return ReadError.NotEnoughData;
    }
    const a: T = std.mem.readInt(T, buf[0..@sizeOf(T)], std.builtin.Endian.big);
    return a;
}

pub const ChunkType = enum {
    IHDR,
    IDAT,
    IEND,
    PLTE,
    Ancillary,
};
