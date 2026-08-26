# ressources — galeries d'artefacts ag.flow

Ce dépôt est la **source de vérité externe** des galeries de deux portails. Rien n'y est
exécuté : les portails **importent** ces artefacts par des URLs `raw` HTTPS, et n'en stockent
aucune copie durable.

| Dossier | Portail | Contenu |
|---|---|---|
| `recipes/` | workspace-portal | recettes devcontainer et recettes de host |
| `profiles/` | workspace-portal | profils VS Code (extensions, settings, image de base) |
| `composes/` | workspace-portal | templates docker-compose déployables sur un nœud |
| `jinja/` | workspace-portal | templates de messages contextuels |
| `hypervisors/` | workspace-portal | scripts de provisioning de VM (Proxmox) |
| `Docflow/templates/` | docflow | templates de structure de workspace |

Chaque dossier porte un `toc.txt` qui l'indexe. Le format attendu de chaque artefact — au
caractère près, un artefact mal formé étant **silencieusement ignoré** à l'import — est décrit
dans [`CLAUDE.md`](CLAUDE.md).

## Licence

**FSL-1.1-ALv2** — Functional Source License v1.1, future licence Apache 2.0.
Texte intégral : [`LICENSE`](LICENSE). Mention centralisée : [`NOTICE`](NOTICE).

Licence *source-available* : le code est lisible, modifiable et utilisable librement, à une
exception près — le **Competing Use**.

| Usage | Autorisé sous FSL |
|---|---|
| Usage interne, en production incluse | ✅ |
| Intégration comme brique d'un produit maison, non commercialisé tel quel | ✅ |
| Prestation de services autour du logiciel pour un licencié | ✅ |
| Modification, création d'œuvres dérivées, redistribution | ✅ |
| Enseignement et recherche non commerciaux | ✅ |
| Proposer à des tiers un produit ou service commercial qui **s'y substitue** | ❌ licence commerciale requise |
| Proposer un produit ou service qui se substitue à une **offre d'ag.flow bâtie dessus** | ❌ licence commerciale requise |
| Proposer un produit ou service aux fonctionnalités **substantiellement similaires** | ❌ licence commerciale requise |

**Bascule automatique en Apache 2.0** deux ans après la publication de **chaque** version. La
fenêtre est glissante — elle court par version, il n'y a pas de date couperet unique. Toute
version publiée aujourd'hui sera donc pleinement libre dans deux ans, sans action de personne.

Questions fréquentes sur ce modèle de licence : <https://fsl.software>.

### Logiciels tiers

Ce dépôt ne redistribue aucun logiciel tiers. Ses artefacts en **installent** sur des machines
cibles — SDK Android, images Docker, paquets npm et système, extensions VS Code — qui restent
régis par leurs propres licences. Voir [`NOTICE`](NOTICE).

## Contribuer

Voir [`CONTRIBUTING.md`](CONTRIBUTING.md). La signature du CLA est un préalable à toute
fusion de contribution externe.
