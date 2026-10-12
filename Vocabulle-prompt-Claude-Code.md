# Vocabulle — Prompt de développement pour Claude Code

Tu es un développeur iOS senior spécialisé en SwiftUI, WidgetKit, App Intents, stockage local et CI GitHub Actions. Construis une application fonctionnelle, maintenable et installable, pas seulement une maquette ou un plan.

## 1. Objectif et contexte

L'application s'appelle **Vocabulle**. Elle permet à un francophone d'enrichir sa culture linguistique avec **trois découvertes par jour : le matin, l'après-midi et le soir**. Un seul mot, terme ou expression est affiché à la fois sur l'écran verrouillé avec une définition courte. Un appui ouvre sa fiche détaillée dans l'application.

Appareil cible : iPhone 15 Pro Max, version déclarée par l'utilisateur : iOS 27. Développement avec Claude Code, compilation distante par GitHub Actions sur un runner macOS, récupération d'un IPA puis installation avec **AltStore Classic**, pas AltStore PAL. L'utilisateur a déjà utilisé ce circuit pour une application SwiftUI. Ne suppose pas l'accès à un Mac local ni à un abonnement Apple Developer payant.

Inspecte d'abord le dépôt et ses instructions. S'il contient déjà une configuration de compilation utilisable, conserve-la et adapte-la. Sinon, crée un projet autonome. Ne prétends pas avoir accès à un ancien projet qui n'est pas présent.

## 2. Décisions produit

- Interface et contenu intégralement en français.
- Trois créneaux par défaut : **08:00, 14:00, 20:00**, modifiables dans les réglages. Fuseau initial Europe/Paris ; réglage permettant de suivre le fuseau de l'appareil.
- Le mot du soir reste affiché jusqu'au créneau du matin suivant, y compris après minuit.
- Avant le tout premier créneau après installation, afficher immédiatement une découverte cohérente avec la période en cours.
- Un mot reste stable pendant son créneau, sauf remplacement explicite.
- Pas de compte, publicité, suivi analytique, serveur applicatif obligatoire, abonnement ou API payante.
- Fonctionnement principal hors ligne dès la première ouverture.
- Préférer une première version aboutie aux fonctionnalités accessoires.

Choix par défaut que tu peux implémenter sans me reposer la question : favoris, historique, recherche, remplacement illimité et mémorisation des mots déjà connus. Notifications facultatives désactivées au départ. Pas de quiz, de streaks, de réseau social, de synchronisation iCloud ni de moteur IA à l'exécution dans cette version.

## 3. Ligne éditoriale : des découvertes pertinentes

Je recherche un mélange de mots littéraires ou assez rares, de mots utiles pour enrichir les conversations, d'expressions avec leur origine et de termes spécialisés expliqués simplement. **« Monomaniaque »** est un exemple du niveau et de l'esprit recherchés : intéressant et réutilisable, sans devoir être extrêmement obscur.

Exemples de candidats à vérifier et documenter : monomaniaque, velléitaire, palimpseste, ataraxie, sérendipité, faire florès, une victoire à la Pyrrhus. Ce sont des candidats, pas des contenus validés à recopier sans vérification.

Répartition initiale indicative, ajustable sans multiplier les paramètres :
- 40 % de mots littéraires, soutenus ou rares mais réutilisables ;
- 25 % d'expressions et locutions ;
- 20 % de vocabulaire nuancé utile à la conversation ;
- 15 % de termes spécialisés accessibles : rhétorique, philosophie, arts, sciences, histoire, etc.

Éviter une sélection au hasard dans tout un dictionnaire : elle donnerait trop de flexions, de graphies alternatives, de mots banals, de noms propres et de termes hyperspécialisés. Sélectionner des lemmes français et des expressions pertinents. Diversifier registres, longueurs, domaines et difficultés. Signaler clairement les usages vieillis, péjoratifs ou techniques ; ne pas transformer un usage familier en diagnostic médical.

Le sélecteur utilise ces métadonnées et un historique, pas une API d'IA. Ne pas présenter trois variantes du même mot comme trois découvertes distinctes. Les catégories peuvent se chevaucher : définir une catégorie principale pour équilibrer la sélection.

## 4. Fiche d'un terme

