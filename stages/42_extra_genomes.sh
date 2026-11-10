#!/usr/bin/env bash
# 42_extra_genomes — dump the genomes that CANNOT live in `maps`, into the same
# search/tmp/<system_name>.json.gz that 40_genes_dump writes.
#
# Why a separate stage. 40_genes_dump drives itself from mongo `maps`, whose _id is the
# assembly accession. oryza_sativamsu (otherfeatures, MSU7) and oryza_sativacshl (cdna) both
# report assembly.accession GCA_001433935.1 -- the SAME accession as oryza_sativa's IRGSP-1.0
# core -- so a maps document for either would collide on the primary key with the reference
# genome. That is why oryza9 served them from two hand-made dumps: maps has 37 genomes there
# while `genes` has 39 system_names, and 93,389 genes reach the site by a path the harness
# never knew about.
#
# This stage is that path, made reproducible. It does NOT write to maps. 50_genes_decorate
# ingests `zcat tmp/*.json.gz`, so a dump dropped here is picked up with no further wiring,
# and its own expected-gene total is computed from the files rather than from maps.
#
# The two cores are declared as `extra_cores` in gramene-mongodb/ensembl_db_info.json -- a
# sibling of `cores`, so maps/load.js (which reads .cores) still cannot see them and the
# EXPECT_CORES=37 preflight invariant is unchanged.
#
# taxon_id is NOT hardcoded. Each extra genome borrows the identity of the maps genome that
# shares its assembly accession, which is the very thing that forced it out of maps. The
# synthetic per-genome taxon ids are reassigned whenever the genome set changes, so reading it
# back from maps at build time is what keeps these dumps from carrying another genome's id --
# the same failure 40_genes_dump guards against with its maps-stamp staleness check.
cd "$(dirname "$0")/.."
. ./config.sh
. ./lib.sh
stage_begin 42_extra_genomes

SEARCH="${MONGODB_REPO}/search"
DBINFO="${MONGODB_REPO}/ensembl_db_info.json"
cd "${SEARCH}"
mkdir -p tmp

