import sys
import threading
import tkinter as tk
from tkinter import font as tkfont
from tkinter import messagebox

from audio import AudioPlayer, find_ffplay
from danmaku import DanmakuClient
from history import RoomHistory
from huya_api import fetch_room, normalize_room_id, search_anchors

MAX_DANMU = 500
TRIM_COUNT = 400
HOVER_HEIGHT = 10
BG = "#12141A"
PANEL = "#1B1F2A"
CARD = "#232836"
LINE = "#32384A"
TEXT = "#E8ECF2"
MUTED = "#8B93A7"
ACCENT = "#4C8DFF"
OK = "#3DDB8A"
OFF = "#FF6B6B"
NAME = "#9AA8C7"


class Pill(tk.Frame):
    def __init__(self, master, text, command=None, kind="ghost"):
        super().__init__(master, bg=PANEL, highlightthickness=0)
        self.command = command
        self.kind = kind
        self.enabled = True
        self.var_text = text
        self.lbl = tk.Label(self, text=text, padx=12, pady=5, cursor="hand2")
        self.lbl.pack()
        self._paint()
        for w in (self, self.lbl):
            w.bind("<Button-1>", self._click)
            w.bind("<Enter>", lambda e: self._paint(hover=True))
            w.bind("<Leave>", lambda e: self._paint())

    def _palette(self, hover=False):
        if not self.enabled:
            return CARD, MUTED
        if self.kind == "on":
            return ("#2FBE78" if hover else "#249E64", "#FFFFFF")
        if self.kind == "busy":
            return ("#F0D35A" if hover else "#E0B83D", "#1A1A1A")
        if self.kind == "off":
            return ("#E25A5A" if hover else "#C94C4C", "#FFFFFF")
        if self.kind == "primary":
            return ("#3B78E7" if hover else ACCENT, "#FFFFFF")
        if self.kind == "danger":
            return ("#E25A5A" if hover else "#C94C4C", "#FFFFFF")
        if self.kind == "ok":
            return ("#2FBE78" if hover else "#249E64", "#FFFFFF")
        return (LINE if hover else CARD, TEXT)

    def _paint(self, hover=False):
        bg, fg = self._palette(hover)
        self.configure(bg=bg)
        self.lbl.configure(bg=bg, fg=fg, font=("Microsoft YaHei UI", 9, "bold"))

    def set_text(self, text):
        self.var_text = text
        self.lbl.configure(text=text)

    def set_kind(self, kind):
        self.kind = kind
        self._paint()

    def _click(self, _event=None):
        if self.enabled and self.command:
            self.command()


