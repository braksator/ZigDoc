//! CLI entry point: options parsing, progress reporting, extract, render, and write output.
const std = @import("std");
const extract = @import("extract.zig");
const imports = @import("imports.zig");
const minify = @import("minify.zig");
const model = @import("model.zig");
const render = @import("render.zig");
const search = @import("search.zig");
const style = @import("style.zig");
const template = @import("template.zig");

pub const options = struct {
    /// Output document format.
    pub const Format = enum { html, md };
    /// Whether output is one file (`none`) or split per input file (`file`) or per item (`item`).
    /// `--split ns` is an accepted alias for `file` under `--discover ns`.
    pub const Split = enum { none, file, item };
    /// How decl source is embedded in HTML output. `md` only supports `none`/`inline_`.
    /// `tab` requires `--split item` (page-level) or non-`none` split (page-source level).
    pub const SourceMode = enum { none, collapsed, resizable, inline_, tab };
    /// Same as `SourceMode` minus `tab` — used by `--tests`.
    pub const TestsMode = enum { none, collapsed, resizable, inline_ };
    /// Whether CSS is embedded in the output or written to a sibling file.
    pub const CssMode = enum { embed, external };
    /// Which color scheme the generated CSS uses. `auto` follows the OS.
    pub const Theme = enum { auto, light, dark };
    /// Which nested lists start collapsed. `dir`: `--tree` directory groups. `ns`: `--discover
    /// ns` per-file namespace roots. `top`: a page's outermost index list. `all`: everything
    /// collapsible. HTML-only.
    pub const Collapse = enum { dir, ns, top, all, none };
    /// How sections are ordered, recursively at every nesting level.
    pub const ItemOrder = enum { code, alpha, grouped };
    /// Where directories sort relative to files in index/nav listings.
    pub const DirOrder = enum { first, last, alpha };
    /// Which strategy finds the files to document: `fs` walks the filesystem, `ns` follows
    /// `@import(...)` from a root file.
    pub const Discover = enum { fs, ns };
    /// One category of content `--show` can turn on or off: `file`/`linenum`
    /// are a decl's source location, `fields`/`parameters`/`errorsets` are its
    /// own members, the rest list its children by kind as links. `funcsigs` is
    /// a rendering variant of `functions` (signature + doc comment instead of
    /// a plain link) and trumps it when both are shown; excluding `functions`
    /// always excludes `funcsigs` too — see `parseShow`.
    pub const ShowFlag = enum {
        file,
        linenum,
        fields,
        parameters,
        errorsets,
        directories,
        files,
        namespaces,
        structs,
        types,
        values,
        functions,
        funcsigs,
    };

    /// A listing category `--omitdoc` can mark link-less. `functions`/`values` decls
    /// each have their own page, so marking them also suppresses that page entirely,
    /// leaving just the name + doc comment shown in the parent's listing. `fields`,
    /// `errors`, and `params` never had a page of their own to begin with, so they're
    /// accepted for symmetry but change nothing.
    pub const OmitDocFlag = enum { functions, fields, errors, params, values, none };

    /// Default `--head` value: a self-contained favicon `<link>` as a data URI.
    pub const defaultHead = "<link rel=\"shortcut icon\" href=\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAMAAABEpIrGAAAARVBMVEVHcEwAAA0BAQKWWAH7lhH/qAHZ2tv6jwT////8xn9SMQSzbAL/ogj49/X92quSlZoIGzr91J780Jb7rUf+5sf/wwD91aGX+9VwAAAAAXRSTlMAQObYZgAAAMpJREFUeNql0ssSgyAMQFEeiYEQUVra///U1tKFRGeY2ruRxZmRR8xWJujK1XQVoL4CsQORVFnoNgJ0G4BOHEC9UxNHgO+ISqWteAAgntkLUK3lmWOZNRC262pZiO6figKS3BLC4pJQKyqA3k4hTNbjJSCIj9RAeiCKAiDJ+8RuA463tUAHhJ211jXwWbLsAXq3zNO7OYT2XZzHPeA1qFYeg+EvRpscHvOni/r/LcbPrQdGAz1yGuihPYKuC6AAnQbFfMsEJ1E2xpgXnRgXb8riHD8AAAAASUVORK5CYII=\" />";

    const zdBadge = "<a href=http://github.com/braksator/ZigDoc target=_blank><img height=32 src=\"data:image/png;base64,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\" style=display:block;margin:auto;margin-top:2rem></a>";

    /// Resolved CLI configuration shared by the extractor, renderers, and build.zig integration.
    pub const Options = struct {
        format: Format = .html,
        split: Split = .none,
        discover: Discover = .fs,
        /// Format-dependent default: `.resizable` for `html`, `.none` for `md`.
        source: SourceMode = .resizable,
        /// Like `source`, but for the page's main item (a whole file/namespace, or a single
        /// decl under `--split item`). Defaults to `.none` regardless of format.
        pageSource: SourceMode = .none,
        /// Whether an index page is written and shows its nested contents list. When `split`
        /// isn't `.none`, an index page is always written regardless — this only affects its content.
        index: bool = true,
        /// Whether a file's heading/index label keeps its `.zig` extension.
        ext: bool = true,
        /// Whether a file's label is prefixed with its directory path. Suppressed when `tree` is on.
        dir: bool = true,
        /// Whether the index nests per-file entries under directory headers instead of a flat list.
        tree: bool = true,
        /// Split modes only. Whether a file's slug/folder keeps its full extension
        /// (`main.zig.html`) to help avoid slug collisions — see `dirUrls`.
        extUrls: bool = true,
        /// Split modes only. Whether a file's own page becomes `<file>/index.<ext>` inside a
        /// directory named for the file, rather than a flat sibling file.
        dirUrls: bool = true,
        /// HTML only. Strips a trailing `index.html` from generated link text. Ignored for `md`.
        prettyUrls: bool = false,
        /// Whether a symbol's name in a signature/source block links to its own docs.
        /// Defaults to `true` for `html`, `false` for `md`.
        codelinks: bool = true,
        /// Format-dependent default: `.external` when `split` isn't `.none`
        /// and `format` is `html`; `.embed` otherwise (`md` never uses CSS).
        css: CssMode = .embed,
        /// HTML-only. Ignored (with a warning) for `md`.
        theme: Theme = .auto,
        /// HTML-only. Ignored (with a warning) for `md`.
        collapse: Collapse = .all,
        /// Recursive at every nesting level; applied once after extraction/merge.
        itemOrder: ItemOrder = .code,
        /// Where directories sort relative to files in the index/nav listing.
        dirOrder: DirOrder = .first,
        /// Raw text appended inside `<head>`. Unescaped. Ignored for `md`.
        head: []const u8 = defaultHead,
        /// Output directory. Defaults to `./zigdoc`.
        out: []const u8 = "zigdoc",
        /// Output filename when `split == .none`. Format-dependent default. Unused otherwise.
        filename: []const u8 = "index.html",
        /// Overrides the guessed project title. Falls back to the first input's parent dir name.
        title: ?[]const u8 = null,
        /// Overrides the index/only page's heading and breadcrumb root label.
        rootname: ?[]const u8 = null,
        /// Also document nested containers.
        recursive: bool = true,
        /// When `file` is shown, prefix it with the root directory's real name.
        fileDir: bool = true,
        /// Show "File" / "Code" subheadings above the location line and source block.
        subheadings: bool = true,
        /// Which per-section content categories render. See `ShowFlag`.
        show: []const ShowFlag = &.{ .file, .linenum },
        /// Whether and how a file/namespace's own `test` blocks render via `{tests}`.
        tests: TestsMode = .none,
        /// Whether the breadcrumb trail renders.
        breadcrumb: bool = true,
        /// Raw text placed right after `<body>` (`html`) or as the first line (`md`).
        prepend: []const u8 = "",
        /// Raw text placed right before `</body>` (`html`) or as the last line (`md`).
        append: []const u8 = "",
        /// Whether `append` is heap-owned (via `--zd`) and must be freed by the caller.
        appendOwned: bool = false,
        /// Raw text placed via the doc template's `{desc}` variable.
        desc: []const u8 = "",
        /// Overrides `{comment}` on the root/front page only. Empty means no override.
        rootComment: []const u8 = "",
        /// Path to a custom `--htmldoctpl` file. `null` uses `template.htmlDoc`.
        tplHtmlDoc: ?[]const u8 = null,
        /// Path to a custom `--htmlsectpl` file. `null` uses `template.htmlSec`.
        tplHtmlSec: ?[]const u8 = null,
        /// Path to a custom `--mddoctpl` file. `null` uses `template.mdDoc`.
        tplMdDoc: ?[]const u8 = null,
        /// Path to a custom `--mdsectpl` file. `null` uses `template.mdSec`.
        tplMdSec: ?[]const u8 = null,
        inputs: []const []const u8 = &.{},
        /// Extensions (no leading `.`) to include when walking a directory input.
        filetypes: []const []const u8 = &.{"zig"},
        /// Delete existing `.html`/`.md` files under `--out` before writing new output.
        clear: bool = true,
        /// Decl kinds to omit from output. Empty: nothing excluded.
        OmitKind: []const OmitKind = &.{},
        /// Listing categories to render link-less (name + doc comment only). Empty: nothing excluded.
        omitDoc: []const OmitDocFlag = &.{},
        /// Whether to document non-`pub` members. Off by default.
        private: bool = false,
        /// Whether a `.file` section with no doc comment and no children survives in output.
        showEmpty: bool = false,
        /// Whether to emit a client-side fuzzy search box. HTML-only.
        search: bool = false,
        /// Whether written HTML/CSS/JS output is minified. Ignored for `md`.
        minify: bool = true,
        /// Whether a decl's rendered signature keeps a leading `pub ` keyword.
        showPub: bool = true,
        /// Non-fatal problems found while parsing CLI args: unknown options, unknown
        /// values (each falls back to its default), and other ignored combinations.
        /// Printed by the caller after a run completes, never causes a hard failure.
        parseWarnings: []const []const u8 = &.{},

        /// Whether `flag` is one of the categories `--show` turned on.
        pub fn shows(opts: Options, flag: ShowFlag) bool {
            for (opts.show) |f| {
                if (f == flag) return true;
            }
            return false;
        }

        /// Whether extraction should collect a struct/fn/error-set's own
        /// members at all — true if any of the three is shown.
        pub fn collectsExtras(opts: Options) bool {
            return opts.shows(.fields) or opts.shows(.parameters) or opts.shows(.errorsets);
        }
    };

    /// A decl kind excludable via `--omitkind`. No `directory` variant — directory headings
    /// are always structural, never a documented item.
    pub const OmitKind = enum { fn_decl, var_decl, const_decl, struct_decl, enum_decl, union_decl, opaque_decl, file, namespace_decl };

    /// Allocator-failure-only error surfaced while parsing CLI arguments. Malformed input
    /// (unknown options/values, missing values, invalid combinations) is never fatal —
    /// it's recorded in `Options.parseWarnings` and a sane default is used instead.
    pub const ParseError = std.mem.Allocator.Error;

    /// Parses CLI arguments (excluding argv[0]) into `Options`. Resolves `source`/`filename`
    /// defaults from the final `--format` once the whole argument list is read. Malformed
    /// input never fails parsing: it's recorded in the returned `Options.parseWarnings`
    /// and a sane default is substituted, so the caller can always proceed.
    pub fn parseArgs(gpa: std.mem.Allocator, args: []const []const u8) ParseError!Options {
        var opts = Options{};
        var sourceExplicit = false;
        var codelinksExplicit = false;
        var filenameExplicit = false;
        var cssExplicit = false;
        var filetypesOwned: ?[]const []const u8 = null;
        errdefer if (filetypesOwned) |ft| gpa.free(ft);
        var OmitKindOwned: ?[]const OmitKind = null;
        errdefer if (OmitKindOwned) |ek| gpa.free(ek);
        var omitDocOwned: ?[]const OmitDocFlag = null;
        errdefer if (omitDocOwned) |od| gpa.free(od);
        var showOwned: ?[]const ShowFlag = null;
        errdefer if (showOwned) |s| gpa.free(s);
        var inputs: std.ArrayList([]const u8) = .empty;
        errdefer inputs.deinit(gpa);
        var zdRequested = false;
        var warnings: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (warnings.items) |w| gpa.free(w);
            warnings.deinit(gpa);
        }

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (!std.mem.startsWith(u8, arg, "--")) {
                try inputs.append(gpa, arg);
                continue;
            }

            const name = arg[2..];

            if (std.mem.eql(u8, name, "zd")) {
                zdRequested = true;
                continue;
            }

            // A missing value is either the flag being the last arg, or the next
            // token itself looking like a flag — either way there's nothing to
            // consume, so the option is dropped and parsing carries on from there.
            const hasValue = i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--");
            if (!hasValue) {
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "Option \"--{s}\" is missing a value, ignored.", .{name}));
                continue;
            }
            i += 1;
            const value = args[i];

            if (std.mem.eql(u8, name, "format")) {
                opts.format = try parseEnumWarn(gpa, &warnings, Format, name, value, opts.format);
            } else if (std.mem.eql(u8, name, "discover")) {
                opts.discover = try parseEnumWarn(gpa, &warnings, Discover, name, value, opts.discover);
            } else if (std.mem.eql(u8, name, "split")) {
                opts.split = if (std.mem.eql(u8, value, "ns"))
                    .file
                else
                    try parseEnumWarn(gpa, &warnings, Split, name, value, opts.split);
            } else if (std.mem.eql(u8, name, "source")) {
                opts.source = if (std.mem.eql(u8, value, "inline"))
                    .inline_
                else
                    try parseEnumWarn(gpa, &warnings, SourceMode, name, value, opts.source);
                sourceExplicit = true;
            } else if (std.mem.eql(u8, name, "pagesource")) {
                opts.pageSource = if (std.mem.eql(u8, value, "inline"))
                    .inline_
                else
                    try parseEnumWarn(gpa, &warnings, SourceMode, name, value, opts.pageSource);
            } else if (std.mem.eql(u8, name, "index")) {
                opts.index = try parseOnOffWarn(gpa, &warnings, name, value, opts.index);
            } else if (std.mem.eql(u8, name, "ext")) {
                opts.ext = try parseOnOffWarn(gpa, &warnings, name, value, opts.ext);
            } else if (std.mem.eql(u8, name, "dir")) {
                opts.dir = try parseOnOffWarn(gpa, &warnings, name, value, opts.dir);
            } else if (std.mem.eql(u8, name, "tree")) {
                opts.tree = try parseOnOffWarn(gpa, &warnings, name, value, opts.tree);
            } else if (std.mem.eql(u8, name, "exturls")) {
                opts.extUrls = try parseOnOffWarn(gpa, &warnings, name, value, opts.extUrls);
            } else if (std.mem.eql(u8, name, "dirurls")) {
                opts.dirUrls = try parseOnOffWarn(gpa, &warnings, name, value, opts.dirUrls);
            } else if (std.mem.eql(u8, name, "prettyurls")) {
                opts.prettyUrls = try parseOnOffWarn(gpa, &warnings, name, value, opts.prettyUrls);
            } else if (std.mem.eql(u8, name, "codelinks")) {
                opts.codelinks = try parseOnOffWarn(gpa, &warnings, name, value, opts.codelinks);
                codelinksExplicit = true;
            } else if (std.mem.eql(u8, name, "css")) {
                opts.css = try parseEnumWarn(gpa, &warnings, CssMode, name, value, opts.css);
                cssExplicit = true;
            } else if (std.mem.eql(u8, name, "theme")) {
                opts.theme = try parseEnumWarn(gpa, &warnings, Theme, name, value, opts.theme);
            } else if (std.mem.eql(u8, name, "collapse")) {
                opts.collapse = try parseEnumWarn(gpa, &warnings, Collapse, name, value, opts.collapse);
            } else if (std.mem.eql(u8, name, "itemorder")) {
                opts.itemOrder = try parseEnumWarn(gpa, &warnings, ItemOrder, name, value, opts.itemOrder);
            } else if (std.mem.eql(u8, name, "dirorder")) {
                opts.dirOrder = try parseEnumWarn(gpa, &warnings, DirOrder, name, value, opts.dirOrder);
            } else if (std.mem.eql(u8, name, "clear")) {
                opts.clear = try parseOnOffWarn(gpa, &warnings, name, value, opts.clear);
            } else if (std.mem.eql(u8, name, "private")) {
                opts.private = try parseOnOffWarn(gpa, &warnings, name, value, opts.private);
            } else if (std.mem.eql(u8, name, "showempty")) {
                opts.showEmpty = try parseOnOffWarn(gpa, &warnings, name, value, opts.showEmpty);
            } else if (std.mem.eql(u8, name, "search")) {
                opts.search = try parseOnOffWarn(gpa, &warnings, name, value, opts.search);
            } else if (std.mem.eql(u8, name, "minify")) {
                opts.minify = try parseOnOffWarn(gpa, &warnings, name, value, opts.minify);
            } else if (std.mem.eql(u8, name, "showpub")) {
                opts.showPub = try parseOnOffWarn(gpa, &warnings, name, value, opts.showPub);
            } else if (std.mem.eql(u8, name, "omitkind")) {
                OmitKindOwned = try parseOmitKind(gpa, &warnings, value);
            } else if (std.mem.eql(u8, name, "omitdoc")) {
                omitDocOwned = try parseOmitDoc(gpa, &warnings, value);
            } else if (std.mem.eql(u8, name, "head")) {
                opts.head = value;
            } else if (std.mem.eql(u8, name, "out")) {
                opts.out = value;
            } else if (std.mem.eql(u8, name, "filename")) {
                opts.filename = value;
                filenameExplicit = true;
            } else if (std.mem.eql(u8, name, "filetypes")) {
                filetypesOwned = try parseFiletypes(gpa, &warnings, value);
            } else if (std.mem.eql(u8, name, "title")) {
                opts.title = value;
            } else if (std.mem.eql(u8, name, "rootname")) {
                opts.rootname = value;
            } else if (std.mem.eql(u8, name, "recursive")) {
                opts.recursive = try parseOnOffWarn(gpa, &warnings, name, value, opts.recursive);
            } else if (std.mem.eql(u8, name, "filedir")) {
                opts.fileDir = try parseOnOffWarn(gpa, &warnings, name, value, opts.fileDir);
            } else if (std.mem.eql(u8, name, "subheadings")) {
                opts.subheadings = try parseOnOffWarn(gpa, &warnings, name, value, opts.subheadings);
            } else if (std.mem.eql(u8, name, "show")) {
                if (showOwned) |old| gpa.free(old);
                showOwned = try parseShow(gpa, &warnings, value);
            } else if (std.mem.eql(u8, name, "tests")) {
                opts.tests = if (std.mem.eql(u8, value, "inline"))
                    .inline_
                else
                    try parseEnumWarn(gpa, &warnings, TestsMode, name, value, opts.tests);
            } else if (std.mem.eql(u8, name, "breadcrumb")) {
                opts.breadcrumb = try parseOnOffWarn(gpa, &warnings, name, value, opts.breadcrumb);
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
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "Unknown option \"--{s}\" ignored.", .{name}));
            }
        }

        if (!sourceExplicit) opts.source = if (opts.format == .md) .none else .resizable;
        if (!codelinksExplicit) opts.codelinks = opts.format != .md;
        if (!filenameExplicit) opts.filename = if (opts.format == .md) "index.md" else "index.html";
        if (!cssExplicit) opts.css = if (opts.split != .none and opts.format != .md) .external else .embed;

        if (opts.format == .md and (opts.source == .collapsed or opts.source == .resizable)) {
            try warnings.append(gpa, try std.fmt.allocPrint(gpa, "HTML-specific option \"--source {s}\" ignored, using \"none\" instead.", .{@tagName(opts.source)}));
            opts.source = .none;
        }
        if (opts.format == .md and (opts.pageSource == .collapsed or opts.pageSource == .resizable)) {
            try warnings.append(gpa, try std.fmt.allocPrint(gpa, "HTML-specific option \"--pagesource {s}\" ignored, using \"none\" instead.", .{@tagName(opts.pageSource)}));
            opts.pageSource = .none;
        }
        if (opts.format == .md and opts.source == .tab) {
            try warnings.append(gpa, try std.fmt.allocPrint(gpa, "HTML-specific option \"--source tab\" ignored, using \"none\" instead.", .{}));
            opts.source = .none;
        }
        if (opts.format == .md and opts.pageSource == .tab) {
            try warnings.append(gpa, try std.fmt.allocPrint(gpa, "HTML-specific option \"--pagesource tab\" ignored, using \"none\" instead.", .{}));
            opts.pageSource = .none;
        }
        if (opts.format == .md and (opts.tests == .collapsed or opts.tests == .resizable)) {
            try warnings.append(gpa, try std.fmt.allocPrint(gpa, "HTML-specific option \"--tests {s}\" ignored, using \"none\" instead.", .{@tagName(opts.tests)}));
            opts.tests = .none;
        }
        if (opts.split == .none and opts.pageSource == .tab) {
            try warnings.append(gpa, try std.fmt.allocPrint(gpa, "Option \"--pagesource tab\" requires \"--split\" other than \"none\", ignored, using \"none\" instead.", .{}));
            opts.pageSource = .none;
        }
        if (opts.split != .item and opts.source == .tab) {
            try warnings.append(gpa, try std.fmt.allocPrint(gpa, "Option \"--source tab\" requires \"--split item\", ignored, using \"none\" instead.", .{}));
            opts.source = .none;
        }

        if (zdRequested) {
            opts.append = try std.mem.concat(gpa, u8, &.{ zdBadge, opts.append });
            opts.appendOwned = true;
        }

        opts.filetypes = filetypesOwned orelse try gpa.dupe([]const u8, &.{"zig"});
        opts.OmitKind = OmitKindOwned orelse &.{};
        opts.omitDoc = omitDocOwned orelse &.{};
        opts.show = showOwned orelse try gpa.dupe(ShowFlag, &.{ .file, .linenum });
        opts.inputs = try inputs.toOwnedSlice(gpa);
        opts.parseWarnings = try warnings.toOwnedSlice(gpa);
        return opts;
    }

    /// Splits a comma-separated `--filetypes` value into extensions (trimmed, no leading `.`).
    /// A value with no usable entries falls back to the `zig`-only default.
    fn parseFiletypes(gpa: std.mem.Allocator, warnings: *std.ArrayList([]const u8), value: []const u8) ParseError![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(gpa);
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0) continue;
            try list.append(gpa, trimmed);
        }
        if (list.items.len == 0) {
            try warnings.append(gpa, try std.fmt.allocPrint(gpa, "Invalid --filetypes option \"{s}\", using default \"zig\" instead.", .{value}));
            list.deinit(gpa);
            return gpa.dupe([]const u8, &.{"zig"});
        }
        return list.toOwnedSlice(gpa);
    }

    /// Splits a comma-separated `--omitkind` value into `OmitKind`s. Each unrecognized
    /// token is warned about and skipped; recognized tokens are kept regardless.
    fn parseOmitKind(gpa: std.mem.Allocator, warnings: *std.ArrayList([]const u8), value: []const u8) ParseError![]const OmitKind {
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
            else if (std.mem.eql(u8, trimmed, "file"))
                .file
            else if (std.mem.eql(u8, trimmed, "namespace"))
                .namespace_decl
            else {
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "Invalid --omitkind entry \"{s}\" ignored.", .{trimmed}));
                continue;
            };
            try list.append(gpa, kind);
        }
        return list.toOwnedSlice(gpa);
    }

    /// Splits a comma-separated `--omitdoc` value into `OmitDocFlag`s. `none` (also
    /// the default) and unrecognized tokens are skipped, the latter with a warning.
    fn parseOmitDoc(gpa: std.mem.Allocator, warnings: *std.ArrayList([]const u8), value: []const u8) ParseError![]const OmitDocFlag {
        var list: std.ArrayList(OmitDocFlag) = .empty;
        errdefer list.deinit(gpa);
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none")) continue;
            const flag = parseEnumOpt(OmitDocFlag, trimmed) orelse {
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "Invalid --omitdoc entry \"{s}\" ignored.", .{trimmed}));
                continue;
            };
            try list.append(gpa, flag);
        }
        return list.toOwnedSlice(gpa);
    }

    /// Splits a comma-separated `--show` value into `ShowFlag`s. `all` expands
    /// to every flag; a `-name` token excludes it, regardless of ordering. Each
    /// unrecognized token is warned about and skipped; recognized tokens are kept.
    /// Excluding `functions` always excludes `funcsigs` too, since `funcsigs` is
    /// just an alternate rendering of the functions section — there's nothing
    /// left for it to render once `functions` itself is off.
    fn parseShow(gpa: std.mem.Allocator, warnings: *std.ArrayList([]const u8), value: []const u8) ParseError![]const ShowFlag {
        const flagCount = @typeInfo(ShowFlag).@"enum".field_names.len;
        var included: [flagCount]bool = @splat(false);
        var excluded: [flagCount]bool = @splat(false);
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, "all")) {
                included = @splat(true);
                continue;
            }
            if (trimmed[0] == '-') {
                if (parseEnumOpt(ShowFlag, trimmed[1..])) |flag| {
                    excluded[@intFromEnum(flag)] = true;
                } else {
                    try warnings.append(gpa, try std.fmt.allocPrint(gpa, "Invalid --show entry \"{s}\" ignored.", .{trimmed}));
                }
            } else {
                if (parseEnumOpt(ShowFlag, trimmed)) |flag| {
                    included[@intFromEnum(flag)] = true;
                } else {
                    try warnings.append(gpa, try std.fmt.allocPrint(gpa, "Invalid --show entry \"{s}\" ignored.", .{trimmed}));
                }
            }
        }
        if (excluded[@intFromEnum(ShowFlag.functions)]) excluded[@intFromEnum(ShowFlag.funcsigs)] = true;
        var list: std.ArrayList(ShowFlag) = .empty;
        errdefer list.deinit(gpa);
        for (included, excluded, 0..) |isIncluded, isExcluded, i| {
            if (isIncluded and !isExcluded) try list.append(gpa, @enumFromInt(i));
        }
        return list.toOwnedSlice(gpa);
    }

    /// Matches `value` against the snake_case tag names of enum `T`. `null` when unmatched.
    fn parseEnumOpt(comptime T: type, value: []const u8) ?T {
        const info = @typeInfo(T).@"enum";
        inline for (info.field_names, info.field_values) |name, tag_value| {
            if (comptime std.mem.eql(u8, name, "inline_")) {
                // skip: not a user-facing value
            } else if (std.mem.eql(u8, value, name)) {
                return @enumFromInt(tag_value);
            }
        }
        return null;
    }

    /// Like `parseEnumOpt`, but warns and returns `default` instead of `null` on a mismatch.
    fn parseEnumWarn(gpa: std.mem.Allocator, warnings: *std.ArrayList([]const u8), comptime T: type, optName: []const u8, value: []const u8, default: T) ParseError!T {
        return parseEnumOpt(T, value) orelse {
            try warnings.append(gpa, try std.fmt.allocPrint(gpa, "Invalid --{s} option \"{s}\", using default \"{s}\" instead.", .{ optName, value, @tagName(default) }));
            return default;
        };
    }

    /// Parses "on"/"off" into a bool; warns and returns `default` on a mismatch.
    fn parseOnOffWarn(gpa: std.mem.Allocator, warnings: *std.ArrayList([]const u8), optName: []const u8, value: []const u8, default: bool) ParseError!bool {
        if (std.mem.eql(u8, value, "on")) return true;
        if (std.mem.eql(u8, value, "off")) return false;
        try warnings.append(gpa, try std.fmt.allocPrint(gpa, "Invalid --{s} option \"{s}\", using default \"{s}\" instead.", .{ optName, value, if (default) "on" else "off" }));
        return default;
    }
};

