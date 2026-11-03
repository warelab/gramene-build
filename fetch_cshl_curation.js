#!/usr/bin/env node
// fetch_cshl_curation.js — turn the "Curated Genes (Responses)" sheet into the
// cshl_curated_genes.json the decorate-stage `curated` adder reads.
//
// WHY THIS EXISTS. Every gene page links a Google Form, "Curate Gene Function", prefilled with the
// gene id. It writes to this sheet. The build, however, read a hand-made JSON on dev.gramene.org
// whose Last-Modified was 2024-10-10 and which held 158 entries, while the sheet grew to 1,221 rows
// -- 1,013 of them submitted in 2026. The site has been soliciting curation and then discarding it.
// No generator for that JSON existed anywhere, so this is it, and the output is a tracked in-tree
// artifact: staleness becomes visible in git rather than in an HTTP header, and the build stops
// depending on a host we do not control.
//
// The sheet is readable anonymously over the CSV export endpoint, so no credentials are involved.
//
// Output (stdout): the same JSON shape RAP-DB publishes, so curated_source.js handles both:
//   [{locus, gene_symbols, gene_names, references:{<pmid>:{description}}, po:[], to:[], go:[],
//     chebi:[], evidence:{<term>:<code>}, status}]
// Coverage and every rejected row go to stderr: unresolved ids are REPORTED, never silently dropped.
//
// Usage: MONGO_URI=... MONGO_DB=search70 node fetch_cshl_curation.js [--include-ai] [--no-ncbi]
'use strict';

const path = require('path');
const fs = require('fs');

const MONGO_LIB = process.env.MONGO_LIB
  || path.resolve(__dirname, '..', 'gramene-mongodb', 'node_modules', 'mongodb');
const { MongoClient } = require(MONGO_LIB);

const MONGO_URI = process.env.MONGO_URI || 'mongodb://localhost:27017';
// Same reasoning as fetch_grassius.js: a literal default is dangerous because this script only
// READS, so the wrong database yields a plausible artifact keyed to another release's gene ids.
const MONGO_DB = process.env.MONGO_DB || (() => {
  try {
    return require(path.resolve(__dirname, '..', 'gramene-mongodb-config', 'collections.js'))
             .getMongoConfig().db;
  } catch (e) {
    console.error('MONGO_DB is unset and collections.js would not load: ' + e.message);
    process.exit(3);
  }
})();

const SHEET_ID = process.env.CURATION_SHEET_ID || '1-clhm1bgZW91cbYVd1iy-hye84GtBZ34QX4bXeEAOLw';
// Pin the tab. Without gid, a future tab reorder silently swaps the input for the "Valid Status"
// lookup table and the stage would cheerfully emit nothing.
const SHEET_GID = process.env.CURATION_SHEET_GID || '1571263491';
const SHEET_URL = `https://docs.google.com/spreadsheets/d/${SHEET_ID}/export?format=csv&gid=${SHEET_GID}`;

const SORGHUM_LUT = path.resolve(__dirname, '..', 'gramene-mongodb', 'search', 'sorghum_v5_lut.txt');
const INCLUDE_AI = process.argv.includes('--include-ai');

// Tracked beside the artifact it supports, so a rebuild resolves the same DOIs to the same PMIDs
// without asking NCBI, and so a new resolution shows up as a reviewable diff.
const PMID_CACHE = process.env.CURATION_PMID_CACHE
  || path.resolve(__dirname, '..', 'gramene-mongodb', 'search', 'curation_pmid_map.tsv');
// NCBI asks for an identifying address on E-utilities traffic; it is not used for anything else.
const NCBI_EMAIL = process.env.NCBI_EMAIL || 'gramene@gramene.org';
// Skips the NCBI lookups only -- the sheet fetch still needs the network, so this is not an
// offline mode. Use it to keep a build off E-utilities and accept whatever the cache holds.
const NO_NCBI = process.argv.includes('--no-ncbi');

// The form's columns, in order. Validated exactly: the owner adding one question shifts every
// column, and a shifted parse produces a plausible-looking artifact full of wrong data.
const EXPECTED_HEADER = [
  'Timestamp', 'Email Address', 'Gene ID', 'Describe gene function', 'Literature Reference',
  'Gene symbol used in publication', 'Gene name used in publication', 'Ontology terms',
  'Evidence code', 'Status', 'Reviewed by', 'Notes'
];
const C = {TS:0, EMAIL:1, ID:2, FUNC:3, REF:4, SYMBOL:5, NAME:6, ONT:7, EVID:8, STATUS:9, REVIEWER:10, NOTES:11};

// From the sheet's own "Valid Status" tab. Rejected is the only explicit veto. Blank means nobody
// has reviewed it yet, which is the normal state of 1,220 of the 1,221 rows -- filtering on Status
// would publish exactly one gene. AI (NLP-generated) is held back unless asked for.
const STATUS_EXCLUDE = {rejected: 1};
const STATUS_EXCLUDE_UNLESS_ASKED = {ai: 1};

