{
  let input = document.getElementById('fnd-i'), resultsEl = document.getElementById('fnd-res');
  let searchBox = input && resultsEl && (input.closest('.fnd') || resultsEl.parentNode);

  if (searchBox) {
    let
      index = window.ZDI || [],
      items = [], // current filtered/sorted results
      selected = -1,
      // search-index.js and this script both load via <script src> (not
      // fetch), so hrefs are resolved relative to *this script's own* URL
      // rather than the current page's — one shared index works from any
      // page depth in split mode, and from file:// with no server.
      scriptHref = (document.currentScript && document.currentScript.src) || location.href,
      resolveHref = rel => new URL(rel, scriptHref).href,

      escapeHtml = s => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),

      // --- Markdown-aware matching -------------------------------------
      //
      // entry[3] is the doc comment's raw markdown (whitespace-
      // collapsed, otherwise untouched). Matching/ranking runs against a
      // "plain" rendering with markdown syntax removed, so a query isn't
      // thrown off by a `**`/backtick sitting inside the phrase it's
      // looking for. `plain[i]` maps back to `raw[map[i]]` via `map`, so
      // once a match is found in `plain`, its position can be translated
      // back to `raw` to build a snippet that still carries the original
      // formatting.
      buildPlain = (raw, plain = '', map = [], i = 0, c, closeBracket, closeParen, j) => {
        while (i < raw.length) {
          c = raw[i];
          if (['#', '*', '_', '`', '>'].includes(c)) {
            i++;
          }
          else if (c == '[' && (closeBracket = raw.indexOf(']', i + 1)) >= 0 && raw[closeBracket + 1] == '(' && (closeParen = raw.indexOf(')', closeBracket + 2)) >= 0) {
            for (j = i + 1; j < closeBracket; j++) {
              plain += raw[j];
              map.push(j);
            }
            i = closeParen + 1;
          }
          else {
            plain += c;
            map.push(i);
            i++;
          }
        }
        return { plain: plain, map: map };
      },

      // Cached by entry identity, since entries are arrays and can't carry
      // an extra property of their own.
      plainCache = new Map(),
      getPlain = (entry, cached = plainCache.get(entry)) => {
        if (!cached) {
          cached = buildPlain(entry[3] || ''); // 3 = text
          plainCache.set(entry, cached);
        }
        return cached;
      },

      findMatch = (haystack, needle) => (!needle || !haystack) ? -1 : haystack.toLowerCase().indexOf(needle.toLowerCase()),

      // Loose fallback for when there's no contiguous substring match:
      // every character of the query appears in order somewhere in text.
      // Returns the matched indices (for highlighting) or null.
      subsequenceMatch = (haystack, needle, h = haystack.toLowerCase(), n = needle.toLowerCase(), hi = 0, idxs = [], ni) => {
        if (haystack) {
          for (ni = 0; ni < n.length; ni++) {
            hi = h.indexOf(n[ni], hi);
            if (hi < 0) return null;
            idxs.push(hi);
            hi++;
          }
        }
        return idxs.length ? idxs : null;
      },

      // --- Rendering -----------------------------------------------------
      //
      // Renders a raw-markdown snippet to HTML in one pass, converting
      // `**bold**` / `` `code` `` / `[text](url)` to real tags *and*
      // wrapping [hs, he) (raw-string indices) in <mark>, so highlighting
      // never has to be spliced into already-built HTML. A span whose
      // closing marker falls outside the (already-truncated) snippet is
      // left as literal text rather than guessed-closed — harmless
      // stray "**" at a snippet's edge, never mismatched tags. `faintIdxs`
      // (optional) is a set of individual indices — the scattered
      // characters a fuzzy subsequence match hit — each wrapped in its own
      // lighter <mark> so a fuzzy result shows what it thinks matched
      // instead of leaving the reader to guess.
      renderSnippet = (raw, hs, he, faintIdxs, out = '', markOpen = 0, faintOpen = 0, i = 0, end, endTick, closeBracket, closeParen, j, jt, jl) => {
          emitChar = (c, idx) => {
            !markOpen && idx >= hs && idx < he && (out += '<mark class="fnd-mark">', markOpen = 1);
            !markOpen && !faintOpen && faintIdxs && faintIdxs.has(idx) && (out += '<mark class="fnd-mark2">', faintOpen = 1);
            out += escapeHtml(c);
            markOpen && idx + 1 >= he && (out += '</mark>', markOpen = 0);
            faintOpen && !(faintIdxs && faintIdxs.has(idx + 1)) && (out += '</mark>', faintOpen = 0);
          };

        while (i < raw.length) {
          if (raw.substr(i, 2) == '**' && (end = raw.indexOf('**', i + 2)) >= 0) {
            out += '<strong>';
            for (j = i + 2; j < end; j++) emitChar(raw[j], j);
            out += '</strong>';
            i = end + 2;
          }
          else if (raw[i] == '`' && (endTick = raw.indexOf('`', i + 1)) >= 0) {
            out += '<code>';
            for (jt = i + 1; jt < endTick; jt++) emitChar(raw[jt], jt);
            out += '</code>';
            i = endTick + 1;
          }
          else if (raw[i] == '[' && (closeBracket = raw.indexOf(']', i + 1)) >= 0 && raw[closeBracket + 1] == '(' && (closeParen = raw.indexOf(')', closeBracket + 2)) >= 0) {
            out += '<a href="' + escapeHtml(raw.slice(closeBracket + 2, closeParen)) + '">';
            for (jl = i + 1; jl < closeBracket; jl++) emitChar(raw[jl], jl);
            out += '</a>';
            i = closeParen + 1;
          }
          else {
            emitChar(raw[i], i);
            i++;
          }
        }
        if (markOpen || faintOpen) out += '</mark>';
        return out;
      },

      SNIPPET_RADIUS = 40, // characters of context shown before/after a comment match

      snippetHtml = (entry, query, raw = entry[3] || '') => { // 3 = text
        if (!raw) return '';
        let p = getPlain(entry), pIdx = findMatch(p.plain, query), lead, subIdxs, faintIdxs, si, rawIdx, html, rawStart, lastPlainIdx, rawEnd, winStart, winEnd, prefix, suffix;
        if (pIdx < 0) {
          // No contiguous match in the comment — only a fuzzy subsequence
          // (or nothing, and the name matched instead). Show the start of
          // the comment for context, faintly marking the subsequence hit
          // if there is one so it's clear what the fuzzy match found.
          lead = raw.length <= SNIPPET_RADIUS * 2 ? raw : raw.slice(0, SNIPPET_RADIUS * 2);
          subIdxs = subsequenceMatch(p.plain, query);
          faintIdxs = null;
          if (subIdxs) {
            faintIdxs = new Set();
            for (si = 0; si < subIdxs.length; si++) {
              rawIdx = p.map[subIdxs[si]];
              if (rawIdx < lead.length) faintIdxs.add(rawIdx);
            }
          }
          html = renderSnippet(lead, -1, -1, faintIdxs);
          return raw.length > lead.length ? html + '\u2026' : html;
        }

        rawStart = p.map[pIdx];
        lastPlainIdx = Math.min(pIdx + query.length, p.plain.length) - 1;
        rawEnd = p.map[lastPlainIdx] + 1;

        winStart = Math.max(0, rawStart - SNIPPET_RADIUS);
        winEnd = Math.min(raw.length, rawEnd + SNIPPET_RADIUS);
        prefix = winStart > 0 ? '\u2026' : '';
        suffix = winEnd < raw.length ? '\u2026' : '';
        return prefix + renderSnippet(raw.slice(winStart, winEnd), rawStart - winStart, rawEnd - winStart) + suffix;
      },

      markSubsequence = (s, idxs, set = new Set(idxs), out = '', open = 0, i, hit) => {
        for (i = 0; i < s.length; i++) {
          hit = set.has(i);
          if (hit && !open) {
            out += '<mark class="fnd-mark2">';
            open = 1;
          }
          out += escapeHtml(s[i]);
          if (open && !set.has(i + 1)) {
            out += '</mark>';
            open = 0;
          }
        }
        return out;
      },

      // Mirrors the old nameHtml/pathHtml wrappers (now inlined at their
      // one call site each in render()): contiguous-match-first, fuzzy-
      // fallback treatment shared by both the name and path fields.
      markHtml = (s, query, idx = findMatch(s, query), subIdxs = subsequenceMatch(s, query)) =>
        idx >= 0 ?
          escapeHtml(s.slice(0, idx)) + '<mark class="fnd-mark">' + escapeHtml(s.slice(idx, idx + query.length)) + '</mark>' + escapeHtml(s.slice(idx + query.length))
          : subIdxs ? markSubsequence(s, subIdxs) : escapeHtml(s),

      // --- UI --------------------------------------------------------------

      close = document.createElement('button'),

      setVisible = v => {
        resultsEl.hidden = !v;
        close.hidden = !v;
      },

      closeResults = X => {
        setVisible(0);
        resultsEl.innerHTML = '';
        items = [];
        selected = -1;
      },

      setSelected = (i, j, els = resultsEl.querySelectorAll('.fnd-r')) => {
        for (j = 0; j < els.length; j++) els[j].classList.remove('sel');
        selected = i;
        if (i >= 0 && els[i]) els[i].classList.add('sel');
      },

      scrollSelectedIntoView = (els = resultsEl.querySelectorAll('.fnd-r')) => {
        selected >= 0 && els[selected] && els[selected].scrollIntoView({ block: 'nearest' });
      },

      render = (query, frag, a, title, pathEl, snippet, snippetEl) => {
        resultsEl.innerHTML = '';
        selected = -1;
        if (!items.length) {
          setVisible(0);
        }
        else {
          setVisible(1);

          frag = document.createDocumentFragment();
          items.forEach((entry, i) => {
            a = document.createElement('a');
            a.className = 'fnd-r';
            a.href = resolveHref(entry[2]); // 2 = href

            title = document.createElement('div');
            title.className = 'fnd-r-title';
            title.innerHTML = markHtml(entry[0], query); // 0 = name
            a.appendChild(title);

            if (entry[1] && entry[1] != entry[0]) { // 0 = name, 1 = path
              pathEl = document.createElement('div');
              pathEl.className = 'fnd-r-path';
              pathEl.innerHTML = markHtml(entry[1], query); // 1 = path
              a.appendChild(pathEl);
            }

            snippet = snippetHtml(entry, query);
            if (snippet) {
              snippetEl = document.createElement('div');
              snippetEl.className = 'fnd-snip';
              snippetEl.innerHTML = snippet;
              a.appendChild(snippetEl);
            }

            a.addEventListener('mouseenter', X => setSelected(i));

            frag.appendChild(a);
          });
          resultsEl.appendChild(frag);

          // The first result is highlighted by default, so it's clear what
          // pressing Enter will do.
          setSelected(0);
        }
      },

      search = (query, scored = [], i, entry, plain, nameIdx, textIdx, pathIdx, score) => {
        if (!query) {
          closeResults();
        }
        else {
          for (i = 0; i < index.length; i++) {
            entry = index[i];
            plain = getPlain(entry).plain;
            nameIdx = findMatch(entry[0], query); // 0 = name
            textIdx = findMatch(plain, query);
            pathIdx = findMatch(entry[1], query); // 1 = path
            score = nameIdx >= 0 ?
              1000 - nameIdx : pathIdx >= 0 ?
              750 - pathIdx : textIdx >= 0 ?
              500 - Math.min(textIdx, 500) : (subsequenceMatch(entry[0], query) || subsequenceMatch(entry[1], query) || subsequenceMatch(plain, query)) ? // 0 = name, 1 = path
              1 : -1;
            if (score >= 0) scored.push({ entry: entry, score: score });
          }
          scored.sort((a, b) => b.score - a.score);
          items = scored.slice(0, 30).map(s => s.entry);
          render(query);
        }
      },

      // --- Shortcut-tips widget ("?") and jump-to-source ("u") ---------
      //
      // The tips box's own show/hide is pure CSS (a checkbox + `:checked
      // ~` sibling selector — see style.zig's `.tips-box` rules); this
      // only drives that same checkbox's `checked` state so the "?"/"Esc"
      // keys reach the same state a mouse click does, rather than
      // duplicating the show/hide logic in JS.
      tipsToggle = document.getElementById('tips-tog'),
      tabSource = document.getElementById('tab-src'),

      typingInField = (active = document.activeElement) => active && (active.tagName == 'INPUT' || active.tagName == 'TEXTAREA' || active.isContentEditable);

    close.type = 'button';
    close.className = 'fnd-x';
    close.hidden = 1;
    close.setAttribute('aria-label', 'Clear search');
    close.textContent = '\u00d7';
    close.addEventListener('click', X => {
      input.value = '';
      closeResults();
      input.focus();
    });
    searchBox.appendChild(close);

    input.addEventListener('input', X => search(input.value.trim()));

    input.addEventListener('keydown', e => {
      if (e.key == 'Escape') {
        input.value = '';
        closeResults();
        input.blur();
      }
      else if (e.key == 'ArrowDown') {
        if (items.length) {
          e.preventDefault();
          setSelected(Math.min(selected + 1, items.length - 1));
          scrollSelectedIntoView();
        }
      }
      else if (e.key == 'ArrowUp') {
        if (items.length) {
          e.preventDefault();
          setSelected(Math.max(selected - 1, 0));
          scrollSelectedIntoView();
        }
      }
      else if (e.key == 'Enter') {
        let target = items[selected >= 0 ? selected : 0];
        if (target) window.location.href = resolveHref(target[2]); // 2 = href
      }
    });

    document.addEventListener('keydown', e => {
      if (e.key == 's' || e.key == 'S') {
        if (!typingInField()) {
          e.preventDefault();
          input.focus();
          input.scrollIntoView({ block: 'center' });
        }
      }
      if ((e.key == '?' || (e.key == '/' && e.shiftKey)) && !typingInField()) {
        if (tipsToggle) {
          e.preventDefault();
          tipsToggle.checked = 1;
        }
      }
      else if (e.key == 'u' || e.key == 'U') {
        if (tabSource && !typingInField()) {
          e.preventDefault();
          tabSource.checked = 1;
          tabSource.scrollIntoView({ block: 'start' });
        }
      }
      else if (e.key == 'Escape' && tipsToggle) {
        tipsToggle.checked = 0;
        // input's own Escape handler (above) already clears/blurs search.
      }
    });
  }
}