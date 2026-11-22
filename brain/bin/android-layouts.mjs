#!/usr/bin/env node
// android-layouts.mjs — put an Android build's res/layout XML into its code graph
// (INNOV-427).
//
// WHY THIS EXISTS. graphify's detect step has no .xml in CODE_EXTENSIONS or
// DOC_EXTENSIONS (graphify 0.9.79, graphify/detect.py:47-48), so a layout file
// never reaches the graph. POS has 711 res/layout*/ XML files, and a lot of
// Android work is layout work: on those tasks the graph had nothing to offer.
// Routing them through graphify's semantic (LLM) extraction was rejected — the
// Android graph would then be partly LLM-built and the CI rebuild (INNOV-355)
// could not reproduce it. So this is a deterministic, brain-side pass: no LLM,
// no upstream change, run by sync-graph.sh just before a mirror is published.
//
// WHAT IT ADDS (every node and edge carries "_origin": "android-layouts"):
//   - a LAYOUT node per layout name per module (`activity_main`), source_file the
//     base layout/<name>.xml (or the first qualified variant when there is none).
//   - a VARIANT node per qualified file (layout-land/, layout-sw600dp/ ...),
//     linked to its layout by `variant_of`.
//   - code -> layout `uses_layout` edges, from the class whose body holds the
//     reference: R.layout.<name> (setContentView, inflate and DataBindingUtil all
//     go through it; `context` says which) or a view-binding class <Name>Binding.
//   - layout -> view `uses_view` edges: an element tag that is a fully qualified
//     class name links to that class's node, when the class is in the graph.
//   - layout -> layout `includes` edges from <include layout="@layout/x"/>.
// Nothing is added unless BOTH ends resolve; an unresolved name creates no node.
//
// IDEMPOTENT. Every run first strips what an earlier run added (tagged nodes,
// tagged edges, and any edge touching a stripped node), so re-running it on its
// own output, or on a graph `graphify --update` carried the tags through, is a
// byte-identical no-op.
//
// BYTE-PRESERVING. The mirror is a committed 67 MB file. JSON.stringify would
// rewrite every `1.0` as `1` and unescape every `\uXXXX`, so a one-line change
// would churn the whole file. graph.json is graphify's Python `json.dump(indent=2)`
// output, and this module writes that exact format back (newline style detected
// from the input, ASCII escaping unless the input carries raw non-ASCII).
//
// SCOPE. Only <dir>/**/src/main/res/layout*/*.xml, skipping dot dirs, build/,
// generated/, node_modules/ and whatever the checkout's .graphifyignore carves —
// the same file the build used, so a carved-out module's layouts stay out. Code
// references are read only from .kt/.java files that already have nodes in the
// graph, which inherits the build's carve-out for free.
//
// USAGE
//   node android-layouts.mjs <build-dir> [--graph <graph.json>] [--dry-run]
//     --graph defaults to <build-dir>/graphify-out/graph.json
//
// CONTRACT (sync-graph.sh and tests/android-layouts.test.mjs depend on it). The
// first line of stdout is one of:
//   exit 0  "ANDROID-LAYOUTS: OK - <n> layout(s), <n> variant(s), <n> code->layout, <n> layout->view, <n> include edge(s) (written|unchanged|dry run)"
//   exit 0  "ANDROID-LAYOUTS: SKIPPED - <reason>"   nothing written
//   exit 2  "ANDROID-LAYOUTS: ERROR - <reason>"     nothing written
import { readFileSync, readdirSync, renameSync, writeFileSync } from 'node:fs';
import { basename, isAbsolute, join, resolve } from 'node:path';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { carveMatcher } from './lib/graphifyignore.mjs';

const ORIGIN = 'android-layouts';

// --- Python-compatible JSON --------------------------------------------------
// Floats are smuggled through JSON.parse as sentinel strings so `1.0` survives.
// The per-process nonce means no string in an input graph can pose as one.
const FLOAT = `\u0000android-layouts-float:${randomBytes(16).toString('hex')}:`;
export const pyFloat = (raw) => FLOAT + raw;