const GO_EVIDENCE = {};
('EXP IDA IPI IMP IGI IEP HTP HDA HMP HGI HEP IBA IBD IKR IRD ISS ISO ISA ISM IGC RCA TAS NAS IC ND IEA')
  .split(' ').forEach(c => { GO_EVIDENCE[c] = 1; });

// The ontologies this build actually hosts. ancestor_adder.js loads LUTs for GO/PO/TO only
// (LUT_SOURCES = domains,GO,PO,TO,taxonomy), so a term from any other vocabulary has no hierarchy,
// no name and no ancestors to hang on: it is disregarded here rather than emitted. CHEBI used to be
// carried and fell through to a bare CHEBI__xrefs field -- an xref that looked like an annotation
// and was not one.
const ONT_PREFIX = {GO: 'go', PO: 'po', TO: 'to'};

// --- RFC 4180 CSV, hand-rolled: the repo carries no CSV dependency. ----------------------------
function parseCsv(text) {
  const rows = [];
  let row = [], field = '', inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; }
        else inQuotes = false;
      } else field += ch;
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === ',') {
      row.push(field); field = '';
    } else if (ch === '\n') {
      row.push(field); field = ''; rows.push(row); row = [];
    } else if (ch !== '\r') {
      field += ch;
    }
  }
  if (field.length || row.length) { row.push(field); rows.push(row); }
  return rows.filter(r => r.length > 1 || (r[0] || '').trim());
}

function get(row, i) { return (row[i] === undefined ? '' : String(row[i])).trim(); }

function splitCodes(cell) {
  return cell.split(/[;,/|]+|\s+and\s+/).map(s => s.trim().toUpperCase()).filter(Boolean);
}

function parseOntologyTerms(cell) {
  const out = [];
  cell.split(/[;,]+/).forEach(raw => {
    const t = raw.trim();
    if (!t) return;
    // Accept GO_0008283 as well as GO:0008283; curators type both.
    const m = /^([A-Za-z]+)[:_]\s*([0-9]+)$/.exec(t);
    if (!m) { out.push({bad: t}); return; }
    const pfx = m[1].toUpperCase();
    // Well formed, but from a vocabulary we do not host. Disregarded like a typo, but counted apart
    // from one: nobody needs to go and correct it.
    if (!ONT_PREFIX[pfx]) { out.push({foreign: t, prefix: pfx}); return; }
    out.push({bucket: ONT_PREFIX[pfx], id: pfx + ':' + m[2]});
  });
  return out;
}

// Parse the "Literature Reference" cell into typed identifiers.
//
// THE BUG THIS REPLACES. The old implementation was a bare /\b\d{7,8}\b/ scan over the whole
// cell, which is wrong in both directions once curators start pasting DOIs -- and as of
// 2026-11-01 every new row does:
//   * "10.3389/fpls.2024.1430467" yielded PMID "1430467", a real 1992 paper about something
//     else. The curation was about to be filed against the wrong publication.
//   * "10.1038/srep28366" yielded nothing, so the description went in the bin: descriptions are
//     only ever stored under a reference key.
// So DOIs and PMC ids are matched FIRST and removed from the string before any bare-number scan,
// because both routinely contain a 7-8 digit run.
function parseReference(cell) {
  const out = {pmids: [], dois: [], pmcids: [], leftover: ''};
  if (!cell) return out;
  let work = ' ' + cell + ' ';

  // DOIs. The trailing-character class deliberately excludes sentence punctuation, and we also
  // peel a trailing .,;:)] because "see 10.1234/abc." is common.
  work = work.replace(/\b10\.\d{4,9}\/[^\s;,)\]"'<>]+/g, m => {
    out.dois.push(m.replace(/[.,;:)\]]+$/, ''));
    return ' ';
  });
  // PMC ids: PMC11234113 carries an 8-digit run.
  work = work.replace(/\bPMC\d{5,9}\b/gi, m => { out.pmcids.push(m.toUpperCase()); return ' '; });
  // Explicitly labelled PMIDs win over anything else left in the cell.
  work = work.replace(/\bPM(?:ID|\.?\s?ID)\s*[:#]?\s*(\d{4,8})\b/gi, (m, d) => {
    out.pmids.push(d); return ' ';
  });
  // Whatever bare 7-8 digit runs survive. Still a heuristic, but now it cannot see a DOI suffix.
  (work.match(/\b\d{7,8}\b/g) || []).forEach(d => out.pmids.push(d));

  out.pmids = Array.from(new Set(out.pmids));
  out.dois = Array.from(new Set(out.dois.map(d => d.toLowerCase())));
  out.pmcids = Array.from(new Set(out.pmcids));
  out.leftover = work.replace(/\s+/g, ' ').trim();
  return out;
}

