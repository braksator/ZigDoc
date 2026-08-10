const std = @import("std");

/// Output document format.
pub const Format = enum { html, md };
/// Whether output is one file (`none`) or a directory of interlinked
/// files split per input file (`file`) or per documented item (`item`).
/// This is the sole layout control — there's no separate single/split
/// flag, since "not split" and "split how" are the same choice.
pub const Split = enum { none, file, item };
/// How (or whether) decl source is embedded in HTML output. In `md`
/// output only `none` and `inline_` are valid (see `--source` docs) —
/// `collapsed`/`resizable` are HTML-only concepts with no plain-text
/// equivalent.
pub const SourceMode = enum { none, collapsed, resizable, inline_ };
/// Whether CSS is embedded in the output or written to a sibling file.
pub const CssMode = enum { embed, external };
/// Which color scheme the generated CSS uses. `auto` follows the OS via
/// `prefers-color-scheme`, `light`/`dark` force one regardless of it.
pub const Theme = enum { auto, light, dark };
/// Which nested `<ul>` lists start collapsed via native `<details>`.
/// `dir`: each `--tree` directory group. `all`: `dir`'s targets plus a
/// decl's own nested-children list. HTML-only, like `css`/`theme`/`head`.
pub const Collapse = enum { dir, all, none };
/// How sections are ordered, recursively at every nesting level (a
/// struct's own fields/decls get the same treatment as the top level).
/// `code`: source/AST order (today's only behavior). `alpha`: by name.
/// `grouped`: by `Section.kind` first, then name within each kind.
pub const ItemOrder = enum { code, alpha, grouped };
/// Where directories sort relative to files at the same nesting level
/// in the *Index* navigation list and split-mode directory pages.
/// `first`/`last` put every directory before/after every file at that
/// level; `alpha` interleaves them, sorted purely by name. Directories
/// are always alphabetical relative to other directories regardless of
/// this setting — it only controls their position relative to files.
pub const DirOrder = enum { first, last, alpha };

/// Default `--head` value: a favicon `<link>`, embedded as a data URI so
/// the output stays self-contained with no sibling asset file.
pub const defaultHead = "<link rel=\"shortcut icon\" href=\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAMAAABEpIrGAAAARVBMVEVHcEwAAA0BAQKWWAH7lhH/qAHZ2tv6jwT////8xn9SMQSzbAL/ogj49/X92quSlZoIGzr91J780Jb7rUf+5sf/wwD91aGX+9VwAAAAAXRSTlMAQObYZgAAAMpJREFUeNql0ssSgyAMQFEeiYEQUVra///U1tKFRGeY2ruRxZmRR8xWJujK1XQVoL4CsQORVFnoNgJ0G4BOHEC9UxNHgO+ISqWteAAgntkLUK3lmWOZNRC262pZiO6figKS3BLC4pJQKyqA3k4hTNbjJSCIj9RAeiCKAiDJ+8RuA463tUAHhJ211jXwWbLsAXq3zNO7OYT2XZzHPeA1qFYeg+EvRpscHvOni/r/LcbPrQdGAz1yGuihPYKuC6AAnQbFfMsEJ1E2xpgXnRgXb8riHD8AAAAASUVORK5CYII=\" />";

