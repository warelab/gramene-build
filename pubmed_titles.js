#!/usr/bin/env node
// pubmed_titles.js — fill the "Title/Description" column for literature references that arrived
// without one.
//
// Publications.js:125 renders `xrefs[].text` straight out of the mongo gene doc into that column, so
// a PUBMED xref with no `text` shows an empty cell. Three sources supply text -- rap-db the paper
// title, geneRIF the RIF statement, CSHL the curator's own description -- but the references that
// come off the Ensembl cores supply none at all, which is why medicago's references render blank.
// This asks PubMed for the title.
//
// mongo-only by design: mongo2solr.join.js:428 builds PUBMED__xrefs from `xref.ids` and drops `text`
// and `source` entirely, so the index has nothing to update. No reindex, no terms.tsv, no stage 65.
//
// Titles are cached in gramene-mongodb/search/pubmed_titles.tsv, which is committed, so the lookup
// happens once and search/pubmed_title_adder.js can replay it during a full decorate with no network
// access -- otherwise the next 50_genes_decorate would rebuild these docs from the stage-40 dumps
// and drop every title again.
//
// Existing text is NEVER overwritten: a curator's description outranks a journal title, and the
// whole point of `source` is that the reader can tell which they are looking at.
//
// usage: MONGO_DB=search70 node pubmed_titles.js [--apply] [--no-ncbi] [--rescan]
'use strict';

const fs = require('fs');
const path = require('path');
const dry = require('./curated_dryrun.js');
const { usable, SEARCH, MONGO_LIB, MONGO_URI, MONGO_DB } = dry;
// The exact transform the decorate adder applies, imported rather than restated: if the patch
// filled differently from the rebuild, the next full decorate would silently undo this work.
const { fillGene } = require(path.resolve(SEARCH, 'pubmed_title_adder.js'));

const APPLY   = process.argv.includes('--apply');
const NO_NCBI = process.argv.includes('--no-ncbi');
const RESCAN  = process.argv.includes('--rescan');

const CACHE    = process.env.PUBMED_TITLE_CACHE || path.resolve(SEARCH, 'pubmed_titles.tsv');
const WORK     = process.env.PUBMED_TITLE_WORK  || '/tmp/pubmed_titles.worklist.jsonl';
const NCBI_EMAIL = process.env.NCBI_EMAIL || 'gramene@gramene.org';
const BATCH = 500;

// ---------------------------------------------------------------------------------------------
// the committed cache
// ---------------------------------------------------------------------------------------------
// pmid \t title \t journal \t retrieved.  A title of "-" means PubMed was asked and gave nothing
// usable (a withdrawn record, or an id that is not a PMID at all); it is a negative entry and is
// never re-queried, the same convention curation_pmid_map.tsv uses.
function loadCache() {
  const m = new Map();
  let text;
  try { text = fs.readFileSync(CACHE, 'utf8'); } catch (e) { return m; }
  text.split('\n').forEach(line => {
    if (!line || line[0] === '#') return;
    const f = line.split('\t');
    if (f[0]) m.set(f[0].trim(), {title: (f[1] || '').trim(), journal: (f[2] || '').trim(), when: (f[3] || '').trim()});
  });
  return m;
}

function saveCache(cache) {
  // Numeric sort, so the file reads as a list of PMIDs rather than a lexicographic shuffle, and a
  // diff of two refreshes shows only the genuinely new rows.
  const keys = Array.from(cache.keys()).sort((a, b) => (+a) - (+b));
  const body = ['# pmid\ttitle\tjournal\tretrieved   (title "-" = PubMed had nothing usable; do not re-query)']
    .concat(keys.map(k => {
      const v = cache.get(k);
      return [k, v.title || '-', v.journal || '', v.when].join('\t');
    })).join('\n') + '\n';
  fs.writeFileSync(CACHE, body);
}

const ENT = {amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' '};

