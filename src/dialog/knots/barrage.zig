//! The Barrage easter egg behind About's wordmark: up to six pilots by join code, or practice against the AI; main thread only.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const game = @import("../../barrage/game.zig");
const messages = @import("../../barrage/messages.zig");
const wire = @import("../../multiplayer/wire.zig");
const link = @import("../../multiplayer/link.zig");
const host = @import("host.zig");
const session = @import("session.zig");
const style = @import("style.zig");
const widgets = @import("widgets.zig");
const glyphs = @import("glyphs.zig");
const barrage_tanks = @import("barrage_tanks.zig");
const lang = @import("../../lang/lang.zig");
const log = @import("../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Canvas = ui.component.Canvas;
const TextInput = ui.component.TextInput;
const SelectInput = ui.component.SelectInput;
const Game = game.Game;
const SeatKind = messages.SeatKind;
const PilotName = messages.PilotName;
const TankStyle = messages.TankStyle;
const Painter = barrage_tanks.Painter;
const slog = log.Scoped("barrage");

/// Clicks on the wordmark, each soon after the last, that open the game.
const OPENING_CLICKS = 5;
const CLICK_GAP_MS = 600;
const ROUND_CHOICES = [_]u8{ 1, 3, 5, 10 };
/// Sent even when nothing else is, so the relay's sockets don't time out.
const KEEPALIVE_INTERVAL_MS = 1000;
/// How often the barrel's turning is passed on, at most.
const AIM_SEND_INTERVAL_MS = 50;
/// How often a pilot's changed name or tank style is passed on, at most.
const PILOT_SEND_INTERVAL_MS = 300;
/// Messages that arrived ahead of this machine's game, e.g. a shot while the last one still flies.
const MAX_PENDING = 16;
/// How long the marker over a tank whose turn has just begun bobs.
const TURN_PULSE_MS = 1500;
/// How long the ring around it spreads.
const TURN_RING_MS = 800;
/// Columns between the points of the drawn ground line.
const GROUND_LINE_STEP = 4;
/// Columns between the hatching lines under the ground.
const HATCH_STEP = 12;
/// The lobby's tank previews, in field units, and the canvas pixels per unit they're drawn at.
const PREVIEW_WIDTH: f32 = 40;
const PREVIEW_HEIGHT: f32 = 30;
const PREVIEW_SCALE: f32 = 2;
/// From the preview's bottom up to the tank's.
const PREVIEW_GROUND: f32 = 3;
const PREVIEW_ANGLE_DEGREES: f32 = 50;
const HEALTH_BAR_WIDTH: f32 = 34;
/// From a tank's tracks up to its health bar.
const HEALTH_BAR_RISE: f32 = 32;
const SHELL_DRAWN_RADIUS: f32 = 2.5;
/// Between a fire's flames, and their tallest.
const FLAME_STEP: f32 = 5;
const FLAME_HEIGHT: f32 = 8;
/// So six long names still fit across the field's width.
const STANDINGS_PER_ROW = 3;
/// The wind arrow's length at MAX_WIND.
const WIND_ARROW_LENGTH: f32 = 80;
/// From the field's top down to the wind arrow, below its label.
const WIND_ARROW_DROP: f32 = 36;
const CODE_INPUT_KEY: ui.Key = .str("knots.barrage.code");
const NAME_SELECT_KEY: ui.Key = .str("knots.barrage.name");
const CANVAS_KEY: ui.Key = .str("knots.barrage.field");

const Screen = enum { menu, connecting, lobby, playing, ended };

const Mode = enum { practice, host, guest };

/// A message from another player, kept until this machine's game reaches it.
const Pending = struct {
    sender: wire.Seat,
    message: messages.Message,
};

const Outcome = enum { applied, later, stale };

/// Which tank's turn, so a new one can be noticed.
const TurnMark = struct {
    round: u8,
    turn: u16,
    current: u8,
};

comptime {
    std.debug.assert(game.FIELD_WIDTH == style.BARRAGE_FIELD_WIDTH and game.FIELD_HEIGHT == style.BARRAGE_FIELD_HEIGHT);
}

var g_allocator: std.mem.Allocator = undefined;
var g_is_open: bool = false;
var g_screen: Screen = .menu;
var g_mode: Mode = .practice;
/// This machine's relay seat; 0 when hosting or practising.
var g_my_seat: wire.Seat = 0;
/// Edited by the host or in practice; a guest's copy is the host's last.
var g_lobby: messages.Lobby = undefined;
/// A guest's is false until the host's first lobby arrives.
var g_has_lobby: bool = false;
/// By seat; an empty one shows the default.
var g_names: [wire.MAX_SEATS]PilotName = @splat(.{});
/// Kept while the app runs, so it's there the next time the game opens.
var g_my_name: PilotName = .{};
/// By seat; a seat whose pilot hasn't said gets its default.
var g_tank_styles: [wire.MAX_SEATS]TankStyle = defaultTankStyles();
/// Kept while the app runs, like g_my_name.
var g_my_tank_style: TankStyle = .standard;
var g_is_pilot_unsent: bool = false;
var g_last_pilot_sent_ms: i64 = 0;
/// Set when play starts; read only while g_screen is .playing.
var g_game: Game = undefined;
var g_pending: [MAX_PENDING]Pending = undefined;
var g_pending_count: usize = 0;
/// Clicked on the weapon card's arrows, for the next frame's control.
var g_weapon_step: i8 = 0;
var g_turn_mark: ?TurnMark = null;
var g_turn_started_ms: i64 = 0;
var g_code_text: std.ArrayList(u8) = .empty;
var g_code_error: []const u8 = "";
var g_lobby_error: []const u8 = "";
var g_should_focus_code: bool = false;
var g_host_code: wire.Code = @splat(' ');
/// Why the last match or connection ended; a string literal, translated when shown.
var g_ended_reason: []const u8 = "";
var g_last_frame_ms: i64 = 0;
var g_last_sent_ms: i64 = 0;
var g_last_aim_sent_ms: i64 = 0;
var g_last_sent_aim: ?messages.Aim = null;
var g_click_count: u32 = 0;
var g_last_click_ms: i64 = 0;

/// At startup, since a link's thread can outlive the window.
pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
    link.init(allocator);
}

/// Once the window has closed.
pub fn reset() void {
    if (g_is_open) close();
    g_code_text.deinit(g_allocator);
    g_code_text = .empty;
    g_click_count = 0;
}

