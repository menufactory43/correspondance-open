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

# L'adresse de publication par défaut : les ponts macOS et Continuwuity en
# viennent tous depuis la phase 6.
RELEASES_ATTENDU="https://github.com/menufactory43/correspondance-releases/releases/latest/download"

echo "Hôte « macos-arm64 »"
MAC="$(bash "$INSTALL" --dry-run --hote macos-arm64 2>&1)"
verifier "prend le binaire macOS de NOTRE publication" "continuwuity-macos-arm64" "$MAC"
# Depuis la phase 6, les ponts macOS sont les NÔTRES, construits en `-tags
# goolm` : plus une seule ligne de libolm dans le plan, sur aucun hôte. C'est
# la seule preuve statique qu'on ait que la dylib a bien quitté la pile.
verifier_absent "ne pose plus libolm nulle part" "libolm" "$MAC"
verifier "prend les ponts darwin-arm64 de NOTRE publication" "mautrix-whatsapp-darwin-arm64" "$MAC"
verifier "les ponts macOS ne viennent plus de github.com/mautrix" "$RELEASES_ATTENDU/mautrix-signal-darwin-arm64" "$MAC"
verifier "prend Instagram en darwin-arm64" "mautrix-instagram-darwin-arm64" "$MAC"
# Messenger, c'est le binaire `mautrix-meta` nu du même dépôt : le confondre avec
# celui d'Instagram poserait deux fois le même réseau sous deux noms.
verifier "prend Messenger en darwin-arm64" "mautrix-meta-darwin-arm64" "$MAC"
verifier "prend X en darwin-arm64, de NOTRE publication" "$RELEASES_ATTENDU/mautrix-twitter-darwin-arm64" "$MAC"
verifier "prend Slack en darwin-arm64, de NOTRE publication" "$RELEASES_ATTENDU/mautrix-slack-darwin-arm64" "$MAC"
verifier "pose un agent launchd utilisateur" "Library/LaunchAgents" "$MAC"
# Cinq processus sur Mac (le Relais et les quatre ponts), mais UN SEUL élément
# d'arrière-plan : macOS notifie et fait approuver chaque agent launchd, et cinq
# notifications à l'installation ne sont pas un « un clic ».
verifier "n'annonce qu'un seul agent pour toute la pile" "UN SEUL agent pour toute la pile" "$MAC"
verifier "dit que le superviseur tient le Relais et les ponts" "superviseur.sh" "$MAC"
# Sur macOS, le Relais et l'app sont sur la MÊME machine : y poser Tailcat
# serait un tunnel de 127.0.0.1 vers 127.0.0.1.
verifier "dit qu'il ne pose ni Tailcat ni Tailscale sur Mac" "ni Tailcat ni Tailscale ne sont posés" "$MAC"
verifier_absent "ne pose pas Tailcat sur Mac" "tailcat_0.4.0" "$MAC"
verifier_absent "aucun service tailcat sur Mac" "correspondance-tailcat" "$MAC"
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
verifier "prend X en amd64" "mautrix-twitter-amd64" "$LX"
verifier "prend Slack en amd64" "mautrix-slack-amd64" "$LX"
verifier "pose une unité systemd utilisateur" "systemctl --user enable --now" "$LX"
verifier "parle du linger" "enable-linger" "$LX"
verifier "respecte --prefix" "$HOME/unclic" "$LX"
verifier_absent "aucun launchd sur Linux" "LaunchAgents" "$LX"
verifier_absent "ne pose pas libolm sur Linux" "libolm" "$LX"

