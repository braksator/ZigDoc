//! Format-agnostic intermediate representation shared by all renderers.
const std = @import("std");

/// What kind of thing a `Section` documents.
pub const Kind = enum {
    file,
    fn_decl,
    var_decl,
    const_decl,
    struct_decl,
    enum_decl,
    union_decl,
    opaque_decl,
    directory,
};

/// A single extracted declaration, plus its nested children.
pub const Section = struct {
    name: []const u8,
    path: []const u8,
    signature: []const u8,
    docComment: []const u8,
    source: []const u8,
    /// Path of the file this decl was extracted from, relative to the
    /// documented input root (not resolved/absolute, and never the
    /// raw CLI input path — see `extractFile`'s `sourcePath`).
    sourceFile: []const u8,
    /// 1-based line number the decl starts on.
    sourceLine: u32,
    /// What this section documents.
    kind: Kind = .const_decl,
    children: []Section,
    /// Whether the source item has nested named members, independent
    /// of `--recursive`: stays true even when `children` is empty
    /// because extraction didn't descend.
    hasChildren: bool = false,
    /// Directory-relative path.
    fileLabel: []const u8 = "",
    /// True for a non-`.zig` file's synthetic section (`--filetypes`):
    /// `source` is arbitrary file content, not Zig — renderers must not
    /// syntax-highlight it or fence it as ```zig in Markdown.
    raw: bool = false,
    /// File size in bytes. Only set (and only shown) for `raw` sections
    /// — an ordinary decl's size isn't meaningful, its source already
    /// shows the extent.
    sizeBytes: u64 = 0,

    /// HTML id / md fragment anchor for this section.
    pub fn anchorSlug(self: Section, gpa: std.mem.Allocator) ![]u8 {
        return slugify(gpa, self.path);
    }

    /// Anchor slug for Markdown output: uses `slugifyMd` so the result
    /// matches the heading ID auto-generated from `## {path}`.
    pub fn anchorSlugMd(self: Section, gpa: std.mem.Allocator) ![]u8 {
        return slugifyMd(gpa, self.path);
    }

    /// Filename stem for this section's page in split layout.
    pub fn fileStem(self: Section, gpa: std.mem.Allocator) ![]u8 {
        return self.anchorSlug(gpa);
    }

    /// Like `slugify` but for Markdown headings: replaces every character
    /// that is not alphanumeric with a hyphen and lowercases, matching the
    /// anchor IDs that most Markdown renderers auto-generate from heading text.
    pub fn slugifyMd(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
        var out = try gpa.alloc(u8, path.len);
        for (path, 0..) |c, i| {
            out[i] = switch (c) {
                'a'...'z', '0'...'9' => c,
                'A'...'Z' => c - 'A' + 'a',
                else => '-',
            };
        }
        return out;
    }
};

/// A module's full set of extracted sections, ready for rendering.
pub const DocTree = struct {
    moduleName: []const u8,
    rootDocComment: ?[]const u8,
    sections: []Section,
    /// The file's full source text, for `--filesource`. `""`
    /// for a merged/synthetic root tree that has no single backing
    /// file (`mergeTrees`'s own return value) — only a tree built
    /// directly by `extract.extractFile` for one real `.zig` file has
    /// this populated.
    fullSource: []const u8 = "",

    /// Frees every allocation owned by this tree.
    pub fn deinit(self: *DocTree, gpa: std.mem.Allocator) void {
        for (self.sections) |*s| freeSection(gpa, s);
        gpa.free(self.sections);
        gpa.free(self.moduleName);
        if (self.rootDocComment) |doc| gpa.free(doc);
        if (self.fullSource.len > 0) gpa.free(self.fullSource);
        self.* = undefined;
    }
};

/// Wraps a single file's extracted `DocTree` as a synthetic top-level
/// `Section` representing that module, for merging into a combined
/// tree. `displayName` is the already-formatted label to show in
/// headings/index links (`--ext`/`--dir` applied); `rawLabel` is the
/// unformatted directory-relative path (always with extension and any
/// directory components), used only to group the index into a tree
/// when `--tree` is on. `locationPath` is the real, openable path
/// (input-root-relative, e.g. `src/foo.zig`) shown in `{location}`;
/// falls back to `rawLabel` if the file had no decls to source it
/// from. `path`/anchors are unaffected by any of these — they stay
/// keyed on `tree.moduleName`, the identifier used while extracting,
/// so display formatting never changes an anchor.
pub fn moduleSection(gpa: std.mem.Allocator, tree: DocTree, displayName: []const u8, rawLabel: []const u8, locationPath: []const u8) !Section {
    return Section{
        .name = try gpa.dupe(u8, displayName),
        .path = try gpa.dupe(u8, tree.moduleName),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, tree.rootDocComment orelse ""),
        .source = try gpa.dupe(u8, tree.fullSource),
        .sourceFile = try gpa.dupe(u8, locationPath),
        .sourceLine = 0,
        .kind = .file,
        .children = tree.sections,
        .fileLabel = try gpa.dupe(u8, rawLabel),
    };
}

