const std = @import("std");
const log = std.log.scoped(.data_storage);

const Entity = @import("table.zig").Entity;
const nil = @import("table.zig").nil;
const Pool = @import("table.zig").Pool;
const Hint = @import("table.zig").Hint;

const BUCKET_LOAD_MAX = 0.8;
const BUCKET_MERGE_MAX = 0.6;
const STORAGE_LOAD_MAX = 0.7;
const STORAGE_LOAD_MIN = 0.3;

// ensures that the bucket and slot in bucket a key goes into are uncorrelated
// greatly reduces the number of collisions in the buckets
const STORAGE_PRIME = 3491872367;
const BUCKET_PRIME = 3650591537;

const BucketHeader = struct {
    next: ?*Bucket,
    len: usize,
};
const Bucket = struct {
    const capacity = Pool.BLOCK_SIZE / 8;
    const Location = packed struct {
        fingerprint: u8,
        page: u12,
        index: u12,
    };
    const ix_nil = std.math.maxInt(u12);

    const load_max = @as(comptime_int, @intFromFloat(
        BUCKET_LOAD_MAX * @as(comptime_float, capacity),
    ));
    const merge_max = @as(comptime_int, @intFromFloat(
        BUCKET_MERGE_MAX * @as(comptime_float, capacity),
    ));

    head: BucketHeader,
    locs: [capacity]Location,

    fn create(pool: *Pool) *Bucket {
        const bucket: *Bucket = pool.create(Bucket);
        bucket.head = .{
            .next = null,
            .len = 0,
        };
        // NOTE partial undefined packed structs currently dont work due to a compiler bug
        bucket.locs = .{Location{
            // .fingerprint = undefined,
            // .page = undefined,
            .fingerprint = 0,
            .page = 0,
            .index = ix_nil, // only this is actually required
        }} ** capacity;
        return bucket;
    }

    fn destroy(bucket: *Bucket, pool: *Pool) void {
        if (bucket.head.next) |next| next.destroy(pool);
        pool.destroy(bucket);
    }

    /// does not overwrite if key is present
    /// returns whether an insertion was made
    fn ins(
        bucket: *Bucket,
        pool: *Pool,
        page_index: *PageIndex,
        key: Entity,
        page: u12,
        index: u12,
    ) bool {
        std.debug.assert(key != nil);

        if (bucket.head.len > load_max) {
            if (bucket.head.next == null) {
                bucket.head.next = Bucket.create(pool);
            }
            return bucket.head.next.?.ins(pool, page_index, key, page, index);
        }

        const h = hash(key);
        const fingerprint: u8 = @intCast(h >> 24);
        var ix = h % capacity;
        while (bucket.locs[ix].index != ix_nil) : (ix = (ix + 1) % capacity) {
            const l = bucket.locs[ix];
            if (l.fingerprint == fingerprint) {
                const k = page_index.pages[l.page].?.head.keys[l.index];
                if (k == key) return false;
            }
        }
        std.debug.assert(bucket.locs[ix].index == ix_nil);
        bucket.head.len += 1;
        bucket.locs[ix] = .{
            .fingerprint = fingerprint,
            .page = page,
            .index = index,
        };
        page_index.pages[page].?.head.modified.store(true, .unordered);
        return true;
    }

    fn getLocPtr(bucket: *Bucket, page_index: *PageIndex, key: Entity) ?*Location {
        const h = hash(key);
        const fingerprint: u8 = @intCast(h >> 24);
        for (0..capacity) |probe| {
            const ix = (h + probe) % capacity;
            const l = bucket.locs[ix];
            if (l.index == ix_nil) break;
            if (l.fingerprint == fingerprint) {
                const k = page_index.pages[l.page].?.head.keys[l.index];
                if (k == key) return &bucket.locs[ix];
            }
        }

        if (bucket.head.next) |next| {
            return next.getLocPtr(page_index, key);
        } else {
            return null;
        }
    }

    fn has(bucket: *Bucket, page_index: *PageIndex, key: Entity) bool {
        const h = hash(key);
        const fingerprint: u8 = @intCast(h >> 24);
        for (0..capacity) |probe| {
            const ix = (h + probe) % capacity;
            const l = bucket.locs[ix];
            if (l.index == ix_nil) break;
            if (l.fingerprint == fingerprint) {
                const k = page_index.pages[l.page].?.head.keys[l.index];
                if (k == key) return true;
            }
        }

        if (bucket.head.next) |next| {
            return next.has(page_index, key);
        } else {
            return false;
        }
    }

    fn getPtr(bucket: *Bucket, comptime V: type, page_index: *PageIndex, key: Entity) ?*V {
        const h = hash(key);
        const fingerprint: u8 = @intCast(h >> 24);
        for (0..capacity) |probe| {
            const ix = (h + probe) % capacity;
            const l = bucket.locs[ix];
            if (l.index == ix_nil) break;
            if (l.fingerprint == fingerprint) {
                const k = page_index.pages[l.page].?.head.keys[l.index];
                if (k == key) {
                    page_index.pages[l.page].?.head.modified.store(true, .unordered);
                    return &page_index.pages[l.page].?.head.vals(V)[l.index];
                }
            }
        }

        if (bucket.head.next) |next| {
            return next.getPtr(V, page_index, key);
        } else {
            return null;
        }
    }

    fn getConstPtr(bucket: *Bucket, comptime V: type, page_index: *PageIndex, key: Entity) ?*const V {
        const h = hash(key);
        const fingerprint: u8 = @intCast(h >> 24);
        for (0..capacity) |probe| {
            const ix = (h + probe) % capacity;
            const l = bucket.locs[ix];
            if (l.index == ix_nil) break;
            if (l.fingerprint == fingerprint) {
                const k = page_index.pages[l.page].?.head.keys[l.index];
                if (k == key) {
                    return &page_index.pages[l.page].?.head.vals(V)[l.index];
                }
            }
        }

        if (bucket.head.next) |next| {
            return next.getConstPtr(V, page_index, key);
        } else {
            return null;
        }
    }

    /// returns whether a deletion was made
    fn del(
        bucket: *Bucket,
        pool: *Pool,
        page_index: *PageIndex,
        n_pages: usize,
        key: Entity,
    ) bool {
        const h = hash(key);
        const fingerprint: u8 = @intCast(h >> 24);
        for (0..capacity) |probe| {
            const ix = (h + probe) % capacity;
            const l = bucket.locs[ix];
            if (l.index == ix_nil) break;
            if (l.fingerprint == fingerprint) {
                const k = page_index.pages[l.page].?.head.keys[l.index];
                if (k != key) continue;

                // shuffle entries in bucket to preserve hashmap structure
                var ix_remove = ix;
                var ix_shift = ix_remove;
                var dist: usize = 1;
                while (true) {
                    ix_shift = (ix_shift + 1) % capacity;
                    const l_shift = bucket.locs[ix_shift];
                    if (l_shift.index == ix_nil) {
                        bucket.locs[ix_remove] = .{
                            // .fingerprint = undefined,
                            // .page = undefined,
                            .fingerprint = 0,
                            .page = 0,
                            .index = ix_nil,
                        };
                        bucket.head.len -= 1;
                        page_index.pages[l.page].?.head.modified.store(true, .unordered);
                        return true;
                    }
                    const k_shift = page_index.pages[l_shift.page].?.head.keys[l_shift.index];
                    const key_dist = (ix_shift -% hash(k_shift)) % capacity;
                    if (key_dist >= dist) {
                        bucket.locs[ix_remove] = bucket.locs[ix_shift];
                        ix_remove = ix_shift;
                        dist = 1;
                    } else {
                        dist += 1;
                    }
                }
            }
        }

        if (bucket.head.next) |next| {
            const deleted = next.del(pool, page_index, n_pages, key);
            if (next.head.len == 0) {
                bucket.head.next = next.head.next;
                next.head.next = null;
                next.destroy(pool);
            } else if (bucket.head.len + next.head.len < merge_max) {
                bucket.head.next = next.head.next;
                next.head.next = null;
                for (0..capacity) |i| {
                    const l = next.locs[i];
                    if (l.index != ix_nil) {
                        const k = page_index.pages[l.page].?.head.keys[l.index];
                        const success = bucket.ins(pool, page_index, k, l.page, l.index);
                        std.debug.assert(success);
                    }
                }
                next.destroy(pool);
            }
            return deleted;
        }

        return false;
    }

    fn hash(key: Entity) u32 {
        return std.hash.XxHash32.hash(BUCKET_PRIME, std.mem.asBytes(&key));
    }

    const Iterator = struct {
        bucket: ?*Bucket,
        cursor: usize = 0,

        pub fn next(it: *Iterator) ?Location {
            if (it.bucket == null) return null;

            while (true) {
                if (it.cursor == 0) {
                    if (it.bucket.?.head.next) |_next| {
                        it.bucket = _next;
                        it.cursor = capacity;
                    } else {
                        it.bucket = null;
                        return null;
                    }
                }

                it.cursor -= 1;
                if (it.bucket.?.locs[it.cursor].index != ix_nil) {
                    return it.bucket.?.locs[it.cursor];
                }
            }
        }
    };

    fn iterator(bucket: *Bucket) Iterator {
        return .{
            .bucket = bucket,
            .cursor = capacity,
        };
    }

    fn debugPrint(bucket: Bucket, page_index: *PageIndex) void {
        std.debug.print(" [ ", .{});
        for (0..capacity) |i| {
            if (bucket.locs[i].index != ix_nil) {
                const l = bucket.locs[i];
                const k = page_index.pages[l.page].?.head.keys[l.index];
                std.debug.print("({},{})->{} ", .{ l.page, l.index, k });
            }
        }
        if (bucket.head.next) |next| {
            next.debugPrint(page_index);
            std.debug.print("] ->", .{});
        } else {
            std.debug.print("]\n", .{});
        }
    }
};

