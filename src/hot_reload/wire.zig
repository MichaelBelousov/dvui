//! Reads and writes values in std.zon's text format so that they can be carried
//! from one build of a type to another.
//!
//! Struct fields are written by name as `.{ "shape", value }`. Reading walks the
//! new type and pulls out what still matches:
//! - removed fields are ignored
//! - new fields, and fields whose shape changed, get `zero`
//!
//! `shape` is the exact type name for scalars and pointers, so u32 -> i32 is a
//! change. Aggregates only record their kind and are compared field by field.
//!
//! Pointers are written as addresses and are never followed. The pointee stays
//! where it is, so its layout must not change across a reload.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Serializer = std.zon.Serializer;
const Zoir = std.zig.Zoir;
const ZonGen = std.zig.ZonGen;

/// Name of `T` for comparison across builds. See `shapeEql`.
pub fn shape(comptime T: type) []const u8 {
    return comptime switch (@typeInfo(T)) {
        .@"struct" => "struct",
        .@"enum" => "enum",
        .@"union" => |u| if (u.tag_type != null) "union" else rawShape(T),
        .optional => |o| "?" ++ shape(o.child),
        .array => |a| std.fmt.comptimePrint("[{d}{s}]", .{ a.len, if (a.sentinel() != null) ":s" else "" }) ++ shape(a.child),
        .vector => |v| std.fmt.comptimePrint("@Vector({d})", .{v.len}) ++ shape(v.child),
        .error_union => |e| "!" ++ shape(e.payload),
        .error_set => "error",
        .void, .bool, .int, .float, .pointer => @typeName(T),
        else => rawShape(T),
    };
}

fn rawShape(comptime T: type) []const u8 {
    return std.fmt.comptimePrint("raw:{s}:{d}", .{ @typeName(T), @sizeOf(T) });
}

/// Compare shapes ignoring the compiler assigned numbers in the names of
/// anonymous types (`foo__struct_1234`), which differ between builds.
pub fn shapeEql(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (true) {
        ai = skipAnonNumber(a, ai);
        bi = skipAnonNumber(b, bi);
        if (ai == a.len or bi == b.len) return ai == a.len and bi == b.len;
        if (a[ai] != b[bi]) return false;
        ai += 1;
        bi += 1;
    }
}

fn skipAnonNumber(s: []const u8, start: usize) usize {
    for ([_][]const u8{ "__struct_", "__enum_", "__union_", "__opaque_" }) |prefix| {
        if (start < prefix.len) continue;
        if (!std.mem.eql(u8, s[start - prefix.len .. start], prefix)) continue;
        var i = start;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        return i;
    }
    return start;
}

/// Serialize `value`, returning ZON allocated with `gpa`.
pub fn encode(gpa: Allocator, comptime T: type, value: *const T) Allocator.Error![:0]u8 {
    return encodeInner(gpa, T, value, null);
}

/// Serialize the elements of a slice, returning ZON allocated with `gpa`.
pub fn encodeSlice(gpa: Allocator, comptime T: type, items: []const T) Allocator.Error![:0]u8 {
    return encodeInner(gpa, T, null, items);
}

fn encodeInner(gpa: Allocator, comptime T: type, value: ?*const T, items: ?[]const T) Allocator.Error![:0]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var s: Serializer = .{ .writer = &aw.writer, .options = .{ .whitespace = false } };
    (if (value) |v| writeTagged(&s, T, v) else writeSliceRoot(&s, T, items.?)) catch return error.OutOfMemory;
    return aw.toOwnedSliceSentinel(0);
}

fn writeSliceRoot(s: *Serializer, comptime T: type, items: []const T) Serializer.Error!void {
    var t = try s.beginTuple(.{ .whitespace_style = .{ .wrap = false } });
    try t.fieldPrefix();
    try s.string(comptime "[]" ++ shape(T), .{});
    try t.fieldPrefix();
    try writeItems(s, T, items);
    try t.end();
}

