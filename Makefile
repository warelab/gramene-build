# ─────────────────────────────────────────────────────────────────────────────
# SorghumBase search-index build — orchestration.
#
# Each stage script is idempotent (drops+rebuilds its target) and writes a stamp
# in .state/<stage>.done on success. Make uses those stamps as targets, so a
# re-run only re-does what's missing or what you explicitly invalidate.
#
#   make all            # full build: mongo + solr genes + suggestions
#   make mongo          # everything up to the decorated genes collection
#   make solr           # solr genes + suggestions (needs mongo done)
#   make <stage>        # run one stage (e.g. make 25_reactome)
#   make status         # show which stages are done
#   make clean-stamps   # forget completion (does NOT touch data)
#
# Re-run on new data (clears just the affected stamps, then rebuild):
#   make refresh-compara     # new compara: genetrees+homologs+decorate+solr
#   make refresh-genes       # new/changed cores: dump+decorate+solr
#   make refresh-expression  # new Atlas data: atlas+expression_attributes+solr genes
#   make refresh-reactome    # new Plant Reactome: reactome+decorate+solr
#   make refresh-ontologies  # new GO/PO/TO/InterPro: ontologies+decorate+solr
#
# Atomic refresh of ONE post-dump attribute layer — patches the genes core IN PLACE
# (no drop / no downtime), far lighter than refresh-attributes (which reloads 5.2M docs):
#   make refresh-attr ATTR=expression   # or: maker | vep | grassius
#   make refresh-expression-attrs / refresh-maker / refresh-vep / refresh-grassius-homolog
# ─────────────────────────────────────────────────────────────────────────────
SHELL := /bin/bash
S     := .state
ST    := stages

.PHONY: all mongo solr index status running clean-stamps \
        refresh-compara refresh-genes refresh-expression refresh-reactome refresh-ontologies \
        refresh-grassius refresh-attributes \
        refresh-attr refresh-maker refresh-vep refresh-grassius-homolog refresh-expression-attrs \
        00_preflight 05_install 10_maps 15_ontologies 20_variation 22_germplasm 25_reactome 28_grassius_source 30_curated \
        35_genetrees 40_genes_dump 45_homologs 50_genes_decorate 52_tree_domains 55_atlas \
        56_project_maize_v4v5 58_expression_attributes 60_solr_genes 65_solr_suggestions 70_services

28_grassius_source:
	bash $(ST)/28_grassius_source.sh

# ── on-demand ATOMIC refresh of ONE post-dump attribute layer ────────────────
# Patches that layer into the genes core IN PLACE via Solr atomic updates (no drop /
# no downtime) and partially rebuilds any suggestion category it feeds. For when ONLY
# that attribute changed (the decorated genes are unchanged). Requires a fully-loaded
# genes core. Heavier alternative that reloads all 5.2M docs: `make refresh-attributes`.
#   make refresh-attr ATTR=expression     (or maker | vep | grassius)
refresh-attr:
	@[ -n "$(ATTR)" ] || { echo "usage: make refresh-attr ATTR=<maker|vep|grassius|expression>"; exit 2; }
	bash $(ST)/62_attr_atomic.sh $(ATTR)
refresh-maker:            ; bash $(ST)/62_attr_atomic.sh maker
refresh-vep:              ; bash $(ST)/62_attr_atomic.sh vep
refresh-grassius-homolog: ; bash $(ST)/62_attr_atomic.sh grassius
refresh-expression-attrs: ; bash $(ST)/62_attr_atomic.sh expression

# default: full index. The genes core now includes expression: 60_solr_genes depends on
# 58_expression_attributes -> 55_atlas, so `make all` builds the expression collection,
# the expression_attributes (mongo-native pipeline), and merges them into the solr genes.
all: $(S)/52_tree_domains.done $(S)/22_germplasm.done $(S)/65_solr_suggestions.done
	@echo "BUILD COMPLETE — mongo + solr genes + suggestions ready"

mongo: $(S)/52_tree_domains.done
solr:  $(S)/65_solr_suggestions.done
index: $(S)/65_solr_suggestions.done

