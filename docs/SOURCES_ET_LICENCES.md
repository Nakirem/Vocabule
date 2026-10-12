# Sources, licences et attributions

## Le principe

Le **code** de Vocabulle et les **contenus** qu'il embarque n'ont pas le même
régime juridique, et l'application le dit à l'utilisateur plutôt que de le
noyer dans une page de mentions. Chaque bloc de texte d'une fiche porte sa
provenance, affichée sous le texte lui-même :

| Provenance affichée | Ce que cela veut dire |
| --- | --- |
| **Wiktionnaire** | Repris de fr.wiktionary.org, sous CC BY-SA 4.0, adapté et abrégé |
| **Wikipédia** | Repris d'un article de Wikipédia, sous CC BY-SA 4.0 |
| **Rédaction Vocabulle** | Écrit pour Vocabulle. Aucune source externe : ce texte est nôtre |

L'utilisateur voit donc, sur chaque fiche, ce qui vient d'où. Une fiche dont un
bloc prétendrait venir du Wiktionnaire sans citer de page du Wiktionnaire est
refusée par la chaîne de production **et** par l'application.

---

## Source lexicale

**Wiktionnaire francophone** — <https://fr.wiktionary.org/>

C'est la source lexicale principale, et la seule utilisée pour les définitions,
les étymologies, les registres et les exemples. Wikipédia n'intervient que pour
du contexte historique ou culturel ; en pratique, la chaîne actuelle ne
l'utilise pas du tout, car le Wiktionnaire fournit déjà les éléments
historiques dans ses sections d'étymologie.

### Accès technique

L'API MediaWiki est interrogée via l'endpoint générique :

```
action=query&prop=revisions&rvslots=main&rvprop=content|ids|timestamp
```

Ce choix est délibéré. Le cahier des charges interdit de transposer à
fr.wiktionary.org un endpoint d'extraction de définitions qui ne serait
documenté que pour l'édition anglaise : on récupère donc le **wikitexte brut**,
et on l'analyse nous-mêmes. Aucune API propriétaire n'est sollicitée, aucun
dictionnaire commercial n'est scrapé.

### Bonnes pratiques respectées

- **User-Agent identifiable**, avec un moyen de contact.
- **Une requête par seconde au maximum**, y compris entre deux lots.
- **Cache disque** borné à 200 Mo par défaut, purgeable.
- **Reprise sur erreur** : les réponses 429 et 5xx déclenchent une attente
  exponentielle qui respecte l'en-tête `Retry-After`.
- **Requêtes groupées** : 50 titres par appel. Le corpus complet tient en une
  trentaine de requêtes.

---

## Licence des contenus repris

Les contenus du Wiktionnaire sont publiés sous
**[Creative Commons Attribution – Partage dans les Mêmes Conditions 4.0](https://creativecommons.org/licenses/by-sa/4.0/deed.fr)**
(CC BY-SA 4.0).

### Ce que cette licence impose, et comment Vocabulle s'y conforme

| Obligation | Mise en œuvre |
| --- | --- |
| **Attribution** | Chaque fiche cite la page du Wiktionnaire dont elle provient, avec son identifiant de révision |
| **Lien vers la licence** | L'adresse de la licence est cliquable sur chaque fiche |
| **Mention des modifications** | « Contenu adapté et abrégé pour Vocabulle. » — les définitions sont systématiquement raccourcies et reformatées |
| **Partage dans les mêmes conditions** | Le corpus dérivé est distribué sous la même licence |
| **Pas de suggestion d'approbation** | Aucune mention ne suggère que Wikimédia approuve Vocabulle |

### Identifiants de révision

Chaque source enregistrée porte l'identifiant de révision MediaWiki de la page
au moment de l'extraction, ainsi que la date de consultation. Une citation reste
donc vérifiable même si la page a changé depuis.

### Ce que la chaîne ne fait jamais

- **Inventer une source.** Une section sans source est supprimée, jamais
  complétée par une référence plausible mais fictive.
- **Attribuer un exemple à un auteur que la source ne nomme pas.** Le champ
  auteur reste vide, et l'exemple est crédité du seul ouvrage que la source
  nomme — ou du Wiktionnaire seul si elle n'en nomme aucun.
- **Présenter un texte rédigé pour Vocabulle comme venant d'une source.**

---

## Textes de rédaction Vocabulle

Trois blocs sont rédigés par Vocabulle et marqués comme tels :

1. **« Quand l'utiliser ? »** — un conseil d'emploi dérivé d'une étiquette
   **attestée** de registre. Par exemple, une fiche étiquetée « vieilli » par le
   Wiktionnaire reçoit une phrase expliquant ce que cela implique à l'usage. La
   formulation est nôtre ; le fait est celui de la source.
2. **Les rapprochements éditoriaux** — des liens entre termes que la source
   n'énonce pas, rédigés à la main dans
   `tools/corpus/editorial_relations.json`, chacun avec sa justification. Ils
   sont affichés comme « Rapprochement éditorial », distincts des « Liens
   attestés ».
3. **L'interface** — tous les textes de l'application.

---

## Contenus tiers cités dans les exemples

Certains exemples du Wiktionnaire sont des citations d'œuvres, avec leur auteur
et leur source. Vocabulle les reprend **tels que le Wiktionnaire les publie**,
en conservant la mention d'auteur et de titre lorsqu'elle existe, et en limitant
chaque citation à 400 caractères.

Le crédit affiché sous l'exemple reprend ce que la source nomme, dans cet ordre :

- « Exemple issu du Wiktionnaire — Théophile Gautier » : la source nomme
  l'auteur, on le crédite.
- « Exemple issu du Wiktionnaire — Zeste de Savoir » : elle ne nomme personne
  mais cite un ouvrage, on crédite l'ouvrage. C'est le cas de 225 des 686
  exemples du corpus livré.
- « Exemple issu du Wiktionnaire » : elle ne nomme ni auteur ni ouvrage.
  Aucune fiche livrée n'est dans ce cas — et la règle de validation le refuse,
  parce qu'un exemple sans provenance est une citation invérifiable.

---

## Ce que Vocabulle n'utilise pas

- Aucune API Larousse ou Robert : aucune API officielle publique gratuite
  exploitable n'existe pour ces dictionnaires.
- Aucun scraping de dictionnaire propriétaire.
- Aucune image, aucun fichier audio : le texte ne le justifie pas, et le corpus
  doit rester léger.
- Aucun service payant.

---

## Signaler un problème

Si une fiche vous semble fausse, mal attribuée ou mal licenciée, le plus utile
est de regarder d'abord la page du Wiktionnaire citée en bas de la fiche : elle
est liée, avec l'identifiant de révision exact utilisé. Une erreur qui s'y
trouve déjà doit être corrigée là-bas ; une erreur introduite par la chaîne de
production de Vocabulle doit être corrigée ici.
