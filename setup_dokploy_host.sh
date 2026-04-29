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

    # Dokploy was installed as root; its server-health check inspects whether
    # the install user (root) is in the docker group. Adding root to docker
    # is a no-op for capabilities (root already has all privileges) but
    # silences Dokploy's check.
    if usermod -aG docker root; then
        print_success "Added 'root' to docker group (satisfies Dokploy's check)"
    else
        print_warning "Could not add 'root' to docker group — Dokploy may continue to flag it"
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

validate_ssh_key() {
    local key="$1"
    if [[ ! "$key" =~ ^(ssh-(rsa|dss|ed25519|ecdsa)|sk-(ssh-ed25519|ecdsa-sha2-nistp256))(@openssh\.com)? ]]; then
        return 1
    fi
    local parts_count
    parts_count=$(echo "$key" | wc -w)
    if [[ $parts_count -lt 2 ]]; then
        return 1
    fi
    return 0
}

phase_ssh_key() {
    print_step "Phase 2: SSH public key for '$SETUP_USERNAME'"

    local home_dir="/home/$SETUP_USERNAME"
    local ssh_dir="$home_dir/.ssh"
    local auth_keys="$ssh_dir/authorized_keys"
    local ssh_key=""

    echo
    echo "═══════════════════════════════════════════════════════════════════════════════"
    print_info "PURPOSE: Enable passwordless SSH login for '$SETUP_USERNAME'"
    print_info "KEY TYPE: Paste your SSH PUBLIC KEY (the .pub file, NOT the private key)"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo
    print_step "👉 PASTE YOUR SSH PUBLIC KEY NOW (then press Enter):"
    echo
    printf "> "
    read -r ssh_key

    if [[ -z "$ssh_key" ]]; then
        handle_error "No SSH key provided"
    fi
    if ! validate_ssh_key "$ssh_key"; then
        handle_error "Invalid SSH key format. Expected one of: ssh-rsa, ssh-ed25519, ssh-ecdsa, ssh-dss, sk-ssh-ed25519@openssh.com, sk-ecdsa-sha2-nistp256@openssh.com"
    fi
    print_success "SSH key format looks valid"

    sudo -u "$SETUP_USERNAME" mkdir -p "$ssh_dir"     || handle_error "Failed to create $ssh_dir"
    sudo -u "$SETUP_USERNAME" chmod 700 "$ssh_dir"    || handle_error "Failed to chmod 700 $ssh_dir"
    sudo -u "$SETUP_USERNAME" touch "$auth_keys"      || handle_error "Failed to create $auth_keys"
    sudo -u "$SETUP_USERNAME" chmod 600 "$auth_keys"  || handle_error "Failed to chmod 600 $auth_keys"

    if echo "$ssh_key" | sudo -u "$SETUP_USERNAME" tee "$auth_keys" > /dev/null; then
        print_success "Wrote authorized_keys for '$SETUP_USERNAME'"
    else
        handle_error "Failed to write authorized_keys"
    fi

    if ! sudo -u "$SETUP_USERNAME" grep -q '^ssh-' "$auth_keys"; then
        handle_error "Verification failed: no SSH key in $auth_keys"
    fi
    print_success "Verified: SSH key written"
}

backup_ssh_config() {
    local config_file="/etc/ssh/sshd_config"
    local backup_file="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"

    if cp "$config_file" "$backup_file"; then
        print_success "Backed up sshd_config to: $backup_file"
        SSHD_BACKUP_FILE="$backup_file"
    else
        handle_error "Failed to back up sshd_config"
    fi
}

handle_sshd_config_d() {
    local config_dir="/etc/ssh/sshd_config.d"
    local backup_dir="/etc/ssh/sshd_config.d.backup.$(date +%Y%m%d_%H%M%S)"

    if [[ ! -d "$config_dir" ]]; then
        print_info "No sshd_config.d directory found, skipping"
        return 0
    fi

    print_step "Scrubbing conflicting settings from sshd_config.d/*.conf..."

    if cp -r "$config_dir" "$backup_dir" 2>/dev/null; then
        print_success "Backed up $config_dir to: $backup_dir"
    fi

    local conflicting_settings=(
        "PasswordAuthentication"
        "PubkeyAuthentication"
        "PermitRootLogin"
        "ChallengeResponseAuthentication"
        "KbdInteractiveAuthentication"
        "UsePAM"
        "X11Forwarding"
        "PrintMotd"
        "AcceptEnv"
        "Subsystem"
    )

    local fixed_count=0
    while IFS= read -r -d '' file; do
        [[ -f "$file" ]] || continue
        local filename
        filename=$(basename "$file")
        local has_conflicts=false
        for setting in "${conflicting_settings[@]}"; do
            if grep -qE "^[[:space:]]*${setting}([[:space:]]|$)" "$file" 2>/dev/null; then
                if [[ "$has_conflicts" == false ]]; then
                    print_warning "Stripping conflicting settings from $filename"
                    has_conflicts=true
                    fixed_count=$((fixed_count + 1))
                fi
                sed -i -E "/^[[:space:]]*${setting}([[:space:]]|$)/d" "$file"
            fi
        done
    done < <(find "$config_dir" -type f -name "*.conf" -print0 2>/dev/null)

    if [[ $fixed_count -gt 0 ]]; then
        print_success "Scrubbed $fixed_count file(s) in sshd_config.d"
    else
        print_info "No conflicting settings in sshd_config.d"
    fi
}

