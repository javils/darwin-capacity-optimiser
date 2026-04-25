# SQXSplitInstaller

A Windows tool that lets non-technical StrategyQuant X (SQX) users adopt the
[SplitOrder library](../Include/SplitOrder/) without ever opening a code
editor. It installs the library into a MetaTrader 5 terminal and rewrites
SQX-generated `.mq5` Expert Advisors so they execute their entries as a
sequence of split orders instead of a single large market fill.

It ships as both a graphical app (double-click to use) and a command-line
tool (for power users and scripting). Both share the same engine.

---

## Why this tool exists

Most SQX users are not developers. They design strategies visually in
AlgoWizard and rarely — if ever — touch the generated `.mq5` code. The
SplitOrder library's manual integration procedure is technically simple
(copy a folder, add three lines to `OnInit`, one line to `OnTimer`, run a
find-and-replace on `openPosition(`), but for the typical SQX user it is
intimidating, easy to get wrong, and one wrong step produces a strategy
that fails to compile.

This tool automates the whole flow. It distinguishes call sites from the
definition, injects everything in the right places, and exposes the split
configuration as runtime inputs the user can adjust from the standard MT5
inputs dialog without recompiling.

---

## Installation

Two options, depending on how you prefer to use the tool.

### Windows users — download the executable

Grab the latest `SQXSplitInstaller.exe` (graphical app) and/or
`SQXSplitInstaller-cli.exe` (command line) from the
[Releases page](../../releases). They are single-file portable
executables — no Python install required, no admin rights needed.

### Developers — install from source

```bash
git clone https://github.com/marticastany/darwin-capacity-optimiser.git
cd darwin-capacity-optimiser/SQXSplitInstaller
python -m venv .venv
.venv\Scripts\pip install -e ".[dev]"
```

Two CLI entry points become available inside the venv:

- `sqx-split-installer` — the CLI
- `sqx-split-installer-gui` — the graphical app

---

## Usage — Graphical app

Launch `SQXSplitInstaller.exe` (or `sqx-split-installer-gui` from a venv).
A window opens with two tabs.

### "Install Library" tab

Installs the three SplitOrder `.mqh` files into a MetaTrader 5 terminal so
your patched strategies can `#include` them.

1. Click **Browse…** and select your MT5 terminal folder. This is the
   directory that contains a `MQL5/` subfolder. On Windows it usually
   lives under
   `%APPDATA%\MetaQuotes\Terminal\<some-hash>\`.
   If you have several terminals (different brokers, demo vs live), pick
   the one you want to install into; you can run the installer once per
   terminal.
2. Click **Install**. The tool copies the library files into
   `<terminal>/MQL5/Include/SplitOrder/`, creating the subfolder if
   needed and overwriting any existing copy.
3. The log box reports the destination and the files installed.

### "Patch Strategies" tab

Rewrites SQX-generated `.mq5` files so they use the SplitOrder library.

1. **Inputs**: click **Add files…** to pick one or more `.mq5` strategies,
   or **Add folder…** to point at a directory (its `.mq5` files are
   processed; subfolders are not). You can mix files and folders. The
   list shows everything queued up; **Remove** drops the selection,
   **Clear** empties the list.
2. **Output directory**: optional. Leave empty and each patched file is
   written next to its source. Pick one to collect them all in one place.
3. **Suffix**: appended to each patched file name. Default is `_split`,
   so `MyStrategy.mq5` becomes `MyStrategy_split.mq5`. You can change it
   to anything (or leave the field empty to use the default).
4. **Split count**: how many positions the original entry is split into,
   including the first one. Range 2–10. Default 3.
5. **Split delay seconds**: pause between each child order in seconds.
   Range 1–300. Default 10.
6. Click **Patch**. The log box reports each file as it succeeds or fails.

The split count and delay are **also** exposed inside the patched EA as
MT5 input parameters. The values you choose here become the defaults; the
end user can still tweak them in the strategy's inputs dialog without
recompiling.

---

## Usage — Command line

The CLI exposes the same two operations as subcommands.

### `install`

```
SQXSplitInstaller-cli.exe install <terminal-folder>
```

Copies the SplitOrder library into `<terminal-folder>/MQL5/Include/SplitOrder/`.

| Argument | Required | Description |
|---|---|---|
| `terminal-folder` | yes | Path to the MT5 terminal root (the directory that contains `MQL5/`). |

Example:

```bash
SQXSplitInstaller-cli.exe install "C:\Users\me\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
```

The destination subfolder is created if missing. Existing files are
overwritten. The command refuses to run if the path does not exist or
does not contain a `MQL5/` subfolder.

### `patch`

```
SQXSplitInstaller-cli.exe patch [options] <input>...
```

Rewrites one or more SQX-generated `.mq5` files. `<input>` accepts both
files and directories — directories are expanded to their `*.mq5` files
non-recursively. Mixing both is fine; duplicates are deduped.

| Option | Default | Description |
|---|---|---|
| `--split-count N` | `3` | Total positions including the first one. Range 2–10. |
| `--delay-seconds N` | `10` | Seconds between each child order. Range 1–300. |
| `--output-dir DIR` | alongside each input | Destination folder for patched files. |
| `--suffix S` | `_split` | Suffix appended to the stem of the patched file. |

Examples:

```bash
# Single file, output written next to the input as MyStrategy_split.mq5
SQXSplitInstaller-cli.exe patch MyStrategy.mq5

