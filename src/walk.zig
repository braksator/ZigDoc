//! A cross-file identifier/scope graph for `--discover ns`, ported from
//! Zig's own Autodoc (`lib/docs/wasm/{Walk,Decl}.zig`). Parses every
//! reachable file into one shared graph, resolves identifiers against
//! per-file `Scope`s, and classifies each decl into a `Category` —
//! including `.alias`, so a re-export resolves through to its real
//! target decl rather than showing the one-line alias.
//!
//! Renamed to this project's camelCase convention; index types are plain
//! `u32`s into owned `ArrayList`s; no `modules`/multi-package support, no
//! doctest extraction. Otherwise a close, node-tag-for-node-tag port.
const std = @import("std");
const Ast = std.zig.Ast;

pub const Error = std.mem.Allocator.Error;
/// `Graph.addFile`'s own error set: allocation failure, or the source
/// failed to parse as valid Zig.
pub const AddFileError = Error || error{ParseFailed};

/// What a decl's value expression resolves to. Mirrors Autodoc's own
/// `Category` — keeps `alias` as a distinct case callers chase
/// themselves via `Decl.resolveAlias`, since a decl's own identity is
/// meaningful even when its content is an alias.
pub const Category = union(enum) {
    /// A struct type used only to group declarations (no fields).
    namespace: Ast.Node.Index,
    /// A container type (struct, union, enum, opaque) with fields.
    container: Ast.Node.Index,
    globalVariable: Ast.Node.Index,
    /// A function not detected as returning a type.
    function: Ast.Node.Index,
    primitive: Ast.Node.Index,
    errorSet: Ast.Node.Index,
    globalConst: Ast.Node.Index,
    alias: Decl.Index,
    /// A primitive identifier that is also a type (e.g. `i32`).
    type,
    /// Specifically the literal `type`.
    typeType,
    /// A function that returns a type (a generic type constructor).
    /// Payload is the returned container's own node when resolvable
    /// (see `findReturnedContainerNode`), else falls back to the
    /// `fn_decl` node itself.
    typeFunction: Ast.Node.Index,
};

/// One parsed, walked file. Owns its own `Ast` and per-file resolution
/// tables; does not own the `Decl`s it contributes (those live in the
/// shared `Graph.decls`).
pub const File = struct {
    ast: Ast,
    /// Owned copy of the source `ast` was parsed from — `Ast.parse`
    /// borrows the buffer rather than copying it, and this `File`
    /// outlives the caller's own source buffer, so it needs a durable
    /// copy of its own.
    ownedSource: [:0]const u8,
    /// Maps an identifier token to the AST node it resolves to
    /// (a `var`/`const`/`fn` decl node, found via `Scope.lookup`).
    identDecls: std.AutoHashMapUnmanaged(Ast.TokenIndex, Ast.Node.Index) = .empty,
    /// Maps a decl node to its `Decl.Index` in the shared graph.
    nodeDecls: std.AutoHashMapUnmanaged(Ast.Node.Index, Decl.Index) = .empty,
    /// root node, or a struct/union/enum/opaque decl node => its
    /// namespace scope; a local `var`/`const` node => its local scope.
    scopes: std.AutoHashMapUnmanaged(Ast.Node.Index, *Scope) = .empty,

    pub fn deinit(self: *File, gpa: std.mem.Allocator) void {
        self.identDecls.deinit(gpa);
        self.nodeDecls.deinit(gpa);
        var it = self.scopes.valueIterator();
        while (it.next()) |s| s.*.destroy(gpa);
        self.scopes.deinit(gpa);
        self.ast.deinit(gpa);
        gpa.free(self.ownedSource);
    }

    pub const Index = enum(u32) {
        _,

        pub fn get(i: File.Index, graph: *const Graph) *File {
            return &graph.files.items[@intFromEnum(i)];
        }

        pub fn path(i: File.Index, graph: *const Graph) []const u8 {
            return graph.filePaths.items[@intFromEnum(i)];
        }

        /// This file's path as it should be shown to a reader —
        /// relative to the root file's own directory, `/`-separated.
        /// Falls back to `path` verbatim if relative resolution fails.
        pub fn displayPath(i: File.Index, gpa: std.mem.Allocator, graph: *const Graph) ![]u8 {
            const raw = i.path(graph);
            const dir = graph.rootDir orelse return gpa.dupe(u8, raw);
            return relativePosix(gpa, dir, raw);
        }

        pub fn findRootDecl(i: File.Index, graph: *const Graph) Decl.Index {
            const file = i.get(graph);
            return file.nodeDecls.get(.root) orelse .none;
        }
    };
};

