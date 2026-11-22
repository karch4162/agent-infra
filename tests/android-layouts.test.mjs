// tests/android-layouts.test.mjs — INNOV-427: res/layout XML into the code graph.
// Run via tests/test-android-layouts.sh (node --test).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dumpPyJson, parsePyJson } from '../brain/bin/android-layouts.mjs';

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), '..', 'brain', 'bin', 'android-layouts.mjs');
const F = '\u0000android-layouts-float:1.0';

function put(root, rel, text) {
  mkdirSync(dirname(join(root, rel)), { recursive: true });
  writeFileSync(join(root, rel), text);
}

const J = 'app/src/main/java/com/example/app';
const n = (id, label, sf, line, extra = {}) => ({ id, label, _origin: 'ast', community: 0, file_type: 'code', source_file: sf, source_location: `L${line}`, ...extra });
const cls = { _callable: true, _callable_class: true };
const fn = { _callable: true };
const edge = (source, target, relation, sf) => ({ source, target, relation, _origin: 'ast', confidence: 'EXTRACTED', confidence_score: F, source_file: sf, source_location: 'L1', weight: F });

function fixture({ crlf = false } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'android-layouts-'));
  const eol = (s) => (crlf ? s.replace(/\n/g, '\r\n') : s);
  // layouts
  put(root, 'app/src/main/res/layout/activity_main.xml', eol(`<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android">
    <include layout="@layout/toolbar" />
    <!-- <include layout="@layout/item_row" /> -->
    <com.example.app.ui.FancyView
        android:id="@+id/fancy" />
    <androidx.recyclerview.widget.RecyclerView android:id="@+id/list" />
</LinearLayout>
`));
  put(root, 'app/src/main/res/layout-land/activity_main.xml', eol(`<FrameLayout>
    <com.example.app.ui.FancyView />
</FrameLayout>
`));
  put(root, 'app/src/main/res/layout/toolbar.xml', eol('<Toolbar />\n'));
  put(root, 'app/src/main/res/layout/item_row.xml', eol('<TextView />\n'));
  put(root, 'app/src/main/res/layout-sw600dp/item_row.xml', eol('<TextView />\n'));
  put(root, 'app/src/main/res/layout/simple_list_item_1.xml', eol('<TextView />\n'));
  put(root, 'app/src/main/res/layout/orphan_only_land.xml.bak', 'not xml\n');
  put(root, 'app/src/main/res/layout-land/only_land.xml', eol('<TextView />\n'));
  // never indexed: build output, a carved module, a test source set
  put(root, 'app/build/intermediates/src/main/res/layout/junk.xml', '<X />\n');
  put(root, 'bench/src/main/res/layout/bench.xml', '<X />\n');
  put(root, 'app/src/androidTest/res/layout/test_only.xml', '<X />\n');
  put(root, '.graphifyignore', 'build/\nbench/\n');
  // code
  put(root, `${J}/MainActivity.kt`, eol(`package com.example.app

class MainActivity : AppCompatActivity() {
    override fun onCreate(b: Bundle?) {
        setContentView(R.layout.activity_main)
    }
}
`));
  put(root, `${J}/RowAdapter.java`, eol(`package com.example.app;

public class RowAdapter {
    interface Listener {
        void onRow();
    }
    private final int header = R.layout.item_row;
    public View make(LayoutInflater inflater) {
        View v = inflater.inflate(R.layout.toolbar, null);
        int x = android.R.layout.simple_list_item_1;
        return v;
    }
}
`));
  put(root, `${J}/ToolbarHost.kt`, eol(`package com.example.app

import com.example.app.databinding.ToolbarBinding

class ToolbarHost {
    fun bind() {
        val b = ToolbarBinding.inflate(layoutInflater)
    }
}
`));
  put(root, `${J}/ui/FancyView.kt`, eol('package com.example.app.ui\n\nclass FancyView : View\n'));
  const nodes = [
    n('main_kt', 'MainActivity.kt', `${J}/MainActivity.kt`, 1),
    n('main_cls', 'MainActivity', `${J}/MainActivity.kt`, 3, cls),
    n('main_oncreate', '.onCreate()', `${J}/MainActivity.kt`, 4, fn),
    n('row_java', 'RowAdapter.java', `${J}/RowAdapter.java`, 1),
    n('row_cls', 'RowAdapter', `${J}/RowAdapter.java`, 3, cls),
    n('row_listener', 'Listener', `${J}/RowAdapter.java`, 4, cls),
    n('row_onrow', '.onRow()', `${J}/RowAdapter.java`, 5, fn),
    n('row_make', '.make()', `${J}/RowAdapter.java`, 8, fn),
    n('tb_kt', 'ToolbarHost.kt', `${J}/ToolbarHost.kt`, 1),
    n('tb_cls', 'ToolbarHost', `${J}/ToolbarHost.kt`, 5, cls),
    n('tb_bind', '.bind()', `${J}/ToolbarHost.kt`, 6, fn),
    n('fancy_kt', 'FancyView.kt', `${J}/ui/FancyView.kt`, 1),
    n('fancy_cls', 'FancyView', `${J}/ui/FancyView.kt`, 3, { ...cls, note: 'café' }),
  ];
  const links = [
    edge('main_cls', 'main_oncreate', 'method', `${J}/MainActivity.kt`),
    edge('row_cls', 'row_make', 'method', `${J}/RowAdapter.java`),
    edge('row_listener', 'row_onrow', 'method', `${J}/RowAdapter.java`),
    edge('tb_cls', 'tb_bind', 'method', `${J}/ToolbarHost.kt`),
  ];
  const graph = { directed: false, multigraph: false, graph: { schema_version: 1 }, nodes, links, hyperedges: [], built_at_commit: 'abc1234' };
  const nl = crlf ? '\r\n' : '\n';
  put(root, 'graphify-out/graph.json', dumpPyJson(graph, { nl }) + nl);
  return root;
}

