//+------------------------------------------------------------------+
//|                                          StepIndexTickScalp.mq5  |
//|   TP/SL in POINTS. Broker-safe stop placement.                    |
//+------------------------------------------------------------------+
#property copyright "Step Index Tick Scalp"
#property version   "1.20"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs
input int    Trigger_Ticks     = 2;       // Consecutive ticks to trigger entry
input int    TP_Points         = 15;      // Take profit in POINTS
input int    SL_Points         = 60;      // Stop loss in POINTS
input int    TickLookback      = 20;      // Recent ticks to pull each time
input double Lot_Size          = 0.10;    // Lot size
input ulong  Magic_Number      = 20260921;// Magic number

//--- Globals
double   point          = 0.0;
double   tickSize       = 0.0;
int      digits         = 0;
long     stopsLevel     = 0;
long     freezeLevel    = 0;
double   minStopDist    = 0.0;   // in price units
datetime lastProcessedTickTime = 0;
double   lastProcessedPrice    = 0.0;

//+------------------------------------------------------------------+
int OnInit()
{
   point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(tickSize <= 0.0) tickSize = point;

   stopsLevel  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   double minByStops  = (double)stopsLevel  * point;
   double minByFreeze = (double)freezeLevel * point;
   minStopDist = MathMax(minByStops, minByFreeze);

   // Add a small safety buffer (some brokers are finicky)
   minStopDist += point;

   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol);

   PrintFormat("Init | Point=%.5f | TickSize=%.5f | Digits=%d | StopsLevel=%d pts | Freeze=%d pts | MinStopDist=%.5f (%.0f pts)",
               point, tickSize, digits,
               (int)stopsLevel, (int)freezeLevel,
               minStopDist, minStopDist / point);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) { }

//+------------------------------------------------------------------+
//| Snap a price to the nearest valid tick                           |
//+------------------------------------------------------------------+
double AlignToTick(double price)
{
   if(tickSize <= 0.0) return NormalizeDouble(price, digits);
   double snapped = MathRound(price / tickSize) * tickSize;
   return NormalizeDouble(snapped, digits);
}

//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Magic_Number) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
int CountConsecutiveTicks(const MqlTick &ticks[], int count)
{
   if(count < 2) return 0;

   int consecutive = 0;
   int direction   = 0;

   for(int i = count - 1; i > 0; i--)
   {
      double curr = (ticks[i].bid   + ticks[i].ask)   / 2.0;
      double prev = (ticks[i-1].bid + ticks[i-1].ask) / 2.0;

      int dir = 0;
      if(curr > prev)      dir =  1;
      else if(curr < prev) dir = -1;
      else continue;

      if(direction == 0)      { direction = dir; consecutive = 1; }
      else if(dir == direction) consecutive++;
      else break;
   }
   return direction * consecutive;
}

//+------------------------------------------------------------------+
//| Build TP/SL prices for a given direction, respecting broker      |
//+------------------------------------------------------------------+
bool BuildStops(bool isBuy, double entry, double &tp, double &sl)
{
   double tpDist = TP_Points * point;
   double slDist = SL_Points * point;

   // Enforce broker minimum
   if(tpDist < minStopDist) tpDist = minStopDist;
   if(slDist < minStopDist) slDist = minStopDist;

   if(isBuy)
   {
      tp = AlignToTick(entry + tpDist);
      sl = AlignToTick(entry - slDist);
      if(tp <= entry || sl >= entry)
      {
         PrintFormat("BUY stops invalid: entry=%.*f tp=%.*f sl=%.*f",
                     digits, entry, digits, tp, digits, sl);
         return false;
      }
   }
   else
   {
      tp = AlignToTick(entry - tpDist);
      sl = AlignToTick(entry + slDist);
      if(tp >= entry || sl <= entry)
      {
         PrintFormat("SELL stops invalid: entry=%.*f tp=%.*f sl=%.*f",
                     digits, entry, digits, tp, digits, sl);
         return false;
      }
   }
   return true;
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick ticks[];
   int copied = CopyTicks(_Symbol, ticks, COPY_TICKS_ALL, 0, TickLookback);
   if(copied < 3) return;

   datetime lastTime = ticks[copied - 1].time;
   double   lastPx   = (ticks[copied - 1].bid + ticks[copied - 1].ask) / 2.0;
   if(lastTime == lastProcessedTickTime && lastPx == lastProcessedPrice)
      return;
   lastProcessedTickTime = lastTime;
   lastProcessedPrice    = lastPx;

   if(CountPositions() > 0) return;

   int streak = CountConsecutiveTicks(ticks, copied);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- BUY
   if(streak >= Trigger_Ticks)
   {
      double tp, sl;
      if(!BuildStops(true, ask, tp, sl)) return;

      if(trade.Buy(Lot_Size, _Symbol, ask, sl, tp, "TickScalp Buy"))
         PrintFormat("BUY  | streak=+%d | entry=%.*f | TP=%.*f (%.0f pts) | SL=%.*f (%.0f pts)",
                     streak, digits, ask, digits, tp, (tp-ask)/point, digits, sl, (ask-sl)/point);
      else
         PrintFormat("BUY failed retcode=%d desc=%s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
   }

   //--- SELL
   if(streak <= -Trigger_Ticks)
   {
      double tp, sl;
      if(!BuildStops(false, bid, tp, sl)) return;

      if(trade.Sell(Lot_Size, _Symbol, bid, sl, tp, "TickScalp Sell"))
         PrintFormat("SELL | streak=%d | entry=%.*f | TP=%.*f (%.0f pts) | SL=%.*f (%.0f pts)",
                     streak, digits, bid, digits, tp, (bid-tp)/point, digits, sl, (sl-bid)/point);
      else
         PrintFormat("SELL failed retcode=%d desc=%s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
   }
}
//+------------------------------------------------------------------+
