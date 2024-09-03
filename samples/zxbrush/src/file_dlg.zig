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

        pub fn init(s: []const u8) Self {
            var self = Self{};
            self.set(s);
            return self;
        }

        pub fn set(self: *Self, s: []const u8) void {
            std.debug.assert(s.len < N);
            mem.copyForwards(u8, &self.buf, s);
            self.buf[s.len] = 0;
            self.str = self.buf[0..s.len];
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
    };
}

const PathStr = StrWithBuf(1024);
const MsgStr = StrWithBuf(256);
const DirList = std.ArrayList(PathStr);
const ExtSet = std.StringHashMap(void);

pub const FileDialog = struct {
    allocator: Allocator,
    title: MsgStr,
    exts: *ExtSet,
    is_saving: bool,
    file_handler: *const fn (fpath: [:0]const u8) anyerror!void,
    is_confirmed: bool,
    cur_dir: PathStr,
    cur_dir_listing: DirList,
    cur_dir_item: i32,
    cur_file_text: PathStr,
    msg: MsgStr,

    pub fn create(allocator: Allocator, title: []const u8, exts: []const []const u8, is_saving: bool, file_handler: *const fn (fpath: [:0]const u8) anyerror!void) anyerror!*FileDialog {
        const _exts = try allocator.create(ExtSet);
        _exts.* = ExtSet.init(allocator);
        for (exts) |ext| {
            try _exts.put(ext, {});
        }
        var dlg = try allocator.create(FileDialog);
        dlg.* = FileDialog{
            .allocator = allocator,
            .title = undefined,
            .exts = _exts,
            .is_saving = is_saving,
            .file_handler = file_handler,
            .is_confirmed = false,
            .cur_dir = undefined,
            .cur_dir_listing = DirList.init(allocator),
            .cur_dir_item = -1,
            .cur_file_text = undefined,
            .msg = undefined,
        };
        dlg.title.set(title);
        try dlg.set_cur_dir("");
        dlg.cur_file_text.set("");
        dlg.msg.set("");
        return dlg;
    }

    pub fn destroy(self: *FileDialog) void {
        self.exts.deinit();
        self.allocator.destroy(self.exts);
        self.cur_dir_listing.deinit();
        self.allocator.destroy(self);
    }

    pub fn set_cur_dir(self: *FileDialog, cur_dir: []u8) anyerror!void {
        var buf: PathStr.BufType() = undefined;
        const _buf = try std.fs.cwd().realpath(cur_dir, &buf);
        self.cur_dir.set(_buf);
        self.cur_dir.replaceChar('\\', '/');
        if (self.cur_dir.lastChar() != '/') {
            self.cur_dir.concat("/");
        }
    }

    pub fn reset(self: *FileDialog, cur_dir: []u8, cur_file_text: []u8) anyerror!void {
        self.is_confirmed = false;
        try self.set_cur_dir(cur_dir);
        self.cur_dir_listing.deinit();
        self.cur_dir_listing = DirList.init(self.allocator);
        self.cur_dir_item = -1;
        self.cur_file_text.set(cur_file_text);
        self.msg.set("");
    }

    pub fn ui(self: *FileDialog, p_need_confirm: *bool) anyerror!bool {
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
            if (self.cur_dir_listing.items.len == 0) {
                const par_dir = try self.cur_dir_listing.addOne();
                par_dir.set("../");
                var dir_obj: std.fs.Dir = try std.fs.openDirAbsolute(self.cur_dir.str, std.fs.Dir.OpenDirOptions{
                    .iterate = true,
                });
                defer dir_obj.close();
                var dir_iter = dir_obj.iterate();
                while (try dir_iter.next()) |entry| {
                    var entry_name: PathStr = undefined;
                    entry_name.set(entry.name);
                    //std.debug.print("cur_dir={s}, entry.name={s}\n", .{ self.cur_dir.str, entry.name });
                    if (entry.kind == .directory) {
                        entry_name.concat("/");
                    } else {
                        if (!self.exts.contains(std.fs.path.extension(entry.name))) {
                            continue;
                        }
                    }
                    const entry_str = try self.cur_dir_listing.addOne();
                    entry_str.set(entry_name.str);
                }
                if (native_os == .windows) {
                    // list all drives
                }
            }
            zgui.text("{s}", .{self.cur_dir.str});
            if (zgui.beginListBox("Items", .{})) {
                for (0.., self.cur_dir_listing.items) |i, list_item| {
                    var selected = (i == self.cur_dir_item);
                    const changed = zgui.selectableStatePtr(list_item.str_z, .{ .pselected = &selected, .flags = zgui.SelectableFlags{ .allow_double_click = true } });
                    const hovered = zgui.isItemHovered(.{});
                    if (hovered) {
                        mouse_dbl_clk = zgui.isMouseDoubleClicked(zgui.MouseButton.left);
                    }
                    if (changed and selected) {
                        self.cur_dir_item = @intCast(i);
                        self.cur_file_text.set(list_item.str);
                    } else if (mouse_dbl_clk and self.cur_dir_item == i) {
                        self.cur_file_text.set(list_item.str);
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
                                try self.reset("", "");
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
                                try self.file_handler(open_path.str_z);
                                is_active = false;
                                try self.reset("", "");
                            } else {
                                if (need_confirm) {
                                    self.msg.set("Check <");
                                    self.msg.concat(confirm_msg.str);
                                    self.msg.concat("> to proceed.");
                                }
                            }
                        }
                    } else {
                        try self.reset("", "");
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
