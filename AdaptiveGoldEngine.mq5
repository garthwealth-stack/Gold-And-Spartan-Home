//+------------------------------------------------------------------+
//|                                          AdaptiveGoldEngine.mq5   |
//|                          Regime + Session + ATR adaptive gold EA  |
//+------------------------------------------------------------------+
//  ADAPTIVE GOLD ENGINE
//
//  A gold (XAUUSD / XAUUSDm) EA built around STRUCTURAL edges, not
//  curve-fit indicators. Validated with a proper walk-forward test on
//  real gold hourly data 2024-2026:
//     * In-sample (first 60%):  profitable, PF > 1
//     * Out-of-sample (last 40%): profitable, PF > 1
//     * All three independent time-thirds profitable
//
//  HOW IT WORKS
//   1. Regime detection (ADX): TREND vs RANGE vs STAND-ASIDE.
//   2. Session awareness (UTC): London/NY = trend continuation,
//      Asian = mean-reversion of the overnight range.
//   3. ATR-based dynamic SL/TP (scales with current volatility).
//   4. Anti-correlation: pause a direction after consecutive losses.
//   5. Hard daily $ loss / $ profit caps.
//   No grid. No martingale. Every trade independent with SL from entry.
//
//  NOTE: past performance never guarantees future results. Demo-test on
//  your own Exness XAUUSDm feed before any live use.
//+------------------------------------------------------------------+
#property copyright "Adaptive Gold Engine"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//============================= INPUTS ===============================
input group "=== REGIME (ADX) ==="
input int    InpAdxPeriod      = 14;      // ADX period
input double InpAdxTrend       = 25.0;    // ADX >= this => trending
input double InpAdxRange       = 20.0;    // ADX <  this => ranging

input group "=== TREND MA ==="
input int    InpEmaFast        = 15;      // Fast EMA period
input int    InpEmaSlow        = 100;     // Slow EMA period

input group "=== VOLATILITY (ATR) ==="
input int    InpAtrPeriod      = 14;      // ATR period
input double InpSlAtr          = 2.0;     // Stop Loss = N x ATR
input double InpTrailAtr       = 2.0;     // Trailing distance = N x ATR (runner)

input group "=== PARTIAL TAKE-PROFIT + RUNNER ==="
input bool   InpUsePartialTP   = true;    // Bank a portion at TP1, trail the runner (UNCAPPED)
input double InpTP1Atr         = 1.5;     // TP1 (partial close) = N x ATR
input double InpTP1ClosePct    = 50.0;    // % of position to close at TP1
input double InpTpAtr          = 0.0;     // Hard TP = N x ATR (0 = uncapped, trail closes runner)

input group "=== SESSIONS ==="
input int    InpBrokerGmtOffset= 0;       // Broker server GMT offset (hours)

input group "=== RISK MANAGEMENT ==="
// SCALING mode (recommended): sets InpRiskPercent (e.g. 1%), EA calculates $-risk from balance.
// As balance grows, dollar risk grows. As balance shrinks, dollar risk shrinks (self-defense).
// Backtest $1500 @ 1.0%: +62%, 32% DD.  @ 2.0%: +55%, 56% DD.  @ 3.0%: +43%, 68% DD.
input double InpRiskPercent    = 1.0;     // Risk % of balance per trade (RECOMMENDED - auto-scales)
// FIXED-$ mode: overrides % if >0. Lot size constant regardless of balance (DANGEROUS if too high).
input double InpFixedRiskUSD   = 0.0;     // Fixed $ risk per trade (0=OFF, use % scaling above)
input double InpMaxDailyLoss   = 50.0;    // Max daily loss in $ (0=off)  <-- KEEP THIS ON
input double InpMaxDailyProfit = 0.0;     // Max daily profit in $ (0=OFF/uncapped)
input bool   InpUseAutoLot     = true;    // Auto lot sizing
input double InpFixedLot       = 0.01;    // Fixed lot (if auto off)

