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
- `--split` (`none`, `file`, `item`, default: `none`):
  - Output file structure. `none` - one file. `file` - one source code file is documented per page. `item` - one declaration is documented per page.
- `--out` (directory path, default: `zigdoc`):
  - Output directory.  **I wouldn't output to directories that contain something already!**
- `--clear` (`on`, `off`, default: `on`):
  - **Deletes any md/html files from the output directory before running.** *You should probably know this is on by default*
- `--filetypes` (comma-separated extensions, default: `zig`):
  - By default, ZigDoc just does the `.zig` files, but you can include other files too like: `--filetypes zig,md,css,html`. It can't parse non-zig files, but it can at least include them in the listed items.

#### Navigation

> *Controls the nav links near the top.*

- `--index` (`on`, `off`, default: `on`):
  - Outputs a "table of contents" style *Index* navigation list at the top. If you don't like it, here's how you get rid of it.
- `--breadcrumb` (`on`, `off`, default: `on`):
  - Show breadcrumb navigation in `--split` modes. Turn it off if you want to provide your own nav or back/home link.

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

- `--location` (`on`, `off`, default: `on`):
  - Show each declaration's source file path.
- `--linenum` (`on`, `off`, default: `on`):
  - Show each declaration's source line number.
- `--subheadings` (`on`, `off`, default: `off`):
  - Print "File" and "Code" subheadings.
- `--ext` (`on`, `off`, default: `on`):
  - Whether the title of "file" items displays the ".zig" extension.

#### URLs

> *Tweaks how URLs will look, and may affect the output file structure.*

- `--prettyurls` (`on`, `off`, default: `off`):
  - Links don't have "index.html" at the end - this ONLY works on a web server configured to handle that.
- `--exturls` (`on`, `off`, default: `on`):
  - Whether the URL of "file" items displays the ".zig" extension. That's more correct, and consistent with how clashes in naming would be resolved.
- `--dirurls` (`on`, `off`, default: `on`):
  - When enabled the URL of items is the index.html of their own directory.  It's nicer and turning it off can make things a bit sus.

#### Processing

> *These ones are just weird.*

- `--tree` (`on`, `off`, default: `on`):
  - Switches the *Index* navigation list between nested and flat lists.
- `--dir` (`on`, `off`, default: `on`):
  - Can be used to remove the directory path that prefixes "file" items when `--tree` is off.
- `--itemorder` (`code`, `alpha`, `grouped`, default: `code`):
  - Listed items appear in the same order as in the code. Here you can change the order to be alphabetical or grouped by the kind of item it is.
- `--dirorder` (`first`, `last`, `alpha`, default: `first`):
  - Where to display directories in the *Index* navigation tree.
- `--omitkind` (comma-separated: `fn`, `const`, `var`, `struct`, `enum`, `union`, `opaque`, default: none):
  - Omits declarations of the given kind(s) from output entirely, e.g. `--omitkind const,var`.
- `--recursive` (`on`, `off`, default: `on`):
  - Also document nested containers (a struct declared inside a struct, etc...), not just top-level declarations in each file.

### 🔸 HTML options

- `--filename` (file name, `index.html`):
  - The output filename.  (Ignored when `--split` is used)
- `--source` (`none`, `collapsed`, `resizable`, `inline`, default: `resizable`):
  - Whether and how source code is displayed.
- `--filesource` (`none`, `collapsed`, `resizable`, `inline`, default: `none`):
  - Whether and how full-file source code is displayed (with the "file" items).
- `--css` (`embed`, `external`, default: `embed`):
  - By default, CSS is in a `<style>` tag, here you can switch to a .css file so you can change it.
- `--theme` (`auto`, `light`, `dark`, default: `auto`):
  - `auto` uses the OS/browser color scheme. `light`/`dark` rigs the page to a consistent scheme.
- `--collapse` (`dir`, `all`, `none`, default: `dir`):
  - Changes how collapsing works in the *Index* navigation list.
- `--head` (raw HTML, default: ZigDoc favicon):
  - Stick something into the `<head>` tag. Setting this ditches the ZigDoc favicon.

### 🔸 Markdown options (`--format md`)

- `--filename` (file name, default: `index.md`):
  - The output filename.  (Ignored when `--split` is used)
- `--source` (`none`, `inline`, default: `none`):
  - Whether and how source code is displayed.
- `--filesource` (`none`, `inline`, default: `none`):
  - Whether and how full-file source code is displayed (with the "file" items).

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
zigdoc --format md --source inline --location off --out docs src/root.zig
```

#### 🔸 Generating an `AI_CONTEXT.md` for LLM context

A single-file .md dump of a project's shape, meant to be provided to
an LLM: every declaration's signature and doc comment.

```
zigdoc . --format md --index off --out AI_CONTEXT.md --rootname "My App AI Context" --desc "Auto-generated API reference: signatures and doc comments only, no source code. Don't edit this file."
```

#### 🔸 Build file (`build.zig`) integration

```zig
const zigdoc_dep = b.dependency("zigdoc", .{});
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
that's why there's fewer line-breaks in the template.

A variable can also carry its own `format="..."` attribute right in the
template, e.g.:

```
{index format="<nav class=\"index\"><strong>Index</strong>{index}</nav>"}
```

When the variable's value is non-empty, the format string is used in its
place — with the variable's own name inside the format string standing in
for its raw value, and every other page/section variable still available
too (e.g. `{breadcrumb format="<nav>{breadcrumb}{page-title}</nav>"}`).
When the value is empty, the whole `{name format="..."}` outputs nothing,
same as an empty plain `{name}` would. This is how the default templates
supply their own wrapper markup around `index`, `breadcrumb`, `name`,
`path`, `sig`, `file-heading`, `location`, and `code-heading` — copy a
default template and adjust the format strings to restyle any of these
without touching ZigDoc's source.

This gives you control over the output order and the ability to add custom
wrappers. If you need more than this then CSS/JS is the answer.

Variable names should clue you in to what they are. Depending on the options
that **ZigDoc** is run with: some variables will output nothing.

## ☝️ Tips & Advice

### Search

No in-built search. The philosophy here is that between a browser or file
reader's functionality, operating system capabilities, and search engines,
a method for locating the docs can be easily arrived at.

### Output files starting with `_` (underscore)

My webhost would 404 on files starting with underscores. Turned out to be
something called Jekyll processing. Adding an empty file called `.nojekyll`
to my web root solved the problem.

### Syntax highlighting

This is built-in for `.zig` files and nothing else.  If you need more
than that you'll have to post-process or attach JS to the front end, perhaps
with something like **highlight.js**.  Considered integrating TextMate
grammars, but that is too big of an undertaking.

## 💖 Show your love

Add a button link to this github project:

```
--append "<a href=http://github.com/braksator/ZigDoc target=_blank><img height=32 src=data:image/png;base64,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 style=display:block;margin:auto;margin-top:2rem></a>"
```

