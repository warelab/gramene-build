#!/usr/bin/env node
// msu_alt_id_patch.js — land a regenerated OsNipp_IRGSP_MSU_lut.json on an already-built
// `genes` collection without a 2h decorate, exactly as decorate's msu6_adder would.
//
// It does NOT restate the adder's rule: it imports the same LUT the adder reads and applies the
// same "concat then uniq" to gene.alt_id, so a later full rebuild produces the same result.
//
// Only LOC_Os* members of alt_id are touched. alt_id also carries Sobic./GRMZM/Vitvi alternate
// ids for other species, and those must survive untouched -- which is why this replaces the
// LOC_Os* subset rather than overwriting the field.
//
// Dry by default; --apply writes. Prints the solr reconciliation command on the way out.

'use strict';
const path = require('path');
const MongoClient = require(path.join(__dirname, '..', 'gramene-mongodb', 'node_modules', 'mongodb')).MongoClient;

const LUT = require(path.join(__dirname, '..', 'gramene-mongodb', 'search', 'OsNipp_IRGSP_MSU_lut.json'));
const URI = process.env.MONGO_URI || 'mongodb://localhost:27017';
const DB = process.env.MONGO_DB;
if (!DB) { console.error('msu_alt_id_patch: MONGO_DB is not set'); process.exit(1); }
const APPLY = process.argv.indexOf('--apply') >= 0;

const IS_MSU = /^LOC_Os/;

function wanted(id) {
  const hit = LUT[id];
  if (!hit || !hit.MSU_id) return [];
  return Array.isArray(hit.MSU_id) ? hit.MSU_id.slice() : [hit.MSU_id];
}

(async function main() {
  const client = await MongoClient.connect(URI, { useNewUrlParser: true, useUnifiedTopology: true });
  const genes = client.db(DB).collection('genes');

  // candidates: every gene the LUT names, plus every gene that currently carries an MSU alt_id
  // (so entries RAP-DB has retracted are actually removed, not merely left behind).
  const ids = new Set(Object.keys(LUT));
  const cur = await genes.find({ alt_id: IS_MSU }, { projection: { alt_id: 1 } }).toArray();
  for (const g of cur) ids.add(g._id);
  console.log((APPLY ? 'PATCHING ' : 'dry run against ') + DB + '.genes' + (APPLY ? '' : ' -- nothing is written') + '\n');
  console.log('candidate gene ids            : ' + ids.size);

  const ops = [];
  let present = 0, same = 0, added = 0, removed = 0, changedGenes = 0;
  let addedIds = 0, removedIds = 0;
  const bySys = {};

  const idList = Array.from(ids);
  for (let i = 0; i < idList.length; i += 2000) {
    const chunk = idList.slice(i, i + 2000);
    const docs = await genes.find({ _id: { $in: chunk } },
      { projection: { alt_id: 1, system_name: 1 } }).toArray();
    for (const g of docs) {
      present++;
      const old = Array.isArray(g.alt_id) ? g.alt_id : (g.alt_id ? [g.alt_id] : []);
      const keep = old.filter(x => !IS_MSU.test(x));          // other species' alternate ids
      const oldMsu = old.filter(x => IS_MSU.test(x));
      const newMsu = wanted(g._id);
      const next = keep.concat(newMsu).filter((x, j, a) => a.indexOf(x) === j);

      const a = oldMsu.slice().sort().join(','), b = newMsu.slice().sort().join(',');
      if (a === b) { same++; continue; }
      changedGenes++;
      const gained = newMsu.filter(x => oldMsu.indexOf(x) < 0);
      const lost = oldMsu.filter(x => newMsu.indexOf(x) < 0);
      addedIds += gained.length; removedIds += lost.length;
      if (gained.length) added++;
      if (lost.length) removed++;
      const s = g.system_name || '(none)';
      bySys[s] = (bySys[s] || 0) + 1;
      ops.push({ updateOne: { filter: { _id: g._id },
        update: next.length ? { $set: { alt_id: next } } : { $unset: { alt_id: '' } } } });
    }
  }

  console.log('present in ' + DB + '.genes          : ' + present);
  console.log('already correct (no change)   : ' + same);
  console.log('\ngenes that would change        : ' + changedGenes);
  console.log('  gaining an MSU id           : ' + added + '  (+' + addedIds + ' ids)');
  console.log('  losing an MSU id            : ' + removed + '  (-' + removedIds + ' ids)');
  for (const s of Object.keys(bySys).sort()) console.log('    ' + s + '\t' + bySys[s]);

  if (!APPLY) {
    console.log('\nre-run with --apply to write, then reconcile the index: make msu-solr');
  } else if (ops.length) {
    for (let i = 0; i < ops.length; i += 1000) {
      await genes.bulkWrite(ops.slice(i, i + 1000), { ordered: false });
      process.stdout.write('  wrote ' + Math.min(i + 1000, ops.length) + '/' + ops.length + '\r');
    }
    console.log('\n\nnow reconcile the index:  make msu-solr');
  } else {
    console.log('\nnothing to write.');
  }
  await client.close();
})().catch(e => { console.error('msu_alt_id_patch: ' + (e.stack || e.message)); process.exit(1); });
