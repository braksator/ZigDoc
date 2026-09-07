//! Format-agnostic intermediate representation shared by all renderers.
const std = @import("std");

/// What kind of thing a `Section` documents. Directory headings are not a `Kind` — `--tree`
/// grouping is synthesized from `Section.fileLabel` at render time.
pub const Kind = enum {
    file,
    fn_decl,
    var_decl,
    const_decl,
    struct_decl,
    enum_decl,
    union_decl,
    opaque_decl,
    /// One uniquely-discovered file under `--discover ns`.
    namespace,
    /// A decl-position struct/union with no fields — Zig's namespace convention.
    namespace_decl,
};

/// A struct/union field, extracted for `--extras` content.
pub const Field = struct {
    name: []const u8,
    docComment: []const u8,
    typeText: []const u8,
    /// Byte offset of `typeText`'s first character, relative to the
    /// owning `Section.source`'s start — lets `typeText` reuse
    /// `Section.codelinkTargets` for scope-aware linking instead of
    /// bare-name lookup.
    typeTextStart: u32 = 0,
    /// The field's `= <default>` initializer, source text verbatim;
    /// empty when the field has none.
    defaultValueText: []const u8 = "",
    /// Byte offset of `defaultValueText`'s first character, relative
    /// to the owning `Section.source`'s start — same purpose as
    /// `typeTextStart`.
    defaultValueTextStart: u32 = 0,
    /// True when `docComment` came from a plain `//` fallback, not a real `///` comment.
    docCommentIsFallback: bool = false,
};

/// A function parameter, extracted for `--extras` content.
pub const Param = struct {
    name: []const u8,
    typeText: []const u8,
    /// Byte offset of `typeText`'s first character, relative to the
    /// owning `Section.source`'s start — lets `typeText` reuse
    /// `Section.codelinkTargets` for scope-aware linking instead of
    /// bare-name lookup.
    typeTextStart: u32 = 0,
    /// `///` immediately above the parameter, within a multi-line param list.
    docComment: []const u8 = "",
    /// True when `docComment` came from a plain `//` fallback, not a real `///` comment.
    docCommentIsFallback: bool = false,
};

/// One error set member, extracted for `--extras` content.
pub const ErrorMember = struct {
    name: []const u8,
    docComment: []const u8,
};

/// One resolved identifier reference inside a `Section`'s own `source`.
pub const CodelinkTarget = struct {
    start: u32,
    end: u32,
    /// The resolved decl's full dotted path.
    targetPath: []const u8,
};

/// A cross-file identifier reference whose target file is known but whose target
/// `Section.path` isn't resolvable until the whole tree exists.
pub const PendingCodelinkTarget = struct {
    start: u32,
    end: u32,
    /// Raw string passed to `@import(...)` for this reference's binding.
    importTarget: []const u8,
    /// Dotted path after the import alias; empty if the reference is the alias itself.
    remainingPath: []const u8,
};

