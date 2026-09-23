//+------------------------------------------------------------------+
//|                                        PulseStrike_Scalper.mq5   |
//|                                                                    |
//| PulseStrike — a tick-driven fast scalper.                          |
//|                                                                    |
//| Unlike the bar-close-based SMC EA, this one reacts on every tick,   |
//| not every candle close, so it can enter/exit multiple times per     |
//| minute when the market is active. Meant to be run on an M1 chart.  |
//|                                                                    |
//| The signal: it watches price over a short rolling window           |
//| (InpBurstWindowSeconds) and keeps a running history of the last     |
//| InpStatsSampleCount completed window-returns for this symbol, to    |
//| build an empirical picture of what a "normal" move over that        |
//| window actually looks like right now. The current window's move is  |
//| then converted to a z-score against that history, and only counted  |
//| as a burst if it's a genuine statistical outlier (InpZScoreThreshold|
//| standard deviations away). This replaced an earlier version that    |
//| compared the move to a fixed fraction of ATR — testing showed that   |
//| version was firing on ordinary tick noise (thousands of trades,      |
//| catastrophic drawdown on every major pair), because a quarter of a   |
//| bar's ATR happening in a few seconds isn't actually unusual. A       |
//| proper z-score against the symbol's own recent behaviour is a much   |
//| stricter, self-adapting bar to clear.                                |
//| Two selectable hypotheses for what to do with a burst:              |
//|   - Momentum mode  : trade WITH the burst (bet it continues)        |
//|   - Reversion mode : trade AGAINST the burst (bet it snaps back)    |
//| Which one actually works is symbol/broker/regime-dependent — this   |
//| EA does not assume either is correct. Backtest both on your own     |
//| symbol before choosing.                                             |
//|                                                                    |
//| Cost-awareness (the thing that kills most naive fast scalpers):     |
//| the take-profit distance must be a meaningful multiple of the       |
//| current spread, or the setup is skipped outright — otherwise the    |
//| spread alone would eat the target before any edge matters.          |
//|                                                                    |
//| Safety: hard stop loss on every trade, a cooldown between entries,  |
//| a daily trade-count cap, and a daily loss limit that stops new      |
//| entries for the rest of the day. Exits are left entirely to the     |
//| broker's own SL/TP execution — there is no manual force-close.      |
//| An earlier version force-closed a trade after a fixed hold time,    |
//| but under emulated broker delay a manual close request could        |
//| collide with one already in flight, producing repeated rejections   |
//| during MQL5's validation. Removing it removed that failure mode      |
//| entirely, at the cost of no longer cutting a stagnant trade short.  |
//|                                                                    |
//| Design choice — one trade at a time, not several simultaneous:      |
//| most retail MT5 accounts run in netting mode, where a second        |
//| market order on the same symbol just merges into the existing       |
//| position instead of becoming a separate tracked trade. Rather than  |
//| ship something that silently behaves wrong on netting accounts,     |
//| this keeps one position open at a time but cycles it as fast as     |
//| the market and InpCooldownSeconds allow — which is what actually    |
//| delivers "many trades in a short time" without the account-type     |
//| landmine. True simultaneous multi-position trading needs a          |
//| hedging-mode account and is a natural Phase 2, not this version.    |
//|                                                                    |
//| IMPORTANT FOR TESTING: because this EA trades off ticks, only       |
//| backtest it with the Strategy Tester's "Every tick based on real    |
//| ticks" model. Any other model (Open prices only, even generic       |
//| "Every tick") will not reflect what this EA actually reacts to,     |
//| and real tick history is only reliably available for a broker's     |
//| more recent past — don't trust results from many years back.        |
//|                                                                    |
//| No strategy is guaranteed to be profitable. This gives you a        |
//| sound, cost-aware, risk-limited structure to test — not a promise.  |
//|                                                                    |
//| NOTE ON MQL5's AUTOMATIC VALIDATION: it always tests submissions    |
//| on EURUSD, H1 regardless of what timeframe the EA is meant for —    |
//| that's expected and not a sign the EA is broken on its intended     |
//| M1 usage.                                                            |
//+------------------------------------------------------------------+
#property copyright "Article demo EA"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

