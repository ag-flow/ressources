#!/usr/bin/env bash
set -euo pipefail

# Snowflake Cortex Code (« CoCo ») — agent CLI branché sur la gateway MCP devpod.
#
# ─── Ce qui distingue cette recette de recipes/cline ───
#
# CoCo INTERPOLE l'environnement dans sa config MCP. La doc l'énonce noir sur
# blanc (docs.snowflake.com/en/user-guide/cortex-code/cortex-code-mcp) : « CoCo
# expands environment variables in every field of mcp.json before connecting »,
# avec trois syntaxes acceptées — ${VAR}, ${VAR:-defaut} et $VAR. Le jeton de la
# gateway reste donc une RÉFÉRENCE sur le disque : aucun secret matérialisé, on
# reste sur le modèle de l'ADR « Agents CLI : config par install.sh, pas jinja ».
#
# Deux contraintes imposent malgré tout un wrapper de lancement — pour des motifs
# qui n'ont rien à voir avec les secrets :
#
#   1. Les fichiers de config de CoCo vivent sous ~/.snowflake, donc dans le HOME
#      de l'UTILISATEUR du workspace. Ce HOME n'existe pas au build : install.sh
#      tourne en root. Un fichier écrit ici au build atterrirait dans /root et
#      l'utilisateur ne le verrait jamais.
#   2. La connexion Snowflake (~/.snowflake/connections.toml) n'a, elle, AUCUNE
#      interpolation documentée — seul mcp.json en a une, et on n'extrapole pas
#      d'un fichier à l'autre (c'est exactement l'erreur que Cline a punie). Le
#      PAT y est donc écrit RÉSOLU, dans un fichier 0600. Si un essai montre que
#      ${VAR} y est aussi expansé, ce fichier pourra redevenir statique et plus
#      aucun secret ne touchera le disque.

for tool in curl tar; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: $tool introuvable — requis par l'installateur Cortex Code." >&2
        exit 1
    fi
done

# Node est requis deux fois, et les deux méritent d'être dites :
#   - la fusion des fichiers de config (ci-dessous) est écrite en node, pas en jq :
#     jq n'est pas garanti dans les images de base, node l'est par l'installs_after ;
#   - l'installateur amont bascule sur une distribution TypeScript quand l'archive
#     contient dist/index.js, et EXIGE alors node ≥ 18 (il échoue sinon). Le choix
#     appartient à Snowflake, pas à nous : dépendre de nodejs met la recette à
#     l'abri d'une bascule amont qui, autrement, casserait le build sans préavis.
if ! command -v node &>/dev/null; then
    echo "ERROR: node introuvable. Add the nodejs recipe first." >&2
    exit 1
fi

echo "==> Installing Snowflake Cortex Code (CoCo CLI)"

# HOME DÉDIÉ ET PERMANENT, pas un HOME jetable comme dans recipes/mammouth.
#
# L'installateur code en dur $HOME/.local/bin et $HOME/.local/share/cortex :
# aucune variable ne les déplace (lu dans install.sh amont, lignes 29-30). En root
# au build, tout partirait donc dans /root, illisible pour l'utilisateur réel.
#
# Mais ici on ne peut PAS se contenter de copier le lanceur ailleurs, contrairement
# à mammouth : selon la distribution, $HOME/.local/bin/cortex est soit un lien
# symbolique vers .local/share/cortex/<version>/cortex, soit un script généré qui
# porte un INSTALL_DIR ABSOLU vers ce même dossier de version. Dans les deux cas le
# lanceur dépend de l'arborescence de version — la déplacer ou la supprimer casse
# l'installation. D'où un HOME système qui reste en place.
CORTEX_HOME=/opt/cortex
mkdir -p "$CORTEX_HOME"

