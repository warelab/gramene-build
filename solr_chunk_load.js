#!/usr/bin/env node
// Stream a large mongo2solr "[ {doc}\n,\n{doc}\n... ]" file into a Solr core in
// batches, so we never hold the whole 25GB array in memory or hand Solr a single
// enormous update request.
//
// RESUMABLE: docs are written in file order and committed periodically, so on
// startup we ask the core how many docs it already has (numFound) and skip that
// many doc-lines. A killed load can simply be re-run and it picks up where the
// last commit left off. Docs are upserts by uniqueKey(id), so re-loading the few
// docs in the in-flight (uncommitted) batch is harmless.
//
// usage: SOLR_URL=http://localhost:8983/solr node solr_chunk_load.js <core> <file> [batchSize]
//        SKIP_DOCS=N to force-skip a specific count instead of auto-detecting.
'use strict';
const fs = require('fs');
const readline = require('readline');

const core = process.argv[2];
const file = process.argv[3];
const BATCH = parseInt(process.argv[4] || '10000', 10);
// How often to issue an explicit commit=true (which opens+warms a new searcher).
// Each such commit lets a killed load resume from the committed numFound, but adds
// a searcher-reopen + segment flush. Solr's own autoCommit (openSearcher=false)
// already provides durability, so for a detached, non-kill-prone load you can set
// SOLR_COMMIT_EVERY=0 to skip ALL intermediate commits (only commit at the very
// end) for max throughput. Default 50 (~every 500k docs) balances the two.
const COMMIT_EVERY = parseInt(process.env.SOLR_COMMIT_EVERY || '50', 10);
const SOLR = (process.env.SOLR_URL || 'http://localhost:8983/solr').replace(/\/$/, '');
if (!core || !file) { console.error('usage: solr_chunk_load.js <core> <file> [batchSize]'); process.exit(2); }
const base = `${SOLR}/${core}/update`;

async function numFound() {
  if (process.env.SKIP_DOCS !== undefined) return parseInt(process.env.SKIP_DOCS, 10) || 0;
  try {
    const res = await fetch(`${SOLR}/${core}/select?q=*:*&rows=0&wt=json`);
    const j = await res.json();
    return j.response.numFound || 0;
  } catch (e) { return 0; }
}

async function post(docLines, commit) {
  if (!docLines.length && !commit) return;
  const body = docLines.length ? '[' + docLines.join(',') + ']' : '[]';
  const res = await fetch(`${base}?commit=${commit ? 'true' : 'false'}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body
  });
  const txt = await res.text();
  if (!res.ok || !/"status":0/.test(txt)) {
    throw new Error(`solr update failed (HTTP ${res.status}): ${txt.slice(0, 400)}`);
  }
}

(async () => {
  const skip = await numFound();
  if (skip) console.error(`resuming: core ${core} already has ${skip} docs — skipping that many doc-lines`);
  const rl = readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity });
  let seen = 0, batch = [], total = 0, batches = 0;
  for await (const line of rl) {
    if (line.length && line.charCodeAt(0) === 123 /* { */) {
      seen++;
      if (seen <= skip) continue;          // already loaded in a prior run
      batch.push(line);
      if (batch.length >= BATCH) {
        batches++;
        await post(batch, COMMIT_EVERY > 0 && batches % COMMIT_EVERY === 0);
        total += batch.length;
        batch = [];
        if (batches % 5 === 0) console.error(`  loaded ${skip + total} / docs so far (${batches} new batches)`);
      }
    }
  }
  if (batch.length) { await post(batch, false); total += batch.length; }
  await post([], true);   // final commit
  console.error(`DONE: core ${core} now has ${skip + total} docs (loaded ${total} this run) and is committed`);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