const PageHeader = struct {
    keys: [*]Entity,
    _vals: usize, // [*]V
    capacity: usize,
    len: usize,
    modified: std.atomic.Value(bool),
    refcount: usize,

    fn vals(head: *PageHeader, comptime V: type) [*]V {
        return @ptrFromInt(head._vals);
    }
};
const Page = struct {
    head: PageHeader,
    bytes: [Pool.BLOCK_SIZE - 64]u8,

    pub fn create(comptime V: type, pool: *Pool) *Page {
        const page = pool.create(Page);
        page.head = .{
            .keys = undefined,
            ._vals = undefined,
            .capacity = @min(
                page.bytes.len / (@sizeOf(Entity) + @sizeOf(V)),
                4095, // make room for ix_nil in bucket
            ),
            .len = 0,
            .modified = std.atomic.Value(bool).init(false),
            .refcount = 1,
        };

        // layout the keys and vals array in bytes
        while (page.head.capacity > 0) : (page.head.capacity -= 1) {
            var p: usize = @intFromPtr(&page.bytes[0]);
            page.head.keys = @ptrFromInt(p);
            p += @sizeOf(Entity) * page.head.capacity;
            p = std.mem.alignForward(usize, p, @alignOf(V));
            page.head._vals = p;
            p += @sizeOf(V) * page.head.capacity;

            if (p < @intFromPtr(&page.bytes[page.bytes.len - 1])) {
                break;
            }
        }
        if (page.head.capacity == 0) {
            @panic("Page.create - " ++ @typeName(V) ++ " cannot fit with the given block size");
        }

        return page;
    }

    pub fn destroy(page: *Page, pool: *Pool) void {
        page.head.refcount -= 1;
        if (page.head.refcount == 0) pool.destroy(page);
    }

    pub fn push(page: *Page, comptime V: type, key: Entity, val: V) usize {
        std.debug.assert(page.head.len < page.head.capacity);
        page.head.keys[page.head.len] = key;
        page.head.vals(V)[page.head.len] = val;
        page.head.modified.store(true, .unordered);
        const result = page.head.len;
        page.head.len += 1;
        return result;
    }

    fn debugPrint(page: *Page, comptime V: type) void {
        std.debug.print(" [ ", .{});
        for (0..page.head.len) |i| {
            std.debug.print("{}:{} ", .{ page.head.keys[i], page.head.vals(V)[i] });
        }
        std.debug.print("] - {} item(s)\n", .{page.head.len});
    }
};

