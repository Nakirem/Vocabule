"""Extraction d'une fiche depuis le wikitexte d'une page du Wiktionnaire.

# Ce que l'extraction doit distinguer

Le cahier des charges est précis : « extraction exclusive des sections françaises
pertinentes, sans confondre traductions, flexions et définitions ». C'est le
point où une chaîne de production naïve se trompe le plus souvent — elle récolte
les traductions comme si c'étaient des définitions, ou prend une ligne de flexion
pour un lemme.

Trois garde-fous :
- on ne lit que la section ``== {{langue|fr}} ==`` ;
- on ne lit que les sections de nature grammaticale connue (``{{S|nom|fr}}``,
  ``{{S|adjectif|fr}}``…) et on ignore explicitement traductions,
  prononciation, anagrammes, références, dérivés et apparentés ;
- les étiquettes en tête de définition sont isolées **avant** de lire le sens,
  parce que « {{lexique|logique|fr}} » n'est pas du texte de définition.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timezone

from . import normalize as norm
from .model import (
    PROVENANCE_EDITORIAL,
    PROVENANCE_WIKTIONARY,
    SHORT_DEFINITION_MAX_LENGTH,
    WIKTIONARY_LICENSE,
    Entry,
    Example,
    Source,
    TextField,
)
from .wikitext import (
    LANGUAGE_CODES,
    Section,
    heading_label,
    heading_template,
    iter_list_items,
    iter_templates,
    leading_templates,
    parse_sections,
    parse_template,
    to_plain_text,
)

#: Nature grammaticale, indexée par l'étiquette de section du Wiktionnaire.
#: Les valeurs sont celles de l'énumération Swift `PartOfSpeech`.
PART_OF_SPEECH: dict[str, str] = {
    "nom": "nomCommun",
    "nom propre": "nomPropre",
    "adjectif": "adjectif",
    "verbe": "verbe",
    "adverbe": "adverbe",
    "locution nominale": "locutionNominale",
    "locution verbale": "locutionVerbale",
    "locution adjectivale": "locutionAdjectivale",
    "locution adverbiale": "locutionAdverbiale",
    "locution interjective": "locutionInterjective",
    "interjection": "interjection",
    "préposition": "preposition",
    "conjonction": "conjonction",
    "pronom": "pronom",
    "déterminant": "determinant",
}

#: Registres, indexés par le modèle d'étiquette du Wiktionnaire.
#: Les valeurs sont celles de l'énumération Swift `Register`.
REGISTER_TEMPLATES: dict[str, str] = {
    "courant": "courant",
    "soutenu": "soutenu",
    "littéraire": "litteraire",
    "familier": "familier",
    "argot": "argotique",
    "argotique": "argotique",
    "populaire": "populaire",
    "vieilli": "vieilli",
    "vieillot": "vieilli",
    "désuet": "desuet",
    "désuète": "desuet",
    "rare": "rare",
    "technique": "technique",
    "péjoratif": "pejorative",
    "mélioratif": "meliorative",
    "humoristique": "humoristique",
    "ironique": "ironique",
    "figuré": "figure",
    "au sens figuré": "figure",
    "par extension": "parExtension",
    "par métonymie": "parExtension",
    "régionalisme": "regionalisme",
    "régional": "regionalisme",
}

#: Modèles d'étiquette qui désignent un **domaine**, pas un registre.
#:
#: La liste est explicite plutôt que devinée : classer tout modèle inconnu comme
#: domaine produirait des étiquettes fantaisistes — « réfnec », par exemple, se
#: retrouverait présenté comme un domaine de spécialité, et rien ne le
#: signalerait. Tout modèle absent de cette liste **et** absent des registres est
#: compté comme inconnu et publié dans le rapport, ce qui permet d'étendre la
#: liste à partir de cas réels plutôt que de suppositions.
DOMAIN_TEMPLATES = frozenset({
    "lexique", "info lex", "info-lex", "domaine",
    "anatomie", "anthropologie", "architecture", "archéologie", "art",
    "astronomie", "athlétisme", "audiovisuel", "automobile", "aéronautique",
    "bijouterie", "biologie", "botanique", "boucherie", "boxe", "brasserie",
    "bricolage", "chasse", "chemin de fer", "chimie", "cinéma", "coiffure",
    "commerce", "couture", "cuisine", "cyclisme", "danse", "droit", "escalade",
    "escrime", "ethnologie", "entomologie", "finance", "football", "félins",
    "gastronomie", "géographie", "géologie", "géométrie", "grammaire", "guerre",
    "génétique", "héraldique", "histoire", "ichtyologie", "imprimerie",
    "informatique", "jardinage", "jeux", "jeu de cartes", "joaillerie",
    "linguistique", "littérature", "marine", "mathématiques", "menuiserie",
    "militaire", "musique", "mycologie", "mécanique", "médecine",
    "médecine vétérinaire", "météorologie", "minéralogie", "natation",
    "navigation", "numismatique", "ornithologie", "paléontologie",
    "parfumerie", "pathologie", "peinture", "pharmacie", "philosophie",
    "photographie", "physique", "plomberie", "poissons", "politique",
    "presse", "psychanalyse", "psychiatrie", "psychologie", "pêche",
    "religion", "rhétorique", "rugby", "scolaire", "sculpture", "ski",
    "sociologie", "sport", "sylviculture", "tapisserie", "technique",
    "tennis", "textile", "théâtre", "typographie", "télécommunications",
    "urbanisme", "viticulture", "voile", "zoologie", "échecs", "économie",
    "électricité", "élevage", "équitation", "œnologie",
})

#: Sections de niveau 3 qui ne portent jamais de définition de lemme.
IGNORED_SECTIONS = frozenset({
    "traductions", "prononciation", "anagrammes", "références", "dérivés",
    "apparentés", "synonymes", "antonymes", "vocabulaire", "voir aussi",
    "homophones", "paronymes", "expressions", "composés", "formes de",
    "conjugaison", "dérivation", "locutions", "notes", "statistiques",
    "hyperonymes", "hyponymes", "méronymes", "holonymes", "quasi-synonymes",
    "proverbes", "citations", "wikisource", "voir", "dérivé",
})

#: Sous-sections d'où proviennent des termes associés.
#:
#: Ces sections sont écartées de la lecture des définitions — une liste de
#: dérivés n'est pas une définition — mais elles sont la source de liens la
#: mieux fondée qui existe : c'est le Wiktionnaire lui-même qui affirme que ces
#: termes sont apparentés. S'en priver obligerait à inventer des rapprochements.
RELATED_SECTIONS: dict[str, str] = {
    "apparentés": "apparentés",
    "apparenté": "apparentés",
    "dérivés": "dérivés",
    "dérivé": "dérivés",
    "synonymes": "synonymes",
    "quasi-synonymes": "synonymes",
    "antonymes": "antonymes",
}

#: Espaces de noms d'inclusion à ne jamais prendre pour un terme.
NON_TERM_NAMESPACES = ("fichier:", "image:", "file:", "catégorie:", "category:", "média:", "media:")

#: Verbes et noms qui ouvrent de nombreuses locutions. Sert uniquement de
#: dernier recours pour rattacher deux locutions construites pareil ; le
#: rapprochement est alors marqué comme éditorial, jamais comme attesté.
SHARED_HEAD_CANDIDATES = frozenset({
    "faire", "être", "avoir", "prendre", "mettre", "donner", "tenir", "aller",
    "jeter", "porter", "passer", "tirer", "rendre", "mener", "garder",
})

#: Genres, indexés par le modèle du Wiktionnaire.
GENDER_TEMPLATES: dict[str, str] = {
    "m": "masculin",
    "masculin": "masculin",
    "f": "feminin",
    "féminin": "feminin",
    "mf": "masculinOuFeminin",
    "m ou f": "masculinOuFeminin",
    "invariable": "invariable",
    "inv": "invariable",
    "invar": "invariable",
}

#: Bornes de longueur d'un exemple retenu.
MIN_EXAMPLE_LENGTH = 30
MAX_EXAMPLE_LENGTH = 400
MAX_EXAMPLES = 2
MAX_LONG_DEFINITION_PARTS = 3


@dataclass
class ExtractionStats:
    """Ce que l'extraction a vu, pour le rapport de validation."""

    unknown_label_templates: dict[str, int] = field(default_factory=dict)
    missing_french_section: int = 0
    missing_definitions: int = 0


