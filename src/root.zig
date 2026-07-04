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

    const string_pool = try allocator.alloc(u8, max_unique_station_count * max_station_name_length);
    defer allocator.free(string_pool);

    var string_pool_buff_allocator = std.heap.FixedBufferAllocator.init(string_pool);
    const string_pool_allocator = string_pool_buff_allocator.allocator();
    
    var hashmap: SwissTable = try .init(hashmap_len, allocator, string_pool_allocator);
    defer hashmap.deinit(allocator);

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

            try hashmap.update(name, value);
        }
    } else |fill_err| switch (fill_err) {
        error.EndOfStream => {},
        else => {
            return fill_err;
        },
    }

    std.debug.print("hash collisions: {}\n", .{hashmap.hash_collisions});

    // plus 16 gives us a tiny amount of wiggle room that shouldn't be necessary just so we don't fail to slice 16 names forward
    // in the hashtable extractAll function
    const sorted_names_buffer = try allocator.alloc([]const u8, max_unique_station_count + 16);
    const sorted_stats_buffer = try allocator.alloc(StationStats, max_unique_station_count + 16);
    defer allocator.free(sorted_names_buffer);
    defer allocator.free(sorted_stats_buffer);
    const total_count = hashmap.extractAll(sorted_names_buffer, sorted_stats_buffer);
    assert(total_count <= max_unique_station_count);
    const sorted_names = sorted_names_buffer[0..total_count];
    const sorted_stats = sorted_stats_buffer[0..total_count];

    const sort_context: struct {
        name_buffer: [][]const u8,
        stats_buffer: []StationStats,

        pub fn swap(self: *const @This(), elem1: usize, elem2: usize) void {
            std.mem.swap([]const u8, &self.name_buffer[elem1], &self.name_buffer[elem2]);
            std.mem.swap(StationStats, &self.stats_buffer[elem1], &self.stats_buffer[elem2]);
        }

        pub fn lessThan(self: *const @This(), elem1: usize, elem2: usize) bool {
            return stringCompareAssumingSafeOOB(self.name_buffer[elem1], self.name_buffer[elem2]) == .lt;
        }
    } = .{
        .name_buffer = sorted_names,
        .stats_buffer = sorted_stats,
    };

    std.sort.heapContext(0, sorted_names.len, sort_context);
    
    try finalPrint(sorted_names, sorted_stats, writer);
}

