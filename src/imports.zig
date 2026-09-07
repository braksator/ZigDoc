//! Discovers a `--discover ns` doc tree by following `@import(...)`
//! targets from a root file, then builds `model.Section`s from the
//! resulting `walk.Graph` — resolving `.alias` decls (re-exports) to
//! their real target's content, the way Zig's own Autodoc does.
const std = @import("std");
const Ast = std.zig.Ast;
const extract = @import("extract.zig");
const model = @import("model.zig");
const walk = @import("walk.zig");
const progress_mod = @import("main.zig").progress_mod;
const codelinks = extract.codelinks;

/// Errors surfaced while walking an import graph.
pub const WalkError = error{ ParseFailed, ImportNotFound } || std.mem.Allocator.Error;

/// Reads a file's full contents into a null-terminated buffer, so
/// `walkTree` can be tested against in-memory sources.
pub const Reader = struct {
    context: *const anyopaque,
    readFn: *const fn (context: *const anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![:0]u8,

    fn read(self: Reader, gpa: std.mem.Allocator, path: []const u8) ![:0]u8 {
        return self.readFn(self.context, gpa, path);
    }
};

/// Computes `decl`'s fully-qualified dotted path by walking its `.parent`
/// chain in its own home file — call on the resolved target, not an alias
/// (see `walk.Decl.resolveAliasIndex`). `rootFile`/`rootModuleName` display
/// the entry file's root under its module name rather than a path fragment;
/// pass `rootModuleName = null` for multi-root discovery, where every file's
/// fqn is just its own on-disk name.
fn fqn(gpa: std.mem.Allocator, graph: *walk.Graph, declIndex: walk.Decl.Index, rootFile: walk.File.Index, rootModuleName: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendFqnPath(&out, gpa, graph, declIndex, rootFile, rootModuleName);
    const decl = declIndex.get(graph);
    if (decl.parent != .none) {
        try appendParentNs(&out, gpa, graph, decl.parent, rootFile, rootModuleName);
        try out.appendSlice(gpa, decl.extraInfo(graph).name);
    } else {
        out.items.len -= 1; // remove the trailing '.'
    }
    return out.toOwnedSlice(gpa);
}

/// Appends `declIndex`'s own file's dotted prefix (its display name,
/// followed by `.`) — the base every ancestor namespace name and the
/// decl's own name get appended onto. Mirrors `Decl.append_path`.
fn appendFqnPath(out: *std.ArrayList(u8), gpa: std.mem.Allocator, graph: *walk.Graph, declIndex: walk.Decl.Index, rootFile: walk.File.Index, rootModuleName: ?[]const u8) !void {
    const file = declIndex.get(graph).file;
    if (rootModuleName) |name| if (file == rootFile) {
        try out.appendSlice(gpa, name);
        try out.append(gpa, '.');
        return;
    };
    const filePath = try file.displayPath(gpa, graph);
    defer gpa.free(filePath);
    if (rootModuleName) |name| {
        try out.appendSlice(gpa, name);
        try out.append(gpa, '.');
    }
    const start = out.items.len;
    try out.appendSlice(gpa, filePath);
    for (out.items[start..]) |*byte| if (byte.* == '/') {
        byte.* = '.';
    };
    if (std.mem.endsWith(u8, out.items, ".zig")) {
        out.items.len -= 3;
    } else {
        try out.append(gpa, '.');
    }
}

/// Appends every ancestor namespace's own name, each followed by `.`,
/// from the outermost down to (but not including) `parent` itself.
/// Mirrors `Decl.append_parent_ns`.
fn appendParentNs(out: *std.ArrayList(u8), gpa: std.mem.Allocator, graph: *walk.Graph, parent: walk.Decl.Index, rootFile: walk.File.Index, rootModuleName: ?[]const u8) !void {
    const decl = parent.get(graph);
    if (decl.parent != .none) {
        try appendParentNs(out, gpa, graph, decl.parent, rootFile, rootModuleName);
        try out.appendSlice(gpa, decl.extraInfo(graph).name);
        try out.append(gpa, '.');
    }
}

/// Caches each file's own codelink scope frames, keyed by `walk.File.Index`,
/// so a file visited through many decls only has its scope built once.
const ScopeCache = struct {
    byFile: std.AutoHashMap(walk.File.Index, std.ArrayList(codelinks.ScopeFrame)),

    fn init(gpa: std.mem.Allocator) ScopeCache {
        return .{ .byFile = .init(gpa) };
    }

    fn deinit(self: *ScopeCache, gpa: std.mem.Allocator) void {
        var it = self.byFile.valueIterator();
        while (it.next()) |frames| codelinks.freeScopeFrames(gpa, frames);
        self.byFile.deinit();
    }

    /// Returns `fileIndex`'s scope frames, building and caching them
    /// on first request.
    fn get(self: *ScopeCache, gpa: std.mem.Allocator, graph: *walk.Graph, rootFile: walk.File.Index, rootModuleName: ?[]const u8, fileIndex: walk.File.Index) ![]const codelinks.ScopeFrame {
        if (self.byFile.getPtr(fileIndex)) |frames| return frames.items;

        var frames: std.ArrayList(codelinks.ScopeFrame) = .empty;
        errdefer codelinks.freeScopeFrames(gpa, &frames);
        const ast = &fileIndex.get(graph).ast;
        const rootDecl = fileIndex.findRootDecl(graph);
        const rootPath = if (rootDecl != .none) try fqn(gpa, graph, rootDecl, rootFile, rootModuleName) else try gpa.dupe(u8, "");
        defer gpa.free(rootPath);
        try codelinks.buildFileScopes(gpa, ast.*, ast.rootDecls(), rootPath, 0, @intCast(ast.source.len), &frames);

        try self.byFile.put(fileIndex, frames);
        return self.byFile.getPtr(fileIndex).?.items;
    }
};

/// Walks the whole import graph and builds a `model.DocTree` rooted
/// at `rootPath`, nested rather than a flat sibling list. `progress`,
/// if given, is updated during discovery and again before tree-building.
pub fn walkDisk(
    gpa: std.mem.Allocator,
    io: std.Io,
    rootPath: []const u8,
    recursive: bool,
    extras: bool,
    collectTests: bool,
    progress: ?*progress_mod.Progress,
) WalkError!model.DocTree {
    const diskReader = DiskReader{ .io = io };
    return walkTree(gpa, diskReader.reader(), rootPath, recursive, extras, collectTests, progress);
}

const DiskReader = struct {
    io: std.Io,

    fn reader(self: *const DiskReader) Reader {
        return .{ .context = self, .readFn = readImpl };
    }

    fn readImpl(context: *const anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![:0]u8 {
        const self: *const DiskReader = @ptrCast(@alignCast(context));
        return std.Io.Dir.cwd().readFileAllocOptions(self.io, path, gpa, .unlimited, .of(u8), 0);
    }
};

/// Discovers every file reachable from `rootPath` via `@import`
/// (already-visited targets, including cycles, aren't re-visited),
/// parses+walks each into a shared `walk.Graph`, then builds a
/// `model.DocTree` from the root file, recursively resolving `.alias`.
pub fn walkTree(
    gpa: std.mem.Allocator,
    reader: Reader,
    rootPath: []const u8,
    recursive: bool,
    extras: bool,
    collectTests: bool,
    progress: ?*progress_mod.Progress,
) WalkError!model.DocTree {
    var graph = walk.Graph.init(gpa);
    defer graph.deinit();

    var visited: std.StringHashMap(void) = .init(gpa);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        visited.deinit();
    }
    var discoveredCount: usize = 0;

    const rootResolved = normalizeSeparators(try std.fs.path.resolvePosix(gpa, &.{rootPath}));
    defer gpa.free(rootResolved);

    const rootFileIndex = try discoverFile(gpa, reader, &graph, &visited, rootResolved, progress, &discoveredCount);

    if (progress) |p| p.update("building doc tree ({d} files)", .{discoveredCount});

    return buildTree(gpa, &graph, rootFileIndex, recursive, extras, collectTests, progress);
}

/// Parses+walks `resolvedPath` into `graph` (already known unvisited),
/// then recurses into every `@import` it references.
fn discoverFile(
    gpa: std.mem.Allocator,
    reader: Reader,
    graph: *walk.Graph,
    visited: *std.StringHashMap(void),
    resolvedPath: []const u8,
    progress: ?*progress_mod.Progress,
    discoveredCount: *usize,
) WalkError!walk.File.Index {
    const visitedKey = try gpa.dupe(u8, resolvedPath);
    try visited.put(visitedKey, {});

    discoveredCount.* += 1;
    if (progress) |p| p.update("documenting {s} (import graph, {d} files)", .{ resolvedPath, discoveredCount.* });

    const source = reader.read(gpa, resolvedPath) catch return WalkError.ImportNotFound;
    defer gpa.free(source);

    const fileIndex = graph.addFile(resolvedPath, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => return WalkError.ParseFailed,
    };

    const refs = try extract.parseImportTargets(gpa, source);
    defer extract.freeImportTargets(gpa, refs);

    for (refs) |ref| {
        if (!isRelativeImport(ref.target)) continue;

        const targetResolved = try resolveImport(gpa, resolvedPath, ref.target);
        defer gpa.free(targetResolved);

        if (visited.contains(targetResolved)) continue;

        // A `.zig`-suffixed target can still be a build.zig module name
        // (`addImport("foo.zig", dep)`) rather than a real relative file;
        // such targets aren't reachable on disk, so skip instead of erroring.
        _ = discoverFile(gpa, reader, graph, visited, targetResolved, progress, discoveredCount) catch |err| switch (err) {
            WalkError.ImportNotFound => continue,
            else => return err,
        };
    }

    return fileIndex;
}

/// Rewrites `\` to `/` in-place and returns `path`. Every path used as a
/// `Graph` lookup key must go through this once, or the same file reached
/// two different ways can produce two byte-different keys.
fn normalizeSeparators(path: []u8) []u8 {
    for (path) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return path;
}

/// Resolves an `@import` string against the importing file's own directory.
/// Works equally on doc-root-relative display paths (as used by
/// `render.resolvePendingCodelinks`) and on real disk paths (as used by
/// `discoverFile`) — it's pure lexical path algebra, not filesystem access.
pub fn resolveImport(gpa: std.mem.Allocator, importingFile: []const u8, importTarget: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(importingFile) orelse ".";
    const resolved = try std.fs.path.resolvePosix(gpa, &.{ dir, importTarget });
    return normalizeSeparators(resolved);
}

/// Whether `target` is a relative `.zig` file path rather than a package name.
pub fn isRelativeImport(target: []const u8) bool {
    return std.mem.endsWith(u8, target, ".zig");
}

/// A whole file's front-matter: module doc comment, full source text,
/// and (if `collectTests`) its top-level `test` blocks.
const WholeFile = struct {
    docComment: ?[]const u8,
    source: []const u8,
    testSource: []const u8,
    codelinkTargets: []const model.CodelinkTarget,
    pendingCodelinkTargets: []const model.PendingCodelinkTarget,

    fn deinit(self: *WholeFile, gpa: std.mem.Allocator) void {
        if (self.docComment) |d| gpa.free(d);
        gpa.free(self.source);
        gpa.free(self.testSource);
        for (self.codelinkTargets) |t| gpa.free(t.targetPath);
        if (self.codelinkTargets.len > 0) gpa.free(self.codelinkTargets);
        for (self.pendingCodelinkTargets) |t| {
            gpa.free(t.importTarget);
            if (t.remainingPath.len > 0) gpa.free(t.remainingPath);
        }
        if (self.pendingCodelinkTargets.len > 0) gpa.free(self.pendingCodelinkTargets);
    }
};

/// Extracts `ast`'s whole-file front-matter, including codelinks resolved
/// against `frames` over the entire file — what a whole-file wrapper
/// `Section`'s own `source` needs, as opposed to `buildSection`'s
/// per-decl resolution. `ast.source` is duped so the result outlives
/// `ast`'s owning `walk.Graph`.
fn wholeFile(gpa: std.mem.Allocator, ast: Ast, collectTests: bool, frames: []const codelinks.ScopeFrame) !WholeFile {
    const docComment = try extract.extractModuleDocComment(gpa, ast);
    errdefer if (docComment) |d| gpa.free(d);

    const source = try gpa.dupe(u8, ast.source);
    errdefer gpa.free(source);

    const testSource = if (collectTests)
        try extract.collectTestSource(gpa, ast, ast.rootDecls())
    else
        try gpa.dupe(u8, "");
    errdefer gpa.free(testSource);

    const codelinkResult = try codelinks.resolveCodelinksForFile(gpa, ast, frames);
    errdefer {
        for (codelinkResult.resolved) |r| gpa.free(r.targetPath);
        gpa.free(codelinkResult.resolved);
        for (codelinkResult.pending) |p| p.deinit(gpa);
        gpa.free(codelinkResult.pending);
    }
    const pendingTargets = try gpa.alloc(model.PendingCodelinkTarget, codelinkResult.pending.len);
    for (codelinkResult.pending, 0..) |p, i| {
        pendingTargets[i] = .{
            .start = p.start,
            .end = p.end,
            .importTarget = p.importTarget,
            .remainingPath = p.remainingPath,
        };
    }
    gpa.free(codelinkResult.pending);

    return .{
        .docComment = docComment,
        .source = source,
        .testSource = testSource,
        .codelinkTargets = codelinkResult.resolved,
        .pendingCodelinkTargets = pendingTargets,
    };
}

/// Tracks which namespaces (files reached via a cross-file re-export)
/// have already had their real content built, so every later reference
/// gets a lightweight link instead of rebuilding the subtree.
const Worklist = struct {
    seen: std.AutoHashMap(walk.Decl.Index, void),

    fn init(gpa: std.mem.Allocator) Worklist {
        return .{ .seen = .init(gpa) };
    }

    fn deinit(self: *Worklist) void {
        self.seen.deinit();
    }
};

fn buildTree(
    gpa: std.mem.Allocator,
    graph: *walk.Graph,
    rootFile: walk.File.Index,
    recursive: bool,
    extras: bool,
    collectTests: bool,
    progress: ?*progress_mod.Progress,
) WalkError!model.DocTree {
    const rootDeclIndex = rootFile.findRootDecl(graph);
    const rootAst = &rootFile.get(graph).ast;
    const rootModuleName = try gpa.dupe(u8, model.stripZigExt(std.fs.path.basename(rootFile.path(graph))));
    errdefer gpa.free(rootModuleName);

    var scopeCache = ScopeCache.init(gpa);
    defer scopeCache.deinit(gpa);
    const rootFrames = try scopeCache.get(gpa, graph, rootFile, rootModuleName, rootFile);

    var front = try wholeFile(gpa, rootAst.*, collectTests, rootFrames);
    errdefer front.deinit(gpa);

    var worklist = Worklist.init(gpa);
    defer worklist.deinit();
    try worklist.seen.put(rootDeclIndex, {});

    var sections: std.ArrayList(model.Section) = .empty;
    errdefer {
        for (sections.items) |*s| model.freeSection(gpa, s);
        sections.deinit(gpa);
    }

    const kids = try rootDeclIndex.get(graph).children(graph, gpa);
    defer gpa.free(kids);
    var visiting: std.AutoHashMap(walk.Decl.Index, void) = .init(gpa);
    defer visiting.deinit();
    try visiting.put(rootDeclIndex, {});
    var builtCount: usize = 0;
    for (kids) |childIndex| {
        if (try buildSection(gpa, graph, childIndex, rootModuleName, recursive, extras, collectTests, &worklist, &visiting, rootFile, rootModuleName, &scopeCache)) |section| {
            try sections.append(gpa, section);
            builtCount += 1;
            if (progress) |p| p.update("building doc tree ({d}/{d} branches)", .{ builtCount, kids.len });
        }
    }

    try buildUnreachedFiles(gpa, graph, rootFile, rootModuleName, recursive, extras, collectTests, &worklist, &sections, &scopeCache, progress);

    return model.DocTree{
        .moduleName = rootModuleName,
        .rootDocComment = front.docComment,
        .sections = try sections.toOwnedSlice(gpa),
        .sourceFile = try rootFile.displayPath(gpa, graph),
        .fullSource = front.source,
        .testSource = front.testSource,
        .fileCodelinkTargets = front.codelinkTargets,
        .filePendingCodelinkTargets = front.pendingCodelinkTargets,
    };
}

/// Builds real content for any discovered file whose root decl the normal
/// alias-following walk never reached (e.g. only referenced through a
/// private, nested re-export), and grafts it into `sections` at its `fqn`
/// path so it isn't silently dropped from output.
fn buildUnreachedFiles(
    gpa: std.mem.Allocator,
    graph: *walk.Graph,
    rootFile: walk.File.Index,
    rootModuleName: ?[]const u8,
    recursive: bool,
    extras: bool,
    collectTests: bool,
    worklist: *Worklist,
    sections: *std.ArrayList(model.Section),
    scopeCache: *ScopeCache,
    progress: ?*progress_mod.Progress,
) WalkError!void {
    var fileIndex: u32 = 0;
    while (fileIndex < graph.files.items.len) : (fileIndex += 1) {
        if (progress) |p| p.update("building doc tree ({d}/{d} files scanned)", .{ fileIndex + 1, graph.files.items.len });
        const file: walk.File.Index = @enumFromInt(fileIndex);
        if (file == rootFile) continue;
        const declIndex = file.findRootDecl(graph);
        if (declIndex == .none) continue;
        if (worklist.seen.contains(declIndex)) continue;

        const path = try fqn(gpa, graph, declIndex, rootFile, rootModuleName);
        defer gpa.free(path);

        const name = model.stripZigExt(std.fs.path.basename(file.path(graph)));
        const isPub = declIndex.get(graph).extraInfo(graph).isPub;
        const contentAst = &file.get(graph).ast;

        try worklist.seen.put(declIndex, {});
        const section = try buildFileRootSection(gpa, graph, declIndex, contentAst.*, declIndex.get(graph), name, isPub, path, recursive, extras, collectTests, worklist, rootFile, rootModuleName, scopeCache);

        try graftSection(gpa, sections, path, rootModuleName != null, section);
    }
}

/// Attaches `section` (dotted path `fqnPath`) as a child of the existing
/// section matching `fqnPath`'s parent segment. `hasModulePrefix` skips
/// the outermost segment when it's the root module name `sections` already
/// represents.
fn graftSection(gpa: std.mem.Allocator, sections: *std.ArrayList(model.Section), fqnPath: []const u8, hasModulePrefix: bool, section: model.Section) WalkError!void {
    var it = std.mem.splitScalar(u8, fqnPath, '.');
    if (hasModulePrefix) _ = it.next(); // the root module name itself; `sections` already is that level

    var path: std.ArrayList(*model.Section) = .empty;
    defer path.deinit(gpa);

    var siblings: []model.Section = sections.items;
    while (it.next()) |segment| {
        if (it.peek() == null) break; // the leaf itself; attach `section` as a child here
        var found: ?*model.Section = null;
        for (siblings) |*s| {
            if (std.mem.eql(u8, s.name, segment)) {
                found = s;
                break;
            }
        }
        const parent = found orelse {
            // Every fqn segment above a leaf is a real file's section,
            // built by the alias-following walk or this pass. Don't leak
            // `section` if that assumption is ever violated.
            var owned = section;
            model.freeSection(gpa, &owned);
            return;
        };
        try path.append(gpa, parent);
        siblings = parent.children;
    }

    if (path.items.len == 0) {
        try sections.append(gpa, section);
        return;
    }
    const leafParent = path.items[path.items.len - 1];
    if (leafParent.children.len == 0) {
        const one = try gpa.alloc(model.Section, 1);
        one[0] = section;
        leafParent.children = one;
    } else {
        const grown = try gpa.realloc(leafParent.children, leafParent.children.len + 1);
        grown[grown.len - 1] = section;
        leafParent.children = grown;
    }
    leafParent.hasChildren = true;
}

/// Builds the `Section` for a whole file's own root — module doc comment,
/// full source, top-level members recursed into as children. Called both
/// from `buildSection`'s canonical-reach branch and directly from
/// `buildUnreachedFiles`.
fn buildFileRootSection(
    gpa: std.mem.Allocator,
    graph: *walk.Graph,
    rootDeclIndex: walk.Decl.Index,
    contentAst: Ast,
    contentDecl: *walk.Decl,
    name: []const u8,
    isPub: bool,
    path: []const u8,
    recursive: bool,
    extras: bool,
    collectTests: bool,
    worklist: *Worklist,
    rootFile: walk.File.Index,
    rootModuleName: ?[]const u8,
    scopeCache: *ScopeCache,
) WalkError!model.Section {
    const frames = try scopeCache.get(gpa, graph, rootFile, rootModuleName, contentDecl.file);
    var front = try wholeFile(gpa, contentAst, collectTests, frames);
    errdefer front.deinit(gpa);
    const sourceFile = try contentDecl.file.displayPath(gpa, graph);
    errdefer gpa.free(sourceFile);

    var children: std.ArrayList(model.Section) = .empty;
    errdefer {
        for (children.items) |*c| model.freeSection(gpa, c);
        children.deinit(gpa);
    }
    var childVisiting: std.AutoHashMap(walk.Decl.Index, void) = .init(gpa);
    defer childVisiting.deinit();
    try childVisiting.put(rootDeclIndex, {});
    const kids = try contentDecl.children(graph, gpa);
    defer gpa.free(kids);
    if (recursive) {
        for (kids) |childIndex| {
            if (try buildSection(gpa, graph, childIndex, path, recursive, extras, collectTests, worklist, &childVisiting, rootFile, rootModuleName, scopeCache)) |childSection| {
                try children.append(gpa, childSection);
            }
        }
    }

    // A file-root struct needs the same field collection non-root
    // decls get below, but reads members from `rootDecls()` directly.
    var fields: []model.Field = &.{};
    if (extras) {
        fields = try extract.collectFields(gpa, contentAst, contentAst.rootDecls(), 0);
    }
    const hasFields = extract.hasFieldMember(contentAst, contentAst.rootDecls());

    return model.Section{
        .name = try gpa.dupe(u8, name),
        .path = try gpa.dupe(u8, path),
        .signature = try gpa.dupe(u8, ""),
        .docComment = front.docComment orelse try gpa.dupe(u8, ""),
        .source = front.source,
        .sourceFile = sourceFile,
        .sourceLine = 1,
        .kind = if (hasFields) .struct_decl else .namespace_decl,
        .children = try children.toOwnedSlice(gpa),
        .hasChildren = kids.len > 0,
        .hasFields = hasFields,
        .isPub = isPub,
        .testSource = front.testSource,
        .isFileRoot = true,
        .fields = fields,
        .codelinkTargets = front.codelinkTargets,
        .pendingCodelinkTargets = front.pendingCodelinkTargets,
    };
}

/// Builds one `Section` for `declIndex`, resolving `.alias` first so it
/// shows the resolved target's content under the alias's own name and
/// tree position. Returns `null` for a decl with no name.
fn buildSection(
    gpa: std.mem.Allocator,
    graph: *walk.Graph,
    declIndex: walk.Decl.Index,
    parentPath: []const u8,
    recursive: bool,
    extras: bool,
    collectTests: bool,
    worklist: *Worklist,
    visiting: *std.AutoHashMap(walk.Decl.Index, void),
    rootFile: walk.File.Index,
    rootModuleName: ?[]const u8,
    scopeCache: *ScopeCache,
) WalkError!?model.Section {
    const ownDecl = declIndex.get(graph);
    const ownInfo = ownDecl.extraInfo(graph);
    if (ownInfo.name.len == 0) return null;

    const resolved = try walk.Decl.resolveAliasIndex(declIndex, graph);
    const resolvedIndex = resolved[0];
    const category = resolved[1];

    const contentDecl = resolvedIndex.get(graph);
    const contentCategory = category;
    const contentFile = contentDecl.file.get(graph);
    const contentAst = &contentFile.ast;
    const contentNode = contentDecl.astNode;
    // For a type function, `contentNode` is the `fn_decl` itself, but
    // members live in whatever container its body returns.
    const membersNode = switch (contentCategory) {
        .typeFunction => |returnedNode| returnedNode,
        else => contentNode,
    };

    const path = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ parentPath, ownInfo.name });
    errdefer gpa.free(path);

    // Crossing into another file's root: only the reach whose path matches
    // the target's real, structural home builds real content; every other
    // reach is an alias.
    if (contentNode == .root) {
        const realPath = try fqn(gpa, graph, resolvedIndex, rootFile, rootModuleName);
        defer gpa.free(realPath);
        const isCanonicalReach = std.mem.eql(u8, realPath, path);
        if (!isCanonicalReach or worklist.seen.contains(resolvedIndex)) {
            return model.Section{
                .name = try gpa.dupe(u8, ownInfo.name),
                .path = path,
                .signature = try gpa.dupe(u8, ""),
                .docComment = try gpa.dupe(u8, ""),
                .source = try gpa.dupe(u8, ""),
                .sourceFile = try contentDecl.file.displayPath(gpa, graph),
                .sourceLine = 1,
                .kind = .namespace_decl,
                .children = &.{},
                .hasChildren = false,
                .hasFields = false,
                .isPub = ownInfo.isPub,
                .aliasTargetPath = try gpa.dupe(u8, realPath),
            };
        }
        try worklist.seen.put(resolvedIndex, {});
        const result = try buildFileRootSection(gpa, graph, resolvedIndex, contentAst.*, contentDecl, ownInfo.name, ownInfo.isPub, path, recursive, extras, collectTests, worklist, rootFile, rootModuleName, scopeCache);
        gpa.free(path);
        return result;
    }

    const kind: model.Kind = switch (contentCategory) {
        .function => .fn_decl,
        .namespace, .container => extract.declKind(contentAst.*, contentNode),
        // Reflects what the function's body actually returns.
        .typeFunction => extract.containerKind(contentAst.*, membersNode) orelse .struct_decl,
        .globalVariable => .var_decl,
        .globalConst, .errorSet, .primitive, .type, .typeType => .const_decl,
        // Not reachable: the `.root` case is handled above.
        .alias => .const_decl,
    };

    // An alias to an ordinary decl in another file has exactly one real
    // page: wherever that file reaches the decl directly. Scoped to a
    // top-level decl — a deeper nested decl falls through to the
    // ordinary build below.
    const isCrossFileAlias = declIndex != resolvedIndex and
        contentDecl.file != ownDecl.file and
        contentDecl.parent == contentDecl.file.findRootDecl(graph);
    if (isCrossFileAlias) {
        const targetPath = try fqn(gpa, graph, resolvedIndex, rootFile, rootModuleName);
        return model.Section{
            .name = try gpa.dupe(u8, ownInfo.name),
            .path = path,
            .signature = try gpa.dupe(u8, ""),
            .docComment = try gpa.dupe(u8, ""),
            .source = try gpa.dupe(u8, ""),
            .sourceFile = try contentDecl.file.displayPath(gpa, graph),
            .sourceLine = 1,
            .kind = kind,
            .children = &.{},
            .hasChildren = false,
            .hasFields = false,
            .isPub = ownInfo.isPub,
            .isTypeFunction = contentCategory == .typeFunction,
            .aliasTargetPath = targetPath,
        };
    }

    const nameToken = declNameTokenFor(contentAst.*, contentNode) orelse contentAst.nodeMainToken(contentNode);
    const doc = try extract.extractDocComment(gpa, contentAst.*, nameToken, ownInfo.isPub);
    errdefer if (doc) |d| gpa.free(d.text);
    const signature = try extract.extractSignature(gpa, contentAst.*, contentNode);
    errdefer gpa.free(signature);

    const declFirst = contentAst.firstToken(contentNode);
    const declLast = contentAst.lastToken(contentNode);
    const declStartByte: u32 = @intCast(extract.lineStart(contentAst.source, contentAst.tokenStart(declFirst)));
    const declEndByte: u32 = @intCast(contentAst.tokenStart(declLast) + contentAst.tokenSlice(declLast).len);
    const source = try gpa.dupe(u8, contentAst.source[declStartByte..declEndByte]);
    errdefer gpa.free(source);
    const line = extract.declLine(contentAst.*, nameToken);
    const sourceFile = try contentDecl.file.displayPath(gpa, graph);
    errdefer gpa.free(sourceFile);

    // This decl's own file's scope frames, built once and cached
    // across every decl `buildSection` reaches in that file.
    const scopeFrames = try scopeCache.get(gpa, graph, rootFile, rootModuleName, contentDecl.file);
    const codelinkResult = try codelinks.resolveCodelinksForDecl(gpa, contentAst.*, declStartByte, declEndByte, scopeFrames);
    // `.resolved` moves into `Section.codelinkTargets` below — not freed here.
    errdefer {
        for (codelinkResult.resolved) |r| gpa.free(r.targetPath);
        gpa.free(codelinkResult.resolved);
    }
    // Each `.pending` entry's strings move into `pendingTargets` unchanged;
    // resolving them (same mechanism regardless of discovery mode) is
    // `render.resolvePendingCodelinks`'s job, not this walk's.
    defer gpa.free(codelinkResult.pending);
    const pendingTargets = try gpa.alloc(model.PendingCodelinkTarget, codelinkResult.pending.len);
    for (codelinkResult.pending, 0..) |p, i| {
        pendingTargets[i] = .{
            .start = p.start,
            .end = p.end,
            .importTarget = p.importTarget,
            .remainingPath = p.remainingPath,
        };
    }

    var buf: [2]Ast.Node.Index = undefined;
    var containerNodes: ?[]const Ast.Node.Index = null;
    var ownedContainerNodes: ?[]const Ast.Node.Index = null;
    defer if (ownedContainerNodes) |n| gpa.free(n);
    var allowNamespaceDowngrade = true;
    if (kind == .struct_decl or kind == .union_decl) {
        if (contentCategory == .typeFunction) {
            // `membersNode` is already the bare container node here,
            // not a `const X = struct{}` wrapper.
            allowNamespaceDowngrade = false;
            if (contentAst.fullContainerDecl(&buf, membersNode)) |container| {
                containerNodes = container.ast.members;
            }
        } else if (try extract.containerMembers(gpa, contentAst.*, contentNode)) |nested| {
            ownedContainerNodes = nested;
            containerNodes = nested;
        }
    }
    const fpe = try extract.collectFieldsParamsErrors(gpa, contentAst.*, kind, contentNode, containerNodes, declStartByte, extras, allowNamespaceDowngrade);

    var children: std.ArrayList(model.Section) = .empty;
    errdefer {
        for (children.items) |*c| model.freeSection(gpa, c);
        children.deinit(gpa);
    }
    var hasChildren = false;

    if (contentCategory == .namespace or contentCategory == .container or contentCategory == .typeFunction) {
        const kids = try contentDecl.children(graph, gpa);
        defer gpa.free(kids);
        hasChildren = kids.len > 0;
        if (recursive) {
            // Same-file cycle guard (e.g. `const Self = @This();`
            // nested inside the struct it names).
            const alreadyVisiting = visiting.contains(resolvedIndex);
            if (!alreadyVisiting) {
                try visiting.put(resolvedIndex, {});
                defer _ = visiting.remove(resolvedIndex);
                for (kids) |childIndex| {
                    if (try buildSection(gpa, graph, childIndex, path, recursive, extras, collectTests, worklist, visiting, rootFile, rootModuleName, scopeCache)) |childSection| {
                        try children.append(gpa, childSection);
                    }
                }
            }
        }
    }

    return model.Section{
        .name = try gpa.dupe(u8, ownInfo.name),
        .path = path,
        .signature = signature,
        .docComment = if (doc) |d| d.text else try gpa.dupe(u8, ""),
        .docCommentIsFallback = if (doc) |d| d.isFallback else false,
        .source = source,
        .sourceFile = sourceFile,
        .sourceLine = line,
        .kind = fpe.sectionKind,
        .children = try children.toOwnedSlice(gpa),
        .hasChildren = hasChildren,
        .hasFields = fpe.hasFields,
        .isPub = ownInfo.isPub,
        .fields = fpe.fields,
        .params = fpe.params,
        .errors = fpe.errors,
        .isTypeFunction = contentCategory == .typeFunction,
        .codelinkTargets = codelinkResult.resolved,
        .pendingCodelinkTargets = pendingTargets,
    };
}

/// Like `extract.zig`'s private `declNameToken`, for a node already
/// known to be a decl. `null` only for the `.root` node itself.
fn declNameTokenFor(tree: Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    var buf: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&buf, node)) |proto| return proto.name_token;
    if (tree.fullVarDecl(node)) |decl| return decl.ast.mut_token + 1;
    return null;
}


fn findSection(sections: []const model.Section, name: []const u8) ?model.Section {
    for (sections) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}