/// Builds a synthetic per-file `Section` for a non-`.zig` input
/// (`--filetypes`): no decls, no doc comment — just `content` as its
/// raw, unhighlighted `source`. Shaped like `moduleSection`'s output so
/// it slots into the same `--dir`/`--tree` grouping.
pub fn rawFileSection(gpa: std.mem.Allocator, moduleName: []const u8, displayName: []const u8, rawLabel: []const u8, content: []const u8) !Section {
    return Section{
        .name = try gpa.dupe(u8, displayName),
        .path = try gpa.dupe(u8, moduleName),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, content),
        .sourceFile = try gpa.dupe(u8, rawLabel),
        .sourceLine = 0,
        .kind = .file,
        .children = &.{},
        .fileLabel = try gpa.dupe(u8, rawLabel),
        .raw = true,
        .sizeBytes = content.len,
    };
}

/// Detects `path` collisions among top-level file-kind sections and
/// returns a new slice where colliding sections have disambiguated
/// `path`s built from their real `fileLabel` (e.g. `render.html_single`
/// instead of `html_single`). Non-colliding sections are unchanged.
/// Caller owns the returned slice; only changed sections' `path`/`children`
/// are freshly allocated — everything else is shared with the originals.
pub fn disambiguateSectionPaths(gpa: std.mem.Allocator, sections: []const Section) ![]Section {
    const out = try gpa.dupe(Section, sections);
    errdefer gpa.free(out);

    for (out, 0..) |s, i| {
        if (s.kind != .file or s.fileLabel.len == 0) continue;
        var collides = false;
        for (out, 0..) |other, j| {
            if (i == j) continue;
            if (other.kind == .file and other.fileLabel.len > 0 and std.mem.eql(u8, other.path, s.path)) {
                collides = true;
                break;
            }
        }
        if (!collides) continue;

        const stem = stripZigExt(s.fileLabel);
        const newPrefix = try gpa.alloc(u8, stem.len);
        defer gpa.free(newPrefix);
        for (stem, 0..) |c, k| newPrefix[k] = if (c == '/') '.' else c;

        out[i] = try withRenamedPathPrefix(gpa, s, s.path, newPrefix);
    }

    return out;
}

fn withRenamedPathPrefix(gpa: std.mem.Allocator, section: Section, oldPrefix: []const u8, newPrefix: []const u8) !Section {
    var copy = section;
    if (std.mem.startsWith(u8, section.path, oldPrefix)) {
        copy.path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ newPrefix, section.path[oldPrefix.len..] });
    }
    if (section.children.len > 0) {
        const children = try gpa.alloc(Section, section.children.len);
        for (section.children, 0..) |child, i| {
            children[i] = try withRenamedPathPrefix(gpa, child, oldPrefix, newPrefix);
        }
        copy.children = children;
    }
    return copy;
}

/// Frees a slice returned by `disambiguateSectionPaths`. `originals`
/// is the same slice originally passed to it (e.g. `tree.sections`).
pub fn freeDisambiguatedSections(gpa: std.mem.Allocator, sections: []Section, originals: []const Section) void {
    for (sections, originals) |s, orig| {
        if (s.children.ptr != orig.children.ptr) {
            freeRenamedChildren(gpa, s.children, orig.children);
        }
        if (s.path.ptr != orig.path.ptr) gpa.free(s.path);
    }
    gpa.free(sections);
}

fn freeRenamedChildren(gpa: std.mem.Allocator, children: []Section, originals: []const Section) void {
    for (children, originals) |c, orig| {
        if (c.children.ptr != orig.children.ptr) {
            freeRenamedChildren(gpa, c.children, orig.children);
        }
        if (c.path.ptr != orig.path.ptr) gpa.free(c.path);
    }
    gpa.free(children);
}

/// Merges several file-level `DocTree`s into one, with each file's
/// sections nested under a synthetic section named for its module.
/// `rawLabels[i]` is `trees[i]`'s directory-relative source path (see
/// `moduleSection`); `showExt`/`showDirPrefix` control how that
/// becomes each synthetic section's display name. Takes ownership of
/// `trees`' `sections` slices; frees everything else each tree owns.
pub fn mergeTrees(
    gpa: std.mem.Allocator,
    moduleName: []const u8,
    trees: []DocTree,
    rawLabels: []const []const u8,
    showExt: bool,
    showDirPrefix: bool,
) !DocTree {
    var sections = try gpa.alloc(Section, trees.len);
    errdefer gpa.free(sections);

    for (trees, 0..) |*tree, i| {
        const displayName = try fileDisplayName(gpa, rawLabels[i], showExt, showDirPrefix);
        defer gpa.free(displayName);
        const locationPath = if (tree.sections.len > 0) tree.sections[0].sourceFile else rawLabels[i];
        sections[i] = try moduleSection(gpa, tree.*, displayName, rawLabels[i], locationPath);
        gpa.free(tree.moduleName);
        if (tree.rootDocComment) |doc| gpa.free(doc);
        if (tree.fullSource.len > 0) gpa.free(tree.fullSource);
        tree.* = undefined;
    }

    return DocTree{
        .moduleName = try gpa.dupe(u8, moduleName),
        .rootDocComment = null,
        .sections = sections,
    };
}

