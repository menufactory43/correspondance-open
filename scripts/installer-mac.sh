#!/bin/zsh
# Installe la build courante dans /Applications — la seule copie que le Dock
# doit connaître. À lancer après chaque changement qu'on veut sous la main.
#
#   scripts/installer-mac.sh              # compile, remplace /Applications, relance
#   scripts/installer-mac.sh --no-launch  # compile et remplace, sans relancer
#
# Pourquoi ce script et pas « copier à la main » : la copie de /Applications
# prenait du retard sans que rien ne dise de quel commit elle venait (le 10 sept.,
# une build à la main y est restée avec un plantage au lancement corrigé le 11).
# Ici, le commit est gravé dans l'Info.plist (`CorrespondanceCommit`) et le
# script le relit après coup.
#
# Pas de notarisation : Gatekeeper ne l'exige que d'une app téléchargée, marquée
# en quarantaine ; une app compilée ici n'a pas cet attribut. Et la même
# signature que les builds Xcode (« Apple Development », automatique) : macOS
# lie l'accès disque, Contacts et l'automatisation à l'identité de signature,
# changer d'identité fait retomber les cases de Réglages Système.
#
# Release, comme ce qu'on livre, dans un DerivedData à part (build/local/dd) :
# incrémental, donc quelques secondes quand peu de fichiers ont changé, et
# séparé du Debug d'Xcode et de celui de release-mac.sh. Le drapeau
# CORRESPONDANCE_CRYPTO=1 est levé comme partout ailleurs (cf. scripts/test.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
LAUNCH=1
[ "${1:-}" = "--no-launch" ] && LAUNCH=0

DD="build/local/dd"
CIBLE="/Applications/Correspondance.app"
COMMIT="$(git rev-parse --short HEAD)"
[ -z "$(git status --porcelain --untracked-files=no)" ] || COMMIT="${COMMIT}+modifs"

echo "▸ Build Release (${COMMIT})"
xcodegen generate >/dev/null
CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Release -destination 'platform=macOS' -derivedDataPath "$DD" \
  CORRESPONDANCE_COMMIT="$COMMIT" build 2>&1 | grep -E "error:|warning: tailcat|BUILD (SUCCEEDED|FAILED)"
APP="$DD/Build/Products/Release/Correspondance.app"
[ -d "$APP" ] || { echo "✗ pas d'app dans $APP"; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "✗ signature invalide"; exit 1; }

echo "▸ Remplacement de ${CIBLE}"
# Remplacer un bundle qui tourne casse l'instance ouverte : on la quitte d'abord.
if pgrep -x Correspondance >/dev/null; then
  osascript -e 'tell application id "app.correspondance.Correspondance" to quit' 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Correspondance >/dev/null || break; sleep 0.5; done
  pkill -x Correspondance 2>/dev/null || true
fi
# Un bundle neuf à côté, puis un renommage : jamais un /Applications à moitié copié.
rm -rf "${CIBLE}.nouveau"
ditto "$APP" "${CIBLE}.nouveau"
rm -rf "$CIBLE"
mv "${CIBLE}.nouveau" "$CIBLE"
# Le registre LaunchServices ne doit connaître que /Applications (cf. le script).
scripts/desinscrire-doublons.sh >/dev/null 2>&1 || true

INSTALLE="$(defaults read "$CIBLE/Contents/Info.plist" CorrespondanceCommit 2>/dev/null || echo '?')"
VERSION="$(defaults read "$CIBLE/Contents/Info.plist" CFBundleShortVersionString) ($(defaults read "$CIBLE/Contents/Info.plist" CFBundleVersion))"
echo "✅ ${CIBLE} — ${VERSION}, commit ${INSTALLE}"
if [ "$LAUNCH" = 1 ]; then
  open "$CIBLE"
  echo "→ lancée. Épingle cette icône au Dock : elle lancera toujours cette copie."
fi