/// A click on About's wordmark; enough of them in a row open the game.
pub fn countWordmarkClick(context: *ui.Frame) void {
    const now_ms = context.ui().input.now_ms;
    g_click_count = if (now_ms - g_last_click_ms <= CLICK_GAP_MS) g_click_count + 1 else 1;
    g_last_click_ms = now_ms;
    if (g_click_count < OPENING_CLICKS) return;
    g_click_count = 0;
    slog.info("Barrage opened", .{});
    g_is_open = true;
    g_screen = .menu;
    g_code_error = "";
    g_should_focus_code = true;
    g_last_frame_ms = 0;
    host.startAnimation();
    context.requestRedraw();
}

/// What the link's thread posted, as host's barrage_arrival command.
pub fn onArrival(lParam: win32.LPARAM) void {
    const arrival = link.take(lParam) orelse return;
    switch (arrival.event) {
        .notice => |notice| onNotice(notice),
        .message => |message| onMessage(message),
        .lost => end(if (g_screen == .connecting) "Couldn't reach the game relay." else "The connection was lost."),
    }
}

pub fn show(context: *ui.Frame) !void {
    if (!g_is_open) return;
    update(context);
    // Only the lobby and the field need more than a prompt's width.
    const panel_style: *const ui.Style = switch (g_screen) {
        .menu, .connecting, .ended => &style.modal,
        .lobby, .playing => &style.barrage_panel,
    };
    const dialog = widgets.modal(.src(@src()), &g_is_open, panel_style);
    _ = try dialog.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Barrage", .style = &style.heading });
    switch (g_screen) {
        .menu => try menu(context),
        .connecting => try connecting(context),
        .lobby => try lobby(context),
        .playing => try playing(context),
        .ended => try ended(context),
    }
    try dialog.close(context);
    // Escape or a click outside closed it.
    if (!g_is_open) close();
}

fn close() void {
    leave();
    g_is_open = false;
    host.stopAnimation();
}

/// Back to the menu, dropping any connection.
fn leave() void {
    link.close();
    g_screen = .menu;
}

fn end(reason: []const u8) void {
    link.close();
    g_ended_reason = reason;
    g_screen = .ended;
    slog.info("Barrage session ended: {s}", .{reason});
}

fn connect(target: link.Target) void {
    const app = session.runningApp();
    const timer_hwnd = app.timer_hwnd orelse {
        slog.err("Failed to connect to the game relay: the timer window is missing", .{});
        end("Couldn't reach the game relay.");
        return;
    };
    link.open(app.io, timer_hwnd, @backingInt(host.Command.barrage_arrival), target) catch |err| {
        slog.err("Failed to connect to the game relay: {}", .{err});
        end("Couldn't reach the game relay.");
        return;
    };
    g_mode = switch (target) {
        .host => .host,
        .join => .guest,
    };
    g_screen = .connecting;
}

/// The host or practice player in seat 0, every other seat empty or, in practice, one AI.
fn openLobby(mode: Mode) void {
    g_mode = mode;
    g_lobby = .{ .seats = @splat(.empty), .round_count = ROUND_CHOICES[1] };
    g_lobby.seats[0] = .human;
    if (mode == .practice) g_lobby.seats[1] = .ai_normal;
    g_has_lobby = true;
    g_lobby_error = "";
    takeSeat(0);
    g_screen = .lobby;
}

/// Forgets everyone else's name and style.
fn takeSeat(seat: wire.Seat) void {
    g_my_seat = seat;
    g_names = @splat(.{});
    g_names[seat] = g_my_name;
    g_tank_styles = defaultTankStyles();
    g_tank_styles[seat] = g_my_tank_style;
    g_is_pilot_unsent = true;
}

fn onNotice(notice: wire.Notice) void {
    switch (notice) {
        .code => |code| {
            g_host_code = code;
            openLobby(.host);
        },
        .welcome => |seat| {
            takeSeat(seat);
            g_has_lobby = false;
            g_screen = .lobby;
        },
        .joined => |seat| {
            if (g_mode != .host or g_screen != .lobby) return;
            g_lobby.seats[seat] = .human;
            sendLobby();
            // The newcomer missed every pilot's choices sent before it joined.
            for (g_lobby.seats, 0..) |kind, pilot_seat| {
                if (kind == .human and pilot_seat != seat) send(.{ .pilot = pilotAt(@intCast(pilot_seat)) });
            }
        },
        .left => |seat| switch (g_screen) {
            .lobby => {
                g_names[seat] = .{};
                g_tank_styles[seat] = defaultTankStyles()[seat];
                if (g_mode != .host) return;
                g_lobby.seats[seat] = .empty;
                sendLobby();
            },
            .playing => {
                slog.info("Barrage pilot in seat {d} left; the AI takes over", .{seat});
                g_game.handToAi(seat);
            },
            .menu, .connecting, .ended => {},
        },
        .waiting => {},
        .host_left => end("The host left."),
        .refused => |refusal| end(switch (refusal) {
            .not_found => "No one is hosting that code. It may have expired, or the host may have left.",
            .full => "That match already has six pilots.",
            .started => "That match has already started.",
            .version => "The host runs a different version of EVE-Maj Preview.",
            .rate_limited => "Too many attempts. Wait a minute and try again.",
            .expired => "The match didn't start within 10 minutes, so the code expired.",
            .unknown => "The game relay turned the connection away.",
        }),
    }
}

fn onMessage(message: wire.Message) void {
    const decoded = messages.decode(message.slice()) catch |err| {
        slog.warn("Failed to read a Barrage message from seat {d}: {}", .{ message.sender, err });
        return;
    };
    switch (decoded) {
        .keepalive => {},
        .lobby => |received| {
            if (message.sender != 0 or g_mode != .guest or g_screen != .lobby) return;
            g_lobby = received;
            g_has_lobby = true;
        },
        .start => |start| {
            if (message.sender != 0 or g_mode != .guest or g_screen != .lobby) return;
            beginMatch(start);
        },
        .pilot => |pilot| {
            if (g_screen != .lobby and g_screen != .playing) return;
            if (pilot.seat == g_my_seat) return;
            if (message.sender != pilot.seat and message.sender != 0) return;
            g_names[pilot.seat] = pilot.name;
            g_tank_styles[pilot.seat] = pilot.tank_style;
        },
        .aim, .fired, .next_round, .restart => {
            if (g_screen != .playing) return;
            if (g_pending_count == MAX_PENDING) {
                slog.warn("Failed to keep a Barrage message from seat {d}: too many are waiting", .{message.sender});
                return;
            }
            g_pending[g_pending_count] = .{ .sender = message.sender, .message = decoded };
            g_pending_count += 1;
            applyPending();
        },
    }
}

