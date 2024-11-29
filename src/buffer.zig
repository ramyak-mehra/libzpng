const std = @import("std");

pub const Buffer = struct {
    const Self = @This();
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Self {
        return Self{ .data = data, .pos = 0 };
    }

    pub fn readNBytes(self: *Self, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) {
            return error.EOF;
        }
        const previousPos = self.pos;
        self.pos += n;
        return self.data[previousPos .. previousPos + n];
    }
};