/// Formats a raw directory-relative label (e.g. `"render/foo.zig"`) for
/// display: strips the `.zig` extension unless `showExt`, and strips
/// any directory prefix down to the bare filename unless
/// `showDirPrefix`.
pub fn fileDisplayName(gpa: std.mem.Allocator, rawLabel: []const u8, showExt: bool, showDirPrefix: bool) ![]u8 {
    const based = if (showDirPrefix) rawLabel else labelBasename(rawLabel);
    if (showExt) return gpa.dupe(u8, based);
    return gpa.dupe(u8, stripExt(based));
}

fn labelBasename(label: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, label, '/')) |i| return label[i + 1 ..];
    return label;
}

/// Strips the last `.ext` from `name`, if any — generalizes what was
/// `.zig`-only stripping so `--ext off` also works for `--filetypes`'
/// non-`.zig` files (e.g. `readme.md` -> `readme`).
fn stripExt(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[0..i];
    return name;
}

/// Strips a trailing `.zig` extension, if present.
pub fn stripZigExt(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".zig")) name[0 .. name.len - 4] else name;
}

/// Recursively frees a section and its children. `fileLabel` is only
/// freed when non-empty: it defaults to `""` (a string literal, not
/// heap-allocated) for every ordinary decl section — only the
/// synthetic per-file sections `mergeTrees`/`rawFileSection` build
/// actually own a heap-allocated `fileLabel`.
pub fn freeSection(gpa: std.mem.Allocator, section: *Section) void {
    for (section.children) |*c| freeSection(gpa, c);
    gpa.free(section.children);
    gpa.free(section.name);
    gpa.free(section.path);
    gpa.free(section.signature);
    gpa.free(section.docComment);
    gpa.free(section.source);
    gpa.free(section.sourceFile);
    if (section.fileLabel.len > 0) gpa.free(section.fileLabel);
}

/// Mirrors `options.ItemOrder`; declared here (not imported from
/// `options.zig`) to avoid a dependency from the shared IR module on
/// the CLI-parsing module — `main.zig` converts at the call site.
pub const SectionOrder = enum { code, alpha, grouped };

/// Mirrors `options.DirOrder`; declared here for the same reason as
/// `SectionOrder`.
pub const DirOrder = enum { first, last, alpha };

/// Mirrors `options.OmitKind`; declared here (not imported from
/// `options.zig`) for the same reason as `SectionOrder` — `main.zig`
/// converts at the call site.
pub const OmitKind = enum { fn_decl, var_decl, const_decl, struct_decl, enum_decl, union_decl, opaque_decl };

/// Whether `kind` matches one of `excluded`.
fn kindOmitted(kind: Kind, excluded: []const OmitKind) bool {
    for (excluded) |ek| {
        const matches = switch (ek) {
            .fn_decl => kind == .fn_decl,
            .var_decl => kind == .var_decl,
            .const_decl => kind == .const_decl,
            .struct_decl => kind == .struct_decl,
            .enum_decl => kind == .enum_decl,
            .union_decl => kind == .union_decl,
            .opaque_decl => kind == .opaque_decl,
        };
        if (matches) return true;
    }
    return false;
}

/// Recursively drops sections (and their children) whose `kind` is in
/// `excluded`. In-place; dropped sections are released via
/// `freeSection`.
pub fn filterSections(gpa: std.mem.Allocator, sections: *[]Section, excluded: []const OmitKind) !void {
    var kept: std.ArrayList(Section) = .empty;
    errdefer kept.deinit(gpa);
    for (sections.*) |*s| {
        if (kindOmitted(s.kind, excluded)) {
            freeSection(gpa, s);
            continue;
        }
        try filterSections(gpa, &s.children, excluded);
        try kept.append(gpa, s.*);
    }
    gpa.free(sections.*);
    sections.* = try kept.toOwnedSlice(gpa);
}

/// Recursively sorts `sections` in place per `order`. `code` (the
/// default) is a no-op, since sections already arrive in source/AST
/// order. Applies uniformly at every level — a merged tree's top-level
/// file-wrapper sections included, not just decls within one file.
pub fn sortSections(sections: []Section, order: SectionOrder) void {
    switch (order) {
        .code => {},
        .alpha => std.mem.sort(Section, sections, {}, lessByName),
        .grouped => std.mem.sort(Section, sections, {}, lessByKindThenName),
    }
    for (sections) |*s| sortSections(s.children, order);
}

fn lessByName(_: void, a: Section, b: Section) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn lessByKindThenName(_: void, a: Section, b: Section) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Lowercases and replaces non-alphanumeric bytes with "-", except "."
/// which is preserved as the path separator — collapsing both
/// "." and a literal "-" to the same character would make two distinct
/// paths (e.g. `extract.ast` and `extract-ast`) resolve to the same
/// anchor.
pub fn slugify(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = try gpa.alloc(u8, path.len);
    for (path, 0..) |c, i| {
        out[i] = switch (c) {
            'a'...'z', '0'...'9', '.' => c,
            'A'...'Z' => c - 'A' + 'a',
            else => '-',
        };
    }
    return out;
}

