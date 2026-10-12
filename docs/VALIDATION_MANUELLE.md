# Validation manuelle sur iPhone

> **Rien de ce qui suit n'a été exécuté.** L'environnement dans lequel ce projet
> a été écrit n'a ni Mac, ni Xcode, ni simulateur, ni iPhone : l'application n'a
> jamais été ouverte sur un appareil, et l'écran verrouillé n'a jamais été
> observé.
>
> La CI, elle, compile, archive et teste sur simulateur — le détail de ce qui est
> couvert et de ce qui ne l'est pas est dans `LIMITES_CONNUES.md`. Un simulateur
> ne dit rien de ce qui se passe sur un vrai téléphone, ce qui est précisément
> l'objet de cette liste.
>
> Annoncer « testé sur iPhone » sans l'avoir fait serait un mensonge.

---

## Avant de commencer

- [ ] L'IPA a été produite par le workflow et téléchargée depuis les artefacts.
- [ ] AltStore Classic est installé et fonctionnel sur l'iPhone.
- [ ] L'installation a été faite en choisissant **« Keep App Extensions »**.

Si l'application s'ouvre mais que le widget n'apparaît nulle part, la cause est
presque toujours là : l'extension a été retirée à l'installation. Réinstaller en
conservant les extensions.

---

## 1. Premier lancement

- [ ] L'application s'ouvre sans écran blanc ni plantage.
- [ ] L'écran de bienvenue s'affiche, en français, sans faute de mise en page.
- [ ] Aucune demande d'autorisation n'est faite (notifications, suivi, réseau).
- [ ] Après « Voir ma première découverte », un terme s'affiche avec sa
      définition courte.
- [ ] **En mode avion**, relancer l'application : tout doit continuer de
      fonctionner. C'est la vérification la plus importante du premier
      lancement — le corpus doit être embarqué, pas téléchargé.

## 2. Widget d'écran verrouillé

- [ ] Verrouiller l'iPhone. Le widget apparaît sur l'écran verrouillé.
      *(S'il n'est pas déjà configuré : appui long sur l'écran verrouillé →
      Personnaliser → ajouter le widget Vocabulle en format rectangulaire.)*
- [ ] Le terme et la définition courte sont lisibles, non tronqués au milieu
      d'un mot.
- [ ] **Le terme affiché par le widget est exactement celui de l'écran
      Aujourd'hui.** C'est la garantie centrale du projet ; si les deux
      diffèrent, quelque chose est cassé.
- [ ] Toucher le widget ouvre **le terme affiché**, pas un autre.
- [ ] Toucher le widget alors que le créneau vient de changer ouvre le terme
      qui était affiché au moment du toucher, pas celui du nouveau créneau.

### Écran toujours activé (Always-On)

Sur un iPhone 15 Pro ou 15 Pro Max :

- [ ] Écran toujours activé **activé** : le widget reste lisible et ne
      clignote pas.
- [ ] Écran toujours activé **désactivé** : le comportement reste correct.

### Après un redémarrage

- [ ] Redémarrer l'iPhone sans ouvrir l'application.
- [ ] Verrouiller l'écran. Le widget affiche-t-il encore un terme ?
      *(Après un redémarrage, iOS peut refuser de déchiffrer les données tant
      que l'appareil n'a pas été déverrouillé une fois. C'est une limite connue
      du système, documentée dans `LIMITES_CONNUES.md`.)*
- [ ] Déverrouiller, verrouiller de nouveau : le terme réapparaît.

## 3. Boutons du widget

Ces boutons ne peuvent exister que si l'application et l'extension partagent un
conteneur. Vérifier d'abord dans **Réglages → Partage avec le widget** si
l'état est « Partagé » ou « Isolé ».

- [ ] Si l'état est **« Partagé »** : les boutons sont visibles sur le widget.
  - [ ] « Autre mot » change le terme **sans** le marquer comme connu.
        Vérifier qu'il réapparaîtra plus tard dans la Collection.
  - [ ] « Déjà connu » change le terme **et** l'ajoute aux termes connus
        (Réglages → Votre usage).
- [ ] Si l'état est **« Isolé »** : les boutons sont **absents** du widget, et
      l'application l'explique. C'est le comportement attendu avec un compte
      Apple gratuit.
- [ ] Dans les deux cas : **activer le mode avion et rouvrir le widget.** Rien
      ne doit se figer ni afficher un écran vide.

## 4. Créneaux horaires

- [ ] Réglages → Heures des découvertes : régler le matin à une heure proche
      (par exemple deux minutes plus tard).
