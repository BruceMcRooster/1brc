//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const assert = std.debug.assert;

const max_station_name_length = 100;
const max_unique_station_count = 10_000;

const StationStats = struct {
    min: i16,
    max: i16,
    sum: i64,
    count: u32
};

const State = union(enum) {
    reading_name: void,
    reading_value: struct {
        stats: *StationStats,
        // whether we should just updated the stats
        // instead of overwriting them with our new values (because there were no stats)
        do_update: bool
    }
};

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
    
    var hashmap = std.StringHashMap(StationStats).init(allocator);
    try hashmap.ensureTotalCapacity(max_unique_station_count * 4); // vibes-based number, will get rounded up to nearest power of 2 internally
    defer hashmap.deinit();

    const string_buffer = try allocator.alloc(u8, max_station_name_length * max_unique_station_count);
    defer allocator.free(string_buffer);
    var string_buffer_allocator = std.heap.FixedBufferAllocator.init(string_buffer);
    const string_allocator = string_buffer_allocator.allocator();

    // align to vector reads (64 bytes)
    // allocate a little extra to guarantee reads potentially past their known slices
    const read_buffer = try allocator.alignedAlloc(u8, .@"64", 1024 * 1024 + 128);
    defer allocator.free(read_buffer);

    var file_reader = file.reader(io, read_buffer[0..(1024 * 1024)]);

    var separator_bitmask_curr: u128 = 0;
    var state: State = .reading_name;

    readloop: while (true) {
        const buffer_curr: []u8 = get_buff: {
            if (separator_bitmask_curr != 0) {
                break :get_buff handleNonzeroBitmask(&separator_bitmask_curr, read_buffer, &file_reader.interface);
            } else {
                break :get_buff handleZeroBitmask(&separator_bitmask_curr, read_buffer, &file_reader.interface, state) catch |err| switch (err) {
                    error.EndOfStream => {
                        break :readloop;
                    },
                    else => {
                        @branchHint(.cold);
                        return err;
                    }
                };
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
                const value = parseFloat(buffer_curr);
                if (builtin.mode == .Debug) {
                    assert(value == @as(i16, @trunc(try std.fmt.parseFloat(f32, buffer_curr) * 10)));
                }
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
    try finalPrint(&allocator, hashmap, writer);
}

inline fn finalPrint(allocator: *const std.mem.Allocator, hashmap: std.StringHashMap(StationStats), writer: *Io.Writer) !void {
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
            const partial_result = @divTrunc(stats.sum * 10, @as(i64, @intCast(stats.count)));
            break :blk @divFloor(partial_result + 5, 10);
        };
        try writer.print(
            "{s}{d}.{d}/{s}{d}.{d}/{s}{d}.{d}",
            .{
                if (stats.min < 0) "-" else "", @abs(@divTrunc(stats.min, 10)), @abs(@rem(stats.min, 10)),
                if (average < 0) "-" else "", @abs(@divTrunc(average, 10)), @abs(@rem(average, 10)),
                if (stats.max < 0) "-" else "", @abs(@divTrunc(stats.max, 10)), @abs(@rem(stats.max, 10))}
        );
    }
    try writer.print("}}\n", .{});
    try writer.flush();
}

