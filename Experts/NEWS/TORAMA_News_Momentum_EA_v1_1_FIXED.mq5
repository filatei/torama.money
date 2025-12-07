//+------------------------------------------------------------------+
//|                                   TORAMA_News_Momentum_EA_v1.1.mq5|
//|                                      Copyright 2025, TORAMA CAPITAL|
//|                                            https://money.torama.biz|
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, TORAMA CAPITAL"
#property link      "https://money.torama.biz"
#property version   "1.10"
#property description "NEWS MOMENTUM EA - Gold & Bitcoin Specialist (FIXED v1.1)"
#property description "Trades BOTH directions with fast SL on wrong side"
#property description "Rides momentum with replaceable grid levels"
#property description "FIXES: TP/SL calculations, grid recalculation, reference price tracking"
#property description "Contact: ea@torama.biz"

#define EA_VERSION "1.1"
#define EA_NAME "NEWS MOMENTUM"

//+------------------------------------------------------------------+
//| INPUTS - NEWS TRADING OPTIMIZED                                  |
//+------------------------------------------------------------------+

// === CORE SETTINGS ===
input group "=== TRADING PARAMETERS ==="
input double   GridSpacingPercent = 0.15;      // Grid spacing % (0.10-0.30 for news)
input double   LotSize = 0.10;                 // Lot size per position
input int      MaxPositionsPerSide = 5;        // Max positions per direction (BUY or SELL)

input group "=== PROFIT & LOSS PROTECTION ==="
input double   IndividualTPPercent = 75.0;     // Take Profit % of gap (75% recommended)
input double   IndividualSLPercent = 125.0;    // Stop Loss % of gap (125% recommended, CRITICAL)
input double   GlobalTPDollars = 200.0;        // Global Take Profit $
input double   MaxDrawdownPercent = 15.0;      // Max drawdown % (emergency stop)

input group "=== MOMENTUM DETECTION ==="
input int      InitialSignalGaps = 1;          // Gaps for initial signal (1 = immediate)
input int      ReversalGaps = 3;               // Gaps for reversal detection (3-5 recommended)
input int      FastSLTriggerSeconds = 10;      // Seconds to trigger fast SL on wrong side

input group "=== RISK CONTROLS ==="
input int      MagicNumber = 202512;           // Magic number (unique ID for this EA)
input int      MaxSpread = 500;                // Maximum spread in points (500 for Gold, 2000 for BTC)
input bool     CloseOppositeOnReversal = true; // Close losing side on reversal (NEWS MODE)
input bool     EnableFastSL = true;            // Enable fast SL for wrong direction

input group "=== TRADING WINDOW ==="
input bool     UseTradeWindow = false;         // Enable trading time restrictions
input int      TradeStartHour = 8;             // Trading start hour (server time)
input int      TradeEndHour = 22;              // Trading end hour (server time)

input group "=== SUPPORT & RESISTANCE ==="
input bool     ShowSupportResistance = true;   // Show H4 S/R lines on chart
input int      SRLookbackBars = 50;            // Bars to lookback for S/R (20-100)
input int      SRUpdateMinutes = 240;          // Re-evaluate S/R every N minutes (240 = 4 hours)

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

// Working variables (can be modified by auto-detection)
int workingMaxSpread;  // Actual max spread used (auto-set based on symbol)

// Calculated TP/SL in dollars (from percentages of gap)
double calculatedTPDollars = 0;
double calculatedSLDollars = 0;

// Support & Resistance variables
double currentSupport = 0;
double currentResistance = 0;
datetime lastSRUpdate = 0;

// Position tracking structure
struct PositionInfo
{
   ulong    ticket;
   string   direction;      // "BUY" or "SELL"
   double   entryPrice;
   double   lotSize;
   datetime openTime;
   double   tp;
   double   sl;
   bool     isFastSL;       // Marked for fast SL closure
};

// Momentum state
enum MomentumDirection
{
   MOMENTUM_NONE,    // No momentum detected
   MOMENTUM_UP,      // Buying momentum
   MOMENTUM_DOWN     // Selling momentum
};

// Global variables
PositionInfo buyPositions[];
PositionInfo sellPositions[];
MomentumDirection currentMomentum = MOMENTUM_NONE;
double referencePrice = 0;
datetime momentumStartTime = 0;
double gridSpacing = 0;
bool emergencyStop = false;
string emergencyReason = "";
datetime emergencyTime = 0;
double peakEquity = 0;

// Statistics
int totalBuys = 0;
int totalSells = 0;
int closedProfits = 0;
int closedLosses = 0;
double sessionPnL = 0;

// Panel
string panelPrefix = "NewsEA_";
bool panelVisible = true;

//+------------------------------------------------------------------+
//| Calculate H4 Support and Resistance                              |
//+------------------------------------------------------------------+
void CalculateSupportResistance()
{
   // Use H4 timeframe for S/R
   double highs[];
   double lows[];
   
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   
   // Get H4 high and low data
   int copiedHighs = CopyHigh(_Symbol, PERIOD_H4, 0, SRLookbackBars, highs);
   int copiedLows = CopyLow(_Symbol, PERIOD_H4, 0, SRLookbackBars, lows);
   
   if(copiedHighs <= 0 || copiedLows <= 0)
   {
      Print("Failed to copy H4 data for S/R calculation");
      return;
   }
   
   // Find resistance (highest high in lookback period)
   currentResistance = highs[ArrayMaximum(highs, 0, SRLookbackBars)];
   
   // Find support (lowest low in lookback period)
   currentSupport = lows[ArrayMinimum(lows, 0, SRLookbackBars)];
   
   // Draw or update lines
   DrawSupportResistanceLines();
   
   Print("📊 S/R Updated: Support=", DoubleToString(currentSupport, _Digits), 
         " | Resistance=", DoubleToString(currentResistance, _Digits));
}

