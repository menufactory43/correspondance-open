#!/usr/bin/env bash
# Correspondance — la machine crypto de `cc`, pour Linux, construite depuis ce Mac.
#
#   bash infra/relais/crypto-linux.sh              # construit et pose la .a
#   bash infra/relais/crypto-linux.sh --verifier   # ne construit rien, dit ce qui manque
#
# **Pourquoi ce script existe.** `matrix-sdk-crypto-ffi` est publié en un seul
# artefact : `MatrixSDKCryptoFFI.zip`, un XCFramework de tranches Apple. Sous
# Linux il n'y a rien à télécharger — et son `Sources/` ne contient même pas la
# carte de modules. Il faut donc construire la bibliothèque, une fois, et la
# poser à côté des en-têtes que le dépôt garde
# (`Sources/MatrixSDKCryptoFFILinux/include/`).
#
# **Ce qui n'était pas évident** :
#
#   1. On ne construit **que** le `staticlib` (`cargo rustc --crate-type
#      staticlib`). Le `cdylib` que le crate déclare aussi demanderait un
#      éditeur de liens Linux complet ; un `.a` ne demande que le compilateur.
#   2. La caisse `cc` de Rust passe elle-même `--target=x86_64-unknown-linux-musl`
#      au compilateur C — la triplette **Rust**, que zig refuse (« unable to
#      parse target query : UnknownOperatingSystem »). L'enveloppe ci-dessous
#      retire toute option `--target` reçue et impose celle de zig.
#   3. musl et non glibc, parce que le SDK Swift pour Linux (`swift sdk install`
#      du bundle `static-linux`) est lui-même en musl : les deux moitiés du
#      binaire final doivent parler la même libc. Le binaire qui en sort est
#      **statique**, donc il tourne sur n'importe quelle distribution — le NUC
#      est en glibc 2.36 et ne s'en aperçoit pas.
#
# Rien n'est installé hors de `$SRC` et `$SORTIE` ; rien ne touche la production.
set -euo pipefail

VERSION="matrix-sdk-crypto-ffi-0.17.0"   # la même qu'au manifeste (Package.swift)
CIBLE_RUST="x86_64-unknown-linux-musl"
CIBLE_ZIG="x86_64-linux-musl"
SRC="${CORRESPONDANCE_UNCLIC_SRC:-$HOME/.correspondance-unclic-src}"
SORTIE="${CORRESPONDANCE_CRYPTO_LINUX:-$HOME/.correspondance-unclic/crypto-linux/x86_64}"
DEPOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFIER=0
[ "${1:-}" = "--verifier" ] && VERIFIER=1

dire() { printf '→ %s\n' "$*"; }
mort() { printf '!! %s\n' "$*" >&2; exit 1; }

# --- ce qu'il faut sur la machine de construction ---------------------------
manque=""
command -v cargo >/dev/null || manque="$manque rustup/cargo"
command -v zig   >/dev/null || manque="$manque zig(brew install zig)"
[ -d "$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain" ] \
  || manque="$manque swift-6.3.3-RELEASE.xctoolchain"
swift sdk list 2>/dev/null | grep -q static-linux || manque="$manque swift-sdk(static-linux)"
if [ -n "$manque" ]; then
  cat >&2 <<'AIDE'
!! la chaîne Linux n'est pas complète sur cette machine. Ce qu'il faut, une fois :

   rustup target add x86_64-unknown-linux-musl
   brew install zig

   # La chaîne Swift open source — celle d'Xcode ne sert PAS : ses modules
   # Foundation sont d'une autre version que ceux du SDK, et `swift build`
   # s'arrête sur « compiled module was created by an older version ».
   curl -fLO https://download.swift.org/swift-6.3.3-release/xcode/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE-osx.pkg
   installer -pkg swift-6.3.3-RELEASE-osx.pkg -target CurrentUserHomeDirectory   # sans sudo

   # Le SDK Linux statique, à la version EXACTE de la chaîne ci-dessus.
   swift sdk install \
     https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
     --checksum 87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b

   Compter ~6 Gio de libre : 1,5 Gio de paquet, ~2,5 Gio de chaîne installée,
   ~1,2 Gio de `target/` Rust.
