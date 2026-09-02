#!/usr/bin/env bash
# Correspondance — pose un Relais complet (homeserver + ponts) sur cette machine,
# sans conteneur, sans sudo, et finit sur le code d'appairage que l'app lit.
#
#   curl -fsSL https://github.com/menufactory43/correspondance-releases/releases/latest/download/relais-install.sh \
#     -o /tmp/relais-install.sh && bash /tmp/relais-install.sh
#
# Pas de « curl | sh » : un domaine absent y fait un script vide, et `sh` d'un
# script vide sort en 0 — la commande dirait « installé » sans rien avoir fait
# (le défaut trouvé sur l'installeur de l'agent, commit d59bf27).
#
# Options
#   --dry-run             imprime le plan et n'exécute rien
#   --prefix DOSSIER      où tout vit          (défaut : ~/.correspondance-unclic)
#   --port N              port du Relais       (défaut : 8010)
#   --server-name NOM     nom du serveur Matrix (défaut : unclic.local)
#   --user NOM            compte propriétaire  (défaut : essai)
#   --bind ADRESSE        adresse d'écoute     (défaut : 127.0.0.1)
#   --hote CIBLE          force l'hôte (macos-arm64 | linux-x86_64 | linux-arm64),
#                         pour éprouver le plan des trois cibles depuis une seule
#   --sans-ponts          ne pose que le homeserver
#
# Ce qu'il ne fait pas : il n'installe jamais Tailscale (ça demande sudo). Il
# l'utilise s'il est là, et dit ce qu'il faudrait faire s'il manque.
set -euo pipefail

# ------------------------------------------------------------------ les options
PREFIX="${CORRESPONDANCE_RELAIS_PREFIX:-$HOME/.correspondance-unclic}"
PORT=8010
SERVER_NAME=unclic.local
USER_NAME=essai
BIND=127.0.0.1
DRY=0
HOTE=""
PONTS=1

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --prefix) PREFIX="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    --server-name) SERVER_NAME="$2"; shift ;;
    --user) USER_NAME="$2"; shift ;;
    --bind) BIND="$2"; shift ;;
    --hote) HOTE="$2"; shift ;;
    --sans-ponts) PONTS=0 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "!! option inconnue : $1" >&2; exit 2 ;;
  esac
  shift
done

case "$PREFIX" in
  "$HOME/.correspondance-agent"|"$HOME/Library/Application Support/Correspondance")
    echo "!! $PREFIX appartient à la prod — refus." >&2; exit 2 ;;
esac

# ------------------------------------------------------------------- l'hôte
if [ -z "$HOTE" ]; then
  case "$(uname -s)/$(uname -m)" in
    Darwin/arm64)   HOTE=macos-arm64 ;;
    Linux/x86_64)   HOTE=linux-x86_64 ;;
    Linux/aarch64)  HOTE=linux-arm64 ;;
    *) echo "!! machine non prévue : $(uname -s)/$(uname -m)" >&2; exit 1 ;;
  esac
fi

# ------------------------------------------- versions épinglées et empreintes
# Continuwuity ne publie que des binaires Linux. Sur macOS, le binaire vient de
# NOTRE publication (construit au même tag, cf. docs/spike-un-clic/phase-1.md) —
# et pour ce spike, d'un serveur local qu'on donne par CORRESPONDANCE_RELEASES.
CONTINUWUITY_TAG=v26.8.1
AMONT_CONTINUWUITY="https://forgejo.ellis.link/continuwuation/continuwuity/releases/download/$CONTINUWUITY_TAG"
RELEASES="${CORRESPONDANCE_RELEASES:-https://github.com/menufactory43/correspondance-releases/releases/latest/download}"
MAUTRIX_TAG=v0.2608.0