inline fn finalPrint(sorted_names: [][]const u8, sorted_stats: []StationStats, writer: *Io.Writer) !void {    
    try writer.print("{{", .{});
    for (sorted_names, 0..) |name, i| {
        if (i > 0) try writer.print(", ", .{});

        try writer.print("{s}=", .{name});
        const stats = sorted_stats[i];
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

// Assumes we can safely read up to one native vector length (std.simd.suggestVectorLength(u8))
// past the end of the string to allow for faster comparisons
fn stringEqualAssumingSafeOOB(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    const Vec = @Vector(std.simd.suggestVectorLength(u8) orelse 1, u8);

    var i: usize = 0;
    while (i < a.len & ~@as(usize, @sizeOf(Vec) - 1)) : (i += @sizeOf(Vec)) {
        const a_vec: [*]align(1) const Vec = @ptrCast(a.ptr + i);
        const b_vec: [*]align(1) const Vec = @ptrCast(b.ptr + i);
        if (!@reduce(.And, a_vec[0] == b_vec[0])) return false;
    }
    const remainder = a.len % @sizeOf(Vec);
    if (remainder != 0) { // we have a remainder
        const a_vec: [*]align(1) const Vec = @ptrCast(a.ptr + i);
        const b_vec: [*]align(1) const Vec = @ptrCast(b.ptr + i);
        const unequal_bitmask: @Int(.unsigned, @sizeOf(Vec)) = @bitCast(a_vec[0] != b_vec[0]);
        if (@ctz(unequal_bitmask) < remainder) return false;
    }
    return true;
}

fn stringCompareAssumingSafeOOB(a: []const u8, b: []const u8) std.math.Order {
    const Vec = @Vector(std.simd.suggestVectorLength(u8) orelse 1, u8);

    const min_len = @min(a.len, b.len);

    var i: usize = 0;
    while (i < min_len & ~@as(usize, @sizeOf(Vec) - 1)) : (i += @sizeOf(Vec)) {
        const a_vec: [*]align(1) const Vec = @ptrCast(a.ptr + i);
        const b_vec: [*]align(1) const Vec = @ptrCast(b.ptr + i);
        const unequal_bitmask: @Int(.unsigned, @sizeOf(Vec)) = @bitCast(a_vec[0] != b_vec[0]);
        if (unequal_bitmask != 0) {
            return std.math.order(a[i + @ctz(unequal_bitmask)], b[i + @ctz(unequal_bitmask)]);
        }
    }
    const remainder = a.len % @sizeOf(Vec);
    if (remainder != 0) {
        const a_vec: [*]align(1) const Vec = @ptrCast(a.ptr + i);
        const b_vec: [*]align(1) const Vec = @ptrCast(b.ptr + i);
        const unequal_bitmask: @Int(.unsigned, @sizeOf(Vec)) = @bitCast(a_vec[0] != b_vec[0]);
        if (unequal_bitmask != 0 and @ctz(unequal_bitmask) < remainder) {
            return std.math.order(a[i + @ctz(unequal_bitmask)], b[i + @ctz(unequal_bitmask)]);
        }
    }
    return std.math.order(a.len, b.len);
}

test "stringEqualAssumingSafeOOB" {
    const expect = std.testing.expect;

    const pool = "hello world abcdefg. my very long string which is long!!my very long string which is longer. random padding I shouldn't use to make sure the vector can safely read past the end";
    // large native len may mean out-of-bounds read in test, could need more padding
    comptime assert(pool.len - 91 >= (std.simd.suggestVectorLength(u8) orelse 1));

    try expect(stringEqualAssumingSafeOOB(pool[0..5], pool[0..5]));
    try expect(!stringEqualAssumingSafeOOB(pool[0..5], pool[6..11]));
    try expect(stringEqualAssumingSafeOOB(pool[12..18], pool[12..18]));
    try expect(!stringEqualAssumingSafeOOB(pool[12..18], pool[12..19]));

    const a = pool[21..56]; // my very...is long!!
    const b = pool[56..91]; // my very...is longer
    comptime assert(a.len == b.len); // need to actually test boundary condition

    try expect(!stringEqualAssumingSafeOOB(a, b));

    const equal_up_to = 33;
    comptime assert(std.mem.eql(u8, a[0..equal_up_to], b[0..equal_up_to]));
    comptime assert(!std.mem.eql(u8, a[0..equal_up_to+1], b[0..equal_up_to+1]));

    try expect(stringEqualAssumingSafeOOB(a[0..equal_up_to], b[0..equal_up_to]));
}

test "stringCompareAssumingSafeOOB" {
    const expect = std.testing.expect;

    const pool = "hello world abcdefg. my very long string which is long!!my very long string which is longer. random padding I shouldn't use to make sure the vector can safely read past the end";
    // large native len may mean out-of-bounds read in test, could need more padding
    comptime assert(pool.len - 91 >= (std.simd.suggestVectorLength(u8) orelse 1));

    try expect(stringCompareAssumingSafeOOB(pool[0..5], pool[0..5]) == .eq);
    try expect(stringCompareAssumingSafeOOB(pool[0..5], pool[6..11]) == .lt);
    try expect(stringCompareAssumingSafeOOB(pool[12..18], pool[12..18]) == .eq);
    try expect(stringCompareAssumingSafeOOB(pool[12..18], pool[12..19]) == .lt);

    const a = pool[21..56]; // my very...is long!!
    const b = pool[56..91]; // my very...is longer

    try expect(stringCompareAssumingSafeOOB(a, b) == .lt);

    const equal_up_to = 33;
    comptime assert(std.mem.eql(u8, a[0..equal_up_to], b[0..equal_up_to]));
    comptime assert(!std.mem.eql(u8, a[0..equal_up_to+1], b[0..equal_up_to+1]));

    try expect(stringCompareAssumingSafeOOB(a[0..equal_up_to], b[0..equal_up_to]) == .eq);

    try expect(stringCompareAssumingSafeOOB(a[0..equal_up_to], b[0..equal_up_to+1]) == .lt);
}

const SwissTable = struct {
    const Metadata = packed struct {
        name_hash_top: u7,
        in_use: bool,

        fn fromHash(hash: u64) @This() {
            return @bitCast(
                @as(@typeInfo(@This()).@"struct".backing_integer orelse unreachable, 
                    @intCast(hash >> (@bitSizeOf(u64) - 7) | 0x80))
            );
        }
    };
    const Block = @Vector(16, @typeInfo(Metadata).@"struct".backing_integer orelse unreachable);

    data: []Block,
    names: [][]const u8,
    stats: []StationStats,
    name_allocator: std.mem.Allocator,
    // for stats
    hash_collisions: u64, // number of times a full string comparison is needed but comes back false

    fn init(len: usize, allocator: std.mem.Allocator, name_allocator: std.mem.Allocator) !@This() {
        const data = try allocator.alloc(Block, len);
        @memset(data, @as(Block, @splat(0)));
        
        return .{
            .data = data,
            .names = try allocator.alloc([]const u8, len * 16),
            .stats = try allocator.alloc(StationStats, len * 16),
            .name_allocator = name_allocator,
            .hash_collisions = 0,
        };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.names);
        allocator.free(self.stats);
        allocator.free(self.data);
    }

    fn update(self: *@This(), name: []const u8, temperature: i16) !void {
        const hash = xorHash(name);
        const metadata: Metadata = .fromHash(hash);
        var block_index = hash % self.data.len;

        while (true) {
            var compare_result: u16 = @bitCast(self.data[block_index] == @as(Block, @splat(@bitCast(metadata))));
            const first_zero: usize = @ctz(@as(u16, @bitCast(self.data[block_index] == @as(Block, @splat(0)))));

            while (@ctz(compare_result) < first_zero) : (compare_result ^= @as(u16, 1) << @intCast(@ctz(compare_result))) {
                const index = block_index * 16 + @ctz(compare_result);
                if (stringEqualAssumingSafeOOB(name, self.names[index])) {
                    @branchHint(.likely); // chances of collision are low, so very likely to be the same name
                    self.stats[index].count += 1;
                    self.stats[index].min = @min(self.stats[index].min, temperature);
                    self.stats[index].max = @max(self.stats[index].max, temperature);
                    self.stats[index].sum += temperature;
                    return;
                }
                self.hash_collisions += 1;
            } else {
                // we don't find a match very infrequently,
                // because most inserts will be to a table that has already been populated with names
                @branchHint(.unlikely);
                
                if (first_zero < 16) {
                    @branchHint(.likely); // this is the other case (the item isn't there yet)
                    const index = block_index * 16 + first_zero;

                    const new_name = try self.name_allocator.alloc(u8, name.len);
                    @memcpy(new_name, name);
                    self.names[index] = new_name;
                    
                    self.stats[index].count = 1;
                    self.stats[index].min = temperature;
                    self.stats[index].max = temperature;
                    self.stats[index].sum = temperature;

                    @as([*]u8, @ptrCast(&self.data[block_index]))[first_zero] = @bitCast(Metadata.fromHash(hash));
                    return;
                } else {
                    // it is incredibly unlikely that an entire block is filled
                    @branchHint(.cold);
                    block_index = (block_index + 1) % self.data.len;
                    assert(block_index != hash % self.data.len); // we should never reach the original target block
                    continue;
                }
            }
        }
    }

    fn extractAll(self: *const @This(), strings: [][]const u8, stats: []StationStats) usize {
        var offset: usize = 0;
        const empty_elem: Block = @splat(0);
        
        for (0..self.data.len) |block_index| {
            @memcpy(strings[offset..offset+16], self.names[block_index * 16..].ptr);
            @memcpy(stats[offset..offset+16], self.stats[block_index * 16..].ptr);
            
            const first_zero: usize = @ctz(@as(u16, @bitCast(self.data[block_index] == empty_elem)));
            offset += first_zero;
        }
        return offset;
    }
};
