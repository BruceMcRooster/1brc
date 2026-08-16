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

const read_veclen = std.simd.suggestVectorLength(u8) orelse 8; // orelse must fall back to at least 6

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

    const stats = try file.stat(io);
    const file_size = stats.size;
    const good_size = blk: {
        // values read a whole 64-bit int, but at minimum 4 of those bytes (x.x\n)
        // are actually valid bits, so we only need to account for the overread
        const max_value_overread = @sizeOf(u64) - 4;
        const file_size_with_overread = file_size + max_value_overread;
        const desired_to_be_multiple_of = stats.block_size;
        const rounded_up = (file_size_with_overread + desired_to_be_multiple_of - 1) / desired_to_be_multiple_of * desired_to_be_multiple_of;
        break :blk rounded_up;
    };
    const mmapped_buf = try std.posix.mmap(null, good_size, .{ .READ = true, .WRITE = false }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    defer std.posix.munmap(mmapped_buf);

    const madvise_size = 64 * (1 << 20);
    
    comptime assert(max_station_name_length <= 128);

    const sorted_data_buffer = try allocator.alloc(HashTable.Data, max_unique_station_count);
    defer allocator.free(sorted_data_buffer);
    // this will have its length mutated to the correct length,
    // but we need to keep the original around to free the right length
    var sorted_data = sorted_data_buffer;

    const string_pool = try fullProcess(mmapped_buf[0..file_size], &sorted_data, madvise_size, allocator);
    defer allocator.free(string_pool);

    var wrapped: [1][]HashTable.Data = .{sorted_data};
    try mergeAndPrintData(&wrapped, writer);
}

fn fullProcess(
    buffer: []const u8,
    output: *[]HashTable.Data,
    madvise_size: usize,
    allocator: std.mem.Allocator,
) ![]u8 {
    const string_pool = try allocator.alloc(u8, max_unique_station_count * max_station_name_length);

    var string_pool_buff_allocator = std.heap.FixedBufferAllocator.init(string_pool);
    const string_pool_allocator = string_pool_buff_allocator.allocator();
    
    var hashmap: HashTable = try .init(allocator, string_pool_allocator);
    defer hashmap.deinit(allocator);
    
    try extractValuesSafeOOB(buffer, &hashmap, madvise_size);

    const total_count = hashmap.extractAll(output.*);
    assert(total_count <= max_unique_station_count);
    output.len = total_count;
    const sorted_data = output.*;

    const sort_context: struct {
        data_buffer: []HashTable.Data,

        pub fn swap(self: *const @This(), elem1: usize, elem2: usize) void {
            std.mem.swap(HashTable.Data, &self.data_buffer[elem1], &self.data_buffer[elem2]);
        }

        pub fn lessThan(self: *const @This(), elem1: usize, elem2: usize) bool {
            return stringCompareAssumingSafeOOB(self.data_buffer[elem1].name, self.data_buffer[elem2].name) == .lt;
        }
    } = .{
        .data_buffer = sorted_data,
    };

    std.sort.heapContext(0, sorted_data.len, sort_context);

    var wrapped: [1][]HashTable.Data = .{sorted_data};
    try mergeAndPrintData(&wrapped, writer);
}