# MARK: - Sections


def french_sections(sections: list[Section]) -> list[Section]:
    """Sections de la page appartenant à la langue française.

    Une page du Wiktionnaire peut décrire le même mot dans dix langues. Prendre
    la première section venue reviendrait à publier une définition islandaise
    sous une étiquette française.
    """
    start: int | None = None
    for index, section in enumerate(sections):
        if section.level != 2:
            continue
        template = heading_template(section.heading)
        is_french = (
            template is not None
            and template.name in ("langue", "lang")
            and template.positional
            and template.positional[0].strip().lower() == "fr"
        )
        if is_french and start is None:
            start = index
            continue
        if start is not None:
            return sections[start:index]
    return sections[start:] if start is not None else []


def choose_lemma_section(fr: list[Section]):
    """Section de nature grammaticale décrivant le lemme.

    Une page comme « chat » comporte ``{{S|nom|fr|num=1}}``,
    ``{{S|nom|fr|num=2}}`` et ``{{S|nom|fr|num=3}}`` : trois homonymes. On
    retient celle sans numéro si elle existe, sinon la première — et
    l'étymologie correspondante est choisie de la même façon, pour ne pas
    raconter l'histoire du « chat » d'informatique en décrivant l'animal.
    """
    ranked = []
    for index, section in enumerate(fr):
        if section.level != 3:
            continue
        label = heading_label(section.heading)
        if label not in PART_OF_SPEECH or label in IGNORED_SECTIONS:
            continue
        template = heading_template(section.heading)
        number = template.named.get("num") if template else None
        rank = 0 if number is None else (1 if number == "1" else 2)
        ranked.append((rank, index, section, label, number))
    if not ranked:
        return None
    ranked.sort(key=lambda item: item[0])
    return ranked[0]


