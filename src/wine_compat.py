# wine_compat.py -- Linux support: osu! and tosu usually run under Wine there (osu-winello).
#
# - tosu running under Wine reports Windows paths (D:\Songs\...): wine_to_unix_path() maps the
#   drive letter through the Wine prefix's dosdevices links.
# - msd.exe (MinaCalc) is a Windows program: wine_command() runs it through Wine, preferring
#   osu-winello's own Wine and osu!'s prefix (where msd.exe's VC++ runtime is available).
#
# On Windows every function here is a no-op.

import os
import shutil
import sys

IS_WINDOWS = sys.platform == "win32"


def _data_home() -> str:
    return os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")


def find_wine() -> str | None:
    """Wine to run msd.exe with: DANOVERLAY_WINE, osu-winello's own Wine, then the system's."""
    env_wine = os.environ.get("DANOVERLAY_WINE")
    if env_wine:
        return env_wine
    winello = os.path.join(_data_home(), "osuconfig", "wine-osu", "bin", "wine")
    if os.access(winello, os.X_OK):
        return winello
    return shutil.which("wine64") or shutil.which("wine")


def wine_prefix() -> str | None:
    """The Wine prefix osu! runs in: WINEPREFIX if set, else osu-winello's."""
    if os.environ.get("WINEPREFIX"):
        return os.environ["WINEPREFIX"]
    prefix = os.path.join(_data_home(), "wineprefixes", "osu-wineprefix")
    return prefix if os.path.isdir(prefix) else None


def host_env(env: dict | None = None) -> dict | None:
    """Environment for running the system's programs (Wine, ffmpeg) from a PyInstaller bundle:
    its LD_LIBRARY_PATH points at the bundled libraries, which the host's binaries mustn't load.
    PyInstaller keeps the original in LD_LIBRARY_PATH_ORIG."""
    if IS_WINDOWS or not getattr(sys, "frozen", False):
        return env
    env = dict(os.environ if env is None else env)
    orig = env.pop("LD_LIBRARY_PATH_ORIG", None)
    if orig:
        env["LD_LIBRARY_PATH"] = orig
    else:
        env.pop("LD_LIBRARY_PATH", None)
    return env


def wine_command(exe_path: str) -> tuple[list[str], dict | None] | None:
    """(argv, env) to run a Windows executable; (argv, None) on Windows; None without Wine."""
    if IS_WINDOWS or not exe_path.lower().endswith(".exe"):
        return [exe_path], host_env()
    wine = find_wine()
    if not wine:
        return None
    # none of Wine's own chatter on stderr ("fsync: up and running")
    env = host_env(dict(os.environ, WINEDEBUG="-all"))
    prefix = wine_prefix()
    if prefix:
        env["WINEPREFIX"] = prefix
    return [wine, exe_path], env


def _match_case(path: str) -> str:
    """Windows paths ignore case; find the real spelling on a case-sensitive filesystem."""
    if os.path.exists(path):
        return path
    current = "/"
    for part in path.strip("/").split("/"):
        candidate = os.path.join(current, part)
        if not os.path.exists(candidate):
            try:
                match = next((e for e in os.listdir(current) if e.lower() == part.lower()), None)
            except OSError:
                return path
            if match is None:
                return path
            candidate = os.path.join(current, match)
        current = candidate
    return current


def wine_to_unix_path(path: str) -> str:
    """Map a path tosu reported to a local one. Windows: unchanged. Linux: D:\\Songs\\x ->
    whatever the prefix's d: points at, /Songs/x; Linux paths (native tosu) pass through."""
    if IS_WINDOWS or not path:
        return path
    path = path.replace("\\", "/")
    if len(path) < 2 or path[1] != ":":
        return _match_case(os.path.normpath(path))
    drive, rest = path[0].lower(), path[2:].lstrip("/")
    base = None
    prefix = wine_prefix()
    if prefix:
        link = os.path.join(prefix, "dosdevices", drive + ":")
        if os.path.exists(link):
            base = os.path.realpath(link)
        elif drive == "c":
            base = os.path.join(prefix, "drive_c")
    if base is None:
        base = "/" if drive == "z" else drive + ":"
    return _match_case(os.path.normpath(os.path.join(base, rest)))


def join_tosu_path(*parts: str) -> str:
    """os.path.join for paths built from tosu's fields, mapped to the local filesystem."""
    if IS_WINDOWS:
        return os.path.join(*parts)
    return wine_to_unix_path("\\".join(p.strip("\\/") if i else p.rstrip("\\/") for i, p in enumerate(parts) if p))
