//! Builds a `model.DocTree` from a Zig source file via `std.zig.Ast`, including
//! same-file codelink resolution (`codelinks`) while the `Ast` is alive.
const std = @import("std");
const Ast = std.zig.Ast;
const model = @import("model.zig");

pub const codelinks = struct {
    /// A reference that resolved to an import binding, awaiting Phase B.
    pub const PendingCodelink = struct {
        start: u32,
        end: u32,
        /// Raw `@import(...)` string, e.g. `"std"`.
        importTarget: []const u8,
        /// Dotted path after the import alias, e.g. `"Deque.bufferIndex"`. Empty if none.
        remainingPath: []const u8,

        pub fn deinit(self: PendingCodelink, gpa: std.mem.Allocator) void {
            gpa.free(self.importTarget);
            if (self.remainingPath.len > 0) gpa.free(self.remainingPath);
        }
    };

    pub const ResolvedCodelinks = struct {
        /// Same-file references, fully resolved.
        resolved: []model.CodelinkTarget,
        /// Cross-file references awaiting Phase B.
        pending: []PendingCodelink,

        pub fn deinit(self: ResolvedCodelinks, gpa: std.mem.Allocator) void {
            for (self.resolved) |r| gpa.free(r.targetPath);
            gpa.free(self.resolved);
            for (self.pending) |p| p.deinit(gpa);
            gpa.free(self.pending);
        }
    };

    /// A binding in scope: a same-file member or an import alias.
    pub const Binding = union(enum) {
        sameFile: []const u8, // dotted path within this file
        import: []const u8, // raw @import(...) string argument
    };

    /// A binding plus the byte range of its own declaration name token,
    /// so the resolver can recognize a declaration site vs. a use.
    pub const BoundName = struct {
        binding: Binding,
        /// Absolute byte range of the declaration name token, if any.
        declStart: ?u32,
        declEnd: ?u32,
    };

    /// A byte range over which `bindings` are in effect. Searched innermost-first.
    pub const ScopeFrame = struct {
        start: u32,
        end: u32,
        bindings: std.StringHashMap(BoundName),
    };

    /// Builds the scope frame stack for a container's `Ast` region: a root
    /// frame of `members`' bindings and imports scoped to `[rangeStart, rangeEnd)`,
    /// plus one child frame per nested container or function. `parentPath` is
    /// the dotted path prefix for `members`.
    ///
    /// The range matters: without it, two sibling containers declaring the
    /// same-named local (common with `const BitSet = ...;` across generic
    /// containers) would have both bindings compete for every use of that
    /// name in the whole file.
    pub fn buildFileScopes(
        gpa: std.mem.Allocator,
        tree: Ast,
        members: []const Ast.Node.Index,
        parentPath: []const u8,
        rangeStart: u32,
        rangeEnd: u32,
        frames: *std.ArrayList(ScopeFrame),
    ) std.mem.Allocator.Error!void {
        var rootBindings = std.StringHashMap(BoundName).init(gpa);
        errdefer rootBindings.deinit();

        const imports = try importTargets(gpa, tree, members);
        defer freeImportTargets(gpa, imports);

        try collectMemberBindings(gpa, tree, members, parentPath, imports, &rootBindings);

        for (imports) |ref| {
            const nameToken = findMemberNameToken(tree, members, ref.name) orelse continue;
            if (rootBindings.contains(ref.name)) continue;
            const dupedName = try gpa.dupe(u8, ref.name);
            errdefer gpa.free(dupedName);
            try rootBindings.put(dupedName, .{
                .binding = .{ .import = try gpa.dupe(u8, ref.target) },
                .declStart = @intCast(tree.tokenStart(nameToken)),
                .declEnd = @intCast(tree.tokenStart(nameToken) + tree.tokenSlice(nameToken).len),
            });
        }

        try frames.append(gpa, .{
            .start = rangeStart,
            .end = rangeEnd,
            .bindings = rootBindings,
        });

        try buildNestedScopes(gpa, tree, members, parentPath, frames);
    }

    /// Recurses into `members`, pushing one frame per nested container or function.
    fn buildNestedScopes(
        gpa: std.mem.Allocator,
        tree: Ast,
        members: []const Ast.Node.Index,
        parentPath: []const u8,
        frames: *std.ArrayList(ScopeFrame),
    ) std.mem.Allocator.Error!void {
        for (members) |member| {
            const nameToken = declNameToken(tree, member) orelse continue;
            const name = tree.tokenSlice(nameToken);
            const path = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ parentPath, name });
            defer gpa.free(path);

            var buf: [1]Ast.Node.Index = undefined;
            if (tree.fullFnProto(&buf, member)) |proto| {
                var paramBindings = std.StringHashMap(BoundName).init(gpa);
                errdefer paramBindings.deinit();

                var it = proto.iterate(&tree);
                while (it.next()) |param| {
                    const paramNameToken = param.name_token orelse continue;
                    const paramName = tree.tokenSlice(paramNameToken);
                    if (paramName.len == 0) continue;
                    if (paramBindings.contains(paramName)) continue;
                    const dupedName = try gpa.dupe(u8, paramName);
                    errdefer gpa.free(dupedName);
                    // Empty targetPath: a parameter can shadow but never itself be a link target.
                    try paramBindings.put(dupedName, .{
                        .binding = .{ .sameFile = "" },
                        .declStart = @intCast(tree.tokenStart(paramNameToken)),
                        .declEnd = @intCast(tree.tokenStart(paramNameToken) + tree.tokenSlice(paramNameToken).len),
                    });
                }

                // Top-level locals share the function's frame with its parameters.
                if (tree.nodeTag(member) == .fn_decl) {
                    const body = tree.nodeData(member).node_and_node[1];
                    try collectLocalBindings(gpa, tree, body, &paramBindings);
                }

                const memberStart: u32 = @intCast(tree.tokenStart(tree.firstToken(member)));
                const memberEnd: u32 = @intCast(tree.tokenStart(tree.lastToken(member)) + tree.tokenSlice(tree.lastToken(member)).len);
                try frames.append(gpa, .{
                    .start = memberStart,
                    .end = memberEnd,
                    .bindings = paramBindings,
                });

                // A generic type function's returned struct is, for scoping
                // purposes, just another container — a local declared inside
                // it needs to be a resolvable binding the same as an ordinary
                // container's. Scoped to this function's own span, since
                // sibling type functions may each declare the same-named local.
                if (tree.nodeTag(member) == .fn_decl) {
                    const body = tree.nodeData(member).node_and_node[1];
                    if (try returnedContainerMembers(gpa, tree, body)) |nested| {
                        defer gpa.free(nested);
                        try buildFileScopes(gpa, tree, nested, path, memberStart, memberEnd, frames);
                    }
                }
                continue;
            }

            if (try containerMembers(gpa, tree, member)) |nested| {
                defer gpa.free(nested);
                const memberStart: u32 = @intCast(tree.tokenStart(tree.firstToken(member)));
                const memberEnd: u32 = @intCast(tree.tokenStart(tree.lastToken(member)) + tree.tokenSlice(tree.lastToken(member)).len);
                try buildFileScopes(gpa, tree, nested, path, memberStart, memberEnd, frames);
            }
        }
    }

    /// If `body`'s top-level statements include a `return
    /// <container-literal>;`, returns that container's own members —
    /// see the call site in `buildNestedScopes` for why.
    fn returnedContainerMembers(gpa: std.mem.Allocator, tree: Ast, body: Ast.Node.Index) !?[]const Ast.Node.Index {
        var stmtBuf: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&stmtBuf, body) orelse return null;
        for (statements) |stmt| {
            if (tree.nodeTag(stmt) != .@"return") continue;
            const valueNode = tree.nodeData(stmt).opt_node.unwrap() orelse continue;
            var containerBuf: [2]Ast.Node.Index = undefined;
            const container = tree.fullContainerDecl(&containerBuf, valueNode) orelse continue;
            return try gpa.dupe(Ast.Node.Index, container.ast.members);
        }
        return null;
    }

    /// Collects a function body's direct top-level `const`/`var` statements
    /// into `bindings`, alongside its parameters. Nested blocks aren't scoped
    /// separately — a local is visible for the whole function.
    fn collectLocalBindings(
        gpa: std.mem.Allocator,
        tree: Ast,
        body: Ast.Node.Index,
        bindings: *std.StringHashMap(BoundName),
    ) !void {
        var buf: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buf, body) orelse return;

        const imports = try importTargets(gpa, tree, statements);
        defer {
            for (imports) |ref| {
                gpa.free(ref.name);
                gpa.free(ref.target);
            }
            gpa.free(imports);
        }

        for (statements) |stmt| {
            const decl = tree.fullVarDecl(stmt) orelse continue;
            const nameToken = decl.ast.mut_token + 1;
            const name = tree.tokenSlice(nameToken);
            if (name.len == 0 or bindings.contains(name)) continue;

            if (isImportName(imports, name)) {
                // Dupe rather than transfer ownership — imports is freed as a batch below.
                for (imports) |ref| {
                    if (!std.mem.eql(u8, ref.name, name)) continue;
                    const dupedName = try gpa.dupe(u8, name);
                    errdefer gpa.free(dupedName);
                    const dupedTarget = try gpa.dupe(u8, ref.target);
                    errdefer gpa.free(dupedTarget);
                    try bindings.put(dupedName, .{
                        .binding = .{ .import = dupedTarget },
                        .declStart = @intCast(tree.tokenStart(nameToken)),
                        .declEnd = @intCast(tree.tokenStart(nameToken) + tree.tokenSlice(nameToken).len),
                    });
                    break;
                }
                continue;
            }

            // Not an import — a local can only shadow, same as a parameter.
            const dupedName = try gpa.dupe(u8, name);
            errdefer gpa.free(dupedName);
            try bindings.put(dupedName, .{
                .binding = .{ .sameFile = "" },
                .declStart = @intCast(tree.tokenStart(nameToken)),
                .declEnd = @intCast(tree.tokenStart(nameToken) + tree.tokenSlice(nameToken).len),
            });
        }
    }

    /// Collects `members`' own named decls into `bindings` as `sameFile`
    /// entries, skipping any that `imports` identifies as `@import(...)` decls
    /// (those are registered separately as `.import` bindings).
    fn collectMemberBindings(
        gpa: std.mem.Allocator,
        tree: Ast,
        members: []const Ast.Node.Index,
        parentPath: []const u8,
        imports: []const ImportRef,
        bindings: *std.StringHashMap(BoundName),
    ) !void {
        for (members) |member| {
            const nameToken = declNameToken(tree, member) orelse continue;
            const name = tree.tokenSlice(nameToken);
            if (bindings.contains(name)) continue;
            if (isImportName(imports, name)) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ parentPath, name });
            try bindings.put(try gpa.dupe(u8, name), .{
                .binding = .{ .sameFile = path },
                .declStart = @intCast(tree.tokenStart(nameToken)),
                .declEnd = @intCast(tree.tokenStart(nameToken) + tree.tokenSlice(nameToken).len),
            });
        }
    }

    fn isImportName(imports: []const ImportRef, name: []const u8) bool {
        for (imports) |ref| {
            if (std.mem.eql(u8, ref.name, name)) return true;
        }
        return false;
    }

    /// Finds the name token of the member in `members` named `name`.
    fn findMemberNameToken(tree: Ast, members: []const Ast.Node.Index, name: []const u8) ?Ast.TokenIndex {
        for (members) |member| {
            const nameToken = declNameToken(tree, member) orelse continue;
            if (std.mem.eql(u8, tree.tokenSlice(nameToken), name)) return nameToken;
        }
        return null;
    }

    /// Frees every frame's bindings, including owned strings.
    pub fn freeScopeFrames(gpa: std.mem.Allocator, frames: *std.ArrayList(ScopeFrame)) void {
        for (frames.items) |*frame| {
            var it = frame.bindings.iterator();
            while (it.next()) |entry| {
                gpa.free(entry.key_ptr.*);
                switch (entry.value_ptr.binding) {
                    .sameFile => |p| if (p.len > 0) gpa.free(p),
                    .import => |t| gpa.free(t),
                }
            }
            frame.bindings.deinit();
        }
        frames.deinit(gpa);
    }

    /// Like `resolveCodelinksForDecl`, scoped to the entire file (byte range
    /// `[0, tree.source.len)`) rather than one decl — for a whole-file
    /// wrapper `Section` whose own `source` is the full file, not a decl's
    /// trimmed slice. Returned offsets are absolute (relative to byte 0).
    pub fn resolveCodelinksForFile(gpa: std.mem.Allocator, tree: Ast, frames: []const ScopeFrame) !ResolvedCodelinks {
        return resolveCodelinksForDecl(gpa, tree, 0, @intCast(tree.source.len), frames);
    }

    /// Resolves every identifier use within `declNode`'s source span against
    /// `frames`. Returned offsets are relative to `declStartByte`.
    pub fn resolveCodelinksForDecl(
        gpa: std.mem.Allocator,
        tree: Ast,
        declStartByte: u32,
        declEndByte: u32,
        frames: []const ScopeFrame,
    ) !ResolvedCodelinks {
        var resolved: std.ArrayList(model.CodelinkTarget) = .empty;
        errdefer {
            for (resolved.items) |r| gpa.free(r.targetPath);
            resolved.deinit(gpa);
        }
        var pending: std.ArrayList(PendingCodelink) = .empty;
        errdefer {
            for (pending.items) |p| p.deinit(gpa);
            pending.deinit(gpa);
        }

        const declSlice = tree.source[declStartByte..declEndByte];
        const declSource = try gpa.allocSentinel(u8, declSlice.len, 0);
        defer gpa.free(declSource);
        @memcpy(declSource, declSlice);
        var tokenizer = std.zig.Tokenizer.init(declSource);

        // Tracks the immediately preceding token's tag, so an identifier
        // preceded by `.` can be told apart from a fresh top-level one —
        // see the `precededByDot` check below.
        var prevTag: std.zig.Token.Tag = .eof;

        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            const precededByDot = prevTag == .period;
            prevTag = token.tag;

            // Any `@import(...)` call within this decl's source, nested or
            // top-level, is never a reference to a previously-bound
            // identifier. The filename string links to the file itself; each
            // further `.segment` links independently to that segment's decl.
            if (token.tag == .builtin and std.mem.eql(u8, declSource[token.loc.start..token.loc.end], "@import")) {
                var probe = tokenizer;
                if (probe.next().tag == .l_paren) {
                    const strTok = probe.next();
                    if (strTok.tag == .string_literal and probe.next().tag == .r_paren) {
                        const raw = declSource[strTok.loc.start..strTok.loc.end];
                        const importTarget = try parseStringLiteral(gpa, raw);
                        if (importTarget) |target| {
                            errdefer gpa.free(target);
                            tokenizer = probe; // consume "(...)"
                            // Exclude the surrounding quote characters —
                            // only the filename itself should be linked.
                            const absStrStart = declStartByte + @as(u32, @intCast(strTok.loc.start)) + 1;
                            const absStrEnd = declStartByte + @as(u32, @intCast(strTok.loc.end)) - 1;
                            try pending.append(gpa, .{
                                .start = absStrStart - declStartByte,
                                .end = absStrEnd - declStartByte,
                                .importTarget = try gpa.dupe(u8, target),
                                .remainingPath = try gpa.dupe(u8, ""),
                            });
                            const segments = try peekDottedSuffix(gpa, &tokenizer, declSource);
                            // The chain's last consumed token is always an
                            // identifier — keep `prevTag` truthful for
                            // whatever comes right after it.
                            prevTag = .identifier;
                            defer gpa.free(segments);
                            for (segments) |seg| {
                                errdefer gpa.free(seg.cumulativePath);
                                try pending.append(gpa, .{
                                    .start = seg.start,
                                    .end = seg.end,
                                    .importTarget = try gpa.dupe(u8, target),
                                    .remainingPath = seg.cumulativePath,
                                });
                            }
                            gpa.free(target);
                            continue;
                        }
                    }
                }
            }

            if (token.tag != .identifier) continue;
            // A fresh top-level identifier immediately preceded by `.` is
            // never a reference to look up: it's a standalone enum literal,
            // or the continuation of a receiver this loop already declined
            // to link. A real `X.segment` chain never reaches this point for
            // `segment` — resolving `X` already consumes it below.
            if (precededByDot) continue;

            const absStart = declStartByte + @as(u32, @intCast(token.loc.start));
            const absEnd = declStartByte + @as(u32, @intCast(token.loc.end));
            const text = declSource[token.loc.start..token.loc.end];

            // Skip a binding's own name token — it's a declaration, not a use.
            if (isOwnDeclarationToken(absStart, absEnd, frames)) continue;

            const binding = lookupInnermost(frames, absStart, text) orelse continue;
            // `void`, `u8`, `anytype`, etc. lex as plain identifiers but
            // are never real decls — even if some binding elsewhere in
            // this file happens to share the name, a primitive-type use
            // should never itself become a link.
            if (model.isPrimitiveTypeName(text)) continue;

            switch (binding) {
                .sameFile => |path| {
                    // Empty path: a parameter shadows but is never a link target.
                    if (path.len == 0) continue;
                    try resolved.append(gpa, .{
                        .start = absStart - declStartByte,
                        .end = absEnd - declStartByte,
                        .targetPath = try gpa.dupe(u8, path),
                    });
                    // Each further `.segment` links independently to that
                    // segment's own decl, alongside the base reference above.
                    const segments = try peekDottedSuffix(gpa, &tokenizer, declSource);
                    // The chain's last consumed token is always an
                    // identifier — keep `prevTag` truthful for whatever
                    // comes right after it.
                    prevTag = .identifier;
                    defer gpa.free(segments);
                    for (segments) |seg| {
                        defer gpa.free(seg.cumulativePath);
                        const targetPath = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ path, seg.cumulativePath });
                        errdefer gpa.free(targetPath);
                        try resolved.append(gpa, .{
                            .start = seg.start,
                            .end = seg.end,
                            .targetPath = targetPath,
                        });
                    }
                },
                .import => |importTarget| {
                    // `mem` itself is already a resolvable reference to the
                    // imported file; each further `.segment` (recovered here
                    // since the tokenizer sees them separately) links
                    // independently to that segment's own decl.
                    try pending.append(gpa, .{
                        .start = absStart - declStartByte,
                        .end = absEnd - declStartByte,
                        .importTarget = try gpa.dupe(u8, importTarget),
                        .remainingPath = try gpa.dupe(u8, ""),
                    });
                    const segments = try peekDottedSuffix(gpa, &tokenizer, declSource);
                    // The chain's last consumed token is always an
                    // identifier — keep `prevTag` truthful for whatever
                    // comes right after it.
                    prevTag = .identifier;
                    defer gpa.free(segments);
                    for (segments) |seg| {
                        errdefer gpa.free(seg.cumulativePath);
                        try pending.append(gpa, .{
                            .start = seg.start,
                            .end = seg.end,
                            .importTarget = try gpa.dupe(u8, importTarget),
                            .remainingPath = seg.cumulativePath,
                        });
                    }
                },
            }
        }

        return .{
            .resolved = try resolved.toOwnedSlice(gpa),
            .pending = try pending.toOwnedSlice(gpa),
        };
    }

    const DottedSegment = struct { cumulativePath: []const u8, start: u32, end: u32 };

    /// Peeks forward for a `.name` chain (`.Deque.bufferIndex`) following an
    /// already-consumed identifier or `@import(...)` call, advancing
    /// `tokenizer` past it. Returns one entry per segment, in order, each
    /// with its own byte span and the cumulative dotted path up to and
    /// including it (`"Deque"`, then `"Deque.bufferIndex"`) — so each
    /// segment can become its own independently resolvable codelink.
    fn peekDottedSuffix(gpa: std.mem.Allocator, tokenizer: *std.zig.Tokenizer, declSource: [:0]const u8) ![]DottedSegment {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        var starts: std.ArrayList(u32) = .empty;
        defer starts.deinit(gpa);
        var ends: std.ArrayList(u32) = .empty;
        defer ends.deinit(gpa);

        var cursor = tokenizer.*;
        while (true) {
            const dot = cursor.next();
            if (dot.tag != .period) break;
            const name = cursor.next();
            if (name.tag != .identifier) break;
            try names.append(gpa, declSource[name.loc.start..name.loc.end]);
            try starts.append(gpa, @intCast(name.loc.start));
            try ends.append(gpa, @intCast(name.loc.end));
            tokenizer.* = cursor;
        }

        var segments: std.ArrayList(DottedSegment) = .empty;
        errdefer {
            for (segments.items) |s| gpa.free(s.cumulativePath);
            segments.deinit(gpa);
        }
        var cumulative: std.ArrayList([]const u8) = .empty;
        defer cumulative.deinit(gpa);
        for (names.items, 0..) |name, i| {
            try cumulative.append(gpa, name);
            try segments.append(gpa, .{
                .cumulativePath = try std.mem.join(gpa, ".", cumulative.items),
                .start = starts.items[i],
                .end = ends.items[i],
            });
        }
        return segments.toOwnedSlice(gpa);
    }

    /// Finds the innermost frame containing `atByte` with a binding for `name`.
    fn lookupInnermost(frames: []const ScopeFrame, atByte: u32, name: []const u8) ?Binding {
        var i = frames.len;
        while (i > 0) {
            i -= 1;
            const frame = frames[i];
            if (atByte < frame.start or atByte >= frame.end) continue;
            if (frame.bindings.get(name)) |bound| return bound.binding;
        }
        return null;
    }

    /// True when `[start, end)` is exactly some binding's own declaration token.
    fn isOwnDeclarationToken(start: u32, end: u32, frames: []const ScopeFrame) bool {
        for (frames) |frame| {
            var it = frame.bindings.valueIterator();
            while (it.next()) |bound| {
                const declStart = bound.declStart orelse continue;
                const declEnd = bound.declEnd orelse continue;
                if (declStart == start and declEnd == end) return true;
            }
        }
        return false;
    }
};

