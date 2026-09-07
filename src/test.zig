//! Integration tests: extract each fixture and exercise the split
//! renderers' page/file-splitting logic. Templates (.tpl files) are
//! user-overridable and may be blanked or rewritten arbitrarily, so no
//! test may assume anything about what a template renders — assertions
//! stick to page counts, `.filename` paths, tree/registry structure,
//! and `search.buildIndex` entries (all computed independently of
//! `.tpl` content), never `Page.contents`.

const std = @import("std");
const extract = @import("extract.zig");
const codelinks = extract.codelinks;
const imports = @import("imports.zig");
const model = @import("model.zig");
const main = @import("main.zig");
const options = main.options;
const render = @import("render.zig");
const search = @import("search.zig");
const sources = @import("sources.zig");
const template = @import("template.zig");
const walk = @import("walk.zig");
const progress = main.progress_mod;

const bareFunction = @embedFile("fixtures/bare_function.zig");
const documentedStruct = @embedFile("fixtures/documented_struct.zig");
const nestedContainers = @embedFile("fixtures/nested_containers.zig");
const undocumentedDecl = @embedFile("fixtures/undocumented_decl.zig");
const manySmallContainers = @embedFile("fixtures/many_small_containers.zig");

const importGraphRoot = @embedFile("fixtures/import_graph_root.zig");
const importGraphChild = @embedFile("fixtures/import_graph_child.zig");
const importGraphDiamondLeft = @embedFile("fixtures/import_graph_diamond_left.zig");
const importGraphDiamondRight = @embedFile("fixtures/import_graph_diamond_right.zig");
const importGraphShared = @embedFile("fixtures/import_graph_shared.zig");

const codelinkImportRoot = @embedFile("fixtures/codelink_import_root.zig");
const codelinkImportLeaf = @embedFile("fixtures/codelink_import_leaf.zig");

const codelinkWholefileRoot = @embedFile("fixtures/codelink_wholefile_root.zig");
const codelinkWholefileLeaf = @embedFile("fixtures/codelink_wholefile_leaf.zig");

const codelinkMentionRoot = @embedFile("fixtures/codelink_mention_root.zig");
const codelinkMentionTarget = @embedFile("fixtures/codelink_mention_target.zig");

const codelinkMentionSignatureCrash = @embedFile("fixtures/codelink_mention_signature_crash.zig");

const codelinkVoidRoot = @embedFile("fixtures/codelink_void_root.zig");
const codelinkVoidStd = @embedFile("fixtures/codelink_void_std.zig");
const codelinkVoidMem = @embedFile("fixtures/codelink_void_mem.zig");

const codelinkChainStd = @embedFile("fixtures/codelink_chain_std.zig");
const codelinkChainMem = @embedFile("fixtures/codelink_chain_mem.zig");
const codelinkChainAllocator = @embedFile("fixtures/codelink_chain_allocator.zig");
const codelinkChainUser = @embedFile("fixtures/codelink_chain_user.zig");

const codelinkPkgStd = @embedFile("fixtures/codelink_pkg_std.zig");
const codelinkPkgParse = @embedFile("fixtures/codelink_pkg_parse.zig");
const codelinkPkgUser = @embedFile("fixtures/codelink_pkg_user.zig");

const genericContainer = @embedFile("fixtures/generic_container.zig");
const genericContainerRoot = @embedFile("fixtures/generic_container_root.zig");

test "decl kind: fn is fn_decl, const-of-struct is struct_decl not const_decl" {
    const gpa = std.testing.allocator;

    var fnTree = try extract.extractFile(gpa, "bare_function", "test.zig", bareFunction, false, false, false);
    defer fnTree.deinit(gpa);
    try std.testing.expectEqual(model.Kind.fn_decl, fnTree.sections[0].kind);

    var structTree = try extract.extractFile(gpa, "documented_struct", "test.zig", documentedStruct, false, false, false);
    defer structTree.deinit(gpa);
    try std.testing.expectEqual(model.Kind.struct_decl, structTree.sections[0].kind);
}

test "extractFile: recursive walks nested containers, non-recursive stops at the outer one" {
    const gpa = std.testing.allocator;

    var recursiveTree = try extract.extractFile(gpa, "nested_containers", "test.zig", nestedContainers, true, false, false);
    defer recursiveTree.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), recursiveTree.sections.len);
    const outer = recursiveTree.sections[0];
    try std.testing.expectEqualStrings("Outer", outer.name);
    try std.testing.expectEqual(@as(usize, 1), outer.children.len);
    try std.testing.expectEqualStrings("Inner", outer.children[0].name);
    try std.testing.expectEqual(@as(usize, 1), outer.children[0].children.len);
    try std.testing.expectEqualStrings("value", outer.children[0].children[0].name);

    var flatTree = try extract.extractFile(gpa, "nested_containers", "test.zig", nestedContainers, false, false, false);
    defer flatTree.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), flatTree.sections.len);
    try std.testing.expectEqual(@as(usize, 0), flatTree.sections[0].children.len);
    try std.testing.expect(flatTree.sections[0].hasChildren);
}

test "extractFile: several sibling small containers each keep their own correct members" {
    // Regression: sibling containers sharing a scratch buffer could
    // overwrite each other's member list.
    const gpa = std.testing.allocator;

    var tree = try extract.extractFile(gpa, "many_small_containers", "test.zig", manySmallContainers, true, false, false);
    defer tree.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), tree.sections.len);

    const alpha = tree.sections[0];
    try std.testing.expectEqualStrings("Alpha", alpha.name);
    try std.testing.expectEqual(@as(usize, 2), alpha.children.len);
    try std.testing.expectEqualStrings("one", alpha.children[0].name);
    try std.testing.expectEqualStrings("two", alpha.children[1].name);

    const beta = tree.sections[1];
    try std.testing.expectEqualStrings("Beta", beta.name);
    try std.testing.expectEqual(@as(usize, 1), beta.children.len);
    try std.testing.expectEqualStrings("double", beta.children[0].name);
    try std.testing.expectEqual(model.Kind.fn_decl, beta.children[0].kind);

    const gamma = tree.sections[2];
    try std.testing.expectEqualStrings("Gamma", gamma.name);
    try std.testing.expectEqual(@as(usize, 1), gamma.children.len);
    const delta = gamma.children[0];
    try std.testing.expectEqualStrings("Delta", delta.name);
    try std.testing.expectEqual(@as(usize, 2), delta.children.len);
    try std.testing.expectEqualStrings("value", delta.children[0].name);
    try std.testing.expectEqualStrings("triple", delta.children[1].name);
    try std.testing.expectEqual(model.Kind.fn_decl, delta.children[1].kind);
}

test "file section: extracted file metadata has no source line" {
    const gpa = std.testing.allocator;

    const treeA = try extract.extractFile(gpa, "bare_function", "bare_function.zig", bareFunction, false, false, false);
    var trees = [_]model.DocTree{treeA};
    const labels = [_][]const u8{"bare_function.zig"};
    var merged = try model.mergeTrees(gpa, "combined", &trees, .{ .fileLabels = &labels, .showExt = true, .showDirPrefix = true });
    defer merged.deinit(gpa);

    try std.testing.expectEqual(model.Kind.file, merged.sections[0].kind);
    try std.testing.expectEqualStrings("bare_function.zig", merged.sections[0].sourceFile);
    try std.testing.expectEqual(@as(u32, 0), merged.sections[0].sourceLine);
}

test "split file: merged tree produces an index page and one page per file" {
    const gpa = std.testing.allocator;

    const treeA = try extract.extractFile(gpa, "bare_function", "bare_function.zig", bareFunction, false, false, false);
    const treeB = try extract.extractFile(gpa, "undocumented_decl", "undocumented_decl.zig", undocumentedDecl, false, false, false);
    var trees = [_]model.DocTree{ treeA, treeB };
    const labels = [_][]const u8{ "bare_function.zig", "undocumented_decl.zig" };
    var merged = try model.mergeTrees(gpa, "combined", &trees, .{ .fileLabels = &labels, .showExt = true, .showDirPrefix = true });
    merged.rootIsDir = true;
    defer merged.deinit(gpa);

    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .html, merged, "test-project", options.Options{ .split = .file, .tree = false }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    try std.testing.expectEqual(@as(usize, 3), pages.len); // index + 2 file pages

    var foundBarePage = false;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "bare_function.zig/index.html")) foundBarePage = true;
    }
    try std.testing.expect(foundBarePage);
}

test "split file: md output produces an index page and one page per file" {
    const gpa = std.testing.allocator;

    const treeA = try extract.extractFile(gpa, "bare_function", "bare_function.zig", bareFunction, false, false, false);
    var trees = [_]model.DocTree{treeA};
    const labels = [_][]const u8{"bare_function.zig"};
    var merged = try model.mergeTrees(gpa, "combined", &trees, .{ .fileLabels = &labels, .showExt = true, .showDirPrefix = true });
    defer merged.deinit(gpa);

    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .md, merged, "test-project", options.Options{ .format = .md, .split = .file, .tree = false }, template.mdDoc, template.mdSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var foundIndex = false;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "index.md")) foundIndex = true;
    }
    try std.testing.expect(foundIndex);
}

test "imports.walkTree builds a nested tree rooted at the root file itself" {
    const gpa = std.testing.allocator;

    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("import_graph_root.zig", importGraphRoot);
    try fixture.put("import_graph_child.zig", importGraphChild);
    try fixture.put("import_graph_diamond_left.zig", importGraphDiamondLeft);
    try fixture.put("import_graph_diamond_right.zig", importGraphDiamondRight);
    try fixture.put("import_graph_shared.zig", importGraphShared);

    var tree = try imports.walkTree(gpa, fixture.reader(), "import_graph_root.zig", true, false, false, null);
    defer tree.deinit(gpa);

    // The root file is the tree: own doc comment, four top-level
    // alias entries (child, left, right, ownDecl), plus each
    // imported file's own real content as further top-level entries
    // at their own true (fqn-derived) location — not nested inside
    // whichever alias happened to reach them first. child/left/right
    // are each whole-file aliases (own file, own fqn, own real
    // content elsewhere); ownDecl is the only real content that's
    // also a direct child of root.
    try std.testing.expectEqualStrings("import_graph_root", tree.moduleName);
    try std.testing.expect(tree.rootDocComment != null);
    try std.testing.expectEqual(@as(usize, 8), tree.sections.len);

    // "child" is a thin alias; its own file's real content
    // (import_graph_child, with "greet") lives at its own fqn spot.
    const child = findSection(tree.sections, "child").?;
    try std.testing.expectEqual(@as(usize, 0), child.children.len);
    try std.testing.expectEqualStrings("import_graph_root.import_graph_child", child.aliasTargetPath.?);
    const importGraphChildSection = findSection(tree.sections, "import_graph_child").?;
    try std.testing.expectEqual(@as(usize, 1), importGraphChildSection.children.len);
    try std.testing.expectEqualStrings("greet", importGraphChildSection.children[0].name);

    // "left"/"right" are the same shape as "child" — thin aliases to
    // their own files' real, separately-located content.
    const left = findSection(tree.sections, "left").?;
    try std.testing.expectEqual(@as(usize, 0), left.children.len);
    try std.testing.expectEqualStrings("import_graph_root.import_graph_diamond_left", left.aliasTargetPath.?);
    try std.testing.expect(findSection(tree.sections, "import_graph_diamond_left") != null);

    const right = findSection(tree.sections, "right").?;
    try std.testing.expectEqual(@as(usize, 0), right.children.len);
    try std.testing.expectEqualStrings("import_graph_root.import_graph_diamond_right", right.aliasTargetPath.?);
    try std.testing.expect(findSection(tree.sections, "import_graph_diamond_right") != null);

    // "ownDecl" is a real function declared directly on the root, not
    // reached via any import.
    const ownDecl = findSection(tree.sections, "ownDecl").?;
    try std.testing.expectEqual(model.Kind.fn_decl, ownDecl.kind);
}

test "imports.walkTree resolves a diamond import to the same content, built exactly once" {
    const gpa = std.testing.allocator;

    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("import_graph_root.zig", importGraphRoot);
    try fixture.put("import_graph_child.zig", importGraphChild);
    try fixture.put("import_graph_diamond_left.zig", importGraphDiamondLeft);
    try fixture.put("import_graph_diamond_right.zig", importGraphDiamondRight);
    try fixture.put("import_graph_shared.zig", importGraphShared);

    var tree = try imports.walkTree(gpa, fixture.reader(), "import_graph_root.zig", true, false, false, null);
    defer tree.deinit(gpa);

    // "left" and "right" are themselves thin aliases to their own
    // files' real content (import_graph_diamond_left/_right). Each
    // file's own "shared" member in turn aliases
    // "import_graph_shared.zig" — neither is that file's own true
    // (fqn) home either, so both are thin links too. The real content
    // lives separately, at the top level, named after the file itself.
    const leftContent = findSection(tree.sections, "import_graph_diamond_left").?;
    const rightContent = findSection(tree.sections, "import_graph_diamond_right").?;
    const leftShared = findSection(leftContent.children, "shared").?;
    const rightShared = findSection(rightContent.children, "shared").?;
    const sharedContent = findSection(tree.sections, "import_graph_shared").?;

    try std.testing.expectEqual(@as(usize, 0), leftShared.children.len);
    try std.testing.expectEqualStrings("import_graph_root.import_graph_shared", leftShared.aliasTargetPath.?);
    try std.testing.expectEqual(@as(usize, 0), rightShared.children.len);
    try std.testing.expectEqualStrings("import_graph_root.import_graph_shared", rightShared.aliasTargetPath.?);
    try std.testing.expectEqual(@as(usize, 1), sharedContent.children.len);
    try std.testing.expectEqualStrings("common", sharedContent.children[0].name);
    try std.testing.expectEqualStrings("import_graph_shared.zig", sharedContent.children[0].sourceFile);
}

test "discover ns end to end: split none HTML render produces one page" {
    const gpa = std.testing.allocator;

    var tree = try buildImportGraphTree(gpa);
    defer tree.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 8), tree.sections.len);
    try std.testing.expect(findSection(tree.sections, "child") != null);

    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .html, tree, "test-project", options.Options{ .discover = .ns, .split = .none }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    // Page shape (count, filename) is render.write's own decision, not
    // template content — safe to assert on regardless of .tpl content.
    try std.testing.expectEqual(@as(usize, 1), pages.len);
    try std.testing.expectEqualStrings("index.html", pages[0].filename);
}

fn findSection(sections: []const model.Section, name: []const u8) ?model.Section {
    for (sections) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

// Builds the same nested import-graph tree the tests below use, from
// the shared fixture set. Caller owns the result (`deinit`).
fn buildImportGraphTree(gpa: std.mem.Allocator) !model.DocTree {
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("import_graph_root.zig", importGraphRoot);
    try fixture.put("import_graph_child.zig", importGraphChild);
    try fixture.put("import_graph_diamond_left.zig", importGraphDiamondLeft);
    try fixture.put("import_graph_diamond_right.zig", importGraphDiamondRight);
    try fixture.put("import_graph_shared.zig", importGraphShared);

    return imports.walkTree(gpa, fixture.reader(), "import_graph_root.zig", true, false, false, null);
}

// Same shape, for the single-file `nestedContainers` fixture — used by
// the link-consistency matrix below.
fn buildNestedContainersTree(gpa: std.mem.Allocator) !model.DocTree {
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("nested_containers.zig", nestedContainers);
    return imports.walkTree(gpa, fixture.reader(), "nested_containers.zig", true, false, false, null);
}

// A type function whose body lives in a different file than the page
// that instantiates it — see the link-consistency matrix below.
fn buildGenericContainerTree(gpa: std.mem.Allocator) !model.DocTree {
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("generic_container.zig", genericContainer);
    try fixture.put("generic_container_root.zig", genericContainerRoot);
    return imports.walkTree(gpa, fixture.reader(), "generic_container_root.zig", true, false, false, null);
}

test "discover ns, split item: a decl-level cross-file alias (real std.AutoHashMap shape) writes no page of its own and links to the real one" {
    const gpa = std.testing.allocator;

    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\const hash_map = @import("hash_map.zig");
        \\pub const AutoHashMap = hash_map.AutoHashMap;
        \\
    );
    try fixture.put("hash_map.zig",
        \\pub fn AutoHashMap(comptime K: type, comptime V: type) type {
        \\    return Custom(K, V);
        \\}
        \\
        \\pub fn Custom(comptime K: type, comptime V: type) type {
        \\    _ = K;
        \\    _ = V;
        \\    return struct {
        \\        pub fn init() void {}
        \\    };
        \\}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, false, false, null);
    defer tree.deinit(gpa);

    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .html, tree, "test-project", options.Options{ .discover = .ns, .split = .item }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    // index + hash_map + hash_map/AutoHashMap + hash_map/Custom = 4.
    // Root's own alias contributes no page of its own.
    var foundFlatAutoHashMap = false;
    var foundNestedAutoHashMap = false;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "AutoHashMap.html")) foundFlatAutoHashMap = true;
        if (std.mem.eql(u8, p.filename, "hash_map/AutoHashMap.html") or
            std.mem.eql(u8, p.filename, "hash_map/AutoHashMap/index.html")) foundNestedAutoHashMap = true;
    }
    try std.testing.expect(!foundFlatAutoHashMap);
    try std.testing.expect(foundNestedAutoHashMap);

    // The real page has real content; nothing anywhere is blank.
    for (pages) |p| {
        if (std.mem.indexOf(u8, p.filename, "AutoHashMap") != null) {
            try std.testing.expect(std.mem.indexOf(u8, p.contents, "AutoHashMap") != null);
        }
    }
}

test "discover ns, split item: a field's type resolves through a generic type-function's own nested consts (real std.EnumSet.BitSet shape)" {
    const gpa = std.testing.allocator;

    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\pub const enums = @import("enums.zig");
        \\
    );
    try fixture.put("enums.zig",
        \\pub fn EnumSet(comptime E: type) type {
        \\    return struct {
        \\        const BitSet = std.StaticBitSet(32);
        \\
        \\        bits: BitSet = .empty,
        \\    };
        \\}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, true, false, null);
    defer tree.deinit(gpa);

    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .html, tree, "test-project", options.Options{ .discover = .ns, .split = .item, .show = &.{.fields} }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var found = false;
    for (pages) |p| {
        if (std.mem.indexOf(u8, p.filename, "EnumSet") != null and std.mem.indexOf(u8, p.contents, "class=\"fields\"") != null) {
            try std.testing.expect(std.mem.indexOf(u8, p.contents, "\">BitSet</span></a>") != null);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "discover ns, split item: sibling type-functions each define their own same-named local (real std.EnumSet/EnumMap BitSet collision)" {
    const gpa = std.testing.allocator;

    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\pub const enums = @import("enums.zig");
        \\
    );
    try fixture.put("enums.zig",
        \\pub fn EnumSet(comptime E: type) type {
        \\    return struct {
        \\        const BitSet = std.StaticBitSet(32);
        \\
        \\        bits: BitSet = .empty,
        \\    };
        \\}
        \\
        \\pub fn EnumMap(comptime E: type, comptime V: type) type {
        \\    return struct {
        \\        const BitSet = std.StaticBitSet(64);
        \\
        \\        bits: BitSet = .empty,
        \\    };
        \\}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, true, false, null);
    defer tree.deinit(gpa);

    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .html, tree, "test-project", options.Options{ .discover = .ns, .split = .item, .show = &.{.fields} }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    for (pages) |p| {
        if (std.mem.indexOf(u8, p.filename, "EnumSet") != null and std.mem.indexOf(u8, p.contents, "class=\"fields\"") != null) {
            // EnumSet's own field must link to EnumSet's own BitSet, never EnumMap's.
            try std.testing.expect(std.mem.indexOf(u8, p.contents, "EnumSet/BitSet/index.html") != null);
            try std.testing.expect(std.mem.indexOf(u8, p.contents, "EnumMap/BitSet/index.html") == null);
        }
        if (std.mem.indexOf(u8, p.filename, "EnumMap") != null and std.mem.indexOf(u8, p.contents, "class=\"fields\"") != null) {
            // And vice versa.
            try std.testing.expect(std.mem.indexOf(u8, p.contents, "EnumMap/BitSet/index.html") != null);
            try std.testing.expect(std.mem.indexOf(u8, p.contents, "EnumSet/BitSet/index.html") == null);
        }
    }
}

test "discover ns, split item, --private off: a private type used as a public field's type is still dropped" {
    const gpa = std.testing.allocator;

    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\pub const enums = @import("enums.zig");
        \\
    );
    try fixture.put("enums.zig",
        \\pub fn EnumSet(comptime E: type) type {
        \\    return struct {
        \\        const BitSet = std.StaticBitSet(32);
        \\
        \\        bits: BitSet = .empty,
        \\    };
        \\}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, true, false, null);
    defer tree.deinit(gpa);

    // `isPub` is authoritative: a private decl is dropped even when a
    // surviving public decl's own text still names it (e.g. as a field's
    // type). No reachability exception — that's what let private decls
    // leak into output whenever public code merely referenced them.
    try model.filterPrivate(gpa, &tree.sections);

    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .html, tree, "test-project", options.Options{ .discover = .ns, .split = .item, .show = &.{.fields} }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var foundBitSetPage = false;
    var enumSetLinked = false;
    for (pages) |p| {
        if (std.mem.indexOf(u8, p.filename, "BitSet") != null) foundBitSetPage = true;
        if (std.mem.eql(u8, p.filename, "enums/EnumSet/index.html")) {
            enumSetLinked = std.mem.indexOf(u8, p.contents, "BitSet/index.html") != null;
        }
    }
    try std.testing.expect(!foundBitSetPage);
    try std.testing.expect(!enumSetLinked);
}

test "discover ns, split item, --private off: a private decl unreferenced by anything public is still dropped" {
    const gpa = std.testing.allocator;

    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\pub const Widget = struct {
        \\    pub fn make() Widget {
        \\        return .{};
        \\    }
        \\};
        \\
        \\const TrulyUnused = struct {
        \\    x: u32 = 0,
        \\};
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, true, false, null);
    defer tree.deinit(gpa);

    try model.filterPrivate(gpa, &tree.sections);

    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .html, tree, "test-project", options.Options{ .discover = .ns, .split = .item, .show = &.{.fields} }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    for (pages) |p| {
        try std.testing.expect(std.mem.indexOf(u8, p.filename, "TrulyUnused") == null);
    }
}

test "discover ns, split item: one page per decl, nested decls included" {
    const gpa = std.testing.allocator;

    var tree = try buildImportGraphTree(gpa);
    defer tree.deinit(gpa);

    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .html, tree, "test-project", options.Options{ .discover = .ns, .split = .item }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    // index + import_graph_child + greet + import_graph_diamond_left
    // + import_graph_diamond_right + import_graph_shared + common +
    // ownDecl = 8. "child"/"left"/"right" and the nested "shared"
    // aliases are thin links resolving to the real content's own
    // top-level page — they get no page of their own.
    try std.testing.expectEqual(@as(usize, 8), pages.len);

    var foundGreetPage = false;
    var foundCommonPage = false;
    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    for (pages) |p| {
        // Each file's real content sits at its own top-level slug;
        // nested decls are named after the real file that holds them.
        if (std.mem.eql(u8, p.filename, "import_graph_child/greet/index.html")) foundGreetPage = true;
        if (std.mem.eql(u8, p.filename, "import_graph_shared/common/index.html")) foundCommonPage = true;
        try std.testing.expect(!seen.contains(p.filename)); // no two pages share a path
        try seen.put(p.filename, {});
    }
    try std.testing.expect(foundGreetPage);
    try std.testing.expect(foundCommonPage);
}

test "discover ns, split item: each decl gets its own page, nested under its namespace's slug" {
    const gpa = std.testing.allocator;

    var tree = try buildImportGraphTree(gpa);
    defer tree.deinit(gpa);

    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .html, tree, "test-project", options.Options{ .discover = .ns, .split = .item, .tree = false }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    // Root's own decls are top-level pages, e.g. "ownDecl/index.html".
    // Each imported file's real content nests under its own top-level
    // slug, not wherever an alias happened to reach it first:
    // "greet" under "import_graph_child", "common" under
    // "import_graph_shared".
    var foundOwnDecl = false;
    var foundGreet = false;
    var foundCommon = false;
    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "ownDecl/index.html")) foundOwnDecl = true;
        if (std.mem.eql(u8, p.filename, "import_graph_child/greet/index.html")) foundGreet = true;
        if (std.mem.eql(u8, p.filename, "import_graph_shared/common/index.html")) foundCommon = true;
        try std.testing.expect(!seen.contains(p.filename)); // no two pages share a path
        try seen.put(p.filename, {});
    }
    try std.testing.expect(foundOwnDecl);
    try std.testing.expect(foundGreet);
    try std.testing.expect(foundCommon);
}

test "discover ns: pageFilename/registry (not rendered output) resolves distinct namespace pages" {
    const gpa = std.testing.allocator;

    var tree = try buildImportGraphTree(gpa);
    defer tree.deinit(gpa);

    // Exercises the registry-lookup path writeNode/writePageLinkList
    // use to build each link's href, without going through render.write.
    const opts = options.Options{ .discover = .ns, .split = .file };
    var registry = try render.buildRegistry(gpa, tree.sections, .html, opts);
    defer registry.deinit(gpa);

    // "child" is a thin alias to import_graph_child's own real page —
    // it still resolves to its own distinct slug, just with no
    // children of its own.
    const child = findSection(tree.sections, "child").?;
    const childOwnPath = try registry.slugForFileSection(gpa, child);
    defer gpa.free(childOwnPath);
    const childPath = try render.pageFilename(gpa, .html, child, childOwnPath, opts, registry);
    defer gpa.free(childPath);

    // import_graph_shared's real content sits at its own top-level
    // slug, with "common" nested one level under it.
    const shared = findSection(tree.sections, "import_graph_shared").?;
    const sharedOwnPath = try registry.slugForFileSection(gpa, shared);
    defer gpa.free(sharedOwnPath);
    const commonSection = findSection(shared.children, "common").?;
    const commonOwnPath = try render.appendDeclPathSegment(gpa, sharedOwnPath, commonSection.name, registry);
    defer gpa.free(commonOwnPath);
    const commonPath = try render.pageFilename(gpa, .html, commonSection, commonOwnPath, opts, registry);
    defer gpa.free(commonPath);

    try std.testing.expectEqualStrings("child/index.html", childPath);
    try std.testing.expectEqualStrings("import_graph_shared/common/index.html", commonPath);
    try std.testing.expect(!std.mem.eql(u8, childPath, commonPath));
}

test "discover ns search index: each namespace's decls resolve to distinct hrefs, not a shared empty path" {
    const gpa = std.testing.allocator;

    var tree = try buildImportGraphTree(gpa);
    defer tree.deinit(gpa);

    const entries = try search.buildIndex(gpa, tree, options.Options{ .discover = .ns, .split = .item, .format = .html });
    defer search.freeEntries(gpa, entries);

    // shared.zig is built exactly once, so there's exactly one "common"
    // entry, not collapsed onto the same path as "greet" (every namespace
    // has an empty fileLabel, so a naive fileLabel-keyed lookup could
    // resolve them all to the same slug).
    var greetHref: []const u8 = "";
    var commonHref: []const u8 = "";
    var commonCount: usize = 0;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "greet")) greetHref = e.href;
        if (std.mem.eql(u8, e.name, "common")) {
            commonHref = e.href;
            commonCount += 1;
        }
    }
    try std.testing.expect(greetHref.len > 0);
    try std.testing.expect(commonHref.len > 0);
    try std.testing.expectEqual(@as(usize, 1), commonCount);
    try std.testing.expect(!std.mem.eql(u8, greetHref, commonHref));
    try std.testing.expect(std.mem.startsWith(u8, greetHref, "import_graph_child/"));
    try std.testing.expect(std.mem.startsWith(u8, commonHref, "import_graph_shared/"));
}