/// In arrival order, each as soon as this machine's game has caught up with it.
fn applyPending() void {
    var index: usize = 0;
    while (index < g_pending_count) {
        switch (apply(g_pending[index])) {
            .later => index += 1,
            .applied, .stale => {
                std.mem.copyForwards(Pending, g_pending[index .. g_pending_count - 1], g_pending[index + 1 .. g_pending_count]);
                g_pending_count -= 1;
            },
        }
    }
}

fn apply(pending: Pending) Outcome {
    switch (pending.message) {
        .aim => |aim| {
            if (!isTurnOf(pending.sender, aim)) return .stale;
            g_game.aimRemote(aim.shot, aim.weapon);
            return .applied;
        },
        .fired => |fired| {
            const aim = fired.aim;
            if (aim.round < g_game.round or (aim.round == g_game.round and aim.turn < g_game.turn)) return .stale;
            if (!isTurnOf(pending.sender, aim)) return .later;
            const state_hash = g_game.stateHash();
            if (state_hash != fired.state_hash) slog.warn("Barrage is out of step with seat {d} in round {d}, turn {d}", .{ pending.sender, aim.round, aim.turn });
            g_game.fireRemote(aim.shot, aim.weapon);
            return .applied;
        },
        .next_round => |round| {
            if (pending.sender != 0 or round < g_game.round) return .stale;
            if (round > g_game.round or g_game.phase != .round_over) return .later;
            g_game.nextRound();
            return .applied;
        },
        .restart => {
            if (pending.sender != 0) return .stale;
            if (g_game.phase != .match_over) return .later;
            g_game.restart();
            return .applied;
        },
        .keepalive, .lobby, .start, .pilot => return .stale,
    }
}

/// Whether `sender`'s tank is waiting on its shot in the turn `aim` was taken in.
fn isTurnOf(sender: wire.Seat, aim: messages.Aim) bool {
    return g_game.isAwaitingRemote() and g_game.currentTank().seat == sender and aim.round == g_game.round and aim.turn == g_game.turn;
}

/// Builds the match every player in the lobby builds from the same start.
fn beginMatch(start: messages.Start) void {
    var players: [game.MAX_TANKS]game.Player = undefined;
    var player_count: usize = 0;
    for (start.lobby.seats, 0..) |seat, index| {
        const controller: game.Controller = switch (seat) {
            .empty => continue,
            .human => if (index == g_my_seat) .human else .remote,
            .ai_easy => .ai_easy,
            .ai_normal => .ai_normal,
            .ai_hard => .ai_hard,
        };
        players[player_count] = .{ .seat = @intCast(index), .controller = controller };
        player_count += 1;
    }
    if (player_count < 2) {
        slog.warn("Failed to start a Barrage match: only {d} seats are filled", .{player_count});
        end("The host started a match without enough players.");
        return;
    }
    g_game = .init(players[0..player_count], start.lobby.round_count, start.seed);
    g_pending_count = 0;
    g_last_sent_aim = null;
    g_weapon_step = 0;
    g_turn_mark = null;
    g_screen = .playing;
    slog.info("Barrage match started with {d} tanks", .{player_count});
}

/// The host's or practice player's Start.
fn startMatch() void {
    var filled: usize = 0;
    for (g_lobby.seats) |seat| {
        if (seat != .empty) filled += 1;
    }
    if (filled < 2) {
        g_lobby_error = "Fill at least two seats, with pilots or the AI.";
        return;
    }
    var seed: [8]u8 = undefined;
    session.runningApp().io.random(&seed);
    const start: messages.Start = .{ .seed = std.mem.readInt(u64, &seed, .little), .lobby = g_lobby };
    if (g_mode == .host) {
        link.lock();
        send(.{ .start = start });
    }
    beginMatch(start);
}

fn send(message: messages.Message) void {
    const encoded = messages.encode(message);
    link.send(encoded.slice());
    g_last_sent_ms = g_last_frame_ms;
}

fn sendLobby() void {
    send(.{ .lobby = g_lobby });
}

fn isOnline() bool {
    return switch (g_mode) {
        .practice => false,
        .host, .guest => true,
    };
}

fn isLocalTurn() bool {
    return g_game.phase == .aiming and g_game.currentTank().controller == .human;
}

/// Advances the game by the time since the last frame and keeps the other players informed.
fn update(context: *ui.Frame) void {
    const now_ms = context.ui().input.now_ms;
    const elapsed_ms = if (g_last_frame_ms == 0) 0 else now_ms - g_last_frame_ms;
    g_last_frame_ms = now_ms;
    switch (g_screen) {
        .playing => {
            const was_local_turn = isLocalTurn();
            g_game.step(@as(f32, @floatFromInt(@max(elapsed_ms, 0))) / 1000, control(context));
            applyPending();
            if (isOnline() and was_local_turn) {
                if (g_game.phase == .resolving) sendFired() else sendAim(now_ms);
            }
            noticeTurn(now_ms);
        },
        .menu, .connecting, .lobby, .ended => {},
    }
    const is_connected = switch (g_screen) {
        .lobby, .playing => isOnline(),
        .menu, .connecting, .ended => false,
    };
    if (!is_connected) return;
    if (g_is_pilot_unsent and now_ms - g_last_pilot_sent_ms >= PILOT_SEND_INTERVAL_MS) {
        send(.{ .pilot = pilotAt(g_my_seat) });
        g_last_pilot_sent_ms = now_ms;
        g_is_pilot_unsent = false;
    }
    if (now_ms - g_last_sent_ms >= KEEPALIVE_INTERVAL_MS) send(.keepalive);
}

/// Starts the turn marker's pulse when a tank's turn begins.
fn noticeTurn(now_ms: i64) void {
    if (g_game.phase != .aiming) return;
    const mark: TurnMark = .{ .round = g_game.round, .turn = g_game.turn, .current = g_game.current };
    if (g_turn_mark) |last| {
        if (std.meta.eql(last, mark)) return;
    }
    g_turn_mark = mark;
    g_turn_started_ms = now_ms;
}

fn sendFired() void {
    const fired = g_game.last_fired orelse return;
    send(.{ .fired = .{
        .aim = .{ .round = g_game.round, .turn = fired.turn, .shot = fired.shot, .weapon = fired.weapon },
        .state_hash = fired.state_hash,
    } });
    g_last_sent_aim = null;
}