/// Resolved CLI configuration shared by the extractor, renderers, and
/// build.zig integration. Some fields' defaults depend on `format` — see
/// `parseArgs`, which resolves those after the full argument list (and
/// therefore the final `--format`) is known.
pub const Options = struct {
    format: Format = .html,
    split: Split = .none,
    /// Format-dependent default: `.resizable` for `html`, `.none` for
    /// `md`. Resolved by `parseArgs` unless explicitly overridden.
    source: SourceMode = .resizable,
    /// Same four modes as `source`, but for a `.zig` file's own full
    /// text (`DocTree.fullSource`/`Section.raw == false, kind == .file`)
    /// rather than a single decl. Independent of `source` — defaults to
    /// `.none` regardless of `format` (unlike `source`, which defaults
    /// differently per format) since showing a whole file's source is
    /// an opt-in, not the common case.
    fileSource: SourceMode = .none,
    /// Whether an index page is written and, on it, whether the nested
    /// contents list ("Index") renders. When `split` is not `.none`, an
    /// index page is always written regardless of this flag (there must
    /// be an entry point into the directory) — `index = false` in that
    /// case still writes the page, just without the nested list, title,
    /// or doc comment beyond a bare heading.
    index: bool = true,
    /// When documenting more than one file, whether each file's own
    /// heading/index label keeps its `.zig` extension (`main.zig`)
    /// rather than just the bare name (`main`).
    ext: bool = true,
    /// When documenting more than one file, whether each file's label
    /// is prefixed with its directory path relative to the input root.
    /// Suppressed automatically when `tree` is on (nesting already
    /// shows it).
    dir: bool = true,
    /// When documenting more than one file, whether the index nests
    /// per-file entries under unlinked directory header lines instead
    /// of one flat list.
    tree: bool = true,
    /// Split modes only. Whether a file's own slug/folder name keeps
    /// its full original extension (`main.zig.html`, `main.zig/`)
    /// rather than the bare name (`main.html`, `main/`). Defaults to
    /// `true` because it's one of two settings (with `dirUrls`) that
    /// help avoid a file's slug colliding with a directory's or
    /// another file's — see `dirUrls`. Collision detection at render
    /// time overrides this per-file when needed regardless of the
    /// setting, so turning it off is never unsafe, just less
    /// defensive.
    extUrls: bool = true,
    /// Split modes only. Whether a file's own page lives at
    /// `<file>/index.<ext>` inside a directory named for the file
    /// (`.zig`-suffixed or not per `extUrls`) rather than a flat
    /// sibling file `<file>.<ext>`. In `--split item` mode a file's
    /// decls already live in that same directory regardless of this
    /// setting (each needs its own page); `dirUrls` only decides
    /// whether the file's *own* content joins them as that
    /// directory's `index.<ext>` (so visiting the directory shows the
    /// file, not a bare listing) or stays a separate flat page.
    /// Defaults to `true` for the same collision-avoidance reason as
    /// `extUrls`.
    dirUrls: bool = true,
    /// HTML only. Strips a trailing `index.html` (and the slash before
    /// it, leaving just the directory) from every generated link, so a
    /// webserver that serves `index.html` for a directory request
    /// doesn't show it in the address bar. Only affects link text —
    /// the file on disk is still named `index.html`. Ignored (with a
    /// warning) for `md`, which has no server/address-bar concept.
    prettyUrls: bool = false,
    css: CssMode = .embed,
    /// HTML-only, like `css`. Ignored (with a warning) for `md`.
    theme: Theme = .auto,
    /// HTML-only, like `css`/`theme`. Ignored (with a warning) for `md`.
    collapse: Collapse = .dir,
    /// Recursive at every nesting level. Applied once, after extraction
    /// and any multi-file merge, in `main.zig::run` — every renderer
    /// just sees sections in final order and stays untouched.
    itemOrder: ItemOrder = .code,
    /// Where directories sort relative to files in the *Index*
    /// navigation list and split-mode directory pages. Only matters
    /// when there's a directory structure to order (`--tree on` with
    /// nested inputs); a flat file list has no directories to place.
    dirOrder: DirOrder = .first,
    /// Raw text appended inside the `<head>` tag of `html` output.
    /// Unescaped. Defaults to a self-contained favicon `<link>`.
    /// Ignored (with a warning) for `md`.
    head: []const u8 = defaultHead,
    /// Output directory. Defaults to `./zigdoc`; the actual file(s)
    /// written inside it are named by `filename` (`split = .none`) or a
    /// per-section scheme plus an `index` page (`split != .none`).
    out: []const u8 = "zigdoc",
    /// Output filename when `split == .none`, without a directory
    /// component. Format-dependent default: `index.html` for `html`,
    /// `index.md` for `md`. Resolved by `parseArgs` unless explicitly
    /// overridden. Unused when `split != .none` (the index page there is
    /// always named `index.<ext>`, and other pages are named from their
    /// qualified path).
    filename: []const u8 = "index.html",
    /// Overrides the guessed project title used as the top-level `<h1>`/
    /// `#` heading and, when `split != .none`, the index page's title.
    /// If unset, the title is guessed from the parent directory name of
    /// the first input path (see `main.zig`'s `guessTitle`).
    title: ?[]const u8 = null,
    /// Overrides the page name (the `<h1>` heading and breadcrumb root
    /// label) of the index/only page. Does not affect `--title` (the
    /// site-name subheading) or internal anchor slugs.
    rootname: ?[]const u8 = null,
    /// Also document nested containers.
    recursive: bool = true,
    /// Show each decl's source file path after its signature.
    showFile: bool = true,
    /// When `showFile` is on, prefix a decl's `{location}` with the
    /// root directory's own real name and a trailing `/` (e.g. `lib/`,
    /// always derived from the input path — never `--rootname`, which
    /// only renames the index page's own on-page heading). For a file
    /// already inside a subdirectory, this prepends onto that
    /// subdirectory's own existing prefix rather than replacing it
    /// (e.g. `lib/build-web/`, still one link to that file's own
    /// directory page); for a root-level file, it's the only prefix
    /// there is (`lib/`), linked to the root/index page. Off shows
    /// just the file's own directory path with no root name added
    /// (`build-web/`, or nothing at all for a root-level file),
    /// same as before this option existed.
    locFull: bool = true,
    /// Show each decl's source line number after its signature. Has no
    /// effect if `showFile` is off.
    showLine: bool = true,
    /// Show "File" / "Code" subheadings above the file-location line and
    /// source block, respectively.
    subheadings: bool = false,
    /// Whether the breadcrumb trail renders. Independent of `index`:
    /// with both off (split modes only — the entry-point page always
    /// keeps its link list regardless of `index`, see `index`'s own
    /// doc comment), the person is expected to supply their own
    /// navigation via `--prepend`/`--append` or a custom `--tpl-*`.
    breadcrumb: bool = true,
    /// Raw text placed immediately after `<body>` (`html`) or as the
    /// first line of the file (`md`), via the doc template's
    /// `{prepend}` variable. Unescaped, empty by default.
    prepend: []const u8 = "",
    /// Raw text placed immediately before `</body>` (`html`) or as the
    /// last line of the file (`md`), via the doc template's
    /// `{append}` variable. Unescaped, empty by default.
    append: []const u8 = "",
    /// Raw text placed via the doc template's `{desc}` variable, below
    /// the site-title line. Unescaped, empty by default — the person
    /// supplies their own wrapping tags/markup if they want structure.
    desc: []const u8 = "",
    /// Overrides `{comment}` on the root/front page only. Markdown
    /// source, rendered the same way a doc comment is. Empty by
    /// default, meaning no override — root keeps its own doc comment.
    rootComment: []const u8 = "",
    /// Path to a custom `--htmldoctpl` file. `null` uses
    /// `template.htmlDoc`. Loaded and read once by
    /// `main.zig`; unused (not even opened) when `format != .html`.
    tplHtmlDoc: ?[]const u8 = null,
    /// Path to a custom `--htmlsectpl` file. `null` uses
    /// `template.htmlSec`. Same loading/unused rules as
    /// `tplHtmlDoc`.
    tplHtmlSec: ?[]const u8 = null,
    /// Path to a custom `--mddoctpl` file. `null` uses
    /// `template.mdDoc`. Same loading/unused rules as
    /// `tplHtmlDoc`, but for `format == .md`.
    tplMdDoc: ?[]const u8 = null,
    /// Path to a custom `--mdsectpl` file. `null` uses
    /// `template.mdSec`. Same loading/unused rules as
    /// `tplMdDoc`.
    tplMdSec: ?[]const u8 = null,
    inputs: []const []const u8 = &.{},
    /// Extensions (without the leading `.`) to include when walking a
    /// directory input, e.g. `&.{"zig"}` or `&.{ "zig", "md" }`.
    /// Non-`.zig` extensions get no parsed decls — just a raw,
    /// unhighlighted `source` (see `model.rawFileSection`). Owned:
    /// freed by the caller alongside `inputs`.
    filetypes: []const []const u8 = &.{"zig"},
    /// Delete existing `.html`/`.md` files under `--out` (and any
    /// directories left empty by that) before writing new output.
    clear: bool = true,
    /// Decl kinds to omit from output. Empty: nothing excluded.
    OmitKind: []const OmitKind = &.{},
};