fn writeItems(s: *Serializer, comptime T: type, items: []const T) Serializer.Error!void {
    if (T == u8) return s.string(items, .{});
    var t = try s.beginTuple(.{ .whitespace_style = .{ .wrap = false } });
    for (items) |*item| {
        try t.fieldPrefix();
        try writeValue(s, T, item);
    }
    try t.end();
}

fn writeTagged(s: *Serializer, comptime T: type, value: *const T) Serializer.Error!void {
    var t = try s.beginTuple(.{ .whitespace_style = .{ .wrap = false } });
    try t.fieldPrefix();
    try s.string(comptime shape(T), .{});
    try t.fieldPrefix();
    try writeValue(s, T, value);
    try t.end();
}

fn writeValue(s: *Serializer, comptime T: type, value: *const T) Serializer.Error!void {
    switch (@typeInfo(T)) {
        .void => try s.writer.writeAll(".{}"),
        .bool => try s.writer.writeAll(if (value.*) "true" else "false"),
        .int => try s.int(value.*),
        .float => try s.float(value.*),
        .pointer => |p| {
            if (p.size == .slice) {
                var t = try s.beginTuple(.{ .whitespace_style = .{ .wrap = false } });
                try t.fieldPrefix();
                try s.int(@intFromPtr(value.ptr));
                try t.fieldPrefix();
                try s.int(value.len);
                try t.end();
            } else {
                try s.int(@intFromPtr(value.*));
            }
        },
        .array => |a| try writeItems(s, a.child, value),
        .vector => |v| {
            const items: [v.len]v.child = value.*;
            try writeItems(s, v.child, &items);
        },
        .@"struct" => |st| {
            var out = try s.beginStruct(.{ .whitespace_style = .{ .wrap = false } });
            inline for (st.field_names, st.field_types, st.field_attrs) |name, F, attrs| {
                if (attrs.@"comptime") continue;
                try out.fieldPrefix(name);
                const field: F = @field(value.*, name);
                try writeTagged(s, F, &field);
            }
            try out.end();
        },
        // Stored data can be undefined, so don't trust that the tag is valid.
        .@"enum" => |e| {
            const int: e.tag_type = @backingInt(value.*);
            inline for (e.field_names, e.field_values) |name, tag_value| {
                if (int == tag_value) return s.ident(name);
            }
            try s.int(int);
        },
        .@"union" => |u| if (u.tag_type) |Tag| {
            const tag: Tag = value.*;
            const tag_int = @backingInt(tag);
            var out = try s.beginStruct(.{ .whitespace_style = .{ .wrap = false } });
            inline for (u.field_names, u.field_types) |name, F| {
                if (tag_int == @backingInt(@field(Tag, name))) {
                    try out.fieldPrefix(name);
                    const field: F = @field(value.*, name);
                    try writeTagged(s, F, &field);
                }
            }
            try out.end();
        } else {
            try s.string(std.mem.asBytes(value), .{});
        },
        .optional => |o| if (value.*) |payload| {
            try writeValue(s, o.child, &payload);
        } else {
            try s.writer.writeAll("null");
        },
        .error_union => |e| {
            var out = try s.beginStruct(.{ .whitespace_style = .{ .wrap = false } });
            if (value.*) |payload| {
                try out.fieldPrefix("ok");
                try writeValue(s, e.payload, &payload);
            } else |err| {
                try out.fieldPrefix("err");
                try s.ident(@errorName(err));
            }
            try out.end();
        },
        .error_set => try s.ident(@errorName(value.*)),
        else => try s.string(std.mem.asBytes(value), .{}),
    }
}