case "$HOTE" in
  macos-arm64)
    RELAIS_URL_BIN="$RELEASES/continuwuity-macos-arm64"
    RELAIS_SHA=a7b4dd2099dd349631b24c3f3970cb440fb9365a3aa406830995d389fae16f77
    WA_URL="https://github.com/mautrix/whatsapp/releases/download/$MAUTRIX_TAG/mautrix-whatsapp-darwin-arm64"
    WA_SHA=938242a121df389706dc00e6cbdd9b6fedd267963e3eaddd2ee701c6ddeb4808
    SG_URL="https://github.com/mautrix/signal/releases/download/$MAUTRIX_TAG/mautrix-signal-darwin-arm64"
    SG_SHA=9d48db00fb3e7e7382d7b165a90e4952a6902d18ecf304436c29fc8cc216e586
    # Les binaires mautrix de macOS chargent @rpath/libolm.3.dylib, que Homebrew
    # ne porte plus. Elle vient de notre publication, posée à côté d'eux.
    OLM_URL="$RELEASES/libolm.3.dylib"
    OLM_SHA=d946defe44adc62d706b3acde6a6904532f32abe4ef7e0096ec08d273ee07168
    ;;
  linux-x86_64)
    RELAIS_URL_BIN="$AMONT_CONTINUWUITY/conduwuit-linux-static-amd64"
    RELAIS_SHA=43bcf0e41a60219fe96673e6ed7c041cca1aee42d1758bfeccb571f89f4ed02d
    WA_URL="https://github.com/mautrix/whatsapp/releases/download/$MAUTRIX_TAG/mautrix-whatsapp-amd64"
    WA_SHA=dc519ea63f34dd0b0b33bffda1dc671360ba9e7f806d77ba9849b9586540e4f5
    SG_URL="https://github.com/mautrix/signal/releases/download/$MAUTRIX_TAG/mautrix-signal-amd64"
    SG_SHA=ab373049f98c3f1b48b3a386bc91166be401eda61176e2d528902f5d22c47afa
    OLM_URL=""; OLM_SHA=""
    ;;
  linux-arm64)
    RELAIS_URL_BIN="$AMONT_CONTINUWUITY/conduwuit-linux-static-arm64"
    RELAIS_SHA=28d0a92c4e5da57db878f6002d66ffbc1be997da8313cd78a8cebe44e9a38c15
    WA_URL="https://github.com/mautrix/whatsapp/releases/download/$MAUTRIX_TAG/mautrix-whatsapp-arm64"
    WA_SHA=fb2872d5c3b4b3d1184ba5971a9940115f404acfe17aa9a74ce470ee1b2c5c11
    SG_URL="https://github.com/mautrix/signal/releases/download/$MAUTRIX_TAG/mautrix-signal-arm64"
    SG_SHA=ca8bc4a741e4bfb41334d803c188bcdb18845b2412ed0e9db8de1aa77dccd368
    OLM_URL=""; OLM_SHA=""
    ;;
  *) echo "!! hôte inconnu : $HOTE" >&2; exit 2 ;;
esac

WA_PORT=$((PORT + 21308))   # 8010 → 29318 : les ports de la phase 1
SG_PORT=$((PORT + 21318))
BIN="$PREFIX/bin"
RELAIS_DIR="$PREFIX/relais"
LOGS="$PREFIX/logs"
OUTILS="$PREFIX/outils"
RELAIS="http://127.0.0.1:$PORT"
MXID="@$USER_NAME:$SERVER_NAME"
case "$HOTE" in macos-*) SYSTEME=launchd ;; *) SYSTEME=systemd ;; esac

dire() { printf '→ %s\n' "$*"; }
mourir() { printf '✗ %s\n' "$*" >&2; exit 1; }
somme() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
          else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# ----------------------------------------------------- l'adresse que l'app verra
# Tailscale n'est jamais installé par cet installeur : ça demande sudo. On le
# détecte, et sinon on dit ce qu'il faudrait faire.
TS_IP=""
TS_MOT=""
if [ "$SYSTEME" = systemd ]; then
  if command -v tailscale >/dev/null 2>&1; then
    TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  fi
  if [ -n "$TS_IP" ]; then
    TS_MOT="Tailscale est là : le code portera http://$TS_IP:$PORT, et le Relais écoutera aussi sur cette adresse."
  else
    TS_MOT="Tailscale absent. Cet installeur ne le pose PAS (ça demande sudo : curl -fsSL https://tailscale.com/install.sh | sh, puis sudo tailscale up). Le code portera http://127.0.0.1:$PORT — joignable depuis un autre poste par : ssh -N -L $PORT:127.0.0.1:$PORT <cette machine>."
  fi
else
  TS_MOT="macOS : Tailscale n'est ni posé ni requis. Le Relais et l'app sont sur la même machine, le code portera http://127.0.0.1:$PORT."
fi
if [ -n "$TS_IP" ]; then PUBLIC="http://$TS_IP:$PORT"; BINDS="\"$BIND\", \"$TS_IP\""; else PUBLIC="$RELAIS"; BINDS="\"$BIND\""; fi

