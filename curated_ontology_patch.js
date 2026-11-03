#!/usr/bin/env node
// curated_ontology_patch.js -- land curated GO/PO/TO terms, AND their ancestor expansion, on the
// live genes collection without a full decorate.
//
// WHY THIS IS NEEDED. The incremental curated refresh (curated_patch.js) replays decorate's
// isGramene block only. `ancestor_adder` runs nine stages later in decorate, so a curated ontology
// term written by the incremental path lands in `gene.xrefs` and is never expanded into
// `gene.annotations`. The result is a term the API reports and the facets cannot see: measured on
// 2026-11-03, 83 of the artifact's 92 curated terms were in the live xrefs but only 71 were in
// annotations. That is the deferral `make refresh-curated-incremental` documents, and until now the
// only cure was the 15h35m 50 -> 60 -> 65 rebuild. 70 genes do not justify 15 hours.
//
// HOW IT STAYS HONEST. The expansion is not reimplemented -- the live docs are piped through
// `search/ancestor_adder.js` itself, the same module decorate uses, so the two cannot drift. Before
// anything is written, every gene is passed through UNMODIFIED and the resulting annotations are
// compared with what is live. Differences are expected exactly where a curated term sits in the
// xref unexpanded; a difference anywhere else (domains, taxonomy, familyRoot, QTL_TO) means the
// replay is not faithful and the run aborts rather than writing.
//
// Only `annotations` and the GO/PO/TO xrefs are written. ancestor_adder PUSHES a temporary
// `taxonomy` xref and a `familyRoot` xref on every pass -- harmless inside decorate, where it sees
// each gene once from a dump that has neither, but a second pass over a live doc would duplicate
// them, and `cleanup` does not dedupe. So the xrefs written are the ones this script merged, never
// the array ancestor_adder handed back.
//
// usage: MONGO_DB=search70 node curated_ontology_patch.js [--apply]
'use strict';

const fs   = require('fs');
const path = require('path');

const BUILD  = __dirname;
const SEARCH = path.resolve(BUILD, '..', 'gramene-mongodb', 'search');
const MONGO_LIB = process.env.MONGO_LIB || path.resolve(SEARCH, '..', 'node_modules', 'mongodb');
const MONGO_URI = process.env.MONGO_URI || 'mongodb://localhost:27017';
const MONGO_DB  = process.env.MONGO_DB;
const APPLY     = process.argv.includes('--apply');
const ART    = path.resolve(SEARCH, 'cshl_curated_genes.json');
const ID_OUT = process.env.ONT_ID_LIST || '/tmp/curated_ontology_ids.txt';
if (!MONGO_DB) { console.error('usage: MONGO_DB=search70 node curated_ontology_patch.js [--apply]'); process.exit(2); }

const ONT = {go: 'GO', po: 'PO', to: 'TO'};
const ONT_DBS = ['GO', 'PO', 'TO'];
// The other keys ancestor_adder owns. A replay must reproduce these byte for byte; if it does not,
// the replay is wrong and must not be trusted with the ones it is meant to change.
const UNTOUCHED = ['domains', 'taxonomy', 'familyRoot', 'QTL_TO'];

function termId(v) { return Array.isArray(v) ? String(v[0]) : String(v); }

// Canonical form of one annotations.<key> subdocument, for comparison only.
function canon(a) {
  if (!a) return null;
  const anc = (a.ancestors || []).slice().sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
  const ent = (a.entries || []).map(e => (e && (e.id !== undefined ? String(e.id) : String(e._id))))
                               .sort();
  return JSON.stringify({anc: anc, ent: ent});
}

// mergeOntologyXref's rule, restated here because curated_source.js applies it to a LUT entry and
// this applies it to a live doc: a term both sides claim keeps the EXISTING pair, whose evidence
// code came from Ensembl and is real rather than inferred. Returns the number of terms added.
function mergeTerms(gene, db, terms) {
  let existing = null;
  for (const x of gene.xrefs || []) if (x.db === db) { if (existing) return -1; existing = x; }
  if (!existing) {
    gene.xrefs.push({db: db, ids: terms.map(t => [t.id, t.code])});
    return terms.length;
  }
  const have = new Set((existing.ids || []).map(termId));
  let added = 0;
  terms.forEach(t => { if (!have.has(t.id)) { existing.ids.push([t.id, t.code]); have.add(t.id); added++; } });
  return added;
}