echo "Tailcat, par défaut, sur Linux"
# Le renversement de la phase 7b : Tailcat est le chemin par défaut, Tailscale
# le repli. Ce qu'on éprouve ici, c'est que le plan le dit et que l'installeur
# épingle l'archive amont comme tout le reste.
verifier "épingle l'archive amont v0.4.0 en amd64" "tailcat_0.4.0_linux_amd64.tar.gz" "$LX"
verifier "en vérifie le sha256" "sha256 8b819c43dfdf806b5663e23535aba557bb106075b0b5839df289af9bba70bec2" "$LX"
verifier "tire une clé persistante dans le dossier du Relais" "tailcat/relais.private.json" "$LX"
verifier "pose un service correspondance-tailcat devant le port du Relais" "service correspondance-tailcat devant le port 8010" "$LX"
verifier "relit le jeton dans le fichier d'adresse, pas dans genkey" "TAILCAT_ADDR_FILE" "$LX"
verifier "met le jeton dans le code d'appairage" "ET jeton Tailcat" "$LX"
verifier "dit que le Mac se connectera seul" "le Mac s'y connectera tout seul" "$LX"
verifier "dit que l'iPhone a encore besoin de Tailscale" "L'iPhone, lui, a encore besoin de Tailscale" "$LX"
# Le message que la phase 7b fait disparaître : sans Tailscale, on ne dit plus
# « il faudrait sudo », parce que ce n'est plus vrai pour le Mac.
verifier_absent "ne réclame plus Tailscale pour le Mac" "Cet installeur ne le pose PAS" "$LX"
verifier_absent "ne propose plus le tunnel ssh quand Tailcat est là" "ssh -N -L 8010" "$LX"


echo "Hôte « linux-arm64 »"
LA="$(bash "$INSTALL" --dry-run --hote linux-arm64 2>&1)"
verifier "prend la release amont, statique, arm64" "conduwuit-linux-static-arm64" "$LA"
verifier "prend les ponts arm64" "mautrix-whatsapp-arm64" "$LA"
verifier "prend Instagram en arm64" "mautrix-instagram-arm64" "$LA"
verifier "prend Messenger en arm64" "mautrix-meta-arm64" "$LA"
verifier "prend X en arm64" "mautrix-twitter-arm64" "$LA"
verifier "prend Slack en arm64" "mautrix-slack-arm64" "$LA"
verifier_absent "ne prend pas le Messenger d'un autre hôte" "mautrix-meta-amd64" "$LA"
verifier_absent "ne confond pas avec l'amd64" "conduwuit-linux-static-amd64" "$LA"
verifier "prend l'archive tailcat arm64" "tailcat_0.4.0_linux_arm64.tar.gz" "$LA"
verifier_absent "ne confond pas les deux archives tailcat" "tailcat_0.4.0_linux_amd64" "$LA"

echo "Le repli, quand on écarte Tailcat (--sans-tailcat)"
# Le chemin d'avant la phase 7b doit rester praticable : c'est lui qui sert si
# Tailcat est refusé, et c'est le seul que l'iPhone sache prendre.
SANS="$(bash "$INSTALL" --dry-run --hote linux-x86_64 --sans-tailcat 2>&1)"
verifier_absent "ne télécharge plus tailcat" "tailcat_0.4.0" "$SANS"
verifier_absent "ne pose plus de service tailcat" "correspondance-tailcat" "$SANS"
verifier "dit ce qu'il ferait pour Tailscale, et que ça demande sudo" "tailscale.com/install.sh" "$SANS"
verifier "propose le tunnel ssh en attendant" "ssh -N -L 8010:127.0.0.1:8010" "$SANS"

echo "Les options"
PORT="$(bash "$INSTALL" --dry-run --hote macos-arm64 --port 8030 --server-name essai.local --user pierre 2>&1)"
verifier "déplace le Relais avec --port" "127.0.0.1:8030" "$PORT"
verifier "déplace les ponts avec lui" "29338 (WhatsApp)" "$PORT"
verifier "déplace Instagram, Messenger et X aussi" "29350 (Instagram), 29351 (Messenger), 29352 (X) et 29355 (Slack)" "$PORT"
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
verifier "ne retire pas une nouvelle clé tailcat" 'clé déjà là, conservée' "$SRC"
# `enable --now` ne redémarre pas une unité active : sans le restart, une seconde
# exécution attendrait une adresse que personne ne réécrit.
verifier "redémarre tailcat pour qu'il réécrive son adresse" 'systemctl --user restart correspondance-tailcat' "$SRC"
verifier "refuse d'installer si un sha256 diffère" "on n'installe rien" "$SRC"

