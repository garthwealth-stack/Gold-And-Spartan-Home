//+------------------------------------------------------------------+
//|                                            SpartanFade_v1.0.mq5 |
//|         BTC US-Open Fade EA — forked from SpartanShield family  |
//|         Validated on 3,646 NYSE days, Bitstamp 1-min, 2012-2026 |
//+------------------------------------------------------------------+
#property copyright "Garth van Veenhuyzen"
#property version   "1.00"
#property strict
#property description "Fades the 9:20->9:30 ET pre-open move on BTCUSDm."
#property description "OnTimer-driven. Real US DST calc. NYSE holiday guard."
#property description "Hard flat at 9:40 ET. No recovery, no martingale."

#include <Trade/Trade.mqh>
CTrade trade;

//--- Core
input group    "=== Core EA Settings ==="
input long     InpMagicNumber       = 793030;   // Magic Number
input double   InpRiskPerTradePct   = 1.0;      // Risk per trade (% of balance)
input int      InpServerUTCOffset   = 0;        // Broker server UTC offset (Exness = 0)

//--- Matrix 1: Anchor
input group    "=== Matrix 1: Anchor / Trigger ==="
input double   InpFadeThresholdPct  = 0.15;     // Min |pre-move| to trigger (%)
input bool     InpLongOnly          = false;    // Long fades only
input double   InpShortSizeFactor   = 0.5;      // Short fade size factor (asymmetry)
input bool     InpTradeTuesday      = false;    // Trade Tuesdays (backtest: negative)

//--- Matrix 2: Variance / Aborts
input group    "=== Matrix 2: Variance / Aborts ==="
input double   InpAbortCeilingPct   = 1.0;      // Max |pre-move| — above = news regime
input double   InpVolAbortMult      = 3.0;      // Abort if pre-vol > N x weekday median
input int      InpVolMedianSessions = 30;       // Same-weekday sessions for median
input int      InpMaxSpreadPoints   = 1500;     // Max spread at entry (points)
input int      InpMaxTickAgeSec     = 5;        // Max quote age (seconds)

//--- Matrix 3: Execution
input group    "=== Matrix 3: Trade Management ==="
input double   InpHardSL_Pct        = 0.5;      // Hard stop loss (%)
input double   InpBE_TriggerPct     = 0.25;     // Move SL to breakeven at +X%
input bool     InpRunnerMode        = false;    // Keep 25% past 9:40 (UNVALIDATED - OFF)
input double   InpRunnerTrailPct    = 0.30;     // Runner trailing stop (%)

//--- Plan B
input group    "=== Plan B: Circuit Breakers ==="
input int      InpCooldownLosses    = 3;        // Consecutive losses to trigger pause
input int      InpCooldownDays      = 5;        // Pause length (calendar days)
input double   InpMaxWeeklyDD_Pct   = 3.0;      // Weekly drawdown cap (%)

//--- State
double   gRefPrice        = 0.0;      // 9:20 snapshot
datetime gRefDate         = 0;        // date the snapshot belongs to
datetime gTradedDate      = 0;        // date we last evaluated the open
int      gConsecLosses    = 0;
datetime gCooldownUntil   = 0;
double   gWeekBalance     = 0.0;
datetime gWeekAnchor      = 0;
bool     gRunnerReduced   = false;
double   gRunnerPeak      = 0.0;
string   GV_PREFIX;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(200);
   GV_PREFIX = "SF" + (string)InpMagicNumber + "_";
   // restore circuit-breaker state across restarts
   if(GlobalVariableCheck(GV_PREFIX+"cooldown"))
      gCooldownUntil = (datetime)GlobalVariableGet(GV_PREFIX+"cooldown");
   if(GlobalVariableCheck(GV_PREFIX+"losses"))
      gConsecLosses = (int)GlobalVariableGet(GV_PREFIX+"losses");
   gWeekBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   gWeekAnchor  = TimeTradeServer();
   EventSetTimer(1);                      // clock-driven, not tick-driven
   Print("SpartanFade v1.0 initialised. Magic=", InpMagicNumber);
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason) { EventKillTimer(); }

