//+------------------------------------------------------------------+
//|                                           FVG_Trend_EA_v3.mq5 |
//|                                        Copyright 2026, Your Name |
//+------------------------------------------------------------------+
#property copyright "Your Name"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade     trade;
CSymbolInfo sym;

//--- Inputs
input group "=== Trend Settings ==="
input ENUM_TIMEFRAMES  InpTrendTF         = PERIOD_H1;    // Trend Timeframe
input int              InpFastEMA         = 21;           // Fast EMA period
input int              InpSlowEMA         = 50;           // Slow EMA period

input group "=== FVG Settings ==="
input ENUM_TIMEFRAMES  InpFvgTF           = PERIOD_M15;   // FVG Timeframe
input int              InpFvgLookback     = 100;          // Bars to scan for FVG
input double           InpMinFvgPips      = 3.0;          // Min FVG size (pips)
input int              InpMaxFvgAge       = 20;           // Max bars since FVG formed (freshness)

input group "=== Order Settings ==="
input double           InpLotSize         = 0.10;         // Lot size
input double           InpSLBufferPips    = 5.0;          // SL buffer beyond FVG (pips)
input int              InpMagic           = 20260603;     // Magic number

input group "=== Trade Management ==="
input bool             InpUseBreakEven    = true;         // Enable break-even
input double           InpBE_TriggerR     = 1.0;          // Move SL to BE at this R multiple
input double           InpBE_OffsetPips   = 2.0;          // Pips profit locked at BE

input bool             InpUseTrailing     = true;         // Enable trailing stop
input double           InpTrailStartR     = 1.5;          // Start trailing after this R multiple
input double           InpTrailDistancePips = 15.0;      // Trailing distance (pips)
input double           InpTrailStepPips   = 3.0;          // Min step to update SL (pips)

input group "=== General ==="
input bool             InpDrawFVG         = true;         // Draw FVG boxes
input bool             InpOnlyOneOrder    = true;         // Only one active order at a time
input bool             InpCancelOnViolation = true;       // Cancel pending if FVG violated

//--- Globals
datetime lastBarTime = 0;
string   OBJ_PREFIX  = "FVG_EA_";

//--- Fixed R:R
#define   TP_RR   3.0

//+------------------------------------------------------------------+
//| Structure for an FVG                                             |
//+------------------------------------------------------------------+
struct FVG
{
   double   high;
   double   low;
   datetime time1;
   datetime time2;
   int      barIndex;
   bool     isBullish;
   bool     isValid;
};

//+------------------------------------------------------------------+
//| Helper: pip size for the current symbol                          |
//+------------------------------------------------------------------+
double PipSize()
{
   int    dg    = Digits();
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (dg == 3 || dg == 5) ? point * 10.0 : point;
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(10);

   if(!sym.Name(_Symbol)) return(INIT_FAILED);
   sym.RefreshRates();

   if(InpFastEMA >= InpSlowEMA)
   {
      Print("Fast EMA must be smaller than Slow EMA");
      return(INIT_PARAMETERS_INCORRECT);
   }

   Print("FVG Trend EA v3 initialized on ", _Symbol);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, OBJ_PREFIX);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();

   if(InpCancelOnViolation) CheckPendingInvalidation();

   datetime currentBar = iTime(_Symbol, InpFvgTF, 0);
   if(currentBar == lastBarTime) return;
   lastBarTime = currentBar;

   int trend = GetTrend();
   if(trend == 0)
   {
      ObjectsDeleteAll(0, OBJ_PREFIX);
      return;
   }

   ObjectsDeleteAll(0, OBJ_PREFIX);

   FVG fvg;
   if(!FindMostRecentFVG(trend, fvg)) return;

   if(InpDrawFVG) DrawFVG(fvg);

   if(InpOnlyOneOrder && HasActiveOrderOrPosition()) return;

   PlacePendingOrder(trend, fvg);
}

