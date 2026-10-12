"""Tests des scripts d'outillage.

Paquet Python, et non simple dossier : `unittest discover` refuse un répertoire
de départ qui n'est pas importable. Les tests eux-mêmes n'importent rien de ce
paquet — ils exécutent les scripts en sous-processus, ce qui vérifie leur
comportement réel plutôt que leurs fonctions internes.
"""
