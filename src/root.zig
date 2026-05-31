//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// Computes and prints the statistics for the given file to stdout,
/// in the format specified by the challenge
/// (`{Abha=-23.0/18.0/59.2, Abidjan=-16.2/26.0/67.3, ...}`).
pub fn printStats(
    file_name: []const u8,
    allocator: std.mem.Allocator,
    io: Io,
) !void {
    const file = try Io.Dir.openFile(Io.Dir.cwd(), io, file_name, .{ .mode = .read_only });
    defer file.close(io);
    
    // lines are: <name:100 bytes max>;(-)dd.d\n = 107 bytes max
    var line_buffer: [107]u8 = undefined;
    var file_reader = file.reader(io, &line_buffer);

    const StationStats = struct {
        // since floats only have one decimal place, these just represent them as value * 10
        // to avoid all floating point math
        min: i16,
        max: i16,
        sum: i64,
        count: u64
    };
    
    var hashmap = std.StringHashMap(StationStats).init(allocator);
    defer hashmap.deinit();
    defer {
        var it = hashmap.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
    }


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
            const allocated_name = try allocator.alloc(u8, name.len);
            _ = @memcpy(allocated_name, name);
            lookup.key_ptr.* = allocated_name;
        }
        const semicolon = try file_reader.interface.takeByte();
        std.debug.assert(semicolon == ';');
        const temp = try file_reader.interface.takeDelimiterExclusive('\n');
        if (temp.len == 0) break;
        const decimal_offset: u8 = blk: {
            if (temp[1] == '.') {
                break :blk 1;
            } else if (temp[2] == '.') {
                break :blk 2;
            } else {
                break :blk 3;
            }
        };
        std.debug.assert(temp[decimal_offset] == '.');
        const predecimal = try std.fmt.parseInt(i8, temp[0..decimal_offset], 10);
        const postdecimal = try std.fmt.parseInt(u8, temp[decimal_offset + 1 ..], 10);
        const value = @as(i16, predecimal) * 10 + postdecimal;
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

    var iterator = hashmap.iterator();
    std.debug.print("{{", .{});
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const stats = entry.value_ptr;
        std.debug.print("{s}={}/{}/{d:.1}, ", .{name, stats.min, stats.max, @as(f64, @floatFromInt(stats.sum)) / @as(f64, @floatFromInt(stats.count))});
    }
    std.debug.print("}}\n", .{});
}
