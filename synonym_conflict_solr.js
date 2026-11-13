#!/usr/bin/env node
// synonym_conflict_solr.js — reconcile the genes core after synonym_conflict_patch.js.
//
// Two fields carry a synonym into the index: `synonyms` (the list itself) and `_terms` (the
// catch-all that search and the suggestion builder read). Cleaning only `synonyms` would leave the
// contaminated id searchable via `_terms`, which is the actual false positive being fixed.
//
// The new value is the CORE's list minus the contaminants -- deliberately not mongo's list.
// mongo2solr.join.js:162-181 drops any synonym equal to the gene's name or id (case-insensitively)
// and dedupes the rest by lowercase, so the core legitimately holds FEWER synonyms than mongo and
// pushing mongo's list would re-add values the build removes on purpose. Removing only the named
// contaminants sidesteps having to reimplement that filter at all.
//
// The guard therefore checks something narrower: a synonym mongo has and the core lacks is fine
// when the filter above explains it, and an abort otherwise -- that would mean the core is not
// merely stale and a `set` could lose data.
//
// `_terms` needs more care. The same string can reach `_terms` from a field OTHER than `synonyms`
// (an xref id, a name, a description), and removing it then would delete a legitimate search term.
// So for each string being dropped, every other stored field of that document is scanned, and the
// string is removed from `_terms` only when nothing else supplies it. Strings that survive that
// test are reported, not silently kept.

'use strict';
const path = require('path');
const http = require('http');
const https = require('https');

const MONGO_LIB = path.join(__dirname, '..', 'gramene-mongodb', 'node_modules', 'mongodb');
const URI  = process.env.MONGO_URI || 'mongodb://localhost:27017';
const DB   = process.env.MONGO_DB;
const CORE = process.env.GENES_CORE;
const APPLY = process.argv.indexOf('--apply') >= 0;
if (!DB || !CORE) {
  console.error('usage: MONGO_DB=oryza10 GENES_CORE=http://host:8983/solr/oryza_genes10 node synonym_conflict_solr.js [--apply]');
  process.exit(1);
}
const SKIP_FIELDS = new Set(['synonyms', '_terms', '_version_']);

function req(url, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const mod = u.protocol === 'https:' ? https : http;
    const opts = { method: body ? 'POST' : 'GET', hostname: u.hostname, port: u.port,
      path: u.pathname + u.search,
      headers: body ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } : {} };
    const r = mod.request(opts, res => {
      let s = '';
      res.on('data', d => s += d);
      res.on('end', () => res.statusCode === 200 ? resolve(s)
        : reject(new Error('HTTP ' + res.statusCode + ' ' + url + ' :: ' + s.slice(0, 300))));
    });
    r.on('error', reject);
    if (body) r.write(body);
    r.end();
  });
}

(async function main() {
  const { MongoClient } = require(MONGO_LIB);
  const client = await MongoClient.connect(URI, { useNewUrlParser: true, useUnifiedTopology: true });
  const genes = client.db(DB).collection('genes');

  // Candidates: every gene the core lists a synonym for that mongo no longer has. The core is the
  // side still holding the stale values, so it drives the candidate set (the same lesson as the
  // MSU patch: a mongo-only candidate set misses exactly the rows that were cleaned).
  const docs = [];
  let cursor = '*';
  for (;;) {
    const body = JSON.stringify({ query: 'synonyms:*', fields: '*', limit: 2000,
      sort: 'id asc', params: { cursorMark: cursor } });
    const j = JSON.parse(await req(CORE + '/select', body));
    for (const d of j.response.docs) docs.push(d);
    process.stdout.write('  core docs with synonyms: ' + docs.length + '\r');
    if (!j.nextCursorMark || j.nextCursorMark === cursor || !j.response.docs.length) break;
    cursor = j.nextCursorMark;
  }
  console.log('\ncore docs carrying synonyms : ' + docs.length);

  const ids = docs.map(d => d.id);
  const mongoSyn = new Map();
  for (let i = 0; i < ids.length; i += 2000) {
    for (const g of await genes.find({ _id: { $in: ids.slice(i, i + 2000) } },
      { projection: { synonyms: 1 } }).toArray()) {
      mongoSyn.set(g._id, Array.isArray(g.synonyms) ? g.synonyms : (g.synonyms ? [g.synonyms] : []));
    }
  }

  const updates = [];
  let changed = 0, dropped = 0, termsKept = 0, mismatched = 0;
  const kept = [], bad = [];
  for (const d of docs) {
    const sIn = Array.isArray(d.synonyms) ? d.synonyms : (d.synonyms ? [d.synonyms] : []);
    const mIn = mongoSyn.get(d.id) || [];
    const removals = sIn.filter(s => mIn.indexOf(s) < 0);
    if (!removals.length) continue;
    // A synonym mongo has that the core lacks is expected when mongo2solr's filter explains it:
    // equal to the name or id case-insensitively, or a case-variant of a synonym already kept.
    const lcKept = new Set(sIn.map(x => String(x).toLowerCase()));
    const lcName = String(d.name || '').toLowerCase(), lcId = String(d.id).toLowerCase();
    const unexplained = mIn.filter(s => {
      if (sIn.indexOf(s) >= 0) return false;
      const lc = String(s).toLowerCase();
      return lc !== lcName && lc !== lcId && !lcKept.has(lc);
    });
    if (unexplained.length) { mismatched++; if (bad.length < 5) bad.push(d.id + ' core lacks ' + unexplained.join(',')); continue; }
    changed++; dropped += removals.length;

    const terms = Array.isArray(d._terms) ? d._terms.slice() : [];
    const elsewhere = new Set();
    for (const [k, v] of Object.entries(d)) {
      if (SKIP_FIELDS.has(k)) continue;
      const s = JSON.stringify(v);
      for (const r of removals) if (s === JSON.stringify(r) || (typeof v === 'string' && v === r)
        || (Array.isArray(v) && v.indexOf(r) >= 0)) elsewhere.add(r);
    }
    for (const r of removals) if (elsewhere.has(r)) { termsKept++; kept.push(d.id + ' keeps term ' + r); }
    const nextTerms = terms.filter(t => !(removals.indexOf(t) >= 0 && !elsewhere.has(t)));
    const nextSyn = sIn.filter(x => removals.indexOf(x) < 0);
    const u = { id: d.id, synonyms: { set: nextSyn.length ? nextSyn : null } };
    if (nextTerms.length !== terms.length) u._terms = { set: nextTerms };
    updates.push(u);
  }

  if (mismatched) {
    console.error('\nABORT: ' + mismatched + ' gene(s) have synonyms in mongo that the core lacks, so the core'
      + ' is not merely stale and `set` could lose data. Nothing was written.');
    for (const b of bad) console.error('  ' + b);
    await client.close(); process.exit(2);
  }

  console.log('genes to update             : ' + changed);
  console.log('synonym values to drop      : ' + dropped);
  console.log('_terms entries kept (another field supplies them): ' + termsKept);
  for (const k of kept.slice(0, 8)) console.log('    ' + k);

  if (!APPLY) {
    console.log('\ndry run -- nothing posted. re-run with --apply');
  } else if (updates.length) {
    for (let i = 0; i < updates.length; i += 500) await req(CORE + '/update', JSON.stringify(updates.slice(i, i + 500)));
    await req(CORE + '/update?commit=true', '{}');
    console.log('\ncommitted.');
  } else {
    console.log('\nnothing to post.');
  }
  await client.close();
})().catch(e => { console.error('synonym_conflict_solr: ' + (e.stack || e.message)); process.exit(1); });
