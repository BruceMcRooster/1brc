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

    comptime assert(max_station_name_length <= 128);

    // vibes-based length, should keep number of collisions low
    const hashmap_len = comptime std.math.ceilPowerOfTwo(usize, max_unique_station_count * 4) catch unreachable;
    const hashmap = try allocator.alloc(
        packed struct {
            name_len: u8,
            top_hash: u8,
            buffer_index: u16,
        },
        hashmap_len,
    );
    @memset(hashmap, @bitCast(@as(u32, 0)));
    defer allocator.free(hashmap);

    // plus one lets us overread when hashing
    const name_buffer = try allocator.alignedAlloc([128]u8, .@"64", max_unique_station_count + 1);
    defer allocator.free(name_buffer);
    const stats_buffer = try allocator.alloc(StationStats, max_unique_station_count);
    defer allocator.free(stats_buffer);
    var next_buffer_insert_index: u16 = 0;

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

    // collisions of indices into the hashmap
    var hashmap_collisions: u64 = 0;
    // collisions of actual hash value + len that requires full string check
    var hash_collisions: u64 = 0;
    
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
            const name: []u8 = read_buffer[file_reader.interface.seek..vector_start_offset + @ctz(semicolon_bitmask_curr) + 1]; // plus 1 for the ';'
            semicolon_bitmask_curr ^= @as(@Int(.unsigned, veclen), 1) << @intCast(@ctz(semicolon_bitmask_curr));

            file_reader.interface.toss(name.len);

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

            // drop semicolon to minimize hash collisions
            const name_hash = xorHash(name[0..name.len-1]);
            comptime assert(std.math.isPowerOfTwo(hashmap_len));
            var hashmap_index: @Int(.unsigned, @ctz(hashmap_len)) = @intCast(name_hash % hashmap_len);
            const expected_value: u32 = @intCast(((name_hash >> 48) & 0xFF00) | @as(u8, @intCast(name.len)));
            assert(blk: {
                const extract = @as(@typeInfo(@TypeOf(hashmap)).pointer.child, @bitCast(expected_value));
                break :blk extract.top_hash == (name_hash >> 56) and extract.name_len == name.len and extract.buffer_index == 0;
            });

            const og_index = hashmap_index;
            
            while (@as(u32, @bitCast(hashmap[hashmap_index])) != 0) : (hashmap_index +%= 1) {
                // TODO: check the assembly to make sure this just masks the value
                if (@as(u32, @bitCast(hashmap[hashmap_index])) & 0xFFFF != expected_value) {
                    continue;
                }
                // TODO: probably unroll this into definitely vectorized comparison, or check the assembly
                if (std.mem.eql(u8, name, name_buffer[hashmap[hashmap_index].buffer_index][0..name.len])) {
                    // found existing value
                    const buffer_index = hashmap[hashmap_index].buffer_index;
                    stats_buffer[buffer_index].count += 1;
                    stats_buffer[buffer_index].sum += value;
                    stats_buffer[buffer_index].min = @min(stats_buffer[buffer_index].min, value);
                    stats_buffer[buffer_index].max = @max(stats_buffer[buffer_index].max, value);
                    break;
                }
                // did not ignore with initial check, so we ran full name compare but it failed
                hash_collisions += 1;
            } else {
                // no existing value, now at an open slot (zeroed)
                hashmap[hashmap_index] = .{ .top_hash = @intCast(name_hash >> 56), .name_len = @intCast(name.len), .buffer_index = next_buffer_insert_index };
                stats_buffer[next_buffer_insert_index] = .{ .count = 1, .sum = value, .min = value, .max = value };
                @memcpy(name_buffer[next_buffer_insert_index][0..name.len], name);
                next_buffer_insert_index += 1;
                // only increment if we had to move to a different index (collision)
                hashmap_collisions += hashmap_index - og_index;
            }
        }
    } else |fill_err| switch (fill_err) {
        error.EndOfStream => {},
        else => {
            return fill_err;
        },
    }

    std.debug.print("hashmap collisions: {}, hash collisions: {}\n", .{hashmap_collisions, hash_collisions});
    
    try finalPrint(name_buffer[0..next_buffer_insert_index], stats_buffer[0..next_buffer_insert_index], writer);
}

inline fn finalPrint(name_buffer: [][128]u8, stats_buffer: []StationStats, writer: *Io.Writer) !void {
    const sort_context: struct {
        name_buffer: [][128] u8,
        stats_buffer: []StationStats,

        pub fn swap(self: *const @This(), elem1: usize, elem2: usize) void {
            std.mem.swap([128]u8, &self.name_buffer[elem1], &self.name_buffer[elem2]);
            std.mem.swap(StationStats, &self.stats_buffer[elem1], &self.stats_buffer[elem2]);
        }

        pub fn lessThan(self: *const @This(), elem1: usize, elem2: usize) bool {
            return std.mem.lessThan(u8, &self.name_buffer[elem1], &self.name_buffer[elem2]);
        }
    } = .{
        .name_buffer = name_buffer,
        .stats_buffer = stats_buffer,
    };
    
    std.sort.heapContext(0, name_buffer.len, sort_context);
    
    try writer.print("{{", .{});
    for (name_buffer, 0..) |name, i| {
        if (i > 0) try writer.print(", ", .{});
                                            // need to slice at null terminator to avoid printing garbage
        try writer.print("{s}=", .{std.mem.sliceTo(&name, ';')});
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

fn xorHash(str: []const u8) u64 {
    const ptr_start: [*]align(1) const u64 = @ptrCast(str.ptr);
    var hash: u64 = undefined;

    const end_mask = blk: {
        const remaining_length = str.len % @sizeOf(u64);
        // and to branchlessly fix the case where remaining_length = 0 (so we don't shift by the entire integer)
        const shift = ((@sizeOf(u64) - remaining_length) & (@sizeOf(u64) - 1)) * @bitSizeOf(u8);
        break :blk @as(u64, 0xFFFF_FFFF_FFFF_FFFF) >> @intCast(shift);
    };
    
    if (str.len <= 16) {
        @branchHint(.likely);
        const is_gt_8_mask: u64 = @bitCast(@as(i64, @intFromBool(str.len > 8)) << 63 >> 63);
        const quad_first = ptr_start[0] & (end_mask | is_gt_8_mask); // if str.len > 8, we just saturate and mask nothing
        hash = quad_first;
        const quad_second = ptr_start[1] & (end_mask & is_gt_8_mask); // if str.len <= 8, we mask any high bits
        hash ^= quad_second;
    } else {
        hash = ptr_start[0] ^ ptr_start[1];
        const index_end = (str.len - 1) / @sizeOf(u64);
        for (ptr_start[2..index_end]) |quad| {
            hash ^= quad;
        } else { // reached end
            const quad_last = ptr_start[index_end] & end_mask;
            hash ^= quad_last;
        }
    }
    
    return hash ^ (hash >> 33) ^ (hash >> 15);
}