pub const Decl = struct {
    astNode: Ast.Node.Index,
    file: File.Index,
    /// The decl whose namespace this is nested in, or `.none` for a
    /// file's own root decl.
    parent: Index,

    pub const Index = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn get(i: Decl.Index, graph: *const Graph) *Decl {
            return &graph.decls.items[@intFromEnum(i)];
        }
    };

    pub const ExtraInfo = struct {
        isPub: bool,
        name: []const u8,
        firstDocComment: Ast.OptionalTokenIndex,
    };

    pub fn extraInfo(decl: *const Decl, graph: *const Graph) ExtraInfo {
        const ast = &decl.file.get(graph).ast;
        switch (ast.nodeTag(decl.astNode)) {
            .root => return .{
                .name = "",
                .isPub = true,
                .firstDocComment = if (ast.tokenTag(0) == .container_doc_comment)
                    .fromToken(0)
                else
                    .none,
            },
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => {
                const varDecl = ast.fullVarDecl(decl.astNode).?;
                const nameToken = varDecl.ast.mut_token + 1;
                return .{
                    .name = ast.tokenSlice(nameToken),
                    .isPub = varDecl.visib_token != null,
                    .firstDocComment = findFirstDocComment(ast, varDecl.firstToken()),
                };
            },
            .fn_proto,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto_simple,
            .fn_decl,
            => {
                var buf: [1]Ast.Node.Index = undefined;
                const fnProto = ast.fullFnProto(&buf, decl.astNode).?;
                const nameToken = fnProto.name_token.?;
                return .{
                    .name = ast.tokenSlice(nameToken),
                    .isPub = fnProto.visib_token != null,
                    .firstDocComment = findFirstDocComment(ast, fnProto.firstToken()),
                };
            },
            else => unreachable,
        }
    }

    pub fn categorize(decl: *const Decl, graph: *Graph) Error!Category {
        return categorizeDecl(graph, decl.file, decl.astNode);
    }

    /// Follows `.alias` until a non-alias `Category` (or a cycle,
    /// guarded by `Graph.maxAliasChase`) is reached.
    pub fn resolveAliasIndex(index: Decl.Index, graph: *Graph) Error!struct { Decl.Index, Category, usize } {
        var current = index;
        var hops: usize = 0;
        while (true) {
            const cat = try current.get(graph).categorize(graph);
            switch (cat) {
                .alias => |aliasee| {
                    hops += 1;
                    if (hops > graph.maxAliasChase) return .{ current, cat, hops };
                    current = aliasee;
                },
                else => return .{ current, cat, hops },
            }
        }
    }

    /// Looks up a direct child of `decl` by name — a member of its
    /// namespace/container, or (transparently) of whatever it's an
    /// alias for.
    pub fn getChild(decl: *const Decl, graph: *Graph, name: []const u8) Error!?Decl.Index {
        const cat = try decl.categorize(graph);
        switch (cat) {
            .alias => |aliasee| return aliasee.get(graph).getChild(graph, name),
            .namespace, .container => |node| {
                const file = decl.file.get(graph);
                const scope = file.scopes.get(node) orelse return null;
                const childNode = scope.getChild(name) orelse return null;
                return file.nodeDecls.get(childNode);
            },
            else => return null,
        }
    }

    /// Lists every direct child of `decl`'s namespace/container, in
    /// source order — transparently chasing `.alias` first, same as
    /// `getChild`. Re-derives the member list directly from the
    /// container's own AST node, which preserves source order without
    /// scanning the whole graph's decl list.
    pub fn children(decl: *const Decl, graph: *Graph, gpa: std.mem.Allocator) Error![]Decl.Index {
        const cat = try decl.categorize(graph);
        switch (cat) {
            .alias => |aliasee| return aliasee.get(graph).children(graph, gpa),
            .namespace, .container, .typeFunction => |node| {
                const file = decl.file.get(graph);
                const t = &file.ast;
                const memberNodes: []const Ast.Node.Index = if (t.nodeTag(node) == .root) t.rootDecls() else blk: {
                    var buf: [2]Ast.Node.Index = undefined;
                    const full = t.fullContainerDecl(&buf, node) orelse break :blk &.{};
                    break :blk full.ast.members;
                };

                var out: std.ArrayList(Decl.Index) = .empty;
                errdefer out.deinit(gpa);
                for (memberNodes) |member| {
                    const declIndex = file.nodeDecls.get(member) orelse continue;
                    try out.append(gpa, declIndex);
                }
                return out.toOwnedSlice(gpa);
            },
            else => return &.{},
        }
    }

    fn findFirstDocComment(ast: *const Ast, token: Ast.TokenIndex) Ast.OptionalTokenIndex {
        var it = token;
        while (it > 0) {
            it -= 1;
            if (ast.tokenTag(it) != .doc_comment) return .fromToken(it + 1);
        }
        return .none;
    }
};

/// Computes `path`'s form relative to `dir` — both already resolved
/// and `/`-separated, sharing the same root, so this is plain
/// prefix-stripping. Falls back to `path` unchanged if `dir` isn't a
/// prefix of it.
fn relativePosix(gpa: std.mem.Allocator, dir: []const u8, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, dir, ".")) return gpa.dupe(u8, path);
    if (!std.mem.startsWith(u8, path, dir)) return gpa.dupe(u8, path);
    var rest = path[dir.len..];
    if (std.mem.startsWith(u8, rest, "/") or std.mem.startsWith(u8, rest, "\\")) rest = rest[1..];
    if (rest.len == 0) return gpa.dupe(u8, path);
    return gpa.dupe(u8, rest);
}

