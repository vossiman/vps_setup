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

`setup_dokploy_host.sh` is safe to re-run after a Dokploy upgrade that flipped a hardened setting back; it re-asserts the desired state and timestamped backups preserve prior runs.

Caveat: the SSH-key prompt always runs and overwrites `~user/.ssh/authorized_keys` with the freshly pasted key. If you don't want to replace the key, hit Ctrl-C at the SSH-key prompt — earlier phases will already have completed.

## What's intentionally NOT here

- Docker installation — Dokploy handles it.
- Homebrew / lazydocker / python3.12-venv — installed ad-hoc when actually needed.
- The `chaifeng/ufw-docker` "Docker bypasses UFW" fix — incompatibilities with Docker Swarm and Dokploy's overlay network; not needed when apps stay behind Traefik on 80/443.
- Custom SSH ports, aggressive Fail2Ban modes — security through obscurity / operator-lockout footguns.

See `docs/superpowers/specs/2026-04-29-dokploy-adaption-design.md` for the full design rationale.