Présenter, lorsque l'information est disponible :
1. Terme et type : mot, terme spécialisé, expression.
2. Nature grammaticale, genre éventuel et registre.
3. Définition courte pour le widget, rédigée spécifiquement pour être lisible en quelques lignes.
4. Définition détaillée en français clair, en distinguant les sens si nécessaire.
5. Un ou deux exemples naturels. Les exemples rédigés pour Vocabulle sont identifiés comme tels ; aucune fausse citation attribuée à un auteur.
6. « Quand l'utiliser ? » : nuance et contexte d'emploi.
7. Étymologie, puis contexte historique ou anecdote lorsque les sources le permettent.
8. Deux à quatre termes associés, cliquables, avec une phrase expliquant chaque rapprochement.
9. Sources consultables et crédits.

Les associations ne se limitent pas aux synonymes : nuance opposée, même origine, même courant intellectuel, même période d'usage attestée, contraste intéressant, même contexte culturel. **La raison du lien doit être explicite et défendable.** Ne pas déduire une époque d'usage d'une seule date de publication d'une citation. Distinguer un rapprochement éditorial d'un lien étymologique ou historique attesté.

Ne pas inventer d'histoire, d'étymologie, de date ou de source pour remplir un champ. Une section absente vaut mieux qu'une fausse anecdote. Une source manquante doit être signalée dans le pipeline de données, pas remplacée par une URL fictive. Les liens associés pointent vers des entrées existantes ; sinon offrir explicitement une consultation externe, jamais une fiche vide.

## 5. Sources et corpus léger

Architecture recommandée : **corpus local préparé et contrôlé + enrichissement en ligne facultatif**.

Source lexicale principale : **Wiktionnaire français**. Wikipédia sert uniquement à compléter des sujets historiques ou culturels pertinents. Ne pas dépendre d'une API Larousse gratuite supposée : aucune API officielle publique gratuite exploitable n'a été établie dans la recherche préalable. Pas de scraping non autorisé de dictionnaires propriétaires.

L'API MediaWiki donne accès aux pages, mais ne fournit pas nécessairement une fiche lexicale française structurée prête à l'emploi. Vérifier les endpoints et les formats réels avant de coder. Ne pas transposer à fr.wiktionary.org un endpoint de définitions uniquement documenté pour l'édition anglaise.

Construire un pipeline reproductible, par exemple en Python :
- liste éditoriale de candidats versionnée ;
- récupération via les APIs documentées, avec User-Agent identifiable, cache, limitation de débit, temporisation et gestion des erreurs/429 ;
- extraction exclusive des sections françaises pertinentes, sans confondre traductions, flexions et définitions ;
- conservation des sources, identifiants de révision disponibles, dates de récupération, licences et attributions ;
- transformation vers un schéma stable, puis fichier SQLite embarqué ou stockage équivalent justifié ;
- rapport de validation : doublons, données incomplètes, sources manquantes, liens cassés, longueur des définitions courtes, répartition des catégories et taille finale ;
- séparation des contenus importés, des adaptations éditoriales et des exemples originaux.

Éviter une extraction fragile reposant uniquement sur des expressions régulières. Tester les variantes de pages à partir de réponses de référence. Ne pas demander à l'iPhone de parser quotidiennement tout le Wiktionnaire. Vérifier les obligations des licences au niveau du contenu effectivement importé ; afficher l'attribution, les liens de licence et les modifications pertinentes. Garder la licence des données distincte de celle du code.

Livrer un **corpus initial réel et vérifié**, viser au moins 300 fiches pour la première version. C'est environ 100 jours à trois termes par jour, avant les remplacements, pas une année complète. Concevoir le pipeline pour atteindre ensuite 1 500 à 3 000 fiches. Si les accès aux sources limitent le corpus, livrer le maximum réellement vérifié et annoncer le nombre exact ; ne jamais remplir artificiellement pour atteindre un quota. Les fixtures de démonstration ne comptent pas comme fiches vérifiées.

Budget : viser moins de 100 Mo pour le corpus initial ; **plafond de 400 Mo pour corpus et cache de contenu cumulés**, avec objectif de rester sous 300 Mo en usage normal. Mesurer séparément IPA compressé, application installée et données. Le texte ne justifie pas d'embarquer des images ou des fichiers audio lourds. Cache réseau borné, purgeable, sans supprimer favoris et historique utilisateur. Ne pas recopier la base complète dans plusieurs targets sans mesurer le coût.

