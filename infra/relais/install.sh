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
#   --sans-tailcat        ne pose pas Tailcat sur Linux (l'adresse du code sera
#                         alors celle de Tailscale, ou 127.0.0.1 et un tunnel ssh)
#   --json                une ligne JSON par étape, et le code d'appairage en
#                         dernier objet — le mode que l'app lit quand c'est
#                         elle qui lance l'installeur (carte « Sur ce Mac »)
#
# Comment on joint ce Relais depuis un autre poste. Un homeserver ouvert sur
# l'Internet est une porte : celui-ci n'écoute que sur 127.0.0.1. Sur Linux,
# l'installeur pose donc **Tailcat** à côté de lui — le plan de données de
# Tailscale (WireGuard, traversée de NAT, DERP en repli) sans son plan de
# contrôle : ni compte, ni tailnet, ni démon privilégié, ni sudo. Le jeton qu'il
# publie entre dans le code d'appairage, et le Mac s'y connecte tout seul.
#
# Tailscale devient un **repli** : s'il est là, le code porte aussi son adresse ;
# l'installeur ne l'installe toujours pas (ça demande sudo). C'est l'iPhone qui
# en a encore besoin — Tailcat y demande un tailcat embarqué, que nous n'avons
# pas (docs/spike-un-clic/phase-7a.md § 3).
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
TAILCAT=1
JSON=0

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
    --sans-tailcat) TAILCAT=0 ;;
    --json) JSON=1 ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
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
# Instagram et Messenger sont le MÊME dépôt (mautrix/meta) et le même tag, mais deux
# binaires : depuis v26.08 un binaire ne fait plus qu'un réseau. `mautrix-instagram-*`
# est Instagram ; `mautrix-meta-*`, sans préfixe, est Messenger (il se dit
# « mautrix-facebook »). Deux processus, deux bases, deux salons de gestion —
# rien ne se partage, pas même la session Meta (cf. infra/matrix/docker-compose.yml).
META_AMONT="https://github.com/mautrix/meta/releases/download/$MAUTRIX_TAG"
# Tailcat : l'amont publie Linux (amd64/arm64/armv7) et Windows, **pas macOS** —
# là-bas il passe par un tap Homebrew, que le spike s'interdit dans la pile
# livrée. Le binaire macOS est donc le NÔTRE, construit au même tag par
# infra/relais/construire.sh ; mais sur macOS le Relais n'a de toute façon pas
# besoin de Tailcat — l'app est sur la même machine que lui.
TAILCAT_TAG=v0.4.0
TAILCAT_AMONT="https://github.com/tailscale/tailcat/releases/download/$TAILCAT_TAG"