/// Parsed wire data, valid until `deinit`.
pub const Parsed = struct {
    ast: std.zig.Ast,
    zoir: Zoir,

    pub fn init(gpa: Allocator, source: [:0]const u8) Allocator.Error!Parsed {
        var ast = try std.zig.Ast.parse(gpa, source, .{ .mode = .zon });
        errdefer ast.deinit(gpa);
        return .{ .ast = ast, .zoir = try ZonGen.generate(gpa, ast, .{}) };
    }

    pub fn deinit(self: *Parsed, gpa: Allocator) void {
        self.zoir.deinit(gpa);
        self.ast.deinit(gpa);
    }

    /// The root `.{ "shape", value }` pair if it is well formed and its shape is `expected`.
    fn rootValue(self: *const Parsed, expected: []const u8) ?Zoir.Node.Index {
        if (self.zoir.hasCompileErrors()) return null;
        return taggedValue(&self.zoir, .root, expected);
    }

    /// Value matching `T`, or null if `T` is not a compatible type at all.
    pub fn value(self: *const Parsed, comptime T: type) ?T {
        const node = self.rootValue(comptime shape(T)) orelse return null;
        return readValue(&self.zoir, T, node, @typeName(T));
    }

    /// Number of elements if the data is a slice of `T`.
    pub fn sliceLen(self: *const Parsed, comptime T: type) ?usize {
        const node = self.rootValue(comptime "[]" ++ shape(T)) orelse return null;
        return switch (node.get(&self.zoir)) {
            .string_literal => |str| if (T == u8) str.len else null,
            .array_literal => |range| range.len,
            .empty_literal => 0,
            else => null,
        };
    }

    /// Fill `out` (which must have `sliceLen` items) with the elements.
    pub fn sliceInto(self: *const Parsed, comptime T: type, out: []T) void {
        const node = self.rootValue(comptime "[]" ++ shape(T)).?;
        readItems(&self.zoir, T, node, out, @typeName(T));
    }
};

fn taggedValue(zoir: *const Zoir, node: Zoir.Node.Index, expected: []const u8) ?Zoir.Node.Index {
    const range = switch (node.get(zoir)) {
        .array_literal => |range| range,
        else => return null,
    };
    if (range.len != 2) return null;
    const stored = switch (range.at(0).get(zoir)) {
        .string_literal => |str| str,
        else => return null,
    };
    if (!shapeEql(stored, expected)) return null;
    return range.at(1);
}

fn readTagged(zoir: *const Zoir, comptime T: type, node: Zoir.Node.Index, where: []const u8) T {
    const inner = taggedValue(zoir, node, comptime shape(T)) orelse return zero(T, where);
    return readValue(zoir, T, inner, where);
}

fn readItems(zoir: *const Zoir, comptime T: type, node: Zoir.Node.Index, out: []T, where: []const u8) void {
    switch (node.get(zoir)) {
        .string_literal => |str| if (T == u8 and str.len == out.len) {
            @memcpy(out, str);
            return;
        },
        .array_literal => |range| if (range.len == out.len) {
            for (out, 0..) |*item, i| item.* = readValue(zoir, T, range.at(@intCast(i)), where);
            return;
        },
        .empty_literal => if (out.len == 0) return,
        else => {},
    }
    for (out) |*item| item.* = zero(T, where);
}

fn readInt(zoir: *const Zoir, comptime T: type, node: Zoir.Node.Index) ?T {
    return switch (node.get(zoir)) {
        .int_literal => |int| switch (int) {
            .small => |small| std.math.cast(T, small),
            .big => |big| big.toInt(T) catch null,
        },
        else => null,
    };
}

/// Pointer from address without the safety checks of `@ptrFromInt`, stored
/// pointers can legitimately be undefined.
fn ptrFromBits(comptime P: type, bits: usize) P {
    var out: P = undefined;
    @memcpy(std.mem.asBytes(&out)[0..@sizeOf(usize)], std.mem.asBytes(&bits));
    return out;
}

