pub const Entity = @import("table.zig").Entity;
pub const nil = @import("table.zig").nil;
pub const Pool = @import("table.zig").Pool;
pub const Table = @import("table.zig").Table;

// so that we can run the tests on this file and all is used
// (does this have any other side-effects?)
comptime {
    _ = @import("table.zig");
    _ = @import("storage.zig");
    _ = @import("implementation.zig");
}