//+------------------------------------------------------------------+
//| Draw Support and Resistance lines                                |
//+------------------------------------------------------------------+
void DrawSupportResistanceLines()
{
   if(!ShowSupportResistance) return;
   
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Support Line
   if(ObjectFind(0, "SR_Support") < 0)
   {
      ObjectCreate(0, "SR_Support", OBJ_HLINE, 0, 0, currentSupport);
      ObjectSetInteger(0, "SR_Support", OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, "SR_Support", OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, "SR_Support", OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, "SR_Support", OBJPROP_BACK, false);
      ObjectSetInteger(0, "SR_Support", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, "SR_Support", OBJPROP_HIDDEN, true);
   }
   else
   {
      ObjectSetDouble(0, "SR_Support", OBJPROP_PRICE, currentSupport);
   }
   
   // Support Label
   if(ObjectFind(0, "SR_Support_Label") < 0)
   {
      ObjectCreate(0, "SR_Support_Label", OBJ_TEXT, 0, TimeCurrent(), currentSupport);
      ObjectSetString(0, "SR_Support_Label", OBJPROP_TEXT, " S: " + DoubleToString(currentSupport, digits));
      ObjectSetInteger(0, "SR_Support_Label", OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, "SR_Support_Label", OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, "SR_Support_Label", OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, "SR_Support_Label", OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, "SR_Support_Label", OBJPROP_BACK, false);
      ObjectSetInteger(0, "SR_Support_Label", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, "SR_Support_Label", OBJPROP_HIDDEN, true);
   }
   else
   {
      ObjectMove(0, "SR_Support_Label", 0, TimeCurrent(), currentSupport);
      ObjectSetString(0, "SR_Support_Label", OBJPROP_TEXT, " S: " + DoubleToString(currentSupport, digits));
   }
   
   // Resistance Line
   if(ObjectFind(0, "SR_Resistance") < 0)
   {
      ObjectCreate(0, "SR_Resistance", OBJ_HLINE, 0, 0, currentResistance);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_COLOR, clrOrangeRed);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_BACK, false);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_HIDDEN, true);
   }
   else
   {
      ObjectSetDouble(0, "SR_Resistance", OBJPROP_PRICE, currentResistance);
   }
   
   // Resistance Label
   if(ObjectFind(0, "SR_Resistance_Label") < 0)
   {
      ObjectCreate(0, "SR_Resistance_Label", OBJ_TEXT, 0, TimeCurrent(), currentResistance);
      ObjectSetString(0, "SR_Resistance_Label", OBJPROP_TEXT, " R: " + DoubleToString(currentResistance, digits));
      ObjectSetInteger(0, "SR_Resistance_Label", OBJPROP_COLOR, clrOrangeRed);
      ObjectSetInteger(0, "SR_Resistance_Label", OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, "SR_Resistance_Label", OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, "SR_Resistance_Label", OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, "SR_Resistance_Label", OBJPROP_BACK, false);
      ObjectSetInteger(0, "SR_Resistance_Label", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, "SR_Resistance_Label", OBJPROP_HIDDEN, true);
   }
   else
   {
      ObjectMove(0, "SR_Resistance_Label", 0, TimeCurrent(), currentResistance);
      ObjectSetString(0, "SR_Resistance_Label", OBJPROP_TEXT, " R: " + DoubleToString(currentResistance, digits));
   }
}

