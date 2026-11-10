#!/usr/bin/env node
// fetch_reactome_literature.js — build the tracked artifact behind the PlantReactome publication
// xrefs: `{db:'PUBMED', source:'PlantReactome', text:<paper title>, ids:[<pmid>]}`.
//
// WHY THIS EXISTS. oryza9 serves those xrefs on 6,695 genes across 9 genomes and NOTHING in any
// of the five repos produces them: `PlantReactome` appears only in reactome/get_pathways.js,
// which emits pathway and reaction xrefs and no PUBMED at all, and `source` is a per-adder
// literal elsewhere (curated.js -> CSHL, rapdb.js -> RAP-DB). They were applied by hand, and the
// rebuilt oryza10 came out with zero. No other site has them either -- search70, search69,
// maize6, grapevine5 and sorghum11 are all 0 -- so there was no upstream to copy from.
//
// THE RULE, recovered from the data rather than guessed, and measured against oryza9:
//
//   gene id            column 1 of reactome/Ensembl2PlantReactomeReactions.txt, which
//                      25_reactome already downloads (and already appends the Osa and Zmy
//                      supplements to)
//     -> event         column 2, species prefix normalised to R-OSA-<n>; literature lives ONLY
//                      on the rice source events, and a projected event's `inferredFrom`
//                      points at the R-OSA event with the same numeric suffix (verified on
//                      R-ATH-3899351 -> R-OSA-3899351)
//     -> closure       that event PLUS ALL ITS ANCESTORS in the rice event hierarchy. This is
//                      the part that cannot be guessed: literature is curated at pathway level
//                      and inherited by the genes of every reaction beneath it. Os05g0400800
//                      carries pmid 16547652 in oryza9 while BOTH of its reactions
//                      (R-OSA-1120832, R-OSA-1121446) have no literature at all -- it comes
//                      from their ancestor R-OSA-1119509 "Histidine biosynthesis I".
//     -> literature    literatureReference[].pubMedIdentifier and .title
//
// Measured against oryza9's 6,695 genes: direct-event-only reproduces 24 of them exactly;
// event+immediate-parent 4,432; event+ALL-ancestors 6,268, covering 6,668 of the 6,695. The
// residual is Plant Reactome having grown since v9 was built (847 distinct pmids today against
// v9's 790), not a different rule.
//
// THERE IS NO GENOME FILTER, which also had to be measured: the rule yields 99,227 gene ids, of
// which only 6,831 are gene ids in this site at all. The join against `genes` is the filter, and
// it lands on exactly v9's 9 genomes with per-genome counts a few higher throughout
// (zea_maysb73v4 955 -> 970, oryza_sativa 910 -> 935, chlamydomonas 190 -> 191, ...).
//
// WHY NOT THE BULK FILE. download/current/ReactionPMIDS.txt looks like the obvious source and is
// a trap: 887 rows over 716 reactions, reaction-level only, so it has none of the pathway-level
// literature that nearly all of these xrefs actually come from. R-OSA-3899351's six references
// are absent from it.
//
// Output: reactome/reactome_literature.json, holding what the API said and nothing derived --
//   { fetched, service, species, literature: {event: [{pmid,title}]}, parents: {event:[ancestor]} }
// so the closure rule above stays visible in the adder instead of being baked into the artifact.
//
// usage: node fetch_reactome_literature.js [--api URL] [--out FILE]
'use strict';

const fs = require('fs');
const path = require('path');

// Hand-rolled rather than minimist: build/ has no node_modules of its own, and this script must
// run from a bare checkout before 05_install has done anything.
function arg(name, dflt) {
  const i = process.argv.indexOf('--' + name);
  return (i !== -1 && process.argv[i + 1]) ? process.argv[i + 1] : dflt;
}
const API = arg('api', process.env.PLANT_REACTOME_API || 'https://plantreactome.gramene.org/ContentService');
const OUT = arg('out', path.join(__dirname, '..', 'gramene-mongodb', 'reactome', 'reactome_literature.json'));
const OSA_TAXON = 4530;   // Oryza sativa, Plant Reactome's reference species

