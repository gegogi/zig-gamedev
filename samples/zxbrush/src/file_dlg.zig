const builtin = @import("builtin");
const std = @import("std");
const zgui = @import("zgui");
const mem = std.mem;
const Allocator = mem.Allocator;
const native_os = builtin.target.os.tag;

var base_font: ?zgui.Font = null;
var button_font: ?zgui.Font = null;

pub fn StrWithBuf(comptime N: u32) type {
    return struct {
        const Self = @This();
        const Dim: u32 = N;

        buf: [N]u8 = undefined,
        str: []u8 = &[_]u8{},
        //str_z: [:0]u8 = &[_:0]u8{},   // 왜 안 됨?
        str_z: [:0]u8 = undefined,

        pub fn BufType() type {
            return [N]u8;
        }

        // 포인터가 무효화 되므로 사용하지 않는다.
        // pub fn init(s: []const u8) Self {
        //     var self = Self{};
        //     self.set(s);
        //     return self;
        // }

        pub fn set(self: *Self, s: []const u8) void {
            // const empty_str: []u8 = &[_]u8{};
            // const empty_str_z: [:0]u8 = &[_:0]u8{};
            // const c_empty_str: []const u8 = &[_]u8{};
            // const c_empty_str_z: [:0]const u8 = &[_:0]u8{};
            // _ = empty_str;
            // _ = empty_str_z;
            // _ = c_empty_str;
            // _ = c_empty_str_z;

            std.debug.assert(s.len < N);
            mem.copyForwards(u8, &self.buf, s);
            self.setLen(s.len);
        }

        pub fn setLen(self: *Self, len: usize) void {
            self.buf[len] = 0;
            self.str = self.buf[0..len];
            self.str_z = @ptrCast(self.str);
        }

        pub fn concat(self: *Self, s: []const u8) void {
            const new_len = self.str.len + s.len;
            std.debug.assert(new_len < N);
            mem.copyForwards(u8, self.buf[self.str.len..], s);
            self.buf[new_len] = 0;
            self.str = self.buf[0..new_len];
            self.str_z = @ptrCast(self.str);
        }

        pub fn replaceChar(self: *Self, from_c: u8, to_c: u8) void {
            for (0..self.str.len) |i| {
                if (self.str[i] == from_c) {
                    self.str[i] = to_c;
                }
            }
        }

        pub fn lastChar(self: *Self) u8 {
            if (self.str.len == 0) {
                return 0;
            }
            return self.str[self.str.len - 1];
        }

        pub fn trimRight(self: *Self) void {
            var i = self.str.len;
            while (i > 0) : (i -= 1) {
                const c = self.buf[i - 1];
                if (c == '\n' or c == '\t' or c == ' ') {
                    self.buf[i - 1] = 0;
                    continue;
                }
                break;
            }
            self.buf[i] = 0;
            self.str = self.buf[0..i];
            self.str_z = @ptrCast(self.str);
        }
    };
}

pub const PathStr = StrWithBuf(1024);
pub const MsgStr = StrWithBuf(256);
pub const ExtSet = std.StringHashMap(void);

pub fn createExtSet(allocator: Allocator, exts: []const []const u8) !*ExtSet {
    const ext_set = try allocator.create(ExtSet);
    ext_set.* = ExtSet.init(allocator);
    for (exts) |ext| {
        try ext_set.put(ext, {});
    }
    return ext_set;
}

fn pathStrLessThan(_: void, a: *PathStr, b: *PathStr) bool {
    return (std.mem.order(u8, a.str, b.str) == .lt);
}

