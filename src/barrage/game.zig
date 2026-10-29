//! Barrage's rules: the terrain, turns, shells and their blasts, falling tanks, rounds, and the AI; no I/O.
const std = @import("std");

/// One ground column per unit.
pub const FIELD_WIDTH = 740;
pub const FIELD_HEIGHT: f32 = 520;
pub const MAX_TANKS = 6;
pub const MAX_HEALTH: f32 = 100;
pub const MAX_POWER: f32 = 100;
pub const TANK_HALF_WIDTH: f32 = 14;
pub const TANK_HEIGHT: f32 = 9;
pub const DOME_RADIUS: f32 = 6;
pub const BARREL_LENGTH: f32 = 20;
/// Sideways acceleration at its strongest, in units per second squared.
pub const MAX_WIND: f32 = 50;
pub const MAX_PROJECTILES = 8;
pub const MAX_EXPLOSIONS = 12;
pub const MAX_FIRES = 6;
/// Either side of where napalm lands.
pub const FIRE_HALF_WIDTH: f32 = 30;
pub const EXPLOSION_SECONDS: f32 = 0.6;
pub const TRAIL_POINTS = 32;
pub const WEAPON_COUNT = std.enums.values(Weapon).len;
const GRAVITY: f32 = 220;
/// Muzzle speed at full power, in units per second.
const MAX_SPEED: f32 = 520;
const STEP_SECONDS: f32 = 1.0 / 240.0;
/// Coarser than a real shell's; close enough to aim by, and cheap enough for hundreds of trial shots.
const AI_STEP_SECONDS: f32 = 1.0 / 120.0;
const AI_MAX_FLIGHT_SECONDS: f32 = 8;
const TRAIL_EVERY_STEPS = 4;
/// A shell can't hit the tank that fired it this soon, so it clears its own barrel.
const ARMING_SECONDS: f32 = 0.15;
const FALL_SPEED: f32 = 160;
const SAFE_FALL: f32 = 8;
const FALL_DAMAGE_PER_UNIT: f32 = 0.5;
const WRECK_BLAST_RADIUS: f32 = 22;
const WRECK_BLAST_DAMAGE: f32 = 20;
const CLUSTER_BOMBLETS = 5;
/// Sideways speed between neighbouring bomblets, in units per second.
const CLUSTER_SPREAD: f32 = 35;
/// A roller's speed along the ground, in units per second.
const ROLL_SPEED: f32 = 90;
const ROLL_SECONDS: f32 = 4;
/// The most the ground may rise from one column to the next before a roller stops against it.
const ROLL_MAX_RISE: f32 = 1.2;
/// How far either side a landing roller looks to find downhill.
const ROLL_PROBE: f32 = 6;
/// How far below the surface a digger goes off.
const DIG_DEPTH: f32 = 28;
/// Turn ends a napalm fire burns through.
const FIRE_BURNS = 4;
const FIRE_DAMAGE: f32 = 12;
/// Degrees, or power points, a second while a key is held, and while it's held with Shift.
const AIM_SPEED: f32 = 45;
const FINE_AIM_SPEED: f32 = 8;
const POWER_SPEED: f32 = 40;
const FINE_POWER_SPEED: f32 = 6;
const AI_AIM_SPEED: f32 = 90;
const AI_POWER_SPEED: f32 = 80;
const AI_MIN_THINK_SECONDS: f32 = 0.8;
/// Added to the miss of a trial shot that would land within its own blast.
const AI_SELF_HIT_PENALTY: f32 = 1000;
/// A round's wind starts within this share of MAX_WIND, leaving it room to drift.
const STARTING_WIND_SHARE: f32 = 0.5;
const WIND_DRIFT: f32 = 12;
const MIN_GROUND: f32 = 30;
const MAX_GROUND: f32 = FIELD_HEIGHT * 0.7;
/// Dirt piles no higher, so a mound never reaches the sky.
const MAX_DIRT: f32 = FIELD_HEIGHT - 40;
const EDGE_MARGIN: f32 = 24;
const TERRAIN_WAVES = 4;

/// `human` is played on this machine and `remote` on another, whose shots arrive through fireRemote.
pub const Controller = enum { human, remote, ai_easy, ai_normal, ai_hard };

pub const Weapon = enum { shell, heavy_shell, cluster, roller, digger, napalm, megaton, dirt_clod };

pub const WeaponSpec = struct {
    blast_radius: f32,
    damage: f32,
    /// Per round; null is unlimited.
    ammo: ?u8,
    /// Piles up earth rather than blasting it away.
    adds_dirt: bool = false,
};

/// Seat and controller of one tank in a new match.
pub const Player = struct {
    /// Which of the six seats, for the player's name and colour.
    seat: u8,
    controller: Controller,
};

pub const Tank = struct {
    seat: u8,
    controller: Controller,
    x: f32,
    /// Its tracks' height above the field's bottom.
    y: f32,
    health: f32 = MAX_HEALTH,
    /// 0 points right, 90 up and 180 left.
    angle_degrees: f32 = 90,
    power: f32 = 60,
    weapon: Weapon = .shell,
    /// Rounds left per weapon; ignored for those with unlimited ammo.
    ammo: [WEAPON_COUNT]u8 = @splat(0),
    wins: u8 = 0,
    /// Height it started falling from, while it falls.
    fall_from: ?f32 = null,

    pub fn isAlive(self: *const Tank) bool {
        return self.health > 0;
    }

    pub fn hasAmmo(self: *const Tank, weapon: Weapon) bool {
        return spec(weapon).ammo == null or self.ammo[@intFromEnum(weapon)] > 0;
    }

    /// Null for unlimited.
    pub fn ammoLeft(self: *const Tank, weapon: Weapon) ?u8 {
        if (spec(weapon).ammo == null) return null;
        return self.ammo[@intFromEnum(weapon)];
    }

    /// Where the barrel turns.
    pub fn pivot(self: *const Tank) [2]f32 {
        return .{ self.x, self.y + TANK_HEIGHT };
    }

    fn barrelTipAt(self: *const Tank, angle_degrees: f32) [2]f32 {
        const direction = unitVector(angle_degrees);
        const from = self.pivot();
        return .{ from[0] + direction[0] * BARREL_LENGTH, from[1] + direction[1] * BARREL_LENGTH };
    }

    /// The next weapon with ammo left in `direction`, -1 or 1; the shell always has some.
    fn nextWeapon(self: *const Tank, direction: i8) Weapon {
        var index: i32 = @intFromEnum(self.weapon);
        for (0..WEAPON_COUNT) |_| {
            index = @mod(index + direction, @as(i32, WEAPON_COUNT));
            const weapon: Weapon = @enumFromInt(index);
            if (self.hasAmmo(weapon)) return weapon;
        }
        return .shell;
    }
};

