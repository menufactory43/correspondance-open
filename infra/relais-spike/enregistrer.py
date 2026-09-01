#!/usr/bin/env python3
"""Enregistre un compte sur le Relais du spike par l'API cliente standard.

    enregistrer.py <url> <utilisateur> <mot de passe> <jeton>

Sort le JSON de la réponse du serveur — l'appelant y cherche `access_token`.
On passe par `/register` et non par l'API d'administration parce que
Continuwuity n'en a pas : le premier compte enregistré devient administrateur
du serveur de lui-même, ce qui est exactement ce dont on a besoin une fois.
"""

import json
import sys
import urllib.error
import urllib.request


def main() -> None:
    url, user, password, token = sys.argv[1:5]

    def post(body: dict) -> dict:
        requete = urllib.request.Request(
            url + "/_matrix/client/v3/register",
            method="POST",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            return json.load(urllib.request.urlopen(requete))
        except urllib.error.HTTPError as erreur:
            return json.load(erreur)

    base = {
        "username": user,
        "password": password,
        "initial_device_display_name": "spike-un-clic",
    }
    # Premier appel sans `auth` : le serveur ouvre une session d'authentification
    # interactive et annonce l'étape qu'il attend (m.login.registration_token).
    ouverture = post(dict(base))
    session = ouverture.get("session")
    if not session:
        print(json.dumps(ouverture))
        return
    print(json.dumps(post(
        dict(base, auth={"type": "m.login.registration_token", "token": token, "session": session})
    )))


if __name__ == "__main__":
    main()