def subsections_of(fr: list[Section], index: int) -> list[Section]:
    """Sections de niveau inférieur qui suivent celle-ci.

    # Le piège que cette fonction évite

    ``parse_sections`` aplatit tous les niveaux de titre en une seule liste.
    Le corps d'une section de niveau 3 s'arrête donc au titre de niveau 4
    suivant — les sous-sections ``==== {{S|dérivés}} ====`` ne sont pas
    *dedans*, elles sont **après**. Les chercher dans le corps de la section
    renvoie invariablement une liste vide, et toutes les sections de synonymes,
    d'antonymes, d'apparentés et de dérivés sont silencieusement perdues : ce
    sont pourtant les seuls endroits où le Wiktionnaire affirme lui-même qu'un
    terme en appelle un autre.
    """
    if index < 0 or index >= len(fr):
        return []
    parent_level = fr[index].level
    result: list[Section] = []
    for section in fr[index + 1:]:
        if section.level <= parent_level:
            break
        result.append(section)
    return result


def etymology_section(fr: list[Section]) -> Section | None:
    for section in fr:
        if section.level == 3 and heading_label(section.heading) in ("étymologie", "etymologie"):
            return section
    return None


# MARK: - Étiquettes


def classify_label(template) -> tuple[str, str]:
    """Nature d'une étiquette en tête de définition.

    Renvoie ``("register", valeur)``, ``("domain", valeur)`` ou
    ``("unknown", nom_du_modèle)``.
    """
    name = template.name.strip().lower()
    if name in REGISTER_TEMPLATES:
        return ("register", REGISTER_TEMPLATES[name])
    if name in ("lexique", "info lex", "info-lex", "domaine"):
        values = [value for value in template.positional if value not in ("fr",) and value]
        extra = template.argument("domaine", "spécialité", "thème")
        if extra:
            values.append(extra)
        return ("domain", ", ".join(values)) if values else ("unknown", name)
    if name in DOMAIN_TEMPLATES:
        return ("domain", name)
    return ("unknown", name)


# MARK: - Définitions


@dataclass
class Definition:
    """Une définition, ses étiquettes et ses exemples bruts."""

    text: str
    registers: list[str]
    domains: list[str]
    raw: str
    examples: list[str] = field(default_factory=list)


#: Longueur minimale d'une définition utilisable.
MIN_DEFINITION_LENGTH = 4

#: Formules qui renvoient à un autre terme au lieu de définir.
_RENVOI_RE = re.compile(
    r"^(Synonyme|Antonyme|Variante|Diminutif|Augmentatif|Abréviation|Sigle|"
    r"Orthographe|Forme|Pluriel|Féminin|Masculin)s?\s+(de|ancienne|rare)\b",
    re.IGNORECASE,
)


