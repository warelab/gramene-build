#!/usr/bin/env node
// synonym_conflict_patch.js — remove synonyms that are another LOCUS's identifier.
//
// WHY. A gene's `synonyms` come partly from the Ensembl core's display xref, and `dump_genes.js`
// joins `external_synonym es ON es.xref_id = x.xref_id` against `g.display_xref_id`. For a
// `Uniprot_gn` xref that whole row is keyed on the bare gene SYMBOL, not on a locus -- so when two
// unrelated genes abbreviate to the same symbol, every identifier UniProt associates with that
// symbol lands on BOTH of them.
//
// The worked example: rice Os01g0100900 is sphingosine-1-phosphate lyase (UniProt Q52RG7) at
// chr1:35,623. Its display xref is `Uniprot_gn` with dbprimary_acc = "SPL1", and that row carries
// external_synonyms LOC_Os01g18850 and Os01g0292900 -- the RAP and MSU ids of Os01g0292900,
// OsSPL1/OsSBP1, a SQUAMOSA-promoter-binding transcription factor 10.6 Mb away. Searching
// LOC_Os01g18850 returned three genes, one of them wrong.
//
// The tell that this is upstream mis-assignment and not a local bug: the gene's OWN correct MSU id
// (LOC_Os01g01080) is absent from that synonym list while the other locus's is present.
//
// THE RULE. Drop synonym S from gene G when all of:
//   * S is the primary `_id` of some other gene in this site  (S !== G._id)
//   * S is not one of G's own `alt_id`s                        (those are G's real synonyms)
//   * G and the gene S names are NOT plausibly the same locus: different chromosome, or disjoint
//     intervals more than ADJACENCY apart.
//
// That last clause is the one that matters, and it is not cosmetic. Some synonyms that are another
// gene's id are LEGITIMATE: a split or merged gene model properly carries its neighbour's retired
// id. In oryza10 the gaps are 0, 0, 428 and 690 bp and then jump straight to 13,907 bp, so the two
// populations are cleanly separated and ADJACENCY sits in the empty space between them. Keeping
// those four (3 arabidopsis pairs with consecutive AT ids, plus Os06g0610350/Os06g0610300) is
// deliberate -- they are model revisions, not symbol collisions.
//
// Dry by default; --apply writes. Idempotent.

'use strict';
const path = require('path');
const MongoClient = require(path.join(__dirname, '..', 'gramene-mongodb', 'node_modules', 'mongodb')).MongoClient;

const URI = process.env.MONGO_URI || 'mongodb://localhost:27017';
const DB = process.env.MONGO_DB;
if (!DB) { console.error('synonym_conflict_patch: MONGO_DB is not set'); process.exit(1); }
const APPLY = process.argv.indexOf('--apply') >= 0;
const VERBOSE = process.argv.indexOf('--verbose') >= 0;
const ADJACENCY = Number(process.env.SYNONYM_ADJACENCY || 2000);

// exported so a caller can apply exactly this rule without restating it
function conflicts(gene, isGeneId, locOf, adjacency) {
  const own = Array.isArray(gene.alt_id) ? gene.alt_id : (gene.alt_id ? [gene.alt_id] : []);
  const syns = Array.isArray(gene.synonyms) ? gene.synonyms : (gene.synonyms ? [gene.synonyms] : []);
  const out = [];
  for (const s of syns) {
    if (!isGeneId(s) || s === gene._id || own.indexOf(s) >= 0) continue;
    const a = gene.location, b = locOf(s);
    // No coordinates on either side: cannot establish they are the same locus, so the symbol-keyed
    // collision is the likelier explanation. Drop it, but say so under --verbose.
    if (!a || !b) { out.push(s); continue; }
    if (a.region === b.region) {
      const gap = Math.max(0, Math.max(a.start, b.start) - Math.min(a.end, b.end));
      if (gap <= adjacency) continue;              // overlapping or adjacent: a model revision
    }
    out.push(s);
  }
  return out;
}

