"""
executor.py — OPTIONAL Python execution of the Adaptive Gold Engine rules.

This is a transparent, second execution path that mirrors the MQL5 EA logic:
  * regime (ADX) + session filter
  * ATR stop, partial TP at 1.5xATR (close 50%, SL->breakeven)
  * uncapped trailing runner
  * fixed % risk sizing
Plus HARD portfolio guardrails from config (drawdown kill-switch, daily loss,
max open positions).

SAFETY:
  * Runs on H1 gold bars, one decision per closed bar (no tick spam).
  * DRY-RUN by default. Set config.LIVE_EXECUTE = True to place real orders.
  * Do NOT run this at the same time as the MQL5 AdaptiveGoldEngine on the
    same symbol/magic — pick ONE execution path.

Run:  python executor.py
"""
import time
from datetime import datetime, timezone

import numpy as np

import config
import mt5_client as mt5c
import alerts
from indicators import ema, atr, adx

try:
    import MetaTrader5 as mt5
except ImportError:
    mt5 = None

# --- strategy params (match AdaptiveGoldEngine.set) -------------------
P = dict(atr_n=14, adx_n=14, ema_fast=15, ema_slow=100,
         adx_trend=25, adx_range=20, sl_atr=2.0, tp1_atr=1.5,
         tp1_pct=50.0, trail_atr=2.0)

BARS = 400            # history bars to pull for indicators
_last_bar_time = None
_peak_equity = config.ACCOUNT_START_BALANCE
# runner state per ticket: {ticket: {"tp1_done": bool, "dir": 1/-1, "tp1lvl": float}}
_state = {}


def _session(hr):
    london = 7 <= hr < 11
    ny = 13 <= hr < 16
    asian = hr >= 22 or hr < 7
    return london, ny, asian


def _overnight_range(times, highs, lows):
    """High/low of the most recent completed Asian window (22:00-07:00 UTC)."""
    hi, lo = None, None
    chi, clo = -1e18, 1e18
    in_prev = False
    for t, h, l in zip(times, highs, lows):
        hr = t.hour
        ina = hr >= 22 or hr < 7
        if ina:
            chi = max(chi, h); clo = min(clo, l)
        if in_prev and not ina:
            if chi > -1e17:
                hi, lo = chi, clo
            chi, clo = -1e18, 1e18
        in_prev = ina
    return hi, lo


def get_signal(symbol):
    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_H1, 0, BARS)
    if rates is None or len(rates) < 200:
        return None
    times = [datetime.fromtimestamp(r["time"], tz=timezone.utc) for r in rates]
    h = np.array([r["high"] for r in rates])
    l = np.array([r["low"] for r in rates])
    c = np.array([r["close"] for r in rates])

    _atr = atr(h, l, c, P["atr_n"])
    _adx, _pdi, _mdi = adx(h, l, c, P["adx_n"])
    emaF = ema(c, P["ema_fast"]); emaS = ema(c, P["ema_slow"])

    i = len(c) - 2  # last CLOSED bar
    a = _atr[i]
    if np.isnan(a) or np.isnan(_adx[i]):
        return None

    hr = times[i].hour
    london, ny, asian = _session(hr)
    adxv = _adx[i]
    trend = adxv >= P["adx_trend"]
    rng = adxv < P["adx_range"]
    sig = 0
    if trend and (london or ny):
        if _pdi[i] > _mdi[i] and c[i] > emaF[i] > emaS[i]:
            sig = 1
        elif _mdi[i] > _pdi[i] and c[i] < emaF[i] < emaS[i]:
            sig = -1
    elif rng and asian:
        ahi, alo = _overnight_range(times[:i + 1], h[:i + 1], l[:i + 1])
        if ahi is not None:
            if l[i] <= alo and c[i] > l[i]:
                sig = 1
            elif h[i] >= ahi and c[i] < h[i]:
                sig = -1

    return {"sig": sig, "atr": a, "close": c[i], "bar_time": times[i],
            "regime": "TREND" if trend else ("RANGE" if rng else "STANDBY")}


def calc_lot(symbol, sl_dist, risk_pct):
    acc = mt5c.account()
    meta = mt5c.symbol_meta(symbol)
    if acc is None or meta is None:
        return 0.0
    risk_cash = acc["balance"] * risk_pct / 100.0
    # $ loss per 1.0 lot over sl_dist price move
    loss_per_lot = sl_dist / meta["tick_size"] * meta["tick_value"]
    if loss_per_lot <= 0:
        return 0.0
    return risk_cash / loss_per_lot


def guardrails_ok():
    global _peak_equity
    acc = mt5c.account()
    if acc is None:
        return False, "no account"
    _peak_equity = max(_peak_equity, acc["equity"])
    dd = (_peak_equity - acc["equity"]) / _peak_equity * 100 if _peak_equity > 0 else 0
    if dd >= config.MAX_ACCOUNT_DRAWDOWN_PCT:
        return False, f"drawdown {dd:.1f}% >= {config.MAX_ACCOUNT_DRAWDOWN_PCT}%"
    realised, _ = mt5c.closed_deals_today(config.GOLD_MAGIC)
    if realised <= -config.DAILY_LOSS_LIMIT_USD:
        return False, f"daily loss {realised:+.2f}"
    if len(mt5c.positions()) >= config.MAX_OPEN_POSITIONS:
        return False, "max open positions"
    return True, "ok"


