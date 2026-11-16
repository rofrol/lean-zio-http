const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

// Info level, so that dusty logs "Listening on", the line bench.sh waits for.
pub const std_options: std.Options = .{ .log_level = .info };

fn index(res: *http.Response) !void {
    try res.print(.text, "Hello, World!", .{});
}

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    var server = http.Server(void).init(init.gpa, rt.io(), .{
        .listeners = &.{.{ .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8084) } }},
        .max_connections = 65_536,
    }, {});
    defer server.deinit();
    server.router.get("/", index);
    try server.run();
}