# ------------------------------------------------------------------ le plan
plan() {
  echo "Plan d'installation du Relais Correspondance"
  echo "  hôte              $HOTE ($SYSTEME)"
  echo "  dossier           $PREFIX"
  echo "  serveur Matrix    $SERVER_NAME, propriétaire $MXID"
  echo "  écoute            $BIND:$PORT ; ponts sur $WA_PORT (WhatsApp) et $SG_PORT (Signal)"
  echo "  adresse du code   $PUBLIC"
  echo
  echo "  1. Prérequis : curl, python3, un calcul de sha256. Aucun sudo, aucun Docker, aucun Homebrew."
  echo "  2. Binaires, épinglés et vérifiés par sha256 (rien n'est installé si une somme diffère) :"
  echo "       continuwuity $CONTINUWUITY_TAG"
  echo "         $RELAIS_URL_BIN"
  echo "         sha256 $RELAIS_SHA"
  if [ $PONTS = 1 ]; then
    echo "       mautrix-whatsapp $MAUTRIX_TAG"
    echo "         $WA_URL"
    echo "         sha256 $WA_SHA"
    echo "       mautrix-signal $MAUTRIX_TAG"
    echo "         $SG_URL"
    echo "         sha256 $SG_SHA"
    if [ -n "$OLM_URL" ]; then
      echo "       libolm.3.dylib"
      echo "         $OLM_URL"
      echo "         sha256 $OLM_SHA"
      echo "         (les binaires mautrix de macOS la chargent par @rpath ; Homebrew ne la porte plus)"
    fi
  fi
  echo "  3. Secrets tirés une fois dans $PREFIX/secrets.env (0600), jamais réécrits."
  echo "  4. Configuration $RELAIS_DIR/continuwuity.toml : fédération fermée, base RocksDB dans le dossier."
  echo "  5. Service du Relais :"
  if [ "$SYSTEME" = launchd ]; then
    echo "       ~/Library/LaunchAgents/app.correspondance.relais.plist, chargé par launchctl bootstrap gui/\$(id -u)"
    echo "       (aucun launchd système, aucun sudo : c'est un agent utilisateur)"
  else
    echo "       ~/.config/systemd/user/correspondance-relais.service, systemctl --user enable --now"
    echo "       loginctl enable-linger \$(id -un) — sans sudo si la session en a le droit ; sinon l'installeur"
    echo "       le dit et continue (sans linger, tout meurt à la déconnexion SSH)"
  fi
  echo "  6. Attente que $RELAIS/_matrix/client/versions réponde."
  echo "  7. Compte propriétaire $MXID par /register — avec le jeton d'AMORÇAGE que Continuwuity"
  echo "     n'écrit que dans son journal (celui du .toml ne marche pas sur une base neuve)."
  echo "     Le premier compte enregistré devient administrateur et rejoint #admins."
  if [ $PONTS = 1 ]; then
    echo "  8. Configuration des deux ponts (SQLite, chiffrement des portails allow+default),"
    echo "     registration engendrée par le pont lui-même, puis déclarée au Relais par un message"
    echo "     « !admin appservices register » dans #admins — Continuwuity n'a pas de fichier de"
    echo "     registration, et la prend en compte à chaud."
    echo "  9. Services des ponts, démarrés APRÈS l'enregistrement de l'appservice."
  fi
  echo " 10. Preuve : /login avec le mot de passe du code, puis /account/whoami — « connecté comme $MXID »."
  echo " 11. Code d'appairage correspondance://relais/… + ses six mots de vérification."
  echo
  echo "  Tailscale : $TS_MOT"
}

if [ "$DRY" = 1 ]; then
  plan
  echo
  echo "  (--dry-run : rien n'a été exécuté)"
  exit 0
fi

# ============================================================ 1. les prérequis
command -v curl >/dev/null || mourir "curl est nécessaire"
command -v python3 >/dev/null || mourir "python3 est nécessaire (il lit le jeton et parle à #admins)"
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
  || mourir "ni sha256sum ni shasum : impossible de vérifier les binaires"

dire "hôte $HOTE — tout vit sous $PREFIX"
mkdir -p "$BIN" "$RELAIS_DIR/db" "$LOGS" "$OUTILS"
chmod 700 "$PREFIX"
: > "$PREFIX/.correspondance-relais"   # la marque que uninstall.sh exige avant d'effacer

# ============================================================== 2. les binaires
poser() {
  local nom="$1" url="$2" attendu="$3" cible="$BIN/$1"
  if [ -f "$cible" ] && [ "$(somme "$cible")" = "$attendu" ]; then
    dire "$nom déjà posé, sha256 conforme"
    return
  fi
  dire "$nom ← $url"
  curl -fsSL -o "$cible.part" "$url" || { rm -f "$cible.part"; mourir "$nom : téléchargement impossible ($url)"; }
  local vu; vu="$(somme "$cible.part")"
  [ "$vu" = "$attendu" ] || { rm -f "$cible.part"; mourir "$nom : sha256 $vu ≠ $attendu — on n'installe rien"; }
  mv "$cible.part" "$cible"
  chmod 755 "$cible"
  # macOS met en quarantaine tout ce qui vient du réseau : sans ça le binaire est tué.
  xattr -d com.apple.quarantine "$cible" 2>/dev/null || true
  dire "$nom : sha256 $vu ✓"
}