/// A decl kind excludable via `--omitkind`. Values map 1:1 to
/// `--omitkind`'s accepted strings (`fn`, `const`, `var`, `struct`,
/// `enum`, `union`, `opaque`). No `file`/`directory` variant — those
/// are structural containers, not documented items, so they're simply
/// not valid `--omitkind` values.
pub const OmitKind = enum { fn_decl, var_decl, const_decl, struct_decl, enum_decl, union_decl, opaque_decl };

/// Errors surfaced while parsing CLI arguments.
pub const ParseError = error{
    MissingValue,
    UnknownOption,
    UnknownValue,
    NoInputs,
    /// `--source collapsed`/`--source resizable` was requested (or left
    /// at an explicit non-format-default value) together with
    /// `--format md`, which has no such concepts.
    SourceModeNotValidForMd,
} || std.mem.Allocator.Error;

/// Parses CLI arguments (excluding argv[0]) into `Options`. Resolves
/// `source` and `filename` defaults based on the final `--format` once
/// the whole argument list has been read, so `--source` and `--filename`
/// can be given before or after `--format` on the command line.
pub fn parseArgs(gpa: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    var opts = Options{};
    var sourceExplicit = false;
    var filenameExplicit = false;
    var filetypesOwned: ?[]const []const u8 = null;
    errdefer if (filetypesOwned) |ft| gpa.free(ft);
    var OmitKindOwned: ?[]const OmitKind = null;
    errdefer if (OmitKindOwned) |ek| gpa.free(ek);
    var inputs: std.ArrayList([]const u8) = .empty;
    errdefer inputs.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "--")) {
            try inputs.append(gpa, arg);
            continue;
        }

        const name = arg[2..];

        i += 1;
        if (i >= args.len) return ParseError.MissingValue;
        const value = args[i];

        if (std.mem.eql(u8, name, "format")) {
            opts.format = try parseEnum(Format, value);
        } else if (std.mem.eql(u8, name, "split")) {
            opts.split = try parseEnum(Split, value);
        } else if (std.mem.eql(u8, name, "source")) {
            opts.source = if (std.mem.eql(u8, value, "inline"))
                .inline_
            else
                try parseEnum(SourceMode, value);
            sourceExplicit = true;
        } else if (std.mem.eql(u8, name, "filesource")) {
            opts.fileSource = if (std.mem.eql(u8, value, "inline"))
                .inline_
            else
                try parseEnum(SourceMode, value);
        } else if (std.mem.eql(u8, name, "index")) {
            opts.index = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "ext")) {
            opts.ext = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "dir")) {
            opts.dir = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "tree")) {
            opts.tree = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "exturls")) {
            opts.extUrls = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "dirurls")) {
            opts.dirUrls = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "prettyurls")) {
            opts.prettyUrls = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "css")) {
            opts.css = try parseEnum(CssMode, value);
        } else if (std.mem.eql(u8, name, "theme")) {
            opts.theme = try parseEnum(Theme, value);
        } else if (std.mem.eql(u8, name, "collapse")) {
            opts.collapse = try parseEnum(Collapse, value);
        } else if (std.mem.eql(u8, name, "itemorder")) {
            opts.itemOrder = try parseEnum(ItemOrder, value);
        } else if (std.mem.eql(u8, name, "dirorder")) {
            opts.dirOrder = try parseEnum(DirOrder, value);
        } else if (std.mem.eql(u8, name, "clear")) {
            opts.clear = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "omitkind")) {
            OmitKindOwned = try parseOmitKind(gpa, value);
        } else if (std.mem.eql(u8, name, "head")) {
            opts.head = value;
        } else if (std.mem.eql(u8, name, "out")) {
            opts.out = value;
        } else if (std.mem.eql(u8, name, "filename")) {
            opts.filename = value;
            filenameExplicit = true;
        } else if (std.mem.eql(u8, name, "filetypes")) {
            filetypesOwned = try parseFiletypes(gpa, value);
        } else if (std.mem.eql(u8, name, "title")) {
            opts.title = value;
        } else if (std.mem.eql(u8, name, "rootname")) {
            opts.rootname = value;
        } else if (std.mem.eql(u8, name, "recursive")) {
            opts.recursive = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "location")) {
            opts.showFile = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "locfull")) {
            opts.locFull = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "linenum")) {
            opts.showLine = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "subheadings")) {
            opts.subheadings = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "breadcrumb")) {
            opts.breadcrumb = try parseOnOff(value);
        } else if (std.mem.eql(u8, name, "prepend")) {
            opts.prepend = value;
        } else if (std.mem.eql(u8, name, "append")) {
            opts.append = value;
        } else if (std.mem.eql(u8, name, "desc")) {
            opts.desc = value;
        } else if (std.mem.eql(u8, name, "rootcomment")) {
            opts.rootComment = value;
        } else if (std.mem.eql(u8, name, "htmldoctpl")) {
            opts.tplHtmlDoc = value;
        } else if (std.mem.eql(u8, name, "htmlsectpl")) {
            opts.tplHtmlSec = value;
        } else if (std.mem.eql(u8, name, "mddoctpl")) {
            opts.tplMdDoc = value;
        } else if (std.mem.eql(u8, name, "mdsectpl")) {
            opts.tplMdSec = value;
        } else {
            return ParseError.UnknownOption;
        }
    }

    if (!sourceExplicit) opts.source = if (opts.format == .md) .none else .resizable;
    if (!filenameExplicit) opts.filename = if (opts.format == .md) "index.md" else "index.html";

    if (opts.format == .md and (opts.source == .collapsed or opts.source == .resizable)) {
        return ParseError.SourceModeNotValidForMd;
    }
    if (opts.format == .md and (opts.fileSource == .collapsed or opts.fileSource == .resizable)) {
        return ParseError.SourceModeNotValidForMd;
    }

    if (inputs.items.len == 0) return ParseError.NoInputs;
    opts.filetypes = filetypesOwned orelse try gpa.dupe([]const u8, &.{"zig"});
    opts.OmitKind = OmitKindOwned orelse &.{};
    opts.inputs = try inputs.toOwnedSlice(gpa);
    return opts;
}