const BUCKET_INDEX_SIZE = Pool.BLOCK_SIZE / @sizeOf(usize);
const PAGE_INDEX_SIZE = @min(Pool.BLOCK_SIZE / @sizeOf(usize), 4096);

const BucketIndex = struct {
    buckets: [BUCKET_INDEX_SIZE]?*Bucket,
};

const PageIndex = struct {
    pages: [PAGE_INDEX_SIZE]?*Page,
};

pub const DataStorage = struct {
    pool: *Pool,
    len: usize,

    bucket_index: *BucketIndex,
    bucket_split: usize,
    bucket_round: usize,
    n_buckets: usize,

    page_index: *PageIndex,
    n_pages_static: usize,
    n_pages_dynamic: usize,

    pub fn init(pool: *Pool) DataStorage {
        var storage = DataStorage{
            .pool = pool,
            .len = 0,
            .bucket_index = pool.create(BucketIndex),
            .bucket_split = 0,
            .bucket_round = 0,
            .n_buckets = 0,
            .page_index = pool.create(PageIndex),
            .n_pages_static = 0,
            .n_pages_dynamic = 0,
        };

        storage.bucket_index.buckets = [_]?*Bucket{null} ** BUCKET_INDEX_SIZE;
        storage.page_index.pages = [_]?*Page{null} ** PAGE_INDEX_SIZE;
        return storage;
    }

    pub fn deinit(storage: *DataStorage) void {
        for (0..storage.n_buckets) |i| {
            storage.bucket_index.buckets[i].?.destroy(storage.pool);
        }
        for (0..storage.n_pages_static) |i| {
            storage.page_index.pages[i].?.destroy(storage.pool);
        }
        for (0..storage.n_pages_dynamic) |i| {
            storage.page_index.pages[i + PAGE_INDEX_SIZE / 2].?.destroy(storage.pool);
        }
        storage.pool.destroy(storage.bucket_index);
        storage.pool.destroy(storage.page_index);
        storage.* = undefined;
    }

    pub fn copy(storage: *DataStorage, comptime V: type) DataStorage {
        var new_storage = DataStorage.init(storage.pool);
        new_storage.len = storage.len;

        for (0..storage.n_buckets) |i| {
            var bucket = storage.bucket_index.buckets[i];
            var new_bucket_ptr: *?*Bucket = &new_storage.bucket_index.buckets[i];

            while (bucket != null) {
                new_bucket_ptr.* = Bucket.create(storage.pool);
                new_bucket_ptr.*.?.* = bucket.?.*;
                new_bucket_ptr = &new_bucket_ptr.*.?.head.next;
                bucket = bucket.?.head.next;
            }
        }
        new_storage.bucket_split = storage.bucket_split;
        new_storage.bucket_round = storage.bucket_round;
        new_storage.n_buckets = storage.n_buckets;

        for (0..PAGE_INDEX_SIZE) |i| {
            if (storage.page_index.pages[i] == null) continue;
            if (storage.page_index.pages[i].?.head.modified.load(.unordered)) {
                new_storage.page_index.pages[i] = Page.create(V, storage.pool);
                // we mustn't overwrite the pointers in the header generated by Page.create
                // so the copying of the actual data is done manually
                const len = storage.page_index.pages[i].?.head.len;
                if (len > 0) {
                    @memcpy(
                        new_storage.page_index.pages[i].?.head.keys[0..len],
                        storage.page_index.pages[i].?.head.keys[0..len],
                    );
                    @memcpy(
                        new_storage.page_index.pages[i].?.head.vals(V)[0..len],
                        storage.page_index.pages[i].?.head.vals(V)[0..len],
                    );
                }
                new_storage.page_index.pages[i].?.head.len = len;
            } else {
                new_storage.page_index.pages[i] = storage.page_index.pages[i];
                new_storage.page_index.pages[i].?.head.refcount += 1;
            }
        }
        new_storage.n_pages_static = storage.n_pages_static;
        new_storage.n_pages_dynamic = storage.n_pages_dynamic;

        return new_storage;
    }

    pub fn has(storage: DataStorage, key: Entity) bool {
        if (storage.n_buckets == 0) return false;
        if (key == nil) return false;
        const bucket_ix = storage.bucketIndex(key);
        return storage.bucket_index.buckets[bucket_ix].?.has(storage.page_index, key);
    }

    pub fn getPtr(storage: *DataStorage, comptime V: type, key: Entity) ?*V {
        if (storage.n_buckets == 0) return null;
        if (key == nil) return null;
        const bucket_ix = storage.bucketIndex(key);
        return storage.bucket_index.buckets[bucket_ix].?.getPtr(V, storage.page_index, key);
    }

    pub fn getConstPtr(storage: *DataStorage, comptime V: type, key: Entity) ?*const V {
        if (storage.n_buckets == 0) return null;
        if (key == nil) return null;
        const bucket_ix = storage.bucketIndex(key);
        return storage.bucket_index.buckets[bucket_ix].?.getConstPtr(V, storage.page_index, key);
    }

    /// noop if present (returns false), true means key was added
    pub fn ins(storage: *DataStorage, comptime V: type, key: Entity, val: V, hint: Hint) bool {
        std.debug.assert(key != nil);
        // failure to expand buckets is a soft fail and doesn't break anything
        // we just get performance loss from bucket chaining
        if (storage.bucketLoad() > STORAGE_LOAD_MAX) storage.bucketExpand();
        if (storage.pageFull(hint)) {
            const success = storage.pageExpand(V, hint);
            if (!success) {
                log.err(
                    "Failed to ins {s} for entity {} (with value {}): All {} pages full",
                    .{ @typeName(V), key, val, hint },
                );
                return false;
            }
        }

        const page = switch (hint) {
            .static => storage.n_pages_static - 1,
            .dynamic => storage.n_pages_dynamic - 1 + PAGE_INDEX_SIZE / 2,
        };
        const index = storage.page_index.pages[page].?.head.len;
        // const index = storage.page_index.pages[page].?.push(V, key, val);
        const success = storage.bucketIns(key, page, index);
        if (success) {
            storage.len += 1;
            _ = storage.page_index.pages[page].?.push(V, key, val);
        }
        return success;
    }

    /// noop if not present (return false), true means key was removed
    pub fn del(storage: *DataStorage, comptime V: type, key: Entity) bool {
        std.debug.assert(key != nil);
        if (storage.len == 0) return false;
        if (storage.bucketLoad() < STORAGE_LOAD_MIN) storage.bucketShrink();
        if (storage.pageEmpty(.static)) storage.pageShrink(.static);
        if (storage.pageEmpty(.dynamic)) storage.pageShrink(.dynamic);

        const bucket_ix = storage.bucketIndex(key);
        // we can only delete things that exist
        const loc = storage.bucket_index.buckets[bucket_ix].?.getLocPtr(
            storage.page_index,
            key,
        ) orelse return false;

        // first, replace our entry with the last entry on the last page
        // note that we avoid changing the hinting of the swap-erased object
        const last_page_index = if (loc.page < PAGE_INDEX_SIZE / 2)
            storage.n_pages_static - 1
        else
            storage.n_pages_dynamic - 1 + PAGE_INDEX_SIZE / 2;
        const last_page = storage.page_index.pages[last_page_index].?;
        std.debug.assert(last_page.head.len > 0);
        const last_key = last_page.head.keys[last_page.head.len - 1];
        const last_val = last_page.head.vals(V)[last_page.head.len - 1];

        const last_bucket_ix = storage.bucketIndex(last_key);
        const last_loc = storage.bucket_index.buckets[last_bucket_ix].?
            .getLocPtr(storage.page_index, last_key).?;

        storage.page_index.pages[last_loc.page].?.head.keys[last_loc.index] =
            storage.page_index.pages[loc.page].?.head.keys[loc.index];
        storage.page_index.pages[last_loc.page].?.head.vals(V)[last_loc.index] =
            storage.page_index.pages[loc.page].?.head.vals(V)[loc.index];
        storage.page_index.pages[loc.page].?.head.keys[loc.index] = last_key;
        storage.page_index.pages[loc.page].?.head.vals(V)[loc.index] = last_val;
        const tmp_page = last_loc.page;
        const tmp_index = last_loc.index;
        last_loc.page = loc.page;
        last_loc.index = loc.index;
        loc.page = tmp_page;
        loc.index = tmp_index;

        storage.page_index.pages[loc.page].?.head.modified.store(true, .unordered);
        storage.page_index.pages[last_loc.page].?.head.modified.store(true, .unordered);

        // then we can delete in the hashmap
        const deleted = storage.bucket_index.buckets[bucket_ix].?.del(
            storage.pool,
            storage.page_index,
            last_page_index,
            key,
        );
        std.debug.assert(deleted);
        last_page.head.len -= 1;
        storage.len -= 1;
        return true;
    }

    const EntityIterator = struct {
        storage: *DataStorage,
        keys: [*]Entity,
        page_cursor: usize,
        index_cursor: usize,

        pub fn next(it: *EntityIterator) ?Entity {
            while (it.index_cursor == 0) {
                if (it.page_cursor == PAGE_INDEX_SIZE / 2) {
                    it.page_cursor = it.storage.n_pages_static;
                }
                if (it.page_cursor == 0) return null;

                it.page_cursor -= 1;
                it.index_cursor = it.storage.page_index.pages[it.page_cursor].?.head.len;
                it.keys = it.storage.page_index.pages[it.page_cursor].?.head.keys;
            }

            it.index_cursor -= 1;
            return it.keys[it.index_cursor];
        }
    };

    pub fn entityIterator(storage: *DataStorage) EntityIterator {
        return .{
            .storage = storage,
            .keys = undefined,
            .page_cursor = storage.n_pages_dynamic + PAGE_INDEX_SIZE / 2,
            .index_cursor = 0,
        };
    }

    fn bucketLoad(storage: DataStorage) f64 {
        return if (storage.n_buckets > 0)
            @as(f64, @floatFromInt(storage.len)) /
                @as(f64, @floatFromInt(Bucket.capacity * storage.n_buckets))
        else
            return 1.0;
    }

    fn bucketExpand(storage: *DataStorage) void {
        const index = storage.bucket_index;

        if (storage.n_buckets == 0) {
            storage.bucket_index.buckets[0] = Bucket.create(storage.pool);
            storage.n_buckets += 1;
            return;
        }

        if (storage.n_buckets == storage.bucket_index.buckets.len) return;

        const splitting = index.buckets[storage.bucket_split].?;
        index.buckets[storage.bucket_split] = Bucket.create(storage.pool);
        index.buckets[storage.n_buckets] = Bucket.create(storage.pool);
        storage.bucket_split += 1;
        storage.n_buckets += 1;

        var it = splitting.iterator();
        while (it.next()) |loc| {
            if (loc.index == Bucket.ix_nil) continue;
            const key = storage.page_index.pages[loc.page].?.head.keys[loc.index];
            const bucket_ix = storage.bucketIndex(key);
            std.debug.assert(bucket_ix == storage.bucket_split - 1 or
                bucket_ix == storage.n_buckets - 1);
            const success = index.buckets[bucket_ix].?.ins(
                storage.pool,
                storage.page_index,
                key,
                loc.page,
                loc.index,
            );
            std.debug.assert(success);
        }
        splitting.destroy(storage.pool);

        if (storage.bucket_split == (@as(usize, 1) << @intCast(storage.bucket_round))) {
            storage.bucket_round += 1;
            storage.bucket_split = 0;
        }
    }

    fn bucketShrink(storage: *DataStorage) void {
        if (storage.n_buckets == 0) return;
        if (storage.n_buckets == 1) {
            if (storage.len > 0) return;
            // storage is empty, destroy the last bucket and just reset to initial storage
            storage.bucket_index.buckets[0].?.destroy(storage.pool);
            storage.n_buckets = 0;
            storage.bucket_split = 0;
            storage.bucket_round = 0;
        }

        const index = storage.bucket_index;
        const merging = index.buckets[storage.n_buckets - 1].?;
        index.buckets[storage.n_buckets - 1] = null;

        if (storage.bucket_split > 0) {
            storage.bucket_split -= 1;
        } else {
            storage.bucket_split = (@as(usize, 1) << @intCast(storage.bucket_round - 1)) - 1;
            storage.bucket_round -= 1;
        }
        storage.n_buckets -= 1;

        var it = merging.iterator();
        while (it.next()) |loc| {
            if (loc.index == Bucket.ix_nil) continue;
            const key = storage.page_index.pages[loc.page].?.head.keys[loc.index];
            const bucket_ix = storage.bucketIndex(key);
            std.debug.assert(bucket_ix == storage.bucket_split);
            const success = index.buckets[storage.bucket_split].?.ins(
                storage.pool,
                storage.page_index,
                key,
                loc.page,
                loc.index,
            );
            std.debug.assert(success);
        }
        merging.destroy(storage.pool);
    }

    fn bucketIns(storage: *DataStorage, key: Entity, page: usize, index: usize) bool {
        const bucket_ix = storage.bucketIndex(key);
        return storage.bucket_index.buckets[bucket_ix].?.ins(
            storage.pool,
            storage.page_index,
            key,
            @intCast(page),
            @intCast(index),
        );
    }

    fn hash(key: Entity) u32 {
        return std.hash.XxHash32.hash(STORAGE_PRIME, std.mem.asBytes(&key));
    }

    fn bucketIndex(storage: DataStorage, key: Entity) usize {
        const h = hash(key);
        var loc = h & ((@as(usize, 1) << @intCast(storage.bucket_round)) - 1);
        if (loc < storage.bucket_split) { // i wonder if this branch predicts well
            loc = h & ((@as(usize, 1) << (@intCast(storage.bucket_round + 1))) - 1);
        }
        return loc;
    }

    fn pageFull(storage: DataStorage, hint: Hint) bool {
        switch (hint) {
            .static => {
                if (storage.n_pages_static == 0) return true;
                const page = storage.page_index.pages[storage.n_pages_static - 1].?;
                std.debug.assert(page.head.len <= page.head.capacity);
                return page.head.len == page.head.capacity;
            },
            .dynamic => {
                if (storage.n_pages_dynamic == 0) return true;
                const page = storage.page_index
                    .pages[storage.n_pages_dynamic - 1 + PAGE_INDEX_SIZE / 2].?;
                std.debug.assert(page.head.len <= page.head.capacity);
                return page.head.len == page.head.capacity;
            },
        }
    }

    fn pageEmpty(storage: DataStorage, hint: Hint) bool {
        switch (hint) {
            .static => {
                if (storage.n_pages_static == 0) return false;
                const page = storage.page_index.pages[storage.n_pages_static - 1].?;
                return page.head.len == 0;
            },
            .dynamic => {
                if (storage.n_pages_dynamic == 0) return false;
                const page = storage.page_index
                    .pages[storage.n_pages_dynamic - 1 + PAGE_INDEX_SIZE / 2].?;
                return page.head.len == 0;
            },
        }
    }

    fn pageExpand(storage: *DataStorage, comptime V: type, hint: Hint) bool {
        switch (hint) {
            .static => {
                const index = storage.page_index;
                if (storage.n_pages_static == PAGE_INDEX_SIZE / 2) return false;

                index.pages[storage.n_pages_static] = Page.create(V, storage.pool);
                storage.n_pages_static += 1;
            },
            .dynamic => {
                const index = storage.page_index;
                if (storage.n_pages_dynamic == PAGE_INDEX_SIZE / 2) return false;

                index.pages[storage.n_pages_dynamic + PAGE_INDEX_SIZE / 2] =
                    Page.create(V, storage.pool);
                storage.n_pages_dynamic += 1;
            },
        }

        return true;
    }

    fn pageShrink(storage: *DataStorage, hint: Hint) void {
        switch (hint) {
            .static => {
                std.debug.assert(storage.n_pages_static > 0);
                storage.page_index.pages[storage.n_pages_static - 1].?.destroy(storage.pool);
                storage.page_index.pages[storage.n_pages_static - 1] = null;
                storage.n_pages_static -= 1;
            },
            .dynamic => {
                std.debug.assert(storage.n_pages_dynamic > 0);
                storage.page_index
                    .pages[storage.n_pages_dynamic - 1 + PAGE_INDEX_SIZE / 2].?.destroy(storage.pool);
                storage.page_index
                    .pages[storage.n_pages_dynamic - 1 + PAGE_INDEX_SIZE / 2] = null;
                storage.n_pages_dynamic -= 1;
            },
        }
    }

    fn debugPrint(storage: DataStorage, comptime V: type) void {
        std.debug.print("DataStorage - {} item(s)\n", .{storage.len});
        for (0..storage.n_buckets) |i| {
            std.debug.print(" bkt", .{});
            storage.bucket_index.buckets[i].?.debugPrint(storage.page_index);
        }
        for (0..storage.n_pages_static) |i| {
            std.debug.print(" {:>3}", .{i});
            storage.page_index.pages[i].?.debugPrint(V);
        }
        for (0..storage.n_pages_dynamic) |i| {
            std.debug.print(" {:>3}", .{i + PAGE_INDEX_SIZE / 2});
            storage.page_index.pages[i + PAGE_INDEX_SIZE / 2].?.debugPrint(V);
        }
    }
};

