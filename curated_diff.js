#!/usr/bin/env node
// curated_diff.js — compare a freshly generated curation artifact against the committed one and say
// what changed, per locus and per field, so an incremental refresh knows which path it needs.
//
// WHY A CLASSIFIER AND NOT JUST A DIFF. The two refresh paths are not interchangeable:
//
//   name / synonyms / references   -> patchable. curated_patch*.js writes these into mongo and the
//                                    live core by atomic update in ~40 minutes.
//   ontology terms (GO/PO/TO)      -> NOT patchable. ancestor_adder.js expands each term to its
//                                    ancestor closure during decorate, producing the
//                                    <ont>__ancestors fields and the facet counts. Nothing
//                                    downstream of a mongo write recomputes that, so a patched
//                                    ontology term would be present on the gene and missing from
//                                    every ancestor facet -- visible to no gate and wrong for
//                                    anyone browsing by term. That needs the 50 -> 60 -> 65 chain.
//
// So this exits 0 with a recommended path rather than pretending one size fits.
//
// usage: node curated_diff.js <old.json> <new.json> [--json <out>]
'use strict';

const fs = require('fs');

const OLD = process.argv[2], NEW = process.argv[3];
const JSON_OUT = (() => { const i = process.argv.indexOf('--json'); return i > 0 ? process.argv[i + 1] : null; })();
if (!OLD || !NEW) { console.error('usage: curated_diff.js <old.json> <new.json> [--json <out>]'); process.exit(2); }

function load(f) {
  let d;
  try { d = JSON.parse(fs.readFileSync(f, 'utf8')); }
  catch (e) { console.error('cannot read ' + f + ': ' + e.message); process.exit(2); }
  const m = new Map();
  (d || []).forEach(e => { if (e && e.locus) m.set(e.locus, e); });
  return m;
}

// Compare the fields that matter, ignoring presentation. gene_symbols is a ", "-joined string in
// the artifact; comparing the strings would report a reorder as a change and send a no-op refresh
// down the 15h path.
function symbolSet(e) {
  return new Set(String(e.gene_symbols || '').split(',').map(s => s.trim()).filter(Boolean));
}
function refMap(e) {
  const m = new Map();
  Object.keys(e.references || {}).forEach(k => {
    m.set(k, String((e.references[k] || {}).description || ''));
  });
  return m;
}
function ontSet(e) {
  const s = new Set();
  ['po', 'to', 'go', 'chebi'].forEach(o => (e[o] || []).forEach(t => s.add(o + ':' + t)));
  return s;
}
function evidMap(e) {
  const m = new Map();
  Object.keys(e.evidence || {}).forEach(k => m.set(k, e.evidence[k]));
  return m;
}
function setDiff(a, b) { return Array.from(a).filter(x => !b.has(x)); }

const oldM = load(OLD), newM = load(NEW);
const loci = Array.from(new Set(Array.from(oldM.keys()).concat(Array.from(newM.keys())))).sort();

const changes = [];
for (const locus of loci) {
  const o = oldM.get(locus), n = newM.get(locus);
  const c = {locus: locus, kind: o ? (n ? 'changed' : 'removed') : 'added', fields: {}};

  const oSym = o ? symbolSet(o) : new Set(), nSym = n ? symbolSet(n) : new Set();
  const symAdd = setDiff(nSym, oSym), symDel = setDiff(oSym, nSym);
  if (symAdd.length || symDel.length) c.fields.symbols = {added: symAdd, removed: symDel};

  const oRef = o ? refMap(o) : new Map(), nRef = n ? refMap(n) : new Map();
  const refAdd = Array.from(nRef.keys()).filter(k => !oRef.has(k));
  const refDel = Array.from(oRef.keys()).filter(k => !nRef.has(k));
  // A description edit matters: it is the text the Curated publications tab displays.
  const refText = Array.from(nRef.keys()).filter(k => oRef.has(k) && oRef.get(k) !== nRef.get(k));
  if (refAdd.length || refDel.length || refText.length) {
    c.fields.references = {added: refAdd, removed: refDel, retexted: refText};
  }

  const oOnt = o ? ontSet(o) : new Set(), nOnt = n ? ontSet(n) : new Set();
  const ontAdd = setDiff(nOnt, oOnt), ontDel = setDiff(oOnt, nOnt);
  const oEv = o ? evidMap(o) : new Map(), nEv = n ? evidMap(n) : new Map();
  const evChanged = Array.from(nEv.keys()).filter(k => oEv.has(k) && oEv.get(k) !== nEv.get(k));
  if (ontAdd.length || ontDel.length || evChanged.length) {
    c.fields.ontology = {added: ontAdd, removed: ontDel, evidenceChanged: evChanged};
  }

  if (Object.keys(c.fields).length) changes.push(c);
}

