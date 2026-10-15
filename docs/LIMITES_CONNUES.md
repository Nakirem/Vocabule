# Limites connues et choix assumés

Ce document liste ce que Vocabulle **ne fait pas**, ce qu'il ne peut pas faire,
et les décisions qui ont un coût. Il est écrit pour être lu avant de signaler un
défaut : plusieurs des entrées ci-dessous sont des conséquences assumées, pas
des oublis.

---

## 1. Compilé et testé en CI, jamais ouvert sur un iPhone

L'environnement de développement de ce projet n'a **ni Mac, ni Xcode, ni
simulateur, ni iPhone**. Tout ce qui a été compilé l'a donc été par la CI, sur
un coureur macOS — et rien ne l'a été sur un appareil réel.

**Ce que la CI vérifie à chaque exécution** (dernier passage vert, Xcode 16.4
build 16F6, coureur `macos-15`) :

- Les **114 tests SwiftPM** passent : créneaux, changements d'heure, passage de
  minuit, tirage déterministe, actions périmées, écritures concurrentes, et le
  décodage des 1 938 fiches du corpus réel.
- Les **9 tests XCTest** passent sur un simulateur iPhone.
- L'archive `Release` pour `generic/platform=iOS` est produite, et l'extension
  widget est contrôlée présente dans `Vocabulle.app/PlugIns/`.
- L'IPA non signée est produite, vérifiée, puis publiée en artefact.

**Ce que la CI ne peut pas vérifier, et qui reste donc inconnu :**

- L'application n'a **jamais été ouverte sur un iPhone**. Le simulateur n'est pas
  un téléphone : il ne dit rien de l'écran verrouillé, d'Always-On, ni du
  comportement après redémarrage.
- Le comportement de l'écran verrouillé n'a **pas été observé**.
- L'installation par AltStore et la survie de l'App Group à la re-signature
  n'ont pas été éprouvées.
- Aucun test n'a tourné sur un appareil physique.

Un appareil de développement ne disposant d'aucun outil Swift, le seul
compilateur de ce projet est la CI. Une erreur de compilation ne se voit donc
qu'après un envoi — c'est arrivé trois fois de suite pendant la mise au point.

La liste de ce qui doit être vérifié est dans `VALIDATION_MANUELLE.md`.

## 2. Le partage avec le widget dépend du profil de signature

Vocabulle utilise un **App Group** pour que l'application et l'extension lisent
le même état. Or un profil de provisionnement délivré à un **compte Apple
gratuit** — le cas d'AltStore Classic — ne contient pas l'entitlement
`com.apple.security.application-groups`. Le système renvoie alors `nil`, sans
erreur.

**Conséquence :** dans ce cas, le widget ne peut pas enregistrer « Autre mot »
ni « Déjà connu ». Ces boutons ne sont donc **pas affichés**, et les Réglages
indiquent « Isolé » avec la liste des groupes essayés.

**C'est le cas constaté sur l'appareil cible.** Les Réglages y affichent
« Isolé », et la liste des groupes essayés ne contient que
`group.fr.vocabulle.app` — celui que l'application demande. Le système n'a donc
accordé **aucun** conteneur partagé : la demande a été refusée, ce n'est pas un
nom mal orthographié qu'il suffirait de corriger.

**Ce que cela implique pour « Autre mot » dans l'application.** Le bouton de la
fiche appelle bien `WidgetCenter.reloadAllTimelines()`, et cet appel part depuis
la première version. Mais recharger une chronologie ne transmet aucune donnée :
le widget se recalcule à partir de l'état partagé — qui n'existe pas ici — et
retombe sur le tirage nominal du créneau. Tant que le conteneur partagé est
refusé, **aucun** remplacement choisi dans l'application ne peut apparaître sur
l'écran verrouillé. Ce n'est pas un défaut de code, et il n'y a pas de correction
possible : iOS n'offre aucun moyen à une application d'écrire dans le conteneur
de son extension sans App Group.

**Ce qui est fait à la place :** le widget recalcule le **tirage nominal** du
créneau. Cette fonction ne dépend d'aucun état utilisateur, donc le widget
affiche exactement le terme que l'application afficherait si l'utilisateur
n'était pas intervenu. Le widget reste juste ; il est seulement en lecture
seule.