def is_usable_definition(text: str, term: str) -> bool:
    """La définition dit-elle quelque chose ?

    Trois rebuts fréquents, tous observés sur des pages réelles :

    - une définition réduite à un point, quand son contenu vivait dans un modèle
      que l'extraction ne rend pas ;
    - une « définition » qui n'est que le terme lui-même dans une autre
      orthographe — « Mutagénèse » pour « mutagénèse » n'apprend rien ;
    - un simple renvoi vers un autre mot, qui sert à construire un lien, pas à
      définir.
    """
    text = text.strip()
    if len(text) < MIN_DEFINITION_LENGTH:
        return False
    if not any(char.isalpha() for char in text):
        return False
    if _RENVOI_RE.match(text):
        return False
    return norm.normalize(text) != norm.normalize(term)


def parse_definitions(head: str, stats: ExtractionStats) -> list[Definition]:
    """Définitions de premier niveau et exemples qui les suivent."""
    definitions: list[Definition] = []
    for item in iter_list_items(head):
        if item.marker == "#" and item.depth == 1:
            templates, rest = leading_templates(item.content)
            registers: list[str] = []
            domains: list[str] = []
            for template in templates:
                kind, value = classify_label(template)
                if kind == "register":
                    registers.append(value)
                elif kind == "domain":
                    domains.append(value)
                else:
                    stats.unknown_label_templates[value] = (
                        stats.unknown_label_templates.get(value, 0) + 1
                    )
            definitions.append(
                Definition(
                    text=to_plain_text(rest),
                    registers=registers,
                    domains=domains,
                    raw=item.content,
                )
            )
        elif item.marker == "*" and item.depth == 2 and definitions:
            definitions[-1].examples.append(item.content)
    return definitions


# MARK: - Exemples


def split_source(raw_source: str) -> tuple[str | None, str | None]:
    """Auteur et titre d'ouvrage à partir du paramètre ``source``.

    On n'invente jamais un auteur : si la source ne le nomme pas, le champ reste
    vide et l'exemple est présenté comme venant du Wiktionnaire, page nommée.
    C'est la règle que le modèle Swift vérifie.
    """
    author: str | None = None
    title: str | None = None

    for _, _, body in iter_templates(raw_source):
        template = parse_template(body)
        if template.name in ("w", "ws", "wikisource", "wikipedia") and template.positional:
            if author is None:
                author = template.positional[0].strip()
        elif template.name in ("lien web", "ouvrage", "article", "chapitre"):
            if author is None:
                author = template.argument("auteur", "auteurs", "nom")
            if title is None:
                title = template.argument("titre", "ouvrage", "article")

    for match in re.finditer(r"''(.+?)''", raw_source):
        candidate = to_plain_text(match.group(1))
        if candidate and len(candidate) > 1:
            title = candidate
            break

    if title is None:
        cleaned = to_plain_text(raw_source)
        if cleaned:
            title = cleaned[:200]

    return (
        author.strip() if author else None,
        title.strip() if title else None,
    )


def parse_example(raw: str, page_title: str) -> Example | None:
    """Exemple retenu à partir d'une ligne ``#*``."""
    content = raw.strip()
    template = None
    for start, end, body in iter_templates(content):
        if start == 0 and end == len(content):
            template = parse_template(body)
        break

    author: str | None = None
    source_title: str | None = None
    if template is not None and template.name in ("exemple", "citation", "citation2"):
        text = to_plain_text(template.argument("1", "texte") or "")
        raw_source = template.argument("source", "auteur", "2", "3") or ""
        if raw_source:
            author, source_title = split_source(raw_source)
    else:
        text = to_plain_text(content)

    text = text.strip()
    if not MIN_EXAMPLE_LENGTH <= len(text) <= MAX_EXAMPLE_LENGTH:
        return None

    # La provenance est toujours nommée, et jamais inventée. Quand la ligne
    # nomme un auteur ou un ouvrage, c'est lui qui est crédité. Quand elle ne
    # nomme rien — le cas le plus fréquent — l'exemple est crédité à la page du
    # Wiktionnaire dont il est réellement tiré : c'est une provenance exacte, et
    # c'est exactement ce que `split_source` annonçait déjà deux fonctions plus
    # haut.
    #
    # La version précédente refusait ces exemples, faute de provenance nommée.
    # L'effet était l'inverse de celui recherché : deux fiches sur trois se
    # retrouvaient sans aucun exemple d'emploi alors que la source en publiait
    # un, et la fiche ne pouvait plus montrer que sa définition. Rien n'est
    # inventé ici — le texte vient de la page, et la page est nommée.
    return Example(
        text=text,
        origin="wiktionary",
        attributed_to=author,
        source_title=source_title or f"Wiktionnaire, page « {page_title} »",
    )


