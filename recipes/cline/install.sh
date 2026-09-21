#!/usr/bin/env bash
set -euo pipefail

# Cline — agent CLI branché sur la gateway MCP devpod.
#
# Deux écarts au modèle des autres recettes d'agent (opencode, mammouth), tous
# deux imposés par Cline lui-même et vérifiés dans son code publié (npm `cline`
# 3.0.62, paquets @cline/{core,llms,shared} 0.0.83) :
#
#   1. Cline N'INTERPOLE PAS les variables d'environnement dans sa config. Le
#      schéma zod d'une entrée MCP distante (`@cline/core`) est
#      `{type, url, headers}` où `headers` est un Record<string,string> brut :
#      aucune passe de substitution. Un `Bearer ${MCP_GATEWAY_TOKEN}` posé dans
#      un fichier statique part littéralement sur le réseau — constaté à
#      l'exécution contre un serveur témoin. Le `{env:…}` d'opencode n'a donc
#      pas d'équivalent ici.
#
#   2. Cline NE LIT PAS la clé d'API d'un provider depuis l'environnement. Le
#      registre déclare bien `apiKeyEnv:["DEEPSEEK_API_KEY"]`, mais c'est une
#      métadonnée : elle sert à construire le formulaire de configuration. La
#      seule boucle qui résout `apiKeyEnv` via `process.env[...]` appartient au
#      handler Bedrock (elle retombe sur AWS_BEARER_TOKEN_BEDROCK et filtre les
#      variables AWS). Tout le bundle @cline/llms ne compte que DEUX lectures
#      `process.env[...]`. Pour un provider openai-compatible — deepseek, zai —
#      la clé ne peut venir que de `providers.json`.
#
# Conséquence : les deux fichiers doivent être MATÉRIALISÉS avec les secrets en
# clair, ce qui est impossible au build (les secrets n'existent qu'à
# l'exécution, et ils tourneraient). D'où un wrapper de lancement qui fait un
# upsert à chaque démarrage. C'est l'écart assumé à l'ADR « Agents CLI : config
# par install.sh, pas jinja » : aucun secret dans les fichiers de la recette,
# mais le jeton finit dans un fichier 0600 du HOME de l'utilisateur.

if ! command -v npm &>/dev/null; then
    echo "ERROR: npm not found. Add the nodejs recipe first." >&2
    exit 1
fi

echo "==> Installing Cline CLI"

# Canal stable et non `cline@nightly` : une recette doit poser une version
# reproductible, pas la dernière nuit de build.
npm install -g cline

# Le VRAI lanceur, pas `command -v cline`. Quand le prefix npm est /usr/local —
# le cas par défaut des images devcontainer — npm pose lui-même un lien
# /usr/local/bin/cline, exactement là où le wrapper va s'installer. Résoudre le
# binaire par le PATH reviendrait donc, au second passage de la recette, à faire
# pointer le wrapper sur lui-même : boucle infinie au lancement. `npm root -g`
# donne <prefix>/lib/node_modules, chemin que le wrapper ne touche jamais.
NPM_ROOT="$(npm root -g)"
CLINE_REAL="${NPM_ROOT}/cline/bin/cline"

if [ ! -f "$CLINE_REAL" ]; then
    echo "ERROR: lanceur cline introuvable à ${CLINE_REAL} (npm root -g = ${NPM_ROOT})." >&2
    exit 1
fi
echo "==> Found cline launcher at ${CLINE_REAL}"

# Partie STATIQUE de la config, en lecture seule et hors du HOME : elle ne
# contient que des identifiants publics (URL de la gateway, ids de provider).
# La séparer du script rend l'URL auditable et modifiable sans toucher au code,
# et garantit qu'aucun secret ne vit dans un fichier de la recette.
#
# Pas de `baseUrl` pour les providers : `deepseek` et `zai` sont des providers
# NATIFS de Cline, qui portent déjà leur baseUrl et leur modèle par défaut
# (`defaults.baseUrl`, `defaultModelId`). Les redéclarer ici figerait une valeur
# que l'amont fait évoluer — le catalogue a déjà changé de modèle par défaut
# entre deux versions mineures.
mkdir -p /etc/cline
cat > /etc/cline/devpod.json <<'STATIC'
{
  "mcp": {
    "name": "devpod",
    "type": "streamableHttp",
    "url": "https://dev.yoops.org/mcp/"
  },
  "providers": [
    { "id": "deepseek", "keyEnv": "DEEPSEEK_API_KEY" },
    { "id": "zai",      "keyEnv": "ZAI_API_KEY" }
  ],
  "defaultProvider": "deepseek"
}
STATIC
chmod 644 /etc/cline/devpod.json

