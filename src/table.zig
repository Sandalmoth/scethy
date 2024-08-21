const std = @import("std");
const log = std.log.scoped(.table);

const DataStorage = @import("storage.zig").DataStorage;
const ImplStorage = @import("implementation.zig").ImplStorage;

pub const Entity = u64;
pub const nil: Entity = 0;

pub const Hint = enum { static, dynamic };

pub const EntityStream = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (cts: *anyopaque) ?Entity,
    };

    pub fn next(ei: EntityStream) ?Entity {
        return ei.vtable.next(ei.ctx);
    }
};

pub const Pool = struct {
    // all ecs data lives in these blocks s.t. we an alloc/dealloc efficiently
    pub const BLOCK_SIZE = 4 * 1024;
    pub const BLOCK_ALIGN = 64;
    const Block = struct {
        data: [BLOCK_SIZE - @sizeOf(usize)]u8 align(BLOCK_ALIGN),
        next: ?*Block,
    };

    comptime {
        std.debug.assert(@sizeOf(Block) == BLOCK_SIZE);
        std.debug.assert(@alignOf(Block) == BLOCK_ALIGN);
    }

    alloc: std.mem.Allocator,
    n_allocs: usize,
    n_free: usize,
    free: ?*Block,

    pub fn init(alloc: std.mem.Allocator) Pool {
        return .{
            .alloc = alloc,
            .n_allocs = 0,
            .n_free = 0,
            .free = null,
        };
    }

    pub fn deinit(pool: *Pool) void {
        std.debug.assert(pool.n_allocs == pool.n_free);
        var walk = pool.free;
        while (walk) |b| {
            walk = b.next;
            pool.alloc.destroy(b);
            pool.n_free -= 1;
            pool.n_allocs -= 1;
        }
        std.debug.assert(pool.n_allocs == 0);
        std.debug.assert(pool.n_free == 0);
        pool.* = undefined;
    }

    pub fn create(pool: *Pool, comptime T: type) *T {
        std.debug.assert(@sizeOf(T) <= BLOCK_SIZE);
        std.debug.assert(@alignOf(T) <= BLOCK_ALIGN);

        if (pool.free == null) {
            const block = pool.alloc.create(Block) catch @panic("allocation failure");
            pool.n_allocs += 1;
            return @alignCast(@ptrCast(block));
        } else {
            const block = pool.free.?;
            pool.free = block.next;
            block.next = null;
            pool.n_free -= 1;
            return @alignCast(@ptrCast(block));
        }
    }

    pub fn destroy(pool: *Pool, ptr: *anyopaque) void {
        // TODO some kind of memory reclamation strategy
        const block: *Block = @alignCast(@ptrCast(ptr));
        block.next = pool.free;
        pool.free = block;
        pool.n_free += 1;
    }
};

const ENTITY_GENERATOR_STEP = 712544676207699917; // prime number

const ComponentSpec = struct {
    type: type,
    interface: bool = false,
};

