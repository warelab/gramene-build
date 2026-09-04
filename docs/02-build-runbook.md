# Build runbook

Operating the build. For what each stage *does*, see [README.md](../README.md).

## The basics

```bash
cd /usr/local/gramene/subsites/sorghum/v11/build
make status          # which stages are stamped done
make running         # what is executing RIGHT NOW (status only shows completions)
make all             # build everything that isn't done
```

`make status` shows completion stamps, which is not the same as "nothing is running". Use
`make running` to see live activity — it greps for the known stage processes and shows the three
most recently touched logs.

A full build from nothing takes roughly **4 hours**, dominated by `50_genes_decorate` (~1 h) and
`60_solr_genes` (~1.5 h).

## Running a single stage

```bash
make 25_reactome              # via make (respects dependencies)
bash stages/25_reactome.sh    # directly (ignores dependencies — you are on your own)
```

Every stage tees to `logs/<stage>.log` and stamps `.state/<stage>.done` only on success. A failed
stage leaves no stamp, so re-running `make all` retries exactly it.

## Resuming after a failure or an interruption

Just re-run `make all`. Stamps make it skip what already completed. Stages are idempotent — they
drop and rebuild their own target — so re-running one never leaves half-merged data.

If you need to force a stage to re-run, delete its stamp:

```bash
rm .state/50_genes_decorate.done && make all
```

`make clean-stamps` forgets *all* completions without touching any data. That means a full rebuild,
so use it deliberately.

## Refreshing after new upstream data

Each target invalidates exactly the stamps affected by that kind of change, then rebuilds:

| new data | command |
| --- | --- |
| new compara | `make refresh-compara` |
| new / changed cores | `make refresh-genes` |
| new Expression Atlas | `make refresh-expression` |
| new Plant Reactome | `make refresh-reactome` |
| new GO/PO/TO/InterPro | `make refresh-ontologies` |
| new Grassius download | `make refresh-grassius` |

### Adding a few new Atlas studies (much cheaper than a refresh)

A new Expression Atlas study affects **one genome**, so rebuilding everything is the wrong shape —
a full `make refresh-expression` costs about **3 hours** (55: 19 min, 58: 50 min, 60: 103 min,
65: 7 min) and drops the Solr genes core. Instead:

```bash
make add-studies                                        # auto-discover new RNA-Seq studies
make add-studies ACCESSIONS="E-MTAB-8969,E-MTAB-10280"   # explicit
FORCE=1 make add-studies ACCESSIONS="E-MTAB-8969"        # re-load one already present
```

It fetches and upserts just those experiments, rebuilds expression attributes for **only the
affected genomes**, then patches the genes core **in place** via Solr atomic updates — no drop, no
downtime — and rebuilds the `expr` suggestion category. Studies already loaded are skipped unless
`FORCE=1`; each addition is recorded in `.state/atlas_studies.tsv`.

Discover what is available first with
`MONGO_DB=sorghum11 node ../gramene-mongodb/atlas/check_new_atlas_experiments.js` (see
[docs/03-operations.md](03-operations.md)).

Use `make refresh-expression` instead for a first build or a wholesale reload.

**A new study barely changes the `expression` document count** — it adds a *field* to existing
gene documents rather than creating new ones. Judge success by experiment presence, not doc counts.

### Updating rsIDs for one genome (no merge, no full rebuild)

rsID attributes are strictly per-genome — a gene belongs to exactly one genome — so a re-projected
VCF only needs that genome re-extracted and re-applied. There is no need to rebuild or merge a
pan-genome table:

```bash
cd ../gramene-solr/rsid_pipeline
./check_vcf_assembly.sh sorghum_353          # FIRST: is the new VCF on our assembly?
./build_rsid_table.sh sorghum_353            # ~2 min; writes $RSID_WORK_DIR/sorghum_353.tsv
./run_summary.sh                             # REF% must be 100.00, PTV% in 6-11%
cd ../../build
make refresh-rsid-genome GENOME=sorghum_353  # scoped atomic update, no downtime
```