# MARK: - Étymologie


def parse_etymology(
    section: Section | None, number: str | None
) -> tuple[TextField | None, str | None, str | None]:
    """Étymologie, siècle d'attestation et etymon.

    Lorsque la page distingue plusieurs homonymes, l'étymologie est donnée ligne
    par ligne et numérotée par ``{{laé|fr|nom|1}}``. On ne retient que la ligne
    du numéro correspondant : mélanger les trois raconterait l'histoire de trois
    mots différents dans une seule fiche.
    """
    if section is None:
        return (None, None, None)

    lines = [item.content for item in iter_list_items(section.body) if item.marker == ":"]
    if not lines:
        return (None, None, None)

    chosen: list[str] = []
    for line in lines:
        numbers: list[str] = []
        for _, _, body in iter_templates(line):
            template = parse_template(body)
            if template.name in ("laé", "laé2", "laé-", "homonyme") and template.positional:
                numbers.append(template.positional[-1].strip())
        if numbers:
            if number is not None and number in numbers:
                chosen.append(line)
            # Ligne rattachée à un homonyme précis : elle ne décrit pas le lemme
            # qu'on est en train de lire, on la laisse de côté.
            continue
        chosen.append(line)

    if not chosen:
        return (None, None, None)

    value = " ".join(to_plain_text(line) for line in chosen).strip()
    if len(value) < 20:
        return (None, None, None)

    century: str | None = None
    etymon: str | None = None
    for line in chosen:
        for _, _, body in iter_templates(line):
            template = parse_template(body)
            if template.name in ("siècle", "siécle", "date"):
                century = century or template.argument("1", "2")
            elif template.name in ("étyl", "étymologie") and etymon is None:
                language = template.positional[0].strip() if template.positional else ""
                word = template.argument("mot", "3")
                if language and word:
                    etymon = f"{language}:{word.strip().lower()}"
        if century and etymon:
            break

    return (TextField(value=value, provenance=PROVENANCE_WIKTIONARY), century, etymon)


# MARK: - Notes d'emploi

#: Conseils d'emploi dérivés d'une étiquette **attestée**.
#:
#: Ce ne sont pas des inventions : chaque phrase ne fait que reformuler une
#: étiquette présente dans la source. Elles sont marquées comme rédaction
#: Vocabulle, précisément parce que la formulation est nôtre — présenter ce
#: texte comme venant du Wiktionnaire serait faux.
USAGE_NOTES: dict[str, str] = {
    "vieilli": "Terme vieilli : il se rencontre surtout dans des textes anciens ou chez des auteurs qui le cultivent. Dans un échange courant, il surprendra.",
    "desuet": "Terme désuet : il n'est plus employé, sauf pour évoquer une époque. À réserver aux citations et aux reconstitutions.",
    "rare": "Terme rare : peu de gens l'emploient, mais il est compris. Son usage passe pour une recherche, ce qui peut être un compliment comme un reproche.",
    "soutenu": "Registre soutenu : il convient à l'écrit soigné et à l'oral formel. Dans une conversation détendue, il sonnera apprêté.",
    "litteraire": "Registre littéraire : il appartient à l'écrit travaillé. À l'oral, il produit un effet de style qu'il vaut mieux assumer.",
    "familier": "Registre familier : parfait entre proches ou dans un message détendu, à éviter dans un écrit professionnel.",
    "argotique": "Registre argotique : il marque une appartenance et peut surprendre hors de son milieu d'origine.",
    "populaire": "Registre populaire : courant à l'oral, il détonne dans un texte formel.",
    "pejorative": "Terme péjoratif : il porte un jugement négatif sur ce qu'il désigne. À employer en connaissance de cause, jamais par inadvertance.",
    "meliorative": "Terme mélioratif : il porte un jugement positif et engage donc celui qui l'emploie.",
    "ironique": "Emploi ironique : le sens réel est l'inverse de ce qui est dit. À l'écrit, sans le ton, la phrase peut être mal comprise.",
    "humoristique": "Emploi humoristique : le décalage fait partie du sens. Employé sérieusement, il tombe à plat.",
    "figure": "Sens figuré : l'image est devenue l'usage principal, mais le sens propre reste présent à l'esprit.",
    "parExtension": "Sens obtenu par extension : le sens premier est plus étroit. Le contexte décide de celui qu'on entend.",
    "regionalisme": "Régionalisme : compris dans sa région, il peut dérouter ailleurs. À employer en sachant où l'on se trouve.",
    "technique": "Terme de spécialité : il suppose un contexte précis. Hors de ce contexte, il faudra l'expliquer.",
}


