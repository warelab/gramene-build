// project_maize_v4_to_v5.js — fold orphaned maize v4 (Zm00001d) differential expression onto the
// corresponding v5 (Zm00001eb) genes via the MaizeGDB id-history (geneIDhistory.maizeV5). The maize
// gene models in the `genes` collection are all v5, so the v4-keyed differential expression docs
// never join (genes ⋈ expression) and would otherwise be lost; this projects them so that
// 58_expression_attributes scores them (attributes.activated_by / repressed_by).
//
//   run from gramene-mongodb/search (reads geneIDhistory.maizeV5 relative to cwd):
//     mongosh "$MONGO_URI/$MONGO_DB" /path/to/build/project_maize_v4_to_v5.js
//
// Idempotent + safe: only projects differential experiments that are NOT already present on the
// v5 doc, so it never overwrites v5 baseline data and re-runs are no-ops. fan-out (1 v4 -> N v5
// gene splits) is honored; fan-in (N v4 -> 1 v5) is deduped per contrast group (lowest p kept).
var fs = require('fs');
var LUT = 'geneIDhistory.maizeV5';
if (!fs.existsSync(LUT)) { print('[project_maize_v4_to_v5] ' + LUT + ' not in cwd — skipping'); quit(0); }

// v4 (Zm00001d...) -> [v5 (Zm00001eb...), ...]
var v2v5 = {}, nPairs = 0;
fs.readFileSync(LUT, 'utf8').split('\n').forEach(function (l) {
  if (!l) return; var f = l.split('\t'), o = f[0], v5 = f[1];
  if (/^Zm00001d/.test(o) && /^Zm00001eb/.test(v5)) { (v2v5[o] = v2v5[o] || []).push(v5); nPairs++; }
});
if (!nPairs) { print('[project_maize_v4_to_v5] no v4->v5 pairs in ' + LUT + ' — skipping'); quit(0); }

// experiment accessions already present on v5 docs (e.g. baseline) — never overwrite these
var v5exps = {};
db.expression.aggregate([
  { $match: { _id: /^Zm00001eb/ } },
  { $project: { k: { $map: { input: { $objectToArray: '$$ROOT' }, as: 'e', in: '$$e.k' } } } },
  { $unwind: '$k' }, { $match: { k: { $ne: '_id' } } }, { $group: { _id: '$k' } }
], { allowDiskUse: true }).forEach(function (d) { v5exps[d._id] = 1; });

// accumulate per v5 target: experiment -> contrast group -> most-significant differential entry
var acc = {}, v4used = 0;
db.expression.find({ _id: /^Zm00001d/ }).forEach(function (d) {
  var tgts = v2v5[d._id]; if (!tgts) return;
  var used = false;
  Object.keys(d).forEach(function (k) {
    if (k === '_id' || !Array.isArray(d[k]) || !d[k].length || v5exps[k]) return; // skip baseline-owned exps
    var diff = d[k].filter(function (e) { return e && e.p_value !== undefined && e.p_value !== null; });
    if (!diff.length) return;
    used = true;
    tgts.forEach(function (v5) {
      var ex = (acc[v5] = acc[v5] || {}); var gm = (ex[k] = ex[k] || {});
      diff.forEach(function (e) { if (!gm[e.group] || e.p_value < gm[e.group].p_value) gm[e.group] = e; });
    });
  });
  if (used) v4used++;
});
var targets = Object.keys(acc);
print('[project_maize_v4_to_v5] LUT v4 keys=' + Object.keys(v2v5).length +
      ', v4 docs projected=' + v4used + ', v5 targets=' + targets.length);
if (!targets.length) { print('[project_maize_v4_to_v5] nothing new to project — skipping'); quit(0); }

var bulk = db.expression.initializeUnorderedBulkOp(), n = 0;
targets.forEach(function (v5) {
  var set = {};
  Object.keys(acc[v5]).forEach(function (exp) {
    set[exp] = Object.keys(acc[v5][exp]).map(function (g) { return acc[v5][exp][g]; });
  });
  bulk.find({ _id: v5 }).upsert().updateOne({ $set: set }); n++;
  if (n % 5000 === 0) { bulk.execute(); bulk = db.expression.initializeUnorderedBulkOp(); }
});
if (n % 5000 !== 0) bulk.execute();
print('[project_maize_v4_to_v5] done — issued updates for ' + targets.length + ' v5 expression docs');