/// Splits a comma-separated `--filetypes` value into extensions
/// (leading/trailing whitespace trimmed per entry, no leading `.`).
/// Sub-slices borrow from `value`, same as every other string-valued
/// option — only the container is allocated.
fn parseFiletypes(gpa: std.mem.Allocator, value: []const u8) ParseError![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try list.append(gpa, trimmed);
    }
    if (list.items.len == 0) return ParseError.UnknownValue;
    return list.toOwnedSlice(gpa);
}

/// Splits a comma-separated `--omitkind` value into `OmitKind`s.
fn parseOmitKind(gpa: std.mem.Allocator, value: []const u8) ParseError![]const OmitKind {
    var list: std.ArrayList(OmitKind) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const kind: OmitKind = if (std.mem.eql(u8, trimmed, "fn"))
            .fn_decl
        else if (std.mem.eql(u8, trimmed, "const"))
            .const_decl
        else if (std.mem.eql(u8, trimmed, "var"))
            .var_decl
        else if (std.mem.eql(u8, trimmed, "struct"))
            .struct_decl
        else if (std.mem.eql(u8, trimmed, "enum"))
            .enum_decl
        else if (std.mem.eql(u8, trimmed, "union"))
            .union_decl
        else if (std.mem.eql(u8, trimmed, "opaque"))
            .opaque_decl
        else
            return ParseError.UnknownValue;
        try list.append(gpa, kind);
    }
    return list.toOwnedSlice(gpa);
}