poser continuwuity "$RELAIS_URL_BIN" "$RELAIS_SHA"
if [ $PONTS = 1 ]; then
  [ -n "$OLM_URL" ] && poser libolm.3.dylib "$OLM_URL" "$OLM_SHA"
  poser mautrix-whatsapp "$WA_URL" "$WA_SHA"
  poser mautrix-signal "$SG_URL" "$SG_SHA"
fi

# =============================================================== 3. les secrets
SECRETS="$PREFIX/secrets.env"
if [ ! -f "$SECRETS" ]; then
  dire "secrets tirés dans $SECRETS (0600, hors dépôt)"
  ( umask 077
    {
      echo "REGISTRATION_TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
      echo "MATRIX_PASSWORD=$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(24)))')"
    } > "$SECRETS" )
  chmod 600 "$SECRETS"
fi
set -a; . "$SECRETS"; set +a

# ============================================================ 4. les outils py
# Trois petits programmes que l'installeur pose à côté de la pile : ils sont la
# traduction Continuwuity de ce que l'app fait chez Synapse par _synapse/admin.
cat > "$OUTILS/salon-admin.py" <<'PYADMIN'
#!/usr/bin/env python3
"""Poste une commande dans #admins et rend la réponse du bot du serveur.

    salon-admin.py <url> <jeton> <serveur> "<commande>"

Continuwuity n'a pas d'API d'administration HTTP : enregistrer un application
service, reposer un mot de passe, lister les sessions d'un compte — tout passe
par un message dans `#admins:<serveur>`.
"""
import json, sys, time, urllib.error, urllib.parse, urllib.request

TIMEOUT = 20


def appel(url, jeton, methode, chemin, corps=None):
    requete = urllib.request.Request(
        url + chemin, method=methode,
        data=None if corps is None else json.dumps(corps).encode(),
        headers={"Authorization": f"Bearer {jeton}", "Content-Type": "application/json"})
    try:
        return json.load(urllib.request.urlopen(requete, timeout=TIMEOUT))
    except urllib.error.HTTPError as erreur:
        return json.load(erreur)


def main():
    url, jeton, serveur, commande = sys.argv[1:5]
    alias = urllib.parse.quote(f"#admins:{serveur}")
    moi = appel(url, jeton, "GET", "/_matrix/client/v3/account/whoami").get("user_id", "")
    resolu = appel(url, jeton, "GET", f"/_matrix/client/v3/directory/room/{alias}")
    salon = resolu.get("room_id")
    if not salon:
        print(json.dumps({"erreur": "salon #admins introuvable", "detail": resolu})); sys.exit(1)
    # On note où on en est AVANT d'écrire : la réponse du bot est ce qui arrive
    # après. Sans ça on relirait l'historique et on prendrait une vieille réponse.
    filtre = urllib.parse.quote(json.dumps({"room": {"timeline": {"limit": 1}}}))
    depuis = appel(url, jeton, "GET", f"/_matrix/client/v3/sync?filter={filtre}&timeout=0").get("next_batch", "")
    envoi = appel(url, jeton, "PUT",
                  f"/_matrix/client/v3/rooms/{urllib.parse.quote(salon)}/send/m.room.message/admin{int(time.time()*1000)}",
                  {"msgtype": "m.text", "body": commande})
    if "event_id" not in envoi:
        print(json.dumps({"erreur": "envoi refusé", "detail": envoi})); sys.exit(1)
    fin = time.time() + TIMEOUT
    while time.time() < fin:
        sync = appel(url, jeton, "GET", f"/_matrix/client/v3/sync?since={urllib.parse.quote(depuis)}&timeout=3000")
        depuis = sync.get("next_batch", depuis)
        piece = sync.get("rooms", {}).get("join", {}).get(salon, {})
        for evenement in piece.get("timeline", {}).get("events", []):
            if evenement.get("type") != "m.room.message": continue
            if evenement.get("event_id") == envoi["event_id"]: continue
            if evenement.get("sender") == moi: continue
            print(json.dumps({"auteur": evenement.get("sender"),
                              "reponse": evenement.get("content", {}).get("body", "")}))
            return
    print(json.dumps({"erreur": "le bot n'a pas répondu"})); sys.exit(1)


