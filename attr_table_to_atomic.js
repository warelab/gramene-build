#!/usr/bin/env node
'use strict';
// attr_table_to_atomic.js — convert ANY add_attributes.pl table into Solr
// ATOMIC-UPDATE NDJSON (one doc per gene). This is the in-place equivalent of
// add_attributes.pl: rather than merging the table into solr_genes.json for a full
// reload, it patches the live genes core. Works for every post-dump attribute layer
// — MAKER, VEP, grassius_homolog, expression — because they all share one format:
//
//   TSV, first line a header:  id  <col>  <col> ...
//   each <col> is either "capabilities" or matches ^\w+_attr_[sif]s?$
//   (_ss/_is/_fs = multi-valued, comma-split; _s/_i/_f = single; i=int, f=float)
//
//   node attr_table_to_atomic.js < table.txt > atomic.ndjson
//
// Mapping (matches add_attributes.pl semantics, made authoritative for in-place use):
//   * attr field, non-empty -> {set: value}      (add_attributes "set if absent"; on a
//       fresh full-rebuild doc that's identical, and {set} is what an UPDATE wants)
//   * attr field, EMPTY      -> {set: null}       (clears a value the gene no longer
//       has — needed so the in-place result matches a from-scratch rebuild)
//   * capabilities           -> {add-distinct: token}  (add_attributes push; add-distinct
//       is the idempotent in-place form — no duplicate token on re-run)
// Genes that vanish from the table entirely are handled by the loader's remove pass.

const readline = require('readline');
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

let cols = null;        // classified columns after the id column
let mismatch = 0, rows = 0;

function classify(name) {
  if (name === 'capabilities') return { name, kind: 'cap' };
  const m = name.match(/^\w+_attr_([sif])(s?)$/);
  if (!m) throw new Error('attr_table_to_atomic: unrecognized column "' + name + '" (must be capabilities or *_attr_[sif]s?)');
  return { name, kind: m[1], multi: m[2] === 's' };
}
function conv(kind, v) { return kind === 'i' ? parseInt(v, 10) : kind === 'f' ? parseFloat(v) : v; }

rl.on('line', (line) => {
  if (cols === null) {                       // header: drop id column, classify the rest
    const h = line.split('\t');
    h.shift();
    cols = h.map(classify);
    return;
  }
  if (line === '') return;
  const f = line.split('\t');
  const id = f.shift();
  if (id === undefined || id === '') return;
  rows++;
  if (f.length !== cols.length) mismatch++;   // tolerated (missing trailing cells -> null), but counted
  const doc = { id };
  for (let i = 0; i < cols.length; i++) {
    const c = cols[i];
    const raw = (f[i] === undefined ? '' : f[i]);
    if (c.kind === 'cap') {
      if (raw !== '') doc.capabilities = { 'add-distinct': raw };
      continue;
    }
    if (raw === '') { doc[c.name] = { set: null }; continue; }
    if (c.multi) {
      const arr = raw.split(',').filter(x => x !== '').map(x => conv(c.kind, x));
      doc[c.name] = { set: arr.length ? arr : null };
    } else {
      doc[c.name] = { set: conv(c.kind, raw) };
    }
  }
  process.stdout.write(JSON.stringify(doc) + '\n');
});
rl.on('close', () => {
  if (mismatch) process.stderr.write(`attr_table_to_atomic: WARNING ${mismatch}/${rows} rows had a column-count mismatch\n`);
});