const withSym = changes.filter(c => c.fields.symbols);
const withRef = changes.filter(c => c.fields.references);
const withOnt = changes.filter(c => c.fields.ontology);
const added = changes.filter(c => c.kind === 'added');
const removed = changes.filter(c => c.kind === 'removed');

console.log('curated artifact diff');
console.log('  old: ' + OLD + '  (' + oldM.size + ' loci)');
console.log('  new: ' + NEW + '  (' + newM.size + ' loci)');
console.log('');
console.log('  loci changed in any way   : ' + changes.length);
console.log('    newly curated genes     : ' + added.length);
console.log('    genes no longer present : ' + removed.length);
console.log('    symbol/synonym changes  : ' + withSym.length);
console.log('    literature changes      : ' + withRef.length);
console.log('    ontology-term changes   : ' + withOnt.length);

function show(label, list, fmt) {
  if (!list.length) return;
  console.log('\n  ' + label + ':');
  list.slice(0, 25).forEach(c => console.log('    ' + c.locus.padEnd(22) + fmt(c)));
  if (list.length > 25) console.log('    ... and ' + (list.length - 25) + ' more');
}
show('symbols', withSym, c => {
  const f = c.fields.symbols;
  return (f.added.length ? '+' + f.added.join(',') : '') +
         (f.removed.length ? '  -' + f.removed.join(',') : '');
});
show('literature', withRef, c => {
  const f = c.fields.references;
  return (f.added.length ? '+' + f.added.join(',') : '') +
         (f.removed.length ? '  -' + f.removed.join(',') : '') +
         (f.retexted.length ? '  text:' + f.retexted.join(',') : '');
});
show('ontology', withOnt, c => {
  const f = c.fields.ontology;
  return (f.added.length ? '+' + f.added.join(',') : '') +
         (f.removed.length ? '  -' + f.removed.join(',') : '') +
         (f.evidenceChanged.length ? '  ev:' + f.evidenceChanged.join(',') : '');
});

console.log('\n=== recommended path ===');
if (!changes.length) {
  console.log('  NOTHING TO DO -- the regenerated artifact is identical to the committed one.');
} else if (withOnt.length) {
  console.log('  FULL CHAIN (50 -> 60 -> 65, ~15h). ' + withOnt.length + ' loci change ontology terms,');
  console.log('  and ancestor_adder.js expands those into <ont>__ancestors during decorate. A patch');
  console.log('  cannot recompute an ancestor closure, so patching would leave the term on the gene');
  console.log('  and absent from every ancestor facet.');
  console.log('  To patch the rest now and defer the ontology work, drop those loci from the');
  console.log('  artifact and re-run this diff.');
} else {
  console.log('  INCREMENTAL PATCH (~40min): name/synonyms/references only, no ontology change.');
  console.log('  Run: bash ' + __dirname + '/refresh_curated_incremental.sh');
}

if (JSON_OUT) {
  fs.writeFileSync(JSON_OUT, JSON.stringify({
    generated: new Date().toISOString(),
    old: OLD, new: NEW,
    oldLoci: oldM.size, newLoci: newM.size,
    needsFullChain: withOnt.length > 0,
    counts: {changed: changes.length, added: added.length, removed: removed.length,
             symbols: withSym.length, references: withRef.length, ontology: withOnt.length},
    loci: changes.map(c => c.locus),
    changes: changes
  }, null, 1) + '\n');
  console.log('\nwrote ' + JSON_OUT);
}
