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

// Xref keys (db + '/' + source) this patcher is willing to write. Curated literature only: the
// reference set for one source is fully recomputed by the chain, so replacing it wholesale is
// equivalent to a rebuild for those entries.
const REF_KEYS = /^(PUBMED|DOI)\/CSHL$/;

// Ontology xrefs are DEFERRED, not patched and not treated as a blocking difference.
//
// Why neither: ancestor_adder.js runs at decorate.js:242, after the homology and domain adders, and
// expands each GO/PO/TO term into the <ont>__ancestors fields the facets are built from. A subset
// replay cannot reproduce those (it has no homology or domain input), so writing the term would put
// it on the gene while leaving it out of every ancestor facet -- wrong in a way no gate here would
// catch. Writing nothing instead keeps mongo and the core consistent and leaves the term in the
// artifact, where the next full decorate picks it up. The deferred set is reported and written out
// so it is a tracked remainder rather than a silent omission.
const ONT_KEYS = /^(GO|PO|TO|CHEBI)(\/|$)/;

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
    let ids = (x.ids || []).map(i => Array.isArray(i) ? i.join(':') : String(i)).sort().join(',');
    // For the curated-literature keys only, fold `text` into the signature. That field is the
    // description the Curated publications tab renders, so a curator rewriting a description is a
    // real change -- and signing on ids alone made it invisible: 13 of the 36 loci in the first
    // real refresh changed only their description text and would have been skipped in silence.
    // Restricted to the keys this patcher owns, because a text difference on PUBMED/geneRIF or
    // PUBMED/rap-db is not ours to write and would turn into a spurious blocking delta.
    if (REF_KEYS.test(k)) {
      ids += '|' + (x.text === undefined || x.text === null ? '' : String(x.text));
    }
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

  const changes = [];       // {_id, taxon_id, set:{...}, was:{...}, refXrefs?, refKeys?}
  const deferredOnt = [];   // {_id, terms:[...]} -- ontology additions this path will not write
  // Live docs kept across species: the apply step rebuilds each changed gene's xrefs array from its
  // live value, so it needs the doc after the per-species loop has moved on.
  const liveById = {};
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
      .toArray()).forEach(d => { live[d._id] = d; liveById[d._id] = d; });

    const tally = {};
    WATCHED.forEach(f => tally[f] = 0);
    let missing = 0;

    // Keys the chain never emits for this species are downstream additions, not curated changes.
    // Derived rather than hardcoded so a new downstream adder does not silently break the guard.
    const chainKeys = new Set();
    after.forEach(a => Object.keys(xrefMap(a)).forEach(k => chainKeys.add(k)));
    const xrefDelta = {};   // key -> number of genes differing (BLOCKING)
    const refKeyDelta = {}; // curated literature keys (patchable)
    const ontDelta = {};    // ontology keys (deferred)
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
      let refsDiffer = false;
      const deferred = [];
      new Set(Object.keys(ma).concat(Object.keys(ml))).forEach(k => {
        if (!chainKeys.has(k) && !ml.hasOwnProperty(k)) { downstream.add(k); return; }
        if (ma[k] === ml[k]) return;
        if (REF_KEYS.test(k)) { refsDiffer = true; refKeyDelta[k] = (refKeyDelta[k] || 0) + 1; return; }
        if (ONT_KEYS.test(k)) {
          // Report exactly which terms would have been added, not just that something differs.
          const now = new Set((ml[k] || '').split(';').join(',').split(',').filter(Boolean));
          (ma[k] || '').split(';').join(',').split(',').filter(Boolean)
            .forEach(t => { if (!now.has(t)) deferred.push(k + ' ' + t); });
          ontDelta[k] = (ontDelta[k] || 0) + 1;
          return;
        }
        if (!chainKeys.has(k)) { downstream.add(k); return; }
        xrefDelta[k] = (xrefDelta[k] || 0) + 1;
      });
      if (deferred.length) deferredOnt.push({_id: a._id, terms: deferred});

      if (Object.keys(set).length || refsDiffer) {
        const c = {_id: a._id, taxon_id: l.taxon_id, set, was};
        if (refsDiffer) {
          // The complete replacement set for the keys we own, taken from the chain. The apply step
          // drops the gene's existing xrefs for exactly these keys and inserts these, so an entry
          // the sheet removed disappears instead of lingering -- which a push-only patch cannot do.
          c.refKeys = Object.keys(ma).concat(Object.keys(ml)).filter(k => REF_KEYS.test(k))
                        .filter((v, i, arr) => arr.indexOf(v) === i);
          c.refXrefs = (a.xrefs || []).filter(x => REF_KEYS.test(x.db + (x.source ? '/' + x.source : '')));
          c.wasRefCount = (l.xrefs || []).filter(x => REF_KEYS.test(x.db + (x.source ? '/' + x.source : ''))).length;
        }
        changes.push(c);
      }
    });

    const xrefGenes = Object.values(xrefDelta).reduce((a, b) => a + b, 0);
    const refGenes = Object.values(refKeyDelta).reduce((a, b) => a + b, 0);
    const ontGenes = Object.values(ontDelta).reduce((a, b) => a + b, 0);
    // Only the UNRECOGNISED xref classes block. Curated literature is written; ontology is deferred.
    blocked += tally.description + tally.summary + xrefGenes;
    console.log('## ' + sp + '  (' + after.length + ' in dump, ' + Object.keys(live).length + ' live'
                + (missing ? ', ' + missing + ' dump docs absent from the collection' : '') + ')');
    console.log('   name ' + String(tally.name).padStart(5)
              + '   synonyms ' + String(tally.synonyms).padStart(5)
              + '   | description ' + String(tally.description).padStart(5)
              + '   summary ' + String(tally.summary).padStart(5)
              + '   xref-genes ' + String(xrefGenes).padStart(6));
    if (refGenes) console.log('     literature deltas (will be written): ' + JSON.stringify(refKeyDelta));
    if (ontGenes) console.log('     ontology deltas (DEFERRED to the next decorate): ' + JSON.stringify(ontDelta));
    if (xrefGenes) console.log('     unrecognised xref deltas (BLOCKING): ' + JSON.stringify(xrefDelta));
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

  if (deferredOnt.length) {
    const terms = deferredOnt.reduce((n, d) => n + d.terms.length, 0);
    console.log('\nDEFERRED: ' + terms + ' ontology terms on ' + deferredOnt.length + ' genes are NOT');
    console.log('  written by this path (ancestor_adder expands them during decorate). They stay in');
    console.log('  the artifact and land at the next full decorate. Affected genes:');
    deferredOnt.slice(0, 20).forEach(d => console.log('    ' + d._id.padEnd(22) + d.terms.join(', ')));
    if (deferredOnt.length > 20) console.log('    ... and ' + (deferredOnt.length - 20) + ' more');
    require('fs').writeFileSync(process.env.DEFERRED_OUT || '/tmp/curated_deferred_ontology.json',
      JSON.stringify({generated: new Date().toISOString(), genes: deferredOnt}, null, 1) + '\n');
    console.log('  recorded in ' + (process.env.DEFERRED_OUT || '/tmp/curated_deferred_ontology.json'));
  }

  const refChanges = changes.filter(c => c.refXrefs);
  if (refChanges.length) {
    const refs = refChanges.reduce((n, c) => n + c.refXrefs.length, 0);
    const was = refChanges.reduce((n, c) => n + c.wasRefCount, 0);
    console.log('\n  genes with literature changes   : ' + refChanges.length +
                '  (' + was + ' curated references -> ' + refs + ')');
  }

  const renames = changes.filter(c => c.set.name !== undefined && c.was.name && c.was.name !== c._id);
  const newnames = changes.filter(c => c.set.name !== undefined && (!c.was.name || c.was.name === c._id));
  console.log('  names newly set (was the bare id): ' + newnames.length);
  console.log('  names replaced (old curated name): ' + renames.length);
  console.log('  synonym-only changes             : ' +
    changes.filter(c => c.set.name === undefined).length);
  console.log('\nsample:');
  changes.slice(0, 6).forEach(c => {
    const fields = Object.keys(c.set).length
      ? JSON.stringify(c.was) + ' -> ' + JSON.stringify(c.set) : '';
    const refs = c.refXrefs
      ? (fields ? '  ' : '') + 'refs ' + c.wasRefCount + ' -> ' + c.refXrefs.length +
        ' [' + c.refXrefs.map(x => x.ids[0]).join(',') + ']' : '';
    console.log('  ' + c._id.padEnd(22) + fields + refs);
  });

  require('fs').writeFileSync(process.env.PATCH_OUT || '/tmp/curated_patch.json',
    JSON.stringify(changes), 'utf8');
  console.log('\nwrote ' + changes.length + ' changes to ' + (process.env.PATCH_OUT || '/tmp/curated_patch.json'));

  if (!APPLY) { console.log('\n(dry run -- re-run with --apply to write mongo)'); await client.close(); process.exit(0); }

  let n = 0;
  for (let i = 0; i < changes.length; i += 500) {
    const ops = changes.slice(i, i + 500).map(c => {
      if (!c.refXrefs) {
        return {updateOne: {filter: {_id: c._id}, update: {$set: c.set}}};
      }
      // Literature: drop every xref for the keys we own, then insert the chain's set. Done as one
      // $set of the whole array rather than $pull + $push, because those are two round trips and a
      // failure between them would leave the gene with no curated references at all. The array is
      // rebuilt here from the live doc, so xrefs we do not own are carried over untouched.
      const liveDoc = liveById[c._id];
      const keep = (liveDoc.xrefs || [])
        .filter(x => !c.refKeys.includes(x.db + (x.source ? '/' + x.source : '')));
      const set = Object.assign({}, c.set, {xrefs: keep.concat(c.refXrefs)});
      return {updateOne: {filter: {_id: c._id}, update: {$set: set}}};
    });
    const r = await genes.bulkWrite(ops, {ordered: false});
    n += r.modifiedCount;
  }
  console.log('mongo: ' + n + ' documents modified');
  await client.close();
  process.exit(0);
})().catch(e => { console.error('ERR ' + (e && e.stack || e)); process.exit(1); });