main()
PYADMIN

cat > "$OUTILS/enregistrer.py" <<'PYREG'
#!/usr/bin/env python3
"""Enregistre le compte propriétaire par l'API cliente standard (UIA en deux temps).

    enregistrer.py <url> <utilisateur> <mot de passe> <jeton>

Continuwuity n'a pas d'API d'administration : on passe par /register, et le
PREMIER compte enregistré devient administrateur du serveur de lui-même.
"""
import json, sys, urllib.error, urllib.request


def poste(url, corps):
    requete = urllib.request.Request(url + "/_matrix/client/v3/register", method="POST",
                                     data=json.dumps(corps).encode(),
                                     headers={"Content-Type": "application/json"})
    try:
        return json.load(urllib.request.urlopen(requete))
    except urllib.error.HTTPError as erreur:
        return json.load(erreur)


url, user, password, token = sys.argv[1:5]
base = {"username": user, "password": password, "initial_device_display_name": "relais-install"}
ouverture = poste(url, dict(base))
session = ouverture.get("session")
if not session:
    print(json.dumps(ouverture))
else:
    print(json.dumps(poste(url, dict(base, auth={"type": "m.login.registration_token",
                                                 "token": token, "session": session}))))
PYREG

cat > "$OUTILS/appairage.py" <<'PYPAIR'
#!/usr/bin/env python3
"""Le code d'appairage que l'app lit, et ses six mots de vérification.

    appairage.py <url publique> <serveur> <utilisateur> <mot de passe>

Format de RelayPairingCode (Packages/CorrespondanceCore/…/RelayPairingCode.swift)
et de infra/matrix/pair.sh : un JSON compact trié, en base64 URL-safe sans
remplissage, derrière `correspondance://relais/`.
"""
import base64, json, sys, time

DUREE = 900
LEXIQUE = ["arbre", "banc", "cabane", "dune", "encre", "falaise", "givre", "halo",
           "iris", "jardin", "kiosque", "lampe", "marée", "neige", "olive", "pluie",
           "quai", "roseau", "sable", "tuile", "usine", "vague", "wagon", "zeste",
           "brume", "chêne", "digue", "étang", "flotte", "grange", "houle", "index"]


def mots(materiau):
    condense = 1469598103934665603
    for octet in materiau.encode():
        condense ^= octet
        condense = (condense * 1099511628211) % (1 << 64)
    sortie, reste = [], condense
    for _ in range(6):
        sortie.append(LEXIQUE[reste % len(LEXIQUE)])
        reste = (reste // len(LEXIQUE) + reste * 31) % (1 << 64)
    return sortie


url, serveur, utilisateur, mot_de_passe = sys.argv[1:5]
charge = {"v": 1, "homeserver": url, "server": serveur, "user": utilisateur,
          "password": mot_de_passe, "exp": time.time() + DUREE}
brut = json.dumps(charge, separators=(",", ":"), sort_keys=True).encode()
jeton = base64.b64encode(brut).decode().replace("+", "-").replace("/", "_").rstrip("=")
print()
print("  Relais prêt. Dans Correspondance : « Connecter un Relais », puis colle ce code.")
print()
print(f"  correspondance://relais/{jeton}")
print()
print(f"  Vérification (six mots) : {' '.join(mots(f'{url}|{serveur}|@{utilisateur}:{serveur}'))}")
print("  Il périme dans 15 minutes. Il contient un mot de passe : ne le poste nulle part.")
PYPAIR

# ========================================================= 5. le homeserver
# Écrit une seule fois : le .toml porte le jeton d'enregistrement, et la base
# RocksDB a été créée avec ce server_name. Relancer l'installeur ne le réécrit
# pas — c'est ce qui rend l'opération rejouable sans casser l'existant.
if [ ! -f "$RELAIS_DIR/continuwuity.toml" ]; then
  ( umask 077; cat > "$RELAIS_DIR/continuwuity.toml" <<TOML
# Écrit par infra/relais/install.sh — contient un jeton, ne pas versionner.
[global]
server_name = "$SERVER_NAME"
address = [$BINDS]
port = $PORT
database_path = "$RELAIS_DIR/db"
new_user_displayname_suffix = ""

# Le premier compte enregistré devient administrateur et rejoint #admins : c'est
# par ce salon que passe toute l'administration (Continuwuity n'a pas d'API HTTP
# d'administration, cf. docs/spike-un-clic/phase-1.md).
allow_registration = true
registration_token = "$REGISTRATION_TOKEN"
yes_i_am_very_very_sure_i_want_an_open_registration_server_prone_to_abuse = false

# Relais personnel sur la machine de son propriétaire : rien ne sort.
allow_federation = false
allow_public_room_directory_over_federation = false
# allow_check_for_updates en est un ALIAS : les deux ensemble = « duplicate field ».
allow_announcements_check = false
trusted_servers = []

# default_room_version = "10" empêche le démarrage sur une base neuve
# (« m.room.create event incorrectly omits creator field ») : on laisse le défaut.

log = "info"
log_colors = false
TOML
  )
  chmod 600 "$RELAIS_DIR/continuwuity.toml"
  dire "écrit $RELAIS_DIR/continuwuity.toml"
else
  dire "$RELAIS_DIR/continuwuity.toml déjà là, conservé"
fi

# ============================================================= 6. les services
service_launchd() {
  local nom="$1"; shift
  local label="app.correspondance.$nom"
  local plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$label</string>"
    echo '  <key>ProgramArguments</key><array>'
    for a in "$@"; do echo "    <string>$a</string>"; done
    echo '  </array>'
    echo '  <key>RunAtLoad</key><true/>'
    echo '  <key>KeepAlive</key><true/>'
    echo "  <key>StandardOutPath</key><string>$LOGS/$nom.log</string>"
    echo "  <key>StandardErrorPath</key><string>$LOGS/$nom.log</string>"
    echo '</dict></plist>'
  } > "$plist"
  # `bootout` rend la main AVANT que le service ait disparu : enchaîner
  # `bootstrap` tout de suite donne « Bootstrap failed: 5: Input/output error »,
  # et une seconde exécution de l'installeur échouait là. On attend la sortie.
  if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    for _ in $(seq 1 100); do
      launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break
      sleep 0.2
    done
  fi
  launchctl bootstrap "gui/$(id -u)" "$plist"
  dire "service $label chargé (journal $LOGS/$nom.log)"
}