input group "=== Burst Detection (statistical) ==="
input int    InpBurstWindowSeconds    = 4;      // Rolling window (seconds) used to measure each move
input int    InpStatsSampleCount      = 120;    // How many past window-returns to keep as the statistical baseline
input double InpZScoreThreshold       = 3.0;    // Only trade if the current move is this many std. deviations from normal
input bool   InpModeIsMomentum        = true;   // true = trade WITH the burst (momentum), false = trade AGAINST it (reversion)

input group "=== Trade Management ==="
input int    InpVolATRPeriod          = 14;     // ATR period (current chart timeframe) — used for TP/SL sizing only
input double InpRiskPercent           = 0.5;    // Risk % of balance per trade
input double InpTakeProfitATRMult     = 0.35;   // Take profit distance, as a multiple of ATR
input double InpStopLossATRMult       = 0.55;   // Stop loss distance, as a multiple of ATR
input double InpMinTPToSpreadRatio    = 3.0;    // Reject entry if TP distance is less than (spread x this ratio)
input int    InpMaxSpreadPoints       = 20;     // Skip entry if current spread exceeds this (points)
input int    InpCooldownSeconds       = 5;      // Minimum gap between two entries
input int    InpSlippagePoints        = 5;      // Max allowed slippage (points)
input ulong  InpMagicNumber           = 771001; // Magic number

input group "=== Daily Safety Limits ==="
input int    InpMaxTradesPerDay       = 100;    // Hard cap on number of entries per day
input double InpDailyLossLimitPercent = 3.0;    // Stop opening new trades once today's loss reaches this % of the day's starting balance

input group "=== Session Filter (broker/server time) ==="
input bool   InpUseSessionFilter      = false;  // Restrict new entries to a server-time window
input int    InpSessionStartHour      = 7;      // Session start hour (0-23)
input int    InpSessionEndHour        = 20;     // Session end hour (0-23)

input group "=== Display ==="
input bool   InpDrawOnChart           = true;   // Show a live running scorecard on the chart

// ---- active trade ----
ulong    g_activeTicket  = 0;
datetime g_lastEntryTime = 0;

// ---- daily counters ----
string   g_currentDayKey   = "";
double   g_dayStartBalance = 0.0;
int      g_tradesToday     = 0;

// ---- scorecard ----
int g_totalTrades = 0, g_totalWins = 0;

// ---- tick buffer for burst detection ----
datetime g_tickTime[];
double   g_tickPrice[];

// ---- rolling history of completed window-returns, for the z-score baseline ----
double   g_burstReturns[];
datetime g_lastStatsSampleTime = 0;

// ---- indicator handle ----
int g_atrHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
      g_activeTicket = (ulong)PositionGetInteger(POSITION_TICKET);

   g_atrHandle = iATR(_Symbol, _Period, InpVolATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("Failed to create ATR indicator handle.");
      return(INIT_FAILED);
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
double GetPoint() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }

//+------------------------------------------------------------------+
//| Minimum distance (in price) the broker requires between the       |
//| current price and a stop level. ATR-based SL/TP can be tighter    |
//| than this on some symbols, which is what "Invalid stops" meant.   |
//+------------------------------------------------------------------+
double GetMinStopDistance(const string symbol)
  {
   double point       = SymbolInfoDouble(symbol, SYMBOL_POINT);
   long   stopsLevel  = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freezeLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long   minPoints   = MathMax(stopsLevel, freezeLevel);
   return minPoints * point;
  }

//+------------------------------------------------------------------+
double ValuePerPoint(const string symbol)
  {
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(tickSize <= 0.0)
      return 0.0;
   return tickValue * (point / tickSize);
  }

//+------------------------------------------------------------------+
double NormalizeLot(double lot, const string symbol)
  {
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return 0.0;

   lot = MathFloor(lot / step) * step;
   if(lot > maxLot)
      lot = maxLot;
   if(lot < minLot)
      lot = 0.0;
   return NormalizeDouble(lot, 2);
  }

//+------------------------------------------------------------------+
bool InSession()
  {
   if(!InpUseSessionFilter)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(InpSessionStartHour <= InpSessionEndHour)
      return (dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);

   return (dt.hour >= InpSessionStartHour || dt.hour < InpSessionEndHour);
  }

//+------------------------------------------------------------------+
double GetATR()
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) < 1)
      return 0.0;
   return buf[0];
  }