# ---- stamp targets (prereqs encode the dependency graph) ----
$(S)/05_install.done:
	bash $(ST)/05_install.sh
$(S)/00_preflight.done: $(S)/05_install.done
	bash $(ST)/00_preflight.sh
$(S)/10_maps.done: $(S)/00_preflight.done
	bash $(ST)/10_maps.sh
$(S)/15_ontologies.done: $(S)/10_maps.done
	bash $(ST)/15_ontologies.sh
$(S)/20_variation.done: $(S)/10_maps.done
	bash $(ST)/20_variation.sh
$(S)/22_germplasm.done: $(S)/00_preflight.done
	bash $(ST)/22_germplasm.sh
$(S)/25_reactome.done: $(S)/10_maps.done
	bash $(ST)/25_reactome.sh
$(S)/30_curated.done: $(S)/00_preflight.done
	bash $(ST)/30_curated.sh
$(S)/35_genetrees.done: $(S)/30_curated.done $(S)/10_maps.done
	bash $(ST)/35_genetrees.sh
$(S)/40_genes_dump.done: $(S)/10_maps.done
	bash $(ST)/40_genes_dump.sh
$(S)/45_homologs.done: $(S)/00_preflight.done
	bash $(ST)/45_homologs.sh
$(S)/50_genes_decorate.done: $(S)/15_ontologies.done $(S)/20_variation.done $(S)/25_reactome.done \
                            $(S)/35_genetrees.done $(S)/40_genes_dump.done $(S)/45_homologs.done
	bash $(ST)/50_genes_decorate.sh
$(S)/52_tree_domains.done: $(S)/50_genes_decorate.done $(S)/15_ontologies.done
	bash $(ST)/52_tree_domains.sh
$(S)/55_atlas.done: $(S)/10_maps.done
	bash $(ST)/55_atlas.sh
$(S)/56_project_maize_v4v5.done: $(S)/55_atlas.done
	bash $(ST)/56_project_maize_v4v5.sh
$(S)/58_expression_attributes.done: $(S)/56_project_maize_v4v5.done $(S)/50_genes_decorate.done
	bash $(ST)/58_expression_attributes.sh
$(S)/60_solr_genes.done: $(S)/50_genes_decorate.done $(S)/58_expression_attributes.done
	bash $(ST)/60_solr_genes.sh
$(S)/65_solr_suggestions.done: $(S)/60_solr_genes.done
	bash $(ST)/65_solr_suggestions.sh
$(S)/70_services.done: $(S)/65_solr_suggestions.done
	bash $(ST)/70_services.sh

# ---- convenience phony aliases: `make 25_reactome` etc. ----
00_preflight: $(S)/00_preflight.done
05_install: $(S)/05_install.done
10_maps: $(S)/10_maps.done
15_ontologies: $(S)/15_ontologies.done
20_variation: $(S)/20_variation.done
22_germplasm: $(S)/22_germplasm.done
25_reactome: $(S)/25_reactome.done
30_curated: $(S)/30_curated.done
35_genetrees: $(S)/35_genetrees.done
40_genes_dump: $(S)/40_genes_dump.done
45_homologs: $(S)/45_homologs.done
50_genes_decorate: $(S)/50_genes_decorate.done
52_tree_domains: $(S)/52_tree_domains.done
55_atlas: $(S)/55_atlas.done
56_project_maize_v4v5: $(S)/56_project_maize_v4v5.done
58_expression_attributes: $(S)/58_expression_attributes.done
60_solr_genes: $(S)/60_solr_genes.done
65_solr_suggestions: $(S)/65_solr_suggestions.done
70_services: $(S)/70_services.done

status:
	@for s in 00_preflight 05_install 10_maps 15_ontologies 20_variation 22_germplasm 25_reactome 28_grassius_source 30_curated \
	          35_genetrees 40_genes_dump 45_homologs 50_genes_decorate 52_tree_domains 55_atlas \
	          56_project_maize_v4v5 58_expression_attributes 60_solr_genes 65_solr_suggestions 70_services; do \
	  if [ -f $(S)/$$s.done ]; then echo "  [x] $$s ($$(cat $(S)/$$s.done))"; else echo "  [ ] $$s"; fi; \
	done

