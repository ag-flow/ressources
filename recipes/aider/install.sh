#!/usr/bin/env bash
set -euo pipefail

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 not found. Add the python recipe first." >&2
    exit 1
fi

echo "==> Installing Aider in /opt/aider (isolated venv)"
python3 -m venv /opt/aider
/opt/aider/bin/pip install --no-cache-dir aider-chat

ln -sf /opt/aider/bin/aider /usr/local/bin/aider

echo "==> Aider: $(aider --version 2>/dev/null || echo 'installed')"

# Provider par défaut : DeepSeek (enabler 38da7c02 — cible sobre de l'ADR).
# DEEPSEEK_API_KEY est injecté à l'exécution (requires_secrets → remoteEnv) ;
# aider le consomme nativement avec --model deepseek/… GLM volontairement
# différé (l'ADR le route via claude-code) ; surcharge ponctuelle : aider --model.
cat > /etc/profile.d/aider-defaults.sh <<'PROFILE'
# aider — provider par défaut (recette aider) : DeepSeek.
export AIDER_MODEL="deepseek/deepseek-chat"
PROFILE
chmod 644 /etc/profile.d/aider-defaults.sh
echo "==> Aider: DeepSeek par défaut (AIDER_MODEL=deepseek/deepseek-chat)"
