# Gold & Spartan Trading EAs

**MetaTrader 5 Expert Advisors for Exness**  
**Account:** $1,500 starting capital  
**Server:** GMT+0

---

## 📦 What's Included

### 🥇 Adaptive Gold Engine (XAUUSDm)
**Strategy:** Regime-adaptive swing/intraday  
**Timeframe:** H1 (1-hour)  
**Hold time:** 2-8 hours (uncapped runner can trail longer)  
**Expected return:** +24% per year @ 1% risk  
**Validation:** 2.5 years walk-forward tested (2024-2026)

**Files:**
- `AdaptiveGoldEngine.mq5` — The EA (compile with F7)
- `AdaptiveGoldEngine.set` — 1% scaling risk config (recommended)

**How it works:**
- **Trend regime** (ADX ≥25): Follows EMA crossovers during London/NY sessions
- **Range regime** (ADX <20): Fades Asian session highs/lows
- **Partial TP:** Banks 50% at TP1 (1.5×ATR), moves SL to breakeven
- **Uncapped runner:** Trails remaining 50% with no profit ceiling

---

### ₿ SpartanFade (BTCUSDm)
**Strategy:** US Market Open fade  
**Timeframe:** Any (timer-driven)  
**Hold time:** 10 minutes (9:30-9:40 AM ET)  
**Expected return:** +9% per year @ 2.5% risk  
**Validation:** 14 years tested (2012-2026, 3,646 NYSE days)

**Files:**
- `SpartanFade_v1.0.mq5` — The EA (compile with F7)
- `SpartanFade_Exness_Aggressive.set` — 2.5% risk (recommended)
- `SpartanFade_Exness_Conservative.set` — 1% risk (safer)

**How it works:**
- Snapshots BTC price at **9:20 AM ET** (13:20 UTC / 15:20 SAST)
- If move ≥0.15% by **9:30 AM ET** → fades the move
- Hard flat exit at **9:40 AM ET** (10-minute hold)
- Real US DST calculation, NYSE holiday guard
- ~100 trades/year

---

## 🚀 Quick Start

### 1. Compile EAs
1. Copy all `.mq5` files to MT5 `MQL5/Experts/` folder
2. Open MetaEditor → open each `.mq5` → press **F7**
3. Confirm "0 errors" for both

### 2. Setup Charts

#### Chart 1: XAUUSDm (Gold)
- **Timeframe:** H1 (important!)
- Attach `AdaptiveGoldEngine`
- Load `AdaptiveGoldEngine.set`
- Verify: `InpBrokerGmtOffset = 0` ✅
- Enable AutoTrading

#### Chart 2: BTCUSDm (Bitcoin)
- **Timeframe:** Any (M1, M5, H1)
- Attach `SpartanFade_v1.0`
- Load `SpartanFade_Exness_Aggressive.set`
- Verify: `InpServerUTCOffset = 0` ✅
- Enable AutoTrading

### 3. Demo First!
Run both on **demo for 2 weeks** before going live to:
- Verify correct timing (Spartan fires at 13:30 UTC / 15:30 SAST)
- Watch Gold's regime detection + partial TP + trailing runner
- Confirm no errors in the MT5 journal

---

## 💰 Expected Performance (on $1,500)

### Conservative Split ($750 each)
| EA | Risk | Expected/year |
|---|---|---|
| Spartan @ 2% | $750 | +$56 |
| Gold @ 1% | $750 | +$180 |
| **Total** | $1,500 | **+$236/year (16%)** |

### Aggressive (pick one)
| Strategy | Risk | Expected/year | Max DD |
|---|---|---|---|
| Gold only @ 1% | $1,500 | **+$360 (24%)** | 34% |
| Gold only @ 1.5% | $1,500 | +$330 (22%) | 37% |

---

## ⚙️ Key Settings

### Adaptive Gold Engine
- `InpBrokerGmtOffset = 0` — Exness server is GMT+0
- `InpRiskPercent = 1.0` — Auto-scales with balance (recommended)
- `InpFixedRiskUSD = 0.0` — Keep OFF (use % scaling)
- `InpMaxDailyLoss = 50.0` — Circuit breaker (keep ON)
- `InpMaxDailyProfit = 0.0` — Uncapped profit side
- `InpUsePartialTP = true` — Bank 50% at TP1, trail runner
- `InpTpAtr = 0.0` — Uncapped runner (no hard TP)

### SpartanFade
- `InpServerUTCOffset = 0` — Exness server is GMT+0
- `InpRiskPerTradePct = 2.5` — Aggressive (can dial up to 3.0%)
- `InpFadeThresholdPct = 0.15` — Validated optimum
- `InpTradeTuesday = false` — Backtest shows Tuesdays lose
- `InpMaxWeeklyDD_Pct = 5.0` — Weekly circuit breaker

---

## 📊 Trading Schedule (South Africa Time, UTC+2)

### Spartan (BTC)
- **15:20** — Snapshots BTC price (9:20 AM ET)
- **15:30** — Evaluates and enters (9:30 AM ET = US market open)
- **15:40** — Hard flat exit (9:40 AM ET)
- Trades **2-3 times per week** (not every day triggers)

### Gold (XAU)
- **09:00-13:00** — London session (trend following)
- **15:00-18:00** — NY session (trend following)
- **00:00-09:00** — Asian session (range fading)
- Trades **multiple times per day** across all sessions

---

## 🔐 Risk Management

**Both EAs have built-in safety:**
- Auto lot sizing (scales with balance)
- Daily loss caps (circuit breakers)
- Max spread filters
- Anti-correlation (pauses after consecutive losses)

**Recommended portfolio allocation:**
- **Conservative:** Split $750/$750 (diversification across BTC and Gold)
- **Moderate:** Full $1,500 on Gold @ 1% (accept 34% DD)
- **Aggressive:** Full $1,500 on Gold @ 1.5% (accept 37% DD)

---

## ⚠️ Important Notes

1. **VPS recommended** — EAs need to run 24/5 (Spartan needs to be live at 15:30 daily)
2. **Demo first** — Validate timing and behavior before risking real money
3. **Don't panic on drawdowns** — Gold's 34% DD is survivable but painful (tested on 2.5 years)
4. **Don't manually close runners** — Gold's uncapped trail is where big wins come from
5. **Check the journal** — Watch for errors, especially around DST changes

---

## 📈 Validation & Backtesting

### Adaptive Gold Engine
- **Backtest period:** 2024-2026 (2.5 years, hourly data)
- **Method:** Walk-forward (60/40 split + 3-way validation)
- **In-sample:** Profitable, PF > 1
- **Out-of-sample:** Profitable, PF > 1
- **All three time-thirds:** Profitable independently
- **@ 1% risk:** +60% return, 34% max DD, PF 1.18

### SpartanFade
- **Backtest period:** 2012-2026 (14 years, 3,646 NYSE days)
- **Data:** Bitstamp 1-minute BTC spot
- **@ 0.15% threshold:** 1,442 trades, 54% win rate, +52% total
- **Edge:** Mean-reversion of pre-open BTC move at US market open

---

## 📞 Support

For issues or questions:
1. Check MT5 Experts tab for error messages
2. Verify correct GMT offset settings
3. Confirm EAs show smiley face 😊 on chart
4. Ensure AutoTrading is enabled (green button)

---

**Developed:** July 2026  
**Platform:** MetaTrader 5  
**Broker:** Exness (GMT+0)  
**Starting Capital:** $1,500  
**Risk Level:** Conservative to Moderate (1-2.5%)