/// A single extracted declaration, plus its nested children.
pub const Section = struct {
    name: []const u8,
    path: []const u8,
    signature: []const u8,
    docComment: []const u8,
    /// True when `docComment` came from a plain `//` fallback on a non-`pub` item.
    docCommentIsFallback: bool = false,
    source: []const u8,
    /// Path of the file this decl was extracted from, relative to the documented root.
    sourceFile: []const u8,
    /// 1-based line number the decl starts on.
    sourceLine: u32,
    kind: Kind = .const_decl,
    children: []Section,
    /// True if the source item has nested members, even when `children` wasn't populated.
    hasChildren: bool = false,
    /// Directory-relative path.
    fileLabel: []const u8 = "",
    /// True for a non-`.zig` file's synthetic section (`--filetypes`).
    raw: bool = false,
    /// File size in bytes; only set for `raw` sections.
    sizeBytes: u64 = 0,
    /// True when a `raw` section's content looks binary (a NUL byte in the first 8KB).
    /// Its source is never rendered as a code block.
    isBinary: bool = false,
    /// Whether the decl is marked `pub` in source. Defaults true for synthetic wrappers.
    isPub: bool = true,
    /// `--extras`: this struct/union's own fields, in source order.
    fields: []Field = &.{},
    /// `--extras`: this function's own parameters, in source order.
    params: []Param = &.{},
    /// `--extras`: member names of an error set, when statically known.
    errors: []ErrorMember = &.{},
    /// `--tests`: this file/namespace's own `test` blocks, concatenated in source order.
    testSource: []const u8 = "",
    /// Whether `source`/`docComment`/`testSource` describe a whole file rather than one decl.
    isFileRoot: bool = false,

    /// True for a generic type function (`fn(...) type { ... }`); `kind` still matches
    /// what it returns, but the page label reads "Type Function".
    isTypeFunction: bool = false,

    /// True if a struct/union container has at least one field member.
    hasFields: bool = false,

    /// Set only for a cross-file alias with one canonical page elsewhere; holds that
    /// section's own `path` so links resolve straight to it instead of a separate page.
    aliasTargetPath: ?[]const u8 = null,

    /// `--omitdoc`: this decl gets no page/anchor or content block of its
    /// own anywhere. It still gets a listing entry in its parent's
    /// Functions/Values list — name + doc comment, just with no link.
    docOnly: bool = false,

    /// Byte-range identifier references in `source` resolved to another documented decl.
    codelinkTargets: []const CodelinkTarget = &.{},

    /// Byte-range filename mentions (in a comment or string literal,
    /// anywhere in `source`) resolved to that file's own page. Kept
    /// separate from `codelinkTargets`: unlike those, these are never
    /// valid against `signature` (a different, shorter string sharing no
    /// offset basis with `source`), so signature rendering must not reuse
    /// them the way it does `codelinkTargets`.
    mentionTargets: []const CodelinkTarget = &.{},

    /// Cross-file references found during extraction, not yet resolved against the full tree.
    pendingCodelinkTargets: []const PendingCodelinkTarget = &.{},

    /// HTML id / md fragment anchor for this section.
    pub fn anchorSlug(self: Section, gpa: std.mem.Allocator) ![]u8 {
        return slugify(gpa, self.path);
    }

    /// Anchor slug for Markdown output.
    pub fn anchorSlugMd(self: Section, gpa: std.mem.Allocator) ![]u8 {
        return slugifyMd(gpa, self.path);
    }

    /// Filename stem for this section's page in split layout.
    pub fn fileStem(self: Section, gpa: std.mem.Allocator) ![]u8 {
        return self.anchorSlug(gpa);
    }

    /// Whether this section's `source`/`docComment`/`testSource` describe a whole file.
    pub fn isWholeFileWrapper(self: Section) bool {
        return self.isFileRoot;
    }

    /// Like `slugify` but lowercases, matching Markdown's auto-generated heading anchors.
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
    /// Root file's own path, when there is one.
    sourceFile: []const u8 = "",
    /// Full source text for `--pagesource`; empty for a merged/synthetic root.
    fullSource: []const u8 = "",
    /// `--tests`: this file's own `test` blocks, concatenated in source order.
    testSource: []const u8 = "",
    /// True when the root represents a filesystem directory rather than a single file.
    rootIsDir: bool = false,

    /// Same-file identifier references resolved against `fullSource` rather than
    /// any single decl's own trimmed source — what the whole-file page-source
    /// tab codelinks against. Empty for a merged/synthetic root.
    fileCodelinkTargets: []const CodelinkTarget = &.{},
    /// Cross-file counterpart of `fileCodelinkTargets`, awaiting Phase B.
    filePendingCodelinkTargets: []const PendingCodelinkTarget = &.{},

    /// Frees every allocation owned by this tree.
    pub fn deinit(self: *DocTree, gpa: std.mem.Allocator) void {
        for (self.sections) |*s| freeSection(gpa, s);
        gpa.free(self.sections);
        gpa.free(self.moduleName);
        if (self.rootDocComment) |doc| gpa.free(doc);
        if (self.sourceFile.len > 0) gpa.free(self.sourceFile);
        if (self.fullSource.len > 0) gpa.free(self.fullSource);
        if (self.testSource.len > 0) gpa.free(self.testSource);
        freeCodelinkTargets(gpa, self.fileCodelinkTargets);
        freePendingCodelinkTargets(gpa, self.filePendingCodelinkTargets);
        self.* = undefined;
    }
};