pub const Flight = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,

    fn launch(tank: *const Tank, angle_degrees: f32, power: f32) Flight {
        const tip = tank.barrelTipAt(angle_degrees);
        const direction = unitVector(angle_degrees);
        const speed = power / MAX_POWER * MAX_SPEED;
        return .{ .x = tip[0], .y = tip[1], .vx = direction[0] * speed, .vy = direction[1] * speed };
    }

    fn advance(self: *Flight, wind: f32, seconds: f32) void {
        self.vx += wind * seconds;
        self.vy -= GRAVITY * seconds;
        self.x += self.vx * seconds;
        self.y += self.vy * seconds;
    }

    fn isOffField(self: *const Flight) bool {
        return self.x < 0 or self.x >= FIELD_WIDTH;
    }
};

pub const Projectile = struct {
    flight: Flight,
    weapon: Weapon,
    is_bomblet: bool = false,
    /// A roller on the ground, moving at flight.vx.
    is_rolling: bool = false,
    roll_seconds: f32 = 0,
    /// Index of the tank that fired it.
    owner: u8,
    age_seconds: f32 = 0,
    steps: u32 = 0,
    trail: [TRAIL_POINTS][2]f32 = undefined,
    trail_count: u8 = 0,

    /// Oldest first; borrows from the projectile.
    pub fn trailPoints(self: *const Projectile) []const [2]f32 {
        return self.trail[0..self.trail_count];
    }

    fn addTrailPoint(self: *Projectile) void {
        if (self.trail_count == TRAIL_POINTS) {
            std.mem.copyForwards([2]f32, self.trail[0 .. TRAIL_POINTS - 1], self.trail[1..]);
            self.trail_count -= 1;
        }
        self.trail[self.trail_count] = .{ self.flight.x, self.flight.y };
        self.trail_count += 1;
    }
};

pub const Explosion = struct {
    x: f32,
    y: f32,
    radius: f32,
    age_seconds: f32 = 0,
    adds_dirt: bool,
};

/// Napalm's flames, hurting every tank in them at each turn's end.
pub const Fire = struct {
    x: f32,
    burns_left: u8,
};

pub const Phase = union(enum) {
    aiming,
    /// Shells in the air, blasts fading or tanks falling.
    resolving,
    /// The round winner's index, or null when no one survived.
    round_over: ?u8,
    /// The index of the tank with the most round wins, or null for a tie.
    match_over: ?u8,
};

/// One frame of the current human player's keys.
pub const Control = struct {
    /// Positive turns the barrel left.
    turn: f32 = 0,
    power: f32 = 0,
    is_fine: bool = false,
    /// -1 or 1 steps through the weapons with ammo left.
    weapon_step: i8 = 0,
    choice: ?Weapon = null,
    is_firing: bool = false,
};

pub const Shot = struct {
    angle_degrees: f32,
    power: f32,
};

/// What the last shot was fired with, for passing on to other players.
pub const Fired = struct {
    shot: Shot,
    weapon: Weapon,
    /// Game.turn as it was fired.
    turn: u16,
    /// stateHash just before it was fired.
    state_hash: u32,
};

const AiPlan = struct {
    shot: Shot,
    waited_seconds: f32 = 0,
};

