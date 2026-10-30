#!/usr/bin/env node
// curated_patch.js — apply a curated-source change to the LIVE index without a 15h rebuild.
//
// Why this exists: the in-house curation feed sat frozen for two years because refreshing it cost
// a full 50 -> 60 -> 65 chain (~15h), and the sheet gains rows every month. A sheet edit that only
// moves names must not cost a release rebuild.
//
// What makes it trustworthy rather than a shortcut: the "after" state is not computed by this
// file. It comes from curated_dryrun.js's CHAIN -- decorate.js's entire isGramene block, in pipe
// order -- replayed over the stage-40 dumps. So "what the patch writes" and "what a rebuild would
// write" are the same expression evaluated once, not two implementations that can disagree.
//
// Scope guard: it applies ONLY `name` and `synonyms`. Any other field the chain would change is
// reported and ABORTS the run, because the cheap path is only valid while the change is the one
// you think it is. A description or xref delta means re-decorate, not patch.
//
// usage: MONGO_DB=search70 node curated_patch.js [--apply] [system_name ...]
//   default species: sorghum_bicolor zea_mays oryza_sativa arabidopsis_thaliana
//   without --apply nothing is written anywhere.
'use strict';

const dry = require('./curated_dryrun.js');
const { CHAIN, readDump, pipeThrough, MONGO_LIB, MONGO_URI, MONGO_DB } = dry;

const APPLY = process.argv.includes('--apply');
const SPECIES = process.argv.slice(2).filter(a => !a.startsWith('-'));
const TARGETS = SPECIES.length ? SPECIES
  : ['sorghum_bicolor', 'zea_mays', 'oryza_sativa', 'arabidopsis_thaliana'];

const PATCHABLE = ['name', 'synonyms'];
const WATCHED   = ['name', 'synonyms', 'description', 'summary'];

function arrEq(a, b) {
  const x = (a || []).slice().sort(), y = (b || []).slice().sort();
  return x.length === y.length && x.every((v, i) => v === y[i]);
}
// All the ways this pipeline spells "no value": undefined, null, '', the 4-char 'NULL' that
// ThaleMine ships and the 2-char '""' that Ensembl does. Collapsing them is required, not lenient.
// fix_maize_v5 writes '' for the maize genes it has no entry for, where the live docs hold null, so
// a strict compare reports 5,697 maize descriptions as changed when nothing a user sees differs --
// and 5,697 is also precisely the gap between a truthy and a usable count, the same mistake that
// made an arabidopsis description GAIN of 3,050 read as a loss of 690.
function blank(v) {
  return v === undefined || v === null || v === '' || v === 'NULL' || v === '""'
         || (typeof v === 'string' && v.trim() === '');
}
function sameField(f, a, b) {
  if (f === 'synonyms') return arrEq(a, b);
  if (blank(a) && blank(b)) return true;
  return (a === undefined ? null : a) === (b === undefined ? null : b);
}
// Per-db xref signatures, order-insensitive, keyed by db+source.
// NOT a whole-array signature: the live docs carry xref dbs the isGramene chain never emits --
// `domains`, `taxonomy` and `familyRoot` are attached by LATER decorate stages -- so a flat
// comparison reports every gene in the release as changed. That is the same apples-to-oranges
// trap curated_dryrun.js's CHAIN comment describes, one level down.
function xrefMap(doc) {
  const m = {};
  (doc.xrefs || []).forEach(x => {
    const k = x.db + (x.source ? '/' + x.source : '');
    const ids = (x.ids || []).map(i => Array.isArray(i) ? i.join(':') : String(i)).sort().join(',');
    m[k] = m[k] ? m[k] + ';' + ids : ids;
  });
  return m;
}

