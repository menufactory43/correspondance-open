#!/usr/bin/env bash
# La release publiée correspond-elle encore au dépôt ?
#
#   bash infra/relais/tests/release-a-jour.sh          # dit, et sort 1 si non
#   bash infra/relais/tests/release-a-jour.sh --muet   # ne dit rien si tout va
#
# Pourquoi ce contrôle existe. `SHA256SUMS` prouve qu'un fichier téléchargé est
# bien celui qui a été publié — jamais qu'il correspond au code d'aujourd'hui.
# Le 2 septembre, `relais-install.sh` publié avait deux commits de retard : la
# commande d'installation posait encore cinq agents launchd et cinq
# notifications, une heure après que le dépôt ne le fasse plus. Rien ne le
# disait, parce que personne ne compare.
#
# Ce qu'on compare : les trois scripts, qui sont publiés tels quels et dont la
# somme se calcule des deux côtés. Les binaires ne se comparent pas ainsi (ils
# ne sont pas reproductibles au bit près) : pour eux on compare les **dates**,
# la construction devant être postérieure au dernier commit qui touche leurs
# sources.
#
# Le DMG n'est volontairement pas contrôlé. Il dépend de tout le code de l'app,
# donc il serait « en retard » à chaque commit, tous les jours : un
# avertissement permanent finit par ne plus se lire, et emporterait les autres
# avec lui. Ici on ne surveille que ce dont la péremption **casse une
# installation neuve** en silence.
set -euo pipefail

DEPOT="${CORRESPONDANCE_DEPOT:-menufactory43/correspondance-releases}"
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MUET=0
[ "${1:-}" = "--muet" ] && MUET=1

command -v gh >/dev/null || { [ "$MUET" = 1 ] || echo "release : gh absent, contrôle sauté"; exit 0; }
gh auth status >/dev/null 2>&1 || { [ "$MUET" = 1 ] || echo "release : gh non authentifié, contrôle sauté"; exit 0; }

INFOS="$(gh release view --repo "$DEPOT" --json tagName,publishedAt,assets 2>/dev/null)" || {
  [ "$MUET" = 1 ] || echo "release : $DEPOT injoignable, contrôle sauté"; exit 0;
}
TAG="$(printf '%s' "$INFOS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tagName"])')"

ecarts=()
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- les scripts, à la somme près
verifier_script() {
  local publie="$1" source="$2"
  if ! gh release download "$TAG" --repo "$DEPOT" -p "$publie" -D "$tmp" --clobber >/dev/null 2>&1; then
    ecarts+=("$publie : absent de la release $TAG")
    return
  fi
  local a b
  a="$(shasum -a 256 "$tmp/$publie" | awk '{print $1}')"
  b="$(shasum -a 256 "$ICI/$source" | awk '{print $1}')"
  [ "$a" = "$b" ] || ecarts+=("$publie : en retard sur $source")
}
verifier_script relais-install.sh   infra/relais/install.sh
verifier_script relais-uninstall.sh infra/relais/uninstall.sh
verifier_script install.sh          infra/agent/install.sh

# --- les binaires de l'agent, à la date près
publie_le() {
  printf '%s' "$INFOS" | python3 -c '
import json,sys
nom = sys.argv[1]
for asset in json.load(sys.stdin)["assets"]:
    if asset["name"] == nom:
        print(asset["updatedAt"]); break
' "$1"
}
SOURCES_AGENT="Packages/CorrespondanceCore/Sources infra/agent"
# `%cI` porte le décalage local, la release répond en UTC : on compare des
# secondes, jamais des chaînes — sinon « 21:26+02 » passe pour postérieur à
# « 14:29Z » par accident, et le contrôle dirait vrai pour de mauvaises raisons.
DERNIER_COMMIT="$(cd "$ICI" && git log -1 --format=%cI -- $SOURCES_AGENT 2>/dev/null || true)"
en_secondes() {
  python3 -c 'import datetime,sys; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' "$1"
}
lisible() {
  python3 -c 'import datetime,sys; print(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).astimezone().strftime("%d/%m %H:%M"))' "$1"
}
[ -n "$DERNIER_COMMIT" ] && COMMIT_S="$(en_secondes "$DERNIER_COMMIT")" || COMMIT_S=""
for binaire in correspondance-agent-linux-x86_64 correspondance-agent-macos-arm64; do
  quand="$(publie_le "$binaire")"
  if [ -z "$quand" ]; then
    ecarts+=("$binaire : absent de la release $TAG")
  elif [ -n "$COMMIT_S" ] && [ "$(en_secondes "$quand")" -lt "$COMMIT_S" ]; then
    ecarts+=("$binaire : publié le $(lisible "$quand"), les sources ont bougé le $(lisible "$DERNIER_COMMIT")")
  fi
done

if [ ${#ecarts[@]} -eq 0 ]; then
  [ "$MUET" = 1 ] || echo "release $TAG : à jour"
  exit 0
fi

echo
echo "⚠ La release publiée ($TAG) est en retard sur le dépôt :"
for e in "${ecarts[@]}"; do echo "   — $e"; done
echo "   Republier : infra/relais/construire.sh && infra/agent/construire.sh && infra/relais/publier.sh --vraiment"
exit 1
