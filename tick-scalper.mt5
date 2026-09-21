//+------------------------------------------------------------------+
//|                                          TickScalperEA.mq5       |
//|                    Aggressive Tick Scalper with Fast Trailing    |
//+------------------------------------------------------------------+
#property copyright "Aggressive Tick Scalper - by Tinashe Viz"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Input parameters
input group "=== Trade Settings ==="
input double   InpLotSize          = 0.01;    // Lot Size
input double   InpRiskReward       = 1.5;     // Risk to Reward Ratio for initial TP
input int      InpMagicNumber      = 20250202; // Magic Number
input int      InpSlippage         = 5;       // Slippage in points
input int      InpMaxSpread        = 20;      // Max spread in points (0 = disabled)

input group "=== Entry Triggers ==="
input int      InpTickBurst         = 3;      // Consecutive same-direction ticks to trigger entry
input double   InpMinTickMovePts    = 2.0;    // Min total move in points for the burst
input int      InpCooldownMs        = 500;    // Min ms between entries

input group "=== Stop Loss & Trailing ==="
input double   InpInitialSLPts      = 30.0;   // Initial SL in points (fallback if no swing)
input bool     InpUseStructureSL    = true;   // Use recent high/low as initial SL
input int      InpStructureLookback = 10;     // Bars to look back for structure SL

input group "=== Aggressive Trailing ==="
input double   InpTrailStartPts     = 3.0;    // Profit in points before trailing starts
input double   InpTrailStepPts      = 1.0;    // Trailing step in points (lock in tiny gains)
input double   InpTrailDistancePts  = 2.0;    // Distance from price to trail SL (points)
input bool     InpBreakEvenEnabled  = true;   // Enable break-even
input double   InpBreakEvenPts      = 2.0;    // Profit in points to trigger BE
input double   InpBreakEvenLockPts  = 1.0;    // Points to lock in at BE (cover costs)

input group "=== Exit Rules ==="
input double   InpMaxHoldSeconds    = 60;     // Max hold time in seconds (0 = disabled)

//--- Global objects
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

//--- Tick tracking
double         lastBid          = 0.0;
double         lastAsk          = 0.0;
int            upTickStreak     = 0;
int            downTickStreak   = 0;
double         burstStartPrice  = 0.0;
ulong          lastEntryTimeMs  = 0;