/// At most every AIM_SEND_INTERVAL_MS, and only when the aim has changed.
fn sendAim(now_ms: i64) void {
    if (now_ms - g_last_aim_sent_ms < AIM_SEND_INTERVAL_MS) return;
    const tank = g_game.currentTank();
    const aim: messages.Aim = .{
        .round = g_game.round,
        .turn = g_game.turn,
        .shot = .{ .angle_degrees = tank.angle_degrees, .power = tank.power },
        .weapon = tank.weapon,
    };
    if (g_last_sent_aim) |last| {
        if (std.meta.eql(last, aim)) return;
    }
    send(.{ .aim = aim });
    g_last_aim_sent_ms = now_ms;
    g_last_sent_aim = aim;
}

/// Left and Right aim, Up and Down set the power, Shift slows both, Q/E, the weapon card's arrows or 1-8 pick the weapon, and Space fires.
fn control(context: *ui.Frame) game.Control {
    const input = &context.ui().input;
    var result: game.Control = .{ .is_fine = input.shift_held, .is_firing = input.keyPressed(.space), .weapon_step = g_weapon_step };
    g_weapon_step = 0;
    if (input.keyDown(.left)) result.turn += 1;
    if (input.keyDown(.right)) result.turn -= 1;
    if (input.keyDown(.up)) result.power += 1;
    if (input.keyDown(.down)) result.power -= 1;
    if (input.keyPressed(.q)) result.weapon_step -= 1;
    if (input.keyPressed(.e)) result.weapon_step += 1;
    if (input.keyPressed(.@"1")) result.choice = .shell;
    if (input.keyPressed(.@"2")) result.choice = .heavy_shell;
    if (input.keyPressed(.@"3")) result.choice = .cluster;
    if (input.keyPressed(.@"4")) result.choice = .roller;
    if (input.keyPressed(.@"5")) result.choice = .digger;
    if (input.keyPressed(.@"6")) result.choice = .napalm;
    if (input.keyPressed(.@"7")) result.choice = .megaton;
    if (input.keyPressed(.@"8")) result.choice = .dirt_clod;
    return result;
}

fn menu(context: *ui.Frame) !void {
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Fight up to five other pilots with a join code, or practise against the AI. Other pilots see only the name you give, never your address."), .style = &style.modal_text });
    const join_row = try widgets.openModalRow(context, .src(@src()), "Join code");
    if (g_should_focus_code) {
        try widgets.focusTextInput(context, CODE_INPUT_KEY, g_code_text.items.len);
        g_should_focus_code = false;
    }
    try context.e(TextInput{ .key = CODE_INPUT_KEY, .buf = &g_code_text, .placeholder = "ABC123", .bytes_max = 16, .style = &style.barrage_code_input });
    const is_join_clicked = (try context.interact(Button{ .key = .src(@src()), .label = lang.text("Join"), .style = &style.outline_button })).clicked;
    try join_row.close(context);
    const is_entered = context.ui().state.focused == CODE_INPUT_KEY.hash() and context.ui().input.keyPressed(.enter);
    if (is_join_clicked or is_entered) {
        join();
        context.requestRedraw();
    }
    if (g_code_error.len > 0) try widgets.boxedText(context, .src(@src()), g_code_error, &style.modal_hint_box, &style.field_error);

    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Cancel"), .style = &style.plain_button })).clicked) g_is_open = false;
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Practice"), .style = &style.outline_button })).clicked) {
        openLobby(.practice);
        context.requestRedraw();
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Host Game"), .style = &style.primary_button })).clicked) {
        connect(.host);
        context.requestRedraw();
    }
    try actions.close(context);
}

fn join() void {
    const code = wire.normalizeCode(g_code_text.items) catch {
        slog.info("Rejected Barrage join code '{s}'", .{g_code_text.items});
        g_code_error = "A join code is 6 letters and digits.";
        return;
    };
    g_code_error = "";
    connect(.{ .join = code });
}

fn connecting(context: *ui.Frame) !void {
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Connecting to the game relay..."), .style = &style.modal_text });
    try leaveButton(context, "Cancel");
}

fn lobby(context: *ui.Frame) !void {
    const arena = context.arena();
    if (g_mode == .host) try hostCode(context);
    try nameRow(context);
    try tankStyleRow(context);
    if (!g_has_lobby) {
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Joined. Waiting for the host's lobby..."), .style = &style.modal_text });
        try leaveButton(context, "Leave");
        return;
    }
    const is_editable = g_mode != .guest;
    for (&g_lobby.seats, 0..) |*seat, index| {
        const row = Rect{ .key = ui.Key.str("knots.barrage.seat").indexed(index), .style = &style.barrage_row };
        _ = try row.open(context);
        try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.barrage.seat_name").indexed(index), .content = try playerName(arena, @intCast(index)), .style = try seatNameStyle(arena, @intCast(index), &style.barrage_seat_label) });
        const label = lang.text(seatLabel(seat.*, @intCast(index)));
        const is_cyclable = is_editable and seat.* != .human;
        if (is_cyclable) {
            if ((try context.interact(Button{ .key = ui.Key.str("knots.barrage.seat_choice").indexed(index), .label = label, .style = &style.barrage_choice })).clicked) {
                seat.* = nextSeatKind(seat.*);
                g_lobby_error = "";
                if (g_mode == .host) sendLobby();
            }
        } else {
            try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.barrage.seat_fixed").indexed(index), .content = label, .style = &style.barrage_value });
        }
        try row.close(context);
    }
    const rounds_row = Rect{ .key = .src(@src()), .style = &style.barrage_row };
    _ = try rounds_row.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Rounds"), .style = &style.barrage_seat_label });
    const rounds_label = try std.fmt.allocPrint(arena, "{d}", .{g_lobby.round_count});
    if (is_editable) {
        if ((try context.interact(Button{ .key = .src(@src()), .label = rounds_label, .style = &style.barrage_choice })).clicked) {
            g_lobby.round_count = nextRoundCount(g_lobby.round_count);
            if (g_mode == .host) sendLobby();
        }
    } else {
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = rounds_label, .style = &style.barrage_value });
    }
    try rounds_row.close(context);

    if (g_lobby_error.len > 0) try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text(g_lobby_error), .style = &style.status_failure });
    const hint = switch (g_mode) {
        .practice => "Click a seat to give it to the AI or leave it empty.",
        .host => "Pilots who join take the next free seat. Click any other seat to give it to the AI or leave it empty.",
        .guest => "Waiting for the host to start the match.",
    };
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text(hint), .style = &style.hint });
    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Leave"), .style = &style.outline_button })).clicked) {
        leave();
        context.requestRedraw();
    }
    if (is_editable and (try context.interact(Button{ .key = .src(@src()), .label = lang.text("Start"), .style = &style.primary_button })).clicked) {
        startMatch();
        context.requestRedraw();
    }
    try actions.close(context);
}

