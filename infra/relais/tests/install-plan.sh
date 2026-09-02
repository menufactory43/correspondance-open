#!/usr/bin/env bash
# Éprouve ce qu'on peut éprouver sans poser la pile : le plan que l'installeur
# du Relais produit pour chacun des trois hôtes, et son idempotence.
#
#   infra/relais/tests/install-plan.sh
#
# Ce que ça ne prouve pas, et il faut le dire : que Continuwuity démarre, que
# les ponts s'enregistrent, que le code d'appairage marche. Ça prouve que
# l'installeur décide les bonnes choses, dans le bon ordre, pour la bonne cible,
# et qu'une seconde exécution ne remet pas en cause la première.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$HERE/install.sh"
DESINSTALL="$HERE/uninstall.sh"
echecs=0

verifier() {
  local nom="$1" attendu="$2" sortie="$3"
  if printf '%s' "$sortie" | grep -qF -- "$attendu"; then echo "  ✓ $nom"
  else echo "  ✗ $nom — introuvable : $attendu"; echecs=$((echecs + 1)); fi
}
verifier_absent() {
  local nom="$1" interdit="$2" sortie="$3"
  if printf '%s' "$sortie" | grep -qF -- "$interdit"; then
    echo "  ✗ $nom — présent alors qu'il ne devrait pas : $interdit"; echecs=$((echecs + 1))
  else echo "  ✓ $nom"; fi
}

echo "Hôte « macos-arm64 »"
MAC="$(bash "$INSTALL" --dry-run --hote macos-arm64 2>&1)"
verifier "prend le binaire macOS de NOTRE publication" "continuwuity-macos-arm64" "$MAC"
verifier "pose libolm à côté des ponts" "libolm.3.dylib" "$MAC"
verifier "prend les ponts darwin-arm64 d'amont" "mautrix-whatsapp-darwin-arm64" "$MAC"
verifier "prend Instagram en darwin-arm64" "mautrix-instagram-darwin-arm64" "$MAC"
# Messenger, c'est le binaire `mautrix-meta` nu du même dépôt : le confondre avec
# celui d'Instagram poserait deux fois le même réseau sous deux noms.
verifier "prend Messenger en darwin-arm64" "mautrix-meta-darwin-arm64" "$MAC"
verifier "pose un agent launchd utilisateur" "Library/LaunchAgents" "$MAC"
verifier "dit qu'il ne pose pas Tailscale sur Mac" "Tailscale n'est ni posé ni requis" "$MAC"
verifier "finit sur la preuve" "/account/whoami" "$MAC"
verifier "finit sur le code d'appairage" "correspondance://relais/" "$MAC"
verifier "n'exécute rien" "rien n'a été exécuté" "$MAC"
verifier_absent "aucun systemd sur Mac" "systemctl --user" "$MAC"
verifier "annonce qu'il n'y a ni sudo ni Docker" "Aucun sudo, aucun Docker" "$MAC"
verifier_absent "ne demande aucun sudo sur Mac" "sudo loginctl" "$MAC"
verifier_absent "ne pose pas Tailscale sur Mac" "tailscale.com/install.sh" "$MAC"

echo "Hôte « linux-x86_64 »"
LX="$(bash "$INSTALL" --dry-run --hote linux-x86_64 --prefix "$HOME/unclic" 2>&1)"
verifier "prend la release amont, statique, amd64" "conduwuit-linux-static-amd64" "$LX"
verifier "prend les ponts amd64" "mautrix-signal-amd64" "$LX"
verifier "prend Instagram en amd64" "mautrix-instagram-amd64" "$LX"
verifier "prend Messenger en amd64" "mautrix-meta-amd64" "$LX"
verifier "pose une unité systemd utilisateur" "systemctl --user enable --now" "$LX"
verifier "parle du linger" "enable-linger" "$LX"
verifier "respecte --prefix" "$HOME/unclic" "$LX"
verifier_absent "aucun launchd sur Linux" "LaunchAgents" "$LX"
verifier_absent "ne pose pas libolm sur Linux" "libolm" "$LX"

echo "Hôte « linux-arm64 »"
LA="$(bash "$INSTALL" --dry-run --hote linux-arm64 2>&1)"
verifier "prend la release amont, statique, arm64" "conduwuit-linux-static-arm64" "$LA"
verifier "prend les ponts arm64" "mautrix-whatsapp-arm64" "$LA"
verifier "prend Instagram en arm64" "mautrix-instagram-arm64" "$LA"
verifier "prend Messenger en arm64" "mautrix-meta-arm64" "$LA"
verifier_absent "ne prend pas le Messenger d'un autre hôte" "mautrix-meta-amd64" "$LA"
verifier_absent "ne confond pas avec l'amd64" "conduwuit-linux-static-amd64" "$LA"