/// Errors surfaced while extracting a `DocTree` from source.
pub const ExtractError = error{ParseFailed} || std.mem.Allocator.Error;

/// Result of `extractDocComment`/`extractFieldDocComment`: the joined
/// comment text, and whether it came from `extractPlainCommentFallback`
/// rather than a real `///` doc comment.
pub const DocCommentResult = struct {
    text: []const u8,
    isFallback: bool = false,
};

/// Parses `source` and returns the `@import` targets referenced by its
/// top-level decls, without building a `DocTree`. Used by import-graph
/// discovery to find edges before deciding whether a file is worth
/// extracting at all.
pub fn parseImportTargets(gpa: std.mem.Allocator, source: [:0]const u8) ExtractError![]ImportRef {
    var tree = Ast.parse(gpa, source, .{ .mode = .zig }) catch return ExtractError.ParseFailed;
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return ExtractError.ParseFailed;

    return importTargets(gpa, tree, tree.rootDecls());
}

/// Frees a slice returned by `importTargets`/`parseImportTargets`.
pub fn freeImportTargets(gpa: std.mem.Allocator, refs: []ImportRef) void {
    for (refs) |ref| {
        gpa.free(ref.name);
        gpa.free(ref.target);
    }
    gpa.free(refs);
}

/// Parses `source` and extracts a `DocTree` for `moduleName`.
/// `sourcePath` is recorded on each `Section` verbatim, shown to the
/// reader as-is — pass a document-root-relative path, not a raw CLI path.
pub fn extractFile(
    gpa: std.mem.Allocator,
    moduleName: []const u8,
    sourcePath: []const u8,
    source: [:0]const u8,
    recursive: bool,
    extras: bool,
    collectTests: bool,
) ExtractError!model.DocTree {
    var tree = Ast.parse(gpa, source, .{ .mode = .zig }) catch return ExtractError.ParseFailed;
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return ExtractError.ParseFailed;

    const rootDoc = try extractModuleDocComment(gpa, tree);

    var sections: std.ArrayList(model.Section) = .empty;
    errdefer sections.deinit(gpa);

    const rootMembers = tree.rootDecls();

    var frames: std.ArrayList(codelinks.ScopeFrame) = .empty;
    defer codelinks.freeScopeFrames(gpa, &frames);
    try codelinks.buildFileScopes(gpa, tree, rootMembers, moduleName, 0, @intCast(tree.source.len), &frames);

    try collectMembers(gpa, tree, rootMembers, moduleName, sourcePath, recursive, extras, frames.items, &sections);

    const testSource = if (collectTests) try collectTestSource(gpa, tree, rootMembers) else try gpa.dupe(u8, "");

    const fileCodelinks = try codelinks.resolveCodelinksForFile(gpa, tree, frames.items);
    errdefer {
        for (fileCodelinks.resolved) |r| gpa.free(r.targetPath);
        gpa.free(fileCodelinks.resolved);
        for (fileCodelinks.pending) |p| p.deinit(gpa);
        gpa.free(fileCodelinks.pending);
    }
    const filePendingTargets = try gpa.alloc(model.PendingCodelinkTarget, fileCodelinks.pending.len);
    for (fileCodelinks.pending, 0..) |p, i| {
        filePendingTargets[i] = .{
            .start = p.start,
            .end = p.end,
            .importTarget = p.importTarget,
            .remainingPath = p.remainingPath,
        };
    }
    gpa.free(fileCodelinks.pending);

    return model.DocTree{
        .moduleName = try gpa.dupe(u8, moduleName),
        .rootDocComment = rootDoc,
        .sections = try sections.toOwnedSlice(gpa),
        .sourceFile = try gpa.dupe(u8, sourcePath),
        .fullSource = try gpa.dupe(u8, source),
        .testSource = testSource,
        .fileCodelinkTargets = fileCodelinks.resolved,
        .filePendingCodelinkTargets = filePendingTargets,
    };
}

