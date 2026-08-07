# Open items

Everything unfinished as of **2026-08-05**, with enough context to act without the conversation that
produced it. Ordered by what blocks what.

---

## Deployment status

v11 **is publicly served**. Verified 2026-08-07:

| check | result |
| --- | --- |
| `https://data.sorghumbase.org/sorghum_v11/swagger` | 200, titled "API for sorghumbase release 11" |
| `…/sorghum_v11/search?q=*:*&rows=0` | 5,407,132 — matches localhost:50011 and Mongo |
| `…/sorghum_v11/gene_lists/validate` | serves the current `{resolved,ambiguous,unknown}` contract |
| `…/sorghum_v10b/search?q=*:*&rows=0` | 5,248,909 — v10b still live and separate |

So of the `70_services` checklist, the Apache proxy and firewall are **done**. Still outstanding:

* **Ensembl REST registry** — see [below](#1-ensembl-rest-registry-merge). The shared registry file
  is dated **2024-03-14**; `sorghum_pi656029` and `sorghum_bicolort2tcas` return 400 from REST while
  `sorghum_bicolor` and `sorghum_353` resolve. REST reports 151 species.
* **BLAST** — `gramene-blast` is online but its uptime predates the v11 build completing, so it has
  not picked up this release. Needs the merged registry first, then `ensure_blast.pl` and a restart.
* **Gene-tree curation UI** (`gramene-genetree-vis`) — point `defaultServerSb` at the v11 swagger.
* **v10b ebeye moved to port 51010** — check the Apache proxy for it matches.

### ebeye `defaultServer` is pointed at localhost

`gramene-ebeye/app.js` has an uncommitted change:

```diff
-global.gramene = {defaultServer: "https://data.sorghumbase.org/sorghum_v11/swagger"};
+global.gramene = {defaultServer: "http://localhost:50011/sorghum_v11/swagger"};
```

`70_services` writes the local URL by design. Both URLs currently answer 200, so ebeye works either
way from this host — this is not breaking anything today. But the committed `https://` value is the
correct one for production: the comment in that file explains that the spec fetch and the API calls
must go over real TLS or you get `EPROTO`. Restore it (`git checkout -- app.js` would also discard
the alt_id fix below, so revert just that line) and restart `sorghum_ebeye11`.

---

## 1. Ensembl REST registry merge

v11's 131 databases need to reach the shared registry at
`/usr/local/ensembl-87/ensembl-rest/reg.pm`, which serves **91 species across every subsite**. The
other subsites' entries must survive.

Tooling is ready and verified, in this repo:

* `make_reg_pm.js` — generates the release's own registry from `ensembl_db_info.json`
* `merge_reg_pm.pl` — merges N registries, later files winning on `(species, group)`

```bash
PERL5LIB=$(ls -d /usr/local/ensembl-115/*/modules | tr '\n' ':') \
  perl merge_reg_pm.pl /usr/local/ensembl-87/ensembl-rest/reg.pm reg.pm > merged.pm 2> conflicts.txt
perl -c merged.pm          # then install and restart REST
```

**Why it is a Perl script that executes the registries rather than parsing them:** real registry
files build adaptors in loops —

```perl
for my $core (@core_10_108_2) { Bio::EnsEMBL::DBSQL::DBAdaptor->new('-species' => $core, …); }
```

— which no text parser handles. `ensembl-108/reg.pm` has four such loops generating 116 stanzas. It
also catches two things only Ensembl itself knows: a duplicate whose connection matches exactly is
silently *absorbed*, and one whose connection differs gets its species silently *renamed* to
`species1`. `DBAdaptor->new` does not connect, so this is safe to run against unreachable hosts.

A merge of `ensembl-108/reg.pm` + `ensembl-115/reg.pm` + `ensembl-115/reg.sb11.pm` has already been
produced and verified (279 entries, 155 conflicts resolved, compiles under `perl -c`, all 131 sb11
entries winning): `reg.merged.pm` with the report in `reg.merged.conflicts.txt`. **Not installed.**

Two things in that merged file to decide on before installing:

* `brachypodium_distachyon` is the only entry not on `cabot` — it resolves to `colden`, inherited
  from `ensembl-108/reg.pm:66`. All other 278 are on cabot.
* The merged set has **10 variation databases**; v11 itself supplies only 2 (`sorghum_bicolor`,
  `oryza_sativa`). The other 8 (maize B73 and seven rice accessions) come from the 108/115
  registries. If v11 should serve only its own variation set, those extras carry forward silently.

---

## 2. Web client: the gene-lists API changed

Full spec: `../gramene-swagger/docs/gene_lists_api.md`. Three changes matter:

* **`POST /gene_lists/validate` returns a new shape** — `{resolved, ambiguous, unknown}` instead of
  `{ids, missing, hash}` — and no longer writes anything. It now also matches **alternate ids**
  (`Sobic.*`, `LOC_Os*`, `GRMZM*`), which previously all came back as missing.
* **Ambiguity is now reportable and must be handled.** There was previously no way to express a
  multi-match. `loc_os07g23485` matches 15 genes, `grmzm2g034428` matches 10. A client that reads
  `resolved` and ignores `ambiguous` silently drops genes the user asked for.
* **Saving moved to a JSON body** on `POST /gene_lists`; the server now computes the hash and
  `n_genes`.

**⚠ The old save call fails silently.** `GET /gene_lists?label=…&hash=…&site=…` still returns
**200** — it is now just the listing endpoint ignoring unknown query params — and saves nothing.
Verified: the document count is unchanged across such a call. Grep the client for `gene_lists?` with
`hash=` and convert those call sites first.

The server side is done, committed, pushed, and live (`sorghum_swagger11`, verified serving the new
code). One thing was **not** verifiable from the shell: the authenticated save path needs a real
Firebase ID token. The 401s, the swagger contract, the rejection of the old form, and the hash
change are all verified; the actual write of a `genelists` document plus core tagging is not. **Do
one manual save from the client and confirm it lands** before relying on it.

---

## 3. Gene trees are stale relative to two fixes

Tree representatives were chosen *before* the `in_compara` fix and the +25 non-anchor scoring tier
landed. The choices are stored, not computed at read time, so the trees currently carry the old
selections.

```bash
make 35_genetrees      # then the stages that depend on it
```

Note this cascades: `50_genes_decorate` → `52_tree_domains` → `60_solr_genes` →
`65_solr_suggestions`. `make refresh-compara` does the whole chain. Cosmetic but visible in the tree
viewer — not urgent, but it should not ship to a new release uncorrected.

---

## 4. MAKER verification pass

The v11 MAKER table is built and merged (coverage went 28 → 37 genomes, `capabilities:MAKER`
1,015,322 → 1,451,176). The verification checklist in `../gramene-solr/maker_pipeline/README.md`
under "Verifying" was only partly worked through. Worth completing before the release is called
done.

---

## Uncommitted work

Nothing below is committed. Decide per item; several are junk and should just be deleted.

### `build/` (this repo — now committed as part of the handoff)

Committed with the docs: `HANDOFF.md`, `docs/`, `make_reg_pm.js`, `merge_reg_pm.pl`.

Deliberately **not** committed:

| file | why |
| --- | --- |
| `reg.pm` | **contains the MySQL password in plaintext.** `gramene-build` tracks no credentials today and this would be the first. It is regenerable in one command: `node make_reg_pm.js > reg.pm`. Now in `.gitignore` so it cannot be added by accident. (Note `gramene-mongodb` *does* track `ensembl_db_info.json` with the same password — worth cleaning up separately.) |
| `reg.merged.pm`, `reg.merged.conflicts.txt` | regenerable outputs, and `reg.merged.pm` carries the same credentials |
| `reg.pm.bak.pre-v11` | backup snapshot; git has the history |
| `apply_poplar_expr_fix.sh` | **obsolete and destructive if re-run** — a one-shot fix already applied. Recommend deleting it. |

### `gramene-ebeye`

Two unrelated changes in the tree — commit them separately:

* `src/translateResponseDocument.js` — **a live bug fix, should be committed.** `3743b55` added
  `alt_id` to `FL`, which is both the Solr field list *and* the list `checkFields` walks to require
  fields on every doc. `alt_id` is on only 107,226 of 5,407,132 genes, so EBeye threw
  `Doc <id> missing field alt_id` on ~98% of results. The fix moves the exemptions into an
  `OPTIONAL_FIELDS` list (`gene_tree`, `synonyms`, `alt_id`). Verified: error log stays at 0 bytes
  across seven queries spanning sorghum, Arabidopsis and rice, and `alt_id` still exports into
  `gene_synonym` where present.
* `app.js` — the `defaultServer` change described above; restore the `https://` value.
* `package-lock.json` — untracked npm churn; ignore.

**Known, unfixed, in the same file:** `genetree: [result.gene_tree] || []` yields `[null]` for the
~2.7M genes with no tree, because `[x]` is always truthy so the `|| []` never fires. Should be
`result.gene_tree ? [result.gene_tree] : []`. EBI Search may reject a null inside an array.

### `gramene-mongodb`

| file | disposition |
| --- | --- |
| `atlas/taxon_remap.json` (218 B) | **Should probably be committed.** `getAtlasData.js` loads it at runtime; regenerate with `build_taxon_remap.js` if lost. |
| `atlas/poplar_v4.lut.txt` (1.2 MB) | intermediate — already merged into the tracked `new_old.lut.txt`, and referenced nowhere. Safe to delete. |
| `atlas/new_old.lut.txt.bak.prePoplarV4` | backup; delete |
| `atlas/tmp_poplar_stale_ids.txt` | scratch; delete |
| `ensembl_db_info.json.bak.131cores`, `.bak.1var`, `.v10-stale.bak` | backups from selecting the v11 database set; delete |
| `trees/inserts.jsonl` | build scratch; delete |

### `gramene-solr`, `gramene-mongodb-config`

`package-lock.json` only — npm churn from `npm install`. Ignore or commit as you prefer; it is not
meaningful to this pipeline.

### `gramene-swagger`

`package-lock.json` only — npm churn; ignore. The API reference
(`docs/gene_lists_api.md`) is committed and pushed as `81cb669`.

---

## Stale task list

The task tracker attached to this session still lists items 4–7 as pending. 5, 6 and 7 are in fact
**done** (the gene-lists rewrite shipped, was verified, committed and pushed as `61756cb`). Item 4
(MAKER verification) is genuinely still open — see above.