test "storage interface" {
    var p = Pool.init(std.testing.allocator);
    var s = DataStorage.init(&p);
    defer s.deinit();

    try std.testing.expect(s.getPtr(u8, 1) == null);
    try std.testing.expect(s.ins(u8, 1, 0, .static));
    try std.testing.expect(!s.ins(u8, 1, 1, .static));
    try std.testing.expect(s.getPtr(u8, 1) != null);
    try std.testing.expectEqual(0, s.getPtr(u8, 1).?.*);
    try std.testing.expectEqual(0, s.getConstPtr(u8, 1).?.*);
    try std.testing.expect(s.del(u8, 1));
    try std.testing.expect(!s.del(u8, 1));
    try std.testing.expect(s.getPtr(u8, 1) == null);

    _ = s.ins(u8, 1, 1, .static);
    _ = s.ins(u8, 2, 2, .dynamic);
    _ = s.ins(u8, 3, 3, .static);
    _ = s.ins(u8, 4, 4, .dynamic);
    var it = s.entityIterator();
    // NOTE order is dynamic before static
    try std.testing.expectEqual(4, it.next().?);
    try std.testing.expectEqual(2, it.next().?);
    try std.testing.expectEqual(3, it.next().?);
    try std.testing.expectEqual(1, it.next().?);
    try std.testing.expectEqual(null, it.next());
}