fn freeCodelinkTargets(gpa: std.mem.Allocator, targets: []const CodelinkTarget) void {
    for (targets) |t| gpa.free(t.targetPath);
    if (targets.len > 0) gpa.free(targets);
}

fn freePendingCodelinkTargets(gpa: std.mem.Allocator, targets: []const PendingCodelinkTarget) void {
    for (targets) |t| {
        gpa.free(t.importTarget);
        if (t.remainingPath.len > 0) gpa.free(t.remainingPath);
    }
    if (targets.len > 0) gpa.free(targets);
}

/// Wraps one file's extracted `DocTree` as a synthetic top-level `Section`.
pub fn fileWrapperSection(gpa: std.mem.Allocator, tree: DocTree, kind: Kind, displayName: []const u8, fileLabel: []const u8, locationPath: []const u8) !Section {
    return Section{
        .name = try gpa.dupe(u8, displayName),
        .path = try gpa.dupe(u8, tree.moduleName),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, tree.rootDocComment orelse ""),
        .source = try gpa.dupe(u8, tree.fullSource),
        .sourceFile = try gpa.dupe(u8, locationPath),
        .sourceLine = 0,
        .kind = kind,
        .children = tree.sections,
        .hasChildren = tree.sections.len > 0,
        .fileLabel = try gpa.dupe(u8, fileLabel),
        .testSource = try gpa.dupe(u8, tree.testSource),
        .isFileRoot = true,
        .codelinkTargets = try dupeCodelinkTargets(gpa, tree.fileCodelinkTargets),
        .pendingCodelinkTargets = try dupePendingCodelinkTargets(gpa, tree.filePendingCodelinkTargets),
    };
}

fn dupeCodelinkTargets(gpa: std.mem.Allocator, targets: []const CodelinkTarget) ![]CodelinkTarget {
    const out = try gpa.alloc(CodelinkTarget, targets.len);
    for (targets, 0..) |t, i| out[i] = .{ .start = t.start, .end = t.end, .targetPath = try gpa.dupe(u8, t.targetPath) };
    return out;
}

fn dupePendingCodelinkTargets(gpa: std.mem.Allocator, targets: []const PendingCodelinkTarget) ![]PendingCodelinkTarget {
    const out = try gpa.alloc(PendingCodelinkTarget, targets.len);
    for (targets, 0..) |t, i| out[i] = .{
        .start = t.start,
        .end = t.end,
        .importTarget = try gpa.dupe(u8, t.importTarget),
        .remainingPath = try gpa.dupe(u8, t.remainingPath),
    };
    return out;
}

/// Builds a synthetic per-file `Section` for a non-`.zig` input (`--filetypes`).
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
        .isBinary = looksBinary(content),
        .isFileRoot = true,
    };
}

/// Sniffs the first 8KB for a NUL byte, the same heuristic `file`/git use to
/// tell text from binary content.
fn looksBinary(content: []const u8) bool {
    const sniffLen = @min(content.len, 8192);
    return std.mem.indexOfScalar(u8, content[0..sniffLen], 0) != null;
}

/// Detects `path` collisions among top-level file-kind sections and disambiguates them
/// using their real `fileLabel`. Caller owns the returned slice.
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

