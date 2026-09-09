#!/usr/bin/env bash
set -euo pipefail

# Mammouth Code — agent CLI (fork d'opencode) branché sur la gateway MCP devpod.
#
# Recette AUTONOME plutôt que variante de `recipes/opencode` : l'amont livre une
# release GitHub (binaire compilé, aucun npm là où opencode passe par npm -g), le
# provider est natif au fork au lieu d'être déclaré, et l'espace de config a son
# propre préfixe. Les deux recettes ne partagent que le format du fichier JSON.

for tool in curl tar; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: $tool introuvable — requis pour installer Mammouth Code." >&2
        exit 1
    fi
done

echo "==> Installing Mammouth Code"

# On passe par l'installateur officiel au lieu de refaire la résolution de release
# à la main : c'est lui qui choisit la VARIANTE du binaire — `-musl` sur Alpine,
# `-baseline` quand /proc/cpuinfo n'annonce pas AVX2. Reproduire ce choix ici, ce
# serait livrer un binaire qui part en SIGILL sur les hôtes sans AVX2, et l'échec
# n'arriverait qu'au premier lancement, pas au build.
#
# En revanche cet installateur pose le binaire dans "$HOME/.mammouth/bin" — chemin
# CODÉ EN DUR, aucune variable pour le déplacer — et ajoute une ligne de PATH au
# profil shell de $HOME. Exécuté en root au build, il écrit donc dans /root, en
# mode 700 : illisible pour l'utilisateur du workspace. Un wrapper qui pointerait
# vers /root échouerait en « permission denied » pour l'utilisateur réel, pas pour
# root — donc invisible au build. D'où le HOME jetable ci-dessous : l'installateur
# travaille dans un bac à sable (et n'y pollue qu'un profil qu'on jette), puis on
# relocalise le binaire par une vraie copie système.
MAMMOUTH_TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$MAMMOUTH_TMP_HOME"' EXIT

curl -fsSL https://code.mammouth.ai/install.sh | HOME="$MAMMOUTH_TMP_HOME" bash

MAMMOUTH_BIN="${MAMMOUTH_TMP_HOME}/.mammouth/bin/mammouth"
if [ ! -f "$MAMMOUTH_BIN" ]; then
    # Filet si l'amont change INSTALL_DIR : on cherche plus large avant d'échouer.
    MAMMOUTH_BIN="$(find "$MAMMOUTH_TMP_HOME" -type f -name mammouth 2>/dev/null | head -n 1)"
fi

if [ -z "$MAMMOUTH_BIN" ] || [ ! -f "$MAMMOUTH_BIN" ]; then
    echo "ERROR: binaire mammouth introuvable après installation (HOME=${MAMMOUTH_TMP_HOME})." >&2
    exit 1
fi

# Copie et non lien symbolique : la source est dans un répertoire temporaire qui
# disparaît à la sortie du script. /usr/local/bin est déjà dans le PATH de toutes
# les images de base, donc — contrairement à recipes/opencode, où le dossier bin
# global de npm varie — aucun fichier profile.d de PATH n'est nécessaire ici.
install -m 0755 "$MAMMOUTH_BIN" /usr/local/bin/mammouth
echo "==> Mammouth Code: $(mammouth --version 2>/dev/null || echo 'installed')"

# Config globale, écrite par install.sh et non par un template jinja : elle est
# entièrement statique et ne contient aucune valeur propre à l'utilisateur — le
# jeton MCP est référencé en {env:…} et résolu au lancement (ADR « Agents CLI :
# config par install.sh, pas jinja »). Aucun secret n'atterrit sur le disque.
#
# Le $schema reste celui d'opencode : le fork ne le renomme pas, il le ré-estampille
# lui-même à l'écriture (packages/opencode/src/config/config.ts).
#
# AUCUN bloc "provider" ici, contrairement à recipes/opencode — et c'est délibéré.
# Le fork EMBARQUE un provider natif `mammouth-ai` qui s'active sur la seule
# présence de MAMMOUTH_API_KEY dans l'environnement, sans une ligne de config :
# vérifié en exécutant `mammouth models` avec et sans la variable — 0 modèle sans
# elle, 88 avec. Ces 88 entrées portent leurs métadonnées réelles (fenêtre de
# contexte, coût, support des outils). Redéclarer à la main un provider
# openai-compatible sur https://api.mammouth.ai/v1 ajouterait une SECONDE entrée
# dans le sélecteur de modèles, dépourvue de ces métadonnées et à maintenir à
# chaque évolution du catalogue amont — un doublon strictement moins bon.
# Le secret suffit ; la config ne sert plus qu'au modèle par défaut et au MCP.
mkdir -p /etc/mammouth
cat > /etc/mammouth/mammouth.json <<'CONFIG'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "mammouth-ai/mammouth-recommended",
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
chmod 644 /etc/mammouth/mammouth.json

cat > /etc/profile.d/mammouth-config.sh <<'PROFILE'
# Mammouth Code — config globale de la recette (modèle par défaut + gateway MCP).
#
# MAMMOUTH_CONFIG et non OPENCODE_CONFIG : le fork lit chaque drapeau OPENCODE_*
# sous les DEUX préfixes, MAMMOUTH_* d'abord et OPENCODE_* en repli seulement
# (packages/core/src/flag/flag.ts, fonction mammouthKey). Or recipes/opencode
# exporte déjà OPENCODE_CONFIG=/etc/opencode/opencode.json, et les deux recettes
# peuvent être sélectionnées ensemble : /etc/profile.d/opencode-config.sh serait
# alors sourcé APRÈS celui-ci (ordre alphabétique) et mammouth démarrerait sur les
# providers d'opencode — sans la moindre erreur, juste un autre modèle et une clé
# d'API qui n'est pas la sienne. Le préfixe MAMMOUTH_ est ce qui rend les deux
# recettes réellement indépendantes.
export MAMMOUTH_CONFIG="/etc/mammouth/mammouth.json"
PROFILE
chmod +x /etc/profile.d/mammouth-config.sh
echo "==> Mammouth Code: config modele par defaut + MCP gateway ecrite dans /etc/mammouth/mammouth.json"