/// Collects every top-level `test { ... }` block's verbatim source,
/// concatenated in source order with a blank line between blocks.
pub fn collectTestSource(gpa: std.mem.Allocator, tree: Ast, members: []const Ast.Node.Index) ![]const u8 {
    var blocks: std.ArrayList([]const u8) = .empty;
    defer blocks.deinit(gpa);

    for (members) |member| {
        if (tree.nodeTag(member) != .test_decl) continue;
        try blocks.append(gpa, sliceForNode(tree, member));
    }

    if (blocks.items.len == 0) return gpa.dupe(u8, "");
    return std.mem.join(gpa, "\n\n", blocks.items);
}

/// Collects leading `//!` lines at the top of the file, if present.
pub fn extractModuleDocComment(gpa: std.mem.Allocator, tree: Ast) !?[]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);

    var tok: Ast.TokenIndex = 0;
    while (tok < tree.tokens.len and tree.tokenTag(tok) == .container_doc_comment) : (tok += 1) {
        try lines.append(gpa, stripDocPrefix(tree.tokenSlice(tok), "//!"));
    }
    if (lines.items.len == 0) return null;
    return try std.mem.join(gpa, "\n", lines.items);
}

/// The parts of a `Section` that come from a struct/union/fn decl's own
/// members: fields, params, error-set members, and whether a fields-less
/// struct downgrades to `.namespace_decl` (never for a union). Shared by
/// `collectMembers` and `imports.buildSection`.
pub const FieldsParamsErrors = struct {
    fields: []model.Field = &.{},
    params: []model.Param = &.{},
    errors: []model.ErrorMember = &.{},
    hasFields: bool = false,
    sectionKind: model.Kind,
};

