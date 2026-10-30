#!/usr/bin/env node
// curated_dryrun.js — run ONLY the curated-gene adders over the stage-40 dumps and report what a
// re-decorate would change, without writing anything anywhere.
//
// This is the gate that decides whether a 5h30m decorate (plus the solr work behind it) is worth
// starting. Run it, read the table, fix the loaders, run it again -- all at zero rebuild cost.
//
// It is honest about scope: it runs the curated adders in pipe order but NOT the rest of decorate,
// so it tells you about name / synonyms / description / summary / xrefs / ontology terms, which is
// exactly what the curated sources touch, and nothing about homology, bins or pathways.
//
// Usage: MONGO_DB=search70 node curated_dryrun.js [system_name ...]
//   default: sorghum_bicolor zea_mays oryza_sativa arabidopsis_thaliana
'use strict';

const path = require('path');
const fs = require('fs');
const zlib = require('zlib');
const readline = require('readline');

const SEARCH = path.resolve(__dirname, '..', 'gramene-mongodb', 'search');
process.chdir(SEARCH);                       // the adders read their inputs relative to cwd

const MONGO_LIB = process.env.MONGO_LIB || path.resolve(SEARCH, '..', 'node_modules', 'mongodb');
const MONGO_URI = process.env.MONGO_URI || 'mongodb://localhost:27017';
const MONGO_DB = process.env.MONGO_DB || (() => {
  try {
    return require(path.resolve(__dirname, '..', 'gramene-mongodb-config', 'collections.js'))
             .getMongoConfig().db;
  } catch (e) { console.error('MONGO_DB unset and collections.js would not load'); process.exit(3); }
})();

const SPECIES = process.argv.slice(2).filter(a => !a.startsWith('-'));
const TARGETS = SPECIES.length ? SPECIES
  : ['sorghum_bicolor', 'zea_mays', 'oryza_sativa', 'arabidopsis_thaliana'];

// Pipe order copied from decorate.js. Only the adders that can touch a curated field.
// NB: require() resolves relative to THIS file, not to cwd, so the adders are loaded by absolute
// path even though process.chdir(SEARCH) above is what makes them find their own input files.
const A = n => path.join(SEARCH, n);

// This must be decorate.js's ENTIRE isGramene block, in its exact order -- not just the curated
// adders. Running only the curated ones and comparing against the live collection is an
// apples-to-oranges comparison that invents regressions: fix_sorghum_v2 writes 15,504 sorghum
// descriptions from the v2 deflines and grassius supplies 2,799 sorghum synonyms, so omitting them
// made a correct run look like it had destroyed both fields. A gate that reports phantom losses is
// worse than no gate, because someone will believe it.
const CHAIN = [
  ['fixMaizeV4',        () => require(A('fix_maize_v5'))()],
  ['maizegdb',          () => require(A('maizegdb'))()],
  ['fixSorghumV2',      () => require(A('fix_sorghum_v2'))()],
  ['panZeaAdder',       () => require(A('panmaize_xrefs'))()],
  ['grassius',          () => require(A('grassius'))()],
  ['vitisSynonymAdder', () => require(A('vitis_synonym_adder'))()],
  ['msu6Adder',         () => require(A('msu6_adder'))()],
  ['fixBarley',         () => require(A('fix_barley_ids'))()],
  ['thalemine',         () => require(A('thalemine'))()],
  ['rapdb',             () => require(A('rapdb'))()],
  ['curated',           () => require(A('curated'))()],
  ['generifs',          () => require(A('generifs'))(Number(process.env.REDIS_GENERIF_DB || 3))],
  ['qtls',              () => require(A('addQtlXrefs'))()],
];

function usable(v) {
  return !!v && v !== 'NULL' && v !== '""' && v !== '\\N' && String(v).trim() !== '';
}

const ANNOTATION_DBS = ['domains', 'GO', 'PO', 'TO', 'taxonomy', 'familyRoot', 'QTL_TO'];

function readDump(systemName) {
  return new Promise((resolve, reject) => {
    const f = path.join(SEARCH, 'tmp', systemName + '.json.gz');
    if (!fs.existsSync(f)) return reject(new Error('no dump at ' + f));
    const docs = [];
    readline.createInterface({input: fs.createReadStream(f).pipe(zlib.createGunzip()), terminal: false})
      .on('line', l => { if (l) docs.push(JSON.parse(l)); })
      .on('close', () => resolve(docs))
      .on('error', reject);
  });
}

function pipeThrough(docs, stages) {
  return new Promise((resolve, reject) => {
    const streams = stages.map(s => s[1]());
    for (let i = 0; i < streams.length - 1; i++) streams[i].pipe(streams[i + 1]);
    const out = [];
    const last = streams[streams.length - 1];
    last.on('data', d => out.push(d));
    last.on('end', () => resolve(out));
    streams.forEach(s => s.on('error', reject));
    docs.forEach(d => streams[0].write(d));
    streams[0].end();
  });
}

