mutex: Io.Mutex = .init,
storage: Storage = .empty,
trash: Trash = .empty,

pub const Data = @This();

pub const Key = dvui.data.Key;

pub const Storage = dvui.TrackingAutoHashMap(Key, SavedData, .get_and_put, dvui.data.Token);
pub const Trash = std.ArrayList(SavedData);

pub const DeinitFunction = *const fn (*anyopaque) void;

const SavedData = struct {
    alignment: u8,
    data: []u8,
    deinit: ?DeinitFunction = null,

    debug: DebugInfo,

    hot: if (hot_reload) Hot else void = if (hot_reload) .{} else {},

    pub const Encoder = if (hot_reload) ?*const fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![:0]u8 else void;

    pub const Hot = struct {
        /// Writes `data` as ZON. Null if the entry wasn't stored through a typed
        /// function, in which case its bytes are carried over untouched.
        encode: Encoder = null,
        /// Non-null when the entry is frozen, and `data` is either empty or, if
        /// `deinit` is set, the bytes that `deinit` has to run on.
        zon: ?[:0]u8 = null,
    };

    pub const Kind = enum(u2) {
        /// Store the data pointer to by the slice
        single_item,
        /// Store the slice as ptr and len (not copying the data)
        slice,
        /// Store the slice as ptr and len (not copying the data) with embedded sentinel value
        slice_with_sentinel,
    };

    pub const DebugInfo = if (builtin.mode == .debug) struct {
        name: []const u8,
        kind: Kind,

        fn eq(self: DebugInfo, other: DebugInfo) bool {
            const same_name = if (hot_reload)
                dvui.hot_reload.wire.shapeEql(self.name, other.name)
            else
                std.mem.eql(u8, self.name, other.name);
            return same_name and self.kind == other.kind;
        }

        pub fn format(self: DebugInfo, writer: *std.Io.Writer) !void {
            try writer.print("{[name]s} ({[kind]t})", self);
        }
    } else void;

    pub fn free(self: *const SavedData, gpa: std.mem.Allocator) void {
        if (hot_reload) if (self.hot.zon) |zon| gpa.free(zon);
        if (self.deinit) |func| {
            func(self.data.ptr);
        }
        if (self.data.len != 0) {
            gpa.rawFree(
                self.data,
                std.mem.Alignment.fromByteUnits(self.alignment),
                @returnAddress(),
            );
        }
    }
};

fn Slice(S: type) type {
    const dt = @typeInfo(S);
    return if (dt == .pointer and dt.pointer.size == .slice)
        if (dt.pointer.sentinel()) |s|
            [:s]dt.pointer.child
        else
            []dt.pointer.child
    else if (dt == .pointer and dt.pointer.size == .one and @typeInfo(dt.pointer.child) == .array)
        if (@typeInfo(dt.pointer.child).array.sentinel()) |s|
            [:s]@typeInfo(dt.pointer.child).array.child
        else
            []@typeInfo(dt.pointer.child).array.child
    else
        @compileError("Data.Slice needs a slice or pointer to array, given " ++ @typeName(S));
}

pub fn set(self: *Data, gpa: std.mem.Allocator, key: Key, data: anytype) std.mem.Allocator.Error!void {
    const value, _ = try self.getOrPutT(gpa, key, @TypeOf(data));
    value.* = data;
}

pub fn setSlice(self: *Data, gpa: std.mem.Allocator, key: Key, data: anytype) std.mem.Allocator.Error!void {
    return setSliceCopies(self, gpa, key, data, 1);
}
pub fn setSliceCopies(self: *Data, gpa: std.mem.Allocator, key: Key, data: anytype, num_copies: usize) std.mem.Allocator.Error!void {
    const S = @TypeOf(data);
    const sentinel = @typeInfo(Slice(S)).pointer.sentinel();
    const slice, _ = try self.getOrPutSliceT(gpa, key, Slice(S), data.len * num_copies, true);

    // if slice and data alias it means dataSetSlice was called with the slice
    // from dataGetSlice, so it already has the data
    if (slice.ptr != data.ptr) {
        for (0..num_copies) |i| {
            @memcpy(slice[i * data.len ..][0..data.len], data);
        }
    }
    if (sentinel) |s| slice[slice.len - 1] = s;
}