/// `fnNode` is the decl's own content node — used for `.fn_decl` params
/// and errors, and for the standalone-error-set check; ignored otherwise.
/// `containerNodes`, when given, is `fnNode`'s struct/union member nodes.
/// `allowNamespaceDowngrade` is false for a type function's returned
/// container, which keeps its own declared kind rather than downgrading.
pub fn collectFieldsParamsErrors(
    gpa: std.mem.Allocator,
    tree: Ast,
    kind: model.Kind,
    fnNode: Ast.Node.Index,
    containerNodes: ?[]const Ast.Node.Index,
    declStartByte: u32,
    extras: bool,
    allowNamespaceDowngrade: bool,
) !FieldsParamsErrors {
    var result: FieldsParamsErrors = .{ .sectionKind = kind };
    if (kind == .struct_decl or kind == .union_decl) {
        if (containerNodes) |nested| {
            result.hasFields = hasFieldMember(tree, nested);
            if (!result.hasFields and kind == .struct_decl and allowNamespaceDowngrade) {
                result.sectionKind = .namespace_decl;
            }
            if (extras) result.fields = try collectFields(gpa, tree, nested, declStartByte);
        }
    }
    if (extras) {
        if (kind == .fn_decl) {
            result.params = try collectParams(gpa, tree, fnNode, declStartByte);
            result.errors = try collectFnErrors(gpa, tree, fnNode);
        } else if (isErrorSetDecl(tree, fnNode)) {
            result.errors = try collectStandaloneErrorSet(gpa, tree, fnNode);
        }
    }
    return result;
}

