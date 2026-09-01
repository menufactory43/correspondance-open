#!/usr/bin/env bash
# Installe un Relais Correspondance — Synapse, les ponts, et le code d'appairage
# que l'app sait lire.
#
#   infra/matrix/install.sh --target this-mac
#   infra/matrix/install.sh --target linux
#   infra/matrix/install.sh --target ssh --host nuc
#   infra/matrix/install.sh --target ssh --host vps --dry-run   # montre sans faire
#
# Trois hôtes, une commande, une même fin : le code d'appairage. C'est lui qui
# fait le « un clic » — pas l'absence de terminal, mais l'absence de recopie.
#
# CE SCRIPT NE RÉÉCRIT PAS `bootstrap.sh`. Celui-là tourne sur un vrai Relais en
# production : il reste la pièce qui pose Synapse et les ponts, et on l'appelle.
# Ici on fait ce qu'il ne fait pas — détecter l'hôte, poser les prérequis
# (moteur de conteneurs, Tailscale), poser l'adaptateur ACP épinglé, et finir
# sur le code d'appairage.
#
# `--dry-run` imprime le plan sans rien exécuter : c'est la partie qu'on peut
# éprouver sans machine cible, et `infra/matrix/tests/install-plan.sh` le fait.
set -euo pipefail

TARGET=""
SSH_HOST=""
DRY_RUN=0
SERVER_NAME="${SERVER_NAME:-correspondance.local}"
MATRIX_USER="${MATRIX_USER:-$(id -un)}"
# La version de l'adaptateur ACP qu'on a éprouvée (docs/SPIKE-acp.md). Épinglée :
# le régime de permission par défaut d'un adaptateur change d'une version à
# l'autre, et on ne découvre pas ça en production.
ACP_PACKAGE="${CORRESPONDANCE_ACP:-@zed-industries/claude-code-acp@0.16.2}"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    --host) SSH_HOST="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --server-name) SERVER_NAME="${2:-}"; shift 2 ;;
    --user) MATRIX_USER="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "argument inconnu : $1" >&2; usage 2 ;;
  esac
done

[ -n "$TARGET" ] || { echo "!! il manque --target (this-mac | linux | ssh)" >&2; usage 2; }
case "$TARGET" in
  this-mac|linux) ;;
  ssh) [ -n "$SSH_HOST" ] || { echo "!! --target ssh demande --host" >&2; exit 2; } ;;
  *) echo "!! cible inconnue : $TARGET (this-mac | linux | ssh)" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Chaque action passe par là : en mode plan, elle s'imprime au lieu de se faire.
# C'est ce qui rend l'installeur vérifiable sans machine cible.
step() {
  local titre="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "PLAN  $titre"
    printf '      %s\n' "$*"
  else
    echo "→ $titre"
    "$@"
  fi
}

note() { [ "$DRY_RUN" -eq 1 ] && echo "NOTE  $1" || echo "   $1"; }

# ----------------------------------------------------------------- prérequis
#
# Ce qu'il faut, par cible. On ne fait pas semblant : sur un Mac, poser un
# moteur de conteneurs demande une installation qu'on ne peut pas faire en
# silence, donc on l'affiche et on s'arrête si elle manque.
plan_prerequisites() {
  case "$TARGET" in
    this-mac)
      note "moteur de conteneurs : Docker Desktop, OrbStack ou colima"
      step "Vérifier le moteur de conteneurs" check_container_engine
      note "Tailscale : recommandé, évite d'ouvrir un port ou de gérer un certificat"
      step "Vérifier Tailscale" check_tailscale
      ;;
    linux)
      step "Vérifier le moteur de conteneurs" check_container_engine
      step "Vérifier Tailscale" check_tailscale
      note "systemd utilisateur : loginctl enable-linger pour survivre à la déconnexion"
      ;;
    ssh)
      note "les prérequis sont vérifiés sur $SSH_HOST, pas ici"
      step "Vérifier l'accès SSH" ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST" true
      ;;
  esac
}

