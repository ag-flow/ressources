# Contribuer

## CLA — préalable obligatoire

Toute contribution externe exige la **signature du CLA d'ag.flow avant fusion**. Aucune PR
externe n'est fusionnée sans elle, quelle qu'en soit la taille.

> ⚠️ **À compléter** : lien vers le CLA d'ag.flow et procédure de signature. Tant que cette
> ligne subsiste, aucune PR externe ne peut être fusionnée — c'est volontaire, pas un oubli
> bénin.

La raison est concrète : ce dépôt est distribué sous **FSL-1.1-ALv2**, une licence
*source-available* dont ag.flow doit pouvoir concéder des exceptions commerciales. Sans cession
de droits par le contributeur, une contribution fusionnée rendrait ce double licenciement
impossible — et le blocage serait définitif, chaque contributeur gardant un droit de veto de
fait sur toute relicence ultérieure.

## Nature des contributions

Ce dépôt ne contient pas d'application : ce sont des **artefacts déclaratifs** importés par des
portails. Un artefact mal formé n'échoue pas bruyamment, il est **silencieusement ignoré** —
ligne de `toc.txt` sautée, fetch en 404, validation refusée.

Avant toute proposition, lis [`CLAUDE.md`](CLAUDE.md) : il décrit le format exact de chaque type
d'artefact, les regex d'identifiants, les schémas `extra="forbid"` et les pièges d'import.

## Checklist avant proposition

- [ ] L'entrée est présente dans le `toc.txt` du bon dossier, **au bon format**.
- [ ] Tous les fichiers référencés existent dans le même commit, en **UTF-8 sans BOM**.
- [ ] YAML et JSON valides, **sans champ hors schéma**.
- [ ] Recettes : `version` **incrémentée** dans `recipe.meta.yaml`. À version constante, les
      machines déjà provisionnées ne recevront jamais le changement.
- [ ] Scripts de recette : syntaxe **POSIX** vérifiée (`dash -n`) — le portail exécute avec
      `sh`, pas `bash`.
- [ ] Aucun secret dans un artefact : seulement des *chemins* ou des *références* de secrets.

La checklist complète, par type d'artefact, est en §6 de [`CLAUDE.md`](CLAUDE.md).
