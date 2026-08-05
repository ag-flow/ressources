#!/usr/bin/env bash
set -euo pipefail

# Profil GLM opt-in (enabler 2549f804) : la recette claude-code installe le
# binaire pointé sur Anthropic natif ; celle-ci le bascule sur l'endpoint
# anthropic de Z.ai (Coding Plan) pour TOUT le workspace, de façon reproductible.
# Le token (ANTHROPIC_AUTH_TOKEN) vient du secret llm/zai_coding_token injecté
# à l'exécution (requires_secrets → remoteEnv) — jamais écrit sur disque.

if ! command -v claude &>/dev/null; then
    echo "ERROR: claude not found. Add the claude-code recipe first." >&2
    exit 1
fi

cat > /etc/profile.d/claude-code-glm.sh <<'PROFILE'
# claude-code → GLM (Z.ai, Coding Plan) — recette claude-code-glm.
# ANTHROPIC_AUTH_TOKEN est fourni par l'environnement du workspace (secret).
export ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"
export ANTHROPIC_MODEL="glm-5.2"
PROFILE
chmod 644 /etc/profile.d/claude-code-glm.sh

echo "==> claude-code-glm: endpoint Z.ai anthropic configuré (modèle glm-5.2, opt-in par recette)"
