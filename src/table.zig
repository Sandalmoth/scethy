const std = @import("std");

pub const Entity = u64;
pub const nil: Entity = 0;

pub const Hint = enum { static, dynamic };

pub const Pool = struct {
    // all ecs data lives in these blocks s.t. we an alloc/dealloc efficiently
    pub const BLOCK_SIZE = 4 * 1024;
    pub const BLOCK_ALIGN = 64;
    const Block = struct { data: [BLOCK_SIZE]u8 align(BLOCK_ALIGN) };

    comptime {
        std.debug.assert(@sizeOf(Block) == BLOCK_SIZE);
        std.debug.assert(@alignOf(Block) == BLOCK_ALIGN);
    }

    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Pool {
        return .{
            .alloc = alloc,
        };
    }

    pub fn create(pool: *Pool, comptime T: type) *T {
        std.debug.assert(@sizeOf(T) <= BLOCK_SIZE);
        std.debug.assert(@alignOf(T) <= BLOCK_ALIGN);
        const block = pool.alloc.create(Block) catch @panic("allocation failure");
        return @alignCast(@ptrCast(block));
    }

    pub fn destroy(pool: *Pool, ptr: *anyopaque) void {
        const block: *Block = @alignCast(@ptrCast(ptr));
        pool.alloc.destroy(block);
    }
};

pub fn Table() type {
    return struct {
        pool: Pool,
    };
}
