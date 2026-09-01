#!/usr/bin/env python3
"""Ouvre le salon de gestion d'un pont et lui parle, pour prouver qu'il répond.

    eprouver-ponts.py <url> <jeton> <serveur> <bot> <commande> [<commande>…]

Le salon de gestion est un salon privé entre le propriétaire et le bot du pont.
On l'ouvre (ou on le retrouve), on envoie chaque commande, et on imprime la
réponse — texte, ou le type de l'événement quand ce n'en est pas (un QR arrive
en `m.image`).

⚠ On ne scanne JAMAIS le QR d'un pont d'essai : un second appareil lié
débrancherait le vrai pont du NUC. Le faire apparaître est toute la preuve.
"""

import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 45


def appel(url, jeton, methode, chemin, corps=None):
    requete = urllib.request.Request(
        url + chemin,
        method=methode,
        data=None if corps is None else json.dumps(corps).encode(),
        headers={"Authorization": f"Bearer {jeton}", "Content-Type": "application/json"},
    )
    try:
        return json.load(urllib.request.urlopen(requete, timeout=30))
    except urllib.error.HTTPError as erreur:
        return json.load(erreur)


def main() -> None:
    url, jeton, serveur, bot = sys.argv[1:5]
    commandes = sys.argv[5:]
    mxid = f"@{bot}:{serveur}"

    # Un pont ne reconnaît qu'UN salon de gestion : le premier où on lui parle.
    # En ouvrir un second à chaque passe le laisse répondre « use !wa help » sans
    # jamais exécuter la commande — on garde donc le premier, par écrit.
    memoire = pathlib.Path(os.environ.get("SPIKE_HOME", str(pathlib.Path.home() / ".correspondance-unclic")))
    trace = memoire / f"gestion-{bot}.txt"
    piece = trace.read_text().strip() if trace.exists() else ""
    if piece:
        print(f"salon de gestion retrouvé : {piece}")
    else:
        salon = appel(url, jeton, "POST", "/_matrix/client/v3/createRoom", {
            "preset": "trusted_private_chat",
            "is_direct": True,
            "invite": [mxid],
            "name": f"gestion {bot}",
        })
        if "room_id" not in salon:
            print(json.dumps({"erreur": "salon de gestion impossible", "detail": salon}, ensure_ascii=False))
            sys.exit(1)
        piece = salon["room_id"]
        trace.write_text(piece + "\n")
        print(f"salon de gestion ouvert : {piece} (invitation de {mxid})")

    filtre = urllib.parse.quote(json.dumps({"room": {"timeline": {"limit": 1}}}))
    depuis = appel(url, jeton, "GET",
                   f"/_matrix/client/v3/sync?filter={filtre}&timeout=0").get("next_batch", "")

    for commande in commandes:
        envoi = appel(
            url, jeton, "PUT",
            f"/_matrix/client/v3/rooms/{urllib.parse.quote(piece)}/send/m.room.message/"
            f"pont{int(time.time() * 1000)}",
            {"msgtype": "m.text", "body": commande},
        )
        print(f"\n--- envoyé : {commande}  ({envoi.get('event_id', envoi)})")
        # Un pont répond souvent en deux temps (« scanne le QR », puis l'image) :
        # on continue d'écouter quelques secondes après la première réponse.
        fin, vus = time.time() + TIMEOUT, 0
        while time.time() < fin and vus < 3:
            sync = appel(url, jeton, "GET",
                         f"/_matrix/client/v3/sync?since={urllib.parse.quote(depuis)}&timeout=4000")
            depuis = sync.get("next_batch", depuis)
            salle = sync.get("rooms", {}).get("join", {}).get(piece, {})
            for evenement in salle.get("timeline", {}).get("events", []):
                if evenement.get("type") != "m.room.message":
                    continue
                if evenement.get("sender") != mxid:
                    continue
                contenu = evenement.get("content", {})
                genre = contenu.get("msgtype")
                if genre in ("m.image", "m.file"):
                    print(f"[{genre}] {contenu.get('body')} — url {contenu.get('url')} "
                          f"(NON SCANNÉ, volontairement)")
                else:
                    print(contenu.get("body", ""))
                vus += 1
                if vus == 1:
                    fin = min(fin, time.time() + 12)
        if not vus:
            print("(aucune réponse du bot)")


if __name__ == "__main__":
    main()
