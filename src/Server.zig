const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Address = std.net.Address;
const StreamServer = std.net.StreamServer;
const Connection = StreamServer.Connection;

const Self = @This();

allocator: Allocator,
address: Address,
server: StreamServer,

pub fn init(allocator: Allocator, address: []const u8, port: u16) !Self {
    return Self{
        .allocator = allocator,
        .address = try Address.parseIp(address, port),
        .server = StreamServer.init(.{}),
    };
}

pub fn deinit(self: *Self) void {
    self.server.deinit();
    self.* = undefined;
}

pub fn listen(self: *Self) !void {
    try self.server.listen(self.address);

    std.log.info("[LISTENING] server is listening on {}", .{self.address});

    while (true) {
        const connection = try self.server.accept();
        _ = async self.handle(connection);
    }
}

fn handle(self: Self, connection: Connection) !void {
    defer {
        connection.stream.close();
        std.log.info("[CLOSED] connection closed at {}", .{connection.address});
    }

    std.log.info("[NEW CONNECTION] new connection added at {}", .{connection.address});

    var data = ArrayList(u8).init(self.allocator);
    while (true) {
        data.clearAndFree();

        while (data.items.len < 4 or !std.mem.eql(u8, data.items[data.items.len - 4 ..], "\r\n\r\n")) {
            try data.append(connection.stream.reader().readByte() catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            });
        }

        if (data.items.len == 4) continue;

        const header = parseRequestHeader(data.items);

        const response = try switch (header.method) {
            .invalid => self.errorHead(.bad_request),

            .head => if (header.code == .ok)
                self.successHead(header.path, header.close)
            else
                self.errorHead(header.code),

            .get => if (header.code == .ok)
                self.successGet(header.path, header.close)
            else
                self.errorGet(header.code),
        };
        defer self.allocator.free(response);

        try connection.stream.writer().writeAll(response);

        if (header.close) break;
    }
}

const RequestHeader = struct {
    method: Method,
    code: Code,
    close: bool,
    path: []const u8,

    pub const Method = enum {
        invalid,
        head,
        get,
    };

    pub const Code = enum(u16) {
        ok = 200,
        bad_request = 400,
        not_found = 404,
        method_not_allowed = 405,

        pub fn string(self: Code) []const u8 {
            return switch (self) {
                .ok => "OK",
                .bad_request => "BAD REQUEST",
                .not_found => "NOT FOUND",
                .method_not_allowed => "METHOD NOT ALLOWED",
            };
        }
    };
};

fn parseRequestHeader(message_: []const u8) RequestHeader {
    const message = if (std.mem.startsWith(u8, message_, "\r\n"))
        message_[2..]
    else
        message_;

    var line_iter = std.mem.split(u8, message, "\r\n");
    const request = line_iter.next() orelse return invalid_request_response;

    var request_words_iter = std.mem.split(u8, request, " ");
    const method_string = request_words_iter.next() orelse return invalid_request_response;
    const method = if (std.mem.eql(u8, method_string, "GET"))
        RequestHeader.Method.get
    else if (std.mem.eql(u8, method_string, "HEAD"))
        RequestHeader.Method.head
    else
        return RequestHeader{
            .method = .invalid,
            .code = .method_not_allowed,
            .close = true,
            .path = "",
        };

    const path = blk: {
        var path = request_words_iter.next() orelse return invalid_request_response;
        if (std.mem.eql(u8, path, "/")) break :blk "index.html";
        const index = std.mem.indexOf(u8, message_, path) orelse unreachable;
        break :blk message_[index + 1 .. index + path.len];
    };

    const exists = if (std.fs.cwd().access(path, .{})) |_| true else |_| false;
    if (!exists) return RequestHeader{
        .method = .get,
        .code = .not_found,
        .close = true,
        .path = path,
    };

    const close = while (line_iter.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Connection: ")) continue;
        if (std.mem.eql(u8, line["Connection: ".len..], "close")) {
            break true;
        }
    } else false;

    return RequestHeader{
        .method = method,
        .code = .ok,
        .close = close,
        .path = path,
    };
}

const invalid_request_response = RequestHeader{
    .method = .invalid,
    .code = .bad_request,
    .close = true,
    .path = "",
};

fn successHead(self: Self, path: []const u8, close: bool) ![]const u8 {
    std.log.info("[HEAD] successful HEAD request to '{s}'", .{path});
    return try self.success(path, close, false);
}

fn successGet(self: Self, path: []const u8, close: bool) ![]const u8 {
    std.log.info("[HEAD] successful GET request to '{s}'", .{path});
    return try self.success(path, close, true);
}

fn success(self: Self, path: []const u8, close: bool, get: bool) ![]const u8 {
    var result = ArrayList(u8).init(self.allocator);
    errdefer result.deinit();

    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const size = try file.getEndPos();

    try result.appendSlice("HTTP1.1 200 OK\r\n");
    try result.appendSlice("Content-Type: text/html\r\n");
    try result.writer().print("Content-Length: {d}\r\n", .{size});
    if (close) try result.appendSlice("Connection: close\r\n");
    try result.appendSlice("\r\n");

    if (get) try file.reader().readAllArrayList(&result, std.math.maxInt(usize));

    return result.toOwnedSlice();
}

fn errorHead(self: Self, code: RequestHeader.Code) ![]const u8 {
    std.log.info("[HEAD] unsuccessful HEAD request with error code {d}", .{@enumToInt(code)});
    return self.@"error"(code, false);
}

fn errorGet(self: Self, code: RequestHeader.Code) ![]const u8 {
    std.log.info("[HEAD] unsuccessful GET request with error code {d}", .{@enumToInt(code)});
    return self.@"error"(code, true);
}

fn @"error"(self: Self, code: RequestHeader.Code, get: bool) ![]const u8 {
    var result = ArrayList(u8).init(self.allocator);
    errdefer result.deinit();

    const html = @embedFile("error.html");
    const code_string = code.string();

    try result.writer().print("HTTP/1.1 {d}: {s}\r\n", .{ @enumToInt(code), code_string });
    try result.appendSlice("Content-Type: text/html\r\n");
    try result.writer().print("Content-Length: {d}\r\n", .{html.len});
    try result.appendSlice("Connection: close\r\n");
    try result.appendSlice("\r\n");

    if (get) try result.writer().print(
        html,
        .{ @enumToInt(code), code_string, @enumToInt(code), code_string },
    );

    return result.toOwnedSlice();
}