/// Filesystem-safe form of a single decl name, for use in a page
/// filename or directory segment — unlike `slugify`, case is
/// preserved (`Input` stays `Input`, not `input`), since a filename
/// isn't a case-insensitive URL fragment the way an anchor `#id` is:
/// Zig identifiers are case-sensitive and two decls differing only in
/// case are a real (if rare) possibility. Only bytes that are unsafe
/// in a path segment get replaced, with "." kept as-is as an ordinary
/// filename character rather than a separator, since callers of this
/// function build one segment at a time and any directory nesting is
/// already expressed via real path separators, not dots.
pub fn filenameSegment(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = try gpa.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        out[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_' => c,
            else => '-',
        };
    }
    return avoidWindowsReservedName(gpa, out);
}

const windowsReservedNames = [_][]const u8{
    "con", "prn", "aux", "nul",
    "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
    "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
};

/// Appends a trailing "~" if `segment` (its part before any ".") case-
/// insensitively matches a Windows-reserved device name; frees `segment`
/// and returns it unchanged otherwise.
pub fn avoidWindowsReservedName(gpa: std.mem.Allocator, segment: []u8) ![]u8 {
    const base = segment[0 .. std.mem.indexOfScalar(u8, segment, '.') orelse segment.len];
    for (windowsReservedNames) |reserved| {
        if (std.ascii.eqlIgnoreCase(base, reserved)) {
            defer gpa.free(segment);
            return std.fmt.allocPrint(gpa, "{s}~{s}", .{ base, segment[base.len..] });
        }
    }
    return segment;
}

/// Number of directory levels deep a page's output path sits
/// (e.g. `"index.html"` → 0, `"render/index.html"` → 1).
pub fn pageDepth(pagePath: []const u8) usize {
    var depth: usize = 0;
    for (pagePath) |c| {
        if (c == '/') depth += 1;
    }
    return depth;
}

/// Builds a relative href from `fromPath` to `toPath`, both
/// output-relative (e.g. `"render/html_single.html"` → `"index.html"`
/// becomes `"../index.html"`). When `prettyUrls` is set, a trailing
/// `index.html` is dropped from the result (along with the slash
/// before it) — e.g. `"../index.html"` becomes `"../"`. The one
/// exception: a same-directory link (`fromPath` and `toPath` in the
/// same directory) to a bare `"index.html"` would otherwise become an
/// empty string, which isn't a valid href, so `"."` is used instead.
pub fn relativeHref(gpa: std.mem.Allocator, fromPath: []const u8, toPath: []const u8, prettyUrls: bool) ![]u8 {
    const depth = pageDepth(fromPath);
    const target = if (prettyUrls) stripIndexHtml(toPath) else toPath;
    if (depth == 0) return gpa.dupe(u8, if (target.len == 0) "." else target);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..depth) |_| try out.appendSlice(gpa, "../");
    try out.appendSlice(gpa, target);
    return out.toOwnedSlice(gpa);
}

/// Drops a trailing `"index.html"` from `path`, keeping the slash
/// before it so a directory link still ends in `/`
/// (`"foo/index.html"` → `"foo/"`). A bare `"index.html"` becomes
/// `""` — `relativeHref` is responsible for turning that into a valid
/// href (either a leading `"../"` chain, or `"."` if there's none).
/// Leaves anything not ending in exactly `"index.html"` alone.
fn stripIndexHtml(path: []const u8) []const u8 {
    const suffix = "index.html";
    if (!std.mem.endsWith(u8, path, suffix)) return path;
    return path[0 .. path.len - suffix.len];
}

/// Writes `path` as HTML with each dotted segment linked to
/// the anchor of its ancestor section.
pub fn writePathLinks(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    path: []const u8,
) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '.') {
            const prefix = path[0..i];
            const segment = path[start..i];
            const slug = try Section.slugifyMd(gpa, prefix);
            defer gpa.free(slug);
            if (start != 0) try writer.writeAll(".");
            try writer.print("<a href=\"#{s}\">{s}</a>", .{ slug, segment });
            start = i + 1;
        }
    }
}

/// Writes `path` as Markdown with each dotted segment linked to
/// the anchor of its ancestor section, e.g. `[Mod](#mod).[Fn](#mod.fn)`.
pub fn writePathLinksMd(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    path: []const u8,
) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '.') {
            const prefix = path[0..i];
            const segment = path[start..i];
            const slug = try slugify(gpa, prefix);
            defer gpa.free(slug);
            if (start != 0) try writer.writeAll(".");
            try writer.print("[{s}](#{s})", .{ segment, slug });
            start = i + 1;
        }
    }
}

