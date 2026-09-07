//! Default CSS shared by `--css embed` and `--css external` output.
const std = @import("std");
const options = @import("main.zig").options;

const lightVars =
    \\  --zd-fg: #1a1a1a;
    \\  --zd-bg: #fafafa;
    \\  --zd-i: #fff;
    \\  --zd-mute: #6b6b6b;
    \\  --zd-brd: #ddd;
    \\  --zd-src: #f5f5f5;
    \\  --zd-code: #666;
    \\  --zd-link: #2563eb;
    \\  --zd-sigbg: #eff5ff;
    \\  --zd-sigbrd: #333;
    \\  --zd-tok-kw: #a626a4;
    \\  --zd-tok-id: #000;
    \\  --zd-tok-type: #003c8f;
    \\  --zd-tok-f: #9d4600;
    \\  --zd-tok-c: #6b6b6b;
    \\  --zd-tok-str: #50a14f;
    \\  --zd-tok-num: #986801;
    \\  --zd-tok-bi: #4078f2;
    \\  --zd-sel: #cdeb8b;
    \\  --zd-fnd1: #ffe066;
    \\  --zd-fnd2: rgba(255, 224, 102, .4);
    \\  --zd-pop: #f0f0f0;
;
const darkVars =
    \\  --zd-fg: #e6e6e6;
    \\  --zd-bg: #121212;
    \\  --zd-i: #000;
    \\  --zd-mute: #9a9a9a;
    \\  --zd-brd: #333;
    \\  --zd-src: #1e1e1e;
    \\  --zd-code: #999;
    \\  --zd-link: #6ea8fe;
    \\  --zd-sigbg: #1b2636;
    \\  --zd-sigbrd: #3a3a3a;
    \\  --zd-tok-kw: #c678dd;
    \\  --zd-tok-id: #fff;
    \\  --zd-tok-type: #6ea8fe;
    \\  --zd-tok-f: #fbe2af;
    \\  --zd-tok-c: #9a9a9a;
    \\  --zd-tok-str: #98c379;
    \\  --zd-tok-num: #d19a66;
    \\  --zd-tok-bi: #61afef;
    \\  --zd-sel: #131f06;
    \\  --zd-fnd1: #d1a824;
    \\  --zd-fnd2: rgba(209, 168, 36, .4);
    \\  --zd-pop: #1a1a1a;
;

const rootAuto = ":root {\n  color-scheme: light dark;\n" ++ lightVars ++ "\n}\n@media (prefers-color-scheme: dark) {\n  :root {\n" ++ darkVars ++ "\n  }\n}\n";
const rootLight = ":root {\n  color-scheme: light;\n" ++ lightVars ++ "\n}\n";
const rootDark = ":root {\n  color-scheme: dark;\n" ++ darkVars ++ "\n}\n";

fn rootFor(theme: options.Theme) []const u8 {
    return switch (theme) {
        .auto => rootAuto,
        .light => rootLight,
        .dark => rootDark,
    };
}

/// Default stylesheet. `theme` controls whether colors follow
/// `prefers-color-scheme` (`.auto`) or are fixed. Only includes CSS chunks
/// for features `opts` actually has enabled. Caller owns the returned slice.
pub fn css(gpa: std.mem.Allocator, opts: options.Options, theme: options.Theme) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try buf.appendSlice(gpa, rootFor(theme));
    try buf.appendSlice(gpa, bodyCssHead);
    try buf.appendSlice(gpa, ".zigdoc {\n");
    try buf.appendSlice(gpa, zigdocCore);

    if (opts.source == .resizable or opts.pageSource == .resizable) {
        try buf.appendSlice(gpa, resizableFragment);
    }
    if (opts.source == .tab or opts.pageSource == .tab) {
        try buf.appendSlice(gpa, tabsFragment);
    }
    try buf.appendSlice(gpa, tokensFragment);
    if (opts.codelinks) {
        try buf.appendSlice(gpa, codelinksFragment);
    }
    try buf.appendSlice(gpa, sigAndMiscFragment);

    if (opts.index or (opts.breadcrumb and opts.split != .none)) {
        try buf.appendSlice(gpa, navSharedFragment);
    }
    if (opts.index) {
        try buf.appendSlice(gpa, navIndexOnlyFragment);
    }
    if (opts.breadcrumb and opts.split != .none) {
        try buf.appendSlice(gpa, navBreadcrumbOnlyFragment);
    }

    if (opts.search) {
        try buf.appendSlice(gpa, searchFragment);
        try buf.appendSlice(gpa, tipsFragment);
    }

    try buf.appendSlice(gpa, "}\n");
    return buf.toOwnedSlice(gpa);
}

