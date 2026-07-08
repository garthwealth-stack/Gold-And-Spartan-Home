"""
monitor.py — READ-ONLY live dashboard for both EAs.
Run on your Windows machine while MT5 is open:

    python monitor.py

Shows account equity, per-EA open positions & P&L, daily realised P&L,
and drawdown vs peak. Sends a Telegram alert when a position opens/closes
or when a guardrail (drawdown / daily loss) is breached. Places NO orders.
"""
import os
import time
import csv
from datetime import datetime

import config
import mt5_client as mt5c
import alerts


def _fmt_positions(ps):
    if not ps:
        return "   (none)"
    lines = []
    for p in ps:
        lines.append(f"   #{p['ticket']} {p['type']} {p['volume']:.2f} "
                     f"@ {p['price_open']:.2f}  P/L {p['profit']:+.2f}")
    return "\n".join(lines)


def main():
    os.makedirs(config.LOG_DIR, exist_ok=True)
    csv_path = os.path.join(config.LOG_DIR, "equity_log.csv")
    new_file = not os.path.exists(csv_path)
    csvf = open(csv_path, "a", newline="")
    writer = csv.writer(csvf)
    if new_file:
        writer.writerow(["timestamp", "balance", "equity", "gold_pl",
                         "spartan_pl", "gold_open", "spartan_open",
                         "daily_realised", "drawdown_pct"])

    if not mt5c.connect():
        return

    peak_equity = config.ACCOUNT_START_BALANCE
    known_tickets = set()
    halted = False

    try:
        while True:
            acc = mt5c.account()
            if acc is None:
                time.sleep(config.POLL_SECONDS)
                continue

            peak_equity = max(peak_equity, acc["equity"])
            dd_pct = (peak_equity - acc["equity"]) / peak_equity * 100 if peak_equity > 0 else 0

            gold = mt5c.positions(magic=config.GOLD_MAGIC)
            spartan_a = mt5c.positions(magic=config.SPARTAN_MAGIC)
            spartan_b = mt5c.positions(magic=config.SPARTAN_MAGIC + 1)  # aggressive magic
            spartan = spartan_a + spartan_b

            gold_pl = sum(p["profit"] for p in gold)
            spartan_pl = sum(p["profit"] for p in spartan)

            gold_realised, gold_n = mt5c.closed_deals_today(config.GOLD_MAGIC)
            sp_realised_a, _ = mt5c.closed_deals_today(config.SPARTAN_MAGIC)
            sp_realised_b, _ = mt5c.closed_deals_today(config.SPARTAN_MAGIC + 1)
            daily_realised = gold_realised + sp_realised_a + sp_realised_b

            # detect open/close events for alerts
            current = {p["ticket"]: p for p in (gold + spartan)}
            for tk, p in current.items():
                if tk not in known_tickets:
                    alerts.send(f"OPENED {p['symbol']} {p['type']} {p['volume']:.2f} @ {p['price_open']:.2f}")
            for tk in list(known_tickets):
                if tk not in current:
                    alerts.send(f"CLOSED ticket {tk}")
            known_tickets = set(current.keys())

            # guardrail alerts
            if dd_pct >= config.MAX_ACCOUNT_DRAWDOWN_PCT and not halted:
                halted = True
                alerts.send(f"⚠️ DRAWDOWN {dd_pct:.1f}% >= limit {config.MAX_ACCOUNT_DRAWDOWN_PCT}%. "
                            f"Consider pausing EAs.")
            if daily_realised <= -config.DAILY_LOSS_LIMIT_USD:
                alerts.send(f"⚠️ Daily loss {daily_realised:+.2f} hit limit -{config.DAILY_LOSS_LIMIT_USD}.")

            os.system("cls" if os.name == "nt" else "clear")
            print("=" * 58)
            print(f"  MT5 MONITOR   {datetime.now():%Y-%m-%d %H:%M:%S}")
            print("=" * 58)
            print(f"  Balance {acc['balance']:.2f}   Equity {acc['equity']:.2f}   "
                  f"Free {acc['free_margin']:.2f} {acc['currency']}")
            print(f"  Peak {peak_equity:.2f}   Drawdown {dd_pct:.1f}%   "
                  f"Daily realised {daily_realised:+.2f}")
            print("-" * 58)
            print(f"  GOLD (XAU)  open P/L {gold_pl:+.2f}   positions {len(gold)}")
            print(_fmt_positions(gold))
            print(f"  SPARTAN(BTC) open P/L {spartan_pl:+.2f}   positions {len(spartan)}")
            print(_fmt_positions(spartan))
            print("=" * 58)
            if halted:
                print("  >>> DRAWDOWN LIMIT BREACHED — review manually <<<")
            print("  (read-only monitor — Ctrl+C to stop)")

            writer.writerow([datetime.now().isoformat(), acc["balance"], acc["equity"],
                             round(gold_pl, 2), round(spartan_pl, 2), len(gold), len(spartan),
                             round(daily_realised, 2), round(dd_pct, 2)])
            csvf.flush()
            time.sleep(config.POLL_SECONDS)
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        csvf.close()
        mt5c.shutdown()


if __name__ == "__main__":
    main()
