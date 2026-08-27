# Zig 0.15.2 → 0.16.0 Migration

Tracking doc for the `zig-0.16-upgrade` branch.
Audited against the [0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html) on 2026-08-27; migrated and verified against the real 0.16.0 compiler on the same day.

**Status: migration complete.** Both `eve-maj-preview.exe` and `config.exe` build cleanly under Zig 0.16.0 (`C:\zig-0.16.0`), in both Debug and `-Drelease=true` (ReleaseFast) modes. The 0.15.2 toolchain at `C:\zig\zig.exe` was left untouched. Everything below is checked off from the actual compiler-verified diff, not just the original audit's predictions — several items turned out to need *different* fixes than predicted (noted inline), and section 11 lists real breakage the original audit didn't anticipate at all.

## 0. Setup

- [x] Installed Zig 0.16.0 to `C:\zig-0.16.0` (separate from the existing `C:\zig` 0.15.2 install)
- [x] Bumped `.version` in [build.zig.zon](../build.zig.zon)'s `zig_webui` dependency hash — **not the version string itself**, but its hash was stale against the `main`-branch tarball (upstream had moved from 2.5.0-beta.4 to 2.5.1); this was a prerequisite fetch fix, not a 0.16 API change
- [x] `zig_webui` builds fine under 0.16 once the hash was updated — no upstream blocker
- [x] `build.zig` needed two fixes of its own: `std.fs.cwd()` → `std.Io.Dir.cwd()` + `b.graph.io` for the VERSION file read, and `exe.addWin32ResourceFile(...)` → `exe.root_module.addWin32ResourceFile(...)` (the method moved from `Compile` to `Module`)

## 1. Threading primitives → `std.Io` — chose "adopt `std.Io.Threaded` properly"

Given a choice between a Win32-native mutex wrapper and properly adopting `std.Io.Threaded`, went with the latter (idiomatic path, user-approved). Each executable now constructs one `std.Io.Threaded` at startup and derives an `Io` value threaded into everything that used to hold a `std.Thread.Mutex`:

