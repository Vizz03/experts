//+------------------------------------------------------------------+
//|                                              TickScalper9EMA.mq5 |
//|                                              Consecutive Ticks   |
//+------------------------------------------------------------------+
#property copyright "Tick Scalper"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs
input int    EMA_Period        = 9;      // EMA period on M1
input int    Up_Ticks_Entry    = 3;      // Consecutive up ticks to BUY
input int    Down_Ticks_Entry  = 3;      // Consecutive down ticks to SELL
input int    Exit_Ticks        = 2;      // Consecutive opposite ticks to close
input double Lot_Size          = 0.10;   // Lot size
input ulong  Magic_Number      = 20241101;// Magic number

//--- Globals
int      emaHandle = INVALID_HANDLE;
double   lastTickPrice = 0.0;
int      upTickCount   = 0;
int      downTickCount = 0;
int      exitUpCount   = 0;   // consecutive up ticks while in a SELL
int      exitDownCount = 0;   // consecutive down ticks while in a BUY
datetime lastBarTime   = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   emaHandle = iMA(_Symbol, PERIOD_M1, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE)
   {
      Print("Failed to create EMA handle");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(5);

   lastTickPrice = 0.0;
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(emaHandle != INVALID_HANDLE)
      IndicatorRelease(emaHandle);
}

//+------------------------------------------------------------------+
//| Get the current EMA value on M1 (last closed bar)                |
//+------------------------------------------------------------------+
double GetEMA()
{
   double buf[];
   if(CopyBuffer(emaHandle, 0, 0, 2, buf) < 2)
      return 0.0;
   // Use last closed bar (index 1) to avoid repaint during current bar
   return buf[1];
}

//+------------------------------------------------------------------+
//| Count open positions for this EA                                 |
//+------------------------------------------------------------------+
int CountPositions(ENUM_POSITION_TYPE &type)
{
   int count = 0;
   type = (ENUM_POSITION_TYPE)-1;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Magic_Number) continue;
      type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Close all positions of this EA                                   |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Magic_Number) continue;
      trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| Tick handler - main logic                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) / 2.0;

   //--- First tick after init: just record price
   if(lastTickPrice == 0.0)
   {
      lastTickPrice = mid;
      return;
   }

   //--- Determine tick direction
   int dir = 0;
   if(mid > lastTickPrice)      dir =  1;
   else if(mid < lastTickPrice) dir = -1;
   // dir == 0 means unchanged -> ignore, don't reset counters
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
      return; // no price change, skip this tick
   }

   //--- Manage open position first
   ENUM_POSITION_TYPE posType;
   int posCount = CountPositions(posType);

   if(posCount > 0)
   {
      if(posType == POSITION_TYPE_BUY)
      {
         // Exit BUY on N consecutive down ticks
         if(dir == -1)
         {
            exitDownCount++;
            exitUpCount = 0;
            if(exitDownCount >= Exit_Ticks)
            {
               CloseAllPositions();
               ResetCounters();
               return;
            }
         }
         else
         {
            exitUpCount++;
            exitDownCount = 0;
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         // Exit SELL on N consecutive up ticks
         if(dir == 1)
         {
            exitUpCount++;
            exitDownCount = 0;
            if(exitUpCount >= Exit_Ticks)
            {
               CloseAllPositions();
               ResetCounters();
               return;
            }
         }
         else
         {
            exitDownCount++;
            exitUpCount = 0;
         }
      }
      return; // already in a trade, don't look for entries
   }

   //--- No position: look for entry (only one trade at a time)
   double ema = GetEMA();
   if(ema <= 0.0) return;

   double price = ask; // reference for entry decision (use ask for buys, bid for sells)

   //--- BUY setup: price above 9 EMA on M1 + 3 consecutive up ticks
   if(price > ema && upTickCount >= Up_Ticks_Entry)
   {
      if(trade.Buy(Lot_Size, _Symbol, ask, 0, 0, "TickScalp Buy"))
      {
         ResetCounters();
         Print("BUY opened at ", ask, " | EMA=", ema, " | upTicks=", upTickCount);
      }
      return;
   }

   //--- SELL setup: price below 9 EMA on M1 + 3 consecutive down ticks
   if(price < ema && downTickCount >= Down_Ticks_Entry)
   {
      if(trade.Sell(Lot_Size, _Symbol, bid, 0, 0, "TickScalp Sell"))
      {
         ResetCounters();
         Print("SELL opened at ", bid, " | EMA=", ema, " | downTicks=", downTickCount);
      }
      return;
   }
}

//+------------------------------------------------------------------+
//| Reset tick counters                                              |
//+------------------------------------------------------------------+
void ResetCounters()
{
   upTickCount   = 0;
   downTickCount = 0;
   exitUpCount   = 0;
   exitDownCount = 0;
}
//+------------------------------------------------------------------+