pub fn getPtr(self: *Data, gpa: std.mem.Allocator, key: Key, comptime T: type) ?*T {
    self.thaw(gpa, key, T, false);
    return @ptrCast(@alignCast(self.get(key, if (SavedData.DebugInfo == void) {} else .{ .name = @typeName(T), .kind = .single_item })));
}
pub fn getPtrDefault(self: *Data, gpa: std.mem.Allocator, key: Key, comptime T: type, default: T) std.mem.Allocator.Error!*T {
    const value, const existing = try self.getOrPutT(gpa, key, T);
    if (!existing) value.* = default;
    return value;
}

pub fn getSlice(self: *Data, gpa: std.mem.Allocator, key: Key, comptime S: type) ?Slice(S) {
    self.thaw(gpa, key, S, true);
    const bytes = self.get(key, if (SavedData.DebugInfo == void) {} else .{
        .name = @typeName(@typeInfo(S).pointer.child),
        .kind = if (@typeInfo(S).pointer.sentinel() == null) .slice else .slice_with_sentinel,
    });
    if (bytes) |b| {
        var data: Slice(S) = @ptrCast(@alignCast(b));
        return if (@typeInfo(Slice(S)).pointer.sentinel()) |s|
            data[0 .. data.len - 1 :s]
        else
            data;
    }
    return null;
}
pub fn getSliceDefault(self: *Data, gpa: std.mem.Allocator, key: Key, comptime S: type, default: []const @typeInfo(S).pointer.child) std.mem.Allocator.Error!Slice(S) {
    const sentinel = @typeInfo(Slice(S)).pointer.sentinel();
    const slice, const existing = try self.getOrPutSliceT(gpa, key, Slice(S), default.len, false);
    if (!existing) {
        @memcpy(slice, default);
        if (sentinel) |s| slice[default.len] = s;
    }
    return slice;
}

fn getOrPutT(self: *Data, gpa: std.mem.Allocator, key: Key, comptime T: type) std.mem.Allocator.Error!struct { *T, bool } {
    self.thaw(gpa, key, T, false);
    const bytes, const existing = try self.getOrPut(
        gpa,
        key,
        @sizeOf(T),
        @alignOf(T),
        true,
        if (SavedData.DebugInfo == void) {} else .{ .name = @typeName(T), .kind = .single_item },
        if (hot_reload) &encodeSingle(T) else {},
    );
    return .{ @ptrCast(@alignCast(bytes)), existing };
}
fn getOrPutSliceT(self: *Data, gpa: std.mem.Allocator, key: Key, comptime S: type, len: usize, replace_existing: bool) std.mem.Allocator.Error!struct { S, bool } {
    self.thaw(gpa, key, S, true);
    const st = @typeInfo(S);
    const T = st.pointer.child;
    const bytes, const existing = try self.getOrPut(
        gpa,
        key,
        @sizeOf(T) * (len + @intFromBool(st.pointer.sentinel() != null)),
        st.pointer.attrs.@"align" orelse @alignOf(T),
        replace_existing,
        if (SavedData.DebugInfo == void) {} else .{
            .name = @typeName(T),
            .kind = if (@typeInfo(S).pointer.sentinel() == null) .slice else .slice_with_sentinel,
        },
        if (hot_reload) &encodeSliceBytes(S) else {},
    );
    return .{ @ptrCast(@alignCast(bytes)), existing };
}

/// Returns the backing byte slice and a boolean indicating if we found an existing entry
pub fn getOrPut(self: *Data, gpa: std.mem.Allocator, key: Key, len: usize, alignment: u8, replace_existing: bool, debug: SavedData.DebugInfo, encode: SavedData.Encoder) std.mem.Allocator.Error!struct { []u8, bool } {
    const io = dvui.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (replace_existing) try self.trash.ensureUnusedCapacity(gpa, 1);
    const entry = try self.storage.getOrPut(gpa, key);
    errdefer _ = self.storage.remove(key);

    const should_trash = replace_existing and entry.found_existing and entry.value_ptr.data.len != len;
    if (should_trash) {
        // log.debug("dataSet: already had data for id {x} key {s}, freeing previous data\n", .{ id, key });
        if (@TypeOf(debug) != void) {
            if (!debug.eq(entry.value_ptr.debug)) {
                std.debug.panic("Date.getOrPut: stored type {f} doesn't match asked for type {f}", .{ entry.value_ptr.debug, debug });
            }
        }
        self.trash.appendAssumeCapacity(entry.value_ptr.*);
    }
    if (!entry.found_existing or should_trash) {
        entry.value_ptr.* = .{
            .alignment = alignment,
            .data = if (len == 0) &.{} else if (gpa.rawAlloc(len, .fromByteUnits(alignment), @returnAddress())) |ptr| ptr[0..len] else return std.mem.Allocator.Error.OutOfMemory,
            .debug = debug,
        };
    }
    if (hot_reload) entry.value_ptr.hot.encode = encode;
    return .{ entry.value_ptr.data, entry.found_existing };
}

