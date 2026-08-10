//! Builds a `model.DocTree` from a Zig source file via `std.zig.Ast`.
const std = @import("std");
const Ast = std.zig.Ast;
const model = @import("model.zig");

/// Errors surfaced while extracting a `DocTree` from source.
pub const ExtractError = error{ParseFailed} || std.mem.Allocator.Error;

/// Parses `source` and extracts a `DocTree` for `moduleName`.
/// `sourcePath` is recorded on each `Section` verbatim (not resolved to
/// an absolute path) for optional file/line display in output — the
/// caller is responsible for passing something document-root-relative
/// here (e.g. `std/Io/Dir.zig`), never a raw CLI/filesystem path, since
/// whatever's passed in is shown to the reader as-is.
pub fn extractFile(
    gpa: std.mem.Allocator,
    moduleName: []const u8,
    sourcePath: []const u8,
    source: [:0]const u8,
    recursive: bool,
) ExtractError!model.DocTree {
    var tree = Ast.parse(gpa, source, .{ .mode = .zig }) catch return ExtractError.ParseFailed;
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return ExtractError.ParseFailed;

    const rootDoc = try extractModuleDocComment(gpa, tree);

    var sections: std.ArrayList(model.Section) = .empty;
    errdefer sections.deinit(gpa);

    const rootMembers = tree.rootDecls();
    try collectMembers(gpa, tree, rootMembers, moduleName, sourcePath, recursive, &sections);

    return model.DocTree{
        .moduleName = try gpa.dupe(u8, moduleName),
        .rootDocComment = rootDoc,
        .sections = try sections.toOwnedSlice(gpa),
        .fullSource = try gpa.dupe(u8, source),
    };
}

/// Collects leading `//!` lines at the top of the file, if present.
fn extractModuleDocComment(gpa: std.mem.Allocator, tree: Ast) !?[]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);

    var tok: Ast.TokenIndex = 0;
    while (tok < tree.tokens.len and tree.tokenTag(tok) == .container_doc_comment) : (tok += 1) {
        try lines.append(gpa, stripDocPrefix(tree.tokenSlice(tok), "//!"));
    }
    if (lines.items.len == 0) return null;
    return try std.mem.join(gpa, "\n", lines.items);
}

/// Walks `members`, appending a `Section` per named declaration.
fn collectMembers(
    gpa: std.mem.Allocator,
    tree: Ast,
    members: []const Ast.Node.Index,
    parentPath: []const u8,
    sourcePath: []const u8,
    recursive: bool,
    out: *std.ArrayList(model.Section),
) ExtractError!void {
    for (members) |member| {
        const nameToken = declNameToken(tree, member) orelse continue;
        const name = tree.tokenSlice(nameToken);

        const doc = try extractDocComment(gpa, tree, nameToken);
        const signature = try extractSignature(gpa, tree, member);
        const sourceSlice = try gpa.dupe(u8, sliceForNode(tree, member));
        const path = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ parentPath, name });
        const line = declLine(tree, nameToken);
        const kind = declKind(tree, member);

        var children: std.ArrayList(model.Section) = .empty;
        errdefer children.deinit(gpa);
        var hasChildren = false;

        if (try containerMembers(gpa, tree, member)) |nested| {
            defer gpa.free(nested);
            hasChildren = anyNamedMember(tree, nested);
            if (recursive) {
                try collectMembers(gpa, tree, nested, path, sourcePath, recursive, &children);
            }
        }

        try out.append(gpa, model.Section{
            .name = try gpa.dupe(u8, name),
            .path = path,
            .signature = signature,
            .docComment = doc orelse try gpa.dupe(u8, ""),
            .source = sourceSlice,
            .sourceFile = try gpa.dupe(u8, sourcePath),
            .sourceLine = line,
            .kind = kind,
            .children = try children.toOwnedSlice(gpa),
            .hasChildren = hasChildren,
        });
    }
}

/// Returns the 1-based source line a token starts on. `tokenLocation`'s
/// `.line` is 0-indexed, hence `+ 1`.
fn declLine(tree: Ast, token: Ast.TokenIndex) u32 {
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
/// Copies the members into a newly allocated slice (caller frees):
/// `fullContainerDecl`'s compact `container_decl_two`/`_trailing` shape
/// returns a slice borrowed from the caller-supplied scratch buffer, not
/// from the tree's own storage, so returning that slice straight out of
/// this function would leave it pointing at a stack frame that's already
/// gone by the time the caller reads it.
fn containerMembers(gpa: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) !?[]const Ast.Node.Index {
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

/// Classifies a top-level container member as a `model.Kind`.
fn declKind(tree: Ast, node: Ast.Node.Index) model.Kind {
    var fnBuf: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fnBuf, node)) |_| return .fn_decl;

    const decl = tree.fullVarDecl(node) orelse return .const_decl; // unreachable given declNameToken's guarantee; safe fallback
    const isConst = tree.tokenTag(decl.ast.mut_token) == .keyword_const;

    if (decl.ast.init_node.unwrap()) |valueNode| {
        var buf: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buf, valueNode)) |container| {
            return switch (tree.tokenTag(container.ast.main_token)) {
                .keyword_struct => .struct_decl,
                .keyword_enum => .enum_decl,
                .keyword_union => .union_decl,
                .keyword_opaque => .opaque_decl,
                else => if (isConst) .const_decl else .var_decl,
            };
        }
    }

    return if (isConst) .const_decl else .var_decl;
}

