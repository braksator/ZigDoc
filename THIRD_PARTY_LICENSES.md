# Third-Party Licenses

## Markdown parser (`src/markdown/`)

`src/markdown/Document.zig`, `src/markdown/Parser.zig`, and
`src/markdown/renderer.zig` are vendored from the
[ziglang/zig](https://github.com/ziglang/zig) repository, from
`lib/docs/wasm/markdown/`, retrieved from the `master` branch.

`Document.zig` has one modification: the `render` function's signature
was aligned to the `*std.Io.Writer`-based API used by the `renderer.zig`
retrieved in the same pass (these two files were observed to reflect
slightly different snapshots of Zig's in-progress standard library I/O
API; this project pins to the newer one). No other logic in any of the
three files was altered.

Zig, including the code under `lib/`, is made available under the MIT
license:

```
Copyright (c) Zig contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

See https://github.com/ziglang/zig/blob/master/LICENSE for the
authoritative, current copy.

Before distributing this project, confirm the vendored files are still
current against upstream (they may have moved or changed since
retrieval) and update this note with the commit hash you synced against.