/// Frees a slice returned by `disambiguateSectionPaths`.
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

/// Merges several file-level `DocTree`s into one, nesting each under a synthetic
/// module section. Takes ownership of `trees`.
pub fn mergeTrees(
    gpa: std.mem.Allocator,
    moduleName: []const u8,
    trees: []DocTree,
    labels: MergeLabels,
) !DocTree {
    var sections = try gpa.alloc(Section, trees.len);
    errdefer gpa.free(sections);

    for (trees, 0..) |*tree, i| {
        sections[i] = try labels.buildSection(gpa, tree.*, i);
        gpa.free(tree.moduleName);
        if (tree.rootDocComment) |doc| gpa.free(doc);
        if (tree.sourceFile.len > 0) gpa.free(tree.sourceFile);
        if (tree.fullSource.len > 0) gpa.free(tree.fullSource);
        if (tree.testSource.len > 0) gpa.free(tree.testSource);
        freeCodelinkTargets(gpa, tree.fileCodelinkTargets);
        freePendingCodelinkTargets(gpa, tree.filePendingCodelinkTargets);
        tree.* = undefined;
    }

    return DocTree{
        .moduleName = try gpa.dupe(u8, moduleName),
        .rootDocComment = null,
        .sections = sections,
    };
}

/// Merges several `--discover ns` root `DocTree`s into one, nesting each under a
/// synthetic `Kind.namespace` wrapper. Takes ownership of `trees`.
pub fn mergeNamespaceTrees(gpa: std.mem.Allocator, moduleName: []const u8, trees: []DocTree) !DocTree {
    var sections = try gpa.alloc(Section, trees.len);
    errdefer gpa.free(sections);

    for (trees, 0..) |*tree, i| {
        const locationPath = if (tree.sourceFile.len > 0) tree.sourceFile else if (tree.sections.len > 0) tree.sections[0].sourceFile else tree.moduleName;
        sections[i] = try fileWrapperSection(gpa, tree.*, .namespace, tree.moduleName, tree.moduleName, locationPath);
        gpa.free(tree.moduleName);
        if (tree.rootDocComment) |doc| gpa.free(doc);
        if (tree.sourceFile.len > 0) gpa.free(tree.sourceFile);
        if (tree.fullSource.len > 0) gpa.free(tree.fullSource);
        if (tree.testSource.len > 0) gpa.free(tree.testSource);
        freeCodelinkTargets(gpa, tree.fileCodelinkTargets);
        freePendingCodelinkTargets(gpa, tree.filePendingCodelinkTargets);
        tree.* = undefined;
    }

    return DocTree{
        .moduleName = try gpa.dupe(u8, moduleName),
        .rootDocComment = null,
        .sections = sections,
    };
}

/// How `mergeTrees` labels, kinds, and locates each merged tree's synthetic wrapper section.
pub const MergeLabels = struct {
    fileLabels: []const []const u8,
    showExt: bool,
    showDirPrefix: bool,

    fn buildSection(self: MergeLabels, gpa: std.mem.Allocator, tree: DocTree, i: usize) !Section {
        const displayName = try fileDisplayName(gpa, self.fileLabels[i], self.showExt, self.showDirPrefix);
        defer gpa.free(displayName);
        const locationPath = if (tree.sourceFile.len > 0) tree.sourceFile else self.fileLabels[i];
        return fileWrapperSection(gpa, tree, .file, displayName, self.fileLabels[i], locationPath);
    }
};

/// Formats a raw directory-relative label for display, per `showExt`/`showDirPrefix`.
pub fn fileDisplayName(gpa: std.mem.Allocator, rawLabel: []const u8, showExt: bool, showDirPrefix: bool) ![]u8 {
    const based = if (showDirPrefix) rawLabel else labelBasename(rawLabel);
    if (showExt) return gpa.dupe(u8, based);
    return gpa.dupe(u8, stripExt(based));
}