// The ids endpoint SILENTLY CAPS AT 20 RESULTS. A 200-id POST returns 200 OK with the first 20
// objects and no error, which on the first run here produced 74 events with literature instead of
// 820 -- a 90% loss that looked exactly like sparse curation. Batch at 20 and assert the count
// back, so a cap change cannot quietly halve the artifact again.
const BATCH = 20;

function fail(msg) { console.error('fetch_reactome_literature: ' + msg); process.exit(1); }

async function getJSON(url, init, what) {
  let lastErr;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await fetch(url, init);
      if (!res.ok) { throw new Error(`HTTP ${res.status}`); }
      return await res.json();
    } catch (e) {
      lastErr = e;
      if (attempt < 2) { await new Promise(r => setTimeout(r, 3000 * (attempt + 1))); }
    }
  }
  fail(`${what}: ${lastErr && lastErr.message}`);
}

(async function main() {
  console.error(`service: ${API}`);

  // 1) the whole rice event hierarchy in ONE call, so ancestors are computed locally instead of
  //    with ~2,400 /ancestors requests.
  const hierarchy = await getJSON(`${API}/data/eventsHierarchy/${OSA_TAXON}`, undefined, 'eventsHierarchy');
  if (!Array.isArray(hierarchy) || !hierarchy.length) { fail('empty event hierarchy'); }

  const parents = {};           // event -> every ancestor above it (an event can have several parents)
  const events = new Set();
  (function walk(nodes, chain) {
    nodes.forEach(function (n) {
      const id = n.stId;
      if (!id) { return; }
      events.add(id);
      if (chain.length) {
        const seen = parents[id] || (parents[id] = []);
        chain.forEach(p => { if (seen.indexOf(p) === -1) { seen.push(p); } });
      }
      if (n.children && n.children.length) { walk(n.children, chain.concat([id])); }
    });
  })(hierarchy, []);
  const ids = Array.from(events).sort();
  console.error(`events in the ${OSA_TAXON} hierarchy: ${ids.length}`);

  // 2) literature, 20 at a time, counted back every time.
  const literature = {};
  for (let i = 0; i < ids.length; i += BATCH) {
    const batch = ids.slice(i, i + BATCH);
    const docs = await getJSON(`${API}/data/query/ids`,
      { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: batch.join(',') },
      `query/ids at offset ${i}`);
    if (!Array.isArray(docs) || docs.length !== batch.length) {
      fail(`asked for ${batch.length} events at offset ${i} and got ${Array.isArray(docs) ? docs.length : typeof docs}.`
         + ` The ids endpoint caps its result set, so BATCH (${BATCH}) is now too large --`
         + ` lower it rather than accepting a short answer, which loses literature silently.`);
    }
    docs.forEach(function (e) {
      const refs = (e.literatureReference || [])
        .filter(r => r.pubMedIdentifier)
        .map(r => ({ pmid: String(r.pubMedIdentifier), title: r.title || null }));
      if (refs.length) { literature[e.stId] = refs; }
    });
    if (((i / BATCH) | 0) % 25 === 0) {
      console.error(`  ${i + batch.length}/${ids.length} events, ${Object.keys(literature).length} with literature`);
    }
  }

  const pmids = new Set();
  Object.keys(literature).forEach(k => literature[k].forEach(r => pmids.add(r.pmid)));
  console.error(`events with literature: ${Object.keys(literature).length}; distinct pmids: ${pmids.size}`);

  // A sanity floor rather than an exact count, since Plant Reactome grows: oryza9 was built from
  // 790 distinct pmids and today's service gives 847. Far below that means the fetch was short.
  if (pmids.size < 600) {
    fail(`only ${pmids.size} distinct pmids -- oryza9 was built from 790 and this service currently`
       + ` has ~847, so this fetch is short. Do NOT commit it over a good artifact.`);
  }

  const out = {
    fetched: new Date().toISOString(),
    service: API,
    species: OSA_TAXON,
    events: ids.length,
    literature: literature,
    parents: parents
  };
  fs.writeFileSync(OUT, JSON.stringify(out, null, 1) + '\n');
  console.error(`wrote ${OUT}`);
})();