case "$HOTE" in
  macos-arm64)
    RELAIS_URL_BIN="$RELEASES/continuwuity-macos-arm64"
    RELAIS_SHA=3851299c77ea1ecade76077d66f1646dca0237ee96753d1cb6364fa2b6ce2ff9
    # Les ponts macOS viennent de NOTRE publication depuis la phase 6 : mêmes
    # sources, même tag, mais construits avec `-tags goolm`. libolm — abandonnée
    # amont en 2024 pour faiblesses cryptographiques, et retirée de Homebrew —
    # disparaît de la pile : `otool -L` ne la nomme plus, il n'y a plus de dylib
    # à poser, ni à signer, ni à notariser (infra/relais/construire.sh).
    WA_URL="$RELEASES/mautrix-whatsapp-darwin-arm64"
    WA_SHA=0b4d4bde775c73f6b5803f9dc048d51acee9de4a7593e6af6473b18fff769b11
    SG_URL="$RELEASES/mautrix-signal-darwin-arm64"
    SG_SHA=d85c48ffd92b8deb28748b54409ac3cd71019fe099ab9ad10b8e98f4e846f6f4
    IG_URL="$RELEASES/mautrix-instagram-darwin-arm64"
    IG_SHA=763f1cab3fcddee73e8c96eb408d73afc2e2461a4db4d1c790b4ceab01254b31
    MS_URL="$RELEASES/mautrix-meta-darwin-arm64"
    MS_SHA=bad1ef2d9e73d4e4a27f7def37070d2531aeddb95c57f3a9971c9baa6d3af5f1
    TAILCAT_URL=""; TAILCAT_SHA=""; TAILCAT_ARCHIVE=""
    OLM_URL=""; OLM_SHA=""
    ;;
  linux-x86_64)
    RELAIS_URL_BIN="$AMONT_CONTINUWUITY/conduwuit-linux-static-amd64"
    RELAIS_SHA=43bcf0e41a60219fe96673e6ed7c041cca1aee42d1758bfeccb571f89f4ed02d
    WA_URL="https://github.com/mautrix/whatsapp/releases/download/$MAUTRIX_TAG/mautrix-whatsapp-amd64"
    WA_SHA=dc519ea63f34dd0b0b33bffda1dc671360ba9e7f806d77ba9849b9586540e4f5
    SG_URL="https://github.com/mautrix/signal/releases/download/$MAUTRIX_TAG/mautrix-signal-amd64"
    SG_SHA=ab373049f98c3f1b48b3a386bc91166be401eda61176e2d528902f5d22c47afa
    IG_URL="$META_AMONT/mautrix-instagram-amd64"
    IG_SHA=229586e3e629e928a7f3ec9dbc490c48125b23135c93e0bf04a7d53f2b0b4de9
    MS_URL="$META_AMONT/mautrix-meta-amd64"
    MS_SHA=e861777b51f0e15959e66f0efc0c68b88e1bd1093b09737358b4af7dafd7e6cc
    TAILCAT_ARCHIVE="tailcat_0.4.0_linux_amd64.tar.gz"
    TAILCAT_URL="$TAILCAT_AMONT/$TAILCAT_ARCHIVE"
    TAILCAT_SHA=8b819c43dfdf806b5663e23535aba557bb106075b0b5839df289af9bba70bec2
    OLM_URL=""; OLM_SHA=""
    ;;
  linux-arm64)
    RELAIS_URL_BIN="$AMONT_CONTINUWUITY/conduwuit-linux-static-arm64"
    RELAIS_SHA=28d0a92c4e5da57db878f6002d66ffbc1be997da8313cd78a8cebe44e9a38c15
    WA_URL="https://github.com/mautrix/whatsapp/releases/download/$MAUTRIX_TAG/mautrix-whatsapp-arm64"
    WA_SHA=fb2872d5c3b4b3d1184ba5971a9940115f404acfe17aa9a74ce470ee1b2c5c11
    SG_URL="https://github.com/mautrix/signal/releases/download/$MAUTRIX_TAG/mautrix-signal-arm64"
    SG_SHA=ca8bc4a741e4bfb41334d803c188bcdb18845b2412ed0e9db8de1aa77dccd368
    IG_URL="$META_AMONT/mautrix-instagram-arm64"
    IG_SHA=8d130e30b5da0f2eeef21b92327ebee283d84b7d36b3ecc6960f3a331b0f4cad
    MS_URL="$META_AMONT/mautrix-meta-arm64"
    MS_SHA=5b76822b9ae445fb6fd644a09a12f619e4abc1216a887415d6500e65f61b64fe
    TAILCAT_ARCHIVE="tailcat_0.4.0_linux_arm64.tar.gz"
    TAILCAT_URL="$TAILCAT_AMONT/$TAILCAT_ARCHIVE"
    TAILCAT_SHA=3b77322350f64d229d5b2119b159b863b4bcffa0a62a0294682423a19956dc76
    OLM_URL=""; OLM_SHA=""
    ;;
  *) echo "!! hôte inconnu : $HOTE" >&2; exit 2 ;;
esac

WA_PORT=$((PORT + 21308))   # 8010 → 29318 : les ports de la phase 1
SG_PORT=$((PORT + 21318))
IG_PORT=$((PORT + 21320))   # 8010 → 29330 : les ports du docker-compose de la prod
MS_PORT=$((PORT + 21321))   # 8010 → 29331
BIN="$PREFIX/bin"
RELAIS_DIR="$PREFIX/relais"
LOGS="$PREFIX/logs"
OUTILS="$PREFIX/outils"
RELAIS="http://127.0.0.1:$PORT"
MXID="@$USER_NAME:$SERVER_NAME"
case "$HOTE" in macos-*) SYSTEME=launchd ;; *) SYSTEME=systemd ;; esac

dire() { printf '→ %s\n' "$*"; }

