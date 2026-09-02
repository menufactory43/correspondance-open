#!/usr/bin/env python3
"""Fabrique le code d'appairage que l'app lit, et ses six mots de vérification.

    appairage.py <url> <serveur> <utilisateur> <mot de passe>

Le format est celui de `RelayPairingCode` (Packages/CorrespondanceCore/Sources/
CorrespondanceCore/Matrix/RelayPairingCode.swift) et de infra/matrix/pair.sh :
un JSON compact, trié, en base64 « URL-safe » sans remplissage, derrière
`correspondance://relais/`. Les six mots se calculent sur l'identité du Relais
seule — adresse, nom, propriétaire — pour qu'un code réémis donne les mêmes.
"""

import base64
import json
import sys
import time

DUREE = 900  # un quart d'heure : le temps de passer d'un terminal à une app

LEXIQUE = [
    "arbre", "banc", "cabane", "dune", "encre", "falaise", "givre", "halo",
    "iris", "jardin", "kiosque", "lampe", "marée", "neige", "olive", "pluie",
    "quai", "roseau", "sable", "tuile", "usine", "vague", "wagon", "zeste",
    "brume", "chêne", "digue", "étang", "flotte", "grange", "houle", "index",
]


def mots(materiau: str) -> list[str]:
    condense = 1469598103934665603
    for octet in materiau.encode():
        condense ^= octet
        condense = (condense * 1099511628211) % (1 << 64)
    sortie, reste = [], condense
    for _ in range(6):
        sortie.append(LEXIQUE[reste % len(LEXIQUE)])
        reste = (reste // len(LEXIQUE) + reste * 31) % (1 << 64)
    return sortie


def main() -> None:
    url, serveur, utilisateur, mot_de_passe = sys.argv[1:5]
    charge = {
        "v": 1,
        "homeserver": url,
        "server": serveur,
        "user": utilisateur,
        "password": mot_de_passe,
        "exp": time.time() + DUREE,
    }
    brut = json.dumps(charge, separators=(",", ":"), sort_keys=True).encode()
    jeton = base64.b64encode(brut).decode().replace("+", "-").replace("/", "_").rstrip("=")
    verification = mots(f"{url}|{serveur}|@{utilisateur}:{serveur}")

    print()
    print("  Relais prêt. Dans Correspondance : « Connecter un Relais », puis colle ce code.")
    print()
    print(f"  correspondance://relais/{jeton}")
    print()
    print(f"  Vérification (six mots) : {' '.join(verification)}")
    print("  Il périme dans 15 minutes. Il contient un mot de passe : ne le poste nulle part.")


if __name__ == "__main__":
    main()