pub fn Table(
    comptime Spec: anytype,
) type {
    return struct {
        const Self = @This();

        pub const Component = std.meta.FieldEnum(@TypeOf(Spec));
        const n_components = std.meta.fields(Component).len;
        const spec = std.EnumArray(Component, ComponentSpec).init(Spec);
        fn ComponentType(comptime c: Component) type {
            return spec.get(c).type;
        }
        fn isInterface(comptime c: Component) bool {
            return spec.get(c).interface;
        }

        alloc: std.mem.Allocator,
        pool: *Pool,
        entities: DataStorage,
        data_storage: std.EnumArray(Component, DataStorage),
        impl_storage: std.EnumArray(Component, ImplStorage),

        entity_counter: Entity,

        pub fn init(alloc: std.mem.Allocator, pool: *Pool) *Self {
            var table = alloc.create(Self) catch @panic("Table.init: allocation falure");
            table.alloc = alloc;
            table.pool = pool;
            table.entities = DataStorage.init(pool);
            inline for (0..n_components) |j| {
                const c: Component = @enumFromInt(j);
                table.data_storage.getPtr(c).* = DataStorage.init(pool);
                if (isInterface(c)) table.impl_storage.getPtr(c).* = ImplStorage.init(table.pool);
            }
            table.entity_counter = nil +% ENTITY_GENERATOR_STEP;
            return table;
        }

        pub fn deinit(table: *Self) void {
            table.entities.deinit();
            inline for (0..n_components) |j| {
                const c: Component = @enumFromInt(j);
                table.data_storage.getPtr(c).deinit();
                if (isInterface(c)) table.impl_storage.getPtr(c).deinit();
            }
            table.alloc.destroy(table);
        }

        pub fn copy(table: *Self) *Self {
            var new = table.alloc.create(Self) catch @panic("Table.copy: allocation failure");
            new.alloc = table.alloc;
            new.pool = table.pool;
            new.entities = table.entities.copy(void);
            inline for (0..n_components) |j| {
                const c: Component = @enumFromInt(j);
                new.data_storage.getPtr(c).* = table.data_storage.getPtr(c).copy(ComponentType(c));
                errdefer new.data_storage.getPtr(c).deinit();
                if (comptime isInterface(c)) {
                    new.impl_storage.getPtr(c).* = ImplStorage.init(new.pool);
                    const s = new.data_storage.getPtr(c);
                    var it = s.entityIterator();
                    while (it.next()) |e| {
                        const _i = s.getPtr(ComponentType(c), e).?;
                        _i.ctx = new.impl_storage.getPtr(c).allocCopy(_i.ctx);
                    }
                }
            }
            new.entity_counter = table.entity_counter;
            return new;
        }

        pub fn create(table: *Self) Entity {
            // realistically, we never need to handle this, 2**64 - 1 is more than necessary
            // and we shouldn't reuse entity id's, since that could cause incorrect interpolation
            // though if state interpolation isn't used, one could feasibly check for existance
            // after one lap through the counter has been done
            if (table.entity_counter == nil) @panic("entity generation overflow");
            const e = table.entity_counter;
            table.entity_counter +%= ENTITY_GENERATOR_STEP;
            const success = table.entities.ins(void, e, {}, .static);
            std.debug.assert(success);
            return e;
        }

        pub fn exists(table: *Self, e: Entity) bool {
            return table.entities.has(e);
        }

        pub fn destroy(table: *Self, e: Entity) void {
            inline for (0..n_components) |j| {
                const c: Component = @enumFromInt(j);
                _ = table.data_storage.getPtr(c).del(ComponentType(c), e);
            }
            const success = table.entities.del(void, e);
            std.debug.assert(success);
        }

        pub fn incl(
            table: *Self,
            comptime c: Component,
            e: Entity,
            val: ComponentType(c),
            hint: Hint,
        ) void {
            const success = table.data_storage.getPtr(c).ins(ComponentType(c), e, val, hint);
            if (!success) log.debug("Could not incl {} into {}", .{ c, e });
        }

        pub fn inclInterface(
            table: *Self,
            comptime c: Component,
            e: Entity,
            comptime Impl: type,
            impl: Impl,
        ) void {
            const interface = table.impl_storage.getPtr(c).alloc(
                ComponentType(c),
                Impl,
                impl,
            );
            table.incl(c, e, interface, .static);
        }

        pub fn excl(table: *Self, comptime c: Component, e: Entity) void {
            const success = table.data_storage.getPtr(c).del(ComponentType(c), e);
            if (!success) log.debug("Could not excl {} from {}", .{ c, e });
        }

        pub fn getPtr(table: *Self, comptime c: Component, e: Entity) ?*ComponentType(c) {
            return table.data_storage.getPtr(c).getPtr(ComponentType(c), e);
        }

        pub fn getPtrConst(
            table: *Self,
            comptime c: Component,
            e: Entity,
        ) ?*const ComponentType(c) {
            return table.data_storage.getPtr(c).getPtrConst(ComponentType(c), e);
        }

        pub fn has(table: *Self, c: Component, e: Entity) bool {
            return table.data_storage.getPtr(c).has(e);
        }

        fn Query(comptime include_len: usize, comptime exclude_len: usize) type {
            return struct {
                const QSelf = @This();

                parent: DataStorage.EntityIterator,
                include: [include_len - 1]*DataStorage,
                exclude: [exclude_len]*DataStorage,

                pub fn next(q: *QSelf) ?Entity {
                    loop: while (true) {
                        const e = q.parent.next() orelse return null;
                        for (q.include) |s| if (!s.has(e)) continue :loop;
                        for (q.exclude) |s| if (s.has(e)) continue :loop;
                        return e;
                    }
                }
            };
        }

        pub fn query(
            table: *Self,
            comptime include: []const Component,
            comptime exclude: []const Component,
        ) Query(include.len, exclude.len) {
            std.debug.assert(include.len > 0);
            var include_sorted: [include.len]*DataStorage = undefined;
            for (include, 0..) |c, i| include_sorted[i] = table.data_storage.getPtr(c);
            var include_unsorted = true;
            while (include_unsorted) {
                include_unsorted = false;
                for (1..include.len) |i| {
                    if (include_sorted[i - 1].len > include_sorted[i].len) {
                        const tmp = include_sorted[i];
                        include_sorted[i] = include_sorted[i - 1];
                        include_sorted[i - 1] = tmp;
                        include_unsorted = true;
                    }
                }
            }

            var exclude_sorted: [exclude.len]*DataStorage = undefined;
            if (exclude.len > 0) {
                for (exclude, 0..) |c, i| exclude_sorted[i] = table.data_storage.getPtr(c);
                var exclude_unsorted = false;
                while (exclude_unsorted) {
                    exclude_unsorted = true;
                    for (1..exclude.len) |i| {
                        if (exclude_sorted[i - 1].len < exclude_sorted[i].len) {
                            const tmp = exclude_sorted[i];
                            exclude_sorted[i] = exclude_sorted[i - 1];
                            exclude_sorted[i - 1] = tmp;
                            exclude_unsorted = true;
                        }
                    }
                }
            }

            var q = Query(include.len, exclude.len){
                .parent = include_sorted[0].entityIterator(),
                .include = undefined,
                .exclude = undefined,
            };
            if (include.len > 1) @memcpy(q.include[0..], include_sorted[1..]);
            if (exclude.len > 0) @memcpy(q.exclude[0..], exclude_sorted[1..]);
            return q;
        }
    };
}