/// The shared graph every walked file's decls live in. One `Graph` per
/// `--discover ns` invocation.
pub const Graph = struct {
    gpa: std.mem.Allocator,
    files: std.ArrayList(File) = .empty,
    filePaths: std.ArrayList([]const u8) = .empty,
    decls: std.ArrayList(Decl) = .empty,
    /// The first file added — every file's display path is relative to
    /// this file's own directory. `null` until the first `addFile` call.
    rootDir: ?[]const u8 = null,
    /// Cap on `.alias` hops `resolveAliasIndex` will chase before
    /// giving up, to avoid infinite-looping on a pathological cycle.
    maxAliasChase: usize = 64,

    pub fn init(gpa: std.mem.Allocator) Graph {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Graph) void {
        for (self.files.items) |*f| f.deinit(self.gpa);
        self.files.deinit(self.gpa);
        for (self.filePaths.items) |p| self.gpa.free(p);
        self.filePaths.deinit(self.gpa);
        self.decls.deinit(self.gpa);
        if (self.rootDir) |d| self.gpa.free(d);
        self.* = undefined;
    }

    /// Parses `source` and walks its whole body, registering every
    /// decl and building this file's identifier/scope resolution
    /// tables. `path` is duplicated and owned by the graph. `source`
    /// itself is not retained past this call — this makes its own
    /// durable copy first and parses that.
    pub fn addFile(self: *Graph, path: []const u8, source: [:0]const u8) AddFileError!File.Index {
        if (self.rootDir == null) {
            self.rootDir = try self.gpa.dupe(u8, std.fs.path.dirname(path) orelse ".");
        }

        const ownedSourceBuf = try self.gpa.allocSentinel(u8, source.len, 0);
        errdefer self.gpa.free(ownedSourceBuf);
        @memcpy(ownedSourceBuf, source);
        const ownedSource: [:0]const u8 = ownedSourceBuf;

        var ast = Ast.parse(self.gpa, ownedSource, .{ .mode = .zig }) catch return error.OutOfMemory;
        if (ast.errors.len != 0) {
            ast.deinit(self.gpa);
            return error.ParseFailed;
        }

        const index: File.Index = @enumFromInt(self.files.items.len);
        // Ownership of ast/ownedSource transfers into self.files here.
        try self.files.append(self.gpa, .{ .ast = ast, .ownedSource = ownedSource });
        try self.filePaths.append(self.gpa, try self.gpa.dupe(u8, path));

        var w: Walker = .{ .graph = self, .file = index };
        var topScope: Scope = .{ .tag = .top };
        const declIndex = try addDecl(self, .root, index, .none);
        try w.structDecl(&topScope, declIndex, .root, w.ast().containerDeclRoot());

        return index;
    }

    /// Finds a file already added to this graph by its resolved path,
    /// if any. Used to resolve `@import("...")` targets that were
    /// already discovered under a different import name/site.
    pub fn findFileByPath(self: *const Graph, path: []const u8) ?File.Index {
        for (self.filePaths.items, 0..) |p, i| {
            if (std.mem.eql(u8, p, path)) return @enumFromInt(i);
        }
        return null;
    }

    /// Resolves a raw `@import("importString")` argument, as seen from
    /// `fromFile`, to the `File.Index` it targets. Returns `null` if
    /// the target isn't (yet, or ever) part of this graph.
    pub fn resolveImportString(self: *const Graph, fromFile: File.Index, importString: []const u8) ?File.Index {
        const basePath = fromFile.path(self);
        const baseDir = std.fs.path.dirname(basePath) orelse ".";
        const resolvedPath = normalizeSeparators(std.fs.path.resolvePosix(self.gpa, &.{ baseDir, importString }) catch return null);
        defer self.gpa.free(resolvedPath);
        return self.findFileByPath(resolvedPath);
    }
};

fn addDecl(graph: *Graph, node: Ast.Node.Index, file: File.Index, parent: Decl.Index) Error!Decl.Index {
    try graph.decls.append(graph.gpa, .{ .astNode = node, .file = file, .parent = parent });
    const index: Decl.Index = @enumFromInt(graph.decls.items.len - 1);
    try file.get(graph).nodeDecls.put(graph.gpa, node, index);
    return index;
}

/// A lexical scope during the walk: the top scope (file root), a local
/// `var`/`const` binding, or a namespace (struct/union/enum/opaque
/// body, including the file root once it's known to be one).
pub const Scope = struct {
    tag: Tag,

    const Tag = enum { top, local, namespace };

    const Local = struct {
        base: Scope = .{ .tag = .local },
        parent: *Scope,
        varNode: Ast.Node.Index,
    };

    const Namespace = struct {
        base: Scope = .{ .tag = .namespace },
        parent: *Scope,
        names: std.StringHashMapUnmanaged(Ast.Node.Index) = .empty,
        declIndex: Decl.Index,
    };

    fn destroy(scope: *Scope, gpa: std.mem.Allocator) void {
        switch (scope.tag) {
            .top => {},
            .local => {
                const local: *Local = @alignCast(@fieldParentPtr("base", scope));
                gpa.destroy(local);
            },
            .namespace => {
                const namespace: *Namespace = @alignCast(@fieldParentPtr("base", scope));
                namespace.names.deinit(gpa);
                gpa.destroy(namespace);
            },
        }
    }

    pub fn getChild(scope: *Scope, name: []const u8) ?Ast.Node.Index {
        switch (scope.tag) {
            .top, .local => return null,
            .namespace => {
                const namespace: *Namespace = @alignCast(@fieldParentPtr("base", scope));
                return namespace.names.get(name);
            },
        }
    }

    pub fn lookup(startScope: *Scope, ast: *const Ast, name: []const u8) ?Ast.Node.Index {
        var it: *Scope = startScope;
        while (true) switch (it.tag) {
            .top => break,
            .local => {
                const local: *Local = @alignCast(@fieldParentPtr("base", it));
                const nameToken = ast.nodeMainToken(local.varNode) + 1;
                if (std.mem.eql(u8, ast.tokenSlice(nameToken), name)) return local.varNode;
                it = local.parent;
            },
            .namespace => {
                const namespace: *Namespace = @alignCast(@fieldParentPtr("base", it));
                if (namespace.names.get(name)) |node| return node;
                it = namespace.parent;
            },
        };
        return null;
    }
};

