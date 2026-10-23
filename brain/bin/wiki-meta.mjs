// wiki-meta.mjs — the wiki's meta notes: the catalog (index.md), the rolling
// cache (hot.md) and the append-only log (log.md). They describe the wiki rather
// than hold a concept, so freshness does not lint them as notes, tidy does not
// re-anchor them, and /brain:save 5c never extracts them into the concept graph
// (INNOV-408: log.md is append-only, so it changed on every save and cost a full
// re-extract each time).
//
// One set for every caller. changed-wiki-notes.sh mirrors it in bash (a `case`
// in emit()); tests/test-changed-wiki-notes.sh reads this file to keep the two
// in step.
export const META_NOTES = new Set(['index.md', 'hot.md', 'log.md']);

// Matched on the basename, at any depth, as freshness always has.
export const isMetaNote = (p) => META_NOTES.has(String(p).split(/[\\/]/).pop());
