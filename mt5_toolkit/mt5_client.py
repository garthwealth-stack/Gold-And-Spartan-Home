"""
mt5_client.py — thin wrapper around the MetaTrader5 Python API.
Handles connect, account snapshot, positions, quotes, and safe order helpers.
All functions fail safe (return None / False) instead of raising, so the
monitor never crashes on a transient error.
"""
import time
from datetime import datetime, timezone

try:
    import MetaTrader5 as mt5
except ImportError:
    mt5 = None

import config


def connect():
    """Attach to a running terminal (or log in if credentials given)."""
    if mt5 is None:
        raise RuntimeError(
            "MetaTrader5 package not installed. Run:  pip install MetaTrader5\n"
            "(Windows only — the library does not exist for Linux/Mac.)"
        )
    kwargs = {}
    if config.MT5_PATH:
        kwargs["path"] = config.MT5_PATH
    if config.MT5_LOGIN and config.MT5_PASSWORD and config.MT5_SERVER:
        kwargs.update(login=int(config.MT5_LOGIN),
                      password=config.MT5_PASSWORD,
                      server=config.MT5_SERVER)
    ok = mt5.initialize(**kwargs)
    if not ok:
        print("initialize() failed:", mt5.last_error())
        return False
    ai = mt5.account_info()
    if ai is None:
        print("account_info() failed:", mt5.last_error())
        return False
    print(f"Connected: #{ai.login}  {ai.server}  balance={ai.balance:.2f} {ai.currency}")
    return True


def shutdown():
    if mt5:
        mt5.shutdown()


def account():
    ai = mt5.account_info()
    if ai is None:
        return None
    return {
        "login": ai.login, "server": ai.server, "currency": ai.currency,
        "balance": ai.balance, "equity": ai.equity, "margin": ai.margin,
        "free_margin": ai.margin_free, "profit": ai.profit,
    }


def positions(magic=None, symbol=None):
    ps = mt5.positions_get()
    if ps is None:
        return []
    out = []
    for p in ps:
        if magic is not None and p.magic != magic:
            continue
        if symbol is not None and p.symbol != symbol:
            continue
        out.append({
            "ticket": p.ticket, "symbol": p.symbol, "magic": p.magic,
            "type": "BUY" if p.type == mt5.POSITION_TYPE_BUY else "SELL",
            "volume": p.volume, "price_open": p.price_open,
            "sl": p.sl, "tp": p.tp, "price_current": p.price_current,
            "profit": p.profit, "swap": p.swap,
            "time": datetime.fromtimestamp(p.time, tz=timezone.utc),
        })
    return out


def quote(symbol):
    t = mt5.symbol_info_tick(symbol)
    if t is None:
        # make sure the symbol is selected in Market Watch
        mt5.symbol_select(symbol, True)
        t = mt5.symbol_info_tick(symbol)
    if t is None:
        return None
    return {"bid": t.bid, "ask": t.ask, "time": datetime.fromtimestamp(t.time, tz=timezone.utc)}


def symbol_meta(symbol):
    s = mt5.symbol_info(symbol)
    if s is None:
        mt5.symbol_select(symbol, True)
        s = mt5.symbol_info(symbol)
    if s is None:
        return None
    return {
        "point": s.point, "digits": s.digits,
        "volume_min": s.volume_min, "volume_max": s.volume_max,
        "volume_step": s.volume_step,
        "tick_value": s.trade_tick_value, "tick_size": s.trade_tick_size,
        "spread": s.spread,
    }


def closed_deals_today(magic=None):
    """Realised P&L from closed deals since midnight server time."""
    now = datetime.now()
    start = datetime(now.year, now.month, now.day)
    deals = mt5.history_deals_get(start, datetime.now())
    if deals is None:
        return 0.0, 0
    total, n = 0.0, 0
    for d in deals:
        if magic is not None and d.magic != magic:
            continue
        if d.entry == mt5.DEAL_ENTRY_OUT:
            total += d.profit + d.swap + d.commission
            n += 1
    return total, n


# ---- order helpers (used by executor) --------------------------------
def _round_lot(symbol, lot):
    m = symbol_meta(symbol)
    step = m["volume_step"] or 0.01
    lot = (int(lot / step)) * step
    lot = max(m["volume_min"], min(m["volume_max"], lot))
    return round(lot, 2)


def market_order(symbol, direction, lot, sl_price, tp_price, magic, comment):
    """direction: 'BUY' or 'SELL'. Returns (ok, result)."""
    lot = _round_lot(symbol, lot)
    tick = mt5.symbol_info_tick(symbol)
    if tick is None:
        return False, "no tick"
    price = tick.ask if direction == "BUY" else tick.bid
    otype = mt5.ORDER_TYPE_BUY if direction == "BUY" else mt5.ORDER_TYPE_SELL
    req = {
        "action": mt5.TRADE_ACTION_DEAL, "symbol": symbol, "volume": lot,
        "type": otype, "price": price,
        "sl": round(sl_price, symbol_meta(symbol)["digits"]),
        "tp": round(tp_price, symbol_meta(symbol)["digits"]) if tp_price else 0.0,
        "deviation": 30, "magic": magic, "comment": comment,
        "type_time": mt5.ORDER_TIME_GTC, "type_filling": mt5.ORDER_FILLING_IOC,
    }
    r = mt5.order_send(req)
    ok = r is not None and r.retcode == mt5.TRADE_RETCODE_DONE
    return ok, r


def close_position(ticket):
    ps = mt5.positions_get(ticket=ticket)
    if not ps:
        return False, "not found"
    p = ps[0]
    tick = mt5.symbol_info_tick(p.symbol)
    price = tick.bid if p.type == mt5.POSITION_TYPE_BUY else tick.ask
    otype = mt5.ORDER_TYPE_SELL if p.type == mt5.POSITION_TYPE_BUY else mt5.ORDER_TYPE_BUY
    req = {
        "action": mt5.TRADE_ACTION_DEAL, "symbol": p.symbol, "volume": p.volume,
        "type": otype, "position": ticket, "price": price,
        "deviation": 30, "magic": p.magic, "comment": "toolkit close",
        "type_time": mt5.ORDER_TIME_GTC, "type_filling": mt5.ORDER_FILLING_IOC,
    }
    r = mt5.order_send(req)
    ok = r is not None and r.retcode == mt5.TRADE_RETCODE_DONE
    return ok, r


def modify_sl_tp(ticket, sl=None, tp=None):
    ps = mt5.positions_get(ticket=ticket)
    if not ps:
        return False, "not found"
    p = ps[0]
    req = {
        "action": mt5.TRADE_ACTION_SLTP, "symbol": p.symbol, "position": ticket,
        "sl": sl if sl is not None else p.sl,
        "tp": tp if tp is not None else p.tp,
    }
    r = mt5.order_send(req)
    ok = r is not None and r.retcode == mt5.TRADE_RETCODE_DONE
    return ok, r