fn labelBasename(label: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, label, '/')) |i| return label[i + 1 ..];
    return label;
}

fn stripExt(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[0..i];
    return name;
}

/// Strips a trailing `.zig` extension, if present.
pub fn stripZigExt(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".zig")) name[0 .. name.len - 4] else name;
}

/// Recursively frees a section and its children.
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
    for (section.fields) |f| {
        gpa.free(f.name);
        gpa.free(f.docComment);
        gpa.free(f.typeText);
        gpa.free(f.defaultValueText);
    }
    if (section.fields.len > 0) gpa.free(section.fields);
    for (section.params) |p| {
        gpa.free(p.name);
        gpa.free(p.typeText);
        gpa.free(p.docComment);
    }
    if (section.params.len > 0) gpa.free(section.params);
    for (section.errors) |e| {
        gpa.free(e.name);
        gpa.free(e.docComment);
    }
    if (section.errors.len > 0) gpa.free(section.errors);
    if (section.testSource.len > 0) gpa.free(section.testSource);
    if (section.aliasTargetPath) |p| gpa.free(p);
    for (section.codelinkTargets) |t| gpa.free(t.targetPath);
    if (section.codelinkTargets.len > 0) gpa.free(section.codelinkTargets);
    for (section.mentionTargets) |t| gpa.free(t.targetPath);
    if (section.mentionTargets.len > 0) gpa.free(section.mentionTargets);
    for (section.pendingCodelinkTargets) |t| {
        gpa.free(t.importTarget);
        if (t.remainingPath.len > 0) gpa.free(t.remainingPath);
    }
    if (section.pendingCodelinkTargets.len > 0) gpa.free(section.pendingCodelinkTargets);
}

/// Like `freeSection` but leaves children untouched (already freed or moved elsewhere).
fn freeSectionShallow(gpa: std.mem.Allocator, section: *Section) void {
    gpa.free(section.name);
    gpa.free(section.path);
    gpa.free(section.signature);
    gpa.free(section.docComment);
    gpa.free(section.source);
    gpa.free(section.sourceFile);
    if (section.fileLabel.len > 0) gpa.free(section.fileLabel);
    if (section.aliasTargetPath) |p| gpa.free(p);
}

/// Mirrors `options.ItemOrder`; kept here to avoid a dependency on the CLI-parsing module.
pub const SectionOrder = enum { code, alpha, grouped };

/// Mirrors `options.DirOrder`.
pub const DirOrder = enum { first, last, alpha };

/// Mirrors `options.OmitKind`.
pub const OmitKind = enum { fn_decl, var_decl, const_decl, struct_decl, enum_decl, union_decl, opaque_decl, file, namespace_decl };

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
            .file => kind == .file,
            .namespace_decl => kind == .namespace_decl,
        };
        if (matches) return true;
    }
    return false;
}

/// Mirrors `options.OmitDocFlag`, minus `none` (an empty `excluded` slice serves that role).
pub const OmitDocFlag = enum { functions, fields, errors, params, values };

/// Marks `docOnly` on every function/value decl whose bucket is in `excluded`.
/// Never deletes: the decl still gets a listing entry (name + doc comment,
/// unlinked) in its parent's Functions/Values list. What disappears is the
/// decl's own page/anchor and content block — nowhere to link it to, so
/// nothing renders there (see `Section.docOnly`).
pub fn markOmitDoc(sections: []Section, excluded: []const OmitDocFlag) void {
    if (excluded.len == 0) return;
    for (sections) |*s| {
        const bucket: ?OmitDocFlag = switch (s.kind) {
            .fn_decl => .functions,
            .var_decl, .const_decl => .values,
            else => null,
        };
        if (bucket) |b| {
            for (excluded) |ex| {
                if (ex == b) {
                    s.docOnly = true;
                    break;
                }
            }
        }
        markOmitDoc(s.children, excluded);
    }
}

