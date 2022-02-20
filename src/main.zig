const std = @import("std");

const http = @import("lib.zig");
const Server = http.Server;

pub const io_mode = .evented;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const allocator = gpa.allocator();

    var server = try Server.init(allocator, "127.0.0.1", 12345);
    defer server.deinit();

    try server.listen();
}