service_systemd() {
  local nom="$1"; shift
  local unite="$HOME/.config/systemd/user/correspondance-$nom.service"
  mkdir -p "$HOME/.config/systemd/user"
  { echo "[Unit]"
    echo "Description=Correspondance — $nom (Relais un clic)"
    echo "After=network-online.target"
    echo
    echo "[Service]"
    printf 'ExecStart='; for a in "$@"; do printf "'%s' " "$a"; done; echo
    echo "Restart=always"
    echo "RestartSec=5"
    echo "StandardOutput=append:$LOGS/$nom.log"
    echo "StandardError=append:$LOGS/$nom.log"
    echo
    echo "[Install]"
    echo "WantedBy=default.target"
  } > "$unite"
  systemctl --user daemon-reload
  systemctl --user enable --now "correspondance-$nom.service" >/dev/null
  dire "service correspondance-$nom démarré (journal $LOGS/$nom.log)"
}

service() { if [ "$SYSTEME" = launchd ]; then service_launchd "$@"; else service_systemd "$@"; fi; }

if [ "$SYSTEME" = systemd ]; then
  # Sans linger, tout meurt à la déconnexion SSH — le piège classique du service
  # « 24/7 » qui s'arrête quand on ferme le terminal.
  if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo no)" = yes ]; then
    dire "linger déjà activé pour $(id -un)"
  elif loginctl enable-linger "$(id -un)" 2>/dev/null; then
    dire "linger activé pour $(id -un)"
  else
    echo "   (linger refusé sans privilège : lance « sudo loginctl enable-linger $(id -un) », sinon le Relais s'arrêtera à la déconnexion)"
  fi
fi

service relais "$BIN/continuwuity" -c "$RELAIS_DIR/continuwuity.toml"

# ================================================== 7. attendre, puis le compte
dire "attente du Relais sur $RELAIS"
pret=""
for _ in $(seq 1 60); do
  if curl -fsS -m 2 "$RELAIS/_matrix/client/versions" >/dev/null 2>&1; then pret=oui; break; fi
  sleep 1
done
[ -n "$pret" ] || { tail -20 "$LOGS/relais.log" 2>/dev/null >&2; mourir "le Relais ne répond pas sur $RELAIS"; }
dire "✓ le Relais répond ($(curl -fsS "$RELAIS/_continuwuity/server_version"))"

SESSION="$PREFIX/proprietaire.json"
jeton_session() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$SESSION"; }

if [ -f "$SESSION" ] && curl -fsS -H "Authorization: Bearer $(jeton_session)" \
     "$RELAIS/_matrix/client/v3/account/whoami" >/dev/null 2>&1; then
  dire "compte $MXID déjà là, session valide"