/// Collects contiguous `///` lines immediately preceding a declaration.
fn extractDocComment(gpa: std.mem.Allocator, tree: Ast, nameToken: Ast.TokenIndex) !?[]const u8 {
    var start: Ast.TokenIndex = nameToken;

    // Doc comments precede the `pub`/`fn`/`const` keyword(s) that lead the
    // declaration, not the identifier itself, so walk back past those first.
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

    if (lines.items.len == 0) return null;
    return try std.mem.join(gpa, "\n", lines.items);
}

/// Strips a doc-comment marker (`///` or `//!`) and one leading space.
fn stripDocPrefix(raw: []const u8, prefix: []const u8) []const u8 {
    var s = raw;
    if (std.mem.startsWith(u8, s, prefix)) s = s[prefix.len..];
    if (s.len > 0 and s[0] == ' ') s = s[1..];
    return s;
}

/// Renders a decl's signature: its source span up to the body's `{`.
fn extractSignature(gpa: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) ![]const u8 {
    const full = std.mem.trimStart(u8, sliceForNode(tree, node), " \t");
    const end = std.mem.indexOfScalar(u8, full, '{') orelse full.len;
    const trimmed = std.mem.trimEnd(u8, full[0..end], " \t\r\n");
    return gpa.dupe(u8, trimmed);
}

/// Returns the full source slice spanned by `node`, including any
/// indentation on the first token's line so the first output line
/// isn't dedented relative to the rest.
fn sliceForNode(tree: Ast, node: Ast.Node.Index) []const u8 {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    const start = lineStart(tree.source, tree.tokenStart(first));
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
    return tree.source[start..end];
}

/// Walks back from `pos` over spaces/tabs to the start of the
/// indentation on that line, stopping at a newline or byte 0.
fn lineStart(source: [:0]const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and (source[i - 1] == ' ' or source[i - 1] == '\t')) i -= 1;
    return i;
}

test "extracts a documented function" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\//! Module summary.
        \\
        \\/// Adds two numbers.
        \\/// Second line of docs.
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\
    ;
    var treeDoc = try extractFile(gpa, "example", "example.zig", source, false);
    defer treeDoc.deinit(gpa);

    try std.testing.expect(treeDoc.rootDocComment != null);
    try std.testing.expectEqualStrings("Module summary.", treeDoc.rootDocComment.?);
    try std.testing.expectEqual(@as(usize, 1), treeDoc.sections.len);

    const fnSection = treeDoc.sections[0];
    try std.testing.expectEqualStrings("add", fnSection.name);
    try std.testing.expectEqualStrings("example.add", fnSection.path);
    try std.testing.expectEqualStrings("Adds two numbers.\nSecond line of docs.", fnSection.docComment);
    try std.testing.expectEqualStrings("example.zig", fnSection.sourceFile);
    try std.testing.expectEqual(@as(u32, 5), fnSection.sourceLine);
}

test "undocumented decl still appears" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub fn bare() void {}
        \\
    ;
    var treeDoc = try extractFile(gpa, "example", "example.zig", source, false);
    defer treeDoc.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), treeDoc.sections.len);
    try std.testing.expectEqualStrings("", treeDoc.sections[0].docComment);
    try std.testing.expectEqual(@as(u32, 1), treeDoc.sections[0].sourceLine);
}

test "nested decl source keeps its leading indentation" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub const Outer = struct {
        \\    pub fn inner() void {}
        \\};
        \\
    ;
    var treeDoc = try extractFile(gpa, "example", "example.zig", source, true);
    defer treeDoc.deinit(gpa);

    const outer = treeDoc.sections[0];
    try std.testing.expect(std.mem.startsWith(u8, outer.source, "pub const Outer"));

    const innerFn = outer.children[0];
    try std.testing.expect(std.mem.startsWith(u8, innerFn.source, "    pub fn inner"));
}

test "parse failure surfaces as error" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 = "pub fn broken( {";
    try std.testing.expectError(ExtractError.ParseFailed, extractFile(gpa, "example", "example.zig", source, false));
}