- [ ] Attendre l'heure. Le widget change de terme au bon moment.
- [ ] Régler le fuseau sur « Fuseau de l'appareil », puis changer le fuseau de
      l'iPhone. Vérifier que les heures de découverte suivent.
- [ ] Régler le soir à une heure proche, attendre, puis passer **minuit** :
      le mot du soir doit rester affiché jusqu'au créneau du matin.

## 5. Écran Fiche

- [ ] Ouvrir une fiche : nature grammaticale, registre, définition longue,
      exemples, étymologie, termes associés et sources s'affichent.
- [ ] Chaque section annonce sa provenance (« Wiktionnaire » ou « Rédaction
      Vocabulle »).
- [ ] Toucher un terme associé ouvre sa fiche ; la flèche de retour revient à
      la précédente.
- [ ] La source en bas de fiche est cliquable et mène à la bonne page du
      Wiktionnaire.
- [ ] Une fiche étiquetée « vieilli » ou « péjoratif » affiche bien un
      avertissement.
- [ ] Une fiche sans étymologie n'affiche **pas** de section étymologie vide.

## 6. Collection et recherche

- [ ] Parcourir les catégories, faire défiler : la liste se charge par pages
      sans doublon ni saut.
- [ ] Chercher `ephemere` (sans accent) : « éphémère » doit apparaître.
- [ ] Chercher `EPHEMERE` (en majuscules) : même résultat.
- [ ] Chercher `victoire pyrrhus` : la locution doit apparaître.
- [ ] Ajouter un favori, le retirer, vérifier qu'il apparaît puis disparaît de
      l'onglet Favoris.
- [ ] Marquer un terme « déjà connu », vérifier qu'il apparaît dans l'onglet
      correspondant, puis le décocher et vérifier qu'il redevient disponible
      pour les découvertes.

## 7. Accessibilité

- [ ] **Dynamic Type** : régler la taille du texte au maximum
      (Réglages → Accessibilité → Texte plus grand). Aucun texte ne doit être
      coupé ni se chevaucher.
- [ ] **VoiceOver** : activer, parcourir l'écran Aujourd'hui, la fiche, la
      Collection et les Réglages. Chaque élément doit être annoncé utilement,
      et le terme du widget doit être lisible avec sa définition.
- [ ] **Contraste augmenté** : les textes restent lisibles.
- [ ] **Réduire les animations** : aucun élément ne dépend d'une animation pour
      être compris.
- [ ] **Mode sombre** : activer, parcourir les quatre écrans. Fond sombre,
      texte clair, contraste correct.
- [ ] **Texte en gras** activé : la mise en page tient.

## 8. Notifications (facultatives)

- [ ] Réglages → Notifications : l'interrupteur est **désactivé** par défaut.
- [ ] L'activer : iOS demande l'autorisation **à ce moment-là**, pas avant.
- [ ] Refuser : l'interrupteur revient en position désactivée et le message
      explique où autoriser.
- [ ] Autoriser, puis régler un créneau dans deux minutes : le rappel arrive.
      Il annonce une découverte **sans révéler le mot**.

## 9. Mise à jour du corpus

- [ ] Reconstruire le corpus (`python3 -m tools.corpus.build`), regénérer le
      projet, relancer la CI, réinstaller par-dessus l'installation existante.
- [ ] Vérifier que **les favoris, les termes connus et l'historique sont
      conservés**. C'est l'exigence la plus facile à casser sans s'en rendre
      compte, parce qu'elle ne se voit qu'après une réinstallation.
- [ ] Vérifier qu'une fiche précédemment favorite, si elle a disparu du
      nouveau corpus, disparaît proprement de la Collection sans faire planter
      l'affichage.

## 10. Expiration de la signature

- [ ] Noter la date d'installation. Avec un compte Apple gratuit, la signature
      expire au bout de **7 jours**.
- [ ] Vérifier qu'AltStore rafraîchit bien l'application, et qu'après
      rafraîchissement **le widget fonctionne toujours** et que les données
      sont conservées.

---

## Ce qu'il faut noter si quelque chose échoue

Pour chaque point qui échoue, noter :

1. ce qui était attendu et ce qui s'est produit ;
2. l'écran concerné (application ou écran verrouillé) ;
3. si l'état du partage dans les Réglages était « Partagé » ou « Isolé » ;
4. la version d'iOS et le modèle d'iPhone.

Le point 3 est le plus souvent décisif : beaucoup de différences de
comportement entre deux installations viennent de là, et non du code.