# Multiple files, custom split parameters, output collected in one folder
SQXSplitInstaller-cli.exe patch ^
    --split-count 5 ^
    --delay-seconds 15 ^
    --output-dir patched\ ^
    Strategy1.mq5 Strategy2.mq5 Strategy3.mq5

# Patch every .mq5 in a folder
SQXSplitInstaller-cli.exe patch --output-dir patched\ strategies\
```

If a file is rejected (already patched, or it does not look like an
SQX-generated EA), the tool reports the reason and continues with the
remaining files. The exit code is `0` on full success, `1` if any file
failed, `2` on unexpected errors.

### `--version` and `--help`

```bash
SQXSplitInstaller-cli.exe --version
SQXSplitInstaller-cli.exe --help
SQXSplitInstaller-cli.exe install --help
SQXSplitInstaller-cli.exe patch --help
```

---

## What the patcher does to your strategy

For full transparency, here is everything the `patch` command writes into
the output `.mq5`:

1. A header comment block at the top of the file marking the file as
   patched (also acts as the idempotency guard so the tool refuses to
   patch the same file twice).
2. A `#include <SplitOrder/SplitOrderSQX.mqh>` directive after the last
   existing include.
3. Three runtime inputs the user can adjust from the inputs dialog:
   ```mql5
   input string sSplitOrder = "----------- SplitOrder -----------";
   input int splitOrderCount = 3;            // SplitOrder: positions including pos0 (2-10)
   input int splitOrderDelaySeconds = 10;    // SplitOrder: seconds between child orders (1-300)
   ```
4. Inside `OnInit()`, just before the final `return`:
   ```mql5
   SQXSplitInit(splitOrderCount, splitOrderDelaySeconds);
   EventSetTimer(1);
   ```
5. Inside `OnTimer()`, at the very top of the body, plus a 24-hour
   throttle that protects SQX's own cleanup body from running 86,400
   times more often than its original design:
   ```mql5
   SQXSplitOnTimer();
   static datetime _sqxLastCleanup = 0;
   datetime _sqxNow = TimeCurrent();
   if(_sqxNow - _sqxLastCleanup < 24 * 3600) return;
   _sqxLastCleanup = _sqxNow;
   ```
6. Every `openPosition(` call site rewritten to `openPositionSplit(`.
   The `openPosition()` function definition itself is left untouched.

Nothing else is modified. The strategy logic, indicators, money
management, exits, and timing rules all remain exactly as SQX generated
them.

---

## Limitations

- Only SQX-generated `.mq5` files are supported. Hand-written EAs do not
  match the structural signatures the patcher expects.
- The patcher is not recursive. Pointing it at a directory processes the
  `.mq5` files directly inside it, but not those in subfolders.
- A patched file cannot be re-patched. To change the parameters or
  re-apply the patch, regenerate the original from SQX and run the
  patcher again.
- The output is not compiled or validated. You still need to compile
  the patched file in MetaEditor (or let MetaTrader compile it on
  startup) to confirm it builds cleanly for your symbol/broker.

---

## Development

Standard Python project. Tests are in `tests/` and use `pytest`.

```bash
# Set up
python -m venv .venv
.venv\Scripts\pip install -e ".[dev]"

# Run the unit suite
.venv\Scripts\pytest

# Build the executables locally (needs the build extra)
.venv\Scripts\pip install -e ".[build]"
.venv\Scripts\pyinstaller --onefile --windowed --name SQXSplitInstaller ^
    --paths src --add-data "../Include/SplitOrder;SplitOrder" ^
    src/sqx_split_installer/gui.py
.venv\Scripts\pyinstaller --onefile --console --name SQXSplitInstaller-cli ^
    --paths src --add-data "../Include/SplitOrder;SplitOrder" ^
    src/sqx_split_installer/cli.py
```

---

## License

Apache-2.0, inherited from the parent repository.
