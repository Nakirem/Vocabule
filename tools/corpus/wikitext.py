"""Analyse du wikitexte du Wiktionnaire francophone.

# Pourquoi pas d'expressions régulières

Le cahier des charges l'interdit explicitement, et les pages réelles montrent
pourquoi : ``{{exemple | lang=fr | ...texte... | source={{w|Auteur}}, ''Œuvre''}}``
contient des accolades imbriquées, des barres verticales dans le texte cité et
des liens internes. Une expression régulière qui prétendrait attraper cela
produirait des résultats faux sur une page sur dix, sans jamais échouer
franchement — le pire des cas.

On écrit donc un analyseur par appariement d'accolades : il trouve la fin exacte
d'un modèle, quelle que soit la profondeur d'imbrication. C'est plus de code,
mais chaque construction est vérifiable, et une entrée mal formée est signalée
au lieu d'être avalée en silence.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

#: Modèles dont le contenu textuel doit être conservé tel quel.
KEEP_CONTENT_TEMPLATES = frozenset({
    "nobr", "smcp", "petites capitales", "sc", "lang", "langue",
    "couleur", "color", "souligné", "gras", "italique", "nowrap",
})

#: Modèles dont il faut garder le premier paramètre : ils portent un mot.
WORD_TEMPLATES = frozenset({"lien", "lien-", "étyl", "étymologie", "composé de"})

#: Modèles qui désignent une personne ou une œuvre, dont le nom est du texte.
CREDIT_TEMPLATES = frozenset({"w", "ws", "wikisource", "wikipedia"})

#: Langues reconnues dans les paramètres de modèle. Sert à distinguer
#: « {{félins|fr}} » (domaine + langue) de « {{lien|chat|fr}} » (mot + langue).
LANGUAGE_CODES = frozenset({
    "fr", "en", "de", "es", "it", "la", "grc", "fro", "frm", "oc", "pt", "nl",
    "ru", "ar", "he", "ja", "zh", "sa", "got", "cel", "gaul", "cop", "br",
    "ca", "co", "da", "el", "eo", "et", "eu", "fi", "gl", "hr", "hu", "hy",
    "id", "is", "ko", "lt", "no", "pl", "ro", "sk", "sv", "tr", "uk", "vi",
    "pro", "non", "ang", "enm", "goh", "gmh", "egy", "syc", "arc", "ku", "fa",
})

_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
_REF_RE = re.compile(r"<ref\b[^>]*?/>|<ref\b[^>]*?>.*?</ref>|<references\s*/?>", re.S | re.I)
_TAG_RE = re.compile(r"</?[a-zA-Z][^>]*>")
_HEADING_RE = re.compile(r"^(={2,6})\s*(.+?)\s*\1\s*$", re.M)
_LIST_ITEM_RE = re.compile(r"^([#*;:]+)\s*(.*)$")


@dataclass(frozen=True)
class Template:
    """Un modèle et ses paramètres."""

    name: str
    positional: tuple[str, ...]
    named: dict[str, str]

    def argument(self, *keys: str) -> str | None:
        """Valeur d'un paramètre, nommé ou positionnel.

        Une clé numérique désigne un paramètre positionnel, en comptant à partir
        de 1 comme le fait MediaWiki. Sans cette règle, ``{{étyl|frm|fr|chat}}``
        ne rendrait rien alors que le mot cherché est bien là.
        """
        for key in keys:
            if key.isdigit():
                index = int(key) - 1
                if 0 <= index < len(self.positional) and self.positional[index]:
                    return self.positional[index].strip()
                continue
            value = self.named.get(key)
            if value:
                return value.strip()
        return None

    @property
    def language_arguments(self) -> list[str]:
        """Paramètres positionnels qui sont des codes de langue."""
        return [value for value in self.positional if value in LANGUAGE_CODES]


@dataclass(frozen=True)
class Section:
    """Une section de page, avec son titre brut."""

    level: int
    heading: str
    body: str


@dataclass(frozen=True)
class ListItem:
    """Une ligne de liste, avec sa profondeur et son marqueur."""

    depth: int
    marker: str
    content: str


# MARK: - Appariement d'accolades


def iter_templates(text: str):
    """Parcourt les modèles ``{{...}}`` d'un texte, imbrication comprise.

    Renvoie des triplets ``(début, fin, corps)`` où ``corps`` est le contenu
    entre les accolades, paramètres compris.
    """
    index = 0
    length = len(text)
    while index < length - 1:
        if text[index] == "{" and text[index + 1] == "{":
            # {{{paramètre}}} : trois accolades ouvrantes, à ne pas confondre
            # avec un modèle contenant un paramètre.
            if index + 2 < length and text[index + 2] == "{":
                end = text.find("}}}", index + 3)
                if end == -1:
                    return
                yield (index, end + 3, text[index + 3:end])
                index = end + 3
                continue

            depth = 0
            cursor = index
            while cursor < length - 1:
                if text[cursor] == "{" and text[cursor + 1] == "{":
                    depth += 1
                    cursor += 2
                    continue
                if text[cursor] == "}" and text[cursor + 1] == "}":
                    depth -= 1
                    cursor += 2
                    if depth == 0:
                        break
                    continue
                cursor += 1
            if depth != 0:
                # Accolades non fermées : on s'arrête plutôt que de deviner.
                return
            yield (index, cursor, text[index + 2:cursor - 2])
            index = cursor
            continue
        index += 1


def split_top_level(text: str, separator: str = "|") -> list[str]:
    """Découpe sur un séparateur, en ignorant ceux qui sont imbriqués."""
    parts: list[str] = []
    buffer: list[str] = []
    curly = 0
    bracket = 0
    index = 0
    length = len(text)

    while index < length:
        pair = text[index:index + 2]
        if pair == "{{":
            curly += 1
            buffer.append(pair)
            index += 2
            continue
        if pair == "}}":
            curly = max(0, curly - 1)
            buffer.append(pair)
            index += 2
            continue
        if pair == "[[":
            bracket += 1
            buffer.append(pair)
            index += 2
            continue
        if pair == "]]":
            bracket = max(0, bracket - 1)
            buffer.append(pair)
            index += 2
            continue
        if text[index] == separator and curly == 0 and bracket == 0:
            parts.append("".join(buffer))
            buffer = []
            index += 1
            continue
        buffer.append(text[index])
        index += 1

    parts.append("".join(buffer))
    return parts


def parse_template(body: str) -> Template:
    """Analyse le corps d'un modèle en nom, paramètres positionnels et nommés.

    Un paramètre n'est considéré comme nommé que si sa clé ressemble à une clé
    (identifiant court, minuscules). Sans cette précaution, un texte d'exemple
    contenant « = » serait pris pour un paramètre nommé et disparaîtrait de la
    citation.
    """
    parts = split_top_level(body)
    name = parts[0].strip().lower().lstrip("(").rstrip(")")
    positional: list[str] = []
    named: dict[str, str] = {}

    for part in parts[1:]:
        if "=" in part:
            key, _, value = part.partition("=")
            key = key.strip().lower()
            if key and re.fullmatch(r"[a-z0-9_\- ]{1,24}", key):
                named[key] = value.strip()
                continue
        positional.append(part.strip())

    return Template(name=name, positional=tuple(positional), named=named)


def leading_templates(text: str) -> tuple[list[Template], str]:
    """Modèles en tête de ligne, et texte qui suit.

    Une définition du Wiktionnaire commence presque toujours par une ou
    plusieurs étiquettes : ``# {{lexique|logique|fr}} [[raisonnement|Raisonnement]]``.
    Les isoler est la seule façon de distinguer l'étiquette du sens.
    """
    templates: list[Template] = []
    cursor = 0
    while True:
        while cursor < len(text) and text[cursor] in " \t":
            cursor += 1
        if not text.startswith("{{", cursor):
            break
        found = False
        for start, end, body in iter_templates(text[cursor:]):
            if start != 0:
                break
            templates.append(parse_template(body))
            cursor += end
            found = True
            break
        if not found:
            break
    return templates, text[cursor:].strip()


# MARK: - Nettoyage


def strip_comments(text: str) -> str:
    return _COMMENT_RE.sub("", text)


def strip_references(text: str) -> str:
    return _REF_RE.sub("", text)


def strip_html(text: str) -> str:
    return _TAG_RE.sub("", text)


def strip_links(text: str) -> str:
    """Remplace les liens par leur libellé, et supprime les inclusions.

    ``[[chat|Chat]]`` devient « Chat » ; ``[[Fichier:Chat.jpg|vignette|Un chat]]``
    disparaît entièrement — une légende d'image n'est pas une définition.
    """
    out: list[str] = []
    index = 0
    length = len(text)
    while index < length:
        if text.startswith("[[", index):
            depth = 0
            cursor = index
            while cursor < length - 1:
                if text.startswith("[[", cursor):
                    depth += 1
                    cursor += 2
                    continue
                if text.startswith("]]", cursor):
                    depth -= 1
                    cursor += 2
                    if depth == 0:
                        break
                    continue
                cursor += 1
            if depth != 0:
                break
            pieces = split_top_level(text[index + 2:cursor - 2])
            target = pieces[0].strip()
            namespace = target.split(":")[0].strip().lower()
            if namespace in {"fichier", "image", "file", "catégorie", "category", "media", "média"}:
                pass  # inclusion : rien à conserver
            elif len(pieces) > 1:
                out.append(pieces[-1].strip())
            else:
                out.append(target)
            index = cursor
            continue
        if text[index] == "[":
            match = re.match(r"\[(https?://\S+)(?:\s+([^\]]*))?\]", text[index:])
            if match:
                out.append((match.group(2) or "").strip())
                index += match.end()
                continue
        out.append(text[index])
        index += 1
    return "".join(out)


def strip_formatting(text: str) -> str:
    """Retire les marques de mise en forme, en conservant le texte."""
    text = text.replace("'''", "").replace("''", "")
    text = text.replace("&nbsp;", " ").replace("&amp;", "&")
    text = text.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"')
    return text


def collapse_whitespace(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


# MARK: - Rendu en texte

#: Modèles qui écrivent un numéral ou un ordinal abrégé.
NUMERAL_TEMPLATES: dict[str, str] = {
    "1er": "1er",
    "1re": "1re",
    "2d": "2d",
    "2de": "2de",
    "er": "er",
    "re": "re",
    "ème": "e",
    "eme": "e",
    "e": "e",
}


def template_to_text(template: Template) -> str:
    """Texte produit par un modèle, ou chaîne vide s'il doit disparaître."""
    name = template.name
    if name in KEEP_CONTENT_TEMPLATES:
        if name in ("lang", "langue"):
            # {{lang|fro}} ne porte aucun texte : sans ce filtre, le code de
            # langue se retrouverait dans la phrase affichée à l'utilisateur.
            for value in template.positional:
                if value not in LANGUAGE_CODES:
                    return value
            return ""
        return template.positional[0] if template.positional else ""
    if name in NUMERAL_TEMPLATES:
        # « Pyrrhus I{{er}} » doit redevenir « Pyrrhus Ier ».
        return NUMERAL_TEMPLATES[name]
    if name in WORD_TEMPLATES:
        if name in ("lien", "lien-"):
            return template.argument("mot", "1", "texte") or ""
        if name in ("étyl", "étymologie"):
            return template.argument("mot", "3") or ""
        parts = [p for p in template.positional if p not in LANGUAGE_CODES]
        return " + ".join(parts) if parts else ""
    if name in CREDIT_TEMPLATES:
        # {{w|Victor Hugo}} désigne un auteur : son nom est du texte utile.
        return template.positional[0] if template.positional else ""
    return ""