**Ce qui n'est pas fait :** on ne crée **jamais** deux magasins privés
divergents. L'écran verrouillé et l'application afficheraient alors deux termes
différents à la même heure, ce qui est pire que l'absence d'action.

**Un risque en découle, du côté de l'installation cette fois.** La source
AltStore déclare les entitlements de l'application pour qu'AltStore puisse les
comparer à ceux de l'IPA — c'est une exigence de son format, pas un choix. Or
cette déclaration inclut `com.apple.security.application-groups`, que le profil
gratuit ne fournit pas. Le détail, les deux signatures d'échec possibles et la
correction en une ligne sont dans
**[SOURCE_ALTSTORE.md](SOURCE_ALTSTORE.md)** §« Le point qui n'a pas pu être
vérifié ».

## 3. Après un redémarrage de l'iPhone

Les fichiers de l'application sont chiffrés tant que l'appareil n'a pas été
déverrouillé au moins une fois depuis le démarrage. Avant ce premier
déverrouillage, iOS peut refuser de lire le fichier d'état à l'extension.

**Conséquence :** le widget peut afficher un terme calculé (le tirage nominal)
plutôt que le terme réellement enregistré pour le créneau, jusqu'au premier
déverrouillage suivant le redémarrage.

C'est une limite du système, pas un défaut de Vocabulle. Elle est atténuée par
le fait que le tirage nominal donne le même terme dans le cas courant.

## 4. Le corpus est figé à la construction

Le corpus est un fichier SQLite embarqué dans le bundle. Il ne se met à jour
que par une nouvelle version de l'application.

**Conséquence :** le moteur applique la répartition 40/25/20/15 à chaque cycle
de vingt créneaux, soit 8 fiches littéraires par cycle. Le littéraire — 879
fiches sur 1 938 — est donc la catégorie qui s'épuise la première : au bout de
**109 cycles**, soit 2 180 créneaux, ou **environ 727 jours** à trois découvertes
par jour, pour un utilisateur qui ne remplace jamais un terme. C'est bien plus
que les « 100 jours » visés par le cahier des charges, mais l'épuisement finit
par arriver.

**Ce qui est fait :** l'épuisement est **explicite**. L'application affiche
« Vous avez parcouru les N termes du corpus », propose de recommencer un tour,
et les favoris comme les termes marqués connus sont conservés.

**Ce qui n'est pas fait :** aucun enrichissement en ligne. Le cahier des charges
mentionne la possibilité d'un enrichissement facultatif ; il n'est pas
implémenté, parce qu'un corpus local vérifié couvre le besoin et qu'une
dépendance réseau contredirait la promesse de fonctionnement hors ligne.

## 5. La section « Histoire » est toujours vide

Le Wiktionnaire ne comporte pas de section « histoire » distincte : le contexte
historique vit dans la section « étymologie ». Les fiches n'ont donc **pas** de
section histoire.

C'est délibéré. Remplir cette section aurait demandé d'inventer des anecdotes
plausibles, ce que le cahier des charges interdit explicitement — « une section
absente vaut mieux qu'une fausse anecdote ».

Pour les expressions, l'histoire est présente : elle se trouve dans
l'étymologie, qui raconte l'origine (par exemple l'allusion à Pyrrhus Ier pour
« victoire à la Pyrrhus »).

## 6. Le corpus suit le Wiktionnaire, avec ses défauts

Les définitions sont reprises du Wiktionnaire. Elles en héritent donc les
qualités et les défauts :

- Certaines définitions sont très courtes (« Mourir. », « Prière. ») : elles
  sont exactes mais peu explicatives.
