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

            pub fn next(vw: *View) ?*Entity {
                // there's probably some faster/better way of doing this?

                while (vw.cursor < vw.data.len and !vw.mask.isSet(vw.cursor)) : (vw.cursor += 1) {}
                if (vw.cursor < vw.data.len) {
                    const tmp = vw.cursor; // need post increment lol
                    vw.cursor += 1;
                    return &vw.data[tmp];
                } else {
                    return null;
                }
            }

            pub fn reset(vw: *View) void {
                vw.cursor = 0;
            }
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
                ctx.data[i] = undefined;
                ctx.handles[i] = @truncate(Handle, i);
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

        pub fn create(ctx: *Ctx) !Handle {
            if (ctx.extant.complement().findFirstSet()) |i| {
                ctx.handles[i] += @truncate(Handle, size); // generational increment
                ctx.extant.set(i);
                return ctx.handles[i];
            } else {
                return error.EntityContextFull;
            }
        }

        pub fn destroy(ctx: *Ctx, handle: Handle) void {
            const slot = handle & mask_slot;
            if (handle != ctx.handles[slot]) {
                std.log.warn("used out of date handle in destroy", .{});
                return;
            }

            ctx.extant.unset(slot);
            for (0..n_components) |i| {
                ctx.components[i].unset(i);
            }
            ctx.data[slot] = undefined;
        }

        pub fn add(ctx: *Ctx, handle: Handle, comptime component: Component, value: anytype) void {
            const slot = handle & mask_slot;
            if (handle != ctx.handles[slot]) {
                std.log.warn("used out of date handle in add", .{});
                return;
            }

            // this is a pretty awkward construction...
            // but it should basically disappear at compile time
            // and become entity.component = value
            @field(
                ctx.data[slot],
                std.meta.fieldInfo(Entity, component).name,
            ) = value;
            ctx.components[@enumToInt(component)].set(slot);
        }

        pub fn remove(ctx: *Ctx, handle: Handle, comptime component: Component) void {
            const slot = handle & mask_slot;
            if (handle != ctx.handles[slot]) {
                std.log.warn("used out of date handle in remove", .{});
                return;
            }

            //  does this get removed in release compilation?
            @field(
                ctx.data[slot],
                std.meta.fieldInfo(Entity, component).name,
            ) = undefined;
            ctx.components[@enumToInt(component)].unset(slot);
        }

        pub fn has(ctx: *Ctx, handle: Handle, comptime component: Component) bool {
            const slot = handle & mask_slot;
            if (handle != ctx.handles[slot]) {
                std.log.warn("used out of date handle in has", .{});
                return false;
            }
            return ctx.components[@enumToInt(component)].isSet(slot);
        }

        pub fn view(ctx: *Ctx, includes: anytype, excludes: anytype) View {
            var result = View{
                .mask = ctx.extant.*,
                .data = ctx.data,
                .cursor = 0,
            };

            inline for (includes) |component| {
                result.mask.setIntersection(
                    ctx.components[@enumToInt(@as(Component, component))],
                );
            }

            inline for (excludes) |component| {
                result.mask.setIntersection(
                    ctx.components[@enumToInt(@as(Component, component))].complement(),
                );
            }

            return result;
        }

        pub fn get(ctx: *Ctx, handle: Handle) ?*Entity {
            const slot = handle & mask_slot;
            if (handle != ctx.handles[slot]) {
                return null;
            }
            return &ctx.data[slot];
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
        .handle = u32,
    }).init(std.testing.allocator);
    defer ctx.deinit();

    std.debug.print("{}\n", .{@sizeOf(@TypeOf(ctx))});
    std.debug.print("{x}\n", .{@TypeOf(ctx).mask_slot});

    var e1 = try ctx.create();
    var e2 = try ctx.create();

    std.debug.print("{} {}\n", .{ e1, e2 });

    ctx.add(e1, .a, 3);
    ctx.add(e1, .b, .{ 1, 2, 3, 4 });
    ctx.add(e2, .b, .{ 5, 6, 7, 8 });
    ctx.add(e2, .c, {});

    std.debug.print("has a:{} has b:{} has c:{} {}\n", .{
        ctx.has(e1, .a),
        ctx.has(e1, .b),
        ctx.has(e1, .c),
        ctx.get(e1).?,
    });
    std.debug.print("has a:{} has b:{} has c:{} {}\n", .{
        ctx.has(e2, .a),
        ctx.has(e2, .b),
        ctx.has(e2, .c),
        ctx.get(e2).?,
    });

    std.debug.print("entities with a\n", .{});
    var view_a = ctx.view(.{.a}, .{});
    while (view_a.next()) |entity| {
        std.debug.print("{}\n", .{entity});
    }

    std.debug.print("entities with b\n", .{});
    var view_b = ctx.view(.{.b}, .{});
    while (view_b.next()) |entity| {
        std.debug.print("{}\n", .{entity});
    }

    std.debug.print("entities with c\n", .{});
    var view_c = ctx.view(.{.c}, .{});
    while (view_c.next()) |entity| {
        std.debug.print("{}\n", .{entity});
    }

    std.debug.print("modifying entities with b\n", .{});
    view_b.reset();
    while (view_b.next()) |entity| {
        entity.b += @splat(4, @as(f32, 0.5));
    }

    std.debug.print("entities with b without a\n", .{});
    var view_ba = ctx.view(.{.b}, .{.a});
    while (view_ba.next()) |entity| {
        std.debug.print("{}\n", .{entity});
    }

    std.debug.print("entities with b without c\n", .{});
    var view_bc = ctx.view(.{.b}, .{.c});
    while (view_bc.next()) |entity| {
        std.debug.print("{}\n", .{entity});
    }

    std.debug.print("removing b from e1\n", .{});
    ctx.remove(e1, .b);
    var view_b2 = ctx.view(.{.b}, .{});
    while (view_b2.next()) |entity| {
        std.debug.print("{}\n", .{entity});
    }
    ctx.add(e1, .b, .{ 1, 2, 3, 4 });

    std.debug.print("destroying e2\n", .{});
    ctx.destroy(e2);
    var view_b3 = ctx.view(.{.b}, .{});
    while (view_b3.next()) |entity| {
        std.debug.print("{}\n", .{entity});
    }
}
