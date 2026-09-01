#!/usr/bin/env bash
# Éprouve la partie de l'installeur qu'on peut éprouver sans machine cible :
# le plan qu'il produit pour chaque hôte.
#
#   infra/matrix/tests/install-plan.sh
#
# Ce que ça ne prouve pas, et il faut le dire : que Synapse démarre, que les
# ponts se connectent, que Tailscale s'installe. Ça prouve que l'installeur
# décide les bonnes choses, dans le bon ordre, pour la bonne cible.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$HERE/install.sh"
echecs=0

verifier() {
  local nom="$1" attendu="$2" sortie="$3"
  if printf '%s' "$sortie" | grep -qF -- "$attendu"; then
    echo "  ✓ $nom"
  else
    echo "  ✗ $nom — introuvable : $attendu"
    echecs=$((echecs + 1))
  fi
}

verifier_absent() {
  local nom="$1" interdit="$2" sortie="$3"
  if printf '%s' "$sortie" | grep -qF -- "$interdit"; then
    echo "  ✗ $nom — présent alors qu'il ne devrait pas : $interdit"
    echecs=$((echecs + 1))
  else
    echo "  ✓ $nom"
  fi
}

echo "Cible « linux »"
PLAN_LINUX="$(PUBLIC_URL=http://100.64.0.1:8008 bash "$INSTALL" --target linux --dry-run 2>&1)"
verifier "pose la pile localement" "bootstrap.sh --remote" "$PLAN_LINUX"
verifier "épingle la version de l'adaptateur ACP" "claude-code-acp@0.16.2" "$PLAN_LINUX"
verifier "finit par le code d'appairage" "pair.sh" "$PLAN_LINUX"
verifier "rappelle le linger systemd" "enable-linger" "$PLAN_LINUX"
verifier "n'exécute rien" "rien ne sera exécuté" "$PLAN_LINUX"
verifier_absent "ne passe pas par SSH" "ssh " "$PLAN_LINUX"

echo "Cible « this-mac »"
PLAN_MAC="$(PUBLIC_URL=http://100.64.0.1:8008 bash "$INSTALL" --target this-mac --dry-run 2>&1)"
verifier "dit quel moteur de conteneurs installer" "OrbStack" "$PLAN_MAC"
verifier "pose la pile localement" "bootstrap.sh --remote" "$PLAN_MAC"
verifier "finit par le code d'appairage" "pair.sh" "$PLAN_MAC"

echo "Cible « ssh »"
PLAN_SSH="$(PUBLIC_URL=http://100.64.0.1:8008 bash "$INSTALL" --target ssh --host nuc --dry-run 2>&1)"
verifier "vérifie l'accès SSH d'abord" "Vérifier l'accès SSH" "$PLAN_SSH"
verifier "délègue la pile au bootstrap" "bootstrap.sh" "$PLAN_SSH"
verifier "pose l'adaptateur sur l'hôte distant" "ssh nuc npm install -g" "$PLAN_SSH"
verifier "émet le code depuis l'hôte" "pair.sh" "$PLAN_SSH"
verifier_absent "ne vérifie pas les prérequis en local" "OrbStack" "$PLAN_SSH"

echo "La cohérence avec bootstrap.sh"
# L'installeur appelle `pair.sh` sur l'hôte distant : encore faut-il que
# `bootstrap.sh` l'y ait copié. Le défaut a existé.
BOOTSTRAP="$(cat "$HERE/bootstrap.sh")"
verifier "bootstrap copie pair.sh sur l'hôte" 'pair.sh' "$BOOTSTRAP"

echo "L'adresse publique"
PLAN_URL="$(PUBLIC_URL=http://10.0.0.9:8008 bash "$INSTALL" --target linux --dry-run 2>&1)"
verifier "reprend PUBLIC_URL quand on la donne" "PUBLIC_URL=http://10.0.0.9:8008" "$PLAN_URL"

echo "Les refus"
if bash "$INSTALL" --dry-run >/dev/null 2>&1; then
  echo "  ✗ une cible manquante devrait être refusée"
  echecs=$((echecs + 1))
else
  echo "  ✓ refuse une cible manquante"
fi
if bash "$INSTALL" --target martienne --dry-run >/dev/null 2>&1; then
  echo "  ✗ une cible inconnue devrait être refusée"
  echecs=$((echecs + 1))
else
  echo "  ✓ refuse une cible inconnue"
fi
if bash "$INSTALL" --target ssh --dry-run >/dev/null 2>&1; then
  echo "  ✗ --target ssh sans --host devrait être refusé"
  echecs=$((echecs + 1))
else
  echo "  ✓ refuse --target ssh sans --host"
fi

echo
if [ "$echecs" -eq 0 ]; then
  echo "Plan d'installation : tout est conforme."
else
  echo "Plan d'installation : $echecs écart(s)."
  exit 1
fi
