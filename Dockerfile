FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM tianon/gosu:1.19-trixie@sha256:3b176695959c71e123eb390d427efc665eeb561b1540e82679c15e992006b8b9 AS gosu_source
FROM debian:13.4

# Disable Python stdout buffering to ensure logs are printed immediately
ENV PYTHONUNBUFFERED=1

# Store Playwright browsers outside the volume mount so the build-time
# install survives the /opt/data volume overlay at runtime.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# Install system dependencies in one layer, clear APT cache
# tini reaps orphaned zombie processes (MCP stdio subprocesses, git, bun, etc.)
# that would otherwise accumulate when hermes runs as PID 1. See #15012.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential curl nodejs npm python3 ripgrep ffmpeg gcc python3-dev libffi-dev procps git openssh-client docker-cli tini && \
    rm -rf /var/lib/apt/lists/*

# Non-root user for runtime; UID can be overridden via HERMES_UID at runtime
RUN useradd -u 10000 -m -d /opt/data hermes

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

WORKDIR /opt/hermes

# ---------- Layer-cached dependency install ----------
# Copy only package manifests first so npm install + Playwright are cached
# unless the lockfiles themselves change.
#
# ui-tui/packages/hermes-ink/ is copied IN FULL (not just its manifests)
# because it is referenced as a `file:` workspace dependency from
# ui-tui/package.json.  Copying the tree up front lets npm resolve the
# workspace to real content instead of stopping at a bare package.json.
COPY package.json package-lock.json ./
COPY web/package.json web/package-lock.json web/
COPY ui-tui/package.json ui-tui/package-lock.json ui-tui/
COPY ui-tui/packages/hermes-ink/ ui-tui/packages/hermes-ink/

# `npm_config_install_links=false` forces npm to install `file:` deps as
# symlinks (the npm 10+ default) even on Debian's older bundled npm 9.x,
# which defaults to `install-links=true` and installs file deps as *copies*.
# The host-side package-lock.json is generated with a newer npm that uses
# symlinks, so an install-as-copy produces a hidden node_modules/.package-lock.json
# that permanently disagrees with the root lock on the @hermes/ink entry.
# That disagreement trips the TUI launcher's `_tui_need_npm_install()`
# check on every startup and triggers a runtime `npm install` that then
# fails with EACCES (node_modules/ is root-owned from build time).
ENV npm_config_install_links=false

RUN npm install --prefer-offline --no-audit && \
    npx playwright install --with-deps chromium --only-shell && \
    (cd web && npm install --prefer-offline --no-audit) && \
    (cd ui-tui && npm install --prefer-offline --no-audit) && \
    npm cache clean --force

# ---------- Source code ----------
# .dockerignore excludes node_modules, so the installs above survive.
COPY --chown=hermes:hermes . .

# Build browser dashboard and terminal UI assets.
RUN cd web && npm run build && \
    cd ../ui-tui && npm run build

# ---------- Permissions ----------
# Make install dir world-readable so any HERMES_UID can read it at runtime.
# The venv needs to be traversable too.
USER root
RUN chmod -R a+rX /opt/hermes
# Start as root so the entrypoint can usermod/groupmod + gosu.
# If HERMES_UID is unset, the entrypoint drops to the default hermes user (10000).

# ---------- Python virtualenv ----------
RUN uv venv && \
    uv pip install --no-cache-dir -e ".[all]"

# ---------- Runtime ----------
ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_HOME=/opt/data
ENV PATH="/opt/data/.local/bin:${PATH}"
# NOTA: Eliminamos VOLUME porque Railway no lo soporta
# VOLUME [ "/opt/data" ]
# Force rebuild when entrypoint changes
ARG ENTRYPOINT_VERSION=7
RUN cat > /opt/hermes/docker/entrypoint-railway.sh << 'EOF'
#!/bin/bash
# Script de inicio para Railway: SOLO Gateway (sin Dashboard por seguridad)
set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
INSTALL_DIR="/opt/hermes"

# --- Privilege dropping via gosu ---
if [ "$(id -u)" = "0" ]; then
    if [ -n "$HERMES_UID" ] && [ "$HERMES_UID" != "$(id -u hermes)" ]; then
        echo "Changing hermes UID to $HERMES_UID"
        usermod -u "$HERMES_UID" hermes
    fi

    if [ -n "$HERMES_GID" ] && [ "$HERMES_GID" != "$(id -g hermes)" ]; then
        echo "Changing hermes GID to $HERMES_GID"
        groupmod -o -g "$HERMES_GID" hermes 2>/dev/null || true
    fi

    actual_hermes_uid=$(id -u hermes)
    needs_chown=false
    if [ -n "$HERMES_UID" ] && [ "$HERMES_UID" != "10000" ]; then
        needs_chown=true
    elif [ "$(stat -c %u "$HERMES_HOME" 2>/dev/null)" != "$actual_hermes_uid" ]; then
        needs_chown=true
    fi
    if [ "$needs_chown" = true ]; then
        echo "Fixing ownership of $HERMES_HOME to hermes ($actual_hermes_uid)"
        chown -R hermes:hermes "$HERMES_HOME" 2>/dev/null || \
            echo "Warning: chown failed (rootless container?) — continuing anyway"
    fi

    if [ -f "$HERMES_HOME/config.yaml" ]; then
        chown hermes:hermes "$HERMES_HOME/config.yaml" 2>/dev/null || true
        chmod 640 "$HERMES_HOME/config.yaml" 2>/dev/null || true
    fi

    echo "Dropping root privileges"
    exec gosu hermes "$0" "$@"
fi

# --- Running as hermes from here ---
source "${INSTALL_DIR}/.venv/bin/activate"

# Create essential directory structure
mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home}

# .env
if [ ! -f "$HERMES_HOME/.env" ]; then
    cp "$INSTALL_DIR/.env.example" "$HERMES_HOME/.env"
fi

# config.yaml
if [ ! -f "$HERMES_HOME/config.yaml" ]; then
    cp "$INSTALL_DIR/cli-config.yaml.example" "$HERMES_HOME/config.yaml"
fi

# Configure Kimi as default provider if KIMI_API_KEY is set
if [ -n "$KIMI_API_KEY" ]; then
    echo "Configuring Kimi as default provider..."
    
    # Detectar si es Kimi Code o Moonshot legacy
    if [[ "$KIMI_API_KEY" == sk-kimi-* ]]; then
        KIMI_BASE_URL="https://api.kimi.com/coding/v1"
        echo "✅ Detected Kimi Code API key"
    else
        KIMI_BASE_URL="https://api.moonshot.ai/v1"
        echo "✅ Detected Moonshot legacy API key"
    fi
    
    python3 -c "
import yaml
import os

config_path = '/opt/data/config.yaml'
base_url = os.environ.get('KIMI_BASE_URL', 'https://api.kimi.com/coding/v1')

try:
    with open(config_path, 'r') as f:
        config = yaml.safe_load(f) or {}
    
    if 'model' not in config:
        config['model'] = {}
    
    config['model']['default'] = 'kimi-k2.6'
    config['model']['provider'] = 'kimi-coding'
    config['model']['base_url'] = base_url
    
    # Configurar modelo auxiliar para compresión y títulos
    if 'auxiliary' not in config:
        config['auxiliary'] = {}
    config['auxiliary']['provider'] = 'kimi-coding'
    config['auxiliary']['model'] = 'kimi-k2.5'
    
    with open(config_path, 'w') as f:
        yaml.dump(config, f, default_flow_style=False)
    
    print(f'✅ Kimi configured with base URL: {base_url}')
except Exception as e:
    print(f'Warning: Could not update config.yaml: {e}')
"
fi

# SOUL.md
if [ ! -f "$HERMES_HOME/SOUL.md" ]; then
    cp "$INSTALL_DIR/docker/SOUL.md" "$HERMES_HOME/SOUL.md"
fi

# Sync bundled skills
if [ -d "$INSTALL_DIR/skills" ]; then
    python3 "$INSTALL_DIR/tools/skills_sync.py"
fi

# --- Start ONLY Gateway (Dashboard disabled for security) ---
echo "========================================="
echo "Starting Hermes Agent - Gateway Only"
echo "========================================="
echo ""

# Start Gateway in foreground (this keeps the container running)
echo "🚀 Starting Gateway (Telegram, Discord, etc.)..."
hermes gateway run
EOF
RUN chmod +x /opt/hermes/docker/entrypoint-railway.sh
ENTRYPOINT [ "/usr/bin/tini", "-g", "--", "/opt/hermes/docker/entrypoint-railway.sh" ]