/// Walks one level of `sections` (already sorted so entries sharing a
/// directory at `prefixLen` are contiguous — see `sortByFileLabelOrder`),
/// calling `onDir` with a subdirectory's name, its contiguous slice of
/// sections, and the prefix length for its own children, or `onLeaf`
/// with a single file/decl entry. Shared by `writeIndexTree` (which
/// recurses into each `onDir` slice itself) and any caller that wants
/// one level at a time, such as a split renderer's per-directory
/// listing page.
fn forEachChild(
    sections: []const Section,
    prefixLen: usize,
    context: anytype,
    comptime onDir: fn (@TypeOf(context), []const u8, []const Section, usize) anyerror!void,
    comptime onLeaf: fn (@TypeOf(context), Section) anyerror!void,
) anyerror!void {
    var i: usize = 0;
    while (i < sections.len) {
        const rel = sections[i].fileLabel[prefixLen..];
        if (std.mem.indexOfScalar(u8, rel, '/')) |slash| {
            const dirname = rel[0..slash];
            var end = i + 1;
            while (end < sections.len and dirMatches(sections[end].fileLabel, prefixLen, dirname)) : (end += 1) {}
            try onDir(context, dirname, sections[i..end], prefixLen + slash + 1);
            i = end;
        } else {
            try onLeaf(context, sections[i]);
            i += 1;
        }
    }
}

/// Groups `sections` (which must already be sorted by `fileLabel`)
/// into a directory tree by splitting each `fileLabel` on `/`, calling
/// `onDir`/`onLeaf`/`onDirEnd` to render it. Used for every `--tree`
/// index listing — the top-level index page and, in split-mode
/// output, each directory's own page — so there is one recursive
/// implementation, not a per-page one. `prefixLen` is `0` for the
/// top-level index, or `dirPath.len + 1` when starting from a
/// directory's own page. `sections` are the synthetic per-file
/// entries `mergeTrees` creates (the only ones with a non-empty
/// `fileLabel`), not ordinary decls. Format-agnostic: `onDir` opens a
/// directory group (name only, no trailing "/" — callers add that),
/// `onLeaf` renders one file entry (including recursing into its own
/// decl children however that format does so), `onDirEnd` closes a
/// group.
pub fn writeIndexTree(
    sections: []const Section,
    prefixLen: usize,
    context: anytype,
    comptime onDir: fn (@TypeOf(context), []const u8) anyerror!void,
    comptime onLeaf: fn (@TypeOf(context), Section) anyerror!void,
    comptime onDirEnd: fn (@TypeOf(context)) anyerror!void,
) anyerror!void {
    try writeIndexTreeLevel(sections, prefixLen, context, onDir, onLeaf, onDirEnd);
}

fn writeIndexTreeLevel(
    sections: []const Section,
    prefixLen: usize,
    context: anytype,
    comptime onDir: fn (@TypeOf(context), []const u8) anyerror!void,
    comptime onLeaf: fn (@TypeOf(context), Section) anyerror!void,
    comptime onDirEnd: fn (@TypeOf(context)) anyerror!void,
) anyerror!void {
    const Ctx = @TypeOf(context);
    const Cbs = struct {
        fn dir(c: Ctx, name: []const u8, children: []const Section, childPrefixLen: usize) !void {
            try onDir(c, name);
            try writeIndexTreeLevel(children, childPrefixLen, c, onDir, onLeaf, onDirEnd);
            try onDirEnd(c);
        }
        fn leaf(c: Ctx, s: Section) !void {
            try onLeaf(c, s);
        }
    };
    try forEachChild(sections, prefixLen, context, Cbs.dir, Cbs.leaf);
}

/// Walks one level of `sections`, handing `onDir` the subdirectory's
/// own contiguous slice — for callers (a split renderer's page-writing
/// pass) that need to write that subdirectory's page too, not just
/// link to it.
pub fn forEachDirGroup(
    sections: []const Section,
    prefixLen: usize,
    context: anytype,
    comptime onDir: fn (@TypeOf(context), []const u8, []const Section) anyerror!void,
    comptime onLeaf: fn (@TypeOf(context), Section) anyerror!void,
) anyerror!void {
    const Ctx = @TypeOf(context);
    const Cbs = struct {
        fn dir(c: Ctx, name: []const u8, children: []const Section, _: usize) !void {
            try onDir(c, name, children);
        }
        fn leaf(c: Ctx, s: Section) !void {
            try onLeaf(c, s);
        }
    };
    try forEachChild(sections, prefixLen, context, Cbs.dir, Cbs.leaf);
}

fn dirMatches(label: []const u8, prefixLen: usize, dirname: []const u8) bool {
    if (label.len < prefixLen) return false;
    const rel = label[prefixLen..];
    return std.mem.startsWith(u8, rel, dirname) and rel.len > dirname.len and rel[dirname.len] == '/';
}

pub fn hasFileLabels(sections: []const Section) bool {
    for (sections) |s| {
        if (s.fileLabel.len > 0) return true;
    }
    return false;
}

pub fn lessByFileLabel(_: void, a: Section, b: Section) bool {
    return std.mem.lessThan(u8, a.fileLabel, b.fileLabel);
}

