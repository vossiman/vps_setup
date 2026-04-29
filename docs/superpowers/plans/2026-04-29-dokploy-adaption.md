# Dokploy Host Adaptation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `setup_new_host.sh` + `install_docker_stuff.sh` with a single `setup_dokploy_host.sh` that prepares a Dokploy-already-installed Hetzner box (vossi user with sudo + docker group, hardened SSH, UFW, Fail2Ban).

**Architecture:** Single root-run Bash script. `main()` calls phase functions in order: `preflight → phase_user → phase_ssh_key → phase_ssh_harden → phase_fail2ban → phase_ufw → phase_deploy_repo → phase_summary`. Reuses helpers from the old `setup_new_host.sh` (`print_*`, `handle_error`, `set_ssh_config`, `handle_sshd_config_d`) verbatim. `set -e` for fail-fast. All operations idempotent so re-running is safe.

**Tech Stack:** Bash 5.x, Ubuntu/Debian apt, OpenSSH, ufw, fail2ban.

**Branch:** `dokploy-adaption` (already created and on the spec commit).

**Spec:** `docs/superpowers/specs/2026-04-29-dokploy-adaption-design.md`

**Validation strategy (no test framework — matches repo culture):**
- After every code change: `bash -n setup_dokploy_host.sh` (parse check)
- After significant additions: `shellcheck setup_dokploy_host.sh` (must be clean or only have suppressed warnings explained in comments)
- Full end-to-end is the manual test plan in spec §11 — only run after Task 13

---

## Task 1: Delete dead scripts, create skeleton with shared helpers

**Files:**
- Delete: `install_docker_stuff.sh`
- Delete: `setup_new_host.sh`
- Create: `setup_dokploy_host.sh`

- [ ] **Step 1: Save the old helpers we're going to reuse**

The old `setup_new_host.sh` has helper functions we'll copy verbatim into the new script. Read it once to keep the contents in mind:

```bash
cat setup_new_host.sh
```

The functions we'll reuse: `print_error`, `print_success`, `print_info`, `print_warning`, `print_step`, `handle_error`, `validate_ssh_key`, `set_ssh_config` (logic inside `configure_ssh`), the `handle_sshd_config_d` body, the `deploy_repo_to_user_home` body, the `test_ssh_config` and `restart_ssh` bodies, and `backup_ssh_config`.

- [ ] **Step 2: Delete the old scripts**

```bash
git rm install_docker_stuff.sh setup_new_host.sh
```

- [ ] **Step 3: Create `setup_dokploy_host.sh` with the skeleton**

Create the file with this exact content:

```bash
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
```

- [ ] **Step 4: Make it executable, parse-check, shellcheck**

```bash
chmod +x setup_dokploy_host.sh
bash -n setup_dokploy_host.sh
shellcheck setup_dokploy_host.sh
```

Expected: parse check is silent (success), shellcheck is silent or clean.

- [ ] **Step 5: Commit**

```bash
git add setup_dokploy_host.sh
git commit -m "Replace setup_new_host.sh + install_docker_stuff.sh with skeleton

Drops Docker installation (Dokploy installs it). Creates
setup_dokploy_host.sh with shared helpers; phase functions to follow."
```

---

## Task 2: `preflight()` — root assertion, OS detection, Dokploy presence warning

**Files:**
- Modify: `setup_dokploy_host.sh`

- [ ] **Step 1: Add the `preflight` function above `main()`**

Insert before `main()`:

```bash
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
```

- [ ] **Step 2: Wire it into `main()`**

Replace the body of `main()` with:

```bash
main() {
    echo
    print_info "🚀 Starting Dokploy host setup..."
    echo
    preflight
    echo
}
```

- [ ] **Step 3: Validate**

```bash
bash -n setup_dokploy_host.sh
shellcheck setup_dokploy_host.sh
```

- [ ] **Step 4: Commit**

```bash
git add setup_dokploy_host.sh
git commit -m "Add preflight: root + Ubuntu/Debian + Dokploy presence checks"
```

---

## Task 3: `phase_user()` — create user, add to sudo + docker

**Files:**
- Modify: `setup_dokploy_host.sh`

- [ ] **Step 1: Add the function above `main()`**

```bash
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
```

- [ ] **Step 2: Wire into `main()`**

Replace the body of `main()` with:

```bash
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
```

