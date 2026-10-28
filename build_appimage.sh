#!/usr/bin/env bash
# Linux counterpart of build.bat: dist/DanOverlay-x86_64.AppImage, a PyInstaller bundle (Python,
# pywebview with its Qt WebEngine backend, numpy/pandas, the skins and configs, msd.exe) in an AppDir.
# GitHub Actions runs this on every v* tag (.github/workflows/appimage.yml); locally it needs python3
# and appimagetool (APPIMAGETOOL=/path/to/appimagetool, or on PATH).
#   ./build_appimage.sh            full build
#   ./build_appimage.sh --appdir   stop after the AppDir (no appimagetool needed)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

BUILD_DIR="build/appimage"
APPDIR="$BUILD_DIR/DanOverlay.AppDir"
VENV_DIR="$BUILD_DIR/venv"
VERSION="${DANOVERLAY_VERSION:-$(git describe --tags --always 2>/dev/null || echo dev)}"
ENTRY="src/01_overlay_ui/main.py"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/python" -m pip install -q --upgrade pip
# PyQt6's Qt version pinned: linux/layershell builds LayerShellQt against this exact Qt (QT_VERSION)
"$VENV_DIR/bin/python" -m pip install -q pyinstaller "pywebview[qt]" PyQt6==6.11.0 PyQt6-Qt6==6.11.2 \
    PyQt6-WebEngine==6.11.0 PyQt6-WebEngine-Qt6==6.11.2 requests pillow numpy pandas websocket-client tzdata

"$VENV_DIR/bin/python" - src/01_overlay_ui/web/graph.ico "$BUILD_DIR/danoverlay.png" <<'EOF'
import sys
from PIL import Image
ico = Image.open(sys.argv[1])
ico.size = max(ico.info.get("sizes", [ico.size]))
ico.convert("RGBA").resize((256, 256), Image.LANCZOS).save(sys.argv[2])
EOF

# Same data, paths and hidden imports as build.bat, minus the Windows-only parts (pythonnet,
# ffmpeg.exe: the audio visualizer uses the system's ffmpeg on Linux). onedir: nothing to unpack
# to /tmp on every start.
"$VENV_DIR/bin/pyinstaller" \
    --noconfirm \
    --clean \
    --onedir \
    --name danoverlay \
    --distpath "$BUILD_DIR/dist" \
    --workpath "$BUILD_DIR/work" \
    --specpath "$BUILD_DIR" \
    --add-data "$ROOT_DIR/src/01_overlay_ui/web:web" \
    --add-data "$ROOT_DIR/config:config" \
    --add-data "$ROOT_DIR/src/02_runtime_bridge/etterna/bridges:bridges" \
    --add-data "$ROOT_DIR/src/02_runtime_bridge/etterna/bridges:src/02_runtime_bridge/etterna/bridges" \
    --add-data "$ROOT_DIR/tools/bin/msd.exe:." \
    --paths src \
    --paths src/01_overlay_ui \
    --paths src/02_runtime_bridge \
    --paths src/02_runtime_bridge/etterna \
    --paths src/03_engine_reference \
    --paths src/07_model \
    --paths src/08_isor_engine \
    --hidden-import sr_core --hidden-import sr_core.algorithm --hidden-import sr_core.osu_file_parser \
    --hidden-import events --hidden-import contracts --hidden-import tosu_source \
    --hidden-import analysis_coordinator --hidden-import bridge --hidden-import audio_service \
    --hidden-import chart_export --hidden-import overlay_host --hidden-import wine_compat \
    --hidden-import linux_pin \
    --hidden-import parser --hidden-import validator --hidden-import feature_extractor \
    --hidden-import primary_sr_bridge --hidden-import classifier --hidden-import rhythm_profile \
    --hidden-import rank_engine --hidden-import minacalc_estimator --hidden-import minacalc_bridge \
    --hidden-import celestial_estimator --hidden-import signicial_estimator \
    --hidden-import shoegazer_estimator --hidden-import ln_course_estimator \
    --hidden-import resource_path --hidden-import isor_engine --hidden-import strain \
    --hidden-import etterna --hidden-import etterna.sm_parser --hidden-import etterna.etterna_source \
    --hidden-import etterna.etterna_installer \
    --hidden-import webview --hidden-import webview.platforms.qt --hidden-import qtpy \
    --hidden-import PyQt6.QtWebEngineWidgets --hidden-import PyQt6.QtWebChannel \
    --hidden-import websocket --hidden-import requests --hidden-import bottle --hidden-import proxy_tools \
    --collect-data pandas --collect-data tzdata --collect-all webview \
    --exclude-module tkinter --exclude-module numpy.f2py --exclude-module pytest \
    --exclude-module webview.platforms.gtk --exclude-module webview.platforms.cef \
    --exclude-module webview.platforms.winforms --exclude-module webview.platforms.edgechromium \
    --exclude-module webview.platforms.mshtml --exclude-module webview.platforms.cocoa \
    --exclude-module webview.platforms.android --exclude-module gi \
    --exclude-module PIL._avif --exclude-module PIL.AvifImagePlugin \
    --exclude-module PyQt6.QtQml --exclude-module PyQt6.QtQuick3D --exclude-module PyQt6.QtMultimedia \
    --exclude-module PyQt6.QtBluetooth --exclude-module PyQt6.QtPdf --exclude-module PyQt6.QtDesigner \
    "$ENTRY"