test "discover fs, split none: --collapse dir collapses a --tree directory group but not a same-page struct" {
    const gpa = std.testing.allocator;

    const nestedFile = model.Section{
        .name = "inner.zig",
        .path = "sub.inner",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "sub/inner.zig",
        .sourceLine = 0,
        .kind = .file,
        .isFileRoot = true,
        .children = &.{},
        .fileLabel = "sub/inner.zig",
    };
    var widgetChildren = [_]model.Section{model.Section{
        .name = "make",
        .path = "Widget.make",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "",
        .sourceLine = 0,
        .kind = .fn_decl,
        .children = &.{},
    }};
    const topStruct = model.Section{
        .name = "Widget",
        .path = "Widget",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "",
        .sourceLine = 0,
        .kind = .struct_decl,
        .isPub = true,
        .children = &widgetChildren,
    };
    var sections = [_]model.Section{ nestedFile, topStruct };
    const tree = model.DocTree{ .moduleName = "myproject", .rootDocComment = null, .sections = &sections, .rootIsDir = true };

    const pages = try renderTestWrite(gpa, .html, tree, "myproject", options.Options{ .split = .none, .discover = .fs, .tree = true, .collapse = .dir });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    try std.testing.expectEqual(@as(usize, 1), pages.len);
    try std.testing.expect(std.mem.indexOf(u8, pages[0].contents, "<details><summary class=\"index-dir\">sub/</summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, pages[0].contents, "item-struct item-pub\"><span class=\"prefix\">pub struct</span> <a href=\"#Widget\">Widget</a>") != null);
}

test "discover ns, split none: --collapse dir collapses nothing, --collapse ns collapses the namespace root" {
    const gpa = std.testing.allocator;

    var tree = try buildImportGraphTree(gpa);
    defer tree.deinit(gpa);

    var testProgressDir: progress.Progress = .{};
    {
        const pages = try render.write(gpa, .html, tree, "test-project", options.Options{ .discover = .ns, .split = .none, .collapse = .dir }, template.htmlDoc, template.htmlSec, &testProgressDir);
        defer {
            for (pages) |*p| p.deinit(gpa);
            gpa.free(pages);
        }
        try std.testing.expectEqual(@as(usize, 1), pages.len);
        try std.testing.expect(std.mem.indexOf(u8, pages[0].contents, "<details>") == null);
    }

    var testProgressNs: progress.Progress = .{};
    {
        const pages = try render.write(gpa, .html, tree, "test-project", options.Options{ .discover = .ns, .split = .none, .collapse = .ns }, template.htmlDoc, template.htmlSec, &testProgressNs);
        defer {
            for (pages) |*p| p.deinit(gpa);
            gpa.free(pages);
        }
        try std.testing.expect(std.mem.indexOf(u8, pages[0].contents, "<summary><span><span class=\"prefix\">pub struct</span> import_graph_child</span></summary>") != null);
    }
}

test "discover ns, split none: --collapse top collapses only the outermost level" {
    const gpa = std.testing.allocator;

    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("nested.zig",
        \\pub const Outer = struct {
        \\    pub const Inner = struct {
        \\        pub fn leaf() void {}
        \\    };
        \\};
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "nested.zig", true, false, false, null);
    defer tree.deinit(gpa);
    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .html, tree, "test-project", options.Options{ .discover = .ns, .split = .none, .collapse = .top }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }
    try std.testing.expect(std.mem.indexOf(u8, pages[0].contents, "<details><summary><span><span class=\"prefix\">pub struct</span> Outer</span></summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, pages[0].contents, "<details><summary><span><span class=\"prefix\">pub struct</span> Inner</span></summary>") == null);
}

test "discover ns, split none: --collapse all collapses every depth, --collapse none collapses nothing" {
    // Uses its own fixture with genuine two-level same-file nesting to
    // test the all-vs-dir distinction.
    const gpa = std.testing.allocator;

    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("nested.zig",
        \\pub const Outer = struct {
        \\    pub const Inner = struct {
        \\        pub fn leaf() void {}
        \\    };
        \\};
        \\
    );

    var testProgressAll: progress.Progress = .{};
    {
        var tree = try imports.walkTree(gpa, fixture.reader(), "nested.zig", true, false, false, null);
        defer tree.deinit(gpa);
        const pages = try render.write(gpa, .html, tree, "test-project", options.Options{ .discover = .ns, .split = .none, .collapse = .all }, template.htmlDoc, template.htmlSec, &testProgressAll);
        defer {
            for (pages) |*p| p.deinit(gpa);
            gpa.free(pages);
        }
        // "Outer" nests "Inner" nests "leaf" — --collapse all wraps
        // every level, not just the outermost.
        try std.testing.expect(std.mem.indexOf(u8, pages[0].contents, "<details><summary><span><span class=\"prefix\">pub struct</span> Outer</span></summary>") != null);
        try std.testing.expect(std.mem.indexOf(u8, pages[0].contents, "<details><summary><span><span class=\"prefix\">pub struct</span> Inner</span></summary>") != null);
    }

    var testProgressNone: progress.Progress = .{};
    {
        var tree = try imports.walkTree(gpa, fixture.reader(), "nested.zig", true, false, false, null);
        defer tree.deinit(gpa);
        const pages = try render.write(gpa, .html, tree, "test-project", options.Options{ .discover = .ns, .split = .none, .collapse = .none }, template.htmlDoc, template.htmlSec, &testProgressNone);
        defer {
            for (pages) |*p| p.deinit(gpa);
            gpa.free(pages);
        }
        try std.testing.expect(std.mem.indexOf(u8, pages[0].contents, "<details>") == null);
    }
}

// ===========================================================================
// Link consistency matrix: renders fixtures across every meaningful
// --split/--discover/--collapse/--format combination and checks every
// href/anchor for existence and cross-page agreement.
// ===========================================================================

// Static link-consistency checker: every href must resolve to a real page,
// every #anchor must exist, and every link to the same decl must agree with
// every other link to it. Black-box — only reads the rendered HTML/Markdown.

const LinkFormat = enum { html, md };

// One href="..." (or Markdown ](...)), resolved against the page it was
// found on, plus context for error messages.
const FoundLink = struct {
    fromPage: []const u8,
    raw: []const u8,
    label: []const u8,
};

const LinkIssue = struct {
    fromPage: []const u8,
    raw: []const u8,
    label: []const u8,
    kind: enum { missing_page, missing_anchor, inconsistent_target },
    detail: []const u8,
};

// A .filename + .contents pair, format-agnostic.
const CheckPage = struct {
    filename: []const u8,
    contents: []const u8,
};

// Runs every check over `pages` and returns every issue found.
fn checkLinks(gpa: std.mem.Allocator, fmt: LinkFormat, pages: []const CheckPage) ![]LinkIssue {
    var issues: std.ArrayList(LinkIssue) = .empty;
    errdefer issues.deinit(gpa);

    const indexFilename: []const u8 = switch (fmt) {
        .html => "index.html",
        .md => "index.md",
    };

    var byFilename = std.StringHashMap(usize).init(gpa);
    defer byFilename.deinit();
    for (pages, 0..) |p, i| try byFilename.put(p.filename, i);

    // Decl identity here is the #anchor fragment, not link text (which
    // legitimately repeats in prose/signatures/nav without needing to
    // agree). Only anchored links are compared this way.
    var targetsByAnchor = std.StringHashMap(std.ArrayList(FoundLink)).init(gpa);
    defer {
        var it = targetsByAnchor.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        targetsByAnchor.deinit();
    }

    for (pages) |p| {
        const links = switch (fmt) {
            .html => try extractHtmlLinks(gpa, p.filename, p.contents),
            .md => try extractMdLinks(gpa, p.filename, p.contents),
        };
        defer gpa.free(links);

        for (links) |link| {
            try checkOneLink(gpa, &issues, byFilename, pages, link, indexFilename);

            if (isExternalLink(link.raw)) continue;
            const anchor = anchorOfLink(link.raw);
            if (anchor.len == 0) continue;

            const gop = try targetsByAnchor.getOrPut(anchor);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(gpa, link);
        }
    }

    // Cross-page agreement: every link sharing the same #anchor must
    // resolve to the same real page.
    var it = targetsByAnchor.iterator();
    while (it.next()) |entry| {
        const links = entry.value_ptr.items;
        if (links.len < 2) continue;
        const first = try resolvedLinkTarget(gpa, links[0], indexFilename);
        defer gpa.free(first);
        for (links[1..]) |other| {
            const resolved = try resolvedLinkTarget(gpa, other, indexFilename);
            defer gpa.free(resolved);
            if (!std.mem.eql(u8, first, resolved)) {
                const detail = try std.fmt.allocPrint(
                    gpa,
                    "anchor '#{s}' resolves to '{s}' from {s} but '{s}' from {s}",
                    .{ entry.key_ptr.*, first, links[0].fromPage, resolved, other.fromPage },
                );
                try issues.append(gpa, .{
                    .fromPage = other.fromPage,
                    .raw = other.raw,
                    .label = other.label,
                    .kind = .inconsistent_target,
                    .detail = detail,
                });
            }
        }
    }

    return issues.toOwnedSlice(gpa);
}

fn anchorOfLink(raw: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, raw, '#')) |i| return raw[i + 1 ..];
    return "";
}

fn checkOneLink(
    gpa: std.mem.Allocator,
    issues: *std.ArrayList(LinkIssue),
    byFilename: std.StringHashMap(usize),
    pages: []const CheckPage,
    link: FoundLink,
    indexFilename: []const u8,
) !void {
    if (isExternalLink(link.raw)) return;

    const resolved = try resolveLinkPath(gpa, link.fromPage, link.raw, indexFilename);
    defer gpa.free(resolved);
    const targetPage, const anchor = splitLinkAnchor(resolved);

    const idx = byFilename.get(targetPage) orelse {
        try issues.append(gpa, .{
            .fromPage = link.fromPage,
            .raw = link.raw,
            .label = link.label,
            .kind = .missing_page,
            .detail = try std.fmt.allocPrint(gpa, "no such page: '{s}'", .{targetPage}),
        });
        return;
    };

    if (anchor.len == 0) return;
    const target = pages[idx];
    if (!hasLinkAnchor(target.contents, anchor)) {
        try issues.append(gpa, .{
            .fromPage = link.fromPage,
            .raw = link.raw,
            .label = link.label,
            .kind = .missing_anchor,
            .detail = try std.fmt.allocPrint(gpa, "'{s}' has no anchor '{s}'", .{ targetPage, anchor }),
        });
    }
}

// Resolved, normalized "page#anchor" string a link ultimately points at —
// used only to compare two links for agreement, not displayed.
fn resolvedLinkTarget(gpa: std.mem.Allocator, link: FoundLink, indexFilename: []const u8) ![]u8 {
    if (isExternalLink(link.raw)) return gpa.dupe(u8, link.raw);
    return resolveLinkPath(gpa, link.fromPage, link.raw, indexFilename);
}

fn isExternalLink(raw: []const u8) bool {
    return std.mem.startsWith(u8, raw, "http://") or
        std.mem.startsWith(u8, raw, "https://") or
        std.mem.startsWith(u8, raw, "mailto:") or
        std.mem.startsWith(u8, raw, "data:");
}

// Resolves `raw` (relative to `fromPage`'s own directory, ../-aware) into a
// normalized "page#anchor" absolute path. `indexFilename` fills back in
// what --prettyurls strips: a bare directory means that directory's index page.
fn resolveLinkPath(gpa: std.mem.Allocator, fromPage: []const u8, raw: []const u8, indexFilename: []const u8) ![]u8 {
    if (raw.len > 0 and raw[0] == '#') {
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ fromPage, raw });
    }

    var dirEnd: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, fromPage, '/')) |i| dirEnd = i + 1;

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    if (dirEnd > 0) {
        var it = std.mem.splitScalar(u8, fromPage[0 .. dirEnd - 1], '/');
        while (it.next()) |seg| try parts.append(gpa, seg);
    }

    const anchor = anchorOfLink(raw);
    const pathPart = raw[0 .. raw.len - (if (anchor.len > 0) anchor.len + 1 else 0)];
    const endsWithSlash = pathPart.len > 0 and pathPart[pathPart.len - 1] == '/';

    var sawRealSegment = false;
    var it = std.mem.splitScalar(u8, pathPart, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) parts.items.len -= 1;
            continue;
        }
        try parts.append(gpa, seg);
        sawRealSegment = true;
    }
    // No real segment at all (blank, ".", or ".." chains) — that names
    // a directory, whose implied target is its own index page.
    if (!sawRealSegment or endsWithSlash) try parts.append(gpa, indexFilename);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (parts.items, 0..) |seg, i| {
        if (i > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, seg);
    }
    if (anchor.len > 0) {
        try out.append(gpa, '#');
        try out.appendSlice(gpa, anchor);
    }
    return out.toOwnedSlice(gpa);
}

fn splitLinkAnchor(pathAndAnchor: []u8) struct { []u8, []const u8 } {
    if (std.mem.indexOfScalar(u8, pathAndAnchor, '#')) |i| {
        return .{ pathAndAnchor[0..i], pathAndAnchor[i + 1 ..] };
    }
    return .{ pathAndAnchor, "" };
}

fn hasLinkAnchor(contents: []const u8, anchor: []const u8) bool {
    var buf: [256]u8 = undefined;
    if (anchor.len + 5 <= buf.len) {
        const needleId = std.fmt.bufPrint(&buf, "id=\"{s}\"", .{anchor}) catch return false;
        if (std.mem.indexOf(u8, contents, needleId) != null) return true;
    }
    // Markdown anchors are the heading's auto-generated slug, so a
    // plain substring search is the pragmatic fallback.
    return std.mem.indexOf(u8, contents, anchor) != null;
}

fn extractHtmlLinks(gpa: std.mem.Allocator, fromPage: []const u8, contents: []const u8) ![]FoundLink {
    var out: std.ArrayList(FoundLink) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, contents, i, "<a ")) |tagStart| {
        const tagEnd = std.mem.indexOfScalarPos(u8, contents, tagStart, '>') orelse break;
        const closeTag = tagEnd;

        const hrefKey = "href=\"";
        const hrefAt = std.mem.indexOfPos(u8, contents, tagStart, hrefKey);
        if (hrefAt == null or hrefAt.? > closeTag) {
            // No href on this tag — skip past it, not the next unrelated one.
            i = closeTag + 1;
            continue;
        }
        const valueStart = hrefAt.? + hrefKey.len;
        const valueEnd = std.mem.indexOfScalarPos(u8, contents, valueStart, '"') orelse break;
        const raw = contents[valueStart..valueEnd];

        const labelEnd = std.mem.indexOfPos(u8, contents, closeTag, "</a>") orelse closeTag;
        const label = std.mem.trim(u8, contents[closeTag + 1 .. labelEnd], " \t\r\n");

        try out.append(gpa, .{ .fromPage = fromPage, .raw = raw, .label = label });
        i = labelEnd + 1;
    }

    return out.toOwnedSlice(gpa);
}

fn extractMdLinks(gpa: std.mem.Allocator, fromPage: []const u8, contents: []const u8) ![]FoundLink {
    var out: std.ArrayList(FoundLink) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, contents, i, '[')) |labelStart| {
        const labelEnd = std.mem.indexOfScalarPos(u8, contents, labelStart, ']') orelse break;
        if (labelEnd + 1 >= contents.len or contents[labelEnd + 1] != '(') {
            i = labelStart + 1;
            continue;
        }
        const rawStart = labelEnd + 2;
        const rawEnd = std.mem.indexOfScalarPos(u8, contents, rawStart, ')') orelse break;

        const label = contents[labelStart + 1 .. labelEnd];
        const raw = contents[rawStart..rawEnd];
        try out.append(gpa, .{ .fromPage = fromPage, .raw = raw, .label = label });
        i = rawEnd + 1;
    }

    return out.toOwnedSlice(gpa);
}

const LinkMatrixFixtureBuilder = *const fn (gpa: std.mem.Allocator) anyerror!model.DocTree;

const linkMatrixFixtures = [_]struct { name: []const u8, build: LinkMatrixFixtureBuilder }{
    .{ .name = "generic_container", .build = buildGenericContainerTree },
    .{ .name = "import_graph", .build = buildImportGraphTree },
    .{ .name = "nested_containers", .build = buildNestedContainersTree },
};

const linkMatrixCases = [_]struct {
    split: options.Split,
    discover: options.Discover,
    collapse: options.Collapse,
}{
    .{ .split = .none, .discover = .fs, .collapse = .none },
    .{ .split = .none, .discover = .fs, .collapse = .dir },
    .{ .split = .none, .discover = .ns, .collapse = .none },
    .{ .split = .none, .discover = .ns, .collapse = .dir },
    .{ .split = .none, .discover = .ns, .collapse = .ns },
    .{ .split = .none, .discover = .ns, .collapse = .top },
    .{ .split = .none, .discover = .ns, .collapse = .all },
    .{ .split = .file, .discover = .ns, .collapse = .none },
    .{ .split = .file, .discover = .ns, .collapse = .dir },
    .{ .split = .file, .discover = .ns, .collapse = .ns },
    .{ .split = .file, .discover = .ns, .collapse = .top },
    .{ .split = .file, .discover = .ns, .collapse = .all },
    .{ .split = .item, .discover = .ns, .collapse = .none },
};

const linkMatrixFormats = [_]options.Format{ .html, .md };

// options.Format (CLI-facing) and render.Format are separate enums with
// the same two tags; every call site converts explicitly.
fn toRenderFormat(fmt: options.Format) render.Format {
    return switch (fmt) {
        .html => .html,
        .md => .md,
    };
}

fn runLinkMatrixCase(
    gpa: std.mem.Allocator,
    fixtureName: []const u8,
    build: LinkMatrixFixtureBuilder,
    fmt: options.Format,
    case: @TypeOf(linkMatrixCases[0]),
) !void {
    var tree = try build(gpa);
    defer tree.deinit(gpa);

    const opts = options.Options{
        .format = fmt,
        .split = case.split,
        .discover = case.discover,
        .collapse = case.collapse,
    };

    var testProgress: progress.Progress = .{};
    const tplDoc = if (fmt == .html) template.htmlDoc else template.mdDoc;
    const tplSec = if (fmt == .html) template.htmlSec else template.mdSec;
    const pages = render.write(gpa, toRenderFormat(fmt), tree, "test-project", opts, tplDoc, tplSec, &testProgress) catch |err| {
        std.debug.print(
            "render.write failed for fixture={s} format={s} split={s} discover={s} collapse={s}: {}\n",
            .{ fixtureName, @tagName(fmt), @tagName(case.split), @tagName(case.discover), @tagName(case.collapse), err },
        );
        return err;
    };
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var checkPages = try gpa.alloc(CheckPage, pages.len);
    defer gpa.free(checkPages);
    for (pages, 0..) |p, i| checkPages[i] = .{ .filename = p.filename, .contents = p.contents };

    const checkFmt: LinkFormat = if (fmt == .html) .html else .md;
    const issues = try checkLinks(gpa, checkFmt, checkPages);
    defer {
        for (issues) |issue| gpa.free(issue.detail);
        gpa.free(issues);
    }

    if (issues.len > 0) {
        std.debug.print(
            "\n{d} link issue(s) for fixture={s} format={s} split={s} discover={s} collapse={s}:\n",
            .{ issues.len, fixtureName, @tagName(fmt), @tagName(case.split), @tagName(case.discover), @tagName(case.collapse) },
        );
        for (issues) |issue| {
            std.debug.print("  [{s}] on {s}: link '{s}' -> '{s}': {s}\n", .{
                @tagName(issue.kind), issue.fromPage, issue.label, issue.raw, issue.detail,
            });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "link consistency matrix: every fixture x split x discover x collapse x format" {
    const gpa = std.testing.allocator;

    for (linkMatrixFixtures) |fx| {
        for (linkMatrixFormats) |fmt| {
            for (linkMatrixCases) |case| {
                // --source tab/--pagesource tab aside, .item split only
                // makes sense combined with per-decl pages regardless of
                // collapse (collapse only affects nested same-page
                // listings, and .item never nests more than one
                // collapse-relevant level in these fixtures) — still run
                // every collapse value anyway for uniformity; a cheap
                // no-op re-render either way.
                runLinkMatrixCase(gpa, fx.name, fx.build, fmt, case) catch |err| {
                    std.debug.print("failed case: fixture={s}\n", .{fx.name});
                    return err;
                };
            }
        }
    }
}

// ===========================================================================
// sources.zig tests -- moved here so every test in the project lives in
// this one file, per project convention.
// ===========================================================================

test "none mode emits nothing" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try sources.write(gpa, &aw.writer, "pub fn f() void {}", .none, false, null, 1);
    try std.testing.expectEqualStrings("", aw.written());
}

test "resizable mode escapes, highlights, and is resizable" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try sources.write(gpa, &aw.writer, "if (a < b) {}", .resizable, false, null, 1);
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "class=\"src-code resizable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "&lt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<span class=\"tok-id\">a</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<span class=\"tok-kw\">if</span>") != null);
}

test "resizable mode emits a matching line-number gutter" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try sources.write(gpa, &aw.writer, "const a = 1;\nconst b = 2;", .resizable, false, null, 1);
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "class=\"src-nums\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "class=\"src-txt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<span>1</span>\n<span>2</span>") != null);
}

test "raw mode escapes but does not highlight" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try sources.write(gpa, &aw.writer, "if (a < b) {}", .resizable, true, null, 1);
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "&lt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "tok-") == null);
}

test "collapsed mode wraps in details/summary" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try sources.write(gpa, &aw.writer, "x", .collapsed, false, null, 1);
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "<details") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "class=\"src-code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<span>1</span>") != null);
}

test "inline mode emits a src-code grid with numbers and text panes" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try sources.write(gpa, &aw.writer, "a;\nb;\nc;", .inline_, false, null, 1);
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "class=\"src-code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<span>1</span>\n<span>2</span>\n<span>3</span>") != null);
}

test "tab mode emits the same grid markup as inline" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try sources.write(gpa, &aw.writer, "a;\nb;\nc;", .tab, false, null, 1);
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "class=\"src-code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<span>1</span>\n<span>2</span>\n<span>3</span>") != null);
}

test "highlights a keyword, identifier, and comment" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try sources.writeTokens(&aw.writer, "pub fn add() void {} // sums\n");
    const out = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-kw\">pub</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-f\">add</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-c\">// sums</span>") != null);
}

test "highlights a string literal and escapes angle brackets" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try sources.writeTokens(&aw.writer, "const s = \"a < b\";");
    const out = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-str\">\"a &lt; b\"</span>") != null);
}

test "highlights a doc comment" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try sources.writeTokens(&aw.writer, "/// docs\npub fn f() void {}");
    const out = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-c\">/// docs</span>") != null);
}

// Resolves the token at byte offset 12 ("Widget" in the fixture below)
// to a fake href, ignoring token text — matching real CodelinkLookup usage.
fn testSourcesResolve(context: *const anyopaque, start: u32) ?sources.ResolvedSpan {
    _ = context;
    if (start == 12) return .{ .end = 18, .href = "widget.html" };
    return null;
}

test "writeTokensLinked links a resolvable identifier and underlines it" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var dummy: u8 = 0;
    const links = sources.LinkResolver{ .context = &dummy, .resolveFn = testSourcesResolve };
    try sources.writeTokensLinked(&aw.writer, "pub fn f(w: Widget) void {}", links);
    const out = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "<a class=\"tok-l\" href=\"widget.html\"><span class=\"tok-id\">Widget</span></a>") != null);
}

test "writeTokensLinked leaves an unresolvable identifier as plain highlighting" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var dummy: u8 = 0;
    const links = sources.LinkResolver{ .context = &dummy, .resolveFn = testSourcesResolve };
    // Different byte offset than "Widget" in the fixture above, so a
    // position-based resolver must tell them apart by position, not text.
    try sources.writeTokensLinked(&aw.writer, "pub fn foo(w: Gadget) void {}", links);
    const out = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-id\">Gadget</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tok-l") == null);
}

// Resolves the token at byte offset 19 (the `a.zig` content inside the
// string literal below, quotes excluded) to a fake href.
fn testSourcesResolveImportString(context: *const anyopaque, start: u32) ?sources.ResolvedSpan {
    _ = context;
    if (start == 19) return .{ .end = 24, .href = "a.html" };
    return null;
}

test "writeTokensLinked links a resolvable @import's filename string, and only that span" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var dummy: u8 = 0;
    const links = sources.LinkResolver{ .context = &dummy, .resolveFn = testSourcesResolveImportString };
    try sources.writeTokensLinked(&aw.writer, "const x = @import(\"a.zig\").Y;", links);
    const out = aw.written();

    const linkStart = std.mem.indexOf(u8, out, "<a class=\"tok-l\" href=\"a.html\">").?;
    const linkEnd = std.mem.indexOf(u8, out[linkStart..], "</a>").? + linkStart + "</a>".len;
    // The quotes stay plain text outside the `<a>`; only `a.zig` is linked.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"<a class=\"tok-l\" href=\"a.html\">a.zig</a>\"") != null);
    // `@import` precedes the link; the `.Y` suffix follows it — neither is inside the `<a>...</a>` itself.
    try std.testing.expect(std.mem.indexOf(u8, out[0..linkStart], "@import") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[linkStart..linkEnd], "@import") == null);
    try std.testing.expect(std.mem.indexOf(u8, out[linkEnd..], "tok-l") == null);
}

// Like `testSourcesResolveImportString`, but also resolves `.Y` (offset 27)
// to its own separate href, so a suffix segment's own link can be checked.
fn testSourcesResolveImportStringAndSuffix(context: *const anyopaque, start: u32) ?sources.ResolvedSpan {
    _ = context;
    if (start == 19) return .{ .end = 24, .href = "a.html" };
    if (start == 27) return .{ .end = 28, .href = "a.html#Y" };
    return null;
}

test "writeTokensLinked links a resolvable dotted suffix as its own separate link" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var dummy: u8 = 0;
    const links = sources.LinkResolver{ .context = &dummy, .resolveFn = testSourcesResolveImportStringAndSuffix };
    try sources.writeTokensLinked(&aw.writer, "const x = @import(\"a.zig\").Y;", links);
    const out = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "<a class=\"tok-l\" href=\"a.html\">a.zig</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<a class=\"tok-l\" href=\"a.html#Y\">") != null);
}

// Resolves to an `end` far past this fixture's own length — reproducing a
// target computed against a longer string (a decl's full `source`) being
// wrongly handed to a render of a shorter one (its `signature`).
fn testSourcesResolveOutOfBoundsEnd(context: *const anyopaque, start: u32) ?sources.ResolvedSpan {
    _ = context;
    if (start == 1) return .{ .end = 10_000, .href = "a.html" };
    return null;
}

test "writeTokensLinked clamps a resolved span whose end exceeds the string literal being rendered, instead of crashing" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var dummy: u8 = 0;
    const links = sources.LinkResolver{ .context = &dummy, .resolveFn = testSourcesResolveOutOfBoundsEnd };
    // Reaching this line without a panic is the actual assertion.
    try sources.writeTokensLinked(&aw.writer, "\"x\";", links);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "<a class=\"tok-l\" href=\"a.html\">") != null);
}