/// Walks `members`, appending a `Section` per named declaration.
/// `extras`: whether to also collect fields/params/error-set members.
fn collectMembers(
    gpa: std.mem.Allocator,
    tree: Ast,
    members: []const Ast.Node.Index,
    parentPath: []const u8,
    sourcePath: []const u8,
    recursive: bool,
    extras: bool,
    frames: []const codelinks.ScopeFrame,
    out: *std.ArrayList(model.Section),
) ExtractError!void {
    for (members) |member| {
        const nameToken = declNameToken(tree, member) orelse continue;
        const name = tree.tokenSlice(nameToken);

        const isPub = isPubDecl(tree, member);
        const doc = try extractDocComment(gpa, tree, nameToken, isPub);
        const signature = try extractSignature(gpa, tree, member);

        const declFirst = tree.firstToken(member);
        const declLast = tree.lastToken(member);
        const declStartByte: u32 = @intCast(lineStart(tree.source, tree.tokenStart(declFirst)));
        const declEndByte: u32 = @intCast(tree.tokenStart(declLast) + tree.tokenSlice(declLast).len);
        const sourceSlice = try gpa.dupe(u8, tree.source[declStartByte..declEndByte]);

        const path = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ parentPath, name });
        const line = declLine(tree, nameToken);
        const kind = declKind(tree, member);

        var children: std.ArrayList(model.Section) = .empty;
        errdefer children.deinit(gpa);
        var hasChildren = false;
        var containerNodes: ?[]const Ast.Node.Index = null;
        defer if (containerNodes) |n| gpa.free(n);

        if (try containerMembers(gpa, tree, member)) |nested| {
            hasChildren = anyNamedMember(tree, nested);
            if (recursive) {
                try collectMembers(gpa, tree, nested, path, sourcePath, recursive, extras, frames, &children);
            }
            containerNodes = nested;
        }

        const fpe = try collectFieldsParamsErrors(gpa, tree, kind, member, containerNodes, declStartByte, extras, true);

        const codelinkResult = try codelinks.resolveCodelinksForDecl(gpa, tree, declStartByte, declEndByte, frames);
        // `.resolved` moves into `Section.codelinkTargets` below — not freed here.
        errdefer {
            for (codelinkResult.resolved) |r| gpa.free(r.targetPath);
            gpa.free(codelinkResult.resolved);
        }
        // Each `.pending` entry's strings move into `pendingTargets` unchanged.
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

        try out.append(gpa, model.Section{
            .name = try gpa.dupe(u8, name),
            .path = path,
            .signature = signature,
            .docComment = if (doc) |d| d.text else try gpa.dupe(u8, ""),
            .docCommentIsFallback = if (doc) |d| d.isFallback else false,
            .source = sourceSlice,
            .sourceFile = try gpa.dupe(u8, sourcePath),
            .sourceLine = line,
            .kind = fpe.sectionKind,
            .children = try children.toOwnedSlice(gpa),
            .hasChildren = hasChildren,
            .hasFields = fpe.hasFields,
            .isPub = isPub,
            .fields = fpe.fields,
            .params = fpe.params,
            .errors = fpe.errors,
            .codelinkTargets = codelinkResult.resolved,
            .pendingCodelinkTargets = pendingTargets,
        });
    }
}

