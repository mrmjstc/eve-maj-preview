# Zig Style Guide

How every file in `src/` should read. Where this guide and the [official Zig style guide](https://ziglang.org/documentation/master/#Style-Guide) disagree, this guide wins; each deviation is deliberate and noted.

`zig fmt` is the formatter. Nothing here overrides its output.

## 1. File layout

Every file follows this order:

```zig
//! One sentence: what this module owns or does.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const lines = @import("lines.zig");
const log = @import("../log.zig");

const Config = config_mod.Config;
const slog = log.Scoped("chatlog");

pub const MAX_LINE_LENGTH = 4000;

pub const Monitor = struct { ... };

var g_monitor: ?*Monitor = null;

pub fn start(...) !void { ... }
fn helper(...) void { ... }

test "parseChatLine reads the system after the colon" { ... }
```

1. `//!` header: required, one line. Say what the module owns or is responsible for, not how it works.
2. Imports: `std`, then `platform/`, then project modules, with `log` last.
3. Aliases pulled out of imports (`const Config = config_mod.Config;`) and `slog`. Never pull a type straight out of an import line (`const Config = @import("config.zig").Config;`): import the module, then alias it here.
4. Constants, then types, then globals, then public functions, then private helpers.
5. `test` blocks at the bottom. An alias only the tests use (`const testing = std.testing;`) and the constants and helpers they share sit just above them, never between two tests.

Re-exports (`pub const ThumbnailWindow = window_mod.ThumbnailWindow;`) go straight after the aliases, and only when callers really should reach the type through this module.

## 2. Naming

| Kind | Style | Example |
|---|---|---|
| Types, and functions returning `type` | `TitleCase` | `ProfileStore`, `Tracker(Window)` |
| Functions | `camelCase` | `parseGameLine` |
| Variables, parameters, fields | `snake_case` | `source_hwnd` |
| Module-level constants | `SCREAMING_SNAKE` | `HIDE_DEBOUNCE_TIMER_ID` |
| Mutable globals | `g_` + `snake_case` | `g_painter_ptr` |
| Enum variants, error names | `snake_case` / `TitleCase` | `.jump`, `error.OpenFailed` |

- **Deviation: constants.** Upstream Zig uses `snake_case` for constants. This codebase uses `SCREAMING_SNAKE` for module-level values (numbers, strings, IDs) so they stand out from locals. Keep it consistent; don't mix. Local `const` inside a function stays `snake_case`.
- **Deviation: style values.** `dialog/knots/style.zig`'s `Style` values and theme are named like what they style (`pub const section: Style`), not `SCREAMING_SNAKE`. The plain numbers and colours there still are (`CONTROL_HEIGHT`, `BORDER`).
- **Deviation: camelCase fields.** Only allowed where a struct mirrors an external schema: config types that serialize to the profile JSON (`startX`), and Win32 struct definitions in `platform/win32.zig`. Everything else is `snake_case`. The same goes for enum tags: ones saved into profiles by name (`FontWeight.BoldItalic`) keep their spelling.
- **Deviation: Win32 message parameters.** Parameters carrying a Win32 message or hook's raw values keep their Win32 names, `wParam`, `lParam` and `nCode`, wherever they're passed on (window procedures, hook and enum callbacks, and helpers they hand them to). Never `lparam` or `code`. Other parameters of those callbacks follow the normal rules (`hwnd`, `msg`, `id_object`).
- **Import aliases** use the file stem (`lines`, `wire`, `scout`). Add `_mod` only when the bare stem would clash with a field, local, parameter, capture, or declaration in that file (`config_mod`, because `config` is a common field name). Don't add `_mod` pre-emptively. The one exception is `platform/virtual_keys.zig`, imported as `vk` after the Win32 term (`VK_*`).
- **Allocators**: `allocator` for a general allocator, `arena` when the caller is expected to pass an arena and the callee never frees. Not `alloc` or `gpa`.
- **Log scope** is the file stem, prefixed by its folder when the stem alone is ambiguous (`"activity_tracker"`). Files in one feature may share a scope (`"config"`) when their messages belong together.
- Name booleans as statements: `is_`, `has_` or `should_` for a state (`is_visible`, `is_enabled`, `has_focus`), past tense for a result of something that happened (`existed`, `added`), or a third-person verb (`wraps`, `shows_thumbnails`). A field mirroring an external API or the profile JSON keeps its name (knots' `.disabled`, config's `enabled`). Name counts `*_count` and indices `*_index`.
- Name a function that returns a value for what it returns (`runningName()`, not `running()`), so the plain noun stays free for locals: Zig forbids shadowing.
- A number used once, with a `///` saying why, may stay inline (`.min = 130`). A number two places must agree on gets a named constant (`NUMBER_WIDTH`).
- Include units in names when the type doesn't carry them: `interval_ms`, `window_seconds`, `event_timestamp`.
- Spell words out. `thumbnail` not `thmb`, `character_name` not `cname`, `timestamp` not `ts`, `Context` not `Ctx`, `delta_x` not `dx`, `point` not `pt`, `dimensions` not `dims`, `properties` not `props`, `name_length` not `name_len`. Single letters are fine only for Win32 names (`hwnd`, `hdc`, `rect`), loop captures (`i`, `it`), colour channels (`r`, `g`, `b`), the terms of a published formula (OKLab's `l`, `m`, `s`), and an `if (x) |v|` capture used within a line or two.
- A comparator's pair is `first` and `second`, never `a` and `b`.
- A null-terminated copy is `terminated_name`, not `name_z`.

## 3. Comments

Prefer clear code over comments. Do not comment code that is already self-explanatory.

Add a comment only when it explains why something is done, a non-obvious invariant, subtle Zig behavior, a workaround, or an important constraint. Before adding one, ask: "Would a competent Zig programmer understand the code without this?" If yes, leave it out.

- Never restate what the code does. No comments on obvious control flow, assignments, calls, or straightforward logic.
- Keep comments terse: one short sentence or less, judged by what it says, not its punctuation. No comment blocks, section headers (`// ==== Helpers ====`), or narrating the implementation.
- Two clauses may share a sentence with `;`. A comment that needs a third is carrying too much: shrink the signature, or move each fact onto the field it belongs to.
- Don't add comments just because you changed nearby code. Remove or fix redundant or inaccurate comments in code you touch.
- Judge a comment against the whole file and its callers, not the lines around it: what it claims may have changed further down, or a caller may already do what it describes.
- A doc comment adds only what the name and signature don't say. On `fillTextBackground`, write `/// Clipped to the buffer.`, not `/// Fills a text run's background rect, clipped to the buffer.`
- If a comment exists only because the code is unclear, fix the code in its own change rather than explaining it.
- Quoted game text stays verbatim, however long.

### Which comment to use

| Form | Use for |
|---|---|
| `//!` | File header (required, one line). |
| `///` | A `pub` declaration or field whose contract isn't obvious from its name and type. |
| `//` | Why a specific line or block does something surprising. |

### What `///` is for

A doc comment states a contract the signature can't express. These are worth writing:

- **Ownership:** `/// Takes ownership of cfg, freeing it on failure.` or `/// Borrows from the parsed line.`
- **Thread or lock requirements:** `/// Worker thread only.` or `/// Caller holds mutex.`
- **Units and sentinels:** `/// YYYYMMDDHHMMSS, or 0 if unreadable.`
- **Lifetime and order:** `/// Must only be called after the worker thread has stopped.`
- **Shape of `anytype`:** `/// patch mirrors Config's nesting, e.g. .{ .display = .{ .startX = 10 } }.`
- **Design choices a reader would otherwise "fix":** `/// Searched linearly: there are only ever a few dozen.`

Zig gives parameters no doc comments, so when several parameters or an `anytype`'s members each need a contract, give each, or each kind, its own line under an optional one-line summary: ``/// `covered`: only the first MAX_COVERED count.`` or ``/// `Window` methods: `redraw` and `toggleCollapsed`.`` Prefer an options struct whose fields carry their own docs when the signature can take one.

Don't write `/// Initializes the struct.` on `init`, `/// Returns the name.` on `getName`, or parameter-by-parameter lists.

Each field keeps its own ownership or thread doc. Don't merge them into one comment (`/// Both strings owned.`), which stops applying as soon as a field is added or moved.

### TODOs

Don't leave `TODO`/`FIXME` in committed code. Fix it, or track it outside the source.

## 4. Error handling

Always log before giving up on a failure. Whether "giving up" means `return err` (propagate) or `return` or a fallback (stop here) is set by the function's own return type, not a free choice. Never write a bare `catch {}` or an unlogged `catch return;` outside the three exceptions below.

- A `!T`-returning function propagates: `try`, or `catch |err| { slog.err(...); return err; }` when the call site has context worth adding before it bubbles up.
- Anything else (`void`, `?T`, WinEvent/extern callbacks that can't return an error) logs via `slog` and stops.
- If the callee's doc comment says it logs its own failures (e.g. `http_client.fetch`), a caller may `catch return` without logging again.
- **Exception, statically-safe formatting:** `catch unreachable` on a buffer that provably can't overflow asserts there's no failure; it isn't handling one. A float from the user or a file is never provably safe, since `{d}` can print hundreds of digits: format it into an arena with `allocPrint` instead.
- A logged fallback reads `catch |err| blk: { slog.warn("Failed to ...: {}", .{err}); break :blk fallback; }`, never a bare `catch fallback`.
- **Exception, teardown paths:** a destructor or shutdown path, or the logger's own write/rotate code, can't act on the failure, and logging would be circular or pointless. Silent `catch {}` is fine.
- **Exception, high-frequency formatting:** per-tick or per-row writes into a bounded writer (e.g. `list_view.zig`'s stat text), where a truncated fallback is visible on screen. Logging would spam, so silent `catch {}` is fine.
- **Error names:** default to `XxxFailed` for "an OS/API call didn't succeed." Use `MissingX`/`InvalidX` for validation or parsing failures where the reason matters. Give two errors from the same feature different shapes only when callers branch on the difference, and comment why.
- **`!T` vs `?T`:** prefer `!T` unless "no value" is a normal, expected outcome (a lookup allowed to miss).
- **Raw Win32 BOOL/handle returns:** check and log/propagate on first-time resource creation (`CreateWindowExA`, `SetTimer` at startup, `SetWindowsHookExA`). Discard with `_ =` for calls that reconfigure or tear down an already-valid resource (`ShowWindow`, `SetWindowPos`, `DestroyWindow`, `KillTimer`, `ReleaseDC`). Check the API's documented return first: some (`ShowWindow`) return the *previous* state, not success or failure.
- **`errdefer`** goes on the line right after the acquisition it undoes.
- No `@panic` and no `orelse unreachable` on values that come from the OS, files, or users.

### Log messages

- Start with `Failed to <verb> ...` for failures. Sentence case, no trailing period.
- An expected "nothing to do" outcome, e.g. a cycle hotkey with no character running, isn't a failure: log it at `info` or `debug`, without the prefix.
- In `warn` and `err` messages, quote names and paths with `'{s}'` so empty or space-padded values are visible.
- Put the error last: `slog.err("Failed to load profile '{s}': {}", .{ name, err });`
- Choose the level by what the user loses: `err` for lost data or a broken feature, `warn` for a degraded fallback, `info` for state changes worth seeing in a bug report, `debug` for everything else.
- Use `slog` only. `std.debug.print` belongs inside `log.zig`.

## 5. Memory and ownership

- A type that owns resources has `pub fn init(...) T` (or `!T`) and `pub fn deinit(self: *T) void`. Heap-allocated singletons use `create`/`destroy`.
- `deinit` frees everything the type owns and never fails.
- Store an `allocator` field only when the struct owns allocations it has to free later. Otherwise take it as a parameter.
- `std.ArrayList` is unmanaged (since 0.16): pass the allocator to `append`/`deinit`, and don't wrap it to hide that.
- Document ownership on every `[]const u8` or pointer field or return value that isn't obviously owned: "Borrows from X" or "Owned; freed in deinit".
- Use an arena for build-then-discard work (parsing an import, building a JSON reply). Free the arena, not its contents.
- Pair every allocation in a loop with `errdefer` or explicit cleanup on the `continue` path (see `SystemNameSnapshot.capture`).

## 6. Idioms

- **Decl literals:** prefer `.init`, `.empty`, `.{}` and `.fromMilliseconds(1)` where the result type is known: `.names = .init(allocator)`. For a local, put the type on the left so it is: `var arena: std.heap.ArenaAllocator = .init(allocator);`, not `var arena = std.heap.ArenaAllocator.init(allocator);`. The same goes for `try .init(...)` and struct literals (`const entry: PendingAutoMove = .{ ... }`).
  - **Exception, `catch`:** `catch` doesn't pass the result type to its left side, so `var session = Session.init() catch ...` keeps the type on the right.
  - **Deviation: knots UI.** Files importing `ui` build their trees from `const row = Rect{ ... }` literals; keep that form there.
- **Deprecated std:** don't use what the standard library marks `/// Deprecated` (`std.fmt.bufPrint`, `std.mem.indexOf`, `std.StaticBitSet`, ...); use what its doc comment names. `style_check.py` lists them.
- **`Self`:** use `const Self = @This();` only inside a type-returning function (generics). Everywhere else, name the type: `self: *ProfileStore`.
- **Receivers:** `self: *const T` for read-only methods, `self: *T` for mutating ones, `self: T` only for small value types. A type declared inside a method that already has `self` names its receiver for what it is (`context`), since Zig forbids the shadow.
- **Optionals:** unwrap with `orelse return`, `orelse continue`, or `if (x) |v|`. Avoid `.?` unless a line above proves it's non-null. `.?` on a comptime-known value is fine, since a null is a compile error rather than a crash.
- **`unreachable`** is fine where a `///` documents the precondition that rules the case out, e.g. "`position` must be below the total". Never for values from the OS, files or users.
- **Switches on project enums:** list every variant, no `else =>`, so adding a variant is a compile error at every site that needs updating.
- **Saturating and wrapping operators** (`-|`, `+%`) show intent. Use them rather than manual clamps.
- **`anytype`:** only for comptime reflection (config patches, generic writers). Document the expected shape with `///`.
- **Early returns** over nested `if`s. Guard clauses first.
- **Two or more `bool` parameters** become an options struct or an enum, so a call doesn't read `init(index, count, true, true)`.
- **Slices over pointers** plus lengths. Fixed buffers on the stack (`var buf: [256]u8 = undefined;`) for bounded formatting.
- **`comptime` checks** (`comptime std.debug.assert(...)`, `@compileError`) for invariants between types, such as a wire struct matching its config struct.

## 7. Globals and threads

- Keep globals to what Win32 callbacks and singletons need. Everything else goes through a struct.
- **Deviation: dialog state.** The config window and region select are one-instance, main-thread UIs: each file keeps its scratch state (drags, prompts, the selected tab) in `g_` globals. Settings never live there, since each open re-reads them; per-open scratch state is reset by the file's open/start function, and the rest are run-long caches (cursors, fonts, handles). Where that state is large enough that a hand-written reset could miss a variable, keep it in one struct the start function replaces whole (`region_select.zig`'s `Session`). Don't propose this for files whose few globals reset plainly; report only a concrete stale-state bug.
- Pointer globals set at startup are `?*T = null`, and unwrapped at the use site.
- Every field that more than one thread can reach has a doc comment naming its owning thread or the mutex that guards it. Declare the mutex next to the fields it guards.
- Data owned by one thread stays owned by that thread. Hand data over through a queue (`chatlog/queue.zig`) rather than sharing it under a lock.

## 8. Win32

- Win32 declarations live in `platform/win32.zig`. The only exception is a library used by one module alone (winmm in `sound.zig`, SAPI in `tts.zig`), which may declare its own `extern`s.
- `win32.zig` groups declarations by API area (messages, GDI, COM, ...) rather than §1's constants-types-functions order, so related declarations sit together.
- Wrap anything reused in more than one place in a small helper in `platform/`.
- `win32.zig` doesn't log. Its helpers report failure through their return value, and callers log.
- `HWND_TOP` as `@ptrFromInt(0)` doesn't compile against the non-`allowzero` `HWND`. Use `HWND_NOTOPMOST` with `SWP_NOZORDER` instead.
- Extern callbacks (`WNDPROC`, WinEvent hooks) use `callconv(.c)`, can't return errors, and so follow the log-and-stop rule.

## 9. Module organization

- Group modules in feature subfolders (`chatlog/`, `notifications/`, `config/`). A top-level `src/foo.zig` is for a feature's entry point or a genuinely cross-cutting module.
- Keep logic that needs no Win32, I/O or globals (parsing, layout math, formatting) in pure functions. When it's substantial or the host file imports `platform/`, give it its own file, e.g. `chatlog/lines.zig` ("no I/O"), so tests can import it without the app. Don't split a few trivial lines just to test them.
- Split a file when it has two unrelated reasons to change, not at a line count.
- Avoid import cycles through `main.zig`. Pass what a module needs in, rather than reaching back up for it.

## 10. Tests

- Pure modules carry `test` blocks at the bottom of the file and are listed in `src/tests.zig`.
- Name tests as a claim: `test "undock line with a station containing ' to ' uses the last one"`.
- Use `std.testing.allocator` so leaks fail the test.
- Test code doesn't touch Win32, the filesystem, or globals.

## Checklist for a file

- [ ] One-line `//!` header
- [ ] Imports ordered; `_mod` only where there's a clash; `slog` declared if the file logs
- [ ] Constants `SCREAMING_SNAKE`, globals `g_`, fields `snake_case` (unless mirroring JSON or Win32)
- [ ] No comment that restates code; every `///` states a contract
- [ ] Every comment is one sentence and still true of the code as it stands
- [ ] No comment refers to code that no longer exists, and no doc comment sits on the wrong declaration
- [ ] No bare `catch {}` or unlogged `catch return` outside the three exceptions
- [ ] Every owned resource has `deinit`; every acquisition that can leak has `errdefer`
- [ ] Borrowed slices and cross-thread fields are documented
- [ ] Exhaustive switches on project enums
- [ ] Pure logic split out and tested where practical