const bodyCssHead =
    \\.zd-body {
    \\  color: var(--zd-fg);
    \\  background: var(--zd-bg);
    \\  max-width: 960px;
    \\  margin: 0 auto;
    \\  padding: 2rem 1.5rem 6rem;
    \\  line-height: 1.55;
    \\  overflow-y: scroll;
    \\  &, kbd, .tok-fn { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    \\}
    \\
;

/// Rules that apply regardless of feature flags: base typography, links,
/// headings, generic code/pre/src-code framing, decl layout.
const zigdocCore =
    \\  a {
    \\    color: var(--zd-link);
    \\    text-decoration: none;
    \\    &:hover { text-decoration: underline; }
    \\  }
    \\  h1, h2, h3 { line-height: 1.25; }
    \\  h1 { border-bottom: 1px solid var(--zd-brd); padding-bottom: .4rem; }
    \\  .site-title, .ptype, .dtype {
    \\    color: var(--zd-mute);
    \\    font-size: 1em;
    \\    font-weight: 600;
    \\    text-transform: uppercase;
    \\    letter-spacing: .04em;
    \\  }
    \\  .ptype, .dtype {
    \\    float: right;
    \\    margin-top: 1em;
    \\  }
    \\  section.decl {
    \\    border-bottom: 1px solid var(--zd-brd);
    \\    padding-bottom: 1.25rem;
    \\    margin-bottom: 1.25rem;
    \\  }
    \\  code, pre {
    \\    font-family: ui-monospace, SFMono-Regular, Consolas, "Liberation Mono", monospace;
    \\    font-size: .9em;
    \\    color: var(--zd-code);
    \\  }
    \\  pre {
    \\    background: var(--zd-src);
    \\    border: 1px solid var(--zd-brd);
    \\    border-radius: 6px;
    \\    padding: .75rem;
    \\    overflow: auto;
    \\  }
    \\  .src-code {
    \\    display: grid;
    \\    grid-template-columns: auto 1fr;
    \\    align-items: start;
    \\    background: var(--zd-src);
    \\    border: 1px solid var(--zd-brd);
    \\    border-radius: 6px;
    \\    overflow: auto;
    \\    pre {
    \\      background: none;
    \\      border: none;
    \\      border-radius: 0;
    \\      overflow: visible;
    \\      white-space: pre;
    \\      margin: 0;
    \\    }
    \\  }
    \\  .src-nums {
    \\    position: sticky;
    \\    left: 0;
    \\    background: var(--zd-src);
    \\    opacity: .5;
    \\    pre {
    \\      padding: .75rem .4rem;
    \\      text-align: right;
    \\      color: var(--zd-mute);
    \\      user-select: none;
    \\    }
    \\  }
    \\  .src-txt pre {
    \\    padding: .75rem;
    \\  }
    \\  p code { background: val(--zd-i); }
    \\  .decl > h3 { margin-bottom: 0; }
    \\  .item-priv > * { opacity: .6 }
    \\  .item-doc { margin: .15rem 0 .5rem; color: var(--zd-mute); font-size: .9em; }
    \\  .item-doc p { margin: 0; }
    \\  dl.fields > dt > code { background: var(--zd-src); padding: .25rem .5rem; margin-top: .5rem; display: inline-block; }
    \\  .cols > ul {
    \\    column-width: 20em;
    \\  }
    \\
;

/// `--source`/`--pagesource resizable` only.
const resizableFragment =
    \\  .src-code.resizable {
    \\    width: 100%;
    \\    box-sizing: border-box;
    \\    resize: vertical;
    \\  }
    \\
;

/// `--source`/`--pagesource tab` only.
const tabsFragment =
    \\  .tabs {
    \\    margin: .75rem 0;
    \\  }
    \\  .tab-i {
    \\    position: absolute;
    \\    opacity: 0;
    \\    pointer-events: none;
    \\  }
    \\  .tab-label {
    \\    display: inline-block;
    \\    cursor: pointer;
    \\    padding: .4rem .9rem;
    \\    border: 1px solid var(--zd-brd);
    \\    border-bottom: none;
    \\    border-radius: 6px 6px 0 0;
    \\    background: var(--zd-src);
    \\    color: var(--zd-mute);
    \\    font-size: .9em;
    \\    user-select: none;
    \\  }
    \\  label[for="tab-src"] {
    \\    margin-left: -1px;
    \\  }
    \\  .tab-i:checked + .tab-label {
    \\    background: var(--zd-bg);
    \\    color: var(--zd-fg);
    \\    font-weight: 600;
    \\  }
    \\  .tab-i:focus-visible + .tab-label {
    \\    outline: 2px solid var(--zd-link);
    \\    outline-offset: -2px;
    \\  }
    \\  .tab-panes {
    \\    border: 1px solid var(--zd-brd);
    \\    border-radius: 0 6px 6px 6px;
    \\    padding: 1rem;
    \\  }
    \\  .tab-pane { display: none; }
    \\  #tab-doc:checked ~ .tab-panes .tab-pane-doc,
    \\  #tab-src:checked ~ .tab-panes .tab-pane-source {
    \\    display: block;
    \\  }
    \\