/// Collects a container's field nodes into `Field`s, in source order.
pub fn collectFields(gpa: std.mem.Allocator, tree: Ast, members: []const Ast.Node.Index, declStartByte: u32) ![]model.Field {
    var out: std.ArrayList(model.Field) = .empty;
    errdefer {
        for (out.items) |f| {
            gpa.free(f.name);
            gpa.free(f.docComment);
            gpa.free(f.typeText);
            gpa.free(f.defaultValueText);
        }
        out.deinit(gpa);
    }

    for (members) |member| {
        const field = tree.fullContainerField(member) orelse continue;
        const nameToken = field.ast.main_token;
        const name = tree.tokenSlice(nameToken);
        const doc = try extractFieldDocComment(gpa, tree, nameToken);
        const typeText = if (field.ast.type_expr.unwrap()) |typeNode|
            try gpa.dupe(u8, sliceForExpr(tree, typeNode))
        else
            try gpa.dupe(u8, "");
        const typeTextStart: u32 = if (field.ast.type_expr.unwrap()) |typeNode|
            @intCast(tree.tokenStart(tree.firstToken(typeNode)) - declStartByte)
        else
            0;
        const defaultValueText = if (field.ast.value_expr.unwrap()) |valueNode|
            try gpa.dupe(u8, sliceForExpr(tree, valueNode))
        else
            try gpa.dupe(u8, "");
        const defaultValueTextStart: u32 = if (field.ast.value_expr.unwrap()) |valueNode|
            @intCast(tree.tokenStart(tree.firstToken(valueNode)) - declStartByte)
        else
            0;

        try out.append(gpa, model.Field{
            .name = try gpa.dupe(u8, name),
            .docComment = if (doc) |d| d.text else try gpa.dupe(u8, ""),
            .docCommentIsFallback = if (doc) |d| d.isFallback else false,
            .typeText = typeText,
            .typeTextStart = typeTextStart,
            .defaultValueText = defaultValueText,
            .defaultValueTextStart = defaultValueTextStart,
        });
    }

    return out.toOwnedSlice(gpa);
}

/// Like `extractDocComment`, but for a field's name token, which has
/// no leading `pub`/`fn`/`const` keywords to walk back over.
fn extractFieldDocComment(gpa: std.mem.Allocator, tree: Ast, nameToken: Ast.TokenIndex) !?DocCommentResult {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);

    var tok = nameToken;
    while (tok > 0) {
        const prev = tok - 1;
        if (tree.tokenTag(prev) != .doc_comment) break;
        tok = prev;
    }

    while (tok < nameToken and tree.tokenTag(tok) == .doc_comment) : (tok += 1) {
        try lines.append(gpa, stripDocPrefix(tree.tokenSlice(tok), "///"));
    }

    if (lines.items.len == 0) {
        const fallback = try extractPlainCommentFallback(gpa, tree, nameToken) orelse return null;
        return DocCommentResult{ .text = fallback, .isFallback = true };
    }
    return DocCommentResult{ .text = try std.mem.join(gpa, "\n", lines.items) };
}

/// Collects a `fn_decl`/`fn_proto*` node's parameters into `Param`s.
pub fn collectParams(gpa: std.mem.Allocator, tree: Ast, node: Ast.Node.Index, declStartByte: u32) ![]model.Param {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buf, node) orelse return &.{};

    var out: std.ArrayList(model.Param) = .empty;
    errdefer {
        for (out.items) |p| {
            gpa.free(p.name);
            gpa.free(p.typeText);
            gpa.free(p.docComment);
        }
        out.deinit(gpa);
    }

    var it = proto.iterate(&tree);
    while (it.next()) |param| {
        const name = if (param.name_token) |t| tree.tokenSlice(t) else "";
        const doc = if (param.name_token) |t| try extractFieldDocComment(gpa, tree, t) else null;
        const typeText = if (param.type_expr) |typeNode|
            try gpa.dupe(u8, sliceForExpr(tree, typeNode))
        else
            try gpa.dupe(u8, "");
        const typeTextStart: u32 = if (param.type_expr) |typeNode|
            @intCast(tree.tokenStart(tree.firstToken(typeNode)) - declStartByte)
        else
            0;

        try out.append(gpa, model.Param{
            .name = try gpa.dupe(u8, name),
            .docComment = if (doc) |d| d.text else try gpa.dupe(u8, ""),
            .docCommentIsFallback = if (doc) |d| d.isFallback else false,
            .typeText = typeText,
            .typeTextStart = typeTextStart,
        });
    }

    return out.toOwnedSlice(gpa);
}

/// Whether a top-level member is a standalone named error-set decl
/// (`pub const MyErrors = error{...};`).
pub fn isErrorSetDecl(tree: Ast, node: Ast.Node.Index) bool {
    const decl = tree.fullVarDecl(node) orelse return false;
    const valueNode = decl.ast.init_node.unwrap() orelse return false;
    return tree.nodeTag(valueNode) == .error_set_decl;
}

/// Collects a standalone error-set decl's own members (`error{ A, B }`)
/// into `ErrorMember`s.
pub fn collectStandaloneErrorSet(gpa: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) ![]model.ErrorMember {
    const decl = tree.fullVarDecl(node) orelse return &.{};
    const valueNode = decl.ast.init_node.unwrap() orelse return &.{};
    return collectErrorSetMembers(gpa, tree, valueNode);
}

