//! Root of the shared library built by `addReloadableAppStep`. Wraps the app's
//! root module (imported here as "app") in the C ABI that `host_root.zig` loads.

const std = @import("std");
const dvui = @import("dvui");
const app = @import("app");
const proxy_bridge = @import("proxy_bridge");

const hot = dvui.hot_reload;

pub const dvui_app: dvui.App = app.dvui_app;
pub const std_options: std.Options = if (@hasDecl(app, "std_options")) app.std_options else .{};
pub const panic = if (@hasDecl(app, "panic")) app.panic else std.debug.FullPanic(std.debug.defaultPanic);

fn enter(ctx: *const hot.Context) void {
    hot.adoptContext(ctx);
    proxy_bridge.setBridge(@ptrCast(@alignCast(ctx.bridge)));
}

export fn dvui_abi_hash() u64 {
    return hot.abiHash();
}

export fn dvui_app_config(main_init: ?*const anyopaque, out: *anyopaque) void {
    if (main_init) |init| dvui.App.main_init = @as(*const std.process.Init, @ptrCast(@alignCast(init))).*;
    @as(*dvui.App.StartOptions, @ptrCast(@alignCast(out))).* = dvui_app.config.get();
}

export fn dvui_init(ctx: *const hot.Context) c_int {
    enter(ctx);
    defer hot.publishContext(ctx);
    if (dvui_app.initFn) |initFn| {
        initFn(dvui.currentWindow()) catch |err| {
            dvui.logError(@src(), err, "dvui.App.initFn failed", .{});
            return 1;
        };
    }
    return 0;
}

export fn dvui_deinit(ctx: *const hot.Context) void {
    enter(ctx);
    defer hot.publishContext(ctx);
    if (dvui_app.deinitFn) |deinitFn| deinitFn(dvui.currentWindow());
}

export fn dvui_frame(ctx: *const hot.Context) hot.FrameResult {
    enter(ctx);
    defer hot.publishContext(ctx);
    const result = dvui_app.frameFn() catch |err| {
        dvui.logError(@src(), err, "dvui.App.frameFn failed", .{});
        return .err;
    };
    return switch (result) {
        .ok => .ok,
        .close => .close,
    };
}
