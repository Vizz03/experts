//+------------------------------------------------------------------+
//|                                                  EMA_ADX_Breakout.mq5 |
//|                                  Copyright 2026, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh> // Include standard trade library

//--- Input Parameters
input int      InpEmaPeriod     = 21;       // EMA Period
input int      InpAdxPeriod     = 14;       // ADX Period
input double   InpAdxThreshold  = 25.0;     // ADX Threshold (Trend Strength)
input double   InpLotSize       = 0.01;     // Lot Size (Minimum)

//--- Global Variables
int            handleEma;                   // EMA Indicator Handle
int            handleAdx;                   // ADX Indicator Handle
CTrade         trade;                       // Trading object

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // 1. Initialize Indicator Handles
   handleEma = iMA(_Symbol, _Period, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   // Create ADX handle. The 4th parameter (applied_price) is not used for ADX standard, but MQL5 requires it. 
   // We use PRICE_CLOSE as a placeholder.
   handleAdx = iADX(_Symbol, _Period, InpAdxPeriod); 

   if(handleEma == INVALID_HANDLE || handleAdx == INVALID_HANDLE)
     {
      Print("Error creating indicator handles");
      return(INIT_FAILED);
     }

   // 2. Configure the trade object
   // Ensure the lot size is set. Even if you pass it in OrderSend, good to set defaults.
   trade.SetExpertMagicNumber(123456); // Unique Magic Number
   trade.SetDeviationInPoints(10);      // Slippage
   trade.SetTypeFillingBySymbol(_Symbol); 

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Release indicator handles
   if(handleEma != INVALID_HANDLE) IndicatorRelease(handleEma);
   if(handleAdx != INVALID_HANDLE) IndicatorRelease(handleAdx);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Check for New Bar
   // We only want to execute logic once per candle close to avoid multiple signals on the same bar.
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   
   if(currentBarTime == lastBarTime)
     {
      return; // We are still on the same bar, do nothing
     }
   
   // A new bar has appeared. The "previous" bar (index 1) is now fully closed.
   // Note: In MT5, index 0 is the currently forming bar. Index 1 is the last closed bar.
   // The user wants to check if the "current candle" closes above "previous candle high".
   // This means we check the CLOSED bar (index 1) against the bar before it (index 2).
   // If the user meant the live forming bar, we would check index 0 vs 1, but standard EAs use closed bars.
   
   // We use Index 1 (Last Closed Candle) and Index 2 (Previous to that)
   double lastClose = iClose(_Symbol, _Period, 1);
   double prevHigh  = iHigh(_Symbol, _Period, 2);
   double prevLow   = iLow(_Symbol, _Period, 2);
   
   if(lastClose == 0 || prevHigh == 0 || prevLow == 0) return; // Data not ready

   // Update last bar time
   lastBarTime = currentBarTime;

   // 2. Get Indicator Values (EMA and ADX)
   // We need the values of the closed bar (index 1) to confirm the signal
   double emaBuffer[1];
   double adxBuffer[1];
   
   // CopyBuffer(handle, buffer_num, start_pos, count, array)
   // start_pos = 1 (last closed bar)
   if(CopyBuffer(handleEma, 0, 1, 1, emaBuffer) < 1) return;
   if(CopyBuffer(handleAdx, 0, 1, 1, adxBuffer) < 1) return; // Buffer 0 is ADX Main line

   double emaValue = emaBuffer[0];
   double adxValue = adxBuffer[0];

   // 3. Manage Existing Positions (Exit Logic)
   ManagePositions(lastClose, prevHigh, prevLow);

   // 4. Check for Entry (Only if no positions open)
   if(PositionsTotal() == 0)
     {
      // Filter: ADX must be above threshold
      if(adxValue >= InpAdxThreshold)
        {
         // Buy Condition: Close > EMA AND Close > Previous Candle High
         if(lastClose > emaValue && lastClose > prevHigh)
           {
            ExecuteBuy();
           }
         // Sell Condition: Close < EMA AND Close < Previous Candle Low
         else if(lastClose < emaValue && lastClose < prevLow)
           {
            ExecuteSell();
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Close positions based on the specific exit criteria              |
//+------------------------------------------------------------------+
void ManagePositions(double lastClose, double prevHigh, double prevLow)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionSelectByTicket(ticket))
        {
         // Ensure we are only managing our own positions
         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != 123456)
            continue;

         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         // Exit for BUY: Close < Previous Low (The low of the candle before the last closed one)
         if(type == POSITION_TYPE_BUY)
           {
            if(lastClose < prevLow)
              {
               trade.PositionClose(ticket);
              }
           }
         // Exit for SELL: Close > Previous High
         else if(type == POSITION_TYPE_SELL)
           {
            if(lastClose > prevHigh)
              {
               trade.PositionClose(ticket);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Helper: Execute Buy Order                                        |
//+------------------------------------------------------------------+
void ExecuteBuy()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lot = InpLotSize;

   // Ensure lot is at least the symbol's minimum
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lot < minLot) lot = minLot;

   // Normalize lot size
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;

   if(trade.Buy(lot, _Symbol, ask, 0, 0, "EMA_ADX_Breakout"))
     {
      Print("Buy order opened successfully");
     }
   else
     {
      Print("Buy order failed. Error: ", GetLastError());
     }
  }

//+------------------------------------------------------------------+
//| Helper: Execute Sell Order                                       |
//+------------------------------------------------------------------+
void ExecuteSell()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = InpLotSize;

   // Ensure lot is at least the symbol's minimum
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lot < minLot) lot = minLot;

   // Normalize lot size
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;

   if(trade.Sell(lot, _Symbol, bid, 0, 0, "EMA_ADX_Breakout"))
     {
      Print("Sell order opened successfully");
     }
   else
     {
      Print("Sell order failed. Error: ", GetLastError());
     }
  }
//+------------------------------------------------------------------+