/// Traversal state for one file's walk. Short-lived — created and
/// discarded within `Graph.addFile`.
const Walker = struct {
    graph: *Graph,
    file: File.Index,

    fn ast(w: *Walker) *Ast {
        return &w.file.get(w.graph).ast;
    }

    fn structDecl(
        w: *Walker,
        scope: *Scope,
        parentDecl: Decl.Index,
        node: Ast.Node.Index,
        containerDecl: Ast.full.ContainerDecl,
    ) Error!void {
        const gpa = w.graph.gpa;
        const t = w.ast();

        const namespace = try gpa.create(Scope.Namespace);
        namespace.* = .{ .parent = scope, .declIndex = parentDecl };
        try w.file.get(w.graph).scopes.put(gpa, node, &namespace.base);
        try w.scanDecls(namespace, containerDecl.ast.members);

        for (containerDecl.ast.members) |member| switch (t.nodeTag(member)) {
            .container_field_init,
            .container_field_align,
            .container_field,
            => try w.containerField(&namespace.base, parentDecl, t.fullContainerField(member).?),

            .fn_proto,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto_simple,
            .fn_decl,
            => {
                var buf: [1]Ast.Node.Index = undefined;
                const full = t.fullFnProto(&buf, member).?;
                const declIndex = try addDecl(w.graph, member, w.file, parentDecl);
                const body = if (t.nodeTag(member) == .fn_decl) t.nodeData(member).node_and_node[1].toOptional() else .none;
                try w.fnDecl(&namespace.base, declIndex, body, full);
            },

            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => {
                const declIndex = try addDecl(w.graph, member, w.file, parentDecl);
                try w.globalVarDecl(&namespace.base, declIndex, t.fullVarDecl(member).?);
            },

            .@"comptime" => try w.expr(&namespace.base, parentDecl, t.nodeData(member).node),

            .test_decl => try w.expr(&namespace.base, parentDecl, t.nodeData(member).opt_token_and_node[1]),

            else => {},
        };
    }

    fn scanDecls(w: *Walker, namespace: *Scope.Namespace, members: []const Ast.Node.Index) Error!void {
        const gpa = w.graph.gpa;
        const t = w.ast();
        for (members) |member| {
            const nameToken = switch (t.nodeTag(member)) {
                .global_var_decl,
                .local_var_decl,
                .simple_var_decl,
                .aligned_var_decl,
                => t.nodeMainToken(member) + 1,

                .fn_proto_simple,
                .fn_proto_multi,
                .fn_proto_one,
                .fn_proto,
                .fn_decl,
                => blk: {
                    const ident = t.nodeMainToken(member) + 1;
                    if (t.tokenTag(ident) != .identifier) continue;
                    break :blk ident;
                },

                else => continue,
            };
            try namespace.names.put(gpa, t.tokenSlice(nameToken), member);
        }
    }

    fn globalVarDecl(w: *Walker, scope: *Scope, parentDecl: Decl.Index, full: Ast.full.VarDecl) Error!void {
        try w.maybeExpr(scope, parentDecl, full.ast.type_node);
        try w.maybeExpr(scope, parentDecl, full.ast.align_node);
        try w.maybeExpr(scope, parentDecl, full.ast.addrspace_node);
        try w.maybeExpr(scope, parentDecl, full.ast.section_node);
        try w.maybeExpr(scope, parentDecl, full.ast.init_node);
    }

    fn containerField(w: *Walker, scope: *Scope, parentDecl: Decl.Index, full: Ast.full.ContainerField) Error!void {
        try w.maybeExpr(scope, parentDecl, full.ast.type_expr);
        try w.maybeExpr(scope, parentDecl, full.ast.align_expr);
        try w.maybeExpr(scope, parentDecl, full.ast.value_expr);
    }

    fn fnDecl(
        w: *Walker,
        scope: *Scope,
        parentDecl: Decl.Index,
        body: Ast.Node.OptionalIndex,
        full: Ast.full.FnProto,
    ) Error!void {
        for (full.ast.params) |param| try w.expr(scope, parentDecl, param);
        if (full.ast.return_type.unwrap()) |returnType| try w.expr(scope, parentDecl, returnType);
        try w.maybeExpr(scope, parentDecl, full.ast.align_expr);
        try w.maybeExpr(scope, parentDecl, full.ast.addrspace_expr);
        try w.maybeExpr(scope, parentDecl, full.ast.section_expr);
        try w.maybeExpr(scope, parentDecl, full.ast.callconv_expr);
        try w.maybeExpr(scope, parentDecl, body);
    }

    fn maybeExpr(w: *Walker, scope: *Scope, parentDecl: Decl.Index, node: Ast.Node.OptionalIndex) Error!void {
        if (node.unwrap()) |n| try w.expr(scope, parentDecl, n);
    }

    fn expr(w: *Walker, scope: *Scope, parentDecl: Decl.Index, node: Ast.Node.Index) Error!void {
        const gpa = w.graph.gpa;
        const t = w.ast();
        switch (t.nodeTag(node)) {
            .assign,
            .assign_shl,
            .assign_shl_sat,
            .assign_shr,
            .assign_bit_and,
            .assign_bit_or,
            .assign_bit_xor,
            .assign_div,
            .assign_sub,
            .assign_sub_wrap,
            .assign_sub_sat,
            .assign_mod,
            .assign_add,
            .assign_add_wrap,
            .assign_add_sat,
            .assign_mul,
            .assign_mul_wrap,
            .assign_mul_sat,
            .shl,
            .shr,
            .add,
            .add_wrap,
            .add_sat,
            .sub,
            .sub_wrap,
            .sub_sat,
            .mul,
            .mul_wrap,
            .mul_sat,
            .div,
            .mod,
            .shl_sat,
            .bit_and,
            .bit_or,
            .bit_xor,
            .bang_equal,
            .equal_equal,
            .greater_than,
            .greater_or_equal,
            .less_than,
            .less_or_equal,
            .array_cat,
            .error_union,
            .merge_error_sets,
            .bool_and,
            .bool_or,
            .@"catch",
            .@"orelse",
            .array_type,
            .array_access,
            .switch_range,
            => {
                const lhs, const rhs = t.nodeData(node).node_and_node;
                try w.expr(scope, parentDecl, lhs);
                try w.expr(scope, parentDecl, rhs);
            },

            .assign_destructure => {
                const full = t.assignDestructure(node);
                for (full.ast.variables) |variableNode| try w.expr(scope, parentDecl, variableNode);
                try w.expr(scope, parentDecl, full.ast.value_expr);
            },

            .bool_not,
            .bit_not,
            .negation,
            .negation_wrap,
            .deref,
            .address_of,
            .optional_type,
            .@"comptime",
            .@"nosuspend",
            .@"suspend",
            .@"resume",
            .@"try",
            => try w.expr(scope, parentDecl, t.nodeData(node).node),

            .unwrap_optional,
            .grouped_expression,
            => try w.expr(scope, parentDecl, t.nodeData(node).node_and_token[0]),

            .@"return" => try w.maybeExpr(scope, parentDecl, t.nodeData(node).opt_node),

            .anyframe_type => try w.expr(scope, parentDecl, t.nodeData(node).token_and_node[1]),
            .@"break" => try w.maybeExpr(scope, parentDecl, t.nodeData(node).opt_token_and_opt_node[1]),

            .identifier => {
                const identToken = t.nodeMainToken(node);
                const identName = t.tokenSlice(identToken);
                if (scope.lookup(t, identName)) |varNode| {
                    try w.file.get(w.graph).identDecls.put(gpa, identToken, varNode);
                }
            },

            .field_access => {
                // Unlike Autodoc, no `token_parents` map — nothing here
                // renders inline cross-reference links off of it; only
                // the base-object resolution (for alias chasing) is
                // needed, which comes from recursing below.
                const objectNode, _ = t.nodeData(node).node_and_token;
                try w.expr(scope, parentDecl, objectNode);
            },

            .string_literal,
            .multiline_string_literal,
            .number_literal,
            .unreachable_literal,
            .enum_literal,
            .error_value,
            .anyframe_literal,
            .@"continue",
            .char_literal,
            .error_set_decl,
            => {},

            // These node tags are `unreachable` in Autodoc's own
            // `expr` — top-level/statement-level forms `expr` is never
            // supposed to be invoked on directly (each is always
            // routed through a dedicated caller — `structDecl`,
            // `block`, etc. — before recursing further). Kept as a
            // silent no-op here rather than `unreachable`: a
            // genuinely-unreachable path misclassified by this port
            // should degrade to "this identifier doesn't resolve"
            // (safe — `Category` falls back to `.globalConst`/etc.),
            // not crash the whole `--discover ns` run.
            .root,
            .test_decl,
            .container_field_init,
            .container_field_align,
            .container_field,
            .fn_decl,
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            .@"defer",
            .@"errdefer",
            .switch_case,
            .switch_case_inline,
            .switch_case_one,
            .switch_case_inline_one,
            .asm_output,
            .asm_input,
            .for_range,
            => {},

            .asm_simple, .@"asm" => {
                const full = t.fullAsm(node).?;
                try w.expr(scope, parentDecl, full.ast.template);
            },

            .builtin_call_two,
            .builtin_call_two_comma,
            .builtin_call,
            .builtin_call_comma,
            => {
                var buf: [2]Ast.Node.Index = undefined;
                const params = t.builtinCallParams(&buf, node).?;
                try w.builtinCall(scope, parentDecl, node, params);
            },

            .call_one,
            .call_one_comma,
            .call,
            .call_comma,
            => {
                var buf: [1]Ast.Node.Index = undefined;
                const full = t.fullCall(&buf, node).?;
                try w.expr(scope, parentDecl, full.ast.fn_expr);
                for (full.ast.params) |param| try w.expr(scope, parentDecl, param);
            },

            .if_simple, .@"if" => {
                const full = t.fullIf(node).?;
                try w.expr(scope, parentDecl, full.ast.cond_expr);
                try w.expr(scope, parentDecl, full.ast.then_expr);
                try w.maybeExpr(scope, parentDecl, full.ast.else_expr);
            },

            .while_simple, .while_cont, .@"while" => try w.whileExpr(scope, parentDecl, t.fullWhile(node).?),

            .for_simple, .@"for" => {
                const full = t.fullFor(node).?;
                for (full.ast.inputs) |input| {
                    if (t.nodeTag(input) == .for_range) {
                        const start, const end = t.nodeData(input).node_and_opt_node;
                        try w.expr(scope, parentDecl, start);
                        try w.maybeExpr(scope, parentDecl, end);
                    } else {
                        try w.expr(scope, parentDecl, input);
                    }
                }
                try w.expr(scope, parentDecl, full.ast.then_expr);
                try w.maybeExpr(scope, parentDecl, full.ast.else_expr);
            },

            .slice => try w.slice(scope, parentDecl, t.slice(node)),
            .slice_open => try w.slice(scope, parentDecl, t.sliceOpen(node)),
            .slice_sentinel => try w.slice(scope, parentDecl, t.sliceSentinel(node)),

            .block_two, .block_two_semicolon, .block, .block_semicolon => {
                var buf: [2]Ast.Node.Index = undefined;
                const statements = t.blockStatements(&buf, node).?;
                try w.block(scope, parentDecl, statements);
            },

            .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => {
                const full = t.fullPtrType(node).?;
                try w.maybeExpr(scope, parentDecl, full.ast.align_node);
                try w.maybeExpr(scope, parentDecl, full.ast.addrspace_node);
                try w.maybeExpr(scope, parentDecl, full.ast.sentinel);
                try w.maybeExpr(scope, parentDecl, full.ast.bit_range_start);
                try w.maybeExpr(scope, parentDecl, full.ast.bit_range_end);
                try w.expr(scope, parentDecl, full.ast.child_type);
            },

            .container_decl,
            .container_decl_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            => {
                var buf: [2]Ast.Node.Index = undefined;
                try w.structDecl(scope, parentDecl, node, t.fullContainerDecl(&buf, node).?);
            },

            .array_type_sentinel => {
                const lenExpr, const extraIndex = t.nodeData(node).node_and_extra;
                const extra = t.extraData(extraIndex, Ast.Node.ArrayTypeSentinel);
                try w.expr(scope, parentDecl, lenExpr);
                try w.expr(scope, parentDecl, extra.elem_type);
                try w.expr(scope, parentDecl, extra.sentinel);
            },

            .@"switch", .switch_comma => {
                const full = t.fullSwitch(node).?;
                try w.expr(scope, parentDecl, full.ast.condition);
                for (full.ast.cases) |caseNode| {
                    const case = t.fullSwitchCase(caseNode).?;
                    for (case.ast.values) |valueNode| try w.expr(scope, parentDecl, valueNode);
                    try w.expr(scope, parentDecl, case.ast.target_expr);
                }
            },

            .array_init_one,
            .array_init_one_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init,
            .array_init_comma,
            => {
                var buf: [2]Ast.Node.Index = undefined;
                const full = t.fullArrayInit(&buf, node).?;
                try w.maybeExpr(scope, parentDecl, full.ast.type_expr);
                for (full.ast.elements) |elem| try w.expr(scope, parentDecl, elem);
            },

            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init,
            .struct_init_comma,
            => {
                var buf: [2]Ast.Node.Index = undefined;
                const full = t.fullStructInit(&buf, node).?;
                try w.maybeExpr(scope, parentDecl, full.ast.type_expr);
                for (full.ast.fields) |field| try w.expr(scope, parentDecl, field);
            },

            .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => {
                var buf: [1]Ast.Node.Index = undefined;
                try w.fnDecl(scope, parentDecl, .none, t.fullFnProto(&buf, node).?);
            },
        }
    }

    fn slice(w: *Walker, scope: *Scope, parentDecl: Decl.Index, full: Ast.full.Slice) Error!void {
        try w.expr(scope, parentDecl, full.ast.sliced);
        try w.expr(scope, parentDecl, full.ast.start);
        try w.maybeExpr(scope, parentDecl, full.ast.end);
        try w.maybeExpr(scope, parentDecl, full.ast.sentinel);
    }

    fn builtinCall(
        w: *Walker,
        scope: *Scope,
        parentDecl: Decl.Index,
        node: Ast.Node.Index,
        params: []const Ast.Node.Index,
    ) Error!void {
        const t = w.ast();
        const builtinToken = t.nodeMainToken(node);
        const builtinName = t.tokenSlice(builtinToken);
        if (std.mem.eql(u8, builtinName, "@This")) {
            try w.file.get(w.graph).nodeDecls.put(w.graph.gpa, node, getNamespaceDeclHelper(scope));
        }
        for (params) |param| try w.expr(scope, parentDecl, param);
    }

    fn block(w: *Walker, parentScope: *Scope, parentDecl: Decl.Index, statements: []const Ast.Node.Index) Error!void {
        const t = w.ast();
        var scope = parentScope;
        for (statements) |node| {
            switch (t.nodeTag(node)) {
                .global_var_decl,
                .local_var_decl,
                .simple_var_decl,
                .aligned_var_decl,
                => {
                    const full = t.fullVarDecl(node).?;
                    try w.globalVarDecl(scope, parentDecl, full);
                    const local = try w.graph.gpa.create(Scope.Local);
                    local.* = .{ .parent = scope, .varNode = node };
                    try w.file.get(w.graph).scopes.put(w.graph.gpa, node, &local.base);
                    scope = &local.base;
                },

                .assign_destructure => {}, // not needed for doc-comment/alias resolution

                .grouped_expression => try w.expr(scope, parentDecl, t.nodeData(node).node_and_token[0]),

                .@"defer", .@"errdefer" => try w.expr(scope, parentDecl, t.nodeData(node).node),

                else => try w.expr(scope, parentDecl, node),
            }
        }
    }

    fn whileExpr(w: *Walker, scope: *Scope, parentDecl: Decl.Index, full: Ast.full.While) Error!void {
        try w.expr(scope, parentDecl, full.ast.cond_expr);
        try w.maybeExpr(scope, parentDecl, full.ast.cont_expr);
        try w.expr(scope, parentDecl, full.ast.then_expr);
        try w.maybeExpr(scope, parentDecl, full.ast.else_expr);
    }
};

