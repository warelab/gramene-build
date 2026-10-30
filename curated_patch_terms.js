#!/usr/bin/env node
// curated_patch_terms.js — bring terms.tsv back in line with the genes core after a targeted
// curated patch, so 65_solr_suggestions rebuilds autocomplete from the truth.
//
// terms.tsv is (term, taxon_id) with ONE ROW PER GENE OCCURRENCE and no gene id in it -- genes.js
// streams it sorted, groups by term, and uses the row count as num_genes. So rows cannot be removed
// "for gene X". Instead, for each affected term this asks the (already updated) core how many genes
// now carry it per taxon, deletes every row for that term, and writes exactly that many back.
// The counts therefore come from the index itself, not from arithmetic on a delta.
//
// usage: node curated_patch_terms.js <genesCoreUrl> <terms.tsv> <delta.json> [--apply]
'use strict';
const fs = require('fs');
const readline = require('readline');

const CORE = process.argv[2], TSV = process.argv[3], DELTA = process.argv[4];
const APPLY = process.argv.includes('--apply');
if (!CORE || !TSV || !DELTA) {
  console.error('usage: curated_patch_terms.js <genesCoreUrl> <terms.tsv> <delta.json> [--apply]');
  process.exit(2);
}

async function facetTaxa(term) {
  // {!term} takes the value verbatim -- no phrase quoting or escaping, which matters because these
  // terms contain spaces, commas, slashes and quotes ("similar to ABC transporter, putative").
  const r = await fetch(CORE + '/select', {
    method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: new URLSearchParams({
      q: '{!term f=_terms v=$tv}', tv: term, rows: '0', wt: 'json',
      facet: 'true', 'facet.field': 'taxon_id', 'facet.limit': '-1', 'facet.mincount': '1',
      'json.nl': 'map'
    }).toString()
  });
  if (!r.ok) throw new Error('select ' + r.status + ' for ' + JSON.stringify(term) + ': ' + (await r.text()).slice(0, 200));
  const j = await r.json();
  return j.facet_counts.facet_fields.taxon_id;   // {taxon: count}
}

(async () => {
  const delta = JSON.parse(fs.readFileSync(DELTA, 'utf8'));
  const affected = Array.from(new Set(delta.added.concat(delta.removed)));
  console.log('affected terms: ' + affected.length + ' (' + delta.added.length + ' added, ' + delta.removed.length + ' removed)');

  const want = {};           // term -> {taxon: count}
  let zero = 0;
  for (let i = 0; i < affected.length; i++) {
    want[affected[i]] = await facetTaxa(affected[i]);
    if (!Object.keys(want[affected[i]]).length) zero++;
    if (i && i % 100 === 0) console.log('  queried ' + i + '/' + affected.length);
  }
  const rowsWanted = Object.values(want).reduce((a, m) => a + Object.values(m).reduce((x, y) => x + y, 0), 0);
  console.log('  terms now carried by no gene: ' + zero + ' (their rows just disappear)');
  console.log('  rows to write for affected terms: ' + rowsWanted);

  // terms.tsv stores the term JSON-quoted, exactly as mongo2solr.join.js emitted it.
  const key = {};
  affected.forEach(t => { key[JSON.stringify(t)] = t; });

  const out = APPLY ? fs.createWriteStream(TSV + '.new') : null;
  let kept = 0, dropped = 0, total = 0;
  const rl = readline.createInterface({input: fs.createReadStream(TSV), crlfDelay: Infinity});
  for await (const line of rl) {
    if (!line) continue;
    total++;
    const tab = line.lastIndexOf('\t');
    const qterm = tab < 0 ? line : line.slice(0, tab);
    if (key.hasOwnProperty(qterm)) { dropped++; continue; }
    kept++;
    if (out && !out.write(line + '\n')) await new Promise(r => out.once('drain', r));
  }
  console.log('  scanned ' + total + ' rows: kept ' + kept + ', dropped ' + dropped);

  if (!APPLY) { console.log('\n(dry run -- re-run with --apply to rewrite ' + TSV + ')'); process.exit(0); }

  let written = 0;
  for (const t of affected) {
    const q = JSON.stringify(t);
    for (const [taxon, n] of Object.entries(want[t])) {
      for (let i = 0; i < n; i++) {
        if (!out.write(q + '\t' + taxon + '\n')) await new Promise(r => out.once('drain', r));
        written++;
      }
    }
  }
  await new Promise(r => out.end(r));
  console.log('  appended ' + written + ' rows -> ' + TSV + '.new (' + (kept + written) + ' total)');
  fs.renameSync(TSV, TSV + '.prepatch');
  fs.renameSync(TSV + '.new', TSV);
  console.log('  replaced ' + TSV + ' (previous kept as ' + TSV + '.prepatch)');
  process.exit(0);
})().catch(e => { console.error('ERR ' + (e && e.stack || e)); process.exit(1); });