# NON_INTERACTIVE et SKIP_PATH_PROMPT sont posés EXPLICITEMENT bien que
# l'installateur les déduise de la présence de /.dockerenv : cette détection est un
# détail d'implémentation amont, et un build qui ne présente pas ce fichier
# retomberait sur une invite qui attend un terminal — blocage au build, pas au
# lancement. CORTEX_CHANNEL=stable pour la même raison : ne pas dépendre du défaut.
#
# ÉCART ASSUMÉ — pas d'épinglage de version. L'installateur résout toujours
# <channel>_version.txt, c'est-à-dire la DERNIÈRE version du canal ; il n'accepte ni
# argument ni variable de version (vérifié dans son main()). Épingler supposerait de
# court-circuiter l'installateur et de reconstruire à la main la résolution de
# plateforme et le choix d'archive — un binaire mal choisi n'échouerait qu'au premier
# lancement. On prend donc la dernière stable, on l'affiche en fin de script pour
# qu'elle soit traçable dans le journal de build, et on coupe l'auto-mise à jour
# (settings.json) pour qu'elle ne dérive plus ensuite.
curl -fsSL https://ai.snowflake.com/static/cc-scripts/install.sh \
    | HOME="$CORTEX_HOME" NON_INTERACTIVE=1 SKIP_PATH_PROMPT=1 CORTEX_CHANNEL=stable sh

CORTEX_REAL="${CORTEX_HOME}/.local/bin/cortex"
if [ ! -x "$CORTEX_REAL" ]; then
    echo "ERROR: lanceur cortex introuvable à ${CORTEX_REAL} après installation." >&2
    exit 1
fi

# L'installateur travaille avec l'umask de root : sans ce chmod, l'arborescence
# peut rester illisible pour l'utilisateur du workspace. a+rX (X majuscule) rend
# les dossiers traversables sans rendre exécutable le moindre fichier de données.
chmod -R a+rX "$CORTEX_HOME"
echo "==> Found cortex launcher at ${CORTEX_REAL}"

# Partie STATIQUE de la configuration : hors du HOME, en lecture seule, et SANS
# AUCUN SECRET — seulement l'URL de la gateway et les NOMS des variables. La séparer
# du script rend l'URL auditable et modifiable sans toucher au code.
mkdir -p /etc/cortex-code
cat > /etc/cortex-code/devpod.json <<'STATIC'
{
  "mcp": {
    "name": "devpod",
    "type": "http",
    "url": "https://dev.yoops.org/mcp/",
    "tokenEnv": "MCP_GATEWAY_TOKEN"
  },
  "connection": {
    "name": "devpod",
    "accountEnv": "SNOWFLAKE_ACCOUNT",
    "userEnv": "SNOWFLAKE_USER",
    "patEnv": "SNOWFLAKE_PAT"
  },
  "settings": {
    "autoUpdate": false
  }
}
STATIC
chmod 644 /etc/cortex-code/devpod.json

mkdir -p /usr/local/lib/cortex-code
cat > /usr/local/lib/cortex-code/devpod-config.js <<'MERGE'
#!/usr/bin/env node
"use strict";

// Pose la configuration devpod dans le HOME de l'utilisateur, à CHAQUE lancement.
//
// À chaque lancement et non une fois au build : l'utilisateur du workspace n'est
// pas celui qui a exécuté install.sh, son HOME n'existait pas encore, et une
// rotation de PAT doit être prise en compte au démarrage suivant sans rebuild.
//
// UPSERT et jamais réécriture : CoCo écrit lui-même dans ces fichiers (serveurs
// ajoutés par `cortex mcp add`, connexions créées par l'assistant, réglages de
// l'IHM). Les écraser à chaque lancement effacerait le travail de l'utilisateur
// sans un mot — une régression invisible. On ne touche QUE ce qu'on possède.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const STATIC_CONFIG = "/etc/cortex-code/devpod.json";

function warn(msg) {
  // Sur stderr et sans jamais interrompre : une config incomplète dégrade CoCo,
  // elle ne doit pas l'empêcher de démarrer. L'assistant reste disponible.
  process.stderr.write(`cortex (config devpod) : ${msg}\n`);
}

function env(name) {
  return (process.env[name] || "").trim();
}

// ~/.snowflake est le répertoire de la CLI Snowflake, partagé avec `snow` : on y
// ajoute une connexion nommée, on ne se l'approprie pas.
function snowflakeDir() {
  const home = env("HOME") || os.homedir();
  return path.join(home, ".snowflake");
}
const mcpPath = () => path.join(snowflakeDir(), "cortex", "mcp.json");
const settingsPath = () => path.join(snowflakeDir(), "cortex", "settings.json");
const connectionsPath = () => path.join(snowflakeDir(), "connections.toml");

