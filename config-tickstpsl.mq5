//+------------------------------------------------------------------+
//|                                        TickScalper1TP6SL.mq5     |
//|                             2-tick entry, 1-tick TP, 6-tick SL   |
//+------------------------------------------------------------------+
#property copyright "Tick Scalper"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs
input int    Trigger_Ticks     = 2;       // Consecutive ticks to trigger entry
input int    TP_Ticks          = 1;       // Take profit in ticks (change to 2,3,...)
input int    SL_Ticks          = 6;       // Stop loss in ticks
input bool   Use_EMA_Filter    = true;    // Require price on correct side of EMA
input int    EMA_Period        = 9;       // EMA period on M1
input double Lot_Size          = 0.10;    // Lot size
input ulong  Magic_Number      = 20241102;// Magic number

//--- Globals
int      emaHandle     = INVALID_HANDLE;
double   lastTickPrice = 0.0;
int      upTickCount   = 0;
int      downTickCount = 0;
double   tickSize      = 0.0;   // one tick in price units
int      tickDigits    = 0;     // digits for normalizing stop/TP prices

//+------------------------------------------------------------------+
int OnInit()
{
   if(TP_Ticks < 1 || SL_Ticks < 1 || Trigger_Ticks < 1)
   {
      Print("Invalid input: ticks must be >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Resolve tick size (prefer broker's trade tick size)
   tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      tickSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   tickDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(Use_EMA_Filter)
   {
      emaHandle = iMA(_Symbol, PERIOD_M1, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
      if(emaHandle == INVALID_HANDLE)
      {
         Print("Failed to create EMA handle");
         return INIT_FAILED;
      }
   }

   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol);

   lastTickPrice = 0.0;
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(emaHandle != INVALID_HANDLE)
      IndicatorRelease(emaHandle);
}

//+------------------------------------------------------------------+
//| Normalize price to broker digits                                 |
//+------------------------------------------------------------------+
double NormPrice(double p)
{
   return NormalizeDouble(p, tickDigits);
}

//+------------------------------------------------------------------+
//| Get last closed M1 EMA                                            |
//+------------------------------------------------------------------+
double GetEMA()
{
   if(emaHandle == INVALID_HANDLE) return 0.0;
   double buf[];
   if(CopyBuffer(emaHandle, 0, 0, 2, buf) < 2) return 0.0;
   return buf[1]; // last closed bar
}

//+------------------------------------------------------------------+
//| Count positions for this EA                                       |
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
//| Reset tick counters                                               |
//+------------------------------------------------------------------+
void ResetCounters()
{
   upTickCount   = 0;
   downTickCount = 0;
}

//+------------------------------------------------------------------+
//| Tick handler                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) / 2.0;

   //--- First tick after init
   if(lastTickPrice == 0.0)
   {
      lastTickPrice = mid;
      return;
   }

   //--- Tick direction
   int dir = 0;
   if(mid > lastTickPrice)      dir =  1;
   else if(mid < lastTickPrice) dir = -1;
   lastTickPrice = mid;

   if(dir == 1)
   {
      upTickCount++;
      downTickCount = 0;
   }
   else if(dir == -1)
   {
      downTickCount++;
      upTickCount = 0;
   }
   else
   {
      return; // unchanged tick, skip
   }

   //--- If a position is open, TP/SL handles the exit. Do nothing.
   if(CountPositions() > 0)
      return;

   //--- EMA filter
   double ema = 0.0;
   if(Use_EMA_Filter)
   {
      ema = GetEMA();
      if(ema <= 0.0) return;
   }

   //--- Entry: BUY on N consecutive up ticks
   if(upTickCount >= Trigger_Ticks)
   {
      if(Use_EMA_Filter && !(ask > ema)) return;

      double tp = NormPrice(ask + TP_Ticks * tickSize);
      double sl = NormPrice(ask - SL_Ticks * tickSize);

      if(trade.Buy(Lot_Size, _Symbol, ask, sl, tp, "TickScalp Buy"))
      {
         ResetCounters();
         PrintFormat("BUY @ %.*f | TP %.*f | SL %.*f | upTicks=%d",
                     tickDigits, ask, tickDigits, tp, tickDigits, sl, upTickCount);
      }
      return;
   }

   //--- Entry: SELL on N consecutive down ticks
   if(downTickCount >= Trigger_Ticks)
   {
      if(Use_EMA_Filter && !(bid < ema)) return;

      double tp = NormPrice(bid - TP_Ticks * tickSize);
      double sl = NormPrice(bid + SL_Ticks * tickSize);

      if(trade.Sell(Lot_Size, _Symbol, bid, sl, tp, "TickScalp Sell"))
      {
         ResetCounters();
         PrintFormat("SELL @ %.*f | TP %.*f | SL %.*f | downTicks=%d",
                     tickDigits, bid, tickDigits, tp, tickDigits, sl, downTickCount);
      }
      return;
   }
}
//+------------------------------------------------------------------+
