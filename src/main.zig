const std = @import("std");

// new idea
// basically a fixed sized object pool designed to hold megastruct entities
// with bitsets describing what properties are/aren't set for an entity
// essentially a big-matrix type ECS

// an entity is indicated by a number (u64)
// where masking off the LSBs yields the index into the internal array
// and the MSBs contain a version id for each entity

const Options = struct {
    size: u32,
};

pub fn Context(comptime Entity: type, comptime options: Options) type {
    return struct {
        const Ctx = @This();
        pub const Component = std.meta.FieldEnum(Entity);
        pub const n_components = std.meta.fields(Component).len;
        pub const size = options.size;

        pub const View = struct {
            mask: std.StaticBitSet(size),
            data: []Entity,
        };

        alloc: std.mem.Allocator,

        // actual storage of entities
        data: []Entity,
        // indicates what entities in the array are in use
        entities: *std.StaticBitSet(size),
        // for each entity, indicates if that component is in use
        components: []std.StaticBitSet(size),

        pub fn init(alloc: std.mem.Allocator) !Ctx {
            var ctx = Ctx{
                .alloc = alloc,
                .data = undefined,
                .entities = undefined,
                .components = undefined,
            };

            // NOTE is there a nicer way of allocating several things safely?
            ctx.data = try alloc.alloc(Entity, options.size);
            errdefer alloc.free(ctx.data);
            ctx.entities = try alloc.create(std.StaticBitSet(options.size));
            errdefer alloc.destroy(ctx.entities);
            ctx.components = try alloc.alloc(std.StaticBitSet(options.size), n_components);
            errdefer alloc.free(ctx.components);

            ctx.entities.* = std.StaticBitSet(options.size).initEmpty();
            for (0..n_components) |i| {
                ctx.components[i] = std.StaticBitSet(options.size).initEmpty();
            }

            return ctx;
        }

        pub fn deinit(ctx: *Ctx) void {
            ctx.alloc.free(ctx.data);
            ctx.alloc.destroy(ctx.entities);
            ctx.alloc.free(ctx.components);
            ctx.* = undefined;
        }

        pub fn create(ctx: *Ctx) !u64 {
            _ = ctx;
            // if (ctx.active.complement.findFirstSet()) |i| {}
        }

        pub fn view(ctx: *Ctx, includes: anytype, excludes: anytype) View {
            _ = ctx;
            _ = includes;
            _ = excludes;
        }
    };
}

const _test = struct {
    const A = struct {
        a: u32,
        b: @Vector(4, f32),
        c: void,
    };
};

test "basics" {
    const T = _test.A;

    std.debug.print("{} {}\n", .{ @sizeOf(T), @alignOf(T) });

    var ctx = try Context(T, .{ .size = 1024 }).init(std.testing.allocator);
    defer ctx.deinit();

    const vw = @TypeOf(ctx).View{ .mask = undefined, .data = undefined };

    std.debug.print("{}\n", .{@sizeOf(@TypeOf(ctx))});
    std.debug.print("{}\n", .{@sizeOf(@TypeOf(vw))});
}

// // ensure alignment on cache line boundaries
// // should also be bigger than any type might possibly have?
// const page_alignment = 64;

// // what should we call it?
// // manager? hub? componentcontainer?
// pub const Context = struct {
//     pub const Settings = struct {
//         page_size: u32 = 4096,
//         growable: bool = false,
//     };

//     pub const Page = struct {
//         next: ?*align(page_alignment) @This(),
//     };
//     const PagePtr = *align(page_alignment) Page;

//     alloc: std.mem.Allocator,
//     settings: Settings,

//     n_pages: u32,
//     free_list: ?PagePtr = null,

//     pub fn init(
//         alloc: std.mem.Allocator,
//         initial_page_count: u32,
//         settings: Settings,
//     ) !Context {
//         var ctx = Context{
//             .alloc = alloc,
//             .settings = settings,
//             .n_pages = initial_page_count,
//         };

//         return ctx;
//     }

//     pub fn deinit() void {}

//     fn allocPage(ctx: *Context) !*align(page_alignment) []u8 {
//         const page = try ctx.alloc.alignedAlloc(u8, page_alignment, ctx.settings.page_size);
//         _ = page;
//         // if (ctx.free_list)
//     }
// };

// test "basic add functionality" {
//     try testing.expect(true);
//     _ = std.heap.MemoryPool(i32); // just for easy going to source

//     var ctx = try Context.init(std.testing.allocator, 32, .{});
//     _ = ctx;
// }
