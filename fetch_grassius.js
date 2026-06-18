#!/usr/bin/env node
// fetch_grassius.js — pull transcription-factor family assignments from the
// GRASSIUS source (grassius.org) at build time and emit a grassius.tsv keyed by
// THIS build's gene IDs, ready for the decorate-stage grassius adder.
//
// GRASSIUS publishes per-species gene lists as CSV:
//   https://grassius.org/download_species_gene_list/<Species>/_
//   columns: "number for sorting purposes", "protein name", "family", "gene ID"
// The gene IDs are old-assembly (e.g. sorghum Sbi1: Sb01g014370.1), so we map
// them to current gene IDs via each gene's synonyms in mongo (e.g. SORBI_3* genes
// carry Sb0..g.. and Sobic.. as synonyms). Output rows that don't map are reported
// (not silently dropped) so coverage regressions are visible.
//
// Output (stdout):  <current_gene_id>\t<protein_name>\t<family>   (grassius.tsv format)
// Usage: MONGO_URI=... MONGO_DB=sorghum11 node fetch_grassius.js [Species:system_name ...]
//   default species: Sorghum:sorghum_bicolor Maize:zea_maysb73 Oryza:oryza_sativa
'use strict';
const MONGO_LIB = '/usr/local/gramene/subsites/sorghum/v11/gramene-mongodb/node_modules/mongodb';
const { MongoClient } = require(MONGO_LIB);

const MONGO_URI = process.env.MONGO_URI || 'mongodb://localhost:27017';
const MONGO_DB = process.env.MONGO_DB || 'sorghum11';
const BASE = 'https://grassius.org/download_species_gene_list';
const specs = (process.argv.slice(2).length ? process.argv.slice(2)
              : ['Sorghum:sorghum_bicolor', 'Maize:zea_maysb73', 'Oryza:oryza_sativa'])
              .map(s => { const [g, sn] = s.split(':'); return { grassius: g, system_name: sn }; });

const stripTx = id => id.replace(/\.\d+$/, '');   // drop transcript suffix Sb01g014370.1 -> Sb01g014370

(async () => {
  const client = await MongoClient.connect(MONGO_URI);
  const genes = client.db(MONGO_DB).collection('genes');
  let total = 0, matched = 0;
  for (const { grassius, system_name } of specs) {
    // build id/synonym -> current _id lut for this species
    const lut = {};
    const cur = genes.find({ system_name }, { projection: { _id: 1, synonyms: 1 } });
    for await (const g of cur) {
      lut[g._id] = g._id;
      (g.synonyms || []).forEach(s => { if (s) lut[s] = g._id; lut[stripTx(s)] = g._id; });
    }
    // fetch the grassius csv
    let csv;
    try {
      const res = await fetch(`${BASE}/${grassius}/_`);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      csv = await res.text();
    } catch (e) { console.error(`grassius ${grassius}: fetch failed (${e.message}) — skipping`); continue; }
    const lines = csv.split(/\r?\n/);
    lines.shift();                                   // header
    let sTotal = 0, sMatch = 0;
    for (const line of lines) {
      if (!line.trim()) continue;
      const cols = line.split(',');
      if (cols.length < 4) continue;
      const protein = (cols[1] || '').trim();
      const family = (cols[2] || '').trim();
      const gid = (cols[3] || '').trim();
      if (!family || !gid) continue;
      sTotal++;
      const cid = lut[gid] || lut[stripTx(gid)];
      if (!cid) continue;                            // unmapped (old assembly id not a synonym)
      sMatch++;
      process.stdout.write(`${cid}\t${protein}\t${family}\n`);
    }
    total += sTotal; matched += sMatch;
    console.error(`grassius ${grassius} -> ${system_name}: mapped ${sMatch}/${sTotal} genes (${(100*sMatch/(sTotal||1)).toFixed(1)}%)`);
  }
  console.error(`grassius TOTAL: mapped ${matched}/${total}`);
  await client.close();
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
