// expression_attributes_table.js — emit an add_attributes.pl table from the
// expression_attributes collection so the solr genes core is searchable/facetable
// by per-gene expression summaries. Keyed by gene _id; merged in stage 60.
//
// run: mongosh "$MONGO_URI/$MONGO_DB" expression_attributes_table.js > expression_attributes_table.txt
//
// Field map (all dynamic fields already in the schema):
//   capabilities                 += expression_attributes
//   expr_specific_to__attr_ss     attributes.specific_to            (organs)
//   expr_enhanced_in__attr_ss     attributes.enhanced_in            (organs)
//   expr_high_in__attr_ss         organs with per_organ.level in {high,very_high}
//                                 (unioned with attributes.highly_expressed_in)
//   expr_activated_by__attr_ss    attributes.activated_by           (stress conditions)
//   expr_repressed_by__attr_ss    attributes.repressed_by           (stress conditions)
//   expr_class__attr_ss           breadth + boolean flags as class tokens
//   expr_organ_level__attr_ss     composite "<organ>:<level>" tokens (organ x level pivot)
//   expr_tau__attr_f              tissue-specificity index (0..1)
//   expr_max_tpm__attr_f          peak expression
//   expr_n_organs_detected__attr_i

var HIGH = { high: 1, very_high: 1 };
var FIELDS = ['id', 'capabilities',
  'expr_specific_to__attr_ss', 'expr_enhanced_in__attr_ss', 'expr_high_in__attr_ss',
  'expr_activated_by__attr_ss', 'expr_repressed_by__attr_ss', 'expr_class__attr_ss',
  'expr_organ_level__attr_ss', 'expr_tau__attr_f', 'expr_max_tpm__attr_f',
  'expr_n_organs_detected__attr_i'];

print(FIELDS.join('\t'));

function clean(s) { return ('' + s).replace(/[,\t]/g, ' '); }       // commas split _ss; tabs break TSV
function csv(arr) { return (arr && arr.length) ? arr.filter(function (x) { return x != null && x !== ''; }).map(clean).join(',') : ''; }

// No grapevine id remapping on this subsite, deliberately.
//
// The main release carries a Vitis->VIT_ step here, because its grape genes are keyed
// `Vitis##g#####` while the expression data is `VIT_`-keyed. None of that applies to a grapevine
// subsite, and the step as written was wrong three ways: it read `synonyms` where
// vitis_synonym_adder writes `alt_id`, it hardcoded taxon 29760001 which is `vitis_cabfranc` here
// rather than either vinifera assembly, and `/^Vitis/` does not even match this site's ids --
// `Vitvi` differs at the fourth character and `VIT_` is a different prefix entirely.
//
// Measured on grapevine4: the expression collection holds 29,971 `VIT_` ids and 22,048 `Vitvi`
// ids and ZERO `Vitis...` ids, and every one of them resolves directly to a gene `_id`. So ids
// pass through untouched. Rows whose id matches no gene are already counted by the loader's
// "absent" tally in stage 60, so nothing is silently dropped by removing this.
db.expression_attributes.find({}).forEach(function (d) {
  var gid = d._id;
  var a = d.attributes || {};

  // expression breadth/abundance CLASS (a set of facetable tokens)
  var cls = {};
  if (d.breadth) cls[d.breadth] = 1;
  if (a.broadly_expressed) cls['broadly_expressed'] = 1;
  if (a.ubiquitously_detected || d.ubiquitously_detected) cls['ubiquitous'] = 1;
  if (a.not_expressed_in_panel) cls['not_expressed'] = 1;

  // per-organ levels: composite tokens + the set of high organs
  var highOrgans = {};
  (a.highly_expressed_in || []).forEach(function (o) { highOrgans[clean(o)] = 1; });
  var organLevel = [];
  var po = d.per_organ || {};
  Object.keys(po).forEach(function (org) {
    var lvl = po[org] && po[org].level;
    if (!lvl || lvl === 'no_data') return;
    organLevel.push(clean(org) + ':' + clean(lvl));
    if (HIGH[lvl]) highOrgans[clean(org)] = 1;
  });

  var row = [
    gid,
    'expression_attributes',
    csv(a.specific_to),
    csv(a.enhanced_in),
    Object.keys(highOrgans).join(','),
    csv(a.activated_by),
    csv(a.repressed_by),
    Object.keys(cls).join(','),
    organLevel.join(','),
    (d.tau != null ? d.tau : ''),
    (d.max_tpm != null ? d.max_tpm : ''),
    (d.n_organs_detected != null ? d.n_organs_detected : '')
  ];
  print(row.join('\t'));
});