//+------------------------------------------------------------------+
//| Delete Support and Resistance lines                              |
//+------------------------------------------------------------------+
void DeleteSupportResistanceLines()
{
   ObjectDelete(0, "SR_Support");
   ObjectDelete(0, "SR_Support_Label");
   ObjectDelete(0, "SR_Resistance");
   ObjectDelete(0, "SR_Resistance_Label");
}

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("═══════════════════════════════════════════════════════════");
   Print("🚀 ", EA_NAME, " EA v", EA_VERSION, " - TORAMA CAPITAL");
   Print("═══════════════════════════════════════════════════════════");
   
   //--- Initialize working spread with input value
   workingMaxSpread = MaxSpread;
   
   //--- AUTO-DETECT SYMBOL AND SET SPREAD
   string symbol = _Symbol;
   bool isGold = false;
   bool isBitcoin = false;
   
   // Check for Gold (XAUUSD variations)
   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
   {
      isGold = true;
      workingMaxSpread = 500;  // Gold typical spread
      Print("✅ GOLD detected: ", symbol);
      Print("   MaxSpread auto-set to: 500 points");
   }
   // Check for Bitcoin (BTC variations)
   else if(StringFind(symbol, "BTC") >= 0 || StringFind(symbol, "BITCOIN") >= 0)
   {
      isBitcoin = true;
      workingMaxSpread = 2000;  // Bitcoin typical spread
      Print("✅ BITCOIN detected: ", symbol);
      Print("   MaxSpread auto-set to: 2000 points");
   }
   else
   {
      Print("⚠️ Symbol: ", symbol, " (using MaxSpread: ", workingMaxSpread, ")");
   }
   
   //--- CALCULATE TP/SL FROM GRID GAP
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double gridGapDollars = currentPrice * (GridSpacingPercent / 100.0);
   
   calculatedTPDollars = gridGapDollars * (IndividualTPPercent / 100.0);
   calculatedSLDollars = gridGapDollars * (IndividualSLPercent / 100.0);
   
   Print("Symbol: ", _Symbol);
   Print("Grid Spacing: ", GridSpacingPercent, "% ($", DoubleToString(gridGapDollars, 2), " gap)");
   Print("Individual TP: ", IndividualTPPercent, "% of gap = $", DoubleToString(calculatedTPDollars, 2));
   Print("Individual SL: ", IndividualSLPercent, "% of gap = $", DoubleToString(calculatedSLDollars, 2), " (FAST SL: ", EnableFastSL ? "ON" : "OFF", ")");
   Print("Global TP: $", GlobalTPDollars);
   Print("Max Drawdown: ", MaxDrawdownPercent, "%");
   Print("Close Opposite on Reversal: ", CloseOppositeOnReversal ? "YES" : "NO");
   Print("Max Positions per Side: ", MaxPositionsPerSide);
   Print("Max Spread: ", workingMaxSpread, " points");
   Print("═══════════════════════════════════════════════════════════");
   
   // Validate inputs
   if(GridSpacingPercent <= 0 || GridSpacingPercent > 2.0)
   {
      Alert("❌ Invalid Grid Spacing: ", GridSpacingPercent, "%. Use 0.10-0.30 for news trading");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(IndividualSLPercent <= 0)
   {
      Alert("❌ Individual SL % must be > 0 for news trading!");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(IndividualTPPercent <= 0)
   {
      Alert("❌ Individual TP % must be > 0!");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(IndividualTPPercent < IndividualSLPercent * 0.3)
   {
      Print("⚠️ WARNING: TP% is very small compared to SL%. Recommended: TP% >= 50-100% of SL%");
   }
   
   // Initialize
   ArrayResize(buyPositions, 0);
   ArrayResize(sellPositions, 0);
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Calculate initial Support & Resistance
   if(ShowSupportResistance)
   {
      CalculateSupportResistance();
      lastSRUpdate = TimeCurrent();
   }
   
   // Create panel
   CreateInfoPanel();
   
   Print("✅ EA initialized successfully - Ready for news trading");
   Print("💡 TIP: Start EA 1 minute before news for best results");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("═══════════════════════════════════════════════════════════");
   Print("📊 SESSION STATISTICS:");
   Print("Total BUYs: ", totalBuys);
   Print("Total SELLs: ", totalSells);
   Print("Closed Profits: ", closedProfits);
   Print("Closed Losses: ", closedLosses);
   Print("Session P&L: $", DoubleToString(sessionPnL, 2));
   Print("═══════════════════════════════════════════════════════════");
   
   // Clean up panel
   ObjectsDeleteAll(0, panelPrefix);
   
   // Clean up S/R lines
   DeleteSupportResistanceLines();
   
   Print("EA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function - MAIN TRADING LOGIC                        |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- EMERGENCY STOP CHECK (highest priority)
   if(emergencyStop)
   {
      static datetime lastWarning = 0;
      if(TimeCurrent() - lastWarning > 300) // Every 5 minutes
      {
         Print("🛑 EA IN EMERGENCY STOP MODE");
         Print("   Reason: ", emergencyReason);
         Print("   Remove and re-attach EA to restart");
         lastWarning = TimeCurrent();
      }
      UpdateInfoPanel();
      return;
   }
   
   //--- Update position arrays from actual trades
   SyncPositions();
   
   //--- Check drawdown protection
   if(CheckDrawdownLimit())
   {
      Print("🛑 EMERGENCY STOP: Max Drawdown Exceeded");
      CloseAllPositions("Emergency Stop - Max Drawdown");
      emergencyStop = true;
      emergencyReason = "Max Drawdown Exceeded";
      emergencyTime = TimeCurrent();
      Alert("🛑 EA STOPPED: Max Drawdown ", MaxDrawdownPercent, "% exceeded!");
      UpdateInfoPanel();
      return;
   }
   
   //--- Check spread
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > workingMaxSpread)
   {
      static datetime lastSpreadWarning = 0;
      if(TimeCurrent() - lastSpreadWarning > 60)
      {
         Print("⚠️ Spread too high: ", currentSpread, " > ", workingMaxSpread);
         lastSpreadWarning = TimeCurrent();
      }
      UpdateInfoPanel();
      return;
   }
   
   //--- Update Support & Resistance periodically
   if(ShowSupportResistance)
   {
      int secondsSinceUpdate = (int)(TimeCurrent() - lastSRUpdate);
      if(secondsSinceUpdate >= SRUpdateMinutes * 60)
      {
         CalculateSupportResistance();
         lastSRUpdate = TimeCurrent();
      }
   }
   
   //--- Check trading window
   if(UseTradeWindow && !IsInTradingWindow())
   {
      UpdateInfoPanel();
      return;
   }
   
   //--- Get current prices
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   //--- RECALCULATE grid spacing and TP/SL based on current price (critical for news trading)
   gridSpacing = currentPrice * (GridSpacingPercent / 100.0);
   double gridGapDollars = gridSpacing; // Grid gap in dollars
   calculatedTPDollars = gridGapDollars * (IndividualTPPercent / 100.0);
   calculatedSLDollars = gridGapDollars * (IndividualSLPercent / 100.0);
   
   //--- Check global TP
   double globalPnL = CalculateGlobalPnL();
   if(globalPnL >= GlobalTPDollars)
   {
      Print("✅ GLOBAL TP HIT: $", DoubleToString(globalPnL, 2));
      CloseAllPositions("Global TP Target Reached");
      ResetMomentum();
      UpdateInfoPanel();
      return;
   }
   
   //--- FAST SL CHECK - Close losing side quickly
   if(EnableFastSL && currentMomentum != MOMENTUM_NONE)
   {
      CheckFastSL();
   }
   
   //--- MOMENTUM DETECTION & TRADING LOGIC
   if(currentMomentum == MOMENTUM_NONE)
   {
      //--- WAITING FOR INITIAL SIGNAL
      if(referencePrice == 0)
      {
         referencePrice = currentPrice;
         Print("📍 Reference price set: ", referencePrice);
         UpdateInfoPanel();
         return;
      }
      
      double priceChange = ((currentPrice - referencePrice) / referencePrice) * 100.0;
      double signalThreshold = GridSpacingPercent * InitialSignalGaps;
      
      //--- UP MOMENTUM DETECTED
      if(priceChange >= signalThreshold)
      {
         currentMomentum = MOMENTUM_UP;
         momentumStartTime = TimeCurrent();
         referencePrice = currentPrice;
         
         Print("═══════════════════════════════════════════════════════════");
         Print("🔵 UPWARD MOMENTUM DETECTED!");
         Print("   Price change: +", DoubleToString(priceChange, 2), "%");
         Print("   Starting BUY positions");
         Print("═══════════════════════════════════════════════════════════");
         
         // Open first BUY position
         OpenPosition("BUY", ask);
      }
      //--- DOWN MOMENTUM DETECTED
      else if(priceChange <= -signalThreshold)
      {
         currentMomentum = MOMENTUM_DOWN;
         momentumStartTime = TimeCurrent();
         referencePrice = currentPrice;
         
         Print("═══════════════════════════════════════════════════════════");
         Print("🔴 DOWNWARD MOMENTUM DETECTED!");
         Print("   Price change: ", DoubleToString(priceChange, 2), "%");
         Print("   Starting SELL positions");
         Print("═══════════════════════════════════════════════════════════");
         
         // Open first SELL position
         OpenPosition("SELL", bid);
      }
   }
   else if(currentMomentum == MOMENTUM_UP)
   {
      //--- BUYING MOMENTUM ACTIVE
      
      // Check for reversal
      if(ShouldReverse(currentPrice))
      {
         HandleReversal("DOWN");
         return;
      }
      
      // Add BUY positions as price rises (GRID UP)
      if(ArraySize(buyPositions) > 0)
      {
         double highestBuyPrice = GetHighestBuyPrice();
         if(ask >= highestBuyPrice + gridSpacing && ArraySize(buyPositions) < MaxPositionsPerSide)
         {
            if(OpenPosition("BUY", ask))
            {
               // Update reference price to track from this new level
               referencePrice = ask;
            }
         }
      }
   }
   else if(currentMomentum == MOMENTUM_DOWN)
   {
      //--- SELLING MOMENTUM ACTIVE
      
      // Check for reversal
      if(ShouldReverse(currentPrice))
      {
         HandleReversal("UP");
         return;
      }
      
      // Add SELL positions as price falls (GRID DOWN)
      if(ArraySize(sellPositions) > 0)
      {
         double lowestSellPrice = GetLowestSellPrice();
         if(bid <= lowestSellPrice - gridSpacing && ArraySize(sellPositions) < MaxPositionsPerSide)
         {
            if(OpenPosition("SELL", bid))
            {
               // Update reference price to track from this new level
               referencePrice = bid;
            }
         }
      }
   }
   
   //--- Update panel
   UpdateInfoPanel();
}

//+------------------------------------------------------------------+
//| Open position with TP/SL                                         |
//+------------------------------------------------------------------+
bool OpenPosition(string direction, double price)
{
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.type = (direction == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price = price;
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = EA_NAME + " v" + EA_VERSION;
   
   // Calculate TP and SL prices using OrderCalcProfit
   double tp = 0, sl = 0;
   CalculateTPSL(direction, price, tp, sl);
   
   request.tp = tp;
   request.sl = sl;
   
   if(!OrderSend(request, result))
   {
      Print("❌ Failed to open ", direction, " position. Error: ", GetLastError());
      Print("   Price: ", price, ", TP: ", tp, ", SL: ", sl);
      return false;
   }
   
   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      Print("✅ ", direction, " position opened");
      Print("   Ticket: ", result.order);
      Print("   Price: ", price);
      Print("   TP: $", DoubleToString(calculatedTPDollars, 2), " at ", tp);
      Print("   SL: $", DoubleToString(calculatedSLDollars, 2), " at ", sl);
      
      if(direction == "BUY")
         totalBuys++;
      else
         totalSells++;
      
      return true;
   }
   
   Print("❌ Order failed. RetCode: ", result.retcode);
   return false;
}

//+------------------------------------------------------------------+
//| Calculate TP/SL prices - FIXED for dollar-quoted instruments     |
//+------------------------------------------------------------------+
void CalculateTPSL(string direction, double entryPrice, double &tp, double &sl)
{
   // For dollar-quoted instruments (XAUUSD, BTCUSD), TP/SL are simply price distances
   // TP/SL dollars are already calculated from grid gap percentages in OnInit
   
   if(direction == "BUY")
   {
      // BUY: TP above entry, SL below entry
      tp = (calculatedTPDollars > 0) ? entryPrice + calculatedTPDollars : 0;
      sl = (calculatedSLDollars > 0) ? entryPrice - calculatedSLDollars : 0;
   }
   else // SELL
   {
      // SELL: TP below entry, SL above entry
      tp = (calculatedTPDollars > 0) ? entryPrice - calculatedTPDollars : 0;
      sl = (calculatedSLDollars > 0) ? entryPrice + calculatedSLDollars : 0;
   }
   
   // Verify minimum stop distance
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minStopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   
   if(minStopLevel > 0)
   {
      if(direction == "BUY")
      {
         if(tp > 0 && tp - entryPrice < minStopLevel)
            tp = entryPrice + minStopLevel;
         if(sl > 0 && entryPrice - sl < minStopLevel)
            sl = entryPrice - minStopLevel;
      }
      else
      {
         if(tp > 0 && entryPrice - tp < minStopLevel)
            tp = entryPrice - minStopLevel;
         if(sl > 0 && sl - entryPrice < minStopLevel)
            sl = entryPrice + minStopLevel;
      }
   }
}

//+------------------------------------------------------------------+
//| Sync positions from actual trades                                |
//+------------------------------------------------------------------+
void SyncPositions()
{
   ArrayResize(buyPositions, 0);
   ArrayResize(sellPositions, 0);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      PositionInfo pos;
      pos.ticket = ticket;
      pos.direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      pos.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      pos.lotSize = PositionGetDouble(POSITION_VOLUME);
      pos.openTime = (datetime)PositionGetInteger(POSITION_TIME);
      pos.tp = PositionGetDouble(POSITION_TP);
      pos.sl = PositionGetDouble(POSITION_SL);
      pos.isFastSL = false;
      
      if(pos.direction == "BUY")
      {
         int size = ArraySize(buyPositions);
         ArrayResize(buyPositions, size + 1);
         buyPositions[size] = pos;
      }
      else
      {
         int size = ArraySize(sellPositions);
         ArrayResize(sellPositions, size + 1);
         sellPositions[size] = pos;
      }
   }
}

//+------------------------------------------------------------------+
//| Check if should reverse momentum                                 |
//+------------------------------------------------------------------+
bool ShouldReverse(double currentPrice)
{
   if(referencePrice == 0) return false;
   
   double priceChange = ((currentPrice - referencePrice) / referencePrice) * 100.0;
   double reversalThreshold = GridSpacingPercent * ReversalGaps;
   
   if(currentMomentum == MOMENTUM_UP)
   {
      // Check for downward reversal
      if(priceChange <= -reversalThreshold)
      {
         Print("⚠️ REVERSAL DETECTED: Price dropped ", DoubleToString(MathAbs(priceChange), 2), 
               "% from ", referencePrice);
         return true;
      }
   }
   else if(currentMomentum == MOMENTUM_DOWN)
   {
      // Check for upward reversal
      if(priceChange >= reversalThreshold)
      {
         Print("⚠️ REVERSAL DETECTED: Price rose +", DoubleToString(priceChange, 2), 
               "% from ", referencePrice);
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Handle momentum reversal                                         |
//+------------------------------------------------------------------+
void HandleReversal(string newDirection)
{
   Print("═══════════════════════════════════════════════════════════");
   Print("🔄 MOMENTUM REVERSAL TO ", newDirection);
   Print("═══════════════════════════════════════════════════════════");
   
   if(CloseOppositeOnReversal)
   {
      // CLOSE LOSING SIDE (News Mode)
      if(newDirection == "UP")
      {
         Print("📉 Closing all SELL positions (wrong direction)");
         ClosePositionsByDirection("SELL", "Reversal - Wrong Direction");
         
         // Switch to BUY momentum
         currentMomentum = MOMENTUM_UP;
         referencePrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
         momentumStartTime = TimeCurrent();
         
         // Open first BUY
         OpenPosition("BUY", SymbolInfoDouble(_Symbol, SYMBOL_ASK));
         Print("🔵 Started BUYING momentum");
      }
      else // DOWN
      {
         Print("📈 Closing all BUY positions (wrong direction)");
         ClosePositionsByDirection("BUY", "Reversal - Wrong Direction");
         
         // Switch to SELL momentum
         currentMomentum = MOMENTUM_DOWN;
         referencePrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
         momentumStartTime = TimeCurrent();
         
         // Open first SELL
         OpenPosition("SELL", SymbolInfoDouble(_Symbol, SYMBOL_BID));
         Print("🔴 Started SELLING momentum");
      }
   }
   else
   {
      // Keep both sides (Range mode)
      Print("⚠️ Keeping opposite positions (Range mode)");
      
      if(newDirection == "UP")
      {
         currentMomentum = MOMENTUM_UP;
         OpenPosition("BUY", SymbolInfoDouble(_Symbol, SYMBOL_ASK));
      }
      else
      {
         currentMomentum = MOMENTUM_DOWN;
         OpenPosition("SELL", SymbolInfoDouble(_Symbol, SYMBOL_BID));
      }
      
      referencePrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   }
   
   Print("═══════════════════════════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| Fast SL check - Close losing side quickly                        |
//+------------------------------------------------------------------+
void CheckFastSL()
{
   if(momentumStartTime == 0) return;
   
   int secondsInMomentum = (int)(TimeCurrent() - momentumStartTime);
   
   if(secondsInMomentum < FastSLTriggerSeconds) return;
   
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   if(currentMomentum == MOMENTUM_UP)
   {
      // Check if any SELL positions exist and are losing
      if(ArraySize(sellPositions) > 0)
      {
         double sellPnL = CalculatePnLByDirection("SELL");
         if(sellPnL < -calculatedSLDollars * 0.5) // 50% of SL
         {
            Print("⚡ FAST SL: Closing losing SELL positions (wrong direction)");
            Print("   Time in momentum: ", secondsInMomentum, " seconds");
            Print("   SELL P&L: $", DoubleToString(sellPnL, 2));
            ClosePositionsByDirection("SELL", "Fast SL - Wrong Direction");
         }
      }
   }
   else if(currentMomentum == MOMENTUM_DOWN)
   {
      // Check if any BUY positions exist and are losing
      if(ArraySize(buyPositions) > 0)
      {
         double buyPnL = CalculatePnLByDirection("BUY");
         if(buyPnL < -calculatedSLDollars * 0.5)
         {
            Print("⚡ FAST SL: Closing losing BUY positions (wrong direction)");
            Print("   Time in momentum: ", secondsInMomentum, " seconds");
            Print("   BUY P&L: $", DoubleToString(buyPnL, 2));
            ClosePositionsByDirection("BUY", "Fast SL - Wrong Direction");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate P&L for specific direction                             |
//+------------------------------------------------------------------+
double CalculatePnLByDirection(string direction)
{
   double totalPnL = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      string posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      if(posDir != direction) continue;
      
      totalPnL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   
   return totalPnL;
}

//+------------------------------------------------------------------+
//| Calculate global P&L                                             |
//+------------------------------------------------------------------+
double CalculateGlobalPnL()
{
   double totalPnL = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      totalPnL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   
   return totalPnL;
}

//+------------------------------------------------------------------+
//| Close positions by direction                                     |
//+------------------------------------------------------------------+
void ClosePositionsByDirection(string direction, string reason)
{
   MqlTradeRequest request;
   MqlTradeResult result;
   
   int closed = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      string posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      if(posDir != direction) continue;
      
      ZeroMemory(request);
      ZeroMemory(result);
      
      request.action = TRADE_ACTION_DEAL;
      request.position = ticket;
      request.symbol = _Symbol;
      request.volume = PositionGetDouble(POSITION_VOLUME);
      request.type = (posDir == "BUY") ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price = (posDir == "BUY") ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      request.deviation = 10;
      request.magic = MagicNumber;
      request.comment = reason;
      
      if(OrderSend(request, result))
      {
         if(result.retcode == TRADE_RETCODE_DONE)
         {
            closed++;
            double profit = PositionGetDouble(POSITION_PROFIT);
            sessionPnL += profit;
            
            if(profit > 0)
               closedProfits++;
            else
               closedLosses++;
         }
      }
   }
   
   if(closed > 0)
      Print("   Closed ", closed, " ", direction, " positions. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Close all positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   Print("🔄 Closing all positions. Reason: ", reason);
   ClosePositionsByDirection("BUY", reason);
   ClosePositionsByDirection("SELL", reason);
}

//+------------------------------------------------------------------+
//| Reset momentum state                                             |
//+------------------------------------------------------------------+
void ResetMomentum()
{
   currentMomentum = MOMENTUM_NONE;
   referencePrice = 0;
   momentumStartTime = 0;
   Print("🔄 Momentum reset - Ready for next signal");
}

//+------------------------------------------------------------------+
//| Check drawdown limit                                             |
//+------------------------------------------------------------------+
bool CheckDrawdownLimit()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   if(equity > peakEquity)
      peakEquity = equity;
   
   double drawdown = ((equity - peakEquity) / peakEquity) * 100.0;
   
   if(drawdown <= -MaxDrawdownPercent)
   {
      Print("═══════════════════════════════════════════════════════════");
      Print("🛑 MAX DRAWDOWN EXCEEDED!");
      Print("   Drawdown: ", DoubleToString(drawdown, 2), "%");
      Print("   Limit: ", MaxDrawdownPercent, "%");
      Print("   Peak Equity: $", peakEquity);
      Print("   Current Equity: $", equity);
      Print("═══════════════════════════════════════════════════════════");
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check if in trading window                                       |
//+------------------------------------------------------------------+
bool IsInTradingWindow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   if(dt.hour >= TradeStartHour && dt.hour < TradeEndHour)
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Get highest BUY price                                            |
//+------------------------------------------------------------------+
double GetHighestBuyPrice()
{
   double highest = 0;
   for(int i = 0; i < ArraySize(buyPositions); i++)
   {
      if(buyPositions[i].entryPrice > highest)
         highest = buyPositions[i].entryPrice;
   }
   return highest;
}

//+------------------------------------------------------------------+
//| Get lowest SELL price                                            |
//+------------------------------------------------------------------+
double GetLowestSellPrice()
{
   double lowest = 999999999;
   for(int i = 0; i < ArraySize(sellPositions); i++)
   {
      if(sellPositions[i].entryPrice < lowest)
         lowest = sellPositions[i].entryPrice;
   }
   return (lowest == 999999999) ? 0 : lowest;
}

//+------------------------------------------------------------------+
//| Create info panel                                                |
//+------------------------------------------------------------------+
void CreateInfoPanel()
{
   int x = 20;
   int y = 100;
   int width = 300;
   int height = 380;  // Increased for S/R display
   
   // Background - Solid and on top
   ObjectCreate(0, panelPrefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YSIZE, height);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BACK, false);  // false = on top of chart
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_ZORDER, 0);  // Bring to front
   
   // Title
   CreateLabel(panelPrefix + "Title", x + 10, y + 10, "NEWS MOMENTUM v" + EA_VERSION, clrGold, 11, "Arial Black");
   
   // Server Time
   CreateLabel(panelPrefix + "ServerTime", x + 10, y + 35, "Server: 00:00:00", clrYellow, 9, "Arial Bold");
   
   // Momentum status
   CreateLabel(panelPrefix + "Momentum", x + 10, y + 60, "⏳ WAITING", clrWhite, 10, "Arial Bold");
   
   // Price
   CreateLabel(panelPrefix + "Price", x + 10, y + 85, "PRICE: 0", clrWhite, 12, "Arial Black");
   
   // Next Buy/Sell levels
   CreateLabel(panelPrefix + "NextBuy", x + 10, y + 110, "Next BUY: ---", clrDodgerBlue, 9, "Arial Bold");
   CreateLabel(panelPrefix + "NextSell", x + 10, y + 130, "Next SELL: ---", clrOrangeRed, 9, "Arial Bold");
   
   // H4 Support & Resistance
   CreateLabel(panelPrefix + "Support", x + 10, y + 155, "H4 Support: ---", clrDodgerBlue, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Resistance", x + 10, y + 175, "H4 Resistance: ---", clrOrangeRed, 9, "Arial Bold");
   
   // Positions
   CreateLabel(panelPrefix + "Buys", x + 10, y + 200, "BUYs: 0/5", clrDodgerBlue, 10, "Arial Bold");
   CreateLabel(panelPrefix + "Sells", x + 170, y + 200, "SELLs: 0/5", clrOrangeRed, 10, "Arial Bold");
   
   // P&L
   CreateLabel(panelPrefix + "BuyPnL", x + 10, y + 225, "BUY P&L: $0", clrDodgerBlue, 9, "Arial");
   CreateLabel(panelPrefix + "SellPnL", x + 170, y + 225, "SELL P&L: $0", clrOrangeRed, 9, "Arial");
   
   CreateLabel(panelPrefix + "GlobalPnL", x + 10, y + 250, "Global: $0/$200", clrWhite, 10, "Arial Bold");
   
   // Balance & Equity
   CreateLabel(panelPrefix + "Balance", x + 10, y + 275, "Bal: $0", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "Equity", x + 170, y + 275, "Eq: $0", clrWhite, 9, "Arial");
   
   // Drawdown
   CreateLabel(panelPrefix + "DD", x + 10, y + 300, "DD: 0%", clrLimeGreen, 9, "Arial");
   
   // Grid & TP/SL
   CreateLabel(panelPrefix + "Grid", x + 10, y + 325, "Grid: 0.15%", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "TPSL", x + 10, y + 345, "TP:$30 SL:$50", clrWhite, 9, "Arial Bold");
   
   // Brand
   CreateLabel(panelPrefix + "Brand", x + 10, y + 365, "TORAMA CAPITAL", clrGold, 8, "Arial Bold");
}

//+------------------------------------------------------------------+
//| Create label helper                                              |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, string font)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);  // On top of chart
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);  // Bring to front
}

//+------------------------------------------------------------------+
//| Update info panel                                                |
//+------------------------------------------------------------------+
void UpdateInfoPanel()
{
   if(!panelVisible) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   //--- Server Time
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string serverTime = StringFormat("%02d:%02d:%02d", dt.hour, dt.min, dt.sec);
   ObjectSetString(0, panelPrefix + "ServerTime", OBJPROP_TEXT, "Server: " + serverTime);
   
   // Momentum status
   string momentumText = "⏳ WAITING";
   color momentumColor = clrGray;
   
   if(emergencyStop)
   {
      momentumText = "🛑 EMERGENCY STOP";
      momentumColor = clrRed;
   }
   else if(currentMomentum == MOMENTUM_UP)
   {
      momentumText = "🔵 BUYING UP";
      momentumColor = clrDodgerBlue;
   }
   else if(currentMomentum == MOMENTUM_DOWN)
   {
      momentumText = "🔴 SELLING DOWN";
      momentumColor = clrOrangeRed;
   }
   
   ObjectSetString(0, panelPrefix + "Momentum", OBJPROP_TEXT, momentumText);
   ObjectSetInteger(0, panelPrefix + "Momentum", OBJPROP_COLOR, momentumColor);
   
   // Price
   ObjectSetString(0, panelPrefix + "Price", OBJPROP_TEXT, "PRICE: " + DoubleToString(currentPrice, digits));
   
   //--- Next Buy/Sell Prices (based on grid)
   string nextBuyText = "Next BUY: ---";
   string nextSellText = "Next SELL: ---";
   
   if(gridSpacing > 0)
   {
      if(currentMomentum == MOMENTUM_UP && ArraySize(buyPositions) > 0)
      {
         // Next BUY is one grid level above highest BUY
         double highestBuy = GetHighestBuyPrice();
         double nextBuyPrice = highestBuy + gridSpacing;
         nextBuyText = "Next BUY: " + DoubleToString(nextBuyPrice, digits);
      }
      else if(currentMomentum == MOMENTUM_NONE)
      {
         // Waiting - show both possible entry levels
         double nextBuyPrice = currentPrice + (currentPrice * GridSpacingPercent / 100.0);
         double nextSellPrice = currentPrice - (currentPrice * GridSpacingPercent / 100.0);
         nextBuyText = "BUY Entry: " + DoubleToString(nextBuyPrice, digits);
         nextSellText = "SELL Entry: " + DoubleToString(nextSellPrice, digits);
      }
      
      if(currentMomentum == MOMENTUM_DOWN && ArraySize(sellPositions) > 0)
      {
         // Next SELL is one grid level below lowest SELL
         double lowestSell = GetLowestSellPrice();
         double nextSellPrice = lowestSell - gridSpacing;
         nextSellText = "Next SELL: " + DoubleToString(nextSellPrice, digits);
      }
      else if(currentMomentum == MOMENTUM_NONE && gridSpacing > 0)
      {
         // Already set above in waiting state
      }
   }
   
   ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, nextBuyText);
   ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, nextSellText);
   
   //--- H4 Support & Resistance
   if(ShowSupportResistance && currentSupport > 0 && currentResistance > 0)
   {
      ObjectSetString(0, panelPrefix + "Support", OBJPROP_TEXT, 
                      "H4 Support: " + DoubleToString(currentSupport, digits));
      ObjectSetString(0, panelPrefix + "Resistance", OBJPROP_TEXT, 
                      "H4 Resistance: " + DoubleToString(currentResistance, digits));
   }
   else
   {
      ObjectSetString(0, panelPrefix + "Support", OBJPROP_TEXT, "H4 Support: ---");
      ObjectSetString(0, panelPrefix + "Resistance", OBJPROP_TEXT, "H4 Resistance: ---");
   }
   
   // Positions
   ObjectSetString(0, panelPrefix + "Buys", OBJPROP_TEXT, 
                   "BUYs: " + IntegerToString(ArraySize(buyPositions)) + "/" + IntegerToString(MaxPositionsPerSide));
   ObjectSetString(0, panelPrefix + "Sells", OBJPROP_TEXT,
                   "SELLs: " + IntegerToString(ArraySize(sellPositions)) + "/" + IntegerToString(MaxPositionsPerSide));
   
   // P&L
   double buyPnL = CalculatePnLByDirection("BUY");
   double sellPnL = CalculatePnLByDirection("SELL");
   double globalPnL = CalculateGlobalPnL();
   
   color buyPnLColor = (buyPnL >= 0) ? clrLimeGreen : clrRed;
   color sellPnLColor = (sellPnL >= 0) ? clrLimeGreen : clrRed;
   color globalPnLColor = (globalPnL >= 0) ? clrLimeGreen : clrRed;
   
   ObjectSetString(0, panelPrefix + "BuyPnL", OBJPROP_TEXT, "BUY P&L: $" + DoubleToString(buyPnL, 2));
   ObjectSetInteger(0, panelPrefix + "BuyPnL", OBJPROP_COLOR, buyPnLColor);
   
   ObjectSetString(0, panelPrefix + "SellPnL", OBJPROP_TEXT, "SELL P&L: $" + DoubleToString(sellPnL, 2));
   ObjectSetInteger(0, panelPrefix + "SellPnL", OBJPROP_COLOR, sellPnLColor);
   
   ObjectSetString(0, panelPrefix + "GlobalPnL", OBJPROP_TEXT,
                   "Global: $" + DoubleToString(globalPnL, 2) + "/$" + DoubleToString(GlobalTPDollars, 0));
   ObjectSetInteger(0, panelPrefix + "GlobalPnL", OBJPROP_COLOR, globalPnLColor);
   
   // Balance & Equity
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   ObjectSetString(0, panelPrefix + "Balance", OBJPROP_TEXT, "Bal: $" + DoubleToString(balance, 2));
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT, "Eq: $" + DoubleToString(equity, 2));
   
   // Drawdown
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   color ddColor = (dd >= -5) ? clrLimeGreen : (dd >= -10) ? clrYellow : clrRed;
   
   ObjectSetString(0, panelPrefix + "DD", OBJPROP_TEXT, "DD: " + DoubleToString(dd, 1) + "%");
   ObjectSetInteger(0, panelPrefix + "DD", OBJPROP_COLOR, ddColor);
   
   // Grid & TP/SL - Show both percentages and calculated dollars
   ObjectSetString(0, panelPrefix + "Grid", OBJPROP_TEXT, 
                   "Grid: " + DoubleToString(GridSpacingPercent, 2) + "% ($" + DoubleToString(gridSpacing, 2) + ")");
   ObjectSetString(0, panelPrefix + "TPSL", OBJPROP_TEXT,
                   "TP: " + DoubleToString(IndividualTPPercent, 0) + "% ($" + DoubleToString(calculatedTPDollars, 2) + 
                   ") | SL: " + DoubleToString(IndividualSLPercent, 0) + "% ($" + DoubleToString(calculatedSLDollars, 2) + ")");
}

//+------------------------------------------------------------------+