;

/// Syntax-highlight token colors. Always present regardless of `codelinks`.
const tokensFragment =
    \\  .tok-kw { color: var(--zd-tok-kw); }
    \\  .tok-id { color: var(--zd-tok-id); }
    \\  .tok-type { color: var(--zd-tok-type); font-weight: 600; }
    \\  .tok-f { color: var(--zd-tok-f); }
    \\  .tok-c { color: var(--zd-tok-c); font-style: italic; }
    \\  .tok-str { color: var(--zd-tok-str); }
    \\  .tok-num { color: var(--zd-tok-num); }
    \\  .tok-bi { color: var(--zd-tok-bi); }
    \\  .tok-fn .tok-f { color: var(--zd-link); font-size: 1.2em; }
;

/// `--codelinks on` only: `a.tok-l*` rules for linked tokens.
const codelinksFragment =
    \\  a.tok-l:not(.tok-fn) {
    \\    text-decoration: underline;
    \\    &.tok-kw { color: var(--zd-tok-kw); }
    \\    &.tok-id { color: var(--zd-tok-id); }
    \\    &.tok-type { color: var(--zd-tok-type); }
    \\    &.tok-f { color: var(--zd-tok-f); }
    \\    &.tok-bi { color: var(--zd-tok-bi); }
    \\    &:hover {
    \\      text-decoration-thickness: 2px;
    \\    }
    \\  }
;