(async () => {
  // ancestor_adder reads gramene-mongodb-config and its siblings by bare name, so it has to be
  // required from the search directory. Everything else here uses absolute paths.
  const artifact = JSON.parse(fs.readFileSync(ART, 'utf8'));
  process.chdir(SEARCH);
  const ancestorAdderFactory = require(path.resolve(SEARCH, 'ancestor_adder.js'));
  const collections = require(path.resolve(SEARCH, '..', 'node_modules', 'gramene-mongodb-config'));

  const want = new Map();
  artifact.forEach(e => {
    const terms = [];
    Object.keys(ONT).forEach(o => (e[o] || []).forEach(id => {
      const ev = e.evidence && e.evidence[id];
      const code = Array.isArray(ev) ? ev[0] : ev;
      terms.push({id: id, db: ONT[o], code: code || 'IEA'});
    }));
    if (terms.length) want.set(e.locus, terms);
  });
  const ids = Array.from(want.keys()).sort();
  console.error('curated ontology patch against ' + MONGO_DB + (APPLY ? '  [APPLY]' : '  [dry run]'));
  console.error('genes carrying a curated ontology term: ' + ids.length +
                '  (' + Array.from(want.values()).reduce((n, t) => n + t.length, 0) + ' terms)\n');

  const { MongoClient } = require(MONGO_LIB);
  const client = new MongoClient(MONGO_URI, {useNewUrlParser: true, useUnifiedTopology: true});
  await client.connect();
  const genes = client.db(MONGO_DB).collection('genes');
  const live = await genes.find({_id: {$in: ids}}).toArray();
  const byId = {}; live.forEach(d => byId[d._id] = d);
  console.error('found live: ' + live.length + ' of ' + ids.length);
  if (live.length !== ids.length) {
    console.error('ABORT: ' + ids.filter(i => !byId[i]).join(', ') + ' not in the collection');
    process.exit(2);
  }
  // The keyBy landmine: a gene with two xrefs for one db has its first one silently ignored by
  // ancestor_adder. Assert none exists before touching anything.
  let dupes = 0;
  live.forEach(d => {
    const seen = {};
    (d.xrefs || []).forEach(x => {
      if (ONT_DBS.indexOf(x.db) < 0) return;
      if (seen[x.db]) { console.error('  DUP ontology xref: ' + d._id + ' has two ' + x.db); dupes++; }
      seen[x.db] = 1;
    });
  });
  if (dupes) { console.error('ABORT: ' + dupes + ' duplicated ontology xrefs -- fix before patching'); process.exit(2); }

  // Run every gene through the real ancestor_adder. One instance, two passes: unmodified first
  // (the faithfulness gate), then merged.
  function expand(docs) {
    return new Promise((resolve, reject) => {
      const adder = ancestorAdderFactory();
      const out = [];
      adder.on('data', g => out.push(g));
      adder.on('error', reject);
      adder.on('end', () => resolve(out));
      docs.forEach(d => adder.write(d));
      adder.end();
    });
  }
  const clone = d => JSON.parse(JSON.stringify(d));

  console.error('\n=== gate: replay ancestor_adder over the UNMODIFIED live docs ===');
  const baseline = await expand(live.map(clone));
  const baseById = {}; baseline.forEach(d => baseById[d._id] = d);
  let gateFail = 0, wouldExpand = 0, expandedGenes = new Set();
  live.forEach(d => {
    const rep = baseById[d._id];
    UNTOUCHED.forEach(k => {
      if (canon((d.annotations || {})[k]) !== canon((rep.annotations || {})[k])) {
        console.error('  GATE FAIL ' + d._id + ': replay changed annotations.' + k);
        gateFail++;
      }
    });
    ONT_DBS.forEach(k => {
      const a = canon((d.annotations || {})[k]), b = canon((rep.annotations || {})[k]);
      if (a !== b) {
        const na = JSON.parse(a || '{"ent":[]}').ent, nb = JSON.parse(b || '{"ent":[]}').ent;
        const gained = nb.filter(x => na.indexOf(x) < 0);
        const lost   = na.filter(x => nb.indexOf(x) < 0);
        if (lost.length) { console.error('  GATE FAIL ' + d._id + ' ' + k + ': replay LOST ' + lost.join(',')); gateFail++; }
        if (gained.length) { wouldExpand += gained.length; expandedGenes.add(d._id); }
      }
    });
  });
  console.error('  annotations.{' + UNTOUCHED.join(',') + '} reproduced exactly: ' +
                (gateFail ? 'NO' : 'yes, on all ' + live.length + ' genes'));
  console.error('  terms already in an xref that live annotations never expanded: ' +
                wouldExpand + ' on ' + expandedGenes.size + ' genes');
  if (gateFail) { console.error('\nABORT: the replay is not faithful; nothing written.'); process.exit(3); }

  console.error('\n=== merging the curated terms into the ontology xrefs ===');
  const merged = [], addedPerDb = {GO: 0, PO: 0, TO: 0}, newXrefs = [];
  live.forEach(d => {
    const g = clone(d);
    const byDb = {};
    want.get(d._id).forEach(t => (byDb[t.db] = byDb[t.db] || []).push(t));
    Object.keys(byDb).forEach(db => {
      const had = (g.xrefs || []).some(x => x.db === db);
      const n = mergeTerms(g, db, byDb[db]);
      if (n < 0) { console.error('ABORT: ' + d._id + ' has two ' + db + ' xrefs'); process.exit(2); }
      addedPerDb[db] += n;
      if (!had && n > 0) newXrefs.push(d._id + ':' + db);
    });
    merged.push(g);
  });
  console.error('  terms added to an xref: ' + JSON.stringify(addedPerDb));
  console.error('  genes gaining a NEW ontology xref db: ' + newXrefs.length +
                (newXrefs.length ? '  ' + newXrefs.join(', ') : ''));

  const expanded = await expand(merged.map(clone));
  const expById = {}; expanded.forEach(d => expById[d._id] = d);

  const ops = [];
  let annChanged = 0, newTerms = 0, capGain = {GO: 0, PO: 0, TO: 0};
  merged.forEach(m => {
    const e = expById[m._id], d = byId[m._id];
    let changed = false;
    ONT_DBS.forEach(k => {
      const before = canon((d.annotations || {})[k]), after = canon((e.annotations || {})[k]);
      if (before !== after) {
        changed = true;
        const nb = JSON.parse(before || '{"ent":[]}').ent, na = JSON.parse(after).ent;
        newTerms += na.filter(x => nb.indexOf(x) < 0).length;
        if (!before && after) capGain[k]++;
      }
    });
    if (!changed) return;
    annChanged++;
    // annotations from the replay; xrefs from OUR merge, never the array ancestor_adder handed
    // back -- it has a duplicate taxonomy and familyRoot xref pushed onto it.
    ops.push({updateOne: {filter: {_id: m._id},
                          update: {$set: {xrefs: m.xrefs, annotations: e.annotations}}}});
  });
  console.error('\n=== what would be written ===');
  console.error('  genes with changed annotations : ' + annChanged);
  console.error('  ontology terms newly expanded  : ' + newTerms);
  console.error('  genes gaining an ontology key  : ' + JSON.stringify(capGain) +
                '   (these are the only capability gains)');
  fs.writeFileSync(ID_OUT, ids.join('\n') + '\n');
  console.error('  wrote the gene id list for the solr subset run to ' + ID_OUT);

  if (!APPLY) {
    console.error('\n(dry run -- re-run with --apply to write mongo)');
    await client.close(); collections.closeMongoDatabase(); process.exit(0);
  }
  if (!ops.length) {
    console.error('\nnothing to write.');
    await client.close(); collections.closeMongoDatabase(); process.exit(0);
  }
  const res = await genes.bulkWrite(ops, {ordered: false});
  console.error('\nmongo: matched ' + res.matchedCount + ' modified ' + res.modifiedCount);
  await client.close();
  collections.closeMongoDatabase();
})().catch(e => { console.error('FAILED: ' + (e && e.stack || e)); process.exit(1); });
