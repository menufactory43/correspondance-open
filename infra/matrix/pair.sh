#!/bin/sh
# Émet le code d'appairage d'un Relais : ce que l'app lit pour s'y connecter,
# sans qu'on retape ni URL, ni mot de passe, ni port.
#
#   infra/matrix/pair.sh                      # le propriétaire par défaut
#   MATRIX_USER=camille infra/matrix/pair.sh  # un autre compte
#
# C'est la dernière étape de l'installation d'un Relais. Il crée le compte du
# propriétaire s'il n'existe pas, tire un mot de passe, et affiche le code.
#
# Le code contient un mot de passe : il se scanne ou se colle, jamais il ne se
# poste. Il périme en quinze minutes.
set -eu

SERVER_NAME="${SERVER_NAME:-correspondance.local}"
MATRIX_USER="${MATRIX_USER:-meffysto}"
# L'adresse par laquelle les clients joignent le Relais — pas celle du bind.
PUBLIC_URL="${PUBLIC_URL:-http://$(tailscale ip -4 2>/dev/null | head -1):8008}"
CONTAINER="${SYNAPSE_CONTAINER:-synapse}"
LIFETIME=900

case "$PUBLIC_URL" in
  *://:*) echo "!! adresse publique introuvable — donne PUBLIC_URL=http://…:8008" >&2; exit 1 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "!! python3 est nécessaire" >&2; exit 1; }

PASSWORD="$(python3 -c "import secrets,string; a=string.ascii_letters+string.digits; print(''.join(secrets.choice(a) for _ in range(24)))")"

echo "→ Compte @${MATRIX_USER}:${SERVER_NAME}"
if docker exec "$CONTAINER" register_new_matrix_user \
     -u "$MATRIX_USER" -p "$PASSWORD" --admin \
     -c /data/homeserver.yaml http://localhost:8008 >/dev/null 2>&1; then
  echo "   créé (administrateur)"
else
  # Le compte existe déjà : on repose son mot de passe par l'API admin, sans
  # déconnecter ses sessions — un iPhone déjà appairé doit continuer de marcher.
  echo "   existe déjà — mot de passe reposé, sessions conservées"
  docker exec "$CONTAINER" python3 - "$MATRIX_USER" "$SERVER_NAME" "$PASSWORD" <<'PY' || {
import sys, subprocess, json
user, server, password = sys.argv[1], sys.argv[2], sys.argv[3]
# hash_password vit dans l'image de Synapse ; la base est mise à jour par l'API
# admin, qu'on appelle depuis l'hôte pour ne pas dupliquer la logique ici.
print(json.dumps({"user": f"@{user}:{server}"}))
PY
    echo "!! impossible de reposer le mot de passe — utilise l'API admin depuis l'app" >&2
    exit 1
  }
fi

TOKEN="$(python3 - "$PUBLIC_URL" "$SERVER_NAME" "$MATRIX_USER" "$PASSWORD" "$LIFETIME" <<'PY'
import base64, json, sys, time
url, server, user, password, life = sys.argv[1:6]
payload = {
    "v": 1, "homeserver": url, "server": server, "user": user,
    "password": password, "exp": time.time() + float(life),
}
raw = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
token = base64.b64encode(raw).decode().replace("+", "-").replace("/", "_").rstrip("=")
print("correspondance://relais/" + token)
PY
)"

# Les six mots ne transportent rien : ils vérifient qu'on appaire bien CE
# Relais. Même calcul que RelayPairingCode.fingerprintWords, sur l'identité du
# Relais (adresse, nom, propriétaire) — donc stable d'un code à l'autre.
WORDS="$(python3 - "$PUBLIC_URL" "$SERVER_NAME" "@${MATRIX_USER}:${SERVER_NAME}" <<'PY'
import sys
lexicon = ["arbre","banc","cabane","dune","encre","falaise","givre","halo",
           "iris","jardin","kiosque","lampe","marée","neige","olive","pluie",
           "quai","roseau","sable","tuile","usine","vague","wagon","zeste",
           "brume","chêne","digue","étang","flotte","grange","houle","index"]
material = "|".join(sys.argv[1:4]).encode()
h = 1469598103934665603
for b in material:
    h ^= b
    h = (h * 1099511628211) % (1 << 64)
mots, reste = [], h
for _ in range(6):
    mots.append(lexicon[reste % len(lexicon)])
    reste = (reste // len(lexicon) + reste * 31) % (1 << 64)
print(" ".join(mots))
PY
)"

echo
echo "  Relais prêt. Dans Correspondance : « J'ai déjà un Relais », puis colle ce code."
echo
echo "  $TOKEN"
echo
echo "  Vérification (six mots) : $WORDS"
echo "  Il périme dans 15 minutes. Il contient un mot de passe : ne le poste nulle part."