fn getNamespaceDeclHelper(startScope: *Scope) Decl.Index {
    var it: *Scope = startScope;
    while (true) switch (it.tag) {
        .top => return .none,
        .local => {
            const local: *Scope.Local = @alignCast(@fieldParentPtr("base", it));
            it = local.parent;
        },
        .namespace => {
            const namespace: *Scope.Namespace = @alignCast(@fieldParentPtr("base", it));
            return namespace.declIndex;
        },
    };
}

/// Classifies a decl node — the top-level dispatch `Decl.categorize`
/// calls into. Ports Autodoc's `File.Index.categorize_decl`.
fn categorizeDecl(graph: *Graph, file: File.Index, node: Ast.Node.Index) Error!Category {
    const t = &file.get(graph).ast;
    switch (t.nodeTag(node)) {
        .root => {
            for (t.rootDecls()) |member| {
                switch (t.nodeTag(member)) {
                    .container_field_init,
                    .container_field_align,
                    .container_field,
                    => return .{ .container = node },
                    else => {},
                }
            }
            return .{ .namespace = node };
        },

        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const varDecl = t.fullVarDecl(node).?;
            if (t.tokenTag(varDecl.ast.mut_token) == .keyword_var) return .{ .globalVariable = node };
            const initNode = varDecl.ast.init_node.unwrap() orelse return .{ .globalConst = node };
            return categorizeExpr(graph, file, initNode);
        },

        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            const full = t.fullFnProto(&buf, node).?;
            return categorizeFunc(graph, file, node, full);
        },

        // Not one of Autodoc's own recognized top-level decl-node
        // tags. Degrades rather than crashing.
        else => return .{ .globalConst = node },
    }
}

