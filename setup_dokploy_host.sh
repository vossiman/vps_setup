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

preflight() {
    print_step "Preflight checks..."

    if [[ $EUID -ne 0 ]]; then
        handle_error "This script must be run as root (use sudo)"
    fi
    print_success "Running as root"

    if [[ ! -f /etc/os-release ]]; then
        handle_error "/etc/os-release not found — cannot detect OS"
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian)
            print_success "Detected supported OS: ${PRETTY_NAME:-$ID}"
            ;;
        *)
            handle_error "Unsupported OS: ${PRETTY_NAME:-$ID}. This script targets Ubuntu/Debian."
            ;;
    esac

    if [[ -d /etc/dokploy ]] && command_exists docker; then
        print_success "Dokploy environment detected (/etc/dokploy + docker)"
    else
        print_warning "Dokploy not detected (/etc/dokploy missing or 'docker' not on PATH)"
        print_warning "This script is intended to run AFTER Dokploy installation."
        print_warning "It will continue, but Dokploy-specific verifications will not run."
    fi
}

phase_user() {
    print_step "Phase 1: User account"

    local username
    while true; do
        read -r -p "Enter username to create/configure [vossi]: " username
        username="${username:-vossi}"
        if [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            break
        fi
        print_warning "Invalid username. Use lowercase letters, numbers, underscores, or hyphens."
    done
    print_info "Using username: $username"

    if id "$username" &>/dev/null; then
        print_success "User '$username' already exists"
    else
        if adduser --disabled-password --gecos "" "$username"; then
            print_success "User '$username' created"
        else
            handle_error "Failed to create user '$username'"
        fi

        echo
        print_info "Set a password for '$username' (used for sudo, not SSH login):"
        if passwd "$username"; then
            print_success "Password set for '$username'"
        else
            print_warning "Failed to set password — you can set it later with: passwd $username"
        fi
    fi

    if usermod -aG sudo "$username"; then
        print_success "Added '$username' to sudo group"
    else
        handle_error "Failed to add '$username' to sudo group"
    fi

    if usermod -aG docker "$username"; then
        print_success "Added '$username' to docker group"
    else
        handle_error "Failed to add '$username' to docker group (is the docker group present? Dokploy installs Docker which creates it)"
    fi

    if ! groups "$username" | grep -qw sudo; then
        handle_error "Verification failed: '$username' is not in sudo group"
    fi
    if ! getent group docker | grep -qw "$username"; then
        handle_error "Verification failed: '$username' is not in docker group"
    fi
    print_success "Verified: '$username' is in both sudo and docker groups"

    # Export for use by later phases
    SETUP_USERNAME="$username"
}

main() {
    local SETUP_USERNAME=""

    echo
    print_info "🚀 Starting Dokploy host setup..."
    echo
    preflight
    echo
    phase_user
    echo
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