Le corpus embarqué suffit au fonctionnement de base. L'enrichissement en ligne ne bloque jamais l'affichage ; afficher une erreur discrète et garder le contenu local en cas de panne. Pas de promesse de disponibilité illimitée d'une API gratuite. La synthèse vocale native peut être ajoutée si simple, sans télécharger un corpus audio.

## 6. Écran verrouillé et widgets

Le widget verrouillé est la fonctionnalité centrale. Utiliser WidgetKit, en priorité `accessoryRectangular`, avec le terme et une définition courte lisible. Le widget respecte les dimensions et le rendu imposés par iOS : ne pas promettre une grande carte librement placée. Ajouter un widget d'écran d'accueil si cela réutilise simplement les mêmes composants et données.

- Toucher le contenu ouvre **exactement le terme affiché**, au moyen d'un deep link contenant son identifiant stable, même si un créneau a changé entre-temps.
- Prévoir une action « Autre mot » et, si la place le permet, « Déjà connu ».
- Vérifier dans la documentation Apple actuelle quelles interactions sont supportées pour la famille retenue et le système ciblé. Utiliser Button/AppIntent uniquement lorsque c'est supporté.
- Valider séparément : écran verrouillé visible avec téléphone authentifié, téléphone réellement verrouillé, Always-On et après redémarrage/premier déverrouillage.
- Ne pas promettre une action sans authentification avant test réel. Si l'action directe est indisponible, documenter le repli : ouverture de l'app sur une action rapide ; envisager un contrôle système compatible seulement s'il apporte une réelle solution.
- Un bouton spécifique ne doit pas ouvrir la fiche par erreur ; le tap principal ouvre la fiche.
- Garder des cibles tactiles utilisables. Si la place ne permet pas deux boutons, privilégier une seule action de remplacement dans le widget et les deux actions dans l'app.

Préparer une timeline de plusieurs jours avec des entrées aux trois horaires. Aucune boucle permanente, timer continu, tâche de fond exécutée à heure exacte ou Live Activity utilisée comme affichage permanent. iOS arbitre les rafraîchissements : ne pas garantir un changement à la seconde près. Prévoir le rechargement de la timeline aux modifications pertinentes sans rafraîchissements abusifs.

Le parcours d'accueil explique comment ajouter manuellement le widget à l'écran verrouillé : l'application ne peut pas l'installer silencieusement.

## 7. Planification et état partagé

Créer un moteur de sélection partagé par l'app et l'extension. Un même créneau doit produire le même terme partout et à chaque ouverture.

- Identité de créneau fondée sur la date locale pertinente, l'horaire et la politique de fuseau, avec gestion du soir traversant minuit.
- Éviter les doublons entre créneaux planifiés et termes déjà proposés ; réserver les termes futurs sans les marquer prématurément comme consultés.
- Distinguer « planifié », « proposé », « consulté », « déjà connu » et « favori ». Une timeline future générée ne prouve pas que le widget a été vu.
- « Autre mot » remplace le mot du créneau actuel sans le marquer connu et sans provoquer de répétition immédiate.
- « Déjà connu » marque le terme, le retire des futures découvertes tant que ce statut n'est pas annulé, et le remplace pour le créneau actuel.
- Remplacements illimités ; gérer proprement l'épuisement des termes éligibles, sans boucle ni réintroduction silencieuse des mots connus.
- Un remplacement ne bouleverse pas inutilement les autres créneaux. Réparer les réservations devenues invalides.
- En cas de corpus épuisé, proposer explicitement de revoir des mots ou d'élargir les filtres.
- Gérer changements d'heure été/hiver, fuseau, horloge, réglages des créneaux et reprise après plusieurs jours sans ouvrir l'app.

Partager les données via un App Group correctement configuré pour l'app et le widget. Vérifier sa compatibilité et sa conservation après resignature AltStore. Éviter de dépendre d'identifiants de Team codés en dur. Ne jamais masquer un App Group inaccessible par deux stockages privés divergents.

Prévoir des écritures atomiques ou transactionnelles interprocessus, des migrations et un traitement idempotent des actions répétées/obsolètes. Une action provenant d'un widget périmé ne doit pas remplacer par erreur un autre terme devenu actif. Expliquer les décisions de concurrence.

Ne pas charger le corpus complet en mémoire dans l'extension : snapshots légers et requêtes ciblées. Choisir une protection des fichiers compatible avec les besoins réels sur écran verrouillé, en séparant si utile les données lexicales publiques du profil utilisateur. Documenter les limites avant le premier déverrouillage après redémarrage.