pub const progress_mod = struct {
    const builtin = @import("builtin");

    const spaces: [512]u8 = @splat(' ');

    pub const Progress = struct {
        width: usize = 0,

        pub fn update(self: *Progress, comptime fmt: []const u8, args: anytype) void {
            if (builtin.is_test) return;
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
            std.debug.print("\r{s}", .{msg});
            if (msg.len < self.width) std.debug.print("{s}", .{spaces[0 .. self.width - msg.len]});
            self.width = msg.len;
        }

        pub fn clear(self: *Progress) void {
            if (builtin.is_test) return;
            if (self.width == 0) return;
            std.debug.print("\r{s}\r", .{spaces[0..@min(self.width, spaces.len)]});
            self.width = 0;
        }
    };
};

/// Process entry point.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const opts = try options.parseArgs(gpa, args[1..]);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.OmitKind);
    defer gpa.free(opts.omitDoc);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    defer if (opts.appendOwned) gpa.free(opts.append);
    defer {
        for (opts.parseWarnings) |w| gpa.free(w);
        gpa.free(opts.parseWarnings);
    }

    var runWarnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (runWarnings.items) |w| gpa.free(w);
        runWarnings.deinit(gpa);
    }

    run(gpa, init.io, opts, &runWarnings) catch |err| switch (err) {
        error.NoInputs => std.debug.print("Nothing to document: no matching input files found.\n", .{}),
        else => {
            std.debug.print("Zigdoc error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };

    for (opts.parseWarnings) |w| std.debug.print("{s}\n", .{w});
    for (runWarnings.items) |w| std.debug.print("{s}\n", .{w});
}

/// Reads the first input, extracts its `DocTree`, and dispatches to a
/// layout-specific writer. Non-fatal problems hit while writing output
/// (e.g. a file that failed to minify) are appended to `warnings`,
/// printed by the caller once this returns.
fn run(gpa: std.mem.Allocator, io: std.Io, opts: options.Options, warnings: *std.ArrayList([]const u8)) !void {
    if (opts.inputs.len == 0) return error.NoInputs;

    var progress: progress_mod.Progress = .{};
    var tree = switch (opts.discover) {
        .fs => try buildFsTree(gpa, io, opts, &progress),
        .ns => try buildImportTree(gpa, io, opts, &progress),
    };
    defer tree.deinit(gpa);

    progress.update("processing sections", .{});
    model.sortSections(tree.sections, toSectionOrder(opts.itemOrder));
    if (opts.OmitKind.len > 0) {
        var excluded: std.ArrayList(model.OmitKind) = .empty;
        defer excluded.deinit(gpa);
        for (opts.OmitKind) |k| try excluded.append(gpa, toModelOmitKind(k));
        try model.filterSections(gpa, &tree.sections, excluded.items);
    }
    if (opts.omitDoc.len > 0) {
        var excluded: std.ArrayList(model.OmitDocFlag) = .empty;
        defer excluded.deinit(gpa);
        for (opts.omitDoc) |f| try excluded.append(gpa, toModelOmitDocFlag(f));
        model.markOmitDoc(tree.sections, excluded.items);
    }
    if (!opts.private) {
        try model.filterPrivate(gpa, &tree.sections);
    }
    if (!opts.showEmpty) {
        try model.filterEmpty(gpa, &tree.sections);
    }

    const title = if (opts.title) |t| try gpa.dupe(u8, t) else try guessTitle(gpa, io, opts.inputs[0]);
    defer gpa.free(title);

    progress.update("loading templates", .{});
    var templates = try loadTemplates(gpa, io, opts);
    defer templates.deinit(gpa);

    if (opts.clear) try clearOutputDir(gpa, io, opts.out);

    try writeOutput(gpa, io, tree, title, opts, templates, &progress, warnings);
}

// Filesystem discovery (`--discover fs`, the default): walks
// `opts.inputs` for matching files, extracts each, and merges into
// one `DocTree`.
fn buildFsTree(gpa: std.mem.Allocator, io: std.Io, opts: options.Options, progress: *progress_mod.Progress) !model.DocTree {
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    var labels: std.ArrayList([]const u8) = .empty;
    defer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    var isZig: std.ArrayList(bool) = .empty;
    defer isZig.deinit(gpa);
    for (opts.inputs) |input| {
        try collectFiles(gpa, io, input, opts.filetypes, &paths, &labels, &isZig);
    }
    if (paths.items.len == 0) return error.NoInputs;

    var trees: std.ArrayList(model.DocTree) = .empty;
    defer {
        for (trees.items) |*t| t.deinit(gpa);
        trees.deinit(gpa);
    }
    var zigLabels: std.ArrayList([]const u8) = .empty;
    defer zigLabels.deinit(gpa); // borrows from `labels`, doesn't own
    var rawSections: std.ArrayList(model.Section) = .empty;
    defer {
        for (rawSections.items) |*s| model.freeSection(gpa, s);
        rawSections.deinit(gpa);
    }
    for (paths.items, 0..) |path, i| {
        progress.update("documenting {s} ({d}/{d})", .{ labels.items[i], i + 1, paths.items.len });
        if (isZig.items[i]) {
            const source = try readFileSentinel(gpa, io, path);
            defer gpa.free(source);
            // Single-file mode uses this same name as the root section's
            // own path, matching `--ext`'s display convention before
            // `extractFile` stamps it onto every decl below.
            const moduleName = try model.fileDisplayName(gpa, path, opts.ext, false);
            defer gpa.free(moduleName);
            try trees.append(gpa, try extract.extractFile(gpa, moduleName, labels.items[i], source, opts.recursive, opts.collectsExtras(), opts.tests != .none));
            try zigLabels.append(gpa, labels.items[i]);
        } else {
            const content = try readFileRaw(gpa, io, path);
            defer gpa.free(content);
            const moduleName = moduleNameFromPath(path);
            const display = try model.fileDisplayName(gpa, labels.items[i], opts.ext, opts.dir and !opts.tree);
            defer gpa.free(display);
            try rawSections.append(gpa, try model.rawFileSection(gpa, moduleName, display, labels.items[i], content));
        }
    }

    const rootIsDir = pathIsDir(io, opts.inputs[0]);

    const tree = if (trees.items.len == 1 and rawSections.items.len == 0) blk: {
        // No merge, so no synthetic per-file wrapper — just the file's
        // own top-level decls.
        var t = trees.items[0];
        const display = try model.fileDisplayName(gpa, zigLabels.items[0], opts.ext, false);
        gpa.free(t.moduleName);
        t.moduleName = display;
        t.rootIsDir = rootIsDir;
        break :blk t;
    } else if (trees.items.len == 0 and rawSections.items.len == 1) blk: {
        // A single raw (non-`.zig`) file with nothing to merge against.
        const s = rawSections.items[0];
        rawSections.items.len = 0; // ownership moves into `tree.sections` below
        const sections = try gpa.alloc(model.Section, 1);
        sections[0] = s;
        break :blk model.DocTree{ .moduleName = try gpa.dupe(u8, s.name), .rootDocComment = null, .sections = sections, .sourceFile = try gpa.dupe(u8, s.sourceFile), .rootIsDir = rootIsDir };
    } else blk: {
        const rootLabel = try rootModuleName(gpa, io, opts.inputs[0]);
        defer gpa.free(rootLabel);
        const rootName = if (rootIsDir)
            try std.fmt.allocPrint(gpa, "{s}/", .{rootLabel})
        else
            try gpa.dupe(u8, rootLabel);
        defer gpa.free(rootName);

        var merged = try model.mergeTrees(gpa, rootName, trees.items, .{
            .fileLabels = zigLabels.items,
            .showExt = opts.ext,
            .showDirPrefix = opts.dir and !opts.tree,
        });
        trees.items.len = 0; // ownership moved into `merged.sections` above

        if (rawSections.items.len > 0) {
            const combined = try gpa.alloc(model.Section, merged.sections.len + rawSections.items.len);
            @memcpy(combined[0..merged.sections.len], merged.sections);
            @memcpy(combined[merged.sections.len..], rawSections.items);
            gpa.free(merged.sections);
            merged.sections = combined;
            rawSections.items.len = 0; // ownership moved into `merged.sections` above
        }
        merged.rootIsDir = rootIsDir;
        break :blk merged;
    };
    trees.items.len = 0; // ownership moved into `tree` above either way
    return tree;
}

/// Import-graph discovery (`--discover ns`): follows `@import(...)` from a root file and
/// returns its content as the `DocTree` directly, resolving re-exports through to their
/// real target. A single input file is walked directly; multiple inputs are walked
/// independently and merged as flat namespace siblings. Filesystem-layout options
/// (`--filetypes`/`--dir`/`--tree`/`--dirorder`) don't apply here.
fn buildImportTree(gpa: std.mem.Allocator, io: std.Io, opts: options.Options, progress: *progress_mod.Progress) !model.DocTree {
    if (opts.inputs.len == 1 and !pathIsDir(io, opts.inputs[0])) {
        progress.update("documenting {s} (import graph)", .{opts.inputs[0]});
        return imports.walkDisk(gpa, io, opts.inputs[0], opts.recursive, opts.collectsExtras(), opts.tests != .none, progress);
    }

    std.debug.print("Discovering multiple inputs in namespace mode - this may take some time.\n", .{});

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    for (opts.inputs) |input| {
        if (pathIsDir(io, input)) {
            const dirFiles = try collectTopLevelZigFiles(gpa, io, input);
            defer gpa.free(dirFiles);
            for (dirFiles) |f| try files.append(gpa, f);
        } else {
            try files.append(gpa, try gpa.dupe(u8, input));
        }
    }
    if (files.items.len == 0) return error.NoInputs;

    var trees: std.ArrayList(model.DocTree) = .empty;
    defer {
        for (trees.items) |*t| t.deinit(gpa);
        trees.deinit(gpa);
    }
    for (files.items, 0..) |file, i| {
        progress.update("documenting {s} (import graph) ({d}/{d})", .{ file, i + 1, files.items.len });
        try trees.append(gpa, try imports.walkDisk(gpa, io, file, opts.recursive, opts.collectsExtras(), opts.tests != .none, progress));
    }

    const rootLabel = try rootModuleName(gpa, io, opts.inputs[0]);
    defer gpa.free(rootLabel);
    const rootName = try std.fmt.allocPrint(gpa, "{s}/", .{rootLabel});
    defer gpa.free(rootName);

    const tree = try model.mergeNamespaceTrees(gpa, rootName, trees.items);
    trees.items.len = 0; // ownership moved into `tree.sections` above
    return tree;
}

/// Lists `.zig` files directly inside `path` (not recursive). Returns
/// an empty slice for a missing/non-directory `path` rather than erroring.
fn collectTopLevelZigFiles(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return out.toOwnedSlice(gpa),
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!hasExtension(entry.name, "zig")) continue;
        const dirPrefix = path;
        const full = if (dirPrefix.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try std.fs.path.join(gpa, &.{ dirPrefix, entry.name });
        defer gpa.free(full);
        try out.append(gpa, try normalizeLabelSlashes(gpa, full));
    }

    return out.toOwnedSlice(gpa);
}

/// The four resolved template bodies for one run: either the
/// corresponding `--tpl-*` file's contents, or the `template.zig`
/// default. Both formats' templates are always loaded, regardless of
/// `opts.format`, so passing an unused `--tpl-*` flag is never an error.
const Templates = struct {
    htmlDoc: []const u8,
    htmlSec: []const u8,
    mdDoc: []const u8,
    mdSec: []const u8,
    ownedHtmlDoc: bool,
    ownedHtmlSec: bool,
    ownedMdDoc: bool,
    ownedMdSec: bool,

    fn deinit(self: *Templates, gpa: std.mem.Allocator) void {
        if (self.ownedHtmlDoc) gpa.free(self.htmlDoc);
        if (self.ownedHtmlSec) gpa.free(self.htmlSec);
        if (self.ownedMdDoc) gpa.free(self.mdDoc);
        if (self.ownedMdSec) gpa.free(self.mdSec);
    }
};

fn loadTemplates(gpa: std.mem.Allocator, io: std.Io, opts: options.Options) !Templates {
    var t: Templates = .{
        .htmlDoc = template.htmlDoc,
        .htmlSec = template.htmlSec,
        .mdDoc = template.mdDoc,
        .mdSec = template.mdSec,
        .ownedHtmlDoc = false,
        .ownedHtmlSec = false,
        .ownedMdDoc = false,
        .ownedMdSec = false,
    };
    errdefer t.deinit(gpa);

    if (opts.tplHtmlDoc) |path| {
        t.htmlDoc = try readTemplateFile(gpa, io, path);
        t.ownedHtmlDoc = true;
    }
    if (opts.tplHtmlSec) |path| {
        t.htmlSec = try readTemplateFile(gpa, io, path);
        t.ownedHtmlSec = true;
    }
    if (opts.tplMdDoc) |path| {
        t.mdDoc = try readTemplateFile(gpa, io, path);
        t.ownedMdDoc = true;
    }
    if (opts.tplMdSec) |path| {
        t.mdSec = try readTemplateFile(gpa, io, path);
        t.ownedMdSec = true;
    }
    return t;
}

fn readTemplateFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), null);
}

