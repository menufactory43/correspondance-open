#!/usr/bin/env bash
# Correspondance — réglages communs du Relais du spike « un clic ».
# Sourcé par tous les autres scripts de ce dossier. Aucune valeur ici n'est un secret :
# les secrets se génèrent dans SPIKE_HOME et n'entrent jamais dans le dépôt.

# Le spike vit à part : ni ~/.correspondance-agent/, ni le dossier de l'app.
SPIKE_HOME="${SPIKE_HOME:-$HOME/.correspondance-unclic}"

SERVER_NAME="${SERVER_NAME:-unclic.local}"
BIND_ADDRESS="${BIND_ADDRESS:-127.0.0.1}"
RELAIS_PORT="${RELAIS_PORT:-8010}"
RELAIS_URL="${RELAIS_URL:-http://127.0.0.1:${RELAIS_PORT}}"
MATRIX_USER="${MATRIX_USER:-essai}"
MATRIX_ADMIN="@${MATRIX_USER}:${SERVER_NAME}"

# Continuwuity : version épinglée. Les releases officielles ne portent QUE des
# binaires Linux (amd64/arm64) — sur macOS on construit depuis la source, au même tag.
CONTINUWUITY_TAG="${CONTINUWUITY_TAG:-v26.8.1}"
CONTINUWUITY_REPO="${CONTINUWUITY_REPO:-https://forgejo.ellis.link/continuwuation/continuwuity.git}"
# Les fonctionnalités par défaut (« standard ») supposent Linux : io_uring, systemd,
# journald. Sur macOS on prend le sous-ensemble portable.
CONTINUWUITY_FEATURES="${CONTINUWUITY_FEATURES:-brotli_compression,element_hacks,gzip_compression,media_thumbnail,ring,url_preview,zstd_compression,bindgen-runtime,console}"

# Ponts mautrix : les releases GitHub publient un binaire darwin-arm64 signé par un
# sha256sums.txt amont — pas de Go à installer, pas de cgo à construire. Le tag
# v0.2608.0 est le calver de la même livraison que le `v26.08` des images du NUC.
WHATSAPP_TAG="${WHATSAPP_TAG:-v0.2608.0}"
SIGNAL_TAG="${SIGNAL_TAG:-v0.2608.0}"
# Sommes relevées le 2 septembre 2026 dans les sha256sums.txt des releases amont.
WHATSAPP_SHA256="${WHATSAPP_SHA256:-938242a121df389706dc00e6cbdd9b6fedd267963e3eaddd2ee701c6ddeb4808}"
SIGNAL_SHA256="${SIGNAL_SHA256:-9d48db00fb3e7e7382d7b165a90e4952a6902d18ecf304436c29fc8cc216e586}"
WHATSAPP_PORT="${WHATSAPP_PORT:-29318}"
SIGNAL_PORT="${SIGNAL_PORT:-29328}"

# libolm : les binaires mautrix de macOS la chargent dynamiquement et Homebrew ne
# la porte plus. Construite au tag épinglé, posée à côté des binaires.
OLM_TAG="${OLM_TAG:-3.2.16}"
OLM_REPO="${OLM_REPO:-https://gitlab.matrix.org/matrix-org/olm.git}"

BIN_DIR="$SPIKE_HOME/bin"
RELAIS_DIR="$SPIKE_HOME/relais"
LOG_DIR="$SPIKE_HOME/logs"
RUN_DIR="$SPIKE_HOME/run"

dire() { printf '→ %s\n' "$*"; }
alerte() { printf '⚠ %s\n' "$*" >&2; }
mourir() { printf '✗ %s\n' "$*" >&2; exit 1; }

# Une somme relevée et affichée : la chaîne d'approvisionnement du spike se lit
# dans le rapport, pas dans un « ça marche chez moi ».
somme() { shasum -a 256 "$1" | awk '{print $1}'; }
