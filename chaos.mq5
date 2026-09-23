//+------------------------------------------------------------------+
//|                                                       Chaos.mq5  |
//|                                    Chaos Strategy (Alligator+FR) |
//+------------------------------------------------------------------+
#property copyright "Chaos EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//--- inputs -----------------------------------------------------------
input group "=== Alligator ==="
input int    InpJawPeriod    = 13;
input int    InpJawShift     = 8;
input int    InpTeethPeriod  = 8;
input int    InpTeethShift   = 5;
input int    InpLipsPeriod   = 5;
input int    InpLipsShift    = 3;

input group "=== Fractals / Stop Loss ==="
input int    InpFractalLookback = 300;   // bars to search for fractals
input int    InpSLBufferPoints  = 0;     // extra points beyond fractal for SL

input group "=== Trade ==="
input double InpLots       = 0.10;
input int    InpTPPoints   = 500;        // TP in points (0 = disabled)
input ulong  InpMagic      = 20240101;
input int    InpSlippage   = 20;
input bool   InpOnePositionAtATime = true;

input group "=== Trailing ==="
input bool   InpUseTrailing = true;

//--- globals ----------------------------------------------------------
CTrade      trade;
CSymbolInfo sym;
int         hAlligator = INVALID_HANDLE;
int         hFractals  = INVALID_HANDLE;
datetime    lastBarTime = 0;

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!sym.Name(_Symbol)) { Print("SymbolInfo.Name failed"); return INIT_FAILED; }
   sym.RefreshRates();

   hAlligator = iAlligator(_Symbol, _Period,
                           InpJawPeriod,   InpJawShift,
                           InpTeethPeriod, InpTeethShift,
                           InpLipsPeriod,  InpLipsShift,
                           MODE_SMMA, PRICE_MEDIAN);
   if(hAlligator == INVALID_HANDLE)
   {
      Print("Failed to create Alligator handle, error ", GetLastError());
      return INIT_FAILED;
   }

   hFractals = iFractals(_Symbol, _Period);
   if(hFractals == INVALID_HANDLE)
   {
      Print("Failed to create Fractals handle, error ", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hAlligator != INVALID_HANDLE) IndicatorRelease(hAlligator);
   if(hFractals  != INVALID_HANDLE) IndicatorRelease(hFractals);
}

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   sym.RefreshRates();

   datetime t = iTime(_Symbol, _Period, 0);
   if(t == lastBarTime) return;
   lastBarTime = t;

   // 1) Always manage trailing stops
   ManageOpenPositions();

   // 2) Then look for new entries on the fresh bar
   if(InpOnePositionAtATime && HasOpenPosition()) return;
   CheckForEntry();
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double GetBufferValue(int handle, int bufIdx, int shift)
{
   if(handle == INVALID_HANDLE) return EMPTY_VALUE;
   double arr[];
   ArraySetAsSeries(arr, true);
   int need = shift + 1;
   if(CopyBuffer(handle, bufIdx, 0, need, arr) < need) return EMPTY_VALUE;
   return arr[shift];
}

bool GetAlligatorAt(int shift, double &jaw, double &teeth, double &lips)
{
   jaw   = GetBufferValue(hAlligator, MODE_GATORJAW,   shift);
   teeth = GetBufferValue(hAlligator, MODE_GATORTEETH, shift);
   lips  = GetBufferValue(hAlligator, MODE_GATORLIPS,  shift);

   if(jaw == EMPTY_VALUE || teeth == EMPTY_VALUE || lips == EMPTY_VALUE) return false;
   if(jaw == 0.0 || teeth == 0.0 || lips == 0.0) return false;
   return true;
}