/// Picked from the profile's characters, so no one can type a name; the first choice is the seat's default.
fn nameRow(context: *ui.Frame) !void {
    const arena = context.arena();
    const characters = session.profile().ptr.characters.items;
    const choices = try arena.alloc(PilotName, characters.len + 1);
    const labels = try arena.alloc([]const u8, characters.len + 1);
    choices[0] = .{};
    labels[0] = try defaultName(arena, g_my_seat);
    var count: usize = 1;
    var current: u32 = 0;
    for (characters) |character| {
        // A roster entry no pilot name can hold, e.g. one added by hand, just isn't offered.
        const name = PilotName.fromText(character.name) catch |err| switch (err) {
            error.NameTooLong, error.InvalidName => continue,
        };
        if (name.length == 0 or isListed(choices[1..count], name)) continue;
        if (name.eql(&g_my_name)) current = @intCast(count);
        choices[count] = name;
        labels[count] = choices[count].slice();
        count += 1;
    }
    // Gone from the roster, e.g. on a profile switch.
    if (current == 0 and g_my_name.length > 0) chooseName(.{});
    const values = try arena.alloc(u32, count);
    for (values, 0..) |*value, index| value.* = @intCast(index);

    const row = Rect{ .key = .src(@src()), .style = &style.barrage_row };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Your name"), .style = &style.barrage_seat_label });
    // The dropdown keeps its own selection; while closed it follows the chosen name, which the roster may have dropped.
    if (context.ui().state.get(.select_input, NAME_SELECT_KEY.hash())) |state| {
        if (!state.open) state.selected = current;
    }
    const response = try context.interact(SelectInput(u32){
        .key = NAME_SELECT_KEY,
        .labels = labels[0..count],
        .values = values,
        .initial_selected = current,
        .style = try widgets.fittedSelect(context, labels[0..count]),
        .parts = .{ .popup = &style.select_popup },
    });
    try row.close(context);
    if (response.selected) |selected| chooseName(choices[selected.value]);
}

fn isListed(names: []const PilotName, name: PilotName) bool {
    for (names) |listed| {
        if (listed.eql(&name)) return true;
    }
    return false;
}

fn chooseName(name: PilotName) void {
    if (name.eql(&g_my_name)) return;
    g_my_name = name;
    g_names[g_my_seat] = name;
    g_is_pilot_unsent = true;
}

/// Every style, drawn in this pilot's colour; clicking one picks it.
fn tankStyleRow(context: *ui.Frame) !void {
    const arena = context.arena();
    const row = Rect{ .key = .src(@src()), .style = &style.barrage_row };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Your tank"), .style = &style.barrage_seat_label });
    const options = Rect{ .key = .src(@src()), .style = &style.barrage_tank_options };
    _ = try options.open(context);
    const color = style.BARRAGE_PLAYER_COLORS[g_my_seat].value;
    for (std.enums.values(TankStyle), 0..) |tank_style, index| {
        const is_chosen = tank_style == g_my_tank_style;
        const button = Button{ .key = ui.Key.str("knots.barrage.tank_style").indexed(index), .style = if (is_chosen) &style.barrage_tank_option_chosen else &style.barrage_tank_option };
        const response = try button.openResponse(context);
        const preview_key = ui.Key.str("knots.barrage.tank_preview").indexed(index);
        var painter: Painter = .{ .arena = arena, .origin = try glyphs.snapOffset(context, preview_key), .height = PREVIEW_HEIGHT, .scale = PREVIEW_SCALE };
        try barrage_tanks.drawTank(&painter, tank_style, PREVIEW_WIDTH / 2, PREVIEW_GROUND, PREVIEW_ANGLE_DEGREES, color, true);
        try painter.line(.{ 0, PREVIEW_GROUND }, .{ PREVIEW_WIDTH, PREVIEW_GROUND }, 0.5, style.BARRAGE_GROUND.value);
        try context.e(Canvas{ .key = preview_key, .commands = painter.commands.items, .style = &style.barrage_tank_preview });
        try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.barrage.tank_style_name").indexed(index), .content = lang.text(barrage_tanks.styleName(tank_style)), .style = &style.barrage_wins });
        try button.close(context);
        if (response.clicked and !is_chosen) {
            g_my_tank_style = tank_style;
            g_tank_styles[g_my_seat] = tank_style;
            g_is_pilot_unsent = true;
        }
    }
    try options.close(context);
    try row.close(context);
}

fn pilotAt(seat: wire.Seat) messages.Pilot {
    return .{ .seat = seat, .tank_style = g_tank_styles[seat], .name = g_names[seat] };
}

/// Each seat its own, so AI tanks differ.
fn defaultTankStyles() [wire.MAX_SEATS]TankStyle {
    var styles: [wire.MAX_SEATS]TankStyle = undefined;
    const all = std.enums.values(TankStyle);
    for (&styles, 0..) |*tank_style, seat| tank_style.* = all[seat % all.len];
    return styles;
}

fn hostCode(context: *ui.Frame) !void {
    const row = Rect{ .key = .src(@src()), .style = &style.barrage_actions };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Join code:"), .style = &style.modal_text_inline });
    try context.e(Text{ .key = .src(@src()), .content = &g_host_code, .style = &style.barrage_code });
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Copy"), .style = &style.outline_button })).clicked) {
        context.writeClipboard(&g_host_code) catch |err| {
            slog.warn("Failed to copy the Barrage join code: {}", .{err});
        };
    }
    try row.close(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Up to five pilots can join with it until you start. It expires if the match hasn't started within 10 minutes."), .style = &style.hint });
}

fn leaveButton(context: *ui.Frame, comptime label: []const u8) !void {
    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text(label), .style = &style.outline_button })).clicked) {
        leave();
        context.requestRedraw();
    }
    try actions.close(context);
}

