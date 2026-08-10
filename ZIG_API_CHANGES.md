# Zig 0.17-dev API migration notes

General-purpose reference for Zig 0.17.0-dev (master branch) breaking API
changes, collected across multiple projects being ported from older Zig
versions. Not tied to any one codebase — drop this into a new project's
docs so a fresh session doesn't have to rediscover these one `zig build`
error at a time.

0.17-dev is bleeding-edge enough that public docs/blogs, and even Zig's
own *master*-branch source, can disagree with whatever specific dev
snapshot a project is actually pinned to. **When a std API guess fails to
compile, don't guess again from web search — grep the actual installed
`lib/std` for the real signature instead.** Two separate web-search
guesses for a cwd-as-string API both failed to compile against one real
snapshot before grepping local source turned up the actual, differently
shaped function (`std.process.currentPathAlloc` — see below). Prefer
grepping local source over searching the web whenever a local install is
reachable, and treat a specific snapshot string (`0.17.0-dev.NNNN+hash`)
as liable to go stale within days.

## build.zig / build.zig.zon

- **`fingerprint` is required.** `build.zig.zon` needs a real
  `.fingerprint = 0x...` value (not a placeholder). The compiler prints
  the correct value to use on first build failure if it's wrong/missing.
- **`addExecutable` / `addTest` / `addLibrary` don't take
  `.root_source_file` / `.target` / `.optimize` directly** — wrap them in
  a module:
  ```zig
  const exe = b.addExecutable(.{
      .name = "foo",
      .root_module = b.createModule(.{
          .root_source_file = b.path("src/main.zig"),
          .target = target,
          .optimize = optimize,
      }),
  });
  ```
  Same shape applies to `b.addTest` and `b.addLibrary` (e.g. dynamic
  libraries with `.linkage = .dynamic`, one `root_module` per built
  artifact).
- **`b.args` was removed** as part of the 0.17 build-system rework
  (separates configuration from execution). Replace:
  ```zig
  if (b.args) |args| run_cmd.addArgs(args);
  ```
  with:
  ```zig
  run_cmd.addPassthruArgs();
  ```

## `std.ArrayList`

Unmanaged by default since 0.15 (`ArrayList: make unmanaged the
default`). The list no longer stores an allocator; every mutating call
takes one.

- `std.ArrayList(T).init(gpa)` → `var x: std.ArrayList(T) = .empty;`
- `x.deinit()` → `x.deinit(gpa)`
- `x.append(item)` → `x.append(gpa, item)`
- `x.appendSlice(items)` → `x.appendSlice(gpa, items)`
- `x.toOwnedSlice()` → `x.toOwnedSlice(gpa)`

In a codebase mid-port, some call sites may already be on the new API
while sibling files are still on the old one — check every `ArrayList`
use individually rather than assuming the whole tree is consistent.

Unaffected: `std.Io.Writer.Allocating`, `std.heap.*Allocator`, and other
types that store their own allocator internally still use bare
`.deinit()`.

## `std.Io.Writer.Allocating`

- `.getWritten()` → `.written()`.

## `std.zig.Ast`

- `Ast.parse(gpa, source, mode)` no longer takes a bare `Mode` enum
  value — it takes a `ParseOptions` struct:
  ```zig
  Ast.parse(gpa, source, .{ .mode = .zig })
  ```
  (Confirm the struct's field name is actually `mode` if this resurfaces
  — only the shape of the error, not the exact field name, has been
  double-checked against source so far.)

- **Optional node references are wrapped types, not sentinel integers.**
  Fields like `VarDecl.init_node`, `type_node`, `align_node`,
  `else_expr`, `cont_expr`, `value_expr`, etc. used to be a plain
  `Node.Index` where `0` meant "absent." They're now `Node.OptionalIndex`
  — a distinct enum type — so `if (x == 0)` no longer compiles
  (`incompatible types: 'zig.Ast.Node.OptionalIndex' and
  'comptime_int'`). Unwrap explicitly:
  ```zig
  const value_node = decl.ast.init_node.unwrap() orelse return null; // ?Node.Index -> Node.Index
  ```
  Confirmed in `Ast.zig`: `Node.Index.toOptional() -> OptionalIndex`,
  `Node.OptionalIndex.unwrap() -> ?Node.Index`. The equivalent
  `TokenIndex`/`TokenOffset`/`Offset` types follow the same
  `toOptional()`/`unwrap()` pattern — expect the same fix shape anywhere
  else in `Ast.zig`'s API surface that used to compare against a
  sentinel `0`.