fn readValue(zoir: *const Zoir, comptime T: type, node: Zoir.Node.Index, where: []const u8) T {
    const n = node.get(zoir);
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => switch (n) {
            .true => return true,
            .false => return false,
            else => {},
        },
        .int => if (readInt(zoir, T, node)) |int| return int,
        .float => switch (n) {
            .int_literal => |int| switch (int) {
                .small => |small| return @floatFromInt(small),
                .big => |big| return big.toFloat(T, .nearest_even)[0],
            },
            .float_literal => |float| return @floatCast(float),
            .pos_inf => return std.math.inf(T),
            .neg_inf => return -std.math.inf(T),
            .nan => return std.math.nan(T),
            else => {},
        },
        .pointer => |p| if (p.size == .slice) {
            const range = switch (n) {
                .array_literal => |range| range,
                else => return zero(T, where),
            };
            if (range.len == 2) {
                if (readInt(zoir, usize, range.at(0))) |addr| {
                    if (readInt(zoir, usize, range.at(1))) |len| {
                        var out: T = undefined;
                        out.ptr = ptrFromBits(@TypeOf(out.ptr), addr);
                        out.len = len;
                        return out;
                    }
                }
            }
        } else if (readInt(zoir, usize, node)) |addr| {
            return ptrFromBits(T, addr);
        },
        .array => |a| {
            var out: T = undefined;
            readItems(zoir, a.child, node, out[0..a.len], where);
            if (a.sentinel()) |sentinel| @as([*]a.child, &out)[a.len] = sentinel;
            return out;
        },
        .vector => |v| {
            var items: [v.len]v.child = undefined;
            readItems(zoir, v.child, node, &items, where);
            return items;
        },
        .@"struct" => |st| {
            const fields: ?@FieldType(Zoir.Node, "struct_literal") = switch (n) {
                .struct_literal => |lit| lit,
                .empty_literal => null,
                else => return zero(T, where),
            };
            var out: T = undefined;
            inline for (st.field_names, st.field_types, st.field_attrs) |name, F, attrs| {
                if (attrs.@"comptime") continue;
                const field_where = comptime @typeName(T) ++ "." ++ name;
                @field(out, name) = if (fields) |lit| for (lit.names, 0..) |stored, i| {
                    if (std.mem.eql(u8, stored.get(zoir), name)) break readTagged(zoir, F, lit.vals.at(@intCast(i)), field_where);
                } else zero(F, field_where) else zero(F, field_where);
            }
            return out;
        },
        .@"enum" => |e| switch (n) {
            .enum_literal => |lit| {
                const stored = lit.get(zoir);
                inline for (e.field_names, e.field_values) |name, tag_value| {
                    if (std.mem.eql(u8, stored, name)) return @fromBackingInt(@as(e.tag_type, tag_value));
                }
            },
            else => if (e.mode == .nonexhaustive) {
                if (readInt(zoir, e.tag_type, node)) |int| return @fromBackingInt(int);
            },
        },
        .@"union" => |u| if (u.tag_type == null) {
            switch (n) {
                .string_literal => |str| if (str.len == @sizeOf(T)) {
                    var out: T = undefined;
                    @memcpy(std.mem.asBytes(&out), str);
                    return out;
                },
                else => {},
            }
        } else switch (n) {
            .struct_literal => |lit| if (lit.names.len == 1) {
                const stored = lit.names[0].get(zoir);
                inline for (u.field_names, u.field_types) |name, F| {
                    if (std.mem.eql(u8, stored, name)) {
                        return @unionInit(T, name, readTagged(zoir, F, lit.vals.at(0), comptime @typeName(T) ++ "." ++ name));
                    }
                }
            },
            else => {},
        },
        .optional => |o| return if (n == .null) null else readValue(zoir, o.child, node, where),
        .error_union => |e| switch (n) {
            .struct_literal => |lit| if (lit.names.len == 1) {
                const inner = lit.vals.at(0);
                if (std.mem.eql(u8, lit.names[0].get(zoir), "ok")) return readValue(zoir, e.payload, inner, where);
                return readValue(zoir, e.error_set, inner, where);
            },
            else => {},
        },
        .error_set => |e| switch (n) {
            .enum_literal => |lit| if (e) |names| {
                const stored = lit.get(zoir);
                inline for (names) |name| {
                    if (std.mem.eql(u8, stored, name)) return @errorCast(@field(anyerror, name));
                }
            },
            else => {},
        },
        else => switch (n) {
            .string_literal => |str| if (str.len == @sizeOf(T)) {
                var out: T = undefined;
                @memcpy(std.mem.asBytes(&out), str);
                return out;
            },
            else => {},
        },
    }
    return zero(T, where);
}