fn categorizeFunc(graph: *Graph, file: File.Index, node: Ast.Node.Index, full: Ast.full.FnProto) Error!Category {
    const returnTypeNode = full.ast.return_type.unwrap() orelse return .{ .function = node };
    return switch (try categorizeExpr(graph, file, returnTypeNode)) {
        .namespace, .container, .errorSet, .typeType => .{ .typeFunction = findReturnedContainerNode(graph, file, node) orelse node },
        else => .{ .function = node },
    };
}

/// A generic type function's real members live in whatever container
/// its body returns, not in the `fn_decl` node itself. Resolves to
/// that container's node so callers can treat a type function like an
/// ordinary struct/union/enum for member discovery. Only handles the
/// single-statement `return <container literal>;` shape; anything more
/// elaborate falls back to `null`.
fn findReturnedContainerNode(graph: *Graph, file: File.Index, fnNode: Ast.Node.Index) ?Ast.Node.Index {
    const t = &file.get(graph).ast;
    if (t.nodeTag(fnNode) != .fn_decl) return null;
    const bodyNode = t.nodeData(fnNode).node_and_node[1];

    var buf: [2]Ast.Node.Index = undefined;
    const statements = t.blockStatements(&buf, bodyNode) orelse return null;

    for (statements) |stmt| {
        if (t.nodeTag(stmt) != .@"return") continue;
        const retExpr = t.nodeData(stmt).opt_node.unwrap() orelse return null;

        var containerBuf: [2]Ast.Node.Index = undefined;
        if (t.fullContainerDecl(&containerBuf, retExpr) == null) return null;
        return retExpr;
    }
    return null;
}