def build_usage_note(registers: list[str], domains: list[str]) -> TextField | None:
    """Conseil d'emploi, ou rien du tout.

    Une fiche sans registre remarquable ne reçoit **aucune** note : la section
    reste absente dans l'application. Une section absente vaut mieux qu'un
    conseil inventé.
    """
    sentences: list[str] = []
    for register in registers:
        note = USAGE_NOTES.get(register)
        if note and note not in sentences:
            sentences.append(note)
    if domains:
        domains_text = ", ".join(sorted(set(domains)))
        sentences.append(
            f"Terme de spécialité ({domains_text}) : il suppose un contexte précis "
            "pour être compris sans explication."
        )
    if not sentences:
        return None
    return TextField(value=" ".join(sentences[:2]), provenance=PROVENANCE_EDITORIAL)


# MARK: - Définition courte


def shorten(definition: str) -> str:
    """Définition courte, en une phrase complète.

    On coupe à une frontière de phrase ou de proposition avant la limite, jamais
    au milieu d'un mot. La troncature est signalée : elle est réelle, autant
    qu'elle se voie.
    """
    text = definition.strip()
    if len(text) <= SHORT_DEFINITION_MAX_LENGTH:
        return text

    budget = SHORT_DEFINITION_MAX_LENGTH - 1
    window = text[:budget]
    for boundary in (" ; ", " : ", ", ", ". "):
        position = window.rfind(boundary)
        if position >= 40:
            return window[:position].rstrip(" ,;:.") + "…"
    cut = window.rfind(" ")
    if cut < 20:
        cut = budget
    return window[:cut].rstrip(" ,;:.") + "…"


# MARK: - Extraction complète


def extract_entry(
    *,
    term: str,
    category: str,
    kind: str,
    wikitext: str,
    page_title: str,
    revision_id: int | None,
    fetched_at: str | None,
    source_url: str,
    stats: ExtractionStats,
) -> tuple[Entry | None, str | None]:
    """Construit une fiche. Renvoie ``(fiche, motif_de_rejet)``."""
    sections = parse_sections(wikitext)
    fr = french_sections(sections)
    if not fr:
        stats.missing_french_section += 1
        return (None, "aucune section française")

    chosen = choose_lemma_section(fr)
    if chosen is None:
        stats.missing_definitions += 1
        return (None, "aucune section de nature grammaticale reconnue")

    _, pos_index, pos_section, label, number = chosen
    head = pos_section.body
    subsections = subsections_of(fr, pos_index)
    definitions = parse_definitions(head, stats)
    if not definitions:
        stats.missing_definitions += 1
        return (None, "aucune définition")

    # Les définitions qui ne font que renvoyer à un synonyme ne sont pas des
    # définitions : elles servent à construire les liens, pas à remplir la fiche.
    substantive = [
        definition
        for definition in definitions
        if is_usable_definition(definition.text, term)
    ]
    if not substantive:
        return (None, "aucune définition exploitable")

    registers: list[str] = []
    domains: list[str] = []
    for definition in substantive:
        registers.extend(r for r in definition.registers if r not in registers)
        domains.extend(d for d in definition.domains if d not in domains)

    short_definition = shorten(substantive[0].text)
    if not short_definition:
        return (None, "définition courte vide")

    long_definition = "\n\n".join(
        definition.text for definition in substantive[:MAX_LONG_DEFINITION_PARTS]
    )

    examples: list[Example] = []
    for definition in substantive:
        for raw in definition.examples:
            example = parse_example(raw, page_title)
            if example is None or any(existing.text == example.text for existing in examples):
                continue
            examples.append(example)
            if len(examples) >= MAX_EXAMPLES:
                break
        if len(examples) >= MAX_EXAMPLES:
            break

    etymological = etymology_section(fr)
    etymology, century, etymon = parse_etymology(etymological, number)
    grammar = parse_grammar(head)

    # Les renvois lus dans les définitions et ceux lus dans les sous-sections
    # sont complémentaires : les premiers viennent du corps du texte, les
    # seconds d'une liste que la source présente comme telle.
    inline_synonyms, inline_antonyms = parse_renvois(definitions)
    section_synonyms, section_antonyms, related = parse_subsection_targets(subsections)
    synonyms = dedupe(inline_synonyms + section_synonyms)
    antonyms = dedupe(inline_antonyms + section_antonyms)

    source = Source(
        kind="wiktionary",
        title=f"Wiktionnaire, page « {page_title} »",
        url=source_url,
        revision_id=revision_id,
        fetched_at=fetched_at,
        license=WIKTIONARY_LICENSE,
    )

    return (
        Entry(
            id=norm.slug(term),
            term=term,
            kind=kind,
            category=category,
            difficulty=estimate_difficulty(kind, registers, label),
            part_of_speech=PART_OF_SPEECH.get(label),
            gender=grammar["gender"],
            grammar_note=None,
            ipa=grammar["ipa"],
            registers=tuple(registers),
            tags=tuple(sorted(set(domains))),
            short_definition=TextField(value=short_definition, provenance=PROVENANCE_WIKTIONARY),
            long_definition=TextField(value=long_definition, provenance=PROVENANCE_WIKTIONARY),
            usage_note=build_usage_note(registers, domains),
            etymology=etymology,
            # Aucune section « histoire » n'existe dans le Wiktionnaire. On la
            # laisse vide : inventer une anecdote pour remplir la section serait
            # exactement ce que le cahier des charges interdit.
            history=None,
            examples=tuple(examples),
            sources=(source,),
            etymon=etymon,
            century=century,
            domains=tuple(domains),
            synonym_targets=tuple(synonyms),
            antonym_targets=tuple(antonyms),
            related_targets=tuple(related),
            etymology_links=tuple(etymology_link_targets(etymological)),
            shared_head=shared_head_of(term),
        ),
        None,
    )