# Le mode machine : une ligne JSON par étape, rien d'autre sur cette ligne.
# Les phrases pour l'humain continuent de sortir telles quelles — un flux JSON
# qui se mélange à du texte se lit très bien ligne par ligne, alors qu'un
# installeur muet en mode humain serait une seconde chose à éprouver.
# `etape NOM ETAT [DETAIL]` ; ETAT vaut debut, ok ou erreur.
etape() {
  [ "$JSON" = 1 ] || return 0
  python3 -c 'import json,sys; print(json.dumps({"etape":sys.argv[1],"etat":sys.argv[2],"detail":sys.argv[3]}, ensure_ascii=False), flush=True)' \
    "$1" "$2" "${3:-}"
}

# Un échec doit sortir DANS le flux, pas seulement sur stderr : sans ça l'app
# voit le processus mourir sans savoir sur quoi, et n'a que « code 1 » à dire.
mourir() { etape "${ETAPE_COURANTE:-installation}" erreur "$*"; printf '✗ %s\n' "$*" >&2; exit 1; }
somme() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
          else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# ----------------------------------------------------- l'adresse que l'app verra
#
# Trois chemins possibles vers un Relais qui n'écoute que sur 127.0.0.1, et
# l'ordre entre eux est une décision, pas un hasard :
#
#   1. **Tailcat**, posé par cet installeur, sans compte et sans sudo. C'est le
#      chemin par défaut sur Linux depuis la phase 7b : le code d'appairage
#      porte son jeton, et le Mac s'y connecte tout seul.
#   2. **Tailscale**, s'il est déjà là. Repli, et le seul chemin que l'iPhone
#      sache prendre aujourd'hui. Cet installeur ne le pose pas : ça demande sudo.
#   3. `ssh -N -L`, quand il n'y a ni l'un ni l'autre. Un terminal, une clé, une
#      commande que personne ne retape — d'où les deux premiers.
#
# Le code porte les deux quand les deux existent : `homeserver` est l'adresse
# ordinaire (Tailscale, ou 127.0.0.1) et `tailcat` le jeton. Une app qui ne
# connaît pas le champ `tailcat` retombe donc sur l'adresse, et une app qui le
# connaît n'a besoin de rien d'autre.
TAILCAT_ACTIF=0
if [ "$TAILCAT" = 1 ] && [ -n "$TAILCAT_URL" ]; then TAILCAT_ACTIF=1; fi

TS_IP=""
TS_MOT=""
if [ "$SYSTEME" = systemd ]; then
  if command -v tailscale >/dev/null 2>&1; then
    TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  fi
  if [ "$TAILCAT_ACTIF" = 1 ] && [ -n "$TS_IP" ]; then
    TS_MOT="Tailcat est posé : le code portera son jeton, et le Mac s'y connectera tout seul. Tailscale est là aussi — le code portera http://$TS_IP:$PORT en repli, et c'est cette adresse-là dont l'iPhone a encore besoin."
  elif [ "$TAILCAT_ACTIF" = 1 ]; then
    TS_MOT="Tailcat est posé : le code portera son jeton, et le Mac s'y connectera tout seul, sans tunnel ssh et sans Tailscale. L'iPhone, lui, a encore besoin de Tailscale (curl -fsSL https://tailscale.com/install.sh | sh, puis sudo tailscale up) : il n'embarque pas Tailcat."
  elif [ -n "$TS_IP" ]; then
    TS_MOT="Tailcat écarté (--sans-tailcat). Tailscale est là : le code portera http://$TS_IP:$PORT, et le Relais écoutera aussi sur cette adresse."
  else
    TS_MOT="Tailcat écarté (--sans-tailcat) et Tailscale absent — cet installeur ne pose pas Tailscale (ça demande sudo : curl -fsSL https://tailscale.com/install.sh | sh, puis sudo tailscale up). Le code portera http://127.0.0.1:$PORT — joignable depuis un autre poste par : ssh -N -L $PORT:127.0.0.1:$PORT <cette machine>."
  fi
else
  TS_MOT="macOS : ni Tailcat ni Tailscale ne sont posés, et aucun n'est requis. Le Relais et l'app sont sur la même machine, le code portera http://127.0.0.1:$PORT."
