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
#   tailcat-darwin-arm64                     l'amont ne publie pas macOS (tap Homebrew)
#   install.sh, correspondance-agent-*       l'agent : `latest` ne sert QUE la dernière
#                                            release, donc publier le Relais seul rend
#                                            404 à l'installeur de cc (vu le 2 sept.)
#   SHA256SUMS                               relevé sur les fichiers publiés, pas ailleurs
# Rien pour Linux côté Relais : les releases amont suffisent, et l'installeur les prend là.
#
# Deux refus, parce qu'une release muette est pire qu'une release absente :
#   — un script publié qui diffère de celui du dépôt (on publierait l'installeur
#     d'hier en croyant publier celui d'aujourd'hui) ;
#   — un fichier attendu qui manque du dossier (on viderait `latest`).
# `--quand-meme` lève les deux, et le dit.
set -euo pipefail

DOSSIER="${CORRESPONDANCE_PUBLICATION:-$HOME/unclic-publication}"
DEPOT="${CORRESPONDANCE_DEPOT:-menufactory43/correspondance-releases}"
TAG="relais-$(date +%Y.%m.%d)"
VRAIMENT=0
SIGNER=0
QUAND_MEME=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) VRAIMENT=0 ;;
    --vraiment) VRAIMENT=1 ;;
    --signer) SIGNER=1 ;;
    --quand-meme) QUAND_MEME=1 ;;
    --dossier) DOSSIER="$2"; shift ;;
    --depot) DEPOT="$2"; shift ;;
    --tag) TAG="$2"; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "!! option inconnue : $1" >&2; exit 2 ;;
  esac
  shift
done

[ -d "$DOSSIER" ] || { echo "!! $DOSSIER n'existe pas — lance d'abord infra/relais/construire.sh" >&2; exit 1; }
somme() { shasum -a 256 "$1" | awk '{print $1}'; }
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ------------------------------------------------- une release porte le produit
# `releases/latest/download/<fichier>` ne sert que la release **la plus
# récente** : publier le Relais seul le 2 septembre a rendu 404 à l'installeur
# de cc pendant vingt minutes, parce que ses fichiers vivaient dans la release
# d'avant. Une release porte donc tout, et ce tableau dit d'où vient chaque
# chose — la colonne de gauche est le nom publié, celle de droite sa source
# dans le dépôt quand il y en a une.
declare -a ATTENDUS=(
  "relais-install.sh:infra/relais/install.sh"
  "relais-uninstall.sh:infra/relais/uninstall.sh"
  "install.sh:infra/agent/install.sh"
  "continuwuity-macos-arm64:"
  "mautrix-whatsapp-darwin-arm64:"
  "mautrix-signal-darwin-arm64:"
  "mautrix-meta-darwin-arm64:"
  "mautrix-instagram-darwin-arm64:"
  "tailcat-darwin-arm64:"
  "correspondance-agent-linux-x86_64:"
  "correspondance-agent-macos-arm64:"
)

# ------------------------------------------------- publier ce qui est commité
# Un binaire construit depuis un arbre sale ne correspond à aucun commit : le
# jour où il se comporte mal, il n'y a rien à relire. Ce n'est pas une manie de
# propreté — c'est la seule façon de répondre à « quelle version tourne chez
# lui ? ».
SALE="$(cd "$ICI" && git status --porcelain 2>/dev/null | grep -v '^?? ' || true)"
if [ -n "$SALE" ]; then
  echo "L'arbre de travail n'est pas propre :"
  printf '%s\n' "$SALE" | sed 's/^/    /' | head -12
  if [ "$QUAND_MEME" = 1 ]; then
    echo "  (--quand-meme : on publie quand même, sans commit qui corresponde)"
  else
    echo "!! rien n'est publié : commit d'abord, pour qu'un binaire ait une version." >&2
    exit 1
  fi
  echo
fi

echo "Ce que la release doit porter"
manques=0
derives=0
for entree in "${ATTENDUS[@]}"; do
  nom="${entree%%:*}"; source="${entree#*:}"
  if [ ! -f "$DOSSIER/$nom" ]; then
    printf '  ✗ %-34s absent du dossier\n' "$nom"
    manques=$((manques+1))
    continue
  fi
  # Un script publié doit être celui du dépôt, au bit près. Sinon on publie
  # l'installeur d'hier en croyant publier celui d'aujourd'hui — c'est
  # exactement ce qui rendait `relais-install.sh` vieux de deux commits.
  if [ -n "$source" ] && [ -f "$ICI/$source" ]; then
    if [ "$(somme "$DOSSIER/$nom")" = "$(somme "$ICI/$source")" ]; then
      printf '  ✓ %-34s = %s\n' "$nom" "$source"
    else
      printf '  ✗ %-34s ≠ %s (le dossier a une autre version)\n' "$nom" "$source"
      derives=$((derives+1))
    fi
  else
    printf '  ✓ %-34s\n' "$nom"
  fi
done
if [ "$manques" -gt 0 ] || [ "$derives" -gt 0 ]; then
  echo
  echo "  $manques absent(s), $derives dérive(s)."
  [ "$manques" -gt 0 ] && echo "  → les binaires du Relais : infra/relais/construire.sh"
  [ "$manques" -gt 0 ] && echo "  → ceux de l'agent : infra/agent/construire.sh"
  [ "$derives" -gt 0 ] && echo "  → un script qui dérive se recopie : les deux construire.sh le font"
  if [ "$QUAND_MEME" = 1 ]; then
    echo "  (--quand-meme : on continue quand même)"
  else
    echo "!! rien n'est publié. --quand-meme pour passer outre, en le sachant." >&2
    exit 1
  fi
fi
echo

echo "Publication du Relais Correspondance"
echo "  dossier   $DOSSIER"
echo "  dépôt     $DEPOT"
echo "  tag       $TAG"
echo

echo "Les fichiers, et leurs sommes"
FICHIERS=()
while IFS= read -r f; do
  nom="$(basename "$f")"
  case "$nom" in SHA256SUMS|NOTES.md|*.log) continue ;; esac
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
