#!/usr/bin/env node
// reactome_literature_patch.js — add Plant Reactome's curated publications to the LIVE genes
// collection, without a full decorate.
//
// Same relationship to search/reactome_literature_adder.js that pubmed_titles.js has to
// pubmed_title_adder.js: the transform is IMPORTED, never restated. A patch that writes
// differently from the rebuild is a patch the next decorate silently undoes.
//
// Where the data comes from, how the rule was recovered and what it was measured against is all
// in build/fetch_reactome_literature.js. Run that first if reactome_literature.json is missing.
//
// Solr: mongo2solr.join.js builds PUBMED__xrefs from xref.ids and drops `text` and `source`
// entirely, so the index only ever needs the pmids -- which is exactly what pubmed_solr_patch.js
// reconciles. So after --apply here, run `make pubmed-solr` rather than reindexing. There is no
// terms delta either: mongo2solr folds xref ids into `_terms` only in the branch the PUBMED
// special case never reaches.
//
// usage: MONGO_DB=oryza10 node reactome_literature_patch.js [--apply]
'use strict';

const path = require('path');
const dry = require('./curated_dryrun.js');
const { SEARCH, MONGO_LIB, MONGO_URI, MONGO_DB } = dry;
const adder = require(path.resolve(SEARCH, 'reactome_literature_adder.js'));

const APPLY = process.argv.includes('--apply');

(async () => {
  const lut = await adder.load();
  if (!lut) {
    console.error('no Plant Reactome literature artifact -- run build/fetch_reactome_literature.js first');
    process.exit(1);
  }

  const { MongoClient } = require(MONGO_LIB);
  const client = new MongoClient(MONGO_URI, {useNewUrlParser: true, useUnifiedTopology: true});
  await client.connect();
  const genes = client.db(MONGO_DB).collection('genes');

  console.log(`${APPLY ? 'PATCHING' : 'dry run against'} ${MONGO_DB}.genes` +
              `${APPLY ? '' : ' -- nothing is written'}\n`);

  // Only the genes the rule actually names are read back, which is why this is minutes and not
  // hours: 99,227 candidate ids, of which a site typically holds a few thousand.
  const candidates = Object.keys(lut.geneEvents);
  const CHUNK = 2000;
  let seen = 0, changed = 0, added = 0, already = 0;
  const bySys = {};
  let ops = [];

  for (let i = 0; i < candidates.length; i += CHUNK) {
    const batch = candidates.slice(i, i + CHUNK);
    const docs = await genes.find({_id: {$in: batch}}, {projection: {xrefs: 1, system_name: 1}}).toArray();
    for (const g of docs) {
      seen++;
      const before = (g.xrefs || []).filter(x => x && x.db === 'PUBMED' && x.source === 'PlantReactome').length;
      const n = adder.addGene(g, lut);
      if (!n) { if (before) { already++; } continue; }
      changed++; added += n;
      bySys[g.system_name] = (bySys[g.system_name] || 0) + 1;
      if (APPLY) { ops.push({updateOne: {filter: {_id: g._id}, update: {$set: {xrefs: g.xrefs}}}}); }
    }
    if (APPLY && ops.length >= 1000) { await genes.bulkWrite(ops, {ordered: false}); ops = []; }
  }
  if (APPLY && ops.length) { await genes.bulkWrite(ops, {ordered: false}); }

  console.log(`candidate gene ids from the rule: ${candidates.length}`);
  console.log(`present in ${MONGO_DB}.genes:      ${seen}`);
  console.log(`already complete (no change):     ${already}`);
  console.log(`genes ${APPLY ? 'patched' : 'that would change'}: ${changed}  (+${added} references)`);
  Object.keys(bySys).sort().forEach(s => console.log(`    ${s}\t${bySys[s]}`));
  if (APPLY) { console.log('\nnow reconcile the index:  make pubmed-solr'); }

  await client.close();
})().catch(e => { console.error(e); process.exit(1); });