echo "Tailscale, quand il manque"
verifier "dit ce qu'il ferait, et que ça demande sudo" "tailscale.com/install.sh" "$LX"
verifier "propose le tunnel ssh en attendant" "ssh -N -L 8010:127.0.0.1:8010" "$LX"

echo "Les options"
PORT="$(bash "$INSTALL" --dry-run --hote macos-arm64 --port 8030 --server-name essai.local --user pierre 2>&1)"
verifier "déplace le Relais avec --port" "127.0.0.1:8030" "$PORT"
verifier "déplace les ponts avec lui" "29338 (WhatsApp)" "$PORT"
verifier "déplace Instagram et Messenger aussi" "29350 (Instagram) et 29351 (Messenger)" "$PORT"
verifier "reprend --server-name et --user" "@pierre:essai.local" "$PORT"

echo "Les refus"
if bash "$INSTALL" --dry-run --hote martienne >/dev/null 2>&1; then
  echo "  ✗ un hôte inconnu devrait être refusé"; echecs=$((echecs + 1))
else echo "  ✓ refuse un hôte inconnu"; fi
if bash "$INSTALL" --dry-run --pas-une-option >/dev/null 2>&1; then
  echo "  ✗ une option inconnue devrait être refusée"; echecs=$((echecs + 1))
else echo "  ✓ refuse une option inconnue"; fi
for interdit in "$HOME/.correspondance-agent" "$HOME/Library/Application Support/Correspondance"; do
  if bash "$INSTALL" --dry-run --prefix "$interdit" >/dev/null 2>&1; then
    echo "  ✗ $interdit devrait être refusé (prod)"; echecs=$((echecs + 1))
  else echo "  ✓ refuse $interdit (prod)"; fi
done

echo "Le désinstalleur"
BAC="$(mktemp -d)"
SORTIE="$(bash "$DESINSTALL" --prefix "$BAC" 2>&1)" && VERDICT=0 || VERDICT=1
if [ "$VERDICT" = 1 ] && [ -d "$BAC" ]; then
  echo "  ✓ refuse d'effacer un dossier sans la marque de l'installeur"
else
  echo "  ✗ il a effacé (ou accepté) un dossier qui n'est pas le sien"; echecs=$((echecs + 1))
fi
: > "$BAC/.correspondance-relais"
bash "$DESINSTALL" --prefix "$BAC" >/dev/null 2>&1
if [ -d "$BAC" ]; then
  echo "  ✗ un dossier marqué devrait être effacé"; echecs=$((echecs + 1))
else echo "  ✓ efface un dossier qui porte la marque"; fi
rm -rf "$BAC"

echo "L'idempotence des écritures"
# Le défaut qu'on cherche : un second passage qui réécrit une configuration ou
# retire de nouveaux jetons, et laisse le pont répondre « as_token was not
# accepted ». Le code doit ne réécrire QUE ce qui manque.
SRC="$(cat "$INSTALL")"
verifier "ne réécrit pas le .toml existant" 'déjà là, conservé' "$SRC"
verifier "ne réécrit pas la config d'un pont existante" 'configuration déjà là, conservée' "$SRC"
verifier "ne retire pas de nouveaux jetons de pont" 'registration déjà là, jetons inchangés' "$SRC"
verifier "ne retire pas de nouveaux secrets" 'if [ ! -f "$SECRETS" ]' "$SRC"
verifier "ne recrée pas le compte si la session vaut encore" 'déjà là, session valide' "$SRC"
verifier "refuse d'installer si un sha256 diffère" "on n'installe rien" "$SRC"

echo "Les quatre ponts, même traitement"
verifier "Instagram passe par la même fonction pont()" "pont instagram " "$SRC"
verifier "Messenger passe par la même fonction pont()" "pont messenger " "$SRC"
verifier "le préfixe de commande d'Instagram est celui de l'app" "'!ig' instagrambot" "$SRC"
verifier "le préfixe de commande de Messenger est celui de l'app" "'!fb' messengerbot" "$SRC"
# `pont()` écrit une seule fois la config : SQLite, allow+default, logging.writers.
verifier "les ponts sont en SQLite" "sqlite3-fk-wal" "$SRC"
verifier "les portails sont chiffrés par défaut" "default: true" "$SRC"
verifier "les ponts écrivent leur journal" "writers:" "$SRC"
DESINSTALL_SRC="$(cat "$DESINSTALL")"
verifier "le désinstalleur retire aussi Instagram" "mautrix-instagram" "$DESINSTALL_SRC"
verifier "le désinstalleur retire aussi Messenger" "mautrix-messenger" "$DESINSTALL_SRC"

echo
if [ "$echecs" -eq 0 ]; then
  echo "Plan d'installation du Relais : tout est conforme."
else
  echo "Plan d'installation du Relais : $echecs écart(s)."
  exit 1
fi
