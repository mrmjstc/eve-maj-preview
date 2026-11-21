//! Registering hotkeys and gating each press, which then runs through App's Commands; suspending hotkeys is its own.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");
const scout = @import("../clients/scout.zig");
const config_mod = @import("../config.zig");
const set = @import("../thumbnail/set.zig");
const keyboard_hook = @import("keyboard_hook.zig");
const hooks = @import("hooks.zig");
const hook_bindings = @import("hook_bindings.zig");
const bindings = @import("bindings.zig");
const plan_mod = @import("plan.zig");
const cycle_order = @import("cycle_order.zig");
const commands_mod = @import("commands.zig");
const messages = @import("../messages.zig");
const log = @import("../log.zig");

const GlobalConfig = config_mod.GlobalConfig;
const HotkeyAction = bindings.HotkeyAction;
const ThumbnailSet = set.ThumbnailSet;
const Commands = commands_mod.Commands;
const Outcome = commands_mod.Outcome;
const slog = log.Scoped("hotkeys");

const KEY_NAME_SIZE = 32;

/// What the manager borrows from App, which outlives it and keeps these across the Save that recreates it.
pub const Borrowed = struct {
    store: *config_mod.ProfileStore,
    global_settings: *const GlobalConfig,
    /// The hidden window hotkeys post to.
    timer_hwnd: win32.HWND,
};