class HuyaDanmuApp:
    def __init__(self, root):
        self.root = root
        self.root.title("虎牙监控")
        self.root.geometry("520x620")
        self.root.minsize(360, 200)
        self.root.configure(bg=BG)
        try:
            self.root.attributes("-alpha", 1.0)
        except tk.TclError:
            pass

        self.history = RoomHistory()
        self.auto_hide = tk.BooleanVar(value=False)
        self.always_on_top = tk.BooleanVar(value=False)
        self.toolbar_visible = True
        self.hide_job = None
        self.danmu_count = 0
        self.follow_tail = True
        self._layout_guard = False
        self.danmu_phase = "off"
        self.audio_phase = "off"
        self.vol_win = None
        self.hist_win = None
        self.search_win = None
        self._vol_job = None
        self._search_job = None
        self._search_gen = 0
        self._build_fonts()
        self._build_ui()
        self._bind_autohide()
        self.danmaku = DanmakuClient(self._on_danmu, self._on_danmu_status)
        self.audio = AudioPlayer(self._on_audio_status)
        self.volume_var = tk.IntVar(value=100)
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)
        self.refresh_history()

    def _build_fonts(self):
        self.font_ui = tkfont.Font(family="Microsoft YaHei UI", size=9)
        self.font_ui_b = tkfont.Font(family="Microsoft YaHei UI", size=9, weight="bold")
        self.font_danmu = tkfont.Font(family="Microsoft YaHei UI", size=11, weight="bold")
        self.font_name = tkfont.Font(family="Microsoft YaHei UI", size=10)

    def _build_ui(self):
        self.hover = tk.Frame(self.root, bg=ACCENT, height=HOVER_HEIGHT, cursor="hand2")
        self.hover.pack(fill="x", side="top")
        self.hover.pack_propagate(False)

        self.toolbar = tk.Frame(self.root, bg=PANEL, padx=10, pady=10)
        self.toolbar.pack(fill="x", side="top")

        row1 = tk.Frame(self.toolbar, bg=PANEL)
        row1.pack(fill="x")
        tk.Label(row1, text="房号", bg=PANEL, fg=MUTED, font=self.font_ui_b).pack(side="left")
        self.room_var = tk.StringVar()
        self.room_wrap = tk.Frame(row1, bg=CARD, highlightbackground=LINE, highlightthickness=1)
        self.room_wrap.pack(side="left", fill="x", expand=True, padx=8)
        self.room_entry = tk.Entry(
            self.room_wrap,
            textvariable=self.room_var,
            bg=CARD,
            fg=TEXT,
            insertbackground=TEXT,
            highlightthickness=0,
            bd=0,
            relief="flat",
            font=self.font_ui,
        )
        self.room_entry.pack(side="left", fill="x", expand=True, ipady=4, padx=(8, 0))
        self.btn_hist = tk.Label(
            self.room_wrap,
            text="▼",
            bg=CARD,
            fg=MUTED,
            font=self.font_ui_b,
            cursor="hand2",
            padx=8,
        )
        self.btn_hist.pack(side="right", fill="y")
        self.btn_hist.bind("<Button-1>", lambda _e: self.toggle_history())
        self.room_entry.bind("<Down>", lambda _e: self.open_history())
        self.chk_top = tk.Checkbutton(
            row1, text="置顶", variable=self.always_on_top, command=self.apply_topmost,
            bg=PANEL, fg=TEXT, selectcolor=CARD, activebackground=PANEL, activeforeground=TEXT,
            font=self.font_ui, highlightthickness=0, bd=0,
        )
        self.chk_top.pack(side="left")
        self.chk_hide = tk.Checkbutton(
            row1, text="隐藏", variable=self.auto_hide, command=self._on_autohide_toggle,
            bg=PANEL, fg=TEXT, selectcolor=CARD, activebackground=PANEL, activeforeground=TEXT,
            font=self.font_ui, highlightthickness=0, bd=0,
        )
        self.chk_hide.pack(side="left", padx=(6, 0))

        row2 = tk.Frame(self.toolbar, bg=PANEL)
        row2.pack(fill="x", pady=(10, 0))
        self.btn_connect = Pill(row2, "启动", command=self.connect_all, kind="off")
        self.btn_connect.pack(side="left")
        self.btn_danmu = Pill(row2, "弹幕", command=self.toggle_danmu, kind="off")
        self.btn_danmu.pack(side="left", padx=(8, 0))
        self.btn_audio = Pill(row2, "音频", command=self.toggle_audio, kind="off")
        self.btn_audio.pack(side="left", padx=(8, 0))
        self.btn_clear = Pill(row2, "清屏", command=self.clear_danmu)
        self.btn_clear.pack(side="left", padx=(8, 0))
        self.btn_search = Pill(row2, "搜索", command=self.toggle_search)
        self.btn_search.pack(side="left", padx=(8, 0))
        self.btn_volume = Pill(row2, "音量", command=self.toggle_volume)
        self.btn_volume.pack(side="left", padx=(8, 0))

        list_wrap = tk.Frame(self.root, bg=BG, padx=8, pady=8)
        list_wrap.pack(fill="both", expand=True)
        self.list_card = tk.Frame(list_wrap, bg=CARD, highlightbackground=LINE, highlightthickness=1)
        self.list_card.pack(fill="both", expand=True)

        self.listbox = tk.Text(
            self.list_card,
            bg=CARD,
            fg=TEXT,
            insertbackground=TEXT,
            selectbackground="#2C3650",
            selectforeground=TEXT,
            highlightthickness=0,
            borderwidth=0,
            font=self.font_danmu,
            relief="flat",
            wrap="word",
            cursor="arrow",
            padx=8,
            pady=6,
            state="disabled",
        )
        self._vscroll = tk.Scrollbar(self.list_card, orient="vertical", command=self.listbox.yview, bg=CARD, troughcolor=CARD)
        self.listbox.configure(yscrollcommand=self._on_list_scroll)
        self.listbox.pack(side="left", fill="both", expand=True, padx=(2, 0), pady=2)
        self._vscroll.pack(side="right", fill="y", pady=6, padx=(0, 4))
        self.listbox.bind("<Configure>", self._on_list_configure)
        self.listbox.tag_configure("name", foreground=NAME, font=self.font_name)
        self.listbox.tag_configure("sys", foreground=OFF, font=self.font_ui)

    def _bind_autohide(self):
        self.hover.bind("<Enter>", self._on_hover_enter)
        self.hover.bind("<Leave>", self._on_chrome_leave)
        self.toolbar.bind("<Enter>", self._on_toolbar_enter)
        self.toolbar.bind("<Leave>", self._on_chrome_leave)
        self.root.bind_all("<Button-1>", self._on_root_click, add="+")
        self.root.bind("<Escape>", lambda _e: (self.close_history(), self.close_volume(), self.close_search()))

    def refresh_history(self):
        labels = self.history.labels()
        if labels and not self.room_var.get():
            self.room_var.set(labels[0])
        if self.hist_win is not None:
            self.root.after_idle(self.open_history)

    def current_room_id(self):
        return self.history.room_id_of(self.room_var.get())

    def toggle_history(self):
        if self.hist_win is not None:
            self.close_history()
            return
        self.open_history()

    def close_history(self):
        win = self.hist_win
        self.hist_win = None
        if win is not None:
            try:
                win.destroy()
            except Exception:
                pass
        if self.auto_hide.get():
            self.schedule_hide()

    def _set_history_row(self, frame, hover):
        bg = LINE if hover else CARD
        frame.configure(bg=bg)
        for child in frame.winfo_children():
            child.configure(bg=bg)

    def open_history(self):
        self.close_volume()
        self.close_search()
        old = self.hist_win
        self.hist_win = None
        if old is not None:
            try:
                old.destroy()
            except Exception:
                pass
        items = list(self.history.items)
        win = tk.Toplevel(self.root)
        win.overrideredirect(True)
        win.configure(bg=LINE)
        try:
            win.attributes("-topmost", True)
        except tk.TclError:
            pass
        box = tk.Frame(win, bg=CARD)
        box.pack(fill="both", expand=True, padx=1, pady=1)
        if not items:
            empty = tk.Label(box, text="暂无历史记录", bg=CARD, fg=MUTED, font=self.font_ui, padx=12, pady=10, anchor="w")
            empty.pack(fill="x")
        else:
            canvas = tk.Canvas(box, bg=CARD, highlightthickness=0, bd=0, height=min(220, 36 * len(items) + 8))
            inner = tk.Frame(canvas, bg=CARD)
            window_id = canvas.create_window((0, 0), window=inner, anchor="nw")
            scroll = tk.Scrollbar(box, orient="vertical", command=canvas.yview, bg=CARD, troughcolor=CARD)
            canvas.configure(yscrollcommand=scroll.set)
            canvas.pack(side="left", fill="both", expand=True)
            if len(items) > 6:
                scroll.pack(side="right", fill="y")

            def _sync_scroll(_event=None):
                canvas.configure(scrollregion=canvas.bbox("all") or (0, 0, 0, 0))
                canvas.itemconfigure(window_id, width=max(canvas.winfo_width(), 1))

            inner.bind("<Configure>", _sync_scroll)
            canvas.bind("<Configure>", _sync_scroll)

            def _wheel(event):
                delta = -1 if getattr(event, "delta", 0) > 0 else 1
                if getattr(event, "num", 0) == 4:
                    delta = -1
                elif getattr(event, "num", 0) == 5:
                    delta = 1
                canvas.yview_scroll(delta, "units")

            for w in (canvas, inner, box, win):
                w.bind("<MouseWheel>", _wheel)
                w.bind("<Button-4>", _wheel)
                w.bind("<Button-5>", _wheel)

            for item in items:
                room_id = str(item.get("room_id") or "")
                nick = (item.get("nick") or "").strip()
                label = "%s  %s" % (room_id, nick) if nick else room_id
                row = tk.Frame(inner, bg=CARD)
                row.pack(fill="x")
                name = tk.Label(row, text=label, bg=CARD, fg=TEXT, font=self.font_ui, anchor="w", padx=10, pady=6, cursor="hand2")
                name.pack(side="left", fill="x", expand=True)
                delete = tk.Label(row, text="删除", bg=CARD, fg=OFF, font=self.font_ui, padx=10, pady=6, cursor="hand2")
                delete.pack(side="right")

                def _enter(_event=None, frame=row):
                    self._set_history_row(frame, True)

                def _leave(_event=None, frame=row):
                    self.root.after(10, lambda f=frame: self._set_history_row(f, False) if not self._pointer_in(f) else None)

                def _pick(_event=None, value=label):
                    self.room_var.set(value)
                    self.close_history()

                def _delete(_event=None, rid=room_id):
                    self.delete_history_item(rid)
                    return "break"

                for w in (row, name, delete):
                    w.bind("<Enter>", _enter)
                    w.bind("<Leave>", _leave)
                    w.bind("<MouseWheel>", _wheel)
                    w.bind("<Button-4>", _wheel)
                    w.bind("<Button-5>", _wheel)
                name.bind("<Button-1>", _pick)
                row.bind("<Button-1>", _pick)
                delete.bind("<Button-1>", _delete)

        self.root.update_idletasks()
        bx = self.room_wrap.winfo_rootx()
        by = self.room_wrap.winfo_rooty() + self.room_wrap.winfo_height() + 2
        width = max(self.room_wrap.winfo_width(), 220)
        win.update_idletasks()
        height = win.winfo_reqheight()
        win.geometry("%dx%d+%d+%d" % (width, height, bx, by))
        win.bind("<Enter>", self._on_toolbar_enter)
        win.bind("<Leave>", self._on_chrome_leave)
        self.hist_win = win
        if self.hide_job:
            self.root.after_cancel(self.hide_job)
            self.hide_job = None

    def delete_history_item(self, room_id):
        current = self.current_room_id() or self.room_var.get().strip()
        if not self.history.remove(room_id):
            return
        if str(current) == str(room_id):
            labels = self.history.labels()
            self.room_var.set(labels[0] if labels else "")
        self.refresh_history()

    def apply_topmost(self):
        self.root.attributes("-topmost", bool(self.always_on_top.get()))

    def _on_autohide_toggle(self):
        if self.auto_hide.get():
            self.close_volume()
            self.schedule_hide()
        else:
            self.show_toolbar()

    def show_toolbar(self):
        if self.hide_job:
            self.root.after_cancel(self.hide_job)
            self.hide_job = None
        if not self.toolbar_visible:
            keep = self.follow_tail
            if keep:
                self._layout_guard = True
            self.toolbar.pack(fill="x", side="top", after=self.hover)
            self.toolbar_visible = True
            if keep:
                self.root.after_idle(self._see_end)

    def hide_toolbar(self):
        if not self.auto_hide.get():
            return
        if self.vol_win is not None or self.hist_win is not None or self.search_win is not None:
            return
        if self.toolbar_visible:
            keep = self.follow_tail
            if keep:
                self._layout_guard = True
            self.toolbar.pack_forget()
            self.toolbar_visible = False
            if keep:
                self.root.after_idle(self._see_end)

    def schedule_hide(self):
        if not self.auto_hide.get():
            return
        if self.vol_win is not None or self.hist_win is not None or self.search_win is not None:
            return
        if self.hide_job:
            self.root.after_cancel(self.hide_job)
        self.hide_job = self.root.after(900, self.hide_toolbar)

    def _pointer_in(self, widget):
        if widget is None:
            return False
        try:
            x, y = self.root.winfo_pointerxy()
            rx = widget.winfo_rootx()
            ry = widget.winfo_rooty()
            rw = widget.winfo_width()
            rh = widget.winfo_height()
            return rx <= x <= rx + rw and ry <= y <= ry + rh
        except tk.TclError:
            return False

    def _on_hover_enter(self, _event=None):
        if self.auto_hide.get():
            self.show_toolbar()

    def _on_toolbar_enter(self, _event=None):
        if self.hide_job:
            self.root.after_cancel(self.hide_job)
            self.hide_job = None

    def _on_chrome_leave(self, _event=None):
        if not self.auto_hide.get():
            return
        self.root.after(40, self._maybe_hide_chrome)

    def _maybe_hide_chrome(self):
        if not self.auto_hide.get():
            return
        if self._pointer_in(self.hover) or self._pointer_in(self.toolbar) or self._pointer_in(self.vol_win) or self._pointer_in(self.hist_win) or self._pointer_in(self.search_win):
            return
        self.schedule_hide()

    def _is_under(self, widget, ancestor):
        if ancestor is None or widget is None:
            return False
        try:
            current = widget
            while current:
                if current == ancestor:
                    return True
                current = getattr(current, "master", None)
        except tk.TclError:
            return False
        return False

    def _on_root_click(self, event):
        widget = event.widget
        if self.vol_win is not None:
            if not (self._is_under(widget, self.vol_win) or self._is_under(widget, self.btn_volume)):
                self.close_volume()
        if self.hist_win is not None:
            if not (self._is_under(widget, self.hist_win) or self._is_under(widget, self.room_wrap)):
                self.close_history()
        if self.search_win is not None:
            if not (self._is_under(widget, self.search_win) or self._is_under(widget, self.btn_search)):
                self.close_search()

    def toggle_volume(self):
        if self.vol_win is not None:
            self.close_volume()
            return
        self.close_history()
        self.close_search()
        win = tk.Toplevel(self.root)
        win.overrideredirect(True)
        win.configure(bg=LINE)
        try:
            win.attributes("-topmost", True)
        except tk.TclError:
            pass
        box = tk.Frame(win, bg=CARD, padx=6, pady=8)
        box.pack(fill="both", expand=True, padx=1, pady=1)
        tk.Label(box, text="音量", bg=CARD, fg=MUTED, font=self.font_ui).pack()
        scale = tk.Scale(
            box,
            from_=100,
            to=0,
            orient="vertical",
            length=140,
            width=14,
            sliderlength=16,
            showvalue=1,
            resolution=1,
            variable=self.volume_var,
            command=self._on_volume,
            bg=CARD,
            fg=TEXT,
            troughcolor=PANEL,
            highlightthickness=0,
            bd=0,
            activebackground=ACCENT,
            font=self.font_ui,
        )
        scale.pack(pady=(4, 2))
        self.root.update_idletasks()
        bx = self.btn_volume.winfo_rootx()
        by = self.btn_volume.winfo_rooty() + self.btn_volume.winfo_height() + 6
        win.geometry("+%d+%d" % (bx, by))
        win.bind("<Enter>", self._on_toolbar_enter)
        win.bind("<Leave>", self._on_chrome_leave)
        self.vol_win = win

    def close_volume(self):
        win = self.vol_win
        self.vol_win = None
        if win is not None:
            try:
                win.destroy()
            except Exception:
                pass
        if self.auto_hide.get():
            self.schedule_hide()

    def toggle_search(self):
        if self.search_win is not None:
            self.close_search()
            return
        self.open_search()

    def close_search(self):
        if self._search_job:
            self.root.after_cancel(self._search_job)
            self._search_job = None
        self._search_gen += 1
        win = self.search_win
        self.search_win = None
        if win is not None:
            try:
                win.destroy()
            except Exception:
                pass
        if self.auto_hide.get():
            self.schedule_hide()

    def open_search(self):
        self.close_volume()
        self.close_history()
        old = self.search_win
        self.search_win = None
        if old is not None:
            try:
                old.destroy()
            except Exception:
                pass
        win = tk.Toplevel(self.root)
        win.overrideredirect(True)
        win.configure(bg=LINE)
        try:
            win.attributes("-topmost", True)
        except tk.TclError:
            pass
        box = tk.Frame(win, bg=CARD)
        box.pack(fill="both", expand=True, padx=1, pady=1)
        head = tk.Frame(box, bg=CARD)
        head.pack(fill="x", padx=8, pady=(8, 6))
        self.search_var = tk.StringVar()
        entry = tk.Entry(
            head,
            textvariable=self.search_var,
            bg=PANEL,
            fg=TEXT,
            insertbackground=TEXT,
            highlightthickness=1,
            highlightbackground=LINE,
            highlightcolor=ACCENT,
            bd=0,
            relief="flat",
            font=self.font_ui,
        )
        entry.pack(side="left", fill="x", expand=True, ipady=5, padx=(0, 6))
        go = Pill(head, "查找", command=self._run_search, kind="primary")
        go.pack(side="right")
        self.search_status = tk.Label(box, text="输入主播名后回车搜索", bg=CARD, fg=MUTED, font=self.font_ui, anchor="w", padx=10)
        self.search_status.pack(fill="x")
        body = tk.Frame(box, bg=CARD)
        body.pack(fill="both", expand=True)
        canvas = tk.Canvas(body, bg=CARD, highlightthickness=0, bd=0, height=240, width=360)
        inner = tk.Frame(canvas, bg=CARD)
        window_id = canvas.create_window((0, 0), window=inner, anchor="nw")
        scroll = tk.Scrollbar(body, orient="vertical", command=canvas.yview, bg=CARD, troughcolor=CARD)
        canvas.configure(yscrollcommand=scroll.set)
        canvas.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        self.search_inner = inner
        self.search_canvas = canvas
        self.search_scroll = scroll

        def _sync_scroll(_event=None):
            canvas.configure(scrollregion=canvas.bbox("all") or (0, 0, 0, 0))
            canvas.itemconfigure(window_id, width=max(canvas.winfo_width(), 1))

        inner.bind("<Configure>", _sync_scroll)
        canvas.bind("<Configure>", _sync_scroll)

        def _wheel(event):
            delta = -1 if getattr(event, "delta", 0) > 0 else 1
            if getattr(event, "num", 0) == 4:
                delta = -1
            elif getattr(event, "num", 0) == 5:
                delta = 1
            canvas.yview_scroll(delta, "units")

        for w in (canvas, inner, box, win):
            w.bind("<MouseWheel>", _wheel)
            w.bind("<Button-4>", _wheel)
            w.bind("<Button-5>", _wheel)

        entry.bind("<Return>", lambda _e: self._run_search())
        entry.bind("<KeyRelease>", self._on_search_key)
        win.bind("<Enter>", self._on_toolbar_enter)
        win.bind("<Leave>", self._on_chrome_leave)
        self.root.update_idletasks()
        rx = self.root.winfo_rootx() + 12
        by = self.btn_search.winfo_rooty() + self.btn_search.winfo_height() + 6
        width = max(self.root.winfo_width() - 24, 300)
        win.geometry("%dx%d+%d+%d" % (width, 320, rx, by))
        self.search_win = win
        if self.hide_job:
            self.root.after_cancel(self.hide_job)
            self.hide_job = None
        entry.focus_set()

    def _on_search_key(self, _event=None):
        if self._search_job:
            self.root.after_cancel(self._search_job)
        self._search_job = self.root.after(280, self._run_search)

    def _run_search(self):
        if self._search_job:
            self.root.after_cancel(self._search_job)
            self._search_job = None
        if self.search_win is None:
            return
        keyword = (self.search_var.get() or "").strip()
        if not keyword:
            self.search_status.configure(text="输入主播名后回车搜索", fg=MUTED)
            self._render_search_results([])
            return
        self._search_gen += 1
        gen = self._search_gen
        self.search_status.configure(text="搜索中...", fg=MUTED)
        threading.Thread(target=self._search_worker, args=(keyword, gen), daemon=True).start()

    def _search_worker(self, keyword, gen):
        try:
            items = search_anchors(keyword)
            err = ""
        except Exception as exc:
            items = []
            err = str(exc)
        self.ui(self._on_search_done, gen, items, err)

    def _on_search_done(self, gen, items, err):
        if gen != self._search_gen or self.search_win is None:
            return
        if err:
            self.search_status.configure(text=err, fg=OFF)
            self._render_search_results([])
            return
        if not items:
            self.search_status.configure(text="没有匹配的主播", fg=MUTED)
        else:
            live_n = sum(1 for x in items if x.get("live_on"))
            self.search_status.configure(text="找到 %d 个主播，其中 %d 个开播" % (len(items), live_n), fg=MUTED)
        self._render_search_results(items)

    def _render_search_results(self, items):
        inner = getattr(self, "search_inner", None)
        if inner is None:
            return
        for child in inner.winfo_children():
            child.destroy()
        for item in items:
            room_id = item.get("room_id") or ""
            nick = item.get("nick") or ""
            live_on = bool(item.get("live_on"))
            fg = OK if live_on else TEXT
            status = "开播" if live_on else "未开播"
            row = tk.Frame(inner, bg=CARD, cursor="hand2")
            row.pack(fill="x")
            room_lbl = tk.Label(row, text=room_id, bg=CARD, fg=fg, font=self.font_ui_b, width=12, anchor="w", padx=10, pady=6, cursor="hand2")
            room_lbl.pack(side="left")
            nick_lbl = tk.Label(row, text=nick or "未知主播", bg=CARD, fg=fg, font=self.font_ui, anchor="w", padx=4, pady=6, cursor="hand2")
            nick_lbl.pack(side="left", fill="x", expand=True)
            st_lbl = tk.Label(row, text=status, bg=CARD, fg=OK if live_on else MUTED, font=self.font_ui, padx=10, pady=6, cursor="hand2")
            st_lbl.pack(side="right")

            def _enter(_event=None, frame=row):
                self._set_history_row(frame, True)

            def _leave(_event=None, frame=row):
                self.root.after(10, lambda f=frame: self._set_history_row(f, False) if not self._pointer_in(f) else None)

            def _pick(_event=None, rid=room_id, name=nick):
                self.pick_search_result(rid, name)
                return "break"

            for w in (row, room_lbl, nick_lbl, st_lbl):
                w.bind("<Enter>", _enter)
                w.bind("<Leave>", _leave)
                w.bind("<Button-1>", _pick)

    def pick_search_result(self, room_id, nick):
        room_id = str(room_id or "").strip()
        nick = (nick or "").strip()
        if not room_id:
            return
        label = "%s  %s" % (room_id, nick) if nick else room_id
        self.room_var.set(label)
        self.history.remember(room_id, nick=nick)
        self.refresh_history()
        self.close_search()

    def _on_volume(self, value):
        if self._vol_job:
            self.root.after_cancel(self._vol_job)
        self._vol_job = self.root.after(40, lambda: self.audio.set_volume(value))

    def _on_list_scroll(self, first, last):
        self._vscroll.set(first, last)
        if self._layout_guard:
            return
        try:
            self.follow_tail = float(last) >= 0.98
        except Exception:
            pass

    def _on_list_configure(self, _event=None):
        if self.follow_tail and not self._layout_guard:
            self.listbox.see("end")

    def _see_end(self):
        self.follow_tail = True
        self._layout_guard = True
        self.listbox.see("end")
        self.root.after(30, self._finish_see_end)

    def _finish_see_end(self):
        self.listbox.see("end")
        self.follow_tail = True
        self._layout_guard = False

    def ui(self, fn, *args):
        self.root.after(0, lambda: fn(*args))

    def _phase_of(self, text, ok):
        if ok:
            return "on"
        if "中" in (text or ""):
            return "busy"
        return "off"

    def _on_danmu_status(self, text, ok):
        self.danmu_phase = self._phase_of(text, ok)
        self.ui(self._sync_buttons)

    def _on_audio_status(self, text, ok):
        self.audio_phase = self._phase_of(text, ok)
        self.ui(self._sync_buttons)

    def _sync_buttons(self):
        self.btn_danmu.set_kind(self.danmu_phase)
        self.btn_audio.set_kind(self.audio_phase)
        if self.danmu_phase == "on" and self.audio_phase == "on":
            start_kind = "on"
        elif self.danmu_phase == "off" and self.audio_phase == "off":
            start_kind = "off"
        else:
            start_kind = "busy"
        self.btn_connect.set_kind(start_kind)

    def append_danmu(self, user, text, color):
        follow = self.follow_tail
        tag = "c_%s" % (color or TEXT)
        if tag not in self.listbox.tag_names():
            self.listbox.tag_configure(tag, foreground=color or TEXT, font=self.font_danmu)
        name_tag = "sys" if user == "系统" else "name"
        self.listbox.configure(state="normal")
        self.listbox.insert("end", user, name_tag)
        self.listbox.insert("end", "  ")
        self.listbox.insert("end", text + "\n", tag)
        self.danmu_count += 1
        if self.danmu_count >= MAX_DANMU:
            pos = "1.0"
            for _ in range(TRIM_COUNT):
                found = self.listbox.search("\n", pos, stopindex="end")
                if not found:
                    break
                pos = self.listbox.index("%s+1c" % found)
            self.listbox.delete("1.0", pos)
            self.danmu_count = max(0, self.danmu_count - TRIM_COUNT)
        self.listbox.configure(state="disabled")
        if follow:
            self.listbox.see("end")
            self.follow_tail = True

    def _on_danmu(self, user, text, color=TEXT):
        self.ui(self.append_danmu, user, text, color)

    def clear_danmu(self):
        self.listbox.configure(state="normal")
        self.listbox.delete("1.0", "end")
        self.listbox.configure(state="disabled")
        self.danmu_count = 0
        self.follow_tail = True

    def _load_room(self, room_id):
        room_id = normalize_room_id(room_id)
        room = fetch_room(room_id)
        self.history.remember(room["room_id"], nick=room.get("nick") or "")
        self.ui(self.refresh_history)
        self.ui(self.room_var.set, room["room_id"])
        return room

    def connect_all(self):
        self.danmu_phase = "busy"
        self.audio_phase = "busy"
        self._sync_buttons()
        room_id = self.current_room_id() or self.room_var.get()
        threading.Thread(target=self._connect_all_worker, args=(room_id,), daemon=True).start()

    def _connect_all_worker(self, room_id):
        try:
            room = self._load_room(room_id)
        except Exception as exc:
            self.danmu_phase = "off"
            self.audio_phase = "off"
            self.ui(self._sync_buttons)
            self.ui(messagebox.showerror, "连接失败", str(exc))
            return
        self.ui(self._start_danmu, room)
        self.ui(self._start_audio, room)

    def toggle_danmu(self):
        if self.danmaku.connected or self.danmu_phase in ("on", "busy"):
            self.danmaku.stop()
            self.danmu_phase = "off"
            self._sync_buttons()
            return
        self.danmu_phase = "busy"
        self._sync_buttons()
        room_id = self.current_room_id() or self.room_var.get()
        threading.Thread(target=self._connect_danmu_worker, args=(room_id,), daemon=True).start()

    def _connect_danmu_worker(self, room_id):
        try:
            room = self._load_room(room_id)
        except Exception as exc:
            self.danmu_phase = "off"
            self.ui(self._sync_buttons)
            self.ui(messagebox.showerror, "弹幕连接失败", str(exc))
            return
        self.ui(self._start_danmu, room)

    def _start_danmu(self, room):
        self.danmaku.start(room["uid"] or room["yyid"], room["top_sid"], room["sub_sid"])
        self._sync_buttons()

    def toggle_audio(self):
        if self.audio.connected or self.audio_phase in ("on", "busy"):
            self.audio.stop()
            self.audio_phase = "off"
            self._sync_buttons()
            return
        self.audio_phase = "busy"
        self._sync_buttons()
        room_id = self.current_room_id() or self.room_var.get()
        threading.Thread(target=self._connect_audio_worker, args=(room_id,), daemon=True).start()

    def _connect_audio_worker(self, room_id):
        try:
            room = self._load_room(room_id)
        except Exception as exc:
            self.audio_phase = "off"
            self.ui(self._sync_buttons)
            self.ui(messagebox.showerror, "音频连接失败", str(exc))
            return
        self.ui(self._start_audio, room)

    def _start_audio(self, room):
        try:
            self.audio.start(room)
        except Exception as exc:
            self.audio_phase = "off"
            messagebox.showerror("音频连接失败", str(exc))
        self._sync_buttons()

    def on_close(self):
        self.close_search()
        self.close_history()
        self.close_volume()
        try:
            self.danmaku.stop()
        except Exception:
            pass
        try:
            self.audio.stop()
        except Exception:
            pass
        self.root.destroy()


def main():
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    root = tk.Tk()
    HuyaDanmuApp(root)
    if not find_ffplay():
        root.after(400, lambda: messagebox.showinfo(
            "音频提示",
            "听直播音频需要 ffplay.exe。\n把 ffmpeg 的 ffplay.exe 放到本程序目录的 bin 文件夹即可。",
        ))
    root.mainloop()


if __name__ == "__main__":
    main()