- Les exemples sont ceux que la source publie : des phrases d'illustration, pas
  des citations littéraires. Certains sont courts et purement grammaticaux
  (« Intention actuelle s'oppose à intention virtuelle. ») — exacts, mais peu
  parlants.
- **1 163 fiches sur 1 938 (60 %) portent au moins un exemple**, contre 484
  (34 %) avant la version 1.2. Les autres n'en ont pas parce que la source n'en
  publie aucun dans sa section française.
- Les registres sont ceux du Wiktionnaire, qui peut les attribuer de façon
  inégale selon les pages.

**Aucune correction n'est apportée en silence.** Les textes affichés sont
marqués « Wiktionnaire » et « Contenu adapté et abrégé pour Vocabulle ».

## 7. Ce qui n'est pas implémenté

| Fonction | Statut | Pourquoi |
| --- | --- | --- |
| Export / import des données utilisateur | Absent | Mentionné comme souhaitable dans le cahier des charges. Non implémenté faute de temps, pas par choix. |
| Purge du cache depuis les Réglages | Absent | Le cache est un outil de développement (`tools/corpus/.cache`), il n'existe pas dans l'application. Aucun cache réseau n'est créé à l'exécution. |
| Préférences éditoriales (filtrer par catégorie ou par difficulté) | Absent | Mentionné comme possible. La sélection suit la répartition fixe 40/25/20/15. |
| Synthèse vocale | Absent | Mentionné comme facultatif. Non fait. |
| Enrichissement en ligne | Absent | Voir §4. |
| Synchronisation iCloud | Absent | Exclu par le cahier des charges. |

## 8. Choix techniques qui ont un coût

**Le corpus est dupliqué** dans le bundle de l'application et dans celui de
l'extension : 4,8 Mo × 2. L'alternative — un seul exemplaire dans le conteneur
partagé — ne fonctionne pas quand il n'y a pas de conteneur partagé (§2), et le
widget se retrouverait sans corpus. Le coût est mesuré et acceptable.

**Le projet Xcode est généré par un script Python** plutôt que par XcodeGen ou
Tuist. C'est une dépendance en moins et une régénération déterministe, mais le
script doit être maintenu à la main si la structure des cibles évolue.

**Le tirage utilise un hachage maison** (FNV-1a 64 + SplitMix64) plutôt que
`Hasher` de Swift. C'est délibéré : `hashValue` en Swift n'est **pas stable**
entre deux exécutions d'un même binaire, et encore moins entre deux versions du
compilateur. S'en servir comme graine aurait fait changer les découvertes à
chaque mise à jour.

**`drawSequence` n'entre pas dans la graine du tirage.** Le commentaire
d'origine du code l'affirmait ; c'était faux et il a été corrigé. La
reproductibilité d'une action rejouée vient de l'ordre stable des candidats et
de l'ensemble d'exclusions, pas de ce compteur.

## 9. Couverture du corpus

Le corpus a été élargi en suivant les liens que le Wiktionnaire affirme
lui-même, sur deux sauts depuis la liste éditoriale. Au-delà, la sélection
cesserait d'être éditoriale pour devenir un parcours automatique du
dictionnaire — ce que le cahier des charges interdit.

**Conséquence :** la répartition obtenue (45 % littéraire, 18 % expressions,
26 % conversation, 10 % spécialisé) s'écarte de la cible 40/25/20/15. Cela
n'affecte **pas** ce que voit l'utilisateur : le moteur de sélection applique la
répartition 40/25/20/15 à chaque cycle de vingt créneaux, quelle que soit la
composition du corpus. Ce qui compte est que chaque catégorie ait assez de
fiches pour alimenter ces cycles, et c'est le cas (65 à 126 cycles par
catégorie).

**Ce qui a changé en 1.2 :** la récolte a été élargie, et le corpus passe de
1 432 à 1 938 fiches. La commande exacte est celle-ci — elle n'était documentée
nulle part, ce qui rendait le corpus impossible à reproduire à l'identique :

```bash
python3 -m tools.corpus.build \
  --out Resources/vocabulle-corpus.sqlite \
  --report tools/corpus/report.json \
  --harvest-max 2600 --harvest-per-category 800
```

Le principal motif de rejet reste le même — « nombre de termes associés hors
plage », 865 candidats sur 1 129 — et il n'est **pas** contournable : le cahier
des charges exige deux à quatre termes associés, donc une fiche que la source
n'entoure que d'un seul lien attesté est écartée, aussi bonne soit-elle. C'est ce
plancher, et non le nombre de candidats, qui fixe la taille du corpus.

## 10. Le format de l'état utilisateur

L'état est un fichier JSON dans le conteneur. Un fichier illisible est **mis de
côté** (`state.json.corrompu-<horodatage>`) plutôt que supprimé : l'utilisateur
perd sa progression, mais rien n'est détruit et l'incident reste diagnosticable.

Un état écrit par une version **plus récente** de l'application est **refusé**
et **conservé** : le détruire effacerait des données qu'une version à jour
saurait encore lire.