//+------------------------------------------------------------------+
//| All timing runs on the 1-second timer: snapshot, entry and the  |
//| 9:40 hard flat fire on the clock even if no tick arrives.       |
//+------------------------------------------------------------------+
void OnTimer()
{
   datetime now = TimeTradeServer();
   MqlDateTime dt; TimeToStruct(now, dt);

   // ---- weekly drawdown anchor: reset Monday ----
   if(dt.day_of_week == 1 && (now - gWeekAnchor) > 86400)
   {
      gWeekBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      gWeekAnchor  = now;
   }

   datetime openTime = NYOpenServerTime(now);   // DST-correct 9:30 ET in server time
   datetime today    = DateOf(now);

   // ---- manage open positions first (exits must never be blocked) ----
   ManagePositions(openTime, now);

   // ---- weekend + NYSE holiday guard: no NY open exists ----
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return;
   if(IsUSMarketHoliday(now)) return;

   // ---- circuit breakers ----
   if(now < gCooldownUntil) return;
   if(gWeekBalance > 0)
   {
      double dd = (gWeekBalance - AccountInfoDouble(ACCOUNT_BALANCE)) / gWeekBalance * 100.0;
      if(dd >= InpMaxWeeklyDD_Pct) return;
   }

   // ---- date-anchored snapshot reset (fixes stale-lockout bug) ----
   if(gRefDate != today) { gRefPrice = 0.0; gRefDate = today; gRunnerReduced = false; gRunnerPeak = 0.0; }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   bool freshQuote = (now - tick.time) <= InpMaxTickAgeSec;

   // ---- T-10: capture reference (9:20:00 .. 9:29:59, first fresh quote) ----
   if(now >= openTime - 600 && now < openTime && gRefPrice == 0.0 && freshQuote)
   {
      // only accept the snapshot inside the first 30s so PreMove% means 9:20 exactly
      if(now <= openTime - 570)
         gRefPrice = tick.bid;
   }

   // ---- T0: evaluate & enter (9:30:00 .. 9:30:10) ----
   if(now >= openTime && now <= openTime + 10 && gTradedDate != today)
   {
      gTradedDate = today;                       // one evaluation per day, pass or fail
      if(gRefPrice <= 0.0) { Print("Abort: no 9:20 snapshot"); return; }
      if(!freshQuote)      { Print("Abort: stale quote at open"); return; }
      Evaluate(tick, dt.day_of_week, openTime);
   }
}

//+------------------------------------------------------------------+
void Evaluate(MqlTick &tick, int dow, datetime openTime)
{
   if(dow == 2 && !InpTradeTuesday) return;                       // Matrix 1: day filter

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);       // Matrix 2: spread guard
   if(spread > InpMaxSpreadPoints) { Print("Abort: spread ", spread); return; }

   double preMove = (tick.bid - gRefPrice) / gRefPrice * 100.0;
   double a = MathAbs(preMove);
   if(a < InpFadeThresholdPct) return;                            // no signal
   if(a > InpAbortCeilingPct)  { Print("Abort: news regime |pre|=", a); return; }

   if(!VolumeWindowOK(openTime)) { Print("Abort: volume variance"); return; }

   bool isShort = (preMove > 0);
   if(isShort && InpLongOnly) return;

   double lots = LotSize(tick.bid);
   if(isShort) lots = NormalizeLots(lots * InpShortSizeFactor);
   if(lots <= 0) return;

   double price = isShort ? tick.bid : tick.ask;
   double sl    = isShort ? price * (1.0 + InpHardSL_Pct/100.0)
                          : price * (1.0 - InpHardSL_Pct/100.0);
   sl = NormalizePrice(sl);

   bool ok = isShort ? trade.Sell(lots, _Symbol, 0.0, sl, 0.0, "SF fade S")
                     : trade.Buy (lots, _Symbol, 0.0, sl, 0.0, "SF fade L");
   PrintFormat("SpartanFade %s | pre=%.3f%% lots=%.2f sl=%.2f -> %s",
               isShort?"SHORT":"LONG", preMove, lots, sl, ok?"FILLED":"REJECTED");
}