## 8. Écrans et design

Créer une interface native soignée, sobre, chaleureuse et typographique, avec une identité légère autour de la bulle et du langage. Palette suggérée : fond crème, texte très sombre et accent violet doux ; mode sombre natif. Ce sont des choix par défaut, pas une raison de bloquer le développement.

Écrans :
- **Aujourd'hui** : terme actuel, indicateur matin/après-midi/soir, accès à la fiche et aux actions ; accès aux termes déjà proposés dans la journée. Ne pas révéler obligatoirement les prochains termes.
- **Fiche** : contenu hiérarchisé, explications, associations, sources, favoris et statut connu.
- **Collection** : historique et favoris, recherche tolérant accents et casse, filtres simples par catégorie/registre. Les termes connus restent consultables et leur statut peut être annulé.
- **Réglages** : trois horaires distincts, fuseau, préférences éditoriales simples, notifications facultatives, taille et purge du cache, sources/licences, export/import des données utilisateur.
- **Premier lancement** : présentation concise, choix éventuel des intérêts et guide d'ajout du widget. Rien de bloquant pour découvrir le premier mot.

Accessibilité : Dynamic Type, VoiceOver, contrastes, réduction des animations, textes longs et états vides. Pas de texte rendu comme une image. Pas de police externe lourde ni de dépendance UI superflue.

Les notifications sont une option de rappel, pas un remplacement du widget. Si implémentées, demander la permission au moment où l'utilisateur les active, planifier un horizon compatible avec les limites système et garder leur contenu cohérent lors des remplacements. Ne pas les présenter comme inamovibles sur l'écran verrouillé.

## 9. Architecture technique

Swift + SwiftUI + WidgetKit + App Intents lorsque compatible. Choisir un deployment target raisonnable supporté par le SDK réellement disponible ; être compatible avec l'iPhone cible sans inventer d'API iOS 27. Ne pas confondre version du système de l'iPhone et SDK indispensable pour compiler.

Séparer clairement UI, logique métier, sélection temporelle, dépôt lexical, données utilisateur, intégration widget et import de contenu. Préférer les frameworks natifs et une structure lisible à une architecture excessive. SQLite pour le corpus est un bon défaut ; justifier un autre choix. Le stockage utilisateur doit gérer correctement les accès de l'app et de l'extension.

Schéma minimal : identifiant stable, lemme, type, catégorie principale et tags, registre, difficulté éditoriale, nature grammaticale, définitions courte et longue, exemples avec provenance, notes d'usage, étymologie optionnelle, histoire optionnelle, relations typées avec justification, sources/licences/révisions, version du contenu. Modèle utilisateur séparé pour favoris, connus, historique et créneaux.

Injecter horloge, calendrier et source de hasard pour tester la sélection. Ne pas utiliser un hash instable entre processus comme graine persistante.

## 10. GitHub Actions → IPA → AltStore Classic

Livrer un projet reproductible depuis un clone propre, sans configuration manuelle obligatoire dans Xcode local.

1. Fournir le projet Xcode avec schémas partagés, ou une génération déterministe documentée avec outil versionné.
2. Créer un workflow GitHub Actions avec déclenchement manuel `workflow_dispatch` et validation adaptée aux modifications du code. Pas de compilation planifiée trois fois par jour : le téléphone gère les créneaux.
3. Utiliser un runner macOS et une version Xcode effectivement disponibles et compatibles. Vérifier la documentation GitHub au moment de l'implémentation ; rendre le choix explicite. Afficher versions Xcode et SDK dans les logs.
4. Construire en Release pour **iphoneos/arm64**, pas pour le simulateur, et inclure l'extension `.appex` dans `Vocabulle.app/PlugIns`.
5. Pour le circuit AltStore sans certificat de distribution, prévoir si approprié une compilation non signée et un paquet `Payload/Vocabulle.app` compressé en `Vocabulle.ipa`, destiné à la resignature par AltStore. Ne pas confondre un export App Store signé avec ce paquet.
6. Vérifier les entitlements, App Groups, bundle IDs app/extension et métadonnées nécessaires à la resignature. Ne pas supposer qu'un IPA compilé sans signature est déjà installable ou que les entitlements survivront automatiquement.
7. Ne jamais supprimer l'extension pour contourner un échec : le widget est central. Documenter « conserver les extensions » lors de l'installation si AltStore propose ce choix.
8. Publier l'IPA comme artifact téléchargeable du workflow avec logs utiles et rapport de tests. Configurer une rétention raisonnable, permissions minimales et aucune clé Apple dans le dépôt ou les logs.
9. Documenter le parcours complet : lancer Actions, télécharger/décompresser l'artifact, ouvrir l'IPA dans AltStore Classic, conserver l'extension, lancer l'app une première fois et ajouter le widget.
10. Expliquer les contraintes effectives du compte gratuit, des App IDs et du renouvellement AltStore, en les vérifiant dans les sources officielles. Ne pas assimiler limite d'applications et limite d'App IDs.