else
  # Piège : sur une base neuve, le registration_token du fichier de configuration
  # NE MARCHE PAS. Continuwuity tire un jeton d'amorçage à usage unique et ne le
  # dit que dans son journal.
  # Ce message arrive APRÈS que le port réponde, et le journal d'un service
  # (systemd « append: », launchd) n'est pas écrit à la même seconde : on attend
  # qu'il paraisse au lieu de lire une fois et de se tromper. Le défaut a existé :
  # sur le NUC, l'installeur tombait sur « Invalid registration token ».
  AMORCE=""
  for _ in $(seq 1 20); do
    AMORCE="$(python3 - "$LOGS/relais.log" <<'PY'
import re, sys
try:
    texte = open(sys.argv[1], errors="ignore").read()
except OSError:
    print(""); raise SystemExit
texte = re.sub(r"\x1b\[[0-9;]*m", "", texte)
trouves = re.findall(r"using the registration token (\S+)", texte)
print(trouves[-1] if trouves else "")
PY
)"
    [ -n "$AMORCE" ] && break
    sleep 1
  done
  JETON="$REGISTRATION_TOKEN"
  if [ -n "$AMORCE" ]; then
    dire "jeton d'amorçage relevé dans le journal du Relais"
    JETON="$AMORCE"
  else
    dire "aucun jeton d'amorçage dans le journal — on tente celui de la configuration"
  fi
  dire "enregistrement de $MXID"
  REPONSE="$(python3 "$OUTILS/enregistrer.py" "$RELAIS" "$USER_NAME" "$MATRIX_PASSWORD" "$JETON")"
  python3 -c 'import json,sys; sys.exit(0 if "access_token" in json.loads(sys.argv[1]) else 1)' "$REPONSE" \
    || mourir "enregistrement refusé : $REPONSE"
  ( umask 077; printf '%s\n' "$REPONSE" > "$SESSION" )
  chmod 600 "$SESSION"
  dire "✓ $MXID enregistré"
fi
JETON_PROPRIO="$(jeton_session)"

# ================================================================= 8. les ponts
if [ $PONTS = 1 ]; then
  pont() {
    local nom="$1" port="$2" prefixe="$3" bot="$4"
    local dir="$PREFIX/mautrix-$nom"
    mkdir -p "$dir"
    if [ ! -f "$dir/config.yaml" ]; then
      # On n'écrit QUE nos choix : le pont complète tout le reste lui-même à la
      # première lecture (son « config upgrade »). Pas de PyYAML à installer —
      # le python3 du système, sur macOS, n'a pas le module yaml.
      ( umask 077; cat > "$dir/config.yaml" <<CFG
homeserver:
    address: $RELAIS
    domain: $SERVER_NAME
    # Continuwuity n'est pas Synapse : « standard » est la valeur qui ne suppose
    # aucune extension propre à Synapse (ni API d'administration, ni double
    # puppeting par jeton partagé).
    software: standard
appservice:
    address: http://127.0.0.1:$port
    hostname: 127.0.0.1
    port: $port
    id: $nom
    bot:
        username: $bot
        displayname: $nom bridge bot
    username_template: ${nom}_{{.}}
database:
    type: sqlite3-fk-wal
    uri: file:$dir/$nom.db?_txlock=immediate
bridge:
    command_prefix: '$prefixe'
    personal_filtering_spaces: true
    private_chat_portal_meta: true
    permissions:
        '$SERVER_NAME': user
        '$MXID': admin
matrix:
    federate_rooms: false
# Le chiffrement des portails : le client Swift a une machine Olm depuis la
# phase 2, donc allow+default. « require » reste faux — l'exiger ferait taire le
# pont vis-à-vis de tout client sans machine crypto.
encryption:
    allow: true
    default: true
    require: false
    # Le pont chiffre pour tous les appareils du compte, vérifiés ou non : sans
    # ça, une app non vérifiée ne lirait jamais la réponse à « help ».
    allow_key_sharing: true
    verification_levels:
        receive: unverified
        send: unverified
        share: unverified
logging:
    min_level: info
    # Sans « writers », le pont n'écrit RIEN : le configurateur amont ne complète
    # pas cette liste quand la section existe, et zerolog se tait. Le journal du
    # service (launchd ou systemd) est la seule trace qu'on ait.
    writers:
        - type: stdout
          format: pretty
CFG
      )
      dire "mautrix-$nom : configuration écrite"
    else
      dire "mautrix-$nom : configuration déjà là, conservée"
    fi

    # `-g` retire de NOUVEAUX jetons dans config.yaml : le relancer sur une pile
    # déjà enregistrée fait répondre au pont « The as_token was not accepted »
    # jusqu'à ce qu'on ré-enregistre l'appservice. On ne le fait donc qu'une fois.
    if [ -f "$dir/registration.yaml" ]; then
      dire "mautrix-$nom : registration déjà là, jetons inchangés"
    else
      "$BIN/mautrix-$nom" -c "$dir/config.yaml" -g -r "$dir/registration.yaml" >/dev/null 2>&1 || true
      [ -f "$dir/registration.yaml" ] || mourir "mautrix-$nom : registration.yaml n'a pas été engendré"
      chmod 600 "$dir/registration.yaml" "$dir/config.yaml"
      dire "mautrix-$nom : registration engendrée"
      # Chez Synapse une registration est un fichier listé dans homeserver.yaml,
      # relu au démarrage. Chez Continuwuity c'est un message dans #admins, pris
      # en compte à chaud. Réenregistrer le même id remplace l'ancien.
      commande="$(printf '!admin appservices register\n```\n%s\n```' "$(cat "$dir/registration.yaml")")"
      reponse="$(python3 "$OUTILS/salon-admin.py" "$RELAIS" "$JETON_PROPRIO" "$SERVER_NAME" "$commande")"
      dire "appservice $nom : $(printf '%s' "$reponse" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reponse","?").splitlines()[-1])')"
    fi
    service "mautrix-$nom" "$BIN/mautrix-$nom" -c "$dir/config.yaml"
  }
  pont whatsapp "$WA_PORT" '!wa' whatsappbot
  pont signal "$SG_PORT" '!signal' signalbot
