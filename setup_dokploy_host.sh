#!/bin/bash

# setup_dokploy_host.sh
# Post-Dokploy host hardening: creates a non-root sudo+docker user,
# hardens SSH, installs and enables UFW + Fail2Ban.
# Run as root after Dokploy has been installed.

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_step()    { echo -e "${CYAN}[STEP]${NC} $1"; }

handle_error() {
    print_error "$1"
    print_error "Setup failed. Exiting..."
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

main() {
    print_info "Skeleton — phases not yet implemented."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