# `make running` — liveness (status only shows COMPLETED stamps, not what's active)
running:
	@procs=$$(pgrep -af 'make (all|[0-9])|stages/[0-9]|decorate\.js|mongo2solr|solr_chunk_load|add_attributes\.pl|suggestions/(aux|genes)\.js|dump_genes|dump_homologs|genetree\.js|parseData|project_expression|expression_attributes_table|grassius_homolog_table|attr_table_to_atomic|solr_atomic_attr|62_attr_atomic' | grep -v 'grep\|pgrep' || true); \
	if [ -n "$$procs" ]; then echo "RUNNING:"; echo "$$procs" | sed 's/^/  /'; \
	else echo "idle — no build stage is running"; fi; \
	echo "--- most recent log activity ---"; ls -lt logs/*.log 2>/dev/null | head -3 | awk '{print "  "$$6" "$$7" "$$8"  "$$NF}'

clean-stamps:
	rm -f $(S)/*.done && echo "stamps cleared (data untouched)"

# ---- targeted refresh entry points for new upstream data ----
# Each invalidates the stamps that must rebuild, then runs `all`.
refresh-compara:
	rm -f $(S)/35_genetrees.done $(S)/45_homologs.done $(S)/50_genes_decorate.done \
	      $(S)/52_tree_domains.done $(S)/60_solr_genes.done $(S)/65_solr_suggestions.done
	$(MAKE) all
refresh-genes:
	rm -f $(S)/40_genes_dump.done $(S)/50_genes_decorate.done $(S)/52_tree_domains.done \
	      $(S)/60_solr_genes.done $(S)/65_solr_suggestions.done
	$(MAKE) all
refresh-expression:
	rm -f $(S)/55_atlas.done $(S)/56_project_maize_v4v5.done $(S)/58_expression_attributes.done $(S)/60_solr_genes.done $(S)/65_solr_suggestions.done
	$(MAKE) all
refresh-reactome:
	rm -f $(S)/25_reactome.done $(S)/50_genes_decorate.done $(S)/52_tree_domains.done \
	      $(S)/60_solr_genes.done $(S)/65_solr_suggestions.done
	$(MAKE) all
refresh-ontologies:
	rm -f $(S)/15_ontologies.done $(S)/50_genes_decorate.done $(S)/52_tree_domains.done \
	      $(S)/60_solr_genes.done $(S)/65_solr_suggestions.done
	$(MAKE) all
# refresh direct Grassius TF families from the grassius.org source (merged into
# grassius.tsv), then re-decorate + rebuild solr so it (and grassius_homolog) update.
refresh-grassius:
	bash stages/28_grassius_source.sh
	rm -f $(S)/50_genes_decorate.done $(S)/52_tree_domains.done \
	      $(S)/60_solr_genes.done $(S)/65_solr_suggestions.done
	$(MAKE) all
# refresh the solr-gene attribute tables (MAKER/VEP/grassius_homolog/expression)
# without re-decorating — regenerates solr_genes.attribs.json + rebuilds the genes
# core, THEN rebuilds the suggestion categories that are FACETED from those
# attributes (TF families from grassius_homolog; Expression categories from expr_*).
# Reuses the unchanged base genes (solr_genes.json) and gene-level suggestions
# (genes.json) — only the attribute merge + aux suggestion categories rebuild.
# Use this when the expression_attributes collection (or a grassius/MAKER/VEP table)
# changes but the decorated genes do not.
refresh-attributes:
	rm -f $(S)/60_solr_genes.done ../gramene-solr/genes/solr_genes.attribs.json
	REBUILD_CORE=1 $(MAKE) 60_solr_genes
	rm -f $(S)/65_solr_suggestions.done
	REGEN_AUX=1 $(MAKE) 65_solr_suggestions
