const std = @import("std");
const log = std.log.scoped(.implementation_storage);

const Entity = @import("table.zig").Entity;
const nil = @import("table.zig").nil;
const Pool = @import("table.zig").Pool;

const INDEX_SIZE = Pool.BLOCK_SIZE / @sizeOf(usize);
const PageIndex = struct {
    pages: [INDEX_SIZE]?*Page,
};

const PageHeader = struct {
    offset: usize,
    end: usize,
};

const ImplHeader = struct {
    size: u32,
    _align: u32,
};

const Page = struct {
    head: PageHeader,
    bytes: [Pool.BLOCK_SIZE - 64]u8,

    fn create(pool: *Pool) *Page {
        const page = pool.create(Page);
        page.head = .{
            .offset = @intFromPtr(&page.bytes[0]) + 8,
            .end = @intFromPtr(&page.bytes[0]) + page.bytes.len,
        };
        return page;
    }

    fn alloc(page: *Page, comptime Impl: type) ?*Impl {
        const result: *Impl = @ptrFromInt(page.head.offset);
        page.head.offset = std.mem.alignForward(usize, page.head.offset, @alignOf(Impl));
        page.head.offset += @sizeOf(Impl);
        if (page.head.offset > page.head.end) return null;
        const header = getHeader(result);
        header.size = @sizeOf(Impl);
        header._align = @alignOf(Impl);
        page.head.offset += 8;
        return result;
    }

    fn getHeader(ptr: *anyopaque) *ImplHeader {
        return @ptrFromInt(@intFromPtr(ptr) - 8);
    }
};

pub const ImplStorage = struct {
    pool: *Pool,
    page_index: *PageIndex,
    n_pages: usize,

    pub fn init(pool: *Pool) ImplStorage {
        var storage = ImplStorage{
            .pool = pool,
            .page_index = pool.create(PageIndex),
            .n_pages = 0,
        };
        storage.page_index.pages = [_]?*Page{null} ** INDEX_SIZE;
        return storage;
    }

    pub fn deinit(storage: *ImplStorage) void {
        for (0..storage.n_pages) |i| {
            storage.pool.destroy(storage.page_index.pages[i].?);
        }
        storage.pool.destroy(storage.page_index);
        storage.* = undefined;
    }

    pub fn alloc(
        storage: *ImplStorage,
        comptime Interface: type,
        comptime Impl: type,
        val: Impl,
    ) Interface {
        if (storage.n_pages == 0) storage.newPage();
        const impl = storage.page_index.pages[storage.n_pages - 1].?.alloc(Impl) orelse blk: {
            storage.newPage();
            break :blk storage.page_index.pages[storage.n_pages - 1].?.alloc(Impl) orelse @panic(
                "Page.alloc - " ++ @typeName(Impl) ++ " cannot fit with the given block size",
            );
        };
        impl.* = val;
        return impl.interface();
    }

    fn newPage(storage: *ImplStorage) void {
        if (storage.n_pages == INDEX_SIZE) @panic("Could not create a new page, index is full");
        storage.page_index.pages[storage.n_pages] = Page.create(storage.pool);
        storage.n_pages += 1;
    }
};