/// Guesses a project title from the parent directory name of `path`
/// (e.g. `/home/me/myproject/src` → `myproject`). Falls back to
/// `path`'s own basename if there's no parent component.
fn guessTitle(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const abs = try std.fs.path.resolve(gpa, &.{ cwd, trimmed });
    defer gpa.free(abs);
    const dir = std.fs.path.dirname(abs) orelse return gpa.dupe(u8, std.fs.path.basename(abs));
    return gpa.dupe(u8, std.fs.path.basename(dir));
}

/// Walks `path` (or, if it's a single file, just records that file),
/// appending every file whose extension is in `filetypes` to `outPaths`
/// and each one's directory-relative label to `outLabels`. `outIsZig[i]`
/// says whether `outPaths[i]` is parsed for decls or shown as raw content.
fn collectFiles(gpa: std.mem.Allocator, io: std.Io, path: []const u8, filetypes: []const []const u8, outPaths: *std.ArrayList([]const u8), outLabels: *std.ArrayList([]const u8), outIsZig: *std.ArrayList(bool)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            try outPaths.append(gpa, try normalizeLabelSlashes(gpa, path));
            try outLabels.append(gpa, try gpa.dupe(u8, std.fs.path.basename(path)));
            try outIsZig.append(gpa, hasExtension(std.fs.path.basename(path), "zig"));
            return;
        },
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = matchExtension(entry.basename, filetypes) orelse continue;
        const dirPrefix = path;
        const fullRaw = if (dirPrefix.len == 0)
            try gpa.dupe(u8, entry.path)
        else
            try std.fs.path.join(gpa, &.{ dirPrefix, entry.path });
        defer gpa.free(fullRaw);
        const full = try normalizeLabelSlashes(gpa, fullRaw);
        errdefer gpa.free(full);
        try outPaths.append(gpa, full);
        try outLabels.append(gpa, try normalizeLabelSlashes(gpa, entry.path));
        try outIsZig.append(gpa, std.mem.eql(u8, ext, "zig"));
    }
}