//--- Per-position trailing state
ulong          trackedTicket    = 0;
double         currentSL        = 0.0;
double         entryPrice       = 0.0;
ENUM_POSITION_TYPE trackedType  = POSITION_TYPE_BUY;
datetime       positionOpenTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpLotSize <= 0)
   {
      Print("Error: Lot size must be > 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpTrailDistancePts <= 0 || InpTrailStepPts <= 0)
   {
      Print("Error: Trailing distance and step must be > 0");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(!symInfo.Name(_Symbol))
   {
      Print("Error: Failed to init symbol info");
      return(INIT_FAILED);
   }
   symInfo.RefreshRates();

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   //--- Initialize tick tracking
   lastBid = symInfo.Bid();
   lastAsk = symInfo.Ask();

   Print("Tick Scalper initialized on ", _Symbol,
         " | Lot: ", InpLotSize,
         " | TrailStart: ", InpTrailStartPts, "pts",
         " | TrailDist: ", InpTrailDistancePts, "pts",
         " | TrailStep: ", InpTrailStepPts, "pts");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
}

//+------------------------------------------------------------------+
//| Expert tick function - fires on EVERY tick                      |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!symInfo.RefreshRates())
      return;

   //--- Spread filter
   if(InpMaxSpread > 0 && (int)symInfo.Spread() > InpMaxSpread)
      return;

   double bid = symInfo.Bid();
   double ask = symInfo.Ask();

   //--- If we have a position, manage it first (highest priority)
   if(HasOpenPosition())
   {
      ManageOpenPosition(bid, ask);
      UpdateTickTracking(bid, ask);
      return;
   }

   //--- No position: check entry conditions
   UpdateTickTracking(bid, ask);
   CheckEntry(bid, ask);
}

//+------------------------------------------------------------------+
//| Track tick direction and streaks                                 |
//+------------------------------------------------------------------+
void UpdateTickTracking(double bid, double ask)
{
   double mid     = (bid + ask) * 0.5;
   double lastMid = (lastBid + lastAsk) * 0.5;

   if(lastMid == 0.0)
   {
      lastBid = bid;
      lastAsk = ask;
      return;
   }

   double point = symInfo.Point();

   if(mid > lastMid)
   {
      if(upTickStreak == 0)
         burstStartPrice = lastMid;  // start of new up burst
      upTickStreak++;
      downTickStreak = 0;
   }
   else if(mid < lastMid)
   {
      if(downTickStreak == 0)
         burstStartPrice = lastMid;  // start of new down burst
      downTickStreak++;
      upTickStreak = 0;
   }
   // if equal, do nothing (spread widening)

   lastBid = bid;
   lastAsk = ask;
}

//+------------------------------------------------------------------+
//| Check entry conditions                                           |
//+------------------------------------------------------------------+
void CheckEntry(double bid, double ask)
{
   //--- Cooldown between entries
   ulong nowMs = GetTickCount64();
   if(InpCooldownMs > 0 && (nowMs - lastEntryTimeMs) < (ulong)InpCooldownMs)
      return;

   double point = symInfo.Point();

   //--- Long trigger: up-tick burst with enough movement
   if(upTickStreak >= InpTickBurst)
   {
      double moveFromStart = ask - burstStartPrice;
      if(moveFromStart >= InpMinTickMovePts * point)
      {
         if(OpenBuy(ask))
         {
            lastEntryTimeMs = nowMs;
            upTickStreak = 0;
            return;
         }
      }
   }

   //--- Short trigger: down-tick burst with enough movement
   if(downTickStreak >= InpTickBurst)
   {
      double moveFromStart = burstStartPrice - bid;
      if(moveFromStart >= InpMinTickMovePts * point)
      {
         if(OpenSell(bid))
         {
            lastEntryTimeMs = nowMs;
            downTickStreak = 0;
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage the open position - trailing + exits                      |
//+------------------------------------------------------------------+
void ManageOpenPosition(double bid, double ask)
{
   if(!posInfo.SelectByTicket(trackedTicket))
   {
      // Ticket lost - refresh tracking
      if(!RefreshTracking())
         return;
   }

   double point = symInfo.Point();
   long   stopsLevel = symInfo.StopsLevel();
   double minStopDist = stopsLevel * point;

   //--- Max hold time exit
   if(InpMaxHoldSeconds > 0)
   {
      if((TimeCurrent() - positionOpenTime) >= (datetime)InpMaxHoldSeconds)
      {
         Print("Max hold time reached, closing position");
         trade.PositionClose(trackedTicket);
         ResetTracking();
         return;
      }
   }

   if(trackedType == POSITION_TYPE_BUY)
   {
      double currentPrice = bid;
      double profitPts = (currentPrice - entryPrice) / point;

      //--- Compute desired SL
      double desiredSL = currentSL;

      //--- Break-even
      if(InpBreakEvenEnabled && profitPts >= InpBreakEvenPts)
      {
         double beSL = entryPrice + InpBreakEvenLockPts * point;
         if(beSL > desiredSL)
            desiredSL = beSL;
      }

      //--- Trailing
      if(profitPts >= InpTrailStartPts)
      {
         double trailSL = currentPrice - InpTrailDistancePts * point;
         if(trailSL > desiredSL)
            desiredSL = trailSL;
      }

      //--- Only modify if we can move SL up by at least TrailStepPts
      if(desiredSL > currentSL + InpTrailStepPts * point - point * 0.5)
      {
         //--- Respect broker min stop distance
         if(currentPrice - desiredSL >= minStopDist)
         {
            if(trade.PositionModify(trackedTicket, desiredSL, posInfo.TakeProfit()))
            {
               currentSL = desiredSL;
               Print("Trail SL moved to ", DoubleToString(desiredSL, (int)symInfo.Digits()),
                     " | Profit: ", DoubleToString(profitPts, 1), " pts");
            }
         }
      }
   }
   else if(trackedType == POSITION_TYPE_SELL)
   {
      double currentPrice = ask;
      double profitPts = (entryPrice - currentPrice) / point;

      double desiredSL = currentSL;

      if(InpBreakEvenEnabled && profitPts >= InpBreakEvenPts)
      {
         double beSL = entryPrice - InpBreakEvenLockPts * point;
         if(beSL < desiredSL || currentSL == 0.0)
            desiredSL = beSL;
      }

      if(profitPts >= InpTrailStartPts)
      {
         double trailSL = currentPrice + InpTrailDistancePts * point;
         if(trailSL < desiredSL || currentSL == 0.0)
            desiredSL = trailSL;
      }

      if(desiredSL < currentSL - InpTrailStepPts * point + point * 0.5 || currentSL == 0.0)
      {
         if(desiredSL - currentPrice >= minStopDist)
         {
            if(trade.PositionModify(trackedTicket, desiredSL, posInfo.TakeProfit()))
            {
               currentSL = desiredSL;
               Print("Trail SL moved to ", DoubleToString(desiredSL, (int)symInfo.Digits()),
                     " | Profit: ", DoubleToString(profitPts, 1), " pts");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Refresh tracking from current position                           |
//+------------------------------------------------------------------+
bool RefreshTracking()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
         {
            trackedTicket   = posInfo.Ticket();
            currentSL       = posInfo.StopLoss();
            entryPrice      = posInfo.PriceOpen();
            trackedType     = posInfo.PositionType();
            positionOpenTime = (datetime)posInfo.Time();
            return true;
         }
      }
   }
   ResetTracking();
   return false;
}

//+------------------------------------------------------------------+
//| Reset tracking state                                             |
//+------------------------------------------------------------------+
void ResetTracking()
{
   trackedTicket    = 0;
   currentSL        = 0.0;
   entryPrice       = 0.0;
   positionOpenTime = 0;
}

//+------------------------------------------------------------------+
//| Check if position exists for this EA                             |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   if(trackedTicket != 0)
      return true;
   return RefreshTracking();
}

//+------------------------------------------------------------------+
//| Compute initial SL from structure or fixed points                |
//+------------------------------------------------------------------+
double ComputeInitialSL(bool isBuy, double entry)
{
   double point = symInfo.Point();
   double sl    = 0.0;

   if(InpUseStructureSL)
   {
      if(isBuy)
      {
         double low = iLow(_Symbol, PERIOD_CURRENT, 1);
         for(int i = 2; i <= InpStructureLookback; i++)
         {
            double l = iLow(_Symbol, PERIOD_CURRENT, i);
            if(l < low) low = l;
         }
         sl = low;
      }
      else
      {
         double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
         for(int i = 2; i <= InpStructureLookback; i++)
         {
            double h = iHigh(_Symbol, PERIOD_CURRENT, i);
            if(h > high) high = h;
         }
         sl = high;
      }
   }

   //--- Fallback to fixed points if structure SL is invalid or too far/near
   double maxSLPts = InpInitialSLPts * 3.0;
   if(sl <= 0.0 ||
      (isBuy  && (entry - sl) / point > maxSLPts) ||
      (!isBuy && (sl - entry) / point > maxSLPts) ||
      (isBuy  && sl >= entry) ||
      (!isBuy && sl <= entry))
   {
      sl = isBuy ? entry - InpInitialSLPts * point
                 : entry + InpInitialSLPts * point;
   }

   return NormalizeDouble(sl, (int)symInfo.Digits());
}

//+------------------------------------------------------------------+
//| Open a buy                                                       |
//+------------------------------------------------------------------+
bool OpenBuy(double ask)
{
   double sl = ComputeInitialSL(true, ask);
   double point = symInfo.Point();

   //--- Validate SL vs broker stops level
   double minStopDist = symInfo.StopsLevel() * point;
   if(ask - sl < minStopDist)
      sl = ask - minStopDist - point; // push out if too close

   //--- Initial TP based on RR (will usually be replaced by trailing)
   double risk   = ask - sl;
   double tp     = NormalizeDouble(ask + risk * InpRiskReward, (int)symInfo.Digits());

   if(trade.Buy(InpLotSize, _Symbol, ask, NormalizeDouble(sl, (int)symInfo.Digits()), tp,
                "TickScalp Buy"))
   {
      if(RefreshTracking())
      {
         Print("BUY opened @ ", ask, " SL=", sl, " TP=", tp,
               " | upStreak=", upTickStreak);
      }
      return true;
   }
   else
   {
      Print("Buy failed: ", trade.ResultRetcode(), " ", trade.ResultComment());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Open a sell                                                      |
//+------------------------------------------------------------------+
bool OpenSell(double bid)
{
   double sl = ComputeInitialSL(false, bid);
   double point = symInfo.Point();

   double minStopDist = symInfo.StopsLevel() * point;
   if(sl - bid < minStopDist)
      sl = bid + minStopDist + point;

   double risk   = sl - bid;
   double tp     = NormalizeDouble(bid - risk * InpRiskReward, (int)symInfo.Digits());

   if(trade.Sell(InpLotSize, _Symbol, bid, NormalizeDouble(sl, (int)symInfo.Digits()), tp,
                 "TickScalp Sell"))
   {
      if(RefreshTracking())
      {
         Print("SELL opened @ ", bid, " SL=", sl, " TP=", tp,
               " | downStreak=", downTickStreak);
      }
      return true;
   }
   else
   {
      Print("Sell failed: ", trade.ResultRetcode(), " ", trade.ResultComment());
      return false;
   }
}
//+------------------------------------------------------------------+