// PubMed titles carry real markup -- <i>Arabidopsis</i>, <sup>2+</sup>, &lt;, &amp;. The gene page
// renders text as a plain string, so tags would show up literally. Strip them and decode the
// entities rather than shipping "&lt;i&gt;".
function cleanTitle(s) {
  if (!s) return '';
  let t = String(s)
    .replace(/<[^>]*>/g, '')
    .replace(/&#x([0-9a-f]+);/gi, (m, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (m, d) => String.fromCodePoint(+d))
    .replace(/&([a-z]+);/gi, (m, n) => (ENT[n.toLowerCase()] !== undefined ? ENT[n.toLowerCase()] : m))
    // tabs and newlines would corrupt the TSV cache; the title is one line by definition
    .replace(/\s+/g, ' ')
    .trim();
  // esummary's own placeholders for a record with no usable title.
  if (/^\[?not available\]?\.?$/i.test(t)) return '';
  return t;
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// esummary takes up to 200 ids per request and returns title, journal and date for each. POST, not
// GET, because 200 ids is a long URL and eutils is happier with a body.
async function esummaryBatch(pmids) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 60000);
  try {
    const res = await fetch('https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi', {
      method: 'POST', signal: ctrl.signal,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: new URLSearchParams({
        db: 'pubmed', retmode: 'json', id: pmids.join(','),
        tool: 'gramene', email: NCBI_EMAIL
      }).toString()
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const body = await res.json();
    const r = body.result || {};
    const out = new Map();
    (r.uids || []).forEach(u => {
      const d = r[u] || {};
      if (d.error) return;
      const t = cleanTitle(d.title);
      if (t) out.set(String(u), {title: t, journal: [d.source, d.pubdate].filter(Boolean).join(' ')});
    });
    return out;
  } finally { clearTimeout(timer); }
}

async function resolveTitles(pmids, cache, stats) {
  const want = pmids.filter(p => !cache.has(p));
  stats.cached = pmids.length - want.length;
  if (!want.length) return;
  if (NO_NCBI) {
    stats.skipped = want.length;
    console.error('--no-ncbi: ' + want.length + ' PMIDs left unresolved (not in the cache)');
    return;
  }
  const stamp = new Date().toISOString().slice(0, 10);
  console.error('asking PubMed for ' + want.length + ' titles (' + Math.ceil(want.length / 200) + ' batches)...');

  for (let i = 0; i < want.length; i += 200) {
    const batch = want.slice(i, i + 200);
    let found = new Map();
    try {
      found = await esummaryBatch(batch);
    } catch (e) {
      // A failed batch is left entirely uncached rather than written off as 200 negatives: a
      // transient 5xx must not poison the cache against a re-run.
      console.error('  batch ' + (i / 200 + 1) + ' failed (' + e.message + ') -- those PMIDs stay unresolved');
      stats.failed += batch.length;
      await sleep(1000);
      continue;
    }
    batch.forEach(p => {
      const hit = found.get(p);
      cache.set(p, {title: hit ? hit.title : '-', journal: hit ? hit.journal : '', when: stamp});
      if (hit) stats.resolved++; else stats.notFound++;
    });
    if ((i / 200) % 10 === 0) console.error('  ' + Math.min(i + 200, want.length) + '/' + want.length);
    await sleep(400);          // NCBI allows 3 requests/second without an API key
  }
}

// ---------------------------------------------------------------------------------------------
(async () => {
  const { MongoClient } = require(MONGO_LIB);
  const client = new MongoClient(MONGO_URI, {useNewUrlParser: true, useUnifiedTopology: true});
  await client.connect();
  const genes = client.db(MONGO_DB).collection('genes');
  console.log('pubmed titles against ' + MONGO_DB +
              (APPLY ? '  -- APPLYING' : '  -- dry run, nothing written') + '\n');

  // --- 1. the worklist -------------------------------------------------------------------------
  // One COLLSCAN (there is no index on xrefs.db) streamed with a projection, writing a compact
  // worklist so the apply pass can look its genes up by _id instead of scanning again.
  if (RESCAN || !fs.existsSync(WORK)) {
    console.log('---- scanning for PUBMED references with no text (full scan, several minutes)');
    const out = fs.createWriteStream(WORK);
    const cursor = genes.find({'xrefs.db': 'PUBMED'}, {projection: {xrefs: 1, taxon_id: 1}});
    let seen = 0, affected = 0, slots = 0, multiId = 0, emptyIds = 0;
    const perTaxon = {};
    for await (const g of cursor) {
      seen++;
      const recs = [];
      (g.xrefs || []).forEach(x => {
        if (x.db !== 'PUBMED' || usable(x.text)) return;
        const ids = (x.ids || []).map(String).filter(Boolean);
        if (!ids.length) { emptyIds++; return; }
        if (ids.length > 1) multiId++;
        recs.push(ids);
        const k = (x.source || '(no source)') + '  taxon ' + g.taxon_id;
        perTaxon[k] = (perTaxon[k] || 0) + 1;
      });
      if (!recs.length) continue;
      affected++; slots += recs.length;
      if (!out.write(JSON.stringify({_id: g._id, taxon_id: g.taxon_id, recs: recs}) + '\n')) {
        await new Promise(r => out.once('drain', r));
      }
    }
    await new Promise(r => out.end(r));
    console.log('  genes with a PUBMED reference      : ' + seen);
    console.log('  genes with a reference lacking text: ' + affected);
    console.log('  text-less reference records        : ' + slots);
    console.log('    of those, carrying >1 PMID       : ' + multiId);
    console.log('    carrying no PMID at all          : ' + emptyIds);
    console.log('  by source/taxon (text-less records):');
    Object.keys(perTaxon).sort((a, b) => perTaxon[b] - perTaxon[a]).slice(0, 20)
      .forEach(k => console.log('    ' + k.padEnd(28) + perTaxon[k]));
    console.log('  worklist -> ' + WORK);
  } else {
    console.log('---- reusing the worklist at ' + WORK + ' (--rescan to rebuild)');
  }

  // --- 2. titles -------------------------------------------------------------------------------
  const lines = fs.readFileSync(WORK, 'utf8').split('\n').filter(Boolean);
  const all = new Set();
  lines.forEach(l => JSON.parse(l).recs.forEach(ids => ids.forEach(p => all.add(p))));
  const pmids = Array.from(all).sort((a, b) => (+a) - (+b));
  console.log('\n---- titles for ' + pmids.length + ' distinct PMIDs over ' + lines.length + ' genes');

  const cache = loadCache();
  const stats = {cached: 0, resolved: 0, notFound: 0, failed: 0, skipped: 0};
  await resolveTitles(pmids, cache, stats);
  if (stats.resolved || stats.notFound) saveCache(cache);
  console.log('  already cached : ' + stats.cached);
  console.log('  newly resolved : ' + stats.resolved);
  console.log('  no title       : ' + stats.notFound + '  (cached as "-", never re-queried)');
  if (stats.failed)  console.log('  batch failures : ' + stats.failed + '  (left uncached, retried next run)');
  if (stats.skipped) console.log('  skipped        : ' + stats.skipped + '  (--no-ncbi)');
  const have = pmids.filter(p => { const v = cache.get(p); return v && v.title && v.title !== '-'; });
  console.log('  PMIDs with a usable title: ' + have.length + ' of ' + pmids.length);

  // --- 3. apply --------------------------------------------------------------------------------
  // Re-read each gene's xrefs rather than trusting the array index recorded during the scan: the
  // positional path "xrefs.3.text" is only correct if nothing reordered the array in between, and a
  // read-modify-write of the whole array cannot be wrong about which reference it is filling.
  const lut = {};
  cache.forEach((v, k) => { if (v.title && v.title !== '-') lut[k] = v.title; });
  let touchedGenes = 0, filledSlots = 0, splitRecs = 0, stillBlank = 0, examples = [];
  let ops = [];
  async function flush() {
    if (!ops.length) return;
    if (APPLY) {
      const r = await genes.bulkWrite(ops, {ordered: false});
      if (r.modifiedCount !== ops.length) {
        console.error('  WARNING batch wrote ' + r.modifiedCount + ' of ' + ops.length);
      }
    }
    ops = [];
  }

  for (let i = 0; i < lines.length; i += BATCH) {
    const chunk = lines.slice(i, i + BATCH).map(JSON.parse);
    const byId = {};
    chunk.forEach(c => byId[c._id] = c);
    const live = await genes.find({_id: {$in: Object.keys(byId)}}, {projection: {xrefs: 1}}).toArray();
    live.forEach(g => {
      const r = fillGene(g, lut);
      // Whatever fillGene left without text is genuinely unfillable: no title for that PMID, or a
      // multi-PMID record where not one of its PMIDs resolved.
      stillBlank += (g.xrefs || []).filter(x => x.db === 'PUBMED' && !usable(x.text)).length;
      if (!r.filled && !r.split) return;
      touchedGenes++; filledSlots += r.filled; splitRecs += r.split;
      if (examples.length < 6) {
        const f = (g.xrefs || []).find(x => x.db === 'PUBMED' && usable(x.text));
        if (f) examples.push(g._id + '  ' + (f.ids || []).join(',') + '  ' + String(f.text).slice(0, 88));
      }
      ops.push({updateOne: {filter: {_id: g._id}, update: {$set: {xrefs: g.xrefs}}}});
    });
    await flush();
    if ((i / BATCH) % 20 === 0) process.stderr.write('\r  ' + Math.min(i + BATCH, lines.length) + '/' + lines.length);
  }
  await flush();
  process.stderr.write('\r');

  console.log('\n  genes to update        : ' + touchedGenes);
  console.log('  reference titles filled: ' + filledSlots);
  console.log('  multi-PMID records split: ' + splitRecs + '  (one record per paper, each with its own title)');
  console.log('  still blank            : ' + stillBlank + '  (PubMed had no title for that PMID)');
  if (examples.length) { console.log('\nsample:'); examples.forEach(e => console.log('  ' + e)); }

  if (!APPLY) console.log('\n(dry run -- re-run with --apply to write mongo)');
  else        console.log('\nmongo: ' + touchedGenes + ' documents modified');
  console.log('\nTo keep these across a full decorate, ' + CACHE + ' must be committed;');
  console.log('search/pubmed_title_adder.js replays it from the cache during 50_genes_decorate.');

  await client.close();
  process.exit(0);
})().catch(e => { console.error('ERR ' + (e && e.stack || e)); process.exit(1); });
