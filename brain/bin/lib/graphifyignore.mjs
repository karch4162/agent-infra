// lib/graphifyignore.mjs — the ONE port of graphify's .graphifyignore matching,
// shared by scope-audit.mjs (direction (b), the vault-side carve-out) and
// android-layouts.mjs (which must not index layouts the build carved out).
// Two copies would drift, and the drift would be the auditor and the layout
// pass disagreeing about which paths the build dropped.
//
// Matching is PORTED from graphify's own detect.py `_is_ignored`, because the
// question is "did graphify drop this path", not "what would git do": fnmatch
// (`*` crosses `/`), slashes stripped from both ends, a leading `/` anchors to
// the root, an unanchored pattern also matches any single segment, and every
// ancestor is tested too. `!negation` lines are forbidden by the standard, so
// they are skipped rather than ported. Case-insensitive, as on the Windows
// hosts these vaults are built on.
export function fnmatchRe(p) {
  let re = '';
  for (let i = 0; i < p.length; i++) {
    const c = p[i];
    if (c === '*') re += '.*';
    else if (c === '?') re += '.';
    else if (c === '[') {
      // As fnmatch.translate: a `]` right after `[` or `[!` is a literal member.
      let j = i + 1;
      if (p[j] === '!') j++;
      if (p[j] === ']') j++;
      j = p.indexOf(']', j);
      if (j === -1) { re += '\\['; continue; }
      // Only `!` negates in fnmatch; `^` and `]` are literals.
      let body = p.slice(i + 1, j).replace(/[\\\]^]/g, '\\$&');
      if (body[0] === '!') body = '^' + body.slice(1);
      re += `[${body}]`;
      i = j;
    } else re += c.replace(/[.+^${}()|[\]\\/]/g, '\\$&');
  }
  try {
    return new RegExp(`^${re}$`, 'is');
  } catch {
    return /(?!)/; // fnmatch compiles a reversed range like [z-a] to a non-match
  }
}

// The text of a .graphifyignore → a predicate over repo-relative `/` paths.
// Empty text carves nothing.
export function carveMatcher(text) {
  const rules = [];
  for (const line of String(text || '').split(/\r?\n/)) {
    let raw = line.trim();
    if (!raw || raw.startsWith('#') || raw.startsWith('!')) continue;
    // graphify's _parse_gitignore_line: drop an inline ` # comment`, unescape \#.
    raw = raw.replace(/\s+#+[^\\].*$/, '').replace(/\\#/g, '#').trim();
    const p = raw.replace(/^\/+/, '').replace(/\/+$/, '');
    if (p) rules.push({ re: fnmatchRe(p), anchored: raw.startsWith('/') });
  }
  return (rel) => {
    const parts = rel.split('/');
    for (let i = 0; i < parts.length; i++) {
      const prefix = parts.slice(0, i + 1).join('/');
      for (const { re, anchored } of rules) {
        if (re.test(prefix) || (!anchored && re.test(parts[i]))) return true;
      }
    }
    return false;
  };
}