/// Recursively drops sections whose `kind` is in `excluded`. A dropped `.file` wrapper
/// splices its children into its place; other kinds take their children with them. In-place.
pub fn filterSections(gpa: std.mem.Allocator, sections: *[]Section, excluded: []const OmitKind) !void {
    var kept: std.ArrayList(Section) = .empty;
    errdefer kept.deinit(gpa);
    for (sections.*) |*s| {
        if (s.kind == .file and kindOmitted(s.kind, excluded)) {
            try filterSections(gpa, &s.children, excluded);
            try stripPathPrefix(gpa, s.path, s.children);
            try kept.appendSlice(gpa, s.children);
            gpa.free(s.children);
            freeSectionShallow(gpa, s);
            continue;
        }
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

/// Strips `removedPath` and its joining '.' from the front of every section's path,
/// recursively — used when a `.file` section is spliced out by `filterSections`.
fn stripPathPrefix(gpa: std.mem.Allocator, removedPath: []const u8, sections: []Section) !void {
    const skip = removedPath.len + 1;
    for (sections) |*s| {
        std.debug.assert(s.path.len > skip and std.mem.startsWith(u8, s.path, removedPath) and s.path[removedPath.len] == '.');
        const trimmed = try gpa.dupe(u8, s.path[skip..]);
        gpa.free(s.path);
        s.path = trimmed;
        try stripPathPrefix(gpa, removedPath, s.children);
    }
}

/// Recursively drops sections whose `isPub` is false, along with their
/// children. In-place.
pub fn filterPrivate(gpa: std.mem.Allocator, sections: *[]Section) !void {
    var kept: std.ArrayList(Section) = .empty;
    errdefer kept.deinit(gpa);
    for (sections.*) |*s| {
        if (!s.isPub) {
            freeSection(gpa, s);
            continue;
        }
        try filterPrivate(gpa, &s.children);
        try kept.append(gpa, s.*);
    }
    gpa.free(sections.*);
    sections.* = try kept.toOwnedSlice(gpa);
}

/// Recursively drops a `.file` section once it has no doc comment and no children left.
/// Never drops `raw` sections (`--filetypes`), which are always childless and doc-less.
pub fn filterEmpty(gpa: std.mem.Allocator, sections: *[]Section) !void {
    var kept: std.ArrayList(Section) = .empty;
    errdefer kept.deinit(gpa);
    for (sections.*) |*s| {
        try filterEmpty(gpa, &s.children);
        if (!s.raw and s.kind == .file and s.docComment.len == 0 and s.children.len == 0) {
            freeSection(gpa, s);
            continue;
        }
        try kept.append(gpa, s.*);
    }
    gpa.free(sections.*);
    sections.* = try kept.toOwnedSlice(gpa);
}

/// Recursively sorts `sections` in place per `order`. `code` is a no-op (already AST order).
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

/// Replaces non-alphanumeric bytes with "-", preserving "." as the path separator and
/// case (HTML anchors are case-sensitive, unlike `slugifyMd`).
pub fn slugify(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = try gpa.alloc(u8, path.len);
    for (path, 0..) |c, i| {
        out[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.' => c,
            else => '-',
        };
    }
    return out;
}

/// Filesystem-safe form of a single decl name for a page filename or directory segment;
/// case is preserved since Zig identifiers are case-sensitive.
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

/// Appends a trailing "~" if `segment` case-insensitively matches a Windows-reserved name.
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

/// Number of directory levels deep a page's output path sits.
pub fn pageDepth(pagePath: []const u8) usize {
    var depth: usize = 0;
    for (pagePath) |c| {
        if (c == '/') depth += 1;
    }
    return depth;
}

/// Builds a relative href from `fromPath` to `toPath`, both output-relative. Drops a
/// trailing `index.html` when `prettyUrls` is set.
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

fn stripIndexHtml(path: []const u8) []const u8 {
    const suffix = "index.html";
    if (!std.mem.endsWith(u8, path, suffix)) return path;
    return path[0 .. path.len - suffix.len];
}

/// Shared segment-tokenizing loop behind `writePathLinks`/`writePathLinksMd`.
fn writePathLinksGeneric(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    path: []const u8,
    rootLen: usize,
    mdSyntax: bool,
    rootHref: ?[]const u8,
) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or (i >= rootLen and path[i] == '.')) {
            const prefix = path[0..i];
            const segment = if (start == 0) stripZigExt(path[start..i]) else path[start..i];
            const href = if (start == 0 and rootHref != null) null else blk: {
                const slug = if (mdSyntax) try Section.slugifyMd(gpa, prefix) else try slugify(gpa, prefix);
                break :blk slug;
            };
            defer if (href) |h| gpa.free(h);
            if (start != 0) try writer.writeAll(".");
            const target = if (start == 0 and rootHref != null) rootHref.? else href.?;
            const sep: []const u8 = if (start == 0 and rootHref != null) "" else "#";
            if (mdSyntax) {
                try writer.print("[{s}]({s}{s})", .{ segment, sep, target });
            } else {
                try writer.print("<a href=\"{s}{s}\">{s}</a>", .{ sep, target, segment });
            }
            start = i + 1;
        }
    }
}

