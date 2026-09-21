//+------------------------------------------------------------------+
//|                                          StepIndexTickScalp.mq5  |
//|   Runs on M1 chart. Uses CopyTicks() to analyze raw ticks         |
//|   internally. No tick chart required.                             |
//+------------------------------------------------------------------+
#property copyright "Step Index Tick Scalp"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs
input int    Trigger_Ticks     = 2;       // Consecutive ticks to trigger entry
input int    TP_Ticks          = 1;       // Take profit in ticks
input int    SL_Ticks          = 6;       // Stop loss in ticks
input int    TickLookback      = 20;      // How many recent ticks to pull each time
input double Lot_Size          = 0.10;    // Lot size
input ulong  Magic_Number      = 20260921;// Magic number

//--- Globals
double   tickSize       = 0.0;
int      tickDigits     = 0;
datetime lastProcessedTickTime = 0;
double   lastProcessedPrice    = 0.0;

//+------------------------------------------------------------------+
int OnInit()
{
   tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      tickSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   tickDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol);

   PrintFormat("StepIndexTickScalp init | TickSize=%.5f | Digits=%d | Trigger=%d | TP=%d | SL=%d",
               tickSize, tickDigits, Trigger_Ticks, TP_Ticks, SL_Ticks);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) { }

//+------------------------------------------------------------------+
double NormPrice(double p) { return NormalizeDouble(p, tickDigits); }

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
//| Count consecutive tick moves from the recent tick array          |
//| Returns: positive = consecutive UP ticks, negative = DOWN        |
//+------------------------------------------------------------------+
int CountConsecutiveTicks(const MqlTick &ticks[], int count)
{
   if(count < 2) return 0;

   int consecutive = 0;
   int direction   = 0;

   // Walk backwards from the most recent tick
   for(int i = count - 1; i > 0; i--)
   {
      double curr = (ticks[i].bid + ticks[i].ask) / 2.0;
      double prev = (ticks[i-1].bid + ticks[i-1].ask) / 2.0;

      int dir = 0;
      if(curr > prev)      dir =  1;
      else if(curr < prev) dir = -1;
      else continue; // unchanged tick, skip

      if(direction == 0)
      {
         direction   = dir;
         consecutive = 1;
      }
      else if(dir == direction)
      {
         consecutive++;
      }
      else
      {
         break;
      }
   }

   return direction * consecutive;
}

//+------------------------------------------------------------------+
void OnTick()
{
   //--- Pull recent ticks regardless of chart timeframe
   MqlTick ticks[];
   int copied = CopyTicks(_Symbol, ticks, COPY_TICKS_ALL, 0, TickLookback);
   if(copied < 3)
      return;

   //--- Avoid reprocessing the same last tick repeatedly
   datetime lastTime = ticks[copied - 1].time;
   double   lastPx   = (ticks[copied - 1].bid + ticks[copied - 1].ask) / 2.0;
   if(lastTime == lastProcessedTickTime && lastPx == lastProcessedPrice)
      return;
   lastProcessedTickTime = lastTime;
   lastProcessedPrice    = lastPx;

   //--- Already in a position — TP/SL handles exit
   if(CountPositions() > 0)
      return;

   int streak = CountConsecutiveTicks(ticks, copied);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- BUY on N consecutive UP ticks
   if(streak >= Trigger_Ticks)
   {
      double tp = NormPrice(ask + TP_Ticks * tickSize);
      double sl = NormPrice(ask - SL_Ticks * tickSize);
      if(trade.Buy(Lot_Size, _Symbol, ask, sl, tp, "TickScalp Buy"))
      {
         PrintFormat("BUY  | streak=+%d | entry=%.*f | TP=%.*f | SL=%.*f",
                     streak, tickDigits, ask, tickDigits, tp, tickDigits, sl);
      }
      return;
   }

   //--- SELL on N consecutive DOWN ticks
   if(streak <= -Trigger_Ticks)
   {
      double tp = NormPrice(bid - TP_Ticks * tickSize);
      double sl = NormPrice(bid + SL_Ticks * tickSize);
      if(trade.Sell(Lot_Size, _Symbol, bid, sl, tp, "TickScalp Sell"))
      {
         PrintFormat("SELL | streak=%d | entry=%.*f | TP=%.*f | SL=%.*f",
                     streak, tickDigits, bid, tickDigits, tp, tickDigits, sl);
      }
      return;
   }
}
//+------------------------------------------------------------------+