(async () => {
  const { MongoClient } = require(MONGO_LIB);
  const client = new MongoClient(MONGO_URI, {useNewUrlParser: true, useUnifiedTopology: true});
  await client.connect();
  const db = client.db(MONGO_DB);
  const genes = db.collection('genes');

  console.log('curated patch against ' + MONGO_DB + (APPLY ? '  -- APPLYING' : '  -- dry run, nothing written') + '\n');

  const changes = [];       // {_id, taxon_id, set:{...}, was:{...}}
  let blocked = 0;

  for (const sp of TARGETS) {
    let docs;
    try { docs = await readDump(sp); }
    catch (e) { console.log('## ' + sp + ': SKIPPED (' + e.message + ')'); continue; }

    const after = await pipeThrough(docs, CHAIN);
    const taxa = (await db.collection('maps')
      .find({type: 'genome', system_name: sp}, {projection: {taxon_id: 1}}).toArray())
      .map(m => m.taxon_id);
    if (!taxa.length) { console.log('## ' + sp + ': no genome in maps'); continue; }

    const live = {};
    (await genes.find({taxon_id: {$in: taxa}},
      {projection: {_id: 1, taxon_id: 1, name: 1, synonyms: 1, description: 1, summary: 1, xrefs: 1}})
      .toArray()).forEach(d => { live[d._id] = d; });

    const tally = {};
    WATCHED.forEach(f => tally[f] = 0);
    let missing = 0;

    // Keys the chain never emits for this species are downstream additions, not curated changes.
    // Derived rather than hardcoded so a new downstream adder does not silently break the guard.
    const chainKeys = new Set();
    after.forEach(a => Object.keys(xrefMap(a)).forEach(k => chainKeys.add(k)));
    const xrefDelta = {};   // key -> number of genes differing
    const downstream = new Set();

    after.forEach(a => {
      const l = live[a._id];
      if (!l) { missing++; return; }
      const set = {}, was = {};
      WATCHED.forEach(f => {
        if (!sameField(f, l[f], a[f])) {
          tally[f]++;
          if (PATCHABLE.indexOf(f) >= 0) { set[f] = a[f]; was[f] = l[f]; }
        }
      });
      const ma = xrefMap(a), ml = xrefMap(l);
      new Set(Object.keys(ma).concat(Object.keys(ml))).forEach(k => {
        if (!chainKeys.has(k)) { downstream.add(k); return; }
        if (ma[k] !== ml[k]) xrefDelta[k] = (xrefDelta[k] || 0) + 1;
      });
      if (Object.keys(set).length) changes.push({_id: a._id, taxon_id: l.taxon_id, set, was});
    });

    const xrefGenes = Object.values(xrefDelta).reduce((a, b) => a + b, 0);
    blocked += tally.description + tally.summary + xrefGenes;
    console.log('## ' + sp + '  (' + after.length + ' in dump, ' + Object.keys(live).length + ' live'
                + (missing ? ', ' + missing + ' dump docs absent from the collection' : '') + ')');
    console.log('   name ' + String(tally.name).padStart(5)
              + '   synonyms ' + String(tally.synonyms).padStart(5)
              + '   | description ' + String(tally.description).padStart(5)
              + '   summary ' + String(tally.summary).padStart(5)
              + '   xref-genes ' + String(xrefGenes).padStart(6));
    if (xrefGenes) console.log('     xref deltas by db: ' + JSON.stringify(xrefDelta));
    if (downstream.size) console.log('     ignored (added after the isGramene block): '
                                     + Array.from(downstream).sort().join(', '));
  }

  console.log('\ngenes to patch: ' + changes.length);
  if (blocked) {
    console.log('\nABORT: ' + blocked + ' genes differ in description/summary/xrefs, which this');
    console.log('       patcher does not write. That is a re-decorate, not a patch:');
    console.log('         make refresh-curated');
    await client.close(); process.exit(2);
  }

  const renames = changes.filter(c => c.set.name !== undefined && c.was.name && c.was.name !== c._id);
  const newnames = changes.filter(c => c.set.name !== undefined && (!c.was.name || c.was.name === c._id));
  console.log('  names newly set (was the bare id): ' + newnames.length);
  console.log('  names replaced (old curated name): ' + renames.length);
  console.log('  synonym-only changes             : ' +
    changes.filter(c => c.set.name === undefined).length);
  console.log('\nsample:');
  changes.slice(0, 6).forEach(c => console.log('  ' + c._id + '  ' +
    JSON.stringify(c.was) + ' -> ' + JSON.stringify(c.set)));

  require('fs').writeFileSync(process.env.PATCH_OUT || '/tmp/curated_patch.json',
    JSON.stringify(changes), 'utf8');
  console.log('\nwrote ' + changes.length + ' changes to ' + (process.env.PATCH_OUT || '/tmp/curated_patch.json'));

  if (!APPLY) { console.log('\n(dry run -- re-run with --apply to write mongo)'); await client.close(); process.exit(0); }

  let n = 0;
  for (let i = 0; i < changes.length; i += 500) {
    const ops = changes.slice(i, i + 500).map(c => ({
      updateOne: {filter: {_id: c._id}, update: {$set: c.set}}
    }));
    const r = await genes.bulkWrite(ops, {ordered: false});
    n += r.modifiedCount;
  }
  console.log('mongo: ' + n + ' documents modified');
  await client.close();
  process.exit(0);
})().catch(e => { console.error('ERR ' + (e && e.stack || e)); process.exit(1); });
