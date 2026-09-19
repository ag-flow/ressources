# templates/ — Instructions Claude Code

> Portée : **ce répertoire uniquement**. Objectif : faire de toi un expert de la rédaction de
> templates de type docflow, au point que ce répertoire puisse être **extrait tel quel dans un
> repo dédié** (galerie de templates) sans perdre le savoir nécessaire pour continuer à en écrire.
> Ce fichier doit donc rester **autoportant** — ne suppose pas l'accès à `specs/` ou au reste du
> code une fois extrait ; tout ce qui est indispensable est reproduit ici.

## Ce qu'est ce répertoire pour docflow

Un **template** = un fichier YAML versionné qui décrit une **structure** de workspace : des
`functional_type` (epic, feature, bug…), leurs `properties_defs` typées, leurs valeurs
autorisées, leur hiérarchie parent/enfant. Importer un template **clone la structure** dans un
workspace — jamais le contenu (aucun document, aucune valeur de propriété n'est créé).

**Mécanisme de galerie (déjà câblé côté docflow, vérifié dans le code) :**

- `toc.txt` à la racine : une ligne = un slug de template (pas d'extension). Lignes vides et
  lignes commençant par `#` ignorées.
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

## Format du fichier (schéma exact — vérifié dans `backend/src/docflow/templates/models.py`)

```
Template(version: int, template: str, label: str, functional_types: [TypeDef])

TypeDef(
  slug: str,                    # identité, IMMUABLE une fois publié — jamais d'UUID dans un template
  label: str | null,
  abstract: bool = false,       # true = socle réutilisable, jamais matérialisé en base
  inherit: str | null,          # slug d'un autre TypeDef du MÊME fichier
  parent: str | null,           # slug du type parent (hiérarchie documentaire), null = racine
  content_template: str | null, # squelette markdown — REPRIS par l'import (voir plus bas)
  properties: [PropDef] = []
)

PropDef(
  slug: str, label: str,        # `label` est REQUIS — une propriété sans label fait échouer le fichier
  type: "text" | "int" | "restricted_list" | "date" | "bool" | "url" | "float" | "reference",
  required: bool = false,
  default: str | null,
  behavior: "auto_now" | "auto_now_create" | null,
                                # RÉSERVÉ au type date : le serveur tient la valeur
                                # (auto_now = à chaque enregistrement, auto_now_create = à la
                                # création). Sur tout autre type, le modèle refuse le fichier.
  constraints: [{ kind: str, value: str, message: str? }] = [],
  allowed_values: [{ slug: str, label: str, position: int = 0, color: str? }] = [],
  target_type: str | null,      # slug de type cible, PROPRIÉTÉS reference uniquement —
                                # résolu FAIL-FAST à l'import (voir la section reference)
  max_occurrences: int | null   # multi-valeur — voir "Écarts connus" : INERTE à l'import
)
```

`extra="forbid"` sur **tous** ces modèles : un champ inconnu (faute de frappe, ancien nom) fait
**échouer le parsing entier** du fichier, pas juste ce champ. Vérifie l'orthographe exacte.

Les slugs de **type**, de **propriété** et d'**allowed_value** sont validés au parsing
(`validate_slug`) : `^[a-z0-9][a-z0-9_-]*`, longueur 1–100 — un slug accentué, capitalisé ou
commençant par un tiret fait échouer le fichier entier. Le slug du **template** lui-même
(`template:`) n'est, lui, **pas** validé : tiens la même forme à la main. Et « validé » ne veut
pas dire « correct » : la langue reste à ta charge — slugs en anglais, labels en français (voir
les conventions de style).

## Héritage — résolu UNE FOIS à l'import, jamais stocké tel quel

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
- **Ce que `parent` produit au runtime** (règle DOC-04, vérifiée dans `documents/service.py`) :
  à la **racine d'un bloc**, le type d'un document doit être **le type du bloc** ; **sous un
  parent**, il doit être un **fils direct** du type du parent. Un petit-fils n'est pas accepté
  à deux niveaux d'écart — la chaîne de types déclarée **est** la profondeur de l'arbre.
- **Un type ne peut pas être son propre parent.** C'est le réflexe naturel pour un arbre de
  profondeur libre, et il échoue en deux temps, sans rien signaler la première fois :
  l'import insère le type **avant** de connaître son propre identifiant, donc avec
  `parent = NULL` ; puis **chaque réimport** compare `NULL` au `parent` déclaré, y voit un
  `parent` modifié — un **conflit** — et **bloque le lot entier**, définitivement. Un arbre
  récursif n'est donc pas exprimable par un template de galerie : borne la profondeur par une
  chaîne de types, ou fais évoluer l'importeur côté docflow.
- **Changer le type d'un document purge** les valeurs des propriétés que le nouveau type ne
  porte pas (`_purge_orphan_property_values`). Un « déclassement » ou une promotion d'un type
  vers un autre ne conserve que les slugs communs : quand deux types sont destinés à ce genre
  de bascule, donne le même slug aux propriétés qui ont le même sens.
- La base ne connaît **que des types concrets à plat** : `inherit`/`abstract` n'existent pas en
  SQL, uniquement dans le YAML source.

## Types de propriété — forme stockée et contraintes valides

| `type` | forme stockée | contraintes valides (`kind`) | remarque |
|---|---|---|---|
| `text` | texte libre | `pattern` (regex), `min_length`, `max_length` | ces trois-là sont **réservés à `text`** |
| `int` | entier | `min`, `max` | |
| `float` | décimal | `min`, `max` | |
| `date` | ISO `YYYY-MM-DD` | `min`, `max` (bornes de date) | un timestamp ISO est accepté et **tronqué au jour** ; ni heure ni fuseau stockés |
| `url` | URL absolue | aucune | scheme `http`/`https` **et** hôte requis — une URL relative est refusée |
| `bool` | `"true"` / `"false"` littéral strict | aucune | `"1"`/`"oui"` sont **rejetés**, pas coercés |
| `restricted_list` | référence à une `allowed_values[].slug` | — | `default` doit être un `slug` déclaré dans `allowed_values` |
| `reference` | UUID d'un autre document | — | voir section dédiée ci-dessous |

Une contrainte posée sur un type qui ne l'accepte pas est **refusée en 422 à la déclaration**
(`pattern`/`min_length`/`max_length` hors `text`, `min`/`max` hors `int`/`float`/`date`), et un
opérande illisible l'est aussi (`max_length: "beaucoup"`, regex non compilable) : une borne qu'on
ne sait pas relire ne protège rien. Le `message` déclaré remplace le message par défaut au moment
où la valeur est refusée — écris-le du point de vue du rédacteur, pas du modèle.

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

## Propriété `reference` — relation typée vers un autre document

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
  n'est importable **qu'une fois l'autre template déjà en place dans le workspace** : l'import
  valide désormais **fail-fast** que chaque `target_type` résout vers un type du même fichier ou
  déjà présent côté workspace, et **refuse le lot entier** sinon. L'ordre d'import n'est donc plus
  un détail de confort : le template référencé passe en premier.

## Multi-valeur (`max_occurrences`)

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

## Modèle de contenu (`content_template`)

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

Le champ est bien **repris par l'import** : il est écrit à la création du type, et un `UPDATE`
en `COALESCE` le met à jour quand le template en fournit un — un template muet sur
`content_template` ne l'efface donc pas. Côté diff, un modèle de contenu modifié est une **maj
douce**, pas un conflit.
Style observé dans les templates existants : titre `# {{title}}`, une ligne de contexte en
citation (`> …`), sections `##` vides prêtes à remplir, listes à cocher `- [ ] …` pour les items
actionnables. Reste cohérent avec ce style pour les nouveaux templates.

## Discipline de versionnage — ce qui est additif vs ce qui casse

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
| `behavior` d'une propriété modifié | **conflit** | import bloqué en entier |
| `target_type` d'une propriété modifié | **conflit** | import bloqué en entier |
| `content_template` d'un type modifié | **maj douce** | appliqué (COALESCE : template muet = pas d'effacement) |
| élément retiré du template | **ignoré** | jamais de suppression automatique |

**Un seul conflit dans le lot bloque l'import entier** (rien n'est écrit, y compris les ajouts
valides du même diff). Donc : si un changement n'est **pas strictement additif** au sens de ce
tableau, ce n'est **pas une nouvelle version du même fichier** — c'est un **nouveau template**
(nouveau fichier, nouveau slug dans `toc.txt`). Ne bump jamais la version pour un changement qui
tomberait en conflit — ça casse l'import pour tout workspace qui a déjà cette version en place.

