#!/usr/bin/env python3
"""Fusion profonde des overrides Correspondance dans le config.yaml d'un bridge mautrix.

Les configs amont font des dizaines de kilo-octets et bougent à chaque version : on ne
les fige pas dans le repo, on ne réécrit que nos propres choix par-dessus.

    merge-overrides.py <config.yaml généré par l'image> <overrides.yaml>
"""
import sys
import yaml


# Une section d'overrides marquée ainsi remplace celle d'amont au lieu de s'y ajouter.
# Sans ça, impossible de chasser les valeurs d'exemple que les configs mautrix livrent
# par défaut : `double_puppet.secrets` arrive peuplé d'un `example.com: as_token:foobar`
# qu'une fusion, par construction, ne retire jamais.
REPLACE_MARKER = "__remplacer__"


def replaces(value) -> bool:
    """Un mapping vide, ou marqué, dit « cette section, c'est la mienne, entièrement »."""
    return isinstance(value, dict) and (not value or value.pop(REPLACE_MARKER, False) is True)


def merge(dst, src):
    for key, value in src.items():
        if isinstance(value, dict) and isinstance(dst.get(key), dict) and not replaces(value):
            merge(dst[key], value)
        else:
            dst[key] = value
    return dst


def main() -> None:
    base_path, over_path = sys.argv[1], sys.argv[2]
    with open(base_path) as handle:
        base = yaml.safe_load(handle)
    with open(over_path) as handle:
        over = yaml.safe_load(handle)

    # as_token / hs_token sont générés par le bridge : ne jamais les écraser.
    merge(base, over)
    with open(base_path, "w") as handle:
        yaml.safe_dump(base, handle, sort_keys=False, allow_unicode=True, width=4096)


if __name__ == "__main__":
    main()
