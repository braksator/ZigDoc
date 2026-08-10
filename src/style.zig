//! Default CSS shared by `--css embed` and `--css external` output.
const options = @import("options.zig");

const lightVars =
    \\  --zd-fg: #1a1a1a;
    \\  --zd-bg: #ffffff;
    \\  --zd-muted: #6b6b6b;
    \\  --zd-border: #ddd;
    \\  --zd-code-bg: #f5f5f5;
    \\  --zd-link: #2563eb;
    \\  --zd-sig-bg: #eff5ff;
    \\  --zd-sig-border: #333;
    \\  --zd-tok-keyword: #a626a4;
    \\  --zd-tok-identifier: var(--zd-fg);
    \\  --zd-tok-comment: #6b6b6b;
    \\  --zd-tok-string: #50a14f;
    \\  --zd-tok-number: #986801;
    \\  --zd-tok-builtin: #4078f2;
;
const darkVars =
    \\  --zd-fg: #e6e6e6;
    \\  --zd-bg: #121212;
    \\  --zd-muted: #9a9a9a;
    \\  --zd-border: #333;
    \\  --zd-code-bg: #1e1e1e;
    \\  --zd-link: #6ea8fe;
    \\  --zd-sig-bg: #1b2636;
    \\  --zd-sig-border: #3a3a3a;
    \\  --zd-tok-keyword: #c678dd;
    \\  --zd-tok-identifier: var(--zd-fg);
    \\  --zd-tok-comment: #9a9a9a;
    \\  --zd-tok-string: #98c379;
    \\  --zd-tok-number: #d19a66;
    \\  --zd-tok-builtin: #61afef;
;

const rootAuto = ":root {\n  color-scheme: light dark;\n" ++ lightVars ++ "\n}\n@media (prefers-color-scheme: dark) {\n  :root {\n" ++ darkVars ++ "\n  }\n}\n";
const rootLight = ":root {\n  color-scheme: light;\n" ++ lightVars ++ "\n}\n";
const rootDark = ":root {\n  color-scheme: dark;\n" ++ darkVars ++ "\n}\n";

const cssAuto = rootAuto ++ bodyCss;
const cssLight = rootLight ++ bodyCss;
const cssDark = rootDark ++ bodyCss;

/// Plain, generic default stylesheet: readable line length, monospace for
/// code/signatures. `theme` controls whether colors follow
/// `prefers-color-scheme` (`.auto`) or are fixed to one scheme.
pub fn css(theme: options.Theme) []const u8 {
    return switch (theme) {
        .auto => cssAuto,
        .light => cssLight,
        .dark => cssDark,
    };
}

const bodyCss =
    \\.zd-body {
    \\  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    \\  color: var(--zd-fg);
    \\  background: var(--zd-bg);
    \\  max-width: 960px;
    \\  margin: 0 auto;
    \\  padding: 2rem 1.5rem 6rem;
    \\  line-height: 1.55;
    \\}
    \\.zigdoc {
    \\  a {
    \\    color: var(--zd-link);
    \\    text-decoration: none;
    \\  }
    \\  h1, h2, h3 { line-height: 1.25; }
    \\  h1 { border-bottom: 1px solid var(--zd-border); padding-bottom: .4rem; }
    \\  .site-title {
    \\    color: var(--zd-muted);
    \\    font-size: 1em;
    \\    font-weight: 600;
    \\    text-transform: uppercase;
    \\    letter-spacing: .04em;
    \\  }
    \\  section.decl {
    \\    border-bottom: 1px solid var(--zd-border);
    \\    padding-bottom: 1.25rem;
    \\    margin-bottom: 1.25rem;
    \\  }
    \\  code, pre {
    \\    font-family: ui-monospace, SFMono-Regular, Consolas, "Liberation Mono", monospace;
    \\    font-size: .9em;
    \\  }
    \\  pre {
    \\    background: var(--zd-code-bg);
    \\    border: 1px solid var(--zd-border);
    \\    border-radius: 6px;
    \\    padding: .75rem;
    \\    overflow: auto;
    \\  }
    \\  pre.resizable {
    \\    width: 100%;
    \\    box-sizing: border-box;
    \\    resize: vertical;
    \\    white-space: pre;
    \\  }
    \\  .decl > h3 { margin-bottom: 0; }
    \\  .tok-keyword { color: var(--zd-tok-keyword); }
    \\  .tok-identifier { color: var(--zd-tok-identifier); }
    \\  .tok-comment { color: var(--zd-tok-comment); font-style: italic; }
    \\  .tok-string { color: var(--zd-tok-string); }
    \\  .tok-number { color: var(--zd-tok-number); }
    \\  .tok-builtin { color: var(--zd-tok-builtin); }
    \\  .sig {
    \\    background: var(--zd-sig-bg);
    \\    border: 1px solid var(--zd-sig-border);
    \\    border-radius: 6px;
    \\    padding: .6rem .8rem;
    \\    overflow-x: auto;
    \\  }
    \\  .path {
    \\    color: var(--zd-muted);
    \\    font-size: .85em;
    \\  }
    \\  .location {
    \\    color: var(--zd-muted);
    \\    font-size: .85em;
    \\    font-family: ui-monospace, SFMono-Regular, Consolas, "Liberation Mono", monospace;
    \\    margin-bottom: .5rem;
    \\  }
    \\  .src-ln {
    \\     opacity: .6;
    \\   }
    \\  .decl h4 {
    \\    color: var(--zd-muted);
    \\    font-size: .8em;
    \\    text-transform: uppercase;
    \\    letter-spacing: .03em;
    \\    margin: 1rem 0 .3rem;
    \\  }
    \\  nav.index, nav.breadcrumb {
    \\    border: 1px solid var(--zd-border);
    \\    border-radius: 6px;
    \\    padding: .75rem 1.25rem;
    \\    margin: 1.5rem 0;
    \\  }
    \\  nav.index {
    \\    ul { margin: .3rem 0; padding-left: 1.25rem; }
    \\    .index-dir:not(a) {
    \\      color: var(--zd-muted);
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
    \\          color: var(--zd-muted);
    \\          font-weight: 600;
    \\        }
    \\      }
    \\    }
    \\  }
    \\  .breadcrumb-sep {
    \\    color: var(--zd-muted);
    \\    margin: 0 .4rem;
    \\  }
    \\  summary {
    \\    cursor: pointer;
    \\  }
    \\  details.src summary {
    \\    color: var(--zd-muted);
    \\    margin-bottom: .4rem;
    \\  }
    \\}
;