fi
if [ -n "$TS_IP" ]; then PUBLIC="http://$TS_IP:$PORT"; BINDS="\"$BIND\", \"$TS_IP\""; else PUBLIC="$RELAIS"; BINDS="\"$BIND\""; fi

# Le dossier de Tailcat : sa clé (persistante — un jeton qui changerait à chaque
# redémarrage périmerait tous les codes déjà émis), et le fichier où le serveur
# écrit son adresse à chaque démarrage.
TAILCAT_DIR="$PREFIX/tailcat"
TAILCAT_CLE="$TAILCAT_DIR/relais.private.json"
TAILCAT_ADRESSE="$TAILCAT_DIR/adresse"
TAILCAT_JETON=""

# ------------------------------------------------------------------ le plan
plan() {
  echo "Plan d'installation du Relais Correspondance"
  echo "  hôte              $HOTE ($SYSTEME)"
  echo "  dossier           $PREFIX"
  echo "  serveur Matrix    $SERVER_NAME, propriétaire $MXID"
  echo "  écoute            $BIND:$PORT ; ponts sur $WA_PORT (WhatsApp), $SG_PORT (Signal),"
  echo "                    $IG_PORT (Instagram) et $MS_PORT (Messenger)"
  if [ "$TAILCAT_ACTIF" = 1 ]; then
    echo "  adresse du code   $PUBLIC, plus le jeton Tailcat (le chemin par défaut)"
  else
    echo "  adresse du code   $PUBLIC"
  fi
  echo
  echo "  1. Prérequis : curl, python3, un calcul de sha256. Aucun sudo, aucun Docker, aucun Homebrew."
  echo "  2. Binaires, épinglés et vérifiés par sha256 (rien n'est installé si une somme diffère) :"
  echo "       continuwuity $CONTINUWUITY_TAG"
  echo "         $RELAIS_URL_BIN"
  echo "         sha256 $RELAIS_SHA"
  if [ "$TAILCAT_ACTIF" = 1 ]; then
    echo "       tailcat $TAILCAT_TAG (archive, le binaire en est extrait)"
    echo "         $TAILCAT_URL"
    echo "         sha256 $TAILCAT_SHA"
  fi
  if [ $PONTS = 1 ]; then
    echo "       mautrix-whatsapp $MAUTRIX_TAG"
    echo "         $WA_URL"
    echo "         sha256 $WA_SHA"
    echo "       mautrix-signal $MAUTRIX_TAG"
    echo "         $SG_URL"
    echo "         sha256 $SG_SHA"
    echo "       mautrix-instagram $MAUTRIX_TAG (dépôt mautrix/meta)"
    echo "         $IG_URL"
    echo "         sha256 $IG_SHA"
    echo "       mautrix-messenger $MAUTRIX_TAG (dépôt mautrix/meta, binaire mautrix-meta)"
    echo "         $MS_URL"
    echo "         sha256 $MS_SHA"
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
  if [ "$TAILCAT_ACTIF" = 1 ]; then
    echo "  5 bis. Tailcat : clé persistante dans $TAILCAT_CLE (0600, tirée une seule fois),"
    echo "       service correspondance-tailcat devant le port $PORT du Relais, et le jeton relu"
    echo "       dans $TAILCAT_ADRESSE — le serveur l'y écrit à chaque démarrage (TAILCAT_ADDR_FILE),"
    echo "       ce qui est la seule source juste : la région DERP se choisit au démarrage, donc"
    echo "       le jeton de genkey n'est pas celui que le serveur publie."
  fi
  echo "  6. Attente que $RELAIS/_matrix/client/versions réponde."
  echo "  7. Compte propriétaire $MXID par /register — avec le jeton d'AMORÇAGE que Continuwuity"
  echo "     n'écrit que dans son journal (celui du .toml ne marche pas sur une base neuve)."
  echo "     Le premier compte enregistré devient administrateur et rejoint #admins."
  if [ $PONTS = 1 ]; then
    echo "  8. Configuration des quatre ponts (SQLite, chiffrement des portails allow+default),"
    echo "     registration engendrée par le pont lui-même, puis déclarée au Relais par un message"
    echo "     « !admin appservices register » dans #admins — Continuwuity n'a pas de fichier de"
    echo "     registration, et la prend en compte à chaud."
    echo "  9. Services des ponts, démarrés APRÈS l'enregistrement de l'appservice."
  fi
  echo " 10. Preuve : /login avec le mot de passe du code, puis /account/whoami — « connecté comme $MXID »."
  if [ "$TAILCAT_ACTIF" = 1 ]; then
    echo " 11. Code d'appairage correspondance://relais/… — adresse $PUBLIC ET jeton Tailcat —"
    echo "     + ses six mots de vérification, qui ne changent pas (ils nomment le Relais, pas le jeton)."
  else
    echo " 11. Code d'appairage correspondance://relais/… + ses six mots de vérification."
  fi
  echo
  echo "  Le chemin depuis un autre poste : $TS_MOT"
}