/// Resolves a function's declared error-union return type
/// (`MyError!void`) to its error-set decl and collects its members.
/// Returns empty for an inferred error union (bare `!T`) or a
/// plain return type with no `!`.
pub fn collectFnErrors(gpa: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) ![]model.ErrorMember {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buf, node) orelse return &.{};
    const returnTypeNode = proto.ast.return_type.unwrap() orelse return &.{};

    const first = tree.firstToken(returnTypeNode);
    const last = tree.lastToken(returnTypeNode);

    var tok = first;
    while (tok <= last) : (tok += 1) {
        if (tree.tokenTag(tok) != .bang) continue;
        // A named error set is a single identifier immediately before `!`.
        if (tok == first) return &.{};
        const precedingToken = tok - 1;
        if (tree.tokenTag(precedingToken) != .identifier) return &.{};
        if (precedingToken != first) return &.{};

        const targetName = tree.tokenSlice(precedingToken);
        if (findErrorSetDeclByName(tree, targetName)) |targetDecl| {
            return collectStandaloneErrorSet(gpa, tree, targetDecl);
        }
        return &.{};
    }

    return &.{};
}

/// Finds a top-level `const <name> = error{...};` decl by name.
fn findErrorSetDeclByName(tree: Ast, name: []const u8) ?Ast.Node.Index {
    for (tree.rootDecls()) |decl| {
        const nameToken = declNameToken(tree, decl) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(nameToken), name)) continue;
        if (isErrorSetDecl(tree, decl)) return decl;
    }
    return null;
}

/// Collects the member identifiers of an `error_set_decl` node
/// (`error{ A, B, C }`) by scanning its tokens directly.
fn collectErrorSetMembers(gpa: std.mem.Allocator, tree: Ast, errorSetNode: Ast.Node.Index) ![]model.ErrorMember {
    var out: std.ArrayList(model.ErrorMember) = .empty;
    errdefer {
        for (out.items) |e| {
            gpa.free(e.name);
            gpa.free(e.docComment);
        }
        out.deinit(gpa);
    }

    const first = tree.firstToken(errorSetNode);
    const last = tree.lastToken(errorSetNode);

    var tok = first;
    while (tok <= last) : (tok += 1) {
        if (tree.tokenTag(tok) != .identifier) continue;
        const name = tree.tokenSlice(tok);
        const doc = try extractFieldDocComment(gpa, tree, tok);
        try out.append(gpa, model.ErrorMember{
            .name = try gpa.dupe(u8, name),
            .docComment = if (doc) |d| d.text else try gpa.dupe(u8, ""),
        });
    }

    return out.toOwnedSlice(gpa);
}

/// Returns the 1-based source line a token starts on. `tokenLocation`'s
/// `.line` is 0-indexed, hence `+ 1`.
pub fn declLine(tree: Ast, token: Ast.TokenIndex) u32 {
    const loc = tree.tokenLocation(0, token);
    return @intCast(loc.line + 1);
}

/// Returns the identifier token for a top-level container member if it is a
/// named declaration (fn, var, const), otherwise null (skip test blocks,
/// comptime blocks, etc.).
fn declNameToken(tree: Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    var buf: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&buf, node)) |proto| {
        return proto.name_token;
    }
    if (tree.fullVarDecl(node)) |decl| {
        return decl.ast.mut_token + 1;
    }
    return null;
}

/// Returns the member node list of a container-typed decl's initializer
/// (struct/enum/union body), if the decl's value is itself a container.
/// Copies members into a newly allocated slice (caller frees), since
/// `fullContainerDecl`'s compact form may borrow from scratch space.
pub fn containerMembers(gpa: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) !?[]const Ast.Node.Index {
    const valueNodeOpt = if (tree.fullVarDecl(node)) |decl|
        decl.ast.init_node
    else
        return null;

    const valueNode = valueNodeOpt.unwrap() orelse return null;

    var buf: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buf, valueNode) orelse return null;
    return try gpa.dupe(Ast.Node.Index, container.ast.members);
}

/// Whether any of `members` would yield a `Section` in `collectMembers`.
fn anyNamedMember(tree: Ast, members: []const Ast.Node.Index) bool {
    for (members) |member| {
        if (declNameToken(tree, member) != null) return true;
    }
    return false;
}

/// Whether any of `members` is a struct/union field, independent of
/// `--extras`. Zig's convention for a real data type vs. a namespace.
pub fn hasFieldMember(tree: Ast, members: []const Ast.Node.Index) bool {
    for (members) |member| {
        if (tree.fullContainerField(member) != null) return true;
    }
    return false;
}

/// A top-level `const`/`var` decl whose initializer is `@import("target")`.
pub const ImportRef = struct {
    /// The importing decl's own name (e.g. `foo` in `const foo = @import(...)`).
    name: []const u8,
    /// The raw, unresolved string passed to `@import`.
    target: []const u8,
};

/// Scans `members` for decls initialized by an `@import(...)` call and
/// returns one `ImportRef` per match, in declaration order.
pub fn importTargets(gpa: std.mem.Allocator, tree: Ast, members: []const Ast.Node.Index) ![]ImportRef {
    var out: std.ArrayList(ImportRef) = .empty;
    errdefer {
        for (out.items) |ref| {
            gpa.free(ref.name);
            gpa.free(ref.target);
        }
        out.deinit(gpa);
    }

    for (members) |member| {
        const nameToken = declNameToken(tree, member) orelse continue;
        const decl = tree.fullVarDecl(member) orelse continue;
        const valueNode = decl.ast.init_node.unwrap() orelse continue;
        const target = try importCallTarget(gpa, tree, valueNode) orelse continue;
        try out.append(gpa, ImportRef{
            .name = try gpa.dupe(u8, tree.tokenSlice(nameToken)),
            .target = target,
        });
    }

    return out.toOwnedSlice(gpa);
}