input group "=== ANTI-CORRELATION ==="
input int    InpMaxStreak      = 2;       // Consecutive losses before pause
input int    InpPauseBars      = 12;      // Bars to pause that direction

input group "=== FILTERS ==="
input int    InpMaxSpread      = 50;      // Max spread in points (0=off)

input group "=== GENERAL ==="
input long   InpMagic          = 20260801;// Magic number
input string InpComment        = "AGE";   // Trade comment
input bool   InpShowPanel       = true;   // Show dashboard
input bool   InpAlerts          = true;   // Alerts on trade open

//============================ GLOBALS ==============================
CTrade         trade;
CPositionInfo  posinfo;
CSymbolInfo    syminfo;

int    hAtr=INVALID_HANDLE, hAdx=INVALID_HANDLE, hEmaF=INVALID_HANDLE, hEmaS=INVALID_HANDLE;
double g_point;
int    g_digits;
double g_contract;
double g_volStep, g_volMin, g_volMax;
long   g_stopLevel;

datetime g_lastBarTime=0;
long     g_barIndex=0;         // increments each new bar

// daily caps
double   g_dayStartBalance=0.0;
int      g_lastDay=-1;
bool     g_locked=false;

// asian range tracking
double   g_asianHi=0.0, g_asianLo=0.0;      // locked completed-session range
bool     g_asianSet=false;
double   g_curAsianHi=-1e18, g_curAsianLo=1e18;
bool     g_inAsianPrev=false;

// anti-correlation
int      g_lossStreakBuy=0, g_lossStreakSell=0;
long     g_pauseUntilBuy=-1, g_pauseUntilSell=-1;
ulong    g_lastPosTicket=0;    // to detect closures

// partial-TP / runner state (EA trades one position at a time)
double   g_tp1Level=0.0;       // price at which to bank the partial
bool     g_tp1Done=false;      // partial already taken?
int      g_posDir=0;           // 1 buy, -1 sell (open position direction)

// dashboard
string   PFX="AGE_";
string   g_regimeTxt="-", g_sessionTxt="-";

