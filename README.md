# Vocabulle

Trois découvertes lexicales par jour — matin, après-midi, soir — affichées sur
l'écran verrouillé de l'iPhone, avec une fiche complète à portée de toucher.

Application iOS en Swift et SwiftUI, sans compte, sans serveur, sans publicité,
sans analyse d'usage et sans connexion réseau. Le corpus est embarqué : elle
fonctionne dès le premier lancement, en mode avion.

---

## Ce que fait l'application

- **Trois créneaux quotidiens**, par défaut 08:00, 14:00 et 20:00, modifiables.
  Le mot du soir reste affiché après minuit, jusqu'au créneau du matin.
- **Un widget, cinq formats au choix** : en ligne, circulaire et rectangulaire
  sur l'écran verrouillé, petit et moyen sur l'écran d'accueil. Il affiche le
  terme et sa définition courte, et ouvre la fiche exacte qu'il montre — même si
  le créneau a changé entre l'affichage et le toucher. Le format moyen est celui
  qui laisse tenir une définition entière : le rectangulaire, le plus contraint,
  la tronque.
- **« Autre mot »** remplace la découverte sans la marquer comme sue.
  **« Déjà connu »** l'écarte des découvertes suivantes, jusqu'à ce qu'on la
  décoche.
- **Collection** : parcourir dans l'ordre alphabétique français — les accents
  sont rangés dans leur lettre, pas après le Z — avec une barre de lettres pour
  sauter directement à une initiale ; chercher sans accents (« ephemere » trouve
  « éphémère ») ; retrouver ses favoris et les termes marqués connus.
- **Un exemple d'emploi** sur 60 % des fiches, toujours attribué : à l'auteur
  quand la source le nomme, à la page du Wiktionnaire dont il est tiré sinon.
  Aucune attribution n'est inventée, et une fiche sans exemple n'en affiche pas.
- **Réglages** : heures, fuseau horaire, notifications facultatives (désactivées
  par défaut), état du corpus et du partage avec le widget.

## Ce que l'application ne fait pas

Aucun compte. Aucune publicité. Aucune analyse d'usage. Aucun serveur. Aucune
connexion requise, y compris au premier lancement. Pas de quiz, pas de séries,
pas de réseau social, pas de synchronisation iCloud, pas d'IA à l'exécution.

---

## Architecture

```
Vocabulle/
├── Core/          logique partagée, compilée dans l'application ET le widget
│   ├── Model/     fiche lexicale, sources, provenance
│   ├── Time/      créneaux, fuseaux, changements d'heure
│   ├── Selection/ moteur de sélection déterministe
│   ├── State/     état partagé, conteneur, écriture atomique
│   └── Corpus/    lecture SQLite, normalisation de recherche
├── Shared/        thème et constantes visuelles, compilés dans les deux aussi
├── App/           interface SwiftUI et environnement applicatif
├── Widget/        extension WidgetKit et App Intents
├── Resources/     corpus SQLite embarqué
├── Tests/Core/    tests SwiftPM (swift test)
├── Tests/iOS/     tests XCTest hébergés (xcodebuild test)
├── tools/         outils d'auteur, hors chaîne de compilation
│   ├── corpus/    chaîne de production du corpus (Python, accès réseau)
│   └── make_icon.py  dessin de l'icône (Pillow, jamais lancé par la CI)
└── scripts/       génération du projet, validation, empaquetage
```

**`Core/` et `Shared/` sont compilés dans les deux cibles.** C'est la garantie
structurelle que l'application et l'extension exécutent littéralement le même
moteur de sélection : elles ne peuvent pas diverger, parce qu'il n'existe qu'une
seule implémentation. `scripts/validate_project.py` échoue si l'un de leurs
fichiers n'est compilé que dans une cible.

Ce qui sépare les deux tient à UIKit. `Shared/` porte ce qui en dépend — le
thème, qui peint l'application comme l'écran verrouillé — tandis que `Core/`
reste du Foundation pur, compilable par `swift test` sur macOS, où UIKit
n'existe pas.

Le projet Xcode est **généré** par `scripts/generate_project.py`, en Python pur
et sans dépendance. Le fichier produit est versionné, et sa régénération est
déterministe : relancer le script ne produit aucune différence.

