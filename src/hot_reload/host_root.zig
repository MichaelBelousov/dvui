//! Root of the executable built by `addReloadableAppStep`. It is a normal dvui
//! App that owns the window and real backend, and forwards its callbacks to
//! whichever build of the app's shared library was loaded last.
//!
//! Replaced libraries stay mapped: dvui keeps pointers to app code and constants
//! across frames (dialog callbacks, deinit functions, themes, font bytes, source
//! locations), and all of those have to remain valid after a swap.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const proxy_bridge = @import("proxy_bridge");
const options = @import("hot_reload_options");

const Io = std.Io;
const hot = dvui.hot_reload;
const log = std.log.scoped(.hot_reload);

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = start },
    .initFn = init,
    .deinitFn = deinit,
    .frameFn = frame,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

const poll_interval: Io.Duration = .fromMilliseconds(200);

const Os = if (builtin.os.tag == .windows) struct {
    const HMODULE = *anyopaque;
    const PIN = 0x1;
    const FROM_ADDRESS = 0x4;
    extern "kernel32" fn LoadLibraryW(path: [*:0]const u16) callconv(.winapi) ?HMODULE;
    extern "kernel32" fn GetModuleHandleExW(flags: u32, name: ?*const anyopaque, out: *?HMODULE) callconv(.winapi) i32;
    extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: HMODULE) callconv(.winapi) i32;

    fn open(path: []const u8) ?*anyopaque {
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch return null;
        defer gpa.free(wide);
        const module = LoadLibraryW(wide) orelse return null;
        var pinned: ?HMODULE = null;
        _ = GetModuleHandleExW(PIN | FROM_ADDRESS, module, &pinned);
        return module;
    }
    fn lookup(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque {
        return GetProcAddress(handle, name);
    }
    fn close(handle: *anyopaque) void {
        _ = FreeLibrary(handle);
    }
    fn lastError() []const u8 {
        return "LoadLibraryW failed";
    }
} else struct {
    fn open(path: []const u8) ?*anyopaque {
        const path_z = gpa.dupeSentinel(u8, path, 0) catch return null;
        defer gpa.free(path_z);
        return std.c.dlopen(path_z, .{ .NOW = true, .NODELETE = true });
    }
    fn lookup(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque {
        return std.c.dlsym(handle, name);
    }
    fn close(handle: *anyopaque) void {
        _ = std.c.dlclose(handle);
    }
    fn lastError() []const u8 {
        return std.mem.span(std.c.dlerror() orelse return "unknown error");
    }
};

const Library = struct {
    handle: *anyopaque,
    /// The private copy that is loaded, so that the original can be overwritten
    /// and so that the loader treats each build as a new library.
    path: []const u8,
    frame: hot.FrameFn,
    init: hot.InitFn,
    deinit: hot.DeinitFn,
    config: hot.ConfigFn,

    fn lookup(handle: *anyopaque, comptime T: type, name: [*:0]const u8) error{MissingSymbol}!T {
        const sym = Os.lookup(handle, name) orelse {
            log.err("library has no symbol {s}", .{name});
            return error.MissingSymbol;
        };
        return @ptrCast(@alignCast(sym));
    }
};

var gpa: std.mem.Allocator = undefined;
var io: Io = undefined;
var lib_path: []const u8 = undefined;
var copy_dir: []const u8 = undefined;
var generation: u32 = 0;
var library: Library = undefined;
var start_options: ?dvui.App.StartOptions = null;

var window: *dvui.Window = undefined;
var backend: dvui.Backend = undefined;
var context: hot.Context = undefined;

var watcher: ?std.Thread = null;
var watcher_stop: std.atomic.Value(bool) = .init(false);
var reload_pending: std.atomic.Value(bool) = .init(false);
var loaded_mtime: Io.Timestamp = .zero;

fn libraryPath(main_init: std.process.Init) ![]const u8 {
    const dir = try std.process.executableDirPathAlloc(main_init.io, main_init.gpa);
    defer main_init.gpa.free(dir);
    return std.fs.path.join(main_init.gpa, &.{ dir, options.lib_file });
}

fn loadLibrary() !Library {
    const cwd = Io.Dir.cwd();
    loaded_mtime = (try cwd.statFile(io, lib_path, .{})).mtime;

    generation += 1;
    const copy_name = try std.fmt.allocPrint(gpa, "{d}-{s}", .{ generation, std.fs.path.basename(lib_path) });
    defer gpa.free(copy_name);
    const copy_path = try std.fs.path.join(gpa, &.{ copy_dir, copy_name });
    errdefer gpa.free(copy_path);
    try cwd.copyFile(lib_path, cwd, copy_path, io, .{});
    errdefer cwd.deleteFile(io, copy_path) catch {};

    const handle = Os.open(copy_path) orelse {
        log.err("failed to load {s}: {s}", .{ copy_path, Os.lastError() });
        return error.LoadFailed;
    };
    errdefer Os.close(handle);

    const abiHash = try Library.lookup(handle, hot.AbiHashFn, "dvui_abi_hash");
    if (abiHash() != hot.abiHash()) {
        log.err("{s} was built against a different dvui than this host, rebuild and restart the host", .{lib_path});
        return error.AbiMismatch;
    }

    return .{
        .handle = handle,
        .path = copy_path,
        .frame = try Library.lookup(handle, hot.FrameFn, "dvui_frame"),
        .init = try Library.lookup(handle, hot.InitFn, "dvui_init"),
        .deinit = try Library.lookup(handle, hot.DeinitFn, "dvui_deinit"),
        .config = try Library.lookup(handle, hot.ConfigFn, "dvui_app_config"),
    };
}

fn unloadLibrary(lib: Library) void {
    Os.close(lib.handle);
    // Best effort: windows won't delete a pinned library, these are cleaned up on next start.
    Io.Dir.cwd().deleteFile(io, lib.path) catch {};
    gpa.free(lib.path);
}

fn start() dvui.App.StartOptions {
    if (start_options) |opts| return opts;
    const main_init = dvui.App.main_init orelse @panic("hot reload requires a backend that sets dvui.App.main_init");
    return startInner(main_init) catch |err| std.debug.panic("hot reload: failed to load the app library: {t}", .{err});
}

fn startInner(main_init: std.process.Init) !dvui.App.StartOptions {
    gpa = main_init.gpa;
    io = main_init.io;
    lib_path = try libraryPath(main_init);

    copy_dir = try std.fs.path.join(gpa, &.{ std.fs.path.dirname(lib_path) orelse ".", ".hot-reload" });
    Io.Dir.cwd().deleteTree(io, copy_dir) catch {};
    try Io.Dir.cwd().createDirPath(io, copy_dir);

    library = try loadLibrary();
    var opts: dvui.App.StartOptions = undefined;
    library.config(&main_init, &opts);
    start_options = opts;
    return opts;
}

fn init(win: *dvui.Window) !void {
    try attach(win);
    if (library.init(&context) != 0) return error.AppInitFailed;
}

/// Not every backend calls `dvui.App.initFn`, so this also runs on the first frame.
fn attach(win: *dvui.Window) !void {
    if (watcher != null) return;
    window = win;
    backend = win.backend;
    context = .{
        .window = win,
        .io = &dvui.io,
        .debug = &dvui.debug,
        .ft2lib = @ptrCast(&dvui.ft2lib),
        .bridge = &bridge,
        .main_init = if (dvui.App.main_init) |*main_init| main_init else null,
    };
    io = dvui.io;
    watcher = try std.Thread.spawn(.{}, watch, .{});
    log.info("watching {s} for changes", .{lib_path});
}

fn deinit(_: *dvui.Window) void {
    watcher_stop.store(true, .release);
    if (watcher) |thread| thread.join();
    library.deinit(&context);
    Io.Dir.cwd().deleteTree(io, copy_dir) catch {};
    gpa.free(library.path);
    gpa.free(copy_dir);
    gpa.free(lib_path);
}

fn watch() void {
    while (!watcher_stop.load(.acquire)) {
        io.sleep(poll_interval, .awake) catch return;
        const stat = Io.Dir.cwd().statFile(io, lib_path, .{}) catch continue;
        if (stat.mtime.nanoseconds == loaded_mtime.nanoseconds) continue;
        if (reload_pending.swap(true, .acq_rel)) continue;
        dvui.refresh(window, @src(), null);
    }
}

fn reload() void {
    const new = loadLibrary() catch |err| {
        log.err("keeping the running code, failed to reload: {t}", .{err});
        return;
    };
    // The old library still has to be loaded here, the entries freeze through its code.
    window.data_store.freeze(window.gpa);
    unloadLibrary(library);
    library = new;
    log.info("reloaded {s}", .{lib_path});
}

fn frame() !dvui.App.Result {
    try attach(dvui.currentWindow());
    if (reload_pending.swap(false, .acq_rel)) reload();
    return switch (library.frame(&context)) {
        .ok => .ok,
        .close => .close,
        // keep the window up so a fixed build can be loaded over this one
        .err => .ok,
    };
}

const bridge: proxy_bridge.RenderBridge = .{
    .ctx = null,
    .draw_clipped_triangles = Bridge.drawClippedTriangles,
    .texture_create = Bridge.textureCreate,
    .texture_update = Bridge.textureUpdate,
    .texture_update_sub_rect = Bridge.textureUpdateSubRect,
    .texture_destroy = Bridge.textureDestroy,
    .texture_create_target = Bridge.textureCreateTarget,
    .texture_blend = Bridge.textureBlend,
    .texture_read_target = Bridge.textureReadTarget,
    .texture_destroy_target = Bridge.textureDestroyTarget,
    .texture_clear_target = Bridge.textureClearTarget,
    .texture_from_target = Bridge.textureFromTarget,
    .texture_from_target_temp = Bridge.textureFromTargetTemp,
    .render_target = Bridge.renderTarget,
    .pixel_size = Bridge.pixelSize,
    .window_size = Bridge.windowSize,
    .content_scale = Bridge.contentScale,
    .clipboard_text = Bridge.clipboardText,
    .clipboard_text_set = Bridge.clipboardTextSet,
    .open_url = Bridge.openUrl,
    .set_cursor = Bridge.setCursor,
    .text_input_rect = Bridge.textInputRect,
    .preferred_color_scheme = Bridge.preferredColorScheme,
    .prefers_reduced_motion = Bridge.prefersReducedMotion,
    .refresh = Bridge.refresh,
    .nano_time = Bridge.nanoTime,
    .real_time = Bridge.realTime,
    .title = Bridge.title,
    .window_state_set = Bridge.windowStateSet,
};

const Bridge = struct {
    const Ctx = ?*anyopaque;
    const Desc = proxy_bridge.TextureDesc;
    const null_desc: Desc = .{ .ptr = null, .width = 0, .height = 0, .format = 0, .interpolation = 0, .wrap_u = 0, .wrap_v = 0 };

    fn texture(desc: *const Desc) ?dvui.Texture {
        return proxy_bridge.textureFromDesc(desc.*) catch null;
    }
    fn target(desc: *const Desc) ?dvui.TextureTarget {
        return proxy_bridge.targetFromDesc(desc.*) catch null;
    }
    fn createOptions(o: proxy_bridge.CreateOptions) dvui.Texture.CreateOptions {
        return .{
            .width = o.width,
            .height = o.height,
            .format = @fromBackingInt(@intCast(o.format)),
            .interpolation = @fromBackingInt(@intCast(o.interpolation)),
            .wrap_u = @fromBackingInt(@intCast(o.wrap_u)),
            .wrap_v = @fromBackingInt(@intCast(o.wrap_v)),
        };
    }

    fn drawClippedTriangles(_: Ctx, tex: ?*const Desc, vtx: [*]const dvui.Vertex, vtx_len: usize, idx: [*]const dvui.Vertex.Index, idx_len: usize, has_clip: u8, clip: proxy_bridge.ClipRect) callconv(.c) u8 {
        const clipr: ?dvui.Rect.Physical = if (has_clip != 0) .{ .x = clip.x, .y = clip.y, .w = clip.w, .h = clip.h } else null;
        backend.drawClippedTriangles(if (tex) |t| texture(t) else null, vtx[0..vtx_len], idx[0..idx_len], clipr) catch return 0;
        return 1;
    }
    fn textureCreate(_: Ctx, pixels: [*]const u8, o: proxy_bridge.CreateOptions) callconv(.c) Desc {
        const tex = backend.textureCreate(pixels, createOptions(o)) catch return null_desc;
        return proxy_bridge.textureDescFrom(tex);
    }
    fn textureUpdate(_: Ctx, desc: *const Desc, pixels: [*]const u8) callconv(.c) u8 {
        backend.textureUpdate(texture(desc) orelse return 0, pixels) catch return 0;
        return 1;
    }
    fn textureUpdateSubRect(_: Ctx, desc: *const Desc, pixels: [*]const u8, x: u32, y: u32, w: u32, h: u32) callconv(.c) u8 {
        backend.textureUpdateSubRect(texture(desc) orelse return 0, pixels, x, y, w, h) catch return 0;
        return 1;
    }
    fn textureDestroy(_: Ctx, desc: *const Desc) callconv(.c) void {
        backend.textureDestroy(texture(desc) orelse return);
    }
    fn textureCreateTarget(_: Ctx, o: proxy_bridge.CreateOptions) callconv(.c) Desc {
        const tex = backend.textureCreateTarget(createOptions(o)) catch return null_desc;
        return proxy_bridge.textureDescFromTarget(tex);
    }
    fn textureBlend(_: Ctx, desc: *const Desc, blend: u8) callconv(.c) u8 {
        backend.textureBlend(texture(desc) orelse return 0, @fromBackingInt(@intCast(blend))) catch return 0;
        return 1;
    }
    fn textureReadTarget(_: Ctx, desc: *const Desc, pixels_out: [*]u8) callconv(.c) u8 {
        backend.textureReadTarget(target(desc) orelse return 0, pixels_out) catch return 0;
        return 1;
    }
    fn textureDestroyTarget(_: Ctx, desc: *const Desc) callconv(.c) void {
        backend.textureDestroyTarget(target(desc) orelse return);
    }
    fn textureClearTarget(_: Ctx, desc: *const Desc) callconv(.c) void {
        backend.textureClearTarget(target(desc) orelse return);
    }
    fn textureFromTarget(_: Ctx, desc: *const Desc) callconv(.c) Desc {
        const tex = backend.textureFromTarget(target(desc) orelse return null_desc) catch return null_desc;
        return proxy_bridge.textureDescFrom(tex);
    }
    fn textureFromTargetTemp(_: Ctx, desc: *const Desc) callconv(.c) Desc {
        const tex = backend.textureFromTargetTemp(target(desc) orelse return null_desc) catch return null_desc;
        return proxy_bridge.textureDescFrom(tex);
    }
    fn renderTarget(_: Ctx, desc: ?*const Desc) callconv(.c) u8 {
        const t: ?dvui.TextureTarget = if (desc) |d| target(d) orelse return 0 else null;
        backend.renderTarget(t) catch return 0;
        return 1;
    }
    fn pixelSize(_: Ctx) callconv(.c) proxy_bridge.SizePair {
        const size = backend.pixelSize();
        return .{ .w = size.w, .h = size.h };
    }
    fn windowSize(_: Ctx) callconv(.c) proxy_bridge.SizePair {
        const size = backend.windowSize();
        return .{ .w = size.w, .h = size.h };
    }
    fn contentScale(_: Ctx) callconv(.c) f32 {
        return backend.contentScale();
    }
    fn clipboardText(_: Ctx) callconv(.c) proxy_bridge.TextSlice {
        const text = backend.clipboardText() catch "";
        return .{ .ptr = text.ptr, .len = text.len };
    }
    fn clipboardTextSet(_: Ctx, text: [*]const u8, len: usize) callconv(.c) u8 {
        backend.clipboardTextSet(text[0..len]) catch return 0;
        return 1;
    }
    fn openUrl(_: Ctx, url: [*]const u8, len: usize, new_window: u8) callconv(.c) u8 {
        backend.openURL(url[0..len], new_window != 0) catch return 0;
        return 1;
    }
    fn setCursor(_: Ctx, cursor: u8) callconv(.c) void {
        backend.setCursor(@fromBackingInt(@intCast(cursor)));
    }
    fn textInputRect(_: Ctx, has_rect: u8, rect: proxy_bridge.ClipRect) callconv(.c) void {
        backend.textInputRect(if (has_rect != 0) .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h } else null);
    }
    fn preferredColorScheme(_: Ctx) callconv(.c) i8 {
        return switch (backend.preferredColorScheme() orelse return -1) {
            .light => 0,
            .dark => 1,
        };
    }
    fn prefersReducedMotion(_: Ctx) callconv(.c) u8 {
        return @intFromBool(backend.prefersReducedMotion());
    }
    fn refresh(_: Ctx) callconv(.c) void {
        backend.refresh();
    }
    fn nanoTime(_: Ctx) callconv(.c) i64 {
        return @intCast(backend.nanoTime());
    }
    fn realTime(_: Ctx) callconv(.c) i64 {
        return @intCast(backend.realTime());
    }
    fn title(_: Ctx, new_title: [*]const u8, len: usize) callconv(.c) void {
        window.title(new_title[0..len]);
    }
    fn windowStateSet(_: Ctx, state: u8) callconv(.c) void {
        window.stateSet(@fromBackingInt(@intCast(state)));
    }
};