export function parsePyJson(text) {
  const marked = text.replace(
    /"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+(?:[eE][+-]?\d+)?|[eE][+-]?\d+)/g,
    (m) => (m[0] === '"' ? m : JSON.stringify(FLOAT + m)),
  );
  return JSON.parse(marked);
}

function pyString(s, ascii) {
  if (s.startsWith(FLOAT)) return s.slice(FLOAT.length);
  let out = '"';
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    const ch = s[i];
    if (ch === '"') out += '\\"';
    else if (ch === '\\') out += '\\\\';
    else if (ch === '\n') out += '\\n';
    else if (ch === '\r') out += '\\r';
    else if (ch === '\t') out += '\\t';
    else if (ch === '\b') out += '\\b';
    else if (ch === '\f') out += '\\f';
    else if (c < 0x20 || (ascii && c > 0x7f)) out += '\\u' + c.toString(16).padStart(4, '0');
    else out += ch;
  }
  return out + '"';
}

export function dumpPyJson(value, { nl = '\n', ascii = true } = {}) {
  const parts = [];
  const walk = (v, ind) => {
    if (v === null) parts.push('null');
    else if (v === true) parts.push('true');
    else if (v === false) parts.push('false');
    else if (typeof v === 'number') parts.push(String(v));
    else if (typeof v === 'string') parts.push(pyString(v, ascii));
    else if (Array.isArray(v)) {
      if (v.length === 0) { parts.push('[]'); return; }
      const pad = nl + '  '.repeat(ind + 1);
      parts.push('[');
      v.forEach((x, i) => { parts.push(i ? ',' + pad : pad); walk(x, ind + 1); });
      parts.push(nl + '  '.repeat(ind) + ']');
    } else {
      const keys = Object.keys(v);
      if (keys.length === 0) { parts.push('{}'); return; }
      const pad = nl + '  '.repeat(ind + 1);
      parts.push('{');
      keys.forEach((k, i) => { parts.push((i ? ',' + pad : pad) + pyString(k, ascii) + ': '); walk(v[k], ind + 1); });
      parts.push(nl + '  '.repeat(ind) + '}');
    }
  };
  walk(value, 0);
  return parts.join('');
}

const f1 = FLOAT + '1.0';

// --- the walk ----------------------------------------------------------------
const NEVER_DIR = new Set(['build', 'generated', 'node_modules', 'graphify-out']);
const LAYOUT_DIR = /^layout(-[A-Za-z0-9_+-]+)?$/;

function findLayoutFiles(root, carved) {
  const found = [];
  const walk = (abs, rel) => {
    let entries;
    try { entries = readdirSync(abs, { withFileTypes: true }); } catch { return; }
    entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const e of entries) {
      if (!e.isDirectory()) continue;
      if (e.name.startsWith('.') || NEVER_DIR.has(e.name.toLowerCase())) continue;
      const r = rel ? `${rel}/${e.name}` : e.name;
      if (carved(r)) continue;
      if (LAYOUT_DIR.test(e.name) && r.endsWith(`src/main/res/${e.name}`)) {
        let files;
        try { files = readdirSync(join(abs, e.name), { withFileTypes: true }); } catch { continue; }
        for (const f of files.filter((x) => x.isFile()).map((x) => x.name).sort()) {
          const fr = `${r}/${f}`;
          if (f.toLowerCase().endsWith('.xml') && !carved(fr)) found.push(fr);
        }
        continue;
      }
      walk(join(abs, e.name), r);
    }
  };
  walk(root, '');
  return found;
}

// `app/src/main/res/layout-land/x.xml` -> module "app", qualifier "land", name "x"
function layoutParts(rel) {
  const m = /^(?:(.*)\/)?src\/main\/res\/layout(?:-([^/]+))?\/([^/]+)\.xml$/i.exec(rel);
  return m ? { module: m[1] || '', qualifier: m[2] || '', name: m[3] } : null;
}