//+------------------------------------------------------------------+
//| Trend detection: 1 = up, -1 = down, 0 = none                     |
//+------------------------------------------------------------------+
int GetTrend()
{
   int fastHandle = iMA(_Symbol, InpTrendTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   int slowHandle = iMA(_Symbol, InpTrendTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE)
      return 0;

   double fast[2], slow[2];
   bool okFast = (CopyBuffer(fastHandle, 0, 0, 2, fast) >= 2);
   bool okSlow = (CopyBuffer(slowHandle, 0, 0, 2, slow) >= 2);

   IndicatorRelease(fastHandle);
   IndicatorRelease(slowHandle);

   if(!okFast || !okSlow) return 0;

   if(fast[0] > slow[0] && fast[0] > fast[1]) return  1;
   if(fast[0] < slow[0] && fast[0] < fast[1]) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Find absolute most recent fresh FVG in trend direction           |
//+------------------------------------------------------------------+
bool FindMostRecentFVG(int trend, FVG &outFvg)
{
   double pip     = PipSize();
   double minSize = InpMinFvgPips * pip;

   FVG latestFVG;
   latestFVG.isValid = false;
   int oldestAllowed = InpFvgLookback - 2;

   for(int i = 1; i <= oldestAllowed; i++)
   {
      if(i > InpMaxFvgAge) break;

      double c1_high = iHigh(_Symbol, InpFvgTF, i+1);
      double c1_low  = iLow (_Symbol, InpFvgTF, i+1);
      double c3_high = iHigh(_Symbol, InpFvgTF, i-1);
      double c3_low  = iLow (_Symbol, InpFvgTF, i-1);

      if(c1_high == 0 || c3_high == 0) continue;

      //--- Bullish FVG
      if(trend == 1 && c3_low > c1_high)
      {
         if((c3_low - c1_high) < minSize) continue;

         latestFVG.low      = c1_high;
         latestFVG.high     = c3_low;
         latestFVG.time1    = iTime(_Symbol, InpFvgTF, i+1);
         latestFVG.time2    = iTime(_Symbol, InpFvgTF, i-1);
         latestFVG.barIndex = i;
         latestFVG.isBullish = true;
         latestFVG.isValid  = true;
         break; // Found the most recent matching FVG
      }

      //--- Bearish FVG
      if(trend == -1 && c3_high < c1_low)
      {
         if((c1_low - c3_high) < minSize) continue;

         latestFVG.high     = c1_low;
         latestFVG.low      = c3_high;
         latestFVG.time1    = iTime(_Symbol, InpFvgTF, i+1);
         latestFVG.time2    = iTime(_Symbol, InpFvgTF, i-1);
         latestFVG.barIndex = i;
         latestFVG.isBullish = false;
         latestFVG.isValid  = true;
         break; // Found the most recent matching FVG
      }
   }

   if(latestFVG.isValid)
   {
      outFvg = latestFVG;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Draw FVG rectangle                                               |
//+------------------------------------------------------------------+
void DrawFVG(const FVG &fvg)
{
   string name = OBJ_PREFIX + "Box_" + IntegerToString((int)fvg.time1);
   color clr = fvg.isBullish ? clrDodgerBlue : clrCrimson;

   if(ObjectFind(0, name) < 0)
   {
      datetime t2 = fvg.time2 + PeriodSeconds(InpFvgTF) * 5;
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, fvg.time1, fvg.high, t2, fvg.low);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
}

//+------------------------------------------------------------------+
//| Place pending limit order at FVG edge                            |
//+------------------------------------------------------------------+
void PlacePendingOrder(int trend, const FVG &fvg)
{
   sym.RefreshRates();

   double pip     = PipSize();
   double slBuf   = InpSLBufferPips * pip;
   int    dg      = Digits();

   double price, sl, tp;
   ENUM_ORDER_TYPE type;

   if(trend == 1)
   {
      price = NormalizeDouble(fvg.high, dg);
      sl    = NormalizeDouble(fvg.low - slBuf, dg);

      if(price >= sym.Ask()) return;

      double risk = price - sl;
      if(risk <= 0) return;
      tp = NormalizeDouble(price + risk * TP_RR, dg);
      type = ORDER_TYPE_BUY_LIMIT;
   }
   else
   {
      price = NormalizeDouble(fvg.low, dg);
      sl    = NormalizeDouble(fvg.high + slBuf, dg);

      if(price <= sym.Bid()) return;

      double risk = sl - price;
      if(risk <= 0) return;
      tp = NormalizeDouble(price - risk * TP_RR, dg);
      type = ORDER_TYPE_SELL_LIMIT;
   }

   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(MathAbs(price - sl) < minStop) return;

   if(!trade.OrderOpen(_Symbol, type, InpLotSize, 0.0, price, sl, tp,
                        ORDER_TIME_GTC, 0, "FVG_EA"))
   {
      PrintFormat("OrderOpen failed: %d - %s",
                  trade.ResultRetcode(), trade.ResultComment());
   }
   else
   {
      PrintFormat("Placed %s @ %.*f | SL: %.*f | TP: %.*f",
                  (type == ORDER_TYPE_BUY_LIMIT ? "BUY LIMIT" : "SELL LIMIT"),
                  dg, price, dg, sl, dg, tp);
   }
}

//+------------------------------------------------------------------+
//| Check pending orders validity                                    |
//+------------------------------------------------------------------+
void CheckPendingInvalidation()
{
   if(OrdersTotal() == 0) return;

   sym.RefreshRates();
   double pip = PipSize();

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      long type = OrderGetInteger(ORDER_TYPE);

      if(type == ORDER_TYPE_BUY_LIMIT)
      {
         double fvgLow = OrderGetDouble(ORDER_SL) + InpSLBufferPips * pip;
         double barLow = iLow(_Symbol, InpFvgTF, 1);

         if(barLow < fvgLow)
         {
            if(trade.OrderDelete(ticket))
               PrintFormat("Cancelled BUY LIMIT #%I64u - FVG violated", ticket);
         }
      }
      else if(type == ORDER_TYPE_SELL_LIMIT)
      {
         double fvgHigh = OrderGetDouble(ORDER_SL) - InpSLBufferPips * pip;
         double barHigh = iHigh(_Symbol, InpFvgTF, 1);

         if(barHigh > fvgHigh)
         {
            if(trade.OrderDelete(ticket))
               PrintFormat("Cancelled SELL LIMIT #%I64u - FVG violated", ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage open positions                                            |
//+------------------------------------------------------------------+
void ManagePositions()
{
   if(PositionsTotal() == 0) return;

   double pip = PipSize();
   int    dg  = Digits();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      sym.RefreshRates();
      double bid = sym.Bid();
      double ask = sym.Ask();

      double risk = MathAbs(entry - curSL);
      if(risk <= 0) continue;

      bool   isBuy        = (type == POSITION_TYPE_BUY);
      double currentPrice = isBuy ? bid : ask;
      double profit       = isBuy ? (currentPrice - entry) : (entry - currentPrice);
      double rMultiple    = profit / risk;

      double newSL    = curSL;
      bool   updateSL = false;

      if(InpUseBreakEven && rMultiple >= InpBE_TriggerR)
      {
         double beSL = isBuy ? entry + InpBE_OffsetPips * pip
                             : entry - InpBE_OffsetPips * pip;
         beSL = NormalizeDouble(beSL, dg);

         if(isBuy && beSL > curSL)
         {
            newSL = beSL;
            updateSL = true;
         }
         else if(!isBuy && (curSL == 0 || beSL < curSL))
         {
            newSL = beSL;
            updateSL = true;
         }
      }

      if(InpUseTrailing && rMultiple >= InpTrailStartR)
      {
         double trailDist = InpTrailDistancePips * pip;
         double trailSL   = isBuy ? currentPrice - trailDist
                                  : currentPrice + trailDist;
         trailSL = NormalizeDouble(trailSL, dg);

         double minStep = InpTrailStepPips * pip;

         if(isBuy && trailSL > newSL + minStep)
         {
            newSL = trailSL;
            updateSL = true;
         }
         else if(!isBuy && (newSL == 0 || trailSL < newSL - minStep))
         {
            newSL = trailSL;
            updateSL = true;
         }
      }

      if(updateSL && newSL != curSL)
      {
         double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

         if(isBuy  && (currentPrice - newSL) < minStop) continue;
         if(!isBuy && (newSL - currentPrice) < minStop) continue;

         if(trade.PositionModify(ticket, newSL, curTP))
            PrintFormat("Updated SL for #%I64u to %.*f (R=%.2f)",
                        ticket, dg, newSL, rMultiple);
      }
   }
}

//+------------------------------------------------------------------+
//| Check for existing orders or positions                           |
//+------------------------------------------------------------------+
bool HasActiveOrderOrPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagic &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            return true;
      }
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         if(OrderGetInteger(ORDER_MAGIC) == InpMagic &&
            OrderGetString(ORDER_SYMBOL) == _Symbol)
            return true;
      }
   }
   return false;
}
