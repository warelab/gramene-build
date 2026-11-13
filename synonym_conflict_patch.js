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
//   * S identifies some other gene in this site -- either as that gene's primary `_id` OR as its
//     `alt_id`. The alt_id half is not optional: the MSU genome (oryza_sativamsu) exists only in
//     the rice site, so in maize/sorghum/grapevine a contaminating LOC_Os* id is nobody's `_id`
//     and an id-only rule silently leaves it in place -- which is exactly what the first version
//     of this did, caught by verifying `synonyms:"LOC_Os01g18850"` per site rather than carrying
//     rice's result over.
//   * S is not one of G's own `alt_id`s                        (those are G's real synonyms)
//   * G and the gene(s) S names are NOT plausibly the same locus: different chromosome, or
//     disjoint intervals more than ADJACENCY apart. When S identifies several genes (an MSU id can
//     be the alt_id of more than one RAP locus), S is kept if ANY of them is G or is adjacent to
//     G -- the conservative reading.
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

// exported so a caller can apply exactly this rule without restating it.
// ownersOf(s) -> [{_id, location}] for every gene S identifies, by _id or by alt_id.
function conflicts(gene, ownersOf, adjacency) {
  const own = Array.isArray(gene.alt_id) ? gene.alt_id : (gene.alt_id ? [gene.alt_id] : []);
  const syns = Array.isArray(gene.synonyms) ? gene.synonyms : (gene.synonyms ? [gene.synonyms] : []);
  const out = [];
  for (const s of syns) {
    if (s === gene._id || own.indexOf(s) >= 0) continue;
    const owners = ownersOf(s);
    if (!owners || !owners.length) continue;             // identifies nothing here: leave it alone
    if (owners.some(o => o._id === gene._id)) continue;  // it is this gene's own identifier
    const a = gene.location;
    // Same locus if ANY owner overlaps or sits within ADJACENCY. No coordinates to compare means we
    // cannot establish that, and the symbol-keyed collision is the likelier explanation.
    const sameLocus = owners.some(o => {
      const b = o.location;
      if (!a || !b || a.region !== b.region) return false;
      const gap = Math.max(0, Math.max(a.start, b.start) - Math.min(a.end, b.end));
      return gap <= adjacency;
    });
    if (!sameLocus) out.push(s);
  }
  return out;
}

(async function main() {
  const client = await MongoClient.connect(URI, { useNewUrlParser: true, useUnifiedTopology: true });
  const genes = client.db(DB).collection('genes');

  console.log((APPLY ? 'PATCHING ' : 'dry run against ') + DB + '.genes'
    + (APPLY ? '' : ' -- nothing is written') + '   (adjacency ' + ADJACENCY + ' bp)\n');

  // THREE STREAMING PASSES, and the shape matters. The first version batched the synonym strings
  // and ran `{alt_id: {$in: batch}}` per batch -- but alt_id carries no mongo index, so each batch
  // was a full collection scan: ~56 scans of 16.1M documents on release70, which ran past a 50
  // minute timeout (exit 124). Wiring that into stage 51 would have armed a build that hangs.
  // Streaming costs three scans total regardless of how many distinct synonyms there are, and
  // needs no index.
  //
  // Memory stays bounded: pass 1 holds the synonym strings, pass 2 holds owners only for the few
  // that identify a gene (hundreds), and pass 3 holds nothing.

  // pass 1 -- every synonym string in the collection
  const synSet = new Set();
  let scanned = 0;
  let cur = genes.find({ synonyms: { $exists: true } }, { projection: { synonyms: 1 } });
  while (await cur.hasNext()) {
    const g = await cur.next();
    for (const x of (Array.isArray(g.synonyms) ? g.synonyms : [g.synonyms])) {
      if (typeof x === 'string') synSet.add(x);
    }
    if (++scanned % 200000 === 0) process.stdout.write('  pass 1: ' + scanned + ' genes\r');
  }
  console.log('distinct synonym strings      : ' + synSet.size + '   (from ' + scanned + ' genes with synonyms)');

  // pass 2 -- which of those identify a gene, by _id or by alt_id
  const owners = new Map();
  const add = (k, g) => {
    if (!owners.has(k)) owners.set(k, []);
    if (!owners.get(k).some(o => o._id === g._id)) owners.get(k).push({ _id: g._id, location: g.location });
  };
  let byId = 0, byAlt = 0;
  scanned = 0;
  cur = genes.find({}, { projection: { alt_id: 1, location: 1 } });
  while (await cur.hasNext()) {
    const g = await cur.next();
    if (synSet.has(g._id)) { add(g._id, g); byId++; }
    if (g.alt_id) {
      for (const a of (Array.isArray(g.alt_id) ? g.alt_id : [g.alt_id])) {
        if (typeof a === 'string' && synSet.has(a)) { add(a, g); byAlt++; }
      }
    }
    if (++scanned % 500000 === 0) process.stdout.write('  pass 2: ' + scanned + ' genes\r');
  }
  console.log('of those, identify a gene     : ' + owners.size + '  (' + byId + ' by _id, ' + byAlt + ' by alt_id)');
  const ownersOf = s => owners.get(s);

  const ops = [];
  let changed = 0, removed = 0, keptAdjacent = 0;
  const bySys = {}, examples = [], kept = [];
  // pass 3 -- apply the rule. Streams every gene with synonyms rather than querying
  // `{synonyms: {$in: <owner keys>}}`, which is the same unindexed-field trap as above.
  const cursor = genes.find({ synonyms: { $exists: true } },
    { projection: { synonyms: 1, alt_id: 1, location: 1, name: 1, system_name: 1 } });
  while (await cursor.hasNext()) {
    const g = await cursor.next();
    const bad = conflicts(g, ownersOf, ADJACENCY);
    // count what the adjacency clause spared, so the exemption stays visible
    const all = conflicts(g, ownersOf, -1);
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
