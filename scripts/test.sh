#!/bin/zsh
# Lance les tests unitaires en injectant le bundle XCTest dans l'app host.
# Contourne « Assertion failed: childPID > 0 » (IDELaunchServicesLauncher) d'xcodebuild test sur Xcode 26.x.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
# Les tests de CorrespondanceCore / CorrespondanceUI vivent dans le paquet : Xcode
# ne sait pas les mettre dans le scheme de l'app, `swift test` s'en charge.
swift test --package-path Packages/CorrespondanceCore 2>&1 | grep -E "error:|Executed .* tests, with"
xcodebuild -project Correspondance.xcodeproj -scheme Correspondance -configuration Debug \
  -destination 'platform=macOS' build-for-testing 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
DD=$(xcodebuild -project Correspondance.xcodeproj -scheme Correspondance -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')
APP="$DD/Correspondance.app"
XCT="$APP/Contents/PlugIns/CorrespondanceTests.xctest"
PLAT="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
pkill -f "$APP/Contents/MacOS/Correspondance" 2>/dev/null || true
DYLD_FRAMEWORK_PATH="$PLAT/Library/Frameworks" \
DYLD_LIBRARY_PATH="$PLAT/usr/lib" \
DYLD_INSERT_LIBRARIES="$PLAT/usr/lib/libXCTestBundleInject.dylib" \
XCInjectBundleInto="$APP/Contents/MacOS/Correspondance" \
"$APP/Contents/MacOS/Correspondance" -XCTest All "$XCT" 2>&1 \
  | grep -E "Test Case .* (passed|failed)|error:|Executed .* tests|Test Suite 'All tests' (passed|failed)" | sort -u

# Ce que le monde télécharge correspond-il à ce qu'on vient de tester ? Le
# contrôle est ici parce que c'est ici qu'on regarde : une release en retard ne
# se voit nulle part ailleurs, et le 2 septembre l'installeur publié a gardé
# deux commits de retard sans que rien ne le dise. Il ne fait jamais échouer la
# suite — le code est bon, c'est la publication qui traîne.
bash infra/relais/tests/release-a-jour.sh --muet || true