//+------------------------------------------------------------------+
void CheckDailyReset()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string todayKey = StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day);

   if(todayKey != g_currentDayKey)
     {
      g_currentDayKey   = todayKey;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_tradesToday     = 0;
     }
  }

//+------------------------------------------------------------------+
//| Append the current mid price to the rolling burst-detection buffer|
//+------------------------------------------------------------------+
void RecordTick()
  {
   double mid = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;

   int n = ArraySize(g_tickTime);
   ArrayResize(g_tickTime, n + 1);
   ArrayResize(g_tickPrice, n + 1);
   g_tickTime[n]  = TimeCurrent();
   g_tickPrice[n] = mid;

   while(ArraySize(g_tickTime) > 0 && g_tickTime[0] < TimeCurrent() - InpBurstWindowSeconds)
     {
      ArrayRemove(g_tickTime, 0, 1);
      ArrayRemove(g_tickPrice, 0, 1);
     }
  }

//+------------------------------------------------------------------+
//| Once per completed window, record its return into the baseline    |
//| history used to judge whether a NEW move is actually unusual       |
//+------------------------------------------------------------------+
void UpdateBurstStats()
  {
   if(ArraySize(g_tickPrice) < 2)
      return;
   if(TimeCurrent() - g_lastStatsSampleTime < InpBurstWindowSeconds)
      return;

   double windowReturn = g_tickPrice[ArraySize(g_tickPrice) - 1] - g_tickPrice[0];

   int n = ArraySize(g_burstReturns);
   ArrayResize(g_burstReturns, n + 1);
   g_burstReturns[n] = windowReturn;

   if(ArraySize(g_burstReturns) > InpStatsSampleCount)
      ArrayRemove(g_burstReturns, 0, ArraySize(g_burstReturns) - InpStatsSampleCount);

   g_lastStatsSampleTime = TimeCurrent();
  }

//+------------------------------------------------------------------+
//| How many standard deviations is currentMove from this symbol's    |
//| own recent distribution of window-returns? Returns false until     |
//| enough history has built up for a meaningful baseline.             |
//+------------------------------------------------------------------+
bool GetBurstZScore(double currentMove, double &zscore)
  {
   int n = ArraySize(g_burstReturns);
   if(n < 20)
      return false;

   double mean = 0.0;
   for(int i = 0; i < n; i++)
      mean += g_burstReturns[i];
   mean /= n;

   double variance = 0.0;
   for(int i = 0; i < n; i++)
      variance += (g_burstReturns[i] - mean) * (g_burstReturns[i] - mean);
   variance /= n;

   double stddev = MathSqrt(variance);
   if(stddev <= 0.0)
      return false;

   zscore = (currentMove - mean) / stddev;
   return true;
  }

//+------------------------------------------------------------------+
//| Close-time / result tracking for the single active position.      |
//| Exits are left entirely to the broker's own SL/TP execution — no  |
//| manual force-close. An earlier version force-closed a trade after |
//| InpMaxHoldSeconds, but a manual close request could collide with  |
//| a still-in-flight one under emulated broker delay (Random delay   |
//| in the tester), producing repeated "close order exists" / "close  |
//| to market" rejections during MQL5's validation. Removing the      |
//| manual close removes that entire failure mode.                    |
//+------------------------------------------------------------------+
void ManageOpenPosition()
  {
   if(g_activeTicket == 0)
      return;

   if(PositionSelectByTicket(g_activeTicket))
      return; // still open — wait for its own SL/TP

   double netProfit = 0.0;
   if(HistorySelectByPosition(g_activeTicket))
     {
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
        {
         ulong d = HistoryDealGetTicket(i);
         netProfit += HistoryDealGetDouble(d, DEAL_PROFIT)
                    + HistoryDealGetDouble(d, DEAL_SWAP)
                    + HistoryDealGetDouble(d, DEAL_COMMISSION);
        }
     }

   bool win = netProfit > 0.0;
   g_totalTrades++;
   if(win) g_totalWins++;

   PrintStats(netProfit, win);
   g_activeTicket = 0;
  }

//+------------------------------------------------------------------+
void PrintStats(double lastNet, bool win)
  {
   double rate = (g_totalTrades > 0) ? 100.0 * g_totalWins / g_totalTrades : 0.0;
   string msg = StringFormat("Last: %s (%.2f) | Total: %d trades, %d wins, %.1f%% | Today: %d trades",
                              win ? "WIN" : "LOSS", lastNet, g_totalTrades, g_totalWins, rate, g_tradesToday);
   Print(msg);
   if(InpDrawOnChart)
      Comment(msg);
  }

