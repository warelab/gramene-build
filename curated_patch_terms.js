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
const {Transform, Writable} = require('stream');
const {pipeline} = require('stream/promises');
const {StringDecoder} = require('string_decoder');

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

  // The 47M-row scan is a stream pipeline, NOT `for await` over readline. readline closes as soon as
  // its input ends, and if the consumer happens to be suspended on a `drain` at that moment, the async
  // iterator's next resume() throws ERR_USE_AFTER_CLOSE. That is a race against the end of a 1.1 GB
  // file -- it survived one run of this script and killed the next -- so backpressure is left to the
  // stream machinery instead of being hand-rolled. StringDecoder (not chunk.toString) is what keeps a
  // multi-byte character split across a chunk boundary intact.
  let kept = 0, dropped = 0, total = 0;
  const dec = new StringDecoder('utf8');
  let tail = '';
  const filter = new Transform({
    transform(chunk, enc, cb) {
      const s = tail + dec.write(chunk);
      const nl = s.lastIndexOf('\n');
      if (nl < 0) { tail = s; return cb(); }
      tail = s.slice(nl + 1);
      let keepBuf = '';
      for (const line of s.slice(0, nl).split('\n')) {
        if (!line) continue;
        total++;
        const tab = line.lastIndexOf('\t');
        const qterm = tab < 0 ? line : line.slice(0, tab);
        if (key.hasOwnProperty(qterm)) { dropped++; continue; }
        kept++;
        keepBuf += line + '\n';
      }
      cb(null, keepBuf);
    },
    flush(cb) {
      const line = (tail + dec.end()).replace(/\n$/, '');
      if (!line) return cb();
      total++;
      const tab = line.lastIndexOf('\t');
      const qterm = tab < 0 ? line : line.slice(0, tab);
      if (key.hasOwnProperty(qterm)) { dropped++; return cb(); }
      kept++;
      cb(null, line + '\n');
    }
  });

  await pipeline(
    fs.createReadStream(TSV),
    filter,
    APPLY ? fs.createWriteStream(TSV + '.new')
          : new Writable({write(c, e, cb) { cb(); }})
  );
  console.log('  scanned ' + total + ' rows: kept ' + kept + ', dropped ' + dropped);

  if (!APPLY) { console.log('\n(dry run -- re-run with --apply to rewrite ' + TSV + ')'); process.exit(0); }

  // Appended in a second pass, opened for append, because pipeline() closes the stream it wrote to.
  const out = fs.createWriteStream(TSV + '.new', {flags: 'a'});
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