test "storage fuzz (no copy)" {
    var p = Pool.init(std.testing.allocator);
    var s = DataStorage.init(&p);
    defer s.deinit();
    var h = std.AutoHashMap(Entity, f64).init(std.testing.allocator);
    defer h.deinit();
    var a = try std.ArrayList(Entity).initCapacity(std.testing.allocator, 64 * 1024);
    defer a.deinit();

    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
    var rand = rng.random();

    for (0..64) |_| {
        for (0..1024) |_| {
            const k = rand.int(Entity) & 4096 | 1;
            const v: f64 = @floatFromInt(k);
            try std.testing.expectEqual(h.contains(k), s.has(k));
            if (s.has(k)) continue;
            const success = s.ins(f64, k, v, .static);
            std.debug.assert(success);
            try h.put(k, v);
            try a.append(k);
        }

        for (a.items) |k| {
            if (rand.int(Entity) < k) continue;
            const v: f64 = @floatFromInt(k);
            try std.testing.expectEqual(h.contains(k), s.has(k));
            if (s.has(k)) {
                try std.testing.expectEqual(h.getPtr(k).?.*, s.getPtr(f64, k).?.*);
                const success = s.del(f64, k);
                std.debug.assert(success);
                _ = h.remove(k);
            } else {
                try std.testing.expectEqual(null, s.getPtr(f64, k));
                const success = s.ins(f64, k, v, .dynamic);
                std.debug.assert(success);
                try h.put(k, v);
            }
        }
    }

    var it = h.keyIterator();
    while (it.next()) |k| {
        try std.testing.expect(s.has(k.*));
        const success = s.del(f64, k.*);
        std.debug.assert(success);
    }
    try std.testing.expectEqual(0, s.len);
}