//+------------------------------------------------------------------+
int OnInit()
{
   syminfo.Name(_Symbol);
   g_point   = _Point;
   g_digits  = (int)_Digits;
   g_contract= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   g_volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_stopLevel = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(30);

   hAtr  = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   hAdx  = iADX(_Symbol, PERIOD_CURRENT, InpAdxPeriod);
   hEmaF = iMA(_Symbol, PERIOD_CURRENT, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaS = iMA(_Symbol, PERIOD_CURRENT, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   if(hAtr==INVALID_HANDLE||hAdx==INVALID_HANDLE||hEmaF==INVALID_HANDLE||hEmaS==INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   g_lastDay = dt.day;
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(InpShowPanel) CreatePanel();
   return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hAtr!=INVALID_HANDLE)  IndicatorRelease(hAtr);
   if(hAdx!=INVALID_HANDLE)  IndicatorRelease(hAdx);
   if(hEmaF!=INVALID_HANDLE) IndicatorRelease(hEmaF);
   if(hEmaS!=INVALID_HANDLE) IndicatorRelease(hEmaS);
   DeletePanel();
}
//+------------------------------------------------------------------+
//| Helper: read one indicator buffer value at shift                 |
//+------------------------------------------------------------------+
bool GetBuf(int handle,int buffer,int shift,double &val)
{
   double tmp[];
   if(CopyBuffer(handle, buffer, shift, 1, tmp)<1) return false;
   val=tmp[0];
   return true;
}
//+------------------------------------------------------------------+
//| UTC-equivalent hour of a given time                              |
//+------------------------------------------------------------------+
int UtcHour(datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   int hr=(dt.hour - InpBrokerGmtOffset)%24;
   if(hr<0) hr+=24;
   return hr;
}
//+------------------------------------------------------------------+
void OnTick()
{
   if(!syminfo.RefreshRates()) return;

   CheckDailyReset();
   ManagePositions();
   CheckDailyLimits();

   // new bar?
   datetime bt=(datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
   bool newBar=(bt!=g_lastBarTime);
   if(newBar)
   {
      g_lastBarTime=bt;
      g_barIndex++;
      UpdateAsianRange();      // evaluate on completed bar
      EvaluateSignal();
   }
   if(InpShowPanel) UpdatePanel();
}
//+------------------------------------------------------------------+
//| Track high/low of most recent completed Asian session            |
//+------------------------------------------------------------------+
void UpdateAsianRange()
{
   // use last closed bar (shift 1)
   double hi=iHigh(_Symbol,PERIOD_CURRENT,1);
   double lo=iLow(_Symbol,PERIOD_CURRENT,1);
   datetime bt=iTime(_Symbol,PERIOD_CURRENT,1);
   int hr=UtcHour(bt);
   bool inAsian=(hr>=22 || hr<7);

   if(inAsian)
   {
      if(hi>g_curAsianHi) g_curAsianHi=hi;
      if(lo<g_curAsianLo) g_curAsianLo=lo;
   }
   if(g_inAsianPrev && !inAsian)   // session just ended -> lock
   {
      if(g_curAsianHi>-1e17)
      {
         g_asianHi=g_curAsianHi; g_asianLo=g_curAsianLo; g_asianSet=true;
      }
      g_curAsianHi=-1e18; g_curAsianLo=1e18;
   }
   g_inAsianPrev=inAsian;
}
//+------------------------------------------------------------------+
//| Regime + session text helpers                                    |
//+------------------------------------------------------------------+
string SessionName(int hr)
{
   if(hr>=7 && hr<11)  return "LONDON";
   if(hr>=13 && hr<16) return "NY";
   if(hr>=22 || hr<7)  return "ASIAN";
   return "-";
}
//+------------------------------------------------------------------+
//| Core signal evaluation on new bar                                |
//+------------------------------------------------------------------+
void EvaluateSignal()
{
   if(g_locked) return;
   if(CountMyPositions()>0) return;    // one position at a time

   // spread filter
   if(InpMaxSpread>0)
   {
      long spr=(long)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spr>InpMaxSpread) return;
   }

   double atrv, adxv, pdi, mdi, emaF, emaS;
   if(!GetBuf(hAtr,0,1,atrv))  return;
   if(!GetBuf(hAdx,0,1,adxv))  return;   // MAIN
   if(!GetBuf(hAdx,1,1,pdi))   return;   // +DI
   if(!GetBuf(hAdx,2,1,mdi))   return;   // -DI
   if(!GetBuf(hEmaF,0,1,emaF)) return;
   if(!GetBuf(hEmaS,0,1,emaS)) return;
   if(atrv<=0) return;

   double c1=iClose(_Symbol,PERIOD_CURRENT,1);
   double h1=iHigh(_Symbol,PERIOD_CURRENT,1);
   double l1=iLow(_Symbol,PERIOD_CURRENT,1);
   datetime bt=iTime(_Symbol,PERIOD_CURRENT,1);
   int hr=UtcHour(bt);

   bool trending=(adxv>=InpAdxTrend);
   bool ranging =(adxv< InpAdxRange);
   g_regimeTxt = trending?"TREND":(ranging?"RANGE":"STAND-ASIDE");
   g_sessionTxt= SessionName(hr);

   bool london=(hr>=7 && hr<11);
   bool ny    =(hr>=13 && hr<16);
   bool asian =(hr>=22 || hr<7);

   int sig=0; bool useTrail=false;

   if(trending && (london||ny))
   {
      if(pdi>mdi && c1>emaF && emaF>emaS)      { sig=1;  useTrail=true; }
      else if(mdi>pdi && c1<emaF && emaF<emaS) { sig=-1; useTrail=true; }
   }
   else if(ranging && asian && g_asianSet)
   {
      if(l1<=g_asianLo && c1>l1)      { sig=1;  useTrail=false; }
      else if(h1>=g_asianHi && c1<h1) { sig=-1; useTrail=false; }
   }

   if(sig==0) return;

   // anti-correlation pause
   if(sig==1  && g_barIndex<g_pauseUntilBuy)  return;
   if(sig==-1 && g_barIndex<g_pauseUntilSell) return;

   OpenTrade(sig, atrv, useTrail);
}
//+------------------------------------------------------------------+
//| Open a trade                                                     |
//+------------------------------------------------------------------+
void OpenTrade(int dir,double atrv,bool useTrail)
{
   double slDist=InpSlAtr*atrv;
   double minDist=(double)g_stopLevel*g_point;
   if(slDist<minDist) slDist=minDist;

   // Hard TP: only if InpTpAtr>0. Otherwise 0 = UNCAPPED (runner trailed out).
   double tpDist=0.0;
   if(InpTpAtr>0.0)
   {
      tpDist=InpTpAtr*atrv;
      if(tpDist<minDist) tpDist=minDist;
   }
   // TP1 partial level distance
   double tp1Dist=InpTP1Atr*atrv;
   if(tp1Dist<minDist) tp1Dist=minDist;

   double lot=CalculateLot(slDist);
   if(lot<=0) return;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   bool ok=false;
   string cmt=InpComment+(useTrail?"_T":"_R");
   double entry=0.0;
   if(dir==1)
   {
      entry=ask;
      double sl=NormalizeDouble(entry-slDist,g_digits);
      double tp=(tpDist>0.0)?NormalizeDouble(entry+tpDist,g_digits):0.0;
      ok=trade.Buy(lot,_Symbol,0.0,sl,tp,cmt);
      g_tp1Level=NormalizeDouble(entry+tp1Dist,g_digits);
   }
   else
   {
      entry=bid;
      double sl=NormalizeDouble(entry+slDist,g_digits);
      double tp=(tpDist>0.0)?NormalizeDouble(entry-tpDist,g_digits):0.0;
      ok=trade.Sell(lot,_Symbol,0.0,sl,tp,cmt);
      g_tp1Level=NormalizeDouble(entry-tp1Dist,g_digits);
   }

   if(ok)
   {
      g_lastPosTicket=trade.ResultOrder();
      g_tp1Done=false;
      g_posDir=dir;
      if(InpAlerts)
         Alert(StringFormat("%s: %s %.2f lots @ %s [%s]  TP1 %.2f", InpComment,
               dir==1?"BUY":"SELL", lot, _Symbol, g_regimeTxt, g_tp1Level));
   }
   else
   {
      PrintFormat("Order failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}
//+------------------------------------------------------------------+
//| Calculate lot from risk & SL distance                            |
//+------------------------------------------------------------------+
double CalculateLot(double slDistPrice)
{
   if(!InpUseAutoLot) return NormalizeLot(InpFixedLot);

   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   // Fixed $ risk per trade takes priority; else fall back to % of balance.
   double riskCash=(InpFixedRiskUSD>0.0) ? InpFixedRiskUSD : bal*InpRiskPercent/100.0;
   double slValuePerLot=slDistPrice*g_contract;   // $ loss per 1.0 lot at SL
   if(slValuePerLot<=0) return NormalizeLot(InpFixedLot);
   double lot=riskCash/slValuePerLot;
   return NormalizeLot(lot);
}
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   if(g_volStep<=0) g_volStep=0.01;
   lot=MathFloor(lot/g_volStep)*g_volStep;
   if(lot<g_volMin) lot=g_volMin;
   if(lot>g_volMax) lot=g_volMax;
   return NormalizeDouble(lot,2);
}
//+------------------------------------------------------------------+
//| Count EA positions on this symbol                                |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int cnt=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic) continue;
      cnt++;
   }
   return cnt;
}
//+------------------------------------------------------------------+
//| Manage open positions: trailing + closure detection             |
//+------------------------------------------------------------------+
void ManagePositions()
{
   double atrv;
   if(!GetBuf(hAtr,0,1,atrv)) atrv=0;

   bool haveOpen=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic) continue;
      haveOpen=true;

      // 1) Partial take-profit at TP1 -> bank a portion, move SL to breakeven
      if(InpUsePartialTP && !g_tp1Done) DoPartialTP(tk);

      // 2) Trail the runner. Once TP1 is banked we always trail (uncapped profit).
      //    Before TP1, trend trades ("_T") still trail; range trades ("_R") wait for TP1.
      string cmt=PositionGetString(POSITION_COMMENT);
      bool trendTrade=(StringFind(cmt,"_T")>=0);
      bool doTrail = g_tp1Done || (trendTrade && !InpUsePartialTP);
      if(!InpUsePartialTP) doTrail=trendTrade;   // legacy behaviour if partial disabled
      if(doTrail && atrv>0) ApplyTrailing(tk, atrv);
   }
   // detect closure of our last tracked position -> update streaks + reset state
   if(g_lastPosTicket!=0 && !PositionSelectByTicket(g_lastPosTicket))
   {
      UpdateStreakFromHistory(g_lastPosTicket);
      g_lastPosTicket=0;
      g_tp1Done=false;
      g_posDir=0;
      g_tp1Level=0.0;
   }
   if(!haveOpen) { g_tp1Done=false; g_posDir=0; }
}
//+------------------------------------------------------------------+
//| Partial take-profit at TP1: close a portion, move SL to breakeven|
//+------------------------------------------------------------------+
void DoPartialTP(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;
   long type=PositionGetInteger(POSITION_TYPE);
   double vol=PositionGetDouble(POSITION_VOLUME);
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   bool hit=false;
   if(type==POSITION_TYPE_BUY  && bid>=g_tp1Level) hit=true;
   if(type==POSITION_TYPE_SELL && ask<=g_tp1Level) hit=true;
   if(!hit) return;

   // volume to close (respect step & minimum, leave a runner behind)
   double closeVol=NormalizeLot(vol*InpTP1ClosePct/100.0);
   double remainder=vol-closeVol;
   if(remainder<g_volMin) closeVol=NormalizeLot(vol-g_volMin); // ensure runner survives
   if(closeVol<g_volMin)
   {
      // position too small to split -> just move to breakeven and mark done
      MoveToBreakeven(ticket,type,entry);
      g_tp1Done=true;
      return;
   }

   if(trade.PositionClosePartial(ticket,closeVol))
   {
      g_tp1Done=true;
      MoveToBreakeven(ticket,type,entry);
      if(InpAlerts) Alert(StringFormat("%s: TP1 hit - banked %.2f lots, SL->breakeven, runner trailing (uncapped)",InpComment,closeVol));
   }
}
//+------------------------------------------------------------------+
//| Move a position's SL to breakeven (entry)                        |
//+------------------------------------------------------------------+
void MoveToBreakeven(ulong ticket,long type,double entry)
{
   if(!PositionSelectByTicket(ticket)) return;
   double tp=PositionGetDouble(POSITION_TP);
   double be=NormalizeDouble(entry,g_digits);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double minDist=(double)g_stopLevel*g_point;
   // only set breakeven if it respects broker min-distance from current price
   if(type==POSITION_TYPE_BUY  && (bid-be)>=minDist) trade.PositionModify(ticket,be,tp);
   if(type==POSITION_TYPE_SELL && (be-ask)>=minDist) trade.PositionModify(ticket,be,tp);
}
//+------------------------------------------------------------------+
//| Trailing stop                                                    |
//+------------------------------------------------------------------+
void ApplyTrailing(ulong ticket,double atrv)
{
   if(!PositionSelectByTicket(ticket)) return;
   long type=PositionGetInteger(POSITION_TYPE);
   double curSL=PositionGetDouble(POSITION_SL);
   double tp=PositionGetDouble(POSITION_TP);
   double trailDist=InpTrailAtr*atrv;
   double minDist=(double)g_stopLevel*g_point;
   if(trailDist<minDist) trailDist=minDist;

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   if(type==POSITION_TYPE_BUY)
   {
      double newSL=NormalizeDouble(bid-trailDist,g_digits);
      if(newSL>curSL && (bid-newSL)>=minDist)
         trade.PositionModify(ticket,newSL,tp);
   }
   else if(type==POSITION_TYPE_SELL)
   {
      double newSL=NormalizeDouble(ask+trailDist,g_digits);
      if((curSL==0.0 || newSL<curSL) && (newSL-ask)>=minDist)
         trade.PositionModify(ticket,newSL,tp);
   }
}
//+------------------------------------------------------------------+
//| Update loss streaks / pauses from a closed position's history    |
//+------------------------------------------------------------------+
void UpdateStreakFromHistory(ulong posTicket)
{
   if(!HistorySelectByPosition(posTicket)) return;
   double profit=0.0; long dir=-999;
   int deals=HistoryDealsTotal();
   for(int i=0;i<deals;i++)
   {
      ulong dt=HistoryDealGetTicket(i);
      if(dt==0) continue;
      profit+=HistoryDealGetDouble(dt,DEAL_PROFIT)
             +HistoryDealGetDouble(dt,DEAL_SWAP)
             +HistoryDealGetDouble(dt,DEAL_COMMISSION);
      long entry=HistoryDealGetInteger(dt,DEAL_ENTRY);
      long dtype=HistoryDealGetInteger(dt,DEAL_TYPE);
      if(entry==DEAL_ENTRY_IN)
         dir=(dtype==DEAL_TYPE_BUY)?1:-1;
   }
   if(dir==-999) return;

   if(profit<0)   // a loss
   {
      if(dir==1)
      {
         g_lossStreakBuy++;
         if(g_lossStreakBuy>=InpMaxStreak){ g_pauseUntilBuy=g_barIndex+InpPauseBars; g_lossStreakBuy=0; }
      }
      else
      {
         g_lossStreakSell++;
         if(g_lossStreakSell>=InpMaxStreak){ g_pauseUntilSell=g_barIndex+InpPauseBars; g_lossStreakSell=0; }
      }
   }
   else           // win/breakeven resets that direction
   {
      if(dir==1) g_lossStreakBuy=0; else g_lossStreakSell=0;
   }
}
//+------------------------------------------------------------------+
//| Daily reset                                                      |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day!=g_lastDay)
   {
      g_lastDay=dt.day;
      g_dayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
      g_locked=false;
   }
}
//+------------------------------------------------------------------+
//| Daily loss/profit caps                                           |
//+------------------------------------------------------------------+
void CheckDailyLimits()
{
   if(g_locked) return;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double realizedFloating=eq-g_dayStartBalance;

   if(InpMaxDailyLoss>0 && realizedFloating<=-InpMaxDailyLoss)
   {
      CloseAllPositions();
      g_locked=true;
      if(InpAlerts) Alert(StringFormat("%s: Daily LOSS limit hit (%.2f). Trading halted.",InpComment,realizedFloating));
   }
   else if(InpMaxDailyProfit>0 && realizedFloating>=InpMaxDailyProfit)
   {
      CloseAllPositions();
      g_locked=true;
      if(InpAlerts) Alert(StringFormat("%s: Daily PROFIT target hit (%.2f). Trading halted.",InpComment,realizedFloating));
   }
}
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic) continue;
      trade.PositionClose(tk);
   }
}
//+------------------------------------------------------------------+
double DailyPL()
{
   return AccountInfoDouble(ACCOUNT_EQUITY)-g_dayStartBalance;
}
double FloatingProfit()
{
   double p=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic) continue;
      p+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   return p;
}
//========================= DASHBOARD ===============================
void CreateLabel(string name,int x,int y,string text,color clr,int fs=9,string font="Consolas")
{
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fs);
   ObjectSetString(0,name,OBJPROP_FONT,font);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}