if [ "$DRY" = 1 ]; then
  plan
  echo
  echo "  (--dry-run : rien n'a été exécuté)"
  exit 0
fi

# ============================================================ 1. les prérequis
ETAPE_COURANTE=prerequis
etape prerequis debut "curl, python3, sha256 — aucun sudo, aucun Docker"
command -v curl >/dev/null || mourir "curl est nécessaire"
command -v python3 >/dev/null || mourir "python3 est nécessaire (il lit le jeton et parle à #admins)"
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
  || mourir "ni sha256sum ni shasum : impossible de vérifier les binaires"

etape prerequis ok "$HOTE — tout vit sous $PREFIX"
dire "hôte $HOTE — tout vit sous $PREFIX"
mkdir -p "$BIN" "$RELAIS_DIR/db" "$LOGS" "$OUTILS"
chmod 700 "$PREFIX"
: > "$PREFIX/.correspondance-relais"   # la marque que uninstall.sh exige avant d'effacer

# ============================================================== 2. les binaires
ETAPE_COURANTE=binaires
etape binaires debut "continuwuity $CONTINUWUITY_TAG et les ponts mautrix $MAUTRIX_TAG, sha256 vérifié"
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

# Tailcat est publié en archive, pas en binaire nu : on vérifie la somme de
# l'archive AVANT de la déplier, jamais après — déplier une archive qu'on n'a pas
# vérifiée, c'est écrire sur le disque ce qu'on voulait refuser.
poser_tailcat() {
  if [ -f "$BIN/tailcat" ] && "$BIN/tailcat" version 2>/dev/null | grep -q "${TAILCAT_TAG#v}"; then
    dire "tailcat déjà posé ($("$BIN/tailcat" version 2>/dev/null | head -1))"
    return
  fi
  local tmp; tmp="$(mktemp -d)"
  dire "tailcat ← $TAILCAT_URL"
  curl -fsSL -o "$tmp/$TAILCAT_ARCHIVE" "$TAILCAT_URL" \
    || { rm -rf "$tmp"; mourir "tailcat : téléchargement impossible ($TAILCAT_URL)"; }
  local vu; vu="$(somme "$tmp/$TAILCAT_ARCHIVE")"
  [ "$vu" = "$TAILCAT_SHA" ] || { rm -rf "$tmp"; mourir "tailcat : sha256 $vu ≠ $TAILCAT_SHA — on n'installe rien"; }
  tar xzf "$tmp/$TAILCAT_ARCHIVE" -C "$tmp" || { rm -rf "$tmp"; mourir "tailcat : archive illisible"; }
  [ -f "$tmp/tailcat" ] || { rm -rf "$tmp"; mourir "tailcat : l'archive ne porte pas de binaire « tailcat »"; }
  mv "$tmp/tailcat" "$BIN/tailcat"
  chmod 755 "$BIN/tailcat"
  rm -rf "$tmp"
  dire "tailcat : sha256 $vu ✓ ($("$BIN/tailcat" version 2>/dev/null | head -1))"
}

poser continuwuity "$RELAIS_URL_BIN" "$RELAIS_SHA"
[ "$TAILCAT_ACTIF" = 1 ] && poser_tailcat
if [ $PONTS = 1 ]; then
  [ -n "$OLM_URL" ] && poser libolm.3.dylib "$OLM_URL" "$OLM_SHA"
  poser mautrix-whatsapp "$WA_URL" "$WA_SHA"
  poser mautrix-signal "$SG_URL" "$SG_SHA"
  poser mautrix-instagram "$IG_URL" "$IG_SHA"
  poser mautrix-messenger "$MS_URL" "$MS_SHA"