/// Matches `value` against the snake_case tag names of enum `T`.
fn parseEnum(comptime T: type, value: []const u8) ParseError!T {
    const info = @typeInfo(T).@"enum";
    inline for (info.field_names, info.field_values) |name, tag_value| {
        if (comptime std.mem.eql(u8, name, "inline_")) {
            // skip: not a user-facing value
        } else if (std.mem.eql(u8, value, name)) {
            return @enumFromInt(tag_value);
        }
    }
    return ParseError.UnknownValue;
}

/// Parses "on"/"off" into a bool.
fn parseOnOff(value: []const u8) ParseError!bool {
    if (std.mem.eql(u8, value, "on")) return true;
    if (std.mem.eql(u8, value, "off")) return false;
    return ParseError.UnknownValue;
}

test "Options{} struct defaults match the html format defaults" {
    const opts = Options{};
    try std.testing.expectEqual(Format.html, opts.format);
    try std.testing.expectEqual(Split.none, opts.split);
    try std.testing.expectEqual(SourceMode.resizable, opts.source);
    try std.testing.expectEqual(true, opts.index);
    try std.testing.expectEqual(true, opts.ext);
    try std.testing.expectEqual(true, opts.dir);
    try std.testing.expectEqual(true, opts.tree);
    try std.testing.expectEqual(false, opts.prettyUrls);
    try std.testing.expectEqual(CssMode.embed, opts.css);
    try std.testing.expectEqual(Theme.auto, opts.theme);
    try std.testing.expectEqual(Collapse.dir, opts.collapse);
    try std.testing.expectEqual(DirOrder.first, opts.dirOrder);
    try std.testing.expectEqualStrings(defaultHead, opts.head);
    try std.testing.expectEqualStrings("zigdoc", opts.out);
    try std.testing.expectEqualStrings("index.html", opts.filename);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.title);
    try std.testing.expectEqual(true, opts.showFile);
    try std.testing.expectEqual(true, opts.locFull);
    try std.testing.expectEqual(true, opts.showLine);
    try std.testing.expectEqual(false, opts.subheadings);
    try std.testing.expectEqual(true, opts.breadcrumb);
    try std.testing.expectEqualStrings("", opts.prepend);
    try std.testing.expectEqualStrings("", opts.append);
    try std.testing.expectEqualStrings("", opts.desc);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.tplHtmlDoc);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.tplHtmlSec);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.tplMdDoc);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.tplMdSec);
}