// Lecture tolérante mais NON destructrice : un fichier illisible en JSON est en
// cours d'édition ou corrompu par un incident. On renonce à l'upsert plutôt que
// de le remplacer — écraser la configuration d'un utilisateur pour une virgule en
// trop serait une perte de données.
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

// 0600 sur les fichiers, 0700 sur leurs dossiers : connections.toml porte le PAT
// en clair, faute d'interpolation documentée côté connexion. Les autres fichiers
// suivent le même régime par cohérence — ~/.snowflake est un répertoire privé.
//
// Écriture par fichier temporaire puis rename : CoCo peut lire au même moment, et
// une écriture partielle lui donnerait du JSON tronqué.
function writeFileAtomic(file, content) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, content, { mode: 0o600 });
  fs.renameSync(tmp, file);
  fs.chmodSync(file, 0o600);
}

// N'écrire QUE si le contenu change : un lancement qui ne modifie rien ne doit
// pas toucher la date du fichier ni risquer de croiser une écriture de CoCo.
function writeJsonIfChanged(file, before, doc) {
  const after = `${JSON.stringify(doc, null, 2)}\n`;
  if (after === before) return false;
  writeFileAtomic(file, after);
  return true;
}

function upsertMcp(cfg) {
  const file = mcpPath();
  const doc = readJson(file);
  if (doc === null) return;
  const before = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
  if (!doc.mcpServers || typeof doc.mcpServers !== "object") doc.mcpServers = {};

  const existing = doc.mcpServers[cfg.name];
  doc.mcpServers[cfg.name] = {
    ...existing,
    // "http" et non "streamableHttp" : le vocabulaire de CoCo est stdio | http |
    // sse. Le nom de transport d'un autre agent n'est pas transposable — une
    // valeur inconnue ici ferait échouer la déclaration du serveur.
    type: cfg.type,
    url: cfg.url,
    headers: {
      ...(existing && existing.headers),
      // Le jeton reste une RÉFÉRENCE : CoCo expanse les variables d'environnement
      // dans tous les champs de mcp.json avant de se connecter. Écrire ici la
      // valeur résolue ferait tomber un secret sur le disque sans aucun gain.
      Authorization: `Bearer \${${cfg.tokenEnv}}`,
    },
  };
  // `disabled` et les autres clés posées par l'utilisateur viennent du spread de
  // `existing` : si la gateway a été coupée depuis CoCo, elle reste coupée.
  writeJsonIfChanged(file, before, doc);
}

function upsertSettings(cfg) {
  const file = settingsPath();
  const doc = readJson(file);
  if (doc === null) return;
  const before = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
  for (const [key, value] of Object.entries(cfg || {})) {
    // SEULEMENT si la clé est absente. autoUpdate:false compense l'absence
    // d'épinglage de version côté installateur — mais si l'utilisateur a
    // délibérément réactivé les mises à jour, c'est son choix, pas le nôtre.
    if (!(key in doc)) doc[key] = value;
  }
  writeJsonIfChanged(file, before, doc);
}

