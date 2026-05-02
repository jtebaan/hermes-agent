#!/bin/bash
# Script de inicio para Railway: inicia Gateway + Dashboard compartiendo /opt/data
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
    python3 -c "
import yaml
import os

config_path = '/opt/data/config.yaml'
try:
    with open(config_path, 'r') as f:
        config = yaml.safe_load(f) or {}
    
    if 'model' not in config:
        config['model'] = {}
    
    config['model']['default'] = 'kimi-k2.5'
    config['model']['provider'] = 'kimi-coding'
    config['model']['base_url'] = 'https://api.kimi.com/coding/v1'
    
    # Configurar modelo auxiliar para compresión y títulos
    if 'auxiliary' not in config:
        config['auxiliary'] = {}
    config['auxiliary']['provider'] = 'kimi-coding'
    config['auxiliary']['model'] = 'kimi-k2.5'
    
    with open(config_path, 'w') as f:
        yaml.dump(config, f, default_flow_style=False)
    
    print('✅ Kimi configured as default provider')
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

# --- Start both services ---
echo "========================================="
echo "Starting Hermes Agent services..."
echo "========================================="
echo ""

# Start Gateway in background
echo "🚀 Starting Gateway (Telegram, Discord, etc.)..."
hermes gateway run &
GATEWAY_PID=$!
echo "Gateway PID: $GATEWAY_PID"

# Wait a moment for gateway to initialize
sleep 5

# Use Railway's PORT variable or default to 3000
DASHBOARD_PORT="${PORT:-3000}"

# Start Dashboard in foreground (this keeps the container running)
echo ""
echo "🌐 Starting Dashboard (Web UI)..."
echo "Dashboard will be available at: http://0.0.0.0:$DASHBOARD_PORT"
echo ""
hermes dashboard --host 0.0.0.0 --port "$DASHBOARD_PORT" --no-open --insecure &
DASHBOARD_PID=$!
echo "Dashboard PID: $DASHBOARD_PID"

echo ""
echo "========================================="
echo "✅ Both services are running!"
echo "📱 Gateway: Telegram, Discord, etc."
echo "🌐 Dashboard: http://your-domain:$DASHBOARD_PORT"
echo "========================================="
echo ""

# Handle shutdown gracefully
shutdown_services() {
    echo ""
    echo "Shutting down services..."
    kill $DASHBOARD_PID 2>/dev/null || true
    kill $GATEWAY_PID 2>/dev/null || true
    wait
    echo "Services stopped."
    exit 0
}

trap shutdown_services SIGTERM SIGINT

# Keep the script running
wait