/// The natural zero value of `T`, ignoring any field defaults: 0, false, null,
/// empty slices, the enum tag with value 0 (or else the first tag) and the first
/// field of a union.
///
/// Pointers that can't be null have no zero value, so this panics on them.
/// `where` names the field for the panic message.
pub fn zero(comptime T: type, where: []const u8) T {
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return false,
        .int => return 0,
        .float => return 0,
        .optional => return null,
        .pointer => |p| switch (p.size) {
            .c => return null,
            .slice => {
                var out: T = undefined;
                out.len = 0;
                out.ptr = if (p.sentinel()) |sentinel|
                    @ptrCast(@alignCast(@constCast(&struct {
                        const storage: [1]p.child = .{sentinel};
                    }.storage)))
                else
                    ptrFromBits(@TypeOf(out.ptr), p.attrs.@"align" orelse @alignOf(p.child));
                return out;
            },
            .one, .many => std.debug.panic(
                "hot reload: {s} is a new or changed pointer of type {s}, which has no zero value",
                .{ where, @typeName(T) },
            ),
        },
        .array => |a| {
            var out: T = undefined;
            for (out[0..a.len]) |*item| item.* = zero(a.child, where);
            if (a.sentinel()) |sentinel| @as([*]a.child, &out)[a.len] = sentinel;
            return out;
        },
        .vector => |v| {
            var items: [v.len]v.child = undefined;
            for (&items) |*item| item.* = zero(v.child, where);
            return items;
        },
        .@"struct" => |st| {
            var out: T = undefined;
            inline for (st.field_names, st.field_types, st.field_attrs) |name, F, attrs| {
                if (attrs.@"comptime") continue;
                @field(out, name) = zero(F, comptime @typeName(T) ++ "." ++ name);
            }
            return out;
        },
        .@"enum" => |e| {
            if (e.mode == .nonexhaustive) return @fromBackingInt(@as(e.tag_type, 0));
            inline for (e.field_values) |tag_value| {
                if (tag_value == 0) return @fromBackingInt(@as(e.tag_type, 0));
            }
            return @fromBackingInt(@as(e.tag_type, e.field_values[0]));
        },
        .@"union" => |u| if (u.tag_type != null) {
            const name = u.field_names[0];
            return @unionInit(T, name, zero(u.field_types[0], comptime @typeName(T) ++ "." ++ name));
        },
        .error_union => |e| return zero(e.payload, where),
        .error_set => |e| {
            const names = e orelse return @errorCast(error.HotReloadReset);
            return @errorCast(@field(anyerror, names[0]));
        },
        else => {},
    }
    var out: T = undefined;
    @memset(std.mem.asBytes(&out), 0);
    return out;
}

fn roundTrip(comptime From: type, comptime To: type, from: From) !?To {
    const gpa = std.testing.allocator;
    const zon = try encode(gpa, From, &from);
    defer gpa.free(zon);
    var parsed: Parsed = try .init(gpa, zon);
    defer parsed.deinit(gpa);
    try std.testing.expect(!parsed.zoir.hasCompileErrors());
    return parsed.value(To);
}

const Color = enum { red, green, blue };
const Shape = union(enum) { circle: f32, square: struct { w: f32, h: f32 }, none };

