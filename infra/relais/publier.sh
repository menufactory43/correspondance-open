#!/usr/bin/env bash
# Correspondance — publie les binaires du Relais dans le dépôt public
# `correspondance-releases`. **Par défaut il ne publie rien** : il imprime ce
# qu'il ferait. Publier est une décision du propriétaire, pas un effet de bord
# d'un script de construction.
#
#   bash infra/relais/publier.sh --dry-run      # ce qu'une publication ferait
#   bash infra/relais/publier.sh --vraiment     # la publication elle-même
#
# Options
#   --dossier DIR   d'où viennent les fichiers  (défaut : ~/unclic-publication)
#   --depot NOM     le dépôt public             (défaut : menufactory43/correspondance-releases)
#   --tag NOM       le tag de la release        (défaut : relais-<date>)
#   --signer        signe et notarise avant de publier (demande une identité
#                   Developer ID ; sans elle le script s'arrête en le disant)
#
# Ce que la publication met en ligne, et pourquoi cette liste-là :
#   relais-install.sh, relais-uninstall.sh   les scripts, tels qu'ils sont ici
#   continuwuity-macos-arm64                 l'amont ne publie aucun binaire macOS
#   mautrix-*-darwin-arm64                   nos ponts goolm : ils ne chargent plus libolm
#   SHA256SUMS                               relevé sur les fichiers publiés, pas ailleurs
# Rien pour Linux : les releases amont suffisent, et l'installeur les prend là.
set -euo pipefail

DOSSIER="${CORRESPONDANCE_PUBLICATION:-$HOME/unclic-publication}"
DEPOT="${CORRESPONDANCE_DEPOT:-menufactory43/correspondance-releases}"
TAG="relais-$(date +%Y.%m.%d)"
VRAIMENT=0
SIGNER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) VRAIMENT=0 ;;
    --vraiment) VRAIMENT=1 ;;
    --signer) SIGNER=1 ;;
    --dossier) DOSSIER="$2"; shift ;;
    --depot) DEPOT="$2"; shift ;;
    --tag) TAG="$2"; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "!! option inconnue : $1" >&2; exit 2 ;;
  esac
  shift
done

[ -d "$DOSSIER" ] || { echo "!! $DOSSIER n'existe pas — lance d'abord infra/relais/construire.sh" >&2; exit 1; }
somme() { shasum -a 256 "$1" | awk '{print $1}'; }

echo "Publication du Relais Correspondance"
echo "  dossier   $DOSSIER"
echo "  dépôt     $DEPOT"
echo "  tag       $TAG"
echo

echo "Les fichiers, et leurs sommes"
FICHIERS=()
while IFS= read -r f; do
  nom="$(basename "$f")"
  case "$nom" in SHA256SUMS|*.log) continue ;; esac
  FICHIERS+=("$nom")
  printf '  %-34s %12s o  %s\n' "$nom" "$(wc -c < "$f" | tr -d ' ')" "$(somme "$f")"