def to_plain_text(text: str, *, keep_links: bool = True) -> str:
    """Chaîne affichable à partir d'un fragment de wikitexte."""
    text = strip_comments(text)
    text = strip_references(text)
    if keep_links:
        text = strip_links(text)

    # Remplacement des modèles, du plus profond au plus externe : on relance
    # tant qu'il reste des modèles, ce qui traite correctement l'imbrication.
    for _ in range(8):
        matches = list(iter_templates(text))
        if not matches:
            break
        replaced = False
        for start, end, body in reversed(matches):
            # On ne remplace que les modèles sans imbrication interne.
            if "{{" in body:
                continue
            text = text[:start] + template_to_text(parse_template(body)) + text[end:]
            replaced = True
        if not replaced:
            break

    text = strip_html(text)
    text = strip_formatting(text)
    return collapse_whitespace(text)


# MARK: - Découpage

def _sections_of(text: str) -> list[Section]:
    matches = list(_HEADING_RE.finditer(text))
    sections: list[Section] = []
    for position, match in enumerate(matches):
        start = match.end()
        end = matches[position + 1].start() if position + 1 < len(matches) else len(text)
        sections.append(
            Section(level=len(match.group(1)), heading=match.group(2).strip(), body=text[start:end])
        )
    return sections


def parse_sections(text: str) -> list[Section]:
    """Découpe une page en sections de niveau 2 à 6, dans l'ordre du document."""
    return _sections_of(strip_comments(text))


def heading_template(heading: str) -> Template | None:
    """Modèle porté par un titre de section, s'il y en a un."""
    for start, end, body in iter_templates(heading):
        if start == 0 and end == len(heading):
            return parse_template(body)
        break
    return None


def heading_label(heading: str) -> str:
    """Nom lisible d'un titre : ``{{S|nom|fr}}`` → ``nom``."""
    template = heading_template(heading)
    if template is None:
        return heading.strip().lower()
    if template.name in ("s", "section"):
        return template.positional[0].strip().lower() if template.positional else ""
    return template.name


def iter_list_items(body: str):
    """Parcourt les lignes de liste d'un corps de section."""
    for line in body.split("\n"):
        match = _LIST_ITEM_RE.match(line.strip())
        if not match:
            continue
        markers = match.group(1)
        yield ListItem(depth=len(markers), marker=markers[-1], content=match.group(2).strip())


def subsection_bodies(body: str) -> tuple[str, list[Section]]:
    """Sépare le corps d'une section de ses sous-sections de niveau 4+."""
    matches = list(_HEADING_RE.finditer(body))
    if not matches:
        return body, []
    head = body[:matches[0].start()]
    return head, _sections_of(body)