//+------------------------------------------------------------------+
//| Matrix 2.2: pre-open volume vs 30 same-weekday session medians. |
//| Each historical session's 9:20-9:29 window is located with the  |
//| DST-correct open time FOR THAT DATE (fixes hardcoded hour bug). |
//+------------------------------------------------------------------+
bool VolumeWindowOK(datetime openTime)
{
   long cur = WindowVolume(openTime - 600, openTime - 60);
   if(cur < 0) return true;                       // data unavailable -> pass, spread guard still active

   long hist[]; int found = 0;
   MqlDateTime dtNow; TimeToStruct(openTime, dtNow);
   for(int back = 1; back <= 220 && found < InpVolMedianSessions; back++)
   {
      datetime d = openTime - back*86400;
      MqlDateTime dh; TimeToStruct(d, dh);
      if(dh.day_of_week != dtNow.day_of_week) continue;
      if(IsUSMarketHoliday(d)) continue;
      datetime hOpen = NYOpenServerTime(d);
      long v = WindowVolume(hOpen - 600, hOpen - 60);
      if(v <= 0) continue;
      ArrayResize(hist, found + 1);
      hist[found++] = v;
   }
   if(found < 10) return true;                    // fail-safe: not enough history
   ArraySort(hist);
   long median = hist[found/2];
   return (cur <= median * InpVolAbortMult);
}

long WindowVolume(datetime from, datetime to)
{
   MqlRates rates[];
   int n = CopyRates(_Symbol, PERIOD_M1, from, to, rates);
   if(n < 5) return -1;
   long v = 0;
   for(int i = 0; i < n; i++) v += (long)rates[i].tick_volume;
   return v;
}

//+------------------------------------------------------------------+
//| Matrix 3 exits + Plan B. Runs every second.                     |
//+------------------------------------------------------------------+
void ManagePositions(datetime openTime, datetime now)
{
   datetime flatTime = openTime + 600;            // 9:40:00 ET
   double tickSz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur   = PositionGetDouble(POSITION_PRICE_CURRENT);
      double sl    = PositionGetDouble(POSITION_SL);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool isLong  = (type == POSITION_TYPE_BUY);
      double pnl   = (isLong ? (cur-entry) : (entry-cur)) / entry * 100.0;

      // ---- hard flat at 9:40 (primary, validated exit) ----
      if(now >= flatTime)
      {
         if(InpRunnerMode && isLong && pnl >= 0.30 && !gRunnerReduced)
         {
            double vol = PositionGetDouble(POSITION_VOLUME);
            double closeVol = NormalizeLots(vol * 0.75);
            if(closeVol > 0 && closeVol < vol)
            {
               trade.PositionClosePartial(ticket, closeVol);
               gRunnerReduced = true;             // fixed: partial close fires ONCE
               gRunnerPeak = cur;
               continue;
            }
         }
         if(gRunnerReduced && isLong)             // trail the 25% runner
         {
            if(cur > gRunnerPeak) gRunnerPeak = cur;
            double trail = NormalizePrice(gRunnerPeak * (1.0 - InpRunnerTrailPct/100.0));
            if(cur <= trail) { ForceClose(ticket); continue; }
            if(trail > sl + tickSz) trade.PositionModify(ticket, trail, 0.0);
            continue;
         }
         ForceClose(ticket);
         continue;
      }

      // ---- breakeven move (double-safe compare, normalized) ----
      if(pnl >= InpBE_TriggerPct && MathAbs(sl - entry) > tickSz * 0.5)
      {
         double be = NormalizePrice(entry);
         bool improves = isLong ? (be > sl) : (sl == 0.0 || be < sl);
         if(improves) trade.PositionModify(ticket, be, 0.0);
      }

      // ---- SL integrity: re-arm if broker wiped it ----
      if(sl == 0.0)
      {
         double fix = isLong ? entry * (1.0 - InpHardSL_Pct/100.0)
                             : entry * (1.0 + InpHardSL_Pct/100.0);
         trade.PositionModify(ticket, NormalizePrice(fix), 0.0);
      }
   }
}

