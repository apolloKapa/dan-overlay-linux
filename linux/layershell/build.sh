#!/usr/bin/env bash
# Builds libdanlayer.so and KDE's LayerShellQt against Qt $QT_VERSION (must be the Qt PyQt6 ships,
# since LayerShellQt uses Qt's private Wayland API) into linux/layershell/out. Run by CI.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QT_VERSION="${QT_VERSION:-6.11.2}"
LSQ_TAG="${LSQ_TAG:-v6.8.2}"
ECM_TAG="${ECM_TAG:-v6.31.0}"
WORK="$HERE/work"
OUT="$HERE/out"
mkdir -p "$WORK" "$OUT"

python3 -m pip install -q aqtinstall
[[ -d "$WORK/qt/$QT_VERSION" ]] || python3 -m aqt install-qt linux desktop "$QT_VERSION" linux_gcc_64 --outputdir "$WORK/qt"
QT_DIR="$(ls -d "$WORK/qt/$QT_VERSION"/*/ | head -1)"
PREFIX="$WORK/prefix"

if [[ ! -d "$WORK/ecm" ]]; then
    git clone -q --depth 1 --branch "$ECM_TAG" https://invent.kde.org/frameworks/extra-cmake-modules.git "$WORK/ecm"
fi
cmake -S "$WORK/ecm" -B "$WORK/ecm-build" -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_TESTING=OFF -DBUILD_HTML_DOCS=OFF -DBUILD_MAN_DOCS=OFF -DBUILD_QTHELP_DOCS=OFF >/dev/null
cmake --build "$WORK/ecm-build" >/dev/null
cmake --install "$WORK/ecm-build" >/dev/null

if [[ ! -d "$WORK/lsq" ]]; then
    git clone -q --depth 1 --branch "$LSQ_TAG" https://invent.kde.org/plasma/layer-shell-qt.git "$WORK/lsq"
fi
cmake -S "$WORK/lsq" -B "$WORK/lsq-build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_PREFIX_PATH="$QT_DIR;$PREFIX" -DBUILD_TESTING=OFF
cmake --build "$WORK/lsq-build" -j"$(nproc)"
cmake --install "$WORK/lsq-build"

cmake -S "$HERE" -B "$WORK/shim-build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_PREFIX_PATH="$QT_DIR;$PREFIX"
cmake --build "$WORK/shim-build"
cmake --install "$WORK/shim-build"

# only what the app loads: the shim and LayerShellQt's interface library
cp -L "$PREFIX"/lib*/libdanlayer.so "$OUT/"
cp -L "$(ls "$PREFIX"/lib*/libLayerShellQtInterface.so.6 | head -1)" "$OUT/"
ls -la "$OUT"