test "unchanged types round trip" {
    const S = struct {
        a: u32,
        b: f32,
        c: bool,
        d: ?i8,
        e: ?i8,
        f: Color,
        g: Shape,
        h: Shape,
        i: [3]u16,
        j: [4]u8,
        k: struct { x: f64, y: void },
        l: u128,
        m: i64,
    };
    const s: S = .{
        .a = 7,
        .b = -1.5,
        .c = true,
        .d = null,
        .e = -3,
        .f = .blue,
        .g = .{ .square = .{ .w = 1, .h = 0.1 } },
        .h = .none,
        .i = .{ 1, 2, 3 },
        .j = "a\x00\xffb".*,
        .k = .{ .x = 1e300, .y = {} },
        .l = std.math.maxInt(u128),
        .m = std.math.minInt(i64),
    };
    try std.testing.expectEqualDeep(s, (try roundTrip(S, S, s)).?);
}

test "floats keep their exact value" {
    for ([_]f32{ 0.1, -0.0, 1e30, std.math.floatMin(f32), std.math.inf(f32), -std.math.inf(f32) }) |f| {
        const got = (try roundTrip(f32, f32, f)).?;
        try std.testing.expectEqual(@as(u32, @bitCast(f)), @as(u32, @bitCast(got)));
    }
    try std.testing.expect(std.math.isNan((try roundTrip(f64, f64, std.math.nan(f64))).?));
}

test "struct changes: new, removed, and retyped fields" {
    const Old = struct { keep: u32, inner: struct { keep: f32, retyped: u32 }, gone: bool, retyped: u32, list: [2]u8 };
    const New = struct {
        keep: u32,
        inner: struct { keep: f32, retyped: i32, added: u8 },
        added: f32 = 9.5,
        added_opt: ?*u32,
        added_slice: []const u8,
        added_str: [:0]const u8,
        added_enum: Color,
        added_union: Shape,
        retyped: u64,
        list: [3]u8,
    };
    const got = (try roundTrip(Old, New, .{
        .keep = 1,
        .inner = .{ .keep = 2.5, .retyped = 3 },
        .gone = true,
        .retyped = 4,
        .list = .{ 5, 6 },
    })).?;
    try std.testing.expectEqual(1, got.keep);
    try std.testing.expectEqual(2.5, got.inner.keep);
    try std.testing.expectEqual(0, got.inner.retyped);
    try std.testing.expectEqual(0, got.inner.added);
    try std.testing.expectEqual(0, got.added);
    try std.testing.expectEqual(null, got.added_opt);
    try std.testing.expectEqual(0, got.added_slice.len);
    try std.testing.expectEqualStrings("", got.added_str);
    try std.testing.expectEqual(.red, got.added_enum);
    try std.testing.expectEqual(Shape{ .circle = 0 }, got.added_union);
    try std.testing.expectEqual(0, got.retyped);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &got.list);
}

test "enum and union changes" {
    const Old = struct { removed_tag: enum { a, b }, kept: enum { a, b }, u: union(enum) { a: u32, b: u8 }, v: union(enum) { a: u32, b: u8 } };
    const New = struct { removed_tag: enum { a, c }, kept: enum { c, a, b }, u: union(enum) { z: f32, a: u32 }, v: union(enum) { z: f32, a: u32 } };
    const got = (try roundTrip(Old, New, .{ .removed_tag = .b, .kept = .b, .u = .{ .a = 4 }, .v = .{ .b = 1 } })).?;
    try std.testing.expectEqual(.a, got.removed_tag);
    try std.testing.expectEqual(.b, got.kept);
    try std.testing.expectEqual(4, got.u.a);
    try std.testing.expectEqual(0, got.v.z);
}