set_ssh_config() {
    local setting="$1"
    local value="$2"
    local config_file="/etc/ssh/sshd_config"
    sed -i -E "/^#*[[:space:]]*${setting}([[:space:]]|$)/d" "$config_file"
    echo "$setting $value" >> "$config_file"
}

phase_ssh_harden() {
    print_step "Phase 3: Hardening SSH"

    backup_ssh_config
    handle_sshd_config_d

    print_step "Writing hardened sshd_config..."
    set_ssh_config "PasswordAuthentication"          "no"
    set_ssh_config "PubkeyAuthentication"            "yes"
    set_ssh_config "PermitRootLogin"                 "prohibit-password"
    set_ssh_config "ChallengeResponseAuthentication" "no"
    set_ssh_config "KbdInteractiveAuthentication"    "no"
    set_ssh_config "UsePAM"                          "yes"
    set_ssh_config "X11Forwarding"                   "no"
    set_ssh_config "PrintMotd"                       "no"
    set_ssh_config "AcceptEnv"                       "LANG LC_*"
    set_ssh_config "Subsystem"                       "sftp /usr/lib/openssh/sftp-server"
    print_success "Wrote hardened sshd_config"

    print_step "Validating sshd_config syntax..."
    if sshd -t; then
        print_success "sshd config syntax valid"
    else
        handle_error "sshd -t failed — config invalid. NOT restarting sshd. Restore from $SSHD_BACKUP_FILE"
    fi

    print_step "Restarting ssh service..."
    if systemctl restart ssh; then
        print_success "ssh service restarted"
    else
        handle_error "Failed to restart ssh — restore from $SSHD_BACKUP_FILE"
    fi
    sleep 2
    if systemctl is-active --quiet ssh; then
        print_success "ssh service is running"
    else
        handle_error "ssh service is not running — restore from $SSHD_BACKUP_FILE"
    fi
}

phase_fail2ban() {
    print_step "Phase 4: Fail2Ban"

    if ! command_exists fail2ban-client; then
        print_step "Installing fail2ban..."
        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get update >/dev/null; then
            handle_error "apt-get update failed (see stderr for details)"
        fi
        if ! apt-get install -y fail2ban >/dev/null; then
            handle_error "Failed to install fail2ban (see stderr for details)"
        fi
        print_success "fail2ban installed"
    else
        print_success "fail2ban already installed"
    fi

    # Dokploy's server audit reads /etc/fail2ban/jail.local specifically
    # (see Dokploy: packages/server/src/setup/server-audit.ts validateFail2ban).
    # If we wrote to jail.d/sshd.local instead, fail2ban itself would honor
    # it but Dokploy's UI would still report SSH Protection as disabled.
    # backend=systemd reads from journald (Ubuntu 24.04+ stopped writing
    # /var/log/auth.log by default).
    local jail_file="/etc/fail2ban/jail.local"
    print_step "Writing $jail_file..."
    cat > "$jail_file" <<'EOF'
[sshd]
enabled = true
port = ssh
backend = systemd
maxretry = 5
findtime = 10m
bantime = 10m
EOF
    print_success "Wrote sshd jail config"

    # Remove the legacy jail.d/sshd.local from prior runs of this script.
    # Both files defining [sshd] would work for fail2ban (no conflict), but
    # a single source of truth is cleaner.
    if [[ -f /etc/fail2ban/jail.d/sshd.local ]]; then
        rm -f /etc/fail2ban/jail.d/sshd.local
        print_info "Removed legacy /etc/fail2ban/jail.d/sshd.local"
    fi

    if systemctl enable --now fail2ban >/dev/null 2>&1; then
        print_success "fail2ban enabled and started"
    else
        handle_error "Failed to enable/start fail2ban"
    fi

    sleep 1
    if systemctl is-active --quiet fail2ban; then
        print_success "fail2ban service is active"
    else
        handle_error "fail2ban service did not start cleanly — check 'journalctl -u fail2ban'"
    fi
}