// --- DOI/PMCID -> PMID, through a committed cache ----------------------------------------------
// The cache is a tracked artifact for the same reason cshl_curated_genes.json is: the build must be
// reproducible and must not depend on NCBI answering. A negative result is cached too (pmid "-"),
// otherwise every build re-asks NCBI about the same handful of unresolvable DOIs forever.
function loadPmidCache() {
  const m = new Map();
  let text;
  try { text = fs.readFileSync(PMID_CACHE, 'utf8'); }
  catch (e) { return m; }
  text.split('\n').forEach(line => {
    if (!line || line[0] === '#') return;
    const f = line.split('\t');
    if (f[0]) m.set(f[0].trim().toLowerCase(), {pmid: (f[1] || '').trim(), when: f[2] || '', how: f[3] || ''});
  });
  return m;
}

function savePmidCache(cache) {
  const keys = Array.from(cache.keys()).sort();
  const body = ['# key\tpmid\tresolved\tmethod   (pmid "-" = looked up and not found; do not re-query)']
    .concat(keys.map(k => {
      const v = cache.get(k);
      return [k, v.pmid || '-', v.when, v.how].join('\t');
    })).join('\n') + '\n';
  fs.writeFileSync(PMID_CACHE, body);
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// NCBI's PMC id converter takes up to 200 ids per request and answers for anything in PMC.
async function idconvBatch(ids) {
  const url = 'https://pmc.ncbi.nlm.nih.gov/tools/idconv/api/v1/articles/?format=json'
            + '&tool=gramene&email=' + encodeURIComponent(NCBI_EMAIL)
            + '&ids=' + ids.map(encodeURIComponent).join(',');
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 60000);
  try {
    const res = await fetch(url, {signal: ctrl.signal, redirect: 'follow'});
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const body = await res.json();
    const found = new Map();
    (body.records || []).forEach(r => {
      const key = String(r['requested-id'] || r.doi || r.pmcid || '').toLowerCase();
      if (key && r.pmid) found.set(key, String(r.pmid));
    });
    return found;
  } finally { clearTimeout(timer); }
}

// Fallback for a DOI that is not in PMC: ask PubMed directly. One id per call, so this is the
// throttled path and runs only on idconv's misses.
async function esearchDoi(doi) {
  const url = 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&retmode=json'
            + '&tool=gramene&email=' + encodeURIComponent(NCBI_EMAIL)
            + '&term=' + encodeURIComponent(doi + '[DOI]');
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 30000);
  try {
    const res = await fetch(url, {signal: ctrl.signal});
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const body = await res.json();
    const list = (body.esearchresult && body.esearchresult.idlist) || [];
    // Only trust an unambiguous single hit. A DOI matching two PubMed records means something is
    // wrong with the DOI, and guessing which record the curator meant is not ours to do.
    return list.length === 1 ? String(list[0]) : '';
  } finally { clearTimeout(timer); }
}

async function resolveToPmids(keys, cache, stats) {
  const want = keys.filter(k => !cache.has(k));
  if (!want.length) return;
  if (NO_NCBI) {
    stats.offlineSkipped = want.length;
    console.error('--no-ncbi: ' + want.length + ' identifiers left unresolved (not in the cache)');
    return;
  }
  const stamp = new Date().toISOString().slice(0, 10);
  console.error('resolving ' + want.length + ' identifiers via NCBI...');

  for (let i = 0; i < want.length; i += 200) {
    const batch = want.slice(i, i + 200);
    let found = new Map();
    try { found = await idconvBatch(batch); }
    catch (e) { console.error('  idconv batch failed (' + e.message + ') -- falling back per id'); }
    batch.forEach(k => {
      if (found.has(k)) { cache.set(k, {pmid: found.get(k), when: stamp, how: 'idconv'}); }
    });
    if (i + 200 < want.length) await sleep(400);
  }

  const stillMissing = want.filter(k => !cache.has(k));
  for (const k of stillMissing) {
    if (!/^10\./.test(k)) { cache.set(k, {pmid: '-', when: stamp, how: 'idconv-miss'}); continue; }
    let pmid = '';
    try { pmid = await esearchDoi(k); }
    catch (e) { console.error('  esearch failed for ' + k + ': ' + e.message); }
    cache.set(k, {pmid: pmid || '-', when: stamp, how: pmid ? 'esearch' : 'notfound'});
    await sleep(350);                      // NCBI allows 3 requests/second without an API key
  }
}

// Is this "description" actually a description, or did the curator put the symbol in the wrong
// column? The sheet has rows whose entire gene-function cell is "Dw1". Storing that as the
// description of a paper is worse than storing nothing, because it displaces the real text when
// another row supplies it.
// The test is identity with the gene's OWN name forms, NOT length. A first attempt here also
// rejected anything under 20 characters, which threw away 335 descriptions including "Zn
// transferase", "Phospholipase 1" and "starch synthase" -- short, but real content that the
// Curated publications tab displays today. Short text is handled by PREFERRING a longer
// description when two rows describe the same reference, not by discarding the short one.
function descriptionIsSubstantive(text, junkForms) {
  if (!text) return false;
  const norm = String(text).toLowerCase().replace(/[^a-z0-9]+/g, '');
  if (!norm) return false;
  return !junkForms.has(norm);
}