pub const Game = struct {
    prng: std.Random.DefaultPrng,
    /// Ground height above the field's bottom, per column.
    heights: [FIELD_WIDTH]f32 = undefined,
    tanks: [MAX_TANKS]Tank = undefined,
    tank_count: u8,
    /// Index of the tank whose turn it is.
    current: u8 = 0,
    round: u8 = 1,
    round_count: u8,
    /// Shots fired this round, so a shot from another player can't land in the wrong turn.
    turn: u16 = 0,
    wind: f32 = 0,
    phase: Phase = .aiming,
    projectiles: [MAX_PROJECTILES]Projectile = undefined,
    projectile_count: u8 = 0,
    explosions: [MAX_EXPLOSIONS]Explosion = undefined,
    explosion_count: u8 = 0,
    fires: [MAX_FIRES]Fire = undefined,
    fire_count: u8 = 0,
    /// Whether this turn's fires have burned, once everything else settled.
    has_burned: bool = false,
    /// Time short of a whole step, carried into the next frame.
    leftover_seconds: f32 = 0,
    ai_plan: ?AiPlan = null,
    last_fired: ?Fired = null,

    /// `players` holds 2 to MAX_TANKS entries; `round_count` is at least 1.
    pub fn init(players: []const Player, round_count: u8, seed: u64) Game {
        std.debug.assert(players.len >= 2 and players.len <= MAX_TANKS and round_count >= 1);
        var game: Game = .{ .prng = .init(seed), .tank_count = @intCast(players.len), .round_count = round_count };
        for (players, game.tanks[0..players.len]) |player, *tank| tank.* = .{ .seat = player.seat, .controller = player.controller, .x = 0, .y = 0 };
        game.startRound();
        return game;
    }

    /// Phase must be round_over.
    pub fn nextRound(self: *Game) void {
        self.round += 1;
        self.startRound();
    }

    /// The same players again from round 1.
    pub fn restart(self: *Game) void {
        for (self.tanks[0..self.tank_count]) |*tank| tank.wins = 0;
        self.round = 1;
        self.startRound();
    }

    /// `seconds` since the last call, capped so a stall (a dragged window, say) doesn't jump ahead.
    pub fn step(self: *Game, seconds: f32, control: Control) void {
        const elapsed = @min(seconds, 0.1);
        switch (self.phase) {
            .aiming => self.aim(elapsed, control),
            .resolving => self.resolve(elapsed),
            .round_over, .match_over => {},
        }
    }

    /// A remote tank's aim as its player turns the barrel; only shown, since the shot carries its own.
    pub fn aimRemote(self: *Game, shot: Shot, weapon: Weapon) void {
        const tank = &self.tanks[self.current];
        if (self.phase != .aiming or tank.controller != .remote) return;
        tank.angle_degrees = std.math.clamp(shot.angle_degrees, 0, 180);
        tank.power = std.math.clamp(shot.power, 0, MAX_POWER);
        if (tank.hasAmmo(weapon)) tank.weapon = weapon;
    }

    /// Fires the current tank, which must be remote and aiming, as its player did.
    pub fn fireRemote(self: *Game, shot: Shot, weapon: Weapon) void {
        self.aimRemote(shot, weapon);
        self.fire();
    }

    /// Whether the current tank is remote and waiting on its player's shot.
    pub fn isAwaitingRemote(self: *const Game) bool {
        return self.phase == .aiming and self.currentTank().controller == .remote;
    }

    /// Every remote tank in `seat` plays itself from now on.
    pub fn handToAi(self: *Game, seat: u8) void {
        for (self.tanks[0..self.tank_count]) |*tank| {
            if (tank.seat == seat and tank.controller == .remote) tank.controller = .ai_normal;
        }
    }

    /// Of everything a shot changes, so two machines that disagree can tell.
    pub fn stateHash(self: *const Game) u32 {
        var hasher: std.hash.Wyhash = .init(0);
        hasher.update(std.mem.sliceAsBytes(self.heights[0..]));
        for (self.matchTanks()) |tank| {
            for ([_]f32{ tank.x, tank.y, tank.health }) |value| hasher.update(std.mem.asBytes(&value));
            hasher.update(&tank.ammo);
        }
        for (self.liveFires()) |fire_patch| {
            hasher.update(std.mem.asBytes(&fire_patch.x));
            hasher.update(&.{fire_patch.burns_left});
        }
        hasher.update(std.mem.asBytes(&self.wind));
        hasher.update(std.mem.asBytes(&self.turn));
        hasher.update(&.{ self.current, self.round });
        return @truncate(hasher.final());
    }

    /// Wrecks too.
    pub fn matchTanks(self: *const Game) []const Tank {
        return self.tanks[0..self.tank_count];
    }

    pub fn currentTank(self: *const Game) *const Tank {
        return &self.tanks[self.current];
    }

    pub fn liveProjectiles(self: *const Game) []const Projectile {
        return self.projectiles[0..self.projectile_count];
    }

    pub fn liveExplosions(self: *const Game) []const Explosion {
        return self.explosions[0..self.explosion_count];
    }

    pub fn liveFires(self: *const Game) []const Fire {
        return self.fires[0..self.fire_count];
    }

    pub fn groundAt(self: *const Game, x: f32) f32 {
        return self.heights[columnAt(x)];
    }

    /// The angle and power whose trial shell lands nearest `target`, steering clear of the shooter's own blast.
    pub fn bestShot(self: *const Game, shooter: u8, target: u8) Shot {
        // Lobbed toward the target, should no trial shot land at all.
        var best: Shot = .{ .angle_degrees = if (self.tanks[target].x > self.tanks[shooter].x) 45 else 135, .power = 70 };
        var best_miss = std.math.inf(f32);
        // A coarse grid, then a fine one around its best.
        var angle: f32 = 10;
        while (angle <= 170) : (angle += 4) {
            var power: f32 = 20;
            while (power <= MAX_POWER) : (power += 5) self.considerShot(shooter, target, .{ .angle_degrees = angle, .power = power }, &best, &best_miss);
        }
        const coarse = best;
        angle = @max(0, coarse.angle_degrees - 4);
        while (angle <= @min(180, coarse.angle_degrees + 4)) : (angle += 1) {
            var power = @max(0, coarse.power - 5);
            while (power <= @min(MAX_POWER, coarse.power + 5)) : (power += 1) self.considerShot(shooter, target, .{ .angle_degrees = angle, .power = power }, &best, &best_miss);
        }
        return best;
    }

    /// Where a trial shell lands, or null if it leaves the field or is still flying after AI_MAX_FLIGHT_SECONDS.
    pub fn trialLanding(self: *const Game, shooter: u8, shot: Shot) ?[2]f32 {
        var flight: Flight = .launch(&self.tanks[shooter], shot.angle_degrees, shot.power);
        var age_seconds: f32 = 0;
        while (age_seconds < AI_MAX_FLIGHT_SECONDS) : (age_seconds += AI_STEP_SECONDS) {
            flight.advance(self.wind, AI_STEP_SECONDS);
            if (flight.isOffField()) return null;
            if (self.isImpact(flight, shooter, age_seconds)) return .{ flight.x, flight.y };
        }
        return null;
    }

    fn startRound(self: *Game) void {
        const random = self.prng.random();
        self.generateTerrain();
        self.placeTanks();
        for (self.tanks[0..self.tank_count]) |*tank| {
            tank.health = MAX_HEALTH;
            tank.weapon = .shell;
            tank.power = 60;
            tank.fall_from = null;
            tank.angle_degrees = if (tank.x < FIELD_WIDTH / 2) 60 else 120;
            for (&tank.ammo, 0..) |*ammo, index| ammo.* = spec(@enumFromInt(index)).ammo orelse 0;
        }
        self.wind = (random.float(f32) * 2 - 1) * MAX_WIND * STARTING_WIND_SHARE;
        self.projectile_count = 0;
        self.explosion_count = 0;
        self.fire_count = 0;
        self.leftover_seconds = 0;
        self.ai_plan = null;
        self.turn = 0;
        self.current = @intCast((self.round - 1) % self.tank_count);
        self.phase = .aiming;
    }

    /// A few overlaid waves of random size, wavelength and phase.
    fn generateTerrain(self: *Game) void {
        const random = self.prng.random();
        const base = MIN_GROUND + 40 + random.float(f32) * 100;
        var amplitudes: [TERRAIN_WAVES]f32 = undefined;
        var frequencies: [TERRAIN_WAVES]f32 = undefined;
        var phases: [TERRAIN_WAVES]f32 = undefined;
        for (0..TERRAIN_WAVES) |wave| {
            const octave: f32 = @floatFromInt(wave + 1);
            amplitudes[wave] = 60 / octave * (0.5 + random.float(f32));
            frequencies[wave] = octave * (1 + random.float(f32)) * std.math.tau / FIELD_WIDTH;
            phases[wave] = random.float(f32) * std.math.tau;
        }
        for (&self.heights, 0..) |*height, column| {
            const x: f32 = @floatFromInt(column);
            var sum: f32 = base;
            for (amplitudes, frequencies, phases) |amplitude, frequency, phase| sum += amplitude * @sin(x * frequency + phase);
            height.* = std.math.clamp(sum, MIN_GROUND, MAX_GROUND);
        }
    }

    /// One tank per evenly spaced slot, in shuffled order, each on a flattened pad.
    fn placeTanks(self: *Game) void {
        const random = self.prng.random();
        var order: [MAX_TANKS]u8 = undefined;
        for (order[0..self.tank_count], 0..) |*slot, index| slot.* = @intCast(index);
        random.shuffle(u8, order[0..self.tank_count]);
        const slot_width = FIELD_WIDTH / @as(f32, @floatFromInt(self.tank_count));
        for (self.tanks[0..self.tank_count], order[0..self.tank_count]) |*tank, slot| {
            const jitter = (random.float(f32) * 2 - 1) * slot_width * 0.2;
            tank.x = std.math.clamp(slot_width * (@as(f32, @floatFromInt(slot)) + 0.5) + jitter, EDGE_MARGIN, FIELD_WIDTH - EDGE_MARGIN);
            const level = self.groundAt(tank.x);
            for (columnAt(tank.x - TANK_HALF_WIDTH)..columnAt(tank.x + TANK_HALF_WIDTH) + 1) |column| self.heights[column] = level;
            tank.y = level;
        }
    }

    fn aim(self: *Game, seconds: f32, control: Control) void {
        const tank = &self.tanks[self.current];
        switch (tank.controller) {
            .human => {
                const aim_speed = if (control.is_fine) FINE_AIM_SPEED else AIM_SPEED;
                const power_speed = if (control.is_fine) FINE_POWER_SPEED else POWER_SPEED;
                tank.angle_degrees = std.math.clamp(tank.angle_degrees + control.turn * aim_speed * seconds, 0, 180);
                tank.power = std.math.clamp(tank.power + control.power * power_speed * seconds, 0, MAX_POWER);
                if (control.choice) |weapon| {
                    if (tank.hasAmmo(weapon)) tank.weapon = weapon;
                }
                if (control.weapon_step != 0) tank.weapon = tank.nextWeapon(control.weapon_step);
                if (control.is_firing) self.fire();
            },
            .remote => {},
            .ai_easy, .ai_normal, .ai_hard => self.aiAim(seconds),
        }
    }

    fn fire(self: *Game) void {
        const tank = &self.tanks[self.current];
        if (!tank.hasAmmo(tank.weapon)) tank.weapon = .shell;
        const weapon = tank.weapon;
        self.last_fired = .{ .shot = .{ .angle_degrees = tank.angle_degrees, .power = tank.power }, .weapon = weapon, .turn = self.turn, .state_hash = self.stateHash() };
        self.turn +%= 1;
        if (spec(weapon).ammo != null) tank.ammo[@intFromEnum(weapon)] -= 1;
        if (!tank.hasAmmo(weapon)) tank.weapon = .shell;
        self.addProjectile(.{ .flight = .launch(tank, tank.angle_degrees, tank.power), .weapon = weapon, .owner = self.current });
        self.leftover_seconds = 0;
        self.has_burned = false;
        self.phase = .resolving;
    }

    fn resolve(self: *Game, seconds: f32) void {
        self.leftover_seconds += seconds;
        while (self.leftover_seconds >= STEP_SECONDS) {
            self.leftover_seconds -= STEP_SECONDS;
            self.substep();
        }
        if (self.projectile_count > 0 or self.explosion_count > 0 or self.isAnyTankFalling()) return;
        // A burn can wreck a tank, whose blast resolves before the turn ends.
        if (!self.has_burned) {
            self.has_burned = true;
            self.burn();
            return;
        }
        self.endTurn();
    }

    fn substep(self: *Game) void {
        var index: usize = 0;
        while (index < self.projectile_count) {
            if (self.fly(index)) index += 1 else self.removeProjectile(index);
        }
        index = 0;
        while (index < self.explosion_count) {
            self.explosions[index].age_seconds += STEP_SECONDS;
            if (self.explosions[index].age_seconds < EXPLOSION_SECONDS) {
                index += 1;
                continue;
            }
            self.explosions[index] = self.explosions[self.explosion_count - 1];
            self.explosion_count -= 1;
        }
        self.settleTanks();
    }

    /// Whether the projectile is still in the air.
    fn fly(self: *Game, index: usize) bool {
        const projectile = &self.projectiles[index];
        if (projectile.is_rolling) return self.roll(projectile);
        projectile.flight.advance(self.wind, STEP_SECONDS);
        projectile.age_seconds += STEP_SECONDS;
        projectile.steps += 1;
        if (projectile.steps % TRAIL_EVERY_STEPS == 0) projectile.addTrailPoint();
        if (projectile.flight.isOffField()) return false;
        if (projectile.weapon == .cluster and !projectile.is_bomblet and projectile.flight.vy <= 0) {
            self.splitCluster(index);
            return true;
        }
        if (!self.isImpact(projectile.flight, projectile.owner, projectile.age_seconds)) return true;
        return self.land(projectile);
    }

    /// Whether it lives on, as a roller starting to roll.
    fn land(self: *Game, projectile: *Projectile) bool {
        const x = projectile.flight.x;
        var y = projectile.flight.y;
        const is_on_ground = y <= self.groundAt(x);
        switch (projectile.weapon) {
            .shell, .heavy_shell, .cluster, .megaton, .dirt_clod => {},
            .roller => if (is_on_ground and self.startRolling(projectile)) return true,
            .digger => if (is_on_ground) {
                y = self.groundAt(x) - DIG_DEPTH;
            },
            .napalm => self.addFire(x),
        }
        self.explode(projectile.weapon, x, y);
        return false;
    }

    /// Downhill, or on the way it was going on the level; false if it landed in a pit.
    fn startRolling(self: *const Game, projectile: *Projectile) bool {
        const x = projectile.flight.x;
        const left = self.groundAt(x - ROLL_PROBE);
        const right = self.groundAt(x + ROLL_PROBE);
        var direction: f32 = if (projectile.flight.vx < 0) -1 else 1;
        if (left < right) direction = -1;
        if (right < left) direction = 1;
        const here = self.groundAt(x);
        if (self.groundAt(x + direction * ROLL_PROBE) > here + ROLL_MAX_RISE * ROLL_PROBE) return false;
        projectile.is_rolling = true;
        projectile.flight = .{ .x = x, .y = here, .vx = direction * ROLL_SPEED, .vy = 0 };
        return true;
    }

    /// Whether it rolls on; it goes off against a rise too steep, at a tank, or once ROLL_SECONDS run out, and off the field it's lost.
    fn roll(self: *Game, projectile: *Projectile) bool {
        projectile.roll_seconds += STEP_SECONDS;
        projectile.steps += 1;
        if (projectile.steps % TRAIL_EVERY_STEPS == 0) projectile.addTrailPoint();
        const from = projectile.flight.x;
        const to = from + projectile.flight.vx * STEP_SECONDS;
        if (to < 0 or to >= FIELD_WIDTH) return false;
        const is_blocked = self.groundAt(to) - self.groundAt(from) > ROLL_MAX_RISE;
        if (is_blocked or projectile.roll_seconds >= ROLL_SECONDS or self.isTankAt(to, projectile.flight.y)) {
            self.explode(projectile.weapon, from, projectile.flight.y);
            return false;
        }
        projectile.flight.x = to;
        projectile.flight.y = self.groundAt(to);
        return true;
    }

    fn isTankAt(self: *const Game, x: f32, y: f32) bool {
        for (self.matchTanks()) |tank| {
            if (tank.isAlive() and @abs(x - tank.x) <= TANK_HALF_WIDTH and y <= tank.y + TANK_HEIGHT) return true;
        }
        return false;
    }

    fn explode(self: *Game, weapon: Weapon, x: f32, y: f32) void {
        const weapon_spec = spec(weapon);
        self.detonate(x, y, weapon_spec.blast_radius, weapon_spec.damage, weapon_spec.adds_dirt);
    }

    /// Replaces the oldest fire when there are already MAX_FIRES.
    fn addFire(self: *Game, x: f32) void {
        if (self.fire_count == MAX_FIRES) {
            std.mem.copyForwards(Fire, self.fires[0 .. MAX_FIRES - 1], self.fires[1..]);
            self.fire_count -= 1;
        }
        self.fires[self.fire_count] = .{ .x = x, .burns_left = FIRE_BURNS };
        self.fire_count += 1;
    }

    /// Hurts every tank in the flames, and burns each fire down by one.
    fn burn(self: *Game) void {
        var index: usize = 0;
        while (index < self.fire_count) {
            const fire_patch = &self.fires[index];
            for (self.tanks[0..self.tank_count]) |*tank| {
                if (@abs(tank.x - fire_patch.x) <= FIRE_HALF_WIDTH + TANK_HALF_WIDTH) self.hurt(tank, FIRE_DAMAGE);
            }
            fire_patch.burns_left -= 1;
            if (fire_patch.burns_left > 0) {
                index += 1;
                continue;
            }
            std.mem.copyForwards(Fire, self.fires[index .. self.fire_count - 1], self.fires[index + 1 .. self.fire_count]);
            self.fire_count -= 1;
        }
    }

    /// At the top of its arc; each bomblet keeps the shell's trail.
    fn splitCluster(self: *Game, index: usize) void {
        const parent = self.projectiles[index];
        for (0..CLUSTER_BOMBLETS) |bomblet_index| {
            var bomblet = parent;
            bomblet.is_bomblet = true;
            bomblet.flight.vx += (@as(f32, @floatFromInt(bomblet_index)) - (CLUSTER_BOMBLETS - 1) / 2.0) * CLUSTER_SPREAD;
            if (bomblet_index == 0) self.projectiles[index] = bomblet else self.addProjectile(bomblet);
        }
    }

    fn addProjectile(self: *Game, projectile: Projectile) void {
        if (self.projectile_count == MAX_PROJECTILES) return;
        self.projectiles[self.projectile_count] = projectile;
        self.projectile_count += 1;
    }

    fn removeProjectile(self: *Game, index: usize) void {
        self.projectiles[index] = self.projectiles[self.projectile_count - 1];
        self.projectile_count -= 1;
    }

    fn isImpact(self: *const Game, flight: Flight, owner: u8, age_seconds: f32) bool {
        if (flight.y <= self.groundAt(flight.x)) return true;
        for (self.matchTanks(), 0..) |tank, index| {
            if (!tank.isAlive()) continue;
            if (index == owner and age_seconds < ARMING_SECONDS) continue;
            if (@abs(flight.x - tank.x) <= TANK_HALF_WIDTH and flight.y >= tank.y and flight.y <= tank.y + TANK_HEIGHT + DOME_RADIUS) return true;
        }
        return false;
    }

    fn detonate(self: *Game, x: f32, y: f32, radius: f32, damage: f32, adds_dirt: bool) void {
        if (self.explosion_count < MAX_EXPLOSIONS) {
            self.explosions[self.explosion_count] = .{ .x = x, .y = y, .radius = radius, .adds_dirt = adds_dirt };
            self.explosion_count += 1;
        }
        if (adds_dirt) {
            self.pileDirt(x, y, radius);
            return;
        }
        self.carveCrater(x, y, radius);
        for (self.tanks[0..self.tank_count]) |*tank| {
            const dx = tank.x - x;
            const dy = tank.y + TANK_HEIGHT / 2 - y;
            const reach = radius + TANK_HALF_WIDTH;
            const distance = @sqrt(dx * dx + dy * dy);
            if (distance < reach) self.hurt(tank, damage * (1 - distance / reach));
        }
    }

    /// A tank this destroys blows up in turn, which may destroy others.
    fn hurt(self: *Game, tank: *Tank, damage: f32) void {
        if (!tank.isAlive()) return;
        tank.health -= damage;
        if (tank.isAlive()) return;
        tank.health = 0;
        self.detonate(tank.x, tank.y + TANK_HEIGHT / 2, WRECK_BLAST_RADIUS, WRECK_BLAST_DAMAGE, false);
    }

    fn carveCrater(self: *Game, x: f32, y: f32, radius: f32) void {
        for (columnAt(x - radius)..columnAt(x + radius) + 1) |column| {
            const reach = circleHalfHeight(x, radius, column) orelse continue;
            const bottom = @max(0, y - reach);
            const height = &self.heights[column];
            if (height.* <= bottom) continue;
            // Earth above the blast drops into the hole it leaves.
            height.* -= @min(height.*, y + reach) - bottom;
        }
    }

    fn pileDirt(self: *Game, x: f32, y: f32, radius: f32) void {
        for (columnAt(x - radius)..columnAt(x + radius) + 1) |column| {
            const reach = circleHalfHeight(x, radius, column) orelse continue;
            const height = &self.heights[column];
            height.* = @max(height.*, @min(y + reach, MAX_DIRT));
        }
    }

    /// Wrecks fall too, but only a living tank is hurt by landing.
    fn settleTanks(self: *Game) void {
        for (self.tanks[0..self.tank_count]) |*tank| {
            const rest = self.restHeight(tank.x);
            if (tank.y > rest) {
                if (tank.fall_from == null) tank.fall_from = tank.y;
                tank.y = @max(rest, tank.y - FALL_SPEED * STEP_SECONDS);
                if (tank.y > rest) continue;
            }
            tank.y = rest;
            const fall_from = tank.fall_from orelse continue;
            tank.fall_from = null;
            const fallen = fall_from - rest;
            if (fallen > SAFE_FALL) self.hurt(tank, (fallen - SAFE_FALL) * FALL_DAMAGE_PER_UNIT);
        }
    }

    fn isAnyTankFalling(self: *const Game) bool {
        for (self.matchTanks()) |tank| {
            if (tank.fall_from != null) return true;
        }
        return false;
    }

    /// The highest ground under the tank's tracks.
    fn restHeight(self: *const Game, x: f32) f32 {
        var highest: f32 = 0;
        for (self.heights[columnAt(x - TANK_HALF_WIDTH) .. columnAt(x + TANK_HALF_WIDTH) + 1]) |height| highest = @max(highest, height);
        return highest;
    }

    fn endTurn(self: *Game) void {
        var survivor: ?u8 = null;
        var survivor_count: u8 = 0;
        for (self.matchTanks(), 0..) |tank, index| {
            if (!tank.isAlive()) continue;
            survivor_count += 1;
            survivor = @intCast(index);
        }
        if (survivor_count <= 1) {
            self.endRound(survivor);
            return;
        }
        self.current = self.nextAlive(self.current);
        self.wind = std.math.clamp(self.wind + (self.prng.random().float(f32) * 2 - 1) * WIND_DRIFT, -MAX_WIND, MAX_WIND);
        self.ai_plan = null;
        self.phase = .aiming;
    }

    fn endRound(self: *Game, winner: ?u8) void {
        if (winner) |index| self.tanks[index].wins += 1;
        self.phase = if (self.round >= self.round_count) .{ .match_over = self.matchWinner() } else .{ .round_over = winner };
    }

    fn matchWinner(self: *const Game) ?u8 {
        var winner: ?u8 = null;
        var most_wins: u8 = 0;
        for (self.matchTanks(), 0..) |tank, index| {
            if (tank.wins > most_wins) {
                most_wins = tank.wins;
                winner = @intCast(index);
            } else if (tank.wins == most_wins) {
                winner = null;
            }
        }
        return winner;
    }

    fn nextAlive(self: *const Game, from: u8) u8 {
        for (1..self.tank_count + 1) |offset| {
            const index: u8 = @intCast((from + offset) % self.tank_count);
            if (self.tanks[index].isAlive()) return index;
        }
        return from;
    }

    fn aiAim(self: *Game, seconds: f32) void {
        if (self.ai_plan == null) self.ai_plan = .{ .shot = self.planShot() };
        const plan = if (self.ai_plan) |*pending| pending else return;
        const tank = &self.tanks[self.current];
        plan.waited_seconds += seconds;
        tank.angle_degrees = approach(tank.angle_degrees, plan.shot.angle_degrees, AI_AIM_SPEED * seconds);
        tank.power = approach(tank.power, plan.shot.power, AI_POWER_SPEED * seconds);
        const is_aimed = tank.angle_degrees == plan.shot.angle_degrees and tank.power == plan.shot.power;
        if (is_aimed and plan.waited_seconds >= AI_MIN_THINK_SECONDS) self.fire();
    }

    /// Also picks the AI's weapon.
    fn planShot(self: *Game) Shot {
        const tank = &self.tanks[self.current];
        tank.weapon = aiWeapon(tank);
        const shot = self.bestShot(self.current, self.aiTarget());
        const spread = aimSpread(tank.controller);
        const random = self.prng.random();
        return .{
            .angle_degrees = std.math.clamp(shot.angle_degrees + (random.float(f32) * 2 - 1) * spread.angle_degrees, 0, 180),
            .power = std.math.clamp(shot.power + (random.float(f32) * 2 - 1) * spread.power, 0, MAX_POWER),
        };
    }

    /// An easy AI picks any opponent; the others pick the nearest.
    fn aiTarget(self: *Game) u8 {
        var candidates: [MAX_TANKS]u8 = undefined;
        var candidate_count: usize = 0;
        var nearest: u8 = self.current;
        var nearest_distance = std.math.inf(f32);
        const shooter = self.tanks[self.current];
        for (self.matchTanks(), 0..) |tank, index| {
            if (index == self.current or !tank.isAlive()) continue;
            candidates[candidate_count] = @intCast(index);
            candidate_count += 1;
            const distance = @abs(tank.x - shooter.x);
            if (distance < nearest_distance) {
                nearest_distance = distance;
                nearest = @intCast(index);
            }
        }
        if (shooter.controller != .ai_easy or candidate_count == 0) return nearest;
        return candidates[self.prng.random().uintLessThan(usize, candidate_count)];
    }

    fn considerShot(self: *const Game, shooter: u8, target: u8, shot: Shot, best: *Shot, best_miss: *f32) void {
        const landing = self.trialLanding(shooter, shot) orelse return;
        const aimed_at = self.tanks[target];
        const own = self.tanks[shooter];
        var miss = @abs(landing[0] - aimed_at.x) + @abs(landing[1] - (aimed_at.y + TANK_HEIGHT / 2)) * 0.5;
        if (@abs(landing[0] - own.x) < spec(own.weapon).blast_radius + TANK_HALF_WIDTH) miss += AI_SELF_HIT_PENALTY;
        if (miss >= best_miss.*) return;
        best_miss.* = miss;
        best.* = shot;
    }
};