void ForceClose(ulong ticket)
{
   for(int attempt = 0; attempt < 4; attempt++)
   {
      trade.SetDeviationInPoints(200 + attempt * 300);   // widening escape route
      if(trade.PositionClose(ticket)) { trade.SetDeviationInPoints(200); return; }
      Sleep(150);
   }
   trade.SetDeviationInPoints(200);
   Print("CRITICAL: failed to flatten ticket ", ticket, " err=", GetLastError());
}

//+------------------------------------------------------------------+
//| Plan B.4: loss cooldown driven by ACTUAL closed deals.          |
//| (Fixes the never-firing CheckAndApplyMidasLoss.)                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   double net = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
              + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   if(net < 0) gConsecLosses++; else gConsecLosses = 0;

   if(gConsecLosses >= InpCooldownLosses)
   {
      gCooldownUntil = TimeTradeServer() + (datetime)InpCooldownDays * 86400;
      gConsecLosses  = 0;
      PrintFormat("Plan B: %d consecutive losses -> paused until %s",
                  InpCooldownLosses, TimeToString(gCooldownUntil));
   }
   GlobalVariableSet(GV_PREFIX+"cooldown", (double)gCooldownUntil);
   GlobalVariableSet(GV_PREFIX+"losses",  (double)gConsecLosses);
}

//+------------------------------------------------------------------+
//| Real US DST: 2nd Sunday of March 2:00 -> 1st Sunday of November.|
//| NY open 9:30 ET = 13:30 UTC (DST) / 14:30 UTC (standard).       |
//+------------------------------------------------------------------+
datetime NYOpenServerTime(datetime serverTime)
{
   datetime utc = serverTime - (datetime)(InpServerUTCOffset * 3600);
   MqlDateTime d; TimeToStruct(utc, d);
   int openUTCHour = IsUS_DST(d.year, d.mon, d.day) ? 13 : 14;
   d.hour = openUTCHour; d.min = 30; d.sec = 0;
   return StructToTime(d) + (datetime)(InpServerUTCOffset * 3600);
}

bool IsUS_DST(int year, int month, int day)
{
   if(month > 3 && month < 11) return true;
   if(month < 3 || month > 11) return false;
   int boundary = (month == 3) ? NthWeekdayDom(year, 3, 0, 2)     // 2nd Sunday March
                               : NthWeekdayDom(year, 11, 0, 1);   // 1st Sunday November
   return (month == 3) ? (day >= boundary) : (day < boundary);
}

// day-of-month of the n-th weekday (0=Sun) of a month
int NthWeekdayDom(int year, int month, int weekday, int n)
{
   MqlDateTime d; ZeroMemory(d);
   d.year = year; d.mon = month; d.day = 1; d.hour = 12;
   datetime t = StructToTime(d);
   MqlDateTime f; TimeToStruct(t, f);
   int first = f.day_of_week;
   int offset = (weekday - first + 7) % 7;
   return 1 + offset + (n - 1) * 7;
}
int LastWeekdayDom(int year, int month, int weekday)
{
   int dim = DaysInMonth(year, month);
   MqlDateTime d; ZeroMemory(d);
   d.year = year; d.mon = month; d.day = dim; d.hour = 12;
   datetime t = StructToTime(d);
   MqlDateTime f; TimeToStruct(t, f);
   return dim - ((f.day_of_week - weekday + 7) % 7);
}
int DaysInMonth(int y, int m)
{
   int dm[] = {31,28,31,30,31,30,31,31,30,31,30,31};
   if(m == 2 && ((y%4==0 && y%100!=0) || y%400==0)) return 29;
   return dm[m-1];
}

