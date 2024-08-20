const std = @import("std");

const DataStorage = @import("storage.zig").DataStorage;

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

pub fn Table(comptime Vs: type, comptime Is: type) type {
    return struct {
        const Self = @This();

        pub const Component = std.meta.FieldEnum(Vs);
        const n_components = std.meta.fields(Component).len;
        fn ComponentType(comptime c: Component) type {
            return std.meta.fields(Vs)[@intFromEnum(c)].type;
        }

        pub const Interface = std.meta.FieldEnum(Is);
        const n_interfaces = std.meta.fields(Interface).len;
        fn InterfaceType(comptime i: Interface) type {
            return std.meta.fields(Is)[@intFromEnum(i)].type;
        }

        alloc: std.mem.Allocator,
        pool: *Pool,
        entities: DataStorage,
        data_storage: std.EnumArray(Component, DataStorage),
        // interface_storage: std.EnumArray(Interface, DataStorage),

        pub fn init(alloc: std.mem.Allocator, pool: *Pool) *Self {
            var table = alloc.create(Self) catch @panic("Table.init: allocation falure");
            table.alloc = alloc;
            table.pool = pool;
            table.entities = DataStorage.init(pool);
            inline for (0..n_components) |j| {
                const c: Component = @enumFromInt(j);
                table.data_storage.getPtr(c).* = DataStorage.init(pool);
                errdefer table.data_storage.getPtr(c).deinit();
            }
            // inline for (0..n_interfaces) |j| {
            //     const i: Component = @enumFromInt(j);
            //     table.components.getPtr(i).* = try DataStorage.init(pool);
            //     errdefer table.components.getPtr(i).deinit();
            // }
            return table;
        }

        pub fn deinit(table: *Self) void {
            table.entities.deinit();
            inline for (0..n_components) |j| {
                const c: Component = @enumFromInt(j);
                table.data_storage.getPtr(c).deinit();
            }
            table.alloc.destroy(table);
        }

        pub fn copy(table: *Self) *Self {
            _ = table;
        }

        pub fn create(table: *Self) Entity {
            _ = table;
            return nil;
        }

        pub fn exists(table: *Self, e: Entity) bool {
            _ = table;
            _ = e;
        }

        pub fn destroy(table: *Self, e: Entity) void {
            _ = table;
            _ = e;
        }

        pub fn queueDestroy(table: *Self, e: Entity) void {
            _ = table;
            _ = e;
        }

        pub fn ins(
            table: *Self,
            comptime c: Component,
            hint: Hint,
            e: Entity,
            val: ComponentType(c),
        ) void {
            _ = table;
            _ = e;
            _ = val;
            _ = hint;
        }

        pub fn insInterface(
            table: *Self,
            comptime c: Component,
            e: Entity,
            Impl: type,
        ) void {
            _ = table;
            _ = c;
            _ = e;
            _ = Impl;
        }

        pub fn del(table: *Self, comptime c: Component, e: Entity) void {
            _ = table;
            _ = c;
            _ = e;
        }

        pub fn getPtr(table: *Self, comptime c: Component, e: Entity) ?*ComponentType(c) {
            _ = table;
            _ = e;
        }

        pub fn getConstPtr(
            table: *Self,
            comptime c: Component,
            e: Entity,
        ) ?*const ComponentType(c) {
            _ = table;
            _ = e;
        }

        pub fn has(table: *Self, c: Component, e: Entity) bool {
            _ = table;
            _ = c;
            _ = e;
        }
    };
}

const V1 = struct {
    int: u32,
};
const I1 = struct {
    float: f32,
};

test "scratch" {
    const T = Table(V1, I1);
    inline for (std.meta.fields(T.Component)) |c| {
        std.debug.print("{s}\n", .{c.name});
    }
    inline for (std.meta.fields(T.Interface)) |c| {
        std.debug.print("{s}\n", .{c.name});
    }

    var p = Pool.init(std.testing.allocator);
    var t = T.init(std.testing.allocator, &p);
    defer t.deinit();
}

// define with struct mapping component names to types
// var t = Table(.{.int = u32, ... });
// t.ins(entity, .int, 123);
// this allows for duplicate types, which could be useful

// use types as a key directly
// var t = Table{};
// t.ins(entity, u32, 123);

// stringly typed
// var t = Table{};
// t.set(entity, "int", 123);
// but this seems very inefficient

// constain to enum but register properties later
// var t = Table(<enum>).init();
// t.register(<enum>, type, .data);
// t.register(<enum>, type, .interface);
// t.insI(entity, <enum>, type, value)
// t.insD(entity, <enum>, type, )

// ???

// virtual component design
// const Interface = struct {.ctx: *anyopaque, vtable: *const VTable};
// const Impl = struct {x: i32, fn inc(impl: *Impl) {impl.x += 1;}};
// t.insv(entity, .interface, Impl, .{.x = 123});
// but then, since we store pointers in the interfaces
// any copying of the implementation means the interfaces need updating
// - simplest idea, scrap COW for the virtual components and always copy everything
// - even if we mark implementation pages for edits, how can we find the matching interfaces?
// t.getInterfacePtr(entity, component).?.update();

// get*, has, could actually be the same as for the data components
// even del could be shared if we lazy-delete (and delete only on copy)
// however, inc does need to know the type and value of the implementation
