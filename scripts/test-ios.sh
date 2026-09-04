#!/bin/zsh
# Le test d'interface de l'app iOS, sur le simulateur iPhone 17.
# Séparé de scripts/test.sh : il allume un simulateur et prend une minute,
# là où les tests unitaires (Mac + Core) tiennent en dix secondes.
set -euo pipefail
cd "$(dirname "$0")/.."
UDID="${1:-C6ED30D4-2046-45F4-9815-51E6905FEFF4}"
xcodegen generate >/dev/null
CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj -scheme 'Correspondance iOS' -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath /tmp/dd-ios test 2>&1 \
  | grep -E "Test Case .* (passed|failed)|error:|Executed .* tests|TEST (SUCCEEDED|FAILED)"