echo "Les six ponts, même traitement"
verifier "Instagram passe par la même fonction pont()" "pont instagram " "$SRC"
verifier "Messenger passe par la même fonction pont()" "pont messenger " "$SRC"
verifier "le préfixe de commande d'Instagram est celui de l'app" "'!ig' instagrambot" "$SRC"
verifier "le préfixe de commande de Messenger est celui de l'app" "'!fb' messengerbot" "$SRC"
verifier "X passe par la même fonction pont()" "pont twitter " "$SRC"
verifier "le préfixe de commande de X est celui de l'app" "'!tw' twitterbot" "$SRC"
verifier "Slack passe par la même fonction pont()" "pont slack " "$SRC"
verifier "le préfixe de commande de Slack est celui de l'app" "'!slack' slackbot" "$SRC"
# `pont()` écrit une seule fois la config : SQLite, allow+default, logging.writers.
verifier "les ponts sont en SQLite" "sqlite3-fk-wal" "$SRC"
verifier "les portails sont chiffrés par défaut" "default: true" "$SRC"
verifier "les ponts écrivent leur journal" "writers:" "$SRC"
DESINSTALL_SRC="$(cat "$DESINSTALL")"
verifier "le désinstalleur retire aussi Instagram" "mautrix-instagram" "$DESINSTALL_SRC"
verifier "le désinstalleur retire aussi Messenger" "mautrix-messenger" "$DESINSTALL_SRC"
verifier "le désinstalleur retire aussi X" "mautrix-twitter" "$DESINSTALL_SRC"
verifier "le désinstalleur retire aussi Slack" "mautrix-slack" "$DESINSTALL_SRC"
verifier "le désinstalleur retire aussi le service tailcat" "for nom in relais tailcat" "$DESINSTALL_SRC"

echo "Le mode machine (--json)"
# Ce que la carte « Sur ce Mac » lit. On ne pose rien : on éprouve que le mode
# existe, qu'il nomme chaque étape, et surtout que la FIN est reconnaissable —
# c'est le seul point où l'app peut se tromper sans le voir.
verifier "l'option existe" "--json                une ligne JSON par étape" "$SRC"
verifier "une étape est un objet à trois champs" '"etape":sys.argv[1],"etat":sys.argv[2],"detail":sys.argv[3]' "$SRC"
verifier "un échec sort DANS le flux, pas seulement sur stderr" 'mourir() { etape "${ETAPE_COURANTE:-installation}" erreur' "$SRC"
for nom in prerequis binaires secrets configuration services attente tailcat compte ponts preuve; do
  verifier "l'étape « $nom » est annoncée" "etape $nom debut" "$SRC"
  verifier "l'étape « $nom » est conclue" "etape $nom ok" "$SRC"
done
verifier "l'échec de tailcat se dit « erreur », et n'arrête pas l'installation" \
  "etape tailcat erreur \"tailcat n'a pas publié d'adresse" "$SRC"
verifier "l'appairage est le dernier objet, et il porte le code" '"etape": "appairage", "etat": "ok", "code": code, "mots": six' "$SRC"
verifier "le mode humain garde ses phrases" 'print(f"  Vérification (six mots)' "$SRC"
verifier_absent "le mode humain n'imprime pas de JSON" 'if not en_json' "$SRC"

# L'analyse du flux, pour de vrai : on extrait la fonction `etape` de
# l'installeur et on la fait parler, sans rien poser sur la machine.
BOUT="$(mktemp)"
{ echo "JSON=1"
  sed -n '/^etape() {/,/^}/p' "$INSTALL"
  echo 'etape binaires debut "une somme"'
  echo 'etape binaires ok ""'
} > "$BOUT"
LIGNES="$(bash "$BOUT" 2>&1)"
rm -f "$BOUT"
verifier "une étape émise est bien du JSON" '{"etape": "binaires", "etat": "debut", "detail": "une somme"}' "$LIGNES"
verifier "un détail vide reste un champ" '"detail": ""' "$LIGNES"

echo
if [ "$echecs" -eq 0 ]; then
  echo "Plan d'installation du Relais : tout est conforme."
else
  echo "Plan d'installation du Relais : $echecs écart(s)."
  exit 1
fi