phase_ufw() {
    print_step "Phase 5: UFW firewall"

    if ! command_exists ufw; then
        print_step "Installing ufw..."
        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get update >/dev/null; then
            handle_error "apt-get update failed (see stderr for details)"
        fi
        if ! apt-get install -y ufw >/dev/null; then
            handle_error "Failed to install ufw (see stderr for details)"
        fi
        print_success "ufw installed"
    else
        print_success "ufw already installed"
    fi

    print_step "Setting default policies..."
    ufw default deny incoming  >/dev/null || handle_error "Failed: ufw default deny incoming"
    ufw default allow outgoing >/dev/null || handle_error "Failed: ufw default allow outgoing"
    print_success "Defaults: deny incoming, allow outgoing"

    print_step "Adding allow rules (SSH first, before enabling)..."
    ufw allow 22/tcp  comment 'SSH'                       >/dev/null || handle_error "Failed: allow 22/tcp"
    ufw allow 80/tcp  comment 'HTTP / Traefik'            >/dev/null || handle_error "Failed: allow 80/tcp"
    ufw allow 443/tcp comment 'HTTPS / Traefik'           >/dev/null || handle_error "Failed: allow 443/tcp"
    ufw allow 443/udp comment 'HTTP/3 (QUIC) / Traefik'   >/dev/null || handle_error "Failed: allow 443/udp"
    print_success "Rules added: 22/tcp, 80/tcp, 443/tcp, 443/udp"

    print_step "Enabling ufw..."
    if ufw --force enable >/dev/null; then
        print_success "ufw enabled"
    else
        handle_error "Failed to enable ufw"
    fi

    if systemctl is-active --quiet ufw; then
        print_success "ufw service is active"
    else
        print_warning "ufw service not reported active by systemctl — verify with 'ufw status'"
    fi

    print_info "Current ufw status:"
    ufw status verbose
}

phase_deploy_repo() {
    print_step "Phase 6: Copy repo to /home/$SETUP_USERNAME/"

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    local repo_name
    repo_name="$(basename "$script_dir")"
    local target_repo_dir="/home/$SETUP_USERNAME/$repo_name"

    if [[ "$script_dir" == "$target_repo_dir" ]]; then
        print_info "Repository is already at $target_repo_dir, nothing to do"
        DEPLOYED_REPO_DIR="$target_repo_dir"
        return 0
    fi

    if [[ -e "$target_repo_dir" ]]; then
        print_warning "Target already exists: $target_repo_dir"
        print_warning "Skipping deploy. To re-deploy: rm -rf $target_repo_dir, then re-run."
        DEPLOYED_REPO_DIR="$target_repo_dir"
        return 0
    fi

    if cp -a "$script_dir" "/home/$SETUP_USERNAME/"; then
        print_success "Copied repo to $target_repo_dir"
    else
        handle_error "Failed to copy repo"
    fi

    if chown -R "$SETUP_USERNAME:$SETUP_USERNAME" "$target_repo_dir"; then
        print_success "chowned $target_repo_dir to $SETUP_USERNAME:$SETUP_USERNAME"
    else
        handle_error "Failed to chown $target_repo_dir"
    fi

    chmod 700 "$target_repo_dir/setup_git.sh" 2>/dev/null && \
        print_success "setup_git.sh is executable" || \
        print_warning "Could not chmod setup_git.sh (file may be missing)"

    DEPLOYED_REPO_DIR="$target_repo_dir"
}

phase_summary() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    echo
    echo "======================================================================"
    print_success "🎉 Dokploy host setup complete"
    echo "======================================================================"
    echo
    print_info "User"
    print_info "  • Username:      $SETUP_USERNAME"
    print_info "  • Groups:        sudo, docker"
    print_info "  • SSH key:       installed in /home/$SETUP_USERNAME/.ssh/authorized_keys"
    echo
    print_info "SSH"
    print_info "  • PasswordAuthentication: disabled"
    print_info "  • PubkeyAuthentication:   enabled"
    print_info "  • PermitRootLogin:        prohibit-password (root key still works)"
    print_info "  • Backup of old config:   $SSHD_BACKUP_FILE"
    echo
    print_info "Firewall + Fail2Ban"
    print_info "  • UFW:        active (22/tcp, 80/tcp, 443/tcp, 443/udp)"
    print_info "  • Fail2Ban:   active (sshd jail, 5 fails / 10 min / 10 min ban)"
    echo
    print_info "Connection details"
    print_info "  • SSH:        ssh $SETUP_USERNAME@$server_ip"
    if [[ -n "$DEPLOYED_REPO_DIR" ]]; then
        print_info "  • Optional:   bash $DEPLOYED_REPO_DIR/setup_git.sh   (run as $SETUP_USERNAME)"
    fi
    echo
    print_warning "🚨 Test the new login in a SECOND terminal before closing this one."
    echo
    print_info "If the new SSH login fails, restore the old sshd_config:"
    print_info "  cp $SSHD_BACKUP_FILE /etc/ssh/sshd_config && systemctl restart ssh"
    print_info "If you ever need to disable UFW from this session:  ufw disable"
    echo
}

main() {
    local SETUP_USERNAME=""
    local SSHD_BACKUP_FILE=""
    local DEPLOYED_REPO_DIR=""

    echo
    print_info "🚀 Starting Dokploy host setup..."
    echo
    preflight
    echo
    phase_user
    echo
    phase_ssh_key
    echo
    phase_ssh_harden
    echo
    phase_fail2ban
    echo
    phase_ufw
    echo
    phase_deploy_repo
    echo
    phase_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
