# install-docker.sh

One-liner shell script to install **Docker Engine + Compose v2** on **Debian / Ubuntu**.

Follows the official [Docker apt repository installation](https://docs.docker.com/engine/install/debian/) procedure — automates GPG key import, source configuration, dependency installation, and daemon startup.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh | sudo bash
```

Or with `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/Unarmored7/install-docker/main/install-docker.sh | sudo bash
```

## Requirements

| Item         | Requirement                   |
|--------------|-------------------------------|
| Distribution | Debian 11+ / Ubuntu 20.04+   |
| Privilege    | root (or `sudo`)              |
| Network      | Access to `download.docker.com` |

## What It Does

| Step | Action |
|------|--------|
| 1 | Remove conflicting legacy packages (`docker.io`, `podman-docker`, etc.) |
| 2 | Purge stale Docker apt sources and GPG keys |
| 3 | Update the apt package index |
| 4 | Install prerequisites (`ca-certificates`, `curl`) |
| 5 | Import Docker's official GPG key into `/etc/apt/keyrings/` |
| 6 | Add the Docker apt repository (Deb822 `.sources` format) |
| 7 | Install `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` |

After installation the script enables and starts the Docker daemon via systemd.

## Environment Variables

| Variable  | Default | Description |
|-----------|---------|-------------|
| `DRY_RUN` | `0`     | Set to `1` to print commands without executing them |

```bash
sudo DRY_RUN=1 bash install-docker.sh
```

## Post-Install

Allow a non-root user to run Docker without `sudo`:

```bash
sudo usermod -aG docker $USER
# then log out and back in, or run:
newgrp docker
```

Verify the installation:

```bash
docker run hello-world
```

## Uninstall

```bash
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
sudo rm -rf /var/lib/docker /var/lib/containerd
sudo rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
```

## License

[MIT](LICENSE)