fi
etape binaires ok "posés dans $BIN, toutes les sommes conformes"

# =============================================================== 3. les secrets
ETAPE_COURANTE=secrets
etape secrets debut "tirés une fois, jamais réécrits"
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
etape secrets ok "$SECRETS (0600)"

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

    appairage.py <url publique> <serveur> <utilisateur> <mot de passe> [json] [jeton tailcat]

Format de RelayPairingCode (Packages/CorrespondanceCore/…/RelayPairingCode.swift)
et de infra/matrix/pair.sh : un JSON compact trié, en base64 URL-safe sans
remplissage, derrière `correspondance://relais/`.

Le champ `tailcat` est **facultatif**, et absent quand il n'y a pas de jeton :
un code d'hier se relit tel quel, et un code d'aujourd'hui reste lisible par une
app d'hier, qui ignorera ce champ et prendra l'adresse. Les six mots de
vérification ne le voient pas — ils nomment le Relais, pas le chemin.
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
en_json = len(sys.argv) > 5 and sys.argv[5] == "1"
tailcat = sys.argv[6] if len(sys.argv) > 6 else ""
charge = {"v": 1, "homeserver": url, "server": serveur, "user": utilisateur,
          "password": mot_de_passe, "exp": time.time() + DUREE}
if tailcat:
    charge["tailcat"] = tailcat
brut = json.dumps(charge, separators=(",", ":"), sort_keys=True).encode()
jeton = base64.b64encode(brut).decode().replace("+", "-").replace("/", "_").rstrip("=")
code = f"correspondance://relais/{jeton}"
six = mots(f"{url}|{serveur}|@{utilisateur}:{serveur}")
if en_json:
    # Le DERNIER objet du flux, et le seul qui porte « code » : c'est à ce
    # champ que l'app reconnaît la fin, pas au nom de l'étape — une étape
    # nommée « appairage » sans code la ferait se croire prête.
    print(json.dumps({"etape": "appairage", "etat": "ok", "code": code, "mots": six,
                      "tailcat": bool(tailcat)},
                     ensure_ascii=False), flush=True)
print()
print("  Relais prêt. Dans Correspondance : « Connecter un Relais », puis colle ce code.")
print()
print(f"  {code}")
print()
print(f"  Vérification (six mots) : {' '.join(six)}")
if tailcat:
    print("  Ce code porte un jeton Tailcat : le Mac joindra ce Relais sans tunnel ssh")
    print("  et sans Tailscale. Il porte aussi un mot de passe : ne le poste nulle part.")
    print("  Il périme dans 15 minutes.")
else:
    print("  Il périme dans 15 minutes. Il contient un mot de passe : ne le poste nulle part.")
PYPAIR

# ========================================================= 5. le homeserver
# Écrit une seule fois : le .toml porte le jeton d'enregistrement, et la base
# RocksDB a été créée avec ce server_name. Relancer l'installeur ne le réécrit
# pas — c'est ce qui rend l'opération rejouable sans casser l'existant.
ETAPE_COURANTE=configuration
etape configuration debut "$SERVER_NAME, écoute $BIND:$PORT"
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

# Rien à autoriser pour la passerelle push. Vérifié dans le code de
# Continuwuity 26.8.1 (src/service/pusher/mod.rs), parce que la question se
# posait vraiment :
#   — il n'existe AUCUNE liste d'autorisation d'URL de passerelle. `set_pusher`
#     ne valide que la forme : URL analysable, schéma http ou https ;
#   — `allow_federation = false` ne coupe PAS le push. Le garde de la fédération
#     est dans src/service/federation/execute.rs, en aval ; le push part par un
#     client reqwest distinct (services.client.pusher) et les workers du service
#     `sending` démarrent inconditionnellement. C'était l'inquiétude légitime :
#     dans Conduit, fédération et push partagent la même file d'attente. Ils la
#     partagent toujours, mais pas le garde ;
#   — le seul vrai garde est `ip_range_denylist`, dont le défaut contient
#     100.64.0.0/10 — la plage CGNAT de Tailscale. Une passerelle push sur une
#     adresse 100.x ou en LAN serait refusée, à l'enregistrement si l'URL porte
#     l'IP, et à l'envoi dans tous les cas (le test est refait sur l'IP
#     réellement connectée). C'est précisément pourquoi la passerelle est un nom
#     public en HTTPS et non l'adresse Tailscale du NUC.
# Piège annexe, non documenté : send_request retire `notification_push_path` de
# l'URL déclarée avant que ruma ne le rajoute. L'URL du pusher DOIT donc finir
# par /_matrix/push/v1/notify — ce que fait PushRegistration.defaultGateway.

