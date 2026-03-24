#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Shared logging/color functions for Golden Image Builder
# ═══════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}  ✔  ${NC}${BOLD}$1${NC}"; }
warn()  { echo -e "${YELLOW}  ⚠  ${NC}$1"; }
err()   { echo -e "${RED}  ✖  ${NC}$1" >&2; }
info()  { echo -e "${MAGENTA}  ▶  ${BOLD}$1${NC}"; }
step()  {
    local num="$1"; shift
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║  ${BOLD}STEP ${num} │ $1${BLUE}${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
}
banner() {
    echo -e "${BOLD}${CYAN}"
    echo "══════════════════════════════════════════════════════════"
    echo "  $1"
    echo "══════════════════════════════════════════════════════════"
    echo -e "${NC}"
}
die() { err "$1"; exit 1; }