pub fn spec(weapon: Weapon) WeaponSpec {
    return switch (weapon) {
        .shell => .{ .blast_radius = 22, .damage = 45, .ammo = null },
        .heavy_shell => .{ .blast_radius = 36, .damage = 70, .ammo = 3 },
        // Each bomblet's.
        .cluster => .{ .blast_radius = 16, .damage = 28, .ammo = 2 },
        .roller => .{ .blast_radius = 26, .damage = 55, .ammo = 3 },
        .digger => .{ .blast_radius = 34, .damage = 30, .ammo = 2 },
        // The landing's; its fire burns for more.
        .napalm => .{ .blast_radius = 14, .damage = 15, .ammo = 2 },
        .megaton => .{ .blast_radius = 75, .damage = 120, .ammo = 1 },
        .dirt_clod => .{ .blast_radius = 40, .damage = 0, .ammo = 2, .adds_dirt = true },
    };
}

fn aiWeapon(tank: *const Tank) Weapon {
    return switch (tank.controller) {
        .human, .remote, .ai_easy => .shell,
        .ai_normal => if (tank.hasAmmo(.heavy_shell)) .heavy_shell else .shell,
        .ai_hard => if (tank.hasAmmo(.megaton)) .megaton else if (tank.hasAmmo(.heavy_shell)) .heavy_shell else .shell,
    };
}

