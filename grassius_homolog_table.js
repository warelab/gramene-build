// grassius_homolog_table.js — Grassius TF families as a SUPERSET of the direct
// annotation, for faceting "transcription factor family" suggestions off one field.
//
// Direct Grassius annotations live on gene.xrefs[{db:'Grassius', ids:[family,...]}]
// and only cover the reference genomes (their gene IDs are in grassius.tsv). The
// 124 sorghum pan-genome assemblies share gene trees with those reference genes
// but have no direct annotation.
//
// grassius_homolog__attr_ss is built so it is a strict SUPERSET of Grassius__xrefs:
//   1. every gene in a Grassius-containing gene tree gets that tree's family union
//      (covers the reference genes AND their pan-genome homologs); and
//   2. any direct-Grassius gene NOT covered by (1) — e.g. treeless singletons with
//      no gene tree to project through — still gets at least its own families.
// So faceting grassius_homolog__attr_ss alone captures the whole family everywhere.
//
// run: mongosh "$MONGO_URI/$MONGO_DB" grassius_homolog_table.js > grassius_homolog_attrib_table.txt
// (the connected db is `db`)

// pass 1: tree -> family set, and each direct gene's own families
var treeFam = {};      // gene_tree id -> {family: 1}
var directOwn = {};    // gene _id -> [family,...]  (every directly-annotated gene)
db.genes.find({ 'xrefs.db': 'Grassius' },
              { 'homology.gene_tree.id': 1, 'xrefs': 1 }).forEach(function (g) {
  var t = g.homology && g.homology.gene_tree && g.homology.gene_tree.id;
  var fams = [];
  (g.xrefs || []).forEach(function (x) {
    if (x.db === 'Grassius' && x.ids) x.ids.forEach(function (f) { fams.push(f); });
  });
  directOwn[g._id] = fams;
  if (t) { if (!treeFam[t]) treeFam[t] = {}; fams.forEach(function (f) { treeFam[t][f] = 1; }); }
});

var treeIds = Object.keys(treeFam);
print('id\tcapabilities\tgrassius_homolog__attr_ss');

// (1) every gene in a Grassius-containing tree gets the tree's family union
var emitted = {};
db.genes.find({ 'homology.gene_tree.id': { $in: treeIds } },
              { 'homology.gene_tree.id': 1 }).forEach(function (g) {
  var fams = Object.keys(treeFam[g.homology.gene_tree.id] || {});
  if (!fams.length) return;
  print(g._id + '\tgrassius_homolog\t' + fams.join(','));
  emitted[g._id] = 1;
});

// (2) guarantee superset: direct genes not covered above (treeless) get own families
Object.keys(directOwn).forEach(function (id) {
  if (emitted[id]) return;
  var fams = directOwn[id];
  if (!fams.length) return;
  print(id + '\tgrassius_homolog\t' + fams.join(','));
});
// NOTE: no stdout diagnostics — mongosh routes console.error to stdout, which
// would corrupt the add_attributes.pl table. The caller counts rows.