- [ ] **Step 3: Validate**

```bash
bash -n setup_dokploy_host.sh
shellcheck setup_dokploy_host.sh
```

- [ ] **Step 4: Commit**

```bash
git add setup_dokploy_host.sh
git commit -m "Add phase_user: create user with sudo + docker group memberships"
```

---

## Task 4: `phase_ssh_key()` — write `authorized_keys`

**Files:**
- Modify: `setup_dokploy_host.sh`

- [ ] **Step 1: Add the SSH-key validator and the phase function above `main()`**

```bash
validate_ssh_key() {
    local key="$1"
    if [[ ! "$key" =~ ^ssh-(rsa|dss|ed25519|ecdsa) ]]; then
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
        handle_error "Invalid SSH key format. Keys should start with: ssh-rsa, ssh-ed25519, ssh-ecdsa, or ssh-dss"
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
```

- [ ] **Step 2: Wire into `main()`**

Add `phase_ssh_key; echo` after `phase_user; echo`. Body of `main()`:

```bash
main() {
    local SETUP_USERNAME=""

    echo
    print_info "🚀 Starting Dokploy host setup..."
    echo
    preflight
    echo
    phase_user
    echo
    phase_ssh_key
    echo
}
```

- [ ] **Step 3: Validate**

```bash
bash -n setup_dokploy_host.sh
shellcheck setup_dokploy_host.sh
```

- [ ] **Step 4: Commit**

```bash
git add setup_dokploy_host.sh
git commit -m "Add phase_ssh_key: write authorized_keys for the new user"
```

---

## Task 5: `phase_ssh_harden()` — sshd_config + drop-in conflict scrub

**Files:**
- Modify: `setup_dokploy_host.sh`

This task adds the largest chunk: SSH hardening. It includes the new `KbdInteractiveAuthentication = no` directive and `PermitRootLogin prohibit-password` per spec §6.

- [ ] **Step 1: Add helper functions above `main()`**

```bash
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
    )

    local fixed_count=0
    while IFS= read -r -d '' file; do
        [[ -f "$file" ]] || continue
        local filename
        filename=$(basename "$file")
        local has_conflicts=false
        for setting in "${conflicting_settings[@]}"; do
            if grep -qE "^[[:space:]]*$setting" "$file" 2>/dev/null; then
                if [[ "$has_conflicts" == false ]]; then
                    print_warning "Stripping conflicting settings from $filename"
                    has_conflicts=true
                    fixed_count=$((fixed_count + 1))
                fi
                sed -i "/^[[:space:]]*$setting/d" "$file"
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
    sed -i "/^#*[[:space:]]*$setting/d" "$config_file"
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
```

- [ ] **Step 2: Declare `SSHD_BACKUP_FILE` in `main()` and wire in the phase**

Update `main()`:

```bash
main() {
    local SETUP_USERNAME=""
    local SSHD_BACKUP_FILE=""

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
}
```

- [ ] **Step 3: Validate**

```bash
bash -n setup_dokploy_host.sh
shellcheck setup_dokploy_host.sh
```