/// How far, either way, an AI's shot strays from its best one.
fn aimSpread(controller: Controller) Shot {
    return switch (controller) {
        .human, .remote => .{ .angle_degrees = 0, .power = 0 },
        .ai_easy => .{ .angle_degrees = 10, .power = 12 },
        .ai_normal => .{ .angle_degrees = 4, .power = 5 },
        .ai_hard => .{ .angle_degrees = 1, .power = 1.5 },
    };
}

fn unitVector(angle_degrees: f32) [2]f32 {
    const radians = angle_degrees * (std.math.pi / 180.0);
    return .{ @cos(radians), @sin(radians) };
}

fn columnAt(x: f32) usize {
    return @intFromFloat(std.math.clamp(x, 0, FIELD_WIDTH - 1));
}

/// Half the height of a circle around `x` at `column`'s centre; null outside it.
fn circleHalfHeight(x: f32, radius: f32, column: usize) ?f32 {
    const dx = @as(f32, @floatFromInt(column)) + 0.5 - x;
    const squared = radius * radius - dx * dx;
    if (squared <= 0) return null;
    return @sqrt(squared);
}

fn approach(value: f32, goal: f32, max_change: f32) f32 {
    if (@abs(goal - value) <= max_change) return goal;
    return if (goal > value) value + max_change else value - max_change;
}