log = "info"
log_colors = false
TOML
  )
  chmod 600 "$RELAIS_DIR/continuwuity.toml"
  dire "écrit $RELAIS_DIR/continuwuity.toml"
else
  dire "$RELAIS_DIR/continuwuity.toml déjà là, conservé"
fi
etape configuration ok "$RELAIS_DIR/continuwuity.toml"

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

ETAPE_COURANTE=services
etape services debut "$SYSTEME"
service relais "$BIN/continuwuity" -c "$RELAIS_DIR/continuwuity.toml"

# ------------------------------------------------------------------- Tailcat
# Il se met devant le port du Relais, et rien d'autre : `serve $PORT` n'ouvre
# que celui-là. Pas de nœud de sortie, pas de SSH, pas de service de fichiers.
if [ "$TAILCAT_ACTIF" = 1 ]; then
  mkdir -p "$TAILCAT_DIR"
  chmod 700 "$TAILCAT_DIR"
  if [ -f "$TAILCAT_CLE" ]; then
    dire "tailcat : clé déjà là, conservée (le jeton des codes déjà émis reste valable)"
  else
    # `--key` avec une barre oblique est un CHEMIN : la clé vit sous le dossier
    # du Relais, pas dans ~/.config/tailcat/keys/ — un désinstalleur qui efface
    # le dossier doit tout emporter.
    ( umask 077; "$BIN/tailcat" genkey --key="$TAILCAT_CLE" >/dev/null 2>>"$LOGS/tailcat.log" ) \
      || mourir "tailcat : genkey a échoué (voir $LOGS/tailcat.log)"
    chmod 600 "$TAILCAT_CLE"
    dire "tailcat : clé tirée dans $TAILCAT_CLE (0600)"
  fi
  # Une enveloppe plutôt qu'un `Environment=` dans l'unité : elle dit à quoi sert
  # la variable, et elle est la même quel que soit le gestionnaire de services.
  cat > "$TAILCAT_DIR/servir.sh" <<TCSH
#!/usr/bin/env bash
# Écrit par infra/relais/install.sh. TAILCAT_ADDR_FILE fait écrire au serveur
# l'adresse qu'il publie, à chaque démarrage : c'est la seule source juste du
# jeton, parce que la région DERP se choisit au démarrage et non à la génération
# de la clé.
export TAILCAT_ADDR_FILE="$TAILCAT_ADRESSE"
exec "$BIN/tailcat" serve --key="$TAILCAT_CLE" $PORT
TCSH
  chmod 700 "$TAILCAT_DIR/servir.sh"
  rm -f "$TAILCAT_ADRESSE"
  service tailcat "$TAILCAT_DIR/servir.sh"
  # `enable --now` ne redémarre PAS une unité déjà active : sans ce restart, une
  # seconde exécution attendrait quarante secondes une adresse que personne ne
  # réécrit, et conclurait à tort que Tailcat n'a rien publié.
  systemctl --user restart correspondance-tailcat.service >/dev/null 2>&1 || true
fi
etape services ok "le Relais est un service $SYSTEME : il revient au démarrage de la session"

# ================================================== 7. attendre, puis le compte
ETAPE_COURANTE=attente
etape attente debut "$RELAIS"
dire "attente du Relais sur $RELAIS"
pret=""
for _ in $(seq 1 60); do
  if curl -fsS -m 2 "$RELAIS/_matrix/client/versions" >/dev/null 2>&1; then pret=oui; break; fi
  sleep 1
done
[ -n "$pret" ] || { tail -20 "$LOGS/relais.log" 2>/dev/null >&2; mourir "le Relais ne répond pas sur $RELAIS"; }
VERSION_VUE="$(curl -fsS "$RELAIS/_continuwuity/server_version")"
etape attente ok "$VERSION_VUE"
dire "✓ le Relais répond ($VERSION_VUE)"

