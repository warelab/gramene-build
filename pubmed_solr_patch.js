#!/usr/bin/env node
// pubmed_solr_patch.js -- reconcile the live genes core's PUBMED__xrefs with mongo, by atomic update.
//
// Why this exists. mongo2solr.join.js special-cased PUBMED into a `pubs` array and did
// `pubs.push(xref.ids[0])` -- only the FIRST pmid of each record. 996 medicago references cite 2-3
// papers each, so 1,016 pmid occurrences never reached the index. The code is fixed (gramene-solr
// 885afc3) and takes effect at the next full rebuild; this script carries the same repair to the
// live index now, without one.
//
// Writes exactly ONE field: PUBMED__xrefs. Not `_terms`, because PUBMED ids never enter it --
// mongo2solr folds xref ids into `uniq` only in the `else if (!annotations.hasOwnProperty(db))`
// branch, which the PUBMED special case never reaches. So there is no terms delta, no terms.tsv
// append and no stage 65 here. `*__xrefs -> text` IS a copyField, and Solr regenerates copyField
// destinations from the stored source on an atomic update, so free-text search is repaired too.
//
// add-distinct, not set. PUBMED__xrefs is wholly derived from mongo (nothing appends to it after the
// dump, unlike capabilities), so a recomputed list would be authoritative and `set` would be
// defensible -- but this repair only ever ADDS dropped ids, and add-distinct cannot lose a value to a
// mongo read that came back short. The run reports any id present in solr but absent from mongo
// rather than silently leaving it, so the choice is visible instead of assumed.
//
// usage: MONGO_DB=search70 node pubmed_solr_patch.js [--apply]
'use strict';

const fs   = require('fs');
const path = require('path');

// Resolved here rather than by requiring curated_dryrun.js, which chdirs into the search directory
// so its adders can read their bare filenames.
const SEARCH    = path.resolve(__dirname, '..', 'gramene-mongodb', 'search');
const MONGO_LIB = process.env.MONGO_LIB || path.resolve(SEARCH, '..', 'node_modules', 'mongodb');
const MONGO_URI = process.env.MONGO_URI || 'mongodb://localhost:27017';
const MONGO_DB  = process.env.MONGO_DB;
const CORE      = process.env.GENES_CORE;
const APPLY     = process.argv.includes('--apply');
const BATCH     = parseInt(process.env.POST_BATCH || '200', 10);
const SELECT    = parseInt(process.env.SELECT_BATCH || '500', 10);
if (!MONGO_DB || !CORE) {
  console.error('usage: MONGO_DB=search70 GENES_CORE=http://host/solr/genes70 node pubmed_solr_patch.js [--apply]');
  process.exit(2);
}

async function solrSelect(params) {
  const r = await fetch(CORE + '/select', {
    method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: new URLSearchParams(params).toString()
  });
  if (!r.ok) throw new Error('select ' + r.status + ' ' + (await r.text()).slice(0, 300));
  return r.json();
}
async function solrUpdate(body, commit) {
  const r = await fetch(CORE + '/update' + (commit ? '?commit=true' : ''), {
    method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)
  });
  if (!r.ok) throw new Error('update ' + r.status + ' ' + (await r.text()).slice(0, 400));
  return r.json();
}

