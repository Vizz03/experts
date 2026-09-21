
//+------------------------------------------------------------------+
//|                                        FractalBreakoutEA.mq5     |
//|                              Fractal Breakout Strategy EA         |
//+------------------------------------------------------------------+
#property copyright "Fractal Breakout EA - By Tinashe Viz"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Input parameters
input group "=== Trade Settings ==="
input double   InpLotSize        = 0.10;    // Lot Size
input double   InpRiskReward     = 1.0;     // Risk to Reward Ratio (e.g. 1.0 = 1:1, 2.0 = 1:2)

input group "=== Indicator Settings ==="
input int      InpEmaPeriod      = 50;      // EMA Period
input int      InpFractalLookback = 50;     // Bars to search back for fractals

input group "=== Trade Management ==="
input int      InpMagicNumber    = 20250101; // Magic Number
input int      InpMaxSpread      = 50;      // Max allowed spread in points (0 = disabled)
input int      InpSlippage       = 10;      // Slippage in points

//--- Global objects
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

//--- Indicator handles
int            hFractals = INVALID_HANDLE;
int            hEma      = INVALID_HANDLE;

//--- Indicator buffers
double         upperFractal[];
double         lowerFractal[];
double         emaBuffer[];

//--- State tracking to avoid multiple entries on same bar
datetime       lastBuyBar  = 0;
datetime       lastSellBar = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate inputs
   if(InpLotSize <= 0)
   {
      Print("Error: Lot size must be greater than 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpRiskReward <= 0)
   {
      Print("Error: Risk to reward ratio must be greater than 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpEmaPeriod < 1)
   {
      Print("Error: EMA period must be at least 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpFractalLookback < 3)
   {
      Print("Error: Fractal lookback must be at least 3");
      return(INIT_PARAMETERS_INCORRECT);
   }

   //--- Initialize symbol info
   if(!symInfo.Name(_Symbol))
   {
      Print("Error: Failed to initialize symbol info");
      return(INIT_FAILED);
   }
   symInfo.RefreshRates();

   //--- Configure trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   //--- Create indicator handles for the current timeframe
   hFractals = iFractals(_Symbol, PERIOD_CURRENT);
   hEma      = iMA(_Symbol, PERIOD_CURRENT, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(hFractals == INVALID_HANDLE)
   {
      Print("Error: Failed to create Fractals handle. Error code: ", GetLastError());
      return(INIT_FAILED);
   }
   if(hEma == INVALID_HANDLE)
   {
      Print("Error: Failed to create EMA handle. Error code: ", GetLastError());
      return(INIT_FAILED);
   }

   //--- Set arrays as series so index 0 = most recent
   ArraySetAsSeries(upperFractal, true);
   ArraySetAsSeries(lowerFractal, true);
   ArraySetAsSeries(emaBuffer,    true);

   Print("Fractal Breakout EA initialized. Symbol: ", _Symbol,
         " | Timeframe: ", EnumToString((ENUM_TIMEFRAMES)Period()),
         " | EMA: ", InpEmaPeriod,
         " | Lot: ", InpLotSize,
         " | RR: 1:", InpRiskReward);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hFractals != INVALID_HANDLE)
      IndicatorRelease(hFractals);
   if(hEma != INVALID_HANDLE)
      IndicatorRelease(hEma);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Only process once per bar
   static datetime lastProcessedBar = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastProcessedBar)
      return;

   //--- Refresh symbol data
   if(!symInfo.RefreshRates())
      return;

   //--- Check spread
   if(InpMaxSpread > 0)
   {
      int spread = (int)symInfo.Spread();
      if(spread > InpMaxSpread)
         return;
   }

   //--- Copy indicator data
   int barsToCopy = InpFractalLookback + 5;
   if(CopyBuffer(hFractals, 0, 0, barsToCopy, upperFractal) < barsToCopy)
      return;
   if(CopyBuffer(hFractals, 1, 0, barsToCopy, lowerFractal) < barsToCopy)
      return;
   if(CopyBuffer(hEma, 0, 0, 3, emaBuffer) < 3)
      return;

   //--- Get the most recent CLOSED bar values (index 1 = last closed bar)
   double lastClose = iClose(_Symbol, PERIOD_CURRENT, 1);
   double emaValue  = emaBuffer[1];

   if(lastClose <= 0 || emaValue <= 0)
      return;

   //--- Find most recent confirmed fractals
   double recentUpper = GetRecentUpperFractal();
   double recentLower = GetRecentLowerFractal();

   //--- Check if we already have a position for this symbol/magic
   bool hasPosition = HasOpenPosition();

   //--- BUY SIGNAL
   //    Price above EMA, close breaks above most recent upper fractal
   if(!hasPosition &&
      lastClose > emaValue &&
      recentUpper > 0 &&
      lastClose > recentUpper &&
      lastBuyBar != currentBarTime)
   {
      // Stop loss = most recent opposite (down) fractal
      if(recentLower > 0 && recentLower < lastClose)
      {
         if(OpenBuy(recentLower))
         {
            lastBuyBar = currentBarTime;
         }
      }
   }

   //--- SELL SIGNAL
   //    Price below EMA, close breaks below most recent lower fractal
   if(!hasPosition &&
      lastClose < emaValue &&
      recentLower > 0 &&
      lastClose < recentLower &&
      lastSellBar != currentBarTime)
   {
      // Stop loss = most recent opposite (up) fractal
      if(recentUpper > 0 && recentUpper > lastClose)
      {
         if(OpenSell(recentUpper))
         {
            lastSellBar = currentBarTime;
         }
      }
   }

   lastProcessedBar = currentBarTime;
}

//+------------------------------------------------------------------+
//| Find most recent confirmed upper fractal                         |
//+------------------------------------------------------------------+
double GetRecentUpperFractal()
{
   for(int i = 1; i <= InpFractalLookback; i++)
   {
      if(upperFractal[i] != EMPTY_VALUE &&
         upperFractal[i] != 0.0 &&
         upperFractal[i] != DBL_MAX)
      {
         return upperFractal[i];
      }
   }
   return 0.0;
}

//+------------------------------------------------------------------+
//| Find most recent confirmed lower fractal                         |
//+------------------------------------------------------------------+
double GetRecentLowerFractal()
{
   for(int i = 1; i <= InpFractalLookback; i++)
   {
      if(lowerFractal[i] != EMPTY_VALUE &&
         lowerFractal[i] != 0.0 &&
         lowerFractal[i] != DBL_MAX)
      {
         return lowerFractal[i];
      }
   }
   return 0.0;
}

//+------------------------------------------------------------------+
//| Check if a position for this EA already exists                   |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Normalize price to symbol digits                                 |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   return NormalizeDouble(price, (int)symInfo.Digits());
}

//+------------------------------------------------------------------+
//| Open a buy position                                              |
//+------------------------------------------------------------------+
bool OpenBuy(double stopLossPrice)
{
   symInfo.RefreshRates();
   double ask = symInfo.Ask();
   double sl  = NormalizePrice(stopLossPrice);

   //--- Validate SL
   double minStopLevel = symInfo.StopsLevel() * symInfo.Point();
   if(ask - sl < minStopLevel)
   {
      Print("Buy skipped: SL too close. Ask=", ask, " SL=", sl,
            " MinStop=", minStopLevel);
      return false;
   }

   //--- Calculate TP from risk-reward ratio
   double risk   = ask - sl;
   double reward = risk * InpRiskReward;
   double tp     = NormalizePrice(ask + reward);

   //--- Send order
   if(trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "FractalBreakout Buy"))
   {
      Print("BUY opened. Entry=", ask, " SL=", sl, " TP=", tp,
            " Risk=", DoubleToString(risk, (int)symInfo.Digits()),
            " Reward=", DoubleToString(reward, (int)symInfo.Digits()));
      return true;
   }
   else
   {
      Print("Buy order failed. Retcode=", trade.ResultRetcode(),
            " Comment=", trade.ResultComment());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Open a sell position                                             |
//+------------------------------------------------------------------+
bool OpenSell(double stopLossPrice)
{
   symInfo.RefreshRates();
   double bid = symInfo.Bid();
   double sl  = NormalizePrice(stopLossPrice);

   //--- Validate SL
   double minStopLevel = symInfo.StopsLevel() * symInfo.Point();
   if(sl - bid < minStopLevel)
   {
      Print("Sell skipped: SL too close. Bid=", bid, " SL=", sl,
            " MinStop=", minStopLevel);
      return false;
   }

   //--- Calculate TP from risk-reward ratio
   double risk   = sl - bid;
   double reward = risk * InpRiskReward;
   double tp     = NormalizePrice(bid - reward);

   //--- Send order
   if(trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "FractalBreakout Sell"))
   {
      Print("SELL opened. Entry=", bid, " SL=", sl, " TP=", tp,
            " Risk=", DoubleToString(risk, (int)symInfo.Digits()),
            " Reward=", DoubleToString(reward, (int)symInfo.Digits()));
      return true;
   }
   else
   {
      Print("Sell order failed. Retcode=", trade.ResultRetcode(),
            " Comment=", trade.ResultComment());
      return false;
   }
}
//+------------------------------------------------------------------+