// credit to @merykitty for this implementation
// and https://questdb.com/blog/billion-row-challenge-step-by-step/ for explaining
inline fn parseFloat(buffer_curr: []u8) i16 {
    // we can read 1 64-bit value to always get the up to 5 bytes of the number representation
    // safe because we added extra padding to the buffer
    const number_bytes = @as(*align(1) u64, @ptrCast(buffer_curr.ptr)).*;
    const inv_number_bytes = ~number_bytes;

    // downcasting to u32 to get a u6 instead of a u7,
    // because Zig wants a u6 for the shift by _28_minus_dot_pos later.
    // totally safe because mask will remove any higher bits
    const dot_pos: u6 = @ctz(@as(u32, @intCast(inv_number_bytes & 0x10101000)));
    // micro-optimization: can save one instruction (xor 28 instead of mov 28, sub that other)
    const _28_minus_dot_pos = dot_pos ^ 0b11100;
    // inverse of '-' (0x2D) has 0x10 bit toggled, while any numbers (0x30–0x39) do not,
    // so get a mask of all 1's if that is set in the first byte (it's a '-') or 0's otherwise
    const signed: u64 = @bitCast(@as(i64, @bitCast(inv_number_bytes << 59)) >> 63);
    const minus_filter = ~(signed & 0xFF);

    // extract the decimal values (0–9 is 0x30–0x39, so 0xF mask gets values)
    // at the computed positions of each decimal
    const digits = ((number_bytes & minus_filter) << _28_minus_dot_pos) & 0x0F000F0F00;

    // Multiplies each digit with the appropriate power of ten.
    // Representing 0 as . for readability,
    // 0x.......U...T.H.. * (100 * 0x1000000 + 10 * 0x10000 + 1) =
    // 0x.U...T.H........ * 100 +
    // 0x...U...T.H...... * 10 +
    // 0x.......U...T.H..
    //          ^--- H, T, and U are lined up here.
    // This results in our temperature lying in bits 32 to 41 of this product.
    const MAGIC_MULTIPLIER = (100 * 0x1000000 + 10 * 0x10000 + 1);
    const abs_value = ((digits *% MAGIC_MULTIPLIER) >> 32) & 0x3FF;
    // sign is either all 1's or all 0's, so this conditionally negates
    return @as(i16, @truncate(@as(i64, @bitCast((abs_value +% signed) ^ signed))));
}

inline fn handleNonzeroBitmask(separator_bitmask_curr: *u128, read_buffer: []u8, reader: *Io.Reader) []u8 {
    const buffer_start = reader.seek;
    const buffer_end = blk: {
        const separator_bitmask_start = buffer_start & ~@as(usize, 127); // round down to nearest multiple of 128
        const next_offset: usize = @ctz(separator_bitmask_curr.*);
        assert(next_offset < 128); // not at the end, because we know it wasn't zero
        break :blk separator_bitmask_start + next_offset;
    };
    separator_bitmask_curr.* ^= @as(u128, 1) << @intCast(@ctz(separator_bitmask_curr.*));
    const new_buff = read_buffer[buffer_start..buffer_end];
    reader.toss(new_buff.len + 1); // add one for separator
    return new_buff;
}

inline fn handleZeroBitmask(separator_bitmask_curr: *u128, read_buffer: []u8, reader: *Io.Reader, state: State) ![]u8 {
    // the size required to be loaded so we can safely read the next vector.
    // because when asking for this sizing to be available with fill,
    // we may be rebased to the beginning, we may not end up reading all of it,
    // but this is what is required if that is not the case
    const required_size_next: usize = blk: {
        const up_to_next_128_multiple = ((reader.seek + 127) & ~@as(usize, 127)) - reader.seek;
        break :blk 128 + up_to_next_128_multiple;
    };
    if (reader.fill(required_size_next)) {
        // have to reread here, because it may have changed due to rebase in fill
        const buffer_start = reader.seek;
        
        const next_vec_start = (reader.seek + 127) & ~@as(usize, 127);
        separator_bitmask_curr.* = grabNewSeparatorBitmask(read_buffer, next_vec_start);
        const in_vec_separator_offset: usize = @ctz(separator_bitmask_curr.*);
        separator_bitmask_curr.* ^= @as(u128, 1) << @intCast(in_vec_separator_offset);
        const buffer_end = next_vec_start + in_vec_separator_offset;

        const new_buff = read_buffer[buffer_start..buffer_end];
        reader.toss(new_buff.len + 1); // +1 for separator
        return new_buff;
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
                return try reader.takeDelimiter(';') orelse return err;
            },
            .reading_value => {
                // probably won't ever return null (out of bytes) since generated files have final newlines
                // (it will fail the next time around while reading name),
                // but just in case, it's handled
                return try reader.takeDelimiter('\n') orelse return err;
            }
        }
    }
}

inline fn grabNewSeparatorBitmask(read_buffer: []u8, next_vec_start: usize) u128 {
    const array: *align(64) [128]u8 = @ptrCast(@alignCast(read_buffer[next_vec_start..][0..128]));
    const vec: @Vector(128, u8) = array.*;
    const separators = (vec == @as(@Vector(128, u8), @splat(';'))) | (vec == @as(@Vector(128, u8), @splat('\n')));
    return @bitCast(separators);
}
