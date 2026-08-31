#!/bin/zsh
# Exerce le chemin du push sur le simulateur, sans NUC ni APNs.
#
# Deux choses à savoir avant de lire ce script :
#
# 1. `xcrun simctl push` NE RÉVEILLE PAS une extension de service. Il livre la
#    notification telle quelle : ce qu'on voit alors, c'est la clé de traduction
#    brute de Sygnal (« SINGLE_UNREAD »). Vérifié sur iOS 26.3.
# 2. C'est pourquoi l'écran de démonstration `notification` rejoue, dans l'app,
#    la MÊME fonction de Core que l'extension (`PushNotification.resolve`) :
#    lire l'événement, composer « {expéditeur} · {réseau} : {texte} ».
#
# Usage : scripts/push-demo.sh [UDID]
set -euo pipefail
cd "$(dirname "$0")/.."
UDID="${1:-C6ED30D4-2046-45F4-9815-51E6905FEFF4}"

cat > /tmp/correspondance-push.apns <<'JSON'
{
  "Simulator Target Bundle": "com.correspondance.ios",
  "aps": { "alert": { "loc-key": "SINGLE_UNREAD", "loc-args": [] }, "mutable-content": 1, "sound": "default" },
  "room_id": "!dm-alice:correspondance.local",
  "event_id": "$msg-alice-1",
  "unread": 1
}
JSON
echo "→ charge utile Sygnal (event_id_only) :"
cat /tmp/correspondance-push.apns
xcrun simctl push "$UDID" com.correspondance.ios /tmp/correspondance-push.apns