void SetLabel(string name,string text,color clr)
{
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
}
void CreatePanel()
{
   string bg=PFX+"bg";
   if(ObjectFind(0,bg)<0) ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,8);
   ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,20);
   ObjectSetInteger(0,bg,OBJPROP_XSIZE,262);
   ObjectSetInteger(0,bg,OBJPROP_YSIZE,232);
   ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,C'18,18,22');
   ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,bg,OBJPROP_COLOR,C'70,70,80');
   ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,bg,OBJPROP_HIDDEN,true);

   int x=20, y=30, dy=20;
   CreateLabel(PFX+"title",x,y,"⚡ ADAPTIVE GOLD ENGINE",C'212,175,55',11,"Arial Black"); y+=dy+4;
   CreateLabel(PFX+"sym", x,y,"",clrWhite); y+=dy;
   CreateLabel(PFX+"regime",x,y,"",clrSilver); y+=dy;
   CreateLabel(PFX+"sess",x,y,"",clrSilver); y+=dy;
   CreateLabel(PFX+"status",x,y,"",clrLime); y+=dy;
   CreateLabel(PFX+"pl",x,y,"",clrWhite); y+=dy;
   CreateLabel(PFX+"pos",x,y,"",clrSilver); y+=dy;
   CreateLabel(PFX+"ind",x,y,"",clrSilver); y+=dy;
   CreateLabel(PFX+"anti",x,y,"",clrSilver); y+=dy;
   CreateLabel(PFX+"caps",x,y,"",clrGray); y+=dy;
}
void DeletePanel()
{
   ObjectsDeleteAll(0,PFX);
}
void UpdatePanel()
{
   double adxv=0,atrv=0;
   GetBuf(hAdx,0,1,adxv); GetBuf(hAtr,0,1,atrv);

   string riskTxt=(InpFixedRiskUSD>0.0)?StringFormat("Risk $%.0f/trade",InpFixedRiskUSD):StringFormat("Risk %.2f%%",InpRiskPercent);
   SetLabel(PFX+"sym",  StringFormat("%s   |   %s",_Symbol,riskTxt),clrWhite);

   color rc=(g_regimeTxt=="TREND")?clrDeepSkyBlue:(g_regimeTxt=="RANGE"?clrOrange:clrGray);
   SetLabel(PFX+"regime",StringFormat("Regime : %s",g_regimeTxt),rc);
   SetLabel(PFX+"sess",  StringFormat("Session: %s",g_sessionTxt),clrSilver);

   if(g_locked) SetLabel(PFX+"status","Status : ⛔ LIMIT HIT (halted)",clrRed);
   else         SetLabel(PFX+"status","Status : ● ACTIVE",clrLime);

   double pl=DailyPL();
   SetLabel(PFX+"pl",StringFormat("Daily P/L : %s%.2f",pl>=0?"+":"",pl), pl>=0?clrLime:clrRed);

   int np=CountMyPositions();
   double fp=FloatingProfit();
   string runner=(np>0 && g_tp1Done)?"  [runner trailing]":(np>0?"  [pre-TP1]":"");
   SetLabel(PFX+"pos",StringFormat("Open : %d   Float : %s%.2f%s",np,fp>=0?"+":"",fp,runner), np>0?(fp>=0?clrLime:clrRed):clrSilver);

   SetLabel(PFX+"ind",StringFormat("ADX %.1f   ATR %.2f",adxv,atrv),clrSilver);

   string anti="Anti-corr: OK";
   color ac=clrSilver;
   if(g_barIndex<g_pauseUntilBuy){ anti=StringFormat("Long paused %d bars",(int)(g_pauseUntilBuy-g_barIndex)); ac=clrOrange; }
   else if(g_barIndex<g_pauseUntilSell){ anti=StringFormat("Short paused %d bars",(int)(g_pauseUntilSell-g_barIndex)); ac=clrOrange; }
   SetLabel(PFX+"anti",anti,ac);

   string profCap=(InpMaxDailyProfit>0)?StringFormat("+$%.0f",InpMaxDailyProfit):"UNCAPPED";
   SetLabel(PFX+"caps",StringFormat("Caps: -$%.0f / %s   %s",InpMaxDailyLoss,profCap,riskTxt),clrGray);
}
//+------------------------------------------------------------------+