/// returns the backing byte slice if we have one
pub fn get(self: *Data, key: Key, debug: SavedData.DebugInfo) ?[]u8 {
    const io = dvui.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.storage.getPtr(key)) |sd| {
        if (@TypeOf(debug) != void) {
            if (!debug.eq(sd.debug)) {
                std.debug.panic("Data.get: stored type {f} doesn't match asked for type {f}", .{ sd.debug, debug });
            }
        }
        return sd.data;
    } else {
        return null;
    }
}

pub fn setDeinitFunction(self: *Data, key: Key, func: DeinitFunction) void {
    const io = dvui.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.storage.getPtr(key)) |sd| {
        sd.deinit = func;
    }
}

pub fn retain(self: *Data, gpa: std.mem.Allocator, key: Key, retain_token: ?dvui.data.Token) std.mem.Allocator.Error!void {
    const io = dvui.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    try self.storage.retain(gpa, key, retain_token);
}

pub fn retainClear(self: *Data, token: dvui.data.Token) void {
    const io = dvui.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    self.storage.retainClear(token);
}

pub fn remove(self: *Data, gpa: std.mem.Allocator, key: Key) std.mem.Allocator.Error!void {
    const io = dvui.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    try self.trash.ensureUnusedCapacity(gpa, 1);

    if (self.storage.fetchRemove(key)) |dd| {
        self.trash.appendAssumeCapacity(dd.value);
    }
}

/// Destroys all unused and trashed datas since the last call to `reset`
pub fn reset(self: *Data, gpa: std.mem.Allocator) void {
    const io = dvui.io;

    var temp: std.ArrayList(SavedData) = .empty;
    defer temp.deinit(gpa);

    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var it = self.storage.iterator();
        while (it.next_resetting()) |kv| {
            if (kv.value.deinit) |_| {
                temp.append(gpa, kv.value) catch |err| {
                    dvui.logError(@src(), err, "data with key {x} failed to call deinit function", .{kv.key});
                };
            } else {
                kv.value.free(gpa);
            }
        }
        for (self.trash.items) |sd| {
            if (sd.deinit) |_| {
                temp.append(gpa, sd) catch |err| {
                    dvui.logError(@src(), err, "trash data failed to call deinit function", .{});
                };
            } else {
                sd.free(gpa);
            }
        }
        self.trash.clearRetainingCapacity();
    }

    // We need to not be holding the mutex when these run their deinit
    // functions, because those functions might call data stuff like
    // `retainClear`
    for (temp.items) |sd| {
        sd.free(gpa);
    }
}

pub fn deinit(self: *Data, gpa: std.mem.Allocator) void {
    defer self.* = undefined;
    var it = self.storage.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.free(gpa);
    }
    self.storage.deinit(gpa);
    for (self.trash.items) |sd| {
        sd.free(gpa);
    }
    self.trash.deinit(gpa);
}

/// Write every entry to its ZON wire format, right before the code that stored
/// them goes away. Entries stay frozen until the next typed access, which brings
/// them back as whatever type the new code asks for.
///
/// Must be called on the gui thread, with no pointers to stored data in use
/// after the next `Window.end`.
pub fn freeze(self: *Data, gpa: std.mem.Allocator) void {
    if (!hot_reload) return;
    const io = dvui.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    var it = self.storage.iterator();
    while (it.next()) |entry| {
        const sd = entry.value_ptr;
        if (sd.hot.zon != null) continue;
        const encode = sd.hot.encode orelse continue;
        self.trash.ensureUnusedCapacity(gpa, 1) catch |err| {
            dvui.logError(@src(), err, "data with key {x} can't be frozen for hot reload", .{entry.key_ptr.*});
            continue;
        };
        sd.hot.zon = encode(gpa, sd.data) catch |err| {
            dvui.logError(@src(), err, "data with key {x} can't be frozen for hot reload", .{entry.key_ptr.*});
            continue;
        };
        if (sd.deinit == null) {
            // like a replaced value, pointers from earlier this frame stay valid until `reset`
            var old = sd.*;
            old.hot = .{};
            self.trash.appendAssumeCapacity(old);
            sd.data = &.{};
        }
    }
}

