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
// Usage: MONGO_URI=... MONGO_DB=search70 node fetch_cshl_curation.js [--include-ai]
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

const ONT_PREFIX = {GO: 'go', PO: 'po', TO: 'to', CHEBI: 'chebi'};

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
    if (!ONT_PREFIX[pfx]) { out.push({bad: t}); return; }
    out.push({bucket: ONT_PREFIX[pfx], id: pfx + ':' + m[2]});
  });
  return out;
}

function extractPmids(cell) {
  const ids = (cell.match(/\b\d{7,8}\b/g) || []);
  return Array.from(new Set(ids));
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
  const stats = {noId: 0, trimmed: 0, excludedStatus: {}, badTerms: [], badCodes: {}, noPmid: 0};
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

  await client.close();

  // --- pass 3: emit one entry per resolved gene ----------------------------------------------
  const entries = new Map();           // gene _id -> entry
  const rejects = [];
  for (const [rawId, rowsForId] of byRawId) {
    const geneId = resolved.get(rawId);
    if (!geneId) { rejects.push(rawId); continue; }

    if (!entries.has(geneId)) {
      entries.set(geneId, {
        locus: geneId, gene_symbols: [], gene_names: [], references: {},
        po: [], to: [], go: [], chebi: [], evidence: {}, status: []
      });
    }
    const e = entries.get(geneId);

    for (const row of rowsForId) {
      const sym = get(row, C.SYMBOL);
      // A "symbol" that is just the gene id carries no information; the sheet has several.
      if (sym && sym !== rawId && sym !== geneId) e.gene_symbols.push(sym);
      const nm = get(row, C.NAME);
      if (nm) e.gene_names.push(nm);

      const codes = splitCodes(get(row, C.EVID)).filter(c => {
        if (GO_EVIDENCE[c]) return true;
        stats.badCodes[c] = (stats.badCodes[c] || 0) + 1;
        return false;
      });
      // The sheet gives no term-to-code pairing when a row has several of each, so the row's first
      // valid code applies to that row's terms. Inventing a pairing would be worse than this.
      const rowCode = codes[0];

      parseOntologyTerms(get(row, C.ONT)).forEach(t => {
        if (t.bad) { stats.badTerms.push(rawId + ': ' + t.bad); return; }
        if (e[t.bucket].indexOf(t.id) < 0) e[t.bucket].push(t.id);
        if (rowCode && !e.evidence[t.id]) e.evidence[t.id] = rowCode;
      });

      const pmids = extractPmids(get(row, C.REF));
      if (!pmids.length && get(row, C.REF)) stats.noPmid++;
      const desc = get(row, C.FUNC);
      pmids.forEach(p => {
        // One description per PMID; the first row to cite it wins. NOTE: the submitter's email is
        // deliberately NOT carried through -- this artifact is committed and served publicly.
        if (!e.references[p]) e.references[p] = {description: desc};
      });

      const st = get(row, C.STATUS);
      if (st && e.status.indexOf(st) < 0) e.status.push(st);
    }
  }

  const out = Array.from(entries.values()).map(e => ({
    locus: e.locus,
    gene_symbols: Array.from(new Set(e.gene_symbols)).join(', '),
    gene_names: Array.from(new Set(e.gene_names)).join(', '),
    references: e.references,
    po: e.po, to: e.to, go: e.go, chebi: e.chebi,
    evidence: e.evidence,
    status: e.status.join(', ')
  })).sort((a, b) => (a.locus < b.locus ? -1 : a.locus > b.locus ? 1 : 0));

  // --- coverage report ------------------------------------------------------------------------
  const refCount = out.reduce((n, e) => n + Object.keys(e.references).length, 0);
  const termCount = out.reduce((n, e) => n + e.po.length + e.to.length + e.go.length + e.chebi.length, 0);
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
  console.error('  references with no PMID    : ' + stats.noPmid);
  if (Object.keys(stats.badCodes).length) {
    console.error('  evidence codes not in the GO set (left for the curators, not rewritten):');
    Object.keys(stats.badCodes).sort().forEach(c =>
      console.error('     ' + c + ' x' + stats.badCodes[c]));
  }
  if (stats.badTerms.length) {
    console.error('  unparseable ontology terms: ' + stats.badTerms.length);
    stats.badTerms.slice(0, 20).forEach(t => console.error('     ' + t));
  }
  if (rejects.length) {
    console.error('  unresolved gene ids:');
    rejects.sort().forEach(r => console.error('     ' + r));
  }

  process.stdout.write(JSON.stringify(out, null, 1) + '\n');
})().catch(e => { console.error('ERR ' + (e && e.stack || e)); process.exit(1); });
