# CLAUDE.md — Dépôt de ressources workspace-portal (recipes · profiles · composes · jinja)

Tu es l'agent de **ce dépôt de ressources**. Ce dépôt est la **source de vérité externe**
des galeries du portail *workspace-portal* : recettes devcontainer, profils VS Code,
templates docker-compose, et templates de messages Jinja2. Le portail ne stocke rien de
durable pour ces artefacts — il **importe** depuis ce dépôt via des URLs `raw` HTTPS.

Ta mission : produire et maintenir ces artefacts **au format exact** attendu par le portail.
Un artefact mal formé est **silencieusement ignoré** (ligne de `toc.txt` sautée, fetch 404,
validation pydantic échouée → warning côté portail, rien d'importé). Respecte les schémas au
caractère près.

---

## 1. Principe commun des galeries

Chaque type d'artefact vit dans **son répertoire**, avec un fichier d'index **`toc.txt`** :

```
<repo>/
├── recipes/    toc.txt + une entrée par recette
├── profiles/   toc.txt + un .yaml par profil
├── composes/   toc.txt + un sous-dossier par template
└── jinja/      toc.txt + un .j2 par (key, culture)
```

Le portail est configuré avec une **URL de source** par galerie, pointant sur le `toc.txt`
(ou le dossier — les deux formes sont acceptées) :

```
https://raw.githubusercontent.com/<org>/<repo>/refs/heads/main/recipes/toc.txt
https://raw.githubusercontent.com/<org>/<repo>/refs/heads/main/profiles/toc.txt
https://raw.githubusercontent.com/<org>/<repo>/refs/heads/main/composes/toc.txt
https://raw.githubusercontent.com/<org>/<repo>/refs/heads/main/jinja/toc.txt
```

Flux d'import : le portail **lit `toc.txt`**, puis pour chaque entrée **fetch les fichiers**
au chemin **relatif au dossier du `toc.txt`**. Contraintes réseau imposées par le portail
(à connaître, elles conditionnent tes URLs) :

- **HTTPS obligatoire** ; hôte public uniquement (anti-SSRF : IP privées/loopback rejetées).
- **Pas de redirection** suivie (`follow_redirects=False`) → l'URL doit répondre en 200 direct.
- Timeout 5 s par fichier.
- Encodage **UTF-8** partout (accents inclus). Pas de BOM.

**Règle d'or : toute entrée ajoutée à un `toc.txt` doit avoir ses fichiers présents et
valides dans le même commit.** Un `toc.txt` qui référence un fichier manquant casse
l'import de cette entrée.

---

## 2. Recettes (`recipes/`)

Une recette = une **Feature devcontainer** que le portail compose dans le `devcontainer.json`
du workspace. Deux formats coexistent ; **préfère le format répertoire**.

### 2.1 `recipes/toc.txt`

Une **entrée par ligne** (PAS de pipes). Deux formes reconnues :

- `mon-outil/` — recette **format répertoire** (slug + slash final)
- `mon-outil.sh` — recette **format legacy** (script `.sh` seul)

Regex : dossier `^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?/$` · fichier `^[a-zA-Z0-9][a-zA-Z0-9_.-]*\.sh$`.
Lignes vides ignorées.

```
ansible/
terraform/
legacy-tool.sh
```

### 2.2 Format répertoire (recommandé)

```
recipes/mon-outil/
├── recipe.meta.yaml     # métadonnées (schéma ci-dessous)
├── install.sh           # script d'installation exécuté dans le conteneur
└── files/               # (optionnel) fichiers embarqués pour les ops copy (type=initialize)
```

Tu n'écris **pas** de `devcontainer-feature.json` : le portail le génère à l'import.

**`recipe.meta.yaml`** (modèle `RecipeMeta`, `extra` interdit → aucun champ hors liste) :

| Champ | Type | Défaut | Règles |
|-------|------|--------|--------|
| `id` | str | — (requis) | `^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$` — identifiant lisible |
| `key` | str (UUID) | auto-généré | UUID v4. **Fixe-le explicitement** pour que d'autres recettes puissent le référencer via `installs_after` |
| `type` | `install` \| `start` \| `initialize` | `install` | `install` = build ; `start` = à chaque démarrage ; `initialize` = ops copy/transform à la demande |
| `version` | str | `1.0.0` | semver conseillé |
| `description` | str | `""` | |
| `options` | map | `{}` | `nom: {type, default, description}` (voir `RecipeOption`) |
| `requires_secrets` | list | `[]` | `{path, env}` ou string courte (auto → env `PATH.upper()` avec `/`,`-`→`_`). `path` `^[A-Za-z0-9][A-Za-z0-9/_-]{0,127}$`, `env` `^[A-Z][A-Z0-9_]{0,63}$` |
| `installs_after` | list[UUID] | `[]` | **keys** (UUID) des recettes à installer avant. Auto-incluses même non sélectionnées |
| `memory_volume` | objet\|null | `null` | `{name, optional, mapping:{target}}` — volume Docker persistant |
| `copy` | list | `[]` | (type=initialize) `{source, target}` — `source` relatif (pas de `..`), `target` absolu |
| `transform` | list | `[]` | (type=initialize) `{op: replace\|remove, target:{file, node}, value?}` ; `node` = dot-path `$.a.b` ; `replace` exige `value`, `remove` l'interdit |

> Note : la clé legacy **`category`** est acceptée comme alias de `type`. La clé
> **`memory-volume`** (avec tiret) est acceptée comme alias de `memory_volume`.

Exemple `recipes/ansible/recipe.meta.yaml` :

```yaml
id: ansible
key: 6f1c2d34-5678-4abc-9def-0123456789ab
type: install
version: 1.2.0
description: Ansible — Red Hat extension, lint, autocomplétion, YAML intégré
options:
  version:
    type: string
    default: latest
    description: Version d'Ansible à installer
installs_after:
  - 11111111-2222-4333-8444-555555555555   # key de la recette python-dev
```

`install.sh` — script POSIX exécuté dans le conteneur. En-tête conseillé :

```sh
#!/usr/bin/env bash
set -euo pipefail
pip install --no-cache-dir "ansible${VERSION:+==$VERSION}" ansible-lint
```

### 2.3 Format legacy `.sh`

Un seul fichier `recipes/legacy-tool.sh`. Métadonnées dans des **commentaires d'en-tête**
(regex `^#\s*(name|description|version)\s*:\s*(.+)$`) :

```sh
# name: Legacy Tool
# description: Installe l'outil historique
# version: 1.0.0
#!/usr/bin/env bash
set -euo pipefail
# … installation …
```

`id` de la recette = nom de fichier sans `.sh`. Pas d'options, pas de dépendances.

---

## 3. Profils VS Code (`profiles/`)

Un profil = un jeu d'extensions + settings VS Code, importable dans un workspace.

### 3.1 `profiles/toc.txt`

**Pipe-délimité, 4 champs** : `filename.yaml | name | description | extension_count`

- `filename.yaml` : regex `^[a-z0-9][a-z0-9-]*\.yaml$`
- `name` / `description` : libres (pas de `|`)
- `extension_count` : entier (affichage seulement ; met le vrai nombre d'extensions)

```
python-dev.yaml | Python Dev | Python 3.12+ — Ruff, debugpy, mypy | 4
go-dev.yaml | Go Dev | Go 1.22+ — gopls, Delve, tests | 1
```

### 3.2 Fichier profil `<filename>.yaml`

Modèle `ProfileBody` (`extra` interdit) :

| Champ | Type | Règles |
|-------|------|--------|
| `name` | str | 1–80 car., `^[\w\s\-+.]{1,80}$`. **Sert à dériver le slug** (conflit → 409 à l'import) |
| `description` | str | libre |
| `extensions` | list[str] | IDs d'extensions marketplace (ex. `ms-python.python`) |
| `settings` | map | settings VS Code arbitraires |

Exemple `profiles/python-dev.yaml` :

```yaml
name: Python Dev
description: Python 3.12+ — Ruff, debugpy, mypy
extensions:
  - ms-python.python
  - ms-python.vscode-pylance
  - charliermarsh.ruff
  - ms-python.debugpy
settings:
  editor.formatOnSave: true
  python.analysis.typeCheckingMode: basic
```

Le champ `extension_count` du `toc.txt` doit refléter `len(extensions)` (ici 4).

---

## 4. Templates docker-compose (`composes/`)

Un template = un `docker-compose` paramétrable déployable sur un nœud.

### 4.1 `composes/toc.txt`

**Une entrée dossier par ligne** (PAS de pipes), lignes `#…` ignorées. Regex dossier :
`^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?/$`.

```
# Galerie compose
browserless-chromium/
searxng/
```

### 4.2 Structure d'un template

```
composes/browserless-chromium/
├── meta.yaml       # métadonnées + paramètres
└── compose.yml     # le docker-compose (avec placeholders ${PARAM})
```

**`meta.yaml`** — champs consommés par le portail :

| Champ | Type | Règles |
|-------|------|--------|
| `id` | str | slug `^[a-z0-9][a-z0-9-]{0,40}[a-z0-9]$` — identité du template |
| `name` | str | nom affiché |
| `description` | str | |
| `version` | str | requis |
| `tags` | list[str] | filtres/affichage |
| `image` | str | image principale (affichage) |
| `message_key` | str \| null | **clé d'un template Jinja2** rendu quand le service passe `running` (voir §5, contexte deploy) |
| `parameters` | list | paramètres saisis à l'import/déploiement (modèle `ComposeParam`) |

`ComposeParam` : `{key, label, description?, type, default?, required, options?, secret_ref_hint?}`
avec `type ∈ {string, number, bool, enum, port, secret}` (`options` requis pour `enum`).

Exemple `composes/browserless-chromium/meta.yaml` :

```yaml
id: browserless-chromium
name: Browserless Chromium
description: Chromium headless accessible via API REST (screenshots, PDF, scraping).
version: 1.0.0
image: ghcr.io/browserless/chromium
tags: [browser, headless, automation]
message_key: compose_resource_available
parameters:
  - key: CONCURRENT
    label: Sessions concurrentes
    description: Nombre de sessions Chromium simultanées
    type: number
    default: "5"
    required: false
```

`compose.yml` — docker-compose standard, référence les paramètres via `${KEY}` :

```yaml
services:
  chromium:
    image: ghcr.io/browserless/chromium:latest
    environment:
      CONCURRENT: "${CONCURRENT}"
    ports:
      - "3000"
```

> `extra_files` (fichiers compagnons) est **réservé aux templates builtin** du portail —
> ne l'utilise pas dans la galerie.

---

## 5. Templates de messages Jinja2 (`jinja/`)

Un template Jinja2 = un message contextuel rendu par le portail et déposé pour l'**agent**
du workspace (ex. « une machine de test est dispo »). Identité = **`(key, culture)`**.

### 5.1 `jinja/toc.txt`

**Pipe-délimité, 4 champs** : `filename | key | culture | description`

- `filename` : `^[a-zA-Z0-9._-]+\.j2$` — **convention `<key>.<culture>.j2`**
- `key` : `^[a-zA-Z0-9_-]+$`
- `culture` : `^[a-z]{2}$` (ex. `fr`, `en`)
- `description` : libre (pas de `|`)

```
test_host_available.fr.j2 | test_host_available | fr | Machine de test mise à disposition
test_host_available.en.j2 | test_host_available | en | Test host available message
compose_resource_available.fr.j2 | compose_resource_available | fr | Ressource docker-compose mise à disposition
```

### 5.2 Fichier `<key>.<culture>.j2`

Le fichier contient le **body Jinja2 brut** (aucune métadonnée dedans). Rendu par un
`SandboxedEnvironment` (`autoescape=False`, `keep_trailing_newline=True`). Filtres Jinja2
standards disponibles (`join`, `default`, boucles, conditions).

### 5.3 Clés & contextes de rendu (crucial)

Le message n'est utile que si ses variables correspondent au **contexte** injecté par le
portail. Deux contextes existent :

**a) Machine de test** — clé **réservée `test_host_available`** (culture = celle du user).
Variables :

```
host.name        host.ssh_alias   host.ip   host.ssh_user   host.ssh_port
workspace.id     workspace.owner
user.login       user.culture
created_at        # ISO 8601
```

**b) Service compose** — clé = le `message_key` déclaré dans un `meta.yaml` compose (§4).
Variables :

```
host.name  host.ssh_alias  host.ip  host.ssh_user  host.ssh_port
deployment.id            deployment.status
deployment.ports         # dict  nom → port  (itérer avec .items())
deployment.template.id   deployment.template.name    deployment.template.description
deployment.template.version   deployment.template.tags   # list
deployment.compose       # arbre YAML parsé du docker-compose
workspace.id  workspace.owner
user.login    user.culture
started_at               # ISO 8601
```

Exemple `jinja/compose_resource_available.fr.j2` :

```jinja
Une ressource docker-compose « {{ deployment.template.name }} » est disponible pour ton workspace « {{ workspace.id }} ».

{{ deployment.template.description }}
Version : {{ deployment.template.version }}{% if deployment.template.tags %} — tags : {{ deployment.template.tags | join(', ') }}{% endif %}

Ports exposés (hôte {{ host.ip }}, alias SSH {{ host.ssh_alias }}) :
{% for name, port in deployment.ports.items() -%}
- {{ name }} : {{ host.ip }}:{{ port }}
{% endfor %}
```

> Une culture absente retombe sur `en` (fallback). Fournis au moins la culture `en` pour
> chaque `key` si tu veux un défaut universel.

---

## 6. Checklist avant commit

Pour **chaque** artefact ajouté/modifié :

- [ ] L'entrée est présente dans le `toc.txt` du bon dossier, **au bon format** (pipes pour
      profiles/jinja ; entrée simple pour recipes/composes).