const run = (root, ...args) => spawnSync(process.execPath, [SCRIPT, root, ...args], { encoding: 'utf8' });
const load = (root) => JSON.parse(readFileSync(join(root, 'graphify-out', 'graph.json'), 'utf8'));
const tagged = (g) => ({
  nodes: g.nodes.filter((x) => x._origin === 'android-layouts'),
  links: g.links.filter((x) => x._origin === 'android-layouts'),
});
const has = (links, source, target, relation) => links.some((e) => e.source === source && e.target === target && e.relation === relation);

for (const crlf of [false, true]) {
  test(`indexes layouts, variants and their edges (${crlf ? 'CRLF' : 'LF'})`, () => {
    const root = fixture({ crlf });
    try {
      const r = run(root);
      assert.equal(r.status, 0, r.stdout + r.stderr);
      assert.match(r.stdout, /^ANDROID-LAYOUTS: OK - 5 layout\(s\), 3 variant\(s\), 4 code->layout, 2 layout->view, 1 include edge\(s\) \(written\)/);
      const g = load(root);
      const t = tagged(g);
      const byLabel = Object.fromEntries(t.nodes.map((x) => [x.label, x]));
      assert.deepEqual(Object.keys(byLabel).sort(), [
        'activity_main', 'item_row', 'layout-land/activity_main.xml', 'layout-land/only_land.xml',
        'layout-sw600dp/item_row.xml', 'only_land', 'simple_list_item_1', 'toolbar',
      ]);
      const L = (name) => byLabel[name].id;
      // name node points at the base file; a layout with no base file points at its variant
      assert.equal(byLabel.activity_main.source_file, 'app/src/main/res/layout/activity_main.xml');
      assert.equal(byLabel.only_land.source_file, 'app/src/main/res/layout-land/only_land.xml');
      assert.ok(has(t.links, L('layout-land/activity_main.xml'), L('activity_main'), 'variant_of'));
      assert.ok(has(t.links, L('layout-sw600dp/item_row.xml'), L('item_row'), 'variant_of'));
      // code -> layout, from the enclosing class (not the nested interface above the method)
      const main = t.links.find((e) => e.source === 'main_cls' && e.target === L('activity_main'));
      assert.equal(main.relation, 'uses_layout');
      assert.equal(main.context, 'setContentView');
      assert.equal(main.source_location, 'L5');
      const row = t.links.find((e) => e.target === L('item_row') && e.relation === 'uses_layout');
      assert.equal(row.source, 'row_cls', 'a field below a nested interface is the outer class');
      assert.equal(row.context, 'R.layout');
      const inflate = t.links.find((e) => e.source === 'row_cls' && e.target === L('toolbar'));
      assert.equal(inflate.context, 'inflate');
      const bind = t.links.find((e) => e.target === L('toolbar') && e.relation === 'uses_layout' && e.source === 'tb_cls');
      assert.equal(bind.source, 'tb_cls');
      assert.equal(bind.context, 'view_binding');
      assert.equal(bind.source_location, 'L7', 'the import line is not a use');
      // android.R.layout.* is the framework's, never ours
      assert.ok(!t.links.some((e) => e.target === L('simple_list_item_1')));
      // layout -> view (base and variant), unresolved framework tags add nothing
      assert.ok(has(t.links, L('activity_main'), 'fancy_cls', 'uses_view'));
      assert.ok(has(t.links, L('layout-land/activity_main.xml'), 'fancy_cls', 'uses_view'));
      // include; the commented-out include does not count
      assert.ok(has(t.links, L('activity_main'), L('toolbar'), 'includes'));
      assert.ok(!has(t.links, L('activity_main'), L('item_row'), 'includes'));
      // nothing from build/, a carved module or a test source set
      const files = t.nodes.map((x) => x.source_file).join(' ');
      assert.doesNotMatch(files, /junk|bench|test_only/);
      // every edge resolves, root keys and existing content survive
      const ids = new Set(g.nodes.map((x) => x.id));
      for (const e of t.links) assert.ok(ids.has(e.source) && ids.has(e.target), JSON.stringify(e));
      assert.equal(g.built_at_commit, 'abc1234');
      assert.equal(g.nodes.length, 13 + 8);
      // Python format kept: newline style, 1.0 floats, ASCII escapes
      const text = readFileSync(join(root, 'graphify-out', 'graph.json'), 'utf8');
      assert.equal(/\r\n/.test(text), crlf);
      assert.match(text, /"weight": 1\.0/);
      assert.match(text, /"caf\\u00e9"/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
}

test('a second run is a byte-identical no-op', () => {
  const root = fixture();
  try {
    run(root);
    const first = readFileSync(join(root, 'graphify-out', 'graph.json'), 'utf8');
    const r = run(root);
    assert.match(r.stdout, /\(unchanged\)/);
    assert.equal(readFileSync(join(root, 'graphify-out', 'graph.json'), 'utf8'), first);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('a removed layout takes its nodes and every edge touching them with it', () => {
  const root = fixture();
  try {
    run(root);
    rmSync(join(root, 'app/src/main/res/layout/toolbar.xml'));
    run(root);
    const t = tagged(load(root));
    assert.ok(!t.nodes.some((x) => x.label === 'toolbar'));
    assert.ok(!t.links.some((e) => e.relation === 'includes'));
    assert.ok(!t.links.some((e) => e.context === 'view_binding'));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('a build with no layouts is SKIPPED and the graph is untouched', () => {
  const root = mkdtempSync(join(tmpdir(), 'android-layouts-'));
  try {
    const text = '{\n  "nodes": [],\n  "links": []\n}';
    put(root, 'graphify-out/graph.json', text);
    const r = run(root);
    assert.equal(r.status, 0);
    assert.match(r.stdout, /^ANDROID-LAYOUTS: SKIPPED - /);
    assert.equal(readFileSync(join(root, 'graphify-out', 'graph.json'), 'utf8'), text);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('an unreadable graph is an ERROR, exit 2, never OK', () => {
  const root = mkdtempSync(join(tmpdir(), 'android-layouts-'));
  try {
    put(root, 'graphify-out/graph.json', '{ not json');
    const r = run(root);
    assert.equal(r.status, 2);
    assert.match(r.stdout, /^ANDROID-LAYOUTS: ERROR - /);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('Python json.dump(indent=2) text round-trips byte for byte', () => {
  const text = '{\r\n  "a": 1.0,\r\n  "b": [],\r\n  "c": {},\r\n  "d": [\r\n    "x\\"y\\\\z\\u00e9\\n",\r\n    -2,\r\n    0.85,\r\n    1e-05,\r\n    null,\r\n    true\r\n  ]\r\n}';
  assert.equal(dumpPyJson(parsePyJson(text), { nl: '\r\n' }), text);
});

test('a same-module layout wins over a same-named one in another module', () => {
  const root = fixture();
  try {
    put(root, 'feature/src/main/res/layout/item_row.xml', '<TextView />\n');
    put(root, 'feature/src/main/res/layout/feature_only.xml', '<TextView />\n');
    const sf = 'feature/src/main/java/com/example/feature/FeatureView.kt';
    put(root, sf, 'package com.example.feature\n\nclass FeatureView {\n    val a = R.layout.item_row\n}\n');
    // app code reaching a layout only the feature module has resolves to it
    put(root, `${J}/MainActivity.kt`, readFileSync(join(root, `${J}/MainActivity.kt`), 'utf8').replace('setContentView(R.layout.activity_main)', 'setContentView(R.layout.activity_main); R.layout.feature_only'));
    const g = parsePyJson(readFileSync(join(root, 'graphify-out', 'graph.json'), 'utf8'));
    g.nodes.push(n('fv_cls', 'FeatureView', sf, 3, cls));
    put(root, 'graphify-out/graph.json', dumpPyJson(g) + '\n');
    assert.equal(run(root).status, 0);
    const t = tagged(load(root));
    const id = (file) => t.nodes.find((x) => x.source_file === file).id;
    assert.ok(has(t.links, 'fv_cls', id('feature/src/main/res/layout/item_row.xml'), 'uses_layout'));
    assert.ok(!has(t.links, 'fv_cls', id('app/src/main/res/layout/item_row.xml'), 'uses_layout'));
    assert.ok(has(t.links, 'row_cls', id('app/src/main/res/layout/item_row.xml'), 'uses_layout'));
    assert.ok(has(t.links, 'main_cls', id('feature/src/main/res/layout/feature_only.xml'), 'uses_layout'));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('references in code comments and string literals are not uses', () => {
  const root = fixture();
  try {
    put(root, `${J}/MainActivity.kt`, `package com.example.app

class MainActivity : AppCompatActivity() {
    override fun onCreate(b: Bundle?) {
        val url = "https://x.test/a" // R.layout.toolbar
        /* setContentView(R.layout.item_row)
           ToolbarBinding.inflate(i) */
        val s = "R.layout.only_land"
        setContentView(R.layout.activity_main)
    }
}
`);
    assert.equal(run(root).status, 0);
    const t = tagged(load(root));
    const from = t.links.filter((e) => e.source === 'main_cls').map((e) => t.nodes.find((x) => x.id === e.target).label);
    assert.deepEqual(from, ['activity_main']);
    assert.equal(t.links.find((e) => e.source === 'main_cls').source_location, 'L9', 'line numbers survive the blanking');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('single-quoted include attributes count; a directory named *.xml is not a layout', () => {
  const root = fixture();
  try {
    put(root, 'app/src/main/res/layout/item_row.xml', "<FrameLayout>\n    <include layout='@layout/toolbar' />\n</FrameLayout>\n");
    mkdirSync(join(root, 'app/src/main/res/layout/not_a_layout.xml'), { recursive: true });
    assert.equal(run(root).status, 0);
    const t = tagged(load(root));
    const L = (label) => t.nodes.find((x) => x.label === label).id;
    assert.ok(has(t.links, L('item_row'), L('toolbar'), 'includes'));
    assert.ok(!t.nodes.some((x) => x.label === 'not_a_layout'));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