`max_occurrences` reste le seul champ **pas comparé par le diff** (voir écart connu ci-dessous) :
le faire évoluer sur une propriété déjà publiée ne sera ni appliqué ni détecté en conflit. Traite-le
comme les autres champs structurels par prudence : ne le change jamais sur un slug déjà publié,
publie un nouveau type si besoin.

## Écarts connus entre la spec et l'implémentation actuelle de l'import

Vérifiés dans le code de docflow (`backend/src/docflow/templates/`), à re-vérifier si tu
retravailles ce fichier après une évolution du backend — ce ne sont **pas** des choix de design à
respecter dans tes templates, ce sont des **limites actuelles à connaître** pour ne pas promettre
un comportement qui n'existe pas encore :

- **`max_occurrences` n'a aucune colonne ni effet runtime.** Le multi-valeur (`39_MMV`) n'est pas
  implémenté côté stockage — déclarer `max_occurrences > 1` est accepté par le parsing mais n'a
  aujourd'hui aucun effet observable après import, et le diff ne le compare pas.

Trois écarts listés ici auparavant sont **comblés** (vérifié le 2026-09-19 dans
`backend/src/docflow/templates/` : `models.py`, `importer.py`, `diff.py`) — ne réécris pas des
templates pour les contourner :

- `content_template` **est** repris par l'import (écrit à la création, `COALESCE` à la mise à jour) ;
- `target_type` **est** reporté en base (`target_functional_type_ref`) et validé fail-fast à
  l'import : une cible qui ne résout pas fait échouer le lot entier ;