/// Sorts `sections` by `fileLabel` so `writeIndexTree`/`writeDirPages`
/// group correctly, honoring `order` for how a directory sorts
/// relative to a file at the same nesting level. Directories are
/// always alphabetical relative to other directories; `order` only
/// moves the whole directory bucket before/after the file bucket
/// (`.first`/`.last`) or interleaves both alphabetically (`.alpha`).
pub fn sortByFileLabelOrder(sections: []Section, order: DirOrder) void {
    switch (order) {
        .first => std.mem.sort(Section, sections, {}, lessByFileLabelDirsFirst),
        .last => std.mem.sort(Section, sections, {}, lessByFileLabelDirsLast),
        .alpha => std.mem.sort(Section, sections, {}, lessByFileLabel),
    }
}

fn lessByFileLabelDirsFirst(_: void, a: Section, b: Section) bool {
    return lessByFileLabelBucketed(a.fileLabel, b.fileLabel, true);
}

fn lessByFileLabelDirsLast(_: void, a: Section, b: Section) bool {
    return lessByFileLabelBucketed(a.fileLabel, b.fileLabel, false);
}

/// Compares two `fileLabel`s segment by segment. At the first segment
/// where the two paths diverge, if one path ends there (a file) and
/// the other continues (a directory), the directory sorts before the
/// file when `dirsFirst` and after it otherwise. Otherwise (both
/// continue, or both end — i.e. divergence at the same "kind") the
/// segments themselves are compared alphabetically, matching plain
/// `lessByFileLabel` at every other level.
fn lessByFileLabelBucketed(a: []const u8, b: []const u8, dirsFirst: bool) bool {
    var aRest = a;
    var bRest = b;
    while (true) {
        const aSlash = std.mem.indexOfScalar(u8, aRest, '/');
        const bSlash = std.mem.indexOfScalar(u8, bRest, '/');
        const aSeg = if (aSlash) |i| aRest[0..i] else aRest;
        const bSeg = if (bSlash) |i| bRest[0..i] else bRest;

        if (!std.mem.eql(u8, aSeg, bSeg)) {
            const aIsDir = aSlash != null;
            const bIsDir = bSlash != null;
            if (aIsDir != bIsDir) return if (dirsFirst) aIsDir else bIsDir;
            return std.mem.lessThan(u8, aSeg, bSeg);
        }
        if (aSlash == null or bSlash == null) return aRest.len < bRest.len;
        aRest = aRest[aSlash.? + 1 ..];
        bRest = bRest[bSlash.? + 1 ..];
    }
}

test "writeIndexTree groups sections by directory and closes each group" {
    const gpa = std.testing.allocator;

    const mk = struct {
        fn f(label: []const u8) Section {
            return Section{
                .name = label,
                .path = label,
                .signature = "",
                .docComment = "",
                .source = "",
                .sourceFile = "",
                .sourceLine = 0,
                .children = &.{},
                .fileLabel = label,
            };
        }
    }.f;

    // Already sorted by fileLabel, as writeIndexTree requires.
    const sections = [_]Section{ mk("main.zig"), mk("render/html_single.zig"), mk("render/md_single.zig") };

    const Ctx = struct {
        out: std.ArrayList(u8) = .empty,
        gpa: std.mem.Allocator,
    };
    var ctx = Ctx{ .gpa = gpa };
    defer ctx.out.deinit(gpa);

    const cbs = struct {
        fn onDir(c: *Ctx, name: []const u8) !void {
            const s = try std.fmt.allocPrint(c.gpa, "DIR({s})", .{name});
            defer c.gpa.free(s);
            try c.out.appendSlice(c.gpa, s);
        }
        fn onLeaf(c: *Ctx, s: Section) !void {
            const str = try std.fmt.allocPrint(c.gpa, "LEAF({s})", .{s.name});
            defer c.gpa.free(str);
            try c.out.appendSlice(c.gpa, str);
        }
        fn onDirEnd(c: *Ctx) !void {
            try c.out.appendSlice(c.gpa, "END");
        }
    };

    try writeIndexTree(&sections, 0, &ctx, cbs.onDir, cbs.onLeaf, cbs.onDirEnd);

    try std.testing.expectEqualStrings("LEAF(main.zig)DIR(render)LEAF(render/html_single.zig)LEAF(render/md_single.zig)END", ctx.out.items);
}

/// Depth-first traversal of `sections`, calling `visit` on each node.
pub fn walk(
    sections: []const Section,
    context: anytype,
    comptime visit: fn (@TypeOf(context), Section) anyerror!void,
) anyerror!void {
    for (sections) |s| {
        try visit(context, s);
        try walk(s.children, context, visit);
    }
}

test "anchorSlug lowercases and preserves the '.' separator" {
    const gpa = std.testing.allocator;
    const section = Section{
        .name = "myFn",
        .path = "MyModule.MyStruct.myFn",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "",
        .sourceLine = 0,
        .children = &.{},
    };
    const slug = try section.anchorSlug(gpa);
    defer gpa.free(slug);
    try std.testing.expectEqualStrings("mymodule.mystruct.myfn", slug);
}

