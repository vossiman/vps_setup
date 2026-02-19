#!/bin/bash

# Locale detection and repair script for Debian/Ubuntu systems.
# Detects configured locales that are missing from locale -a and fixes them.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

handle_error() {
    print_error "$1"
    exit 1
}

normalize_locale() {
    local value="$1"
    value="${value%\"}"
    value="${value#\"}"
    value="${value,,}"
    value="${value//utf-8/utf8}"
    echo "$value"
}

is_special_locale() {
    local value
    value="$(normalize_locale "$1")"
    [[ "$value" == "c" || "$value" == "posix" ]]
}

extract_locales_from_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    awk '
        /^[[:space:]]*#/ { next }
        {
            line=$0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            sub(/^export[[:space:]]+/, "", line)
            if (line ~ /^(LANG|LC_ALL|LC_[A-Z_]+)=/) {
                split(line, kv, "=")
                val=substr(line, length(kv[1]) + 2)
                gsub(/^"|"$/, "", val)
                gsub(/^'\''|'\''$/, "", val)
                if (val != "") print val
            }
        }
    ' "$file"
}

collect_configured_locales() {
    {
        locale 2>/dev/null | awk -F= '
            /^(LANG|LC_ALL|LC_[A-Z_]+)=/ {
                gsub(/"/, "", $2)
                if ($2 != "") print $2
            }
        '
        env | awk -F= '
            /^(LANG|LC_ALL|LC_[A-Z_]+)=/ {
                if ($2 != "") print $2
            }
        '
        [[ -n "${LC_ALL:-}" ]] && echo "$LC_ALL"
        [[ -n "${LANG:-}" ]] && echo "$LANG"
        extract_locales_from_file "/etc/default/locale"
        extract_locales_from_file "/etc/environment"
        extract_locales_from_file "/root/.profile"
        extract_locales_from_file "/root/.bashrc"
        extract_locales_from_file "$HOME/.profile"
        extract_locales_from_file "$HOME/.bashrc"
    } | awk 'NF' | sort -u
}

locale_exists() {
    local target
    target="$(normalize_locale "$1")"
    grep -qx "$target" <<<"$NORMALIZED_AVAILABLE_LOCALES"
}

ensure_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        handle_error "Please run as root: sudo bash get_locale.sh"
    fi
}

install_locales_package() {
    if command -v locale-gen >/dev/null 2>&1 && command -v update-locale >/dev/null 2>&1; then
        return 0
    fi

    print_info "Installing locales package..."
    apt update
    apt install -y locales
}

generate_missing_locales() {
    local missing=("$@")
    print_info "Generating missing locales: ${missing[*]}"
    locale-gen "${missing[@]}"
}

main() {
    if ! command -v locale >/dev/null 2>&1; then
        handle_error "'locale' command not found on this system"
    fi

    local available_locales
    available_locales="$(locale -a 2>/dev/null || true)"
    NORMALIZED_AVAILABLE_LOCALES="$(echo "$available_locales" | awk 'NF {print tolower($0)}' | sed 's/utf-8/utf8/g')"

    local configured_raw
    configured_raw="$(collect_configured_locales)"

    # Optional explicit locale(s) as arguments:
    # sudo ./get_locale.sh de_AT.UTF-8 en_US.UTF-8
    if [[ $# -gt 0 ]]; then
        configured_raw+=$'\n'"$(printf '%s\n' "$@")"
    fi

    if [[ -z "$configured_raw" ]]; then
        print_warning "No configured locale variables found (LANG/LC_* are empty)."
        print_info "Nothing to repair."
        exit 0
    fi

    local -a configured=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if is_special_locale "$line"; then
            continue
        fi
        configured+=("$line")
    done <<<"$configured_raw"

    if [[ ${#configured[@]} -eq 0 ]]; then
        print_info "Only C/POSIX locales are configured. Nothing to repair."
        exit 0
    fi

    local -a missing=()
    local locale_name
    for locale_name in "${configured[@]}"; do
        if ! locale_exists "$locale_name"; then
            missing+=("$locale_name")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        print_success "All discovered locale settings are available. No changes needed."
        exit 0
    fi

    print_warning "Missing configured locale(s): ${missing[*]}"
    ensure_root
    install_locales_package
    generate_missing_locales "${missing[@]}"

    # Set system defaults to currently configured values if they were missing.
    local update_args=()
    if [[ -n "${LANG:-}" ]] && ! is_special_locale "${LANG:-}"; then
        update_args+=("LANG=$LANG")
    fi
    if [[ -n "${LC_ALL:-}" ]] && ! is_special_locale "${LC_ALL:-}"; then
        update_args+=("LC_ALL=$LC_ALL")
    fi

    if [[ ${#update_args[@]} -gt 0 ]]; then
        print_info "Updating system locale defaults: ${update_args[*]}"
        update-locale "${update_args[@]}"
    fi

    print_success "Locale repair finished."
    print_info "Open a new shell session (or reboot) to apply updated locale defaults."
}

main "$@"
