const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;

const assert = std.debug.assert;
const inflate = std.compress.flate.inflate;
const debug = std.debug;

const Allocator = std.mem.Allocator;

pub fn decoder(data: []const u8) !Decoder {
    const buffer = Buffer.init(data);

    return Decoder{ .data = buffer, .lastChunk = false, .header = null };
}

pub const Decoder = struct {
    data: Buffer,
    lastChunk: bool,
    header: ?IHDR,

    // Extracts the chunk as well as setting any relevant info about the image.
    pub fn nextChunk(self: *Decoder) !?Chunk {
        if (!self.lastChunk) {
            const chunk = try Chunk.parse(&self.data);
            std.debug.print("Chunk Type: {}\n", .{chunk.chunkType()});
            const chunkData = try chunk.parseData();
            switch (chunkData) {
                .IHDR => {
                    self.header = chunkData.IHDR;
                },

                .IEND => {
                    self.lastChunk = true;
                },
                else => {},
            }
            return chunk;
        } else {
            return null;
        }
    }

    // Caller owns the data, the function returns
    pub fn collectAllData(self: *Decoder, allocator: Allocator) ![]u8 {
        //TODO: Implement a reader on top of decoder
        var dataBuffer = std.ArrayList(u8).init(allocator);

        while (try self.nextChunk()) |chunk| {
            std.debug.print("Chunk Type: {}\n", .{chunk.chunkType()});
            if (chunk.chunkType() == ChunkType.IDAT) {
                try dataBuffer.appendSlice(chunk.data);
            }
        }
        return dataBuffer.toOwnedSlice();
    }

    // Caller owns the data, the function returns
    pub fn decompress(reader: anytype, allocator: Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        var d = inflate.decompressor(.zlib, reader);
        d.decompress(buf.writer()) catch |err| {
            return err;
        };
        return buf.toOwnedSlice();
    }

    // Returns display image data. It may modify the provided buffer data
    // It only supports images of color type 2 and bit depth 8.
    // It returns a slice that the caller owns
    pub fn displayData(self: Decoder, allocator: Allocator, data: []u8) ![]u8 {
        var dd = std.ArrayList(u8).init(allocator);
        const bytesPerPixel = 3;
        const header = self.header orelse return error.NoHeaderFound;

        if (header.bitDepth != 8 or header.colorType != 2) {
            return error.UnsupportedFileFormat;
        }

        const bytesPerScanLine = (header.width * bytesPerPixel) + 1;

        for (0..header.height) |y| {
            const filter: Filter = @enumFromInt(data[y * bytesPerScanLine]);
            debug.print("Filter: {}, height: {}\n", .{ filter, y });

            const start = y * bytesPerScanLine + 1;
            const end = start + bytesPerScanLine - 1;

            var scanLine = data[start..end];

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
                        const sub: u8 = if (i < bytesPerPixel) 0 else scanLine[(i - bytesPerPixel)];
                        scanLine[i] = @truncate(try std.math.add(usize, scanLine[i], sub) % 256);
                    }
                },

                .Up => {
                    for (0..bytesPerScanLine - 1) |i| {
                        scanLine[i] = @truncate(try std.math.add(usize, scanLine[i], previousScanLine.?[i]) % 256);
                    }
                },
                .Average => {
                    for (0..bytesPerScanLine - 1) |i| {
                        const prior_val = previousScanLine.?[i];

                        const sub: usize = std.math.sub(usize, i, bytesPerPixel) catch 0;
                        const sub_val = scanLine[sub];

                        const average: usize = @divFloor((sub_val + prior_val), 2);

                        scanLine[i] = @truncate(try std.math.add(usize, scanLine[i], average) % 256);
                    }
                },
                .Paeth => {
                    for (0..bytesPerScanLine - 1) |i| {
                        const sub_val: isize = if (i < bytesPerPixel) 0 else scanLine[(i - bytesPerPixel)];

                        const prior_val: isize = previousScanLine.?[i];

                        const prior_bpp_val: isize = if (i < bytesPerPixel) 0 else previousScanLine.?[i - bytesPerPixel];

                        const val = paethPredictor(isize, sub_val, prior_val, prior_bpp_val);

                        const valf: usize = @intCast(try std.math.add(isize, scanLine[i], val));

                        const final_val: u8 = @truncate(valf % 256);
                        scanLine[i] = final_val;
                    }
                },
            }
            try dd.appendSlice(scanLine);
        }
        return dd.toOwnedSlice();
    }

    const Filter = enum { None, Sub, Up, Average, Paeth };

    const ChunkData = union(ChunkType) { IHDR: IHDR, IEND: IEND, IDAT: IDAT, Ancillary: Ancillary };

    const ChunkType = enum { IHDR, IEND, IDAT, Ancillary };

    const Chunk = struct {
        length: u32,
        tipe: []const u8,
        data: []const u8,
        crc: u32,

        fn chunkType(self: Chunk) ChunkType {
            return std.meta.stringToEnum(ChunkType, self.tipe) orelse ChunkType.Ancillary;
        }

        fn parseData(self: Chunk) !ChunkData {
            switch (self.chunkType()) {
                .IHDR => {
                    return ChunkData{ .IHDR = try IHDR.parse(self.data) };
                },
                .IEND => return ChunkData{ .IEND = IEND.parse() },
                .IDAT => return ChunkData{ .IDAT = IDAT.parse(self.data) },
                .Ancillary => return ChunkData{ .Ancillary = Ancillary.parse(self.tipe, self.data) },
            }
        }

        fn parse(reader: *Buffer) !Chunk {
            const length = try readBe(u32, try reader.readNBytes(4));

            var crcHasher = std.hash.crc.Crc32.init();

            const chunkTypeBuf = try reader.readNBytes(4);

            crcHasher.update(chunkTypeBuf);

            const data = try reader.readNBytes(length);

            crcHasher.update(data);

            const crc = try readBe(u32, try reader.readNBytes(4));

            const calculatedCrc32: u32 = crcHasher.final();

            if (calculatedCrc32 != crc) {
                @panic("invalid crc");
            }

            return Chunk{ .length = length, .tipe = chunkTypeBuf, .data = data, .crc = crc };
        }
    };

    const InterlaceMethod = enum { Adam7, NoInterlace };

    pub const IHDR = struct {
        width: u32,
        height: u32,
        bitDepth: u8,
        colorType: u8,
        compressionMethod: u8, //  only accepted value is 0
        filterMethod: u8, // only accepted value is 0,
        interlaceMethod: InterlaceMethod,

        fn parse(data: []const u8) !IHDR {
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
            return IHDR{ .width = width, .height = height, .bitDepth = bitDepth, .colorType = colorType, .compressionMethod = compressionMethod, .filterMethod = filterMethod, .interlaceMethod = interlaceMethod };
        }
    };

    pub const IEND = struct {
        // This does not have any data
        fn parse() IEND {
            return IEND{};
        }
    };

    pub const IDAT = struct {
        data: []const u8,
        fn parse(data: []const u8) IDAT {
            return IDAT{ .data = data };
        }
    };

    pub const Ancillary = struct {
        tipe: []const u8,
        data: []const u8,
        fn parse(tipe: []const u8, data: []const u8) Ancillary {
            return Ancillary{ .tipe = tipe, .data = data };
        }
    };
};

fn readBe(comptime T: type, buf: []const u8) !T {
    if (@sizeOf(T) > buf.len) {
        return error.NotEnoughData;
    }
    const a: T = std.mem.readInt(T, buf[0..@sizeOf(T)], std.builtin.Endian.big);
    return a;
}

fn paethPredictor(comptime T: type, a: T, b: T, c: T) T {
    const p = a + b - c;
    const pa: usize = @abs(p - a);
    const pb: usize = @abs(p - b);
    const pc: usize = @abs(p - c);
    if (pa <= pb and pa <= pc) {
        return a;
    } else if (pb <= pc) {
        return b;
    }
    return c;
}
