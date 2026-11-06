#!/usr/bin/env node
// curated_patch_solr.js — push a curated_patch.js change into the live genes core by atomic update,
// and report the term set the suggestions layer has to be told about.
//
// Writes exactly three fields: name, synonyms, _terms. Nothing else, for two reasons.
//   * compara_idx / compara_neighbors_* in the recomputed docs are WRONG, because mongo2solr's `p`
//     counter is a running position over the whole sorted collection and this input came from a
//     358-gene subset run.
//   * `capabilities` is not recoverable from mongo at all -- add_attributes.pl and 62_attr_atomic.sh
//     append expression_attributes / grassius_homolog / MAKER / VEP after the dump -- so a `set`
//     would silently delete them. A name change cannot alter capabilities, so it is not touched.
//
// _terms uses `set`, NOT add-distinct: 50 of these genes are RENAMES, and add-distinct would leave
// the superseded symbol searchable forever. `set` is safe here precisely because the value was
// recomputed by mongo2solr.join.js from the updated mongo doc, so it is the complete list.
//
// usage: node curated_patch_solr.js <genesCoreUrl> <patch_solr.json> [--apply]
'use strict';

const fs = require('fs');
const CORE = process.argv[2];
const FILE = process.argv[3];
const APPLY = process.argv.includes('--apply');
if (!CORE || !FILE) { console.error('usage: curated_patch_solr.js <genesCoreUrl> <recomputed.json> [--apply]'); process.exit(2); }
const BATCH = parseInt(process.env.POST_BATCH || '200', 10);

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
  const docs = JSON.parse(fs.readFileSync(FILE, 'utf8'));
  const byId = {}; docs.forEach(d => byId[d.id] = d);
  const ids = Object.keys(byId);
  console.log('recomputed docs: ' + ids.length);

  // Current state, so the affected-term set is exact rather than assumed.
  const SEP = '\u0001';
  const before = {};
  for (let i = 0; i < ids.length; i += 500) {
    const b = ids.slice(i, i + 500);
    const j = await solrSelect({q: '{!terms f=id separator="' + SEP + '"}' + b.join(SEP),
                                fl: 'id,name,synonyms,_terms,PUBMED__xrefs,DOI__xrefs,capabilities',
                                rows: String(b.length), wt: 'json'});
    (j.response ? j.response.docs : []).forEach(d => before[d.id] = d);
  }
  const found = Object.keys(before).length;
  console.log('found in core    : ' + found);
  if (found !== ids.length) {
    console.error('ABORT: ' + (ids.length - found) + ' of these genes are not in the core.');
    process.exit(2);
  }

  const added = new Set(), removed = new Set();
  const updates = [];
  // Capability tokens a curation refresh can legitimately move. `pubs` appears the moment a gene has
  // any PUBMED xref; `xrefs` the moment it has a non-PUBMED one, which a DOI-keyed reference is.
  const CURATION_CAPS = ['pubs', 'xrefs'];
  const capStats = {added: 0, removed: 0};
  ids.forEach(id => {
    const n = byId[id], o = before[id];
    const nt = n._terms || [], ot = o._terms || [];
    const nset = new Set(nt), oset = new Set(ot);
    nt.forEach(t => { if (!oset.has(t)) added.add(t); });
    ot.forEach(t => { if (!nset.has(t)) removed.add(t); });

    const u = {
      id: id,
      name:     {set: n.name === undefined ? null : n.name},
      synonyms: {set: n.synonyms === undefined ? null : n.synonyms},
      _terms:   {set: nt}
    };

    // Literature xref fields. `set` is correct here for the same reason it is for _terms: the value
    // was recomputed by mongo2solr.join.js from the updated mongo doc, so it is the complete list
    // for that field -- including references from geneRIF and rap-db, which this refresh does not
    // touch but which share the field. A null clears a field whose last entry went away.
    ['PUBMED__xrefs', 'DOI__xrefs'].forEach(f => {
      const nv = n[f], ov = o[f];
      const same = JSON.stringify((nv || []).slice().sort()) === JSON.stringify((ov || []).slice().sort());
      if (!same) u[f] = {set: nv === undefined ? null : nv};
    });

    // capabilities is NEVER `set`: add_attributes.pl and 62_attr_atomic.sh append
    // expression_attributes / grassius_homolog / MAKER / VEP after the dump, so they are not in the
    // recomputed doc and a `set` would delete them from 1.5M genes. add-distinct and remove touch
    // only the token named.
    const ncap = new Set(n.capabilities || []), ocap = new Set(o.capabilities || []);
    const capAdd = CURATION_CAPS.filter(c => ncap.has(c) && !ocap.has(c));
    const capDel = CURATION_CAPS.filter(c => !ncap.has(c) && ocap.has(c));
    if (capAdd.length) { u.capabilities = {'add-distinct': capAdd}; capStats.added += capAdd.length; }
    else if (capDel.length) { u.capabilities = {remove: capDel}; capStats.removed += capDel.length; }

    updates.push(u);
  });
  console.log('terms newly present : ' + added.size);
  console.log('terms now absent    : ' + removed.size);
  console.log('xref fields written : ' +
    updates.filter(u => u.PUBMED__xrefs).length + ' PUBMED, ' +
    updates.filter(u => u.DOI__xrefs).length + ' DOI');
  console.log('capability tokens   : +' + capStats.added + ' / -' + capStats.removed +
              '  (add-distinct/remove only, never set)');
  fs.writeFileSync(process.env.TERMS_DELTA || '/tmp/curated_terms_delta.json',
    JSON.stringify({added: Array.from(added), removed: Array.from(removed)}), 'utf8');
  console.log('wrote term delta to ' + (process.env.TERMS_DELTA || '/tmp/curated_terms_delta.json'));
  console.log('\nsample update: ' + JSON.stringify(updates[0]).slice(0, 220));

  if (!APPLY) { console.log('\n(dry run -- re-run with --apply to write solr)'); process.exit(0); }

  let sent = 0;
  for (let i = 0; i < updates.length; i += BATCH) {
    const b = updates.slice(i, i + BATCH);
    await solrUpdate(b, false);
    sent += b.length;
  }
  await solrUpdate([], true);
  console.log('solr: ' + sent + ' docs atomically updated and committed');
  process.exit(0);
})().catch(e => { console.error('ERR ' + (e && e.stack || e)); process.exit(1); });