inline fn extractValuesSafeOOB(
    buffer: []const u8,
    hash_table: *HashTable,
    madvise_size: usize
) !void {
    assert(@intFromPtr(buffer.ptr) % read_veclen == 0);
    assert(std.math.isPowerOfTwo(madvise_size));
    
    try std.posix.madvise(
        @constCast(@alignCast(buffer.ptr)),
        if (buffer.len <= 2 * madvise_size) buffer.len else 2 * madvise_size,
        std.posix.MADV.WILLNEED
    );

    var offset: usize = 0;

    var semicolon_bitmask_curr: @Int(.unsigned, read_veclen) = grabSemicolonBitmask(
        read_veclen, @alignCast(@ptrCast(buffer.ptr)));
    var vector_offset: usize = 0;

    while (offset < buffer.len) {
        while (semicolon_bitmask_curr == 0) {
            vector_offset += read_veclen;
            semicolon_bitmask_curr = grabSemicolonBitmask(read_veclen, @alignCast(@ptrCast(buffer.ptr + vector_offset)));
        }
        const name: []const u8 = buffer[offset..vector_offset + @ctz(semicolon_bitmask_curr)];
        semicolon_bitmask_curr ^= @as(@Int(.unsigned, read_veclen), 1) << @intCast(@ctz(semicolon_bitmask_curr));

        const prev_offset = offset;
        
        offset += name.len + 1; // plus 1 for the ';'

        const result = extractValueSafeOOB(buffer[offset..]);
        const value = result.val;
        const char_count = result.char_count;
        offset += char_count;

        const offset_floor = offset & ~(madvise_size - 1);
        if (offset_floor != prev_offset & ~(madvise_size - 1)) {
            // we crossed an madvise_size boundary, so need advise we'll need the next one
            const next_start = offset_floor + madvise_size;
            const next_end = @min(next_start + madvise_size, buffer.len);
            if (next_start < next_end) {
                try std.posix.madvise(
                    @constCast(@alignCast(buffer.ptr + next_start)),
                    next_end - next_start,
                    std.posix.MADV.WILLNEED
                );
            }
        }

        try hash_table.update(name, value);
    }
}

// credit to @merykitty for this implementation
// and https://questdb.com/blog/billion-row-challenge-step-by-step/ for explaining
inline fn extractValueSafeOOB(buffer: []const u8) struct { val: i16, char_count: usize } {
    const value_ptr_start: *align(1) const u64 = @ptrCast(buffer.ptr);
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
    const char_count: usize = @intCast(
        -@as(i64, @bitCast(signed)) // possibly a negative sign
        + @intFromBool(abs_value > 99) // possibly a 10s place
        + 3 // x.x
        + 1 // \n
    );
    return .{ .val = result, .char_count = char_count };
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

const HashTable = struct {
    const Metadata = packed struct {
        name_hash_top: u7,
        in_use: bool,

        fn fromHash(hash: u64) @This() {
            return @bitCast(
                @as(@typeInfo(@This()).@"struct".backing_integer orelse unreachable, 
                    @intCast(hash >> (@bitSizeOf(u64) - 7) | 0x80))
            );
        }

        fn empty() @This() {
            return @bitCast(@as(@typeInfo(@This()).@"struct".backing_integer orelse unreachable, 0));
        }
    };
    const Data = struct {
        name: []const u8,
        stats: StationStats,
    };
    const IndexInt = u16;
    const ExtractVector = blk: {
        const MetadataBackingInt = @typeInfo(Metadata).@"struct".backing_integer orelse unreachable;
        const suggested_len = std.simd.suggestVectorLength(MetadataBackingInt) orelse 1;
        const max_len = std.math.maxInt(MetadataBackingInt) + 1;
        break :blk @Vector(@min(suggested_len, max_len), MetadataBackingInt);
    };

    meta: []Metadata,
    data: []Data,
    name_allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, name_allocator: std.mem.Allocator) !@This() {
        const len = std.math.maxInt(IndexInt) + 1;
        const meta = try allocator.alignedAlloc(Metadata, .fromByteUnits(@alignOf(ExtractVector)), len);
        @memset(meta, .empty());
        
        return .{
            .meta = meta,
            .data = try allocator.alloc(Data, len),
            .name_allocator = name_allocator,
        };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.meta);
        allocator.free(self.data);
    }

    fn update(self: *@This(), name: []const u8, temperature: i16) !void {
        const hash = xorHash(name);
        const metadata: Metadata = .fromHash(hash);
        var index: IndexInt = @intCast(hash % self.data.len);

        while (true) : (index +%= 1) {
            if (self.meta[index] == Metadata.empty()) {
                const new_name = try self.name_allocator.alloc(u8, name.len);
                @memcpy(new_name, name);
                self.data[index].name = new_name;
                
                self.data[index].stats.count = 1;
                self.data[index].stats.min = temperature;
                self.data[index].stats.max = temperature;
                self.data[index].stats.sum = temperature;

                self.meta[index] = metadata;
                return;
            }
            if (self.meta[index] != metadata) {
                @branchHint(.unlikely); // number of hash collisions stays pretty low
                continue;
            }

            assert(self.meta[index] == metadata);
            
            if (stringEqualAssumingSafeOOB(name, self.data[index].name)) {
                @branchHint(.likely); // chances of collision are low, so very likely to be the same name
                self.data[index].stats.count += 1;
                self.data[index].stats.min = @min(self.data[index].stats.min, temperature);
                self.data[index].stats.max = @max(self.data[index].stats.max, temperature);
                self.data[index].stats.sum += temperature;
                return;
            }
        }

        unreachable;
    }

    fn extractAll(self: *const @This(), dest: []Data) usize {
        var curr_dest_offset: usize = 0;
        const empty_elems: ExtractVector = @splat(0);
        // working with clz instead of ctz because ordering doesn't matter and clz is faster on Mac (ctz not native)
        const cmp_bit_at_top: @Int(.unsigned, @typeInfo(ExtractVector).vector.len) = @as(@Int(.unsigned, @typeInfo(ExtractVector).vector.len), 1) << (@typeInfo(ExtractVector).vector.len - 1);

        var curr_ptr: [*]align(@alignOf(ExtractVector)) const Metadata = @ptrCast(@alignCast(self.meta.ptr));

        while (curr_ptr != self.meta.ptr + self.meta.len) {
            const curr_elems: ExtractVector = @as(*const ExtractVector, @ptrCast(curr_ptr)).*;
            // add immediately so we can subtract leading 0s from it
            curr_ptr += @typeInfo(ExtractVector).vector.len;
            
            var cmp: @Int(.unsigned, @typeInfo(ExtractVector).vector.len) = @bitCast(curr_elems != empty_elems);
            while (cmp != 0) : ({
                cmp ^= cmp_bit_at_top >> @intCast(@clz(cmp));
            }) {
                const offset = @intFromPtr(curr_ptr - (@clz(cmp) + 1) - @intFromPtr(self.meta.ptr));
                assert(self.meta[offset].in_use == true);
                dest[curr_dest_offset] = self.data[offset];
                curr_dest_offset += 1;
            }
        }
        return curr_dest_offset;
    }
};

