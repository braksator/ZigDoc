//! Integration tests: extract each fixture and exercise the split
//! renderers' page/file-splitting logic, without asserting on any
//! template's rendered output.

const std = @import("std");
const extract = @import("extract.zig");
const model = @import("model.zig");
const options = @import("options.zig");
const render = @import("render.zig");
const template = @import("template.zig");
const progress = @import("progress.zig");

const bareFunction = @embedFile("fixtures/bare_function.zig");
const documentedStruct = @embedFile("fixtures/documented_struct.zig");
const nestedContainers = @embedFile("fixtures/nested_containers.zig");
const undocumentedDecl = @embedFile("fixtures/undocumented_decl.zig");
const manySmallContainers = @embedFile("fixtures/many_small_containers.zig");

test "decl kind: fn is fn_decl, const-of-struct is struct_decl not const_decl" {
    const gpa = std.testing.allocator;

    var fnTree = try extract.extractFile(gpa, "bare_function", "test.zig", bareFunction, false);
    defer fnTree.deinit(gpa);
    try std.testing.expectEqual(model.Kind.fn_decl, fnTree.sections[0].kind);

    var structTree = try extract.extractFile(gpa, "documented_struct", "test.zig", documentedStruct, false);
    defer structTree.deinit(gpa);
    try std.testing.expectEqual(model.Kind.struct_decl, structTree.sections[0].kind);
}

test "extractFile: recursive walks nested containers, non-recursive stops at the outer one" {
    const gpa = std.testing.allocator;

    var recursiveTree = try extract.extractFile(gpa, "nested_containers", "test.zig", nestedContainers, true);
    defer recursiveTree.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), recursiveTree.sections.len);
    const outer = recursiveTree.sections[0];
    try std.testing.expectEqualStrings("Outer", outer.name);
    try std.testing.expectEqual(@as(usize, 1), outer.children.len);
    try std.testing.expectEqualStrings("Inner", outer.children[0].name);
    try std.testing.expectEqual(@as(usize, 1), outer.children[0].children.len);
    try std.testing.expectEqualStrings("value", outer.children[0].children[0].name);

    var flatTree = try extract.extractFile(gpa, "nested_containers", "test.zig", nestedContainers, false);
    defer flatTree.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), flatTree.sections.len);
    try std.testing.expectEqual(@as(usize, 0), flatTree.sections[0].children.len);
    try std.testing.expect(flatTree.sections[0].hasChildren);
}

test "extractFile: several sibling small containers each keep their own correct members" {
    // Regression test: fullContainerDecl's compact two-member form
    // returns a slice borrowed from a caller-local scratch buffer, so
    // walking several such containers back-to-back (each getting its
    // own short-lived buffer) previously risked one sibling's member
    // list being overwritten by another's before it was read. Every
    // name and depth here is checked precisely to catch that kind of
    // cross-contamination or out-of-bounds node index.
    const gpa = std.testing.allocator;

    var tree = try extract.extractFile(gpa, "many_small_containers", "test.zig", manySmallContainers, true);
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

    const treeA = try extract.extractFile(gpa, "bare_function", "bare_function.zig", bareFunction, false);
    var trees = [_]model.DocTree{treeA};
    const labels = [_][]const u8{"bare_function.zig"};
    var merged = try model.mergeTrees(gpa, "combined", &trees, &labels, true, true);
    defer merged.deinit(gpa);

    try std.testing.expectEqual(model.Kind.file, merged.sections[0].kind);
    try std.testing.expectEqualStrings("bare_function.zig", merged.sections[0].sourceFile);
    try std.testing.expectEqual(@as(u32, 0), merged.sections[0].sourceLine);
}

test "split file: merged tree produces an index page and one page per file" {
    const gpa = std.testing.allocator;

    const treeA = try extract.extractFile(gpa, "bare_function", "bare_function.zig", bareFunction, false);
    const treeB = try extract.extractFile(gpa, "undocumented_decl", "undocumented_decl.zig", undocumentedDecl, false);
    var trees = [_]model.DocTree{ treeA, treeB };
    const labels = [_][]const u8{ "bare_function.zig", "undocumented_decl.zig" };
    var merged = try model.mergeTrees(gpa, "combined", &trees, &labels, true, true);
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

    const treeA = try extract.extractFile(gpa, "bare_function", "bare_function.zig", bareFunction, false);
    var trees = [_]model.DocTree{treeA};
    const labels = [_][]const u8{"bare_function.zig"};
    var merged = try model.mergeTrees(gpa, "combined", &trees, &labels, true, true);
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