(async () => {
  const { MongoClient } = require(MONGO_LIB);
  const client = new MongoClient(MONGO_URI, {useNewUrlParser: true, useUnifiedTopology: true});
  await client.connect();
  const genes = client.db(MONGO_DB).collection('genes');
  console.log('PUBMED__xrefs reconcile: mongo ' + MONGO_DB + ' -> ' + CORE +
              (APPLY ? '  [APPLY]' : '  [dry run]') + '\n');

  // ---- phase 1: the authoritative per-gene pmid set, straight from mongo ----
  // ids are ints from geneRIF and strings from rap-db; the solr field is `string`, so String() them
  // or the comparison below reports phantom differences on every geneRIF gene.
  const want = new Map(), taxonOf = new Map();
  let scanned = 0, idOccurrences = 0;
  const cursor = genes.find({'xrefs.db': 'PUBMED'}, {projection: {xrefs: 1, taxon_id: 1}});
  for await (const g of cursor) {
    scanned++;
    const set = new Set();
    (g.xrefs || []).forEach(x => {
      if (x.db !== 'PUBMED') return;
      (x.ids || []).forEach(i => { const s = String(i); if (s) set.add(s); });
    });
    if (!set.size) continue;
    want.set(g._id, set);
    taxonOf.set(g._id, g.taxon_id);
    idOccurrences += set.size;
  }
  await client.close();
  console.log('mongo genes with a PUBMED xref : ' + scanned);
  console.log('  of those, carrying >=1 id    : ' + want.size);
  console.log('  distinct ids per gene, summed : ' + idOccurrences + '\n');

  // ---- phase 2: what the live core actually holds ----
  const ids = Array.from(want.keys());
  const SEP = '\u0001';
  const have = new Map();
  const capless = [];
  for (let i = 0; i < ids.length; i += SELECT) {
    const b = ids.slice(i, i + SELECT);
    const j = await solrSelect({q: '{!terms f=id separator="' + SEP + '"}' + b.join(SEP),
                                fl: 'id,PUBMED__xrefs,capabilities',
                                rows: String(b.length), wt: 'json'});
    (j.response ? j.response.docs : []).forEach(d => {
      have.set(d.id, new Set((d['PUBMED__xrefs'] || []).map(String)));
      if (!(d.capabilities || []).includes('pubs')) capless.push(d.id);
    });
    if (i % (SELECT * 20) === 0) process.stderr.write('  fetched ' + Math.min(i + SELECT, ids.length) + '/' + ids.length + '\r');
  }
  process.stderr.write('\n');
  const missingDocs = ids.filter(id => !have.has(id));
  console.log('found in core                  : ' + have.size);
  if (missingDocs.length) {
    console.log('NOT in core                    : ' + missingDocs.length + '  e.g. ' + missingDocs.slice(0, 5).join(', '));
  }
  console.log('already carrying `pubs`        : ' + (have.size - capless.length) +
              (capless.length ? '   (' + capless.length + ' without it)' : ''));

  // ---- phase 3: the diff ----
  const updates = [];
  let addGenes = 0, addIds = 0, extraGenes = 0, extraIds = 0;
  const byTaxon = {}, extraSample = [];
  have.forEach((solrSet, id) => {
    const mongoSet = want.get(id);
    const add = [];
    mongoSet.forEach(v => { if (!solrSet.has(v)) add.push(v); });
    const extra = [];
    solrSet.forEach(v => { if (!mongoSet.has(v)) extra.push(v); });
    if (extra.length) {
      extraGenes++; extraIds += extra.length;
      if (extraSample.length < 5) extraSample.push(id + ': ' + extra.join(','));
    }
    if (!add.length) return;
    addGenes++; addIds += add.length;
    const t = taxonOf.get(id);
    byTaxon[t] = (byTaxon[t] || 0) + add.length;
    const u = {id: id, 'PUBMED__xrefs': {'add-distinct': add}};
    // A gene whose only pmid was dropped would have no `pubs` token either. add-distinct, never set:
    // expression_attributes / grassius_homolog / MAKER / VEP are appended after the dump and a set
    // would delete them.
    if (!solrSet.size) u.capabilities = {'add-distinct': ['pubs']};
    updates.push(u);
  });

  console.log('\n=== diff ===');
  console.log('genes needing ids added        : ' + addGenes);
  console.log('ids to add                     : ' + addIds);
  Object.keys(byTaxon).sort((a, b) => byTaxon[b] - byTaxon[a]).forEach(t =>
    console.log('    taxon ' + t + ': ' + byTaxon[t]));
  console.log('genes with ids solr has and mongo does not : ' + extraGenes + ' (' + extraIds + ' ids)');
  extraSample.forEach(s => console.log('    ' + s));
  if (updates.length) console.log('\nsample update: ' + JSON.stringify(updates[0]));

  fs.writeFileSync(process.env.PUBMED_SOLR_DELTA || '/tmp/pubmed_solr_delta.json',
                   JSON.stringify(updates), 'utf8');
  console.log('wrote ' + updates.length + ' updates to ' +
              (process.env.PUBMED_SOLR_DELTA || '/tmp/pubmed_solr_delta.json'));

  if (!APPLY) { console.log('\n(dry run -- re-run with --apply to write solr)'); return; }
  if (!updates.length) { console.log('\nnothing to do.'); return; }

  for (let i = 0; i < updates.length; i += BATCH) {
    const b = updates.slice(i, i + BATCH);
    await solrUpdate(b, false);
    process.stderr.write('  posted ' + Math.min(i + BATCH, updates.length) + '/' + updates.length + '\r');
  }
  process.stderr.write('\n');
  await solrUpdate([], true);
  console.log('committed.');
})().catch(e => { console.error('FAILED: ' + (e && e.stack || e)); process.exit(1); });
