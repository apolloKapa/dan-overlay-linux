# linux_pin.py -- "pin above everything" for a Qt window on Linux (Wayland).
#
# On Windows a topmost window stays over a fullscreen game. Wayland compositors (niri, KWin,
# Hyprland, Sway...) ignore that request, and niri hides normal windows behind a focused fullscreen
# window. Only layer-shell surfaces on the "overlay" layer stay above it, so pinning turns the window
# into one, at the same spot (libdanlayer.so over KDE's LayerShellQt, see linux/layershell), and
# unpinning turns it back into a normal window.
#
# Qt window changes have to happen on the GUI thread: call init() on the main thread before the
# event loop starts; toggle()/pin()/unpin() can then be called from any thread.

import ctypes
import json
import logging
import os
import shutil
import subprocess
import sys
import threading

logger = logging.getLogger(__name__)

_lib = None
_lib_failed = False
_relay = None
_state = {"pinned": False, "pos": None}


def _load_lib():
    """libdanlayer.so sits next to the Qt it was built for (PyQt6/Qt6/lib in the bundle). Loaded
    once Qt runs, so its Qt libraries are already the bundled ones."""
    global _lib, _lib_failed
    if _lib is not None or _lib_failed:
        return _lib
    try:
        import PyQt6
        path = os.path.join(os.path.dirname(PyQt6.__file__), "Qt6", "lib", "libdanlayer.so")
        lib = ctypes.CDLL(path)
        for name in ("danlayer_pin", "danlayer_move"):
            getattr(lib, name).argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        for name in ("danlayer_unpin", "danlayer_is_pinned"):
            getattr(lib, name).argtypes = [ctypes.c_void_p]
        _lib = lib
    except Exception as exc:
        logger.info("linux_pin: layer-shell pinning unavailable (%s)", exc)
        _lib_failed = True
    return _lib


def available() -> bool:
    if not sys.platform.startswith("linux"):
        return False
    lib = _load_lib()
    return bool(lib and lib.danlayer_available())


def _host_env():
    try:
        from wine_compat import host_env
        return host_env()
    except Exception:
        return None


def _niri(*args):
    """niri msg -j ...; None when niri isn't running or the call fails."""
    if not os.environ.get("NIRI_SOCKET") or not shutil.which("niri"):
        return None
    try:
        out = subprocess.run(["niri", "msg", "-j", *args], capture_output=True, text=True,
                             timeout=2, env=_host_env())
        return json.loads(out.stdout) if out.returncode == 0 and out.stdout.strip() else None
    except Exception:
        return None


def _niri_window():
    """This process's window in niri (the newest, if it has several)."""
    windows = _niri("windows") or []
    mine = [w for w in windows if w.get("pid") == os.getpid()]
    return max(mine, key=lambda w: w.get("id", 0)) if mine else None


def _window_global_pos():
    """Where niri has our window (global logical coordinates), or None. niri only reports it for
    floating windows; for a tiled one the window's own screen corner is used instead."""
    win = _niri_window()
    if not win:
        return None
    layout = win.get("layout") or {}
    tile = layout.get("tile_pos_in_workspace_view")
    if not tile:
        return None
    off = layout.get("window_offset_in_tile") or [0, 0]
    workspaces = {w["id"]: w for w in (_niri("workspaces") or [])}
    output_name = (workspaces.get(win.get("workspace_id")) or {}).get("output")
    outputs = _niri("outputs") or {}
    logical = (outputs.get(output_name) or {}).get("logical") or {}
    return (int(logical.get("x", 0) + tile[0] + off[0]), int(logical.get("y", 0) + tile[1] + off[1]))


def _restore_position(pos):
    """After unpinning: float the new normal window and put it back where the overlay was."""
    if not pos:
        return
    win = _niri_window()
    if not win:
        return
    outputs = _niri("outputs") or {}
    workspaces = {w["id"]: w for w in (_niri("workspaces") or [])}
    output_name = (workspaces.get(win.get("workspace_id")) or {}).get("output")
    logical = (outputs.get(output_name) or {}).get("logical") or {}
    env = _host_env()
    wid = str(win["id"])
    if not win.get("is_floating"):
        subprocess.run(["niri", "msg", "action", "move-window-to-floating", "--id", wid],
                       capture_output=True, timeout=2, env=env)
    subprocess.run(["niri", "msg", "action", "move-floating-window", "--id", wid,
                    "-x", str(pos[0] - logical.get("x", 0)), "-y", str(pos[1] - logical.get("y", 0))],
                   capture_output=True, timeout=2, env=env)


def _qwindow_ptr(widget):
    from PyQt6 import sip
    handle = widget.windowHandle()
    return ctypes.c_void_p(sip.unwrapinstance(handle)) if handle is not None else None


def _do_pin(widget, size=None):
    lib = _load_lib()
    if not lib or not lib.danlayer_available() or _state["pinned"]:
        return False
    pos = _window_global_pos()
    if pos is None:
        geo = widget.screen().geometry() if widget.screen() else None
        pos = _state["pos"] or ((geo.x() + 40, geo.y() + 40) if geo else (40, 40))
    if size:
        widget.resize(*size)
    widget.hide()
    ptr = _qwindow_ptr(widget)
    if ptr is None or not lib.danlayer_pin(ptr, pos[0], pos[1]):
        widget.show()
        return False
    widget.show()
    _state.update(pinned=True, pos=pos)
    logger.info("linux_pin: pinned at %s", pos)
    return True


def _do_unpin(widget):
    lib = _load_lib()
    if not lib or not _state["pinned"]:
        return False
    widget.hide()
    ptr = _qwindow_ptr(widget)
    if ptr is None or not lib.danlayer_unpin(ptr):
        widget.show()
        return False
    widget.show()
    _state["pinned"] = False
    pos = _state["pos"]
    threading.Thread(target=_restore_position, args=(pos,), daemon=True).start()
    logger.info("linux_pin: unpinned")
    return True


def init():
    """Create the GUI-thread relay. Call on the main thread before the Qt event loop runs."""
    global _relay
    if _relay is not None or not sys.platform.startswith("linux"):
        return
    try:
        from PyQt6.QtCore import QObject, pyqtSignal, Qt
    except Exception:
        return

    class _Relay(QObject):
        request = pyqtSignal(object)

        def __init__(self):
            super().__init__()
            self.request.connect(self._run, Qt.ConnectionType.QueuedConnection)

        def _run(self, job):
            func, args, done = job
            try:
                done["result"] = func(*args)
            except Exception as exc:
                logger.warning("linux_pin: %s failed: %s", func.__name__, exc)
                done["result"] = False
            done["event"].set()

    _relay = _Relay()


def _on_gui_thread(func, *args):
    from PyQt6.QtCore import QThread, QCoreApplication
    app = QCoreApplication.instance()
    if app is not None and QThread.currentThread() == app.thread():
        return func(*args)
    if _relay is None:
        return False
    done = {"event": threading.Event(), "result": False}
    _relay.request.emit((func, args, done))
    done["event"].wait(5)
    return done["result"]


def is_pinned() -> bool:
    return _state["pinned"]


def pin(widget, size=None) -> bool:
    return bool(_on_gui_thread(_do_pin, widget, size))


def unpin(widget) -> bool:
    return bool(_on_gui_thread(_do_unpin, widget))


def toggle(widget, size=None) -> bool:
    """Pin or unpin; returns the new pinned state."""
    if _state["pinned"]:
        unpin(widget)
    else:
        pin(widget, size)
    return _state["pinned"]