mapfile -t EXTRA < <("${NODE_BIN}" -e '
  const info = require(process.argv[1]);
  (info.extra_cores || []).forEach(c => console.log([c.database, c.host, c.user, c.password || ""].join("\t")));
' "${DBINFO}")

if [ "${#EXTRA[@]}" -eq 0 ]; then
  log "no extra_cores declared in ${DBINFO} — nothing to do"
  stage_end
  exit 0
fi
log "extra genomes declared: ${#EXTRA[@]}"

fail=0
while IFS=$'\t' read -r db dbhost dbuser dbpass; do
  [ -n "${db}" ] || continue

  # The database must exist. A silent miss here is how 20_variation died three stages later.
  exists="$(MYSQL_PWD="${dbpass}" mysql -h "${dbhost}" -u "${dbuser}" -N -e \
            "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db}';" 2>/dev/null)"
  [ "${exists:-0}" -eq 1 ] || { warn "extra core ${db} does not exist on ${dbhost}"; fail=1; continue; }

  # system_name and the assembly accession come from the core itself, exactly as dump_genes.js
  # reads them (system_name <- species.production_name, db_type <- the database name).
  sys="$(MYSQL_PWD="${dbpass}" mysql -h "${dbhost}" -u "${dbuser}" -N -e \
        "SELECT meta_value FROM ${db}.meta WHERE meta_key='species.production_name' LIMIT 1;" 2>/dev/null)"
  acc="$(MYSQL_PWD="${dbpass}" mysql -h "${dbhost}" -u "${dbuser}" -N -e \
        "SELECT meta_value FROM ${db}.meta WHERE meta_key='assembly.accession' LIMIT 1;" 2>/dev/null)"
  [ -n "${sys}" ] || { warn "${db}: no species.production_name in meta"; fail=1; continue; }
  [ -n "${acc}" ] || { warn "${db}: no assembly.accession in meta — nothing to borrow a taxon_id from"; fail=1; continue; }

  # Borrow the taxon_id of the maps genome on the same assembly. This is the whole reason the
  # genome cannot be in maps, so if the lookup fails the premise of this stage is wrong.
  taxon="$(mongo_eval "var m=db.maps.findOne({type:'genome',_id:'${acc}'}); print(m?m.taxon_id:'')" | tr -d '\r')"
  [ -n "${taxon}" ] || { warn "${db}: no maps genome with _id='${acc}' to borrow a taxon_id from — did 10_maps run?"; fail=1; continue; }

  want="$(MYSQL_PWD="${dbpass}" mysql -h "${dbhost}" -u "${dbuser}" -N -e \
         "SELECT COUNT(*) FROM ${db}.gene WHERE is_current=1;" 2>/dev/null)"
  [ "${want:-0}" -gt 0 ] || { warn "${db}: 0 current genes"; fail=1; continue; }

  f="tmp/${sys}.json.gz"
  # Resumable on the same terms as 40_genes_dump, including its maps-stamp rule: a dump written
  # before the current maps carries taxon ids that may since have moved.
  if [ -s "$f" ] && gzip -t "$f" 2>/dev/null \
     && [ "$(zcat "$f" | wc -l)" = "${want}" ] \
     && { [ ! -f "${STATE_DIR}/10_maps.done" ] || [ ! "${STATE_DIR}/10_maps.done" -nt "$f" ]; }; then
    ok "${sys}: ${want} genes already dumped (${f})"
    continue
  fi

  log "dumping ${sys} from ${db} (db_type from the name, map ${acc}, taxon ${taxon}, expect ${want} genes)"
  # NB dump_genes.js takes the password as -p on the command line, so it is visible in `ps` for
  # the duration of the run. Pre-existing across every dump in this harness; not widened here.
  pwarg=""
  [ -n "${dbpass}" ] && pwarg="-p ${dbpass}"
  "${NODE_BIN}" --max-old-space-size=4096 ./dump_genes.js \
    -h "${dbhost}" -u "${dbuser}" ${pwarg} -d "${db}" -m "${acc}" -t "${taxon}" \
    | gzip -c > "${f}.part"
  rc=${PIPESTATUS[0]}
  if [ "${rc}" -ne 0 ]; then
    warn "${sys}: dump_genes.js exited ${rc} — leaving ${f} untouched"
    rm -f "${f}.part"; fail=1; continue
  fi
  have="$(zcat "${f}.part" 2>/dev/null | wc -l)"
  if [ "${have}" != "${want}" ]; then
    warn "${sys}: dumped ${have} genes, expected ${want} — refusing to publish a short dump"
    rm -f "${f}.part"; fail=1; continue
  fi
  mv "${f}.part" "${f}"
  ok "${sys}: ${have} genes -> ${f}"

  # The dump must actually carry the system_name and db_type the site groups on. taxon_id alone
  # cannot separate these three genomes -- oryza_sativa, oryza_sativamsu and oryza_sativacshl all
  # carry ${taxon} -- so (system_name, db_type) is the only key that distinguishes them, and a
  # dump missing either would merge silently into the reference genome.
  firstline="$(zcat "${f}" | head -1)"
  echo "${firstline}" | "${NODE_BIN}" -e '
    let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
      const g=JSON.parse(s);
      const want=process.argv[1], taxon=+process.argv[2];
      if (g.system_name !== want) { console.error(`system_name is ${g.system_name}, expected ${want}`); process.exit(1); }
      if (!g.db_type)             { console.error("no db_type on the gene doc");                        process.exit(1); }
      if (g.taxon_id !== taxon)   { console.error(`taxon_id is ${g.taxon_id}, expected ${taxon}`);       process.exit(1); }
      console.log(`${g.system_name} / ${g.db_type} / taxon ${g.taxon_id}`);
    });' "${sys}" "${taxon}" || { warn "${sys}: dump does not carry the expected identity"; fail=1; continue; }
done < <(printf '%s\n' "${EXTRA[@]}")

[ "${fail}" -eq 0 ] || die "one or more extra genomes failed — see the warnings above. 50_genes_decorate
 ingests every tmp/*.json.gz, so continuing would silently ship the site without them, which is
 exactly how oryza9's 93,389 MSU/CSHL genes went unnoticed on the first port."

log "gene dumps now in ${SEARCH}/tmp: $(ls tmp/*.json.gz 2>/dev/null | wc -l)"
log "total gene lines across all dumps: $(zcat tmp/*.json.gz | wc -l)"
stage_end