test "writeTokensLinked with null links behaves exactly like writeTokens" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try sources.writeTokensLinked(&aw.writer, "pub fn add() void {}", null);
    const out = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-f\">add</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tok-l") == null);
}

// ===========================================================================
// search.zig tests
// ===========================================================================

fn searchTestSection(kind: model.Kind, children: []model.Section) model.Section {
    return .{
        .name = "",
        .fileLabel = "",
        .path = "",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "",
        .sourceLine = 0,
        .kind = kind,
        .children = children,
        .hasChildren = children.len > 0,
    };
}

test "normalizeWhitespace collapses whitespace but keeps markdown syntax" {
    const gpa = std.testing.allocator;
    const out = try search.normalizeWhitespace(gpa, "# Title\n\nSee `code` and **bold** and [a link](https://example.com).\n");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("# Title See `code` and **bold** and [a link](https://example.com).", out);
}

test "buildIndex resolves split-item hrefs as page-only links (one page per decl)" {
    const gpa = std.testing.allocator;
    var opts = options.Options{ .split = .item, .index = true };
    opts.inputs = &.{};
    opts.filetypes = &.{};

    var bar = searchTestSection(.fn_decl, &.{});
    bar.name = "bar";
    bar.path = "Foo.bar";
    bar.docComment = "Does a thing.";

    var barArr = [_]model.Section{bar};
    var foo = searchTestSection(.const_decl, &barArr);
    foo.name = "Foo";
    foo.path = "Foo";
    foo.hasChildren = true;

    var fooArr = [_]model.Section{foo};
    var file = searchTestSection(.file, &fooArr);
    file.name = "example.zig";
    file.fileLabel = "example.zig";

    var fileArr = [_]model.Section{file};
    const tree = model.DocTree{ .sections = &fileArr, .moduleName = "example", .rootDocComment = null };
    const entries = try search.buildIndex(gpa, tree, opts);
    defer search.freeEntries(gpa, entries);

    // One entry per decl (file, Foo, bar), each its own page (no `#`
    // fragment — the whole page already is that decl), all distinct,
    // and `bar`'s doc comment carried through.
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    for (entries) |e| try std.testing.expect(std.mem.indexOfScalar(u8, e.href, '#') == null);
    try std.testing.expect(!std.mem.eql(u8, entries[0].href, entries[1].href));
    try std.testing.expect(!std.mem.eql(u8, entries[1].href, entries[2].href));
    try std.testing.expectEqualStrings("bar", entries[2].name);
    try std.testing.expectEqualStrings("Does a thing.", entries[2].text);
}

test "buildIndex resolves split-none hrefs as in-page anchors" {
    const gpa = std.testing.allocator;
    var opts = options.Options{ .split = .none, .index = true, .filename = "index.html" };
    opts.inputs = &.{};
    opts.filetypes = &.{};

    var top = searchTestSection(.fn_decl, &.{});
    top.name = "add";
    top.path = "add";
    top.docComment = "Adds two numbers.";

    var topArr = [_]model.Section{top};
    const tree = model.DocTree{ .sections = &topArr, .moduleName = "example", .rootDocComment = null };
    const entries = try search.buildIndex(gpa, tree, opts);
    defer search.freeEntries(gpa, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("add", entries[0].name);
    try std.testing.expect(std.mem.startsWith(u8, entries[0].href, "index.html#"));
}

test "toJs serializes entries as a window global and escapes special characters" {
    const gpa = std.testing.allocator;
    const entries = [_]search.Entry{
        .{ .name = try gpa.dupe(u8, "a\"b</script>"), .path = try gpa.dupe(u8, "a"), .href = try gpa.dupe(u8, "a.html"), .text = try gpa.dupe(u8, "line1\nline2") },
    };
    defer for (entries) |e| {
        gpa.free(e.name);
        gpa.free(e.path);
        gpa.free(e.href);
        gpa.free(e.text);
    };
    const js = try search.toJs(gpa, &entries);
    defer gpa.free(js);
    try std.testing.expect(std.mem.startsWith(u8, js, "window.ZDI = [\n"));
    // Only `<` needs escaping to defuse a literal `</script>` — that's
    // enough on its own, so `>` is left as a plain character.
    try std.testing.expect(std.mem.indexOf(u8, js, "\\\"b\\u003C/script>") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "line1\\nline2") != null);
}
// ===========================================================================
// walk.zig tests
// ===========================================================================

test "single file: namespace root, plain const alias" {
    const gpa = std.testing.allocator;
    var graph = walk.Graph.init(gpa);
    defer graph.deinit();

    const source: [:0]const u8 =
        \\pub const Value = 1;
        \\pub const Copy = Value;
        \\
    ;
    const fileIndex = try graph.addFile("root.zig", source);

    const rootDecl = fileIndex.findRootDecl(&graph);
    try std.testing.expect(rootDecl != .none);

    const rootCat = try rootDecl.get(&graph).categorize(&graph);
    try std.testing.expect(rootCat == .namespace);

    const copyDecl = (try rootDecl.get(&graph).getChild(&graph, "Copy")).?;
    const copyCat = try copyDecl.get(&graph).categorize(&graph);
    try std.testing.expect(copyCat == .alias);

    const resolved = try walk.Decl.resolveAliasIndex(copyDecl, &graph);
    const valueDecl = (try rootDecl.get(&graph).getChild(&graph, "Value")).?;
    try std.testing.expectEqual(valueDecl, resolved[0]);
}

test "single file: root with a field is a container, not a namespace" {
    const gpa = std.testing.allocator;
    var graph = walk.Graph.init(gpa);
    defer graph.deinit();

    // A file whose top level has a field isn't valid free-standing Zig
    // (fields are only valid inside a struct/union/enum literal), so
    // this exercises `categorizeDecl`'s `.root` branch using a nested
    // struct instead, matching how the real check (scanning for
    // container_field members) is actually exercised in practice.
    const source: [:0]const u8 =
        \\pub const Point = struct {
        \\    x: i32,
        \\};
        \\
    ;
    const fileIndex = try graph.addFile("root.zig", source);
    const rootDecl = fileIndex.findRootDecl(&graph);
    const pointDecl = (try rootDecl.get(&graph).getChild(&graph, "Point")).?;
    const pointCat = try pointDecl.get(&graph).categorize(&graph);
    try std.testing.expect(pointCat == .container);
}

test "cross-file: @import resolves to the target file's root decl" {
    const gpa = std.testing.allocator;
    var graph = walk.Graph.init(gpa);
    defer graph.deinit();

    const hashMapSource: [:0]const u8 =
        \\pub fn AutoHashMap() type {
        \\    return struct {};
        \\}
        \\
    ;
    _ = try graph.addFile("hash_map.zig", hashMapSource);

    const rootSource: [:0]const u8 =
        \\const hash_map = @import("hash_map.zig");
        \\pub const AutoHashMap = hash_map.AutoHashMap;
        \\
    ;
    const rootFile = try graph.addFile("root.zig", rootSource);
    const rootDecl = rootFile.findRootDecl(&graph);

    const aliasDecl = (try rootDecl.get(&graph).getChild(&graph, "AutoHashMap")).?;
    const resolved = try walk.Decl.resolveAliasIndex(aliasDecl, &graph);
    const resolvedDecl = resolved[0].get(&graph);
    const info = resolvedDecl.extraInfo(&graph);
    try std.testing.expectEqualStrings("AutoHashMap", info.name);

    // And it's specifically a type_function (a generic-type-returning
    // fn), not a plain function — since it returns `struct {}`.
    try std.testing.expect(resolved[1] == .typeFunction);
}

test "cross-file: import target not yet discovered falls back to globalConst" {
    const gpa = std.testing.allocator;
    var graph = walk.Graph.init(gpa);
    defer graph.deinit();

    // Deliberately never add "missing.zig" to the graph.
    const source: [:0]const u8 =
        \\pub const Thing = @import("missing.zig");
        \\
    ;
    const fileIndex = try graph.addFile("root.zig", source);
    const rootDecl = fileIndex.findRootDecl(&graph);
    const thingDecl = (try rootDecl.get(&graph).getChild(&graph, "Thing")).?;
    const cat = try thingDecl.get(&graph).categorize(&graph);
    try std.testing.expect(cat == .globalConst);
}

test "multi-segment dotted alias chain resolves through two hops" {
    const gpa = std.testing.allocator;
    var graph = walk.Graph.init(gpa);
    defer graph.deinit();

    const source: [:0]const u8 =
        \\pub const inner = struct {
        \\    pub const Deep = i32;
        \\};
        \\pub const mid = struct {
        \\    pub const inner_alias = inner;
        \\};
        \\pub const Reached = mid.inner_alias.Deep;
        \\
    ;
    const fileIndex = try graph.addFile("root.zig", source);
    const rootDecl = fileIndex.findRootDecl(&graph);
    const reachedDecl = (try rootDecl.get(&graph).getChild(&graph, "Reached")).?;
    const cat = try reachedDecl.get(&graph).categorize(&graph);
    // `Deep = i32` categorizes via categorizeExpr's `.identifier` case:
    // `i32` is a primitive type, so this resolves to `.alias` pointing
    // at `Deep` itself (not further, since alias-chasing stops once a
    // non-alias Category is reached) — confirms the two struct-member
    // hops (mid -> inner_alias -> inner -> Deep) resolved correctly
    // rather than falling back to globalConst.
    try std.testing.expect(cat == .alias);
}

test "children lists a namespace's direct members in source order" {
    const gpa = std.testing.allocator;
    var graph = walk.Graph.init(gpa);
    defer graph.deinit();

    const source: [:0]const u8 =
        \\pub const First = 1;
        \\pub const Second = 2;
        \\pub const Third = 3;
        \\
    ;
    const fileIndex = try graph.addFile("root.zig", source);
    const rootDecl = fileIndex.findRootDecl(&graph);
    const kids = try rootDecl.get(&graph).children(&graph, gpa);
    defer gpa.free(kids);

    try std.testing.expectEqual(@as(usize, 3), kids.len);
    try std.testing.expectEqualStrings("First", kids[0].get(&graph).extraInfo(&graph).name);
    try std.testing.expectEqualStrings("Second", kids[1].get(&graph).extraInfo(&graph).name);
    try std.testing.expectEqualStrings("Third", kids[2].get(&graph).extraInfo(&graph).name);
}

test "children transparently chases an alias to the target's own members" {
    const gpa = std.testing.allocator;
    var graph = walk.Graph.init(gpa);
    defer graph.deinit();

    _ = try graph.addFile("target.zig",
        \\pub const A = 1;
        \\pub const B = 2;
        \\
    );
    const rootFile = try graph.addFile("root.zig",
        \\pub const redirected = @import("target.zig");
        \\
    );
    const rootDecl = rootFile.findRootDecl(&graph);
    const aliasDecl = (try rootDecl.get(&graph).getChild(&graph, "redirected")).?;
    const kids = try aliasDecl.get(&graph).children(&graph, gpa);
    defer gpa.free(kids);

    try std.testing.expectEqual(@as(usize, 2), kids.len);
    try std.testing.expectEqualStrings("A", kids[0].get(&graph).extraInfo(&graph).name);
}
// ===========================================================================
// template.zig tests
// ===========================================================================

test "render substitutes known variables and leaves unknown ones verbatim" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "<h1>{title}</h1>{unknown}", &.{
        .{ .name = "title", .value = "Hello" },
    }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("<h1>Hello</h1>{unknown}", out);
}

test "render passes through a lone unmatched '{' without a closing brace" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "a { b", &.{}, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a { b", out);
}

test "render handles a variable used multiple times" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "{x}-{x}", &.{
        .{ .name = "x", .value = "42" },
    }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("42-42", out);
}

test "render leaves empty-brace and malformed spans untouched" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "{}{ }{{x}}", &.{
        .{ .name = "x", .value = "V" },
    }, null);
    defer gpa.free(out);
    // "{}" and "{ }" match no var name, left verbatim. "{{x}}" is
    // "{" + "{x}" + "}" — the inner "{x}" substitutes, the outer
    // braces are unmatched literal text.
    try std.testing.expectEqualStrings("{}{ }{V}", out);
}

test "render applies a format attribute, wrapping the raw value" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "{x format=\"<b>{x}</b>\"}", &.{
        .{ .name = "x", .value = "hi" },
    }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("<b>hi</b>", out);
}

test "render with format attribute produces nothing for an empty value" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "before{x format=\"<b>{x}</b>\"}after", &.{
        .{ .name = "x", .value = "" },
    }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("beforeafter", out);
}

test "render allows a format string with other variables inside" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "{crumb format=\"<nav>{crumb}{title}</nav>\"}", &.{
        .{ .name = "crumb", .value = "Home" },
        .{ .name = "title", .value = "Page" },
    }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("<nav>HomePage</nav>", out);
}

test "render unescapes \\n in a format string to a literal newline" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "{x format=\"## {x}\\n\"}after", &.{
        .{ .name = "x", .value = "Heading" },
    }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("## Heading\nafter", out);
}

test "render with padBlock pads a bare substitution but not a format-string one" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "**{crumb format=\"{crumb}{title}\"}**\\n{title}", &.{
        .{ .name = "crumb", .value = "Home > " },
        .{ .name = "title", .value = "Page" },
    }, template.padMdBlock);
    defer gpa.free(out);
    // Inside the format string neither {crumb} nor {title} gets
    // padded, so the bold span stays intact. The bare {title} at the
    // end is a top-level slot and does get a trailing newline.
    try std.testing.expectEqualStrings("**Home > Page**\nPage\n", out);
}

test "render with padBlock leaves an already-newline-terminated value alone" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "{x}after", &.{
        .{ .name = "x", .value = "line\n" },
    }, template.padMdBlock);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("line\nafter", out);
}

test "render with padBlock produces nothing for an empty bare value" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "before{x}after", &.{
        .{ .name = "x", .value = "" },
    }, template.padMdBlock);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("beforeafter", out);
}

test "render with padBlock strips literal newlines from the template source" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "before\n{x}\nafter", &.{
        .{ .name = "x", .value = "mid" },
    }, template.padMdBlock);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("beforemid\nafter", out);
}

test "render with padBlock turns an escaped \\n in the template source into a real newline" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "before\\n{x}after", &.{
        .{ .name = "x", .value = "mid" },
    }, template.padMdBlock);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("before\nmid\nafter", out);
}

test "render with padBlock leaves a format string's own \\n escape untouched by newline stripping" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "{x format=\"a\\n{x}\"}", &.{
        .{ .name = "x", .value = "mid" },
    }, template.padMdBlock);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a\nmid", out);
}

test "render without padBlock (HTML) leaves literal template newlines alone" {
    const gpa = std.testing.allocator;
    const out = try template.render(gpa, "before\n{x}\nafter", &.{
        .{ .name = "x", .value = "mid" },
    }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("before\nmid\nafter", out);
}
test "resolveCodelinksForDecl: same-file container member resolves" {
    const gpa = std.testing.allocator;
    var frames = [_]codelinks.ScopeFrame{undefined};
    var bindings = std.StringHashMap(codelinks.BoundName).init(gpa);
    defer bindings.deinit();
    try bindings.put("helper", .{ .binding = .{ .sameFile = "root.helper" }, .declStart = null, .declEnd = null });
    frames[0] = .{ .start = 0, .end = 100, .bindings = bindings };

    const source: [:0]const u8 = "pub fn run() void { helper(); }";
    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);

    const result = try codelinks.resolveCodelinksForDecl(gpa, tree, 0, @intCast(source.len), &frames);
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), result.resolved.len);
    try std.testing.expectEqualStrings("root.helper", result.resolved[0].targetPath);
    try std.testing.expectEqual(@as(usize, 0), result.pending.len);
}

test "resolveCodelinksForDecl: import-rooted reference is pending, with full dotted suffix" {
    const gpa = std.testing.allocator;
    var frames = [_]codelinks.ScopeFrame{undefined};
    var bindings = std.StringHashMap(codelinks.BoundName).init(gpa);
    defer bindings.deinit();
    try bindings.put("std", .{ .binding = .{ .import = "std" }, .declStart = null, .declEnd = null });
    frames[0] = .{ .start = 0, .end = 100, .bindings = bindings };

    const source: [:0]const u8 = "pub fn run() void { std.Deque.bufferIndex(); }";
    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);

    const result = try codelinks.resolveCodelinksForDecl(gpa, tree, 0, @intCast(source.len), &frames);
    defer result.deinit(gpa);

    // `std`, `std.Deque`, and `std.Deque.bufferIndex` each get their own,
    // independently resolvable pending target.
    try std.testing.expectEqual(@as(usize, 0), result.resolved.len);
    try std.testing.expectEqual(@as(usize, 3), result.pending.len);
    try std.testing.expectEqualStrings("std", result.pending[0].importTarget);
    try std.testing.expectEqualStrings("", result.pending[0].remainingPath);
    try std.testing.expectEqualStrings("std", result.pending[1].importTarget);
    try std.testing.expectEqualStrings("Deque", result.pending[1].remainingPath);
    try std.testing.expectEqualStrings("std", result.pending[2].importTarget);
    try std.testing.expectEqualStrings("Deque.bufferIndex", result.pending[2].remainingPath);
}

test "resolveCodelinksForDecl: inner scope shadows outer binding of the same name" {
    const gpa = std.testing.allocator;
    var outerBindings = std.StringHashMap(codelinks.BoundName).init(gpa);
    defer outerBindings.deinit();
    try outerBindings.put("std", .{ .binding = .{ .import = "std" }, .declStart = null, .declEnd = null });

    var innerBindings = std.StringHashMap(codelinks.BoundName).init(gpa);
    defer innerBindings.deinit();
    try innerBindings.put("std", .{ .binding = .{ .sameFile = "root.shadow.std" }, .declStart = null, .declEnd = null });

    const source: [:0]const u8 = "pub fn run() void { std.foo(); }";
    var frames = [_]codelinks.ScopeFrame{
        .{ .start = 0, .end = @intCast(source.len), .bindings = outerBindings },
        .{ .start = 0, .end = @intCast(source.len), .bindings = innerBindings },
    };

    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);

    const result = try codelinks.resolveCodelinksForDecl(gpa, tree, 0, @intCast(source.len), &frames);
    defer result.deinit(gpa);

    // Innermost frame's binding (a same-file decl) wins over the
    // outer import binding of the same name — this is the exact
    // collision class (`std` shadowed by a local of the same name)
    // that motivated moving resolution here in the first place.
    // `std` and `std.foo` each get their own resolved target.
    try std.testing.expectEqual(@as(usize, 2), result.resolved.len);
    try std.testing.expectEqualStrings("root.shadow.std", result.resolved[0].targetPath);
    try std.testing.expectEqualStrings("root.shadow.std.foo", result.resolved[1].targetPath);
    try std.testing.expectEqual(@as(usize, 0), result.pending.len);
}

test "resolveCodelinksForDecl: unresolvable identifier is left unlinked" {
    const gpa = std.testing.allocator;
    var frames = [_]codelinks.ScopeFrame{undefined};
    var bindings = std.StringHashMap(codelinks.BoundName).init(gpa);
    defer bindings.deinit();
    frames[0] = .{ .start = 0, .end = 100, .bindings = bindings };

    const source: [:0]const u8 = "pub fn run() void { unknownThing(); }";
    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);

    const result = try codelinks.resolveCodelinksForDecl(gpa, tree, 0, @intCast(source.len), &frames);
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.resolved.len);
    try std.testing.expectEqual(@as(usize, 0), result.pending.len);
}

test "resolveCodelinksForDecl: a binding's own declaration-name token is never linked to itself" {
    const gpa = std.testing.allocator;
    // `const helper = ...;` — "helper"'s own name token starts at
    // byte 6 (after "const "), 6 bytes long.
    const source: [:0]const u8 = "const helper = 1; const x = helper;";
    const declNameStart: u32 = 6;
    const declNameEnd: u32 = 12; // "helper".len == 6

    var bindings = std.StringHashMap(codelinks.BoundName).init(gpa);
    defer bindings.deinit();
    try bindings.put("helper", .{
        .binding = .{ .sameFile = "root.helper" },
        .declStart = declNameStart,
        .declEnd = declNameEnd,
    });
    var frames = [_]codelinks.ScopeFrame{.{ .start = 0, .end = @intCast(source.len), .bindings = bindings }};

    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);

    const result = try codelinks.resolveCodelinksForDecl(gpa, tree, 0, @intCast(source.len), &frames);
    defer result.deinit(gpa);

    // Only the *second* occurrence of "helper" (the reference, not
    // the declaration site) should resolve.
    try std.testing.expectEqual(@as(usize, 1), result.resolved.len);
    try std.testing.expect(result.resolved[0].start != declNameStart);
}

test "buildFileScopes: end-to-end — import, container member, and fn param all resolve or shadow correctly" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\pub const Widget = struct {
        \\    pub fn make(std: u8) u8 {
        \\        return std + 1;
        \\    }
        \\};
        \\pub fn useWidget() void {
        \\    std.debug.print("{}", .{Widget.make(1)});
        \\}
        \\
    ;

    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);

    var frames: std.ArrayList(codelinks.ScopeFrame) = .empty;
    defer codelinks.freeScopeFrames(gpa, &frames);

    try codelinks.buildFileScopes(gpa, tree, tree.rootDecls(), "root", 0, @intCast(tree.source.len), &frames);

    // `useWidget`'s body: `std` is the file-level import (no shadow in
    // this function), so `std.debug.print` should be pending under
    // the `std` import — but `Widget.make(1)` is a same-file
    // reference to `Widget`. We only assert the shadowing/import
    // split via the frames themselves here (resolveCodelinksForDecl
    // is exercised separately above); this test's job is to confirm
    // `buildFileScopes` actually produced the right frame shape.
    var sawFileLevelStdImport = false;
    var sawWidgetContainerMember = false;
    var sawMakeParamShadowsStd = false;
    for (frames.items) |frame| {
        if (frame.bindings.get("std")) |bound| {
            switch (bound.binding) {
                .import => |t| if (std.mem.eql(u8, t, "std")) {
                    sawFileLevelStdImport = true;
                },
                .sameFile => |p| if (p.len == 0) {
                    sawMakeParamShadowsStd = true;
                },
            }
        }
        if (frame.bindings.get("Widget")) |bound| {
            switch (bound.binding) {
                .sameFile => |p| if (std.mem.eql(u8, p, "root.Widget")) {
                    sawWidgetContainerMember = true;
                },
                else => {},
            }
        }
    }

    try std.testing.expect(sawFileLevelStdImport);
    try std.testing.expect(sawWidgetContainerMember);
    try std.testing.expect(sawMakeParamShadowsStd);
}

test "buildFileScopes: a function body's own local const import resolves a dotted reference in that same body" {
    const gpa = std.testing.allocator;
    // The exact shape reported against std.ArrayList: a type function
    // whose body imports a backing module as a local (not file-level)
    // `const`, then references a member of it through that local.
    const source: [:0]const u8 =
        \\pub fn ArrayList(comptime T: type) type {
        \\    const array_list = @import("array_list.zig");
        \\    return array_list.Aligned(T, null);
        \\}
        \\
    ;

    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);

    var frames: std.ArrayList(codelinks.ScopeFrame) = .empty;
    defer codelinks.freeScopeFrames(gpa, &frames);

    try codelinks.buildFileScopes(gpa, tree, tree.rootDecls(), "root", 0, @intCast(tree.source.len), &frames);

    var sawLocalImport = false;
    for (frames.items) |frame| {
        if (frame.bindings.get("array_list")) |bound| {
            switch (bound.binding) {
                .import => |t| if (std.mem.eql(u8, t, "array_list.zig")) {
                    sawLocalImport = true;
                },
                else => {},
            }
        }
    }
    try std.testing.expect(sawLocalImport);

    // And the reference inside the body actually resolves through it,
    // end to end via resolveCodelinksForDecl — not just present in the
    // frame's own bindings table.
    const result = try codelinks.resolveCodelinksForDecl(gpa, tree, 0, @intCast(source.len), frames.items);
    defer result.deinit(gpa);

    var sawPendingAligned = false;
    for (result.pending) |p| {
        if (std.mem.eql(u8, p.importTarget, "array_list.zig") and std.mem.eql(u8, p.remainingPath, "Aligned")) {
            sawPendingAligned = true;
        }
    }
    try std.testing.expect(sawPendingAligned);
}

test "render.resolvePendingCodelinks: a dotted reference through an @import resolves to the imported file's real decl" {
    const gpa = std.testing.allocator;

    // Plain multi-file extraction (no `--discover`): unlike the import-graph
    // walk, this never resolves a decl's own cross-file aliasing up front,
    // so `Allocator`'s `mem.Allocator` reference genuinely stays pending
    // until `resolvePendingCodelinks` runs — the actual path this bug was in.
    const rootTree = try extract.extractFile(gpa, "codelink_import_root", "codelink_import_root.zig", codelinkImportRoot, true, false, false);
    const leafTree = try extract.extractFile(gpa, "codelink_import_leaf", "codelink_import_leaf.zig", codelinkImportLeaf, true, false, false);
    var trees = [_]model.DocTree{ rootTree, leafTree };
    const labels = [_][]const u8{ "codelink_import_root.zig", "codelink_import_leaf.zig" };
    var merged = try model.mergeTrees(gpa, "combined", &trees, .{ .fileLabels = &labels, .showExt = true, .showDirPrefix = true });
    defer merged.deinit(gpa);

    const rootFile = findSection(merged.sections, "codelink_import_root.zig").?;
    const rootAllocator = findSection(rootFile.children, "Allocator").?;
    try std.testing.expect(rootAllocator.signature.len > 0);
    // `mem` itself and `mem.Allocator` each get their own pending target.
    try std.testing.expectEqual(@as(usize, 2), rootAllocator.pendingCodelinkTargets.len);
    try std.testing.expectEqualStrings("codelink_import_leaf.zig", rootAllocator.pendingCodelinkTargets[0].importTarget);
    try std.testing.expectEqualStrings("", rootAllocator.pendingCodelinkTargets[0].remainingPath);
    try std.testing.expectEqualStrings("codelink_import_leaf.zig", rootAllocator.pendingCodelinkTargets[1].importTarget);
    try std.testing.expectEqualStrings("Allocator", rootAllocator.pendingCodelinkTargets[1].remainingPath);
    try std.testing.expectEqual(@as(usize, 0), rootAllocator.codelinkTargets.len);

    const leafFile = findSection(merged.sections, "codelink_import_leaf.zig").?;
    const leafAllocator = findSection(leafFile.children, "Allocator").?;

    var virtualRoot: model.Section = undefined;
    var fileRoots = try render.buildFileRootIndex(gpa, merged, &virtualRoot);
    defer fileRoots.deinit();
    try render.resolvePendingCodelinks(gpa, merged.sections, &fileRoots);

    // Re-find: `resolvePendingCodelinks` mutated the tree in place, so the
    // struct copies above are stale.
    const resolvedFile = findSection(merged.sections, "codelink_import_root.zig").?;
    const resolved = findSection(resolvedFile.children, "Allocator").?;
    try std.testing.expectEqual(@as(usize, 2), resolved.codelinkTargets.len);
    try std.testing.expectEqualStrings(leafFile.path, resolved.codelinkTargets[0].targetPath);
    try std.testing.expectEqual(rootAllocator.pendingCodelinkTargets[0].start, resolved.codelinkTargets[0].start);
    try std.testing.expectEqual(rootAllocator.pendingCodelinkTargets[0].end, resolved.codelinkTargets[0].end);
    try std.testing.expectEqualStrings(leafAllocator.path, resolved.codelinkTargets[1].targetPath);
    try std.testing.expectEqual(rootAllocator.pendingCodelinkTargets[1].start, resolved.codelinkTargets[1].start);
    try std.testing.expectEqual(rootAllocator.pendingCodelinkTargets[1].end, resolved.codelinkTargets[1].end);
}

