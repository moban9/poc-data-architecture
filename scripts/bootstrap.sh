#!/usr/bin/env bash
# One-time bootstrap for the GCP POC node. Idempotent.
# Runs as GCP metadata_startup_script (root) and can be re-run manually.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { echo "[bootstrap] $*"; }

log "installing docker"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker || true

log "installing docker compose plugin"
mkdir -p /usr/local/lib/docker/cli-plugins
if [ ! -x /usr/local/lib/docker/cli-plugins/docker-compose ]; then
  curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

log "docker ready: $(docker --version 2>&1)"

log "installing envsubst (gettext-base) for connector registration"
apt-get update -qq && apt-get install -y -qq gettext-base >/dev/null 2>&1 || true

log "adding ubuntu to docker group (deploy via SSH as ubuntu)"
usermod -aG docker ubuntu || true

log "stack is started by 'make deploy' (compose dir must be synced to /home/ubuntu/poc/compose)"