pub const DirList = struct {
    allocator: Allocator,
    dpath: PathStr = undefined,
    name_list: std.ArrayList(*PathStr) = undefined,
    is_populated: bool = false,

    const Self: type = @This();

    pub fn init(allocator: Allocator) Self {
        var self = Self{
            .allocator = allocator,
        };
        self.dpath.set("");
        self.name_list = @TypeOf(self.name_list).init(allocator);
        self.is_populated = false;
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.reset();
        self.name_list.deinit();
    }

    pub fn reset(self: *Self) void {
        self.is_populated = false;
        for (self.name_list.items) |item| {
            self.name_list.allocator.destroy(item);
        }
        self.name_list.clearAndFree();
        self.dpath.set("");
    }

    pub fn populate(self: *Self, dpath: []const u8, add_sub_dirs: bool, ext_set: ?*ExtSet) !void {
        self.is_populated = true;
        self.dpath.set(dpath);
        if (add_sub_dirs) {
            const par_dir = try self.allocator.create(PathStr);
            par_dir.set("../");
            try self.name_list.append(par_dir);
        }
        var dir_obj: std.fs.Dir = try std.fs.openDirAbsolute(dpath, std.fs.Dir.OpenDirOptions{
            .iterate = true,
        });
        defer dir_obj.close();
        var dir_iter = dir_obj.iterate();
        while (try dir_iter.next()) |entry| {
            var entry_name: PathStr = undefined;
            entry_name.set(entry.name);
            //std.debug.print("cur_dir={s}, entry.name={s}\n", .{ self.cur_dir.str, entry.name });
            if (entry.kind == .directory) {
                if (!add_sub_dirs) {
                    continue;
                }
                entry_name.concat("/");
            } else {
                if (ext_set != null and !ext_set.?.contains(std.fs.path.extension(entry_name.str))) {
                    continue;
                }
            }
            const entry_str = try self.allocator.create(PathStr);
            entry_str.set(entry_name.str);
            try self.name_list.append(entry_str);
        }
        if (native_os == .windows) {
            // list all drives
        }

        std.mem.sort(*PathStr, self.name_list.items, {}, pathStrLessThan);
    }
};