/// Deletes existing `.html`/`.md`/`.js`/`.css` files under `path`,
/// recursively, then removes any directory left empty by that. No-op
/// if `path` doesn't exist yet.
fn clearOutputDir(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (dirs.items) |d| gpa.free(d);
        dirs.deinit(gpa);
    }

    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                if (matchExtension(entry.basename, &.{ "html", "md", "js", "css" }) == null) continue;
                try dir.deleteFile(io, entry.path);
            },
            .directory => try dirs.append(gpa, try gpa.dupe(u8, entry.path)),
            else => {},
        }
    }

    std.mem.sort([]const u8, dirs.items, {}, longestPathFirst);
    for (dirs.items) |d| dir.deleteDir(io, d) catch |err| switch (err) {
        error.DirNotEmpty => {},
        else => return err,
    };
}

/// Sorts deepest paths first so `clearOutputDir` removes a directory's
/// children before the directory itself.
fn longestPathFirst(_: void, a: []const u8, b: []const u8) bool {
    return a.len > b.len;
}

/// Returns the matching entry of `filetypes` if `basename` ends with
/// `.` + that extension, else null.
fn matchExtension(basename: []const u8, filetypes: []const []const u8) ?[]const u8 {
    for (filetypes) |ext| {
        if (hasExtension(basename, ext)) return ext;
    }
    return null;
}

