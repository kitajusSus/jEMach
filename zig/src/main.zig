const std = @import("std");

pub const BlockType = enum {
    Function,
    Macro,
    Module,
    Struct,
    MutableStruct,
    Begin,
    Quote,
    Let,
    For,
    While,
    If,
    Try,
    Unknown,
};

pub const JuliaParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) JuliaParser {
        return .{
            .allocator = allocator,
        };
    }

    pub fn detectBlockType(self: *JuliaParser, line: []const u8) ?BlockType {
        _ = self;

        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "function ")) return .Function;
        if (std.mem.startsWith(u8, trimmed, "macro ")) return .Macro;
        if (std.mem.startsWith(u8, trimmed, "module ")) return .Module;
        if (std.mem.startsWith(u8, trimmed, "mutable struct ")) return .MutableStruct;
        if (std.mem.startsWith(u8, trimmed, "struct ")) return .Struct;
        if (std.mem.startsWith(u8, trimmed, "begin")) return .Begin;
        if (std.mem.startsWith(u8, trimmed, "quote")) return .Quote;
        if (std.mem.startsWith(u8, trimmed, "let ")) return .Let;
        if (std.mem.startsWith(u8, trimmed, "for ")) return .For;
        if (std.mem.startsWith(u8, trimmed, "while ")) return .While;
        if (std.mem.startsWith(u8, trimmed, "if ")) return .If;
        if (std.mem.startsWith(u8, trimmed, "try")) return .Try;

        return null;
    }

    pub fn isBlockEnd(self: *JuliaParser, line: []const u8) bool {
        _ = self;
        const trimmed = std.mem.trim(u8, line, " \t");
        return std.mem.eql(u8, trimmed, "end");
    }

    pub fn extractVariables(self: *JuliaParser, code: []const u8) !std.ArrayList([]const u8) {
        var variables = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        errdefer variables.deinit(self.allocator);

        var lines = std.mem.tokenizeSequence(u8, code, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                if (eq_pos > 0) {
                    const var_part = std.mem.trim(u8, trimmed[0..eq_pos], " \t");

                    if (std.mem.indexOf(u8, var_part, "\"") == null and
                        std.mem.indexOf(u8, var_part, "'") == null)
                    {
                        const var_name = try self.allocator.dupe(u8, var_part);
                        try variables.append(self.allocator, var_name);
                    }
                }
            }
        }

        return variables;
    }
};

export fn julia_detect_block(
    code_ptr: [*]const u8,
    code_len: usize,
    cursor_line: usize,
    out_start: *usize,
    out_end: *usize,
) bool {
    const code = code_ptr[0..code_len];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parser = JuliaParser.init(allocator);

    var line_list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return false;
    defer line_list.deinit(allocator);

    var lines_iter = std.mem.tokenizeSequence(u8, code, "\n");
    while (lines_iter.next()) |line| {
        line_list.append(allocator, line) catch return false;
    }

    const lines = line_list.items;

    if (cursor_line >= lines.len) return false;

    var start_line: usize = cursor_line;
    var block_type: ?BlockType = null;

    while (start_line > 0) : (start_line -= 1) {
        if (parser.detectBlockType(lines[start_line])) |bt| {
            block_type = bt;
            break;
        }
    }
    if (block_type == null) {
        if (parser.detectBlockType(lines[0])) |bt| {
            block_type = bt;
            start_line = 0;
        } else {
            return false;
        }
    }

    var end_line: usize = start_line + 1;
    var depth: usize = 1;

    while (end_line < lines.len) : (end_line += 1) {
        if (parser.detectBlockType(lines[end_line])) |_| {
            depth += 1;
        } else if (parser.isBlockEnd(lines[end_line])) {
            depth -= 1;
            if (depth == 0) break;
        }
    }

    if (depth != 0 or end_line >= lines.len) return false;

    out_start.* = start_line;
    out_end.* = end_line;

    return true;
}

export fn julia_get_block_content(
    code_ptr: [*]const u8,
    code_len: usize,
    start_line: usize,
    end_line: usize,
    out_buffer: [*]u8,
    buffer_len: usize,
) usize {
    const code = code_ptr[0..code_len];
    const out_slice = out_buffer[0..buffer_len];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var line_list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return 0;
    defer line_list.deinit(allocator);

    var lines_iter = std.mem.tokenizeSequence(u8, code, "\n");
    while (lines_iter.next()) |line| {
        line_list.append(allocator, line) catch return 0;
    }

    const lines = line_list.items;

    if (end_line >= lines.len or start_line > end_line) return 0;

    var total_len: usize = 0;
    for (lines[start_line .. end_line + 1]) |line| {
        const line_len = line.len;
        const needed = line_len + 1;

        if (total_len + needed > out_slice.len) {
            if (total_len + line_len <= out_slice.len) {
                @memcpy(out_slice[total_len .. total_len + line_len], line);
                total_len += line_len;
            }
            break;
        }

        @memcpy(out_slice[total_len .. total_len + line_len], line);
        total_len += line_len;

        out_slice[total_len] = '\n';
        total_len += 1;
    }

    return total_len;
}

test "detect function block" {
    const code =
        \\function hello()
        \\    println("Hello")
        \\end
    ;

    var start: usize = undefined;
    var end: usize = undefined;

    const result = julia_detect_block(code.ptr, code.len, 1, &start, &end);

    try std.testing.expect(result);
    try std.testing.expectEqual(@as(usize, 0), start);
    try std.testing.expectEqual(@as(usize, 2), end);
}

test "extract variables" {
    const code =
        \\x = 5
        \\y = 10
        \\z = x + y
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parser = JuliaParser.init(allocator);
    var vars = try parser.extractVariables(code);
    defer {
        for (vars.items) |v| {
            allocator.free(v);
        }
        vars.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 3), vars.items.len);
    try std.testing.expect(std.mem.eql(u8, vars.items[0], "x"));
    try std.testing.expect(std.mem.eql(u8, vars.items[1], "y"));
    try std.testing.expect(std.mem.eql(u8, vars.items[2], "z"));
}