Ne pas imposer un abonnement Apple Developer payant ou un Mac local comme solution par défaut. Si un blocage réel exige un choix utilisateur, apporter le diagnostic concret, les tests effectués et les options, après avoir terminé tout ce qui peut fonctionner. Ne pas activer de service payant ni publier le dépôt publiquement sans autorisation.

## 11. Vérifications et critères d'acceptation

Tests automatisés ciblés sur les risques réels :
- choix stable d'un terme dans un créneau ;
- transitions 08:00/14:00/20:00 et persistance du soir après minuit ;
- changements d'heure, de fuseau et de réglages ;
- remplacement, termes connus, absence de doublons et épuisement du corpus ;
- cohérence app/widget, actions obsolètes, écritures concurrentes et migrations ;
- deep link vers le terme affiché plutôt que vers le terme actuel ;
- extraction de pages représentatives, données malformées, sources et relations ;
- panne réseau et fonctionnement entièrement hors ligne ;
- structure IPA, présence de l'extension, architectures et tailles.

Checklist manuelle sur iPhone réel : installation AltStore, état du widget après resignature, tap vers la bonne fiche, remplacement si supporté, verrouillage réel, Always-On, économie d'énergie, redémarrage, persistance des données après mise à jour/renouvellement et ouverture sans réseau. La compilation ou le simulateur ne remplacent pas cette validation.

L'app est livrable quand le parcours central fonctionne, que le corpus réellement livré est quantifié, que l'IPA est construit par la CI lorsque celle-ci est accessible, et que les validations impossibles à effectuer dans ton environnement sont clairement listées. Ne jamais annoncer « testé sur iPhone » sans l'avoir fait.

## 12. Livrables et méthode

Produire :
- sources complètes de l'app et du widget ;
- projet/build reproductible, workflow GitHub Actions et scripts IPA ;
- corpus initial vérifié, pipeline d'import et rapport de qualité/taille ;
- tests métier, tests de données et checklist de validation réelle ;
- README en français pour compiler, installer, utiliser et dépanner ;
- documentation des sources, licences, choix techniques et limites connues.

Commence par une courte inspection, puis un plan concret. **Implémente ensuite sans t'arrêter au plan.** Traite rapidement le risque principal : prototype minimal app + widget + App Group + construction IPA. Poursuis avec sélection, corpus, interface et vérifications. Ne bloque pas tout le projet si tu ne peux pas toi-même installer l'IPA sur mon téléphone.

Prends les décisions techniques courantes de manière autonome. Pose seulement les questions réellement bloquantes après recherche. Ne remplace pas le besoin principal par une application de fiches sans widget. Termine avec un bilan factuel : réalisé, nombre de fiches vérifiées, tests exécutés, limitations restantes, emplacement de l'IPA s'il existe et étapes exactes à effectuer de mon côté.

## Références de départ à vérifier lors du développement

- Widgets d'écran verrouillé : https://developer.apple.com/documentation/widgetkit/widgetfamily/accessoryrectangular
- Interactions : https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- Timelines et rafraîchissements : https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date
- API MediaWiki : https://www.mediawiki.org/wiki/API:Parsing_wikitext
- Wiktionnaire français : https://fr.wiktionary.org/
- Licence des contenus : https://fr.wiktionary.org/wiki/Wiktionnaire:Licence
- App IDs AltStore : https://faq.altstore.io/altstore-classic/app-ids
- Documentation développeurs AltStore : https://developer.altstore.io/
- Runners GitHub : https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- Artifacts GitHub : https://docs.github.com/en/actions/tutorials/store-and-share-data

Ces références sont des points de départ, pas une preuve que les interactions ou la resignature ont déjà été testées pour cette application.