test "storage fuzz (with copy)" {
    const N = 16;

    var ss: [N + 1]DataStorage = undefined;
    var hs: [N + 1]std.AutoHashMap(Entity, f64) = undefined;

    var p = Pool.init(std.testing.allocator);
    var s = DataStorage.init(&p);
    var h = std.AutoHashMap(Entity, f64).init(std.testing.allocator);
    var a = try std.ArrayList(Entity).initCapacity(std.testing.allocator, 16 * 1024);
    defer a.deinit();

    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
    var rand = rng.random();

    for (0..N) |i| {
        for (0..1024) |_| {
            const k = rand.int(Entity) | 1;
            const v: f64 = @floatFromInt(k);
            try std.testing.expectEqual(h.contains(k), s.has(k));
            if (s.has(k)) continue;
            const success = s.ins(f64, k, v, .static);
            std.debug.assert(success);
            try h.put(k, v);
            try a.append(k);
        }

        for (a.items) |k| {
            if (rand.int(Entity) < k) continue;
            const v: f64 = @floatFromInt(k);
            try std.testing.expectEqual(h.contains(k), s.has(k));
            if (s.has(k)) {
                try std.testing.expectEqual(h.getPtr(k).?.*, s.getPtr(f64, k).?.*);
                const success = s.del(f64, k);
                std.debug.assert(success);
                _ = h.remove(k);
            } else {
                try std.testing.expectEqual(null, s.getPtr(f64, k));
                const success = s.ins(f64, k, v, .dynamic);
                std.debug.assert(success);
                try h.put(k, v);
            }
        }

        ss[i] = s;
        hs[i] = h;
        s = s.copy(f64);
        h = try h.clone();
    }
    ss[N] = s;
    hs[N] = h;

    for (0..N + 1) |i| {
        s = ss[i];
        h = hs[i];

        var it = h.keyIterator();
        while (it.next()) |k| {
            try std.testing.expect(s.has(k.*));
            if (i % 2 == 0) continue;
            const success = s.del(f64, k.*);
            std.debug.assert(success);
        }
        if (i % 2 == 1) try std.testing.expectEqual(0, s.len);

        s.deinit();
        h.deinit();
    }
}

