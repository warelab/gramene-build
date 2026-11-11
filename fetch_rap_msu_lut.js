#!/usr/bin/env node
// fetch_rap_msu_lut.js — rebuild search/OsNipp_IRGSP_MSU_lut.json, the rice RAP -> MSU/RGAP
// locus correspondence, from RAP-DB's own published file instead of the hand-made table that
// every subsite has been carrying.
//
// WHY THIS EXISTS. The tracked LUT (committed in b5d2a95, present in maize v6, sorghum
// v10/v10b/v11, grapevine v5, rice v8 and release70) is substantially wrong. Measured against
// RAP-DB's RAP-MSU.txt.gz:
//
//   * 1,738 of its 33,938 entries (5.1%) map a RAP id and an MSU id to DIFFERENT CHROMOSOMES.
//     Both schemes encode the chromosome -- Os01g... is chromosome 1, LOC_Os01g... is
//     chromosome 1 -- so these cannot be right. RAP-DB's own file has 0 such rows out of
//     33,651. Example: Os01g0105300 -> LOC_Os11g36790 (chr 11) where RAP-DB gives
//     LOC_Os01g01560; Os01g0110500 -> LOC_Os05g01040 where RAP-DB gives LOC_Os01g02040.
//   * 2,853 more carry the value of the PRECEDING row of RAP-DB's file where RAP-DB itself
//     says `None` (no correspondence) -- a fill-forward artifact of whatever join built it.
//     That is also why 5,549 MSU ids appear under more than one RAP gene.
//   * 5,548 real correspondences are missing entirely.
//
// WHAT RAP-DB PUBLISHES. One tab-separated file, RAP locus id -> comma-separated MSU
// TRANSCRIPT ids or the literal `None`:
//
//     Os01g0100100<TAB>LOC_Os01g01010.1,LOC_Os01g01010.2
//     Os01g0100300<TAB>None
//
// We strip the transcript suffix and de-duplicate, so one RAP locus can legitimately map to
// several MSU GENES (459 rows do). gene.alt_id is an array and holds them all; the old scalar
// LUT could not, which is one reason data was lost. msu6_adder.js accepts a string or an array.
//
// NB the host. rapdb.dna.affrc.go.jp is DEAD (it does not answer at all) -- the same trap
// documented in rapdb.js. naro.go.jp is the live host. There is no mirror for this file, so a
// fetch failure is fatal rather than silently producing a thinner LUT.
//
// TWO CLASSES RAP-DB CANNOT ADJUDICATE, both preserved from the existing LUT:
//   * 78 organellar `gene-*` keys (gene-atp1, gene-rps2, ...). Not RAP loci, so absent from the
//     file by construction. Kept verbatim.
//   * 76 RAP-style keys absent from the 2024-07 file. 71 are chromosome-consistent and kept;
//     the 5 that are chromosome-INCONSISTENT are dropped, being both demonstrably wrong and
//     unverifiable.

'use strict';
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const https = require('https');

const URL = 'https://rapdb.dna.naro.go.jp/download/archive/RAP-MSU.txt.gz';
const OUT = path.join(__dirname, '..', 'gramene-mongodb', 'search', 'OsNipp_IRGSP_MSU_lut.json');

function arg(name, dflt) {
  const i = process.argv.indexOf('--' + name);
  if (i < 0) return dflt;
  const v = process.argv[i + 1];
  return (v === undefined || v.slice(0, 2) === '--') ? true : v;
}
function fail(msg) { console.error('fetch_rap_msu_lut: ' + msg); process.exit(1); }
function log(msg) { console.error('fetch_rap_msu_lut: ' + msg); }

const RAP_CHR = /^Os(\d\d)g\d+$/;
const MSU_CHR = /^LOC_Os(\d\d)g\d+$/;

function get(url) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': 'gramene-build' } }, res => {
      if (res.statusCode === 301 || res.statusCode === 302) {
        res.resume(); return get(res.headers.location).then(resolve, reject);
      }
      if (res.statusCode !== 200) { res.resume(); return reject(new Error('HTTP ' + res.statusCode + ' for ' + url)); }
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks)));
      res.on('error', reject);
    }).on('error', reject);
  });
}

// one RAP row -> the de-duplicated list of MSU GENE ids it names
function msuGenes(field) {
  if (field === undefined || field === null) return [];
  const s = String(field).trim();
  if (s === '' || s === 'None') return [];
  const out = [];
  for (const tx of s.split(',')) {
    const t = tx.trim();
    if (!t || t === 'None') continue;
    const g = t.split('.')[0];
    if (out.indexOf(g) < 0) out.push(g);
  }
  return out;
}