/// Like `categorizeExpr`, but also chases through `.alias` to whatever
/// it resolves to — for callers that need the underlying shape rather
/// than "is this decl merely an alias." Bounded by `graph.maxAliasChase`.
fn categorizeExprDeep(graph: *Graph, file: File.Index, node: Ast.Node.Index) Error!Category {
    const cat = try categorizeExpr(graph, file, node);
    switch (cat) {
        .alias => |aliasee| {
            const resolved = try Decl.resolveAliasIndex(aliasee, graph);
            return resolved[1];
        },
        else => return cat,
    }
}

fn categorizeExpr(graph: *Graph, file: File.Index, node: Ast.Node.Index) Error!Category {
    const f = file.get(graph);
    const t = &f.ast;
    switch (t.nodeTag(node)) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            const containerDecl = t.fullContainerDecl(&buf, node).?;
            if (t.tokenTag(containerDecl.ast.main_token) != .keyword_struct) {
                return .{ .container = node };
            }
            for (containerDecl.ast.members) |member| {
                switch (t.nodeTag(member)) {
                    .container_field_init,
                    .container_field_align,
                    .container_field,
                    => return .{ .container = node },
                    else => {},
                }
            }
            return .{ .namespace = node };
        },

        .error_set_decl, .merge_error_sets => return .{ .errorSet = node },

        .identifier => {
            const nameToken = t.nodeMainToken(node);
            const identName = t.tokenSlice(nameToken);
            if (std.mem.eql(u8, identName, "type")) return .typeType;
            if (isPrimitiveNonType(identName)) return .{ .primitive = node };
            if (std.zig.primitives.isPrimitive(identName)) return .type;

            if (f.identDecls.get(nameToken)) |declNode| {
                if (f.nodeDecls.get(declNode)) |declIndex| return .{ .alias = declIndex };
                return categorizeDecl(graph, file, declNode);
            }

            return .{ .globalConst = node };
        },

        .field_access => {
            const objectNode, const fieldIdent = t.nodeData(node).node_and_token;
            const fieldName = t.tokenSlice(fieldIdent);

            switch (try categorizeExpr(graph, file, objectNode)) {
                .alias => |aliasee| {
                    if (try aliasee.get(graph).getChild(graph, fieldName)) |declIndex| {
                        return .{ .alias = declIndex };
                    }
                },
                else => {},
            }

            return .{ .globalConst = node };
        },

        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            const params = t.builtinCallParams(&buf, node).?;
            return categorizeBuiltinCall(graph, file, node, params);
        },

        .call_one,
        .call_one_comma,
        .call,
        .call_comma,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            return categorizeCall(graph, file, node, t.fullCall(&buf, node).?);
        },

        .if_simple, .@"if" => {
            const ifFull = t.fullIf(node).?;
            if (ifFull.ast.else_expr.unwrap()) |elseExpr| {
                const thenCat = try categorizeExprDeep(graph, file, ifFull.ast.then_expr);
                const elseCat = try categorizeExprDeep(graph, file, elseExpr);
                if (thenCat == .typeType and elseCat == .typeType) {
                    return .typeType;
                } else if (thenCat == .errorSet and elseCat == .errorSet) {
                    return .{ .errorSet = node };
                } else if (thenCat == .type or elseCat == .type or
                    thenCat == .namespace or elseCat == .namespace or
                    thenCat == .container or elseCat == .container or
                    thenCat == .errorSet or elseCat == .errorSet or
                    thenCat == .typeFunction or elseCat == .typeFunction)
                {
                    return .type;
                }
            }
            return .{ .globalConst = node };
        },

        .@"switch", .switch_comma => return categorizeSwitch(graph, file, node),

        .optional_type,
        .array_type,
        .array_type_sentinel,
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        .anyframe_type,
        => return .type,

        else => return .{ .globalConst = node },
    }
}