fn hasExtension(basename: []const u8, ext: []const u8) bool {
    if (basename.len < ext.len + 1) return false;
    return basename[basename.len - ext.len - 1] == '.' and
        std.mem.eql(u8, basename[basename.len - ext.len ..], ext);
}

fn ensureDir(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn warnIgnoredOptions(opts: options.Options) void {
    if (opts.format == .md and opts.theme != .auto) {
        std.debug.print("HTML-specific option \"--theme\" ignored.\n", .{});
    }
    if (opts.format == .md and !std.mem.eql(u8, opts.head, options.defaultHead)) {
        std.debug.print("HTML-specific option \"--head\" ignored.\n", .{});
    }
    if (opts.format == .md and opts.collapse != .all) {
        std.debug.print("HTML-specific option \"--collapse\" ignored.\n", .{});
    }
    if (opts.format == .md and opts.css == .external) {
        std.debug.print("HTML-specific option \"--css external\" ignored.\n", .{});
    }
    if (opts.split == .none and !opts.extUrls) {
        std.debug.print("Option \"--exturls\" has no effect for \"--split none\", ignored.\n", .{});
    }
    if (opts.split == .none and !opts.dirUrls) {
        std.debug.print("Option \"--dirurls\" has no effect for \"--split none\", ignored.\n", .{});
    }
    if (opts.format == .md and opts.prettyUrls) {
        std.debug.print("HTML-specific option \"--prettyurls\" ignored.\n", .{});
    }
    if (opts.format == .md and opts.codelinks) {
        std.debug.print("HTML-specific option \"--codelinks\" ignored.\n", .{});
    }
    if (opts.format == .md and opts.search) {
        std.debug.print("HTML-specific option \"--search\" ignored.\n", .{});
    }
    if (opts.format == .md and !opts.minify) {
        std.debug.print("HTML-specific option \"--minify\" ignored.\n", .{});
    }
    if (opts.discover == .ns and !opts.dir) {
        std.debug.print("Option \"--dir\" has no effect for \"--discover ns\", ignored.\n", .{});
    }
    if (opts.discover == .ns and !opts.tree) {
        std.debug.print("Option \"--tree\" has no effect for \"--discover ns\", ignored.\n", .{});
    }
    if (opts.discover == .ns and opts.dirOrder != .first) {
        std.debug.print("Option \"--dirorder\" has no effect for \"--discover ns\", ignored.\n", .{});
    }
    if (opts.discover == .ns and opts.collapse == .dir) {
        std.debug.print("Option \"--collapse dir\" has no effect for \"--discover ns\", ignored.\n", .{});
    }
    if (opts.discover == .ns and !isDefaultFiletypes(opts.filetypes)) {
        std.debug.print("Option \"--filetypes\" has no effect for \"--discover ns\", ignored.\n", .{});
    }
}

/// Whether `filetypes` is exactly the unmodified `--filetypes` default.
fn isDefaultFiletypes(filetypes: []const []const u8) bool {
    return filetypes.len == 1 and std.mem.eql(u8, filetypes[0], "zig");
}

/// Renders `tree` to `opts.out` (creating it if needed) and writes
/// every resulting page.
fn writeOutput(gpa: std.mem.Allocator, io: std.Io, tree: model.DocTree, title: []const u8, opts: options.Options, templates: Templates, progress: *progress_mod.Progress, warnings: *std.ArrayList([]const u8)) !void {
    try ensureDir(io, opts.out);

    const pages = switch (opts.format) {
        .html => try render.write(gpa, .html, tree, title, opts, templates.htmlDoc, templates.htmlSec, progress),
        .md => try render.write(gpa, .md, tree, title, opts, templates.mdDoc, templates.mdSec, progress),
    };
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }
    for (pages, 0..) |p, i| {
        progress.update("writing {s} ({d}/{d})", .{ p.filename, i + 1, pages.len });
        const minifyKind: ?minify.Kind = if (opts.format == .html) .html else null;
        try writeOutFile(gpa, io, opts.out, p.filename, p.contents, minifyKind, opts.minify, warnings);
    }
    progress.clear();

    if (opts.css == .external and opts.format == .html) {
        const cssPath = try std.fs.path.join(gpa, &.{ opts.out, "style.css" });
        defer gpa.free(cssPath);
        const cssData = try style.css(gpa, opts, opts.theme);
        defer gpa.free(cssData);
        const cssOut = try minifyOrFallback(gpa, .css, cssData, opts.minify, "style.css", warnings);
        defer gpa.free(cssOut);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cssPath, .data = cssOut });
    }

    if (opts.search and opts.format == .html) {
        const entries = try search.buildIndex(gpa, tree, opts);
        defer search.freeEntries(gpa, entries);
        const indexJs = try search.toJs(gpa, entries);
        defer gpa.free(indexJs);

        const indexPath = try std.fs.path.join(gpa, &.{ opts.out, "search-index.js" });
        defer gpa.free(indexPath);
        const indexJsOut = try minifyOrFallback(gpa, .js, indexJs, opts.minify, "search-index.js", warnings);
        defer gpa.free(indexJsOut);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = indexPath, .data = indexJsOut });

        const scriptPath = try std.fs.path.join(gpa, &.{ opts.out, "search.js" });
        defer gpa.free(scriptPath);
        const scriptOut = try minifyOrFallback(gpa, .js, search.clientJs, opts.minify, "search.js", warnings);
        defer gpa.free(scriptOut);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = scriptPath, .data = scriptOut });
    }

    if (opts.split == .none) {
        const outPath = try std.fs.path.join(gpa, &.{ opts.out, opts.filename });
        defer gpa.free(outPath);
        std.debug.print("wrote {s}\n", .{outPath});
    } else {
        std.debug.print("wrote {s}/\n", .{opts.out});
    }

    warnIgnoredOptions(opts);
}

