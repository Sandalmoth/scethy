const std = @import("std");
const testing = std.testing;

// ensure alignment on cache line boundaries
// should also be bigger than any type might possibly have?
const page_alignment = 64;

// what should we call it?
// manager? hub? componentcontainer?
pub const Context = struct {
    pub const Settings = struct {
        page_size: u32 = 4096,
        growable: bool = false,
    };

    pub const Page = struct {
        next: ?*align(page_alignment) @This(),
    };
    const PagePtr = *align(page_alignment) Page;

    alloc: std.mem.Allocator,
    settings: Settings,

    n_pages: u32,
    free_list: ?PagePtr = null,

    pub fn init(
        alloc: std.mem.Allocator,
        initial_page_count: u32,
        settings: Settings,
    ) !Context {
        var ctx = Context{
            .alloc = alloc,
            .settings = settings,
            .n_pages = initial_page_count,
        };

        return ctx;
    }

    pub fn deinit() void {}

    fn allocPage(ctx: *Context) !*align(page_alignment) []u8 {
        const page = try ctx.alloc.alignedAlloc(u8, page_alignment, ctx.settings.page_size);
        _ = page;
        // if (ctx.free_list)
    }
};

test "basic add functionality" {
    try testing.expect(true);
    _ = std.heap.MemoryPool(i32); // just for easy going to source

    var ctx = try Context.init(std.testing.allocator, 32, .{});
    _ = ctx;
}