// Curators paste whatever identifier is in front of them, and a large share of the sheet's ids are
// TRANSCRIPT or PROTEIN ids rather than gene ids: SORBI_3001G320200.1, SORBI_3002G021900.2,
// Sobic.001G025700.1.p, SORBI_3001G208500.1.v2.1, Sobic.006G175700.v5.1. Peel the suffixes and try
// the shorter forms too. Over-generating is safe because every candidate is validated against the
// collection before use -- a nonsense candidate simply matches nothing -- and candidates are tried
// most-specific first so an exact hit always wins.
function idCandidates(raw) {
  var out = [raw], s = raw, t;
  t = s.replace(/\.p$/i, '');                      if (t !== s) { out.push(t); s = t; }
  t = s.replace(/\.v[0-9]+(\.[0-9]+)*$/i, '');      if (t !== s) { out.push(t); s = t; }
  t = s.replace(/\.[0-9]+$/, '');                   if (t !== s) { out.push(t); s = t; }
  return out.filter(function (v, i) { return v && out.indexOf(v) === i; });
}

function loadSorghumLut() {
  // col0 ensembl SORBI_3*, col1 phytozome Sobic.*, col2 v1 Sb##g*. fix_sorghum_v2.js reads this
  // forward; we need it backwards.
  const rev = new Map();
  let lines;
  try { lines = fs.readFileSync(SORGHUM_LUT, 'utf8').split('\n'); }
  catch (e) { console.error('WARNING cannot read ' + SORGHUM_LUT + ': ' + e.message); return rev; }
  for (const line of lines) {
    if (!line) continue;
    const f = line.split('\t');
    if (!f[0]) continue;
    for (const alt of [f[1], f[2]]) {
      if (alt && alt !== '-') rev.set(alt, f[0]);
    }
  }
  return rev;
}

