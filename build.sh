#!/usr/bin/env bash
# build.sh — thin entry point. Delegates to the Makefile (the real orchestrator).
#   ./build.sh            -> make all
#   ./build.sh status     -> make status
#   ./build.sh 25_reactome -> make 25_reactome
#   ./build.sh refresh-compara
cd "$(dirname "$0")"
exec make "${@:-all}"