const I1 = struct {
    ctx: *anyopaque,
    vtable: VTable,

    const VTable = struct {
        foo: *const fn (*anyopaque) void,
    };

    fn foo(i: I1) void {
        i.vtable.foo(i.ctx);
    }
};

const B1 = struct {
    fn foo(ctx: *anyopaque) void {
        _ = ctx;
        std.debug.print("hello from B1\n", .{});
    }

    pub fn interface(b: *B1) I1 {
        return .{
            .ctx = @alignCast(@ptrCast(b)),
            .vtable = .{ .foo = foo },
        };
    }
};

const B2 = struct {
    x: usize,

    fn foo(ctx: *anyopaque) void {
        const b: *B2 = @alignCast(@ptrCast(ctx));
        std.debug.print("hello #{} from B2\n", .{b.x});
        b.x += 1;
    }

    pub fn interface(b: *B2) I1 {
        return .{
            .ctx = @alignCast(@ptrCast(b)),
            .vtable = .{ .foo = foo },
        };
    }
};

test "scratch" {
    const T = Table(.{
        .int = .{ .type = u32 },
        .float = .{ .type = f32 },
        .behaviour = .{ .type = I1, .interface = true },
    });

    var p = Pool.init(std.testing.allocator);
    defer p.deinit();
    var t = T.init(std.testing.allocator, &p);
    defer t.deinit();

    const e0 = t.create();
    std.debug.print("{}\n", .{t.has(.int, e0)});
    std.debug.print("{}\n", .{t.has(.float, e0)});
    std.debug.print("{}\n", .{t.incl(.int, e0, 123, .static)});
    std.debug.print("{}\n", .{t.incl(.int, e0, 234, .static)});
    std.debug.print("{}\n", .{t.incl(.int, e0, 234, .dynamic)});
    std.debug.print("{}\n", .{t.incl(.float, e0, 1.0, .dynamic)});
    std.debug.print("{}\n", .{t.incl(.float, e0, 2.0, .static)});
    std.debug.print("{}\n", .{t.incl(.float, e0, 2.0, .dynamic)});
    if (t.getPtrConst(.int, e0)) |ptr| std.debug.print("{}\n", .{ptr.*});
    if (t.getPtr(.int, e0)) |ptr| ptr.* += 1;
    if (t.getPtrConst(.int, e0)) |ptr| std.debug.print("{}\n", .{ptr.*});
    std.debug.print("{}\n", .{t.has(.int, e0)});
    std.debug.print("{}\n", .{t.has(.float, e0)});

    const e1 = t.create();
    _ = t.inclInterface(.behaviour, e1, B1, .{});
    t.getPtr(.behaviour, e1).?.foo();

    const e2 = t.create();
    _ = t.inclInterface(.behaviour, e2, B2, .{ .x = 0 });
    t.getPtr(.behaviour, e2).?.foo();
    t.getPtr(.behaviour, e2).?.foo();
    t.getPtr(.behaviour, e2).?.foo();

    {
        const t_old = t.copy();
        t.deinit();
        t = t_old;
    }

    t.getPtr(.behaviour, e2).?.foo();
    t.getPtr(.behaviour, e2).?.foo();
    t.getPtr(.behaviour, e2).?.foo();

    var q_int = t.query(&.{.int}, &.{});
    while (q_int.next()) |e| {
        std.debug.print("{}\n", .{t.getPtrConst(.int, e).?.*});
    }

    var q_float = t.query(&.{.float}, &.{});
    while (q_float.next()) |e| {
        std.debug.print("{}\n", .{t.getPtrConst(.float, e).?.*});
    }

    var q_behaviour = t.query(&.{.behaviour}, &.{});
    while (q_behaviour.next()) |e| {
        t.getPtrConst(.behaviour, e).?.foo();
    }
}