/// Writes `path` as HTML with each dotted segment linked to its ancestor section's anchor.
pub fn writePathLinks(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    path: []const u8,
    rootLen: usize,
    rootHref: ?[]const u8,
) !void {
    return writePathLinksGeneric(gpa, writer, path, rootLen, false, rootHref);
}

/// Writes `path` as Markdown with each dotted segment linked to its ancestor section's anchor.
pub fn writePathLinksMd(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    path: []const u8,
    rootLen: usize,
    rootHref: ?[]const u8,
) !void {
    return writePathLinksGeneric(gpa, writer, path, rootLen, true, rootHref);
}

/// Walks one level of `sections` (already sorted by `fileLabel`), calling `onDir` with a
/// subdirectory's contiguous slice, or `onLeaf` for a single file/decl entry.
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

/// Groups `sections` (sorted by `fileLabel`) into a directory tree for `--tree` index listings.
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

/// Walks one level of `sections`, handing `onDir` the subdirectory's own slice — for
/// callers that need to write that subdirectory's page too, not just link to it.
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

/// Sorts `sections` by `fileLabel` so `writeIndexTree`/`writeDirPages` group correctly.
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

/// Compares two `fileLabel`s segment by segment, sorting directories before or after a
/// file at the point they diverge, per `dirsFirst`.
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

const primitiveTypeNames = std.StaticStringMap(void).initComptime(.{
    .{"type"},     .{"anytype"}, .{"anyerror"}, .{"anyframe"}, .{"anyopaque"},
    .{"bool"},     .{"void"},    .{"noreturn"}, .{"comptime_int"}, .{"comptime_float"},
    .{"f16"},      .{"f32"},     .{"f64"},      .{"f80"},      .{"f128"},
    .{"c_char"},   .{"c_short"}, .{"c_ushort"}, .{"c_int"},    .{"c_uint"},
    .{"c_long"},   .{"c_ulong"}, .{"c_longlong"}, .{"c_ulonglong"}, .{"c_longdouble"},
});

/// Whether `text` names a Zig primitive type (`bool`, `f32`, sized-int
/// forms like `u8`/`i32`, etc). Primitives are never real decls, so a
/// reference to one must never become a codelink.
pub fn isPrimitiveTypeName(text: []const u8) bool {
    if (primitiveTypeNames.has(text)) return true;
    if (text.len < 2) return false;
    const rest = text[1..];
    return switch (text[0]) {
        'i', 'u' => for (rest) |c| {
            if (!std.ascii.isDigit(c)) break false;
        } else true,
        else => false,
    };
}
