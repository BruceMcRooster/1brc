//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

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

    // align to vector reads (64 bytes)
    const read_buffer = try allocator.alignedAlloc(u8, .@"64", 1024 * 1024);
    defer allocator.free(read_buffer);

    var file_reader = file.reader(io, read_buffer);

    var separator_bitmask_curr: u128 = 0;
    var state: union(enum) {
        reading_name: void,
        reading_value: struct {
            stats: *StationStats,
            // whether we should just updated the stats
            // instead of overwriting them with our new values (because there were no stats)
            do_update: bool
        }
    } = .reading_name;

    readloop: while (true) {
        const buffer_curr: []u8 = get_buff: {
            if (separator_bitmask_curr != 0) {
                const buffer_start = file_reader.interface.seek;
                const buffer_end = blk: {
                    const separator_bitmask_start = buffer_start & ~@as(usize, 127); // round down to nearest multiple of 128
                    const next_offset: usize = @ctz(separator_bitmask_curr);
                    assert(next_offset < 128); // not at the end, because we know it wasn't zero
                    break :blk separator_bitmask_start + next_offset;
                };
                separator_bitmask_curr ^= @as(u128, 1) << @intCast(@ctz(separator_bitmask_curr));
                const new_buff = read_buffer[buffer_start..buffer_end];
                file_reader.interface.toss(new_buff.len + 1); // add one for separator
                break :get_buff new_buff;
            } else {
                // the size required to be loaded so we can safely read the next vector.
                // because when asking for this sizing to be available with fill,
                // we may be rebased to the beginning, we may not end up reading all of it,
                // but this is what is required if that is not the case
                const required_size_next: usize = blk: {
                    const up_to_next_128_multiple = ((file_reader.interface.seek + 127) & ~@as(usize, 127)) - file_reader.interface.seek;
                    break :blk 128 + up_to_next_128_multiple;
                };
                if (file_reader.interface.fill(required_size_next)) {
                    // have to reread here, because it may have changed due to rebase in fill
                    const buffer_start = file_reader.interface.seek;
                    
                    const next_vec_start = (file_reader.interface.seek + 127) & ~@as(usize, 127);
                    separator_bitmask_curr = blk: {
                        const array: *align(64) [128]u8 = @ptrCast(@alignCast(read_buffer[next_vec_start..][0..128]));
                        const vec: @Vector(128, u8) = array.*;
                        const separators = (vec == @as(@Vector(128, u8), @splat(';'))) | (vec == @as(@Vector(128, u8), @splat('\n')));
                        break :blk @bitCast(separators);
                    };
                    const in_vec_separator_offset: usize = @ctz(separator_bitmask_curr);
                    separator_bitmask_curr ^= @as(u128, 1) << @intCast(in_vec_separator_offset);
                    const buffer_end = next_vec_start + in_vec_separator_offset;

                    const new_buff = read_buffer[buffer_start..buffer_end];
                    file_reader.interface.toss(new_buff.len + 1); // +1 for separator
                    break :get_buff new_buff;
                } else |err| {
                    if (err == error.ReadFailed) {
                        @branchHint(.cold);
                        return err;
                    }
                    // EndOfStream indicates we cannot make another full vectorized read
                    // so we must instead use simpler techniques
                    switch (state) {
                        .reading_name => {
                            // returns null if at the end of the stream (0 bytes remain), which signals we're done reading
                            break :get_buff try file_reader.interface.takeDelimiter(';') orelse break :readloop;
                        },
                        .reading_value => {
                            // probably won't ever return null (out of bytes) since generated files have final newlines
                            // (it will fail the next time around while reading name),
                            // but just in case, it's handled
                            break :get_buff try file_reader.interface.takeDelimiter('\n') orelse break :readloop;
                        }
                    }
                }
            }
        }; // buffer_curr
        switch (state) {
            .reading_name => {
                const lookup = try hashmap.getOrPut(buffer_curr);
                if (!lookup.found_existing) {
                    const allocated_name = try string_allocator.alloc(u8, buffer_curr.len);
                    _ = @memcpy(allocated_name, buffer_curr);
                    lookup.key_ptr.* = allocated_name;
                }
                state = .{ .reading_value = .{ .do_update = lookup.found_existing, .stats = lookup.value_ptr } };
            },
            .reading_value => |value_state| {
                const value = try std.fmt.parseFloat(f32, buffer_curr);
                var new_value: StationStats = undefined;
                if (value_state.do_update) {
                    new_value = .{
                        .min = @min(value_state.stats.min, value),
                        .max = @max(value_state.stats.max, value),
                        .sum = value_state.stats.sum + value,
                        .count = value_state.stats.count + 1,
                    };
                } else {
                    new_value = .{ .min = value, .max = value, .sum = value, .count = 1 };
                }
                value_state.stats.* = new_value;

                state = .reading_name;
            }
        }
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
