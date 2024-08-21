const std = @import("std");

const Entity = @import("table.zig").Entity;
const Pool = @import("table.zig").Pool;
const Table = @import("table.zig").Table;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try bench1(alloc);
}

fn bench1(alloc: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    var stdout = std.io.getStdOut().writer();
    var rng = std.Random.DefaultPrng.init(
        @as(u64, @bitCast(std.time.microTimestamp())) *% 11400714819323198393,
    );
    const rand = rng.random();

    try stdout.print(
        "n\tincl\texcl\tit123\tit12\tit1\tcpall\tcpnone\tcp1\tcp2\tcp3\n",
        .{},
    );

    var acc: u64 = 0;

    const ns = [_]usize{ 100, 316, 1000, 3162, 10_000, 31623, 100_000 };

    for (ns) |n| {
        _ = arena.reset(.retain_capacity);
        var p = Pool.init(alloc);
        defer p.deinit();
        var t = Table(.{
            .int1 = .{ .type = u32 },
            .int2 = .{ .type = u32 },
            .int3 = .{ .type = u32 },
        }).init(alloc, &p);
        defer t.deinit();

        var timer = try std.time.Timer.start();

        for (0..n) |_| {
            const e = t.create();
            if (rand.float(f32) < 0.25) t.incl(.int1, e, rand.int(u32), .static);
            if (rand.float(f32) < 0.50) t.incl(.int2, e, rand.int(u32), .static);
            if (rand.float(f32) < 0.75) t.incl(.int3, e, rand.int(u32), .static);
        }
        const t_incl = @as(f64, @floatFromInt(timer.lap())) / @as(f64, @floatFromInt(n));

        {
            var to_del = std.ArrayList(Entity).init(arena_alloc);
            var it = t.entities.entityIterator();
            while (it.next()) |e| {
                if (rand.boolean()) continue;
                try to_del.append(e);
            }
            timer.reset();
            for (to_del.items) |e| {
                t.destroy(e);
            }
        }
        const t_excl = @as(f64, @floatFromInt(timer.lap())) / @as(f64, @floatFromInt(n / 2));

        var q123 = t.query(&.{ .int1, .int2, .int3 }, &.{});
        var n123: usize = 0;
        while (q123.next()) |e| {
            const v1 = t.getPtrConst(.int1, e).?.*;
            const v2 = t.getPtr(.int2, e).?;
            const v3 = t.getPtrConst(.int3, e).?.*;
            v2.* +%= v3 *% v1;
            n123 += 1;
        }
        const t_it123 = @as(f64, @floatFromInt(timer.lap())) / @as(f64, @floatFromInt(n123));

        var q12 = t.query(&.{ .int1, .int2 }, &.{});
        var n12: usize = 0;
        while (q12.next()) |e| {
            const v1 = t.getPtrConst(.int1, e).?.*;
            const v2 = t.getPtr(.int2, e).?;
            v2.* ^= v1;
            n12 += 1;
        }
        const t_it12 = @as(f64, @floatFromInt(timer.lap())) / @as(f64, @floatFromInt(n12));

        var q1 = t.query(&.{.int1}, &.{});
        var n1: usize = 0;
        while (q1.next()) |e| {
            const v1 = t.getPtrConst(.int1, e).?.*;
            acc += v1;
            n1 += 1;
        }
        const t_it1 = @as(f64, @floatFromInt(timer.lap())) / @as(f64, @floatFromInt(n1));

        {
            const t_old = t.copy();
            t.deinit();
            t = t_old;
        }
        const t_copyall = @as(f64, @floatFromInt(timer.lap())) * 1e-6;

        {
            const t_old = t.copy();
            t.deinit();
            t = t_old;
        }
        const t_copynone = @as(f64, @floatFromInt(timer.lap())) * 1e-6;

        {
            var it = t.query(&.{.int1}, &.{});
            while (it.next()) |e| t.getPtr(.int1, e).?.* += 1;
            const t_old = t.copy();
            t.deinit();
            t = t_old;
        }
        const t_copy1 = @as(f64, @floatFromInt(timer.lap())) * 1e-6;

        {
            var it = t.query(&.{.int2}, &.{});
            while (it.next()) |e| t.getPtr(.int2, e).?.* += 1;
            const t_old = t.copy();
            t.deinit();
            t = t_old;
        }
        const t_copy2 = @as(f64, @floatFromInt(timer.lap())) * 1e-6;

        {
            var it = t.query(&.{.int3}, &.{});
            while (it.next()) |e| t.getPtr(.int3, e).?.* += 1;
            const t_old = t.copy();
            t.deinit();
            t = t_old;
        }
        const t_copy3 = @as(f64, @floatFromInt(timer.lap())) * 1e-6;

        try stdout.print(
            "{}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\t{d:.2}\n",
            .{
                n,
                t_incl,
                t_excl,
                t_it123,
                t_it12,
                t_it1,
                t_copyall,
                t_copynone,
                t_copy1,
                t_copy2,
                t_copy3,
            },
        );
    }

    std.debug.print("{}\n", .{acc});
}
