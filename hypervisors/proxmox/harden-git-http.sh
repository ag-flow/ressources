#!/usr/bin/env bash
# harden-git-http.sh — Contourne l'échec de git 2.39 contre GitHub en HTTP/2 (bug f21f9db6).
# À exécuter en root sur la VM cible :
#   sudo bash harden-git-http.sh              (pose le contournement)
#   sudo bash harden-git-http.sh --remove     (le retire proprement)
#
# LE DÉFAUT
#   git 2.39.5 + libcurl 7.88.1 + nghttp2 1.52.0 — la pile de Debian bookworm —
#   échoue contre GitHub en HTTP/2 sur un dépôt PUBLIC : la requête `info/refs`
#   passe (200), le POST `git-upload-pack` qui suit sur le même flux multiplexé
#   revient 401 avec `www-authenticate: Basic realm="GitHub"`. git en déduit
#   qu'un identifiant lui manque et le réclame — sur un dépôt qui n'en demande
#   aucun.
#
#   Mesuré sur machine de test, configuration git entièrement vide, à la même
#   seconde : HTTP/2 → 6 échecs sur 6 ; HTTP/1.1 forcé → 10 succès sur 10.
#   Le même clone anonyme réussit depuis une machine en git 2.55.
#
# CE QUE FAIT CE SCRIPT
#   Force HTTP/1.1 pour les seules URL github.com, au niveau système (donc pour
#   tous les utilisateurs et tous les outils, pas pour un script en particulier).
#   La valeur vit dans un fichier dédié et commenté, inclus depuis /etc/gitconfig :
#   qui la découvre en trouve la raison à côté, et le retrait est un seul geste.
#
#   C'est un PANSEMENT, pas une correction. La correction de fond est un git
#   récent — impossible sur bookworm aujourd'hui : `git` n'est pas dans
#   bookworm-backports, et le tirer de trixie entraînerait la libc.
#   Elle viendra avec le passage du template à Debian 13 (git 2.47).
#
# Idempotent : re-run → aucune duplication, aucune valeur écrasée.

set -euo pipefail

INC_FILE=/etc/git/http2-github.inc
KEY='http.https://github.com.version'

[[ $EUID -eq 0 ]] || { echo "ERREUR : exécuter en root (sudo)." >&2; exit 1; }
command -v git >/dev/null || { echo "ERREUR : git absent — installer git d'abord." >&2; exit 1; }

GIT_VER=$(git --version | awk '{print $3}')

# ─── Retrait ──────────────────────────────────────────────────────────────────
# Le jour où le template passe à un git sain, le contournement se retire ici
# plutôt qu'à coups de rm : la ligne d'inclusion part avec le fichier.
if [[ "${1:-}" == "--remove" ]]; then
    if git config --system --get-all include.path 2>/dev/null | grep -qxF "$INC_FILE"; then
        git config --system --unset-all include.path "^${INC_FILE}$"
        echo "    Inclusion retirée de /etc/gitconfig."
    fi
    rm -f "$INC_FILE"
    echo "    $INC_FILE supprimé (git $GIT_VER)."
    echo "    Vérifier : 10 clones anonymes consécutifs d'un dépôt public GitHub."
    exit 0
fi

echo "==> Contournement HTTP/2 GitHub — git $GIT_VER"

# ─── 1. Le fichier de configuration, documenté sur place ──────────────────────
install -d -m 755 /etc/git
cat > "$INC_FILE" <<'EOF'
# Posé par harden-git-http.sh (bug f21f9db6) — ne pas retirer sans avoir mesuré.
#
# git 2.39.5 (Debian bookworm) échoue contre GitHub en HTTP/2 : le POST
# git-upload-pack revient 401 sur un dépôt PUBLIC et git réclame un identifiant.
# Mesuré : HTTP/2 → 6 échecs sur 6 ; HTTP/1.1 → 10 succès sur 10, config vide.
#
# Le symptôme ressemble à un défaut de droits, et il est INTERMITTENT (il dépend
# de la réutilisation de connexion) : deux essais qui passent ne prouvent rien.
# C'est ce qui a fait conclure trois fois à tort avant qu'on mesure.
#
# Ciblé sur github.com, sans effet sur les autres hôtes. Coût : pas de
# multiplexage vers GitHub — négligeable pour un clone ou un pull.
#
# QUAND LE RETIRER : quand la machine porte un git récent (passage du template
# à Debian 13). Alors, et seulement alors :
#     sudo bash harden-git-http.sh --remove
# puis vérifier par DIX clones anonymes consécutifs d'un dépôt public :
#     GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false \
#       git clone --depth 1 https://github.com/<org>/<repo>.git /tmp/probe
# Un seul essai concluant ne prouve rien.
[http "https://github.com"]
	version = HTTP/1.1
EOF
chmod 644 "$INC_FILE"
echo "    $INC_FILE écrit."

# ─── 2. L'inclusion depuis /etc/gitconfig ─────────────────────────────────────
# --add et non --replace-all : include.path est multi-valué et peut déjà servir
# à autre chose. On n'ajoute que si notre chemin n'y est pas déjà.
if git config --system --get-all include.path 2>/dev/null | grep -qxF "$INC_FILE"; then
    echo "    Inclusion déjà présente dans /etc/gitconfig."
else
    git config --system --add include.path "$INC_FILE"
    echo "    Inclusion ajoutée à /etc/gitconfig."
fi

# ─── 3. Vérifier que git lit bien la valeur ───────────────────────────────────
# Lecture SANS --system : c'est la résolution normale, celle qui suit les
# includes — donc celle que verront réellement les clones.
EFFECTIF=$(git config --get "$KEY" 2>/dev/null || true)
if [[ "$EFFECTIF" != "HTTP/1.1" ]]; then
    echo "ERREUR : $KEY vaut '${EFFECTIF:-<vide>}' au lieu de HTTP/1.1." >&2
    echo "  L'inclusion n'est pas prise en compte — vérifier /etc/gitconfig." >&2
    exit 1
fi
echo "    Vérifié : $KEY = HTTP/1.1 (résolution effective)."

# ─── 4. Signaler un git qui n'est plus celui qu'on a mesuré ───────────────────
# Le défaut n'est établi que sur 2.39.5. Au-delà, on ne sait pas : on ne retire
# rien tout seul, mais on le dit, pour que le pansement ne survive pas par oubli.
MAJEUR=${GIT_VER%%.*}; MINEUR=$(printf '%s\n' "$GIT_VER" | cut -d. -f2)
if [[ "$MAJEUR" -gt 2 || ( "$MAJEUR" -eq 2 && "${MINEUR:-0}" -ge 40 ) ]]; then
    echo "AVERTISSEMENT : git $GIT_VER — le défaut n'est mesuré que sur 2.39.5." >&2
    echo "  Revérifier s'il est encore nécessaire (10 clones), puis --remove." >&2
fi