// TOML : pas d'analyseur dans node, et on n'en embarque pas pour trois clés. On
// ne réécrit donc QUE notre propre section, par découpage en lignes, et on laisse
// le reste du fichier octet pour octet — y compris les connexions de l'utilisateur
// et celles de la CLI `snow`.
//
// Limite connue et assumée : une chaîne TOML multi-lignes dont une ligne commence
// par « [ » tromperait la détection de fin de section. Le cas ne se présente pas
// dans un connections.toml réel (comptes, utilisateurs, jetons) et la parade —
// embarquer un analyseur TOML complet — coûterait plus cher que le risque.
function upsertConnection(cfg) {
  const account = env(cfg.accountEnv);
  const user = env(cfg.userEnv);
  const pat = env(cfg.patEnv);
  if (!account || !user || !pat) {
    // Pas de connexion à moitié écrite : une entrée incomplète ferait échouer
    // l'authentification avec un message obscur, là où son absence laisse
    // l'assistant de premier lancement faire son travail.
    warn(
      `connexion Snowflake non écrite — ${[cfg.accountEnv, cfg.userEnv, cfg.patEnv]
        .filter((v) => !env(v))
        .join(", ")} absent(s) de l'environnement`
    );
    return;
  }

  const file = connectionsPath();
  const before = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
  const lines = before ? before.split("\n") : [];

  // Authentification par PAT : le jeton se pose dans `password`, et `authenticator`
  // est OMIS — le renseigner bascule sur un autre mode (externalbrowser, oauth…),
  // qui exige un navigateur et ramène l'interactivité qu'on cherche à éviter.
  const block = [
    `[${cfg.name}]`,
    `account = ${JSON.stringify(account)}`,
    `user = ${JSON.stringify(user)}`,
    `password = ${JSON.stringify(pat)}`,
  ];

  const header = new RegExp(`^\\s*\\[\\s*${cfg.name}\\s*\\]\\s*$`);
  const start = lines.findIndex((l) => header.test(l));
  let next;
  if (start === -1) {
    next = lines.concat(lines.length && lines[lines.length - 1] !== "" ? [""] : [], block, [""]);
  } else {
    let end = start + 1;
    while (end < lines.length && !/^\s*\[/.test(lines[end])) end += 1;
    next = lines.slice(0, start).concat(block, lines.slice(end));
  }

  // default_connection_name seulement s'il est absent, et en TÊTE : une clé posée
  // après un en-tête de section appartiendrait à cette section, pas au document.
  if (!next.some((l) => /^\s*default_connection_name\s*=/.test(l))) {
    next = [`default_connection_name = ${JSON.stringify(cfg.name)}`, ""].concat(next);
  }

  const after = next.join("\n");
  if (after !== before) writeFileAtomic(file, after);
}

function main() {
  const cfg = readJson(STATIC_CONFIG);
  if (!cfg || !cfg.mcp) {
    warn(`${STATIC_CONFIG} absent ou invalide — configuration devpod ignorée`);
    return;
  }
  // Chaque volet est isolé : l'échec de l'un ne doit pas priver l'utilisateur des
  // deux autres, et aucun ne doit empêcher CoCo de démarrer.
  for (const [label, fn, arg] of [
    ["entrée MCP", upsertMcp, cfg.mcp],
    ["connexion Snowflake", upsertConnection, cfg.connection],
    ["réglages", upsertSettings, cfg.settings],
  ]) {
    if (!arg) continue;
    try {
      fn(arg);
    } catch (e) {
      warn(`${label} non écrite : ${e.message}`);
    }
  }
}

main();
MERGE
chmod 644 /usr/local/lib/cortex-code/devpod-config.js

# Le wrapper. /usr/local/bin est dans le PATH de toutes les images de base, y
# compris pour les shells non interactifs : aucun fichier profile.d n'est
# nécessaire ici, contrairement au dossier ~/.local/bin que l'installateur amont
# aurait voulu ajouter au profil de login (et qu'on lui interdit de toucher avec
# SKIP_PATH_PROMPT). Le wrapper est traversé par TOUS les chemins d'appel, y
# compris les sessions tmux lancées par le portail, qui ne sourcent pas le profil.
#
# Le chemin du lanceur est figé À L'INSTALLATION (heredoc NON quoté) : le résoudre
# au lancement par le PATH ferait pointer le wrapper sur lui-même le jour où
# l'amont déciderait d'installer aussi dans /usr/local/bin.
cat > /usr/local/bin/cortex <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail

# Config devpod posée avant CHAQUE lancement (MCP + connexion + réglages), parce
# que les fichiers de CoCo vivent dans le HOME de l'utilisateur, inexistant au
# build — voir /usr/local/lib/cortex-code/devpod-config.js.
#
# L'échec de la pose ne bloque JAMAIS le lancement : mieux vaut un CoCo sans
# gateway qu'un CoCo qui refuse de démarrer.
node /usr/local/lib/cortex-code/devpod-config.js || true

exec "${CORTEX_REAL}" "\$@"
WRAPPER
chmod +x /usr/local/bin/cortex

echo "==> Cortex Code: $("$CORTEX_REAL" --version 2>/dev/null || echo 'installed')"
echo "==> Cortex Code: wrapper /usr/local/bin/cortex + config statique /etc/cortex-code/devpod.json"
