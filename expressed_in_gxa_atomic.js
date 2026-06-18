// expressed_in_gxa_atomic.js — emit Solr atomic-update docs that set
// expressed_in_gxa_attr_ss = the set of GXA experiment accessions in which a gene is
// expressed. Mirrors the logic now in gramene-solr/genes/mongo2solr.js (baseline TPM
// >= 0.5, or differential p < 0.05 AND |log2FC| >= 1.0) so the live genes core can be
// backfilled IN PLACE without re-running the full mongo->solr conversion. The field is
// normally produced during that conversion; this is the no-reload equivalent.
//
//   mongosh "$MONGO_URI/$MONGO_DB" expressed_in_gxa_atomic.js > expressed_in_gxa.ndjson
//   node solr_atomic_attr.js <genesCoreUrl> expressed_in_gxa.ndjson
//
// solr_atomic_attr.js existence-filters (so version-mismatched expression ids — e.g.
// grape Vitvi projection clones — can't create orphans) and, because these docs carry
// no `capabilities` token, it SETs only (no removal pass).

db.expression.find({}).forEach(function (d) {
  var studies = {};
  for (var k in d) {
    if (k === '_id') continue;
    var samples = d[k];                       // each non-_id key is a GXA experiment accession
    if (!Array.isArray(samples)) continue;
    for (var i = 0; i < samples.length; i++) {
      var s = samples[i];
      if (s.value != null && s.value >= 0.5) {                                   // baseline: detectable TPM
        studies[k] = 1;
      } else if (s.p_value != null && s.p_value < 0.05 && Math.abs(s.l2fc || 0) >= 1.0) {  // differential
        studies[k] = 1;
      }
    }
  }
  var arr = Object.keys(studies);
  if (arr.length) print(JSON.stringify({ id: d._id, expressed_in_gxa_attr_ss: { set: arr } }));
});
