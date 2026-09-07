//! Build script for the ZigDoc project.
//!
//! `zig build` (compile),
//! `zig build run` (compile and run),
//! `zig build test` (run unit tests),
//! `zig build docs` (generate documentation),
//! `zig build fmt` (format code),
//! `zig build release` (build release binaries).
//! `zig build zip` (zip the source files with powershell).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const minify_mod = b.dependency("minify_zig", .{
        .target = target,
        .optimize = optimize,
    }).module("minify.zig");

    const exe = b.addExecutable(.{
        .name = "zigdoc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("minify.zig", minify_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run zigdoc");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");

    // `src/main.zig` imports (directly or transitively) every other
    // module under `src/`, and its own `test { refAllDecls(...) }`
    // block pulls all of their test blocks into this one target.
    const lib_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_tests_mod.addImport("minify.zig", minify_mod);
    const lib_tests = b.addTest(.{ .root_module = lib_tests_mod });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    // Integration tests, kept as their own target since they exercise
    // the split renderers' page/file-splitting logic end-to-end rather
    // than one module at a time.
    const golden_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    golden_tests_mod.addImport("minify.zig", minify_mod);
    const golden_tests = b.addTest(.{ .root_module = golden_tests_mod });
    test_step.dependOn(&b.addRunArtifact(golden_tests).step);

    // Example integration: generate this project's own docs. `--out` is a
    // directory now (writes zig-out/docs/zigdoc/index.html).
    const docs_run = b.addRunArtifact(exe);
    docs_run.addArgs(&.{ "--out", "zig-out/docs/zigdoc" });
    docs_run.addFileArg(b.path("src/main.zig"));
    docs_run.step.dependOn(b.getInstallStep());
    const docs_step = b.step("docs", "Generate documentation for this project");
    docs_step.dependOn(&docs_run.step);

    // Cross-build for every supported platform and install straight
    // into <project_root>/release/<triple>/, bypassing zig-out.
    const release_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
    };
    const release_step = b.step("release", "Build stripped release binaries for all platforms into /release");
    // Delete stale output directories before building.
    std.Io.Dir.cwd().deleteTree(b.graph.io, "zig-out") catch |err| {
        std.debug.print("warning: failed to delete zig-out: {t}\n", .{err});
    };
    std.Io.Dir.cwd().deleteTree(b.graph.io, "release") catch |err| {
        std.debug.print("warning: failed to delete release: {t}\n", .{err});
    };
    for (release_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const release_minify_mod = b.dependency("minify_zig", .{
            .target = resolved,
            .optimize = .ReleaseFast,
        }).module("minify.zig");
        const release_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = resolved,
            .optimize = .ReleaseFast,
            .strip = true, // no .pdb / debug symbols in the output
        });
        release_mod.addImport("minify.zig", release_minify_mod);
        const release_exe = b.addExecutable(.{
            .name = "zigdoc",
            .root_module = release_mod,
        });
        const triple = query.zigTriple(b.allocator) catch @panic("OOM");
        // dest_dir override is relative to the *install prefix*.
        // Default prefix is zig-out, so ".." walks back to the
        // project root, landing us in <project_root>/release/<triple>/
        // instead of zig-out/release/<triple>/.
        const install = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{
                .override = .{ .custom = b.pathJoin(&.{ "..", "release", triple }) },
            },
        });

        release_step.dependOn(&install.step);
    }


    {
        // Zip the source files with Powershell `zig build zip`.
        const zip_output_name = "zigdoc.zip";
        const zip_includes = [_][]const u8{
            "build.zig",
            "*.md",
            "src",
        };
        var includes_literal: std.ArrayList(u8) = .empty;
        includes_literal.appendSlice(b.allocator, "@(") catch @panic("OOM");
        for (zip_includes, 0..) |item, i| {
            if (i != 0) includes_literal.appendSlice(b.allocator, ",") catch @panic("OOM");
            includes_literal.appendSlice(b.allocator, "\"") catch @panic("OOM");
            includes_literal.appendSlice(b.allocator, item) catch @panic("OOM");
            includes_literal.appendSlice(b.allocator, "\"") catch @panic("OOM");
        }
        includes_literal.appendSlice(b.allocator, ")") catch @panic("OOM");
        const ps_script = b.fmt(
            \\$ErrorActionPreference = "Stop"; $OutputZip = "{s}"; $Include = {s}; $resolvedPaths = @()
            \\foreach ($pattern in $Include) {{
            \\  if ($pattern -match '[\*\?]') {{
            \\    $matches = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
            \\    if (-not $matches -or $matches.Count -eq 0) {{ throw "Include pattern '$pattern' matched no files or folders." }}
            \\    $resolvedPaths += $matches.FullName
            \\  }} else {{
            \\    if (-not (Test-Path -Path $pattern)) {{ throw "Include entry '$pattern' does not exist." }}
            \\    $resolvedPaths += (Resolve-Path -Path $pattern).Path
            \\  }}
            \\}}
            \\$resolvedPaths = $resolvedPaths | Select-Object -Unique
            \\Write-Host "Packaging $($resolvedPaths.Count) item(s) into $OutputZip"; foreach ($p in $resolvedPaths) {{ Write-Host "  - $p" }}
            \\if (Test-Path -Path $OutputZip) {{ Remove-Item -Path $OutputZip -Force }}
            \\Compress-Archive -Path $resolvedPaths -DestinationPath $OutputZip -Force; Write-Host "Wrote $OutputZip"
        , .{ zip_output_name, includes_literal.items });

        const zip_cmd = b.addSystemCommand(&.{
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            ps_script,
        });
        zip_cmd.setCwd(b.path("."));
        const zip_step = b.step("zip", "Package project files into " ++ zip_output_name);
        zip_step.dependOn(&zip_cmd.step);
    }

}
