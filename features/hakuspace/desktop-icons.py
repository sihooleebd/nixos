#!/usr/bin/env python3
# Desktop icons for a wlroots/Hyprland session, reimplemented.
#
# The upstream hakuspace desktop_icons.py was experimental and buggy: every
# file showed a generic document glyph (it never read a .desktop's Icon= or a
# file's mime type), .desktop launchers did not open (xdg-open opened them as
# text), the window resized during drags so icons/labels wobbled (the "jelly"),
# and there was NO cross-application drag-and-drop -- the whole point of a
# desktop.
#
# This version is a STATIC full-monitor transparent layer (anchored on all four
# edges, so it never resizes -> never re-animates), resolves real icons,
# launches .desktop files via `gio launch`, and implements real DnD:
#   * each icon is a text/uri-list drag SOURCE   -> drag a file out to Dolphin
#   * the desktop is a text/uri-list drag DEST    -> drop a file in from Dolphin
#     (a drop from the desktop onto itself just repositions the icon)

import subprocess
import json
from pathlib import Path

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gtk, Gdk, Gio, GLib, GtkLayerShell, Pango  # noqa: E402

ICON_SIZE = 48
CELL_W = 96
CELL_H = 94
PAD_X = 16
PAD_Y = 12
# Extra top padding so the first row clears waybar (a ~56px top-layer bar that
# renders over this bottom-layer desktop). Icons start below it, not under it.
TOP_INSET = 64
LABEL_H = 34

LAYOUT_FILE = Path.home() / ".local/state/haku_theme/desktop-icons-layout.json"

# text/uri-list is the standard file drag payload understood by Dolphin,
# Nautilus, browsers, etc. info=0 is our own tag; we only use one target.
URI_TARGETS = [Gtk.TargetEntry.new("text/uri-list", 0, 0)]
DND_ACTIONS = Gdk.DragAction.COPY | Gdk.DragAction.MOVE


def run_quiet(cmd):
    try:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def desktop_dir() -> Path:
    cfg = Path.home() / ".config/user-dirs.dirs"
    if cfg.exists():
        for line in cfg.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("XDG_DESKTOP_DIR="):
                v = line.split("=", 1)[1].strip().strip('"').replace("$HOME", str(Path.home()))
                return Path(v)
    return Path.home() / "Desktop"


def list_items(d: Path):
    d.mkdir(parents=True, exist_ok=True)
    return [p for p in sorted(d.iterdir(), key=lambda x: x.name.lower()) if not p.name.startswith(".")]


def _desktop_icon_name(path: Path):
    try:
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("Icon="):
                return line.split("=", 1)[1].strip()
    except Exception:
        pass
    return None


_ICON_CACHE = {}


def icon_for(path: Path):
    if path.is_dir():
        key = "dir"
    elif path.suffix.lower() == ".desktop":
        key = "d:" + path.name
    else:
        key = "s:" + (path.suffix.lower() or "file")
    ico = _ICON_CACHE.get(key)
    if ico is not None:
        return ico
    ico = _resolve_icon(path)
    _ICON_CACHE[key] = ico
    return ico


def _resolve_icon(path: Path):
    # Directories: the folder icon.
    if path.is_dir():
        return Gio.ThemedIcon.new("folder")
    # .desktop launchers: their own Icon= (a themed name, or an absolute path).
    if path.suffix.lower() == ".desktop":
        name = _desktop_icon_name(path)
        if name:
            if "/" in name and Path(name).exists():
                return Gio.FileIcon.new(Gio.File.new_for_path(name))
            return Gio.ThemedIcon.new(name)
        return Gio.ThemedIcon.new("application-x-executable")
    # Everything else: the icon for its guessed mime type (falls back through a
    # chain like image-x-generic -> image -> text-x-generic internally).
    ctype, _u = Gio.content_type_guess(str(path), None)
    if ctype:
        return Gio.content_type_get_icon(ctype)
    return Gio.ThemedIcon.new("text-x-generic")


def open_path(path: Path):
    # .desktop launchers must be LAUNCHED, not opened as a text file.
    if path.is_file() and path.suffix.lower() == ".desktop":
        run_quiet(["gio", "launch", str(path)])
        return
    run_quiet(["xdg-open", str(path)])


def unique_dest(d: Path, name: str) -> Path:
    """A non-clobbering destination path in d for an incoming file called name."""
    target = d / name
    if not target.exists():
        return target
    stem = target.stem
    suffix = target.suffix
    n = 1
    while True:
        cand = d / f"{stem} (copy{'' if n == 1 else ' ' + str(n)}){suffix}"
        if not cand.exists():
            return cand
        n += 1


