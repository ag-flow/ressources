#!/usr/bin/env bash
set -euo pipefail

# GitHub CLI (gh) — dépôt apt officiel de GitHub (cli.github.com).
# Pas de npm, pas de binaire téléchargé à la main : le dépôt apt couvre amd64
# et arm64 et laisse `apt-get upgrade` faire son travail ensuite.
# L'état d'auth vit dans ~/.config/gh (hosts.yml) — persisté entre restarts via
# le memory_volume déclaré dans recipe.meta.yaml.

GH_VERSION="${RECIPE_OPT_GH_VERSION:-${GH_VERSION:-latest}}"

command -v apt-get >/dev/null 2>&1 || { echo "ERROR: apt-get not found. Requires Debian/Ubuntu." >&2; exit 1; }

echo "==> Installing GitHub CLI (gh) — version demandée : ${GH_VERSION}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list

apt-get update -qq

# Version exacte si demandée, avec repli explicite sur latest : une version
# retirée du dépôt ne doit pas laisser le workspace sans gh du tout.
if [ "$GH_VERSION" = "latest" ] || [ -z "$GH_VERSION" ]; then
    apt-get install -y --no-install-recommends gh
elif ! apt-get install -y --no-install-recommends "gh=${GH_VERSION}"; then
    echo "WARNING: gh=${GH_VERSION} introuvable dans le dépôt — repli sur la dernière version." >&2
    apt-get install -y --no-install-recommends gh
fi

# Complétion bash pour tous les shells du conteneur (non bloquant).
if gh completion -s bash > /etc/bash_completion.d/gh 2>/dev/null; then
    echo "==> Complétion bash installée (/etc/bash_completion.d/gh)"
else
    rm -f /etc/bash_completion.d/gh
    echo "WARNING: complétion bash non générée — étape sautée." >&2
fi

echo "==> GitHub CLI: $(gh --version 2>/dev/null | head -1)"

# Auth = device-flow OAuth, À L'USAGE (aucun secret stocké dans le dépôt) :
# l'utilisateur lance `gh auth login` et colle le code sur github.com. Un
# GITHUB_TOKEN/GH_TOKEN déjà présent dans l'environnement est utilisé tel quel
# par gh, sans passer par ~/.config/gh.
echo "==> Auth GitHub : lancez 'gh auth login' (device-flow OAuth). État d'auth : ~/.config/gh (persisté sur volume)."