fn playing(context: *ui.Frame) !void {
    try field(context);
    try standings(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("\u{2190} \u{2192} aim  \u{00B7}  \u{2191} \u{2193} power (hold Shift for fine steps)  \u{00B7}  Space fires"), .style = &style.hint });
    const actions = Rect{ .key = .src(@src()), .style = &style.barrage_actions };
    _ = try actions.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try lang.format(context.arena(), "Round {round} of {rounds}", .{ .round = g_game.round, .rounds = g_game.round_count }), .style = &style.barrage_status });
    const is_deciding = g_mode != .guest;
    switch (g_game.phase) {
        .round_over => if (is_deciding and (try context.interact(Button{ .key = .src(@src()), .label = lang.text("Next Round"), .style = &style.primary_button })).clicked) {
            if (g_mode == .host) send(.{ .next_round = g_game.round });
            g_game.nextRound();
            context.requestRedraw();
        },
        .match_over => if (is_deciding and (try context.interact(Button{ .key = .src(@src()), .label = lang.text("Play Again"), .style = &style.primary_button })).clicked) {
            if (g_mode == .host) send(.restart);
            g_game.restart();
            context.requestRedraw();
        },
        .aiming, .resolving => {},
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Leave"), .style = &style.outline_button })).clicked) {
        leave();
        context.requestRedraw();
    }
    try actions.close(context);
}

/// Whose turn it is and their aim, over the field's top-left.
fn aimCard(context: *ui.Frame) !void {
    const arena = context.arena();
    const tank = g_game.currentTank();
    const card = Rect{ .key = .src(@src()), .style = &style.barrage_aim_card };
    _ = try card.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try playerName(arena, tank.seat), .style = try seatNameStyle(arena, tank.seat, &style.barrage_name) });
    const status = switch (g_game.phase) {
        .aiming => switch (tank.controller) {
            .human => "Your turn",
            .remote => "Aiming...",
            .ai_easy, .ai_normal, .ai_hard => "The AI is aiming...",
        },
        .resolving => "Shot away",
        .round_over => "Round over",
        .match_over => "Match over",
    };
    const status_style = if (isLocalTurn()) try seatNameStyle(arena, tank.seat, &style.barrage_card_status) else &style.barrage_card_status;
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text(status), .style = status_style });

    const angle_line = Rect{ .key = .src(@src()), .style = &style.barrage_card_line };
    _ = try angle_line.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Angle"), .style = &style.barrage_card_label });
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try std.fmt.allocPrint(arena, "{d}\u{00B0}", .{wholeNumber(tank.angle_degrees)}), .style = &style.barrage_value });
    try angle_line.close(context);

    const power_line = Rect{ .key = .src(@src()), .style = &style.barrage_card_line };
    _ = try power_line.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Power"), .style = &style.barrage_card_label });
    const track = Rect{ .key = .src(@src()), .style = &style.barrage_power_track };
    _ = try track.open(context);
    const fill_style = try arena.create(ui.Style);
    fill_style.* = style.barrage_power_fill.with(.{
        .width = .fixed(style.BARRAGE_POWER_TRACK_WIDTH * tank.power / game.MAX_POWER),
        .background = .{ .color = style.BARRAGE_PLAYER_COLORS[tank.seat] },
    });
    try context.e(Rect{ .key = .src(@src()), .style = fill_style });
    try track.close(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try std.fmt.allocPrint(arena, "{d}", .{wholeNumber(tank.power)}), .style = &style.barrage_value });
    try power_line.close(context);
    try card.close(context);
}

/// "◀ 12" for wind blowing left, "12 ▶" right, or "calm".
fn windText(arena: std.mem.Allocator) ![]const u8 {
    const strength = wholeNumber(@abs(g_game.wind));
    if (strength == 0) return lang.text("calm");
    if (g_game.wind < 0) return std.fmt.allocPrint(arena, "\u{25C0} {d}", .{strength});
    return std.fmt.allocPrint(arena, "{d} \u{25B6}", .{strength});
}

/// The weapon in use and its ammo, over the field's top-right; its arrows step through the weapons on this pilot's turn.
fn weaponCard(context: *ui.Frame) !void {
    const arena = context.arena();
    const tank = g_game.currentTank();
    // Sized for the longest name and the most ammo, so the arrows stay put.
    var name_width: f32 = 0;
    var ammo_width: f32 = 0;
    for (std.enums.values(game.Weapon)) |weapon| {
        name_width = @max(name_width, try widgets.textWidth(context, lang.text(weaponName(weapon)), &style.barrage_weapon_name));
        ammo_width = @max(ammo_width, try widgets.textWidth(context, try ammoText(arena, game.spec(weapon).ammo), &style.barrage_card_hint));
    }
    const name_style = try arena.create(ui.Style);
    name_style.* = style.barrage_weapon_name.with(.{ .width = .fixed(@ceil(name_width)) });
    const ammo_style = try arena.create(ui.Style);
    ammo_style.* = style.barrage_card_hint.with(.{ .width = .fixed(@ceil(ammo_width)) });

    const dock = Rect{ .key = .src(@src()), .style = &style.barrage_weapon_dock };
    _ = try dock.open(context);
    const card = Rect{ .key = .src(@src()), .style = &style.barrage_weapon_card };
    _ = try card.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Q", .style = &style.barrage_card_hint });
    if ((try context.interact(Button{ .key = .src(@src()), .label = "\u{25C0}", .style = &style.barrage_weapon_arrow })).clicked and isLocalTurn()) g_weapon_step = -1;
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text(weaponName(tank.weapon)), .style = name_style });
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try ammoText(arena, tank.ammoLeft(tank.weapon)), .style = ammo_style });
    if ((try context.interact(Button{ .key = .src(@src()), .label = "\u{25B6}", .style = &style.barrage_weapon_arrow })).clicked and isLocalTurn()) g_weapon_step = 1;
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "E", .style = &style.barrage_card_hint });
    try card.close(context);
    try dock.close(context);
}

/// "×3", or "∞" for unlimited.
fn ammoText(arena: std.mem.Allocator, ammo: ?u8) ![]const u8 {
    const count = ammo orelse return "\u{221E}";
    return std.fmt.allocPrint(arena, "\u{00D7}{d}", .{count});
}

/// Each tank's name, health and round wins, this pilot's marked when online.
fn standings(context: *ui.Frame) !void {
    const rows = Rect{ .key = .src(@src()), .style = &style.barrage_standings };
    _ = try rows.open(context);
    const tanks = g_game.matchTanks();
    var row_start: usize = 0;
    while (row_start < tanks.len) : (row_start += STANDINGS_PER_ROW) {
        const row = Rect{ .key = ui.Key.str("knots.barrage.standings_row").indexed(row_start), .style = &style.barrage_standings_row };
        _ = try row.open(context);
        for (row_start..@min(row_start + STANDINGS_PER_ROW, tanks.len)) |index| try standing(context, tanks[index], index);
        try row.close(context);
    }
    try rows.close(context);
}

