#!/usr/bin/env python3
"""Image Size Reducer - Compress a folder of images to a target file size."""

import io
import math
import os
import queue
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import Optional, Tuple

from PIL import Image

SUPPORTED = {'.jpg', '.jpeg', '.png', '.webp', '.bmp', '.tiff', '.tif'}
MIN_KB, MAX_KB, DEFAULT_KB = 10, 10_240, 100


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def fmt_size(b: int) -> str:
    if b < 1024:
        return f"{b} B"
    if b < 1_048_576:
        return f"{b / 1024:.1f} KB"
    return f"{b / 1_048_576:.2f} MB"


def slider_to_kb(v: float) -> int:
    lo = math.log10(MIN_KB)
    hi = math.log10(MAX_KB)
    return max(MIN_KB, min(MAX_KB, round(10 ** (lo + v / 100.0 * (hi - lo)))))


def kb_to_slider(kb: int) -> float:
    lo = math.log10(MIN_KB)
    hi = math.log10(MAX_KB)
    return (math.log10(max(MIN_KB, min(MAX_KB, kb))) - lo) / (hi - lo) * 100.0


def find_images(root: Path, exclude: Path) -> list:
    result = []
    for dirpath, dirs, files in os.walk(root):
        dp = Path(dirpath)
        dirs[:] = sorted(d for d in dirs if dp / d != exclude)
        for f in sorted(files):
            p = dp / f
            if p.suffix.lower() in SUPPORTED:
                result.append(p)
    return result


# ---------------------------------------------------------------------------
# Compression logic
# ---------------------------------------------------------------------------

def compress_image(
    src: Path,
    dst: Path,
    target: int,
    max_w: Optional[int] = None,
    max_h: Optional[int] = None,
) -> Tuple[str, int, int, str]:
    """Compress image at src to dst so its size <= target bytes.

    If max_w / max_h are set the image is first scaled down to fit within
    those bounds (aspect ratio preserved). Then file-size compression is
    applied on top of the result.

    Returns (status, original_bytes, final_bytes, message)
    status: 'skip' | 'success' | 'error'
    """
    orig = src.stat().st_size
    ext = src.suffix.lower()

    try:
        img = Image.open(src)

        if ext in {'.jpg', '.jpeg'} and img.mode not in ('RGB', 'L', 'CMYK'):
            img = img.convert('RGB')

        W, H = img.size

        # --- Step 0: pixel-dimension cap (if requested) ---
        needs_px = (max_w and W > max_w) or (max_h and H > max_h)
        px_label = ""
        if needs_px:
            scale = 1.0
            if max_w and W > max_w:
                scale = min(scale, max_w / W)
            if max_h and H > max_h:
                scale = min(scale, max_h / H)
            nw = max(int(W * scale), 1)
            nh = max(int(H * scale), 1)
            img = img.resize((nw, nh), Image.LANCZOS)
            W, H = nw, nh
            px_label = f"{nw}×{nh}"

        # Skip only when the file already fits every constraint
        if orig <= target and not needs_px:
            return 'skip', orig, orig, "Déjà sous le seuil"

        def to_bytes(im: Image.Image, q: int = 85) -> bytes:
            buf = io.BytesIO()
            if ext in {'.jpg', '.jpeg'}:
                im.save(buf, 'JPEG', quality=q, optimize=True)
            elif ext == '.webp':
                im.save(buf, 'WEBP', quality=q, method=6)
            elif ext == '.png':
                im.save(buf, 'PNG', optimize=True, compress_level=9)
            elif ext in {'.tiff', '.tif'}:
                im.save(buf, 'TIFF', compression='tiff_lzw')
            else:
                im.save(buf, 'BMP')
            return buf.getvalue()

        def best_quality(im: Image.Image) -> Optional[bytes]:
            """Binary-search for the highest quality that fits in target."""
            lo, hi, best = 10, 95, None
            while lo <= hi:
                mid = (lo + hi) // 2
                d = to_bytes(im, mid)
                if len(d) <= target:
                    best, lo = d, mid + 1
                else:
                    hi = mid - 1
            return best

        # After pixel resize, check if we're already under the size target
        if needs_px:
            is_lossy_check = ext in {'.jpg', '.jpeg', '.webp'}
            d0 = to_bytes(img, 95 if is_lossy_check else 85)
            if len(d0) <= target:
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_bytes(d0)
                return 'success', orig, len(d0), f"Redimensionné {px_label}"

        # Step 1 — quality reduction (lossy formats only)
        if ext in {'.jpg', '.jpeg', '.webp'}:
            d = best_quality(img)
            if d:
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_bytes(d)
                msg = f"{px_label} — qualité réduite" if px_label else "Qualité réduite"
                return 'success', orig, len(d), msg

        # Step 2 — dimension reduction (binary search on scale %)
        lo_s, hi_s = 5, 95
        best_s: Optional[int] = None
        best_d: Optional[bytes] = None
        is_lossy = ext in {'.jpg', '.jpeg', '.webp'}

        while lo_s <= hi_s:
            mid_s = (lo_s + hi_s) // 2
            nw = max(int(W * mid_s / 100), 8)
            nh = max(int(H * mid_s / 100), 8)
            r = img.resize((nw, nh), Image.LANCZOS)
            d = to_bytes(r, 85) if is_lossy else to_bytes(r)
            if len(d) <= target:
                best_s, best_d, hi_s = mid_s, d, mid_s - 1
            else:
                lo_s = mid_s + 1

        if best_s is not None:
            nw = max(int(W * best_s / 100), 8)
            nh = max(int(H * best_s / 100), 8)
            r = img.resize((nw, nh), Image.LANCZOS)
            if is_lossy:
                optimized = best_quality(r)
                if optimized:
                    best_d = optimized
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(best_d)
            dim_msg = f"Redimensionné {nw}×{nh}"
            msg = f"{px_label} — {dim_msg.lower()}" if px_label else dim_msg
            return 'success', orig, len(best_d), msg

        return 'error', orig, orig, f"Impossible d'atteindre {fmt_size(target)}"

    except Exception as e:
        return 'error', orig, 0, f"Erreur : {e}"


# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Image Size Reducer")
        self.geometry("980x700")
        self.minsize(760, 540)
        self.configure(bg='#f4f4f4')
        self._q: queue.Queue = queue.Queue()
        self._cancel = False
        self._setup_style()
        self._build()
        self._poll()

    # ------------------------------------------------------------------
    # Style
    # ------------------------------------------------------------------

    def _setup_style(self):
        s = ttk.Style(self)
        s.theme_use('clam')
        bg = '#f4f4f4'
        s.configure('.', background=bg, font=('Segoe UI', 10))
        s.configure('TFrame', background=bg)
        s.configure('TLabelframe', background=bg)
        s.configure('TLabelframe.Label', font=('Segoe UI', 10, 'bold'),
                    foreground='#2c3e50', background=bg)
        s.configure('H.TLabel', font=('Segoe UI', 17, 'bold'),
                    foreground='#2c3e50', background=bg)
        s.configure('Muted.TLabel', font=('Segoe UI', 9),
                    foreground='#888888', background=bg)
        s.configure('Val.TLabel', font=('Segoe UI', 11, 'bold'),
                    foreground='#2980b9', background=bg)
        s.configure('Big.TButton', font=('Segoe UI', 11, 'bold'), padding=(14, 8))
        s.configure('Treeview', rowheight=23, font=('Segoe UI', 9))
        s.configure('Treeview.Heading', font=('Segoe UI', 9, 'bold'))

    # ------------------------------------------------------------------
    # UI construction
    # ------------------------------------------------------------------

    def _build(self):
        outer = ttk.Frame(self, padding=(18, 14, 18, 14))
        outer.pack(fill='both', expand=True)

        ttk.Label(outer, text="Image Size Reducer", style='H.TLabel').pack(
            anchor='w', pady=(0, 10))

        # Source folder
        sf = ttk.LabelFrame(outer, text="Dossier source", padding=(8, 6))
        sf.pack(fill='x', pady=(0, 4))
        self._src = tk.StringVar()
        self._src.trace_add('write', self._update_dst_label)
        ttk.Entry(sf, textvariable=self._src).pack(
            side='left', fill='x', expand=True, padx=(0, 8))
        ttk.Button(sf, text="Parcourir…", command=self._browse).pack(side='right')

        self._dst_lbl = ttk.Label(
            outer, text="Dossier de sortie : —", style='Muted.TLabel')
        self._dst_lbl.pack(anchor='w', padx=4, pady=(0, 8))

        # Target size
        tf = ttk.LabelFrame(outer, text="Taille cible maximale", padding=(8, 6))
        tf.pack(fill='x', pady=(0, 8))

        r1 = ttk.Frame(tf)
        r1.pack(fill='x')
        ttk.Label(r1, text="10 KB", style='Muted.TLabel').pack(side='left')
        self._sv = tk.DoubleVar(value=kb_to_slider(DEFAULT_KB))
        ttk.Scale(r1, from_=0, to=100, variable=self._sv, orient='horizontal',
                  command=self._on_slide).pack(side='left', fill='x', expand=True, padx=6)
        ttk.Label(r1, text="10 MB", style='Muted.TLabel').pack(side='left')

        r2 = ttk.Frame(tf)
        r2.pack(fill='x', pady=(6, 0))
        self._val_lbl = tk.StringVar(value="100 KB")
        ttk.Label(r2, text="Valeur sélectionnée :").pack(side='left')
        ttk.Label(r2, textvariable=self._val_lbl, style='Val.TLabel').pack(
            side='left', padx=(4, 24))
        ttk.Label(r2, text="Saisie manuelle (KB) :").pack(side='left')
        self._entry = ttk.Entry(r2, width=8)
        self._entry.insert(0, str(DEFAULT_KB))
        self._entry.pack(side='left', padx=(4, 6))
        ttk.Button(r2, text="Appliquer", command=self._apply_entry).pack(side='left')

        # Pixel-dimension cap
        pf = ttk.LabelFrame(outer, text="Dimensions de sortie (pixels)", padding=(8, 6))
        pf.pack(fill='x', pady=(0, 8))

        self._px_on = tk.BooleanVar(value=False)
        ttk.Checkbutton(
            pf,
            text="Limiter les dimensions en pixels (ratio conservé)",
            variable=self._px_on,
            command=self._toggle_px,
        ).pack(anchor='w')

        self._px_opts = ttk.Frame(pf)
        # Packed on demand by _toggle_px

        po = self._px_opts
        ttk.Label(po, text="Largeur max :").pack(side='left')
        self._max_w_var = tk.StringVar()
        ttk.Entry(po, textvariable=self._max_w_var, width=7).pack(side='left', padx=(4, 2))
        ttk.Label(po, text="px", style='Muted.TLabel').pack(side='left', padx=(0, 16))
        ttk.Label(po, text="Hauteur max :").pack(side='left')
        self._max_h_var = tk.StringVar()
        ttk.Entry(po, textvariable=self._max_h_var, width=7).pack(side='left', padx=(4, 2))
        ttk.Label(po, text="px", style='Muted.TLabel').pack(side='left', padx=(0, 12))
        ttk.Label(po, text="(laisser un champ vide pour ignorer cet axe)",
                  style='Muted.TLabel').pack(side='left')

        # Action buttons
        br = ttk.Frame(outer)
        br.pack(fill='x', pady=(4, 6))
        self._btn_start = ttk.Button(
            br, text="▶  Démarrer la compression",
            style='Big.TButton', command=self._start)
        self._btn_start.pack(side='left')
        self._btn_cancel = ttk.Button(
            br, text="✕  Annuler",
            command=self._do_cancel, state='disabled')
        self._btn_cancel.pack(side='left', padx=10)
        self._summary_var = tk.StringVar()
        ttk.Label(br, textvariable=self._summary_var,
                  style='Muted.TLabel').pack(side='right')

        # Progress bar
        pr = ttk.Frame(outer)
        pr.pack(fill='x', pady=(0, 8))
        self._pvar = tk.DoubleVar()
        ttk.Progressbar(pr, variable=self._pvar, maximum=100).pack(
            side='left', fill='x', expand=True)
        self._plbl = ttk.Label(pr, text="", width=12, anchor='e')
        self._plbl.pack(side='right', padx=(8, 0))

        # Results table
        rf = ttk.LabelFrame(outer, text="Résultats", padding=4)
        rf.pack(fill='both', expand=True)
        cols = ('file', 'orig', 'comp', 'ratio', 'status')
        headers = [
            ("Fichier", 340, 'w'),
            ("Original", 88, 'e'),
            ("Compressé", 90, 'e'),
            ("Ratio", 62, 'center'),
            ("Statut", 230, 'w'),
        ]
        self._tree = ttk.Treeview(
            rf, columns=cols, show='headings', selectmode='browse')
        for col, (txt, w, anc) in zip(cols, headers):
            self._tree.heading(col, text=txt)
            self._tree.column(col, width=w, minwidth=40, anchor=anc)
        self._tree.tag_configure('success', foreground='#27ae60')
        self._tree.tag_configure('skip',    foreground='#2980b9')
        self._tree.tag_configure('error',   foreground='#c0392b')
        self._tree.tag_configure('running', foreground='#e67e22')
        sb = ttk.Scrollbar(rf, orient='vertical', command=self._tree.yview)
        self._tree.configure(yscrollcommand=sb.set)
        self._tree.pack(side='left', fill='both', expand=True)
        sb.pack(side='right', fill='y')

    # ------------------------------------------------------------------
    # Callbacks
    # ------------------------------------------------------------------

    def _update_dst_label(self, *_):
        src = self._src.get().strip()
        if src and Path(src).is_dir():
            self._dst_lbl.config(
                text=f"Dossier de sortie : {Path(src) / 'compress'}")
        else:
            self._dst_lbl.config(text="Dossier de sortie : —")

    def _browse(self):
        d = filedialog.askdirectory(title="Sélectionner le dossier source")
        if d:
            self._src.set(d)

    def _on_slide(self, _=None):
        kb = slider_to_kb(self._sv.get())
        self._val_lbl.set(fmt_size(kb * 1024))
        self._entry.delete(0, 'end')
        self._entry.insert(0, str(kb))

    def _apply_entry(self):
        try:
            kb = int(self._entry.get())
            kb = max(MIN_KB, min(MAX_KB, kb))
            self._sv.set(kb_to_slider(kb))
            self._val_lbl.set(fmt_size(kb * 1024))
            self._entry.delete(0, 'end')
            self._entry.insert(0, str(kb))
        except ValueError:
            messagebox.showerror("Erreur", "Veuillez entrer un entier valide.")

    def _toggle_px(self):
        if self._px_on.get():
            self._px_opts.pack(fill='x', pady=(6, 0))
        else:
            self._px_opts.pack_forget()

    def _get_px_dims(self) -> Tuple[Optional[int], Optional[int]]:
        max_w = max_h = None
        try:
            v = self._max_w_var.get().strip()
            if v:
                max_w = max(1, int(v))
        except ValueError:
            pass
        try:
            v = self._max_h_var.get().strip()
            if v:
                max_h = max(1, int(v))
        except ValueError:
            pass
        return max_w, max_h

    def _target_bytes(self) -> int:
        return slider_to_kb(self._sv.get()) * 1024

    def _start(self):
        src = self._src.get().strip()
        if not src or not Path(src).is_dir():
            messagebox.showwarning(
                "Attention", "Veuillez sélectionner un dossier source valide.")
            return

        max_w, max_h = None, None
        if self._px_on.get():
            max_w, max_h = self._get_px_dims()
            if max_w is None and max_h is None:
                messagebox.showwarning(
                    "Attention",
                    "La limitation en pixels est activée mais aucune dimension n'est saisie.\n"
                    "Entrez une largeur et/ou une hauteur maximale.")
                return

        for item in self._tree.get_children():
            self._tree.delete(item)
        self._pvar.set(0)
        self._plbl.config(text="")
        self._summary_var.set("")
        self._cancel = False
        self._btn_start.config(state='disabled')
        self._btn_cancel.config(state='normal')
        threading.Thread(
            target=self._run,
            args=(Path(src), self._target_bytes(), max_w, max_h),
            daemon=True,
        ).start()

    def _do_cancel(self):
        self._cancel = True
        self._btn_cancel.config(state='disabled')

    # ------------------------------------------------------------------
    # Worker thread
    # ------------------------------------------------------------------

    def _run(self, src: Path, target: int,
             max_w: Optional[int] = None, max_h: Optional[int] = None):
        dst_base = src / 'compress'
        files = find_images(src, exclude=dst_base)
        total = len(files)
        if total == 0:
            self._q.put(('done', 0, 0, 0, 0))
            return

        ok = skip = err = 0
        saved = 0

        for i, fp in enumerate(files):
            if self._cancel:
                break
            rel = str(fp.relative_to(src))
            iid = str(i)
            self._q.put(('start', iid, rel, i, total))

            status, orig, final, msg = compress_image(
                fp, dst_base / fp.relative_to(src), target, max_w, max_h)

            if status == 'success':
                ok += 1
                saved += orig - final
            elif status == 'skip':
                skip += 1
            else:
                err += 1

            ratio = (f"{round(final / orig * 100)}%"
                     if orig and status == 'success' else "—")
            comp_str = fmt_size(final) if status == 'success' else "—"
            self._q.put(('result', iid, fmt_size(orig), comp_str, ratio, status, msg))

        self._q.put(('done', ok, skip, err, saved))

    # ------------------------------------------------------------------
    # Queue polling (main thread)
    # ------------------------------------------------------------------

    def _poll(self):
        try:
            while True:
                msg = self._q.get_nowait()
                kind = msg[0]

                if kind == 'start':
                    _, iid, rel, i, total = msg
                    self._pvar.set(i / total * 100)
                    self._plbl.config(text=f"{i + 1} / {total}")
                    self._tree.insert('', 'end', iid=iid,
                                      values=(rel, '…', '…', '…', 'En cours…'),
                                      tags=('running',))
                    self._tree.see(iid)

                elif kind == 'result':
                    _, iid, orig, comp, ratio, status, note = msg
                    icons = {'success': '✓', 'skip': '→', 'error': '✗'}
                    label = f"{icons.get(status, '')}  {note}"
                    try:
                        prev = self._tree.item(iid, 'values')
                        self._tree.item(iid,
                                        values=(prev[0], orig, comp, ratio, label),
                                        tags=(status,))
                    except tk.TclError:
                        pass

                elif kind == 'done':
                    _, ok, skip, err, saved = msg
                    self._pvar.set(100)
                    self._plbl.config(text="Terminé")
                    self._btn_start.config(state='normal')
                    self._btn_cancel.config(state='disabled')
                    parts = [
                        f"✓ {ok} compressée(s)",
                        f"→ {skip} ignorée(s)",
                        f"✗ {err} erreur(s)",
                    ]
                    if saved:
                        parts.append(f"| Économisé : {fmt_size(saved)}")
                    self._summary_var.set("   ".join(parts))

        except queue.Empty:
            pass

        self.after(40, self._poll)


if __name__ == '__main__':
    App().mainloop()