test "resolveCodelinksForDecl: a same-file dotted reference (Namespace.Member) links both the namespace and the member separately" {
    const gpa = std.testing.allocator;

    const source: [:0]const u8 =
        \\pub const Namespace = struct {
        \\    pub const Member = struct {};
        \\};
        \\pub fn use() type {
        \\    return Namespace.Member;
        \\}
    ;
    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);

    var frames: std.ArrayList(codelinks.ScopeFrame) = .empty;
    defer codelinks.freeScopeFrames(gpa, &frames);

    try codelinks.buildFileScopes(gpa, tree, tree.rootDecls(), "root", 0, @intCast(tree.source.len), &frames);

    const result = try codelinks.resolveCodelinksForDecl(gpa, tree, 0, @intCast(source.len), frames.items);
    defer result.deinit(gpa);

    var sawNamespace = false;
    var sawMember = false;
    for (result.resolved) |r| {
        if (std.mem.eql(u8, r.targetPath, "root.Namespace")) sawNamespace = true;
        if (std.mem.eql(u8, r.targetPath, "root.Namespace.Member")) sawMember = true;
    }
    try std.testing.expect(sawNamespace);
    try std.testing.expect(sawMember);
}

test "resolveCodelinksForDecl: a `void` return type does not resolve as a same-file reference" {
    const gpa = std.testing.allocator;

    const source: [:0]const u8 =
        \\pub const Tz = struct {
        \\    pub fn deinit(self: *Tz) void {
        \\        _ = self;
        \\    }
        \\};
    ;
    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);

    var frames: std.ArrayList(codelinks.ScopeFrame) = .empty;
    defer codelinks.freeScopeFrames(gpa, &frames);

    try codelinks.buildFileScopes(gpa, tree, tree.rootDecls(), "root", 0, @intCast(tree.source.len), &frames);

    const voidStart = std.mem.indexOf(u8, source, "void").?;
    const result = try codelinks.resolveCodelinksForDecl(gpa, tree, 0, @intCast(source.len), frames.items);
    defer result.deinit(gpa);

    for (result.resolved) |r| {
        try std.testing.expect(r.start != voidStart);
    }
}

test "render.write: a `void` return type in a method's signature is never linked, even with a same-file import alias chain and a same-named struct in scope" {
    const gpa = std.testing.allocator;

    const rootTree = try extract.extractFile(gpa, "codelink_void_root", "codelink_void_root.zig", codelinkVoidRoot, true, false, false);
    const stdTree = try extract.extractFile(gpa, "codelink_void_std", "codelink_void_std.zig", codelinkVoidStd, true, false, false);
    const memTree = try extract.extractFile(gpa, "codelink_void_mem", "codelink_void_mem.zig", codelinkVoidMem, true, false, false);
    var trees = [_]model.DocTree{ rootTree, stdTree, memTree };
    const labels = [_][]const u8{ "codelink_void_root.zig", "codelink_void_std.zig", "codelink_void_mem.zig" };
    var merged = try model.mergeTrees(gpa, "combined", &trees, .{ .fileLabels = &labels, .showExt = true, .showDirPrefix = true });
    merged.rootIsDir = true;
    defer merged.deinit(gpa);

    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .html, merged, "test-project", options.Options{ .split = .item, .tree = false, .pageSource = .collapsed }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var deinitPage: ?[]const u8 = null;
    for (pages) |p| {
        if (std.mem.indexOf(u8, p.filename, "deinit") != null) deinitPage = p.contents;
    }
    try std.testing.expect(deinitPage != null);

    const sigStart = std.mem.indexOf(u8, deinitPage.?, "<code>") orelse {
        std.debug.print("DEBUG no <code> found in deinitPage:\n{s}\n", .{deinitPage.?});
        try std.testing.expect(false);
        return;
    };
    const sigEnd = (std.mem.indexOf(u8, deinitPage.?[sigStart..], "</code>") orelse {
        std.debug.print("DEBUG no </code> found in deinitPage:\n{s}\n", .{deinitPage.?});
        try std.testing.expect(false);
        return;
    }) + sigStart;
    const sig = deinitPage.?[sigStart..sigEnd];
    // `Tz` in `*Tz` is expected to link; `void` right after it must not —
    // i.e. `void` never appears as the content of an `<a>`.
    try std.testing.expect(std.mem.indexOf(u8, sig, "tok-type\">void</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sig, "\">void</span></a>") == null);
}

test "resolveCodelinksForDecl: an @import(...) nested inside a decl's body, not just its top-level value, is still captured" {
    const gpa = std.testing.allocator;

    const source: [:0]const u8 =
        \\pub fn load() type {
        \\    return @import("nested_target.zig").Thing;
        \\}
    ;
    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);

    var frames: std.ArrayList(codelinks.ScopeFrame) = .empty;
    defer codelinks.freeScopeFrames(gpa, &frames);

    try codelinks.buildFileScopes(gpa, tree, tree.rootDecls(), "root", 0, @intCast(tree.source.len), &frames);

    const result = try codelinks.resolveCodelinksForDecl(gpa, tree, 0, @intCast(source.len), frames.items);
    defer result.deinit(gpa);

    var sawFile = false;
    var sawSegment = false;
    for (result.pending) |p| {
        if (std.mem.eql(u8, p.importTarget, "nested_target.zig") and p.remainingPath.len == 0) sawFile = true;
        if (std.mem.eql(u8, p.importTarget, "nested_target.zig") and std.mem.eql(u8, p.remainingPath, "Thing")) sawSegment = true;
    }
    try std.testing.expect(sawFile);
    try std.testing.expect(sawSegment);
}

test "extractFile: a whole-file re-export (`pub const X = @import(...);`, no dotted suffix) is captured as a whole-file pending codelink" {
    const gpa = std.testing.allocator;

    var tree = try extract.extractFile(gpa, "codelink_wholefile_root", "codelink_wholefile_root.zig", codelinkWholefileRoot, true, false, false);
    defer tree.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), tree.filePendingCodelinkTargets.len);
    try std.testing.expectEqualStrings("codelink_wholefile_leaf.zig", tree.filePendingCodelinkTargets[0].importTarget);
    try std.testing.expectEqualStrings("", tree.filePendingCodelinkTargets[0].remainingPath);
    try std.testing.expectEqual(@as(usize, 0), tree.fileCodelinkTargets.len);
}

test "render.write: a file's own page-source pane links a whole-file `@import` re-export to the imported file's page" {
    const gpa = std.testing.allocator;

    const rootTree = try extract.extractFile(gpa, "codelink_wholefile_root", "codelink_wholefile_root.zig", codelinkWholefileRoot, true, false, false);
    const leafTree = try extract.extractFile(gpa, "codelink_wholefile_leaf", "codelink_wholefile_leaf.zig", codelinkWholefileLeaf, true, false, false);
    var trees = [_]model.DocTree{ rootTree, leafTree };
    const labels = [_][]const u8{ "codelink_wholefile_root.zig", "codelink_wholefile_leaf.zig" };
    var merged = try model.mergeTrees(gpa, "combined", &trees, .{ .fileLabels = &labels, .showExt = true, .showDirPrefix = true });
    merged.rootIsDir = true;
    defer merged.deinit(gpa);

    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .html, merged, "test-project", options.Options{ .split = .file, .tree = false, .pageSource = .collapsed }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var rootPage: ?[]const u8 = null;
    for (pages) |p| {
        if (std.mem.indexOf(u8, p.filename, "codelink_wholefile_root") != null) rootPage = p.contents;
    }
    try std.testing.expect(rootPage != null);

    // The whole-file source pane should link the `Leaf` decl's `@import(...)`
    // filename string to the leaf file's own page — `@import` and the
    // surrounding quotes stay plain text, outside the `<a>`.
    const srcPaneStart = std.mem.indexOf(u8, rootPage.?, "src-txt") orelse {
        try std.testing.expect(false);
        return;
    };
    const srcPane = rootPage.?[srcPaneStart..];
    try std.testing.expect(std.mem.indexOf(u8, srcPane, "@import") != null);
    const wantLink = std.mem.indexOf(u8, srcPane, "\">codelink_wholefile_leaf.zig</a>") != null;
    try std.testing.expect(wantLink);
    try std.testing.expect(std.mem.indexOf(u8, srcPane, "\"codelink_wholefile_leaf.zig\"") == null);
}

test "render.write: a plain filename mention in a comment or free-text string links to that file's own page, without swallowing punctuation or quotes" {
    const gpa = std.testing.allocator;

    const rootTree = try extract.extractFile(gpa, "codelink_mention_root", "codelink_mention_root.zig", codelinkMentionRoot, true, false, false);
    const targetTree = try extract.extractFile(gpa, "codelink_mention_target", "codelink_mention_target.zig", codelinkMentionTarget, true, false, false);
    var trees = [_]model.DocTree{ rootTree, targetTree };
    const labels = [_][]const u8{ "codelink_mention_root.zig", "codelink_mention_target.zig" };
    var merged = try model.mergeTrees(gpa, "combined", &trees, .{ .fileLabels = &labels, .showExt = true, .showDirPrefix = true });
    merged.rootIsDir = true;
    defer merged.deinit(gpa);

    var testProgress: progress.Progress = .{};
    const pages = try render.write(gpa, .html, merged, "test-project", options.Options{ .split = .file, .tree = false, .pageSource = .collapsed }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var rootPage: ?[]const u8 = null;
    for (pages) |p| {
        if (std.mem.indexOf(u8, p.filename, "codelink_mention_root") != null) rootPage = p.contents;
    }
    try std.testing.expect(rootPage != null);
    const srcPaneStart = std.mem.indexOf(u8, rootPage.?, "src-txt") orelse {
        try std.testing.expect(false);
        return;
    };
    const srcPane = rootPage.?[srcPaneStart..];

    // In the `//!` comment: "See codelink_mention_target.zig for the
    // implementation." — linked exactly, trailing period excluded.
    try std.testing.expect(std.mem.indexOf(u8, srcPane, "\">codelink_mention_target.zig</a> for") != null);

    // Inside a plain string literal, not an `@import` call: "consult
    // codelink_mention_target.zig for details" — linked, quotes untouched.
    try std.testing.expect(std.mem.indexOf(u8, srcPane, "\">codelink_mention_target.zig</a> for details") != null);
    try std.testing.expect(std.mem.indexOf(u8, srcPane, "\"consult ") != null);
}

test "render.write: a mentionTarget stays out of signature rendering, even when its offset would fall inside a much shorter signature by coincidence" {
    const gpa = std.testing.allocator;

    const rootTree = try extract.extractFile(gpa, "codelink_mention_signature_crash", "codelink_mention_signature_crash.zig", codelinkMentionSignatureCrash, true, false, false);
    const targetTree = try extract.extractFile(gpa, "codelink_mention_target", "codelink_mention_target.zig", codelinkMentionTarget, true, false, false);
    var trees = [_]model.DocTree{ rootTree, targetTree };
    const labels = [_][]const u8{ "codelink_mention_signature_crash.zig", "codelink_mention_target.zig" };
    var merged = try model.mergeTrees(gpa, "combined", &trees, .{ .fileLabels = &labels, .showExt = true, .showDirPrefix = true });
    merged.rootIsDir = true;
    defer merged.deinit(gpa);

    var testProgress: progress.Progress = .{};
    // `--show all --pagesource collapsed` is exactly the reported crashing
    // combination: signatures are rendered (`.item` split, not just source).
    const pages = try render.write(gpa, .html, merged, "test-project", options.Options{ .split = .item, .tree = false, .pageSource = .collapsed }, template.htmlDoc, template.htmlSec, &testProgress);
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    // Reaching this point without a panic is the actual assertion — a
    // `mentionTargets` entry with an out-of-range offset for `signature`
    // used to crash `writeTokensLinked`/`writeLinkedRun` here.
    try std.testing.expect(pages.len > 0);
}

test "render.resolvePendingCodelinks: a dotted reference chases through bare re-exports across flat, non-hierarchical file paths" {
    const gpa = std.testing.allocator;

    // Mirrors real `--discover fs` output: every file's own `.path` is
    // just its basename, unrelated to directory or import structure —
    // so `std.mem.Allocator` can only be resolved by actually walking
    // the chain (root -> mem -> Allocator, hopping through two bare
    // re-exports), never by composing a dotted path string.
    const stdTree = try extract.extractFile(gpa, "codelink_chain_std", "codelink_chain_std.zig", codelinkChainStd, true, false, false);
    const memTree = try extract.extractFile(gpa, "codelink_chain_mem", "codelink_chain_mem.zig", codelinkChainMem, true, false, false);
    const allocatorTree = try extract.extractFile(gpa, "codelink_chain_allocator", "codelink_chain_allocator.zig", codelinkChainAllocator, true, false, false);
    const userTree = try extract.extractFile(gpa, "codelink_chain_user", "codelink_chain_user.zig", codelinkChainUser, true, false, false);
    var trees = [_]model.DocTree{ stdTree, memTree, allocatorTree, userTree };
    const labels = [_][]const u8{ "codelink_chain_std.zig", "codelink_chain_mem.zig", "codelink_chain_allocator.zig", "codelink_chain_user.zig" };
    var merged = try model.mergeTrees(gpa, "combined", &trees, .{ .fileLabels = &labels, .showExt = true, .showDirPrefix = true });
    defer merged.deinit(gpa);

    // Confirm the flat-path premise: none of these share a dotted prefix.
    const memFile = findSection(merged.sections, "codelink_chain_mem.zig").?;
    const memAllocator = findSection(memFile.children, "Allocator").?;
    const allocatorFile = findSection(merged.sections, "codelink_chain_allocator.zig").?;
    try std.testing.expectEqualStrings("codelink_chain_mem", memFile.path);
    try std.testing.expectEqualStrings("codelink_chain_mem.Allocator", memAllocator.path);
    try std.testing.expectEqualStrings("codelink_chain_allocator", allocatorFile.path);

    // Diagnostics: confirm each hop's own extraction data independently,
    // so a failure below points at the actual broken link in the chain.
    const stdFile = findSection(merged.sections, "codelink_chain_std.zig").?;
    const stdMem = findSection(stdFile.children, "mem").?;
    try std.testing.expectEqual(@as(usize, 1), stdMem.pendingCodelinkTargets.len);
    try std.testing.expectEqualStrings("codelink_chain_mem.zig", stdMem.pendingCodelinkTargets[0].importTarget);
    try std.testing.expectEqualStrings("", stdMem.pendingCodelinkTargets[0].remainingPath);
    try std.testing.expectEqual(@as(usize, 0), stdMem.codelinkTargets.len);

    try std.testing.expectEqual(@as(usize, 1), memAllocator.pendingCodelinkTargets.len);
    try std.testing.expectEqualStrings("codelink_chain_allocator.zig", memAllocator.pendingCodelinkTargets[0].importTarget);
    try std.testing.expectEqualStrings("", memAllocator.pendingCodelinkTargets[0].remainingPath);
    try std.testing.expectEqual(@as(usize, 0), memAllocator.codelinkTargets.len);

    const userFileBefore = findSection(merged.sections, "codelink_chain_user.zig").?;
    const userAllocatorBefore = findSection(userFileBefore.children, "Allocator").?;
    // `std`, `std.mem`, and `std.mem.Allocator` each get their own pending target.
    try std.testing.expectEqual(@as(usize, 3), userAllocatorBefore.pendingCodelinkTargets.len);
    try std.testing.expectEqualStrings("codelink_chain_std.zig", userAllocatorBefore.pendingCodelinkTargets[0].importTarget);
    try std.testing.expectEqualStrings("", userAllocatorBefore.pendingCodelinkTargets[0].remainingPath);
    try std.testing.expectEqualStrings("codelink_chain_std.zig", userAllocatorBefore.pendingCodelinkTargets[1].importTarget);
    try std.testing.expectEqualStrings("mem", userAllocatorBefore.pendingCodelinkTargets[1].remainingPath);
    try std.testing.expectEqualStrings("codelink_chain_std.zig", userAllocatorBefore.pendingCodelinkTargets[2].importTarget);
    try std.testing.expectEqualStrings("mem.Allocator", userAllocatorBefore.pendingCodelinkTargets[2].remainingPath);

    var virtualRoot: model.Section = undefined;
    var fileRoots = try render.buildFileRootIndex(gpa, merged, &virtualRoot);
    defer fileRoots.deinit();
    try render.resolvePendingCodelinks(gpa, merged.sections, &fileRoots);

    const userFile = findSection(merged.sections, "codelink_chain_user.zig").?;
    const userAllocator = findSection(userFile.children, "Allocator").?;
    // The final (longest) segment still resolves through the whole chain
    // to the real decl; the earlier two resolve to their own, shorter hops.
    try std.testing.expectEqual(@as(usize, 3), userAllocator.codelinkTargets.len);
    try std.testing.expectEqualStrings(allocatorFile.path, userAllocator.codelinkTargets[2].targetPath);
}

test "render.resolvePendingCodelinks: a bare @import naming the root's own package name resolves back to it (--discover ns)" {
    const gpa = std.testing.allocator;

    // `imports.walkTree`, not `extract.extractFile`/`mergeTrees` — this
    // is specifically the `--discover ns` pipeline, since the bare
    // package-name self-import (`@import("std")`, as opposed to a
    // relative `.zig` path) only has a root to resolve back to when
    // there's a single privileged root file, which only this pipeline
    // (and single-file `fs` mode) has.
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("codelink_pkg_std.zig", codelinkPkgStd);
    try fixture.put("codelink_pkg_parse.zig", codelinkPkgParse);
    try fixture.put("codelink_pkg_user.zig", codelinkPkgUser);

    var tree = try imports.walkTree(gpa, fixture.reader(), "codelink_pkg_std.zig", true, false, false, null);
    defer tree.deinit(gpa);

    const userFileBefore = findSection(tree.sections, "codelink_pkg_user");
    const userSomeTypeBefore = findSection((userFileBefore orelse unreachable).children, "SomeType").?;
    // `codelink_pkg_std`, `+zon_parse`, and `+zon_parse.SomeType` each get
    // their own pending target.
    try std.testing.expectEqual(@as(usize, 3), userSomeTypeBefore.pendingCodelinkTargets.len);
    try std.testing.expectEqualStrings("codelink_pkg_std", userSomeTypeBefore.pendingCodelinkTargets[0].importTarget);
    try std.testing.expectEqualStrings("", userSomeTypeBefore.pendingCodelinkTargets[0].remainingPath);
    try std.testing.expectEqualStrings("codelink_pkg_std", userSomeTypeBefore.pendingCodelinkTargets[1].importTarget);
    try std.testing.expectEqualStrings("zon_parse", userSomeTypeBefore.pendingCodelinkTargets[1].remainingPath);
    try std.testing.expectEqualStrings("codelink_pkg_std", userSomeTypeBefore.pendingCodelinkTargets[2].importTarget);
    try std.testing.expectEqualStrings("zon_parse.SomeType", userSomeTypeBefore.pendingCodelinkTargets[2].remainingPath);

    var virtualRoot: model.Section = undefined;
    var fileRoots = try render.buildFileRootIndex(gpa, tree, &virtualRoot);
    defer fileRoots.deinit();
    try render.resolvePendingCodelinks(gpa, tree.sections, &fileRoots);

    const parseFile = findSection(tree.sections, "codelink_pkg_parse").?;
    const realSomeType = findSection(parseFile.children, "SomeType").?;

    const userFile = findSection(tree.sections, "codelink_pkg_user").?;
    const userSomeType = findSection(userFile.children, "SomeType").?;
    try std.testing.expectEqual(@as(usize, 3), userSomeType.codelinkTargets.len);
    try std.testing.expectEqualStrings(realSomeType.path, userSomeType.codelinkTargets[2].targetPath);
}

test "buildFileScopes: a non-import local shadows an outer binding of the same name, for the rest of that function only" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub const helper = struct {};
        \\pub fn run() void {
        \\    const helper = 5;
        \\    _ = helper;
        \\}
        \\
    ;

    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);

    var frames: std.ArrayList(codelinks.ScopeFrame) = .empty;
    defer codelinks.freeScopeFrames(gpa, &frames);

    try codelinks.buildFileScopes(gpa, tree, tree.rootDecls(), "root", 0, @intCast(tree.source.len), &frames);

    var sawFileLevelHelper = false;
    var sawLocalHelperShadow = false;
    for (frames.items) |frame| {
        if (frame.bindings.get("helper")) |bound| {
            switch (bound.binding) {
                .sameFile => |p| {
                    if (std.mem.eql(u8, p, "root.helper")) sawFileLevelHelper = true;
                    if (p.len == 0) sawLocalHelperShadow = true;
                },
                else => {},
            }
        }
    }
    try std.testing.expect(sawFileLevelHelper);
    try std.testing.expect(sawLocalHelperShadow);
}
// ===========================================================================
// imports.zig tests
// ===========================================================================

// In-memory Reader: a fixed map of relative path to source text, so
// import resolution can be exercised without real files. Test-only --
// used across every fixture-based test in this file.
const FixtureReader = struct {
    gpa: std.mem.Allocator,
    files: std.StringHashMap([:0]const u8),

    fn init(gpa: std.mem.Allocator) FixtureReader {
        return .{ .gpa = gpa, .files = .init(gpa) };
    }

    fn deinit(self: *FixtureReader) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.files.deinit();
    }

    fn put(self: *FixtureReader, path: []const u8, source: [:0]const u8) !void {
        const key = try self.gpa.dupe(u8, path);
        const value = try allocSentinelCopy(self.gpa, source);
        try self.files.put(key, value);
    }

    fn reader(self: *const FixtureReader) imports.Reader {
        return .{ .context = self, .readFn = readImpl };
    }

    fn readImpl(context: *const anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![:0]u8 {
        const self: *const FixtureReader = @ptrCast(@alignCast(context));
        const source = self.files.get(path) orelse return error.FileNotFound;
        return allocSentinelCopy(gpa, source);
    }
};

// Copies source into a new null-terminated buffer.
fn allocSentinelCopy(gpa: std.mem.Allocator, source: []const u8) ![:0]u8 {
    const buf = try gpa.allocSentinel(u8, source.len, 0);
    @memcpy(buf, source);
    return buf;
}

// Counts sections named `name` that actually have children of their
// own (i.e. are the real, fully-built content, not just a same-named
// link elsewhere in the tree pointing back to it).
fn importsCountRealOccurrences(sections: []const model.Section, name: []const u8, count: *usize) void {
    for (sections) |s| {
        if (std.mem.eql(u8, s.name, name) and s.children.len > 0) count.* += 1;
        importsCountRealOccurrences(s.children, name, count);
    }
}

test "walkTree: single file with no imports" {
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\//! Root module.
        \\pub fn hello() void {}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", false, false, false, null);
    defer tree.deinit(gpa);

    try std.testing.expectEqualStrings("root", tree.moduleName);
    try std.testing.expectEqual(@as(usize, 1), tree.sections.len);
    try std.testing.expectEqualStrings("hello", tree.sections[0].name);
    try std.testing.expectEqualStrings("root.hello", tree.sections[0].path);
}

test "walkTree: follows a relative import and resolves the alias to real content" {
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\const child = @import("child.zig");
        \\pub const Greeter = child.Greeter;
        \\
    );
    try fixture.put("child.zig",
        \\pub fn Greeter() type {
        \\    return struct {};
        \\}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, false, false, null);
    defer tree.deinit(gpa);

    // Root's two direct entries: "child" (inlines its file's content)
    // and "Greeter" (a decl-level alias to child.zig's real Greeter,
    // linking rather than duplicating content).
    try std.testing.expectEqual(@as(usize, 2), tree.sections.len);
    const greeter = findSection(tree.sections, "Greeter").?;

    try std.testing.expectEqualStrings("root.Greeter", greeter.path);
    // Cross-file alias site: no content of its own.
    try std.testing.expectEqual(@as(usize, 0), greeter.source.len);

    // "child" carries its own real content. Its "Greeter" child
    // resolves to the actual generic-type constructor, grouped with
    // structs (typeFunction) rather than plain functions.
    const child = findSection(tree.sections, "child").?;
    try std.testing.expectEqualStrings("root.child", child.path);
    try std.testing.expect(child.children.len > 0);
    const childGreeter = findSection(child.children, "Greeter").?;
    try std.testing.expectEqual(model.Kind.struct_decl, childGreeter.kind);
    try std.testing.expect(std.mem.indexOf(u8, childGreeter.source, "return struct") != null);
    try std.testing.expectEqualStrings("child.zig", childGreeter.sourceFile);
}

test "walkTree: a nested namespace section shows its own file's test blocks, not just the root file's" {
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\const child = @import("child.zig");
        \\pub const Child = child;
        \\
        \\test "root's own test" {
        \\    try @import("std").testing.expect(true);
        \\}
        \\
    );
    try fixture.put("child.zig",
        \\pub fn hello() void {}
        \\
        \\test "child's own test" {
        \\    try @import("std").testing.expect(true);
        \\}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, false, true, null);
    defer tree.deinit(gpa);

    // Root file's own tests are collected onto the tree itself.
    try std.testing.expect(std.mem.indexOf(u8, tree.testSource, "root's own test") != null);

    // "child.zig"'s own real content lives at its own on-disk-name
    // fqn ("child"), regardless of which of "child"/"Child" is
    // public — privacy plays no part in where a file's content lives.
    // "Child" is just a link to it.
    const childPage = findSection(tree.sections, "child").?;
    try std.testing.expect(std.mem.indexOf(u8, childPage.testSource, "child's own test") != null);
    try std.testing.expect(std.mem.indexOf(u8, childPage.testSource, "root's own test") == null);
}

test "walkTree: collectTests off leaves a namespace page's own testSource empty" {
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\const child = @import("child.zig");
        \\pub const Child = child;
        \\
    );
    try fixture.put("child.zig",
        \\pub fn hello() void {}
        \\
        \\test "child's own test" {
        \\    try @import("std").testing.expect(true);
        \\}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, false, false, null);
    defer tree.deinit(gpa);

    try std.testing.expectEqualStrings("", tree.testSource);
    const childPage = findSection(tree.sections, "child").?;
    try std.testing.expectEqualStrings("", childPage.testSource);
}

test "walkTree: a nested non-root struct section (not a whole other file) has no testSource of its own" {
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\pub const Inner = struct {
        \\    pub fn hello() void {}
        \\};
        \\
        \\test "root's own test" {
        \\    try @import("std").testing.expect(true);
        \\}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, false, true, null);
    defer tree.deinit(gpa);

    // A real named struct decl, not an alias, so it stays empty
    // rather than duplicating the root's tests onto nested sections.
    const inner = findSection(tree.sections, "Inner").?;
    try std.testing.expectEqualStrings("", inner.testSource);
}

test "walkTree: a namespace's own page is a whole-file wrapper, same as the front page" {
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\const child = @import("child.zig");
        \\pub const Child = child;
        \\
    );
    try fixture.put("child.zig",
        \\//! Child's own module doc comment.
        \\pub fn hello() void {}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, false, false, null);
    defer tree.deinit(gpa);

    // "child.zig"'s own real content lives at its own on-disk-name
    // fqn ("child"), reporting as a whole-file wrapper same as the
    // front page itself. "Child" is just a link to it.
    const child = findSection(tree.sections, "child").?;
    try std.testing.expect(child.isWholeFileWrapper());
    try std.testing.expect(std.mem.indexOf(u8, child.source, "pub fn hello") != null);
}

