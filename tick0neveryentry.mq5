//+------------------------------------------------------------------+
//|                                          TickEveryEntryEA.mq5     |
//|   Every up tick opens a BUY. Every down tick opens a SELL.        |
//|   TP/SL in POINTS. Configurable.                                  |
//+------------------------------------------------------------------+
#property copyright "Every Tick Entry"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs
input int    TP_Points         = 15;      // Take profit in POINTS
input int    SL_Points         = 60;      // Stop loss in POINTS
input double Lot_Size          = 0.10;    // Lot size per entry
input int    Max_Open_Positions= 50;      // Safety cap on concurrent positions
input ulong  Magic_Number      = 20260922;// Magic number

//--- Globals
double   point          = 0.0;
double   tickSize       = 0.0;
int      digits         = 0;
long     stopsLevel     = 0;
long     freezeLevel    = 0;
double   minStopDist    = 0.0;
double   lastMidPrice   = 0.0;

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
   minStopDist = MathMax(minByStops, minByFreeze) + point;

   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol);

   lastMidPrice = 0.0;

   PrintFormat("Init | Point=%.5f | TickSize=%.5f | Digits=%d | StopsLevel=%d pts | Freeze=%d pts | MinStopDist=%.5f (%.0f pts)",
               point, tickSize, digits,
               (int)stopsLevel, (int)freezeLevel,
               minStopDist, minStopDist / point);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) { }

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
bool BuildStops(bool isBuy, double entry, double &tp, double &sl)
{
   double tpDist = TP_Points * point;
   double slDist = SL_Points * point;

   if(tpDist < minStopDist) tpDist = minStopDist;
   if(slDist < minStopDist) slDist = minStopDist;

   if(isBuy)
   {
      tp = AlignToTick(entry + tpDist);
      sl = AlignToTick(entry - slDist);
      return (tp > entry && sl < entry);
   }
   else
   {
      tp = AlignToTick(entry - tpDist);
      sl = AlignToTick(entry + slDist);
      return (tp < entry && sl > entry);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) / 2.0;

   //--- First tick after init
   if(lastMidPrice == 0.0)
   {
      lastMidPrice = mid;
      return;
   }

   //--- No change, ignore
   if(mid == lastMidPrice)
      return;

   bool isUpTick = (mid > lastMidPrice);
   lastMidPrice = mid;

   //--- Safety cap
   if(CountPositions() >= Max_Open_Positions)
      return;

   //--- Open on tick direction
   if(isUpTick)
   {
      double tp, sl;
      if(!BuildStops(true, ask, tp, sl)) return;

      if(trade.Buy(Lot_Size, _Symbol, ask, sl, tp, "EveryTick Buy"))
         PrintFormat("BUY  @ %.*f | TP=%.*f (%.0f pts) | SL=%.*f (%.0f pts)",
                     digits, ask, digits, tp, (tp-ask)/point, digits, sl, (ask-sl)/point);
      else
         PrintFormat("BUY failed retcode=%d desc=%s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   else
   {
      double tp, sl;
      if(!BuildStops(false, bid, tp, sl)) return;

      if(trade.Sell(Lot_Size, _Symbol, bid, sl, tp, "EveryTick Sell"))
         PrintFormat("SELL @ %.*f | TP=%.*f (%.0f pts) | SL=%.*f (%.0f pts)",
                     digits, bid, digits, tp, (bid-tp)/point, digits, sl, (sl-bid)/point);
      else
         PrintFormat("SELL failed retcode=%d desc=%s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}
//+------------------------------------------------------------------+