test "storage fuzz (no copy) v2" {
    var p = Pool.init(std.testing.allocator);
    var s = DataStorage.init(&p);
    defer s.deinit();
    var h = std.AutoHashMap(Entity, u32).init(std.testing.allocator);
    defer h.deinit();

    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
    var rand = rng.random();

    for (0..4096) |_| {
        {
            const k = (rand.int(Entity) & 4096) | 1;
            const v: u32 = @intCast(k);
            const success = s.ins(u32, k, v, .static);
            if (success) try h.put(k, v);
        }
        {
            const k = (rand.int(Entity) & 4096) | 1;
            const v: u32 = @intCast(k);
            const success = s.ins(u32, k, v, .dynamic);
            if (success) try h.put(k, v);
        }
        {
            const k = (rand.int(Entity) & 4096) | 1;
            const ss = s.del(u32, k);
            const hs = h.remove(k);
            try std.testing.expect(ss == hs);
        }

        var acc_s: u32 = 0;
        var acc_h: u32 = 0;

        var sit = s.entityIterator();
        while (sit.next()) |k| {
            const v = s.getConstPtr(u32, k).?.*;
            acc_s +%= v;
        }
        var hit = h.keyIterator();
        while (hit.next()) |k| {
            const v = h.get(k.*).?;
            acc_h +%= v;
        }
        try std.testing.expect(acc_s == acc_h);
    }
}