/// Parses a Zig string literal, converting a syntactically invalid literal
/// to `null` instead of an error. Explicit return type so a caller that
/// unwraps it only ever sees `error.OutOfMemory`.
fn parseStringLiteral(gpa: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!?[]u8 {
    return std.zig.string_literal.parseAlloc(gpa, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLiteral => return null,
    };
}

/// If `node` is an `@import("...")` call, or a `field_access` chain
/// rooted in one (e.g. `@import("x").Y`), returns the decoded string
/// argument. Otherwise `null`.
fn importCallTarget(gpa: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) !?[]u8 {
    var target = node;
    while (tree.nodeTag(target) == .field_access) {
        target = tree.nodeData(target).node_and_token[0];
    }

    var buf: [2]Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buf, target) orelse return null;
    if (params.len != 1) return null;

    const builtinToken = tree.nodeMainToken(target);
    if (!std.mem.eql(u8, tree.tokenSlice(builtinToken), "@import")) return null;

    const argToken = tree.firstToken(params[0]);
    if (tree.tokenTag(argToken) != .string_literal) return null;

    return parseStringLiteral(gpa, tree.tokenSlice(argToken));
}

/// Classifies a container node (struct/union/enum/opaque) by its keyword token.
pub fn containerKind(tree: Ast, containerNode: Ast.Node.Index) ?model.Kind {
    var buf: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buf, containerNode) orelse return null;
    return switch (tree.tokenTag(container.ast.main_token)) {
        .keyword_struct => .struct_decl,
        .keyword_enum => .enum_decl,
        .keyword_union => .union_decl,
        .keyword_opaque => .opaque_decl,
        else => null,
    };
}

pub fn declKind(tree: Ast, node: Ast.Node.Index) model.Kind {
    var fnBuf: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fnBuf, node)) |_| return .fn_decl;

    const decl = tree.fullVarDecl(node) orelse return .const_decl; // unreachable given declNameToken's guarantee; safe fallback
    const isConst = tree.tokenTag(decl.ast.mut_token) == .keyword_const;

    if (decl.ast.init_node.unwrap()) |valueNode| {
        if (containerKind(tree, valueNode)) |k| return k;
    }

    return if (isConst) .const_decl else .var_decl;
}

/// Whether a top-level container member is marked `pub`.
pub fn isPubDecl(tree: Ast, node: Ast.Node.Index) bool {
    var fnBuf: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fnBuf, node)) |proto| return proto.visib_token != null;

    const decl = tree.fullVarDecl(node) orelse return false; // unreachable given declNameToken's guarantee; safe fallback
    return decl.visib_token != null;
}

/// Collects contiguous `///` lines immediately preceding a declaration.
/// `isPub`: when false and none found, falls back to a leading `//` comment.
pub fn extractDocComment(gpa: std.mem.Allocator, tree: Ast, nameToken: Ast.TokenIndex, isPub: bool) !?DocCommentResult {
    var start: Ast.TokenIndex = nameToken;

    // Doc comments precede the leading keyword(s), not the identifier itself.
    while (start > 0) {
        const prev = start - 1;
        switch (tree.tokenTag(prev)) {
            .keyword_pub, .keyword_fn, .keyword_const, .keyword_var, .keyword_extern, .keyword_export => start = prev,
            else => break,
        }
    }

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);

    var tok = start;
    while (tok > 0) {
        const prev = tok - 1;
        if (tree.tokenTag(prev) != .doc_comment) break;
        tok = prev;
    }

    while (tok < start and tree.tokenTag(tok) == .doc_comment) : (tok += 1) {
        try lines.append(gpa, stripDocPrefix(tree.tokenSlice(tok), "///"));
    }

    if (lines.items.len == 0) {
        if (isPub) return null;
        const fallback = try extractPlainCommentFallback(gpa, tree, start) orelse return null;
        return DocCommentResult{ .text = fallback, .isFallback = true };
    }
    return DocCommentResult{ .text = try std.mem.join(gpa, "\n", lines.items) };
}

/// Strips a doc-comment marker (`///` or `//!`) and one leading space.
fn stripDocPrefix(raw: []const u8, prefix: []const u8) []const u8 {
    var s = raw;
    if (std.mem.startsWith(u8, s, prefix)) s = s[prefix.len..];
    if (s.len > 0 and s[0] == ' ') s = s[1..];
    return s;
}

/// Fallback for a non-`pub` item with no `///` doc comment: collects
/// contiguous plain `//` lines directly above it, stopping at the
/// first blank or non-comment line.
fn extractPlainCommentFallback(gpa: std.mem.Allocator, tree: Ast, startToken: Ast.TokenIndex) !?[]const u8 {
    const source = tree.source;
    const declLineStart: usize = lineStart(source, tree.tokenStart(startToken));

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);

    var lineEnd: usize = if (declLineStart > 0) declLineStart - 1 else 0;
    while (lineEnd > 0) {
        const start = if (std.mem.lastIndexOfScalar(u8, source[0..lineEnd], '\n')) |i| i + 1 else 0;
        const rawLine = std.mem.trimEnd(u8, source[start..lineEnd], " \t\r");
        const line = std.mem.trimStart(u8, rawLine, " \t");

        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "///") or std.mem.startsWith(u8, line, "//!")) break;
        if (!std.mem.startsWith(u8, line, "//")) break;

        try lines.append(gpa, stripDocPrefix(line, "//"));
        lineEnd = if (start > 0) start - 1 else 0;
    }

    if (lines.items.len == 0) return null;
    std.mem.reverse([]const u8, lines.items);
    return try std.mem.join(gpa, "\n", lines.items);
}

/// Renders a decl's signature: its source span up to the body's `{`.
pub fn extractSignature(gpa: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) ![]const u8 {
    const full = std.mem.trimStart(u8, sliceForNode(tree, node), " \t");
    const end = std.mem.indexOfScalar(u8, full, '{') orelse full.len;
    const trimmed = std.mem.trimEnd(u8, full[0..end], " \t\r\n");
    return gpa.dupe(u8, trimmed);
}

/// Returns the full source slice spanned by `node`, including leading
/// indentation on the first token's line.
pub fn sliceForNode(tree: Ast, node: Ast.Node.Index) []const u8 {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    const start = lineStart(tree.source, tree.tokenStart(first));
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
    return tree.source[start..end];
}

/// Like `sliceForNode`, but for a sub-expression fragment — no
/// leading-indentation back-walk.
fn sliceForExpr(tree: Ast, node: Ast.Node.Index) []const u8 {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    const start = tree.tokenStart(first);
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
    return tree.source[start..end];
}

/// Walks back from `pos` over spaces/tabs to the start of the
/// indentation on that line, stopping at a newline or byte 0.
pub fn lineStart(source: [:0]const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and (source[i - 1] == ' ' or source[i - 1] == '\t')) i -= 1;
    return i;
}