(async function main() {
  const client = await MongoClient.connect(URI, { useNewUrlParser: true, useUnifiedTopology: true });
  const genes = client.db(DB).collection('genes');

  console.log((APPLY ? 'PATCHING ' : 'dry run against ') + DB + '.genes'
    + (APPLY ? '' : ' -- nothing is written') + '   (adjacency ' + ADJACENCY + ' bp)\n');

  // Which synonym strings are also a gene id? distinct() keeps this to one pass plus a few
  // batched lookups rather than a per-gene query over the whole collection.
  const syns = await genes.distinct('synonyms');
  const idSet = new Set();
  for (let i = 0; i < syns.length; i += 2000) {
    const batch = syns.slice(i, i + 2000).filter(s => typeof s === 'string');
    for (const g of await genes.find({ _id: { $in: batch } }, { projection: { _id: 1 } }).toArray()) idSet.add(g._id);
  }
  console.log('distinct synonym strings      : ' + syns.length);
  console.log('of those, also a gene _id     : ' + idSet.size);

  const locs = new Map();
  const ids = Array.from(idSet);
  for (let i = 0; i < ids.length; i += 2000) {
    for (const g of await genes.find({ _id: { $in: ids.slice(i, i + 2000) } },
      { projection: { location: 1 } }).toArray()) locs.set(g._id, g.location);
  }
  const isGeneId = s => idSet.has(s);
  const locOf = s => locs.get(s);

  const ops = [];
  let changed = 0, removed = 0, keptAdjacent = 0;
  const bySys = {}, examples = [], kept = [];
  const cursor = genes.find({ synonyms: { $in: ids } },
    { projection: { synonyms: 1, alt_id: 1, location: 1, name: 1, system_name: 1 } });
  while (await cursor.hasNext()) {
    const g = await cursor.next();
    const bad = conflicts(g, isGeneId, locOf, ADJACENCY);
    // count what the adjacency clause spared, so the exemption stays visible
    const all = conflicts(g, isGeneId, locOf, -1);
    if (all.length > bad.length) {
      keptAdjacent += all.length - bad.length;
      for (const s of all) if (bad.indexOf(s) < 0) kept.push(g._id + ' keeps ' + s);
    }
    if (!bad.length) continue;
    changed++; removed += bad.length;
    bySys[g.system_name] = (bySys[g.system_name] || 0) + 1;
    const next = g.synonyms.filter(s => bad.indexOf(s) < 0);
    if (examples.length < 6) examples.push(g._id + ' (' + g.name + ')  drop ' + bad.join(', '));
    ops.push({ updateOne: { filter: { _id: g._id },
      update: next.length ? { $set: { synonyms: next } } : { $unset: { synonyms: '' } } } });
  }

  console.log('\ngenes to change               : ' + changed);
  console.log('synonyms to remove            : ' + removed);
  console.log('kept as adjacent/overlapping  : ' + keptAdjacent + '  (model revisions, not collisions)');
  for (const s of Object.keys(bySys).sort()) console.log('    ' + s + '\t' + bySys[s]);
  if (examples.length) { console.log(''); for (const e of examples) console.log('  ' + e); }
  if (kept.length && (VERBOSE || kept.length <= 8)) { console.log('\n  kept:'); for (const k of kept) console.log('    ' + k); }

  if (!APPLY) {
    console.log('\nre-run with --apply to write, then reconcile the index: make synonym-conflicts-solr');
  } else if (ops.length) {
    for (let i = 0; i < ops.length; i += 500) await genes.bulkWrite(ops.slice(i, i + 500), { ordered: false });
    console.log('\nwrote ' + ops.length + ' updates.\nnow reconcile the index: make synonym-conflicts-solr');
  } else {
    console.log('\nnothing to write.');
  }
  await client.close();
})().catch(e => { console.error('synonym_conflict_patch: ' + (e.stack || e.message)); process.exit(1); });

module.exports.conflicts = conflicts;
