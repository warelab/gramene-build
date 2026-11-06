#!/usr/bin/env node
// curated_ontology_patch_solr.js -- push the curated ontology expansion into the live genes core.
//
// Input is a SUBSET mongo2solr.join.js run (SOLR_ID_FILTER) over the genes curated_ontology_patch.js
// touched. Per that script's own warning, a subset run's compara_idx / compara_neighbors_* are
// WRONG -- `p` is a running position over the whole sorted collection -- so only the fields asked
// for are taken, never whole documents.
//
// Writes four things and nothing else:
//   {GO,PO,TO}__ancestors  `set`. Wholly derived from mongo.annotations, so the recomputed value is
//                          the complete list. Solr stores ancestors and the most-specific entry ids
//                          in the same field, which is why a term subsumed by a descendant on the
//                          same gene is still searchable.
//   annotations            `set`. The free-text side (term ids, names, defs), recomputed in full.
//                          It is the source of a copyField into `text`, which Solr regenerates.
//   capabilities           `add-distinct`, NEVER `set`. expression_attributes, grassius_homolog,
//                          MAKER and VEP are appended after the dump by add_attributes.pl and
//                          62_attr_atomic.sh, so a `set` would delete them from 1.5M genes. Only
//                          GO/PO/TO may move here; anything else differing is reported, not written.
//
// NOT written: _terms, and so no terms.tsv append and no stage 65. Ontology text goes to
// `solr.annotations` (-> `text`), never into `uniq`/`_terms`, so autocomplete is unaffected.
//
// usage: node curated_ontology_patch_solr.js <genesCoreUrl> <subset.json> [--apply]
'use strict';

const fs = require('fs');
const CORE  = process.argv[2];
const FILE  = process.argv[3];
const APPLY = process.argv.includes('--apply');
if (!CORE || !FILE) {
  console.error('usage: curated_ontology_patch_solr.js <genesCoreUrl> <subset.json> [--apply]');
  process.exit(2);
}
const BATCH = parseInt(process.env.POST_BATCH || '200', 10);
const ONT_CAPS = ['GO', 'PO', 'TO'];
const ANC = ONT_CAPS.map(o => o + '__ancestors');

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
const sameSet = (a, b) => JSON.stringify((a || []).slice().sort()) === JSON.stringify((b || []).slice().sort());

(async () => {
  const docs = JSON.parse(fs.readFileSync(FILE, 'utf8'));
  const byId = {}; docs.forEach(d => byId[d.id] = d);
  const ids = Object.keys(byId);
  console.log('recomputed docs: ' + ids.length);

  const SEP = '\u0001';
  const before = {};
  for (let i = 0; i < ids.length; i += 400) {
    const b = ids.slice(i, i + 400);
    const j = await solrSelect({q: '{!terms f=id separator="' + SEP + '"}' + b.join(SEP),
                                fl: ['id', 'capabilities', 'annotations'].concat(ANC).join(','),
                                rows: String(b.length), wt: 'json'});
    (j.response ? j.response.docs : []).forEach(d => before[d.id] = d);
  }
  console.log('found in core   : ' + Object.keys(before).length);
  if (Object.keys(before).length !== ids.length) {
    console.error('ABORT: ' + (ids.length - Object.keys(before).length) + ' not in the core');
    process.exit(2);
  }

  const updates = [];
  const stats = {anc: {GO: 0, PO: 0, TO: 0}, ann: 0, capAdd: {GO: 0, PO: 0, TO: 0}, cleared: [], otherCap: []};
  ids.forEach(id => {
    const n = byId[id], o = before[id];
    const u = {id: id};
    let touch = false;

    ANC.forEach((f, k) => {
      const nv = n[f], ov = o[f];
      if (nv === undefined && ov !== undefined) {
        // Only ever additive here, so this should not happen. Report instead of nulling a field on
        // a guess.
        stats.cleared.push(id + ' ' + f);
        return;
      }
      if (nv === undefined) return;
      if (!sameSet(nv, ov)) { u[f] = {set: nv}; touch = true; stats.anc[ONT_CAPS[k]]++; }
    });

    if (!sameSet(n.annotations, o.annotations)) { u.annotations = {set: n.annotations || []}; touch = true; stats.ann++; }

    const ncap = new Set(n.capabilities || []), ocap = new Set(o.capabilities || []);
    const add = ONT_CAPS.filter(c => ncap.has(c) && !ocap.has(c));
    const del = ONT_CAPS.filter(c => !ncap.has(c) && ocap.has(c));
    if (del.length) stats.otherCap.push(id + ' would LOSE ' + del.join(',') + ' -- not written');
    if (add.length) { u.capabilities = {'add-distinct': add}; touch = true; add.forEach(c => stats.capAdd[c]++); }

    if (touch) updates.push(u);
  });

  console.log('\n=== what would be written ===');
  console.log('  docs to update        : ' + updates.length);
  console.log('  __ancestors changed   : ' + JSON.stringify(stats.anc));
  console.log('  annotations changed   : ' + stats.ann);
  console.log('  capability tokens +   : ' + JSON.stringify(stats.capAdd) + '  (add-distinct only)');
  if (stats.cleared.length) {
    console.log('  WARNING fields present in solr but absent from the recompute (NOT cleared):');
    stats.cleared.forEach(c => console.log('     ' + c));
  }
  if (stats.otherCap.length) {
    console.log('  WARNING capability losses, deliberately not written:');
    stats.otherCap.forEach(c => console.log('     ' + c));
  }
  if (updates.length) console.log('\nsample: ' + JSON.stringify(updates[0]).slice(0, 260));

  if (!APPLY) { console.log('\n(dry run -- re-run with --apply to write solr)'); return; }
  if (!updates.length) { console.log('\nnothing to do.'); return; }
  for (let i = 0; i < updates.length; i += BATCH) {
    await solrUpdate(updates.slice(i, i + BATCH), false);
  }
  await solrUpdate([], true);
  console.log('committed.');
})().catch(e => { console.error('FAILED: ' + (e && e.stack || e)); process.exit(1); });