The per-genome `.tsv` files in `$RSID_WORK_DIR` are the working set for this, not disposable resume
state. The remove pass is scoped to `system_name:<genome>` automatically; see
[troubleshooting](04-troubleshooting.md#incremental-updates-two-traps) for why that matters.

### Attribute-only refreshes (much cheaper)

When only an attribute table changed and the decorated genes did not, patch the Solr core **in
place** — no drop, no downtime:

```bash
make refresh-attr ATTR=maker        # or vep | rsid | grassius | expression
```

The heavier `make refresh-attributes` regenerates the merged attribute JSON and reloads all 5.4M
docs. Use it when several layers changed at once; use `refresh-attr` for one.

## Monitoring a long stage

```bash
tail -f logs/50_genes_decorate.log
make running
```

Decorate prints per-adder counters. If the counters stop advancing but the process is alive, see
[docs/04-troubleshooting.md](04-troubleshooting.md#decorate-stalls) — this has happened, four times
in a row, and the cause was not what it looked like.

## Killing a build safely

**Do not `pkill -f 'make all'`.** The pattern matches the cmdline of the shell you are typing in and
will kill your own session. Find the PID and kill it explicitly:

```bash
pgrep -af 'make all|stages/[0-9]'
kill <pid>
```

A killed stage leaves no stamp, so the next `make all` re-runs it from the top. Stages are
idempotent, so this is safe — but a killed `60_solr_genes` may leave a partially loaded core, which
the next run recreates from scratch anyway.

## Tunables

Set as environment variables:

| var | default | what |
| --- | --- | --- |
| `DUMP_PARALLELISM` | 6 | concurrent genome dumps in `40_genes_dump` |
| `SOLR_URL` | `http://localhost:8983/solr` | |
| `ENSEMBL_REST` | `https://data.gramene.org/pansite-ensembl-115` | public pansite REST; the local `:3000` registry is stale |
| `MAKER_TABLE` / `VEP_TABLE` | see `config.sh` | attribute table paths |
| `RSID_VCF_DIR` / `RSID_TABLE` | see `config.sh` | rsID VCFs and the table built from them |
| `RSID_FLANK_UP` / `RSID_FLANK_DOWN` | 200 / 0 | rsID flank, **upstream only and strand-aware** (below `start` on `+`, above `end` on `-`) |
| `RSID_MODE` | `cds` | window anchored on the CDS (robust to bad gene models) rather than the gene span |
| `RSID_CDS_UP` / `RSID_CDS_DOWN` | 1000 / 500 | bp before the start codon / after the stop codon |
| `RSID_CDS_FASTA_DIR` | `/scratch/olson/fasta` | CDS sequence for PTV/PAV consequence calling |
| `RSID_INTRON_MAX_DIST` | 10 | intronic variants further than this from a canonical exon are dropped |
| `RSID_MAX_PER_GENE` / `RSID_JOBS` | 5000 / 4 | per-gene rsID ceiling; genomes extracted in parallel |
| `RSID_SKIP_GENOMES` | `sorghum_353 sorghum_pi154844` | genomes whose VCF is on a different assembly — see [troubleshooting](04-troubleshooting.md#rsid-vcfs-projected-onto-the-wrong-assembly) |
| `REBUILD_CORE=1` | — | force-recreate the Solr genes core |
| `GT_PREFIX` | `SB<version>GT_` | synthetic gene-tree id prefix |
| `SWAGGER_PORT` / `EBEYE_PORT` | 10000+v / 11000+v | `70_services` |
| `START_SERVICES=1` | off | let `70_services` pm2-start the services |

## Verifying a finished build

Beyond the stage guards, sanity-check the result before publishing:

```bash
# Solr doc counts should match Mongo
mongosh --quiet sorghum11 --eval 'db.genes.countDocuments({})'
curl -s 'http://localhost:8983/solr/sorghum_genes11/select?q=*:*&rows=0' | grep -o '"numFound":[0-9]*'

# every genome represented, with sane counts
mongosh --quiet sorghum11 --eval 'db.maps.find({},{system_name:1,num_genes:1,taxon_id:1}).toArray()'

# attribute coverage
curl -s 'http://localhost:8983/solr/sorghum_genes11/select?q=capabilities:MAKER&rows=0' | grep -o '"numFound":[0-9]*'

# the API answers
curl -s 'http://localhost:50011/sorghum_v11/search?q=*:*&rows=0' | head -c 200
```

Compare against the previous release rather than against absolute numbers — v11 has 5,407,132 genes
vs v10b's 5,248,909, and a change of that rough size is expected when genomes are added. A change
of *zero*, or a change of 10x, means something is wrong.