done < <(find "$DOSSIER" -maxdepth 1 -type f | sort)
[ ${#FICHIERS[@]} -gt 0 ] || { echo "!! rien à publier dans $DOSSIER" >&2; exit 1; }
echo

# ------------------------------------------------------- ce que SHA256SUMS dit
# Le fichier de sommes est ce que l'installeur ET l'app lisent : s'il ne
# correspond pas aux fichiers du dossier, publier reviendrait à publier un
# contrôle qui refuse tout. On le vérifie avant, pas après.
if [ -f "$DOSSIER/SHA256SUMS" ]; then
  echo "SHA256SUMS"
  ecarts=0
  while read -r attendue nom; do
    nom="${nom#\*}"
    [ -f "$DOSSIER/$nom" ] || { echo "  ✗ $nom est dans SHA256SUMS mais pas dans le dossier"; ecarts=$((ecarts+1)); continue; }
    vue="$(somme "$DOSSIER/$nom")"
    if [ "$vue" = "$attendue" ]; then echo "  ✓ $nom"
    else echo "  ✗ $nom : $vue ≠ $attendue"; ecarts=$((ecarts+1)); fi
  done < "$DOSSIER/SHA256SUMS"
  for nom in "${FICHIERS[@]}"; do
    grep -q " \*\?$nom\$" "$DOSSIER/SHA256SUMS" || { echo "  ✗ $nom n'a pas de somme"; ecarts=$((ecarts+1)); }
  done
  [ "$ecarts" = 0 ] || { echo "!! $ecarts écart(s) — régénère par construire.sh avant de publier" >&2; exit 1; }
else
  echo "!! pas de SHA256SUMS dans $DOSSIER — l'installeur et l'app en ont besoin" >&2
  exit 1
fi
echo

# ---------------------------------------------------- signature et notarisation
# Ce que Gatekeeper évalue dépend de QUI lance le binaire. Lancé depuis un
# terminal après un `curl`, il porte l'attribut de quarantaine et l'installeur
# le retire (`xattr -d`) — c'est ce qui marche depuis la phase 3. Lancé comme
# processus enfant d'une app signée, la quarantaine est héritée du
# téléchargement de l'app, pas du nôtre : mesuré en phase 6, § D.
IDENTITE="$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'Developer ID Application' || true)"
echo "Signature et notarisation"
if [ "$IDENTITE" -gt 0 ]; then
  echo "  identité Developer ID Application trouvée sur cette machine"
else
  echo "  aucune identité « Developer ID Application » sur cette machine :"
  echo "    — il en faut une (compte développeur payant) pour signer ;"
  echo "    — sans elle, --signer s'arrête ici plutôt que de publier du non signé en le taisant."
fi
cat <<'NOTES'
  Ce qu'il faudrait, binaire par binaire (les ponts amont ne sont pas signés :
  les republier chez nous est justement ce qui permet de les signer) :
    codesign --force --options runtime --timestamp \
      --sign "Developer ID Application: <nom> (<équipe>)" <binaire>
    ditto -c -k --keepParent <binaire> <binaire>.zip
    xcrun notarytool submit <binaire>.zip --keychain-profile <profil> --wait
  Un binaire seul (pas un .app, pas un .dmg) ne peut pas être « stapled » :
  xcrun stapler n'agrafe que des paquets. Le ticket de notarisation reste donc
  en ligne, et Gatekeeper le demande au premier lancement — ce qui veut dire
  qu'une machine hors réseau évaluera le binaire sans ticket.
NOTES
if [ "$SIGNER" = 1 ] && [ "$IDENTITE" = 0 ]; then
  echo "!! --signer demandé sans identité : rien n'est publié." >&2
  exit 1
fi
echo

# --------------------------------------------------------------- gh release
echo "Ce qu'une publication exécuterait"
CMD_VOIR="gh release view $TAG --repo $DEPOT"
CMD_CREER="gh release create $TAG --repo $DEPOT --title 'Relais $TAG' --notes-file $DOSSIER/NOTES.md"
CMD_ENVOI="gh release upload $TAG --repo $DEPOT --clobber"
for nom in "${FICHIERS[@]}"; do CMD_ENVOI="$CMD_ENVOI '$DOSSIER/$nom'"; done
CMD_ENVOI="$CMD_ENVOI '$DOSSIER/SHA256SUMS'"
echo "  $CMD_VOIR   # existe déjà ?"
echo "  $CMD_CREER"
echo "  $CMD_ENVOI"
echo
echo "  Puis l'installeur pointe sur :"
echo "    https://github.com/$DEPOT/releases/latest/download/relais-install.sh"
echo "  (c'est l'adresse par défaut de install.sh et de RelaisInstallateur.releases)"
echo

if [ "$VRAIMENT" = 0 ]; then
  echo "(--dry-run : rien n'a été poussé. Publier : --vraiment, et c'est une décision.)"
  exit 0
fi

command -v gh >/dev/null || { echo "!! gh est nécessaire pour publier" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "!! gh n'est pas authentifié" >&2; exit 1; }
if ! eval "$CMD_VOIR" >/dev/null 2>&1; then eval "$CMD_CREER"; fi
eval "$CMD_ENVOI"
echo "✓ publié sur $DEPOT au tag $TAG"