/// Always present: signature box, path/file metadata, decl h4s.
const sigAndMiscFragment =
    \\  .sig {
    \\    background: var(--zd-sigbg);
    \\    border: 1px solid var(--zd-sigbrd);
    \\    border-radius: 6px;
    \\    padding: .6rem .8rem;
    \\    overflow-x: auto;
    \\  }
    \\  .path {
    \\    color: var(--zd-mute);
    \\    font-size: .85em;
    \\  }
    \\  .file {
    \\    color: var(--zd-mute);
    \\    font-size: .85em;
    \\    font-family: ui-monospace, SFMono-Regular, Consolas, "Liberation Mono", monospace;
    \\    margin-bottom: .5rem;
    \\  }
    \\  .src-ln {
    \\     opacity: .6;
    \\   }
    \\  .decl h4, .dtype {
    \\    color: var(--zd-mute);
    \\    font-size: .8em;
    \\    text-transform: uppercase;
    \\    letter-spacing: .03em;
    \\    margin: 1rem 0 .3rem;
    \\  }
    \\  .dtype {
    \\    margin-top: 0;
    \\  }
    \\  .decl-root .dtype { display: none; }
    \\  summary {
    \\    cursor: pointer;
    \\  }
    \\  details.src summary {
    \\    color: var(--zd-mute);
    \\    margin-bottom: .4rem;
    \\  }
    \\
;

/// Shared border/padding/margin for both `nav.index` and `nav.bc`.
const navSharedFragment =
    \\  nav.index, nav.bc {
    \\    border: 1px solid var(--zd-brd);
    \\    border-radius: 6px;
    \\    padding: .75rem 1.25rem;
    \\    margin: 1.5rem 0;
    \\  }
    \\
;

/// `--index on` only: the nested contents-list styling.
const navIndexOnlyFragment =
    \\  nav.index {
    \\    ul { margin: .3rem 0; padding-left: 1.25rem; }
    \\    .index-dir:not(a) {
    \\      color: var(--zd-mute);
    \\      font-weight: 600;
    \\    }
    \\    details > a.index-dir { display: none; }
    \\    li:has(> details) {
    \\      list-style: none;
    \\      > details > summary {
    \\        position: relative;
    \\        left: -1.25em;
    \\        > span {
    \\          padding-left: .15em;
    \\          color: var(--zd-mute);
    \\          font-weight: 600;
    \\        }
    \\      }
    \\    }
    \\  }
    \\
;

/// `--breadcrumb on` (split modes only): the separator between segments.
const navBreadcrumbOnlyFragment =
    \\  .bc-sep {
    \\    color: var(--zd-mute);
    \\    margin: 0 .4rem;
    \\  }
    \\  .zd-root nav.bc { display: none; }
    \\
;

/// `--search on` only: search box + results dropdown.
const searchFragment =
    \\  .fnd {
    \\    position: relative;
    \\    display: flex;
    \\    flex-wrap: wrap;
    \\    align-items: center;
    \\    gap: .5rem;
    \\    margin: 1rem 0;
    \\  }
    \\  .fnd-i {
    \\    flex: 1 1 auto;
    \\    min-width: 0;
    \\    box-sizing: border-box;
    \\    padding: .55rem 2.2rem .55rem .9rem;
    \\    font-size: 1rem;
    \\    color: var(--zd-fg);
    \\    background: var(--zd-bg);
    \\    border: 1px solid var(--zd-brd);
    \\    border-radius: 20px;
    \\    &:focus {
    \\      outline: 2px solid var(--zd-link);
    \\      outline-offset: -1px;
    \\    }
    \\  }
    \\  .fnd-res {
    \\    position: absolute;
    \\    width: calc(100% - 40px - 2.8em);
    \\    margin: 0 20px;
    \\    border: 1px solid var(--zd-brd);
    \\    border-top: none;
    \\    border-radius: 0 0 .6rem .6rem;
    \\    background: var(--zd-pop);
    \\    max-height: 60vh;
    \\    overflow-y: auto;
    \\    top: 2.4em;
    \\    z-index: 1;
    \\    letter-spacing: .02em;
    \\  }
    \\  .fnd-r {
    \\    display: block;
    \\    padding: .5rem .9rem;
    \\    border-top: 1px solid var(--zd-brd);
    \\    color: var(--zd-fg);
    \\    &:first-child { border-top: none; }
    \\    &.sel { background: var(--zd-sel); }
    \\    &:hover { text-decoration: none; }
    \\  }
    \\  .fnd-r-title { font-weight: 600; }
    \\  .fnd-r-path {
    \\    font-size: .8rem;
    \\    color: var(--zd-mute);
    \\  }
    \\  .fnd-snip {
    \\    font-size: .9rem;
    \\    color: var(--zd-mute);
    \\    margin-top: .15rem;
    \\    code {
    \\      background: var(--zd-src);
    \\      padding: .05rem .3rem;
    \\      border-radius: .25rem;
    \\    }
    \\  }
    \\  .fnd-mark {
    \\    background: var(--zd-fnd1);
    \\    color: #1a1a1a;
    \\    border-radius: .2rem;
    \\  }
    \\  .fnd-mark2 {
    \\    background: var(--zd-fnd2);
    \\    color: var(--zd-fg);
    \\    border-radius: .2rem;
    \\  }
    \\  .fnd-x {
    \\    position: absolute;
    \\    top: 1.1em;
    \\    right: 2.8em;
    \\    transform: translateY(-50%);
    \\    border: none;
    \\    background: none;
    \\    color: var(--zd-mute);
    \\    font-size: 1.1rem;
    \\    line-height: 1;
    \\    cursor: pointer;
    \\    padding: .2rem .4rem;
    \\    &:hover { color: var(--zd-fg); }
    \\  }
    \\