pub const FileDialog = struct {
    allocator: Allocator,
    title: MsgStr,
    ext_set: ?*ExtSet,
    is_saving: bool,
    file_open_handler: *const fn (fpath: [:0]const u8, is_saving: bool) anyerror!void,
    is_confirmed: bool,
    cur_dir: PathStr,
    cur_dir_ls: DirList,
    cur_dir_item: i32,
    cur_file_text: PathStr,
    msg: MsgStr,

    const Self = @This();

    pub fn create(allocator: Allocator, title: []const u8, ext_set: ?*ExtSet, is_saving: bool, file_open_handler: *const fn (fpath: [:0]const u8, is_saving: bool) anyerror!void) !*FileDialog {
        var dlg = try allocator.create(Self);
        dlg.* = Self{
            .allocator = allocator,
            .title = undefined,
            .ext_set = ext_set,
            .is_saving = is_saving,
            .file_open_handler = file_open_handler,
            .is_confirmed = false,
            .cur_dir = undefined,
            .cur_dir_ls = DirList.init(allocator),
            .cur_dir_item = -1,
            .cur_file_text = undefined,
            .msg = undefined,
        };
        dlg.title.set(title);
        try dlg.set_cur_dir(".");
        dlg.cur_file_text.set("");
        dlg.msg.set("");
        return dlg;
    }

    pub fn destroy(self: *Self) void {
        self.reset(".", "") catch unreachable;
        self.cur_dir_ls.deinit();
        self.allocator.destroy(self);
    }

    pub fn set_cur_dir(self: *Self, cur_dir: []const u8) anyerror!void {
        var buf: PathStr.BufType() = undefined;
        const _buf = try std.fs.cwd().realpath(cur_dir, &buf);
        self.cur_dir.set(_buf);
        self.cur_dir.replaceChar('\\', '/');
        if (self.cur_dir.lastChar() != '/') {
            self.cur_dir.concat("/");
        }
    }

    pub fn reset(self: *Self, cur_dir: []const u8, cur_file_text: []const u8) anyerror!void {
        self.is_confirmed = false;
        try self.set_cur_dir(cur_dir);
        self.cur_dir_ls.reset();
        self.cur_dir_item = -1;
        self.cur_file_text.set(cur_file_text);
        self.msg.set("");
    }

    pub fn ui(self: *Self, p_need_confirm: *bool) anyerror!bool {
        if (base_font != null) zgui.pushFont(base_font.?);

        const need_confirm = p_need_confirm.*;
        var is_active: bool = true;
        var mouse_dbl_clk: bool = false;
        var ui_opened: bool = true;
        _ = zgui.begin("Select/Input a File Name", .{
            .popen = &ui_opened,
            .flags = zgui.WindowFlags{ .no_collapse = true },
        });
        if (ui_opened) {
            //const cur_dir_text = self.cur_dir;
            if (!self.cur_dir_ls.is_populated) {
                try self.cur_dir_ls.populate(self.cur_dir.str, true, self.ext_set);
            }
            zgui.text("{s}", .{self.cur_dir.str});
            if (zgui.beginListBox("Items", .{})) {
                for (0.., self.cur_dir_ls.name_list.items) |i, fname| {
                    var selected = (i == self.cur_dir_item);
                    const changed = zgui.selectableStatePtr(fname.str_z, .{ .pselected = &selected, .flags = zgui.SelectableFlags{ .allow_double_click = true } });
                    const hovered = zgui.isItemHovered(.{});
                    if (hovered) {
                        mouse_dbl_clk = zgui.isMouseDoubleClicked(zgui.MouseButton.left);
                    }
                    if (changed and selected) {
                        self.cur_dir_item = @intCast(i);
                        self.cur_file_text.set(fname.str);
                    } else if (mouse_dbl_clk and self.cur_dir_item == i) {
                        self.cur_file_text.set(fname.str);
                    }
                }
                zgui.endListBox();
            }
            if (zgui.inputText("File Name", .{ .buf = self.cur_file_text.str_z, .flags = zgui.InputTextFlags{ .auto_select_all = true } })) {
                std.debug.print("fileName={s}", .{self.cur_file_text.str_z});
            }
            var confirm_msg: MsgStr = undefined;
            if (need_confirm) {
                if (self.is_saving) {
                    confirm_msg.set("Overwrite Existing");
                } else {
                    confirm_msg.set("Discard Unsaved");
                }
                _ = zgui.checkbox(confirm_msg.str_z, .{
                    .v = &self.is_confirmed,
                });
            }
            zgui.pushStyleColor1u(.{ .idx = zgui.StyleCol.text, .c = 0xFFFF00FF });
            zgui.text("{s}", .{self.msg.str_z});
            zgui.popStyleColor(.{});
            zgui.newLine();

            {
                if (button_font != null) zgui.pushFont(button_font.?);
                const ok_clk = zgui.button("OK", .{});
                zgui.sameLine(.{});
                const cancel_clk = zgui.button("Cancel", .{});
                if (button_font != null) zgui.popFont();
                if (mouse_dbl_clk or ok_clk or cancel_clk) {
                    if (mouse_dbl_clk or ok_clk) {
                        var open_path: PathStr = undefined;
                        open_path.set(self.cur_dir.str);
                        open_path.concat(self.cur_file_text.str);
                        if (open_path.lastChar() == '/') {
                            // dir
                            var valid_path = true;
                            std.fs.accessAbsolute(open_path.str, .{}) catch {
                                valid_path = false;
                            };
                            if (valid_path) {
                                try self.reset(open_path.str, "");
                            } else {
                                try self.reset(".", "");
                                self.msg.set("Error while opening the path.");
                            }
                        } else {
                            // file
                            var can_open = true;
                            if (self.is_saving) {
                                if (need_confirm) {
                                    var valid_path = true;
                                    std.fs.accessAbsolute(open_path.str, .{}) catch {
                                        valid_path = false;
                                    };
                                    if (valid_path) {
                                        can_open = self.is_confirmed;
                                    }
                                }
                            } else {
                                can_open = if (self.is_confirmed) need_confirm else true;
                            }
                            /////////////////////////////////////////////
                            if (can_open) {
                                try self.file_open_handler(open_path.str_z, self.is_saving);
                                is_active = false;
                                try self.reset(".", "");
                            } else {
                                if (need_confirm) {
                                    self.msg.set("Check <");
                                    self.msg.concat(confirm_msg.str);
                                    self.msg.concat("> to proceed.");
                                }
                            }
                        }
                    } else {
                        try self.reset(".", "");
                        is_active = false;
                    }
                }
            }
        } else {
            is_active = false;
        }
        zgui.end();

        if (base_font != null) zgui.popFont();

        return is_active;
    }
};