# Fusion en Node et non en jq : `jq` n'est pas garanti dans les images de base,
# alors que node l'est — la recette dépend déjà de `recipes/nodejs`.
mkdir -p /usr/local/lib/cline
cat > /usr/local/lib/cline/devpod-config.js <<'MERGE'
#!/usr/bin/env node
"use strict";

// Upsert des deux fichiers de configuration de Cline, à CHAQUE lancement.
//
// À chaque lancement, et non une fois au build, pour trois raisons : les
// secrets n'existent pas au build ; une rotation de jeton est prise en compte
// au démarrage suivant sans rebuild ; et l'utilisateur du workspace n'est pas
// celui qui a exécuté install.sh, donc son HOME n'existait pas encore.
//
// UPSERT et non réécriture : Cline écrit lui-même dans ces deux fichiers —
// bascule `disabled` d'un serveur, flux OAuth, serveurs ajoutés par
// `cline mcp`, provider choisi dans l'IHM. Les écraser effacerait le travail de
// l'utilisateur à chaque lancement, sans message : une régression invisible.
// On ne touche donc QUE les clés qu'on possède.

const fs = require("node:fs");
const path = require("node:path");

const STATIC_CONFIG = "/etc/cline/devpod.json";

function warn(msg) {
  // Sur stderr et sans jamais interrompre : une config incomplète dégrade
  // Cline (pas de MCP, pas de provider préconfiguré), elle ne doit pas
  // l'empêcher de démarrer. L'utilisateur garde `cline mcp` et l'IHM.
  process.stderr.write(`cline (config devpod) : ${msg}\n`);
}

// Résolution des chemins IDENTIQUE à @cline/shared/storage : mêmes variables,
// même ordre, mêmes valeurs par défaut. Toute divergence écrirait à côté du
// fichier que Cline lit — en silence.
function clineDir() {
  const v = (process.env.CLINE_DIR || "").trim();
  if (v) return v;
  const home = (process.env.HOME || "").trim();
  return path.join(home || require("node:os").homedir(), ".cline");
}
function dataDir() {
  const v = (process.env.CLINE_DATA_DIR || "").trim();
  return v || path.join(clineDir(), "data");
}
function mcpSettingsPath() {
  const v = (process.env.CLINE_MCP_SETTINGS_PATH || "").trim();
  return v || path.join(dataDir(), "settings", "cline_mcp_settings.json");
}
function providerSettingsPath() {
  const v = (process.env.CLINE_PROVIDER_SETTINGS_PATH || "").trim();
  return v || path.join(dataDir(), "settings", "providers.json");
}

// Lecture tolérante mais NON destructrice : un fichier illisible en JSON est
// probablement en cours d'édition, ou corrompu par un incident. On renonce à
// l'upsert plutôt que de le remplacer — écraser le fichier de configuration
// d'un utilisateur pour cause de virgule en trop serait une perte de données.
function readJson(file) {
  if (!fs.existsSync(file)) return {};
  try {
    const raw = fs.readFileSync(file, "utf8").trim();
    if (!raw) return {};
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : null;
  } catch (e) {
    warn(`${file} illisible (${e.message}) — laissé intact, upsert ignoré`);
    return null;
  }
}

// 0600 sur le fichier, 0700 sur ses répertoires : ces fichiers portent des
// secrets en clair, faute d'interpolation côté Cline. C'est le prix de l'écart
// à l'ADR, et le moins qu'on puisse faire pour le contenir.
function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  // Écriture par fichier temporaire puis rename : Cline peut lire le fichier
  // au même moment, et un write partiel lui donnerait du JSON tronqué.
  const tmp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, file);
  fs.chmodSync(file, 0o600);
}

function upsertMcp(cfg) {
  const token = (process.env.MCP_GATEWAY_TOKEN || "").trim();
  if (!token) {
    // Pas d'entrée plutôt qu'une entrée cassée : un `Bearer ` vide donnerait un
    // 401 à chaque démarrage de session, bruit permanent pour un secret qui
    // n'a simplement pas été lié au workspace.
    warn("MCP_GATEWAY_TOKEN absent — entrée MCP devpod non écrite");
    return;
  }
  const file = mcpSettingsPath();
  const doc = readJson(file);
  if (doc === null) return;
  if (!doc.mcpServers || typeof doc.mcpServers !== "object") doc.mcpServers = {};

  const existing = doc.mcpServers[cfg.name];
  doc.mcpServers[cfg.name] = {
    // `type` EXPLICITE : sans lui, une entrée à `url` est traitée en `sse` par
    // Cline. La gateway devpod parle streamable HTTP — la session s'ouvrirait
    // sur le mauvais transport, et l'échec se lirait comme une panne réseau.
    ...existing,
    type: cfg.type,
    url: cfg.url,
    headers: { ...(existing && existing.headers), Authorization: `Bearer ${token}` },
  };
  // `disabled` n'est jamais réécrit (il vient du spread de `existing`) : si
  // l'utilisateur a coupé la gateway depuis Cline, elle reste coupée.
  writeJson(file, doc);
}