//+------------------------------------------------------------------+
//| Check for a burst and enter if all cost/risk/safety gates pass    |
//+------------------------------------------------------------------+
void TryEnter()
  {
   if(!InSession())
      return;
   if(g_tradesToday >= InpMaxTradesPerDay)
      return;
   if(AccountInfoDouble(ACCOUNT_BALANCE) - g_dayStartBalance <= -InpDailyLossLimitPercent / 100.0 * g_dayStartBalance)
      return;
   if(TimeCurrent() - g_lastEntryTime < InpCooldownSeconds)
      return;
   if(ArraySize(g_tickPrice) < 2)
      return;

   double currentMove = g_tickPrice[ArraySize(g_tickPrice) - 1] - g_tickPrice[0];
   double zscore = 0.0;
   if(!GetBurstZScore(currentMove, zscore))
      return; // not enough history yet to judge what's "unusual"

   if(MathAbs(zscore) < InpZScoreThreshold)
      return;

   double atr = GetATR();
   if(atr <= 0.0)
      return;

   bool burstIsUp = zscore > 0.0;
   bool wantBuy   = InpModeIsMomentum ? burstIsUp : !burstIsUp;

   double spreadPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPoints > InpMaxSpreadPoints)
      return;

   double point  = GetPoint();
   double tpDist = InpTakeProfitATRMult * atr;
   double slDist = InpStopLossATRMult * atr;

   // Never allow a stop tighter than what the broker requires — this is
   // what "Invalid stops" meant, regardless of price freshness.
   double minStopDist = GetMinStopDistance(_Symbol) * 1.5;
   slDist = MathMax(slDist, minStopDist);
   tpDist = MathMax(tpDist, minStopDist);

   if(tpDist < spreadPoints * point * InpMinTPToSpreadRatio)
      return;

   double valuePerPoint = ValuePerPoint(_Symbol);
   double slDistPoints  = slDist / point;
   if(valuePerPoint <= 0.0 || slDistPoints <= 0.0)
      return;

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;
   double lot        = NormalizeLot(riskAmount / (slDistPoints * valuePerPoint), _Symbol);
   if(lot <= 0.0)
      return;

   // Open with no SL/TP first, then attach them based on the ACTUAL fill
   // price. Pre-computing SL/TP off a price snapshot and sending them with
   // the order caused "Invalid stops" rejections under emulated broker
   // delay, because the market had moved by the time the order reached
   // the (simulated) server and the snapshot-based stops no longer matched
   // the real execution price.
   bool sent = wantBuy ? trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, "PulseStrike")
                       : trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, "PulseStrike");

   if(!sent)
     {
      PrintFormat("Order failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
     }

   if(!PositionSelect(_Symbol))
     {
      Print("Order sent but the resulting position could not be found.");
      return;
     }

   ulong  newTicket       = (ulong)PositionGetInteger(POSITION_TICKET);
   double actualOpenPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = wantBuy ? actualOpenPrice - slDist : actualOpenPrice + slDist;
   double tp = wantBuy ? actualOpenPrice + tpDist : actualOpenPrice - tpDist;

   if(!trade.PositionModify(newTicket, sl, tp))
     {
      // Never leave a position without a stop loss. If we can't protect
      // it, close it immediately rather than let it run unmanaged.
      PrintFormat("Failed to attach SL/TP (%d %s) — closing the position for safety.",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
      if(!trade.PositionClose(newTicket))
         Print("WARNING: could not close the unprotected position either.");
      return;
     }

   g_activeTicket  = newTicket;
   g_lastEntryTime = TimeCurrent();
   g_tradesToday++;
   PrintFormat("Entered %s (%s mode) at %.5f  SL %.5f  TP %.5f  lot %.2f",
               wantBuy ? "BUY" : "SELL", InpModeIsMomentum ? "momentum" : "reversion", actualOpenPrice, sl, tp, lot);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   CheckDailyReset();
   RecordTick();
   UpdateBurstStats();

   ManageOpenPosition();
   if(g_activeTicket != 0)
      return;

   TryEnter();
  }
//+------------------------------------------------------------------+