;

/// `--search on` only: the `?`-triggered keyboard-shortcut tips popover.
const tipsFragment =
    \\  kbd {
    \\    display: inline-block;
    \\    padding: .1rem .4rem;
    \\    border: 1px solid var(--zd-brd);
    \\    border-radius: 4px;
    \\    background: var(--zd-bg);
    \\    font-weight: 600;
    \\    min-width: 1.2em;
    \\    text-align: center;
    \\    box-shadow: 0 1px 0 var(--zd-brd);
    \\    height: 1.6em;
    \\    line-height: 1.6em;
    \\    user-select: none;
    \\    &.tip {
    \\      cursor: pointer;
    \\    }
    \\    &.KE span { font-size: .68em; }
    \\    &.KR {
    \\      min-width: 2em;
    \\      line-height: 1.8em;
    \\      span { font-size: 1.2em; }
    \\    }
    \\  }
    \\  label.tip {
    \\    display: inline-flex;
    \\  }
    \\  .tips-box {
    \\    display: none;
    \\    position: absolute;
    \\    top: 2.8em;
    \\    right: 0;
    \\    z-index: 5;
    \\    width: max-content;
    \\    max-width: 18rem;
    \\    padding: .75rem 1rem;
    \\    border: 1px solid var(--zd-brd);
    \\    border-radius: 8px;
    \\    background: var(--zd-pop);
    \\    box-shadow: 0 4px 12px rgba(0, 0, 0, .15);
    \\    opacity: 0;
    \\    transform: translateY(-.3rem);
    \\    transition: opacity .12s ease, transform .12s ease;
    \\    user-select: none;
    \\    strong {
    \\      display: block;
    \\      margin-bottom: .5rem;
    \\    }
    \\    dl {
    \\      display: flex;
    \\      align-items: center;
    \\      gap: .5rem;
    \\      margin: .35rem 0;
    \\    }
    \\    dt {
    \\      margin: 0;
    \\      width: 2.8em;
    \\      text-align: center;
    \\    }
    \\    dd {
    \\      margin: 0;
    \\      color: var(--zd-mute);
    \\      font-size: .9em;
    \\    }
    \\  }
    \\  .tips-tog {
    \\    position: absolute;
    \\    opacity: 0;
    \\    pointer-events: none;
    \\    &:checked ~ .tips-box {
    \\      display: block;
    \\      opacity: 1;
    \\      transform: translateY(0);
    \\    }
    \\  }
    \\  .tips-x {
    \\    position: absolute;
    \\    top: .3rem;
    \\    right: .5rem;
    \\    color: var(--zd-mute);
    \\    font-size: 1.1rem;
    \\    line-height: 1;
    \\    cursor: pointer;
    \\    padding: .2rem .4rem;
    \\    &:hover { color: var(--zd-fg); }
    \\  }
;