check_container_engine() {
  if command -v docker >/dev/null 2>&1; then return 0; fi
  if command -v podman >/dev/null 2>&1; then return 0; fi
  cat >&2 <<'AIDE'
!! Aucun moteur de conteneurs.
   macOS : brew install --cask orbstack   (ou docker, ou colima)
   Linux : votre gestionnaire de paquets, puis `sudo usermod -aG docker $USER`
   Relancez ensuite cette commande.
AIDE
  return 1
}

check_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then return 0; fi
  cat >&2 <<'AIDE'
   Tailscale absent. Sans lui, il faudra une adresse joignable et un certificat.
   macOS : brew install --cask tailscale
   Linux : curl -fsSL https://tailscale.com/install.sh | sh
   Passez outre en donnant PUBLIC_URL=http://…:8008 à l'étape d'appairage.
AIDE
  return 0
}

# ------------------------------------------------------------------- adresse
#
# L'adresse par laquelle les clients joindront le Relais. Le tailnet d'abord :
# c'est ce qui évite d'ouvrir un port. Pure, donc éprouvable.
public_url() {
  if [ -n "${PUBLIC_URL:-}" ]; then echo "$PUBLIC_URL"; return 0; fi
  local ip=""
  if command -v tailscale >/dev/null 2>&1; then
    ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  fi
  if [ -z "$ip" ]; then echo ""; return 0; fi
  echo "http://${ip}:8008"
}

# --------------------------------------------------------------------- pile
plan_stack() {
  case "$TARGET" in
    ssh)
      step "Poser Synapse et les ponts sur $SSH_HOST" \
        env SERVER_NAME="$SERVER_NAME" MATRIX_USER="$MATRIX_USER" SSH_HOST="$SSH_HOST" \
        "$HERE/bootstrap.sh"
      ;;
    this-mac|linux)
      # `bootstrap.sh --remote` est la phase qui s'exécute *sur* la machine du
      # Relais : c'est exactement ce qu'il nous faut en local.
      step "Poser Synapse et les ponts sur cette machine" \
        env SERVER_NAME="$SERVER_NAME" MATRIX_USER="$MATRIX_USER" \
        REMOTE_DIR="${REMOTE_DIR:-correspondance-matrix}" \
        bash "$HERE/bootstrap.sh" --remote
      ;;
  esac
}

plan_acp() {
  local commande="npm install -g $ACP_PACKAGE"
  case "$TARGET" in
    ssh) step "Adaptateur ACP épinglé sur $SSH_HOST" ssh "$SSH_HOST" "$commande" ;;
    *) step "Adaptateur ACP épinglé" sh -c "$commande" ;;
  esac
  note "s'il manque, l'agent répondra par la CLI (FallbackBackend) — jamais muet"
}

plan_pairing() {
  local url
  url="$(public_url)"
  if [ -z "$url" ]; then
    note "adresse publique inconnue : donnez PUBLIC_URL=http://…:8008 pour l'appairage"
  fi
  case "$TARGET" in
    ssh)
      step "Émettre le code d'appairage depuis $SSH_HOST" \
        ssh "$SSH_HOST" "SERVER_NAME='$SERVER_NAME' MATRIX_USER='$MATRIX_USER' ${url:+PUBLIC_URL='$url'} sh ~/correspondance-matrix/pair.sh"
      ;;
    *)
      step "Émettre le code d'appairage" \
        env SERVER_NAME="$SERVER_NAME" MATRIX_USER="$MATRIX_USER" ${url:+PUBLIC_URL="$url"} \
        sh "$HERE/pair.sh"
      ;;
  esac
}

echo "Relais Correspondance — cible : $TARGET${SSH_HOST:+ ($SSH_HOST)}, serveur : $SERVER_NAME, propriétaire : $MATRIX_USER"
[ "$DRY_RUN" -eq 1 ] && echo "(plan seulement — rien ne sera exécuté)"
echo

plan_prerequisites
plan_stack
plan_acp
plan_pairing

echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Fin du plan. Relancez sans --dry-run pour l'exécuter."
else
  echo "Relais prêt. Colle le code ci-dessus dans Correspondance (« Connecter un Relais »)."
fi