fi

# ================================================== 9. la preuve, pas la promesse
# Un mot de passe neuf, reposé par #admins. Sans --logout, les sessions ouvertes
# survivent : c'est l'équivalent du logout_devices:false de Synapse, ce qui évite
# de tuer un agent qui tourne ailleurs.
NOUVEAU="$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(24)))')"
python3 "$OUTILS/salon-admin.py" "$RELAIS" "$JETON_PROPRIO" "$SERVER_NAME" \
  "!admin users reset-password $USER_NAME $NOUVEAU" >/dev/null \
  || mourir "la repose du mot de passe par #admins a échoué"
python3 - "$SECRETS" "$NOUVEAU" <<'PY'
import pathlib, sys
f = pathlib.Path(sys.argv[1])
lignes = [l for l in f.read_text().splitlines() if not l.startswith("MATRIX_PASSWORD=")]
f.write_text("\n".join(lignes + [f"MATRIX_PASSWORD={sys.argv[2]}"]) + "\n")
PY

CONNEXION="$(curl -fsS -X POST "$RELAIS/_matrix/client/v3/login" -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"type":"m.login.password","identifier":{"type":"m.id.user","user":sys.argv[1]},"password":sys.argv[2],"initial_device_display_name":"preuve installeur"}))' "$USER_NAME" "$NOUVEAU")")" \
  || mourir "le /login de preuve a échoué"
JETON_PREUVE="$(printf '%s' "$CONNEXION" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
[ -n "$JETON_PREUVE" ] || mourir "le Relais n'a pas rendu de jeton : $CONNEXION"
QUI="$(curl -fsS -H "Authorization: Bearer $JETON_PREUVE" "$RELAIS/_matrix/client/v3/account/whoami" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("user_id",""))')"
[ "$QUI" = "$MXID" ] || mourir "whoami dit « $QUI », on attendait $MXID"
# On referme la session de preuve : elle a servi, elle ne doit pas traîner.
curl -fsS -X POST -H "Authorization: Bearer $JETON_PREUVE" "$RELAIS/_matrix/client/v3/logout" >/dev/null 2>&1 || true

echo
echo "✓ le Relais répond, connecté comme $QUI (/login puis /account/whoami)."
if [ $PONTS = 1 ]; then
  echo "  Ponts : mautrix-whatsapp sur $WA_PORT, mautrix-signal sur $SG_PORT — portails chiffrés."
fi
echo "  $TS_MOT"

python3 "$OUTILS/appairage.py" "$PUBLIC" "$SERVER_NAME" "$USER_NAME" "$NOUVEAU"
echo
if [ "$SYSTEME" = launchd ]; then
  echo "  Le Relais revient tout seul : launchctl kickstart -k gui/$(id -u)/app.correspondance.relais"
else
  echo "  Le Relais revient tout seul : systemctl --user restart correspondance-relais"
fi
echo "  Tout retirer : bash uninstall.sh --prefix $PREFIX"