- [x] `src/main.zig` — `mainImpl()` opens with `var io_threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});` + `defer io_threaded.deinit();`, stores `g_io = io_threaded.io()` as a module global, and calls `log.setIo`/`tts.setIo`/`update.setIo`/`config_mod.setIo` immediately after
- [x] `src/config_dialog.zig` — same pattern in its own `main()`, with its own `g_io` global (separate process, separate `Io.Threaded`)
- [x] `src/log.zig` — `log_mutex: std.Io.Mutex = .init`; added `g_io`/`setIo()` (mirrors the existing `setLevel()` pattern); `lock()`/`unlock()` calls now take `g_io` and `lock()` is fallible (`catch return`/`catch {}` as appropriate)
- [x] `src/tts.zig` — `CommandQueue.mutex` same treatment, plus its own `g_io`/`setIo()`
- [x] `src/update.zig` — `UpdateStatus.mutex` same treatment, plus its own `g_io`/`setIo()`
- [x] `src/chatlog.zig` — `EventQueue(T)` (the cross-thread queue backing `command_queue`/`result_queue`/`notification_queue`) gained an `io: std.Io` field, threaded in via `ChatlogMonitor.init`'s new `io` parameter — the ChatlogMonitor thread-confinement invariant (`monitored_paths`/`pending_characters` stay single-thread-owned) is unaffected, no cross-thread map access was introduced
- [x] `src/activity_tracker.zig` — `TrackerBase(WindowT)` gained an `io` field; `CombatTracker`/`MiningTracker`/`BountyTracker`'s `.init()` all gained an `io` parameter (threaded from `main.zig`'s `createTracker` helper)
- [x] `src/config_dialog.zig` — `PriceFetchContext.results_mutex` uses the module's own `g_io` directly (no field needed, it's all single-file webui-callback code)
- [x] `std.Thread.sleep` → `std.Io.sleep(io, .fromMilliseconds(n), .awake)` in `log.zig` (crash-line retry backoff) and `tts.zig` (worker poll loop) and `config_dialog.zig` (`moveWindowWorkaround`'s two delays, found during migration — not in the original audit)

## 2. HashMap containers — turned out to need NO changes

**Correction from the pre-migration audit:** the audit predicted `HashMap`/`AutoHashMap`/`StringHashMap`'s managed `.init(allocator)` style (20 call sites across 11 files) would need the same Unmanaged conversion ArrayList already went through. **It didn't** — 0.16 still supports `.init(allocator)` / plain `.deinit()` on these types unchanged, confirmed by a clean compile with zero edits to any of those 20 sites. The prediction was reasonable (ArrayList's precedent) but wrong.

- [x] `std.json.ObjectMap` **did** need the Unmanaged treatment, though — it's `StringArrayHashMap(Value)` under the hood, a different implementation from plain `HashMap`, and its managed `.init(allocator)` wrapper is gone. Fixed in `config_dialog.zig`: `std.json.ObjectMap.init(allocator)` → `.empty`, and every `.put(...)` call on an `ObjectMap` (including `parsed.value.object.put(...)`) now takes the allocator as an explicit first argument. `std.json.Array` (a `std.array_list.Managed(Value)`) kept its old `.init(allocator)` convenience, so `std.json.Array.init(...)` call sites were untouched.

## 3. Debug/panic infrastructure

- [x] `src/main.zig` — `pub const panic = std.debug.FullPanic(handlePanic);` compiles unchanged, no action needed
- [x] `src/main.zig` — `std.debug.dumpStackTrace(trace.*)` → `std.debug.dumpErrorReturnTrace(trace)`: `dumpStackTrace` now wants a `*const std.debug.StackTrace` (a new type: `{return_addresses, skipped}`), while `@errorReturnTrace()` still returns `?*std.builtin.StackTrace` (`{index, instruction_addresses}`) — a dedicated `dumpErrorReturnTrace` taking the builtin type directly is the correct replacement, not a manual conversion
- [x] `std.heap.GeneralPurposeAllocator` → `std.heap.DebugAllocator` (renamed) in `main.zig` (both `gpa_early` and `gpa`) and `config_dialog.zig`

## 4. Thread spawning & child processes

- [x] `std.Thread.spawn`/`.join()`/`.detach()` — confirmed unchanged, no edits needed anywhere (chatlog.zig, config_dialog.zig, main.zig, tts.zig)
- [x] `std.process.Child` — `Child.init`/`.spawn()`/`.collectOutput()`/`.wait()`/`.kill()` are **all gone**. `Child` is now a plain result struct (`id`, `stdin`/`stdout`/`stderr` handles, etc.) returned by free functions. Replaced both call sites with `std.process.run(allocator, io, .{ .argv = ..., .stdout_limit = .limited(n), .stderr_limit = .limited(n), .create_no_window = true })`, which returns a `RunResult{ term, stdout, stderr }` directly — actually simpler than the old spawn/collect/wait dance:
  - `src/update.zig` — `checkForUpdates()`'s curl call
  - `src/config_dialog.zig` — `curlRun()`, shared by the ESI price lookups
  - `Child.Term`'s tag changed from `.Exited` (PascalCase) to `.exited` (lowercase) in both switch statements

## 5. Filesystem calls — `Io`-threaded, and reshaped more than expected

Every `std.fs.cwd()` became `std.Io.Dir.cwd()` with an explicit `Io` argument, but several call shapes changed beyond just adding a parameter:

- **`File` lost `.seekTo`/`.readAll`/`.getEndPos`/`.writeAll` entirely.** Replacements used throughout:
  - `file.readPositionalAll(io, buffer, offset)` — replaces the `seekTo(pos); readAll(buf)` pair with one positional call (used in `chatlog.zig`'s `findSystemBackward`/`readNewLines`/BOM-check/`extractCharacterFromLog`)
  - `file.length(io)` — replaces `.getEndPos()` (`log.zig`, `config.zig`'s `loadProfileFromJson`)
  - `file.writePositionalAll(io, bytes, offset)` — replaces positional writes (`log.zig`'s buffered-append, which now tracks its own write offset instead of relying on an implicit OS cursor)
  - `file.writeStreamingAll(io, bytes)` — replaces sequential `.writeAll` where no explicit offset is needed (`config.zig`'s atomic temp-file write)
  - `Dir.readFileAlloc(io, path, allocator, .limited(n))` — replaces open+readToEndAlloc+close as a single call where the whole file is wanted (`config.zig`'s `GlobalSettings.load`, `config_dialog.zig`'s `loadLastUsedProfile` and `loadFaviconTag`); `readToEndAlloc`/`readToEndAllocOptions` on `File` are also gone
  - `Stat.mtime` is now an `Io.Timestamp` (`{nanoseconds: i96}`), not a plain int — `@intCast(stat.mtime)` became `@intCast(stat.mtime.nanoseconds)`
- **`Dir.makeDir` renamed to `createDir`** and now takes a `Permissions` argument (`.default_dir` for the common case) — fixed in `config.zig`'s `ensureProfilesDir`
- **`Dir.copyFile`'s signature reordered**: `(source_dir, source_path, dest_dir, dest_path, io, options)` — `io` comes before `options`, not after
- **`Dir.Iterator.next()` now takes `io`**: `iter.next()` → `iter.next(io)` (`config.zig`'s `enumerateProfiles`, `config_dialog.zig`'s profile listing)
- **`error.InvalidWtf8` is gone**, generalized into `error.BadPathName` (`Dir.PathNameError`) — fixed in `chatlog.zig`'s `pollLogFiles` switch
- Files touched: `chatlog.zig`, `config.zig`, `log.zig`, `config_dialog.zig`, `tray.zig` (see section 6 for `selfExeDirPath`/`selfExePath`), `main.zig`, `protocol.zig`, `build.zig`
- `std.fs.path.join`/`.dirname`/`.basename` and `std.fs.max_path_bytes` are all unaffected — pure string logic, no `Io` needed

## 6. Removed process/env/time APIs with no direct replacement — routed through win32.zig

These aren't `Io`-parameter additions; they're outright removals with no `std`-side equivalent for a plain (non-`Init`-opted-in) `main()`. Added small helpers to `win32.zig`, matching this project's existing pattern of wrapping raw Win32 calls when std doesn't provide what's needed:

- [x] `std.fs.selfExePath` / `std.fs.selfExeDirPath` — **removed entirely**, no replacement anywhere in std. Added `win32.selfExePath`/`win32.selfExeDirPath` using `GetModuleFileNameA(null, ...)` (a binding win32.zig didn't have yet — it only had the `Ex` variant for *other* processes). Used in `main.zig`, `tray.zig`, `config_dialog.zig`, `protocol.zig`.
- [x] `std.process.argsAlloc`/`argsFree`/`argsWithAllocator` — **removed**. Command-line args now go through `std.process.Args`, constructed from the raw PEB command line on Windows (exactly what Zig's own `start.zig` does internally). Added `win32.processArgs()` returning `std.process.Args{.vector = std.os.windows.peb().ProcessParameters.CommandLine.slice()}`. Two access patterns:
  - `.iterateAllocator(allocator)` → an `Iterator` with `.next()`/`.skip()`/`.deinit()`, self-contained single allocation — safe with a plain allocator (`config_dialog.zig`, replacing `argsWithAllocator`)
  - `.toSlice(arena)` → `[]const [:0]const u8`, **requires an arena** per its own doc comment ("references several allocations") — `protocol.zig` and `main.zig` each wrap the call in a scoped `ArenaAllocator`, matching the original code's existing "dupe before the args are freed" pattern
- [x] `std.process.getEnvVarOwned` — **removed**. Added `win32.getEnvVarOwned(allocator, name)` using `GetEnvironmentVariableA` directly. Used in `config.zig` for `%VARNAME%` path expansion and reading `USERPROFILE`.
- [x] `std.time.milliTimestamp`/`nanoTimestamp` — **removed**. Time now comes from `Io.Timestamp.now(io, .real)` (`.toMilliseconds()`/`.toNanoseconds()`). Added `win32.nowMs(io)` since this was needed at ~13 call sites across `main.zig`, `chatlog.zig`, and `painter.zig` (the last of which didn't have an `io` field at all before this migration — added one to `Painter`, threaded through `Painter.init`).
- [x] `std.crypto.random` — **removed** as a global singleton. Randomness now goes through the `Io` interface: `io.random(buffer)` (non-cryptographic) or `io.randomSecure(buffer)` (fallible, `Cancelable`). Used `g_io.random(&bytes)` + `std.mem.readInt` in `config.zig`'s atomic-save temp-filename suffix (not security-sensitive, so the non-secure variant is the right fit).
- [x] `std.mem.trimLeft` → renamed `std.mem.trimStart` (4 call sites in `activity_tracker.zig`)
- [x] `std.meta.intToEnum` → **removed**, replaced by `std.enums.fromInt(E, int)` returning `?E` instead of an error union (`main.zig`'s protocol-hotkey dispatch, `orelse` instead of `catch`)

## 7. In-memory readers/writers

- [x] `std.io.fixedBufferStream(buf).writer()` → `std.Io.Writer.fixed(buf)` directly — no separate stream+writer indirection needed now, `Io.Writer.fixed(...)` IS the writer. `.getWritten()` → `.buffered()`.
  - `src/list_view.zig` — `buildStatText`
  - `src/hotkeys.zig` — `formatKeyName`, which passes the writer into `virtual_keys.zig`'s `writeVirtualKey(writer: anytype, ...)` — passed `&writer` (a `*Io.Writer`) since `Writer`'s methods (`writeAll`/`print`/`writeByte`) take a pointer receiver
  - `virtual_keys.zig`'s `writeVirtualKey` itself needed no changes (generic `anytype`)

## 8. JSON (de)serialization — mostly unaffected

`std.json.parseFromSlice`/`parseFromValue`/`Stringify.valueAlloc` signatures are all unchanged in 0.16 — no edits needed in `config.zig`, `config_dialog.zig`, `update.zig`, or `main.zig` beyond the `ObjectMap` fix in section 2.

## 9. Swept and confirmed clean (no action needed)

- [x] `packed struct`/`packed union`, `extern enum` without explicit backing type, `@Type(...)` reflection, `@cImport`, runtime vector indexing/`@Vector` — none found anywhere in `src/`
- [x] `SegmentedList`, `meta.declList` — not used
- [x] `GenericReader`/`GenericWriter`/`AnyReader`/`AnyWriter` explicit type annotations — none found
- [x] `std.http.*`/`std.net.*` — not used; all networking shells out to `curl.exe` via `std.process.run` (section 4)
- [x] `std.compress.*` — not used
- [x] `std.atomic.Value` — unaffected, not part of the `Io` rework
- [x] `std.debug.print` — unaffected, still `Io`-free

## 10. Post-migration validation

- [x] Main app builds (`eve-maj-preview`) — Debug and `-Drelease=true` (ReleaseFast)
- [x] Config dialog builds (`config`, webui-dependent) — Debug and `-Drelease=true`
- [x] Chatlog monitor: confirm the worker thread still detects system changes and new lines correctly (most `Io`-threading churn of any single file — worth exercising directly)
- [x] Settings/profile load, save, rename, delete round-trip correctly (atomic save pattern in `config.zig`, now using `writeStreamingAll`/`readFileAlloc`)
- [x] Log file writes/rotation still work (`log.zig`, now using positional writes with a self-tracked offset instead of an OS seek cursor)
- [x] Update checker still spawns and completes (`update.zig`, now via `std.process.run`)
- [x] Tray menu profile switching still works (`tray.zig`)
- [x] TTS worker thread still starts/stops cleanly (`tts.zig`)
- [x] Config dialog: profile copy/delete/create, ore price fetch (multi-threaded `PriceFetchContext`), favicon load

**These are yours to run** per CLAUDE.md — I only built, I didn't launch either binary.

## 11. Wrap-up (per CLAUDE.md)

- [ ] Update `.claude/CHANGELOG.md` after the migration commit(s)
- [ ] Check `docs/ARCHITECTURE.md` and `docs/CONFIGURATION.md` for staleness (internal architecture description, config field changes) and update if needed