function moduleOf(rel) {
  const i = rel.indexOf('/src/');
  return i === -1 ? (rel.startsWith('src/') ? '' : null) : rel.slice(0, i);
}

const idOf = (p) => p.replace(/\.xml$/i, '').replace(/[^A-Za-z0-9]+/g, '_').replace(/^_+|_+$/g, '').toLowerCase();

const pascal = (snake) => snake.split('_').filter(Boolean).map((w) => w[0].toUpperCase() + w.slice(1)).join('');

function lineAt(starts, idx) {
  let lo = 0, hi = starts.length - 1;
  while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] <= idx) lo = mid; else hi = mid - 1; }
  return lo + 1;
}

// Kotlin/Java source with comments and string/char literals blanked to spaces
// (newlines kept, so offsets and line numbers still line up): commented-out
// `R.layout.x` is not a use, and a `//` inside a URL string is not a comment.
export function blankCommentsAndStrings(src) {
  const out = src.split('');
  const blank = (from, to) => { for (let k = from; k < to; k++) if (out[k] !== '\n' && out[k] !== '\r') out[k] = ' '; };
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i], d = src[i + 1];
    if (c === '/' && d === '/') {
      let j = src.indexOf('\n', i); if (j === -1) j = n;
      blank(i, j); i = j;
    } else if (c === '/' && d === '*') {
      let j = src.indexOf('*/', i + 2); j = j === -1 ? n : j + 2;
      blank(i, j); i = j;
    } else if (c === '"' && src.startsWith('"""', i)) {
      let j = src.indexOf('"""', i + 3); j = j === -1 ? n : j + 3;
      blank(i + 1, j - 1); i = j;
    } else if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < n && src[j] !== c && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1;
      blank(i + 1, j); i = j + 1;
    } else i++;
  }
  return out.join('');
}

const lineNo = (loc) => { const m = /^L(\d+)/.exec(String(loc || '')); return m ? Number(m[1]) : 0; };

