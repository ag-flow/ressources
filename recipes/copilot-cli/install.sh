#!/usr/bin/env bash
set -euo pipefail

# GitHub Copilot CLI — agent de terminal (pendant de claude-code). On ne livre
# QUE la CLI : l'extension IDE Copilot est hors de portée sous openvscode-server
# / Open VSX. Installation calquée sur la recette claude-code (même moule).
# Node.js 22+ requis (fourni par la recette nodejs, cf. installs_after).

if ! command -v npm &>/dev/null; then
    echo "ERROR: npm not found. Add the nodejs recipe first (Copilot CLI requiert Node.js 22+)." >&2
    exit 1
fi

echo "==> Installing GitHub Copilot CLI"
npm install -g @github/copilot

# 1. Localiser le binaire fraîchement installé
COPILOT_BIN=""

# Priorité 1 : prefix global npm (npm bin -g supprimé en npm 9+)
NPM_BIN_DIR="$(npm prefix -g 2>/dev/null)/bin"
if [ -f "${NPM_BIN_DIR}/copilot" ]; then
    COPILOT_BIN="${NPM_BIN_DIR}/copilot"
fi

# Priorité 2 : copilot déjà présent dans le PATH
if [ -z "$COPILOT_BIN" ]; then
    COPILOT_BIN="$(command -v copilot 2>/dev/null || true)"
fi

if [ -z "$COPILOT_BIN" ]; then
    echo "ERROR: copilot binary not found after install — PATH=$PATH" >&2
    exit 1
fi

echo "==> Found copilot at ${COPILOT_BIN}"

# 2. Exposer /usr/local/bin/copilot (toujours dans le PATH, indépendant de nvm)
#    Wrapper plutôt que symlink : résiste aux changements de version nvm.
if [ "$COPILOT_BIN" != "/usr/local/bin/copilot" ]; then
    cat > /usr/local/bin/copilot <<WRAPPER
#!/usr/bin/env bash
exec "${COPILOT_BIN}" "\$@"
WRAPPER
    chmod +x /usr/local/bin/copilot
fi

# 3. Ajouter le répertoire npm bin au PATH système (profile.d)
NPM_BIN_PATH="$(dirname "$COPILOT_BIN")"
PROFILE_D="/etc/profile.d/copilot-cli-path.sh"
cat > "$PROFILE_D" <<PROFILE
# Added by copilot-cli devcontainer recipe
export PATH="\${PATH:+\$PATH:}${NPM_BIN_PATH}"
PROFILE
chmod +x "$PROFILE_D"

# 4. Vérification de version NON-BLOQUANTE
#    </dev/null : coupe stdin → pas d'attente sur un prompt interactif éventuel
#    timeout 15 : borne tout appel réseau résiduel
#    || echo    : filet si le binaire ne répond pas comme attendu
COPILOT_VERSION="$(timeout 15 copilot --version </dev/null 2>/dev/null || echo 'installed')"
echo "==> GitHub Copilot CLI: ${COPILOT_VERSION}"

# 5. Auth = device-flow OAuth, À L'USAGE (aucun secret stocké ici) : l'utilisateur
#    lance `copilot`, tape /login, puis colle le code sur github.com avec SA
#    licence Copilot. L'état d'auth vit dans ~/.copilot/config.json — persisté
#    entre restarts via le memory_volume monté sur ~/.copilot (recipe.meta.yaml).
echo "==> Auth Copilot : lancez 'copilot' puis /login (device-flow OAuth). Config/état : ~/.copilot (persisté sur volume)."