//+------------------------------------------------------------------+
//| NYSE holidays: fixed (with observed shifts), floating, and      |
//| Good Friday via Gauss/anonymous Gregorian Easter algorithm.     |
//+------------------------------------------------------------------+
bool IsUSMarketHoliday(datetime serverTime)
{
   datetime utc = serverTime - (datetime)(InpServerUTCOffset * 3600);
   MqlDateTime d; TimeToStruct(utc, d);
   int y = d.year, m = d.mon, dd = d.day;

   if(IsObservedFixed(y, m, dd, 1, 1))  return true;    // New Year
   if(IsObservedFixed(y, m, dd, 6, 19)) return true;    // Juneteenth
   if(IsObservedFixed(y, m, dd, 7, 4))  return true;    // Independence Day
   if(IsObservedFixed(y, m, dd, 12, 25))return true;    // Christmas
   if(m == 1  && dd == NthWeekdayDom(y, 1, 1, 3))  return true;  // MLK: 3rd Mon Jan
   if(m == 2  && dd == NthWeekdayDom(y, 2, 1, 3))  return true;  // Presidents: 3rd Mon Feb
   if(m == 5  && dd == LastWeekdayDom(y, 5, 1))    return true;  // Memorial: last Mon May
   if(m == 9  && dd == NthWeekdayDom(y, 9, 1, 1))  return true;  // Labor: 1st Mon Sep
   if(m == 11 && dd == NthWeekdayDom(y, 11, 4, 4)) return true;  // Thanksgiving: 4th Thu Nov
   // Good Friday = Easter Sunday - 2 days
   int em, ed; EasterSunday(y, em, ed);
   datetime easter = MakeDate(y, em, ed);
   MqlDateTime gf; TimeToStruct(easter - 2*86400, gf);
   if(m == gf.mon && dd == gf.day) return true;
   return false;
}

bool IsObservedFixed(int y, int m, int dd, int hm, int hd)
{
   datetime h = MakeDate(y, hm, hd);
   MqlDateTime f; TimeToStruct(h, f);
   datetime obs = h;
   if(f.day_of_week == 6) obs = h - 86400;              // Sat -> Friday before
   if(f.day_of_week == 0) obs = h + 86400;              // Sun -> Monday after
   MqlDateTime o; TimeToStruct(obs, o);
   return (m == o.mon && dd == o.day && y == o.year);
}

void EasterSunday(int y, int &month, int &day)
{
   int a = y % 19, b = y / 100, c = y % 100;
   int dq = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3;
   int hh = (19*a + b - dq - g + 15) % 30;
   int i = c / 4, k = c % 4;
   int l = (32 + 2*e + 2*i - hh - k) % 7;
   int mm = (a + 11*hh + 22*l) / 451;
   month = (hh + l - 7*mm + 114) / 31;
   day   = ((hh + l - 7*mm + 114) % 31) + 1;
}

datetime MakeDate(int y, int m, int d)
{
   MqlDateTime t; ZeroMemory(t);
   t.year = y; t.mon = m; t.day = d; t.hour = 12;
   return StructToTime(t);
}
datetime DateOf(datetime t) { return t - (t % 86400); }

//+------------------------------------------------------------------+
//| Sizing & normalization                                          |
//+------------------------------------------------------------------+
double LotSize(double price)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskCash = balance * InpRiskPerTradePct / 100.0;
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSz <= 0) return 0;
   double slDist   = price * InpHardSL_Pct / 100.0;
   double lossPerLot = slDist / tickSz * tickVal;
   if(lossPerLot <= 0) return 0;
   return NormalizeLots(riskCash / lossPerLot);
}
double NormalizeLots(double lots)
{
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   return MathMax(minL, MathMin(maxL, lots));
}
double NormalizePrice(double p)
{
   double tickSz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSz <= 0) return NormalizeDouble(p, _Digits);
   return NormalizeDouble(MathRound(p / tickSz) * tickSz, _Digits);
}
//+------------------------------------------------------------------+