## `std.builtin.Mode` / `OptimizeMode` moved to `lang.Optimize`

Compiler error: `no field named 'Debug' in enum 'lang.Optimize'`,
pointing into `std/lang.zig`. The old `std.builtin.Mode`
(`Debug`/`ReleaseSafe`/`ReleaseFast`/`ReleaseSmall`) has moved under the
same `std/lang.zig` reflection relocation as `@typeInfo` (see below), and
may also have been renamed to lowercase/snake_case variants in the
process (per the field-naming complaint in ziglang/zig#23551). The exact
new field names haven't been pinned down yet — if all a call site needs
is "is runtime safety on," `std.debug.runtime_safety: bool` sidesteps
the enum entirely and is a much safer bet than guessing the new tag
casing blind. If a project genuinely needs the `Debug`/`ReleaseSafe`/etc.
tag names (e.g. for an `-Doptimize`-driven codepath), dump
`std/lang.zig` around the `Optimize` declaration first rather than
guessing the casing.

## `std.ArrayList(T).getLast()` now returns an optional

Compiler error shape: `optional type '?T' does not support field
access`. `getLast()` used to return `T` (presumably asserting/panicking
on an empty list, or only ever called after a length check); it now
returns `?T` unconditionally — every call site becomes the same shape as
the old `getLastOrNull()`. Typical fix where the caller already guards
`items.len > 0` immediately before calling `getLast()`: `.getLast()` →
`.getLast().?`. **`getLastOrNull()` was removed outright** (`no field or
member function named 'getLastOrNull'`) — it isn't just that
`getLast()` gained optional-returning behavior, `getLastOrNull` no
longer exists at all since `getLast()` now covers that case itself.
Existing `if (p.x.getLastOrNull()) |y| { ... }` call sites need only the
rename to `getLast()`, since the returned shape (`?T`) is identical.

## `std.mem`

- `std.mem.trimRight` → `std.mem.trimEnd`
- `std.mem.trimLeft` → `std.mem.trimStart`
  (renamed because "left/right" is ambiguous for RTL scripts;
  "start/end" is unambiguous)

## `Allocator.dupeZ` removed

`no field or member function named 'dupeZ' in 'mem.Allocator'`. Plain
`Allocator.dupe` (no sentinel) is unaffected — this looks like the
sentinel-returning convenience wrapper specifically was dropped, not a
broader `Allocator` API change. Fix: `allocator.allocSentinel(u8,
source.len, 0)` + `@memcpy` in place of `allocator.dupeZ(u8, source)`;
or, if reading a sentinel-terminated file from disk, use
`dir.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0)`
directly (see filesystem section below) instead of dupe-ing after a
separate read.

## `std.heap.GeneralPurposeAllocator` → `std.heap.DebugAllocator`

Same shape (`std.heap.DebugAllocator(.{}){}`, `.allocator()`,
`.deinit()`) — a rename only, not a behavior change. The old name is
gone entirely (not even a deprecated alias) on recent dev snapshots, so
`GeneralPurposeAllocator` errors with "no member named" rather than a
deprecation warning.

## Process/entry-point rework ("juicy main")

The biggest change in this migration — not a rename, a restructuring of
how a program gets its allocator/args/env at all. Tied to
`std.os.environ`/`std.os.argv` being deleted (both were unsound in a
threaded context) and process APIs moving onto the new `std.Io`
interface.

- **`std.process.argsAlloc`/`argsFree` are gone**, and so is the old
  freestanding `std.process.args()` iterator. There is no longer any way
  to fetch CLI args except through `main`'s parameter.
- **`pub fn main` can take a parameter now.** The compiler dispatches on
  `@typeInfo(@TypeOf(root.main)).@"fn".param_types` (see
  `lib/std/start.zig`, `callMain`):
  - No parameters → old behavior, no way to reach argv/environ/io from
    inside `main` at all.
  - One parameter of type `std.process.Init.Minimal` → lightweight path,
    only `.args`/`.environ`, no allocator/io/arena.
  - One parameter of type `std.process.Init` (the full struct) → the
    runtime builds a `gpa`, an arena, and a threaded `std.Io` for you,
    and passes them in.
- **Typical usage of the full `std.process.Init`:**
  ```zig
  pub fn main(init: std.process.Init) !void {
      const gpa = init.gpa;   // already leak-checked in debug builds
      const io = init.io;     // threaded Io instance
      const args = try init.minimal.args.toSlice(init.arena.allocator());
      ...
  }
  ```
  - `init.gpa` replaces manually constructing a `DebugAllocator` — the
    runtime owns it and calls `deinit()` on your behalf on the way out;
    don't wrap it in your own `defer gpa_state.deinit()`.
  - `init.minimal.args` is a `std.process.Args`, not a ready-made slice.
    Get one of:
    - `args.iterate()` / `args.iterateAllocator(gpa)` → an `Iterator`
      with `.next()`/`.skip()`, for streaming access.
    - `args.toSlice(arena)` → `[]const [:0]const u8`, matching the old
      `argsAlloc` shape. **Must be an arena-style allocator** — the doc
      comment says returned slices may point into multiple internal
      allocations and into the allocator itself, so a plain `gpa`
      expecting one-free-per-alloc will not work correctly; use
      `init.arena.allocator()`.
  - No more manual `defer std.process.argsFree(gpa, args)` when using
    the arena path — it's torn down for you on process exit.
  - `init.environ_map` is the equivalent of the old
    `std.os.environ`/`std.process.getEnvMap`, for a project that needs
    env vars.

## Filesystem API moved to `std.Io.Dir` / `std.Io.File`

`std.fs.cwd()`, `Dir.openFile`, `Dir.createFile`, `File.writeAll`,
`File.readAll`, `Dir.makePath`, etc. are gone from `std.fs` entirely —
that namespace is now just path-string helpers
(`std.fs.path.{dirname,join,basename,stem,...}`, though annotated
deprecated in favor of `std.Io.Dir.path` in some snapshots) plus a
couple of `base64` re-exports. All actual filesystem *operations* moved
to `std.Io.Dir`/`std.Io.File`, and every operation now takes an explicit
`io: std.Io` argument (get one from `std.process.Init.io`, see above).

| Old (`std.fs`) | New (`std.Io.Dir` / `std.Io.File`) |
|---|---|
| `std.fs.cwd()` | `std.Io.Dir.cwd()` — no `io` needed for this one |
| `dir.openFile(path, opts)` | `dir.openFile(io, path, opts)` |
| `dir.createFile(path, opts)` | `dir.createFile(io, path, opts)` |
| `dir.makePath(path)` | `dir.createDirPath(io, path)` — same "ok if already exists as a dir" semantics |
| `file.close()` | `file.close(io)` |
| `file.stat()` | `file.stat(io)` |
| `file.writeAll(bytes)` | no direct equivalent on an open `File` — either build a `std.Io.Writer` via `file.writer(io, buffer)` and use its `.interface`, or (simpler, for "create + write once" cases) skip opening the file yourself and call `dir.writeFile(io, .{ .sub_path = ..., .data = ..., .flags = ... })`, which does open+write+close internally |
| `file.readAll(buf)` after manual `stat()`+`allocSentinel` | `dir.readFileAllocOptions(io, path, gpa, limit, alignment, sentinel)` — one call, handles the read, supports an optional sentinel byte directly (pass `0` for `[:0]u8`), takes an `Io.Limit` (`.unlimited` or `.limited(n)`) instead of a manually-checked byte count |

`std.fs.max_path_bytes` (the path-string-helpers side of `std.fs`) is
still valid — it's specifically the *operations* that moved, not every
symbol under `std.fs`.

Manual `stat()`+`allocSentinel`+`readAll()`+short-read-check sequences
collapse to a single `dir.readFileAllocOptions(io, path, gpa,
.unlimited, .of(u8), 0)` call. Manual `createFile`+`writeAll`+`close`
sequences collapse to a single `dir.writeFile(io, .{ .sub_path = ...,
.data = ... })` call.

**Threading `io` through:** since `std.Io` values only come from
`std.process.Init.io` (no free-standing "just get me an Io" constructor
for application code), any function that used to reach for
`std.fs.cwd()` internally now needs an `io: std.Io` parameter threaded
down from `main`, the same way `gpa: std.mem.Allocator` already gets
threaded through. Expect nearly every function that touches disk to
need an explicit `io` parameter now.

**`Dir.Walker.next()` also takes `io` now:** `while (try
walker.next(io)) |entry|` rather than the old bare `walker.next()`.
`dir.walk(gpa)` itself is unaffected (still just takes the allocator).
Whether `walker.deinit()` also picked up an `io` param hasn't been
pinned down — check that too if this resurfaces with a different error
shape.

**Getting the cwd as a string:** `std.process.currentPathAlloc(io,
allocator)`. Two prior guesses both failed to compile:
`std.process.getCwdAlloc` doesn't exist and never did, and
`std.process.getCwd(buf)` — found via web search, present on Zig
*master* branch source at the time — was not present on the specific
dev snapshot actually in use, evidently added/renamed between the two.
The real signature was found by grepping the locally installed
`lib/std/process.zig` for "cwd", which turned up `currentPathAlloc` in
that file's own internal test (`try currentPathAlloc(testing.io,
testing.allocator)`) — an `Io`-taking, allocator-returning cwd query,
unlike either prior guess.

## `@typeInfo` reflection (`std.builtin.Type`, now under `std/lang.zig`)

The reflection info type moved from `std/builtin.zig` to `std/lang.zig`
(compiler error notes say `lang.Type.Enum`/`lang.Type.Struct`, not
`builtin.Type...`). More importantly, the shape changed: a single
`fields: []const FieldInfo` array became **parallel arrays**.

**`@typeInfo(T).@"enum"`:**
- Old: `fields: []const EnumField`, each with `.name`/`.value`
- New:
  ```zig
  tag_type: type,
  mode: Mode,               // enum { exhaustive, nonexhaustive }
  field_names: []const [:0]const u8,
  field_values: []const comptime_int,   // same length as field_names
  decl_names: []const [:0]const u8,
  ```
  Migration: `inline for (info.fields) |field| { ...field.name...field.value... }`
  → `inline for (info.field_names, info.field_values) |name, tag_value| { ... }`

**`@typeInfo(T).@"struct"`:**
- Old: `fields: []const StructField`, each with `.name`/`.type`
- New:
  ```zig
  is_tuple: bool,
  layout: ContainerLayout,
  backing_integer: ?type,
  field_names: []const [:0]const u8,
  field_types: []const type,            // same length as field_names
  field_attrs: []const FieldAttributes, // comptime flag, alignment, default value
  decl_names: []const [:0]const u8,
  ```
  Migration: `inline for (info.fields) |field| { ...field.name...field.type... }`
  → `inline for (info.field_names, info.field_types) |name, field_type| { ... }`

**`@typeInfo(T).@"union"`** follows the same parallel-array pattern
(`field_names`/`field_types`/`field_attrs`).

This comes up in any generic field-by-field decode/encode machinery
(config parsing, serialization) that iterates struct/enum fields at
comptime.

### Gotcha: `continue` inside `inline for` over the new reflection arrays

A bare runtime-conditioned `continue` inside `inline for` can trip
**"comptime control flow inside runtime block."** Fix by avoiding
`continue` — use `if`/`else if` instead — and force the comptime-only
check explicitly with `comptime`:

```zig
inline for (info.field_names, info.field_values) |name, tag_value| {
    if (comptime std.mem.eql(u8, name, "some_sentinel")) {
        // skip
    } else if (std.mem.eql(u8, value, name)) {
        return @enumFromInt(tag_value);
    }
}
```

## No array/string repeat operator (`**`) — use `@splat`

`"foo" ** 3`-style repeat expressions aren't valid syntax on this
snapshot and fail with a spacing-looking parser error (`binary operator
'*' has whitespace on one side, but not the other`) that has nothing to
do with actual whitespace — don't chase the spacing, the operator itself
doesn't exist here. For a comptime-known repeated array, `@splat(value)`
on the target array type is the replacement; for building a repeated
string/byte buffer at runtime (arbitrary repeat count, not a fixed
comptime array type), loop and `@memcpy` the pattern into a buffer
instead. Typically surfaces in test code building repeated byte
patterns.

## `@export` takes a pointer, not a value

`@export(&some_fn, .{ .name = "exported_name", .linkage = .strong })` —
the first argument is `&fn`, not the bare function. This is how to give
an exported C symbol a name distinct from the Zig identifier calling it
internally.

## `std.DynLib` has no Windows implementation on this snapshot

Attempting to use `std.DynLib.open`/`.lookup`/`.close` on the `windows`
target fails to compile — this snapshot's `std.DynLib` only has a
`posix`-backed implementation. Workaround is a small hand-rolled wrapper
around `kernel32.LoadLibraryW`/`GetProcAddress`/`FreeLibrary`, selected
via
`switch (@import("builtin").os.tag) { .windows => struct {...}, else => std.DynLib }`.
Every method on the Windows branch needs to be `pub` if anything outside
the defining file calls `.lookup()` on the wrapped value (ordinary Zig
visibility, not a 0.17 API change, but easy to miss since `std.DynLib`'s
own methods are `pub` so the omission only shows up on the Windows
build).

## Build gotcha: `zig build test` and `zig build run` compile different roots

`zig build test` only compiles whichever files are actually listed as
test roots in `build.zig` — not necessarily every file in the project.
If `main.zig` (or any entry point) isn't itself a test root, a rename
fixed via a `grep`-and-replace across `src/` can still get missed there
— either because the grep ran before the entry-point file was edited, or
the file was hand-edited later and the rename skipped. This kind of
miss only surfaces when `zig build run` (or the actual binary) is tried
— **`zig build test` passing is not proof `zig build run` will too.**
When a rename affects a widely-used API (`getWritten`→`written`,
`ArrayList` methods, etc.), grep the *entire* source tree after the
fact, not just the file(s) the compiler happened to complain about.

## `@import("../x.zig")` fails when a file is its own standalone test root

A module can't `@import` a file outside its own root file's directory —
even along a relative path that resolves fine when the same file is
reached via a *downward* `@import` from a module rooted higher up.
Concretely: a file like `src/render/foo.zig` containing
`@import("../model.zig")` resolves fine when the main module (rooted at
`src/`) imports `foo.zig` downward, since `../model.zig` from
`src/render/` still resolves to `src/model.zig`, inside that module's
root. But giving `foo.zig` its *own* standalone `b.addTest` with
`root_source_file = b.path("src/render/foo.zig")` makes `src/render/`
*that test module's* root — and now `../model.zig` escapes it:
`error: import of file outside module path`. Same failure mode for a
test file like `tests/some_test.zig` doing `@import("../src/model.zig")`
against a module rooted at `tests/`.

Two general fixes:

- **For files inside the main module** (e.g. `src/render/*.zig`): don't
  give them a standalone test root at all. A single umbrella file (e.g.
  `src/lib.zig`) that re-exports every module under `src/`, with its own
  test module rooted at `src/lib.zig` (so every file's `../` imports
  resolve inside `src/`), can pull in all `test` blocks across the tree
  via `std.testing.refAllDecls(@This())` — one test target covers
  everything, no per-file test root needed.
- **For files genuinely outside the main module** (e.g. a top-level
  `tests/` directory that needs `src/model.zig` etc. but has no reason
  to live under `src/`): give the main source directory a proper named
  module via `b.addModule("my_lib", .{ .root_source_file =
  b.path("src/lib.zig"), ... })`, and `.addImport("my_lib", my_lib)` it
  onto the test's own `root_module`. The test file then does
  `@import("my_lib").model` instead of `@import("../src/model.zig")` —
  a package import, not a directory-escaping relative path.

(A quicker but scrappier workaround is a small test-only umbrella file
that just `@import`s the problem file downward from within the correct
module root — works, but leaves loose files with no other purpose; the
named-module approach above is the more standard pattern.)

## How to look up the next one

The fastest path when a new reflection-shape or std-lib-rename error
comes up, on a machine with a local Zig install:

```powershell
# find where a type/struct is declared
Select-String -Pattern "pub const <Name> = struct" -Path C:\zig\lib\std\<file>.zig

# then dump the surrounding lines
Get-Content C:\zig\lib\std\<file>.zig | Select-Object -Skip (<line>-1) -First 40
```

(Adjust the path/command for the local OS and Zig install location —
e.g. `grep -n` / `sed` on Linux or macOS.) This is far more reliable
than web search — 0.17-dev is bleeding-edge enough that public
docs/blogs lag behind the actual source. Check `zig version` before
trusting any cached answer (including this file).

When a new project hits something not covered here, or finds this file
wrong for the current snapshot, just add/fix it in place — no separate
verification bookkeeping needed, just keep the content itself accurate.
