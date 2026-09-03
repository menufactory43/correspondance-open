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
  "mautrix-twitter-darwin-arm64:"
  "mautrix-slack-darwin-arm64:"
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
  elif [ "$VRAIMENT" = 1 ]; then
    echo "!! rien n'est publié : commit d'abord, pour qu'un binaire ait une version." >&2
    exit 1
  else
    echo "  (--dry-run : rien ne part, mais --vraiment refuserait ici)"
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
  elif [ "$VRAIMENT" = 1 ]; then
    echo "!! rien n'est publié. --quand-meme pour passer outre, en le sachant." >&2
    exit 1
  else
    echo "  (--dry-run : rien ne part, mais --vraiment refuserait ici)"
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
#
# Un binaire seul (pas un .app, pas un .dmg) ne peut pas être agrafé : `stapler`
# n'agrafe que des paquets. Le ticket reste donc en ligne, et Gatekeeper le
# demande au premier lancement — une machine hors réseau évaluera le binaire
# sans ticket.
#
# Ce bloc **signe** au lieu de dire comment signer. Il l'a longtemps imprimé :
# les six binaires du Relais ont été signés à la main, et les deux de l'agent,
# déposés après coup, ne l'ont jamais été. Un binaire ad-hoc n'est pas signé du
# tout — `flags=0x20002(adhoc,linker-signed)` est ce que le linker pose d'office
# sur arm64.
IDENTITE="$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'Developer ID Application' || true)"
NOTARY_PROFILE="${CORRESPONDANCE_NOTARY_PROFILE:-notarisation}"
echo "Signature et notarisation"
if [ "$SIGNER" = 1 ] && [ "$IDENTITE" = 0 ]; then
  echo "!! --signer demandé sans identité « Developer ID Application » sur cette machine." >&2
  echo "   Il en faut une (compte développeur payant) ; rien n'est publié." >&2
  exit 1
fi

# Pas de `| grep -q` ici : `grep -q` ferme le tuyau dès qu'il trouve, `codesign`
# reçoit un SIGPIPE, et `pipefail` rend 141 — un binaire signé passait donc pour
# non signé, et on aurait re-signé puis re-notarisé les six pour rien. On lit
# une fois, on cherche dans la chaîne.
contient() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac }
deja_signe() { contient "Authority=Developer ID Application" "$(codesign -dvv "$1" 2>&1 || true)"; }
est_macho() { contient "Mach-O" "$(file "$1" 2>/dev/null || true)"; }
A_SIGNER=()
for nom in "${FICHIERS[@]}"; do
  f="$DOSSIER/$nom"
  # Le DMG est signé et notarisé par scripts/release-mac.sh, qui sait l'agrafer.
  # Un ELF ne se signe pas : la tranche Linux de l'agent reste nue, et c'est
  # sans objet — Gatekeeper n'existe pas là-bas.
  case "$nom" in *.dmg) continue ;; esac
  est_macho "$f" || continue
  if deja_signe "$f"; then
    printf '  ✓ %-34s déjà signé Developer ID\n' "$nom"
  else
    printf '  ○ %-34s pas signé (ad-hoc)\n' "$nom"
    A_SIGNER+=("$nom")
  fi
done

