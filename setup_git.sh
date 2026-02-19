#!/bin/bash

# Git + GitHub SSH setup helper for a new machine/user account.
# Generates an SSH key, adds it to ssh-agent, and shows where to add it on GitHub.

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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

ensure_not_root() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        handle_error "Run this script as your regular user, not root."
    fi
}

ensure_dependencies() {
    local missing=()
    command_exists git || missing+=("git")
    command_exists ssh-keygen || missing+=("openssh-client")
    command_exists ssh-agent || missing+=("openssh-client")
    command_exists ssh-add || missing+=("openssh-client")

    if [[ ${#missing[@]} -gt 0 ]]; then
        handle_error "Missing required tools: ${missing[*]}. Install them first."
    fi
}

configure_git_identity() {
    local current_name current_email
    current_name="$(git config --global user.name || true)"
    current_email="$(git config --global user.email || true)"

    print_info "Current global git identity:"
    print_info "  user.name: ${current_name:-<not set>}"
    print_info "  user.email: ${current_email:-<not set>}"

    local name email
    read -r -p "Git user.name [${current_name:-Your Name}]: " name
    read -r -p "Git user.email [${current_email:-you@example.com}]: " email
    name="${name:-$current_name}"
    email="${email:-$current_email}"

    [[ -n "$name" ]] || handle_error "Git user.name cannot be empty"
    [[ -n "$email" ]] || handle_error "Git user.email cannot be empty"

    git config --global user.name "$name"
    git config --global user.email "$email"
    print_success "Global git identity updated"
}

ensure_ssh_dir() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
}

generate_or_reuse_key() {
    local email="$1"
    local default_key_name="id_ed25519_github"
    local key_name key_path

    read -r -p "SSH key filename [$default_key_name]: " key_name
    key_name="${key_name:-$default_key_name}"
    key_path="$HOME/.ssh/$key_name"

    if [[ -f "$key_path" ]]; then
        print_warning "Key already exists: $key_path"
        read -r -p "Reuse existing key instead of creating a new one? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo "$key_path"
            return 0
        fi
        read -r -p "Overwrite existing key at $key_path? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            handle_error "Aborted to avoid overwriting existing key"
        fi
        rm -f "$key_path" "$key_path.pub"
    fi

    print_info "Generating SSH key..."
    if ssh-keygen -t ed25519 -C "$email" -f "$key_path"; then
        chmod 600 "$key_path"
        chmod 644 "$key_path.pub"
        print_success "Generated key: $key_path"
    else
        handle_error "Failed to generate SSH key"
    fi

    echo "$key_path"
}

add_key_to_agent() {
    local key_path="$1"

    print_info "Starting ssh-agent..."
    eval "$(ssh-agent -s)" >/dev/null

    if ssh-add "$key_path"; then
        print_success "Added key to ssh-agent"
    else
        handle_error "Failed to add key to ssh-agent"
    fi
}

ensure_ssh_config_entry() {
    local key_path="$1"
    local config_file="$HOME/.ssh/config"

    touch "$config_file"
    chmod 600 "$config_file"

    if grep -qE "^[[:space:]]*Host[[:space:]]+github\\.com([[:space:]]|$)" "$config_file"; then
        print_info "Host github.com already exists in ~/.ssh/config (left unchanged)"
        return 0
    fi

    cat >> "$config_file" <<EOF

Host github.com
    HostName github.com
    User git
    IdentityFile $key_path
    IdentitiesOnly yes
EOF
    print_success "Added github.com SSH config entry"
}

show_next_steps() {
    local key_path="$1"
    local pub_key_path="${key_path}.pub"

    echo
    print_info "Copy this PUBLIC key and add it to GitHub:"
    echo "────────────────────────────────────────────────────────────────────────────"
    cat "$pub_key_path"
    echo "────────────────────────────────────────────────────────────────────────────"
    echo
    print_info "GitHub page for SSH keys:"
    print_info "  https://github.com/settings/keys"
    print_info "Click: New SSH key"
    print_info "  - Title: any label for this server (for example: $(hostname)-$(date +%Y%m%d))"
    print_info "  - Key type: Authentication Key"
    print_info "  - Key: paste the PUBLIC key shown above"
    echo
    print_warning "Never share your private key: $key_path"
    print_info "After adding the key, test with:"
    print_info "  ssh -T git@github.com"
}

main() {
    print_info "Starting Git + GitHub SSH setup..."
    ensure_not_root
    ensure_dependencies
    ensure_ssh_dir

    configure_git_identity

    local key_email
    key_email="$(git config --global user.email || true)"
    if [[ -z "$key_email" ]]; then
        read -r -p "Email for SSH key comment: " key_email
    else
        read -r -p "Email for SSH key comment [$key_email]: " key_email_input
        key_email="${key_email_input:-$key_email}"
    fi
    [[ -n "$key_email" ]] || handle_error "Email for SSH key comment is required"

    local key_path
    key_path="$(generate_or_reuse_key "$key_email")"
    add_key_to_agent "$key_path"
    ensure_ssh_config_entry "$key_path"
    show_next_steps "$key_path"
}

main "$@"
