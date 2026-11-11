#!/usr/bin/env node
// msu_solr_patch.js — reconcile the genes core's `alt_id` with mongo after msu_alt_id_patch.js.
//
// WHY `set` AND NOT `add-distinct`. The pubmed repair only ever ADDS ids, so it can use
// add-distinct, which cannot lose a value to a race. This one must REMOVE the MSU ids RAP-DB has
// retracted, so it has to replace the field. That is only safe if mongo holds the WHOLE truth
// about alt_id -- if any later stage appended to solr's alt_id without going through mongo, a
// `set` would silently drop it.
//
// So that assumption is TESTED, not assumed: every candidate gene we are NOT changing is
// compared field-for-field, solr against mongo. A single divergence aborts before anything is
// written and names the gene, because it would mean `set` is the wrong operator here.
//
// alt_id is a `lowercase` field: solr lowercases at index time, so the comparison lowercases
// both sides (the same hand-lowercasing solr.js does when it queries alt_id).

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
  console.error('usage: MONGO_DB=oryza10 GENES_CORE=http://host:8983/solr/oryza_genes10 node msu_solr_patch.js [--apply]');
  process.exit(1);
}
const LUT = require(path.join(__dirname, '..', 'gramene-mongodb', 'search', 'OsNipp_IRGSP_MSU_lut.json'));
const IS_MSU = /^LOC_Os/i;
const lc = a => a.map(x => String(x).toLowerCase()).sort();

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
        : reject(new Error('HTTP ' + res.statusCode + ' ' + url + ' :: ' + s.slice(0, 400))));
    });
    r.on('error', reject);
    if (body) r.write(body);
    r.end();
  });
}
// Every id the CORE currently carries an MSU alt_id for. Needed because the mongo side has
// already been patched: a gene whose MSU id RAP-DB retracted no longer matches `alt_id:/^LOC_Os/`
// in mongo and is not in the LUT either, so it would never enter the candidate set -- and its
// stale value would sit in the index forever. alt_id is a `lowercase` field, hence `loc_os*`.
async function solrMsuIds() {
  const out = [];
  let cursor = '*';
  for (;;) {
    const body = JSON.stringify({ query: 'alt_id:loc_os*', fields: 'id', limit: 5000,
      sort: 'id asc', params: { cursorMark: cursor } });
    const j = JSON.parse(await req(CORE + '/select', body));
    for (const d of j.response.docs) out.push(d.id);
    process.stdout.write('  core ids ' + out.length + '\r');
    if (!j.nextCursorMark || j.nextCursorMark === cursor || !j.response.docs.length) break;
    cursor = j.nextCursorMark;
  }
  return out;
}

async function solrGet(ids) {
  const out = {};
  for (let i = 0; i < ids.length; i += 400) {
    const chunk = ids.slice(i, i + 400);
    const body = JSON.stringify({ query: '*:*', filter: ['{!terms f=id separator=|}' + chunk.join('|')],
      fields: 'id,alt_id', limit: chunk.length });
    const j = JSON.parse(await req(CORE + '/select', body));
    for (const d of j.response.docs) out[d.id] = Array.isArray(d.alt_id) ? d.alt_id : (d.alt_id ? [d.alt_id] : []);
    process.stdout.write('  read ' + Math.min(i + 400, ids.length) + '/' + ids.length + '\r');
  }
  return out;
}

(async function main() {
  const { MongoClient } = require(MONGO_LIB);
  const client = await MongoClient.connect(URI, { useNewUrlParser: true, useUnifiedTopology: true });
  const genes = client.db(DB).collection('genes');

  const ids = new Set(Object.keys(LUT));
  for (const g of await genes.find({ alt_id: IS_MSU }, { projection: { _id: 1 } }).toArray()) ids.add(g._id);
  const fromCore = await solrMsuIds();
  let onlyInCore = 0;
  for (const id of fromCore) if (!ids.has(id)) { ids.add(id); onlyInCore++; }
  console.log('\ncore ids carrying an MSU alt_id : ' + fromCore.length
    + '  (' + onlyInCore + ' of them absent from the LUT and from mongo`s MSU set -- these are'
    + ' the retractions that only the core still holds)');
  const mongoDocs = {};
  const idList = Array.from(ids);
  for (let i = 0; i < idList.length; i += 2000) {
    for (const g of await genes.find({ _id: { $in: idList.slice(i, i + 2000) } },
      { projection: { alt_id: 1 } }).toArray()) {
      mongoDocs[g._id] = Array.isArray(g.alt_id) ? g.alt_id : (g.alt_id ? [g.alt_id] : []);
    }
    process.stdout.write('  mongo ' + Math.min(i + 2000, idList.length) + '/' + idList.length + '\r');
  }
  const present = Object.keys(mongoDocs);
  console.log('candidates in mongo : ' + present.length);
  const solrDocs = await solrGet(present);
  console.log('\nfound in core       : ' + Object.keys(solrDocs).length);

  const updates = [];
  let identical = 0;
  const diverged = [];
  for (const id of present) {
    const m = lc(mongoDocs[id]);
    const s = lc(solrDocs[id] || []);
    if (m.join('|') === s.join('|')) { identical++; continue; }
    // does the difference involve ONLY MSU ids? anything else means solr carries alt_ids that
    // did not come from mongo, and `set` would destroy them.
    const onlyMsuDiff = m.filter(x => s.indexOf(x) < 0).concat(s.filter(x => m.indexOf(x) < 0))
      .every(x => IS_MSU.test(x));
    if (!onlyMsuDiff) diverged.push({ id, mongo: m, solr: s });
    // `set: null` is how solr removes a field; an empty array is not reliably a clear.
    updates.push({ id: id, alt_id: { set: mongoDocs[id].length ? mongoDocs[id] : null } });
  }
  console.log('already identical   : ' + identical);
  console.log('needing update      : ' + updates.length);

  if (diverged.length) {
    console.error('\nABORT: ' + diverged.length + ' gene(s) differ in NON-MSU alt_ids, so something other than'
      + ' mongo writes solr`s alt_id and `set` would discard it. Nothing was written.');
    for (const d of diverged.slice(0, 5)) {
      console.error('  ' + d.id + '\n    mongo: ' + d.mongo.join(',') + '\n    solr : ' + d.solr.join(','));
    }
    await client.close();
    process.exit(2);
  }
  console.log('non-MSU alt_ids diverging: 0  (so `set` from mongo is lossless)');

  if (!APPLY) {
    console.log('\ndry run -- nothing posted. re-run with --apply');
  } else if (updates.length) {
    for (let i = 0; i < updates.length; i += 500) {
      await req(CORE + '/update', JSON.stringify(updates.slice(i, i + 500)));
      process.stdout.write('  posted ' + Math.min(i + 500, updates.length) + '/' + updates.length + '\r');
    }
    await req(CORE + '/update?commit=true', '{}');
    console.log('\ncommitted.');
  } else {
    console.log('\nnothing to post.');
  }
  await client.close();
})().catch(e => { console.error('msu_solr_patch: ' + (e.stack || e.message)); process.exit(1); });
