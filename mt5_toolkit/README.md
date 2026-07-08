# MT5 Toolkit — Live Monitor + Optional Python Executor

Run these on **your Windows machine** (the `MetaTrader5` Python library is
Windows-only) while your MT5 terminal is open and logged in to Exness.

Two tools:

| Script | What it does | Risk |
|---|---|---|
| `monitor.py` | **Read-only** live dashboard of both EAs: equity, per-EA P&L, open positions, daily realised, drawdown vs peak. Optional Telegram alerts on open/close and guardrail breaches. | **None** — places no orders |
| `executor.py` | **Optional** second execution path that runs the Adaptive Gold Engine rules from Python (regime + session + ATR, partial TP, uncapped trail) with hard portfolio guardrails. | **DRY-RUN by default.** Only trades when you set `LIVE_EXECUTE = True` |

---

## 1. Install (once)

```bat
pip install -r requirements.txt
```

Requires Python 3.9–3.12 on Windows, and MetaTrader 5 installed & logged in.

## 2. Configure

Open `config.py` and set:

- `GOLD_MAGIC` / `SPARTAN_MAGIC` — must match the `InpMagicNumber` in your EAs.
  (Set `AdaptiveGoldEngine`'s magic to `990045`, or change the value here to match.)
- `GOLD_SYMBOL` / `BTC_SYMBOL` — confirm the exact Exness names (e.g. `XAUUSDm`, `BTCUSDm`).
- Guardrails: `MAX_ACCOUNT_DRAWDOWN_PCT`, `DAILY_LOSS_LIMIT_USD`, `MAX_OPEN_POSITIONS`.
- (Optional) `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` for phone alerts.

Leave `MT5_LOGIN/PASSWORD/SERVER = None` to just attach to the terminal you
already have open (recommended — no credentials stored in the file).

## 3. Run the monitor (safe, start here)

```bat
python monitor.py
```

You'll see a live dashboard refresh every 30s and a CSV log written to `logs/equity_log.csv`.

## 4. (Optional) Run the executor

**Read this first:**

- The executor is a **second** way to trade the gold strategy from Python. Do **NOT**
  run it on the same symbol/magic while the MQL5 `AdaptiveGoldEngine` EA is also
  attached — pick **one** execution path or they will double-trade.
- It defaults to **DRY-RUN**: it prints/《alerts》 the exact trade it *would* place but
  sends no orders. Watch it for a few days first.
- When you're satisfied, set `LIVE_EXECUTE = True` in `config.py` to go live.

```bat
python executor.py
```

### Hard guardrails the executor enforces
- **Drawdown kill-switch** — stops opening trades if equity falls `MAX_ACCOUNT_DRAWDOWN_PCT`
  below its peak.
- **Daily loss limit** — no new trades once today's realised loss hits `DAILY_LOSS_LIMIT_USD`.
- **Max open positions** — never exceeds `MAX_OPEN_POSITIONS`.
- Fixed **% risk sizing** per trade (`GOLD_RISK_PCT`).

---

## Which execution path should I use?

- **Simplest / most robust:** run the **MQL5 EAs** on charts (they don't need Python
  or your PC's Python env) and use `monitor.py` only, for visibility + alerts.
- **Most transparent / scriptable:** run `executor.py` for gold (so every decision is
  logged in plain Python) and keep SpartanFade as the MQL5 EA on BTC.

Recommended to start: **MQL5 EAs + monitor.py**. Graduate to the executor once you
trust the monitor and have watched the executor in DRY-RUN.

---

## Honest note on "auto-profit"

These tools execute **validated, rule-based** strategies with disciplined risk — that
is the realistic version of "a professional trading for you". They do **not** guarantee
profit, and the gold strategy's backtest showed real drawdowns (~34% at 1% risk). The
guardrails limit damage; they don't remove risk. Always demo first.