const testing = std.testing;

/// Human tanks at `xs` on flat ground 100 high, with no wind.
fn flatGame(xs: []const f32) Game {
    var players: [MAX_TANKS]Player = undefined;
    for (players[0..xs.len], 0..) |*player, index| player.* = .{ .seat = @intCast(index), .controller = .human };
    var game: Game = .init(players[0..xs.len], 3, 1);
    @memset(&game.heights, 100);
    game.wind = 0;
    for (game.tanks[0..xs.len], xs) |*tank, x| {
        tank.x = x;
        tank.y = 100;
    }
    return game;
}

fn resolveShot(game: *Game) void {
    for (0..2000) |_| {
        if (game.phase != .resolving) return;
        game.step(1.0 / 60.0, .{});
    }
}

test "a blast carves a crater and the earth above it falls in" {
    var game = flatGame(&.{ 100, 600 });
    game.carveCrater(360, 100, 20);
    try testing.expectApproxEqAbs(@as(f32, 80), game.heights[360], 0.1);
    try testing.expectEqual(@as(f32, 100), game.heights[300]);
    game.carveCrater(360, 50, 10);
    try testing.expectApproxEqAbs(@as(f32, 60), game.heights[360], 0.1);
}

test "a dirt clod piles a mound where it lands" {
    var game = flatGame(&.{ 100, 600 });
    game.pileDirt(360, 100, 20);
    try testing.expectApproxEqAbs(@as(f32, 120), game.heights[360], 0.1);
    try testing.expectEqual(@as(f32, 100), game.heights[300]);
}