```bash
python3 scripts/generate_project.py     # régénère Vocabulle.xcodeproj
python3 scripts/validate_project.py     # contrôles structurels, sans Xcode
```

---

## Le corpus

**1 938 fiches vérifiées**, produites à partir du Wiktionnaire francophone.

| Catégorie | Fiches | Part | Quota par cycle de 20 créneaux | Cycles couverts |
| --- | --- | --- | --- | --- |
| Littéraire | 879 | 45,4 % | 8 | 109 |
| Expression | 357 | 18,4 % | 5 | 71 |
| Conversation | 506 | 26,1 % | 4 | 126 |
| Spécialisé | 196 | 10,1 % | 3 | 65 |

Taille de la base : **4,8 Mo**, très en deçà du plafond de 100 Mo. Elle est
copiée dans les deux bundles (application et extension), soit 9,6 Mo au total :
c'est le prix de l'indépendance du widget vis-à-vis d'un conteneur partagé qui
n'existe pas toujours.

La colonne « cycles couverts » indique combien de fois le corpus peut être
parcouru en entier avant épuisement d'une catégorie. Le facteur limitant est le
littéraire, avec 109 cycles de vingt créneaux — soit environ 727 jours à trois
découvertes par jour.

### Comment il est produit

Le corpus n'est **pas** un échantillon de dictionnaire prélevé au hasard. La
liste des candidats (`tools/corpus/candidates.json`) est une sélection
éditoriale versionnée : mots littéraires réutilisables, expressions dont
l'origine est documentée, vocabulaire nuancé utile à la conversation, termes
spécialisés accessibles.

La chaîne élargit ensuite cette liste en suivant **les liens que la source
affirme elle-même** — sections « apparentés », « dérivés », synonymes,
étymologies. Le dérivé d'un mot littéraire est traité comme littéraire, et le
rapport enregistre l'origine de chaque terme ajouté.

```bash
python3 -m tools.corpus.build          # reconstruit le corpus (accès réseau)
python3 scripts/validate_corpus.py     # vérifie le corpus livré
```

La reconstruction demande une trentaine de requêtes à l'API MediaWiki, à raison
d'une par seconde, avec un User-Agent identifiable. Elle est **hors ligne par
défaut** dès que le cache local est chaud. Le corpus produit est versionné :
la CI ne le reconstruit pas, elle valide celui qui est livré.

### Ce qui n'est jamais fait

- **Aucune histoire, étymologie, date ou source n'est inventée.** Le Wiktionnaire
  ne fournit pas de section « histoire » : les fiches n'en ont donc pas. Une
  section absente vaut mieux qu'une anecdote plausible.
- **Aucun exemple n'est attribué à un auteur de mémoire.** Un exemple sans
  provenance nommée n'est pas publié.
- **Aucun mot latin n'est présenté comme français.** Les liens d'étymologie sont
  filtrés sur la langue.
- **Aucun rapprochement n'est gratuit.** Chaque terme associé porte une phrase
  qui dit pourquoi, et un statut : *lien attesté par la source* ou
  *rapprochement éditorial assumé*.

Détail des sources, licences et obligations :
**[docs/SOURCES_ET_LICENCES.md](docs/SOURCES_ET_LICENCES.md)**.

---

## Construire et installer

### Par la CI (recommandé, aucun Mac requis)

Poussez le dépôt sur GitHub, puis lancez le workflow « Vocabulle — tests, IPA
non signée et validation » depuis l'onglet *Actions* (ou laissez-le partir sur
un push). Il :

1. imprime les versions de Xcode, du SDK et de Swift ;
2. exécute `swift test` — la logique pure, dont les créneaux et le passage de
   minuit ;
3. valide la structure du projet et le corpus ;
4. exécute les tests d'empaquetage ;
5. compile et teste sur simulateur iPhone ;
6. archive pour `generic/platform=iOS` en `Release`, **signature désactivée** ;
7. vérifie que l'extension widget et le corpus sont présents, et que les
   binaires sont bien `arm64` ;
8. produit `Vocabulle-unsigned.ipa` et le publie en artefact téléchargeable
   (14 jours).

Aucune clé Apple, aucun certificat et aucun identifiant d'équipe n'intervient.
Le workflow lit le dépôt (`contents: read`) ; seul le travail qui publie une
version, et lui seul, dispose de l'écriture — pour créer sa Release.