/// `filename` may include `/`-separated directory components — any
/// needed parent directories under `outDir` are created first. `minifyKind`
/// is `null` for `md` output, which is never minified.
fn writeOutFile(gpa: std.mem.Allocator, io: std.Io, outDir: []const u8, filename: []const u8, contents: []const u8, minifyKind: ?minify.Kind, doMinify: bool, warnings: *std.ArrayList([]const u8)) !void {
    const outPath = try std.fs.path.join(gpa, &.{ outDir, filename });
    defer gpa.free(outPath);
    if (std.fs.path.dirname(outPath)) |dir| {
        try ensureDir(io, dir);
    }
    if (minifyKind) |kind| {
        const out = try minifyOrFallback(gpa, kind, contents, doMinify, filename, warnings);
        defer gpa.free(out);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = outPath, .data = out });
    } else {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = outPath, .data = contents });
    }
}

/// Minifies `contents` as `kind` when `doMinify` is set. On failure, or when
/// `doMinify` is off, returns an owned copy of `contents` unchanged; a
/// failure also records a warning naming `label` (the file being written).
fn minifyOrFallback(gpa: std.mem.Allocator, kind: minify.Kind, contents: []const u8, doMinify: bool, label: []const u8, warnings: *std.ArrayList([]const u8)) ![]u8 {
    if (!doMinify) return gpa.dupe(u8, contents);
    const result = switch (kind) {
        .html => minify.html(gpa, contents, null),
        .css => minify.css(gpa, contents, null),
        .js => minify.js(gpa, contents, null),
        .svg => minify.svg(gpa, contents, null),
    } catch |err| {
        try warnings.append(gpa, try std.fmt.allocPrint(gpa, "Failed to minify \"{s}\" ({t}), writing unminified.", .{ label, err }));
        return gpa.dupe(u8, contents);
    };
    return result;
}

