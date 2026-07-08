# AGENTS.md

## Cursor Cloud specific instructions

### What this repo is
This repository contains **MetaTrader 5 (MT5) Expert Advisors written in MQL5** — automated
trading robots. There is **no conventional build system** (no npm/pip/cargo/make/docker). The
only "build" is compiling `.mq5` source into `.ex5` binaries with **MetaEditor**, and the only
way to "run" an EA is inside the **MetaTrader 5 terminal** (Strategy Tester or on a chart).
See `README.md` for the trading strategies, symbols (XAUUSDm / BTCUSDm on Exness) and presets.

Products:
- `AdaptiveGoldEngine.mq5` — gold (XAUUSDm) regime-adaptive EA. Presets: `AdaptiveGoldEngine.set`, `QuantumOmniGold_best.set`.
- `SpartanFade_v1.0.mq5` — BTC (BTCUSDm) US-open fade EA. Presets: `SpartanFade_Exness_*.set`.

### Toolchain layout (installed via Wine)
- Wine prefix: `WINEPREFIX=$HOME/.mt5` (64-bit). MT5 install dir:
  `$HOME/.mt5/drive_c/Program Files/MetaTrader 5/` containing `terminal64.exe`,
  `MetaEditor64.exe`, `metatester64.exe`.
- MQL5 tree (Experts, Include standard library, etc.):
  `$HOME/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/` (present only after the terminal has
  been launched once with `/portable`).
- Always export before any wine command:
  `export WINEPREFIX=$HOME/.mt5 WINEARCH=win64 WINEDLLOVERRIDES="mscoree=d;mshtml=d" WINEDEBUG=-all`

### Display / GUI
- No physical display. Two X displays exist: `:1` is the **computer-use / screen-recording**
  display (launch MT5 here for GUI/manual testing and demos), and `:99` is a private headless
  `Xvfb` for background/CLI work.
- `:99` must be started manually and kept alive (it does NOT persist across processes). Start it
  in a tmux session, e.g.:
  `tmux -f /exec-daemon/tmux.portal.conf new-session -d -s xvfb -- bash -lc "Xvfb :99 -screen 0 1440x900x24 -ac"`
- Set `export XDG_RUNTIME_DIR=/tmp/xdg-$UID` (create it `mkdir -p`) to silence noise.

### Compiling an EA (the "build")
Copy sources into the Experts folder first, then compile from the MT5 dir:
```
MT5="$HOME/.mt5/drive_c/Program Files/MetaTrader 5"
cp /workspace/*.mq5 "$MT5/MQL5/Experts/"
cd "$MT5"
wine MetaEditor64.exe /compile:"MQL5\\Experts\\AdaptiveGoldEngine.mq5" /log:"Z:\\tmp\\c.log"
iconv -f UTF-16LE -t UTF-8 /tmp/c.log | tr -d '\r'   # log is UTF-16; look for "0 errors"
```
Gotchas:
- `MetaEditor64.exe` returns a **non-zero exit code even on success** — judge success by the
  compile log line `Result: 0 errors, 0 warnings ...` and by the produced `.ex5` file, not `$?`.
- The compile `/log` file is UTF-16LE; decode with `iconv` before reading.

### Running an EA (Strategy Tester)
- The Strategy Tester **requires a logged-in trading account** — it aborts with
  `tester not started because the account is not specified` otherwise. A free
  **MetaQuotes-Demo** account is already configured in this environment (login `5052770341`).
  If it is missing, open a new demo via the terminal's account wizard; the wizard's phone field
  rejects input until a **country code is selected** from the dropdown (e.g. US +1, then a
  10-digit number).
- The intended symbols (`XAUUSDm`, `BTCUSDm`) are Exness-specific; the MetaQuotes-Demo server has
  `XAUUSD` / `BTCUSD` (no `m` suffix). For a smoke test any liquid symbol works (e.g. EURUSD H1).
  Full validation on the real `*m` symbols needs an **Exness account** (not available by default).
- Headless backtest via a config .ini + `terminal64.exe /portable /config:tester.ini`. In the
  `[Tester]` section the `Expert=` path is **relative to `MQL5\Experts`** (use
  `Expert=AdaptiveGoldEngine.ex5`, NOT `Experts\AdaptiveGoldEngine.ex5`).

### Critical gotchas discovered during setup
- Use **`winehq-staging`**, not `winehq-stable`. The MT5 installer/terminal has anti-debug
  protection that throws a false **"A debugger has been found running in your system"** dialog
  under wine-stable; staging avoids it.
- Create the wine prefix / run the installer with `WINEDLLOVERRIDES="mscoree=d;mshtml=d"`,
  otherwise `wineboot` hangs on the wine-mono install dialog. MT5 does not need .NET.
- Install MT5 non-interactively with `wine mt5setup.exe /auto`.
- **Never** use `pkill -f terminal64` / `pkill -f wine` — the pattern matches the killing shell's
  own command line and kills your session. Stop wine cleanly with `wineserver -k`, or kill by
  explicit PID.
- After reinstalling/updating, MetaEditor and the tester cache compiled `.ex5`; recompile after
  editing `.mq5`.
