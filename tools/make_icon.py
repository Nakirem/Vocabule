#!/usr/bin/env python3
"""Dessine l'icône de l'application.

**Outil d'auteur, pas étape de construction.** L'image produite est versionnée
dans `App/Resources/Assets.xcassets/AppIcon.appiconset/`, et c'est elle que la
CI embarque : la CI n'exécute jamais ce script et n'a donc pas besoin de
Pillow. On ne relance ce script que si l'icône doit changer.

Le dessin est volontairement géométrique — un V tracé en polygone, sans police
de caractères. Une lettre composée avec une fonte dépendrait des fontes
installées sur la machine qui l'exécute, et deux personnes n'obtiendraient pas
la même icône. Un polygone donne le même résultat partout.

Le rendu se fait à quatre fois la taille finale puis est réduit : c'est ce qui
donne des bords lisses sans écrire de code d'anticrénelage.

Les couleurs sont celles du thème clair de l'application
(`VocabulleTheme.background` et `VocabulleTheme.accent`), pour que l'icône et
l'écran d'accueil ne jurent pas.

Usage :
    python3 tools/make_icon.py
    python3 tools/make_icon.py --output /tmp/essai.png
"""

from __future__ import annotations

import argparse
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover - dépend de la machine de l'auteur
    raise SystemExit(
        "Pillow est requis pour dessiner l'icône : python3 -m pip install Pillow"
    )

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = (
    ROOT
    / "App"
    / "Resources"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
    / "Icon-1024.png"
)

SIZE = 1024
"""Côté de l'image. iOS attend 1024×1024 pour l'icône d'application."""

SUPERSAMPLE = 4
"""Facteur de suréchantillonnage avant réduction."""

BACKGROUND = (0xFA, 0xF7, 0xF2)
"""`VocabulleTheme.background` en clair — le crème de l'application."""

ACCENT = (0x6B, 0x5B, 0x95)
"""`VocabulleTheme.accent` en clair — le violet doux de l'application."""

# Proportions du V, en fraction du côté. Regroupées ici pour que la forme se
# règle en un seul endroit.
LEFT = 0.227
RIGHT = 0.773
TOP = 0.285
APEX = 0.715
STROKE = 0.129
NOTCH = 0.547


def v_outline(size: int) -> list[tuple[float, float]]:
    """Sommets du V, dans l'ordre du contour, pour un carré de côté `size`.

    Six points : deux pour chaque extrémité haute, deux pour la pointe. Le
    polygone passe par l'extérieur gauche, descend à la pointe intérieure,
    remonte à l'extérieur droit, puis redescend à la pointe extérieure — ce qui
    donne une lettre aux traits qui s'amincissent vers le bas, et non un
    chevron d'épaisseur constante.
    """
    middle = size / 2
    return [
        (size * LEFT, size * TOP),
        (size * (LEFT + STROKE), size * TOP),
        (middle, size * NOTCH),
        (size * (RIGHT - STROKE), size * TOP),
        (size * RIGHT, size * TOP),
        (middle, size * APEX),
    ]


def draw(size: int = SIZE, supersample: int = SUPERSAMPLE) -> Image.Image:
    """Rend l'icône en RGB, sans canal alpha."""
    # RGB et non RGBA : une icône d'application iOS ne doit pas porter de
    # transparence, et Xcode refuse l'archive si elle en contient.
    large = size * supersample
    canvas = Image.new("RGB", (large, large), BACKGROUND)
    ImageDraw.Draw(canvas).polygon(v_outline(large), fill=ACCENT)
    return canvas.resize((size, size), Image.LANCZOS)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, default=DEFAULT_OUTPUT, help="PNG à écrire"
    )
    parser.add_argument("--size", type=int, default=SIZE, help="Côté en pixels")
    args = parser.parse_args()

    image = draw(args.size)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    image.save(args.output, "PNG", optimize=True)

    print(f"Icône écrite : {args.output}")
    print(f"  {image.width}×{image.height}, mode {image.mode}")
    print(f"  {args.output.stat().st_size} octets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