AIDE
  echo "   manque :$manque" >&2
  exit 1
fi
[ "$VERIFIER" = 1 ] && { dire "chaîne complète."; exit 0; }

# --- les sources, au tag épinglé --------------------------------------------
mkdir -p "$SRC"
if [ ! -d "$SRC/matrix-rust-sdk/.git" ]; then
  dire "clonage de matrix-rust-sdk au tag $VERSION"
  git clone --depth 1 --branch "$VERSION" \
    https://github.com/matrix-org/matrix-rust-sdk.git "$SRC/matrix-rust-sdk"
fi
dire "source : $(git -C "$SRC/matrix-rust-sdk" log --oneline -1)"

# --- l'enveloppe zig ---------------------------------------------------------
W="$SRC/zig-wrappers"
mkdir -p "$W"
cat > "$W/zcc-musl" <<EOF
#!/bin/sh
# Retire le --target que la caisse \`cc\` de Rust ajoute (triplette Rust, que
# zig ne sait pas lire) et impose celle de zig.
args=""
skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in
    --target=*) continue ;;
    -target) skip=1; continue ;;
  esac
  args="\$args
\$a"
done
IFS='
'
set -f
exec zig cc -target $CIBLE_ZIG \$args
EOF
printf '#!/bin/sh\nexec zig ar "$@"\n'     > "$W/zar"
printf '#!/bin/sh\nexec zig ranlib "$@"\n' > "$W/zranlib"
chmod +x "$W/zcc-musl" "$W/zar" "$W/zranlib"

# --- la bibliothèque ---------------------------------------------------------
dire "cargo rustc --crate-type staticlib pour $CIBLE_RUST (compter ~2 min)"
(
  cd "$SRC/matrix-rust-sdk"
  export PATH="$W:$PATH"
  export CARGO_TARGET_DIR="$SRC/rust-target"
  export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="$W/zcc-musl"
  export CC_x86_64_unknown_linux_musl="$W/zcc-musl"
  export AR_x86_64_unknown_linux_musl="$W/zar"
  export CFLAGS_x86_64_unknown_linux_musl="-D_GNU_SOURCE"
  cargo rustc -p matrix-sdk-crypto-ffi --lib --release \
    --target "$CIBLE_RUST" --crate-type staticlib
)

A="$SRC/rust-target/$CIBLE_RUST/release/libmatrix_sdk_crypto_ffi.a"
[ -f "$A" ] || mort "la bibliothèque n'est pas là : $A"
mkdir -p "$SORTIE"
cp "$A" "$SORTIE/"
dire "posée : $SORTIE/libmatrix_sdk_crypto_ffi.a"
ls -l "$SORTIE/libmatrix_sdk_crypto_ffi.a"
shasum -a 256 "$SORTIE/libmatrix_sdk_crypto_ffi.a"

# La somme n'est pas épinglée dans le dépôt, et c'est délibéré : `cargo` n'est
# pas reproductible au bit près d'une machine à l'autre (mêmes raisons qu'en
# phase 6 pour Continuwuity — le chemin de construction est embarqué). On la
# relève à chaque construction, on ne la suppose jamais.

cat <<FIN

Construire \`cc\` pour Linux, avec la crypto :

  TC=\$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin
  cd $DEPOT/Packages/CorrespondanceCore
  CORRESPONDANCE_CRYPTO=1 CORRESPONDANCE_CRYPTO_LINUX=$SORTIE \\
    \$TC/swift build --product correspondance-agent -c release \\
    --swift-sdk x86_64-swift-linux-musl --scratch-path /tmp/build-unclic-linux-crypto
FIN