(async function main() {
  const dry = !!arg('dry', false);

  let raw;
  try {
    log('fetching ' + URL);
    raw = zlib.gunzipSync(await get(URL)).toString('utf8');
  } catch (e) {
    fail('could not fetch/ungzip ' + URL + ': ' + e.message +
         '\n  There is no mirror for this file. Refusing to write a thinner LUT from a failed fetch.');
  }

  const rows = [];
  for (const line of raw.split('\n')) {
    if (!line) continue;
    const p = line.replace(/\r$/, '').split('\t');
    if (p.length < 2) continue;
    rows.push([p[0].trim(), p[1]]);
  }
  if (rows.length < 60000) fail('only ' + rows.length + ' rows parsed from RAP-MSU.txt.gz; expected ~68,845. Refusing.');

  // Column 1 is the literal `None` on 22,967 rows -- those are MSU loci with no RAP
  // counterpart, i.e. the reverse direction, and must not become a LUT key. `listed` is every
  // RAP id the file mentions AT ALL, which is what tells "RAP-DB says no correspondence"
  // (value `None`, so the legacy value must be DROPPED) apart from "RAP-DB does not list this
  // locus" (unadjudicated, so a chromosome-consistent legacy value may stand). Conflating
  // those two is what preserves the 2,853 fill-forward values this script exists to remove.
  const fromRapdb = {}, listed = new Set();
  let multi = 0;
  for (const [rapId, field] of rows) {
    if (!rapId || rapId === 'None' || !RAP_CHR.test(rapId)) continue;
    listed.add(rapId);
    const g = msuGenes(field);
    if (!g.length) continue;
    const prev = fromRapdb[rapId] || [];
    for (const x of g) if (prev.indexOf(x) < 0) prev.push(x);
    fromRapdb[rapId] = prev;
  }
  for (const k of Object.keys(fromRapdb)) if (fromRapdb[k].length > 1) multi++;
  const withId = Object.keys(fromRapdb).length;
  if (withId < 30000) fail('only ' + withId + ' RAP loci carry an MSU id; expected ~33,652. Refusing.');
  if (listed.size < 40000) fail('only ' + listed.size + ' RAP loci listed; expected ~45,878. Refusing.');

  // RAP-DB must be internally chromosome-consistent; if it is not, our parse is wrong.
  let bad = 0;
  for (const rapId of Object.keys(fromRapdb)) {
    const a = RAP_CHR.exec(rapId);
    if (!a) continue;
    for (const m of fromRapdb[rapId]) {
      const b = MSU_CHR.exec(m);
      if (b && b[1] !== a[1]) bad++;
    }
  }
  if (bad > 0) {
    fail(bad + ' RAP-DB rows disagree on chromosome after parsing. The real file has none, so the'
       + ' transcript-suffix stripping or the column split is wrong. Refusing to write.');
  }
  log(rows.length + ' rows -> ' + listed.size + ' RAP loci listed, ' + withId
      + ' with an MSU id (' + multi + ' mapping to >1 MSU gene), 0 chromosome disagreements');

  // carry forward only what RAP-DB cannot adjudicate
  let legacy = {};
  try { legacy = JSON.parse(fs.readFileSync(OUT, 'utf8')); }
  catch (e) { log('no existing LUT to carry organellar entries from (' + e.message + ')'); }

  const out = {};
  for (const k of Object.keys(fromRapdb)) out[k] = { MSU_id: fromRapdb[k].length === 1 ? fromRapdb[k][0] : fromRapdb[k] };

  let keptOrganellar = 0, keptUnlisted = 0, droppedUnlisted = 0, droppedNone = 0;
  for (const k of Object.keys(legacy)) {
    if (fromRapdb[k]) continue;                       // RAP-DB gave a correspondence: it wins
    const v = legacy[k] && legacy[k].MSU_id !== undefined ? legacy[k].MSU_id : legacy[k];
    if (typeof v !== 'string') continue;
    if (!RAP_CHR.test(k)) { out[k] = { MSU_id: v }; keptOrganellar++; continue; }
    if (listed.has(k)) { droppedNone++; continue; }   // RAP-DB lists it as `None`: no correspondence
    const a = RAP_CHR.exec(k), b = MSU_CHR.exec(v);
    if (a && b && a[1] === b[1]) { out[k] = { MSU_id: v }; keptUnlisted++; }
    else droppedUnlisted++;
  }
  log('carried forward ' + keptOrganellar + ' organellar gene-* entries and ' + keptUnlisted
      + ' chromosome-consistent RAP loci the file does not list; dropped ' + droppedNone
      + ' that RAP-DB lists as `None` (no correspondence) and ' + droppedUnlisted
      + ' that were chromosome-inconsistent AND unlisted');

  const n = Object.keys(out).length;
  log('LUT entries: ' + n);
  if (dry) { log('--dry: nothing written'); return; }
  fs.writeFileSync(OUT, JSON.stringify(out, null, 0) + '\n');
  log('wrote ' + OUT);
})().catch(e => fail(e.stack || e.message));
