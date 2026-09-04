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
// REMOVE_SCOPE narrows the remove pass to a subset of the core (e.g. system_name:sorghum_353).
// REQUIRED whenever the input covers only part of what carries the capability token — without it
// the remove pass clears the capability from every gene not in this input. See the shrink guard below.
const SCOPE       = process.env.REMOVE_SCOPE || '';
const ALLOW_SHRINK = process.env.ALLOW_SHRINK === '1';
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
// The file is read TWICE and never held in memory. It used to be slurped into one array, which is
// fine for the ~250k-row layers this was written for but not for rsid: 4.1M docs carrying 459M rsID
// strings is roughly 25-40 GB of JS heap. Streaming keeps peak memory at the id list (~300 MB) plus
// one POST_BATCH, so no special heap flag is needed for any layer.
async function* ndjsonLines(file) {
  const rl = readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity });
  for await (const line of rl) { const t = line.trim(); if (t) yield t; }
}

// pass 1 — ids, plus the capability token and attribute field names derived from the docs themselves
async function scan(file) {
  const ids = [];
  const fields = new Set();
  const tokens = new Set();
  for await (const t of ndjsonLines(file)) {
    const d = JSON.parse(t);
    ids.push(d.id);
    for (const k of Object.keys(d)) {
      if (k === 'id') continue;
      if (k === 'capabilities') {
        const v = d.capabilities && d.capabilities['add-distinct'];
        if (v != null) tokens.add(v);
      } else fields.add(k);
    }
  }
  return { ids, fields: [...fields], tokens: [...tokens] };
}

// pass 2 — post SET updates for ids that exist, holding at most POST_BATCH docs at a time
async function streamSet(file, present) {
  let batch = [], sent = 0;
  for await (const t of ndjsonLines(file)) {
    const d = JSON.parse(t);
    if (!present.has(d.id)) continue;
    batch.push(d);
    if (batch.length >= POST_BATCH) {
      await solrUpdate(batch, false); sent += batch.length; batch = [];
      if ((sent / POST_BATCH) % 20 === 0) console.error(`  set ${sent}`);
    }
  }
  if (batch.length) { await solrUpdate(batch, false); sent += batch.length; }
  console.error(`  set ${sent} (done)`);
  return sent;
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
  console.error(`scanning ${FILE}`);
  let { ids, fields, tokens } = await scan(FILE);
  console.error(`  ${ids.length} atomic docs | capability token(s): ${tokens.join(',') || '(none)'} | ${fields.length} attribute field(s)`);

  console.error(SKIP_EXIST ? 'existence filter SKIPPED (SKIP_EXIST_FILTER=1)' : 'existence-filtering ids against the core…');
  const present = await existing(ids);
  const total = ids.length;
  const absent = total - present.size;
  ids = null;   // release the id list before the posting pass
  console.error(`  ${present.size} ids present, ${absent} absent (skipped — not in core)`);

  // removals: only meaningful when there is a single capability token to scope by
  let clearDocs = [];
  if (tokens.length === 1) {
    const token = tokens[0];
    console.error(`finding genes with capabilities:${token} that are NOT in the new set (removals)…`);
    const scopeQ = 'capabilities:"' + token + '"' + (SCOPE ? ' AND (' + SCOPE + ')' : '');
    if (SCOPE) console.error(`  remove pass scoped to: ${SCOPE}`);
    const curr = await currentIds(scopeQ);
    const toClear = [...curr].filter(id => !present.has(id));   // `present` IS the new id set

    // Shrink guard. A partial input (one genome, one chromosome, a truncated table) against an
    // unscoped remove pass silently strips the layer from everything it does not mention. That is
    // not hypothetical: this loader's own docs warn about it, and a single-genome rsid table would
    // clear 4.1M genes. If we are about to clear a large share of what carries the token, stop.
    if (curr.size > 0 && toClear.length > curr.size * 0.5 && !ALLOW_SHRINK) {
      throw new Error(
        `remove pass would clear ${toClear.length} of ${curr.size} genes carrying "${token}" ` +
        `(${(100 * toClear.length / curr.size).toFixed(1)}%). This is what a PARTIAL input against an ` +
        `UNSCOPED remove pass looks like. Set REMOVE_SCOPE (e.g. 'system_name:<genome>') to limit the ` +
        `remove pass to the subset this input covers, or ALLOW_SHRINK=1 if the removal is genuinely intended.`);
    }
    console.error(`  ${curr.size} genes currently carry ${token}; ${toClear.length} to clear`);
    clearDocs = toClear.map(id => {
      const o = { id, capabilities: { remove: token } };
      for (const f of fields) o[f] = { set: null };
      return o;
    });
  } else {
    console.error(`(${tokens.length} capability tokens — skipping the remove pass; ambiguous to scope)`);
  }

  let setCount = 0;
  if (present.size)     { console.error('applying SET updates…');   setCount = await streamSet(FILE, present); }
  if (clearDocs.length) { console.error('applying CLEAR updates…'); await postInBatches(clearDocs, 'clear'); }

  console.error('committing…');
  await solrUpdate('{"commit":{}}', false);

  if (tokens.length === 1) {
    const after = await solrSelect({ q: 'capabilities:"' + tokens[0] + '"', rows: '0', wt: 'json' });
    console.error(`DONE — genes with capabilities:${tokens[0]}: ${after.response.numFound} (set ${setCount}, cleared ${clearDocs.length}, absent ${absent})`);
  } else {
    console.error(`DONE — set ${setCount}, absent ${absent}`);
  }
})().catch(e => { console.error('FATAL', e); process.exit(1); });
