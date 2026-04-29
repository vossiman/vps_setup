# Dokploy host adaptation — design spec

**Date**: 2026-04-29
**Suggested branch**: `dokploy-adaption`
**Scope**: rewrite of the `vps_setup` repo for the Dokploy-on-Hetzner workflow

## 1. Problem statement

The repo's three scripts were designed to bootstrap a bare Hetzner VPS from zero — create a sudo user, harden SSH, install Docker + dev tooling. The user has since switched to **Dokploy** for managing servers:

1. Hetzner UI provisions the box and installs the root SSH key.
2. Dokploy's installer (run as root) installs Docker 28.5.0, initializes a single-node Docker Swarm, creates `/etc/dokploy/`, runs Traefik as a container on `:80`, `:443/tcp`, `:443/udp` (HTTP/3), and installs rclone, nixpacks, pack, railpack.
3. Dokploy's UI then *checks* the host and reports issues it cannot or did not fix:
   - SSH `PasswordAuthentication` enabled (Hetzner default)
   - SSH `UsePAM` enabled
   - UFW not installed / not active
   - Fail2Ban not installed
   - "User is not in docker group" — explained below

The "user not in docker group" message is **not a Dokploy bug**. Dokploy's install script only runs `usermod -aG docker $CURRENT_USER` when invoked as a non-root sudo user. Installed as root (the user's flow), it short-circuits with "Running as root, no extra permissions needed" and adds nobody to the docker group, so Dokploy's check finds zero non-root users in `docker` and flags it.

The user wants:
- a personal `vossi` user on these boxes (sudo + docker, key-only SSH)
- SSH hardened so password auth is off and root SSH is key-only
- UFW enabled with the right ports for Dokploy's Traefik
- Fail2Ban running with the standard sshd jail
- the existing `setup_git.sh` flow preserved as an optional thing vossi runs later for occasional manual git work on the server
- Docker installation removed entirely (Dokploy handles it)

## 2. Out of scope

- Docker / Docker Compose / Homebrew / lazydocker / `python3.12-venv` installation (all removed).
- Any backwards-compatibility shim for `setup_new_host.sh` or `install_docker_stuff.sh` (small repo, two-user audience — clean break).
- The `chaifeng/ufw-docker` "Docker bypasses UFW" fix (see §10 for the decision rationale).
- Custom SSH ports, aggressive Fail2Ban modes, additional Fail2Ban jails (`recidive` etc.).
- Multi-key support in `authorized_keys` (current single-key flow preserved).
- Automated test harness (matches existing repo culture — manual verification only).

## 3. File-layout changes

```
vps_setup/
├── README.md                    ← rewritten for the new flow
├── CLAUDE.md                    ← updated to reflect new model
├── setup_dokploy_host.sh        ← NEW (replaces setup_new_host.sh)
├── setup_git.sh                 ← UNCHANGED
└── install_docker_stuff.sh      ← DELETED
```

`setup_new_host.sh` is removed in the same commit. No rename redirect.

## 4. `setup_dokploy_host.sh` — phase structure

Single root-only Bash script, ~650 lines, organized as numbered phase functions called in order from `main()`. Reuses the `print_error / print_success / print_info / print_warning / print_step` helpers and `handle_error` pattern from the existing `setup_new_host.sh` verbatim. Uses `set -e`.

Phases:

| Phase | Function | Purpose |
|---|---|---|
| 0 | `preflight()` | Assert root, assert Ubuntu/Debian via `/etc/os-release`, warn (don't fail) if Dokploy not detected (`/etc/dokploy/` missing or `docker` not on PATH) |
| 1 | `phase_user()` | Prompt for username (default `vossi`), create user (idempotent), set password interactively, add to `sudo` and `docker` groups, verify membership |
| 2 | `phase_ssh_key()` | Prompt for and validate SSH public key, write `~vossi/.ssh/authorized_keys` with correct permissions (700/600) |
| 3 | `phase_ssh_harden()` | Backup `/etc/ssh/sshd_config` (timestamped), strip conflicting directives from `/etc/ssh/sshd_config.d/*.conf`, write hardened settings, run `sshd -t`, restart `ssh` |
| 4 | `phase_fail2ban()` | `apt install -y fail2ban`, write `/etc/fail2ban/jail.d/sshd.local`, `systemctl enable --now fail2ban`, verify active |
| 5 | `phase_ufw()` | `apt install -y ufw`, set default policies, allow 22/tcp + 80/tcp + 443/tcp + 443/udp **before** enabling, `ufw --force enable`, verify active |
| 6 | `phase_deploy_repo()` | Copy repo dir to `/home/<user>/`, `chown -R <user>:<user>`, ensure `setup_git.sh` is executable; if target exists, log a warning and skip (operator can `rm -rf` it manually for a clean re-deploy) |
| 7 | `phase_summary()` | Print connection details, sshd backup path, rollback command, what to do if locked out |

## 5. Re-run safety (idempotency)

The script is **re-runnable** (D1 "re-assert" mode). Re-running after a Dokploy upgrade that re-enables a setting must be safe and converge to the desired state.

- **User**: `id <user> &>/dev/null` short-circuits creation. `usermod -aG sudo,docker` is a no-op if memberships exist.
- **SSH key**: `tee` overwrites `authorized_keys` with the prompted key. The prompt always runs — if the user wants to skip, they `Ctrl-C`.
- **SSH config**: `set_ssh_config()` from the existing script — `sed -i` deletes any existing line for the directive (commented or not) before appending. Backups are timestamped, so re-runs accumulate harmlessly.
- **Fail2Ban / UFW packages**: `apt install -y` is a no-op if already present. Configs are written via heredoc (full overwrite). Services use `systemctl enable --now`. `ufw --force enable` is idempotent.
- **Repo deploy**: if `/home/<user>/<repo>` exists, log a warning and skip (no destructive overwrite). Operator can `rm -rf` the target manually if they want a clean re-deploy.

## 6. SSH hardening — concrete diff

`/etc/ssh/sshd_config` is rewritten with the directives below. The `conflicting_settings` list in `handle_sshd_config_d()` (which strips overrides from `/etc/ssh/sshd_config.d/*.conf`) is updated to match.

| Setting | Old (`setup_new_host.sh`) | New (`setup_dokploy_host.sh`) |
|---|---|---|
| `PasswordAuthentication` | `no` | `no` |
| `PubkeyAuthentication` | `yes` | `yes` |
| `PermitRootLogin` | `no` | **`prohibit-password`** |
| `ChallengeResponseAuthentication` | `no` | `no` |
| `KbdInteractiveAuthentication` | (not set) | **`no`** (modern OpenSSH name; some checkers read this rather than the legacy `ChallengeResponse...`) |
| `UsePAM` | `yes` | `yes` (kept on; key-only + no-root-password is enough hardening, PAM disable risks breaking sudo session logging and `pam_env`) |
| `X11Forwarding` | `no` | `no` |
| `PrintMotd` | `no` | `no` |
| `AcceptEnv` | `LANG LC_*` | `LANG LC_*` |
| `Subsystem sftp` | `/usr/lib/openssh/sftp-server` | `/usr/lib/openssh/sftp-server` |

**Why `prohibit-password` instead of `no` for `PermitRootLogin`**: Dokploy is installed as root and any future re-installs/updates may want root SSH from the operator's laptop using their existing root key. `prohibit-password` keeps that hatch open with the same security posture as `no` (because `PasswordAuthentication no` already blocks password-based root login — `prohibit-password` is functionally identical in steady state, just more explicit and forgiving if vossi ever gets locked out of sudo).

The `conflicting_settings` array gains `KbdInteractiveAuthentication`.

`sshd -t` runs **before** `systemctl restart ssh`. If the test fails, the script aborts and the existing session is unaffected — operator can restore from the timestamped backup.

## 7. UFW rules

Order matters. The 22/tcp allow runs **before** `ufw enable`, otherwise the operator gets kicked out.

```
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp     comment 'SSH'
ufw allow 80/tcp     comment 'HTTP / Traefik'
ufw allow 443/tcp    comment 'HTTPS / Traefik'
ufw allow 443/udp    comment 'HTTP/3 (QUIC) / Traefik'
ufw --force enable
ufw status verbose   # for the operator's eyes
```

**Why 443/udp**: Dokploy's installed Traefik binds `-p 443:443/udp` for HTTP/3 (QUIC). Plain `ufw allow 443/tcp` does not cover this. Most third-party Dokploy-hardening writeups omit this rule.

**Swarm ports** (2377/tcp, 7946/tcp+udp, 4789/udp): not opened. Single-node swarm doesn't need them on the public interface; default-deny is correct.

**Docker bypassing UFW**: not addressed by this script. Dokploy publishes only the three Traefik ports to the host; user-deployed apps reach the world through Traefik on a Docker overlay network and don't publish their own host ports. The `chaifeng/ufw-docker` fix has known footguns in swarm mode (issues #46 and #70 in that repo, plus a documented "must reboot after `ufw` restart" gotcha) and adds a global swarm service. Plain UFW matches the dominant Dokploy hardening guidance (e.g., the MassiveGRID writeup at `https://massivegrid.com/blog/securing-your-dokploy-instance/`). If the operator ever publishes a host port directly outside Traefik, they'll need to revisit this — see decision #3 in §10.

## 8. Fail2Ban configuration

`apt install -y fail2ban`, then write `/etc/fail2ban/jail.d/sshd.local`:

```ini
[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 5
findtime = 10m
bantime = 10m
```

`systemctl enable --now fail2ban`, then `systemctl is-active --quiet fail2ban` to verify.

Normal mode, default settings. No `[recidive]` jail or aggressive mode (locks the operator out faster than attackers; easy to add later if desired).

## 9. User creation, sudo, docker group

`vossi` (or operator-chosen username) is added to **both** `sudo` and `docker` groups in `phase_user()`:

```bash
usermod -aG sudo "$username"
usermod -aG docker "$username"
```

Verification — script aborts if either fails:

```bash
groups "$username" | grep -qw sudo   || handle_error "..."
getent group docker | grep -qw "$username" || handle_error "..."
```

Adding the user to `docker` is what silences Dokploy's "user is not in docker group" check (see §1). It also lets the operator run `docker` commands on the box without `sudo` after logging in as vossi.

## 10. Decisions log (for reviewers and future-Claude)

| # | Decision | Rationale (short) |
|---|---|---|
| 1 | Single root-run script post-Dokploy (not 3-phase) | The 3-phase split existed because phases 2–3 needed a non-root user that didn't exist yet. Post-Dokploy, only `setup_git.sh` genuinely needs vossi interactively. Everything else is fine in one root script. |
| 2 | Rename to `setup_dokploy_host.sh` | Signals the change in purpose; avoids confusion with the old "bare-VPS bootstrap" intent. Old script removed in same commit. |
| 3 | Plain UFW, not the `chaifeng/ufw-docker` "Docker bypasses UFW" fix | Swarm-mode footguns in the chaifeng project, dominant Dokploy guidance uses plain UFW, user's apps stay behind Traefik so the bypass isn't their threat model. The chaifeng approach is reversible — can be layered on later as a pure additive change. |
| 4 | `PermitRootLogin prohibit-password`, not `no` | Same hardening posture in practice (password auth is off globally), keeps an emergency hatch if vossi sudo gets wedged. Cost: zero. |
| 5 | `UsePAM yes` kept on | Disabling is Dokploy's recommendation but breaks `sudo` session logging and `pam_env`. With key-only + no-root-password the marginal security gain is small. |
| 6 | Fail2Ban normal mode, sshd jail only | Aggressive mode locks the operator out faster than attackers. Easy to extend later. |
| 7 | SSH stays on port 22 | Custom ports are security-through-obscurity and complicate every tool that connects. |
| 8 | Swarm ports (2377, 7946, 4789) not opened | Single-node swarm doesn't need them on the public interface. UFW default-deny correctly blocks them. |
| 9 | `setup_git.sh` kept unchanged | Operator occasionally SSHes in as vossi to inspect / tweak compose files; git-on-server is sometimes useful. |
| 10 | `install_docker_stuff.sh` deleted (Homebrew/lazydocker/python3.12-venv removed) | Dokploy installs Docker. Brew/lazydocker/python on a deploy box rot from disuse. `apt install` ad-hoc when actually needed. |
| 11 | Re-runnable, not first-run-only | Future Dokploy upgrades may flip settings back; re-asserting is the right primitive. Existing timestamped backups protect against accidents. |

## 11. Testing plan (manual)

No automated harness (matches existing repo culture).

1. Provision a fresh Hetzner Ubuntu LTS box. Add root SSH key via Hetzner UI.
2. SSH in as root, run Dokploy's installer per Dokploy's documented flow. Confirm the UI is reachable on `<ip>:3000` (or via Traefik domain if configured).
3. Confirm Dokploy's server-health page shows the expected red flags (UFW inactive, SSH password auth on, Fail2Ban not installed, "user not in docker group").
4. Clone this repo as root, `bash setup_dokploy_host.sh`. Provide username `vossi`, paste SSH public key.
5. Open a **second terminal**. `ssh vossi@<ip>`. Confirm login works. `sudo -v`. `docker ps` works without sudo.
6. From the first terminal (still root), refresh Dokploy's server-health page. Expected: UFW active, SSH password auth off, Fail2Ban active+running, vossi in docker group — all green.
7. **Re-run the script** as root from the first terminal with the same inputs. Confirm: no errors, no destructive surprises, end state unchanged. (`/home/vossi/vps_setup` already-exists warning is acceptable.)
8. From the vossi shell, `bash ~/vps_setup/setup_git.sh`. Confirm it still behaves as today (configures git identity, generates ed25519 key, prints public key for GitHub).

## 12. Rollback

If a re-run breaks SSH access for the operator:

```bash
# (from the still-open original session)
cp /etc/ssh/sshd_config.backup.<latest-timestamp> /etc/ssh/sshd_config
systemctl restart ssh
```

`phase_summary()` prints this command at the end of every run with the actual backup path filled in, so the operator never has to dig for it.

If UFW locks the operator out of an unexpected service: `ufw disable` from a Hetzner web console session restores the previous state. UFW rules can be inspected with `ufw status numbered` and edited with `ufw delete <num>`.