test "walkTree: an ordinary nested struct section is not a whole-file wrapper" {
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\pub const Inner = struct {
        \\    pub fn hello() void {}
        \\};
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, false, false, null);
    defer tree.deinit(gpa);

    // A real named struct decl, not an alias — its own page shows one
    // decl's source, not a whole file's.
    const inner = findSection(tree.sections, "Inner").?;
    try std.testing.expect(!inner.isWholeFileWrapper());
}

test "walkTree: diamond import resolves both alias sites to the same content" {
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\const a = @import("a.zig");
        \\const b = @import("b.zig");
        \\pub const FromA = a.Shared;
        \\pub const FromB = b.Shared;
        \\
    );
    try fixture.put("a.zig",
        \\pub const shared = @import("shared.zig");
        \\pub const Shared = shared.Common;
        \\
    );
    try fixture.put("b.zig",
        \\pub const shared = @import("shared.zig");
        \\pub const Shared = shared.Common;
        \\
    );
    try fixture.put("shared.zig",
        \\pub fn Common() type {
        \\    return struct {};
        \\}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, false, false, null);
    defer tree.deinit(gpa);

    // Root's entries: "a"/"b" carry their files' real content inline
    // (their own names match their own fqn); "FromA"/"FromB" are
    // generic-type-constructor aliases resolved fully inline;
    // "shared" is its own fifth top-level entry — shared.zig's own
    // fqn is its own on-disk name, not nested under "a" or "b".
    try std.testing.expectEqual(@as(usize, 5), tree.sections.len);
    const fromA = findSection(tree.sections, "FromA").?;
    const fromB = findSection(tree.sections, "FromB").?;
    for ([_]model.Section{ fromA, fromB }) |s| {
        try std.testing.expectEqualStrings("shared.zig", s.sourceFile);
        // Generic type constructor, grouped with structs.
        try std.testing.expectEqual(model.Kind.struct_decl, s.kind);
    }

    // shared.zig's own true fqn is its own top-level, on-disk name
    // ("shared") — neither "a.shared" nor "b.shared" is that, so both
    // are thin links to the one real page.
    const a = findSection(tree.sections, "a").?;
    const b = findSection(tree.sections, "b").?;
    const aShared = findSection(a.children, "shared").?;
    const bShared = findSection(b.children, "shared").?;
    const shared = findSection(tree.sections, "shared").?;
    try std.testing.expectEqual(@as(usize, 0), aShared.children.len);
    try std.testing.expectEqualStrings("root.shared", aShared.aliasTargetPath.?);
    try std.testing.expectEqual(@as(usize, 0), bShared.children.len);
    try std.testing.expectEqualStrings("root.shared", bShared.aliasTargetPath.?);
    try std.testing.expect(shared.children.len > 0);
    try std.testing.expect(shared.aliasTargetPath == null);
    try std.testing.expect(findSection(shared.children, "Common") != null);
}

test "walkTree: a namespace reached from three different places gets built exactly once, not duplicated per reference" {
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\const left = @import("left.zig");
        \\const middle = @import("middle.zig");
        \\const right = @import("right.zig");
        \\pub const Left = left.Hub;
        \\pub const Middle = middle.Hub;
        \\pub const Right = right.Hub;
        \\
    );
    try fixture.put("left.zig",
        \\pub const hub = @import("hub.zig");
        \\pub const Hub = hub;
        \\
    );
    try fixture.put("middle.zig",
        \\pub const hub = @import("hub.zig");
        \\pub const Hub = hub;
        \\
    );
    try fixture.put("right.zig",
        \\pub const hub = @import("hub.zig");
        \\pub const Hub = hub;
        \\
    );
    try fixture.put("hub.zig",
        \\pub const Nested = struct {
        \\    pub fn inner() void {}
        \\};
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, false, false, null);
    defer tree.deinit(gpa);

    // hub.zig is reachable several ways, but must still be built
    // exactly once — at its own true fqn location ("hub", its own
    // on-disk name, a top-level sibling of everything else here).
    // "left"/"middle"/"right" are each canonical for their own files
    // (their own on-disk names match their own fqn). Every route
    // to hub.zig itself — "Left"/"Middle"/"Right" and each file's own
    // nested "hub" member — is a thin link to that one real page.
    const left = findSection(tree.sections, "left").?;
    const leftHub = findSection(left.children, "hub").?;
    const bigLeft = findSection(tree.sections, "Left").?;
    const middle = findSection(tree.sections, "Middle").?;
    const right = findSection(tree.sections, "Right").?;
    const hub = findSection(tree.sections, "hub").?;
    try std.testing.expectEqual(@as(usize, 0), leftHub.children.len);
    try std.testing.expectEqualStrings("root.hub", leftHub.aliasTargetPath.?);
    try std.testing.expectEqual(@as(usize, 0), bigLeft.children.len);
    try std.testing.expectEqualStrings("root.hub", bigLeft.aliasTargetPath.?);
    try std.testing.expectEqual(@as(usize, 0), middle.children.len);
    try std.testing.expectEqualStrings("root.hub", middle.aliasTargetPath.?);
    try std.testing.expectEqual(@as(usize, 0), right.children.len);
    try std.testing.expectEqualStrings("root.hub", right.aliasTargetPath.?);
    try std.testing.expect(hub.aliasTargetPath == null);
    try std.testing.expect(findSection(hub.children, "Nested") != null);
}

test "walkTree: many mutually-interconnected files build fast, each namespace exactly once" {
    // Regression: a cross-file namespace reference must queue on
    // Worklist rather than recurse, so each namespace builds exactly
    // once regardless of how many places reference it.
    //
    // `hubCount` "hub" files each import every other hub (mirrors
    // std.mem / std.testing / std.debug), reached from `leafCount`
    // independent leaf files.
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();

    const hubCount = 8;
    const leafCount = 12;

    for (0..hubCount) |i| {
        var importLines: std.ArrayList(u8) = .empty;
        defer importLines.deinit(gpa);
        for (0..hubCount) |j| {
            if (j == i) continue;
            const line = try std.fmt.allocPrint(gpa, "const hub{d} = @import(\"hub{d}.zig\");\n", .{ j, j });
            defer gpa.free(line);
            try importLines.appendSlice(gpa, line);
        }
        const src = try std.fmt.allocPrint(gpa, "{s}pub fn hub{d}Fn() void {{}}\n", .{ importLines.items, i });
        defer gpa.free(src);
        const sentineled = try allocSentinelCopy(gpa, src);
        defer gpa.free(sentineled);
        const path = try std.fmt.allocPrint(gpa, "hub{d}.zig", .{i});
        defer gpa.free(path);
        try fixture.put(path, sentineled);
    }

    var rootSrc: std.ArrayList(u8) = .empty;
    defer rootSrc.deinit(gpa);
    for (0..leafCount) |i| {
        const line = try std.fmt.allocPrint(gpa, "pub const leaf{d} = @import(\"leaf{d}.zig\");\n", .{ i, i });
        defer gpa.free(line);
        try rootSrc.appendSlice(gpa, line);

        var leafImports: std.ArrayList(u8) = .empty;
        defer leafImports.deinit(gpa);
        for (0..hubCount) |h| {
            const hubLine = try std.fmt.allocPrint(gpa, "pub const hub{d} = @import(\"hub{d}.zig\");\n", .{ h, h });
            defer gpa.free(hubLine);
            try leafImports.appendSlice(gpa, hubLine);
        }
        const leafSentineled = try allocSentinelCopy(gpa, leafImports.items);
        defer gpa.free(leafSentineled);
        const leafPath = try std.fmt.allocPrint(gpa, "leaf{d}.zig", .{i});
        defer gpa.free(leafPath);
        try fixture.put(leafPath, leafSentineled);
    }
    const rootSentineled = try allocSentinelCopy(gpa, rootSrc.items);
    defer gpa.free(rootSentineled);
    try fixture.put("root.zig", rootSentineled);

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, false, false, null);
    defer tree.deinit(gpa);

    // Root's leafCount direct entries: each is the canonical reach for
    // its own leaf file (own on-disk name matches its own fqn), so
    // they stay real, top-level sections. Each hub is *also* its own
    // top-level section, at its own fqn (its own on-disk name) — not
    // nested under whichever leaf happened to reference it first.
    try std.testing.expectEqual(@as(usize, leafCount + hubCount), tree.sections.len);

    // Each hub is referenced by every leaf (and every other hub), but
    // must end up with real content exactly once, wherever its
    // resolved canonical path ends up.
    for (0..hubCount) |h| {
        const hubName = try std.fmt.allocPrint(gpa, "hub{d}", .{h});
        defer gpa.free(hubName);
        var realCount: usize = 0;
        importsCountRealOccurrences(tree.sections, hubName, &realCount);
        try std.testing.expectEqual(@as(usize, 1), realCount);
    }
}

test "walkTree: mutual import cycle is discovered without error, root isn't rebuilt" {
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("a.zig",
        \\pub const b = @import("b.zig");
        \\pub fn fromA() void {}
        \\
    );
    try fixture.put("b.zig",
        \\pub const a = @import("a.zig");
        \\pub fn fromB() void {}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "a.zig", true, false, false, null);
    defer tree.deinit(gpa);

    // a.zig's two direct entries: "b" (first reference, real content)
    // and "fromA". b.zig's own "a" is a back-edge to the root and must
    // not cause the root to be rebuilt — it's already seeded into
    // worklist.seen, so it becomes a plain link nested inside "b".
    try std.testing.expectEqual(@as(usize, 2), tree.sections.len);

    const b = findSection(tree.sections, "b").?;
    try std.testing.expect(b.children.len > 0);
    const backToRoot = findSection(b.children, "a").?;
    try std.testing.expectEqual(@as(usize, 0), backToRoot.children.len);
}

test "walkTree: a deep back-edge to the root (several hops away, not immediate) still doesn't requeue it" {
    // Same bug, but the back-edge is several hops down an otherwise
    // unrelated chain rather than the very next file.
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\pub const level1 = @import("level1.zig");
        \\pub fn rootFn() void {}
        \\
    );
    try fixture.put("level1.zig",
        \\pub const level2 = @import("level2.zig");
        \\
    );
    try fixture.put("level2.zig",
        \\pub const level3 = @import("level3.zig");
        \\
    );
    try fixture.put("level3.zig",
        \\pub const back = @import("root.zig");
        \\pub fn level3Fn() void {}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, false, false, null);
    defer tree.deinit(gpa);

    // root.zig -> level1.zig -> level2.zig -> level3.zig each nest one
    // level deeper, inlined in full (each is the first, only,
    // reference to its own file) — the back-edge from level3.zig to
    // root.zig doesn't rebuild root (it's already in `worklist.seen`
    // from `buildTree`'s own start), and becomes a plain link nested
    // inside level3, not a duplicate copy of the whole root.
    // root.zig -> level1.zig is the only reach to level1 (own on-disk
    // name matches its own fqn), so it's real, nested under root.
    // level1's own "level2" member and level2's own "level3" member
    // are each thin links, though — level2.zig/level3.zig's own true
    // fqn locations are top-level ("root.level2"/"root.level3"), not
    // nested under whichever file first referenced them. The
    // back-edge from level3.zig to root.zig doesn't rebuild root
    // (it's already in `worklist.seen` from `buildTree`'s own start),
    // and becomes a plain link.
    const level1 = findSection(tree.sections, "level1").?;
    try std.testing.expect(level1.children.len > 0);
    const level2Stub = findSection(level1.children, "level2").?;
    try std.testing.expectEqual(@as(usize, 0), level2Stub.children.len);
    const level2 = findSection(tree.sections, "level2").?;
    try std.testing.expect(level2.children.len > 0);
    const level3 = findSection(tree.sections, "level3").?;
    try std.testing.expect(findSection(level3.children, "level3Fn") != null);

    const backToRoot = findSection(level3.children, "back").?;
    try std.testing.expectEqual(@as(usize, 0), backToRoot.children.len);
}

test "walkTree: non-relative import target is skipped, not an error" {
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\const std_ = @import("std");
        \\pub fn hello() void {}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", false, false, false, null);
    defer tree.deinit(gpa);

    // "std_" categorizes as .globalConst (unresolved import target) —
    // still shows up as its own const-decl section.
    try std.testing.expectEqual(@as(usize, 2), tree.sections.len);
}

test "walkTree: a decl-level alias to a type function in another file — real std.AutoHashMap shape" {
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\const hash_map = @import("hash_map.zig");
        \\pub const AutoHashMap = hash_map.AutoHashMap;
        \\
    );
    try fixture.put("hash_map.zig",
        \\pub fn AutoHashMap(comptime K: type, comptime V: type) type {
        \\    return HashMap(K, V);
        \\}
        \\
        \\pub fn HashMap(comptime K: type, comptime V: type) type {
        \\    return Custom(K, V);
        \\}
        \\
        \\pub fn Custom(comptime K: type, comptime V: type) type {
        \\    _ = K;
        \\    _ = V;
        \\    return struct {
        \\        pub fn init() void {}
        \\        pub fn deinit(self: *@This()) void {
        \\            _ = self;
        \\        }
        \\    };
        \\}
        \\
    );

    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, false, false, null);
    defer tree.deinit(gpa);

    // Root's two direct entries: "hash_map" (carries its real
    // content, including its own AutoHashMap) and "AutoHashMap"
    // (root's decl-level alias to it, which should link rather than
    // duplicate the real page).
    try std.testing.expectEqual(@as(usize, 2), tree.sections.len);

    const hashMapNs = findSection(tree.sections, "hash_map").?;
    try std.testing.expect(hashMapNs.children.len > 0);
    const nativeAutoHashMap = findSection(hashMapNs.children, "AutoHashMap").?;
    try std.testing.expectEqualStrings("root.hash_map.AutoHashMap", nativeAutoHashMap.path);
    try std.testing.expect(std.mem.indexOf(u8, nativeAutoHashMap.source, "return HashMap") != null);

    const rootAlias = findSection(tree.sections, "AutoHashMap").?;
    try std.testing.expectEqualStrings("root.AutoHashMap", rootAlias.path);
    // Cross-file alias site: no content of its own, just names the
    // real page directly so render.zig can link straight to it.
    try std.testing.expectEqual(@as(usize, 0), rootAlias.source.len);
    try std.testing.expectEqual(@as(usize, 0), rootAlias.children.len);
    try std.testing.expectEqualStrings("root.hash_map.AutoHashMap", rootAlias.aliasTargetPath.?);
}

test "walkTree: progress callback fires once per discovered file" {
    const gpa = std.testing.allocator;
    var fixture = FixtureReader.init(gpa);
    defer fixture.deinit();
    try fixture.put("root.zig",
        \\pub const child = @import("child.zig");
        \\
    );
    try fixture.put("child.zig",
        \\pub fn greet() void {}
        \\
    );

    var walkProgress: progress.Progress = .{};
    var tree = try imports.walkTree(gpa, fixture.reader(), "root.zig", true, false, false, &walkProgress);
    defer tree.deinit(gpa);
    // No direct way to count update() calls (it's a stderr side
    // effect gated off under builtin.is_test), but this confirms
    // passing a non-null progress pointer through a real multi-file
    // walk doesn't crash or corrupt anything. root.zig's own single
    // direct entry, "child" (the only reference to child.zig, so its
    // real content is inlined right there).
    try std.testing.expectEqual(@as(usize, 1), tree.sections.len);
}
// ===========================================================================
// extract.zig tests
// ===========================================================================

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
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, false, false);
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
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, false, false);
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
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, true, false, false);
    defer treeDoc.deinit(gpa);

    const outer = treeDoc.sections[0];
    try std.testing.expect(std.mem.startsWith(u8, outer.source, "pub const Outer"));

    const innerFn = outer.children[0];
    try std.testing.expect(std.mem.startsWith(u8, innerFn.source, "    pub fn inner"));
}

test "isPub reflects the pub keyword" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub fn pubFn() void {}
        \\fn privFn() void {}
        \\pub const PubConst: u8 = 1;
        \\const privConst: u8 = 1;
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, false, false);
    defer treeDoc.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), treeDoc.sections.len);
    try std.testing.expect(treeDoc.sections[0].isPub);
    try std.testing.expect(!treeDoc.sections[1].isPub);
    try std.testing.expect(treeDoc.sections[2].isPub);
    try std.testing.expect(!treeDoc.sections[3].isPub);
}

test "parse failure surfaces as error" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 = "pub fn broken( {";
    try std.testing.expectError(extract.ExtractError.ParseFailed, extract.extractFile(gpa, "example", "example.zig", source, false, false, false));
}

test "extras off collects no fields/params/errors" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub const Point = struct {
        \\    x: i32,
        \\    y: i32,
        \\};
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, false, false);
    defer treeDoc.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), treeDoc.sections[0].fields.len);
}

test "extras on collects struct fields with doc comments" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub const Point = struct {
        \\    /// The x coordinate.
        \\    x: i32,
        \\    y: i32,
        \\};
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, true, false);
    defer treeDoc.deinit(gpa);

    const fields = treeDoc.sections[0].fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("x", fields[0].name);
    try std.testing.expectEqualStrings("i32", fields[0].typeText);
    try std.testing.expectEqualStrings("The x coordinate.", fields[0].docComment);
    try std.testing.expectEqualStrings("y", fields[1].name);
    try std.testing.expectEqualStrings("", fields[1].docComment);
}

test "extras on collects union fields" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub const Value = union {
        \\    int: i32,
        \\    float: f64,
        \\};
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, true, false);
    defer treeDoc.deinit(gpa);

    const fields = treeDoc.sections[0].fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("int", fields[0].name);
    try std.testing.expectEqualStrings("float", fields[1].name);
}

test "extras on collects function params" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, true, false);
    defer treeDoc.deinit(gpa);

    const params = treeDoc.sections[0].params;
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqualStrings("a", params[0].name);
    try std.testing.expectEqualStrings("i32", params[0].typeText);
    try std.testing.expectEqualStrings("b", params[1].name);
    try std.testing.expectEqualStrings("i32", params[1].typeText);
}

test "extras on collects function params with doc comments" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub fn add(
        \\    /// The first addend.
        \\    a: i32,
        \\    b: i32,
        \\) i32 {
        \\    return a + b;
        \\}
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, true, false);
    defer treeDoc.deinit(gpa);

    const params = treeDoc.sections[0].params;
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqualStrings("a", params[0].name);
    try std.testing.expectEqualStrings("The first addend.", params[0].docComment);
    try std.testing.expectEqualStrings("b", params[1].name);
    try std.testing.expectEqualStrings("", params[1].docComment);
}

test "extras on collects standalone error set members" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub const MyError = error{
        \\    /// Something went wrong.
        \\    Bad,
        \\    Worse,
        \\};
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, true, false);
    defer treeDoc.deinit(gpa);

    const errs = treeDoc.sections[0].errors;
    try std.testing.expectEqual(@as(usize, 2), errs.len);
    try std.testing.expectEqualStrings("Bad", errs[0].name);
    try std.testing.expectEqualStrings("Something went wrong.", errs[0].docComment);
    try std.testing.expectEqualStrings("Worse", errs[1].name);
}

test "extras on resolves a function's named error-union return type" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub const MyError = error{
        \\    Bad,
        \\};
        \\pub fn doThing() MyError!void {}
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, true, false);
    defer treeDoc.deinit(gpa);

    // sections[0] is MyError (const decl), sections[1] is doThing (fn decl).
    try std.testing.expectEqual(@as(usize, 2), treeDoc.sections.len);
    const fnSection = treeDoc.sections[1];
    try std.testing.expectEqualStrings("doThing", fnSection.name);
    try std.testing.expectEqual(@as(usize, 1), fnSection.errors.len);
    try std.testing.expectEqualStrings("Bad", fnSection.errors[0].name);
}

test "extras on leaves inferred error union with no error members" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub fn doThing() !void {}
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, true, false);
    defer treeDoc.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), treeDoc.sections[0].errors.len);
}

test "extras on leaves plain non-error-union return type with no error members" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub fn doThing() void {}
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, true, false);
    defer treeDoc.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), treeDoc.sections[0].errors.len);
}

test "extras on leaves unresolvable (imported) error-union identifier with no error members" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\pub fn doThing() anyerror!void {}
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, true, false);
    defer treeDoc.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), treeDoc.sections[0].errors.len);
}

test "collectTests off leaves testSource empty" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\test "example test" {
        \\    try std.testing.expect(true);
        \\}
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, false, false);
    defer treeDoc.deinit(gpa);

    try std.testing.expectEqualStrings("", treeDoc.testSource);
}

test "collectTests on collects a single top-level test block verbatim" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\test "example test" {
        \\    try std.testing.expect(true);
        \\}
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, false, true);
    defer treeDoc.deinit(gpa);

    try std.testing.expectEqualStrings(
        \\test "example test" {
        \\    try std.testing.expect(true);
        \\}
    , treeDoc.testSource);
}

test "collectTests on concatenates multiple test blocks in source order" {
    const gpa = std.testing.allocator;
    const source: [:0]const u8 =
        \\test "first" {
        \\    try std.testing.expect(true);
        \\}
        \\
        \\pub fn notATest() void {}
        \\
        \\test "second" {
        \\    try std.testing.expect(false);
        \\}
        \\
    ;
    var treeDoc = try extract.extractFile(gpa, "example", "example.zig", source, false, false, true);
    defer treeDoc.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, treeDoc.testSource, "\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, treeDoc.testSource, "\"second\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, treeDoc.testSource, "notATest") == null);
    // "first" appears before "second" — source order preserved.
    try std.testing.expect(
        std.mem.indexOf(u8, treeDoc.testSource, "\"first\"").? < std.mem.indexOf(u8, treeDoc.testSource, "\"second\"").?,
    );
}
// ===========================================================================
// model.zig tests
// ===========================================================================

test "fileWrapperSection sets isFileRoot" {
    const gpa = std.testing.allocator;
    const tree = model.DocTree{
        .moduleName = try gpa.dupe(u8, "mod"),
        .rootDocComment = null,
        .sections = &.{},
        .fullSource = try gpa.dupe(u8, "const x = 1;\n"),
        .testSource = try gpa.dupe(u8, ""),
    };
    var section = try model.fileWrapperSection(gpa, tree, .namespace, "mod", "mod.zig", "mod.zig");
    defer model.freeSection(gpa, &section);
    gpa.free(tree.moduleName);
    gpa.free(tree.fullSource);
    gpa.free(tree.testSource);

    try std.testing.expect(section.isFileRoot);
    try std.testing.expect(section.isWholeFileWrapper());
}

test "rawFileSection sets isFileRoot" {
    const gpa = std.testing.allocator;
    var section = try model.rawFileSection(gpa, "mod", "notes.txt", "notes.txt", "hello\n");
    defer model.freeSection(gpa, &section);

    try std.testing.expect(section.isFileRoot);
    try std.testing.expect(section.isWholeFileWrapper());
}

test "rawFileSection flags content with a NUL byte as binary" {
    const gpa = std.testing.allocator;
    var section = try model.rawFileSection(gpa, "mod", "logo.png", "logo.png", "\x89PNG\x00\x01\x02");
    defer model.freeSection(gpa, &section);

    try std.testing.expect(section.isBinary);
}

test "rawFileSection leaves plain text content unflagged" {
    const gpa = std.testing.allocator;
    var section = try model.rawFileSection(gpa, "mod", "notes.md", "notes.md", "# Hello\n\nSome notes.\n");
    defer model.freeSection(gpa, &section);

    try std.testing.expect(!section.isBinary);
}

test "writeIndexTree groups sections by directory and closes each group" {
    const gpa = std.testing.allocator;

    const mk = struct {
        fn f(label: []const u8) model.Section {
            return model.Section{
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
    const sections = [_]model.Section{ mk("main.zig"), mk("render/html_single.zig"), mk("render/md_single.zig") };

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
        fn onLeaf(c: *Ctx, s: model.Section) !void {
            const str = try std.fmt.allocPrint(c.gpa, "LEAF({s})", .{s.name});
            defer c.gpa.free(str);
            try c.out.appendSlice(c.gpa, str);
        }
        fn onDirEnd(c: *Ctx) !void {
            try c.out.appendSlice(c.gpa, "END");
        }
    };

    try model.writeIndexTree(&sections, 0, &ctx, cbs.onDir, cbs.onLeaf, cbs.onDirEnd);

    try std.testing.expectEqualStrings("LEAF(main.zig)DIR(render)LEAF(render/html_single.zig)LEAF(render/md_single.zig)END", ctx.out.items);
}

test "anchorSlug preserves case (Options vs options must not collide) and the '.' separator" {
    const gpa = std.testing.allocator;
    const section = model.Section{
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
    try std.testing.expectEqualStrings("MyModule.MyStruct.myFn", slug);
}

test "anchorSlug: same-name-different-case siblings get distinct anchors" {
    const gpa = std.testing.allocator;
    const typeSection = model.Section{
        .name = "Options",
        .path = "std.Options",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "",
        .sourceLine = 0,
        .children = &.{},
    };
    const valueSection = model.Section{
        .name = "options",
        .path = "std.options",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "",
        .sourceLine = 0,
        .children = &.{},
    };
    const typeSlug = try typeSection.anchorSlug(gpa);
    defer gpa.free(typeSlug);
    const valueSlug = try valueSection.anchorSlug(gpa);
    defer gpa.free(valueSlug);
    try std.testing.expect(!std.mem.eql(u8, typeSlug, valueSlug));
}

test "writePathLinks (HTML) hrefs match anchorSlug's own output — same '.' separator, same case" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try model.writePathLinks(gpa, &aw.writer, "std.Options.logTerminalMode", "std".len, null);
    const written = aw.written();
    // The full path's own anchor must be a link target here too — same
    // slugifier, same separator, same case as anchorSlug produces.
    try std.testing.expect(std.mem.indexOf(u8, written, "href=\"#std.Options.logTerminalMode\"") != null);
}

test "writePathLinks (HTML): a root name containing '.' (e.g. --ext on's \"std.zig\") is one unsplit segment, displayed without the extension" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try model.writePathLinks(gpa, &aw.writer, "std.zig.ArrayListAligned", "std.zig".len, null);
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "<a href=\"#std.zig\">std</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<a href=\"#std\">std</a>") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "href=\"#std.zig.ArrayListAligned\"") != null);
}

test "writePathLinksMd: a root name containing '.' is one unsplit segment, displayed without the extension" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try model.writePathLinksMd(gpa, &aw.writer, "std.zig.ArrayListAligned", "std.zig".len, null);
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "[std](#std-zig)") != null);
}

test "filenameSegment appends a tilde to Windows-reserved device names" {
    const gpa = std.testing.allocator;
    const nul = try model.filenameSegment(gpa, "nul");
    defer gpa.free(nul);
    try std.testing.expectEqualStrings("nul~", nul);

    const con = try model.filenameSegment(gpa, "Con");
    defer gpa.free(con);
    try std.testing.expectEqualStrings("Con~", con);

    const com1 = try model.filenameSegment(gpa, "COM1");
    defer gpa.free(com1);
    try std.testing.expectEqualStrings("COM1~", com1);
}

test "filenameSegment leaves non-reserved names and reserved substrings untouched" {
    const gpa = std.testing.allocator;
    const ordinary = try model.filenameSegment(gpa, "nullable");
    defer gpa.free(ordinary);
    try std.testing.expectEqualStrings("nullable", ordinary);

    const com10 = try model.filenameSegment(gpa, "com10");
    defer gpa.free(com10);
    try std.testing.expectEqualStrings("com10", com10);
}

