//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

const max_station_name_length = 100;
const max_unique_station_count = 10_000;

/// Computes and prints the statistics for the given file to stdout,
/// in the format specified by the challenge
/// (`{Abha=-23.0/18.0/59.2, Abidjan=-16.2/26.0/67.3, ...}`).
pub fn printStats(
    file_name: []const u8,
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
) !void {
    const file = try Io.Dir.openFile(Io.Dir.cwd(), io, file_name, .{ .mode = .read_only });
    defer file.close(io);
    
    // lines are: <name:100 bytes max>;(-)dd.d\n = 107 bytes max
    var line_buffer: [107]u8 = undefined;
    var file_reader = file.reader(io, &line_buffer);

    const StationStats = struct {
        min: f32,
        max: f32,
        sum: f64,
        count: u32
    };
    
    var hashmap = std.StringHashMap(StationStats).init(allocator);
    try hashmap.ensureTotalCapacity(max_unique_station_count * 4); // vibes-based number, will get rounded up to nearest power of 2 internally
    defer hashmap.deinit();

    const string_buffer = try allocator.alloc(u8, max_station_name_length * max_unique_station_count);
    defer allocator.free(string_buffer);
    var string_buffer_allocator = std.heap.FixedBufferAllocator.init(string_buffer);
    const string_allocator = string_buffer_allocator.allocator();

    readloop: while (true) {
        const name = file_reader.interface.takeDelimiterExclusive(';') catch |err| {
            if (err == error.EndOfStream) {
                break :readloop;
            } else {
                return err;
            }
        };
        if (name.len == 0) break;
        const lookup = try hashmap.getOrPut(name);
        if (!lookup.found_existing) {
            const allocated_name = try string_allocator.alloc(u8, name.len);
            _ = @memcpy(allocated_name, name);
            lookup.key_ptr.* = allocated_name;
        }
        const semicolon = try file_reader.interface.takeByte();
        std.debug.assert(semicolon == ';');
        const temp = try file_reader.interface.takeDelimiterExclusive('\n');
        if (temp.len == 0) break;
        const value = try std.fmt.parseFloat(f32, temp);
        // we probably just read past the end (might not have a terminal newline on last byte)
        var found_end = false;
        const newline = file_reader.interface.takeByte() catch |err| blk: {
            if (err == error.EndOfStream) {
                found_end = true;
            } else {
                return err;
            }
            break :blk '\n'; // satisfy the assert, and give some value
        };
        std.debug.assert(newline == '\n');

        var new_value: StationStats = undefined;
        if (lookup.found_existing) {
            new_value = .{
                .min = @min(lookup.value_ptr.min, value),
                .max = @max(lookup.value_ptr.max, value),
                .sum = lookup.value_ptr.sum + value,
                .count = lookup.value_ptr.count + 1,
            };
        } else {
            new_value = .{ .min = value, .max = value, .sum = value, .count = 1 };
        }
        lookup.value_ptr.* = new_value;
    }

    var name_buffer = try allocator.alloc([]const u8, hashmap.count());
    defer allocator.free(name_buffer);
    var stats_buffer = try allocator.alloc(StationStats, hashmap.count());
    defer allocator.free(stats_buffer);
    
    var iterator = hashmap.iterator();
    var curr_index: usize = 0;
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const stats = entry.value_ptr.*;
        name_buffer[curr_index] = name;
        stats_buffer[curr_index] = stats;
        curr_index += 1;
    }

    const sort_context: struct {
        name_buffer: [][]const u8,
        stats_buffer: []StationStats,

        pub fn swap(self: *const @This(), elem1: usize, elem2: usize) void {
            std.mem.swap([]const u8, &self.name_buffer[elem1], &self.name_buffer[elem2]);
            std.mem.swap(StationStats, &self.stats_buffer[elem1], &self.stats_buffer[elem2]);
        }

        pub fn lessThan(self: *const @This(), elem1: usize, elem2: usize) bool {
            return std.mem.lessThan(u8, self.name_buffer[elem1], self.name_buffer[elem2]);
        }
    } = .{ 
        .name_buffer = name_buffer,
        .stats_buffer = stats_buffer,
    };
    
    std.sort.heapContext(0, name_buffer.len, sort_context);
    try writer.print("{{", .{});
    for (name_buffer, 0..) |name, i| {
        if (i > 0) try writer.print(", ", .{});
        try writer.print("{s}=", .{name});
        const stats = stats_buffer[i];
        const average = blk: {
            const partial_result = @floor(stats.sum * 10 + 0.5) / 10 / @as(f64, stats.count);
            // apparently this works for Java Math, so it works for me
            break :blk @floor(partial_result * 10 + 0.5) / 10;
        };
        try writer.print(
            "{d:.1}/{d:.1}/{d:.1}",
            .{stats.min, average, stats.max}
        );
    }
    try writer.print("}}\n", .{});
    try writer.flush();
}