test "a shell fired straight up comes back down on its own tank" {
    var game = flatGame(&.{ 100, 600 });
    game.tanks[0].angle_degrees = 90;
    game.tanks[0].power = 40;
    game.fire();
    resolveShot(&game);
    try testing.expect(game.tanks[0].health < MAX_HEALTH);
    try testing.expectEqual(MAX_HEALTH, game.tanks[1].health);
}

test "a limited weapon runs out, falls back to the shell, and is skipped when stepping" {
    var game = flatGame(&.{ 100, 600 });
    game.tanks[0].weapon = .megaton;
    game.fire();
    try testing.expectEqual(@as(?u8, 0), game.tanks[0].ammoLeft(.megaton));
    try testing.expectEqual(Weapon.shell, game.tanks[0].weapon);
    game.tanks[0].ammo[@intFromEnum(Weapon.heavy_shell)] = 0;
    try testing.expectEqual(Weapon.cluster, game.tanks[0].nextWeapon(1));
    try testing.expectEqual(Weapon.dirt_clod, game.tanks[0].nextWeapon(-1));
}

/// `weapon` dropped from just above the ground at `x`, as if tank 0 fired it.
fn dropOn(game: *Game, weapon: Weapon, x: f32) void {
    game.addProjectile(.{ .flight = .{ .x = x, .y = game.groundAt(x) + 1, .vx = 0, .vy = -10 }, .weapon = weapon, .owner = 0, .age_seconds = ARMING_SECONDS });
    game.has_burned = false;
    game.phase = .resolving;
    resolveShot(game);
}

