#!/usr/bin/env python3
"""Parle au salon d'administration de Continuwuity, et rend la réponse du bot.

    salon-admin.py <url> <jeton> <serveur> "<commande>"

Continuwuity n'a pas d'API d'administration HTTP : tout — enregistrer un
application service, promouvoir un compte, lister les sessions d'un compte —
passe par des messages dans `#admins:<serveur>`, auxquels le bot du serveur
répond par un message. C'est donc ici que se traduit tout ce que l'app fait
aujourd'hui par `_synapse/admin`.

La commande peut porter un bloc de code : on la passe telle quelle, sauts de
ligne compris.
"""

import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 20


def appel(url: str, jeton: str, methode: str, chemin: str, corps=None):
    requete = urllib.request.Request(
        url + chemin,
        method=methode,
        data=None if corps is None else json.dumps(corps).encode(),
        headers={"Authorization": f"Bearer {jeton}", "Content-Type": "application/json"},
    )
    try:
        return json.load(urllib.request.urlopen(requete, timeout=TIMEOUT))
    except urllib.error.HTTPError as erreur:
        return json.load(erreur)


def main() -> None:
    url, jeton, serveur, commande = sys.argv[1:5]
    alias = urllib.parse.quote(f"#admins:{serveur}")

    moi = appel(url, jeton, "GET", "/_matrix/client/v3/account/whoami").get("user_id", "")

    resolu = appel(url, jeton, "GET", f"/_matrix/client/v3/directory/room/{alias}")
    salon = resolu.get("room_id")
    if not salon:
        print(json.dumps({"erreur": "salon #admins introuvable", "detail": resolu}))
        sys.exit(1)

    # On note où on en est avant d'écrire : la réponse du bot est ce qui arrive
    # après. Sans ça on relirait l'historique et on prendrait une vieille réponse.
    filtre = urllib.parse.quote(json.dumps({"room": {"timeline": {"limit": 1}}}))
    debut = appel(url, jeton, "GET", f"/_matrix/client/v3/sync?filter={filtre}&timeout=0")
    depuis = debut.get("next_batch", "")

    envoi = appel(
        url,
        jeton,
        "PUT",
        f"/_matrix/client/v3/rooms/{urllib.parse.quote(salon)}/send/m.room.message/"
        f"admin{int(time.time() * 1000)}",
        {"msgtype": "m.text", "body": commande},
    )
    if "event_id" not in envoi:
        print(json.dumps({"erreur": "envoi refusé", "detail": envoi}))
        sys.exit(1)

    fin = time.time() + TIMEOUT
    while time.time() < fin:
        sync = appel(
            url, jeton, "GET",
            f"/_matrix/client/v3/sync?since={urllib.parse.quote(depuis)}&timeout=3000",
        )
        depuis = sync.get("next_batch", depuis)
        piece = sync.get("rooms", {}).get("join", {}).get(salon, {})
        for evenement in piece.get("timeline", {}).get("events", []):
            if evenement.get("type") != "m.room.message":
                continue
            if evenement.get("event_id") == envoi["event_id"]:
                continue
            if evenement.get("sender") == moi:
                continue
            print(json.dumps({
                "salon": salon,
                "auteur": evenement.get("sender"),
                "reponse": evenement.get("content", {}).get("body", ""),
            }))
            return
    print(json.dumps({"erreur": "le bot n'a pas répondu", "salon": salon}))
    sys.exit(1)


if __name__ == "__main__":
    main()