pub const HotkeyManager = struct {
    allocator: std.mem.Allocator,
    /// The saved copy, for the bindings and the groups and characters their ids index into; other settings read live().
    config: *const config_mod.Config,
    /// Borrowed; outlives the manager.
    store: *config_mod.ProfileStore,
    /// Borrowed; outlives the manager.
    global_settings: *const GlobalConfig,
    /// See Borrowed.timer_hwnd.
    timer_hwnd: win32.HWND,
    hotkey_map: std.AutoHashMap(c_int, HotkeyAction),
    /// What the registered actions' index slices borrow from; null while none are registered.
    plan: ?plan_mod.Plan = null,
    /// The suspend hotkey itself stays live.
    are_hotkeys_suspended: bool = false,
    /// Whether the config dialog is recording a new hotkey; kept separate from are_hotkeys_suspended so the two don't clobber each other.
    is_dialog_suspended: bool = false,
    /// Whether a text box outside the config dialog has the keyboard.
    is_typing_suspended: bool = false,
    /// What syncFocusFilter last handed the hook thread; null until it first does, so a recreated manager sends it again.
    sent_focus_filter: ?hook_bindings.FocusFilter = null,

    /// Registers from the profile's saved copy, since bindings only change on Save.
    pub fn init(allocator: std.mem.Allocator, borrowed: Borrowed) HotkeyManager {
        return .{
            .allocator = allocator,
            .config = &borrowed.store.saved,
            .store = borrowed.store,
            .global_settings = borrowed.global_settings,
            .timer_hwnd = borrowed.timer_hwnd,
            .hotkey_map = .init(allocator),
        };
    }

    /// The running copy, including the dialog's unsaved edits.
    pub fn live(self: *const HotkeyManager) *const config_mod.Config {
        return &self.store.live;
    }

    fn planSettings(self: *const HotkeyManager) plan_mod.Settings {
        return .{ .characters = self.config.characters.items, .groups = self.config.hotkeyGroups.items, .hotkeys = &self.config.hotkeys, .global = self.global_settings };
    }

    fn formatKeyName(virtual_key: u32, buffer: *[KEY_NAME_SIZE]u8) []const u8 {
        var writer: std.Io.Writer = .fixed(buffer);
        vk.writeVirtualKey(&writer, virtual_key) catch |err| {
            slog.warn("Failed to format virtual key 0x{X}: {}", .{ virtual_key, err });
            // "VK" and at most 8 hex digits always fit.
            return std.mem.print(buffer, "VK{X}", .{virtual_key}) catch unreachable;
        };
        return writer.buffered();
    }

    /// Tracks the entry's action once if any key registers, since they all post one ID; logs each failure itself and returns how many failed.
    fn registerKeys(self: *HotkeyManager, hwnd: win32.HWND, entry: plan_mod.Entry) usize {
        var key_name_buf: [KEY_NAME_SIZE]u8 = undefined;
        var registered: config_mod.KeyList = .empty;
        for (entry.keys.slice()) |virtual_key| {
            hooks.register(hwnd, virtual_key, entry.id) catch |err| {
                slog.err("Failed to register hotkey {s} ({s}): {}", .{ formatKeyName(virtual_key, &key_name_buf), entry.description, err });
                continue;
            };
            _ = registered.append(virtual_key);
            slog.debug("Registered hotkey: {s} -> {s}", .{ formatKeyName(virtual_key, &key_name_buf), entry.description });
        }
        if (registered.isEmpty()) return entry.keys.len;

        self.hotkey_map.put(entry.id, entry.action) catch |err| {
            slog.err("Failed to track hotkey ({s}): {}", .{ entry.description, err });
            for (registered.slice()) |virtual_key| hooks.unregister(virtual_key);
            return entry.keys.len;
        };
        return entry.keys.len - registered.len;
    }

    /// Replaces whatever is registered, so resuming restores exactly the saved bindings.
    pub fn registerHotkeys(self: *HotkeyManager, hwnd: win32.HWND) !void {
        self.unregisterAll();
        hooks.setExactModifiers(self.config.hotkeys.exactHotkeyModifiers);

        var built = try plan_mod.build(self.allocator, self.planSettings());
        if (built.isEmpty()) {
            built.deinit();
            slog.debug("No hotkeys configured", .{});
            return;
        }
        self.plan = built;
        const planned = &self.plan.?;

        const counts = planned.counts;
        slog.debug("Registering hotkeys: {} group(s), {} global action(s), {} per-character hotkey(s), {} profile-switch hotkey(s), {} app hotkey(s), {} url hotkey(s)", .{ counts.groups, counts.globals, counts.character_combos, counts.profile_switches, counts.apps, counts.urls });

        var failed_count: usize = 0;
        for (planned.overflows.items) |overflow| {
            slog.err("Failed to register hotkey group '{s}' {s}: too many group cycle keys", .{ overflow.group_name, cycle_order.directionName(overflow.is_forward) });
            failed_count += 1;
        }
        for (planned.entries.items) |entry| failed_count += self.registerKeys(hwnd, entry);

        const success_count: usize = self.hotkey_map.count();
        if (failed_count > 0) {
            if (success_count == 0) {
                slog.err("Failed to register any hotkeys ({} key(s) failed), so none will work", .{failed_count});
                self.unregisterAll();
                return error.RegisterHotkeysFailed;
            }
            // The hotkeys that did register stay live.
            slog.warn("Failed to register {} key(s); the other {} hotkey(s) still work", .{ failed_count, success_count });
            return error.RegisterHotkeysFailed;
        }

        slog.debug("Successfully registered all {} hotkey(s)", .{success_count});
    }

    pub fn unregisterAll(self: *HotkeyManager) void {
        hooks.unregisterAll();
        slog.debug("Unregistering {} hotkey(s)", .{self.hotkey_map.count()});
        self.hotkey_map.clearRetainingCapacity();
        if (self.plan) |*planned| planned.deinit();
        self.plan = null;
    }

    /// Runs a WM_HOTKEY press through `commands` once it passes the gate; `lParam` says whether it's a held key's auto-repeat.
    pub fn handleHotkeyPress(self: *HotkeyManager, hotkey_id: c_int, lParam: win32.LPARAM, commands: *const Commands, thumbnail_set: ?*ThumbnailSet) Outcome {
        const action = self.hotkey_map.getPtr(hotkey_id) orelse {
            slog.warn("Received unknown hotkey ID: {}", .{hotkey_id});
            return .none;
        };

        const verdict = plan_mod.pressVerdict(.{
            .is_repeat = hook_bindings.isRepeat(lParam),
            .allows_repeat = self.live().hotkeys.allowHotkeyAutoRepeat,
            .is_suspend_key = action.* == .suspend_hotkeys,
            .are_hotkeys_suspended = self.are_hotkeys_suspended,
            .is_dialog_recording = self.is_dialog_suspended,
            .requires_eve_focus = self.live().hotkeys.requireEveFocus,
            // Checked again after the hook's check, since focus can move before this message arrives.
            .has_eve_focus = commands.foregroundEveWindow() != null,
        });
        switch (verdict) {
            .run => return commands.run(action, thumbnail_set),
            .toggle_suspend => self.toggleSuspend(),
            .ignore_repeat => slog.debug("Hotkey {} ignored - key-repeat re-fire while held", .{hotkey_id}),
            .ignore_suspended => slog.debug("Hotkey {} ignored - hotkeys suspended", .{hotkey_id}),
            .ignore_recording => slog.debug("Hotkey {} ignored - config dialog is recording a new hotkey", .{hotkey_id}),
            .ignore_unfocused => slog.debug("Hotkey {} ignored - EVE window not in focus", .{hotkey_id}),
        }
        return .none;
    }

    /// Per tick: hands the hook thread what the require-EVE-focus check needs when it changes, so keys reach other apps.
    pub fn syncFocusFilter(self: *HotkeyManager, windows: []const scout.EveWindow) void {
        var filter: hook_bindings.FocusFilter = .{
            .is_required = self.live().hotkeys.requireEveFocus,
            .exempt_id = bindings.globalId(.suspend_hotkeys),
        };
        const is_complete = for (windows) |eve_window| {
            if (!filter.add(eve_window.hwnd)) break false;
        } else true;
        if (self.sent_focus_filter) |*sent| {
            if (sent.eql(&filter)) return;
        }
        if (!is_complete) slog.warn("Failed to pass every window to the require-EVE-focus check: over {} tracked, so hotkeys pass through in the rest", .{filter.window_count});
        if (hook_bindings.setFocusFilter(filter)) self.sent_focus_filter = filter;
    }

    /// For the suspend hotkey's own press, the tray and a protocol link.
    pub fn toggleSuspend(self: *HotkeyManager) void {
        self.are_hotkeys_suspended = !self.are_hotkeys_suspended;
        const state = if (self.are_hotkeys_suspended) "suspended" else "resumed";
        slog.info("Hotkeys {s}", .{state});

        const hwnd = self.timer_hwnd;
        if (self.are_hotkeys_suspended) {
            // Unbound, since the hooks would otherwise keep swallowing these keys system-wide.
            self.unregisterAll();
            // Pressing it again must still be able to resume everything else.
            if (plan_mod.globalEntry(self.planSettings(), bindings.SUSPEND_BINDING)) |entry| _ = self.registerKeys(hwnd, entry);
        } else {
            self.registerHotkeys(hwnd) catch |err| {
                slog.err("Failed to re-register hotkeys after resuming: {}", .{err});
            };
        }
        if (!win32.toBool(win32.PostMessageA(hwnd, messages.WM_HOTKEYS_STATE_CHANGED, 0, 0))) {
            slog.warn("Failed to show that hotkeys were {s}: error {d}", .{ state, win32.GetLastError() });
        }
    }

    pub fn areHotkeysSuspended(self: *const HotkeyManager) bool {
        return self.are_hotkeys_suspended;
    }

    /// Unbinds rather than gates, since the hooks would otherwise swallow the key the dialog is recording.
    pub fn dialogSuspendHotkeys(self: *HotkeyManager) void {
        if (self.is_dialog_suspended) return;
        slog.debug("Config dialog is recording a hotkey - unregistering live hotkeys", .{});
        self.is_dialog_suspended = true;
        self.unregisterAll();
        keyboard_hook.armWinKeyCapture(self.timer_hwnd);
    }

    /// Re-registers from the same in-memory config unregisterAll left untouched, so this restores exactly what was live before.
    pub fn dialogResumeHotkeys(self: *HotkeyManager, hwnd: win32.HWND) void {
        if (!self.is_dialog_suspended) return;
        slog.debug("Config dialog finished recording - re-registering hotkeys", .{});
        self.is_dialog_suspended = false;
        keyboard_hook.disarmWinKeyCapture();
        self.registerHotkeys(hwnd) catch |err| {
            slog.err("Failed to re-register hotkeys after dialog recording: {}", .{err});
        };
    }

    /// Unbinds rather than gates, since the hooks would otherwise swallow the letters typed; hotkeys already suspended stay as they are.
    pub fn typingSuspendHotkeys(self: *HotkeyManager) void {
        if (self.are_hotkeys_suspended or self.is_dialog_suspended or self.is_typing_suspended) return;
        self.is_typing_suspended = true;
        self.unregisterAll();
    }

    pub fn typingResumeHotkeys(self: *HotkeyManager, hwnd: win32.HWND) void {
        if (!self.is_typing_suspended) return;
        self.is_typing_suspended = false;
        self.registerHotkeys(hwnd) catch |err| {
            slog.err("Failed to re-register hotkeys after typing: {}", .{err});
        };
    }

    /// Moves the per-character hotkeys' cursors onto a manually focused character, after Commands moved the rest.
    pub fn syncCharacterCursors(self: *HotkeyManager, character_name: []const u8) void {
        const characters = self.config.characters.items;
        var actions = self.hotkey_map.valueIterator();
        while (actions.next()) |action| {
            if (action.* != .activate_character) continue;
            const group = &action.activate_character;
            for (group.character_indices, 0..) |character_index, member_index| {
                if (character_index < characters.len and std.mem.eql(u8, characters[character_index].name, character_name)) {
                    group.current_index = member_index;
                    break;
                }
            }
        }
    }

    pub fn deinit(self: *HotkeyManager) void {
        self.unregisterAll();
        self.hotkey_map.deinit();
    }
};