fn encodeSingle(comptime T: type) fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![:0]u8 {
    return struct {
        fn encode(gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![:0]u8 {
            const value: *const T = if (@sizeOf(T) == 0) &undefined_value else @ptrCast(@alignCast(bytes.ptr));
            return dvui.hot_reload.wire.encode(gpa, T, value);
        }
        const undefined_value: T = undefined;
    }.encode;
}

fn encodeSliceBytes(comptime S: type) fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![:0]u8 {
    return struct {
        fn encode(gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![:0]u8 {
            const T = @typeInfo(S).pointer.child;
            const has_sentinel = @typeInfo(S).pointer.sentinel() != null;
            if (@sizeOf(T) == 0) return dvui.hot_reload.wire.encodeSlice(gpa, T, &.{});
            const items: []const T = @ptrCast(@alignCast(bytes));
            return dvui.hot_reload.wire.encodeSlice(gpa, T, items[0 .. items.len - @intFromBool(has_sentinel)]);
        }
    }.encode;
}

/// Bring back a frozen entry for the new code's type, if there is one. `T` is
/// the slice type when `is_slice`.
///
/// The entry is removed if `T` is an unrelated type, so that callers see it as
/// missing and apply their usual default.
fn thaw(self: *Data, gpa: std.mem.Allocator, key: Key, comptime T: type, comptime is_slice: bool) void {
    if (!hot_reload) return;
    const io = dvui.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    const sd = self.storage.getPtr(key) orelse return;
    const zon = sd.hot.zon orelse return;

    const Item = if (is_slice) @typeInfo(T).pointer.child else T;
    const sentinel = if (is_slice) @typeInfo(T).pointer.sentinel() else null;
    const alignment: u8 = if (is_slice) @typeInfo(T).pointer.attrs.@"align" orelse @alignOf(Item) else @alignOf(T);
    const encode: SavedData.Encoder = if (is_slice) &encodeSliceBytes(T) else &encodeSingle(T);

    const new_data = decode(gpa, zon, Item, is_slice, sentinel, alignment) catch |err| {
        dvui.logError(@src(), err, "data with key {x} failed to thaw after hot reload", .{key});
        return self.dropFrozen(gpa, key);
    } orelse return self.dropFrozen(gpa, key);

    if (sd.deinit != null) {
        // The deinit function only understands the type it was set for, so it
        // can only stay if the type is unchanged.
        const unchanged = if (encode.?(gpa, new_data)) |zon_again| blk: {
            defer gpa.free(zon_again);
            break :blk std.mem.eql(u8, zon, zon_again);
        } else |_| false;
        if (!unchanged) {
            if (new_data.len != 0) gpa.rawFree(new_data, .fromByteUnits(alignment), @returnAddress());
            return self.dropFrozen(gpa, key);
        }
        if (sd.data.len != 0) gpa.rawFree(sd.data, .fromByteUnits(sd.alignment), @returnAddress());
    }

    gpa.free(zon);
    sd.hot = .{ .encode = encode };
    sd.data = new_data;
    sd.alignment = alignment;
    if (SavedData.DebugInfo != void) {
        sd.debug = if (is_slice)
            .{ .name = @typeName(Item), .kind = if (sentinel == null) .slice else .slice_with_sentinel }
        else
            .{ .name = @typeName(T), .kind = .single_item };
    }
}

/// Returns the native bytes for frozen `zon`, or null if it isn't compatible.
fn decode(gpa: std.mem.Allocator, zon: [:0]const u8, comptime Item: type, comptime is_slice: bool, comptime sentinel: ?Item, alignment: u8) std.mem.Allocator.Error!?[]u8 {
    const wire = dvui.hot_reload.wire;
    var parsed: wire.Parsed = try .init(gpa, zon);
    defer parsed.deinit(gpa);

    const count = (if (is_slice) parsed.sliceLen(Item) else if (parsed.value(Item) != null) @as(usize, 1) else null) orelse return null;
    const total = count + @intFromBool(sentinel != null);
    const len = @sizeOf(Item) * total;
    const bytes: []u8 = if (len == 0)
        &.{}
    else if (gpa.rawAlloc(len, .fromByteUnits(alignment), @returnAddress())) |ptr|
        ptr[0..len]
    else
        return error.OutOfMemory;
    if (@sizeOf(Item) == 0) return bytes;

    const items: []Item = @ptrCast(@alignCast(bytes));
    if (is_slice) {
        parsed.sliceInto(Item, items[0..count]);
        if (sentinel) |s| items[count] = s;
    } else {
        items[0] = parsed.value(Item).?;
    }
    return bytes;
}

fn dropFrozen(self: *Data, gpa: std.mem.Allocator, key: Key) void {
    const kv = self.storage.fetchRemove(key) orelse return;
    self.trash.append(gpa, kv.value) catch |err| {
        dvui.logError(@src(), err, "data with key {x} failed to call deinit function", .{key});
    };
}

const hot_reload = dvui.hot_reload.enabled;

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const dvui = @import("./dvui.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

test "freeze and thaw across type changes" {
    if (!hot_reload) return error.SkipZigTest;
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const win = dvui.currentWindow();
    const data = &win.data_store;
    const gpa = win.gpa;

    const key: Key = .U64(1);
    const Old = struct { a: u32, removed: u8, retyped: u32 };
    const New = struct { a: u32, added: f32 = 3, retyped: i32 };
    try data.set(gpa, key, Old{ .a = 5, .removed = 1, .retyped = 2 });

    data.freeze(gpa);
    try std.testing.expect(data.storage.getPtr(key).?.hot.zon != null);
    // a second freeze with no access in between leaves the entry alone
    data.freeze(gpa);

    try std.testing.expectEqual(New{ .a = 5, .added = 0, .retyped = 0 }, data.getPtr(gpa, key, New).?.*);
    try std.testing.expect(data.storage.getPtr(key).?.hot.zon == null);

    // stays writable through the returned pointer, and those writes are what get frozen next
    data.getPtr(gpa, key, New).?.a = 6;
    data.freeze(gpa);
    try std.testing.expectEqual(6, data.getPtr(gpa, key, New).?.a);
}

test "frozen entries of an unrelated type are missing" {
    if (!hot_reload) return error.SkipZigTest;
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const win = dvui.currentWindow();
    const data = &win.data_store;
    const gpa = win.gpa;

    const key: Key = .U64(1);
    try data.set(gpa, key, @as(u32, 1));
    data.freeze(gpa);
    try std.testing.expectEqual(null, data.getPtr(gpa, key, f32));

    try data.set(gpa, key, @as(u32, 1));
    data.freeze(gpa);
    try std.testing.expectEqual(4.5, (try data.getPtrDefault(gpa, key, f32, 4.5)).*);
}

test "set replaces frozen entries" {
    if (!hot_reload) return error.SkipZigTest;
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const win = dvui.currentWindow();
    const data = &win.data_store;
    const gpa = win.gpa;

    const key: Key = .U64(1);
    try data.set(gpa, key, @as(u32, 1));
    data.freeze(gpa);
    try data.set(gpa, key, @as(f32, 2));
    try std.testing.expectEqual(2, data.getPtr(gpa, key, f32).?.*);
}

test "freeze and thaw slices" {
    if (!hot_reload) return error.SkipZigTest;
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const win = dvui.currentWindow();
    const data = &win.data_store;
    const gpa = win.gpa;

    try data.setSlice(gpa, .U64(1), @as([]const u8, "ab"));
    try data.setSlice(gpa, .U64(2), "cd");
    try data.setSlice(gpa, .U64(3), @as([]const u16, &.{ 1, 2, 3 }));
    data.freeze(gpa);
    try std.testing.expectEqualSlices(u8, "ab", data.getSlice(gpa, .U64(1), []u8).?);
    try std.testing.expectEqualSentinel(u8, 0, "cd", data.getSlice(gpa, .U64(2), [:0]u8).?);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, data.getSlice(gpa, .U64(3), []u16).?);

    // element type changes
    data.freeze(gpa);
    try std.testing.expectEqual(null, data.getSlice(gpa, .U64(3), []u8));
}

test "deinit function stays for an unchanged type and runs for a changed one" {
    if (!hot_reload) return error.SkipZigTest;
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const win = dvui.currentWindow();
    const data = &win.data_store;
    const gpa = win.gpa;

    const S = struct {
        var last_deinit: u32 = 0;
        a: u32,
        fn deinit(ptr: *anyopaque) void {
            last_deinit = @as(*@This(), @ptrCast(@alignCast(ptr))).a;
        }
    };

    const key: Key = .U64(1);
    try data.set(gpa, key, S{ .a = 7 });
    data.setDeinitFunction(key, &S.deinit);

    data.freeze(gpa);
    try std.testing.expectEqual(7, data.getPtr(gpa, key, S).?.a);
    try std.testing.expectEqual(0, S.last_deinit);
    try std.testing.expect(data.storage.getPtr(key).?.deinit != null);

    data.freeze(gpa);
    try std.testing.expectEqual(null, data.getPtr(gpa, key, struct { a: u32, b: u32 }));
    data.reset(gpa);
    try std.testing.expectEqual(7, S.last_deinit);
}
