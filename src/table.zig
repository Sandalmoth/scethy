const std = @import("std");

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
    const Block = struct { data: [BLOCK_SIZE]u8 align(BLOCK_ALIGN) };

    comptime {
        std.debug.assert(@sizeOf(Block) == BLOCK_SIZE);
        std.debug.assert(@alignOf(Block) == BLOCK_ALIGN);
    }

    alloc: std.mem.Allocator,
    n_allocs: usize,

    pub fn init(alloc: std.mem.Allocator) Pool {
        return .{
            .alloc = alloc,
            .n_allocs = 0,
        };
    }

    pub fn deinit(pool: *Pool) void {
        std.debug.assert(pool.n_allocs == 0);
        pool.* = undefined;
    }

    pub fn create(pool: *Pool, comptime T: type) *T {
        std.debug.assert(@sizeOf(T) <= BLOCK_SIZE);
        std.debug.assert(@alignOf(T) <= BLOCK_ALIGN);
        const block = pool.alloc.create(Block) catch @panic("allocation failure");
        pool.n_allocs += 1;
        return @alignCast(@ptrCast(block));
    }

    pub fn destroy(pool: *Pool, ptr: *anyopaque) void {
        const block: *Block = @alignCast(@ptrCast(ptr));
        pool.alloc.destroy(block);
        pool.n_allocs -= 1;
    }
};

const ENTITY_GENERATOR_STEP = 712544676207699917; // prime number

const ComponentSpec = struct {
    typ: type,
    interface: bool = false,
};

pub fn Table(
    comptime Component: type,
    comptime Spec: std.enums.EnumFieldStruct(Component, ComponentSpec, null),
) type {
    return struct {
        const Self = @This();

        // pub const Component = std.meta.FieldEnum(Vs);
        const n_components = std.meta.fields(Component).len;
        const spec = std.EnumArray(Component, ComponentSpec).init(Spec);
        fn ComponentType(comptime c: Component) type {
            return spec.get(c).typ;
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
            table.entity_counter = nil + ENTITY_GENERATOR_STEP;
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

        pub fn inclData(
            table: *Self,
            comptime c: Component,
            e: Entity,
            val: ComponentType(c),
            hint: Hint,
        ) bool {
            return table.data_storage.getPtr(c).ins(ComponentType(c), e, val, hint);
        }

        pub fn inclInterface(
            table: *Self,
            comptime c: Component,
            e: Entity,
            comptime Impl: type,
            impl: Impl,
        ) bool {
            const interface = table.impl_storage.getPtr(c).alloc(
                ComponentType(c),
                Impl,
                impl,
            );
            return table.inclData(c, e, interface, .static);
        }

        pub fn excl(table: *Self, comptime c: Component, e: Entity) void {
            _ = table;
            _ = c;
            _ = e;
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
    };
}

const V1 = struct {
    int: u32,
    float: f32,
    behaviour: I1,
};

const V2 = struct {
    int: .{ .typ = u32, .ifc = false },
    float: .{ .typ = f32, .ifc = false },
    behaviour: .{ .typ = I1, .ifc = true },
};

const V3 = enum { int, float, behaviour };

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
    const T = Table(V3, .{
        .int = .{ .typ = u32 },
        .float = .{ .typ = f32 },
        .behaviour = .{ .typ = I1, .interface = true },
    });

    var p = Pool.init(std.testing.allocator);
    defer p.deinit();
    var t = T.init(std.testing.allocator, &p);
    defer t.deinit();

    const e0 = t.create();
    std.debug.print("{}\n", .{t.has(.int, e0)});
    std.debug.print("{}\n", .{t.has(.float, e0)});
    std.debug.print("{}\n", .{t.inclData(.int, e0, 123, .static)});
    std.debug.print("{}\n", .{t.inclData(.int, e0, 234, .static)});
    std.debug.print("{}\n", .{t.inclData(.int, e0, 234, .dynamic)});
    std.debug.print("{}\n", .{t.inclData(.float, e0, 1.0, .dynamic)});
    std.debug.print("{}\n", .{t.inclData(.float, e0, 2.0, .static)});
    std.debug.print("{}\n", .{t.inclData(.float, e0, 2.0, .dynamic)});
    if (t.getPtrConst(.int, e0)) |ptr| std.debug.print("{}\n", .{ptr.*});
    if (t.getPtr(.int, e0)) |ptr| ptr.* += 1;
    if (t.getPtrConst(.int, e0)) |ptr| std.debug.print("{}\n", .{ptr.*});
    std.debug.print("{}\n", .{t.has(.int, e0)});
    std.debug.print("{}\n", .{t.has(.float, e0)});
    t.destroy(e0);

    const e1 = t.create();
    _ = t.inclInterface(.behaviour, e1, B1, .{});
    t.getPtr(.behaviour, e1).?.foo();
    t.destroy(e1);

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

    t.destroy(e2);
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