If shellcheck flags `SSHD_BACKUP_FILE` as referenced but not assigned (because it's set inside `backup_ssh_config` but used outside), add `# shellcheck disable=SC2034` above its declaration. Verify the warning's exact code first.

- [ ] **Step 4: Commit**

```bash
git add setup_dokploy_host.sh
git commit -m "Add phase_ssh_harden: sshd hardening with KbdInteractiveAuthentication
and PermitRootLogin prohibit-password (see spec §6)"
```

---

## Task 6: `phase_fail2ban()` — install + sshd jail

**Files:**
- Modify: `setup_dokploy_host.sh`

- [ ] **Step 1: Add the function above `main()`**

```bash
phase_fail2ban() {
    print_step "Phase 4: Fail2Ban"

    if ! command_exists fail2ban-client; then
        print_step "Installing fail2ban..."
        export DEBIAN_FRONTEND=noninteractive
        if apt-get update >/dev/null && apt-get install -y fail2ban >/dev/null; then
            print_success "fail2ban installed"
        else
            handle_error "Failed to install fail2ban"
        fi
    else
        print_success "fail2ban already installed"
    fi

    local jail_file="/etc/fail2ban/jail.d/sshd.local"
    print_step "Writing $jail_file..."
    cat > "$jail_file" <<'EOF'
[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 5
findtime = 10m
bantime = 10m
EOF
    print_success "Wrote sshd jail config"

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
```

- [ ] **Step 2: Wire into `main()`**

Add `phase_fail2ban; echo` after `phase_ssh_harden; echo`.

- [ ] **Step 3: Validate**

```bash
bash -n setup_dokploy_host.sh
shellcheck setup_dokploy_host.sh
```

- [ ] **Step 4: Commit**

```bash
git add setup_dokploy_host.sh
git commit -m "Add phase_fail2ban: install fail2ban + standard sshd jail (5/10m/10m)"
```

---

## Task 7: `phase_ufw()` — install + rules + enable

**Files:**
- Modify: `setup_dokploy_host.sh`

Note: ordering is critical. The 22/tcp allow MUST run before `ufw enable`, otherwise the operator gets kicked out the moment UFW activates with default-deny incoming.

- [ ] **Step 1: Add the function above `main()`**

```bash
phase_ufw() {
    print_step "Phase 5: UFW firewall"

    if ! command_exists ufw; then
        print_step "Installing ufw..."
        export DEBIAN_FRONTEND=noninteractive
        if apt-get install -y ufw >/dev/null; then
            print_success "ufw installed"
        else
            handle_error "Failed to install ufw"
        fi
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
```

- [ ] **Step 2: Wire into `main()`**

Add `phase_ufw; echo` after `phase_fail2ban; echo`.

- [ ] **Step 3: Validate**

```bash
bash -n setup_dokploy_host.sh
shellcheck setup_dokploy_host.sh
```

- [ ] **Step 4: Commit**

```bash
git add setup_dokploy_host.sh
git commit -m "Add phase_ufw: deny incoming, allow 22/80/443 (TCP+UDP for HTTP/3)"
```

---

## Task 8: `phase_deploy_repo()` — copy repo into user home for setup_git.sh access

**Files:**
- Modify: `setup_dokploy_host.sh`

- [ ] **Step 1: Add the function above `main()`**

```bash
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
```

- [ ] **Step 2: Add `DEPLOYED_REPO_DIR` to `main()` and wire phase in**

```bash
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
}
```

- [ ] **Step 3: Validate**

```bash
bash -n setup_dokploy_host.sh
shellcheck setup_dokploy_host.sh
```

- [ ] **Step 4: Commit**

```bash
git add setup_dokploy_host.sh
git commit -m "Add phase_deploy_repo: copy repo into user home for later setup_git.sh"
```

---

## Task 9: `phase_summary()` — print connection details and rollback hint

**Files:**
- Modify: `setup_dokploy_host.sh`

- [ ] **Step 1: Add the function above `main()`**

```bash
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
```

- [ ] **Step 2: Wire into `main()`**

Add `phase_summary` (no trailing `echo` since the function manages its own spacing) after `phase_deploy_repo; echo`.

```bash
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
```

- [ ] **Step 3: Validate**

```bash
bash -n setup_dokploy_host.sh
shellcheck setup_dokploy_host.sh
```

- [ ] **Step 4: Commit**

```bash
git add setup_dokploy_host.sh
git commit -m "Add phase_summary: connection details and rollback hint"
```

---

## Task 10: Final shellcheck pass and full file review

**Files:**
- Modify: `setup_dokploy_host.sh` (only if shellcheck/parse issues surface)

- [ ] **Step 1: Run shellcheck strictly**

```bash
shellcheck -S style setup_dokploy_host.sh
```

Expected: clean, or only style suggestions you choose to ignore. Fix anything substantive.

- [ ] **Step 2: Eyeball the full script for ordering**

Read the file end-to-end:

```bash
cat setup_dokploy_host.sh | less
```

Verify:
- All `print_*` and `handle_error` defined before any phase function uses them
- All phase functions defined before `main()`
- `main "$@"` invocation guard at the bottom
- `set -e` at the top
- Variables `SETUP_USERNAME`, `SSHD_BACKUP_FILE`, `DEPLOYED_REPO_DIR` declared in `main()` and assigned by their respective phases

- [ ] **Step 3: Sanity-check function list**

```bash
grep -E '^[a-z_]+\(\) \{' setup_dokploy_host.sh
```

Expected: `print_error`, `print_success`, `print_info`, `print_warning`, `print_step`, `handle_error`, `command_exists`, `validate_ssh_key`, `preflight`, `phase_user`, `phase_ssh_key`, `backup_ssh_config`, `handle_sshd_config_d`, `set_ssh_config`, `phase_ssh_harden`, `phase_fail2ban`, `phase_ufw`, `phase_deploy_repo`, `phase_summary`, `main` — in that order.

- [ ] **Step 4: Commit any fixes**

If you fixed anything in steps 1–3:

```bash
git add setup_dokploy_host.sh
git commit -m "Fix shellcheck/style nits in setup_dokploy_host.sh"
```

If nothing needed fixing, skip this commit.

---

## Task 11: Rewrite `README.md` for the new flow

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace `README.md` with the new content**

Overwrite the file with:

````markdown
# VPS Setup Scripts (Dokploy edition)

Two scripts to harden a freshly Dokploy-installed Hetzner VPS:

1. `setup_dokploy_host.sh` — runs as **root** after Dokploy is installed. Creates a non-root user with sudo + docker group, hardens SSH, installs UFW + Fail2Ban, copies this repo into the new user's home.
2. `setup_git.sh` — optional, runs as the **non-root user**. Configures Git identity and a GitHub SSH key for occasional manual git work on the server.

## Prerequisites

- A Hetzner Cloud VPS provisioned with your root SSH key (via Hetzner UI).
- Dokploy installed on that VPS (via Dokploy's UI/installer, run as root).
- Ubuntu LTS or recent Debian.

## Usage

### Phase 1: as `root`

After Dokploy install, SSH in as root, clone this repo, and run the host setup:

```bash
git clone https://github.com/vossiman/vps_setup.git
cd vps_setup
bash setup_dokploy_host.sh
```

You will be prompted for:
- a username (default `vossi`)
- a password for that user (used for `sudo`, not for SSH login)
- your SSH public key (paste the contents of your `.pub` file)

The script then:
- creates the user, adds it to `sudo` and `docker` groups
- writes `/home/<user>/.ssh/authorized_keys`
- backs up and rewrites `/etc/ssh/sshd_config` (PasswordAuth off, PermitRootLogin prohibit-password, etc.)
- strips conflicting directives from `/etc/ssh/sshd_config.d/*.conf`
- installs and enables Fail2Ban with a standard sshd jail
- installs UFW, opens 22/tcp + 80/tcp + 443/tcp + 443/udp, and enables it
- copies this repo into the new user's home

**Test the new SSH login in a second terminal before closing the original session.** The script prints rollback instructions at the end in case anything goes wrong.

### Phase 2: as the new user (optional)

Only run this if you want to use git on the server (cloning a utility repo, inspecting compose files, etc.):

```bash
ssh <user>@<server-ip>
cd ~/vps_setup
bash setup_git.sh
```

Sets your global git identity and generates an ed25519 SSH key for GitHub.

## Re-running

`setup_dokploy_host.sh` is idempotent. Re-running it after a Dokploy upgrade that re-enabled a setting (e.g. `PasswordAuthentication`) will re-assert the hardened state. Backups are timestamped so prior runs are preserved.

## What's intentionally NOT here

- Docker installation — Dokploy handles it.
- Homebrew / lazydocker / python3.12-venv — installed ad-hoc when actually needed.
- The `chaifeng/ufw-docker` "Docker bypasses UFW" fix — incompatibilities with Docker Swarm and Dokploy's overlay network; not needed when apps stay behind Traefik on 80/443.
- Custom SSH ports, aggressive Fail2Ban modes — security through obscurity / operator-lockout footguns.

See `docs/superpowers/specs/2026-04-29-dokploy-adaption-design.md` for the full design rationale.
````

- [ ] **Step 2: Validate**

```bash
cat README.md | head -50
```

Make sure the markdown looks right, no broken fences.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Rewrite README for Dokploy-edition flow"
```

---

## Task 12: Update `CLAUDE.md` for the new model

**Files:**
- Modify: `CLAUDE.md`

`CLAUDE.md` was created in a prior session and is currently untracked on this branch. We need to update it AND track it.

- [ ] **Step 1: Check current state of CLAUDE.md**

```bash
git status CLAUDE.md
cat CLAUDE.md
```

- [ ] **Step 2: Replace `CLAUDE.md` with the new content**

Overwrite the file with:

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Two Bash scripts that harden a Dokploy-installed Hetzner VPS. There is no build, lint, or test tooling — changes are validated by `bash -n`, `shellcheck`, and running the script on a real Dokploy host.

## Execution model (read before editing)

The repo is run in two phases on the target box:

1. `setup_dokploy_host.sh` — runs as **root** after Dokploy has been installed (Hetzner UI provisions the box → user installs Dokploy → THEN this script). Creates a non-root user with sudo + docker group memberships, hardens SSH, installs+enables Fail2Ban and UFW, then copies the entire repo to `/home/<user>/<repo>/` so the second-phase script is reachable.
2. `setup_git.sh` — runs as the **non-root user** that step 1 created. Optional. Configures git identity and a GitHub SSH key, in case the operator wants to do manual git work on the server.

`install_docker_stuff.sh` and the old `setup_new_host.sh` were removed when the repo was adapted for Dokploy — Dokploy installs Docker; the old "bare-VPS bootstrap" intent no longer applies.

## Phase function structure

`setup_dokploy_host.sh` is organized as numbered phase functions called from `main()`:

- `preflight()` — root + Ubuntu/Debian + Dokploy-presence checks
- `phase_user()` — user creation, sudo + **docker** group
- `phase_ssh_key()` — `authorized_keys`
- `phase_ssh_harden()` — `/etc/ssh/sshd_config` + `/etc/ssh/sshd_config.d/*.conf` scrub
- `phase_fail2ban()` — install + sshd jail
- `phase_ufw()` — rules then enable (22/tcp + 80/tcp + 443/tcp + **443/udp** for Traefik HTTP/3)
- `phase_deploy_repo()` — copy repo into the new user's home
- `phase_summary()` — connection info + rollback hint

Each phase is idempotent: re-running the script after a Dokploy upgrade that flipped a setting back will re-assert the hardened state.

## Non-obvious things to know

- **The "user not in docker group" warning that Dokploy reports is not a bug.** Dokploy's installer only adds the invoking user to `docker` when run as a non-root sudo user; root installs short-circuit. The script's `phase_user` adds `vossi` (or whoever) to both `sudo` and `docker`, which silences Dokploy's check.
- **SSH config is enforced in two places.** `/etc/ssh/sshd_config` is rewritten, AND `/etc/ssh/sshd_config.d/*.conf` is scrubbed of any conflicting directives (Hetzner cloud-init drops files there that override the main config). When adding a new SSH directive in `phase_ssh_harden`, also add it to the `conflicting_settings` array in `handle_sshd_config_d`.
- **`PermitRootLogin prohibit-password`, not `no`.** Same hardening posture (password auth is off globally) but keeps a key-only root SSH hatch open in case the non-root user's sudo gets wedged. See spec §6.
- **`UsePAM yes` is kept on intentionally.** Disabling it is Dokploy's recommendation but breaks `sudo` session logging and `pam_env`; with key-only + no-root-password the marginal security gain doesn't justify the breakage. See spec §10 row 5.
- **UFW order matters.** `ufw allow 22/tcp` runs **before** `ufw enable`, otherwise the operator gets kicked out the moment default-deny activates. This ordering is encoded in `phase_ufw` and must be preserved.
- **HTTP/3 on UDP/443.** Dokploy's Traefik publishes `443/udp` for QUIC. Most third-party Dokploy hardening guides miss this — `phase_ufw` opens it explicitly.
- **No `chaifeng/ufw-docker` fix.** The "Docker bypasses UFW" fix has known footguns in swarm mode and Dokploy uses swarm. Dokploy apps stay behind Traefik on 80/443 anyway. See spec §7 and §10 row 3.

## Shared conventions

- `print_error / print_success / print_info / print_warning / print_step` + `handle_error` — defined at the top of `setup_dokploy_host.sh`. Match the style when adding output. `setup_git.sh` has its own copies (intentionally duplicated; no shared lib).
- `set -e` in `setup_dokploy_host.sh`; `set -euo pipefail` in `setup_git.sh`. Preserve each script's existing style.
- Default user is `vossi` (prompt-defaultable in `phase_user`).
- Target OS is Ubuntu LTS / Debian. `preflight()` rejects others.

## Running / testing

```bash
# On the Dokploy-installed Hetzner box, as root:
sudo bash setup_dokploy_host.sh

# Later, as the user that was just created (optional):
bash ~/vps_setup/setup_git.sh
```

Validation while editing: `bash -n setup_dokploy_host.sh && shellcheck setup_dokploy_host.sh`. Full integration testing is the manual plan in `docs/superpowers/specs/2026-04-29-dokploy-adaption-design.md` §11.

## Spec & plan

- Design: `docs/superpowers/specs/2026-04-29-dokploy-adaption-design.md`
- Implementation plan: `docs/superpowers/plans/2026-04-29-dokploy-adaption.md`
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Update CLAUDE.md for the Dokploy-edition repo model"
```

---

## Task 13: Pre-deployment validation checklist

**Files:** none (verification only)

- [ ] **Step 1: Final repo sanity check**

```bash
ls -la
git log --oneline dokploy-adaption ^main
git status
```

Expected:
- Files present: `README.md`, `CLAUDE.md`, `setup_dokploy_host.sh`, `setup_git.sh`, `docs/`
- Files absent: `install_docker_stuff.sh`, `setup_new_host.sh`
- `git status` clean
- ~13 commits on the branch since `main`

- [ ] **Step 2: Final parse + shellcheck**

```bash
bash -n setup_dokploy_host.sh && bash -n setup_git.sh && echo "PARSE OK"
shellcheck setup_dokploy_host.sh setup_git.sh
```

Expected: `PARSE OK` printed, shellcheck silent or clean.

- [ ] **Step 3: Confirm executable bits**

```bash
ls -l setup_dokploy_host.sh setup_git.sh
```

Both should be `-rwxr-xr-x`.

- [ ] **Step 4: Read the final `setup_dokploy_host.sh` end-to-end one more time**

Open in a viewer and read top to bottom. Look specifically for:
- the function ordering matches Task 10 step 3
- `phase_ufw` adds the SSH allow before calling `ufw --force enable`
- `phase_ssh_harden` runs `sshd -t` before `systemctl restart ssh`
- All `handle_error` messages mention how to recover where applicable

If any issue surfaces, fix and add a final commit.

- [ ] **Step 5: Manual end-to-end test on a real Hetzner box**

Run the manual test plan from spec §11. Briefly:

1. Provision a fresh Hetzner Ubuntu LTS, add root SSH key.
2. SSH in as root, install Dokploy via its installer.
3. Confirm Dokploy UI shows the expected red flags.
4. `git clone https://github.com/vossiman/vps_setup.git -b dokploy-adaption` and `bash setup_dokploy_host.sh`.
5. From a **second terminal**, `ssh vossi@<ip>`. Verify login. `sudo -v`. `docker ps` (no sudo).
6. Refresh Dokploy's UI server-health page — UFW active, SSH password-auth off, Fail2Ban active, vossi in docker group: all green.
7. Re-run the script — verify idempotency.
8. As vossi, `bash ~/vps_setup/setup_git.sh` — verify it still behaves as before.

If all green: merge `dokploy-adaption` to `main` (or open a PR per the operator's preference).

---

## Self-review (post-write check)

After writing this plan, I checked the spec sections against the tasks:

| Spec section | Covered by |
|---|---|
| §1 Problem statement | Task 1 (cleanup), implicit through whole plan |
| §2 Out of scope | Honored throughout (no Docker install, no chaifeng fix, no test harness) |
| §3 File-layout changes | Tasks 1, 11, 12 |
| §4 Phase structure | Tasks 2–9 (one task per phase) |
| §5 Re-run safety | Idempotency baked into each phase function |
| §6 SSH hardening diff | Task 5 (literal directive list, including KbdInteractiveAuthentication and PermitRootLogin prohibit-password) |
| §7 UFW rules | Task 7 (literal rule order, 443/udp included) |
| §8 Fail2Ban config | Task 6 (literal jail.local content) |
| §9 User/sudo/docker | Task 3 (literal usermod commands and verification) |
| §10 Decisions log | Reflected in code choices throughout |
| §11 Testing plan | Task 13 step 5 references it directly |
| §12 Rollback | Task 5 + Task 9 (`phase_summary` prints the rollback command) |

No gaps. No `TBD`/`TODO`/placeholder steps. All function names and signatures consistent across tasks (`SETUP_USERNAME`, `SSHD_BACKUP_FILE`, `DEPLOYED_REPO_DIR` declared in `main`, set by their respective phases, read by `phase_summary`). Function ordering verified in Task 10 step 3.