def manage_runners(symbol):
    """Partial TP + breakeven + uncapped trail on our gold positions."""
    for p in mt5c.positions(magic=config.GOLD_MAGIC, symbol=symbol):
        tk = p["ticket"]
        st = _state.get(tk)
        rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_H1, 0, P["atr_n"] + 5)
        if rates is None:
            continue
        h = np.array([r["high"] for r in rates]); l = np.array([r["low"] for r in rates])
        c = np.array([r["close"] for r in rates])
        a = atr(h, l, c, P["atr_n"])[-2]
        if np.isnan(a):
            continue
        q = mt5c.quote(symbol)
        if not q:
            continue
        is_long = p["type"] == "BUY"
        entry = p["price_open"]
        if st is None:
            # reconstruct state if executor restarted
            st = {"tp1_done": abs(p["sl"] - entry) < a * 0.2, "dir": 1 if is_long else -1,
                  "tp1lvl": entry + (P["tp1_atr"] * a if is_long else -P["tp1_atr"] * a)}
            _state[tk] = st
        px = q["bid"] if is_long else q["ask"]

        if not st["tp1_done"]:
            hit = (px >= st["tp1lvl"]) if is_long else (px <= st["tp1lvl"])
            if hit:
                close_vol = p["volume"] * P["tp1_pct"] / 100.0
                if config.LIVE_EXECUTE:
                    # partial close via opposite deal
                    ok, _ = _partial_close(symbol, tk, close_vol, is_long)
                    mt5c.modify_sl_tp(tk, sl=entry)  # SL -> breakeven
                st["tp1_done"] = True
                alerts.send(f"GOLD TP1 hit: banked {P['tp1_pct']:.0f}% ticket {tk}, SL->BE")
        else:
            # trail runner (uncapped)
            if is_long:
                new_sl = px - P["trail_atr"] * a
                if new_sl > p["sl"]:
                    if config.LIVE_EXECUTE:
                        mt5c.modify_sl_tp(tk, sl=new_sl)
            else:
                new_sl = px + P["trail_atr"] * a
                if p["sl"] == 0 or new_sl < p["sl"]:
                    if config.LIVE_EXECUTE:
                        mt5c.modify_sl_tp(tk, sl=new_sl)

    # clean state for closed tickets
    live = {p["ticket"] for p in mt5c.positions(magic=config.GOLD_MAGIC, symbol=symbol)}
    for tk in list(_state.keys()):
        if tk not in live:
            _state.pop(tk, None)


def _partial_close(symbol, ticket, volume, is_long):
    volume = mt5c._round_lot(symbol, volume)
    tick = mt5.symbol_info_tick(symbol)
    price = tick.bid if is_long else tick.ask
    otype = mt5.ORDER_TYPE_SELL if is_long else mt5.ORDER_TYPE_BUY
    req = {"action": mt5.TRADE_ACTION_DEAL, "symbol": symbol, "volume": volume,
           "type": otype, "position": ticket, "price": price, "deviation": 30,
           "magic": config.GOLD_MAGIC, "comment": "TP1 partial",
           "type_time": mt5.ORDER_TIME_GTC, "type_filling": mt5.ORDER_FILLING_IOC}
    r = mt5.order_send(req)
    return (r is not None and r.retcode == mt5.TRADE_RETCODE_DONE), r


def main():
    global _last_bar_time
    mode = "LIVE" if config.LIVE_EXECUTE else "DRY-RUN"
    print(f"Adaptive Gold executor starting in {mode} mode.")
    if not config.LIVE_EXECUTE:
        print(">>> DRY-RUN: signals printed, NO orders sent. Set LIVE_EXECUTE=True to trade.")
    if not mt5c.connect():
        return
    sym = config.GOLD_SYMBOL
    mt5.symbol_select(sym, True)
    alerts.send(f"Gold executor online ({mode})")
    try:
        while True:
            manage_runners(sym)
            info = get_signal(sym)
            if info and info["bar_time"] != _last_bar_time:
                _last_bar_time = info["bar_time"]
                print(f"{datetime.now():%H:%M:%S}  bar {info['bar_time']:%m-%d %H:%M}  "
                      f"regime={info['regime']}  signal={info['sig']}  ATR={info['atr']:.2f}")
                if info["sig"] != 0:
                    ok, why = guardrails_ok()
                    if not ok:
                        print("  blocked by guardrail:", why)
                        alerts.send(f"Signal blocked: {why}")
                    else:
                        a = info["atr"]; sl_dist = P["sl_atr"] * a
                        lot = calc_lot(sym, sl_dist, config.GOLD_RISK_PCT)
                        direction = "BUY" if info["sig"] == 1 else "SELL"
                        q = mt5c.quote(sym)
                        entry = q["ask"] if direction == "BUY" else q["bid"]
                        sl = entry - sl_dist if direction == "BUY" else entry + sl_dist
                        msg = (f"GOLD {direction} lot~{lot:.2f} entry~{entry:.2f} "
                               f"SL~{sl:.2f} (risk {config.GOLD_RISK_PCT}%)")
                        if config.LIVE_EXECUTE:
                            ok2, r = mt5c.market_order(sym, direction, lot, sl, 0.0,
                                                       config.GOLD_MAGIC, "AdaptiveGold-py")
                            print("  ORDER", "OK" if ok2 else "FAIL", getattr(r, "retcode", r))
                            alerts.send(("✅ " if ok2 else "❌ ") + msg)
                        else:
                            print("  [DRY-RUN]", msg)
                            alerts.send("[DRY-RUN] " + msg)
            time.sleep(15)
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        mt5c.shutdown()


if __name__ == "__main__":
    main()