test "parseArgs applies overrides" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{
        "--format", "md",
        "--split",  "item",
        "--source", "inline",
        "--index",  "off",
        "--title",  "My Project",
        "input.zig",
    };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqual(Format.md, opts.format);
    try std.testing.expectEqual(Split.item, opts.split);
    try std.testing.expectEqual(SourceMode.inline_, opts.source);
    try std.testing.expectEqual(false, opts.index);
    try std.testing.expectEqualStrings("My Project", opts.title.?);
    try std.testing.expectEqual(@as(usize, 1), opts.inputs.len);
}

test "parseArgs defaults source and filename to html when format is unset" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{"input.zig"};
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqual(SourceMode.resizable, opts.source);
    try std.testing.expectEqualStrings("index.html", opts.filename);
}

test "parseArgs defaults source and filename to md when format is md" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md", "input.zig" };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqual(SourceMode.none, opts.source);
    try std.testing.expectEqualStrings("index.md", opts.filename);
}

test "parseArgs resolves format-dependent defaults regardless of flag order" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "input.zig", "--format", "md" };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqual(SourceMode.none, opts.source);
    try std.testing.expectEqualStrings("index.md", opts.filename);
}

test "parseArgs rejects resizable source with md format" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md", "--source", "resizable", "input.zig" };
    try std.testing.expectError(ParseError.SourceModeNotValidForMd, parseArgs(gpa, &args));
}

test "parseArgs rejects collapsed source with md format" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md", "--source", "collapsed", "input.zig" };
    try std.testing.expectError(ParseError.SourceModeNotValidForMd, parseArgs(gpa, &args));
}

test "parseArgs allows explicit inline source with md format" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md", "--source", "inline", "input.zig" };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqual(SourceMode.inline_, opts.source);
}