class DesktopItem(Gtk.EventBox):
    def __init__(self, app, path: Path):
        super().__init__()
        self.app = app
        self.path = path
        self.set_visible_window(False)
        self.set_size_request(CELL_W, CELL_H)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        box.set_size_request(CELL_W, CELL_H)
        box.get_style_context().add_class("icon-item")
        self.box = box

        self._gicon = icon_for(path)
        self.img = Gtk.Image.new_from_gicon(self._gicon, Gtk.IconSize.DIALOG)
        self.img.set_pixel_size(ICON_SIZE)

        self.lbl = Gtk.Label(label=path.name)
        self.lbl.get_style_context().add_class("icon-label")
        self.lbl.set_justify(Gtk.Justification.CENTER)
        self.lbl.set_line_wrap(True)
        self.lbl.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self.lbl.set_ellipsize(Pango.EllipsizeMode.END)
        self.lbl.set_lines(2)
        self.lbl.set_max_width_chars(12)
        self.lbl.set_width_chars(12)
        self.lbl.set_size_request(CELL_W - 6, LABEL_H)

        box.pack_start(self.img, False, False, 0)
        box.pack_start(self.lbl, False, False, 0)
        self.add(box)

        self.add_events(
            Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.ENTER_NOTIFY_MASK
            | Gdk.EventMask.LEAVE_NOTIFY_MASK
        )
        self.connect("button-press-event", self.on_press)
        self.connect("enter-notify-event", lambda *_: self.box.get_style_context().add_class("hover"))
        self.connect("leave-notify-event", lambda *_: self.box.get_style_context().remove_class("hover"))

        # Drag SOURCE: dragging an icon hands its file:// URI to whatever it is
        # dropped on -- Dolphin, a browser, or (see the desktop's dest handler)
        # this very desktop, which treats an internal drop as a reposition.
        self.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, URI_TARGETS, DND_ACTIONS)
        self.connect("drag-begin", self.on_drag_begin)
        self.connect("drag-data-get", self.on_drag_data_get)
        self.connect("drag-data-delete", self.on_drag_data_delete)
        self.connect("drag-end", self.on_drag_end)

    def set_selected(self, sel):
        ctx = self.box.get_style_context()
        (ctx.add_class if sel else ctx.remove_class)("selected")

    def on_press(self, _w, e):
        if e.button == 3 and e.type == Gdk.EventType.BUTTON_PRESS:
            self.app.select(self)
            self.app.show_menu(self, e)
            return True
        if e.button == 1 and e.type == Gdk.EventType._2BUTTON_PRESS:
            self.app.select(self)
            open_path(self.path)
            return True
        if e.button == 1 and e.type == Gdk.EventType.BUTTON_PRESS:
            self.app.select(self)
            return False  # let the drag source see the press too
        return False

    # ---- drag source -----------------------------------------------------
    def on_drag_begin(self, _w, ctx):
        self.app.drag_src_name = self.path.name
        Gtk.drag_set_icon_gicon(ctx, self._gicon, ICON_SIZE // 2, ICON_SIZE // 2)

    def on_drag_data_get(self, _w, _ctx, data, _info, _time):
        data.set_uris([Gio.File.new_for_path(str(self.path)).get_uri()])

    def on_drag_data_delete(self, _w, _ctx):
        # Fires only when an EXTERNAL receiver performed a MOVE and asked the
        # source to delete the original (internal reposition finishes with
        # delete=False, so it never lands here).
        try:
            if self.path.is_dir():
                import shutil
                shutil.rmtree(self.path)
            else:
                self.path.unlink()
        except Exception:
            pass
        self.app.schedule_refresh()

    def on_drag_end(self, _w, _ctx):
        self.app.drag_src_name = None


class Desktop(Gtk.Window):
    def __init__(self):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.set_decorated(False)
        self.set_app_paintable(True)

        self.dir = desktop_dir()
        self.items = {}
        self.cell_map = {}
        self.positions = self.load_layout()
        self.selected = None
        self.drag_src_name = None
        self.origin_x = 0
        self.origin_y = 0
        self.mon_w = 1920
        self.mon_h = 1080
        self.cols = 8
        self.rows = 6
        self.refresh_id = 0

        screen = self.get_screen()
        rgba = screen.get_rgba_visual()
        if rgba and screen.is_composited():
            self.set_visual(rgba)

        css = b"""
        window { background-color: rgba(0,0,0,0); }
        .desktop-bg { background-color: rgba(0,0,0,0); }
        .icon-item { padding: 4px; border-radius: 8px; background-color: rgba(0,0,0,0); }
        .icon-item.hover { background-color: rgba(255,255,255,0.08); }
        .icon-item.selected { background-color: rgba(255,255,255,0.16); }
        .icon-label { color: #f2f2f2; text-shadow: 0 1px 2px rgba(0,0,0,0.9); font-size: 11px; }
        """
        prov = Gtk.CssProvider()
        prov.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        # Static, full-monitor layer: anchored to ALL FOUR edges, so its size is
        # locked to the output and it never resizes -> the compositor never
        # replays the layer (jelly) animation while icons are dragged.
        GtkLayerShell.init_for_window(self)
        GtkLayerShell.set_layer(self, GtkLayerShell.Layer.BOTTOM)
        for edge in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.LEFT,
                     GtkLayerShell.Edge.RIGHT, GtkLayerShell.Edge.BOTTOM):
            GtkLayerShell.set_anchor(self, edge, True)
        GtkLayerShell.set_exclusive_zone(self, -1)
        GtkLayerShell.set_keyboard_mode(self, GtkLayerShell.KeyboardMode.ON_DEMAND)

        # A full-surface background EventBox is the DROP TARGET (so files can be
        # dropped anywhere on the desktop, not only onto an existing icon) and
        # the empty-space click target (deselect). The Fixed holding the icons
        # sits inside it.
        self.bg = Gtk.EventBox()
        self.bg.get_style_context().add_class("desktop-bg")
        self.bg.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.bg.connect("button-press-event", self.on_bg_press)
        self.add(self.bg)

        self.layout = Gtk.Fixed()
        self.bg.add(self.layout)

        # Drag DEST: accept file drops. Fully manual (no DestDefaults) so we can
        # decide copy vs move and, for an internal drop, reposition instead.
        self.bg.drag_dest_set(0, URI_TARGETS, DND_ACTIONS)
        self.bg.connect("drag-motion", self.on_dest_motion)
        self.bg.connect("drag-drop", self.on_dest_drop)
        self.bg.connect("drag-data-received", self.on_dest_received)

        self.connect("destroy", Gtk.main_quit)
        self.connect("realize", self.on_realize)
        self.connect("key-press-event", self.on_key)

        self.monitor = Gio.File.new_for_path(str(self.dir)).monitor_directory(
            Gio.FileMonitorFlags.NONE, None)
        self.monitor.connect("changed", lambda *_: self.schedule_refresh())

        self.compute_grid()

    def compute_grid(self):
        d = Gdk.Display.get_default()
        mon = d.get_primary_monitor() or d.get_monitor(0)
        geo = mon.get_geometry()
        self.origin_x, self.origin_y = geo.x, geo.y
        self.mon_w = max(1, geo.width)
        self.mon_h = max(1, geo.height)
        self.cols = max(1, (self.mon_w - 2 * PAD_X) // CELL_W)
        self.rows = max(1, (self.mon_h - TOP_INSET - 2 * PAD_Y) // CELL_H)

    def on_realize(self, *_):
        self.compute_grid()
        self.refresh()

    # ---- selection / keyboard -------------------------------------------
    def select(self, item):
        self.selected = None if (self.selected == item.path.name) else item.path.name
        for n, it in self.items.items():
            it.set_selected(n == self.selected)

    def clear_selection(self):
        self.selected = None
        for it in self.items.values():
            it.set_selected(False)

    def on_bg_press(self, _w, e):
        if e.button == 1:
            self.clear_selection()
        return False

    def on_key(self, _w, e):
        if e.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            if self.selected in self.items:
                open_path(self.items[self.selected].path)
            return True
        if e.keyval == Gdk.KEY_F2:
            self.rename_selected()
            return True
        if e.keyval == Gdk.KEY_Delete:
            if self.selected in self.items:
                self.trash(self.items[self.selected].path)
            return True
        if e.keyval == Gdk.KEY_Escape:
            self.clear_selection()
            return True
        return False

    # ---- drag destination -----------------------------------------------
    def _preferred_action(self, ctx):
        # Default to MOVE (dropping a file on the desktop should relocate it,
        # not leave a copy behind), but honor an explicit Ctrl for copy. Cross-
        # application drags otherwise suggest COPY, which is what made every
        # drop copy.
        actions = ctx.get_actions()
        ctrl = False
        try:
            disp = Gdk.Display.get_default()
            ptr = disp.get_default_seat().get_pointer()
            win = self.bg.get_window() or self.get_window()
            if win is not None and ptr is not None:
                mask = win.get_device_position(ptr)[3]
                ctrl = bool(mask & Gdk.ModifierType.CONTROL_MASK)
        except Exception:
            pass
        if ctrl and (actions & Gdk.DragAction.COPY):
            return Gdk.DragAction.COPY
        if actions & Gdk.DragAction.MOVE:
            return Gdk.DragAction.MOVE
        if actions & Gdk.DragAction.COPY:
            return Gdk.DragAction.COPY
        return ctx.get_suggested_action()

    def on_dest_motion(self, _w, ctx, _x, _y, time):
        Gdk.drag_status(ctx, self._preferred_action(ctx), time)
        return True

    def on_dest_drop(self, w, ctx, x, y, time):
        target = w.drag_dest_find_target(ctx, None)
        try:
            named = target is not None and target.name() not in (None, "NONE")
        except Exception:
            named = target is not None
        if not named:
            return False
        self._drop_xy = (x, y)
        w.drag_get_data(ctx, target, time)
        return True

    def on_dest_received(self, _w, ctx, x, y, data, _info, time):
        # Internal drop = reposition the icon that started the drag. No file op.
        if self.drag_src_name is not None:
            item = self.items.get(self.drag_src_name)
            if item is not None:
                col = round((x - PAD_X) / CELL_W)
                row = round((y - PAD_Y - TOP_INSET) / CELL_H)
                self.place_in_cell(item, row, col, resolve=True)
                self.save_layout()
            Gtk.drag_finish(ctx, True, False, time)
            return
        # External drop = import the files into the desktop folder.
        action = ctx.get_selected_action() or ctx.get_suggested_action()
        move = bool(action & Gdk.DragAction.MOVE)
        ok = self.import_uris(data.get_uris(), move)
        # We carry out the move/copy OURSELVES (deleting the source on a move
        # rather than trusting the sender to), so the drag always finishes with
        # delete=False -- otherwise the source would try to delete a file we
        # already moved.
        Gtk.drag_finish(ctx, ok, False, time)
        self.schedule_refresh()

    def import_uris(self, uris, move):
        any_ok = False
        for uri in uris or []:
            try:
                src = Gio.File.new_for_uri(uri)
                name = src.get_basename() or "file"
                spath = src.get_path()
                if spath and Path(spath).resolve() == (self.dir / name).resolve():
                    continue  # already in the desktop folder
                dst = Gio.File.new_for_path(str(unique_dest(self.dir, name)))
                if move:
                    try:
                        # Same-filesystem move is an atomic rename; Gio also
                        # copies+deletes across devices for us.
                        src.move(dst, Gio.FileCopyFlags.NONE, None, None, None)
                    except GLib.Error:
                        # Directories across devices, or a source that cannot be
                        # renamed: fall back to copy, then remove the original.
                        src.copy(dst, Gio.FileCopyFlags.NONE, None, None, None)
                        try:
                            src.delete(None)
                        except Exception:
                            pass
                else:
                    src.copy(dst, Gio.FileCopyFlags.NONE, None, None, None)
                any_ok = True
            except GLib.Error:
                pass
            except Exception:
                pass
        return any_ok

    # ---- context menu ----------------------------------------------------
    def show_menu(self, item, event):
        m = Gtk.Menu()

        def add(label, cb):
            mi = Gtk.MenuItem(label=label)
            mi.connect("activate", cb)
            m.append(mi)

        add("Open", lambda *_: open_path(item.path))
        add("Open containing folder", lambda *_: run_quiet(
            ["xdg-open", str(item.path if item.path.is_dir() else item.path.parent)]))
        add("Rename", lambda *_: self.rename_selected())
        add("Move to Trash", lambda *_: self.trash(item.path))
        m.show_all()
        m.popup_at_pointer(event)

    def rename_selected(self):
        if self.selected not in self.items:
            return
        old = self.items[self.selected].path
        dlg = Gtk.Dialog(title="Rename", transient_for=self, flags=0)
        dlg.add_button("_Cancel", Gtk.ResponseType.CANCEL)
        dlg.add_button("_OK", Gtk.ResponseType.OK)
        entry = Gtk.Entry()
        entry.set_text(old.name)
        entry.set_activates_default(True)
        dlg.get_content_area().pack_start(entry, True, True, 8)
        dlg.set_default_response(Gtk.ResponseType.OK)
        dlg.show_all()
        resp = dlg.run()
        new = entry.get_text().strip()
        dlg.destroy()
        if resp != Gtk.ResponseType.OK or not new or "/" in new or new == old.name:
            return
        target = old.parent / new
        if target.exists():
            return
        try:
            old.rename(target)
            if old.name in self.positions:
                self.positions[new] = self.positions.pop(old.name)
                self.write_layout()
            self.selected = new
            self.schedule_refresh()
        except Exception:
            pass

    def trash(self, path: Path):
        try:
            Gio.File.new_for_path(str(path)).trash(None)
        except Exception:
            pass

    # ---- layout persistence ---------------------------------------------
    def load_layout(self):
        try:
            if LAYOUT_FILE.exists():
                d = json.loads(LAYOUT_FILE.read_text(encoding="utf-8"))
                return d if isinstance(d, dict) else {}
        except Exception:
            pass
        return {}

    def write_layout(self):
        try:
            LAYOUT_FILE.parent.mkdir(parents=True, exist_ok=True)
            LAYOUT_FILE.write_text(json.dumps(self.positions, indent=2), encoding="utf-8")
        except Exception:
            pass

    def save_layout(self):
        d = {}
        for name, it in self.items.items():
            x = self.layout.child_get_property(it, "x")
            y = self.layout.child_get_property(it, "y")
            c = self._clamp_col(round((x - PAD_X) / CELL_W))
            r = self._clamp_row(round((y - PAD_Y - TOP_INSET) / CELL_H))
            d[name] = {"row": r, "col": c}
        self.positions = d
        self.write_layout()

    # ---- grid placement --------------------------------------------------
    def _clamp_col(self, c):
        return max(0, min(int(c), self.cols - 1))

    def _clamp_row(self, r):
        return max(0, min(int(r), self.rows - 1))

    def cell_xy(self, r, c):
        return PAD_X + c * CELL_W, PAD_Y + TOP_INSET + r * CELL_H

    def next_free_cell(self):
        for c in range(self.cols):
            for r in range(self.rows):
                if (r, c) not in self.cell_map:
                    return r, c
        return 0, 0

    def place_in_cell(self, item, r, c, resolve=False):
        r, c = self._clamp_row(r), self._clamp_col(c)
        name = item.path.name
        for k, v in list(self.cell_map.items()):
            if v == name:
                del self.cell_map[k]
        if resolve and (r, c) in self.cell_map and self.cell_map[(r, c)] != name:
            other = self.cell_map[(r, c)]
            fr, fc = self.next_free_cell()
            if other in self.items:
                ox, oy = self.cell_xy(fr, fc)
                self.layout.move(self.items[other], ox, oy)
                del self.cell_map[(r, c)]
                self.cell_map[(fr, fc)] = other
        x, y = self.cell_xy(r, c)
        self.layout.move(item, x, y)
        self.cell_map[(r, c)] = name

    def initial_place(self, item, idx):
        pos = self.positions.get(item.path.name)
        if isinstance(pos, dict):
            r, c = self._clamp_row(int(pos.get("row", 0))), self._clamp_col(int(pos.get("col", 0)))
            if (r, c) not in self.cell_map:
                self.place_in_cell(item, r, c)
                return
        c, r = divmod(idx, self.rows)
        if (r, c) in self.cell_map:
            r, c = self.next_free_cell()
        self.place_in_cell(item, r, c)

    # ---- refresh ---------------------------------------------------------
    def schedule_refresh(self):
        if self.refresh_id:
            return
        self.refresh_id = GLib.timeout_add(200, self._do_refresh)

    def _do_refresh(self):
        self.refresh_id = 0
        self.refresh()
        return False

    def refresh(self):
        keep = self.selected
        for ch in self.layout.get_children():
            self.layout.remove(ch)
        self.items.clear()
        self.cell_map.clear()
        for idx, p in enumerate(list_items(self.dir)):
            it = DesktopItem(self, p)
            self.layout.put(it, 0, 0)
            self.items[p.name] = it
            self.initial_place(it, idx)
        if keep and keep in self.items:
            self.selected = keep
            self.items[keep].set_selected(True)
        else:
            self.selected = None
        self.show_all()


if __name__ == "__main__":
    win = Desktop()
    win.show_all()
    Gtk.main()
