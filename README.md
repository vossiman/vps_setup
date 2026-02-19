# VPS Setup Scripts

Small, reusable scripts to bootstrap a fresh Linux VPS for development work.

This repo is designed for a quick setup flow:
1. Create a non-root sudo user and lock down SSH access.
2. Install Docker tooling and common dependencies for container-based workflows.

## Scripts

### `setup_new_host.sh`
Purpose: create a new sudo user and configure SSH securely.

What it does:
- Prompts for a username to create/configure.
- Adds that user to the `sudo` group.
- Prompts for an SSH public key and writes it to `~/.ssh/authorized_keys`.
- Backs up `/etc/ssh/sshd_config`.
- Removes conflicting SSH auth settings from `/etc/ssh/sshd_config.d/*.conf` (if present).
- Enforces secure SSH settings (no root login, key auth enabled, password auth disabled).
- Validates and restarts the SSH service.

Run:
```bash
sudo bash setup_new_host.sh
```

Important:
- Keep your current SSH session open while testing a new login.
- Confirm key-based login works before closing the original root session.

### `install_docker_stuff.sh`
Purpose: install Docker stack and helper tooling for day-to-day dev.

What it does:
- Updates apt package lists.
- Installs `build-essential` and `python3.12-venv`.
- Installs Docker Engine + CLI + Compose plugin + Buildx.
- Adds current user to the `docker` group.
- Installs Homebrew (Linuxbrew) if missing.
- Installs `lazydocker` via Homebrew.
- Runs post-install verification checks.

Run:
```bash
bash install_docker_stuff.sh
```

Notes:
- Script is intended for Ubuntu/Linux Mint.
- If Docker permission changes do not apply immediately, log out and back in.

## Recommended Order On a Fresh VPS

1. Connect as root (or provider default admin user).
2. Run `setup_new_host.sh` to create your real working user and secure SSH.
3. Log in as the new user.
4. Run `install_docker_stuff.sh`.

## Repository Goal

Keep VPS initialization repeatable, fast, and safer than ad-hoc manual setup.