INTERNAL="$BUILD_DIR/dist/danoverlay/_internal"
# Tcl extensions other packages install next to Tcl (graphviz's on Arch) can come along; and the
# libraries AppImages take from the host (the AppImage excludelist): an older bundled fontconfig
# can't read a newer distro's font config, X11 has to match the server, and the graphics stack
# (GL/EGL/GBM/DRM) has to match the host's drivers, which also need the host's newer libstdc++
# (with the build distro's one, Mesa's EGL fails to load and Qt WebEngine gets no GL at all)
rm -rf "$INTERNAL/_tcl_data/graphviz"
# Qt's UI translations aren't used (the overlay is HTML); Chromium only needs its English locale
QT_TR="$INTERNAL/PyQt6/Qt6/translations"
find "$QT_TR" -maxdepth 1 -type f -delete
find "$QT_TR/qtwebengine_locales" -type f ! -name 'en-US.pak' -delete
# Qt's GTK theme plugin pulls in GTK (and with it a second ICU); the HTML overlay has no native widgets
rm -f "$INTERNAL/PyQt6/Qt6/plugins/platformthemes/libqgtk3.so"
for lib in libfontconfig.so.1 libfreetype.so.6 libexpat.so.1 libz.so.1 libuuid.so.1 \
           libX11.so.6 libX11-xcb.so.1 libxcb.so.1 libXau.so.6 libXdmcp.so.6 libXext.so.6 \
           libXrender.so.1 libXft.so.2 libXss.so.1 \
           libstdc++.so.6 libgcc_s.so.1 libGL.so.1 libGLX.so.0 libGLdispatch.so.0 libEGL.so.1 \
           libgbm.so.1 libdrm.so.2 libasound.so.2; do
    rm -f "$INTERNAL/$lib"
done

# then any bundled library nothing else needs any more
"$VENV_DIR/bin/python" - "$INTERNAL" <<'EOF'
import os, subprocess, sys
root = sys.argv[1]
def needed(path):
    out = subprocess.run(["readelf", "-d", path], capture_output=True, text=True).stdout
    return {l.split("[")[1].split("]")[0] for l in out.splitlines() if "(NEEDED)" in l}
def elf(path):
    with open(path, "rb") as f:
        return f.read(4) == b"\x7fELF"
while True:
    files = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs]
    used = set()
    for f in files:
        if not os.path.islink(f) and elf(f):
            used |= needed(f)
    top = [f for f in os.listdir(root) if f.startswith("lib") and ".so" in f]
    # NSS modules are dlopened by Chromium (QtWebEngine), not linked
    keep = ("libpython", "libsoftokn3", "libfreebl", "libnssckbi", "libnssdbm3")
    unused = [f for f in top if f not in used and not f.startswith(keep)]
    if not unused:
        break
    for f in unused:
        os.remove(os.path.join(root, f))
    print("pruned:", " ".join(sorted(unused)))
EOF

# pinning above fullscreen games (linux_pin.py): LayerShellQt + libdanlayer.so, next to the Qt
# they were built for. CI builds them with linux/layershell/build.sh before this script runs.
LAYERSHELL_OUT="$ROOT_DIR/linux/layershell/out"
if [[ -f "$LAYERSHELL_OUT/libdanlayer.so" ]]; then
    cp "$LAYERSHELL_OUT"/*.so* "$INTERNAL/PyQt6/Qt6/lib/"
else
    echo "WARNING: linux/layershell/out missing: the overlay can't pin above fullscreen games"
fi

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/lib" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -r "$BUILD_DIR/dist/danoverlay" "$APPDIR/usr/lib/danoverlay"
cp LICENSE "$APPDIR/usr/lib/danoverlay/LICENSE"
cp "$BUILD_DIR/danoverlay.png" "$APPDIR/danoverlay.png"
cp "$BUILD_DIR/danoverlay.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/danoverlay.png"
ln -sf danoverlay.png "$APPDIR/.DirIcon"

cat >"$APPDIR/danoverlay.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=DanOverlay
GenericName=osu!mania dan overlay
Comment=Real-time dan rank and star rating overlay for osu!mania 4K/7K (needs tosu)
Exec=danoverlay
Icon=danoverlay
Terminal=false
Categories=Game;Utility;
X-AppImage-Version=$VERSION
EOF
cp "$APPDIR/danoverlay.desktop" "$APPDIR/usr/share/applications/danoverlay.desktop"

cat >"$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/lib/danoverlay/danoverlay" "$@"
EOF
chmod +x "$APPDIR/AppRun"

if [[ "${1:-}" == "--appdir" ]]; then
    echo "AppDir ready: $APPDIR"
    exit 0
fi

TOOL="${APPIMAGETOOL:-$(command -v appimagetool || true)}"
[[ -n "$TOOL" ]] || { echo "appimagetool not found (set APPIMAGETOOL)"; exit 1; }
mkdir -p dist
ARCH=x86_64 VERSION="$VERSION" "$TOOL" --no-appstream "$APPDIR" dist/DanOverlay-x86_64.AppImage
echo "Built dist/DanOverlay-x86_64.AppImage ($VERSION)"