- [ ] Tous les fichiers référencés existent dans le même commit, en **UTF-8 sans BOM**.
- [ ] Les identifiants respectent leur **regex** (recipe `id`/`key` UUID, profil filename,
      compose `id` slug, jinja `key`/`culture`/filename).
- [ ] YAML **valide** et **sans champ hors schéma** (les modèles sont `extra="forbid"`).
- [ ] Recettes : `key` fixe (UUID) si d'autres recettes en dépendent ; `installs_after`
      pointe des `key` existants.
- [ ] Profils : `extension_count` du `toc.txt` == `len(extensions)`.
- [ ] Compose : `message_key` (si présent) correspond à une `key` d'un template `jinja/`.
- [ ] Jinja : les variables utilisées appartiennent au **contexte** de la clé (host vs deploy).
- [ ] URLs de fetch résolubles en HTTPS direct (pas de redirection, hôte public).

---

## 7. Générer un nouvel artefact — rappels

- **UUID de recette** : génère un UUID v4 stable et note-le comme `key`. Ne le régénère
  jamais (des dépendances y référent).
- **Slug** (recette `id`, compose `id`) : minuscules, chiffres, tirets ; ni début ni fin par tiret.
- **Message Jinja** : commence par identifier la clé ⇒ le contexte disponible (§5.3), puis
  n'utilise que ces variables. Teste mentalement les boucles (`deployment.ports.items()`).
- **Ne commite jamais de secret** dans un artefact (recette `requires_secrets` ne contient
  que des *chemins* de secrets, jamais de valeurs ; compose `type: secret` = référence).
