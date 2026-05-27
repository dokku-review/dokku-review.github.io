#!/usr/bin/env bash
#
# dokku-review installer — sets up a fresh Ubuntu 24.04 host as a Dokku
# review-app server (Dokku + system-postgres + letsencrypt + redis).
#
# Usage (on the target server, as a sudo user):
#
#   curl -fsSL https://dokku-review.github.io/install.sh \
#     | DOMAIN=review.example.com [DATABASES='DATABASE_URL CACHE_DATABASE_URL'] \
#       sudo -E bash
#
# See https://dokku-review.github.io/ for a wizard that builds this line.
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- Configuration --------------------------------------------------------

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
DATABASES="${DATABASES:-DATABASE_URL}"
DOKKU_TAG="${DOKKU_TAG:-v0.38.5}"
SYSTEM_POSTGRES_PLUGIN="${SYSTEM_POSTGRES_PLUGIN:-https://github.com/dokku-review/system-postgres.git}"
REVIEW_DB_SECRET="${REVIEW_DB_SECRET:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-/var/lib/dokku-review/gha-key}"

# Pinned and exported so the system-postgres install hook picks it up
export SYSTEM_POSTGRES_VERSION=18

# --- Preflight ------------------------------------------------------------

if [ -z "$DOMAIN" ]; then
  echo "ERROR: DOMAIN is required." >&2
  echo "Example: curl ... | DOMAIN=review.example.com sudo -E bash" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root. Use 'sudo -E' so environment variables pass through." >&2
  exit 1
fi

if ! grep -q 'Ubuntu 24' /etc/os-release 2>/dev/null; then
  echo "WARNING: this installer is tested on Ubuntu 24.04 only." >&2
  echo "Detected: $(. /etc/os-release && echo "$PRETTY_NAME")" >&2
fi

EMAIL="${EMAIL:-admin@${DOMAIN}}"

# --- Dokku ----------------------------------------------------------------

echo "==> Installing Dokku ${DOKKU_TAG}"
if command -v dokku >/dev/null 2>&1; then
  echo "Dokku already installed: $(dokku version)"
else
  apt-get update -qq
  apt-get install -y -qq wget openssl >/dev/null

  # Skip dokku's debconf attempt to import /root/.ssh/id_rsa.pub as the admin
  # deploy key — we add keys explicitly via `dokku ssh-keys:add` later. Without
  # this, fresh installs print an alarming "Error: keyfile not found" line.
  echo 'dokku dokku/key_file string /dev/null' | debconf-set-selections

  wget -NP /tmp "https://dokku.com/install/${DOKKU_TAG}/bootstrap.sh"
  DOKKU_TAG="${DOKKU_TAG}" bash /tmp/bootstrap.sh
fi

# --- Redis ----------------------------------------------------------------

echo "==> Installing dokku-redis"
if [ -d /var/lib/dokku/plugins/available/redis ]; then
  dokku plugin:update redis
else
  dokku plugin:install https://github.com/dokku/dokku-redis.git redis
fi

# --- Letsencrypt ----------------------------------------------------------

echo "==> Installing dokku-letsencrypt"
if [ -d /var/lib/dokku/plugins/available/letsencrypt ]; then
  dokku plugin:update letsencrypt
else
  dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git letsencrypt
fi

dokku letsencrypt:set --global email "${EMAIL}"

# --- system-postgres ------------------------------------------------------
#
# Installed last so its noisy post-install hook fires only once, after the
# quieter plugins above are in place.

echo "==> Installing system-postgres"
if [ -d /var/lib/dokku/plugins/available/system-postgres ]; then
  dokku plugin:update system-postgres
else
  dokku plugin:install "${SYSTEM_POSTGRES_PLUGIN}"
fi

# Persist the generated secret so re-runs are stable
SECRET_FILE=/var/lib/dokku/data/system-postgres/.installer-secret
if [ -z "$REVIEW_DB_SECRET" ]; then
  if [ -s "$SECRET_FILE" ]; then
    REVIEW_DB_SECRET=$(cat "$SECRET_FILE")
  else
    REVIEW_DB_SECRET=$(openssl rand -hex 32)
    mkdir -p "$(dirname "$SECRET_FILE")"
    umask 077 && printf '%s' "$REVIEW_DB_SECRET" > "$SECRET_FILE"
  fi
fi

sudo -u dokku dokku system-postgres:set --global db-secret "${REVIEW_DB_SECRET}"
sudo -u dokku dokku system-postgres:set --global databases "${DATABASES}"
sudo -u dokku dokku system-postgres:set --global app-pattern "pr-*"
sudo -u dokku dokku system-postgres:set --global extensions \
  "citext cube earthdistance hstore intarray pg_stat_statements pg_trgm pgcrypto uuid-ossp"

# --- Global domain --------------------------------------------------------

echo "==> Setting global domain to ${DOMAIN}"
dokku domains:set-global "${DOMAIN}"

# --- CI deploy key --------------------------------------------------------

echo "==> Provisioning CI deploy key (gha)"
if [ ! -s "$SSH_KEY_FILE" ]; then
  mkdir -p "$(dirname "$SSH_KEY_FILE")"
  umask 077
  ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N '' -C 'dokku-review gha' -q
  dokku ssh-keys:add gha "${SSH_KEY_FILE}.pub"
fi
REVIEW_SSH_PRIVATE_KEY=$(cat "$SSH_KEY_FILE")

# --- Summary --------------------------------------------------------------

cat <<SUMMARY

================================================================
  Setup complete
================================================================

  Dokku:       $(dokku version)
  Postgres:    $(psql --version 2>/dev/null || echo "see 'dokku system-postgres:report'")
  Domain:      ${DOMAIN}
  LE email:    ${EMAIL}
  Databases:   ${DATABASES}

  system-postgres db-secret (server-side, persisted at ${SECRET_FILE}):
    ${REVIEW_DB_SECRET}

  CI deploy key — REVIEW_SSH_PRIVATE_KEY (also stored at ${SSH_KEY_FILE}):

${REVIEW_SSH_PRIVATE_KEY}

  Set GitHub Actions secrets/vars in your app repo:
    gh variable set REVIEW_SERVER --body '${DOMAIN}'
    gh variable set REVIEW_DOMAIN --body '${DOMAIN}'
    # Save the key block above to ./gha-key, then:
    gh secret set REVIEW_SSH_PRIVATE_KEY < ./gha-key

  Add per-developer SSH keys:
    curl https://github.com/USERNAME.keys | dokku ssh-keys:add USERNAME

  Wire up review apps in your repo with the reusable workflow:
    https://github.com/dokku-review/actions

================================================================
SUMMARY