def parse_grammar(head: str) -> dict[str, str | None]:
    """Genre et prononciation, lus sur la ligne du terme.

    Cette ligne ressemble à ``'''chat''' {{pron|ʃa|ʃɑ|fr}} {{m}}``. On s'arrête
    à la première ligne de liste : au-delà commencent les définitions.
    """
    gender: str | None = None
    ipa: str | None = None

    for line in head.split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith(("#", "*", ";")):
            break
        if "'''" not in stripped:
            continue
        for _, _, body in iter_templates(stripped):
            template = parse_template(body)
            name = template.name.strip().lower()
            if name == "pron" and ipa is None:
                for value in template.positional:
                    if value not in ("fr",) and value.strip():
                        ipa = value.strip()
                        break
            elif name in GENDER_TEMPLATES and gender is None:
                gender = GENDER_TEMPLATES[name]
        break

    return {"gender": gender, "ipa": ipa}


def parse_renvois(definitions: list[Definition]) -> tuple[list[str], list[str]]:
    """Termes cités en synonyme ou en antonyme, avec leur cible de lien.

    On lit la **cible du lien**, pas son libellé : ``[[poisson-chat commun]]``
    désigne une page précise, et c'est cette page qu'il faut retrouver dans le
    corpus pour proposer un lien qui mène quelque part.
    """
    synonyms: list[str] = []
    antonyms: list[str] = []

    for definition in definitions:
        for keyword, bucket in (("Synonyme", synonyms), ("Antonyme", antonyms)):
            match = re.match(rf"^{keyword}s?\s+de\s+(.+)$", definition.text)
            if not match:
                continue
            links = list(re.finditer(r"\[\[([^\]|]+)(?:\|[^\]]*)?\]\]", definition.raw))
            if links:
                for link in links:
                    target = link.group(1).strip()
                    if target and not target.startswith(("Fichier:", "Image:", "Catégorie:")):
                        bucket.append(target)
            else:
                plain = match.group(1).strip().rstrip(".")
                if plain:
                    bucket.append(plain)

        for _, _, body in iter_templates(definition.raw):
            template = parse_template(body)
            if template.name in ("syn", "synonymes"):
                synonyms.extend(v for v in template.positional if v not in ("fr",))
            elif template.name in ("ant", "antonymes"):
                antonyms.extend(v for v in template.positional if v not in ("fr",))

    return (dedupe(synonyms), dedupe(antonyms))