test "storage fuzz (copy) v2" {
    var p = Pool.init(std.testing.allocator);
    var s = DataStorage.init(&p);
    defer s.deinit();
    var h = std.AutoHashMap(Entity, u32).init(std.testing.allocator);
    defer h.deinit();

    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
    var rand = rng.random();

    for (0..256) |_| {
        var spre = s.copy(u32);
        defer spre.deinit();
        var hpre = try h.clone();
        defer hpre.deinit();

        for (0..16) |_| {
            {
                const k = (rand.int(Entity) & 4096) | 1;
                const v: u32 = @intCast(k);
                const success = s.ins(u32, k, v, .static);
                if (success) try h.put(k, v);
            }
            {
                const k = (rand.int(Entity) & 4096) | 1;
                const v: u32 = @intCast(k);
                const success = s.ins(u32, k, v, .dynamic);
                if (success) try h.put(k, v);
            }
            {
                const k = (rand.int(Entity) & 4096) | 1;
                const ss = s.del(u32, k);
                const hs = h.remove(k);
                try std.testing.expect(ss == hs);
            }
        }

        {
            var acc_s: u32 = 0;
            var acc_h: u32 = 0;

            var sit = spre.entityIterator();
            while (sit.next()) |k| {
                const v = spre.getConstPtr(u32, k).?.*;
                acc_s +%= v;
            }
            var hit = hpre.keyIterator();
            while (hit.next()) |k| {
                const v = hpre.get(k.*).?;
                acc_h +%= v;
            }
            try std.testing.expect(acc_s == acc_h);
        }
        {
            var acc_s: u32 = 0;
            var acc_h: u32 = 0;

            var sit = s.entityIterator();
            while (sit.next()) |k| {
                const v = s.getConstPtr(u32, k).?.*;
                acc_s +%= v;
            }
            var hit = h.keyIterator();
            while (hit.next()) |k| {
                const v = h.get(k.*).?;
                acc_h +%= v;
            }
            try std.testing.expect(acc_s == acc_h);
        }
    }
}