fn categorizeCall(graph: *Graph, file: File.Index, node: Ast.Node.Index, call: Ast.full.Call) Error!Category {
    return switch (try categorizeExpr(graph, file, call.ast.fn_expr)) {
        .typeFunction => .type,
        .alias => |aliasee| try categorizeDeclAsCallee(graph, aliasee, node),
        else => .{ .globalConst = node },
    };
}

fn categorizeDeclAsCallee(graph: *Graph, declIndex: Decl.Index, callNode: Ast.Node.Index) Error!Category {
    return switch (try declIndex.get(graph).categorize(graph)) {
        .typeFunction => .type,
        .alias => |aliasee| try categorizeDeclAsCallee(graph, aliasee, callNode),
        else => .{ .globalConst = callNode },
    };
}

/// Rewrites `\` to `/` in-place. Every path used as a `Graph` lookup
/// key must go through this once — see the identical helper and its
/// doc comment in `imports.zig` for why.
fn normalizeSeparators(path: []u8) []u8 {
    for (path) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return path;
}

/// Ports `categorize_builtin_call`'s `@import` branch. A target file may
/// not be in `graph` yet (e.g. an import cycle back to a file whose walk
/// hasn't returned) — falls back to `.globalConst` in that case, same as
/// Autodoc does for an unresolved import.
fn categorizeBuiltinCall(graph: *Graph, file: File.Index, node: Ast.Node.Index, params: []const Ast.Node.Index) Error!Category {
    const t = &file.get(graph).ast;
    const builtinToken = t.nodeMainToken(node);
    const builtinName = t.tokenSlice(builtinToken);
    if (std.mem.eql(u8, builtinName, "@import")) {
        if (params.len != 1) return .{ .globalConst = node };
        const argToken = t.firstToken(params[0]);
        if (t.tokenTag(argToken) != .string_literal) return .{ .globalConst = node };
        const importPath = std.zig.string_literal.parseAlloc(graph.gpa, t.tokenSlice(argToken)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => return .{ .globalConst = node },
        };
        defer graph.gpa.free(importPath);

        const basePath = file.path(graph);
        const baseDir = std.fs.path.dirname(basePath) orelse ".";
        const resolvedPath = normalizeSeparators(std.fs.path.resolvePosix(graph.gpa, &.{ baseDir, importPath }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        });
        defer graph.gpa.free(resolvedPath);

        if (graph.findFileByPath(resolvedPath)) |importedFile| {
            const rootDecl = importedFile.findRootDecl(graph);
            if (rootDecl != .none) return .{ .alias = rootDecl };
        }
        return .{ .globalConst = node };
    } else if (std.mem.eql(u8, builtinName, "@This")) {
        if (file.get(graph).nodeDecls.get(node)) |declIndex| return .{ .alias = declIndex };
        return .{ .globalConst = node };
    }
    return .{ .globalConst = node };
}

fn categorizeSwitch(graph: *Graph, file: File.Index, node: Ast.Node.Index) Error!Category {
    const t = &file.get(graph).ast;
    const full = t.fullSwitch(node).?;
    var allTypeType = true;
    var allErrorSet = true;
    var anyType = false;
    if (full.ast.cases.len == 0) return .{ .globalConst = node };
    for (full.ast.cases) |caseNode| {
        const case = t.fullSwitchCase(caseNode).?;
        switch (try categorizeExprDeep(graph, file, case.ast.target_expr)) {
            .typeType => {
                anyType = true;
                allErrorSet = false;
            },
            .errorSet => {
                anyType = true;
                allTypeType = false;
            },
            .type, .namespace, .container, .typeFunction => {
                anyType = true;
                allErrorSet = false;
                allTypeType = false;
            },
            else => {
                allErrorSet = false;
                allTypeType = false;
            },
        }
    }
    if (allTypeType) return .typeType;
    if (allErrorSet) return .{ .errorSet = node };
    if (anyType) return .type;
    return .{ .globalConst = node };
}

fn isPrimitiveNonType(name: []const u8) bool {
    return std.mem.eql(u8, name, "undefined") or
        std.mem.eql(u8, name, "null") or
        std.mem.eql(u8, name, "true") or
        std.mem.eql(u8, name, "false");
}