test "mergeTrees nests each file's sections under its module name" {
    const gpa = std.testing.allocator;

    const aFn = model.Section{
        .name = try gpa.dupe(u8, "add"),
        .path = try gpa.dupe(u8, "a.add"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .children = &.{},
    };
    const aSections = try gpa.dupe(model.Section, &.{aFn});
    const treeA = model.DocTree{
        .moduleName = try gpa.dupe(u8, "a"),
        .rootDocComment = try gpa.dupe(u8, "Module a."),
        .sections = aSections,
    };

    const bFn = model.Section{
        .name = try gpa.dupe(u8, "sub"),
        .path = try gpa.dupe(u8, "b.sub"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .children = &.{},
    };
    const bSections = try gpa.dupe(model.Section, &.{bFn});
    const treeB = model.DocTree{
        .moduleName = try gpa.dupe(u8, "b"),
        .rootDocComment = null,
        .sections = bSections,
    };

    var trees = [_]model.DocTree{ treeA, treeB };
    const labels = [_][]const u8{ "a.zig", "b.zig" };
    var merged = try model.mergeTrees(gpa, "combined", &trees, .{ .fileLabels = &labels, .showExt = true, .showDirPrefix = true });
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

test "mergeNamespaceTrees nests each root's sections under its own module name as a Kind.namespace wrapper" {
    const gpa = std.testing.allocator;

    const aFn = model.Section{
        .name = try gpa.dupe(u8, "add"),
        .path = try gpa.dupe(u8, "a.add"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, "a.zig"),
        .sourceLine = 0,
        .children = &.{},
    };
    const aSections = try gpa.dupe(model.Section, &.{aFn});
    const treeA = model.DocTree{
        .moduleName = try gpa.dupe(u8, "a"),
        .rootDocComment = try gpa.dupe(u8, "Module a."),
        .sections = aSections,
        .fullSource = try gpa.dupe(u8, "pub fn add() void {}\n"),
        .testSource = try gpa.dupe(u8, ""),
    };

    const bFn = model.Section{
        .name = try gpa.dupe(u8, "sub"),
        .path = try gpa.dupe(u8, "b.sub"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, "b.zig"),
        .sourceLine = 0,
        .children = &.{},
    };
    const bSections = try gpa.dupe(model.Section, &.{bFn});
    const treeB = model.DocTree{
        .moduleName = try gpa.dupe(u8, "b"),
        .rootDocComment = null,
        .sections = bSections,
        .fullSource = try gpa.dupe(u8, "pub fn sub() void {}\n"),
        .testSource = try gpa.dupe(u8, ""),
    };

    var trees = [_]model.DocTree{ treeA, treeB };
    var merged = try model.mergeNamespaceTrees(gpa, "src/", &trees);
    defer merged.deinit(gpa);

    try std.testing.expectEqualStrings("src/", merged.moduleName);
    try std.testing.expectEqual(@as(usize, 2), merged.sections.len);

    // Display name is each root's own module name — no fileLabels
    // input at all, unlike mergeTrees, since there's no --ext/--dir
    // formatting question for a flat list of --discover ns roots.
    try std.testing.expectEqualStrings("a", merged.sections[0].name);
    try std.testing.expectEqualStrings("Module a.", merged.sections[0].docComment);
    try std.testing.expectEqual(model.Kind.namespace, merged.sections[0].kind);
    try std.testing.expect(merged.sections[0].isFileRoot);
    try std.testing.expect(merged.sections[0].isWholeFileWrapper());
    try std.testing.expectEqual(@as(usize, 1), merged.sections[0].children.len);
    try std.testing.expectEqualStrings("add", merged.sections[0].children[0].name);

    try std.testing.expectEqualStrings("b", merged.sections[1].name);
    try std.testing.expectEqual(model.Kind.namespace, merged.sections[1].kind);
    try std.testing.expect(merged.sections[1].isFileRoot);
    try std.testing.expectEqualStrings("sub", merged.sections[1].children[0].name);
}

test "mergeTrees strips extension and directory prefix per showExt/showDirPrefix" {
    const gpa = std.testing.allocator;

    const aFn = model.Section{
        .name = try gpa.dupe(u8, "add"),
        .path = try gpa.dupe(u8, "a.add"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .children = &.{},
    };
    const aSections = try gpa.dupe(model.Section, &.{aFn});
    const treeA = model.DocTree{
        .moduleName = try gpa.dupe(u8, "a"),
        .rootDocComment = null,
        .sections = aSections,
    };

    var trees = [_]model.DocTree{treeA};
    const labels = [_][]const u8{"sub/a.zig"};
    var merged = try model.mergeTrees(gpa, "combined", &trees, .{ .fileLabels = &labels, .showExt = false, .showDirPrefix = false });
    defer merged.deinit(gpa);

    try std.testing.expectEqualStrings("a", merged.sections[0].name);
    try std.testing.expectEqualStrings("sub/a.zig", merged.sections[0].fileLabel);
}

test "filterSections with .file excluded splices a file's decls into its parent and strips the removed prefix from their paths" {
    const gpa = std.testing.allocator;

    const deinitFn = model.Section{
        .name = try gpa.dupe(u8, "deinit"),
        .path = try gpa.dupe(u8, "a.Widget.deinit"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .children = &.{},
    };
    const widgetChildren = try gpa.dupe(model.Section, &.{deinitFn});
    const widgetStruct = model.Section{
        .name = try gpa.dupe(u8, "Widget"),
        .path = try gpa.dupe(u8, "a.Widget"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .kind = .struct_decl,
        .children = widgetChildren,
    };
    const aSections = try gpa.dupe(model.Section, &.{widgetStruct});
    const treeA = model.DocTree{
        .moduleName = try gpa.dupe(u8, "a"),
        .rootDocComment = null,
        .sections = aSections,
    };

    var trees = [_]model.DocTree{treeA};
    const labels = [_][]const u8{"a.zig"};
    var merged = try model.mergeTrees(gpa, "combined", &trees, .{ .fileLabels = &labels, .showExt = true, .showDirPrefix = true });
    defer merged.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), merged.sections.len);
    try std.testing.expectEqual(model.Kind.file, merged.sections[0].kind);

    try model.filterSections(gpa, &merged.sections, &.{.file});

    try std.testing.expectEqual(@as(usize, 1), merged.sections.len);
    try std.testing.expectEqualStrings("Widget", merged.sections[0].name);
    try std.testing.expectEqual(model.Kind.struct_decl, merged.sections[0].kind);
    try std.testing.expectEqualStrings("Widget", merged.sections[0].path);
    try std.testing.expectEqual(@as(usize, 1), merged.sections[0].children.len);
    try std.testing.expectEqualStrings("Widget.deinit", merged.sections[0].children[0].path);
}

test "filterSections with .file excluded leaves non-.file sections alone" {
    const gpa = std.testing.allocator;

    const fnSection = model.Section{
        .name = try gpa.dupe(u8, "add"),
        .path = try gpa.dupe(u8, "add"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .kind = .fn_decl,
        .children = &.{},
    };
    var sections = try gpa.dupe(model.Section, &.{fnSection});
    defer {
        for (sections) |*s| model.freeSection(gpa, s);
        gpa.free(sections);
    }

    try model.filterSections(gpa, &sections, &.{.file});

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expectEqualStrings("add", sections[0].name);
}

test "markOmitDoc marks fn_decl docOnly under functions, leaves other kinds alone" {
    const gpa = std.testing.allocator;

    const fnSection = model.Section{
        .name = try gpa.dupe(u8, "add"),
        .path = try gpa.dupe(u8, "add"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .kind = .fn_decl,
        .children = &.{},
    };
    const constSection = model.Section{
        .name = try gpa.dupe(u8, "max"),
        .path = try gpa.dupe(u8, "max"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .kind = .const_decl,
        .children = &.{},
    };
    const sections = try gpa.dupe(model.Section, &.{ fnSection, constSection });
    defer {
        for (sections) |*s| model.freeSection(gpa, s);
        gpa.free(sections);
    }

    model.markOmitDoc(sections, &.{.functions});

    try std.testing.expect(sections[0].docOnly);
    try std.testing.expect(!sections[1].docOnly);
}

test "markOmitDoc with no flags leaves every section untouched" {
    const gpa = std.testing.allocator;

    const fnSection = model.Section{
        .name = try gpa.dupe(u8, "add"),
        .path = try gpa.dupe(u8, "add"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .kind = .fn_decl,
        .children = &.{},
    };
    const sections = try gpa.dupe(model.Section, &.{fnSection});
    defer {
        for (sections) |*s| model.freeSection(gpa, s);
        gpa.free(sections);
    }

    model.markOmitDoc(sections, &.{});

    try std.testing.expect(!sections[0].docOnly);
}

test "filterSections with .file excluded never omits .namespace sections (--discover ns) — namespaces are never omittable" {
    const gpa = std.testing.allocator;

    const greetFn = model.Section{
        .name = try gpa.dupe(u8, "greet"),
        .path = try gpa.dupe(u8, "mod.greet"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .children = &.{},
    };
    const modChildren = try gpa.dupe(model.Section, &.{greetFn});
    var sections = try gpa.dupe(model.Section, &.{model.Section{
        .name = try gpa.dupe(u8, "mod"),
        .path = try gpa.dupe(u8, "mod"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, "mod.zig"),
        .sourceLine = 0,
        .kind = .namespace,
        .children = modChildren,
        .hasChildren = true,
    }});
    defer {
        for (sections) |*s| model.freeSection(gpa, s);
        gpa.free(sections);
    }

    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expectEqual(model.Kind.namespace, sections[0].kind);

    try model.filterSections(gpa, &sections, &.{.file});

    // .namespace is untouched by --omitkind file: still present, still
    // .namespace, still wrapping its child unspliced.
    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expectEqual(model.Kind.namespace, sections[0].kind);
    try std.testing.expectEqual(@as(usize, 1), sections[0].children.len);
    try std.testing.expectEqualStrings("greet", sections[0].children[0].name);
}

test "walk visits nested children depth-first" {
    const gpa = std.testing.allocator;
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(gpa);

    const child = model.Section{
        .name = "child",
        .path = "root.child",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "",
        .sourceLine = 0,
        .children = &.{},
    };
    var children = [_]model.Section{child};
    const root = model.Section{
        .name = "root",
        .path = "root",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "",
        .sourceLine = 0,
        .children = &children,
    };
    const roots = [_]model.Section{root};

    const Collector = struct {
        list: *std.ArrayList([]const u8),
        gpa: std.mem.Allocator,
        fn visit(self: @This(), s: model.Section) !void {
            try self.list.append(self.gpa, s.name);
        }
    };
    try model.walk(&roots, Collector{ .list = &seen, .gpa = gpa }, Collector.visit);

    try std.testing.expectEqual(@as(usize, 2), seen.items.len);
    try std.testing.expectEqualStrings("root", seen.items[0]);
    try std.testing.expectEqualStrings("child", seen.items[1]);
}

test "sortByFileLabelOrder: first/last bucket directories, alpha interleaves" {
    const mk = struct {
        fn f(label: []const u8) model.Section {
            return model.Section{ .name = label, .path = label, .signature = "", .docComment = "", .source = "", .sourceFile = "", .sourceLine = 0, .children = &.{}, .fileLabel = label };
        }
    }.f;

    var first = [_]model.Section{ mk("banana.zig"), mk("apple/a.zig"), mk("cherry.zig") };
    model.sortByFileLabelOrder(&first, .first);
    try std.testing.expectEqualStrings("apple/a.zig", first[0].fileLabel);
    try std.testing.expectEqualStrings("banana.zig", first[1].fileLabel);
    try std.testing.expectEqualStrings("cherry.zig", first[2].fileLabel);

    var last = [_]model.Section{ mk("banana.zig"), mk("apple/a.zig"), mk("cherry.zig") };
    model.sortByFileLabelOrder(&last, .last);
    try std.testing.expectEqualStrings("banana.zig", last[0].fileLabel);
    try std.testing.expectEqualStrings("cherry.zig", last[1].fileLabel);
    try std.testing.expectEqualStrings("apple/a.zig", last[2].fileLabel);

    var alpha = [_]model.Section{ mk("banana.zig"), mk("apple/a.zig"), mk("cherry.zig") };
    model.sortByFileLabelOrder(&alpha, .alpha);
    try std.testing.expectEqualStrings("apple/a.zig", alpha[0].fileLabel);
    try std.testing.expectEqualStrings("banana.zig", alpha[1].fileLabel);
    try std.testing.expectEqualStrings("cherry.zig", alpha[2].fileLabel);
}

test "sortSections: alpha and grouped sort recursively, code is a no-op" {
    var grandchildren = [_]model.Section{
        .{ .name = "z", .path = "", .signature = "", .docComment = "", .source = "", .sourceFile = "", .sourceLine = 0, .kind = .fn_decl, .children = &.{} },
        .{ .name = "a", .path = "", .signature = "", .docComment = "", .source = "", .sourceFile = "", .sourceLine = 0, .kind = .const_decl, .children = &.{} },
    };
    var children = [_]model.Section{
        .{ .name = "b", .path = "", .signature = "", .docComment = "", .source = "", .sourceFile = "", .sourceLine = 0, .kind = .fn_decl, .children = &.{} },
        .{ .name = "a", .path = "", .signature = "", .docComment = "", .source = "", .sourceFile = "", .sourceLine = 0, .kind = .struct_decl, .children = &grandchildren },
    };
    model.sortSections(&children, .code);
    try std.testing.expectEqualStrings("b", children[0].name); // code: unchanged (AST order)
    try std.testing.expectEqualStrings("z", children[1].children[0].name); // recursed, still unchanged

    model.sortSections(&children, .alpha);
    try std.testing.expectEqualStrings("a", children[0].name);
    try std.testing.expectEqualStrings("b", children[1].name);
    try std.testing.expectEqualStrings("a", children[0].children[0].name); // recursed into "a"'s (now first) children

    model.sortSections(&children, .grouped);
    // fn_decl (b) sorts before struct_decl (a) by Kind's declaration order.
    try std.testing.expectEqualStrings("b", children[0].name);
    try std.testing.expectEqualStrings("a", children[1].name);
}

test "relativeHref leaves the target untouched when prettyUrls is off" {
    const gpa = std.testing.allocator;
    const href = try model.relativeHref(gpa, "render/foo.html", "index.html", false);
    defer gpa.free(href);
    try std.testing.expectEqualStrings("../index.html", href);
}

test "relativeHref strips a trailing index.html when prettyUrls is on" {
    const gpa = std.testing.allocator;
    const href = try model.relativeHref(gpa, "render/foo.html", "index.html", true);
    defer gpa.free(href);
    try std.testing.expectEqualStrings("../", href);
}

test "relativeHref strips index.html inside a subdirectory target" {
    const gpa = std.testing.allocator;
    const href = try model.relativeHref(gpa, "index.html", "render/index.html", true);
    defer gpa.free(href);
    try std.testing.expectEqualStrings("render/", href);
}

test "relativeHref reduces a same-directory index.html to a dot when prettyUrls is on" {
    const gpa = std.testing.allocator;
    const href = try model.relativeHref(gpa, "index.html", "index.html", true);
    defer gpa.free(href);
    try std.testing.expectEqualStrings(".", href);
}

test "relativeHref reduces a cross-directory index.html to a bare ../ chain" {
    const gpa = std.testing.allocator;
    const href = try model.relativeHref(gpa, "render/foo/index.html", "index.html", true);
    defer gpa.free(href);
    try std.testing.expectEqualStrings("../../", href);
}

test "filterEmpty drops a .file with no doc comment and no children" {
    const gpa = std.testing.allocator;
    var sections = try gpa.dupe(model.Section, &.{model.Section{
        .name = try gpa.dupe(u8, "empty.zig"),
        .path = try gpa.dupe(u8, "empty"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, "empty.zig"),
        .sourceLine = 0,
        .kind = .file,
        .children = &.{},
    }});
    defer {
        for (sections) |*s| model.freeSection(gpa, s);
        gpa.free(sections);
    }

    try model.filterEmpty(gpa, &sections);
    try std.testing.expectEqual(@as(usize, 0), sections.len);
}

test "filterEmpty keeps a raw non-zig section despite no doc comment or children" {
    const gpa = std.testing.allocator;
    var sections = try gpa.dupe(model.Section, &.{try model.rawFileSection(gpa, "notes", "notes.md", "notes.md", "hello\n")});
    defer {
        for (sections) |*s| model.freeSection(gpa, s);
        gpa.free(sections);
    }

    try model.filterEmpty(gpa, &sections);
    try std.testing.expectEqual(@as(usize, 1), sections.len);
}

test "filterEmpty keeps a .file with its own doc comment despite no children" {
    const gpa = std.testing.allocator;
    var sections = try gpa.dupe(model.Section, &.{model.Section{
        .name = try gpa.dupe(u8, "documented.zig"),
        .path = try gpa.dupe(u8, "documented"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, "A file-level doc comment."),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, "documented.zig"),
        .sourceLine = 0,
        .kind = .file,
        .children = &.{},
    }});
    defer {
        for (sections) |*s| model.freeSection(gpa, s);
        gpa.free(sections);
    }

    try model.filterEmpty(gpa, &sections);
    try std.testing.expectEqual(@as(usize, 1), sections.len);
}

test "filterEmpty keeps a .file with no doc comment but a surviving child" {
    const gpa = std.testing.allocator;
    const child = model.Section{
        .name = try gpa.dupe(u8, "add"),
        .path = try gpa.dupe(u8, "add"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, "Adds two numbers."),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, "math.zig"),
        .sourceLine = 0,
        .kind = .fn_decl,
        .children = &.{},
    };
    var sections = try gpa.dupe(model.Section, &.{model.Section{
        .name = try gpa.dupe(u8, "math.zig"),
        .path = try gpa.dupe(u8, "math"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, "math.zig"),
        .sourceLine = 0,
        .kind = .file,
        .children = try gpa.dupe(model.Section, &.{child}),
    }});
    defer {
        for (sections) |*s| model.freeSection(gpa, s);
        gpa.free(sections);
    }

    try model.filterEmpty(gpa, &sections);
    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expectEqual(@as(usize, 1), sections[0].children.len);
}

test "filterEmpty drops a .file left childless after its only child is itself pruned empty" {
    const gpa = std.testing.allocator;
    const nestedEmptyFile = model.Section{
        .name = try gpa.dupe(u8, "inner.zig"),
        .path = try gpa.dupe(u8, "dir.inner"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, "dir/inner.zig"),
        .sourceLine = 0,
        .kind = .file,
        .children = &.{},
    };
    var sections = try gpa.dupe(model.Section, &.{model.Section{
        .name = try gpa.dupe(u8, "dir"),
        .path = try gpa.dupe(u8, "dir"),
        .signature = try gpa.dupe(u8, ""),
        .docComment = try gpa.dupe(u8, ""),
        .source = try gpa.dupe(u8, ""),
        .sourceFile = try gpa.dupe(u8, ""),
        .sourceLine = 0,
        .kind = .file,
        .children = try gpa.dupe(model.Section, &.{nestedEmptyFile}),
    }});
    defer {
        for (sections) |*s| model.freeSection(gpa, s);
        gpa.free(sections);
    }

    try model.filterEmpty(gpa, &sections);
    try std.testing.expectEqual(@as(usize, 0), sections.len);
}

test "relativeHref never strips index.md, prettyUrls only applies to html" {
    const gpa = std.testing.allocator;
    const href = try model.relativeHref(gpa, "render/foo.md", "index.md", true);
    defer gpa.free(href);
    try std.testing.expectEqualStrings("../index.md", href);
}

test "relativeHref with prettyUrls leaves non-index targets untouched" {
    const gpa = std.testing.allocator;
    const href = try model.relativeHref(gpa, "index.html", "render/foo.html", true);
    defer gpa.free(href);
    try std.testing.expectEqualStrings("render/foo.html", href);
}
test "Options{} struct defaults match the html format defaults" {
    const opts = options.Options{};
    try std.testing.expectEqual(options.Format.html, opts.format);
    try std.testing.expectEqual(options.Discover.fs, opts.discover);
    try std.testing.expectEqual(options.Split.none, opts.split);
    try std.testing.expectEqual(options.SourceMode.resizable, opts.source);
    try std.testing.expectEqual(true, opts.index);
    try std.testing.expectEqual(true, opts.ext);
    try std.testing.expectEqual(true, opts.dir);
    try std.testing.expectEqual(true, opts.tree);
    try std.testing.expectEqual(false, opts.prettyUrls);
    try std.testing.expectEqual(true, opts.codelinks);
    try std.testing.expectEqual(options.CssMode.embed, opts.css);
    try std.testing.expectEqual(options.Theme.auto, opts.theme);
    try std.testing.expectEqual(options.Collapse.all, opts.collapse);
    try std.testing.expectEqual(options.DirOrder.first, opts.dirOrder);
    try std.testing.expectEqualStrings(options.defaultHead, opts.head);
    try std.testing.expectEqualStrings("zigdoc", opts.out);
    try std.testing.expectEqualStrings("index.html", opts.filename);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.title);
    try std.testing.expectEqual(true, opts.shows(.file));
    try std.testing.expectEqual(true, opts.fileDir);
    try std.testing.expectEqual(true, opts.shows(.linenum));
    try std.testing.expectEqual(false, opts.shows(.fields));
    try std.testing.expectEqual(true, opts.subheadings);
    try std.testing.expectEqual(true, opts.breadcrumb);
    try std.testing.expectEqualStrings("", opts.prepend);
    try std.testing.expectEqualStrings("", opts.append);
    try std.testing.expectEqualStrings("", opts.desc);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.tplHtmlDoc);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.tplHtmlSec);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.tplMdDoc);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.tplMdSec);
    try std.testing.expectEqual(false, opts.private);
    try std.testing.expectEqual(false, opts.showEmpty);
}

test "parseArgs applies search override" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--search", "on", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(true, opts.search);
}

test "parseArgs applies private override" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--private", "on", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(true, opts.private);
}

test "parseArgs applies showempty override" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--showempty", "on", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(true, opts.showEmpty);
}

test "parseArgs applies discover override" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--discover", "ns", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.Discover.ns, opts.discover);
}

test "parseArgs accepts --split ns as an alias for --split file" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--split", "ns", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.Split.file, opts.split);
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
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.Format.md, opts.format);
    try std.testing.expectEqual(options.Split.item, opts.split);
    try std.testing.expectEqual(options.SourceMode.inline_, opts.source);
    try std.testing.expectEqual(false, opts.index);
    try std.testing.expectEqualStrings("My Project", opts.title.?);
    try std.testing.expectEqual(@as(usize, 1), opts.inputs.len);
}

test "parseArgs defaults source and filename to html when format is unset" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{"input.zig"};
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.SourceMode.resizable, opts.source);
    try std.testing.expectEqualStrings("index.html", opts.filename);
}

test "parseArgs defaults source and filename to md when format is md" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.SourceMode.none, opts.source);
    try std.testing.expectEqualStrings("index.md", opts.filename);
}

test "parseArgs resolves format-dependent defaults regardless of flag order" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "input.zig", "--format", "md" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.SourceMode.none, opts.source);
    try std.testing.expectEqualStrings("index.md", opts.filename);
}

test "parseArgs falls back to none for resizable source with md format, with a warning" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md", "--source", "resizable", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    defer {
        for (opts.parseWarnings) |w| gpa.free(w);
        gpa.free(opts.parseWarnings);
    }
    try std.testing.expectEqual(options.SourceMode.none, opts.source);
    try std.testing.expectEqual(@as(usize, 1), opts.parseWarnings.len);
}

test "parseArgs falls back to none for collapsed source with md format, with a warning" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md", "--source", "collapsed", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    defer {
        for (opts.parseWarnings) |w| gpa.free(w);
        gpa.free(opts.parseWarnings);
    }
    try std.testing.expectEqual(options.SourceMode.none, opts.source);
    try std.testing.expectEqual(@as(usize, 1), opts.parseWarnings.len);
}

test "parseArgs falls back to none for tab source with md format, with a warning" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md", "--split", "item", "--source", "tab", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    defer {
        for (opts.parseWarnings) |w| gpa.free(w);
        gpa.free(opts.parseWarnings);
    }
    try std.testing.expectEqual(options.SourceMode.none, opts.source);
    try std.testing.expectEqual(@as(usize, 1), opts.parseWarnings.len);
}

test "parseArgs falls back to none for tab source without split=item, with a warning" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--source", "tab", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    defer {
        for (opts.parseWarnings) |w| gpa.free(w);
        gpa.free(opts.parseWarnings);
    }
    try std.testing.expectEqual(options.SourceMode.none, opts.source);
    try std.testing.expectEqual(@as(usize, 1), opts.parseWarnings.len);
}

test "parseArgs falls back to none for tab pagesource with split=none, with a warning" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--pagesource", "tab", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    defer {
        for (opts.parseWarnings) |w| gpa.free(w);
        gpa.free(opts.parseWarnings);
    }
    try std.testing.expectEqual(options.SourceMode.none, opts.pageSource);
    try std.testing.expectEqual(@as(usize, 1), opts.parseWarnings.len);
}

test "parseArgs accepts tab pagesource with split=file" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--split", "file", "--pagesource", "tab", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.SourceMode.tab, opts.pageSource);
}

test "parseArgs accepts tab pagesource with split=ns (alias for file)" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--split", "ns", "--pagesource", "tab", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.SourceMode.tab, opts.pageSource);
    try std.testing.expectEqual(options.Split.file, opts.split);
}

test "parseArgs accepts tab source with split=item" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--split", "item", "--source", "tab", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.SourceMode.tab, opts.source);
}

test "parseArgs accepts tab pagesource with split=item" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--split", "item", "--pagesource", "tab", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.SourceMode.tab, opts.pageSource);
}

test "parseArgs allows explicit inline source with md format" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md", "--source", "inline", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.SourceMode.inline_, opts.source);
}

test "parseArgs applies show override, defaulting to file,linenum" {
    const gpa = std.testing.allocator;
    const defaultArgs = [_][]const u8{"input.zig"};
    const defaults = try options.parseArgs(gpa, &defaultArgs);
    defer gpa.free(defaults.inputs);
    defer gpa.free(defaults.filetypes);
    defer gpa.free(defaults.show);
    try std.testing.expectEqual(false, defaults.shows(.fields));
    try std.testing.expectEqual(true, defaults.shows(.file));
    try std.testing.expectEqual(true, defaults.shows(.linenum));

    const args = [_][]const u8{ "--show", "fields", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(true, opts.shows(.fields));
    try std.testing.expectEqual(false, opts.shows(.file));
}

test "parseArgs applies tests override, defaulting none" {
    const gpa = std.testing.allocator;
    const defaultArgs = [_][]const u8{"input.zig"};
    const defaults = try options.parseArgs(gpa, &defaultArgs);
    defer gpa.free(defaults.inputs);
    defer gpa.free(defaults.filetypes);
    defer gpa.free(defaults.show);
    try std.testing.expectEqual(options.TestsMode.none, defaults.tests);

    const args = [_][]const u8{ "--tests", "resizable", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.TestsMode.resizable, opts.tests);
}

test "parseArgs accepts inline as a tests value" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--tests", "inline", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.TestsMode.inline_, opts.tests);
}

