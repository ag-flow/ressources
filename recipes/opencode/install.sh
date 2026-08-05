#!/usr/bin/env bash
set -euo pipefail

if ! command -v npm &>/dev/null; then
    echo "ERROR: npm not found. Add the nodejs recipe first." >&2
    exit 1
fi

echo "==> Installing OpenCode CLI"
npm install -g opencode-ai

# Localiser le binaire (nvm, system node, volta…)
OPENCODE_BIN=""
NPM_BIN_DIR="$(npm bin -g 2>/dev/null || true)"
[ -f "${NPM_BIN_DIR}/opencode" ] && OPENCODE_BIN="${NPM_BIN_DIR}/opencode"

if [ -z "$OPENCODE_BIN" ]; then
    PREFIX_BIN="$(npm config get prefix 2>/dev/null)/bin/opencode"
    [ -f "$PREFIX_BIN" ] && OPENCODE_BIN="$PREFIX_BIN"
fi

if [ -z "$OPENCODE_BIN" ]; then
    OPENCODE_BIN="$(command -v opencode 2>/dev/null || true)"
fi

if [ -z "$OPENCODE_BIN" ]; then
    echo "ERROR: opencode binary not found after install — PATH=${PATH}" >&2
    exit 1
fi

echo "==> Found opencode at ${OPENCODE_BIN}"

if [ "$OPENCODE_BIN" != "/usr/local/bin/opencode" ]; then
    cat > /usr/local/bin/opencode <<WRAPPER
#!/usr/bin/env bash
exec "${OPENCODE_BIN}" "\$@"
WRAPPER
    chmod +x /usr/local/bin/opencode
fi

NPM_BIN_PATH="$(dirname "$OPENCODE_BIN")"
cat > /etc/profile.d/opencode-path.sh <<PROFILE
export PATH="\${PATH:+\$PATH:}${NPM_BIN_PATH}"
PROFILE
chmod +x /etc/profile.d/opencode-path.sh

echo "==> OpenCode: $(opencode --version 2>/dev/null || echo 'installed')"

# Config globale opencode (enabler 639f669c) — tranché : écrite par install.sh
# (statique, secrets référencés en {env:…}, aucune valeur en clair) plutôt que
# par template jinja (rien d'utilisateur-spécifique ici). OPENCODE_CONFIG la
# désigne pour tous les shells ; un opencode.json de projet peut la surcharger.
mkdir -p /etc/opencode
cat > /etc/opencode/opencode.json <<'CONFIG'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "deepseek/deepseek-chat",
  "provider": {
    "deepseek": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "DeepSeek",
      "options": {
        "baseURL": "https://api.deepseek.com/v1",
        "apiKey": "{env:DEEPSEEK_API_KEY}"
      },
      "models": {
        "deepseek-chat": {},
        "deepseek-reasoner": {}
      }
    },
    "zai": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "GLM (Z.ai)",
      "options": {
        "baseURL": "https://api.z.ai/api/paas/v4",
        "apiKey": "{env:ZAI_API_KEY}"
      },
      "models": {
        "glm-5.2": {}
      }
    }
  },
  "mcp": {
    "devpod": {
      "type": "remote",
      "url": "https://dev.yoops.org/mcp/",
      "enabled": true,
      "headers": {
        "Authorization": "Bearer {env:MCP_GATEWAY_TOKEN}"
      }
    }
  }
}
CONFIG
chmod 644 /etc/opencode/opencode.json
cat > /etc/profile.d/opencode-config.sh <<'PROFILE'
# opencode — config globale de la recette (providers + MCP gateway devpod).
export OPENCODE_CONFIG="/etc/opencode/opencode.json"
PROFILE
chmod +x /etc/profile.d/opencode-config.sh
echo "==> OpenCode: config providers (DeepSeek defaut, GLM) + MCP gateway ecrite dans /etc/opencode/opencode.json"