fn standing(context: *ui.Frame, tank: game.Tank, index: usize) !void {
    const arena = context.arena();
    const column = Rect{ .key = ui.Key.str("knots.barrage.standing").indexed(index), .style = &style.barrage_standing };
    _ = try column.open(context);
    const name = try playerName(arena, tank.seat);
    const is_mine = isOnline() and tank.controller == .human;
    const label = if (is_mine) try std.fmt.allocPrint(arena, "{s} ({s})", .{ name, lang.text("you") }) else name;
    const name_style = if (tank.isAlive()) try seatNameStyle(arena, tank.seat, &style.barrage_name) else &style.barrage_name_out;
    try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.barrage.standing_name").indexed(index), .content = label, .style = name_style });

    const line = Rect{ .key = ui.Key.str("knots.barrage.standing_line").indexed(index), .style = &style.barrage_standing_line };
    _ = try line.open(context);
    const track = Rect{ .key = ui.Key.str("knots.barrage.standing_track").indexed(index), .style = &style.barrage_health_track };
    _ = try track.open(context);
    const fill_style = try arena.create(ui.Style);
    fill_style.* = style.barrage_health_fill.with(.{
        .width = .fixed(style.BARRAGE_HEALTH_TRACK_WIDTH * tank.health / game.MAX_HEALTH),
        .background = .{ .color = style.BARRAGE_PLAYER_COLORS[tank.seat] },
    });
    try context.e(Rect{ .key = ui.Key.str("knots.barrage.standing_fill").indexed(index), .style = fill_style });
    try track.close(context);
    const wins = try lang.format(arena, "{wins} won", .{ .wins = tank.wins });
    try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.barrage.standing_wins").indexed(index), .content = wins, .style = &style.barrage_wins });
    try line.close(context);
    try column.close(context);
}

fn ended(context: *ui.Frame) !void {
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text(g_ended_reason), .style = &style.modal_text });
    try leaveButton(context, "Back");
}

/// The field, with the wind over its arrow, the aim and weapons in the top corners, and a round's result over the middle.
fn field(context: *ui.Frame) !void {
    const arena = context.arena();
    const snap = try glyphs.snapOffset(context, CANVAS_KEY);
    var painter: Painter = .{ .arena = arena, .origin = snap, .height = game.FIELD_HEIGHT };
    try painter.commands.append(arena, .{ .fill_rect = .{ .x = snap[0], .y = snap[1], .w = game.FIELD_WIDTH, .h = game.FIELD_HEIGHT, .color = style.CHROME.value } });
    try ground(&painter);
    try fires(&painter);
    try windArrow(&painter);
    const turn_age_ms = g_last_frame_ms - g_turn_started_ms;
    for (g_game.matchTanks(), 0..) |tank, index| {
        const is_marked = index == g_game.current and g_game.phase == .aiming;
        try drawTank(&painter, tank, if (is_marked) turn_age_ms else null);
    }
    for (g_game.liveProjectiles()) |projectile| {
        const trail = projectile.trailPoints();
        for (trail, 0..) |point, index| {
            if (index == 0) continue;
            var color = style.TEXT.value;
            color[3] = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(trail.len));
            try painter.line(trail[index - 1], point, 1.5, color);
        }
        try painter.ring(.{ projectile.flight.x, projectile.flight.y }, SHELL_DRAWN_RADIUS, style.TEXT.value);
    }
    for (g_game.liveExplosions()) |explosion| {
        const progress = explosion.age_seconds / game.EXPLOSION_SECONDS;
        var color = if (explosion.adds_dirt) style.BARRAGE_GROUND.value else style.DESTRUCTIVE.value;
        color[3] = 1 - progress;
        const radius = explosion.radius * @min(1, progress * 3);
        try painter.ring(.{ explosion.x, explosion.y }, radius, color);
        try painter.ring(.{ explosion.x, explosion.y }, radius * 0.6, color);
    }
    try painter.commands.append(arena, .{ .stroke_rect = .{ .x = snap[0], .y = snap[1], .w = game.FIELD_WIDTH, .h = game.FIELD_HEIGHT, .color = style.BORDER.value } });
    const field_style = try arena.create(ui.Style);
    field_style.* = .{ .width = .fixed(game.FIELD_WIDTH), .height = .fixed(game.FIELD_HEIGHT) };
    const canvas = Canvas{ .key = CANVAS_KEY, .commands = painter.commands.items, .style = field_style };
    _ = try canvas.open(context);
    const wind_label = Rect{ .key = .src(@src()), .style = &style.barrage_wind_label };
    _ = try wind_label.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try lang.format(arena, "Wind {wind}", .{ .wind = try windText(arena) }), .style = &style.barrage_wind_text });
    try wind_label.close(context);
    try aimCard(context);
    try weaponCard(context);
    try banner(context);
    try canvas.close(context);
}

/// A round's or match's result, over the middle of the field.
fn banner(context: *ui.Frame) !void {
    const arena = context.arena();
    const winner: ?u8 = switch (g_game.phase) {
        .aiming, .resolving => return,
        .round_over => |round_winner| round_winner,
        .match_over => |match_winner| match_winner,
    };
    const is_match = g_game.phase == .match_over;
    const panel = Rect{ .key = .src(@src()), .style = &style.barrage_banner };
    _ = try panel.open(context);
    const title = if (winner) |index|
        try lang.format(arena, if (is_match) "{name} wins the match!" else "{name} wins the round", .{ .name = try playerName(arena, g_game.tanks[index].seat) })
    else
        lang.text(if (is_match) "The match is a draw" else "No tank survived");
    const title_style = if (winner) |index| try seatNameStyle(arena, g_game.tanks[index].seat, &style.barrage_banner_title) else &style.barrage_banner_title;
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = title, .style = title_style });
    const next = switch (g_mode) {
        .guest => "Waiting for the host...",
        .practice, .host => if (is_match) "Play again, or leave." else "Next Round when you're ready.",
    };
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text(next), .style = &style.barrage_banner_text });
    try panel.close(context);
}