function summarise(docs) {
  const s = {
    genes: docs.length, named: 0, withSyn: 0, withDesc: 0, withSummary: 0,
    pubBySource: {}, xrefByDb: {}, idkCodes: 0, dupAnnotationDb: 0, ontTerms: {}, evidence: {}
  };
  docs.forEach(d => {
    if (d.name && d.name !== d._id) s.named++;
    if (d.synonyms && d.synonyms.length) s.withSyn++;
    // Count USABLE values, not merely truthy ones. ThaleMine's absent-value sentinels are the
    // strings "NULL" and the two-character '""', both truthy: 15,475 live arabidopsis docs carry
    // the former as `summary` and 3,740 the latter as `description`. Counting them as present makes
    // removing them look like a loss, when it is the defect being removed.
    if (usable(d.description)) s.withDesc++;
    if (usable(d.summary)) s.withSummary++;
    const perDb = {};
    (d.xrefs || []).forEach(x => {
      perDb[x.db] = (perDb[x.db] || 0) + 1;
      s.xrefByDb[x.db] = (s.xrefByDb[x.db] || 0) + 1;
      if (x.db === 'PUBMED' || x.db === 'DOI') {
        const k = x.db + '/' + (x.source || '(none)');
        s.pubBySource[k] = (s.pubBySource[k] || 0) + 1;
      }
      if (ANNOTATION_DBS.indexOf(x.db) >= 0) {
        (x.ids || []).forEach(i => {
          if (Array.isArray(i)) {
            if (i[1] === 'IDK') s.idkCodes++;
            if (['GO', 'PO', 'TO'].indexOf(x.db) >= 0) {
              s.ontTerms[x.db] = (s.ontTerms[x.db] || 0) + 1;
              s.evidence[i[1] || '(none)'] = (s.evidence[i[1] || '(none)'] || 0) + 1;
            }
          }
        });
      }
    });
    Object.keys(perDb).forEach(db => {
      if (perDb[db] > 1 && ANNOTATION_DBS.indexOf(db) >= 0) s.dupAnnotationDb++;
    });
  });
  return s;
}

// Exported so curated_patch.js can reuse the SAME chain definition rather than restating it.
// Two copies of this pipe order would drift, and the whole point of CHAIN is that it mirrors
// decorate.js exactly -- a patcher built on a stale copy would write docs a rebuild disagrees with.
module.exports = {CHAIN, readDump, pipeThrough, summarise, usable, SEARCH, A, MONGO_LIB, MONGO_URI, MONGO_DB};

if (require.main !== module) return;

(async () => {
  const { MongoClient } = require(MONGO_LIB);
  const client = new MongoClient(MONGO_URI, {useNewUrlParser: true, useUnifiedTopology: true});
  await client.connect();
  const genes = client.db(MONGO_DB).collection('genes');

  console.log('curated dry run against ' + MONGO_DB + ' -- nothing is written\n');

  for (const sp of TARGETS) {
    let docs;
    try { docs = await readDump(sp); }
    catch (e) { console.log('## ' + sp + ': SKIPPED (' + e.message + ')\n'); continue; }

    const after = summarise(await pipeThrough(docs, CHAIN));

    // The "before" is the live collection, which is what users see today. Query by taxon_id: it is
    // indexed (taxon_id_1_db_type_1_gene_idx_1) where system_name is not, which turns a 16.1M-doc
    // collection scan per species into an index lookup.
    const taxa = (await client.db(MONGO_DB).collection('maps')
      .find({type: 'genome', system_name: sp}, {projection: {taxon_id: 1}}).toArray())
      .map(m => m.taxon_id);
    if (!taxa.length) { console.log('## ' + sp + ': no genome in maps\n'); continue; }
    const live = await genes.find({taxon_id: {$in: taxa}},
      {projection: {_id: 1, name: 1, synonyms: 1, description: 1, summary: 1, xrefs: 1}}).toArray();
    const before = summarise(live);

    console.log('## ' + sp + '  (' + after.genes + ' genes in the dump, ' +
                before.genes + ' live)');
    const row = (label, b, a) => {
      const d = (typeof a === 'number' && typeof b === 'number')
        ? (a - b > 0 ? '  +' + (a - b) : a - b < 0 ? '  ' + (a - b) : '   =') : '';
      console.log('   ' + label.padEnd(34) + String(b).padStart(9) + ' -> ' +
                  String(a).padStart(9) + d);
    };
    row('genes with a name != id', before.named, after.named);
    row('genes with synonyms', before.withSyn, after.withSyn);
    row('genes with a usable description', before.withDesc, after.withDesc);
    row('genes with a usable summary', before.withSummary, after.withSummary);
    const srcs = Array.from(new Set(Object.keys(before.pubBySource).concat(Object.keys(after.pubBySource))));
    srcs.sort().forEach(k => row('  literature ' + k, before.pubBySource[k] || 0, after.pubBySource[k] || 0));
    ['MaizeGDB', 'GO', 'PO', 'TO'].forEach(db =>
      row('  xref ' + db, before.xrefByDb[db] || 0, after.xrefByDb[db] || 0));
    row('IDK evidence codes', before.idkCodes, after.idkCodes);
    row('genes w/ dup annotation-bearing db', before.dupAnnotationDb, after.dupAnnotationDb);
    if (Object.keys(after.evidence).length) {
      console.log('   evidence codes after : ' + JSON.stringify(after.evidence));
    }
    console.log('');
  }

  await client.close();
  // generifs.js opens a redis client and never quits it, so the event loop stays alive and this
  // process would hang after printing everything -- which is exactly why decorate.js ends with an
  // explicit process.exit(0) rather than letting the streams drain naturally.
  process.exit(0);
})().catch(e => { console.error('ERR ' + (e && e.stack || e)); process.exit(1); });