(async () => {
  console.error('fetching ' + SHEET_URL);
  const res = await fetch(SHEET_URL, {redirect: 'follow'});
  if (!res.ok) { console.error('sheet fetch failed: HTTP ' + res.status); process.exit(4); }
  const rows = parseCsv(await res.text());
  if (!rows.length) { console.error('sheet is empty'); process.exit(4); }

  const header = rows[0].map(h => h.trim());
  const mismatch = EXPECTED_HEADER.length !== header.length
    || EXPECTED_HEADER.some((h, i) => h !== header[i]);
  if (mismatch) {
    console.error('SHEET HEADER CHANGED -- refusing to parse, because a shifted column set produces');
    console.error('a plausible artifact full of wrong data. Update EXPECTED_HEADER deliberately.');
    console.error('  expected: ' + JSON.stringify(EXPECTED_HEADER));
    console.error('  found   : ' + JSON.stringify(header));
    process.exit(5);
  }
  const data = rows.slice(1);
  console.error('sheet rows: ' + data.length);

  // --- pass 1: parse and bucket rows by the id as written -----------------------------------
  const byRawId = new Map();
  const stats = {noId: 0, trimmed: 0, excludedStatus: {}, badTerms: [], badCodes: {},
                 refKeys: 0, doiResolved: 0, pmcResolved: 0, doiUnresolved: [], noRefId: [],
                 junkDescriptions: [], descUpgrades: 0, offlineSkipped: 0,
                 foreignTerms: [], foreignByPrefix: {}, unpairable: []};
  for (const row of data) {
    const rawId = get(row, C.ID);
    if (!rawId) { stats.noId++; continue; }
    if (row[C.ID] !== rawId) stats.trimmed++;

    const status = get(row, C.STATUS).toLowerCase();
    if (STATUS_EXCLUDE[status] || (!INCLUDE_AI && STATUS_EXCLUDE_UNLESS_ASKED[status])) {
      stats.excludedStatus[status] = (stats.excludedStatus[status] || 0) + 1;
      continue;
    }

    if (!byRawId.has(rawId)) byRawId.set(rawId, []);
    byRawId.get(rawId).push(row);
  }
  console.error('distinct ids as written: ' + byRawId.size);

  // --- pass 2: resolve ids to this build's gene ids ------------------------------------------
  const client = new MongoClient(MONGO_URI, {useNewUrlParser: true, useUnifiedTopology: true});
  await client.connect();
  const genes = client.db(MONGO_DB).collection('genes');

  const rawIds = Array.from(byRawId.keys());
  const resolved = new Map();          // raw id -> gene _id
  const cands = new Map();             // raw id -> ordered candidate list
  rawIds.forEach(id => cands.set(id, idCandidates(id)));

  // Pass A: any candidate that is itself a gene _id. Most specific candidate wins.
  const allCands = Array.from(new Set([].concat.apply([], Array.from(cands.values()))));
  const direct = new Set((await genes.find({_id: {$in: allCands}}, {projection: {_id: 1}})
                            .toArray()).map(d => d._id));
  let viaSuffix = 0;
  for (const id of rawIds) {
    const hit = cands.get(id).find(c => direct.has(c));
    if (hit) { resolved.set(id, hit); if (hit !== id) viaSuffix++; }
  }
  console.error('resolved by _id: ' + resolved.size +
                ' (' + viaSuffix + ' of them after stripping a transcript/protein suffix)');

  // Pass B: legacy sorghum namespaces, via the crosswalk fix_sorghum_v2.js already reads forward.
  const lut = loadSorghumLut();
  const viaLut = [];
  for (const id of rawIds) {
    if (resolved.has(id)) continue;
    for (const c of cands.get(id)) {
      const mapped = lut.get(c);
      if (mapped) { viaLut.push([id, mapped]); break; }
    }
  }
  if (viaLut.length) {
    const targets = Array.from(new Set(viaLut.map(p => p[1])));
    const found = new Set((await genes.find({_id: {$in: targets}}, {projection: {_id: 1}})
                            .toArray()).map(d => d._id));
    let n = 0;
    viaLut.forEach(([raw, mapped]) => {
      if (found.has(mapped) && !resolved.has(raw)) { resolved.set(raw, mapped); n++; }
    });
    console.error('resolved via sorghum_v5_lut.txt: ' + n + ' of ' + viaLut.length + ' candidates');
  }

  // Pass C: whatever is left, against alt_id, which carries every legacy namespace this build knows
  // (34,118 sorghum Sobic./Sb ids, 33,938 rice MSU ids, 38,137 maize v4/pan ids). There is no index
  // on alt_id, so this is one collection scan -- acceptable in a stage outside `make all`, and it is
  // why this pass runs last on the smallest possible id set.
  const stillMissing = rawIds.filter(id => !resolved.has(id));
  if (stillMissing.length) {
    const probe = Array.from(new Set([].concat.apply([],
      stillMissing.map(id => cands.get(id)))));
    console.error('scanning alt_id for ' + stillMissing.length + ' remaining ids (' +
                  probe.length + ' candidates)...');
    const hits = await genes.find({alt_id: {$in: probe}}, {projection: {_id: 1, alt_id: 1}})
                            .toArray();
    const altTo = new Map();
    hits.forEach(d => (d.alt_id || []).forEach(a => { if (!altTo.has(a)) altTo.set(a, d._id); }));
    let n = 0;
    stillMissing.forEach(id => {
      const hit = cands.get(id).find(c => altTo.has(c));
      if (hit) { resolved.set(id, altTo.get(hit)); n++; }
    });
    console.error('resolved via alt_id: ' + n);
  }

  // Pass D: sorghum v5 ids, which belong to SorghumBase rather than to this build. The curation
  // form is shared between the two sites; SorghumBase hosts Sorghum bicolor v5, and the only sorghum
  // genome here is v3 (SORBI_3*, GCA_000003195.3, taxon 4558001), so a v5 id has no gene in this
  // collection and none of the three passes above can place it. Phytozome kept the `Sobic.`
  // namespace across v3.1 and v5.1 with identical numbering, so the v3 counterpart of Sobic.00NGnnnnnn
  // is SORBI_300NGnnnnnn -- a straight prefix swap.
  //
  // Deliberately last, and deliberately not folded into the crosswalk. This is arithmetic on an id
  // string, not a verified correspondence: it asserts that the two annotations gave the same locus
  // the same number, which is true of the shared namespace but is not something this build checks.
  // So it runs only on ids the crosswalk (sorghum_v5_lut.txt, 22,841 of sorghum's 35,567 genes) and
  // alt_id both failed to place, the SORBI_3 target must exist as a gene before it is accepted, and
  // every id it claims is listed in the report rather than merged in silently.
  const viaV5 = [];
  const beforeV5 = rawIds.filter(id => !resolved.has(id));
  if (beforeV5.length) {
    const guesses = new Map();
    for (const id of beforeV5) {
      const c = cands.get(id).find(x => /^Sobic\./.test(x));
      if (c) guesses.set(id, c.replace(/^Sobic\./, 'SORBI_3'));
    }
    if (guesses.size) {
      const targets = Array.from(new Set(guesses.values()));
      const found = new Set((await genes.find({_id: {$in: targets}}, {projection: {_id: 1}})
                              .toArray()).map(d => d._id));
      guesses.forEach((target, raw) => {
        if (found.has(target)) { resolved.set(raw, target); viaV5.push([raw, target]); }
      });
    }
    console.error('resolved as sorghum v5 -> v3 (Sobic. -> SORBI_3): ' + viaV5.length +
                  ' of ' + guesses.size + ' Sobic.* ids still unplaced');
  }

  await client.close();

  // --- pass 2b: standardize every literature reference onto a PMID ---------------------------
  // Done for the whole sheet at once, before any per-gene work, so NCBI is asked once per distinct
  // identifier rather than once per citing row -- 18 of the new rows cite only 16 distinct DOIs,
  // and three different genes cite 10.3389/fpls.2024.1430467.
  const refByRow = new Map();          // row -> parseReference() result
  const needResolving = new Set();
  for (const rowsForId of byRawId.values()) {
    for (const row of rowsForId) {
      const r = parseReference(get(row, C.REF));
      refByRow.set(row, r);
      r.dois.forEach(d => needResolving.add(d));
      r.pmcids.forEach(c => needResolving.add(c.toLowerCase()));
    }
  }
  const pmidCache = loadPmidCache();
  const cacheSizeBefore = pmidCache.size;
  stats.refKeys = needResolving.size;
  await resolveToPmids(Array.from(needResolving).sort(), pmidCache, stats);
  if (pmidCache.size !== cacheSizeBefore) {
    savePmidCache(pmidCache);
    console.error('pmid cache: ' + cacheSizeBefore + ' -> ' + pmidCache.size + ' entries, wrote ' +
                  PMID_CACHE);
  }
  const toPmid = k => {
    const v = pmidCache.get(String(k).toLowerCase());
    return v && v.pmid && v.pmid !== '-' ? v.pmid : '';
  };

  // --- pass 3: emit one entry per resolved gene ----------------------------------------------
  const entries = new Map();           // gene _id -> entry
  const rejects = [];
  for (const [rawId, rowsForId] of byRawId) {
    const geneId = resolved.get(rawId);
    if (!geneId) { rejects.push(rawId); continue; }

    if (!entries.has(geneId)) {
      entries.set(geneId, {
        locus: geneId, symbolByNorm: new Map(), nameByNorm: new Map(), refs: new Map(),
        po: [], to: [], go: [], evidence: {}, status: []
      });
    }
    const e = entries.get(geneId);

    for (const row of rowsForId) {
      // Forms of this gene's own identity, normalized. Used to reject a "symbol" that is just the
      // id, and a "description" that is just the symbol.
      const junk = new Set([rawId, geneId].map(v => v.toLowerCase().replace(/[^a-z0-9]+/g, '')));

      const sym = get(row, C.SYMBOL);
      const symNorm = sym.toLowerCase().replace(/[^a-z0-9]+/g, '');
      // Dedupe symbols case-insensitively, keeping the first spelling seen. The sheet carries both
      // "Dw1" and "dw1" for the same gene, and emitting both makes the second a bogus synonym.
      if (sym && !junk.has(symNorm) && !e.symbolByNorm.has(symNorm)) {
        e.symbolByNorm.set(symNorm, sym);
      }
      if (symNorm) junk.add(symNorm);

      const nm = get(row, C.NAME);
      const nmNorm = nm.toLowerCase().replace(/[^a-z0-9]+/g, '');
      if (nm && !junk.has(nmNorm) && !e.nameByNorm.has(nmNorm)) e.nameByNorm.set(nmNorm, nm);
      if (nmNorm) junk.add(nmNorm);

      // Columns H and I are parallel comma-separated lists: the curators' convention is that
      // term[i] is supported by code[i]. Measured over all 96 rows that carry a term, exactly three
      // shapes occur and every one is unambiguous, so nothing here has to guess:
      //   n terms x n codes   pair positionally -- 2 rows, both written "IMP,IMP", which is only
      //                       worth typing if correspondence is what is meant
      //   n terms x 1 code    the single code supports every term (8 rows)
      //   1 term  x m codes   the term has m independent lines of evidence (41 rows)
      // No row has >1 term AND >1 code with counts that differ. If one ever appears it is reported
      // and its codes dropped, because a cross product would invent evidence nobody asserted.
      //
      // Codes are validated AFTER pairing, never before. Filtering first renumbers the list --
      // "IPP, IEP" collapses to ["IEP"] -- and a two-term row would then take IEP for its first
      // term, silently attaching the wrong evidence to the wrong term.
      const rawCodes = splitCodes(get(row, C.EVID));
      const parsedTerms = parseOntologyTerms(get(row, C.ONT));
      const goodTerms = parsedTerms.filter(t => t.bucket);
      parsedTerms.forEach(t => {
        if (t.bad) stats.badTerms.push(rawId + ': ' + t.bad);
        else if (t.foreign) {
          stats.foreignTerms.push(rawId + ': ' + t.foreign);
          stats.foreignByPrefix[t.prefix] = (stats.foreignByPrefix[t.prefix] || 0) + 1;
        }
      });

      let pairs;
      if (goodTerms.length === 0) {
        // Check the codes anyway, so a junk evidence cell is still reported when the term it went
        // with was the thing that got dropped.
        rawCodes.forEach(c => {
          if (!GO_EVIDENCE[c]) stats.badCodes[c] = (stats.badCodes[c] || 0) + 1;
        });
        pairs = [];
      } else if (rawCodes.length === 0) {
        pairs = goodTerms.map(t => [t, null]);
      } else if (goodTerms.length === rawCodes.length) {
        pairs = goodTerms.map((t, i) => [t, rawCodes[i]]);
      } else if (rawCodes.length === 1) {
        pairs = goodTerms.map(t => [t, rawCodes[0]]);
      } else if (goodTerms.length === 1) {
        pairs = rawCodes.map(c => [goodTerms[0], c]);
      } else {
        stats.unpairable.push(rawId + ': ' + goodTerms.length + ' terms vs ' + rawCodes.length +
                              ' codes -- ' + JSON.stringify(get(row, C.ONT)) + ' / ' +
                              JSON.stringify(get(row, C.EVID)));
        pairs = goodTerms.map(t => [t, null]);
      }

      pairs.forEach(pair => {
        const t = pair[0], code = pair[1];
        if (e[t.bucket].indexOf(t.id) < 0) e[t.bucket].push(t.id);
        if (!code) return;
        if (!GO_EVIDENCE[code]) { stats.badCodes[code] = (stats.badCodes[code] || 0) + 1; return; }
        // An ARRAY per term, in the order the curator typed them. The gene doc has room for only
        // one code per term -- ancestor_adder.js keys usefulInfo by the term's integer id and
        // assigns evidence_code, so a second pair for the same term just overwrites the first -- so
        // curated_source.js narrows this to the first code. Keeping the whole list here means the
        // artifact does not quietly discard what the curator wrote, and the day the gene doc grows
        // a second slot the data is already there.
        const have = e.evidence[t.id] || (e.evidence[t.id] = []);
        if (have.indexOf(code) < 0) have.push(code);
      });

      // Build this row's reference keys. A DOI that resolves becomes its PMID, which is what
      // collapses "cited as a DOI here, as a PMID there" into one reference on the gene.
      const parsed = refByRow.get(row) || {pmids: [], dois: [], pmcids: []};
      const keys = [];
      parsed.pmids.forEach(p => keys.push({key: p, via: 'pmid'}));
      parsed.dois.forEach(d => {
        const p = toPmid(d);
        if (p) { keys.push({key: p, via: 'doi->pmid'}); stats.doiResolved++; }
        // Unresolvable: keep it as a DOI rather than discard the curation. curated_source.js
        // already routes a "DOI:"-prefixed key to a DOI xref, so this needs no consumer change.
        else { keys.push({key: 'DOI:' + d, via: 'doi'}); stats.doiUnresolved.push(rawId + ': ' + d); }
      });
      parsed.pmcids.forEach(c => {
        const p = toPmid(c);
        if (p) { keys.push({key: p, via: 'pmcid->pmid'}); stats.pmcResolved++; }
      });
      if (!keys.length && get(row, C.REF)) {
        stats.noRefId.push(rawId + ': ' + get(row, C.REF).slice(0, 70));
      }

      const desc = get(row, C.FUNC);
      const good = descriptionIsSubstantive(desc, junk);
      if (desc && !good) stats.junkDescriptions.push(rawId + ': ' + JSON.stringify(desc.slice(0, 40)));

      keys.forEach(({key, via}) => {
        const prev = e.refs.get(key);
        // Several rows can cite one paper for one gene. Prefer a substantive description over a
        // junk one, and the longer of two substantive ones -- the sheet's older rows often hold
        // only the symbol where a newer row has the real sentence. NOTE: the submitter's email is
        // deliberately NOT carried through; this artifact is committed and served publicly.
        if (!prev) {
          e.refs.set(key, {description: good ? desc : '', via: via, merged: 1});
        } else {
          prev.merged++;
          if (good && (!prev.description || desc.length > prev.description.length)) {
            if (prev.description) stats.descUpgrades++;
            prev.description = desc;
          }
        }
      });

      const st = get(row, C.STATUS);
      if (st && e.status.indexOf(st) < 0) e.status.push(st);
    }
  }

  const out = Array.from(entries.values()).map(e => {
    const symbols = Array.from(e.symbolByNorm.values());
    const names = Array.from(e.nameByNorm.values());
    const references = {};
    // Sort reference keys so the artifact is byte-stable across runs: an unstable key order makes
    // every regeneration look like a change in git and defeats the incremental diff.
    Array.from(e.refs.keys()).sort().forEach(k => { references[k] = {description: e.refs.get(k).description}; });
    return {
      locus: e.locus,
      // NOTE: `gene_names` is emitted but read by nothing -- curated_source.js only ever looks at
      // gene_symbols -- so the sheet's "Gene name used in publication" column (65 rows) is carried
      // here and goes no further. Folding it into gene_symbols was tried and backed out: it turns
      // published product names into searchable synonyms on 67 loci, and because curated_source.js
      // promotes the first symbol to gene.name for any gene still named after its own id, it would
      // also title genes things like "Zn-regulated GTPase metalloprotein activator". Whether those
      // belong as synonyms is a curation decision, not a parsing one.
      gene_symbols: symbols.join(', '),
      gene_names: names.join(', '),
      references: references,
      po: e.po.slice().sort(), to: e.to.slice().sort(),
      go: e.go.slice().sort(),
      evidence: e.evidence,
      status: e.status.join(', ')
    };
  }).sort((a, b) => (a.locus < b.locus ? -1 : a.locus > b.locus ? 1 : 0));

  // --- coverage report ------------------------------------------------------------------------
  const refCount = out.reduce((n, e) => n + Object.keys(e.references).length, 0);
  const termCount = out.reduce((n, e) => n + e.po.length + e.to.length + e.go.length, 0);
  console.error('');
  console.error('=== coverage ===');
  console.error('  rows parsed                : ' + data.length);
  console.error('  rows with no gene id       : ' + stats.noId);
  console.error('  ids needing whitespace trim: ' + stats.trimmed);
  console.error('  rows excluded by status    : ' + JSON.stringify(stats.excludedStatus));
  console.error('  distinct ids as written    : ' + byRawId.size);
  console.error('  RESOLVED to a gene         : ' + entries.size);
  console.error('  UNRESOLVED (reported below): ' + rejects.length);
  console.error('  references emitted         : ' + refCount);
  console.error('  ontology terms emitted     : ' + termCount);
  console.error('');
  console.error('=== literature references ===');
  console.error('  distinct DOI/PMC ids seen  : ' + stats.refKeys);
  console.error('  DOI citations -> a PMID    : ' + stats.doiResolved + ' (rows, not distinct ids)');
  console.error('  PMC citations -> a PMID    : ' + stats.pmcResolved);
  console.error('  DOI citations kept as DOI  : ' + stats.doiUnresolved.length);
  stats.doiUnresolved.slice(0, 15).forEach(d => console.error('     ' + d));
  if (stats.offlineSkipped) {
    console.error('  NOT resolved (--no-ncbi)   : ' + stats.offlineSkipped +
                  '  <-- rerun without --no-ncbi to standardize these');
  }
  if (stats.noRefId.length) {
    console.error('  reference cells with no usable identifier: ' + stats.noRefId.length);
    stats.noRefId.slice(0, 10).forEach(d => console.error('     ' + d));
  }
  if (stats.junkDescriptions.length) {
    console.error('  "descriptions" rejected as not a description: ' + stats.junkDescriptions.length);
    console.error('    (the gene symbol or id typed into the function column)');
    stats.junkDescriptions.slice(0, 15).forEach(d => console.error('     ' + d));
  }
  if (stats.descUpgrades) {
    console.error('  references whose description was replaced by a better one: ' + stats.descUpgrades);
  }
  if (Object.keys(stats.badCodes).length) {
    console.error('  evidence codes not in the GO set (left for the curators, not rewritten):');
    Object.keys(stats.badCodes).sort().forEach(c =>
      console.error('     ' + c + ' x' + stats.badCodes[c]));
  }
  if (stats.badTerms.length) {
    console.error('  unparseable ontology terms: ' + stats.badTerms.length);
    stats.badTerms.slice(0, 20).forEach(t => console.error('     ' + t));
  }
  if (stats.foreignTerms.length) {
    console.error('  terms disregarded -- not a hosted ontology (' +
                  Object.keys(stats.foreignByPrefix).sort()
                    .map(k => k + ' x' + stats.foreignByPrefix[k]).join(', ') +
                  '); only GO/PO/TO have a LUT:');
    stats.foreignTerms.forEach(t => console.error('     ' + t));
  }
  if (stats.unpairable.length) {
    console.error('  rows where terms and codes could not be paired (codes dropped, NOT guessed):');
    stats.unpairable.forEach(t => console.error('     ' + t));
  }
  if (viaV5.length) {
    console.error('');
    console.error('=== sorghum v5 -> v3 remaps (SorghumBase ids, assigned to the v3 locus) ===');
    viaV5.sort().forEach(([raw, target]) => console.error('     ' + raw + '  ->  ' + target));
  }
  console.error('');
  console.error('=== gene ids that could not be mapped to a gene_id ===');
  if (rejects.length) {
    rejects.sort().forEach(r => console.error('     ' + r));
    console.error('  (' + rejects.length + ' of ' + byRawId.size + ' distinct ids)');
  } else {
    console.error('     none -- every distinct id in the sheet resolved');
  }

  process.stdout.write(JSON.stringify(out, null, 1) + '\n');
})().catch(e => { console.error('ERR ' + (e && e.stack || e)); process.exit(1); });
