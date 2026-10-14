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
const read_buffer_size = 1024 * 1024;
const read_padding = @max(128, read_veclen);
const max_line_length = max_station_name_length + ";-99.9\n".len;
const num_workers = 8;

const ProcessError = Io.File.ReadPositionalError || Io.ConcurrentError || error{
    InvalidRecord,
    UnexpectedEndOfFile,
};

const WorkerConfig = struct {
    io: Io,
    hashtable: HashTable,
    sorted_output_destination: []HashTable.Data,
    file: Io.File,
    soft_start: u64,
    soft_end: u64,
    file_size: u64,
    buffers: [2][]align(read_veclen) u8,
    _string_pool_allocator: *std.heap.FixedBufferAllocator,

    fn init(io: Io, soft_start: u64, soft_end: u64, file_size: u64, file: Io.File, allocator: std.mem.Allocator) !@This() {
        const string_pool = try allocator.alloc(u8, (max_unique_station_count + 1) * max_station_name_length);
        errdefer allocator.free(string_pool);
        const string_pool_allocator = try allocator.create(std.heap.FixedBufferAllocator);
        errdefer allocator.destroy(string_pool_allocator);
        string_pool_allocator.* = std.heap.FixedBufferAllocator.init(string_pool);
        var hashtable = try HashTable.init(allocator, string_pool_allocator.allocator());
        errdefer hashtable.deinit(allocator);

        // allocate a little extra to guarantee reads potentially past their known slices
        const a_buffer = try allocator.alignedAlloc(u8, .fromByteUnits(read_veclen), read_buffer_size + read_padding);
        errdefer allocator.free(a_buffer);
        const b_buffer = try allocator.alignedAlloc(u8, .fromByteUnits(read_veclen), read_buffer_size + read_padding);
        errdefer allocator.free(b_buffer);

        const sorted_output_destination = try allocator.alloc(HashTable.Data, max_unique_station_count);

        return .{
            .io = io,
            .hashtable = hashtable,
            .sorted_output_destination = sorted_output_destination,
            .file = file,
            .soft_start = soft_start,
            .soft_end = soft_end,
            .file_size = file_size,
            .buffers = .{ a_buffer, b_buffer },
            ._string_pool_allocator = string_pool_allocator,
        };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.hashtable.deinit(allocator);
        allocator.free(self._string_pool_allocator.buffer);
        allocator.destroy(self._string_pool_allocator);

        // reset because it will have been changed to reflect the actual count,
        // but must be freed at the originally allocated size
        self.sorted_output_destination.len = max_unique_station_count;
        allocator.free(self.sorted_output_destination);

        for (self.buffers) |buffer| allocator.free(buffer);
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

    const stats = try file.stat(io);
    const file_size = stats.size;

    comptime assert(max_station_name_length <= 128);

    // Workers resolve these block-aligned soft boundaries to newlines themselves.
    var split_points: [num_workers + 1]u64 = undefined;
    split_points[0] = 0;
    split_points[split_points.len - 1] = stats.size;
    for (split_points[1..num_workers], 1..) |*split_point, i| {
        const ideal = file_size / num_workers * i;
        const block_size = @max(stats.block_size, 1);
        const floored_to_block = ideal - (ideal % block_size);
        split_point.* = floored_to_block;
    }
    
    var config: [num_workers]WorkerConfig = undefined;
    var initialized: usize = 0;
    defer {
        for (config[0..initialized]) |*worker_config| worker_config.deinit(allocator);
    }
    for (&config, 0..) |*worker_config, i| {
        worker_config.* = try WorkerConfig.init(
            io,
            split_points[i], split_points[i+1],
            file_size,
            file,
            allocator
        );
        initialized += 1;
    }

    var workers: [num_workers]Io.Future(ProcessError!void) = undefined;
    for (&config, &workers) |*worker_config, *worker| {
        worker.* = io.async(fullProcess, .{worker_config});
    }
    // Join every task before freeing its buffers, including on a worker's read error.
    defer for (&workers) |*worker| {
        worker.cancel(io) catch {};
    };
    for (&workers) |*worker| try worker.await(io);
    
    var wrapped: [num_workers][]HashTable.Data = undefined;
    for (&wrapped, 0..) |*wrapped_slice, i| {
        wrapped_slice.* = config[i].sorted_output_destination;
    }
    
    try mergeAndPrintData(&wrapped, writer);
}

fn readBuffer(config: *const WorkerConfig, buffer: []u8, prefix_len: usize, offset: u64) ProcessError!usize {
    // Read far enough to finish the record at the soft end, without seeking backwards.
    const read_end = @min(config.soft_end +| max_line_length, config.file_size);
    const len: usize = @intCast(@min(read_buffer_size - prefix_len, read_end - offset));
    const bytes_read = try config.file.readPositionalAll(config.io, buffer[prefix_len..][0..len], offset);
    if (bytes_read != len) return error.UnexpectedEndOfFile;
    const filled = prefix_len + len;
    return filled;
}

fn fullProcess(config: *WorkerConfig) ProcessError!void {
    if (config.soft_start != config.soft_end) {
        var current: usize = 0;
        var filled = try readBuffer(config, config.buffers[current], 0, config.soft_start);
        var offset = config.soft_start + filled;
        // The preceding worker owns the record containing a nonzero soft start.
        var parse_start: usize = if (config.soft_start == 0) 0 else
            (std.mem.findScalar(u8, config.buffers[current][0..filled], '\n') orelse return error.InvalidRecord) + 1;
        while (true) {
            const buffer = config.buffers[current];
            const buffer_start = offset - filled;
            if (offset > config.soft_end or offset == config.file_size) {
                const parse_end = if (config.soft_end == config.file_size) blk: {
                    if (buffer[filled - 1] != '\n') return error.UnexpectedEndOfFile;
                    break :blk filled;
                } else blk: {
                    const boundary: usize = @intCast(config.soft_end - buffer_start);
                    break :blk (std.mem.findScalarPos(u8, buffer[0..filled], boundary, '\n') orelse return error.UnexpectedEndOfFile) + 1;
                };
                if (parse_start < parse_end) extractValuesSafeOOB(buffer[parse_start..parse_end], &config.hashtable);
                break;
            }
            const parse_end = (std.mem.findScalarLast(u8, buffer[0..filled], '\n') orelse return error.InvalidRecord) + 1;
            const tail_len = filled - parse_end;
            if (tail_len >= max_line_length) return error.InvalidRecord;

            const next = current ^ 1;
            // Carry the incomplete last record into the spare buffer before filling it.
            @memcpy(config.buffers[next][0..tail_len], buffer[parse_end..filled]);
            var pending = try config.io.concurrent(readBuffer, .{ config, config.buffers[next], tail_len, offset });
            if (parse_start < parse_end) extractValuesSafeOOB(buffer[parse_start..parse_end], &config.hashtable);
            filled = try pending.await(config.io);
            offset += filled - tail_len;
            current = next;
            parse_start = 0;
        }
    }

    const total_count = config.hashtable.extractAll(config.sorted_output_destination);
    assert(total_count <= max_unique_station_count);
    config.sorted_output_destination.len = total_count;
    const sorted_data = config.sorted_output_destination;

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
}

inline fn extractValuesSafeOOB(
    assigned_buffer: []const u8,
    hash_table: *HashTable,
) void {
    var offset: usize = 0;

    const buffer: []const u8 = blk: {
        const aligned_start: [*]const u8 = @ptrFromInt(@intFromPtr(assigned_buffer.ptr) - (@intFromPtr(assigned_buffer.ptr) % read_veclen));
        const total_length = (assigned_buffer.ptr - aligned_start) + assigned_buffer.len;
        break :blk aligned_start[0..total_length];
    };
    
    var semicolon_bitmask_curr: @Int(.unsigned, read_veclen) = grabSemicolonBitmask(
        read_veclen, @alignCast(@ptrCast(buffer.ptr)));
    var vector_offset: usize = 0;
    
    if (buffer.ptr != assigned_buffer.ptr) {
        // need to mask out possible semicolons that we weren't assigned
        const all_ones = ~@as(@Int(.unsigned, read_veclen), 0);
        semicolon_bitmask_curr &= all_ones << @intCast(assigned_buffer.ptr - buffer.ptr);
        offset = assigned_buffer.ptr - buffer.ptr;
    }

    while (offset < buffer.len) {
        while (semicolon_bitmask_curr == 0) {
            vector_offset += read_veclen;
            semicolon_bitmask_curr = grabSemicolonBitmask(read_veclen, @alignCast(@ptrCast(buffer.ptr + vector_offset)));
        }
        const name: []const u8 = buffer[offset..vector_offset + @ctz(semicolon_bitmask_curr)];
        semicolon_bitmask_curr ^= @as(@Int(.unsigned, read_veclen), 1) << @intCast(@ctz(semicolon_bitmask_curr));

        offset += name.len + 1; // plus 1 for the ';'

        const result = extractValueSafeOOB(buffer[offset..]);
        const value = result.val;
        const char_count = result.char_count;
        offset += char_count;

        hash_table.update(name, value);
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
    const remainder = min_len % @sizeOf(Vec);
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

test "stringCompareAssumingSafeOOB: shared-prefix length aligned to vector width" {
    const expect = std.testing.expect;
    const Vec = @Vector(std.simd.suggestVectorLength(u8) orelse 1, u8);
    const vlen = @sizeOf(Vec);

    var buf: [256]u8 = undefined;
    @memset(&buf, 'z'); // padding/garbage that must NOT influence the result

    // "long" = vlen 'a's followed by one 'b', i.e. long.len == vlen + 1.
    for (0..vlen) |i| buf[i] = 'a';
    buf[vlen] = 'b';
    const long = buf[0 .. vlen + 1];

    // "short" is placed elsewhere in the buffer: exactly vlen 'a's (matching long's
    // shared prefix exactly), i.e. short.len == vlen, a length that's an exact
    // multiple of the vector width. Whatever sits right after `short` in memory
    // (here: 'z', deliberately > 'b') must be ignored -- since short is entirely
    // a prefix of long, short must always compare as .lt (and long as .gt)
    // regardless of that padding.
    const short_start = 2 * vlen;
    for (short_start..short_start + vlen) |i| buf[i] = 'a';
    const short = buf[short_start .. short_start + vlen];

    try expect(stringCompareAssumingSafeOOB(short, long) == .lt);
    try expect(stringCompareAssumingSafeOOB(long, short) == .gt);
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
    const capacity = @as(usize, std.math.maxInt(IndexInt)) + 1;
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
        const len = capacity;
        const meta = try allocator.alignedAlloc(Metadata, .fromByteUnits(@alignOf(ExtractVector)), len);
        errdefer allocator.free(meta);
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

    fn update(self: *@This(), name: []const u8, temperature: i16) void {
        assert(self.data.len == capacity);
        const hash = xorHash(name);
        const metadata: Metadata = .fromHash(hash);
        // The fixed capacity spans every IndexInt value, so truncation is modulo capacity.
        var index: IndexInt = @truncate(hash);

        while (true) : (index +%= 1) {
            if (self.meta[index] == Metadata.empty()) {
                @branchHint(.unlikely);
                return self.insert(index, metadata, name, temperature);
            }
            if (self.meta[index] != metadata) {
                @branchHint(.unlikely); // number of hash collisions stays pretty low
                continue;
            }

            assert(self.meta[index] == metadata);
            
            if (stringEqualAssumingSafeOOB(name, self.data[index].name)) {
                @branchHint(.likely); // chances of collision are low, so very likely to be the same name
                const stats = &self.data[index].stats;
                stats.count += 1;
                stats.min = @min(stats.min, temperature);
                stats.max = @max(stats.max, temperature);
                stats.sum += temperature;
                return;
            }
        }

        unreachable;
    }

    // Keep allocation and copying out of the per-measurement update path.
    fn insert(self: *@This(), index: IndexInt, metadata: Metadata, name: []const u8, temperature: i16) void {
        const new_name = self.name_allocator.alloc(u8, name.len) catch unreachable;
        @memcpy(new_name, name);
        self.data[index] = .{
            .name = new_name,
            .stats = .{ .count = 1, .min = temperature, .max = temperature, .sum = temperature },
        };
        self.meta[index] = metadata;
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

/// A min-heap of nonempty sorted streams, ordered by each stream's head.
/// Reuses and consumes the caller's slice descriptors; the records stay unchanged.
const MergeHeap = struct {
    streams: [][]HashTable.Data,

    fn init(data: [][]HashTable.Data) MergeHeap {
        var active: usize = 0;
        for (data) |stream| {
            if (stream.len == 0) continue;
            data[active] = stream;
            active += 1;
        }
        @memset(data[active..], &.{});
        var heap: MergeHeap = .{ .streams = data[0..active] };
        // Bottom-up heap construction is O(k); no stream needs advancing yet.
        var parent = active / 2;
        while (parent > 0) {
            parent -= 1;
            heap.siftDown(parent);
        }
        return heap;
    }

    fn siftDown(self: *MergeHeap, start: usize) void {
        const stream = self.streams[start];
        var parent = start;
        while (parent < self.streams.len / 2) {
            var child = parent * 2 + 1;
            const right = child + 1;
            if (right < self.streams.len and
                stringCompareAssumingSafeOOB(self.streams[right][0].name, self.streams[child][0].name) == .lt)
            {
                child = right;
            }
            if (stringCompareAssumingSafeOOB(stream[0].name, self.streams[child][0].name) != .gt) break;
            self.streams[parent] = self.streams[child];
            parent = child;
        }
        self.streams[parent] = stream;
    }

    fn pop(self: *MergeHeap) HashTable.Data {
        const result = self.streams[0][0];
        self.streams[0] = self.streams[0][1..];
        if (self.streams[0].len == 0) {
            const last = self.streams.len - 1;
            self.streams[0] = self.streams[last];
            self.streams[last] = &.{};
            self.streams.len = last;
        }
        // Advancing a sorted stream can only increase its head. Replacing an
        // exhausted root with the last stream likewise only needs a sift down.
        if (self.streams.len != 0) self.siftDown(0);
        return result;
    }

    fn next(self: *MergeHeap) ?HashTable.Data {
        if (self.streams.len == 0) return null;
        var result = self.pop();
        // Equal names need not be adjacent in the heap, but each reaches the
        // root before any larger name, so combine them before emitting a row.
        while (self.streams.len != 0 and
            stringCompareAssumingSafeOOB(result.name, self.streams[0][0].name) == .eq)
        {
            const other = self.pop().stats;
            result.stats.min = @min(result.stats.min, other.min);
            result.stats.max = @max(result.stats.max, other.max);
            result.stats.sum += other.sum;
            result.stats.count += other.count;
        }
        return result;
    }
};

fn mergeAndPrintData(
    data: [][]HashTable.Data,
    writer: *Io.Writer
) !void {
    var heap = MergeHeap.init(data);

    try writer.print("{{", .{});

    var first_loop = true;
    while (heap.next()) |entry| {
        if (!first_loop) try writer.print(", ", .{});
        first_loop = false;

        try writer.print("{s}=", .{entry.name});
        const stats = entry.stats;
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