// --- main --------------------------------------------------------------------
export function augment(graph, buildDir, readText = (p) => readFileSync(p, 'utf8')) {
  const linkKey = Array.isArray(graph.links) ? 'links' : Array.isArray(graph.edges) ? 'edges' : 'links';
  const nodes = Array.isArray(graph.nodes) ? graph.nodes : [];
  const links = Array.isArray(graph[linkKey]) ? graph[linkKey] : [];

  // 1. strip an earlier run
  const stripped = new Set(nodes.filter((n) => n && n._origin === ORIGIN).map((n) => n.id));
  const keptNodes = nodes.filter((n) => !(n && n._origin === ORIGIN));
  const keptLinks = links.filter((e) => !(e && (e._origin === ORIGIN || stripped.has(e.source) || stripped.has(e.target))));

  // 2. layouts on disk
  let carveText = '';
  try { carveText = readText(join(buildDir, '.graphifyignore')); } catch { /* none */ }
  const files = findLayoutFiles(buildDir, carveMatcher(carveText));

  const layouts = new Map(); // `${module}\0${name}` -> { id, files: [{rel, qualifier}] }
  for (const rel of files) {
    const p = layoutParts(rel);
    if (!p) continue;
    const key = `${p.module}\0${p.name}`;
    if (!layouts.has(key)) layouts.set(key, { module: p.module, name: p.name, files: [] });
    layouts.get(key).files.push({ rel, qualifier: p.qualifier });
  }

  const ids = new Set(keptNodes.map((n) => n.id));
  const uniqueId = (base) => { let id = base, i = 2; while (ids.has(id)) id = `${base}_${i++}`; ids.add(id); return id; };

  const newNodes = [];
  const newLinks = [];
  const seenLink = new Set();
  const addLink = (source, target, relation, source_file, line, context) => {
    const k = `${source}\0${target}\0${relation}`;
    if (seenLink.has(k)) return false;
    seenLink.add(k);
    const e = { source, target, relation, _origin: ORIGIN, confidence: 'EXTRACTED', confidence_score: f1 };
    if (context) e.context = context;
    e.source_file = source_file;
    e.source_location = `L${line}`;
    e.weight = f1;
    newLinks.push(e);
    return true;
  };

  const sortedKeys = [...layouts.keys()].sort();
  for (const key of sortedKeys) {
    const L = layouts.get(key);
    const base = L.files.find((f) => !f.qualifier) || L.files[0];
    L.id = uniqueId(idOf(`${L.module ? L.module + '/' : ''}res/layout/${L.name}`) + '_layout');
    L.baseRel = base.rel;
    newNodes.push({ id: L.id, label: L.name, _origin: ORIGIN, file_type: 'code', norm_label: L.name.toLowerCase(), source_file: base.rel, source_location: 'L1' });
    for (const f of L.files) {
      if (!f.qualifier) { f.nodeId = L.id; continue; }
      f.nodeId = uniqueId(idOf(f.rel) + '_layout');
      const label = `layout-${f.qualifier}/${L.name}.xml`;
      newNodes.push({ id: f.nodeId, label, _origin: ORIGIN, file_type: 'code', norm_label: label.toLowerCase(), source_file: f.rel, source_location: 'L1' });
    }
  }
  let variants = 0;
  for (const key of sortedKeys) {
    const L = layouts.get(key);
    for (const f of L.files) if (f.qualifier) { addLink(f.nodeId, L.id, 'variant_of', f.rel, 1); variants++; }
  }

  // resolve a layout name as seen from a file in `module`: same module wins,
  // else the one module that has it, else nothing.
  const byName = new Map();
  for (const L of layouts.values()) { if (!byName.has(L.name)) byName.set(L.name, []); byName.get(L.name).push(L); }
  const resolveLayout = (name, module) => {
    const c = byName.get(name);
    if (!c) return null;
    return c.find((L) => L.module === module) || (c.length === 1 ? c[0] : null);
  };
  const bindingToName = new Map();
  for (const name of byName.keys()) bindingToName.set(`${pascal(name)}Binding`, name);

  // 3. code -> layout
  const byFile = new Map();
  for (const n of keptNodes) {
    const sf = n && typeof n.source_file === 'string' ? n.source_file.replace(/\\/g, '/') : '';
    if (!/\.(kt|java)$/i.test(sf)) continue;
    // Read only inside the checkout: an absolute or `..` path is not a repo file.
    if (isAbsolute(sf) || /^[A-Za-z]:/.test(sf) || sf.split('/').includes('..')) continue;
    if (!byFile.has(sf)) byFile.set(sf, []);
    byFile.get(sf).push(n);
  }
  const nodeById = new Map(keptNodes.map((n) => [n && n.id, n]));
  const methodOwner = new Map(); // method id -> class node
  for (const e of keptLinks) {
    if (e && e.relation === 'method' && nodeById.has(e.source) && !methodOwner.has(e.target)) methodOwner.set(e.target, nodeById.get(e.source));
  }
  let codeEdges = 0;
  if (layouts.size) {
    const RREF = /(?:\b([A-Za-z_][\w.]*)\.)?\bR\.layout\.([A-Za-z0-9_]+)/g;
    const BREF = /\b([A-Z][A-Za-z0-9]*Binding)\b/g;
    for (const sf of [...byFile.keys()].sort()) {
      let text;
      try { text = blankCommentsAndStrings(readText(join(buildDir, sf))); } catch { continue; }
      const fileNodes = byFile.get(sf);
      const starts = [0];
      for (let i = 0; i < text.length; i++) if (text.charCodeAt(i) === 10) starts.push(i + 1);
      const lineText = (l) => (l >= 1 && l <= starts.length ? text.slice(starts[l - 1], l < starts.length ? starts[l] : text.length) : '');
      // The reference belongs to the innermost CLASS whose body holds it. graphify
      // gives start lines only, so each class's end is found by brace matching on
      // the blanked text (comments and strings cannot unbalance it). A class with
      // no body owns just its header (a ViewHolder's constructor parameters). An
      // interface body never holds a layout reference, so interfaces are skipped.
      const declLines = [...new Set(fileNodes.filter((n) => n._callable).map((n) => lineNo(n.source_location)))].sort((a, b) => a - b);
      const classEnd = (line) => {
        const next = declLines.find((l) => l > line);
        const limit = next ? starts[next - 1] : text.length;
        let depth = 0;
        for (let i = starts[line - 1] || 0; i < limit; i++) {
          const c = text[i];
          if (c === '(') depth++;
          else if (c === ')') depth--;
          else if (c === '{' && depth <= 0) {
            let b = 0;
            for (let j = i; j < text.length; j++) {
              if (text[j] === '{') b++;
              else if (text[j] === '}' && --b === 0) return lineAt(starts, j);
            }
            return starts.length;
          }
        }
        return next ? next - 1 : starts.length;
      };
      const classes = fileNodes
        .filter((n) => n._callable_class && !/\binterface\s/.test(lineText(lineNo(n.source_location))))
        .map((n) => { const s = lineNo(n.source_location); return { n, s, e: classEnd(s) }; });
      const topFns = fileNodes
        .filter((n) => n._callable && !n._callable_class && !methodOwner.has(n.id) && !String(n.label).startsWith('.'))
        .map((n) => ({ n, s: lineNo(n.source_location) }));
      const fileNode = fileNodes.find((n) => n.label === basename(sf)) || null;
      const owner = (line) => {
        let best = null;
        for (const c of classes) if (c.s <= line && line <= c.e && (!best || c.s >= best.s)) best = c;
        if (best) return best.n;
        let fn = null;
        for (const f of topFns) if (f.s <= line && (!fn || f.s >= fn.s)) fn = f;
        return fn ? fn.n : fileNode;
      };
      // A qualified R (`com.vendor.lib.R`) is another package's resources unless
      // it is this file's own package or a parent of it.
      const pkg = (/^\s*package\s+([\w.]+)/m.exec(text) || [])[1] || '';
      const module = moduleOf(sf);
      const hits = [];
      for (const m of text.matchAll(RREF)) {
        if (m[1] && !(pkg === m[1] || pkg.startsWith(m[1] + '.'))) continue;
        const before = text.slice(Math.max(0, m.index - 80), m.index);
        const context = /setContentView\s*\(\s*(?:[\w.]+\s*,\s*)?$/.test(before) ? 'setContentView'
          : /inflate\s*\(\s*(?:[\w.]+\s*,\s*)?$/.test(before) ? 'inflate' : 'R.layout';
        hits.push({ name: m[2], idx: m.index, context });
      }
      for (const m of text.matchAll(BREF)) {
        const name = bindingToName.get(m[1]);
        if (name) hits.push({ name, idx: m.index, context: 'view_binding' });
      }
      hits.sort((a, b) => a.idx - b.idx);
      for (const h of hits) {
        const L = resolveLayout(h.name, module);
        if (!L) continue;
        const line = lineAt(starts, h.idx);
        // An import names the binding class; it is not a use, and would pin the
        // edge to the file's first class at the import line.
        if (/^\s*import\s/.test(text.slice(starts[line - 1], h.idx))) continue;
        const src = owner(line);
        if (!src) continue;
        if (addLink(src.id, L.id, 'uses_layout', sf, line, h.context)) codeEdges++;
      }
    }
  }

  // 4. layout -> view, layout -> layout
  const classIndex = new Map(); // simple name -> class nodes
  for (const nodesOfFile of byFile.values()) {
    for (const n of nodesOfFile) {
      if (!n._callable_class) continue;
      if (!classIndex.has(n.label)) classIndex.set(n.label, []);
      classIndex.get(n.label).push(n);
    }
  }
  const resolveClass = (fqcn) => {
    const parts = fqcn.split('.');
    const simple = parts[parts.length - 1];
    const pkgPath = parts.slice(0, -1).join('/');
    const c = (classIndex.get(simple) || []).filter((n) => n.source_file.replace(/\\/g, '/').includes(`/${pkgPath}/`));
    return c.length === 1 ? c[0] : null;
  };
  let viewEdges = 0, includeEdges = 0;
  for (const key of sortedKeys) {
    const L = layouts.get(key);
    for (const f of L.files) {
      let xml;
      try { xml = readText(join(buildDir, f.rel)); } catch { continue; }
      const starts = [0];
      for (let i = 0; i < xml.length; i++) if (xml.charCodeAt(i) === 10) starts.push(i + 1);
      const noComments = xml.replace(/<!--[\s\S]*?-->/g, (c) => c.replace(/[^\n]/g, ' '));
      for (const m of noComments.matchAll(/<([A-Za-z_][\w.$-]*)\b([^>]*)>/g)) {
        const tag = m[1];
        const line = lineAt(starts, m.index);
        if (tag === 'include') {
          const inc = /\blayout\s*=\s*(["'])@layout\/([A-Za-z0-9_]+)\1/.exec(m[2]);
          const T = inc && resolveLayout(inc[2], L.module);
          if (T && addLink(f.nodeId, T.id, 'includes', f.rel, line)) includeEdges++;
        } else if (tag.includes('.')) {
          const cls = resolveClass(tag);
          if (cls && addLink(f.nodeId, cls.id, 'uses_view', f.rel, line)) viewEdges++;
        }
      }
    }
  }

  graph.nodes = [...keptNodes, ...newNodes];
  graph[linkKey] = [...keptLinks, ...newLinks];
  return {
    layouts: layouts.size, variants, codeEdges, viewEdges, includeEdges, files: files.length,
    stripped: nodes.length - keptNodes.length,
  };
}

function main(argv) {
  let buildDir = '', graphPath = '', dryRun = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--graph') graphPath = argv[++i] || '';
    else if (a === '--dry-run') dryRun = true;
    else if (a.startsWith('-')) return error(`unknown flag '${a}'`);
    else if (!buildDir) buildDir = a;
    else return error(`unexpected argument '${a}'`);
  }
  if (!buildDir) return error('usage: android-layouts.mjs <build-dir> [--graph <graph.json>] [--dry-run]');
  buildDir = resolve(buildDir);
  graphPath = graphPath ? resolve(graphPath) : join(buildDir, 'graphify-out', 'graph.json');
  let text;
  try { text = readFileSync(graphPath, 'utf8'); } catch (e) { return error(`cannot read ${graphPath}: ${e.message}`); }
  let graph;
  try { graph = parsePyJson(text); } catch (e) { return error(`${graphPath} is not JSON: ${e.message}`); }
  if (!graph || typeof graph !== 'object' || !Array.isArray(graph.nodes)) return error(`${graphPath} has no nodes array`);

  const stats = augment(graph, buildDir);
  if (stats.files === 0 && stats.stripped === 0) {
    console.log(`ANDROID-LAYOUTS: SKIPPED - no src/main/res/layout*/*.xml under ${buildDir}; graph left as it was`);
    return 0;
  }
  const nl = /\r\n/.test(text.slice(0, 4096)) ? '\r\n' : '\n';
  const ascii = !/[^\x00-\x7f]/.test(text);
  const trailing = /\r?\n$/.test(text) ? nl : '';
  const out = dumpPyJson(graph, { nl, ascii }) + trailing;
  let state = 'unchanged';
  if (out !== text) {
    if (dryRun) state = 'dry run';
    else {
      const tmp = `${graphPath}.android-layouts.tmp`;
      writeFileSync(tmp, out);
      renameSync(tmp, graphPath);
      state = 'written';
    }
  }
  console.log(`ANDROID-LAYOUTS: OK - ${stats.layouts} layout(s), ${stats.variants} variant(s), ${stats.codeEdges} code->layout, ${stats.viewEdges} layout->view, ${stats.includeEdges} include edge(s) (${state})`);
  return 0;
}

function error(msg) {
  console.log(`ANDROID-LAYOUTS: ERROR - ${msg}`);
  return 2;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