test "parseArgs falls back to none for resizable tests with md format, with a warning" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md", "--tests", "resizable", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    defer {
        for (opts.parseWarnings) |w| gpa.free(w);
        gpa.free(opts.parseWarnings);
    }
    try std.testing.expectEqual(options.TestsMode.none, opts.tests);
    try std.testing.expectEqual(@as(usize, 1), opts.parseWarnings.len);
}

test "parseArgs falls back to none for collapsed tests with md format, with a warning" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md", "--tests", "collapsed", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    defer {
        for (opts.parseWarnings) |w| gpa.free(w);
        gpa.free(opts.parseWarnings);
    }
    try std.testing.expectEqual(options.TestsMode.none, opts.tests);
    try std.testing.expectEqual(@as(usize, 1), opts.parseWarnings.len);
}

test "parseArgs allows explicit inline tests with md format" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md", "--tests", "inline", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.TestsMode.inline_, opts.tests);
}

test "parseArgs applies show/filedir/subheadings/filename overrides" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{
        "--show",         "all,-file,-linenum",
        "--filedir",      "off",
        "--subheadings",  "on",
        "--filename",     "custom.html",
        "input.zig",
    };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(false, opts.shows(.file));
    try std.testing.expectEqual(false, opts.fileDir);
    try std.testing.expectEqual(false, opts.shows(.linenum));
    try std.testing.expectEqual(true, opts.shows(.fields));
    try std.testing.expectEqual(true, opts.subheadings);
    try std.testing.expectEqualStrings("custom.html", opts.filename);
}

test "parseArgs applies theme override" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--theme", "dark", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.Theme.dark, opts.theme);
}

test "parseArgs applies ext/dir/tree overrides" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{
        "--ext",  "off",
        "--dir",  "off",
        "--tree", "off",
        "input.zig",
    };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(false, opts.ext);
    try std.testing.expectEqual(false, opts.dir);
    try std.testing.expectEqual(false, opts.tree);
}

test "parseArgs applies exturls/dirurls overrides, defaulting both on" {
    const gpa = std.testing.allocator;
    const defaultArgs = [_][]const u8{"input.zig"};
    const defaults = try options.parseArgs(gpa, &defaultArgs);
    defer gpa.free(defaults.inputs);
    defer gpa.free(defaults.filetypes);
    defer gpa.free(defaults.show);
    try std.testing.expectEqual(true, defaults.extUrls);
    try std.testing.expectEqual(true, defaults.dirUrls);

    const args = [_][]const u8{
        "--exturls", "off",
        "--dirurls", "off",
        "input.zig",
    };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(false, opts.extUrls);
    try std.testing.expectEqual(false, opts.dirUrls);
}

test "parseArgs defaults codelinks on for html, off for md" {
    const gpa = std.testing.allocator;

    const htmlArgs = [_][]const u8{"input.zig"};
    const htmlOpts = try options.parseArgs(gpa, &htmlArgs);
    defer gpa.free(htmlOpts.inputs);
    defer gpa.free(htmlOpts.filetypes);
    defer gpa.free(htmlOpts.show);
    try std.testing.expectEqual(true, htmlOpts.codelinks);

    const mdArgs = [_][]const u8{ "--format", "md", "input.zig" };
    const mdOpts = try options.parseArgs(gpa, &mdArgs);
    defer gpa.free(mdOpts.inputs);
    defer gpa.free(mdOpts.filetypes);
    defer gpa.free(mdOpts.show);
    try std.testing.expectEqual(false, mdOpts.codelinks);
}

test "parseArgs accepts --omitkind file alongside decl kinds" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--omitkind", "fn,file,struct", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.OmitKind);
    defer gpa.free(opts.show);

    try std.testing.expectEqual(@as(usize, 3), opts.OmitKind.len);
    try std.testing.expectEqual(options.OmitKind.fn_decl, opts.OmitKind[0]);
    try std.testing.expectEqual(options.OmitKind.file, opts.OmitKind[1]);
    try std.testing.expectEqual(options.OmitKind.struct_decl, opts.OmitKind[2]);
}

test "parseArgs accepts --omitdoc as a comma-separated list, dropping none and unknown entries" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--omitdoc", "functions,values,bogus,none", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.omitDoc);
    defer gpa.free(opts.show);
    defer {
        for (opts.parseWarnings) |w| gpa.free(w);
        gpa.free(opts.parseWarnings);
    }

    try std.testing.expectEqual(@as(usize, 2), opts.omitDoc.len);
    try std.testing.expectEqual(options.OmitDocFlag.functions, opts.omitDoc[0]);
    try std.testing.expectEqual(options.OmitDocFlag.values, opts.omitDoc[1]);
    try std.testing.expectEqual(@as(usize, 1), opts.parseWarnings.len);
}

test "parseArgs defaults --omitdoc to empty" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{"input.zig"};
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);

    try std.testing.expectEqual(@as(usize, 0), opts.omitDoc.len);
}

test "parseArgs defaults showPub to true, applies explicit override" {
    const gpa = std.testing.allocator;

    const defaultArgs = [_][]const u8{"input.zig"};
    const defaultOpts = try options.parseArgs(gpa, &defaultArgs);
    defer gpa.free(defaultOpts.inputs);
    defer gpa.free(defaultOpts.filetypes);
    defer gpa.free(defaultOpts.show);
    try std.testing.expectEqual(true, defaultOpts.showPub);

    const offArgs = [_][]const u8{ "--showpub", "off", "input.zig" };
    const offOpts = try options.parseArgs(gpa, &offArgs);
    defer gpa.free(offOpts.inputs);
    defer gpa.free(offOpts.filetypes);
    defer gpa.free(offOpts.show);
    try std.testing.expectEqual(false, offOpts.showPub);
}

test "parseArgs applies explicit codelinks override regardless of format default" {
    const gpa = std.testing.allocator;

    const offArgs = [_][]const u8{ "--codelinks", "off", "input.zig" };
    const offOpts = try options.parseArgs(gpa, &offArgs);
    defer gpa.free(offOpts.inputs);
    defer gpa.free(offOpts.filetypes);
    defer gpa.free(offOpts.show);
    try std.testing.expectEqual(false, offOpts.codelinks);

    const onArgs = [_][]const u8{ "--format", "md", "--codelinks", "on", "input.zig" };
    const onOpts = try options.parseArgs(gpa, &onArgs);
    defer gpa.free(onOpts.inputs);
    defer gpa.free(onOpts.filetypes);
    defer gpa.free(onOpts.show);
    try std.testing.expectEqual(true, onOpts.codelinks);
}

test "parseArgs resolves codelinks default regardless of flag order" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "input.zig", "--format", "md" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(false, opts.codelinks);
}

test "parseArgs applies prettyurls override, defaulting off" {
    const gpa = std.testing.allocator;
    const defaultArgs = [_][]const u8{"input.zig"};
    const defaults = try options.parseArgs(gpa, &defaultArgs);
    defer gpa.free(defaults.inputs);
    defer gpa.free(defaults.filetypes);
    defer gpa.free(defaults.show);
    try std.testing.expectEqual(false, defaults.prettyUrls);

    const args = [_][]const u8{ "--prettyurls", "on", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(true, opts.prettyUrls);
}

test "parseArgs applies collapse override" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--collapse", "dir", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.Collapse.dir, opts.collapse);
}

test "parseArgs applies dirorder override" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--dirorder", "last", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqual(options.DirOrder.last, opts.dirOrder);
}

test "parseArgs applies head override" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--head", "<meta name=\"x\">", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
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
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
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
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
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
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    try std.testing.expectEqualStrings("a.tpl", opts.tplHtmlDoc.?);
    try std.testing.expectEqualStrings("b.tpl", opts.tplHtmlSec.?);
    try std.testing.expectEqualStrings("c.tpl", opts.tplMdDoc.?);
    try std.testing.expectEqualStrings("d.tpl", opts.tplMdSec.?);
}

test "parseArgs warns and ignores an unknown option, keeping other inputs" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--bogus", "x", "input.zig" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    defer {
        for (opts.parseWarnings) |w| gpa.free(w);
        gpa.free(opts.parseWarnings);
    }
    try std.testing.expectEqual(@as(usize, 1), opts.inputs.len);
    try std.testing.expectEqualStrings("input.zig", opts.inputs[0]);
    try std.testing.expectEqual(@as(usize, 1), opts.parseWarnings.len);
}

test "parseArgs succeeds with zero inputs; nothing-to-document is reported by the caller, not parsing" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--format", "md" };
    const opts = try options.parseArgs(gpa, &args);
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.filetypes);
    defer gpa.free(opts.show);
    defer {
        for (opts.parseWarnings) |w| gpa.free(w);
        gpa.free(opts.parseWarnings);
    }
    try std.testing.expectEqual(@as(usize, 0), opts.inputs.len);
}
// ===========================================================================
// render.zig tests
// ===========================================================================

// Test-only fixture/support helpers for render.zig's own tests --
// moved here alongside them.

fn renderTestWrite(gpa: std.mem.Allocator, fmt: render.Format, tree: model.DocTree, title: []const u8, opts: options.Options) ![]render.Page {
    var testWriteProgress: progress.Progress = .{};
    return switch (fmt) {
        .html => render.write(gpa, .html, tree, title, opts, template.htmlDoc, template.htmlSec, &testWriteProgress),
        .md => render.write(gpa, .md, tree, title, opts, template.mdDoc, template.mdSec, &testWriteProgress),
    };
}

// Resolves an href emitted on the page at fromPath (relative to that
// page's own directory, ../ included) back to an output-root-relative
// path, so it can be checked against a set of written page paths.
fn renderResolveTestHref(gpa: std.mem.Allocator, fromPath: []const u8, href: []const u8) ![]u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(gpa);
    var fromIt = std.mem.splitScalar(u8, fromPath, '/');
    var fromParts: std.ArrayList([]const u8) = .empty;
    defer fromParts.deinit(gpa);
    while (fromIt.next()) |seg| try fromParts.append(gpa, seg);
    if (fromParts.items.len > 0) fromParts.items.len -= 1; // drop the filename itself
    try dirs.appendSlice(gpa, fromParts.items);

    var hrefIt = std.mem.splitScalar(u8, href, '/');
    while (hrefIt.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) {
            if (dirs.items.len > 0) dirs.items.len -= 1;
        } else if (seg.len == 0 or std.mem.eql(u8, seg, ".")) {
            continue;
        } else {
            try dirs.append(gpa, seg);
        }
    }
    return std.mem.join(gpa, "/", dirs.items);
}

fn renderTestSection(kind: model.Kind, children: []model.Section) model.Section {
    return .{
        .name = "",
        .path = "",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "",
        .sourceLine = 0,
        .kind = kind,
        .children = children,
        .hasChildren = children.len > 0,
        .isFileRoot = kind == .file or kind == .namespace,
    };
}

test "split item: single-file input's root index links match the decl's real page path" {
    const gpa = std.testing.allocator;

    const structSection = model.Section{
        .name = "Fuzzer",
        .path = "Fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .struct_decl,
        .children = &.{},
        .fileLabel = "",
    };
    var sections = [_]model.Section{structSection};
    const tree = model.DocTree{ .moduleName = "fuzzer", .rootDocComment = null, .sections = &sections };

    const pages = try renderTestWrite(gpa, .html, tree, "fuzzer", options.Options{ .split = .item, .tree = true, .extUrls = false, .dirUrls = true, .index = true });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var rootIndex: ?[]const u8 = null;
    var pathSet = std.StringHashMap(void).init(gpa);
    defer pathSet.deinit();
    for (pages) |p| {
        try pathSet.put(p.filename, {});
        if (std.mem.eql(u8, p.filename, "index.html")) rootIndex = p.contents;
    }
    try std.testing.expect(rootIndex != null);
    // The root index must link to a page that was actually written.
    try std.testing.expect(std.mem.indexOf(u8, rootIndex.?, "href=\"Fuzzer/index.html\"") != null or std.mem.indexOf(u8, rootIndex.?, "href=\"Fuzzer.html\"") != null);
}

test "split item: a file's root index link matches its decl's real (case-preserved) page path" {
    const gpa = std.testing.allocator;

    const structDecl = model.Section{
        .name = "Fuzzer",
        .path = "Fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .struct_decl,
        .children = &.{},
        .fileLabel = "",
    };
    var declChildren = [_]model.Section{structDecl};
    const fileSection = model.Section{
        .name = "fuzzer.zig",
        .path = "fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .file,
        .isFileRoot = true,
        .children = &declChildren,
        .fileLabel = "fuzzer.zig",
    };
    var sections = [_]model.Section{fileSection};
    const tree = model.DocTree{ .moduleName = "myproject", .rootDocComment = null, .sections = &sections, .rootIsDir = true };

    const pages = try renderTestWrite(gpa, .html, tree, "myproject", options.Options{ .split = .item, .tree = true, .extUrls = false, .dirUrls = true, .index = true, .breadcrumb = false });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var writtenPaths = std.StringHashMap(void).init(gpa);
    defer writtenPaths.deinit();
    for (pages) |p| try writtenPaths.put(p.filename, {});
    // The struct's own page must have been written with case preserved.
    try std.testing.expect(writtenPaths.contains("fuzzer/Fuzzer/index.html"));

    var fileIndex: ?[]const u8 = null;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "fuzzer/index.html")) fileIndex = p.contents;
    }
    try std.testing.expect(fileIndex != null);
    // Whatever href the file's own index page emits for "Fuzzer" must
    // point at a page that was actually written.
    const hrefNeedle = "<a href=\"";
    const hrefStart = std.mem.indexOf(u8, fileIndex.?, hrefNeedle).? + hrefNeedle.len;
    const hrefEnd = std.mem.indexOfScalarPos(u8, fileIndex.?, hrefStart, '"').?;
    const href = fileIndex.?[hrefStart..hrefEnd];
    const resolved = try renderResolveTestHref(gpa, "fuzzer/index.html", href);
    defer gpa.free(resolved);
    try std.testing.expect(writtenPaths.contains(resolved) or std.mem.eql(u8, resolved, "Fuzzer/index.html"));
}

test "split item: sibling decls whose names differ only by case get distinct pages, resolved consistently between the file page and the actual write" {
    const gpa = std.testing.allocator;

    const fnDecl = model.Section{
        .name = "fuzzer",
        .path = "fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .fn_decl,
        .children = &.{},
        .fileLabel = "",
    };
    const structDecl = model.Section{
        .name = "Fuzzer",
        .path = "Fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .struct_decl,
        .children = &.{},
        .fileLabel = "",
    };
    var declChildren = [_]model.Section{ fnDecl, structDecl };
    const fileSection = model.Section{
        .name = "fuzzer.zig",
        .path = "fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .file,
        .isFileRoot = true,
        .children = &declChildren,
        .fileLabel = "fuzzer.zig",
    };
    var sections = [_]model.Section{fileSection};
    const tree = model.DocTree{ .moduleName = "myproject", .rootDocComment = null, .sections = &sections, .rootIsDir = true };

    const pages = try renderTestWrite(gpa, .html, tree, "myproject", options.Options{ .split = .item, .tree = true, .extUrls = false, .dirUrls = true, .index = true, .breadcrumb = false });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var lowerWritten = std.StringHashMap(void).init(gpa);
    defer {
        var it = lowerWritten.iterator();
        while (it.next()) |e| gpa.free(@constCast(e.key_ptr.*));
        lowerWritten.deinit();
    }
    var writtenPaths = std.StringHashMap(void).init(gpa);
    defer writtenPaths.deinit();
    for (pages) |p| {
        try writtenPaths.put(p.filename, {});
        const lower = try std.ascii.allocLowerString(gpa, p.filename);
        // Two written pages must never collapse to the same path on a
        // case-insensitive filesystem.
        try std.testing.expect(!lowerWritten.contains(lower));
        try lowerWritten.put(lower, {});
    }

    var fileIndex: ?[]const u8 = null;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "fuzzer/index.html")) fileIndex = p.contents;
    }
    try std.testing.expect(fileIndex != null);
    // Every href on the file's own index page must point at a page
    // that was actually written.
    var searchFrom: usize = 0;
    const needle = "<a href=\"";
    while (std.mem.indexOfPos(u8, fileIndex.?, searchFrom, needle)) |start| {
        const hrefStart = start + needle.len;
        const hrefEnd = std.mem.indexOfScalarPos(u8, fileIndex.?, hrefStart, '"').?;
        const href = fileIndex.?[hrefStart..hrefEnd];
        const resolved = try renderResolveTestHref(gpa, "fuzzer/index.html", href);
        defer gpa.free(resolved);
        try std.testing.expect(writtenPaths.contains(resolved));
        searchFrom = hrefEnd;
    }
}

test "split file: a nested file's page lives at its real directory path" {
    const gpa = std.testing.allocator;

    const fileSection = model.Section{
        .name = "html_single.zig",
        .path = "html_single",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "src/render/html_single.zig",
        .sourceLine = 0,
        .kind = .file,
        .isFileRoot = true,
        .children = &.{},
        .fileLabel = "render/html_single.zig",
    };
    var sections = [_]model.Section{fileSection};
    const tree = model.DocTree{ .moduleName = "combined", .rootDocComment = null, .sections = &sections, .rootIsDir = true };

    const pages = try renderTestWrite(gpa, .html, tree, "myproject", options.Options{ .split = .file, .tree = true });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var foundFilePage = false;
    var foundDirPage = false;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "render/html_single.zig/index.html")) foundFilePage = true;
        if (std.mem.eql(u8, p.filename, "render/index.html")) foundDirPage = true;
    }
    try std.testing.expect(foundFilePage);
    try std.testing.expect(foundDirPage);
}

test "split file: --pagesource tab wraps the whole inlined page as the Doc pane against the file's own source" {
    const gpa = std.testing.allocator;

    const fnDecl = model.Section{
        .name = "run",
        .path = "run",
        .signature = "",
        .docComment = "",
        .source = "pub fn run() void {}",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .fn_decl,
        .children = &.{},
        .fileLabel = "",
    };
    var declChildren = [_]model.Section{fnDecl};
    const fileSection = model.Section{
        .name = "fuzzer.zig",
        .path = "fuzzer",
        .signature = "",
        .docComment = "",
        .source = "pub fn run() void {}",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .file,
        .isFileRoot = true,
        .children = &declChildren,
        .fileLabel = "fuzzer.zig",
    };
    var sections = [_]model.Section{fileSection};
    const tree = model.DocTree{ .moduleName = "myproject", .rootDocComment = null, .sections = &sections, .rootIsDir = true };

    const pages = try renderTestWrite(gpa, .html, tree, "myproject", options.Options{ .split = .file, .pageSource = .tab, .extUrls = false });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var fileIndex: ?[]const u8 = null;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "fuzzer/index.html")) fileIndex = p.contents;
    }
    try std.testing.expect(fileIndex != null);
    // The Doc pane holds the inlined decl; the Source pane holds the
    // file's own source, both inside one page-level tab shell. Source
    // text is syntax-highlighted (tokenized into spans), so check for
    // the decl name rather than an unbroken literal snippet.
    try std.testing.expect(std.mem.indexOf(u8, fileIndex.?, "class=\"tabs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fileIndex.?, "tab-pane-doc") != null);
    try std.testing.expect(std.mem.indexOf(u8, fileIndex.?, "tab-pane-source") != null);
    try std.testing.expect(std.mem.indexOf(u8, fileIndex.?, ">run<") != null);
    // A link landing on this page's hash must force the Doc tab
    // active even if Source was left checked.
    try std.testing.expect(std.mem.indexOf(u8, fileIndex.?, "getElementById('tab-doc')") != null);
    try std.testing.expect(std.mem.indexOf(u8, fileIndex.?, "hashchange") != null);
}

test "split item: a file's slug that collides with a real directory falls back to keeping its extension" {
    const gpa = std.testing.allocator;

    // "src/utils.zig" (a file) and "src/utils/x.zig" (inside a real
    // directory named "utils") would both want the folder
    // "src/utils/" if the file's extension were stripped.
    const utilsFile = model.Section{
        .name = "utils.zig",
        .path = "utils",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "src/utils.zig",
        .sourceLine = 0,
        .kind = .file,
        .isFileRoot = true,
        .children = &.{},
        .fileLabel = "src/utils.zig",
    };
    const xFile = model.Section{
        .name = "x.zig",
        .path = "x",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "src/utils/x.zig",
        .sourceLine = 0,
        .kind = .file,
        .isFileRoot = true,
        .children = &.{},
        .fileLabel = "src/utils/x.zig",
    };
    var sections = [_]model.Section{ utilsFile, xFile };
    const tree = model.DocTree{ .moduleName = "combined", .rootDocComment = null, .sections = &sections, .rootIsDir = true };

    const pages = try renderTestWrite(gpa, .html, tree, "myproject", options.Options{ .split = .file, .tree = true, .extUrls = false, .dirUrls = true });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var foundUtilsFilePage = false;
    var foundUtilsDirPage = false;
    var foundXFilePage = false;
    var pathCounts = std.StringHashMap(usize).init(gpa);
    defer pathCounts.deinit();
    for (pages) |p| {
        const gop = try pathCounts.getOrPut(p.filename);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (std.mem.eql(u8, p.filename, "src/utils.zig/index.html")) foundUtilsFilePage = true;
        if (std.mem.eql(u8, p.filename, "src/utils/index.html")) foundUtilsDirPage = true;
        if (std.mem.eql(u8, p.filename, "src/utils/x/index.html")) foundXFilePage = true;
    }
    // The file kept its extension in its folder name because "utils"
    // was already claimed by the real directory.
    try std.testing.expect(foundUtilsFilePage);
    try std.testing.expect(foundUtilsDirPage);
    try std.testing.expect(foundXFilePage);
    // No two pages ever landed on the same output path.
    var it = pathCounts.valueIterator();
    while (it.next()) |count| try std.testing.expectEqual(@as(usize, 1), count.*);
}

test "split file: --discover ns links every root-level file-boundary sibling, not just the first" {
    const gpa = std.testing.allocator;

    // std.zig's real shape: many `pub const x = @import("x.zig");`
    // siblings directly under root, each crossing into its own file.
    var arrayListChildren = [_]model.Section{.{
        .name = "Aligned",
        .path = "array_list.Aligned",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "array_list.zig",
        .sourceLine = 5,
        .kind = .struct_decl,
        .children = &.{},
        .fileLabel = "",
    }};
    const arrayList = model.Section{
        .name = "array_list",
        .path = "array_list",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "array_list.zig",
        .sourceLine = 1,
        .kind = .struct_decl,
        .isFileRoot = true,
        .children = &arrayListChildren,
        .hasChildren = true,
        .fileLabel = "",
    };
    var hashMapChildren = [_]model.Section{.{
        .name = "AutoHashMap",
        .path = "hash_map.AutoHashMap",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "hash_map.zig",
        .sourceLine = 5,
        .kind = .struct_decl,
        .children = &.{},
        .fileLabel = "",
    }};
    const hashMap = model.Section{
        .name = "hash_map",
        .path = "hash_map",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "hash_map.zig",
        .sourceLine = 1,
        .kind = .struct_decl,
        .isFileRoot = true,
        .children = &hashMapChildren,
        .hasChildren = true,
        .fileLabel = "",
    };
    var rootChildren = [_]model.Section{ arrayList, hashMap };
    const tree = model.DocTree{ .moduleName = "std", .rootDocComment = null, .sourceFile = "std.zig", .sections = &rootChildren };

    const pages = try renderTestWrite(gpa, .html, tree, "std", options.Options{ .split = .file, .extUrls = false });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var rootIndex: ?[]const u8 = null;
    var arrayListPage: ?[]const u8 = null;
    var hashMapPage: ?[]const u8 = null;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "index.html")) rootIndex = p.contents;
        if (std.mem.eql(u8, p.filename, "array_list/index.html")) arrayListPage = p.contents;
        if (std.mem.eql(u8, p.filename, "hash_map/index.html")) hashMapPage = p.contents;
    }
    try std.testing.expect(arrayListPage != null);
    try std.testing.expect(hashMapPage != null);
    try std.testing.expect(std.mem.indexOf(u8, arrayListPage.?, ">Aligned<") != null);
    try std.testing.expect(std.mem.indexOf(u8, hashMapPage.?, ">AutoHashMap<") != null);
    try std.testing.expect(rootIndex != null);
    try std.testing.expect(std.mem.indexOf(u8, rootIndex.?, "href=\"array_list/index.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rootIndex.?, "href=\"hash_map/index.html\"") != null);
    // hash_map/index.html's own nav listing its child AutoHashMap (same
    // file, no boundary crossed) must link to an in-page anchor, not a
    // fabricated standalone page. slugify preserves case/dots, so
    // hash_map.AutoHashMap becomes hash-map.AutoHashMap.
    try std.testing.expect(std.mem.indexOf(u8, hashMapPage.?, "href=\"#hash-map.AutoHashMap\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hashMapPage.?, "AutoHashMap.html") == null);
}

test "split file: a collapsed same-file nested decl puts its own link inside <details>, after <summary>, matching fs mode's directory shape" {
    const gpa = std.testing.allocator;

    const member = model.Section{
        .name = "logTerminalMode",
        .path = "Options.logTerminalMode",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "std.zig",
        .sourceLine = 5,
        .kind = .fn_decl,
        .children = &.{},
        .fileLabel = "",
    };
    var optionsChildren = [_]model.Section{member};
    const options_ = model.Section{
        .name = "Options",
        .path = "Options",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "std.zig",
        .sourceLine = 1,
        .kind = .struct_decl,
        .children = &optionsChildren,
        .hasChildren = true,
        .fileLabel = "",
    };
    var rootChildren = [_]model.Section{options_};
    const tree = model.DocTree{ .moduleName = "std", .rootDocComment = null, .sourceFile = "std.zig", .sections = &rootChildren };

    // .dir is the default collapse mode, but depth 0 only collapses
    // under it, and `Options` is a depth-0 top-level item here — use
    // .all so the assertion doesn't depend on that default.
    const pages = try renderTestWrite(gpa, .html, tree, "std", options.Options{ .split = .file, .extUrls = false, .collapse = .all });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var rootIndex: ?[]const u8 = null;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "index.html")) rootIndex = p.contents;
    }
    try std.testing.expect(rootIndex != null);
    const detailsPos = std.mem.indexOf(u8, rootIndex.?, "<details>");
    const summaryPos = std.mem.indexOf(u8, rootIndex.?, "<summary><span><span class=\"prefix\">pub struct</span> Options</span></summary>");
    const linkPos = std.mem.indexOf(u8, rootIndex.?, "<span class=\"prefix\">pub struct</span> <a href=\"#Options\">Options</a>");
    try std.testing.expect(detailsPos != null);
    try std.testing.expect(summaryPos != null);
    try std.testing.expect(linkPos != null);
    // <details> opens, then <summary> (prefix + name), then the item's
    // own link (prefix again + link) — link comes after both, not
    // before <details> as a sibling, and the prefix shows in both
    // places rather than stranded between <li> and <details>.
    try std.testing.expect(detailsPos.? < summaryPos.?);
    try std.testing.expect(summaryPos.? < linkPos.?);
}

