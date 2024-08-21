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
};

const Page = struct {
    head: PageHeader,
    bytes: [Pool.BLOCK_SIZE - 64]u8,
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
        // TODO allocate properly
        const impl = storage.pool.create(Impl);
        impl.* = val;
        return impl.interface();
    }
};