function upsertProviders(providers, defaultProvider) {
  const wanted = providers.filter((p) => (process.env[p.keyEnv] || "").trim());
  if (wanted.length === 0) {
    warn("aucune clé de provider dans l'environnement — providers.json non écrit");
    return;
  }
  const file = providerSettingsPath();
  const doc = readJson(file);
  if (doc === null) return;

  // Forme attendue par ProviderSettingsManager (@cline/core) :
  // { version: 1, lastUsedProvider?, modes, providers: { <id>: {settings, updatedAt, tokenSource} } }
  if (doc.version !== 1) doc.version = 1;
  if (!doc.modes || typeof doc.modes !== "object") doc.modes = {};
  if (!doc.providers || typeof doc.providers !== "object") doc.providers = {};

  const now = new Date().toISOString();
  for (const p of wanted) {
    const prev = doc.providers[p.id] || {};
    const prevSettings = (prev && prev.settings) || {};
    doc.providers[p.id] = {
      ...prev,
      settings: {
        // On ne pose NI `baseUrl` NI `model` : `deepseek` et `zai` sont des
        // providers natifs qui portent déjà les leurs. Épingler un modèle ici
        // le figerait sur un id que l'amont renomme (le catalogue est passé de
        // `deepseek-flash` à `deepseek-v4-flash` d'une version à l'autre) — et
        // un id inconnu casse précisément le « ça marche sans configuration ».
        ...prevSettings,
        provider: p.id,
        apiKey: process.env[p.keyEnv].trim(),
      },
      updatedAt: now,
      // `manual` et non `oauth` : la clé vient du coffre du portail, pas d'un
      // flux d'autorisation. Mentir sur la source pousserait Cline à tenter un
      // rafraîchissement de jeton qui n'existe pas.
      tokenSource: "manual",
    };
  }

  // Seulement si l'utilisateur n'a rien choisi : c'est ce qui rend le premier
  // lancement utilisable sans configuration. Écraser son choix à chaque
  // démarrage le ramènerait de force sur DeepSeek.
  if (!doc.lastUsedProvider && wanted.some((p) => p.id === defaultProvider)) {
    doc.lastUsedProvider = defaultProvider;
  }
  writeJson(file, doc);
}

function main() {
  const cfg = readJson(STATIC_CONFIG);
  if (!cfg || !cfg.mcp) {
    warn(`${STATIC_CONFIG} absent ou invalide — configuration devpod ignorée`);
    return;
  }
  try {
    upsertMcp(cfg.mcp);
  } catch (e) {
    warn(`entrée MCP non écrite : ${e.message}`);
  }
  try {
    upsertProviders(cfg.providers || [], cfg.defaultProvider);
  } catch (e) {
    warn(`providers non écrits : ${e.message}`);
  }
}

main();
MERGE
chmod 644 /usr/local/lib/cline/devpod-config.js

# Le wrapper. /usr/local/bin est dans le PATH de toutes les images de base —
# contrairement au dossier bin global de npm, d'où le fichier profile.d que
# recipes/opencode doit poser et dont on n'a pas besoin ici.
#
# Le chemin du lanceur est figé À L'INSTALLATION (expansion de $CLINE_REAL
# ci-dessous, heredoc NON quoté) : le résoudre au lancement redonnerait le
# problème de la boucle décrit plus haut.
cat > /usr/local/bin/cline <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail

# Config devpod posée avant CHAQUE lancement (MCP + providers), parce que Cline
# n'interpole pas l'environnement dans ses fichiers — voir les commentaires de
# /usr/local/lib/cline/devpod-config.js.
#
# Ici et pas dans un /etc/profile.d : les sessions lancées par le portail (tmux,
# exec non interactif) ne sourcent pas forcément le profil de login. Le wrapper,
# lui, est traversé par tous les chemins d'appel.
#
# L'échec de l'upsert ne bloque JAMAIS le lancement : mieux vaut un Cline sans
# gateway qu'un Cline qui refuse de démarrer.
node /usr/local/lib/cline/devpod-config.js || true

# exec node <lanceur> plutôt que <lanceur> directement : on ne dépend pas du bit
# exécutable posé par npm sur un fichier du paquet. Le lanceur reste le script
# Node d'origine, qui garde sa logique de résolution du binaire natif et
# d'injection des CA du système.
exec node "${CLINE_REAL}" "\$@"
WRAPPER
chmod +x /usr/local/bin/cline

echo "==> Cline: $(node "${CLINE_REAL}" --version 2>/dev/null || echo 'installed')"
echo "==> Cline: wrapper /usr/local/bin/cline + config statique /etc/cline/devpod.json"