def link_targets(body: str) -> list[str]:
    """Cibles de liens d'un fragment, sous leurs deux écritures.

    ``[[obsessionnellement]]`` et ``{{lien|obsessionalité|fr}}`` désignent tous
    deux une page précise. C'est la **cible** qu'on retient, jamais le libellé :
    un rapprochement qui pointerait vers un mot affiché mais inexistant comme
    page produirait un lien mort dans l'application.
    """
    targets: list[str] = []

    for match in re.finditer(r"\[\[([^\]|]+)(?:\|[^\]]*)?\]\]", body):
        target = match.group(1).strip()
        if target and not target.lower().startswith(NON_TERM_NAMESPACES):
            targets.append(target)

    for _, _, template_body in iter_templates(body):
        template = parse_template(template_body)
        if template.name in ("lien", "lien-"):
            value = french_link_target(template)
            if value:
                targets.append(value)

    return dedupe(targets)


def french_link_target(template) -> str | None:
    """Cible d'un modèle ``{{lien}}``, à condition qu'elle soit française.

    ``{{lien|austerus|la}}`` désigne un mot latin. Le publier comme entrée
    française serait une faute caractérisée : l'utilisateur verrait une fiche
    « austerus » présentée comme du vocabulaire français. Le modèle porte la
    langue, on la lit.
    """
    value = template.argument("mot", "1")
    if not value:
        return None
    languages = [part for part in template.positional if part in LANGUAGE_CODES]
    if languages and languages[-1] != "fr":
        return None
    return value.strip()


def parse_subsection_targets(
    subsections: list[Section],
) -> tuple[list[str], list[str], list[tuple[str, str]]]:
    """Synonymes, antonymes et termes apparentés, lus dans les sous-sections."""
    synonyms: list[str] = []
    antonyms: list[str] = []
    related: list[tuple[str, str]] = []

    for subsection in subsections:
        bucket = RELATED_SECTIONS.get(heading_label(subsection.heading))
        if bucket is None:
            continue
        targets = link_targets(subsection.body)
        if bucket == "synonymes":
            synonyms.extend(targets)
        elif bucket == "antonymes":
            antonyms.extend(targets)
        else:
            related.extend((target, bucket) for target in targets)

    return (dedupe(synonyms), dedupe(antonyms), related)


def etymology_link_targets(section: Section | None) -> list[str]:
    """Termes cités dans l'étymologie.

    « monomaniaque » est formé sur « monomanie » : quand les deux fiches sont au
    corpus, le rapprochement est documenté par la source et vaut mieux qu'une
    parenté de sens devinée.
    """
    if section is None:
        return []
    targets: list[str] = []
    for item in iter_list_items(section.body):
        if item.marker != ":":
            continue
        for _, _, template_body in iter_templates(item.content):
            template = parse_template(template_body)
            if template.name not in ("lien", "lien-"):
                continue
            value = french_link_target(template)
            if value:
                targets.append(value)
    # On ne retient **pas** les liens `[[...]]` nus de l'étymologie : ils
    # apparaissent dans la prose (« le vent du midi ») et désignent des mots
    # cités, pas des termes mis en relation. Le modèle `{{lien}}`, lui, est posé
    # délibérément par les rédacteurs du Wiktionnaire pour signaler un terme
    # digne d'être suivi.
    return dedupe(targets)


def shared_head_of(term: str) -> str | None:
    """Verbe ou nom commun à plusieurs locutions, s'il y en a un.

    Sert de dernier recours pour rattacher deux locutions qui se construisent
    pareil. Le rapprochement qui en découle est marqué **éditorial** : c'est un
    fait observable dans les deux termes, mais que la source n'énonce pas.
    """
    words = term.split()
    if len(words) < 2:
        return None
    head = words[0].lower()
    return head if head in SHARED_HEAD_CANDIDATES else None


def dedupe(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        cleaned = value.strip()
        if cleaned and cleaned not in seen:
            seen.add(cleaned)
            result.append(cleaned)
    return result


def estimate_difficulty(kind: str, registers: list[str], label: str) -> int:
    """Difficulté éditoriale de 1 (accessible) à 3 (exigeant).

    Calcul mécanique à partir d'étiquettes attestées, jamais d'une appréciation
    au cas par cas : deux exécutions de la chaîne doivent produire la même
    valeur.
    """
    demanding = {"litteraire", "rare", "desuet", "vieilli", "soutenu", "technique"}
    if demanding & set(registers):
        return 3
    if kind == "expression":
        return 2
    if set(registers) <= {"courant", "familier"} and label in ("nom", "verbe", "adjectif", "adverbe"):
        return 1
    return 2


def now_iso8601() -> str:
    """Horodatage de récupération, en UTC, au format attendu par Swift."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
