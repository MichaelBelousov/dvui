//! Support for swapping an app's code while its `dvui.Window` keeps running.
//!
//! The host executable owns the `Window` and the real backend. The app is a
//! shared library with its own copy of dvui, built against the proxy backend
//! so that its backend calls land in the host. See `addReloadableAppStep` in
//! build.zig for how the two are built.
//!
//! `dvui.dataSet`/`dataGet` state survives a swap through `wire`.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui.zig");

pub const wire = @import("hot_reload/wire.zig");

/// True when dvui is built to support hot reloading (`-Dhot-reload`, defaulting
/// to true in debug builds) on a target that can load shared libraries.
pub const enabled = @import("build_options").hot_reload and
    !builtin.cpu.arch.isWasm() and
    !builtin.abi.isAndroid() and
    builtin.os.tag != .ios and
    builtin.os.tag != .freestanding;

/// Exported by the library: `dvui_frame`
pub const FrameFn = *const fn (*const Context) callconv(.c) FrameResult;
/// Exported by the library: `dvui_init`
pub const InitFn = *const fn (*const Context) callconv(.c) c_int;
/// Exported by the library: `dvui_deinit`
pub const DeinitFn = *const fn (*const Context) callconv(.c) void;
/// Exported by the library: `dvui_app_config`, `out` is a `*dvui.App.StartOptions`
pub const ConfigFn = *const fn (main_init: ?*const anyopaque, out: *anyopaque) callconv(.c) void;
/// Exported by the library: `dvui_abi_hash`
pub const AbiHashFn = *const fn () callconv(.c) u64;

pub const FrameResult = enum(c_int) {
    ok = 0,
    close = 1,
    /// The frame function returned an error, which the library already logged.
    err = 2,
};

/// Everything the library needs to act on the host's `Window`.
pub const Context = extern struct {
    /// `*dvui.Window`
    window: *anyopaque,
    /// `*const std.Io`
    io: *const anyopaque,
    /// `*dvui.Debug`, copied in and out around each frame.
    debug: *anyopaque,
    /// `*dvui.ft2lib`
    ft2lib: *const anyopaque,
    /// `*const proxy_bridge.RenderBridge`
    bridge: *const anyopaque,
    /// `*const std.process.Init`
    main_init: ?*const anyopaque,
};

/// Host and library pass dvui types to each other by pointer, so they have to
/// agree on layout. This hash covers the types shared across the boundary, and
/// a mismatch means the host needs a rebuild (for example after editing dvui
/// itself or changing build options).
pub fn abiHash() u64 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var h = std.hash.Fnv1a_64.init();
        for ([_]type{ dvui.Window, dvui.Debug, dvui.Data, dvui.App.StartOptions, dvui.Backend, dvui.Texture }) |T| {
            h.update(std.mem.asBytes(&@as(usize, @sizeOf(T))));
            for (@typeInfo(T).@"struct".field_names) |name| {
                h.update(name);
                h.update(std.mem.asBytes(&@as(usize, @offsetOf(T, name))));
            }
        }
        break :blk h.final();
    };
}

/// Called by the library at the top of each entry point, so that its copy of
/// dvui's globals matches the host's.
pub fn adoptContext(ctx: *const Context) void {
    dvui.current_window = @ptrCast(@alignCast(ctx.window));
    dvui.io = @as(*const std.Io, @ptrCast(@alignCast(ctx.io))).*;
    dvui.debug = @as(*dvui.Debug, @ptrCast(@alignCast(ctx.debug))).*;
    if (dvui.useFreeType) dvui.ft2lib = @as(*const @TypeOf(dvui.ft2lib), @ptrCast(@alignCast(ctx.ft2lib))).*;
    if (ctx.main_init) |init| dvui.App.main_init = @as(*const std.process.Init, @ptrCast(@alignCast(init))).*;
}

/// Called by the library before returning to the host.
pub fn publishContext(ctx: *const Context) void {
    @as(*dvui.Debug, @ptrCast(@alignCast(ctx.debug))).* = dvui.debug;
}

test {
    std.testing.refAllDecls(@This());
}