test "parseArgs applies location/locfull/linenum/subheadings/filename overrides" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{
        "--location",    "off",
        "--locfull",     "off",
        "--linenum",    "off",
        "--subheadings",  "on",
        "--filename",     "custom.html",
        "input.zig",
    };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqual(false, opts.showFile);
    try std.testing.expectEqual(false, opts.locFull);
    try std.testing.expectEqual(false, opts.showLine);
    try std.testing.expectEqual(true, opts.subheadings);
    try std.testing.expectEqualStrings("custom.html", opts.filename);
}

test "parseArgs applies theme override" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--theme", "dark", "input.zig" };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqual(Theme.dark, opts.theme);
}

test "parseArgs applies ext/dir/tree overrides" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{
        "--ext",  "off",
        "--dir",  "off",
        "--tree", "off",
        "input.zig",
    };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqual(false, opts.ext);
    try std.testing.expectEqual(false, opts.dir);
    try std.testing.expectEqual(false, opts.tree);
}

test "parseArgs applies exturls/dirurls overrides, defaulting both on" {
    const gpa = std.testing.allocator;
    const defaultArgs = [_][]const u8{"input.zig"};
    const defaults = try parseArgs(gpa, &defaultArgs);
    defer gpa.free(defaults.inputs);
    defer gpa.free(defaults.filetypes);
    try std.testing.expectEqual(true, defaults.extUrls);
    try std.testing.expectEqual(true, defaults.dirUrls);

    const args = [_][]const u8{
        "--exturls", "off",
        "--dirurls", "off",
        "input.zig",
    };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqual(false, opts.extUrls);
    try std.testing.expectEqual(false, opts.dirUrls);
}

test "parseArgs applies prettyurls override, defaulting off" {
    const gpa = std.testing.allocator;
    const defaultArgs = [_][]const u8{"input.zig"};
    const defaults = try parseArgs(gpa, &defaultArgs);
    defer gpa.free(defaults.inputs);
    defer gpa.free(defaults.filetypes);
    try std.testing.expectEqual(false, defaults.prettyUrls);

    const args = [_][]const u8{ "--prettyurls", "on", "input.zig" };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqual(true, opts.prettyUrls);
}

test "parseArgs applies collapse override" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--collapse", "all", "input.zig" };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqual(Collapse.all, opts.collapse);
}

test "parseArgs applies dirorder override" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--dirorder", "last", "input.zig" };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqual(DirOrder.last, opts.dirOrder);
}

test "parseArgs applies head override" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--head", "<meta name=\"x\">", "input.zig" };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqualStrings("<meta name=\"x\">", opts.head);
}

test "parseArgs applies breadcrumb/prepend/append/desc overrides" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{
        "--breadcrumb", "off",
        "--prepend",    "<div>pre</div>",
        "--append",     "<div>post</div>",
        "--desc",       "<p>desc</p>",
        "input.zig",
    };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqual(false, opts.breadcrumb);
    try std.testing.expectEqualStrings("<div>pre</div>", opts.prepend);
    try std.testing.expectEqualStrings("<div>post</div>", opts.append);
    try std.testing.expectEqualStrings("<p>desc</p>", opts.desc);
}

test "parseArgs applies rootcomment override" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{
        "--rootcomment", "<p>front</p>",
        "input.zig",
    };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqualStrings("<p>front</p>", opts.rootComment);
}

test "parseArgs applies tpl-* path overrides" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{
        "--htmldoctpl", "a.tpl",
        "--htmlsectpl", "b.tpl",
        "--mddoctpl",   "c.tpl",
        "--mdsectpl",   "d.tpl",
        "input.zig",
    };
    const opts = try parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    try std.testing.expectEqualStrings("a.tpl", opts.tplHtmlDoc.?);
    try std.testing.expectEqualStrings("b.tpl", opts.tplHtmlSec.?);
    try std.testing.expectEqualStrings("c.tpl", opts.tplMdDoc.?);
    try std.testing.expectEqualStrings("d.tpl", opts.tplMdSec.?);
}

test "parseArgs rejects unknown option" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--bogus", "x", "input.zig" };
    try std.testing.expectError(ParseError.UnknownOption, parseArgs(gpa, &args));
}

test "parseArgs requires at least one input" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md" };
    try std.testing.expectError(ParseError.NoInputs, parseArgs(gpa, &args));
}
