const std = @import("std");
const Io = std.Io;

const _1brc = @import("_1brc");

pub fn main(init: std.process.Init) !void {
    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    const allocator = init.gpa;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    _ = args.skip();
    const file_name = args.next() orelse "data/measurements.txt";

    var print_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &print_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    
    try _1brc.printStats(file_name, allocator, io, stdout_writer);
}