if [ ${#A_SIGNER[@]} -gt 0 ] && [ "$SIGNER" = 0 ]; then
  echo "  → ${#A_SIGNER[@]} binaire(s) à signer : relance avec --signer (profil notarytool « $NOTARY_PROFILE »)"
fi

if [ "$SIGNER" = 1 ] && [ ${#A_SIGNER[@]} -gt 0 ]; then
  for nom in "${A_SIGNER[@]}"; do
    codesign --force --options runtime --timestamp --sign "Developer ID Application" "$DOSSIER/$nom"
    printf '  ✎ %-34s signé\n' "$nom"
  done
  # Une seule soumission pour tout le lot : notarytool accepte une archive qui
  # porte plusieurs binaires, et chaque aller-retour coûte des minutes.
  LOT="$(mktemp -d)"; mkdir -p "$LOT/lot"
  for nom in "${A_SIGNER[@]}"; do cp -f "$DOSSIER/$nom" "$LOT/lot/$nom"; done
  ditto -c -k --keepParent "$LOT/lot" "$LOT/lot.zip"
  echo "  → notarisation du lot (profil « $NOTARY_PROFILE ») — quelques minutes"
  xcrun notarytool submit "$LOT/lot.zip" --keychain-profile "$NOTARY_PROFILE" --wait > "$LOT/notarisation.txt" 2>&1 || true
  grep -E '^ *(id|status|message):' "$LOT/notarisation.txt" | sed 's/^/    /'
  # Le dernier `status:` est le verdict ; les précédents sont ceux de l'attente.
  STATUT="$(grep -E '^ *status:' "$LOT/notarisation.txt" | tail -1 | awk '{print $2}')"
  cp -f "$LOT/notarisation.txt" "$DOSSIER/notarisation.log" 2>/dev/null || true
  rm -rf "$LOT"
  [ "$STATUT" = "Accepted" ] || { echo "!! notarisation non acceptée ($STATUT) — rien n'est publié." >&2; exit 1; }
  # Signer change les octets : les sommes d'avant ne valent plus rien.
  ( cd "$DOSSIER" && rm -f SHA256SUMS &&
    for f in *; do
      case "$f" in SHA256SUMS|NOTES.md|construction.log|*.log) continue ;; esac
      printf '%s  %s\n' "$(somme "$f")" "$f"
    done > SHA256SUMS )
  echo "  ✓ SHA256SUMS régénéré après signature"
fi
echo

# ------------------------------------------------------------ le corps du texte
# Le corps de la release se périmait en silence : `gh release create` ne le pose
# qu'à la **création**, et une republication (`--clobber`) ne remplace que les
# fichiers. Le texte du 2 septembre annonçait donc « la pile du Relais » sur une
# release qui portait aussi l'agent, sa crypto et le DMG, et citait une seule
# soumission de notarisation quand il y en avait trois.
#
# Il s'engendre maintenant à chaque publication : une prose tenue à la main
# (`infra/relais/NOTES-preambule.md`, où l'on écrit ce qu'on veut dire) et un
# inventaire relevé sur les fichiers eux-mêmes — nom, poids, signature, somme.
# Ce qui se vérifie ne s'écrit pas à la main.
NOTES="$DOSSIER/NOTES.md"
{
  sed "s/\$TAG/$TAG/g" "$ICI/infra/relais/NOTES-preambule.md"
  echo
  echo "## Ce que cette release contient"
  echo
  echo "| Fichier | Poids | Signature |"
  echo "| --- | --- | --- |"
  for nom in "${FICHIERS[@]}"; do
    f="$DOSSIER/$nom"
    poids="$(du -h "$f" | cut -f1 | tr -d ' ')"
    nature="$(file "$f" 2>/dev/null || true)"
    case "$nom" in
      *.dmg) etat="image disque, signée et agrafée" ;;
      *)
        if est_macho "$f"; then
          if deja_signe "$f"; then etat="Developer ID, notarisé"; else etat="⚠ non signé"; fi
        elif contient "ELF" "$nature"; then
          # Statique ou non : c'est ce qui décide si le binaire tourne sur une
          # distribution dont la glibc est plus vieille que la nôtre.
          if contient "statically linked" "$nature"; then
            etat="ELF statique — un ELF ne se signe pas"
          else
            etat="ELF dynamique — un ELF ne se signe pas"
          fi
        else
          etat="script, vérifié par sa somme"
        fi ;;
    esac
    printf '| `%s` | %s | %s |\n' "$nom" "$poids" "$etat"
  done
  echo
  echo "Sommes SHA-256 : \`SHA256SUMS\`. Publié le $(date '+%d/%m/%Y à %H:%M')."
} > "$NOTES"
echo "Corps de la release engendré ($(wc -l < "$NOTES" | tr -d ' ') lignes)"
echo

# --------------------------------------------------------------- gh release
echo "Ce qu'une publication exécuterait"
CMD_VOIR="gh release view $TAG --repo $DEPOT"
CMD_CREER="gh release create $TAG --repo $DEPOT --title 'Correspondance $TAG' --notes-file $NOTES"
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
if ! eval "$CMD_VOIR" >/dev/null 2>&1; then
  eval "$CMD_CREER"
else
  # `--clobber` ne remplace que les fichiers : sans ceci, le texte reste celui
  # de la première publication, pour toujours.
  gh release edit "$TAG" --repo "$DEPOT" --notes-file "$NOTES" >/dev/null
  echo "  corps de la release mis à jour"
fi
eval "$CMD_ENVOI"
echo "✓ publié sur $DEPOT au tag $TAG"