fn mergeAndPrintData(
    data: [][]HashTable.Data,
    writer: *Io.Writer
) !void {
    assert(data.len > 0);

    try writer.print("{{", .{});

    var first_loop = true;
    mainloop: while (true) {
        var best_index: usize = 0;
        while (data[best_index].len == 0) {
            best_index += 1;
            if (best_index == data.len) break :mainloop;
        }
        assert(data[best_index].len > 0);

        for (data[1..], 1..) |data_list, i| {
            if (data_list.len == 0) continue;
            const cmp = stringCompareAssumingSafeOOB(data_list[0].name, data[best_index][0].name);
            if (cmp == .lt) {
                best_index = i;
            } else if (cmp == .eq) {
                const stats_a = data[best_index][0].stats;
                const stats_b = data[i][0].stats;
                data[best_index][0].stats = .{
                    .min = @min(stats_a.min, stats_b.min),
                    .max = @max(stats_a.max, stats_b.max),
                    .sum = stats_a.sum + stats_b.sum,
                    .count = stats_a.count + stats_b.count,
                };
                data[i] = data[i][1..];
            }
        }

        if (!first_loop) try writer.print(", ", .{});
        first_loop = false;

        try writer.print("{s}=", .{data[best_index][0].name});
        const stats = data[best_index][0].stats;
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

        data[best_index] = data[best_index][1..];
    }
    try writer.print("}}\n", .{});
    try writer.flush();
}
