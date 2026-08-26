# CLAUDE.md — Dépôt de ressources workspace-portal (recipes · profiles · composes · jinja)

Tu es l'agent de **ce dépôt de ressources**. Ce dépôt est la **source de vérité externe**
des galeries du portail *workspace-portal* : recettes devcontainer, profils VS Code,
templates docker-compose, et templates de messages Jinja2. Le portail ne stocke rien de
durable pour ces artefacts — il **importe** depuis ce dépôt via des URLs `raw` HTTPS.

Ta mission : produire et maintenir ces artefacts **au format exact** attendu par le portail.
Un artefact mal formé est **silencieusement ignoré** (ligne de `toc.txt` sautée, fetch 404,
validation pydantic échouée → warning côté portail, rien d'importé). Respecte les schémas au
caractère près.

> Ce dépôt héberge **aussi** une galerie pour un **autre portail** : les **templates de
> structure docflow** (dossier `Docflow/templates/`). Ce sont des artefacts distincts, avec
> leur propre mécanisme d'import et leurs propres schémas — voir **§8**. Les sections §1 à §7
> ci-dessous concernent uniquement les galeries *workspace-portal*.

> Il héberge **également** les **scripts d'hyperviseur** (dossier `hypervisors/`) : scripts de
> provisioning de VM consommés par le portail *workspace-portal*, mais **sans import de galerie**
> — leur URL est saisie à la main dans la config d'un type d'hyperviseur. Schémas et règles
> propres — voir **§9**.

---

## mcp

Tu es connecté au mcp du protail devpod via le serveur claude-code

## Backlog

La gatway mcp propose une api pour se connecter à docflow
docflow contient des workspaces qui contiennent des blocs de documents.
workspace=ressources et bloc=Backlog tu as un backlog de tache à executer.

- Quand on te demande de traiter le backlog tu te connectes Tu identifies les taches qui ne sont pas en status 'en review'
- Quand tu prends une tache tu passes le statut à 'en cours'
- Quand tu as finis tu passes le statut de la tache 'en review'.
- Si la tâche le necessite tu rédiges les critères en ATDD.

## Documentation

La gatway mcp propose une api pour se connecter à docflow
docflow contient des workspaces qui contiennent des blocs de documents.
workspace=devpod et bloc=Documentation tu as un espace de stockage pour enregistrer et lire la doc.

un espace de documentation globals cross projet (workspace=globals et bloc=Documentation) permet de lister les informations globals à tout les projets. A chaque fois que tu apprends quelques chose inscris le en article qui servira aux autres agents.


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
| `scope` | `workspace` \| `host` | `workspace` | **OÙ** la recette se pose. `host` = sur une machine, via SSH privilégié — voir §2.4 |
| `host_usages` | list | `[]` | (scope=host, **requis**) familles de machines visées : `workspaces`, `tests`, `portail`, `ressources`, `autres` |
| `preconditions` | list | `[]` | (scope=host) `{disk_free_gb?, disk_path?, path_exists?, path_writable?, arch?}` — vérifiées avant tout téléchargement |

> Note : la clé legacy **`category`** est acceptée comme alias de `type`. La clé
> **`memory-volume`** (avec tiret) est acceptée comme alias de `memory_volume`.

### 2.2.1 Recettes de host (`scope: host`)

`type` dit **quand** (build, démarrage, à la demande) ; `scope` dit **où**. Les deux sont
orthogonaux : une recette de host garde un `type`.

Une recette qui exige `/dev/kvm`, des dizaines de Go, ou un accès matériel n'a pas sa place dans
un conteneur : elle se pose **une fois sur une machine**. Sans `scope: host` explicite, elle est
traitée comme une recette de workspace, avec **deux dégâts symétriques** : elle n'apparaît jamais
dans les recettes applicables à une machine, et elle est proposée à l'installation dans un
conteneur, où elle échoue.

```yaml
scope: host
host_usages:      # au moins une famille — le modèle refuse scope:host sans elle
  - tests
  - ressources
preconditions:    # chacune doit vérifier au moins un critère
  - path_writable: /dev/kvm
  - disk_free_gb: 30        # disk_path par défaut : /
  - arch: x86_64            # tel que `uname -m` le rapporte
```

**`path_exists` ou `path_writable` ?** Préfère `path_writable` dès que la recette doit *utiliser*
le chemin et pas seulement constater qu'il est là — un périphérique peut exister et rester
inaccessible faute d'appartenance au bon groupe. Les deux rendent un message distinct, et ces
messages appellent des gestes différents :

| déclaration | message | geste attendu |
|---|---|---|
| `path_exists` | `chemin absent : /dev/kvm` | activer la capacité sur l'hôte (ex. nesting Proxmox) |
| `path_writable` | `chemin non accessible en lecture/ecriture : /dev/kvm` | ajouter l'utilisateur au groupe (`usermod -aG`) |

Ne déclare **pas les deux pour un même chemin** : `path_writable` implique `path_exists`, et deux
lignes de refus pour une seule cause égarent l'administrateur.

Règles de cohérence appliquées par le modèle : `host_usages` et `preconditions` **exigent**
`scope: host` (les déclarer sans lui échoue) ; `scope: host` **exige** au moins une famille dans
`host_usages` ; une précondition vide (aucun critère) est refusée — une garantie qui ne vérifie
rien est pire que pas de garantie.

**Déclare les préconditions même si ton script les vérifie déjà.** Le préflight du script protège
la machine ; la déclaration permet au portail de les **afficher**, de refuser le lancement et de
produire un message lisible avant même d'ouvrir la connexion de transfert.

**Options : le portail exporte les valeurs PRÉFIXÉES** `RECIPE_OPT_<NOM_EN_MAJUSCULES>`. Un script
qui lit `AVD_NAME` au lieu de `RECIPE_OPT_AVD_NAME` **n'reçoit jamais** l'option et retombe en
silence sur son défaut. Le préfixe est délibéré : des noms génériques exportés tels quels dans un
shell distant privilégié entreraient en collision avec l'existant. Motif à reprendre, qui garde le
script lançable seul :

```sh
API="${RECIPE_OPT_API_LEVEL:-${API_LEVEL:-35}}"
```

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

Modèle `ProfileBody` (`extra` interdit → **toute clé hors de cette liste fait échouer
l'import** — pas de champ supplémentaire, même « inoffensif ») :

| Champ | Type | Requis | Règles |
|-------|------|--------|--------|
| `name` | str | **oui** | 1–80 car., `^[\w\s\-+.]{1,80}$`. **Sert à dériver le slug** (conflit → 409 à l'import) |
| `description` | str | non | libre |
| `image` | str | non | **image de base du devcontainer** (référence OCE — voir contrat ci-dessous). Vide/absent = image par défaut du portail |
| `extensions` | list[str] | non | IDs d'extensions marketplace (ex. `ms-python.python`) |
| `settings` | map | non | settings VS Code arbitraires |

**Contrat du champ `image`** :

- **Référence OCI stricte** : `[registre[:port]/]chemin[:tag][@sha256:…]`. Le chemin est en
  **minuscules**, aucune valeur ne commence par `-`, longueur totale **≤ 400 caractères**.
  Exemple : `mcr.microsoft.com/devcontainers/python:3.12`. Regex de validation :

  ```
  ^[a-z0-9][a-z0-9._-]*(:[0-9]{1,5})?(/[a-z0-9][a-z0-9._-]*)*(:[A-Za-z0-9_][A-Za-z0-9._-]{0,127})?(@sha256:[a-f0-9]{64})?$
  ```

- **Vide ou absent** = image par défaut du portail (`mcr.microsoft.com/devcontainers/base:ubuntu`).
- **Sémantique** : le workspace **démarre** sur cette image ; les recettes (§2) ne doivent
  installer que ce qui **manque** à l'image. Choisir une image déjà outillée et cohérente avec
  le profil évite des installations longues au premier démarrage.
- **Toujours pinner un tag majeur explicite** (`python:3.12`, jamais `latest`).

Exemple `profiles/python-dev.yaml` :

```yaml
name: Python Dev
description: Python 3.12+ — Ruff, debugpy, mypy
image: mcr.microsoft.com/devcontainers/python:3.12
extensions:
  - ms-python.python
  - ms-python.vscode-pylance
  - charliermarsh.ruff
  - ms-python.debugpy
settings:
  editor.formatOnSave: true
  python.analysis.typeCheckingMode: basic
```

Le champ `extension_count` du `toc.txt` doit refléter `len(extensions)` (ici 4). Le format des
lignes de `profiles/toc.txt` **ne change pas** : l'`image` n'y figure pas, elle est lue dans le
YAML à l'import.

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

### 4.3 `extra_files` — fichiers compagnons

Un template qui a besoin d'un fichier à côté du `compose.yml` (config d'agent, conf de serveur)
le déclare dans `meta.yaml`. **C'est supporté pour les templates de galerie** — le portail
résout chaque nom dans le **même dossier** que `compose.yml` et fetch le contenu à l'import.

```yaml
extra_files:
  - config.alloy
```

Contraintes : nom de fichier **relatif**, pas de chemin absolu, pas de `..` — un nom hors du
dossier du template est refusé en 422. Le fichier doit exister dans le même commit, sinon
l'import échoue en 502.

### 4.4 Bind-mounts — liste blanche stricte

Un `compose.yml` de galerie ne peut monter **que quatre chemins absolus** de la machine :

```
/var/run/docker.sock   /var/log   /run/log/journal   /etc/machine-id
```

Tout autre bind-mount absolu (`/proc`, `/sys`, `/`, `/var/lib/docker`…) fait **échouer
l'import** avec `bind-mount absolu interdit`. Pour le reste : chemin relatif (`./data:/app/data`)
ou volume nommé.

Conséquence à connaître avant d'écrire un collecteur : un agent qui veut mesurer la **machine**
n'a pas accès à `/proc`, `/sys` ni `/`. En pratique Docker ne cloisonne pas `/proc/stat`,
`/proc/meminfo` ni `/proc/loadavg` — CPU, mémoire et charge restent justes — mais le **système de
fichiers** et le **réseau** mesureraient le conteneur. Coupe ces collecteurs plutôt que de laisser
remonter des séries plausibles et fausses.

Deux autres règles appliquées à l'import :

- **Pas de port hôte codé en dur** (`- "3000:3000"`). Utilise le format alias
  (`web>3000:3000`), résolu au déploiement.
- **Toute variable `${VAR}` du compose doit être déclarée en `parameters`**, sauf les quatre
  injectées par le portail : `LOKI_URL`, `HOSTNAME`, `MODULE`, `ROLE`. Une variable oubliée
  fait échouer l'import, pas le déploiement.

Enfin, une image sans tag ou en `:latest` ne bloque pas l'import mais produit un **warning** :
épingle une version.

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
- [ ] **Recettes : toute modification incrémente `version`** dans `recipe.meta.yaml`, dans le
      même commit. Le portail pose une sentinelle `<version> <date>` par recette appliquée et
      **ne rejoue rien** si la version n'a pas bougé : à version constante, les machines déjà
      provisionnées ne recevront jamais le changement. Semver — retrait d'un défaut, option
      devenue obligatoire, étape activée par défaut ou changement de périmètre = **major**.
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

---

## 8. Templates de structure docflow (`Docflow/templates/`)

> Portée : le sous-dossier **`Docflow/templates/`**. Cette galerie vise un **autre portail**
> (*docflow*), distinct de *workspace-portal* (§1–§7) : mécanisme d'import, schémas et checklist
> propres, décrits ici. Le dossier est volontairement **autoportant** — il peut être extrait tel
> quel dans un repo dédié (galerie de templates docflow) sans perdre le savoir nécessaire pour
> continuer à en écrire ; tout ce qui est indispensable est reproduit ci-dessous.

### 8.1 Ce qu'est ce répertoire pour docflow

Un **template** = un fichier YAML versionné qui décrit une **structure** de workspace : des
`functional_type` (epic, feature, bug…), leurs `properties_defs` typées, leurs valeurs
autorisées, leur hiérarchie parent/enfant. Importer un template **clone la structure** dans un
workspace — jamais le contenu (aucun document, aucune valeur de propriété n'est créé).

**Mécanisme de galerie (déjà câblé côté docflow, vérifié dans le code) :**

- `toc.txt` à la racine de `Docflow/templates/` : une ligne = un slug de template (pas
  d'extension). Lignes vides et lignes commençant par `#` ignorées.
- Pour chaque slug listé, docflow va chercher `<base_url>/<slug>.yaml`.
- Une instance docflow enregistre une ou plusieurs **sources de galerie** (URL de base HTTP) —
  soit via `GALLERY_URL` (variable d'env, source par défaut), soit via l'écran admin
  (`gallery_source`, plusieurs sources possibles).
- **Extraire ce répertoire dans un repo dédié et le servir en HTTP brut (ex. raw GitHub) suffit à
  en faire une source de galerie** : `toc.txt` + `<slug>.yaml` à la racine servie, rien d'autre.
  C'est exactement le mécanisme visé par l'extraction — pas besoin de coder quoi que ce soit côté
  docflow pour que ça fonctionne, juste respecter ce contrat de fichiers.

**Conséquence pour toi** : chaque template doit être valide **seul**, sans dépendre d'un fichier
voisin (sauf `target_type` qui peut légitimement pointer un type d'un *autre* template — mais
c'est résolu par le workspace au moment de l'import, jamais par une lecture croisée de fichiers).

### 8.2 Format du fichier (schéma exact — vérifié dans `backend/src/docflow/templates/models.py`)

```
Template(version: int, template: str, label: str, functional_types: [TypeDef])

TypeDef(
  slug: str,                    # identité, IMMUABLE une fois publié — jamais d'UUID dans un template
  label: str | null,
  abstract: bool = false,       # true = socle réutilisable, jamais matérialisé en base
  inherit: str | null,          # slug d'un autre TypeDef du MÊME fichier
  parent: str | null,           # slug du type parent (hiérarchie documentaire), null = racine
  content_template: str | null, # squelette markdown — voir "Écarts connus" : INERTE à l'import
  properties: [PropDef] = []
)

PropDef(
  slug: str, label: str,
  type: "text" | "int" | "restricted_list" | "date" | "bool" | "reference",
  # ⚠ PAS "url" / "float" malgré 34_MPTS — voir "Écarts connus"
  required: bool = false,
  default: str | null,
  constraints: [{ kind: str, value: str, message: str? }] = [],
  allowed_values: [{ slug: str, label: str, position: int = 0, color: str? }] = [],
  target_type: str | null,      # slug de type cible, PROPRIÉTÉS reference uniquement
  max_occurrences: int | null   # multi-valeur — voir "Écarts connus" : INERTE à l'import
)
```

`extra="forbid"` sur **tous** ces modèles : un champ inconnu (faute de frappe, ancien nom) fait
**échouer le parsing entier** du fichier, pas juste ce champ. Vérifie l'orthographe exacte.

Aucun champ n'a de contrainte de format sur `slug` au niveau du parsing pydantic — la discipline
est **à ta charge**. Convention du reste de docflow (à respecter) : `^[a-z0-9][a-z0-9_-]*$`,
minuscules, pas d'accent, pas d'espace.

### 8.3 Héritage — résolu UNE FOIS à l'import, jamais stocké tel quel

- `inherit` : héritage **simple** (un seul parent d'héritage), chaîne **acyclique** — un cycle
  fait échouer l'import avec une erreur explicite.
- Override d'une propriété par `inherit` = **remplacement complet par slug**, jamais de fusion
  partielle. Si `feature` hérite `statut` de `base_statusable` et redéclare une propriété `statut`
  avec un autre pipeline d'`allowed_values`, la version de `feature` **remplace entièrement**
  celle de la base (constraints et allowed_values inclus — rien n'est fusionné champ à champ).
- `abstract: true` : le type n'est **jamais matérialisé** en base. Il n'existe que pour être
  hérité. Sers-t'en pour factoriser un socle commun (`base_statusable`, `base_editorial` dans les
  exemples existants) — mais **ne le référence jamais** comme `parent:` d'un autre type (parent
  = hiérarchie documentaire, un abstrait n'a pas d'instance).
- `parent` (documentaire) ≠ `inherit` (schéma). Un type peut hériter de A tout en étant
  documentairement enfant de B. **Plusieurs types peuvent partager le même `parent`** (ex.
  `story` et `atdd` tous deux enfants de `feature`) — c'est un cas normal, pas une erreur.
- La base ne connaît **que des types concrets à plat** : `inherit`/`abstract` n'existent pas en
  SQL, uniquement dans le YAML source.

### 8.4 Types de propriété — forme stockée et contraintes valides

| `type` | forme stockée | contraintes valides (`kind`) | remarque |
|---|---|---|---|
| `text` | texte libre | `pattern` (regex), `min`/`max` non pertinents | `pattern` **réservé à `text`** — refusé ailleurs |
| `int` | entier | `min`, `max` (numérique) | |
| `date` | ISO `YYYY-MM-DD` (jour seul, pas d'heure/fuseau) | `min`, `max` (bornes de date) | pas de `datetime` — hors périmètre |
| `bool` | `"true"` / `"false"` littéral strict | aucune | `"1"`/`"oui"` sont **rejetés**, pas coercés |
| `restricted_list` | référence à une `allowed_values[].slug` | — | `default` doit être un `slug` déclaré dans `allowed_values` |
| `reference` | UUID d'un autre document | — | voir section dédiée ci-dessous |

`pattern` sur autre chose que `text` fait échouer la validation applicative à l'usage (pas au
parsing du template). Ne le mets jamais sur `int`/`date`/`bool`/`reference`.

`allowed_values[].color` : pas de contrainte de format imposée, mais **réutilise la palette déjà
en usage** dans les templates existants plutôt que d'inventer de nouvelles teintes (cohérence
visuelle avec le thème shadcn/Tailwind du front) :

| couleur | hex | usage typique |
|---|---|---|
| gris neutre | `#9AA3AF` | état initial / neutre |
| gris foncé | `#6B7280` | archivé / inactif |
| indigo | `#6366F1` | en cadrage / assignation |
| bleu ciel | `#0EA5E9` | en cours |
| ambre | `#F59E0B` | en review / attention |
| vert | `#22C55E` | terminé / validé / positif |
| rouge | `#EF4444` | bloquant / rejeté / critique |

### 8.5 Propriété `reference` — relation typée vers un autre document

```yaml
- slug: assignee
  label: "Assigné à"
  type: reference
  target_type: personne     # slug d'un TypeDef existant (même fichier ou autre template déjà importé)
  required: false
```

- `target_type` restreint le picker à ce type de document cible. Omets `target_type` (laisse
  `null`) pour une cible libre (n'importe quel document du workspace).
- Le **type cible doit exister comme document réel** — donc jamais un type `abstract: true`. Si
  la cible est un simple « annuaire » (ex. `personne`), déclare-le comme type concret normal,
  `parent: null`, sans propriété `statut` (pas de cycle de vie utile pour une fiche annuaire).
- Un template qui a besoin d'une cible définie dans un **autre** template (ex. le point de
  jonction métier↔dev d'`agile-basic.yaml`, où un type `strategie-metier.yaml` référence `epic`)
  reste valide **à condition que le workspace cible ait déjà importé les deux templates** avant
  l'affectation — l'import ne vérifie la résolution de `target_type` qu'à l'écriture d'une valeur,
  pas à l'import de structure.

### 8.6 Multi-valeur (`max_occurrences`)

```yaml
- slug: reviewers
  type: reference
  target_type: personne
  max_occurrences: 1000     # convention : grand nombre = "illimité de fait", 1 = mono (défaut)
```

Défaut = `1` (mono-valeur) si omis. Pour une liste bornée (ex. 1 à 3 valeurs), mets la borne haute
réelle (`max_occurrences: 3`) ; pour une liste non bornée en pratique, utilise une valeur haute
conventionnelle (`1000` dans les templates existants) plutôt qu'un très grand entier arbitraire —
garde cette convention si tu ajoutes un nouveau cas d'usage multi-valeur.

### 8.7 Modèle de contenu (`content_template`)

```yaml
content_template: |
  # {{title}}
  > Créée le {{date}}

  ## Contexte
  ## Objectif
  ## Critères d'acceptation
  - [ ] …
```

Seules variables substituées : **`{{title}}`** (titre saisi à la création) et **`{{date}}`**
(date du jour, ISO). Substitution **une seule fois**, à la création, jamais de liaison vivante.
Style observé dans les templates existants : titre `# {{title}}`, une ligne de contexte en
citation (`> …`), sections `##` vides prêtes à remplir, listes à cocher `- [ ] …` pour les items
actionnables. Reste cohérent avec ce style pour les nouveaux templates.

### 8.8 Discipline de versionnage — ce qui est additif vs ce qui casse

`version` est un **contrat** : une version supérieure **promet** un diff rétro-compatible. Le
tableau ci-dessous est la logique exacte du moteur de diff (vérifié dans
`backend/src/docflow/templates/diff.py`) :

| Changement | Verdict | Effet |
|---|---|---|
| type / propriété / valeur autorisée absente côté workspace | **ajout** | appliqué |
| identique en tout point | **no-op** | rien |
| `label` d'un type ou d'une propriété modifié | **maj douce** | appliqué, seul champ modifiable sans casse |
| `label` d'une `allowed_value` modifié | **maj douce** | idem |
| `type` d'une propriété changé | **conflit** | import bloqué en entier |
| `required` ou `default` modifié | **conflit** | import bloqué en entier |
| une `constraint` existante modifiée (valeur ou message) | **conflit** | import bloqué en entier |
| `position` ou `color` d'une `allowed_value` modifiée | **conflit** | import bloqué en entier |
| `parent` d'un type modifié | **conflit** | import bloqué en entier |
| élément retiré du template | **ignoré** | jamais de suppression automatique |

**Un seul conflit dans le lot bloque l'import entier** (rien n'est écrit, y compris les ajouts
valides du même diff). Donc : si un changement n'est **pas strictement additif** au sens de ce
tableau, ce n'est **pas une nouvelle version du même fichier** — c'est un **nouveau template**
(nouveau fichier, nouveau slug dans `toc.txt`). Ne bump jamais la version pour un changement qui
tomberait en conflit — ça casse l'import pour tout workspace qui a déjà cette version en place.

`target_type` et `max_occurrences` ne sont **pas encore comparés par le diff** (voir écart connu
ci-dessous) : les faire évoluer sur une propriété déjà publiée ne sera ni appliqué ni détecté en
conflit aujourd'hui. Traite-les comme les autres champs structurels par prudence : ne les change
jamais sur un slug déjà publié, publie un nouveau type si besoin.

### 8.9 Écarts connus entre la spec et l'implémentation actuelle de l'import

Vérifiés dans le code de docflow (`backend/src/docflow/templates/`), à re-vérifier si tu
retravailles ce fichier après une évolution du backend — ce ne sont **pas** des choix de design à
respecter dans tes templates, ce sont des **limites actuelles à connaître** pour ne pas promettre
un comportement qui n'existe pas encore :

- **`content_template` n'est pas repris par l'import.** Le champ est parsé, mais l'`INSERT` du
  type fonctionnel n'écrit pas cette colonne — c'est un choix documenté (décision actée : modèle
  de contenu édité en UI, pas embarqué dans le paquet d'import v1). Écris-le quand même dans le
  template (documentation vivante, reprise manuelle possible plus tard côté UI), mais **ne
  promets pas** qu'un import de galerie pré-remplit le corps des documents.
- **`target_type` n'est pas encore reporté en base par l'import.** Une propriété `reference` est
  bien créée, mais sans restriction de cible (`target_functional_type_ref` reste `NULL`) — la
  cible reste **libre** en pratique tant que ce n'est pas câblé, même si `target_type` est
  renseigné dans le YAML. Continue à le déclarer correctement (c'est la bonne pratique dès que
  l'import sera complété), mais ne le vends pas comme filtrant déjà le picker après un import de
  galerie.
- **`max_occurrences` n'a aucune colonne ni effet runtime.** Le multi-valeur (`39_MMV`) n'est pas
  implémenté côté stockage — déclarer `max_occurrences > 1` est accepté par le parsing mais n'a
  aujourd'hui aucun effet observable après import.
- **`type: url` et `type: float` ne sont pas acceptés par le modèle d'import** (`Literal` limité à
  `text`/`int`/`restricted_list`/`date`/`bool`/`reference`), alors que le moteur de validation des
  valeurs de propriété les supporte déjà en interne. Un template qui déclare `type: url` ou
  `type: float` sur une propriété **échoue au parsing**, avant même d'atteindre le diff. Ne les
  utilise pas tant que ce n'est pas corrigé côté import.

Si l'un de ces écarts est comblé côté backend, mets à jour cette section en conséquence.

### 8.10 Conventions de style observées (à reproduire)

- **En-tête de fichier** en commentaire : chemin du fichier + version, une phrase d'objectif, et
  la liste des « briques » spec utilisées si pertinent (ex. `type date/bool`, `reference`,
  `content_template`). But : qu'un lecteur comprenne le fichier sans l'importer.
- **Sections en commentaire boîte** (`# ─── NOM : rôle ───`) pour séparer chaque `TypeDef` dans un
  fichier qui en contient plusieurs — surtout utile passé 3-4 types.
- **Types abstraits nommés `base_*`** (`base_statusable`, `base_editorial`) : un socle = un statut
  ou un cycle de vie commun factorisé, jamais de propriété métier spécifique dedans.
- **Slugs en `snake_case` anglais/neutre, labels en français** lisible pour l'utilisateur final
  (`slug: budget_jours`, `label: "Budget (jours)"`).
- **Un type « annuaire »** (`personne`, `contributeur`) sans `statut` ni cycle de vie, seulement
  pour servir de cible à des propriétés `reference` — pattern à reproduire plutôt que de pointer
  une `reference` vers un type qui a un pipeline de statut qui n'a pas de sens pour lui.
- **Chaque type possède son propre pipeline `statut`** (ses propres `allowed_values`). Ne
  jamais faire porter un pipeline de statut **cross-type** — un board filtré par statut n'a de
  sens que pour un seul type à la fois. Les règles de transition entre statuts (quel slug peut
  aller vers quel autre) ne sont **portées par aucun mécanisme docflow** — n'essaie pas de les
  encoder ici (c'est le rôle d'un futur module workflow, hors périmètre des templates).
- **Commentaire de fermeture** en bas de fichier si le template a un point de couplage volontaire
  avec un autre template (cf. le rappel en bas d'`agile-basic.yaml` sur le pont
  `produit_attendu → epic`) : documente l'intention sans la coder.

### 8.11 `toc.txt` et ajout d'un nouveau template

1. Crée `<slug>.yaml` à la racine de `Docflow/templates/`. Le champ interne `template:` **doit
   être identique** au nom de fichier (sans extension) — rien ne le vérifie automatiquement à
   l'écriture, mais la galerie identifie un template par ce champ, pas par le nom de fichier ;
   les faire diverger est une source de confusion pure.
2. Ajoute une ligne `<slug>` dans `toc.txt` (ordre libre, une ligne = un template).
3. `version: 1` pour un tout nouveau template. N'incrémente une version existante que pour un
   changement strictement additif au sens du tableau de diff ci-dessus.

### 8.12 Checklist avant de livrer un template docflow

- [ ] Chaque `slug` (template, type, propriété, allowed_value) respecte `^[a-z0-9][a-z0-9_-]*$`.
- [ ] Aucun UUID nulle part — tout est par slug, résolu à l'import.
- [ ] Aucun type `abstract: true` n'est utilisé comme `target_type` ou comme `parent`.
- [ ] Chaînes `inherit` acycliques ; overrides = remplacement complet assumé (pas de fusion).
- [ ] `pattern` uniquement sur des propriétés `type: text`.
- [ ] `default` d'une `restricted_list` correspond à un `slug` déclaré dans `allowed_values`.
- [ ] Pas de `type: url` / `type: float` (non supportés par l'import actuel).
- [ ] Chaque type à statut a **son propre** pipeline d'`allowed_values`, jamais partagé cross-type.
- [ ] `content_template` (si présent) suit le style `# {{title}}` / `> … {{date}}` / sections `##`.
- [ ] `template:` interne == nom du fichier == entrée ajoutée dans `toc.txt`.
- [ ] Si tu bumps une version existante : chaque changement est bien un **ajout** ou une
      **maj douce de label**, jamais une modification de `type`/`required`/`default`/contrainte/
      `parent`/position ou couleur d'`allowed_value` — sinon nouveau fichier, pas un bump.

---

## 9. Scripts d'hyperviseur (`hypervisors/`)

> Portée : le dossier **`hypervisors/`**. Ces artefacts sont consommés par le portail
> *workspace-portal*, mais **pas par un import de galerie** : ce sont des URLs de configuration,
> résolues au runtime. Le mécanisme diffère donc de §1–§7.

### 9.1 Ce que c'est et comment le portail s'en sert

Un artefact = une **action de provisioning** sur un hyperviseur (créer une VM, la détruire),
composée de deux fichiers de même nom :

```
hypervisors/
├── toc.txt                          # index humain de la galerie
├── proxmox-clone-vm-node.json       # descripteur : formulaire + commandes
├── proxmox-clone-vm-node.sh         # script exécuté sur le host de l'hyperviseur
├── proxmox-destroy-vm-node.json
├── proxmox-destroy-vm-node.sh
└── harden-networkd.sh               # compagnon, appelé par clone-vm-node.sh (A.10c)
```

Côté portail, un **type d'hyperviseur** porte deux champs d'URL —
`HypervisorType.add_script` et `HypervisorType.destroy_script` (`backend/src/portal/config/models.py`).
Ce sont des **URLs de configuration saisies à la main** (données `/data`), pas un import de
`toc.txt`. Le portail les fetch au runtime, avec la même garde anti-SSRF que les autres galeries :
**HTTPS**, hôte public, **pas de redirection**, UTF-8 sans BOM.

Conséquence pratique : **rien n'est importé automatiquement**. Ajouter un fichier ici ne le rend
pas visible dans le portail — il faut aussi coller son URL raw dans la config de l'hyperviseur.

### 9.2 `hypervisors/toc.txt`

**Pipe-délimité, 4 champs** : `descripteur.json | hyperviseur | action | description`.
Lignes `#…` ignorées. Il sert d'**inventaire** (et de base à un futur importeur) ; le portail ne
le lit pas aujourd'hui.

```
proxmox-clone-vm-node.json | proxmox | create_vm | Clone un template cloud-init et configure un nœud Docker
```

`action` reprend la valeur du champ `tags` du descripteur (`create_vm`, `destroy_vm`). Ne liste
que les **descripteurs** — pas les `.sh`, qui sont récupérés par le descripteur, ni les fichiers
compagnons, qui le sont par le script lui-même.

### 9.3 Le descripteur `.json`

Trois clés à la racine : `args`, `commands`, `tags`.

| Clé | Rôle |
|---|---|
| `args` | champs du formulaire affiché par le portail |
| `commands` | commandes shell exécutées **en séquence** sur le host de l'hyperviseur |
| `tags` | `["create_vm"]` ou `["destroy_vm"]` — nature de l'action |

Un `arg` : `arg` (nom du placeholder), `label_fr`/`label_en`, `description_fr`/`description_en`,
`type` (`string` \| `integer` \| `select` \| `sub`), `required`, `default`, et selon le cas :

- `pattern` — regex de validation côté portail (types texte) ;
- `options` — liste `{value, label}` pour un `select` ;
- `option_script` — shell exécuté **sur le host** pour peupler dynamiquement un `select`, une
  ligne par option au format `valeur|libellé` ;
- `test_script` — `{if, then, else}` : vérification live affichée sous le champ ;
- `type: "sub"` — **groupe repliable** (`label_fr`, `expanded`) contenant ses propres `args`.
  C'est là que vivent les paramètres avancés (groupe *Resources* : `MEMORY`, `CORES`,
  `DISK_EXTRA`, `SWAP_PERCENT`, `CPU_TYPE`).

Dans `commands`, chaque `{ARG}` est **substitué** par la valeur saisie. Le patron en place est
toujours le même — récupérer le script, le rendre exécutable, l'exécuter :

```json
"commands": [
  "curl -fsSL -o /tmp/mon-script.sh https://raw.githubusercontent.com/ag-flow/ressources/refs/heads/main/hypervisors/mon-script.sh",
  "chmod +x /tmp/mon-script.sh",
  "/tmp/mon-script.sh {VMID} --option '{VALEUR}'"
]
```

> **Préfère un `select` à un champ libre** dès que le jeu de valeurs est fermé. Une valeur
> invalide n'échoue pas à la saisie mais **au milieu du script**, laissant une VM à moitié
> configurée. C'est le choix fait pour `CPU_TYPE` (`x86-64-v3` par défaut, `host` pour la
> virtualisation imbriquée).

### 9.4 Le script `.sh`

Bash POSIX-ish, `set -euo pipefail`, **exécuté en root sur le host de l'hyperviseur** (pas dans
la VM) via `curl | bash` — donc :

- **idempotent** : un re-run ne doit pas casser une VM déjà provisionnée ;
- **stdin n'est pas un terminal** (le script arrive par le pipe) : tout `ssh` interne doit passer
  `-n`, sinon il consomme le script lui-même ;
- toute étape optionnelle qui fetch une ressource distante **dégrade proprement** (avertissement
  sur `stderr`, étape sautée) plutôt que d'interrompre le provisioning.

En-tête conseillé : nom du fichier, une phrase de rôle, `À exécuter en root sur le host PVE`,
puis un bloc `Usage :` avec des exemples réels. Les étapes sont numérotées en commentaires boîte
(`# ─── A.10c — Résilience réseau ───`) pour être citables dans un ticket.

### 9.5 URLs internes — le piège du dépôt et de la branche

Un script ou un descripteur qui référence un **autre fichier de cette galerie** doit pointer sur
**ce dépôt, branche `main`** :

```
https://raw.githubusercontent.com/ag-flow/ressources/refs/heads/main/hypervisors/<fichier>
```

Attention : les scripts venaient de `gaelgael5/devpod-ui`, livré depuis la branche **`dev`**.
Une URL oubliée continue de fonctionner tant que l'ancien dépôt existe, puis casse
silencieusement le jour où il est nettoyé. Après toute modification :

```sh
grep -rn "githubusercontent" hypervisors/     # doit ne montrer que ag-flow/ressources … /main
```

### 9.6 Séquence de bascule (à respecter, sinon création de VM cassée)

`add_script` est une **config runtime**, pas une valeur du dépôt. L'ordre sûr :

1. publier le fichier dans `ressources` (`main`) et vérifier qu'il répond **200 en direct** ;
2. basculer l'URL dans la config de l'hyperviseur côté portail ;
3. **vérifier une création de VM réelle** ;
4. seulement ensuite, retirer l'ancien fichier de son dépôt d'origine.

Inverser 1 et 4 provoque un fetch 404 et rend toute création impossible.

### 9.7 Checklist avant de livrer un script d'hyperviseur

- [ ] Descripteur `.json` **valide** (`python3 -m json.tool`) et script `.sh` sans erreur de
      syntaxe (`bash -n`).
- [ ] Chaque `{ARG}` de `commands` correspond à un `arg` déclaré (y compris dans les groupes `sub`).
- [ ] Les valeurs fermées sont des `select`, pas des champs libres.
- [ ] Aucune URL ne pointe encore sur `devpod-ui` / une branche `dev`.
- [ ] Tous les fichiers compagnons référencés au runtime sont présents dans le même commit.
- [ ] Script idempotent ; `ssh -n` partout où le script est piped ; étapes optionnelles qui
      dégradent proprement.
- [ ] Entrée ajoutée à `hypervisors/toc.txt` au bon format (descripteurs uniquement).
- [ ] UTF-8 **sans BOM**, `.sh` exécutable (`chmod +x`).
- [ ] Aucun secret en dur (jetons portail passés en paramètre, jamais écrits dans le dépôt).