test "split none: a collapsed nested decl puts its own link inside <details>, after <summary>, matching split file's shape" {
    const gpa = std.testing.allocator;

    const member = model.Section{
        .name = "logTerminalMode",
        .path = "Options.logTerminalMode",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "std.zig",
        .sourceLine = 5,
        .kind = .fn_decl,
        .children = &.{},
        .fileLabel = "",
    };
    var optionsChildren = [_]model.Section{member};
    const options_ = model.Section{
        .name = "Options",
        .path = "Options",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "std.zig",
        .sourceLine = 1,
        .kind = .struct_decl,
        .children = &optionsChildren,
        .hasChildren = true,
        .fileLabel = "",
    };
    var rootChildren = [_]model.Section{options_};
    const tree = model.DocTree{ .moduleName = "std", .rootDocComment = null, .sourceFile = "std.zig", .sections = &rootChildren };

    const pages = try renderTestWrite(gpa, .html, tree, "std", options.Options{ .split = .none, .extUrls = false, .collapse = .all });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var rootIndex: ?[]const u8 = null;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "index.html")) rootIndex = p.contents;
    }
    try std.testing.expect(rootIndex != null);
    const detailsPos = std.mem.indexOf(u8, rootIndex.?, "<details>");
    const summaryPos = std.mem.indexOf(u8, rootIndex.?, "<summary><span><span class=\"prefix\">pub struct</span> Options</span></summary>");
    const linkPos = std.mem.indexOf(u8, rootIndex.?, "<span class=\"prefix\">pub struct</span> <a href=\"#Options\">Options</a>");
    try std.testing.expect(detailsPos != null);
    try std.testing.expect(summaryPos != null);
    try std.testing.expect(linkPos != null);
    try std.testing.expect(detailsPos.? < summaryPos.?);
    try std.testing.expect(summaryPos.? < linkPos.?);
}

test "split file: --discover ns gives a realistic re-export (struct_decl, not Kind.namespace) its own page" {
    const gpa = std.testing.allocator;

    // This is the shape a real re-export produces: kind == .struct_decl,
    // isFileRoot == false. Only sourceFile differing from its parent's
    // marks it as a file boundary.
    const innerFn = model.Section{
        .name = "run",
        .path = "ArrayList.run",
        .signature = "",
        .docComment = "",
        .source = "pub fn run() void {}",
        .sourceFile = "array_list.zig",
        .sourceLine = 0,
        .kind = .fn_decl,
        .children = &.{},
        .fileLabel = "",
    };
    var nsChildren = [_]model.Section{innerFn};
    const reExport = model.Section{
        .name = "ArrayList",
        .path = "ArrayList",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "array_list.zig",
        .sourceLine = 12,
        .kind = .struct_decl,
        .isFileRoot = false,
        .children = &nsChildren,
        .hasChildren = true,
        .fileLabel = "",
    };
    var rootChildren = [_]model.Section{reExport};
    const tree = model.DocTree{ .moduleName = "std", .rootDocComment = null, .sourceFile = "std.zig", .sections = &rootChildren };

    const pages = try renderTestWrite(gpa, .html, tree, "std", options.Options{ .split = .file, .extUrls = false });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var rootIndex: ?[]const u8 = null;
    var reExportPage: ?[]const u8 = null;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "index.html")) rootIndex = p.contents;
        if (std.mem.eql(u8, p.filename, "ArrayList/index.html")) reExportPage = p.contents;
    }
    try std.testing.expect(reExportPage != null);
    try std.testing.expect(std.mem.indexOf(u8, reExportPage.?, ">run<") != null);
    try std.testing.expect(rootIndex != null);
    try std.testing.expect(std.mem.indexOf(u8, rootIndex.?, ">run<") == null);
    try std.testing.expect(std.mem.indexOf(u8, rootIndex.?, "href=\"ArrayList/index.html\"") != null);
}

test "split file: --discover ns gives each namespace boundary its own page, not one giant inlined page" {
    const gpa = std.testing.allocator;

    const innerFn = model.Section{
        .name = "run",
        .path = "ArrayList.run",
        .signature = "",
        .docComment = "",
        .source = "pub fn run() void {}",
        .sourceFile = "array_list.zig",
        .sourceLine = 0,
        .kind = .fn_decl,
        .children = &.{},
        .fileLabel = "",
    };
    var nsChildren = [_]model.Section{innerFn};
    const namespaceChild = model.Section{
        .name = "ArrayList",
        .path = "ArrayList",
        .signature = "",
        .docComment = "",
        .source = "pub const ArrayList = struct { ... };",
        .sourceFile = "array_list.zig",
        .sourceLine = 0,
        .kind = .namespace,
        .isFileRoot = true,
        .children = &nsChildren,
        .fileLabel = "",
    };
    var rootChildren = [_]model.Section{namespaceChild};
    const tree = model.DocTree{ .moduleName = "std", .rootDocComment = null, .sections = &rootChildren };

    const pages = try renderTestWrite(gpa, .html, tree, "std", options.Options{ .split = .file, .extUrls = false });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var rootIndex: ?[]const u8 = null;
    var namespacePage: ?[]const u8 = null;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "index.html")) rootIndex = p.contents;
        if (std.mem.eql(u8, p.filename, "ArrayList/index.html")) namespacePage = p.contents;
    }
    // The namespace boundary must have gotten its own page...
    try std.testing.expect(namespacePage != null);
    // ...containing its own inlined decl (heading, untokenized —
    // source text gets syntax-highlighted into spans)...
    try std.testing.expect(std.mem.indexOf(u8, namespacePage.?, ">run<") != null);
    // ...and the root must NOT have inlined that decl itself (no
    // giant single page with everything on it).
    try std.testing.expect(rootIndex != null);
    try std.testing.expect(std.mem.indexOf(u8, rootIndex.?, ">run<") == null);
    try std.testing.expect(std.mem.indexOf(u8, rootIndex.?, "href=\"ArrayList/index.html\"") != null);
}

test "split file: a file named after a Windows-reserved device name gets a tilde suffix" {
    const gpa = std.testing.allocator;

    const nulFile = model.Section{
        .name = "nul.zig",
        .path = "nul",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "nul.zig",
        .sourceLine = 0,
        .kind = .file,
        .isFileRoot = true,
        .children = &.{},
        .fileLabel = "nul.zig",
    };
    var sections = [_]model.Section{nulFile};
    const tree = model.DocTree{ .moduleName = "combined", .rootDocComment = null, .sections = &sections, .rootIsDir = true };

    const pages = try renderTestWrite(gpa, .html, tree, "myproject", options.Options{ .split = .file, .tree = true, .extUrls = false, .dirUrls = true });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var foundSafePage = false;
    for (pages) |p| {
        try std.testing.expect(!std.mem.eql(u8, p.filename, "nul/index.html"));
        if (std.mem.eql(u8, p.filename, "nul~/index.html")) foundSafePage = true;
    }
    try std.testing.expect(foundSafePage);
}

test "split file: --tree off still writes each directory's own page" {
    const gpa = std.testing.allocator;

    const fileSection = model.Section{
        .name = "html_single.zig",
        .path = "html_single",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "src/render/html_single.zig",
        .sourceLine = 0,
        .kind = .file,
        .isFileRoot = true,
        .children = &.{},
        .fileLabel = "render/html_single.zig",
    };
    var sections = [_]model.Section{fileSection};
    const tree = model.DocTree{ .moduleName = "combined", .rootDocComment = null, .sections = &sections, .rootIsDir = true };

    const pages = try renderTestWrite(gpa, .html, tree, "myproject", options.Options{ .split = .file, .tree = false });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var foundDirPage = false;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "render/index.html")) foundDirPage = true;
    }
    try std.testing.expect(foundDirPage);
}

test "relativeHref: prettyurls on a directory-group link matches the shape htmlTreeOnDir builds" {
    // Pins the specific page-path shapes htmlTreeOnDir actually calls
    // relativeHref with, root to a subdirectory group and back.
    const gpa = std.testing.allocator;
    const toDir = try model.relativeHref(gpa, "index.html", "render/index.html", true);
    defer gpa.free(toDir);
    try std.testing.expectEqualStrings("render/", toDir);

    const toFile = try model.relativeHref(gpa, "index.html", "render/html_single.zig/index.html", true);
    defer gpa.free(toFile);
    try std.testing.expectEqualStrings("render/html_single.zig/", toFile);

    const backToRoot = try model.relativeHref(gpa, "render/html_single.zig/index.html", "index.html", true);
    defer gpa.free(backToRoot);
    try std.testing.expectEqualStrings("../../", backToRoot);
}

test "resolveLocLink: a root-level file with filedir on links to the root page, labelled with the root's name" {
    const gpa = std.testing.allocator;
    const opts = options.Options{ .tree = true, .fileDir = true };
    const loc = try render.resolveLocLink(gpa, .html, opts, "ubsan_rt.zig", "ubsan_rt.zig/index.html", "lib/");
    defer loc.deinit(gpa);
    try std.testing.expectEqualStrings("../index.html", loc.href);
    try std.testing.expectEqualStrings("lib/", loc.prefix);
}

test "resolveLocLink: a root-level file with filedir off resolves to no link at all" {
    const gpa = std.testing.allocator;
    const opts = options.Options{ .tree = true, .fileDir = false };
    const loc = try render.resolveLocLink(gpa, .html, opts, "ubsan_rt.zig", "ubsan_rt.zig/index.html", "lib/");
    defer loc.deinit(gpa);
    try std.testing.expectEqualStrings("", loc.href);
    try std.testing.expectEqualStrings("", loc.prefix);
}

test "resolveLocLink: a file inside a subdirectory always links there; filedir prepends the root name onto that link's text" {
    const gpa = std.testing.allocator;

    const withFileDir = try render.resolveLocLink(gpa, .html, options.Options{ .tree = true, .fileDir = true }, "render/html_single.zig", "render/html_single.zig/index.html", "lib/");
    defer withFileDir.deinit(gpa);
    try std.testing.expectEqualStrings("../../render/index.html", withFileDir.href);
    try std.testing.expectEqualStrings("lib/render/", withFileDir.prefix);

    const withoutFileDir = try render.resolveLocLink(gpa, .html, options.Options{ .tree = true, .fileDir = false }, "render/html_single.zig", "render/html_single.zig/index.html", "lib/");
    defer withoutFileDir.deinit(gpa);
    try std.testing.expectEqualStrings("../../render/index.html", withoutFileDir.href);
    try std.testing.expectEqualStrings("render/", withoutFileDir.prefix);
}

test "resolveLocLink: filedir never applies to single-file input (empty fileLabel)" {
    const gpa = std.testing.allocator;
    const opts = options.Options{ .tree = true, .fileDir = true };
    const loc = try render.resolveLocLink(gpa, .html, opts, "", "index.html", "lib/");
    defer loc.deinit(gpa);
    try std.testing.expectEqualStrings("", loc.href);
    try std.testing.expectEqualStrings("", loc.prefix);
}

test "resolveLocLink: --tree off still links, since directory pages exist either way" {
    const gpa = std.testing.allocator;
    const opts = options.Options{ .tree = false, .fileDir = true };

    const rootLoc = try render.resolveLocLink(gpa, .html, opts, "ubsan_rt.zig", "ubsan_rt.zig/index.html", "lib/");
    defer rootLoc.deinit(gpa);
    try std.testing.expectEqualStrings("../index.html", rootLoc.href);
    try std.testing.expectEqualStrings("lib/", rootLoc.prefix);

    const nestedLoc = try render.resolveLocLink(gpa, .html, opts, "render/html_single.zig", "render/html_single.zig/index.html", "lib/");
    defer nestedLoc.deinit(gpa);
    try std.testing.expectEqualStrings("../../render/index.html", nestedLoc.href);
    try std.testing.expectEqualStrings("lib/render/", nestedLoc.prefix);
}

test "resolveLocLink: prettyurls strips index.html from the resolved href" {
    const gpa = std.testing.allocator;
    const opts = options.Options{ .tree = true, .fileDir = true, .prettyUrls = true };
    const loc = try render.resolveLocLink(gpa, .html, opts, "ubsan_rt.zig", "ubsan_rt.zig/index.html", "lib/");
    defer loc.deinit(gpa);
    try std.testing.expectEqualStrings("../", loc.href);
    try std.testing.expectEqualStrings("lib/", loc.prefix);
}

test "resolveLocLink: a file in a real Zig-stdlib-shaped tree (lib/build-web/fuzz.zig) reads as one full path down to its own directory" {
    const gpa = std.testing.allocator;
    const opts = options.Options{ .tree = true, .fileDir = true };
    const loc = try render.resolveLocLink(gpa, .html, opts, "build-web/fuzz.zig", "build-web/fuzz.zig/index.html", "lib/");
    defer loc.deinit(gpa);
    try std.testing.expectEqualStrings("../../build-web/index.html", loc.href);
    try std.testing.expectEqualStrings("lib/build-web/", loc.prefix);
}

test "appendDeclPathSegment: builds one path segment at a time, case preserved" {
    const gpa = std.testing.allocator;
    var reg = render.Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa), .declPathsByPath = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);

    const own = try render.appendDeclPathSegment(gpa, "fuzzer.zig", "Input", reg);
    defer gpa.free(own);
    try std.testing.expectEqualStrings("fuzzer.zig/Input", own);

    const nested = try render.appendDeclPathSegment(gpa, own, "deinit", reg);
    defer gpa.free(nested);
    try std.testing.expectEqualStrings("fuzzer.zig/Input/deinit", nested);
}

test "appendDeclPathSegment: an empty parent (single-file input) starts with just the segment" {
    const gpa = std.testing.allocator;
    var reg = render.Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa), .declPathsByPath = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);
    const own = try render.appendDeclPathSegment(gpa, "", "Input", reg);
    defer gpa.free(own);
    try std.testing.expectEqualStrings("Input", own);
}

test "writeIndexItemOpen: showPub on prefixes a pub decl's label with 'pub ' and adds item-pub" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var section = renderTestSection(.fn_decl, &.{});
    section.isPub = true;
    try render.writeIndexItemOpen(gpa, &aw.writer, section, true);

    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "item-fn item-pub") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<span class=\"prefix\">pub fn</span>") != null);
}

test "writeIndexItemOpen: showPub on leaves a private decl's label bare and adds item-priv" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var section = renderTestSection(.fn_decl, &.{});
    section.isPub = false;
    try render.writeIndexItemOpen(gpa, &aw.writer, section, true);

    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "item-fn item-priv") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<span class=\"prefix\">fn</span>") != null);
}

test "writeIndexItemOpen: showPub off never prefixes the label, even for a pub decl" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var section = renderTestSection(.fn_decl, &.{});
    section.isPub = true;
    try render.writeIndexItemOpen(gpa, &aw.writer, section, false);

    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "item-fn item-pub") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<span class=\"prefix\">fn</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "pub fn") == null);
}

test "writeIndexItemOpen: a raw non-zig item gets no kind prefix at all, even with showPub on" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var section = renderTestSection(.file, &.{});
    section.raw = true;
    section.sourceFile = "notes.md";
    try render.writeIndexItemOpen(gpa, &aw.writer, section, true);

    const written = aw.written();
    try std.testing.expectEqualStrings("<li class=\"item-other-md\">", written);
}

test "writeIndexItemOpen: a plain file/directory item skips prefix and pub/priv classes entirely" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const section = renderTestSection(.file, &.{});
    try render.writeIndexItemOpen(gpa, &aw.writer, section, true);

    const written = aw.written();
    try std.testing.expectEqualStrings("<li class=\"item-file\">", written);
}

test "writeIndexItemOpen: a namespace item gets the same treatment as a file item" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const section = renderTestSection(.namespace, &.{});
    try render.writeIndexItemOpen(gpa, &aw.writer, section, true);

    const written = aw.written();
    try std.testing.expectEqualStrings("<li class=\"item-namespace\">", written);
}

test "writeIndexItemOpen: a struct_decl re-export that is isFileRoot still gets its ordinary label" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var section = renderTestSection(.struct_decl, &.{});
    section.isFileRoot = true;
    section.isPub = true;
    try render.writeIndexItemOpen(gpa, &aw.writer, section, true);

    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "<span class=\"prefix\">pub struct</span>") != null);
}

test "pageFilename: a decl with children becomes a folder page; a leaf decl follows --dirurls" {
    const gpa = std.testing.allocator;
    var reg = render.Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa), .declPathsByPath = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);

    var oneChild = [_]model.Section{renderTestSection(.fn_decl, &.{})};
    const withChildren = renderTestSection(.struct_decl, &oneChild);
    const leaf = renderTestSection(.fn_decl, &.{});

    const withChildrenPath = try render.pageFilename(gpa, .html, withChildren, "fuzzer.zig/Input", options.Options{}, reg);
    defer gpa.free(withChildrenPath);
    try std.testing.expectEqualStrings("fuzzer.zig/Input/index.html", withChildrenPath);

    const leafPath = try render.pageFilename(gpa, .html, leaf, "fuzzer.zig/Input/deinit", options.Options{}, reg);
    defer gpa.free(leafPath);
    try std.testing.expectEqualStrings("fuzzer.zig/Input/deinit/index.html", leafPath);

    const leafFlatPath = try render.pageFilename(gpa, .html, leaf, "fuzzer.zig/Input/deinit", options.Options{ .dirUrls = false }, reg);
    defer gpa.free(leafFlatPath);
    try std.testing.expectEqualStrings("fuzzer.zig/Input/deinit.html", leafFlatPath);
}

test "pageFilename: --recursive off still folders a decl that has unextracted children" {
    const gpa = std.testing.allocator;
    var reg = render.Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa), .declPathsByPath = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);

    var unrecursed = renderTestSection(.struct_decl, &.{});
    unrecursed.hasChildren = true;

    const path = try render.pageFilename(gpa, .html, unrecursed, "fuzzer.zig/Input", options.Options{}, reg);
    defer gpa.free(path);
    try std.testing.expectEqualStrings("fuzzer.zig/Input/index.html", path);
}

test "pageFilename: --dirurls off flattens both a decl's leaf page and a childful decl still folders" {
    const gpa = std.testing.allocator;
    var reg = render.Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa), .declPathsByPath = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);
    const opts = options.Options{ .dirUrls = false };

    var oneChild = [_]model.Section{renderTestSection(.fn_decl, &.{})};
    const withChildren = renderTestSection(.struct_decl, &oneChild);
    const declPath = try render.pageFilename(gpa, .html, withChildren, "fuzzer.zig/Input", opts, reg);
    defer gpa.free(declPath);
    try std.testing.expectEqualStrings("fuzzer.zig/Input/index.html", declPath);

    const leaf = renderTestSection(.fn_decl, &.{});
    const leafPath = try render.pageFilename(gpa, .html, leaf, "fuzzer.zig/Input/deinit", opts, reg);
    defer gpa.free(leafPath);
    try std.testing.expectEqualStrings("fuzzer.zig/Input/deinit.html", leafPath);
}

test "pageFilename: file-kind still respects --dirurls, unaffected by the decl-nesting change" {
    const gpa = std.testing.allocator;
    var reg = render.Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa), .declPathsByPath = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);
    try reg.slugs.put(try gpa.dupe(u8, "fuzzer.zig"), try gpa.dupe(u8, "fuzzer.zig"));

    var fileSection = renderTestSection(.file, &.{});
    fileSection.fileLabel = "fuzzer.zig";

    const dirUrlsOn = try render.pageFilename(gpa, .html, fileSection, "", options.Options{ .dirUrls = true }, reg);
    defer gpa.free(dirUrlsOn);
    try std.testing.expectEqualStrings("fuzzer.zig/index.html", dirUrlsOn);

    const dirUrlsOff = try render.pageFilename(gpa, .html, fileSection, "", options.Options{ .dirUrls = false }, reg);
    defer gpa.free(dirUrlsOff);
    try std.testing.expectEqualStrings("fuzzer.zig.html", dirUrlsOff);
}

test "writePageLinkList: a nested-directory file section resolves its href via the file registry, not decl-nesting" {
    const gpa = std.testing.allocator;
    var reg = render.Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa), .declPathsByPath = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);
    // The real per-file registry entry, keyed on the full fileLabel —
    // this is what the file's page was actually written to.
    try reg.slugs.put(try gpa.dupe(u8, "render/html_single.zig"), try gpa.dupe(u8, "render/html_single.zig"));

    var fileSection = renderTestSection(.file, &.{});
    fileSection.name = "html_single.zig";
    fileSection.fileLabel = "render/html_single.zig";

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    // parentDeclPath = "" matches the root `--split item` index call —
    // if writePageLinkList fell back to appendDeclPathSegment here, it
    // would resolve to a bare "html-single-zig" segment instead of the
    // real nested "render/html_single.zig" page.
    try render.writePageLinkList(gpa, .html, &aw.writer, &.{fileSection}, "index.html", "", "index.html", "", options.Options{ .dirUrls = true }, reg, null);

    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "href=\"render/html_single.zig/index.html\"") != null);
}

test "pageFilename: namespace-kind (empty fileLabel) resolves via its registered decl segment, not slugFor(\"\")" {
    const gpa = std.testing.allocator;
    var reg = render.Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa), .declPathsByPath = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);
    // Mirrors buildRegistry's namespace-mode branch: top-level decl
    // segments keyed by ("", name), same slot any other top-level decl
    // uses — not the fileLabel-keyed `slugs` map, which namespace
    // sections never populate (their fileLabel is always "").
    try reg.declSegments.put(try gpa.dupe(u8, "\x00root.child"), try gpa.dupe(u8, "root.child"));
    try reg.declSegments.put(try gpa.dupe(u8, "\x00root.left.shared"), try gpa.dupe(u8, "root.left.shared"));

    var child = renderTestSection(.namespace, &.{});
    child.name = "root.child";
    var shared = renderTestSection(.namespace, &.{});
    shared.name = "root.left.shared";

    const childPath = try render.pageFilename(gpa, .html, child, "", options.Options{ .dirUrls = true }, reg);
    defer gpa.free(childPath);
    try std.testing.expectEqualStrings("root.child/index.html", childPath);

    const sharedPath = try render.pageFilename(gpa, .html, shared, "", options.Options{ .dirUrls = true }, reg);
    defer gpa.free(sharedPath);
    try std.testing.expectEqualStrings("root.left.shared/index.html", sharedPath);

    // The bug this guards against: two distinct namespaces must never
    // collapse onto the same page just because they share an empty
    // fileLabel.
    try std.testing.expect(!std.mem.eql(u8, childPath, sharedPath));
}

test "pageFilename: namespace-kind with no registry entry falls back to a filenameSegment of its own name" {
    const gpa = std.testing.allocator;
    var reg = render.Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa), .declPathsByPath = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);

    var ns = renderTestSection(.namespace, &.{});
    ns.name = "root.child";

    const path = try render.pageFilename(gpa, .html, ns, "", options.Options{ .dirUrls = true }, reg);
    defer gpa.free(path);
    try std.testing.expectEqualStrings("root.child/index.html", path);
}

test "split item end-to-end: --pagesource tab wraps the decl page in a Doc/Source tab shell" {
    const decl = model.Section{
        .name = "add",
        .path = "math.add",
        .signature = "pub fn add(a: i32, b: i32) i32",
        .docComment = "Adds two numbers.",
        .source = "pub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}",
        .sourceFile = "math.zig",
        .sourceLine = 3,
        .kind = .fn_decl,
        .children = &.{},
        .fileLabel = "math.zig",
    };
    const gpa = std.testing.allocator;
    var sections = [_]model.Section{decl};
    const tree = model.DocTree{ .moduleName = "math", .rootDocComment = null, .sections = &sections, .rootIsDir = true };

    const pages = try renderTestWrite(gpa, .html, tree, "myproject", options.Options{ .split = .item, .pageSource = .tab });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var page: ?render.Page = null;
    for (pages) |p| {
        if (std.mem.indexOf(u8, p.contents, "Adds two numbers.") != null) page = p;
    }
    try std.testing.expect(page != null);
    const html = page.?.contents;

    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"tabs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"tab-doc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"tab-src\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span>Doc</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span>Source</span>") != null);
    // Doc pane carries the doc comment; source pane carries the highlighted source.
    try std.testing.expect(std.mem.indexOf(u8, html, "Adds two numbers.") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "tok-kw") != null);
    // Exactly one source pane — {source} isn't separately populated
    // outside the tab shell (buildSectionVars leaves it "" for `tab`).
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "class=\"src-code\""));
}

test "search widget: [u] tip line only appears when this page's own source mode is tab" {
    const decl = model.Section{
        .name = "add",
        .path = "math.add",
        .signature = "",
        .docComment = "Fingerprint for locating this page in test output.",
        .source = "pub fn add() void {}",
        .sourceFile = "math.zig",
        .sourceLine = 1,
        .kind = .fn_decl,
        .children = &.{},
        .fileLabel = "math.zig",
    };
    const gpa = std.testing.allocator;

    var tabSections = [_]model.Section{decl};
    const tabTree = model.DocTree{ .moduleName = "math", .rootDocComment = null, .sections = &tabSections, .rootIsDir = true };
    const tabPages = try renderTestWrite(gpa, .html, tabTree, "myproject", options.Options{ .split = .item, .pageSource = .tab, .search = true });
    defer {
        for (tabPages) |*p| p.deinit(gpa);
        gpa.free(tabPages);
    }
    var tabPage: ?render.Page = null;
    for (tabPages) |p| {
        if (std.mem.indexOf(u8, p.contents, "Fingerprint for locating this page") != null) tabPage = p;
    }
    try std.testing.expect(tabPage != null);
    try std.testing.expect(std.mem.indexOf(u8, tabPage.?.contents, "Jump to source code") != null);

    var resizableSections = [_]model.Section{decl};
    const resizableTree = model.DocTree{ .moduleName = "math", .rootDocComment = null, .sections = &resizableSections, .rootIsDir = true };
    const resizablePages = try renderTestWrite(gpa, .html, resizableTree, "myproject", options.Options{ .split = .item, .pageSource = .resizable, .search = true });
    defer {
        for (resizablePages) |*p| p.deinit(gpa);
        gpa.free(resizablePages);
    }
    var resizablePage: ?render.Page = null;
    for (resizablePages) |p| {
        if (std.mem.indexOf(u8, p.contents, "Fingerprint for locating this page") != null) resizablePage = p;
    }
    try std.testing.expect(resizablePage != null);
    try std.testing.expect(std.mem.indexOf(u8, resizablePage.?.contents, "Jump to source code") == null);
}

test "split item end-to-end: a decl with children nests its own children under it, and this composes with --exturls off" {
    const child = model.Section{
        .name = "deinit",
        .path = "fuzzer.Input.deinit",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .fn_decl,
        .children = &.{},
    };
    var children = [_]model.Section{child};
    const topLevelDecl = model.Section{
        .name = "Input",
        .path = "fuzzer.Input",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .struct_decl,
        .children = &children,
        .hasChildren = true,
    };
    var fileChildren = [_]model.Section{topLevelDecl};
    const fileSection = model.Section{
        .name = "fuzzer.zig",
        .path = "fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .file,
        .isFileRoot = true,
        .children = &fileChildren,
        .fileLabel = "fuzzer.zig",
    };
    const gpa = std.testing.allocator;
    var sections = [_]model.Section{fileSection};
    const tree = model.DocTree{ .moduleName = "combined", .rootDocComment = null, .sections = &sections, .rootIsDir = true };

    const pages = try renderTestWrite(gpa, .html, tree, "myproject", options.Options{ .split = .item, .tree = true, .extUrls = false });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var foundInputPage = false;
    var foundDeinitPage = false;
    for (pages) |p| {
        // extUrls off strips .zig from the *file's* folder name
        // ("fuzzer", not "fuzzer.zig") — Input's own casing is kept,
        // and deinit nests under Input as its own folder page too.
        if (std.mem.eql(u8, p.filename, "fuzzer/Input/index.html")) foundInputPage = true;
        if (std.mem.eql(u8, p.filename, "fuzzer/Input/deinit/index.html")) foundDeinitPage = true;
    }
    try std.testing.expect(foundInputPage);
    try std.testing.expect(foundDeinitPage);
}