### Publier une version

```bash
git tag v1.0.0
git push origin v1.0.0
```

Le tag déclenche la même compilation, puis crée une **Release** publique portant
l'IPA et engendre la **source AltStore** qui la décrit. C'est ce qui permet
d'installer Vocabulle — et de le mettre à jour — depuis AltStore, sans
télécharger d'artefact à la main :

```
https://github.com/Nakirem/Vocabule/releases/latest/download/altstore.json
```

Un envoi sur `main` sans tag compile et teste, mais ne publie rien. Le détail du
mécanisme, ce qu'une source fait et ne fait pas, et **le point qui n'a pas pu
être vérifié** sont dans **[docs/SOURCE_ALTSTORE.md](docs/SOURCE_ALTSTORE.md)**.

### Installer sur l'iPhone avec AltStore Classic

1. Téléchargez l'artefact `Vocabulle-IPA-<numéro>` et extrayez le ZIP.
2. Ouvrez `Vocabulle-unsigned.ipa` dans **AltStore Classic** sur l'iPhone.
3. **Au moment de l'installation, si AltStore propose de retirer les
   extensions, choisissez « Keep App Extensions ».** Sans l'extension, il n'y a
   pas de widget, donc pas d'écran verrouillé — c'est-à-dire pas d'application.
4. Avec un compte Apple gratuit, la signature expire au bout de **7 jours**.
   AltStore doit rafraîchir l'application pour qu'elle continue de s'ouvrir.

> AltStore Classic, et non AltStore PAL. Aucun abonnement ni compte développeur
> payant n'est nécessaire.

### Ce qu'il faut vérifier vous-même

L'environnement de développement de ce dépôt **n'a ni Mac, ni Xcode, ni
simulateur, ni iPhone**. Tout ce qui a été compilé l'a été par la CI, jamais sur
un appareil réel : **rien n'a été ouvert sur un iPhone**, et l'écran verrouillé
n'a jamais été observé.

Ce que la CI vérifie — et elle est verte : les 113 tests SwiftPM, les 9 tests
XCTest sur simulateur, l'archivage `Release` pour `iphoneos/arm64`, la présence
de l'extension widget dans `Vocabulle.app/PlugIns/`, et la production d'une IPA
non signée. Ce qu'elle ne peut pas vérifier : l'écran verrouillé, Always-On, le
comportement après redémarrage, et la survie de l'App Group à la re-signature
AltStore. Le simulateur n'est pas un téléphone.

La liste de ce qui reste à valider sur un vrai téléphone — et notamment le
comportement de l'écran verrouillé, qui ne peut être vérifié nulle part
ailleurs — est dans **[docs/VALIDATION_MANUELLE.md](docs/VALIDATION_MANUELLE.md)**.

Les limites connues et les choix assumés sont dans
**[docs/LIMITES_CONNUES.md](docs/LIMITES_CONNUES.md)**.

---

## Tests

| Suite | Commande | Ce qu'elle couvre |
| --- | --- | --- |
| Logique partagée | `swift test` | Créneaux, changements d'heure, passage de minuit, tirage déterministe, actions périmées, écritures concurrentes, corpus réel |
| Structure | `python3 scripts/validate_project.py` | Graphe du projet Xcode, sources compilées par les bonnes cibles, extension présente, ressources dans les deux bundles |
| Corpus | `python3 scripts/validate_corpus.py` | Contrat de clés JSON avec Swift, liens valides, invariants éditoriaux, distribution |
| Empaquetage | `python3 -m unittest discover -s scripts/tests -t .` | Refus d'une IPA sans widget, mal formée, ou de simulateur |
| Application | `xcodebuild test` | Corpus embarqué, liens profonds, accord de deux sessions indépendantes |

---

## Licence

Le **code** de Vocabulle et les **contenus** qu'il embarque n'ont pas le même
régime. Les définitions et exemples sont repris du Wiktionnaire francophone sous
licence **CC BY-SA 4.0** et crédités sur chaque fiche. Les textes de rédaction
Vocabulle sont signalés comme tels.

Voir **[docs/SOURCES_ET_LICENCES.md](docs/SOURCES_ET_LICENCES.md)**.
