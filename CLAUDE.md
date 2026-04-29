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

Every phase is idempotent except `phase_ssh_key`, which always prompts and overwrites `authorized_keys` (operator can Ctrl-C at the prompt to skip — preceding phases will have already completed).

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
