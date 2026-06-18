#!/usr/bin/env node
'use strict';
// solr_atomic_attr.js — apply ONE attribute layer's atomic updates (from
// attr_table_to_atomic.js) to an ALREADY-LOADED genes core, in place, no full
// reload. Generic over the attribute type: it infers the capability token and the
// field set from the NDJSON, so it works for MAKER / VEP / grassius_homolog /
// expression alike.
//
//   node solr_atomic_attr.js <genesCoreUrl> <atomic.ndjson>
//
//   1. EXISTENCE FILTER — only patch ids that already exist (an atomic update on a
//      missing id would CREATE an orphan partial doc). Uses the {!terms} parser so it
//      scales to ~1M ids. Absent ids are reported (surfaces id mismatches, e.g.
//      poplar Potri.*.v4.1). Skippable with SKIP_EXIST_FILTER=1 for trusted ids.
//   2. SET — posts the atomic docs in batches.
//   3. REMOVE — any gene currently carrying this capability token that is NOT in the
//      new set gets its fields cleared + the token removed (handles drop-outs).
//   4. COMMIT once at the end.
//
// Uses Node's global fetch; no external deps.

const CORE = process.argv[2];
const FILE = process.argv[3];
if (!CORE || !FILE) { console.error('usage: solr_atomic_attr.js <genesCoreUrl> <ndjson>'); process.exit(2); }

const EXIST_BATCH = parseInt(process.env.EXIST_BATCH || '5000', 10);
const POST_BATCH  = parseInt(process.env.POST_BATCH  || '5000', 10);
const SKIP_EXIST  = process.env.SKIP_EXIST_FILTER === '1';
const SEP = '|';   // {!terms} separator; gene ids never contain '|'
const fs = require('fs');
const readline = require('readline');

async function solrSelect(params) {
  const r = await fetch(CORE + '/select', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params).toString()
  });
  if (!r.ok) throw new Error('select failed ' + r.status + ' ' + (await r.text()).slice(0, 300));
  return r.json();
}
async function solrUpdate(body, commit) {
  const r = await fetch(CORE + '/update' + (commit ? '?commit=true' : ''), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: typeof body === 'string' ? body : JSON.stringify(body)
  });
  if (!r.ok) throw new Error('update failed ' + r.status + ' ' + (await r.text()).slice(0, 300));
  return r.json();
}
async function readNdjson(file) {
  const docs = [];
  const rl = readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity });
  for await (const line of rl) { const t = line.trim(); if (t) docs.push(JSON.parse(t)); }
  return docs;
}

// derive the capability token and the attribute field names from the docs themselves
function infer(docs) {
  const fields = new Set();
  const tokens = new Set();
  for (const d of docs) {
    for (const k of Object.keys(d)) {
      if (k === 'id') continue;
      if (k === 'capabilities') {
        const t = d.capabilities && d.capabilities['add-distinct'];
        if (t != null) tokens.add(t);
      } else fields.add(k);
    }
  }
  return { fields: [...fields], tokens: [...tokens] };
}

async function existing(ids) {
  if (SKIP_EXIST) return new Set(ids);
  const present = new Set();
  for (let i = 0; i < ids.length; i += EXIST_BATCH) {
    const batch = ids.slice(i, i + EXIST_BATCH);
    const j = await solrSelect({ q: '{!terms f=id separator="' + SEP + '"}' + batch.join(SEP), fl: 'id', rows: String(batch.length), wt: 'json' });
    for (const d of j.response.docs) present.add(d.id);
    if ((i / EXIST_BATCH) % 10 === 0) console.error(`  existence-check ${Math.min(i + EXIST_BATCH, ids.length)}/${ids.length}`);
  }
  return present;
}

// ids currently carrying the capability token (cursorMark paging)
async function currentIds(query) {
  const ids = new Set();
  let cursor = '*', prev = null;
  do {
    const j = await solrSelect({ q: query, fl: 'id', rows: '20000', sort: 'id asc', cursorMark: cursor, wt: 'json' });
    for (const d of j.response.docs) ids.add(d.id);
    prev = cursor; cursor = j.nextCursorMark;
  } while (cursor !== prev);
  return ids;
}

async function postInBatches(docs, label) {
  for (let i = 0; i < docs.length; i += POST_BATCH) {
    await solrUpdate(docs.slice(i, i + POST_BATCH), false);
    console.error(`  ${label} ${Math.min(i + POST_BATCH, docs.length)}/${docs.length}`);
  }
}

(async () => {
  console.error(`reading ${FILE}`);
  const docs = await readNdjson(FILE);
  const { fields, tokens } = infer(docs);
  console.error(`  ${docs.length} atomic docs | capability token(s): ${tokens.join(',') || '(none)'} | ${fields.length} attribute field(s)`);

  const ids = docs.map(d => d.id);
  console.error(SKIP_EXIST ? 'existence filter SKIPPED (SKIP_EXIST_FILTER=1)' : 'existence-filtering ids against the core…');
  const present = await existing(ids);
  const setDocs = docs.filter(d => present.has(d.id));
  const absent = ids.length - setDocs.length;
  console.error(`  ${setDocs.length} ids present, ${absent} absent (skipped — not in core)`);

  // removals: only meaningful when there is a single capability token to scope by
  let clearDocs = [];
  if (tokens.length === 1) {
    const token = tokens[0];
    console.error(`finding genes with capabilities:${token} that are NOT in the new set (removals)…`);
    const curr = await currentIds('capabilities:"' + token + '"');
    const newSet = new Set(setDocs.map(d => d.id));
    const toClear = [...curr].filter(id => !newSet.has(id));
    console.error(`  ${curr.size} genes currently carry ${token}; ${toClear.length} to clear`);
    clearDocs = toClear.map(id => {
      const o = { id, capabilities: { remove: token } };
      for (const f of fields) o[f] = { set: null };
      return o;
    });
  } else {
    console.error(`(${tokens.length} capability tokens — skipping the remove pass; ambiguous to scope)`);
  }

  if (setDocs.length)   { console.error('applying SET updates…');   await postInBatches(setDocs, 'set'); }
  if (clearDocs.length) { console.error('applying CLEAR updates…'); await postInBatches(clearDocs, 'clear'); }

  console.error('committing…');
  await solrUpdate('{"commit":{}}', false);

  if (tokens.length === 1) {
    const after = await solrSelect({ q: 'capabilities:"' + tokens[0] + '"', rows: '0', wt: 'json' });
    console.error(`DONE — genes with capabilities:${tokens[0]}: ${after.response.numFound} (set ${setDocs.length}, cleared ${clearDocs.length}, absent ${absent})`);
  } else {
    console.error(`DONE — set ${setDocs.length}, absent ${absent}`);
  }
})().catch(e => { console.error('FATAL', e); process.exit(1); });
