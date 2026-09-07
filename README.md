# `ZigDoc` - Zig lang *Auto Doc* alternative! 😲

> A static documentation generator for Zig projects.
>
> - HTML or MD output
> - Single flat file, or split up into multiple files
> - Highly configurable and templatable

❌ Zig's built-in *Auto Doc* output requires a webserver to view (the
generated JavaScript won't load over `file://`) and has some longstanding
usability complaints (see
[ziglang/zig#4736](https://github.com/ziglang/zig/issues/4736)).

✔️ **ZigDoc** produces a single HTML file, or a single Markdown file, or a bunch of
plain interlinked files. Just double-click the file and it works like the good old days.


> You can also:
>
> - Integrate the documentation into your website easily
> - Give it to an AI chatbot so it has context about your ramblings
> - Run it on other Zig projects to help understand their codebase


## 🧐 Demo

[ZigDoc Examples](https://braksator.github.io/zigdoc/)


## 🚀 Release executables

### 🔸 They're included

Ready-to-go release binaries are written to `release/<platform>/` for Windows/Mac/Linux.

### 🔸 Compile it yourself

> **Important: This project targets Zig's `0.17-dev` branch.  It won't compile on previous versions.**

`zig build` - The `zigdoc` binary is placed in `zig-out/bin/`.

`zig build release` - The entire `release/` directory (for all platforms) will be regenerated. (`zig-out/` will get deleted too)

### 🔸 Adding this package as a dependency.

> **Important: This project targets Zig's `0.17-dev` branch.  It won't compile on previous versions.**

`zig fetch --save https://github.com/braksator/ZigDoc/archive/refs/tags/v0.2.0.tar.gz`

You'll probably want build.zig integration (described further below).

## 📚 Usage

```
zigdoc [options] <input-path>...
```

(See examples below)

Each `<input-path>` is either a `.zig` file or a directory to recursively document.

### 🔸 Common options

These apply regardless of `--format`.  Some of these options necessarily change/supress the behaviour of other options and features in a sensible way - no need to worry about it.

#### Inputs and outputs

> *Super important options that govern the modes of operation.*

- `--format` (`html`, `md`, default: `html`):
  - Output format. See the lists further down below for format-specific options.
- `--discover` (`fs`, `ns`, default: `fs`):
  - Determines if we're documenting by *FILE SYSTEM* (`fs`) or *NAMESPACE* (`ns`).  The `ns` mode works better if you feed in one root file and it can follow the import graph to find the rest.  The `fs` mode can do a single file or a whole project directory.
- `--split` (`none`, `file`, `ns`, `item`, default: `none`):
  - Output file structure. `none` - one page. `file`/`ns` - split into pages for each. `item` - split into even more pages.
- `--out` (directory path, default: `zigdoc`):
  - Output directory.  **I wouldn't output to directories that contain something already!**
- `--clear` (`on`, `off`, default: `on`):
  - **Deletes any md/html/css/js files from the output directory before running.** *You should probably know this is on by default*

#### Navigation

> *Controls the nav links near the top.*

- `--index` (`on`, `off`, default: `on`):
  - Outputs a "table of contents" style *Index* navigation list at the top. If you don't like it, here's how you get rid of it.
    - > Instead of the Index use `--show all` (or similar) to actually list the child items in categories as part of the doc.
- `--breadcrumb` (`on`, `off`, default: `on`):
  - Show breadcrumb navigation in `--split` modes. Turn it off if you want to provide your own nav or back/home link.

#### Filesystem discovery options

> *Only meaningful under `--discover fs` (the default).*

- `--filetypes` (comma-separated extensions, default: `zig`):
  - By default, ZigDoc just does the `.zig` files, but you can include other files too like: `--filetypes zig,md,css,html`. It can't parse non-zig files, but it can at least include them in the listed items.
- `--ext` (`on`, `off`, default: `on`):
  - Whether the title of "file" items displays the ".zig" extension.
- `--exturls` (`on`, `off`, default: `on`):
  - Whether the URL of "file" items displays the ".zig" extension. That's more correct, and consistent with how clashes in naming would be resolved.
- `--tree` (`on`, `off`, default: `on`):
  - Switches the *Index* navigation list between directory nesting and flat lists.
- `--dir` (`on`, `off`, default: `on`):
  - Can be used to remove the directory path that prefixes "file" items when `--tree` is off.
- `--dirorder` (`first`, `last`, `alpha`, default: `first`):
  - Where to display directories in the *Index* navigation tree.
- `--filedir` (`on`, `off`, default: `on`):
  - Whether the display of a file location includes the parent directory of the documented project.

#### Display text

> *Supply your own strings to be outputted. How string quoting works may be specific to your platform.*

- `--title` (text, default: guessed from the input path's parent directory):
  - The project or website name.  Written at the top of the document and in the HTML title tags.
- `--desc` (raw html/md, default: none):
  - Add your own project description or custom output near the top.
- `--rootname` (text, default: derived from the input path):
  - Overrides the front (or only) page's title so it isn't based on the input directory name.
- `--rootcomment` (markdown, default: none):
  - Overrides the front (or only) page's main content text.
- `--prepend` (raw html/md, default: none):
  - Add your own header/banner/nav etc... or use this along with `--append` to wrap the output.
- `--append` (raw html/md, default: none):
  - Add your own footer or back/home button.

#### Display switches

> *Desirable handy options for what gets displayed. Custom CSS (See **HTML Options**) and **Templating** can be used to fine-tune it further.*

- `--show` (comma-separated list; default: `file,linenum`):
  - Which categories of content render. Options are: `file`, `linenum`, `fields`, `parameters`, `errorsets`, `directories`, `files`, `namespaces`, `structs`, `types`, `values`, `functions`, `funcsigs`, or `all`; prefix an entry with `-` to exclude it from `all`. Example: `--show all,-linenum` shows everything except line numbers. (tip: `funcsigs` is a more verbose variant of `functions`)
- `--subheadings` (`on`, `off`, default: `on`):
  - Print additional subheadings inside declaration sections.

#### URLs

> *Tweaks how URLs will look, and may affect the output file structure.*

- `--prettyurls` (`on`, `off`, default: `off`):
  - Links don't have "index.html" at the end - this ONLY works on a web server configured to handle that.
- `--dirurls` (`on`, `off`, default: `on`):
  - When enabled, the URL of items is the index.html of their own directory. It's nicer and turning it off can make things a bit sus.

#### Processing

> *These ones are just weird.*

- `--itemorder` (`code`, `alpha`, `grouped`, default: `code`):
  - Listed items appear in the same order as in the code. Here you can change the order to be alphabetical or grouped by the kind of item it is.
- `--omitdoc` (comma-separated: `functions`,`fields`, `errors`, `params`, `values`, default: none):
  - Prevents items in these categories getting their own declaration section or page, but they can still receive minimal documentation inline under their parent using the `--show` option.
- `--omitkind` (comma-separated: `fn`, `const`, `var`, `struct`, `enum`, `union`, `opaque`, `file`, default: none):
  - Omits declarations of the given kinds from output entirely. Use with care.
- `--recursive` (`on`, `off`, default: `on`):
  - Also document nested containers (a struct declared inside a struct, etc...), not just top-level declarations in each file.
- `--private` (`on`, `off`, default: `off`):
  - Also document non-`pub` declarations, not just the public API.
- `--showempty` (`on`, `off`, default: `off`):
  - Keep undocumented files/directories.
- `--showpub` (`on`, `off`, default: `on`):
  - Whether to show the keyword `pub` before things if it should be there.

### 🔸 HTML options

- `--search` (`on`, `off`, default: `off`):
  - Adds a search box, and drops in a couple .js files along with the output.
- `--filename` (file name, `index.html`):
  - The output filename.  (Ignored when `--split` is used)
- `--source` (`none`, `collapsed`, `resizable`, `tab`, `inline`, default: `resizable`):
  - Whether and how source code is displayed.
- `--pagesource` (`none`, `collapsed`, `resizable`, `tab`, `inline`, default: `none`):
  - Whether and how the source code of a page's own main item is displayed.  The `tab` option is nice.
- `--tests` (`none`, `collapsed`, `resizable`, `inline`, default: `none`):
  - Whether and how a file's own `test` blocks are displayed as source text.
- `--codelinks` (`on`, `off`, default: `on`):
  - Puts links into signatures and source code for convenience.
- `--css` (`embed`, `external`, default: `embed` when --split is `none` otherwise `external`):
  - Switches between CSS being in a `<style>` tag or in a .css file. External is better for customizations.
- `--theme` (`auto`, `light`, `dark`, default: `auto`):
  - `auto` uses the OS/browser color scheme. `light`/`dark` rigs the page to a consistent scheme.
- `--collapse` (`dir`, `ns`, `top`, `all`, `none`, default: `all`):
  - Changes how collapsing works in the *Index* navigation list.
- `--head` (raw HTML, default: ZigDoc favicon):
  - Stick something into the `<head>` tag. Setting this ditches the ZigDoc favicon.
- `--minify` (`on`, `off`, default: `on`):
  - Controls whether to pump web output through [minify.zig](https://github.com/braksator/minify.zig). Huge difference in output size.

### 🔸 Markdown options (`--format md`)

- `--filename` (file name, default: `index.md`):
  - The output filename.  (Ignored when `--split` is used)
- `--source` (`none`, `inline`, default: `none`):
  - Whether and how source code is displayed.
- `--pagesource` (`none`, `inline`, default: `none`):
  - Whether and how the source code of a page's own main item is displayed.
- `--tests` (`none`, `inline`, default: `none`):
  - Whether and how a file's own `test` blocks are displayed as source text.

### 🎓 Examples

#### 🔸 General usage

Document an entire project with all defaults (single HTML file):

```
zigdoc .
```

Document a specific file in Markdown format with source code included and no
file path. Write it to the "docs" folder, **and delete any html/md already
in there somewhere**.

```
zigdoc --format md --source inline --show linenum --out docs src/root.zig
```

A more AutoDoc-like style showing how this [live example](https://braksator.github.io/zigdoc/split/) was configured:

```
zigdoc -- /zig/lib/std/std.zig --discover ns --split item --title "Zig 0.17.0-dev (Split by item)"  --index off --pagesource tab --show all --prettyurls on --private on --search on --desc "A description of this project/doc" --zd
```

#### 🔸 Generating an `AI_CONTEXT.md` for LLM context

A single-file .md dump of a project's shape, meant to be provided to
an LLM: every declaration's signature and doc comment.

```
zigdoc . --format md --index off --out AI_CONTEXT.md --rootname "My App AI Context" --desc "Auto-generated API reference: signatures and doc comments only, no source code. Don't edit this file."
```

#### 🔸 Build file (`build.zig`) integration

```zig
const zigdoc_dep = b.dependency("zigdoc", .{
    .target = target,
    .optimize = optimize,
});
const zigdoc_exe = zigdoc_dep.artifact("zigdoc");

const docs_step = b.step("docs", "Generate documentation");
const docs_run = b.addRunArtifact(zigdoc_exe);
docs_run.addArgs(&.{
    "--out",    "zig-out/docs/mylib",
    "--split",  "item",
    "--source", "collapsed",
    "--title",  "mylib",
});
docs_run.addFileArg(b.path("src/root.zig"));
docs_step.dependOn(&docs_run.step);
```

Run with `zig build docs`.


## 📝 Templating

**ZigDoc** uses one template for the document and one for declaration sections.
There's a pair for the HTML version and another pair for the Markdown
version.  You can override them with:

- `--htmldoctpl`
- `--htmlsectpl`
- `--mddoctpl`
- `--mdsectpl`

The value for each of those is the path to a template file.  Base your template
files on the ones in this project in `src/templates/` with names corresponding
to these options.

Templating language is simple, just `{variables}` - no logic. In Markdown
the variables automatically have a newline char output after them, so
that's why there's fewer line-breaks in the template.  And you'll notice
line-breaks have to specified with `\n` - just trust me it's better that way.

A variable can also carry its own `format="..."` attribute right in the
template. You'll see it.

This gives you control over the output order and the ability to add custom
wrappers. If you need more than this then CSS/JS is the answer.

Variable names should clue you in to what they are. Depending on the options
that **ZigDoc** is run with, and the context of the output: some variables
will output nothing.

## ☝️ Tips & Advice

### Output files starting with `_` (underscore)

My webhost would 404 on files starting with underscores. Turned out to be
something called Jekyll processing. Adding an empty file called `.nojekyll`
to my web root solved the problem.

### Syntax highlighting

This is built-in for `.zig` code and nothing else.  If you need more
than that you'll have to post-process or attach JS to the front end, perhaps
with something like **highlight.js**. Considered integrating TextMate
grammars, but that is too big of an undertaking.

### Style classes

Most of our CSS is nested in `.zigdoc`, and there is a front-page-only
selector `.zd-root`.

## 💖 Show your love

Add a button link to this github project in the footer by adding this flag:

```
--zd
```

