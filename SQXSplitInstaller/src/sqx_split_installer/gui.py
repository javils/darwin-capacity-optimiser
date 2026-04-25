"""Tkinter GUI for SQXSplitInstaller.

A thin front-end over the same `install_library` and `patch_file` functions the
CLI uses. Two tabs: Install (library into MT5) and Patch (rewrite SQX EAs).
Long-running work is executed on a background thread so the UI stays
responsive; status is reported in a log box on each tab.
"""

from __future__ import annotations

import queue
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, ttk

from sqx_split_installer.cli import (
    DELAY_SECONDS_MAX,
    DELAY_SECONDS_MIN,
    SPLIT_COUNT_MAX,
    SPLIT_COUNT_MIN,
)
from sqx_split_installer.install import InstallError, install_library
from sqx_split_installer.patcher import PatchError, patch_file


PADDING = 8
LOG_HEIGHT = 12


# --- Generic helpers ---------------------------------------------------------


def _expand_paths(paths: list[Path]) -> list[Path]:
    """Mirror cli._expand_inputs for the GUI: directories become their *.mq5
    files (non-recursive), order preserved, deduped."""
    out: list[Path] = []
    seen: set[Path] = set()
    for p in paths:
        if p.is_dir():
            for f in sorted(p.glob("*.mq5")):
                key = f.resolve()
                if key not in seen:
                    seen.add(key)
                    out.append(f)
        elif p.is_file():
            key = p.resolve()
            if key not in seen:
                seen.add(key)
                out.append(p)
    return out


# --- Install tab -------------------------------------------------------------


class InstallTab(ttk.Frame):
    def __init__(self, parent: tk.Misc) -> None:
        super().__init__(parent, padding=PADDING)
        self._terminal_var = tk.StringVar()
        self._log_queue: queue.Queue[str] = queue.Queue()
        self._busy = False
        self._build()
        self.after(100, self._drain_log)

    def _build(self) -> None:
        ttk.Label(self, text="MetaTrader 5 terminal folder:").grid(
            row=0, column=0, sticky="w", pady=(0, 4)
        )
        entry = ttk.Entry(self, textvariable=self._terminal_var, width=60)
        entry.grid(row=1, column=0, sticky="ew", padx=(0, 4))
        ttk.Button(self, text="Browse…", command=self._browse).grid(row=1, column=1)

        self._install_btn = ttk.Button(self, text="Install", command=self._on_install)
        self._install_btn.grid(row=2, column=0, columnspan=2, pady=(PADDING, 4))

        self._log = tk.Text(self, height=LOG_HEIGHT, state="disabled", wrap="word")
        self._log.grid(row=3, column=0, columnspan=2, sticky="nsew", pady=(PADDING, 0))

        self.columnconfigure(0, weight=1)
        self.rowconfigure(3, weight=1)

    def _browse(self) -> None:
        path = filedialog.askdirectory(title="Select MT5 terminal folder")
        if path:
            self._terminal_var.set(path)

    def _on_install(self) -> None:
        if self._busy:
            return
        terminal = self._terminal_var.get().strip()
        if not terminal:
            self._append("error: please select a terminal folder.\n")
            return

        self._busy = True
        self._install_btn.state(["disabled"])
        threading.Thread(
            target=self._run_install, args=(Path(terminal),), daemon=True
        ).start()

    def _run_install(self, terminal: Path) -> None:
        try:
            installed = install_library(terminal)
            self._append(f"Installed {len(installed)} files to {installed[0].parent}:\n")
            for path in installed:
                self._append(f"  - {path.name}\n")
            self._append("Done.\n\n")
        except InstallError as exc:
            self._append(f"error: {exc}\n\n")
        except OSError as exc:
            self._append(f"error: {exc}\n\n")
        finally:
            self._log_queue.put("__DONE__")

    def _append(self, text: str) -> None:
        self._log_queue.put(text)

    def _drain_log(self) -> None:
        try:
            while True:
                msg = self._log_queue.get_nowait()
                if msg == "__DONE__":
                    self._busy = False
                    self._install_btn.state(["!disabled"])
                else:
                    self._log.configure(state="normal")
                    self._log.insert("end", msg)
                    self._log.see("end")
                    self._log.configure(state="disabled")
        except queue.Empty:
            pass
        self.after(100, self._drain_log)


