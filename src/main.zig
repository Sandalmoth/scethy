const std = @import("std");

// new idea
// basically a fixed sized object pool designed to hold megastruct entities
// with bitsets describing what properties are/aren't set for an entity
// essentially a big-matrix type ECS

// an entity is indicated by a number (u64)
// where masking off the LSBs yields the index into the internal array
// and the MSBs contain a version id for each entity

const Options = struct {
    size: usize,
    handle: type,
};

pub fn Context(comptime Entity: type, comptime options: Options) type {
    std.debug.assert(std.math.isPowerOfTwo(options.size));

    return struct {
        const Ctx = @This();

        pub const Component = std.meta.FieldEnum(Entity);
        pub const n_components = std.meta.fields(Component).len;

        pub const size = options.size;
        pub const Handle = options.handle;
        pub const mask_slot = std.math.maxInt(std.meta.Int(.unsigned, std.math.log2_int(usize, size)));

        pub const View = struct {
            mask: std.StaticBitSet(size),
            data: []Entity,
            cursor: usize,
        };

        alloc: std.mem.Allocator,

        // actual storage of entities
        data: []Entity,
        // indicates what entities in the array are in use
        extant: *std.StaticBitSet(size),
        // for each entity, indicates if that component is in use
        components: []std.StaticBitSet(size),
        // current identifiers
        handles: []Handle,

        pub fn init(alloc: std.mem.Allocator) !Ctx {
            var ctx = Ctx{
                .alloc = alloc,
                .data = undefined,
                .extant = undefined,
                .components = undefined,
                .handles = undefined,
            };

            // NOTE is there a nicer way of allocating several things safely?
            ctx.data = try alloc.alloc(Entity, size);
            errdefer alloc.free(ctx.data);
            ctx.extant = try alloc.create(std.StaticBitSet(size));
            errdefer alloc.destroy(ctx.extant);
            ctx.components = try alloc.alloc(std.StaticBitSet(size), n_components);
            errdefer alloc.free(ctx.components);
            ctx.handles = try alloc.alloc(Handle, size);
            errdefer alloc.free(ctx.handles);

            ctx.extant.* = std.StaticBitSet(options.size).initEmpty();
            for (0..n_components) |i| {
                ctx.components[i] = std.StaticBitSet(options.size).initEmpty();
            }
            for (0..size) |i| {
                ctx.handles[i] = 0;
            }

            return ctx;
        }

        pub fn deinit(ctx: *Ctx) void {
            ctx.alloc.free(ctx.data);
            ctx.alloc.destroy(ctx.extant);
            ctx.alloc.free(ctx.components);
            ctx.alloc.free(ctx.handles);
            ctx.* = undefined;
        }

        pub fn create(ctx: *Ctx) !u64 {
            if (ctx.active.complement.findFirstSet()) |i| {
                _ = i;
            } else {
                return error.EntityContextFull;
            }
        }

        pub fn has(ctx: *Ctx, e: Handle, cmp: Component) bool {
            _ = ctx;
            _ = e;
            _ = cmp;
        }

        pub fn view(ctx: *Ctx, includes: anytype, excludes: anytype) View {
            _ = ctx;
            _ = includes;
            _ = excludes;
        }

        pub fn get(ctx: *Ctx, handle: Handle) !Entity {
            const slot = handle & mask_slot;
            _ = ctx;
            _ = slot;
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

    var ctx = try Context(T, .{
        .size = 512,
        .handle = u64,
    }).init(std.testing.allocator);
    defer ctx.deinit();

    const vw = @TypeOf(ctx).View{ .mask = undefined, .data = undefined, .cursor = undefined };

    std.debug.print("{}\n", .{@sizeOf(@TypeOf(ctx))});
    std.debug.print("{}\n", .{@sizeOf(@TypeOf(vw))});
    std.debug.print("{x}\n", .{@TypeOf(ctx).mask_slot});
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