if [ "$TAILCAT_ACTIF" = 1 ]; then
  ETAPE_COURANTE=tailcat
  etape tailcat debut "le jeton que le code d'appairage portera"
  # Le serveur sonde les régions DERP avant de publier son adresse : quelques
  # secondes, parfois. On attend le fichier plutôt que de lire une fois et de
  # se tromper — le même défaut que le jeton d'amorçage du journal, plus haut.
  for _ in $(seq 1 40); do
    [ -s "$TAILCAT_ADRESSE" ] && break
    sleep 1
  done
  if [ -s "$TAILCAT_ADRESSE" ]; then
    TAILCAT_JETON="$(tr -d " \t\r\n" < "$TAILCAT_ADRESSE")"
    etape tailcat ok "jeton de ${#TAILCAT_JETON} caractères — le Mac se connectera sans tunnel ssh et sans Tailscale"
    dire "✓ tailcat publie ${TAILCAT_JETON:0:12}… ($(wc -c < "$TAILCAT_ADRESSE" | tr -d " ") octets)"
  else
    # Pas un échec : le Relais est joignable autrement. On le dit, on continue.
    # `erreur` et non `ok` : l'étape a échoué, et le dire faux serait pire que
    # de le dire. L'installation continue — le Relais reste joignable par son
    # adresse — et le code d'appairage qui suit le prouve.
    etape tailcat erreur "tailcat n'a pas publié d'adresse — le code portera $PUBLIC seul"
    dire "tailcat n'a pas publié d'adresse en 40 s ; le code portera $PUBLIC seul (voir $LOGS/tailcat.log)"
    TS_MOT="Tailcat n'a pas publié d'adresse — le code porte $PUBLIC. Journal : $LOGS/tailcat.log"
  fi
fi

ETAPE_COURANTE=compte
etape compte debut "$MXID"
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
etape compte ok "$MXID"
JETON_PROPRIO="$(jeton_session)"

# ================================================================= 8. les ponts
if [ $PONTS = 1 ]; then
  ETAPE_COURANTE=ponts
  etape ponts debut "WhatsApp, Signal, Instagram, Messenger — portails chiffrés"
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
  # Les préfixes et les noms de bot sont ceux que l'app reconnaît mot pour mot
  # (MatrixBridgeDescriptor) : `!ig`/instagrambot et `!fb`/messengerbot, comme
  # les gabarits de infra/matrix/templates/.
  pont instagram "$IG_PORT" '!ig' instagrambot
  pont messenger "$MS_PORT" '!fb' messengerbot
  etape ponts ok "quatre ponts enregistrés et démarrés ($WA_PORT, $SG_PORT, $IG_PORT, $MS_PORT)"
fi

# ================================================== 9. la preuve, pas la promesse
# Un mot de passe neuf, reposé par #admins. Sans --logout, les sessions ouvertes
# survivent : c'est l'équivalent du logout_devices:false de Synapse, ce qui évite
# de tuer un agent qui tourne ailleurs.
ETAPE_COURANTE=preuve
etape preuve debut "/login puis /account/whoami"
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

etape preuve ok "connecté comme $QUI"
echo
echo "✓ le Relais répond, connecté comme $QUI (/login puis /account/whoami)."
if [ $PONTS = 1 ]; then
  echo "  Ponts : WhatsApp $WA_PORT, Signal $SG_PORT, Instagram $IG_PORT, Messenger $MS_PORT — portails chiffrés."
fi
echo "  $TS_MOT"

ETAPE_COURANTE=appairage
python3 "$OUTILS/appairage.py" "$PUBLIC" "$SERVER_NAME" "$USER_NAME" "$NOUVEAU" "$JSON" "$TAILCAT_JETON"
echo
if [ "$SYSTEME" = launchd ]; then
  echo "  Le Relais revient tout seul : launchctl kickstart -k gui/$(id -u)/app.correspondance.relais"
else
  echo "  Le Relais revient tout seul : systemctl --user restart correspondance-relais"
  if [ "$TAILCAT_ACTIF" = 1 ]; then
    echo "  Le chemin aussi : systemctl --user restart correspondance-tailcat"
  fi
fi
echo "  Tout retirer : bash uninstall.sh --prefix $PREFIX"