# --- Patch tab ---------------------------------------------------------------


class PatchTab(ttk.Frame):
    def __init__(self, parent: tk.Misc) -> None:
        super().__init__(parent, padding=PADDING)
        self._inputs: list[Path] = []
        self._output_var = tk.StringVar()
        self._suffix_var = tk.StringVar(value="_split")
        self._split_var = tk.IntVar(value=3)
        self._delay_var = tk.IntVar(value=10)
        self._log_queue: queue.Queue[str] = queue.Queue()
        self._busy = False
        self._build()
        self.after(100, self._drain_log)

    def _build(self) -> None:
        # Inputs section
        ttk.Label(self, text="Input files / folders:").grid(
            row=0, column=0, columnspan=4, sticky="w"
        )
        self._inputs_box = tk.Listbox(self, height=6, selectmode="extended")
        self._inputs_box.grid(row=1, column=0, columnspan=4, sticky="ew", pady=(2, 4))

        ttk.Button(self, text="Add files…", command=self._add_files).grid(row=2, column=0, sticky="ew", padx=(0, 2))
        ttk.Button(self, text="Add folder…", command=self._add_folder).grid(row=2, column=1, sticky="ew", padx=2)
        ttk.Button(self, text="Remove", command=self._remove_selected).grid(row=2, column=2, sticky="ew", padx=2)
        ttk.Button(self, text="Clear", command=self._clear).grid(row=2, column=3, sticky="ew", padx=(2, 0))

        # Settings grid
        settings = ttk.LabelFrame(self, text="Settings", padding=PADDING)
        settings.grid(row=3, column=0, columnspan=4, sticky="ew", pady=(PADDING, 0))
        settings.columnconfigure(1, weight=1)

        ttk.Label(settings, text="Output directory:").grid(row=0, column=0, sticky="w")
        ttk.Entry(settings, textvariable=self._output_var).grid(row=0, column=1, sticky="ew", padx=4)
        ttk.Button(settings, text="Browse…", command=self._browse_output).grid(row=0, column=2)
        ttk.Label(settings, text="(empty = alongside each input)", foreground="grey").grid(
            row=1, column=1, sticky="w", padx=4
        )

        ttk.Label(settings, text="Suffix:").grid(row=2, column=0, sticky="w", pady=(6, 0))
        ttk.Entry(settings, textvariable=self._suffix_var, width=12).grid(
            row=2, column=1, sticky="w", padx=4, pady=(6, 0)
        )

        ttk.Label(settings, text=f"Split count ({SPLIT_COUNT_MIN}-{SPLIT_COUNT_MAX}):").grid(
            row=3, column=0, sticky="w", pady=(6, 0)
        )
        ttk.Spinbox(
            settings, from_=SPLIT_COUNT_MIN, to=SPLIT_COUNT_MAX, textvariable=self._split_var, width=6
        ).grid(row=3, column=1, sticky="w", padx=4, pady=(6, 0))

        ttk.Label(settings, text=f"Split delay seconds ({DELAY_SECONDS_MIN}-{DELAY_SECONDS_MAX}):").grid(
            row=4, column=0, sticky="w", pady=(6, 0)
        )
        ttk.Spinbox(
            settings, from_=DELAY_SECONDS_MIN, to=DELAY_SECONDS_MAX, textvariable=self._delay_var, width=6
        ).grid(row=4, column=1, sticky="w", padx=4, pady=(6, 0))

        # Action button
        self._patch_btn = ttk.Button(self, text="Patch", command=self._on_patch)
        self._patch_btn.grid(row=4, column=0, columnspan=4, pady=(PADDING, 4))

        # Log box
        self._log = tk.Text(self, height=LOG_HEIGHT, state="disabled", wrap="word")
        self._log.grid(row=5, column=0, columnspan=4, sticky="nsew", pady=(PADDING, 0))

        for c in range(4):
            self.columnconfigure(c, weight=1)
        self.rowconfigure(5, weight=1)

    # --- input list management -----------------------------------------------

    def _add_files(self) -> None:
        paths = filedialog.askopenfilenames(
            title="Select .mq5 files", filetypes=[("MQL5 files", "*.mq5"), ("All files", "*.*")]
        )
        for p in paths:
            path = Path(p)
            if path not in self._inputs:
                self._inputs.append(path)
        self._refresh_inputs()

    def _add_folder(self) -> None:
        folder = filedialog.askdirectory(title="Select folder containing .mq5 files")
        if folder:
            path = Path(folder)
            if path not in self._inputs:
                self._inputs.append(path)
        self._refresh_inputs()

    def _remove_selected(self) -> None:
        for idx in reversed(self._inputs_box.curselection()):
            del self._inputs[idx]
        self._refresh_inputs()

    def _clear(self) -> None:
        self._inputs.clear()
        self._refresh_inputs()

    def _refresh_inputs(self) -> None:
        self._inputs_box.delete(0, "end")
        for p in self._inputs:
            self._inputs_box.insert("end", str(p))

    def _browse_output(self) -> None:
        folder = filedialog.askdirectory(title="Select output folder")
        if folder:
            self._output_var.set(folder)

    # --- run -----------------------------------------------------------------

    def _on_patch(self) -> None:
        if self._busy:
            return
        if not self._inputs:
            self._append("error: add at least one file or folder.\n")
            return

        try:
            split_count = int(self._split_var.get())
            delay_seconds = int(self._delay_var.get())
        except (tk.TclError, ValueError):
            self._append("error: split count and delay must be integers.\n")
            return

        if not SPLIT_COUNT_MIN <= split_count <= SPLIT_COUNT_MAX:
            self._append(f"error: split count must be {SPLIT_COUNT_MIN}-{SPLIT_COUNT_MAX}.\n")
            return
        if not DELAY_SECONDS_MIN <= delay_seconds <= DELAY_SECONDS_MAX:
            self._append(f"error: delay must be {DELAY_SECONDS_MIN}-{DELAY_SECONDS_MAX} seconds.\n")
            return

        suffix = self._suffix_var.get() or "_split"
        output_text = self._output_var.get().strip()
        output_dir = Path(output_text) if output_text else None

        self._busy = True
        self._patch_btn.state(["disabled"])
        threading.Thread(
            target=self._run_patch,
            args=(list(self._inputs), split_count, delay_seconds, output_dir, suffix),
            daemon=True,
        ).start()

    def _run_patch(
        self,
        inputs: list[Path],
        split_count: int,
        delay_seconds: int,
        output_dir: Path | None,
        suffix: str,
    ) -> None:
        files = _expand_paths(inputs)
        if not files:
            self._append("error: no .mq5 files found in the provided inputs.\n\n")
            self._log_queue.put("__DONE__")
            return

        ok = 0
        fail = 0
        for src in files:
            target_dir = output_dir if output_dir is not None else src.parent
            target = target_dir / f"{src.stem}{suffix}.mq5"
            try:
                patch_file(src, target, split_count, delay_seconds)
                self._append(f"  OK   {src.name} → {target}\n")
                ok += 1
            except PatchError as exc:
                self._append(f"  FAIL {src.name}: {exc}\n")
                fail += 1
            except OSError as exc:
                self._append(f"  FAIL {src.name}: {exc}\n")
                fail += 1

        self._append(f"\nDone. {ok} succeeded, {fail} failed.\n\n")
        self._log_queue.put("__DONE__")

    def _append(self, text: str) -> None:
        self._log_queue.put(text)

    def _drain_log(self) -> None:
        try:
            while True:
                msg = self._log_queue.get_nowait()
                if msg == "__DONE__":
                    self._busy = False
                    self._patch_btn.state(["!disabled"])
                else:
                    self._log.configure(state="normal")
                    self._log.insert("end", msg)
                    self._log.see("end")
                    self._log.configure(state="disabled")
        except queue.Empty:
            pass
        self.after(100, self._drain_log)


# --- App ---------------------------------------------------------------------


def build_app() -> tk.Tk:
    root = tk.Tk()
    root.title("SQX Split Installer")
    root.geometry("760x600")
    root.minsize(640, 520)

    notebook = ttk.Notebook(root)
    notebook.pack(fill="both", expand=True, padx=PADDING, pady=PADDING)

    notebook.add(InstallTab(notebook), text="Install Library")
    notebook.add(PatchTab(notebook), text="Patch Strategies")

    return root


def main() -> int:
    root = build_app()
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