/// Reads a file fully into a null-terminated buffer, as `Ast.parse` needs.
fn readFileSentinel(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
}

/// Reads a non-`.zig` `--filetypes` file's raw content.
fn readFileRaw(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), null);
}

/// Normalizes `path` to `/`-separated labels, since directory-relative
/// labels are display strings, not real filesystem paths, and
/// `std.Io.Dir.Walker` uses the OS's native separator.
fn normalizeLabelSlashes(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// Derives a module name from a file path's stem.
fn moduleNameFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return std.fs.path.stem(base);
}

/// Like `moduleNameFromPath`, but for the merged root's own name, where
/// `path` may resolve to `.` — falls back to the real cwd name.
fn rootModuleName(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const base = moduleNameFromPath(path);
    if (!std.mem.eql(u8, base, ".")) return gpa.dupe(u8, base);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const abs = try std.fs.path.resolve(gpa, &.{ cwd, path });
    defer gpa.free(abs);
    return gpa.dupe(u8, std.fs.path.basename(abs));
}

/// Explicit mapping from `options.ItemOrder` to `model.SectionOrder` —
/// no reliance on the two enums sharing tag order.
fn toSectionOrder(order: options.ItemOrder) model.SectionOrder {
    return switch (order) {
        .code => .code,
        .alpha => .alpha,
        .grouped => .grouped,
    };
}

/// Explicit mapping from `options.OmitKind` to `model.OmitKind`.
fn toModelOmitKind(k: options.OmitKind) model.OmitKind {
    return switch (k) {
        .fn_decl => .fn_decl,
        .var_decl => .var_decl,
        .const_decl => .const_decl,
        .struct_decl => .struct_decl,
        .enum_decl => .enum_decl,
        .union_decl => .union_decl,
        .opaque_decl => .opaque_decl,
        .file => .file,
        .namespace_decl => .namespace_decl,
    };
}

/// Explicit mapping from `options.OmitDocFlag` to `model.OmitDocFlag`.
/// `none` never reaches here — `parseOmitDoc` already drops it.
fn toModelOmitDocFlag(f: options.OmitDocFlag) model.OmitDocFlag {
    return switch (f) {
        .functions => .functions,
        .fields => .fields,
        .errors => .errors,
        .params => .params,
        .values => .values,
        .none => unreachable,
    };
}

/// Whether `path` is a directory.
fn pathIsDir(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

test {
    // Pulls every imported module's own test blocks into this file's
    // test set, so `zig build test` covers all of `src/`.
    std.testing.refAllDecls(@This());
}