// bufIdx: 0 = up fractal, 1 = down fractal
// direction:  0 = any,  -1 = value must be < refPrice,  +1 = value must be > refPrice
bool FindFractal(int bufIdx, double refPrice, int direction, double &outPrice, int &outShift)
{
   if(hFractals == INVALID_HANDLE) return false;

   int bars = Bars(_Symbol, _Period);
   int toCopy = MathMin(InpFractalLookback, bars - 1);
   if(toCopy < 5) return false;

   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(hFractals, bufIdx, 0, toCopy, arr) < toCopy) return false;

   for(int i = 2; i < toCopy; i++)   // confirmed only (need 2 bars)
   {
      double v = arr[i];
      if(v == EMPTY_VALUE || v == 0.0) continue;
      if(direction < 0 && v >= refPrice) continue;
      if(direction > 0 && v <= refPrice) continue;

      outPrice = v;
      outShift = i;
      return true;
   }
   return false;
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Entry logic                                                      |
//+------------------------------------------------------------------+
void CheckForEntry()
{
   // Use the last closed bar for trend confirmation
   double jaw, teeth, lips;
   if(!GetAlligatorAt(1, jaw, teeth, lips)) return;

   double close1 = iClose(_Symbol, _Period, 1);
   double close2 = iClose(_Symbol, _Period, 2);
   if(close1 <= 0.0 || close2 <= 0.0) return;

   double maxAll = MathMax(jaw, MathMax(teeth, lips));
   double minAll = MathMin(jaw, MathMin(teeth, lips));

   bool bullAlign = (lips > teeth && teeth > jaw);
   bool bearAlign = (lips < teeth && teeth < jaw);

   //---------------- BUY ----------------
   if(bullAlign && close1 > maxAll)
   {
      double upFr; int upShift;
      if(FindFractal(0, 0.0, 0, upFr, upShift))   // most recent up fractal
      {
         // breakout of the fractal on close basis
         if(close2 <= upFr && close1 > upFr)
         {
            // SL = most recent down fractal below current price
            double dnFr; int dnShift;
            if(FindFractal(1, close1, -1, dnFr, dnShift))
               OpenBuy(dnFr);
         }
      }
   }
   //---------------- SELL ----------------
   else if(bearAlign && close1 < minAll)
   {
      double dnFr; int dnShift;
      if(FindFractal(1, 0.0, 0, dnFr, dnShift))   // most recent down fractal
      {
         if(close2 >= dnFr && close1 < dnFr)
         {
            double upFr; int upShift;
            if(FindFractal(0, close1, +1, upFr, upShift))
               OpenSell(upFr);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Order helpers                                                    |
//+------------------------------------------------------------------+
void OpenBuy(double slFractal)
{
   sym.RefreshRates();
   double ask = sym.Ask();
   if(ask <= 0.0) return;

   double sl = NormalizeDouble(slFractal - InpSLBufferPoints * _Point, _Digits);
   if(sl >= ask - _Point) { Print("Buy skipped: invalid SL"); return; }

   double tp = 0.0;
   if(InpTPPoints > 0)
      tp = NormalizeDouble(ask + InpTPPoints * _Point, _Digits);

   if(!trade.Buy(InpLots, _Symbol, ask, sl, tp, "Chaos Buy"))
      PrintFormat("Buy failed [%d]: %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   else
      PrintFormat("Chaos BUY @ %.*f SL=%.*f TP=%.*f", _Digits, ask, _Digits, sl, _Digits, tp);
}

void OpenSell(double slFractal)
{
   sym.RefreshRates();
   double bid = sym.Bid();
   if(bid <= 0.0) return;

   double sl = NormalizeDouble(slFractal + InpSLBufferPoints * _Point, _Digits);
   if(sl <= bid + _Point) { Print("Sell skipped: invalid SL"); return; }

   double tp = 0.0;
   if(InpTPPoints > 0)
      tp = NormalizeDouble(bid - InpTPPoints * _Point, _Digits);

   if(!trade.Sell(InpLots, _Symbol, bid, sl, tp, "Chaos Sell"))
      PrintFormat("Sell failed [%d]: %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   else
      PrintFormat("Chaos SELL @ %.*f SL=%.*f TP=%.*f", _Digits, bid, _Digits, sl, _Digits, tp);
}

//+------------------------------------------------------------------+
//| Trailing stop using opposite fractals                            |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(!InpUseTrailing) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
      {
         double bid = sym.Bid();
         double dnFr; int dnShift;
         // Find most recent down fractal that is below current bid (valid SL)
         if(!FindFractal(1, bid - _Point, -1, dnFr, dnShift)) continue;

         double newSL = NormalizeDouble(dnFr - InpSLBufferPoints * _Point, _Digits);
         if(newSL > curSL && newSL < bid - _Point)
         {
            if(!trade.PositionModify(ticket, newSL, curTP))
               PrintFormat("Trail BUY modify failed [%d]: %s",
                           trade.ResultRetcode(), trade.ResultRetcodeDescription());
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double ask = sym.Ask();
         double upFr; int upShift;
         // Most recent up fractal above current ask (valid SL)
         if(!FindFractal(0, ask + _Point, +1, upFr, upShift)) continue;

         double newSL = NormalizeDouble(upFr + InpSLBufferPoints * _Point, _Digits);
         if((curSL == 0.0 || newSL < curSL) && newSL > ask + _Point)
         {
            if(!trade.PositionModify(ticket, newSL, curTP))
               PrintFormat("Trail SELL modify failed [%d]: %s",
                           trade.ResultRetcode(), trade.ResultRetcodeDescription());
         }
      }
   }
}
//+------------------------------------------------------------------+
