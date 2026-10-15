# Publier Vocabulle comme source AltStore

Une **source** AltStore est un fichier JSON public qu'AltStore lit pour
découvrir une application, l'installer et proposer ses mises à jour. Le lien du
dépôt ne suffit pas : c'est ce fichier qui décrit l'application et désigne
l'IPA à télécharger.

---

## L'adresse à ajouter

```
https://github.com/Nakirem/Vocabule/releases/latest/download/altstore.json
```

Dans AltStore Classic : onglet **Sources** → **+** → coller l'adresse.

**Attention au nom : le dépôt s'appelle `Vocabule` — un seul « l » — alors que
l'application s'appelle Vocabulle.** L'adresse est donc piégeuse à recopier, et
une seule lettre de trop suffit à obtenir un 404 que rien n'explique. Ce n'est
pas une note de prudence : c'est la panne qui a réellement eu lieu, et
`scripts/validate_project.py` refuse désormais toute URL de dépôt citée dans la
documentation qui ne désignerait pas le dépôt réel.

Elle ne changera jamais. `releases/latest/download/` est une adresse GitHub qui
sert toujours les fichiers de la **dernière** version publiée : le contenu
suivra les mises à jour sans que vous ayez à retoucher quoi que ce soit sur
l'iPhone.

## Ce qu'une source fait — et ce qu'elle ne fait pas

**Elle fait :** installer l'application, et proposer une mise à jour quand une
version plus récente est publiée. C'est tout.

**Elle ne fait pas :** rafraîchir la signature. Ce sont deux mécanismes
distincts. La signature d'une application installée avec un compte Apple gratuit
expire au bout de **sept jours**, et c'est **Remote AltServer** qui la
renouvelle — un réglage qui fonctionne aussi bien pour une application importée
à la main. Ajouter une source ne garantit donc pas, à elle seule, que
l'application continuera de s'ouvrir.

## Publier une version

```bash
git tag v1.0.0
git push origin v1.0.0
```

C'est tout. Le tag déclenche le workflow, qui :

1. compile, teste et archive comme sur un envoi ordinaire ;
2. **impose `MARKETING_VERSION` à la valeur du tag** — l'IPA portera donc
   exactement la version annoncée ;
3. lit dans l'IPA ses vraies version, numéro de construction, taille et
   identifiant de bundle ;
4. engendre `altstore.json` à partir de ces valeurs ;
5. crée la Release du tag et y joint l'IPA, la source et l'icône.

Un envoi sur `main` sans tag compile et teste, mais **ne publie rien** : c'est
le tag, et lui seul, qui décide qu'une version existe.

### Pourquoi le fichier est engendré et non écrit à la main

Trois champs du schéma doivent correspondre **exactement** à l'IPA :

| Champ | Doit correspondre à |
| --- | --- |
| `version` | `CFBundleShortVersionString` de l'application |
| `buildVersion` | `CFBundleVersion` de l'application |
| `size` | la taille du fichier en octets |

Or la CI compile avec `CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER"` : le numéro
de construction **change à chaque exécution**. Un fichier rédigé à la main
serait périmé dès le build suivant, et AltStore proposerait une mise à jour qui
n'existe pas. C'est la raison d'être de `scripts/make_altstore_source.py`, qui
lit ces valeurs dans l'archive plutôt que de les recevoir.

Le générateur refuse par ailleurs de produire une source dont la version
différerait du tag (`--check-tag`), et `scripts/validate_project.py` vérifie que
l'icône déclarée existe réellement.

### Pourquoi la Release et pas l'artefact

Les artefacts d'Actions ne sont téléchargeables que par une personne connectée à
GitHub. AltStore télécharge l'IPA sans aucune authentification : il lui faut une
**Release**, qui est publique. Les artefacts restent utiles pour le diagnostic,
mais ne peuvent pas servir de source.

---

## Le point qui n'a pas pu être vérifié

**AltStore contrôle que les entitlements déclarés dans la source correspondent à
ce que contient l'IPA**, et refuse l'installation en cas d'écart. Vocabulle
déclare `com.apple.security.application-groups` — c'est ce que porte
`App/Resources/Vocabulle.entitlements`, et la source le déclare donc fidèlement.

Mais la CI compile avec `CODE_SIGNING_ALLOWED=NO`, et **personne n'a vérifié sur
un iPhone** comment AltStore traite ce cas précis. Deux échecs sont documentés
dans l'écosystème AltStore :

- **Erreur 201** (`undeclaredPermissions`) : l'IPA porte un entitlement absent
  de la source. Ici le risque est inverse — la source en déclare un que l'IPA ne
  porte peut-être pas.
- **`AppleDeveloperError 3014`** (« The provided app group is invalid ») : un
  compte Apple gratuit ne peut pas provisionner de groupe d'applications. C'est
  un cas connu, et c'est précisément pourquoi Vocabulle fonctionne **sans** son
  groupe partagé (voir `LIMITES_CONNUES.md` §2 : les Réglages affichent alors
  « Isolé » et les boutons du widget disparaissent, mais l'application reste
  juste).

**Si l'installation est refusée à cause de l'entitlement**, la correction tient
en une ligne : retirer `com.apple.security.application-groups` de l'appel à
`scripts/make_altstore_source.py` dans le workflow, puis publier un nouveau tag.
L'application perd les boutons du widget — ce qu'elle perd déjà avec un compte
gratuit — mais s'installe.

---

## Rappel : « Keep App Extensions »

Au moment de l'installation, AltStore peut proposer de retirer les extensions de
l'application. **Refusez.** Vocabulle *est* son widget d'écran verrouillé :
sans l'extension, l'application s'installe et ne sert à rien.

Ce point n'est pas une précaution de principe — c'est la raison pour laquelle
la CI échoue bruyamment si `Vocabulle.app/PlugIns/VocabulleWidget.appex`
disparaît de l'archive.

## Ce qui reste à vérifier sur un vrai téléphone

Tout ce qui précède décrit un mécanisme, pas un résultat constaté :
**l'application n'a jamais été ouverte sur un iPhone**, et la source n'a jamais
été ajoutée à un AltStore réel. La liste complète est dans
`VALIDATION_MANUELLE.md`.