- `type: url` et `type: float` **sont** acceptés par le modèle d'import, au même titre que le
  moteur de validation des valeurs.

Si l'un des écarts restants est comblé côté backend, mets à jour cette section en conséquence.

## Conventions de style observées (à reproduire)

- **En-tête de fichier** en commentaire : chemin du fichier + version, une phrase d'objectif, et
  la liste des « briques » spec utilisées si pertinent (ex. `type date/bool`, `reference`,
  `content_template`). But : qu'un lecteur comprenne le fichier sans l'importer.
- **Sections en commentaire boîte** (`# ─── NOM : rôle ───`) pour séparer chaque `TypeDef` dans un
  fichier qui en contient plusieurs — surtout utile passé 3-4 types.
- **Types abstraits nommés `base_*`** (`base_statusable`, `base_editorial`) : un socle = un statut
  ou un cycle de vie commun factorisé, jamais de propriété métier spécifique dedans.
- **Slugs TOUJOURS en anglais (`snake_case`), labels en français.** La règle porte sur les
  quatre niveaux de slug — template, type, propriété **et `allowed_values`** — et c'est ce
  dernier qu'on oublie : un pipeline `brouillon` / `actif` / `deprecie` viole la convention
  aussi sûrement qu'une propriété `variables_attendues`. Les `label`, eux, restent en français :
  ce sont eux que l'utilisateur lit (`slug: budget_days` + `label: "Budget (jours)"` ;
  `slug: draft` + `label: "Brouillon"`). Corriger après coup coûte cher : un slug renommé
  n'est **pas** un changement additif — le moteur de diff y voit un retrait (ignoré, jamais
  supprimé) doublé d'un ajout, donc tout workspace ayant importé l'ancienne version garde les
  deux propriétés **en doublon** jusqu'à un nettoyage manuel du type.
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

## `toc.txt` et ajout d'un nouveau template

1. Crée `<slug>.yaml` à la racine de ce répertoire. Le champ interne `template:` **doit être
   identique** au nom de fichier (sans extension) — rien ne le vérifie automatiquement à
   l'écriture, mais la galerie identifie un template par ce champ, pas par le nom de fichier ;
   les faire diverger est une source de confusion pure.
2. Ajoute une ligne `<slug>` dans `toc.txt` (ordre libre, une ligne = un template).
3. `version: 1` pour un tout nouveau template. N'incrémente une version existante que pour un
   changement strictement additif au sens du tableau de diff ci-dessus.

## Checklist avant de livrer un template

- [ ] Chaque `slug` (template, type, propriété, allowed_value) respecte `^[a-z0-9][a-z0-9_-]*$`.
- [ ] Chaque `slug` est en **anglais**, `allowed_values` comprises ; seuls les `label` sont
      en français.
- [ ] Aucun UUID nulle part — tout est par slug, résolu à l'import.
- [ ] Aucun type `abstract: true` n'est utilisé comme `target_type` ou comme `parent`.
- [ ] Chaînes `inherit` acycliques ; overrides = remplacement complet assumé (pas de fusion).
- [ ] `pattern` uniquement sur des propriétés `type: text`.
- [ ] `default` d'une `restricted_list` correspond à un `slug` déclaré dans `allowed_values`.
- [ ] `behavior` uniquement sur des propriétés `type: date` ; `pattern`/`min_length`/`max_length`
      uniquement sur `type: text` ; `min`/`max` uniquement sur `int`/`float`/`date`.
- [ ] Chaque type à statut a **son propre** pipeline d'`allowed_values`, jamais partagé cross-type.
- [ ] `content_template` (si présent) suit le style `# {{title}}` / `> … {{date}}` / sections `##`.
- [ ] `template:` interne == nom du fichier == entrée ajoutée dans `toc.txt`.
- [ ] Si tu bumps une version existante : chaque changement est bien un **ajout** ou une
      **maj douce de label**, jamais une modification de `type`/`required`/`default`/contrainte/
      `parent`/position ou couleur d'`allowed_value` — sinon nouveau fichier, pas un bump.