/// The surface as a line, with hatching down to the field's bottom.
fn ground(painter: *Painter) !void {
    var column: usize = 0;
    while (column < game.FIELD_WIDTH - 1) : (column += GROUND_LINE_STEP) {
        const next = @min(column + GROUND_LINE_STEP, game.FIELD_WIDTH - 1);
        try painter.line(groundPoint(column), groundPoint(next), 1.5, style.BARRAGE_GROUND.value);
    }
    var hatch_color = style.BARRAGE_GROUND.value;
    hatch_color[3] = 0.3;
    column = HATCH_STEP / 2;
    while (column < game.FIELD_WIDTH) : (column += HATCH_STEP) {
        const top = groundPoint(column);
        if (top[1] > 0) try painter.line(.{ top[0], 0 }, top, 1, hatch_color);
    }
}

/// Napalm's flames, flickering along the ground.
fn fires(painter: *Painter) !void {
    const seconds = @as(f32, @floatFromInt(g_last_frame_ms)) / 1000;
    for (g_game.liveFires()) |fire_patch| {
        var offset: f32 = -game.FIRE_HALF_WIDTH;
        while (offset <= game.FIRE_HALF_WIDTH) : (offset += FLAME_STEP) {
            const x = fire_patch.x + offset;
            if (x < 0 or x >= game.FIELD_WIDTH) continue;
            const ground_y = g_game.groundAt(x);
            const height = FLAME_HEIGHT * (2 + @sin(seconds * 9 + offset)) / 3;
            try painter.line(.{ x, ground_y }, .{ x, ground_y + height }, 2, style.BARRAGE_FIRE.value);
        }
    }
}

fn groundPoint(column: usize) [2]f32 {
    return .{ @floatFromInt(column), g_game.heights[column] };
}

/// Under its label at the top of the field, as long as the wind is strong.
fn windArrow(painter: *Painter) !void {
    const centre = [2]f32{ game.FIELD_WIDTH / 2, game.FIELD_HEIGHT - WIND_ARROW_DROP };
    const length = g_game.wind / game.MAX_WIND * WIND_ARROW_LENGTH;
    if (@abs(length) < 4) return;
    const tip = [2]f32{ centre[0] + length / 2, centre[1] };
    const back: f32 = if (length > 0) -8 else 8;
    try painter.line(.{ centre[0] - length / 2, centre[1] }, tip, 2, style.MUTED.value);
    try painter.line(tip, .{ tip[0] + back, centre[1] + 6 }, 2, style.MUTED.value);
    try painter.line(tip, .{ tip[0] + back, centre[1] - 6 }, 2, style.MUTED.value);
}

/// In its pilot's style, with its health bar while it lives; `turn_age_ms` marks the tank to play, bobbing as its turn begins.
fn drawTank(painter: *Painter, tank: game.Tank, turn_age_ms: ?i64) !void {
    const is_alive = tank.isAlive();
    const color = if (is_alive) style.BARRAGE_PLAYER_COLORS[tank.seat].value else style.MUTED.value;
    try barrage_tanks.drawTank(painter, g_tank_styles[tank.seat], tank.x, tank.y, tank.angle_degrees, color, is_alive);
    if (!is_alive) return;
    const bar_y = tank.y + HEALTH_BAR_RISE;
    const bar_left = tank.x - HEALTH_BAR_WIDTH / 2;
    try painter.line(.{ bar_left, bar_y }, .{ bar_left + HEALTH_BAR_WIDTH, bar_y }, 3, style.BORDER.value);
    try painter.line(.{ bar_left, bar_y }, .{ bar_left + HEALTH_BAR_WIDTH * tank.health / game.MAX_HEALTH, bar_y }, 3, color);
    const age_ms = turn_age_ms orelse return;
    const seconds = @as(f32, @floatFromInt(age_ms)) / 1000;
    const bob: f32 = if (age_ms < TURN_PULSE_MS) @abs(@sin(seconds * 8)) * 6 else 0;
    const marker_y = bar_y + 8 + bob;
    try painter.outline(&.{ .{ tank.x - 6, marker_y + 10 }, .{ tank.x + 6, marker_y + 10 }, .{ tank.x, marker_y } }, color);
    if (age_ms >= TURN_RING_MS) return;
    const progress = @as(f32, @floatFromInt(age_ms)) / TURN_RING_MS;
    var ring_color = color;
    ring_color[3] = 1 - progress;
    try painter.ring(.{ tank.x, tank.y + game.TANK_HEIGHT }, 18 + 34 * progress, ring_color);
}

/// The seat's chosen name, which borrows from g_names, or its default made in `arena`.
fn playerName(arena: std.mem.Allocator, seat: u8) ![]const u8 {
    if (g_names[seat].length > 0) return g_names[seat].slice();
    return defaultName(arena, seat);
}

fn defaultName(arena: std.mem.Allocator, seat: u8) ![]const u8 {
    return lang.format(arena, "Player {number}", .{ .number = seat + 1 });
}

/// `base` in the seat's colour.
fn seatNameStyle(arena: std.mem.Allocator, seat: u8, base: *const ui.Style) !*const ui.Style {
    const name_style = try arena.create(ui.Style);
    name_style.* = base.with(.{ .foreground = .{ .color = style.BARRAGE_PLAYER_COLORS[seat] } });
    return name_style;
}

fn seatLabel(kind: SeatKind, seat: u8) []const u8 {
    return switch (kind) {
        .empty => "Empty",
        .human => if (seat == g_my_seat) "You" else "Pilot",
        .ai_easy => "AI: Easy",
        .ai_normal => "AI: Normal",
        .ai_hard => "AI: Hard",
    };
}

/// A seat a pilot doesn't hold cycles through empty and the AI's levels.
fn nextSeatKind(kind: SeatKind) SeatKind {
    return switch (kind) {
        .empty => .ai_easy,
        .ai_easy => .ai_normal,
        .ai_normal => .ai_hard,
        .ai_hard, .human => .empty,
    };
}

fn nextRoundCount(round_count: u8) u8 {
    for (ROUND_CHOICES, 0..) |choice, index| {
        if (choice == round_count) return ROUND_CHOICES[(index + 1) % ROUND_CHOICES.len];
    }
    return ROUND_CHOICES[0];
}

fn weaponName(weapon: game.Weapon) []const u8 {
    return switch (weapon) {
        .shell => "Shell",
        .heavy_shell => "Heavy Shell",
        .cluster => "Cluster",
        .roller => "Roller",
        .digger => "Digger",
        .napalm => "Napalm",
        .megaton => "Megaton",
        .dirt_clod => "Dirt Clod",
    };
}

fn wholeNumber(value: f32) i32 {
    return @intFromFloat(@round(value));
}