test "enum zero is the tag with value 0" {
    try std.testing.expectEqual(.b, zero(enum(u8) { a = 1, b = 0 }, ""));
    try std.testing.expectEqual(.a, zero(enum(u8) { a = 1, b = 2 }, ""));
    const NonExhaustive = enum(u8) { a = 1, _ };
    try std.testing.expectEqual(@as(NonExhaustive, @fromBackingInt(@intCast(0))), zero(NonExhaustive, ""));
}

test "pointers keep their address and are not followed" {
    var target: u32 = 5;
    const items = [_]u8{ 1, 2, 3 };
    const S = struct { p: *u32, o: ?*u32, n: ?*u32, s: []const u8, f: *const fn () void };
    const f = struct {
        fn f() void {}
    }.f;
    const got = (try roundTrip(S, S, .{ .p = &target, .o = &target, .n = null, .s = &items, .f = &f })).?;
    try std.testing.expectEqual(&target, got.p);
    try std.testing.expectEqual(&target, got.o);
    try std.testing.expectEqual(null, got.n);
    try std.testing.expectEqual(@as([]const u8, &items).ptr, got.s.ptr);
    try std.testing.expectEqual(3, got.s.len);
    try std.testing.expectEqual(&f, got.f);
}

test "undefined data in a value can be encoded" {
    const S = struct { p: *u32, s: []u8, e: Color, u: Shape };
    var s: S = undefined;
    @memset(std.mem.asBytes(&s), 0xaa);
    _ = try roundTrip(S, S, s);
}

test "top level type changes give null" {
    try std.testing.expectEqual(null, try roundTrip(u32, i32, 1));
    try std.testing.expectEqual(null, try roundTrip(u32, struct { a: u32 }, 1));
    try std.testing.expectEqual(null, try roundTrip(struct { a: u32 }, u32, .{ .a = 1 }));
    try std.testing.expectEqual(@as(?u32, 1), try roundTrip(u32, u32, 1));
}

test "slices" {
    const gpa = std.testing.allocator;
    const Old = struct { a: u32, b: u32 };
    const New = struct { b: u32, c: u32 };
    const zon = try encodeSlice(gpa, Old, &.{ .{ .a = 1, .b = 2 }, .{ .a = 3, .b = 4 } });
    defer gpa.free(zon);
    var parsed: Parsed = try .init(gpa, zon);
    defer parsed.deinit(gpa);
    try std.testing.expectEqual(null, parsed.sliceLen(u8));

    var out: [2]New = undefined;
    try std.testing.expectEqual(2, parsed.sliceLen(New).?);
    parsed.sliceInto(New, &out);
    try std.testing.expectEqualSlices(New, &.{ .{ .b = 2, .c = 0 }, .{ .b = 4, .c = 0 } }, &out);

    const bytes = try encodeSlice(gpa, u8, "ab\x00\xff\n\"");
    defer gpa.free(bytes);
    var parsed_bytes: Parsed = try .init(gpa, bytes);
    defer parsed_bytes.deinit(gpa);
    var out_bytes: [6]u8 = undefined;
    try std.testing.expectEqual(6, parsed_bytes.sliceLen(u8).?);
    parsed_bytes.sliceInto(u8, &out_bytes);
    try std.testing.expectEqualSlices(u8, "ab\x00\xff\n\"", &out_bytes);

    const empty = try encodeSlice(gpa, u32, &.{});
    defer gpa.free(empty);
    var parsed_empty: Parsed = try .init(gpa, empty);
    defer parsed_empty.deinit(gpa);
    try std.testing.expectEqual(0, parsed_empty.sliceLen(u32).?);
}

test "shapeEql ignores anonymous type numbers" {
    try std.testing.expect(shapeEql("*a.f__struct_123", "*a.f__struct_98765"));
    try std.testing.expect(shapeEql("*a__enum_1.b__union_2", "*a__enum_3.b__union_4"));
    try std.testing.expect(!shapeEql("*a.f__struct_123", "*a.g__struct_123"));
    try std.testing.expect(!shapeEql("u32", "u321"));
    try std.testing.expect(shapeEql("", ""));
}
