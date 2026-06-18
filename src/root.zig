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

    const veclen = std.simd.suggestVectorLength(u8) orelse 8; // orelse must fall back to at least 6
    comptime assert(veclen >= 6); // so that a float value (including newline) never crosses two boundaries
    
    // align to vector reads
    // allocate a little extra to guarantee reads potentially past their known slices
    const read_buffer = try allocator.alignedAlloc(u8, .fromByteUnits(veclen), 1024 * 1024 + 128);
    defer allocator.free(read_buffer);

    var file_reader = file.reader(io, read_buffer[0..(1024 * 1024)]);
    
    var semicolon_bitmask_curr: @Int(.unsigned, veclen) = undefined;
    var vector_start_offset: usize = undefined;
    var newline_last: usize = undefined;

    while (file_reader.interface.fillMore()) {
        assert(file_reader.interface.seek == 0);
        newline_last = std.mem.findLast(u8, read_buffer[0..file_reader.interface.end], "\n") orelse unreachable;
        vector_start_offset = 0;
        semicolon_bitmask_curr = grabSemicolonBitmask(veclen, @ptrCast(read_buffer.ptr));

        while (file_reader.interface.seek < newline_last) {
            while (semicolon_bitmask_curr == 0) {
                vector_start_offset += veclen;
                semicolon_bitmask_curr = grabSemicolonBitmask(veclen, @alignCast(@ptrCast(read_buffer.ptr + vector_start_offset)));
            }
            const name: []u8 = read_buffer[file_reader.interface.seek..vector_start_offset + @ctz(semicolon_bitmask_curr)];
            semicolon_bitmask_curr ^= @as(@Int(.unsigned, veclen), 1) << @intCast(@ctz(semicolon_bitmask_curr));

            file_reader.interface.toss(name.len + 1); // plus 1 for the ';'

            // credit to @merykitty for this implementation
            // and https://questdb.com/blog/billion-row-challenge-step-by-step/ for explaining
            const value: i16 = read_value: {
                const value_ptr_start: *align(1) u64 = @ptrCast(read_buffer.ptr + file_reader.interface.seek);
                const number_bytes = value_ptr_start.*;
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
                const result = @as(i16, @truncate(@as(i64, @bitCast((abs_value +% signed) ^ signed))));

                // advance the file reader past the value and newline
                const prev_seek = file_reader.interface.seek;
                file_reader.interface.toss(@intCast(
                    -@as(i64, @bitCast(signed)) // possibly a negative sign
                    + @intFromBool(abs_value > 99) // possibly a 10s place
                    + 3 // x.x
                    + 1 // \n
                ));
                assert(read_buffer[file_reader.interface.seek - 1] == '\n');
                const multiple_of_veclen_mask = ~(@as(usize, veclen) - 1);
                // detect if we crossed a vector boundary (can cross one at max)
                assert(prev_seek & multiple_of_veclen_mask == file_reader.interface.seek & multiple_of_veclen_mask
                    or semicolon_bitmask_curr == 0); // if we did cross a vector boundary, we should be out of existing semicolons
                                                     // so that the iterator will increment the vector start offset and find a new one
                    
                break :read_value result;
            };
            
            const lookup = try hashmap.getOrPut(name);
            if (!lookup.found_existing) {
                const allocated_name = try string_allocator.alloc(u8, name.len);
                _ = @memcpy(allocated_name, name);
                lookup.key_ptr.* = allocated_name;
                lookup.value_ptr.* = .{ .min = value, .max = value, .sum = value, .count = 1 };
            } else {
                lookup.value_ptr.*.min = @min(lookup.value_ptr.*.min, value);
                lookup.value_ptr.*.max = @max(lookup.value_ptr.*.max, value);
                lookup.value_ptr.*.sum += value;
                lookup.value_ptr.*.count += 1;
            }
        }
    } else |fill_err| switch (fill_err) {
        error.EndOfStream => {},
        else => {
            return fill_err;
        },
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
            const partial_result = @divFloor(stats.sum * 10, @as(i64, @intCast(stats.count)));
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

fn grabSemicolonBitmask(veclen: comptime_int, ptr: *const @Vector(veclen, u8)) @Int(.unsigned, veclen) {
    const Int = @Int(.unsigned, veclen);
    const Vec = @Vector(veclen, u8);
    const vec: Vec = ptr.*;
    const semicolons: Int = @bitCast(vec == @as(Vec, @splat(';')));
    return semicolons;
}