test "filenameSegment appends a tilde to Windows-reserved device names" {
    const gpa = std.testing.allocator;
    const nul = try filenameSegment(gpa, "nul");
    defer gpa.free(nul);
    try std.testing.expectEqualStrings("nul~", nul);

    const con = try filenameSegment(gpa, "Con");
    defer gpa.free(con);
    try std.testing.expectEqualStrings("Con~", con);

    const com1 = try filenameSegment(gpa, "COM1");
    defer gpa.free(com1);
    try std.testing.expectEqualStrings("COM1~", com1);
}

test "filenameSegment leaves non-reserved names and reserved substrings untouched" {
    const gpa = std.testing.allocator;
    const ordinary = try filenameSegment(gpa, "nullable");
    defer gpa.free(ordinary);
    try std.testing.expectEqualStrings("nullable", ordinary);

    const com10 = try filenameSegment(gpa, "com10");
    defer gpa.free(com10);
    try std.testing.expectEqualStrings("com10", com10);
}

test "mergeTrees nests each file's sections under its module name" {
    const gpa = std.testing.allocator;

    const aFn = Section{
        .name = try gpa.dupe(u8, "add"),
        .path = try gpa.dupe(u8, "a.add"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .children = &.{},
    };
    const aSections = try gpa.dupe(Section, &.{aFn});
    const treeA = DocTree{
        .moduleName = try gpa.dupe(u8, "a"),
        .rootDocComment = try gpa.dupe(u8, "Module a."),
        .sections = aSections,
    };

    const bFn = Section{
        .name = try gpa.dupe(u8, "sub"),
        .path = try gpa.dupe(u8, "b.sub"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .children = &.{},
    };
    const bSections = try gpa.dupe(Section, &.{bFn});
    const treeB = DocTree{
        .moduleName = try gpa.dupe(u8, "b"),
        .rootDocComment = null,
        .sections = bSections,
    };

    var trees = [_]DocTree{ treeA, treeB };
    const labels = [_][]const u8{ "a.zig", "b.zig" };
    var merged = try mergeTrees(gpa, "combined", &trees, &labels, true, true);
    defer merged.deinit(gpa);

    try std.testing.expectEqualStrings("combined", merged.moduleName);
    try std.testing.expectEqual(@as(usize, 2), merged.sections.len);
    try std.testing.expectEqualStrings("a.zig", merged.sections[0].name);
    try std.testing.expectEqualStrings("Module a.", merged.sections[0].docComment);
    try std.testing.expectEqual(@as(usize, 1), merged.sections[0].children.len);
    try std.testing.expectEqualStrings("add", merged.sections[0].children[0].name);
    try std.testing.expectEqualStrings("b.zig", merged.sections[1].name);
    try std.testing.expectEqualStrings("sub", merged.sections[1].children[0].name);
}

test "mergeTrees strips extension and directory prefix per showExt/showDirPrefix" {
    const gpa = std.testing.allocator;

    const aFn = Section{
        .name = try gpa.dupe(u8, "add"),
        .path = try gpa.dupe(u8, "a.add"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .children = &.{},
    };
    const aSections = try gpa.dupe(Section, &.{aFn});
    const treeA = DocTree{
        .moduleName = try gpa.dupe(u8, "a"),
        .rootDocComment = null,
        .sections = aSections,
    };

    var trees = [_]DocTree{treeA};
    const labels = [_][]const u8{"sub/a.zig"};
    var merged = try mergeTrees(gpa, "combined", &trees, &labels, false, false);
    defer merged.deinit(gpa);

    try std.testing.expectEqualStrings("a", merged.sections[0].name);
    try std.testing.expectEqualStrings("sub/a.zig", merged.sections[0].fileLabel);
}

test "walk visits nested children depth-first" {
    const gpa = std.testing.allocator;
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(gpa);

    const child = Section{
        .name = "child",
        .path = "root.child",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "",
        .sourceLine = 0,
        .children = &.{},
    };
    var children = [_]Section{child};
    const root = Section{
        .name = "root",
        .path = "root",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "",
        .sourceLine = 0,
        .children = &children,
    };
    const roots = [_]Section{root};

    const Collector = struct {
        list: *std.ArrayList([]const u8),
        gpa: std.mem.Allocator,
        fn visit(self: @This(), s: Section) !void {
            try self.list.append(self.gpa, s.name);
        }
    };
    try walk(&roots, Collector{ .list = &seen, .gpa = gpa }, Collector.visit);

    try std.testing.expectEqual(@as(usize, 2), seen.items.len);
    try std.testing.expectEqualStrings("root", seen.items[0]);
    try std.testing.expectEqualStrings("child", seen.items[1]);
}

test "sortByFileLabelOrder: first/last bucket directories, alpha interleaves" {
    const mk = struct {
        fn f(label: []const u8) Section {
            return Section{ .name = label, .path = label, .signature = "", .docComment = "", .source = "", .sourceFile = "", .sourceLine = 0, .children = &.{}, .fileLabel = label };
        }
    }.f;

    var first = [_]Section{ mk("banana.zig"), mk("apple/a.zig"), mk("cherry.zig") };
    sortByFileLabelOrder(&first, .first);
    try std.testing.expectEqualStrings("apple/a.zig", first[0].fileLabel);
    try std.testing.expectEqualStrings("banana.zig", first[1].fileLabel);
    try std.testing.expectEqualStrings("cherry.zig", first[2].fileLabel);

    var last = [_]Section{ mk("banana.zig"), mk("apple/a.zig"), mk("cherry.zig") };
    sortByFileLabelOrder(&last, .last);
    try std.testing.expectEqualStrings("banana.zig", last[0].fileLabel);
    try std.testing.expectEqualStrings("cherry.zig", last[1].fileLabel);
    try std.testing.expectEqualStrings("apple/a.zig", last[2].fileLabel);

    var alpha = [_]Section{ mk("banana.zig"), mk("apple/a.zig"), mk("cherry.zig") };
    sortByFileLabelOrder(&alpha, .alpha);
    try std.testing.expectEqualStrings("apple/a.zig", alpha[0].fileLabel);
    try std.testing.expectEqualStrings("banana.zig", alpha[1].fileLabel);
    try std.testing.expectEqualStrings("cherry.zig", alpha[2].fileLabel);
}

test "sortSections: alpha and grouped sort recursively, code is a no-op" {
    var grandchildren = [_]Section{
        .{ .name = "z", .path = "", .signature = "", .docComment = "", .source = "", .sourceFile = "", .sourceLine = 0, .kind = .fn_decl, .children = &.{} },
        .{ .name = "a", .path = "", .signature = "", .docComment = "", .source = "", .sourceFile = "", .sourceLine = 0, .kind = .const_decl, .children = &.{} },
    };
    var children = [_]Section{
        .{ .name = "b", .path = "", .signature = "", .docComment = "", .source = "", .sourceFile = "", .sourceLine = 0, .kind = .fn_decl, .children = &.{} },
        .{ .name = "a", .path = "", .signature = "", .docComment = "", .source = "", .sourceFile = "", .sourceLine = 0, .kind = .struct_decl, .children = &grandchildren },
    };
    sortSections(&children, .code);
    try std.testing.expectEqualStrings("b", children[0].name); // code: unchanged (AST order)
    try std.testing.expectEqualStrings("z", children[1].children[0].name); // recursed, still unchanged

    sortSections(&children, .alpha);
    try std.testing.expectEqualStrings("a", children[0].name);
    try std.testing.expectEqualStrings("b", children[1].name);
    try std.testing.expectEqualStrings("a", children[0].children[0].name); // recursed into "a"'s (now first) children

    sortSections(&children, .grouped);
    // fn_decl (b) sorts before struct_decl (a) by Kind's declaration order.
    try std.testing.expectEqualStrings("b", children[0].name);
    try std.testing.expectEqualStrings("a", children[1].name);
}

test "relativeHref leaves the target untouched when prettyUrls is off" {
    const gpa = std.testing.allocator;
    const href = try relativeHref(gpa, "render/foo.html", "index.html", false);
    defer gpa.free(href);
    try std.testing.expectEqualStrings("../index.html", href);
}

test "relativeHref strips a trailing index.html when prettyUrls is on" {
    const gpa = std.testing.allocator;
    const href = try relativeHref(gpa, "render/foo.html", "index.html", true);
    defer gpa.free(href);
    try std.testing.expectEqualStrings("../", href);
}

test "relativeHref strips index.html inside a subdirectory target" {
    const gpa = std.testing.allocator;
    const href = try relativeHref(gpa, "index.html", "render/index.html", true);
    defer gpa.free(href);
    try std.testing.expectEqualStrings("render/", href);
}

test "relativeHref reduces a same-directory index.html to a dot when prettyUrls is on" {
    const gpa = std.testing.allocator;
    const href = try relativeHref(gpa, "index.html", "index.html", true);
    defer gpa.free(href);
    try std.testing.expectEqualStrings(".", href);
}

test "relativeHref reduces a cross-directory index.html to a bare ../ chain" {
    const gpa = std.testing.allocator;
    const href = try relativeHref(gpa, "render/foo/index.html", "index.html", true);
    defer gpa.free(href);
    try std.testing.expectEqualStrings("../../", href);
}

test "relativeHref never strips index.md, prettyUrls only applies to html" {
    const gpa = std.testing.allocator;
    const href = try relativeHref(gpa, "render/foo.md", "index.md", true);
    defer gpa.free(href);
    try std.testing.expectEqualStrings("../index.md", href);
}

test "relativeHref with prettyUrls leaves non-index targets untouched" {
    const gpa = std.testing.allocator;
    const href = try relativeHref(gpa, "index.html", "render/foo.html", true);
    defer gpa.free(href);
    try std.testing.expectEqualStrings("render/foo.html", href);
}