test "a roller landing on the level rolls on and goes off at a tank" {
    var game = flatGame(&.{ 100, 600 });
    dropOn(&game, .roller, 300);
    try testing.expectEqual(@as(f32, 100), game.heights[300]);
    try testing.expect(game.tanks[1].health < MAX_HEALTH);
}

test "a roller stops against a steep rise and goes off there" {
    var game = flatGame(&.{ 100, 600 });
    @memset(game.heights[350..360], 200);
    dropOn(&game, .roller, 300);
    try testing.expect(game.heights[345] < 100);
    try testing.expectEqual(MAX_HEALTH, game.tanks[1].health);
}

test "a digger goes off underground and leaves a pit" {
    var game = flatGame(&.{ 100, 600 });
    dropOn(&game, .digger, 360);
    try testing.expect(game.heights[360] < 100 - DIG_DEPTH);
}

test "napalm leaves flames that burn a tank standing in them as each turn ends" {
    var game = flatGame(&.{ 100, 600 });
    dropOn(&game, .napalm, 360);
    try testing.expectEqual(@as(usize, 1), game.liveFires().len);
    try testing.expectEqual(@as(u8, FIRE_BURNS - 1), game.liveFires()[0].burns_left);
    game.addFire(600);
    game.phase = .resolving;
    game.has_burned = false;
    resolveShot(&game);
    try testing.expectEqual(MAX_HEALTH - FIRE_DAMAGE, game.tanks[1].health);
}

test "a cluster shell splits into bomblets at the top of its arc" {
    var game = flatGame(&.{ 100, 600 });
    game.tanks[0].weapon = .cluster;
    game.tanks[0].angle_degrees = 60;
    game.fire();
    for (0..1000) |_| {
        if (game.projectile_count > 1) break;
        game.step(1.0 / 60.0, .{});
    }
    try testing.expectEqual(@as(u8, CLUSTER_BOMBLETS), game.projectile_count);
}

test "the turn passes to the next tank still alive" {
    var game = flatGame(&.{ 100, 360, 600 });
    game.current = 0;
    game.tanks[1].health = 0;
    game.endTurn();
    try testing.expectEqual(@as(u8, 2), game.current);
    try testing.expectEqual(Phase.aiming, game.phase);
}

test "the last tank standing wins the round" {
    var game = flatGame(&.{ 100, 600 });
    game.tanks[1].health = 0;
    game.endTurn();
    try testing.expectEqual(Phase{ .round_over = 0 }, game.phase);
    try testing.expectEqual(@as(u8, 1), game.tanks[0].wins);
}

test "the last round ends the match, and a tie in wins is a draw" {
    var game = flatGame(&.{ 100, 600 });
    game.round = 3;
    game.tanks[0].wins = 1;
    game.tanks[1].wins = 2;
    game.tanks[1].health = 0;
    game.endTurn();
    try testing.expectEqual(Phase{ .match_over = null }, game.phase);
}

test "a fall beyond the safe height costs health" {
    var game = flatGame(&.{ 100, 600 });
    @memset(game.heights[80..121], 40);
    game.phase = .resolving;
    resolveShot(&game);
    try testing.expectApproxEqAbs(MAX_HEALTH - (60 - SAFE_FALL) * FALL_DAMAGE_PER_UNIT, game.tanks[0].health, 0.01);
    try testing.expectEqual(@as(f32, 40), game.tanks[0].y);
}

test "a remote shot fires the waiting remote tank as its player aimed it" {
    var game = flatGame(&.{ 100, 600 });
    game.tanks[0].controller = .remote;
    try testing.expect(game.isAwaitingRemote());
    game.fireRemote(.{ .angle_degrees = 30, .power = 55 }, .heavy_shell);
    try testing.expectEqual(Phase.resolving, game.phase);
    try testing.expectEqual(@as(u16, 1), game.turn);
    try testing.expectEqual(@as(?u8, 2), game.tanks[0].ammoLeft(.heavy_shell));
    const fired = game.last_fired orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f32, 30), fired.shot.angle_degrees);
}

test "the state hash changes when a blast reshapes the ground" {
    var game = flatGame(&.{ 100, 600 });
    const before = game.stateHash();
    game.carveCrater(360, 100, 20);
    try testing.expect(before != game.stateHash());
}

test "a remote seat handed to the AI aims for itself" {
    var game = flatGame(&.{ 100, 600 });
    game.tanks[0].controller = .remote;
    game.handToAi(0);
    try testing.expectEqual(Controller.ai_normal, game.tanks[0].controller);
    try testing.expect(!game.isAwaitingRemote());
}

test "the AI's best shot lands near its target on flat ground without wind" {
    var game = flatGame(&.{ 150, 550 });
    const shot = game.bestShot(0, 1);
    const landing = game.trialLanding(0, shot) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 550), landing[0], 12);
}

test "the AI's best shot against wind still lands near its target" {
    var game = flatGame(&.{ 150, 550 });
    game.wind = -MAX_WIND;
    const shot = game.bestShot(0, 1);
    const landing = game.trialLanding(0, shot) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 550), landing[0], 12);
}
