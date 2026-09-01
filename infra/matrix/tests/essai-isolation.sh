#!/usr/bin/env bash
# Éprouve que le Relais d'essai ne peut pas toucher la prod.
#
#   infra/matrix/tests/essai-isolation.sh
#
# C'est le test qui compte : meffysto va lancer `destroy` sur sa machine, et rien
# ne doit pouvoir atteindre son vrai Relais, ses vraies conversations, ses
# vrais ponts. On vérifie les quatre axes d'isolation et la garde du projet.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ESSAI="$HERE/essai/essai.sh"
COMPOSE="$HERE/essai/docker-compose.yml"
PROD_COMPOSE="$HERE/docker-compose.yml"
echecs=0

verifier() {
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "  ✓ $1"
  else echo "  ✗ $1 — introuvable : $2"; echecs=$((echecs + 1)); fi
}

verifier_absent() {
  if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "  ✗ $1 — présent alors qu'il ne devrait pas : $2"; echecs=$((echecs + 1))
  else echo "  ✓ $1"; fi
}

COMPOSE_TXT="$(cat "$COMPOSE")"
PROD_TXT="$(cat "$PROD_COMPOSE")"

echo "Les quatre isolations"
verifier "server_name distinct de la prod" "correspondance.essai" "$(bash "$ESSAI" --dry-run up 2>&1)"
verifier "conteneurs préfixés correspondance-essai" "correspondance-essai-synapse" "$COMPOSE_TXT"
verifier "conteneurs préfixés correspondance-essai (postgres)" "correspondance-essai-postgres" "$COMPOSE_TXT"
verifier "port publié 8009" "127.0.0.1:8009:8008" "$COMPOSE_TXT"
verifier "volume Postgres à part" "essai-postgres" "$COMPOSE_TXT"

echo "Ce que l'essai ne doit surtout pas contenir"
# La garantie porte sur les *services*, pas sur les mots : le compose explique
# en commentaire pourquoi il n'y a pas de pont, et c'est très bien ainsi.
IMAGES_ESSAI="$(grep -E '^\s*image:' "$COMPOSE" || true)"
verifier_absent "aucune image de pont mautrix" "dock.mau.dev" "$IMAGES_ESSAI"
verifier_absent "aucune image sygnal" "sygnal" "$IMAGES_ESSAI"
verifier "n'embarque que Postgres et Synapse" "matrixdotorg/synapse" "$IMAGES_ESSAI"
NB_IMAGES="$(printf '%s\n' "$IMAGES_ESSAI" | grep -c 'image:' || true)"
if [ "$NB_IMAGES" -eq 2 ]; then
  echo "  ✓ deux services, pas un de plus"
else
  echo "  ✗ $NB_IMAGES image(s) — l'essai doit se limiter à Postgres et Synapse"
  echecs=$((echecs + 1))
fi
verifier_absent "ne publie pas 8008 sur l'hôte" ":8008:8008" "$COMPOSE_TXT"
verifier_absent "n'emprunte aucun nom de conteneur de la prod" "container_name: correspondance-synapse" "$COMPOSE_TXT"
verifier_absent "n'écrit pas dans le dossier de données de la prod" "../data" "$COMPOSE_TXT"

echo "La prod reste ce qu'elle est"
verifier "la prod garde ses conteneurs" "correspondance-synapse" "$PROD_TXT"
verifier "la prod garde ses ponts" "mautrix-whatsapp" "$PROD_TXT"

echo "La garde du projet — toute commande docker porte -p correspondance-essai"
PLAN_UP="$(bash "$ESSAI" --dry-run up 2>&1)"
PLAN_DESTROY="$(bash "$ESSAI" --dry-run destroy 2>&1)"
PLAN_DOWN="$(bash "$ESSAI" --dry-run down 2>&1)"
for nom in up destroy down; do
  case "$nom" in
    up) plan="$PLAN_UP" ;; destroy) plan="$PLAN_DESTROY" ;; down) plan="$PLAN_DOWN" ;;
  esac
  lignes_docker="$(printf '%s' "$plan" | grep -c 'PLAN  docker compose' || true)"
  lignes_projet="$(printf '%s' "$plan" | grep -c -- '-p correspondance-essai' || true)"
  if [ "$lignes_docker" -eq "$lignes_projet" ] && [ "$lignes_docker" -gt 0 ]; then
    echo "  ✓ $nom : $lignes_docker commande(s) docker, toutes sur le projet d'essai"
  else
    echo "  ✗ $nom : $lignes_docker commande(s) docker, $lignes_projet sur le projet d'essai"
    echecs=$((echecs + 1))
  fi
done

echo "L'effacement"
verifier "destroy efface les volumes du projet d'essai" "-p correspondance-essai" "$PLAN_DESTROY"
verifier "destroy n'efface que son propre dossier" "essai/data" "$PLAN_DESTROY"
verifier "destroy rappelle le dossier de données de l'app" "Correspondance-essai" "$PLAN_DESTROY"
verifier "destroy rappelle l'entrée du Trousseau" "app.correspondance.matrix.essai" "$PLAN_DESTROY"
# `down` sans `-v` : on garde les données, c'est la différence avec `destroy`.
verifier_absent "down ne supprime pas les volumes" "down -v" "$PLAN_DOWN"

echo "L'appairage"
verifier "up finit par un code d'appairage" "code d'appairage" "$PLAN_UP"
verifier "up dit comment lancer l'app à côté" "CORRESPONDANCE_HOME=essai" "$PLAN_UP"

echo
if [ "$echecs" -eq 0 ]; then
  echo "Relais d'essai : isolé de la prod sur tous les axes vérifiables."
else
  echo "Relais d'essai : $echecs écart(s) — NE PAS lancer sur la machine de prod."
  exit 1
fi
