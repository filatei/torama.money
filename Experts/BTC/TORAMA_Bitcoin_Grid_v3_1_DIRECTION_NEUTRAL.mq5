//+------------------------------------------------------------------+
//|                    TORAMA Bitcoin Grid EA v3.1                   |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "3.10"
#property description "Bitcoin Grid EA - DIRECTION NEUTRAL"
#property description "v3.1: STARTS NEUTRAL - Follows first market move, NO BIAS!"
#property description "v3.0: Auto-flip after 2 levels against trend"
#property description "v2.3: Gap-based TP/SL percentages"

#define EA_VERSION "3.1"
#define EA_NAME "BTC GRID"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "=== TREND ADAPTIVE MODE ==="
input int      LevelsBeforeFlip = 2;             // Levels against trend before flip (2-5 recommended)

input group "=== GRID SETTINGS ==="
input double   GridSpacingPercent = 0.30;        // Grid spacing % (0.2-0.5 recommended)
input int      MaxPositions = 30;                // Maximum grid positions
input double   LotSize = 0.1;                    // Lot size per position

input group "=== PROFIT & RISK (% of Gap) ==="
input double   IndividualTPPercent = 300.0;      // Individual TP as % of gap (300 = 3x gap)
input double   IndividualSLPercent = 0.0;        // Individual SL as % of gap (0 = disabled)
input double   GlobalTPPercent = 500.0;          // Global TP as % of gap (500 = 5x gap)
input double   GlobalSLPercent = 0.0;            // Global SL as % of gap (0 = disabled)
input double   SessionProfitPercent = 100.0;     // Session/Daily profit target (% of starting balance)
input bool     ResetSessionDaily = true;         // Reset session profit daily (false = per session)
input double   MaxDrawdownPercent = 20.0;        // Max drawdown % (emergency stop)

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                 // Maximum spread (points)
input int      MagicNumber = 77722;              // Magic number
input bool     ShowPanel = true;                 // Show info panel

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

// v3.1 DIRECTION NEUTRAL - Trading mode enum
enum TradingMode
{
   MODE_NEUTRAL,  // Waiting for first market move
   MODE_BUY,      // Following uptrend
   MODE_SELL      // Following downtrend
};

struct Position
{
   ulong    ticket;
   double   entryPrice;
   datetime entryTime;
};

Position positions[];

// Trading state
TradingMode currentMode = MODE_NEUTRAL;  // v3.1: Start NEUTRAL!
double referencePrice = 0;               // Reference for grid
double highestLevel = 0;                 // Highest grid level
double lowestLevel = 0;                  // Lowest grid level
double currentGapSize = 0;               // Current grid spacing in dollars

// TREND ADAPTIVE v3.0/3.1 - Tracking variables
double highWaterMark = 0;          // Highest price when in BUY mode
double lowWaterMark = 0;           // Lowest price when in SELL mode
double trendStartPrice = 0;        // Price when current trend started
int levelsAgainstTrend = 0;        // Counter for levels moved against current mode
double lastProcessedLevel = 0;     // Last grid level we processed for flip detection

// Risk management
bool emergencyStop = false;
string emergencyReason = "";
double peakEquity = 0;
double totalProfit = 0;

// Session profit tracking
double sessionStartBalance = 0;
double sessionProfit = 0;
double sessionProfitTarget = 0;
datetime lastSessionReset = 0;
int currentDay = 0;
bool sessionTargetReached = false;

// Statistics
int totalTrades = 0;
bool isPaused = false;

// Panel
string panelPrefix = "BTC_";

//+------------------------------------------------------------------+
//| INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("═══════════════════════════════════════");
   Print("🚀 ", EA_NAME, " v", EA_VERSION, " - DIRECTION NEUTRAL");
   Print("═══════════════════════════════════════");
   
   // v3.1: Start in NEUTRAL mode - no bias!
   currentMode = MODE_NEUTRAL;
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Calculate current gap size
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   currentGapSize = currentPrice * GridSpacingPercent / 100.0;
   
   // Initialize trend tracking - all set to current price
   trendStartPrice = currentPrice;
   referencePrice = currentPrice;
   highWaterMark = currentPrice;
   lowWaterMark = currentPrice;
   levelsAgainstTrend = 0;
   lastProcessedLevel = currentPrice;
   
   // Calculate TP/SL values as % of gap
   double individualTPDollars = currentGapSize * IndividualTPPercent / 100.0;
   double individualSLDollars = (IndividualSLPercent > 0) ? (currentGapSize * IndividualSLPercent / 100.0) : 0;
   double globalTPDollars = currentGapSize * GlobalTPPercent / 100.0;
   double globalSLDollars = (GlobalSLPercent > 0) ? (currentGapSize * GlobalSLPercent / 100.0) : 0;
   
   // Initialize session profit tracking
   sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
   sessionProfit = 0;
   sessionTargetReached = false;
   lastSessionReset = TimeCurrent();
   
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   currentDay = time.day;
   
   Print("🎯 DIRECTION NEUTRAL MODE");
   Print("Starting Mode: NEUTRAL (waiting for market move)");
   Print("Will follow first movement: UP→BUY, DOWN→SELL");
   Print("Auto-Flip After: ", LevelsBeforeFlip, " levels against trend");
   Print("Grid Spacing: ", GridSpacingPercent, "% = $", DoubleToString(currentGapSize, 2));
   Print("Individual TP: ", IndividualTPPercent, "% of gap = $", DoubleToString(individualTPDollars, 2));
   Print("Individual SL: ", IndividualSLPercent > 0 ? DoubleToString(IndividualSLPercent, 0) + "% of gap = $" + DoubleToString(individualSLDollars, 2) : "DISABLED");
   Print("Global TP: ", GlobalTPPercent, "% of gap = $", DoubleToString(globalTPDollars, 2));
   Print("Global SL: ", GlobalSLPercent > 0 ? DoubleToString(GlobalSLPercent, 0) + "% of gap = $" + DoubleToString(globalSLDollars, 2) : "DISABLED");
   Print("Session Target: ", SessionProfitPercent, "% = $", DoubleToString(sessionProfitTarget, 2));
   Print("Reset Mode: ", ResetSessionDaily ? "DAILY" : "PER SESSION");
   Print("═══════════════════════════════════════");
   
   // Create panel
   if(ShowPanel) CreatePanel();
   
   // Sync existing positions
   SyncPositions();
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Clean up panel objects
   ObjectsDeleteAll(0, panelPrefix);
   
   string modeStr = (currentMode == MODE_NEUTRAL) ? "NEUTRAL" : (currentMode == MODE_BUY) ? "BUY" : "SELL";
   Print("EA stopped. Total trades: ", totalTrades);
   Print("Final Mode: ", modeStr);
   Print("Levels Against Trend: ", levelsAgainstTrend);
}

//+------------------------------------------------------------------+
//| MAIN TICK FUNCTION                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   // Emergency stop check
   if(emergencyStop)
   {
      UpdatePanel();
      return;
   }
   
   // Session target reached check
   if(sessionTargetReached)
   {
      UpdatePanel();
      return;
   }
   
   // Sync positions
   SyncPositions();
   
   // Check and reset session profit if needed
   CheckSessionReset();
   
   // Check session profit target
   if(CheckSessionProfit())
   {
      sessionTargetReached = true;
      CloseAllPositions();
      Print("╔════════════════════════════════════════════════════════════════╗");
      Print("║          🎯 SESSION TARGET REACHED!                            ║");
      Print("╚════════════════════════════════════════════════════════════════╝");
      Print("Session Profit: $", DoubleToString(sessionProfit, 2));
      Print("Session Target: $", DoubleToString(sessionProfitTarget, 2));
      Print("═══════════════════════════════════════════════════════════════");
      UpdatePanel();
      return;
   }
   
   // Check drawdown
   if(CheckDrawdown())
   {
      emergencyStop = true;
      emergencyReason = "Max Drawdown Exceeded";
      CloseAllPositions();
      
      // Calculate current drawdown for display
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double currentDrawdown = -((equity - peakEquity) / peakEquity) * 100.0;
      
      Print("╔════════════════════════════════════════════════════════════════╗");
      Print("║          🛑 EA STOPPED - MAX DRAWDOWN EXCEEDED!                ║");
      Print("╚════════════════════════════════════════════════════════════════╝");
      Print("Max Drawdown Limit: ", MaxDrawdownPercent, "%");
      Print("Current Drawdown: ", DoubleToString(currentDrawdown, 2), "%");
      Print("EMERGENCY STOP ACTIVATED!");
      Print("═══════════════════════════════════════════════════════════════");
      UpdatePanel();
      return;
   }
   
   // Check global TP/SL (calculate from gap)
   CalculateTotalProfit();
   
   // Update current gap size
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   currentGapSize = currentPrice * GridSpacingPercent / 100.0;
   
   double globalTPDollars = currentGapSize * GlobalTPPercent / 100.0;
   double globalSLDollars = (GlobalSLPercent > 0) ? (currentGapSize * GlobalSLPercent / 100.0) : 0;
   
   // Check Global TP
   if(GlobalTPPercent > 0 && totalProfit >= globalTPDollars)
   {
      Print("✅ GLOBAL TP HIT: $", DoubleToString(totalProfit, 2), " (Target: $", DoubleToString(globalTPDollars, 2), ")");
      CloseAllPositions();
      ResetGrid();
      UpdatePanel();
      return;
   }
   
   // Check Global SL
   if(GlobalSLPercent > 0 && totalProfit <= -globalSLDollars)
   {
      Print("🛑 GLOBAL SL HIT: $", DoubleToString(totalProfit, 2), " (Limit: $", DoubleToString(globalSLDollars, 2), ")");
      CloseAllPositions();
      emergencyStop = true;
      emergencyReason = "Global SL Reached";
      Print("╔════════════════════════════════════════════════════════════════╗");
      Print("║          🛑 EA STOPPED - GLOBAL SL REACHED!                    ║");
      Print("╚════════════════════════════════════════════════════════════════╝");
      Print("Global SL Limit: ", GlobalSLPercent, "% of gap");
      Print("Total Loss Exceeded Global SL");
      Print("EMERGENCY STOP ACTIVATED!");
      Print("═══════════════════════════════════════════════════════════════");
      UpdatePanel();
      return;
   }
   
   // v3.0 TREND ADAPTIVE: Check if we should flip direction
   CheckTrendFlip();
   
   // Check spread
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > MaxSpread) return;
   
   // Don't trade if paused
   if(isPaused)
   {
      UpdatePanel();
      return;
   }
   
   // Main trading logic
   ManageGrid();
   
   // Update panel
   if(ShowPanel) UpdatePanel();
}

//+------------------------------------------------------------------+
//| CHART EVENT HANDLER (Buttons)                                    |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      // SWITCH MODE button - cycles NEUTRAL → BUY → SELL → NEUTRAL
      if(sparam == panelPrefix + "SwitchBtn")
      {
         if(currentMode == MODE_NEUTRAL)
            currentMode = MODE_BUY;
         else if(currentMode == MODE_BUY)
            currentMode = MODE_SELL;
         else
            currentMode = MODE_NEUTRAL;
            
         string modeStr = (currentMode == MODE_NEUTRAL) ? "NEUTRAL" : (currentMode == MODE_BUY) ? "BUY" : "SELL";
         Print("🔄 Switched to ", modeStr, " mode");
         ResetGrid();
         ObjectSetInteger(0, panelPrefix + "SwitchBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      
      // CLOSE PROFITS button
      else if(sparam == panelPrefix + "CloseProfitsBtn")
      {
         CloseAllProfitablePositions();
         ObjectSetInteger(0, panelPrefix + "CloseProfitsBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      
      // PAUSE button
      else if(sparam == panelPrefix + "PauseBtn")
      {
         isPaused = !isPaused;
         Print(isPaused ? "⏸️ EA PAUSED" : "▶️ EA RESUMED");
         ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      
      // CLOSE ALL button
      else if(sparam == panelPrefix + "CloseAllBtn")
      {
         CloseAllPositions();
         ResetGrid();
         ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
   }
}

//+------------------------------------------------------------------+
//| GRID MANAGEMENT - Core Trading Logic                             |
//+------------------------------------------------------------------+
void ManageGrid()
{
   // v3.1: Don't trade if NEUTRAL - wait for CheckTrendFlip to set direction
   if(currentMode == MODE_NEUTRAL) return;
   
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double gridSpacing = currentPrice * (GridSpacingPercent / 100.0);
   
   int posCount = ArraySize(positions);
   
   // Initialize grid if no positions
   if(posCount == 0)
   {
      if(OpenPosition(currentPrice))
      {
         referencePrice = currentPrice;
         highestLevel = currentPrice;
         lowestLevel = currentPrice;
      }
      return;
   }
   
   // Check if we should add positions
   if(posCount >= MaxPositions) return;
   
   // REPLACEABLE GRID LOGIC
   // Add positions both above and below existing grid
   
   if(currentMode == MODE_BUY)
   {
      // BUY MODE: Grid up and down
      // Add BUY above when price rises (follow momentum)
      if(currentPrice >= highestLevel + gridSpacing)
      {
         if(OpenPosition(currentPrice))
         {
            highestLevel = currentPrice;
         }
      }
      
      // Add BUY below when price falls (average down)
      else if(currentPrice <= lowestLevel - gridSpacing)
      {
         if(OpenPosition(currentPrice))
         {
            lowestLevel = currentPrice;
         }
      }
   }
   else
   {
      // SELL MODE: Grid up and down
      // Add SELL below when price falls (follow momentum)
      if(currentPrice <= lowestLevel - gridSpacing)
      {
         if(OpenPosition(currentPrice))
         {
            lowestLevel = currentPrice;
         }
      }
      
      // Add SELL above when price rises (average down)
      else if(currentPrice >= highestLevel + gridSpacing)
      {
         if(OpenPosition(currentPrice))
         {
            highestLevel = currentPrice;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TP/SL DISTANCE BASED ON DESIRED PROFIT                 |
//| This is the CORRECT way to handle micro/mini contracts          |
//+------------------------------------------------------------------+
double CalculateTPSLDistance(double desiredProfitDollars, double lotSize, string direction)
{
   // If desired profit is 0, return 0
   if(desiredProfitDollars <= 0) return 0;
   
   // Get current price for testing
   double currentPrice = (direction == "BUY") ? 
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
                         SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Test with $100 price movement to find profit ratio
   double testDistance = 100.0;
   
   // CRITICAL: Test movement must be in PROFIT direction!
   // BUY: profit when price goes UP (+100)
   // SELL: profit when price goes DOWN (-100)
   double testPriceTo = (direction == "BUY") ? 
                        currentPrice + testDistance :   // BUY: test price above
                        currentPrice - testDistance;    // SELL: test price below
   
   double testProfit = 0;
   
   ENUM_ORDER_TYPE orderType = (direction == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   // Calculate what profit $100 movement gives with current lot size
   if(OrderCalcProfit(orderType, _Symbol, lotSize, currentPrice, testPriceTo, testProfit))
   {
      testProfit = MathAbs(testProfit);  // Ensure positive
      
      if(testProfit > 0.0001)  // Avoid division by zero
      {
         // Calculate profit per $1 price movement
         double profitPerDollar = testProfit / testDistance;
         
         // Calculate price distance needed for desired profit
         double neededDistance = desiredProfitDollars / profitPerDollar;
         
         Print("💡 TP/SL Calculation:");
         Print("   Desired profit: $", DoubleToString(desiredProfitDollars, 2));
         Print("   Test: $", testDistance, " movement = $", DoubleToString(testProfit, 2), " profit");
         Print("   Profit per $1: $", DoubleToString(profitPerDollar, 4));
         Print("   Needed distance: $", DoubleToString(neededDistance, 2));
         
         return neededDistance;
      }
   }
   
   // Fallback: if OrderCalcProfit fails, use simple distance
   // This works for standard contracts where 1 lot = 1 unit
   Print("⚠️ OrderCalcProfit failed, using simple distance");
   return desiredProfitDollars;
}

//+------------------------------------------------------------------+
//| OPEN POSITION - PROFIT-BASED TP/SL Calculation                   |
//+------------------------------------------------------------------+
bool OpenPosition(double price)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.type = (currentMode == MODE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price = (currentMode == MODE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = EA_NAME + " v" + EA_VERSION;
   request.type_filling = ORDER_FILLING_IOC;
   
   // ==================================================================
   // GAP-BASED TP/SL CALCULATION v2.3 - Using % of Grid Spacing
   // TP/SL calculated as percentage of current gap size
   // Calculates price distance needed to achieve desired PROFIT
   // Works on ANY broker, ANY contract size, ANY lot size
   // ==================================================================
   
   string direction = (currentMode == MODE_BUY) ? "BUY" : "SELL";
   
   // Update current gap size
   currentGapSize = request.price * GridSpacingPercent / 100.0;
   
   // Calculate TP/SL dollar amounts from gap percentages
   double individualTPDollars = currentGapSize * IndividualTPPercent / 100.0;
   double individualSLDollars = (IndividualSLPercent > 0) ? (currentGapSize * IndividualSLPercent / 100.0) : 0;
   
   Print("📊 Opening ", direction, " position:");
   Print("   Entry price: $", DoubleToString(request.price, 2));
   Print("   Gap size: $", DoubleToString(currentGapSize, 2));
   Print("   TP Target: ", IndividualTPPercent, "% of gap = $", DoubleToString(individualTPDollars, 2), " profit");
   if(IndividualSLPercent > 0)
      Print("   SL Limit: ", IndividualSLPercent, "% of gap = $", DoubleToString(individualSLDollars, 2), " loss");
   Print("   Lot size: ", LotSize);
   
   // Calculate TP and SL distances based on DESIRED PROFIT
   double tpDistance = CalculateTPSLDistance(individualTPDollars, LotSize, direction);
   double slDistance = (individualSLDollars > 0) ? CalculateTPSLDistance(individualSLDollars, LotSize, direction) : 0;
   
   // Set TP and SL prices
   if(currentMode == MODE_BUY)
   {
      // BUY: TP above entry, SL below entry
      request.tp = (tpDistance > 0) ? request.price + tpDistance : 0;
      request.sl = (slDistance > 0) ? request.price - slDistance : 0;
   }
   else  // SELL
   {
      // SELL: TP below entry, SL above entry
      request.tp = (tpDistance > 0) ? request.price - tpDistance : 0;
      request.sl = (slDistance > 0) ? request.price + slDistance : 0;
   }
   
   Print("   TP distance: $", DoubleToString(tpDistance, 2), " → TP price: $", DoubleToString(request.tp, 2));
   if(slDistance > 0)
      Print("   SL distance: $", DoubleToString(slDistance, 2), " → SL price: $", DoubleToString(request.sl, 2));
   
   // Verify minimum stop distance (broker requirements)
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minStopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   
   if(minStopLevel > 0)
   {
      if(currentMode == MODE_BUY)
      {
         if(request.tp > 0 && request.tp - request.price < minStopLevel)
         {
            Print("⚠️ Adjusting TP to meet minimum stop level");
            request.tp = request.price + minStopLevel;
         }
         if(request.sl > 0 && request.price - request.sl < minStopLevel)
         {
            Print("⚠️ Adjusting SL to meet minimum stop level");
            request.sl = request.price - minStopLevel;
         }
      }
      else // SELL
      {
         if(request.tp > 0 && request.price - request.tp < minStopLevel)
         {
            Print("⚠️ Adjusting TP to meet minimum stop level");
            request.tp = request.price - minStopLevel;
         }
         if(request.sl > 0 && request.sl - request.price < minStopLevel)
         {
            Print("⚠️ Adjusting SL to meet minimum stop level");
            request.sl = request.price + minStopLevel;
         }
      }
   }
   
   // Normalize prices
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   request.price = NormalizeDouble(request.price, digits);
   request.tp = NormalizeDouble(request.tp, digits);
   request.sl = NormalizeDouble(request.sl, digits);
   
   // Send order
   if(!OrderSend(request, result))
   {
      Print("❌ Order failed: ", GetLastError());
      return false;
   }
   
   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      // Add to positions array
      int newSize = ArraySize(positions) + 1;
      ArrayResize(positions, newSize);
      positions[newSize-1].ticket = result.order;
      positions[newSize-1].entryPrice = result.price;
      positions[newSize-1].entryTime = TimeCurrent();
      
      totalTrades++;
      
      // Calculate actual TP/SL for display
      double displayTPDollars = currentGapSize * IndividualTPPercent / 100.0;
      double displaySLDollars = (IndividualSLPercent > 0) ? (currentGapSize * IndividualSLPercent / 100.0) : 0;
      
      string modeStr = (currentMode == MODE_BUY) ? "BUY" : "SELL";
      Print("✅ ", modeStr, " @ ", DoubleToString(result.price, digits), 
            " | TP: ", IndividualTPPercent, "% ($", DoubleToString(displayTPDollars, 2), ")",
            " | SL: ", IndividualSLPercent > 0 ? DoubleToString(IndividualSLPercent, 0) + "% ($" + DoubleToString(displaySLDollars, 2) + ")" : "OFF",
            " | Positions: ", newSize, "/", MaxPositions);
      
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| SYNC POSITIONS                                                    |
//+------------------------------------------------------------------+
void SyncPositions()
{
   ArrayResize(positions, 0);
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      int newSize = ArraySize(positions) + 1;
      ArrayResize(positions, newSize);
      positions[newSize-1].ticket = ticket;
      positions[newSize-1].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      positions[newSize-1].entryTime = (datetime)PositionGetInteger(POSITION_TIME);
   }
   
   // Update grid levels
   if(ArraySize(positions) > 0)
   {
      highestLevel = positions[0].entryPrice;
      lowestLevel = positions[0].entryPrice;
      
      for(int i = 1; i < ArraySize(positions); i++)
      {
         if(positions[i].entryPrice > highestLevel)
            highestLevel = positions[i].entryPrice;
         if(positions[i].entryPrice < lowestLevel)
            lowestLevel = positions[i].entryPrice;
      }
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                           |
//+------------------------------------------------------------------+
void CalculateTotalProfit()
{
   totalProfit = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
}

//+------------------------------------------------------------------+
//| CHECK DRAWDOWN                                                    |
//+------------------------------------------------------------------+
bool CheckDrawdown()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   if(equity > peakEquity)
      peakEquity = equity;
   
   double drawdown = ((equity - peakEquity) / peakEquity) * 100.0;
   
   return (drawdown <= -MaxDrawdownPercent);
}

//+------------------------------------------------------------------+
//| v3.1 DIRECTION NEUTRAL: CHECK TREND AND DETECT FIRST MOVE        |
//+------------------------------------------------------------------+
void CheckTrendFlip()
{
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double gridSpacing = currentPrice * GridSpacingPercent / 100.0;
   
   // v3.1: If NEUTRAL - detect first movement
   if(currentMode == MODE_NEUTRAL)
   {
      // Check if price has moved a full grid level from reference
      double priceMove = currentPrice - referencePrice;
      
      if(MathAbs(priceMove) >= gridSpacing)
      {
         if(priceMove > 0)
         {
            // Price moved UP - start BUY mode
            Print("╔════════════════════════════════════════════════════════════════╗");
            Print("║           📈 FIRST MOVE DETECTED: UP                           ║");
            Print("╚════════════════════════════════════════════════════════════════╝");
            Print("Start Price: $", DoubleToString(referencePrice, 2));
            Print("Current Price: $", DoubleToString(currentPrice, 2));
            Print("Movement: +$", DoubleToString(priceMove, 2));
            Print("Entering: BUY MODE");
            Print("═══════════════════════════════════════════════════════════════");
            
            currentMode = MODE_BUY;
            highWaterMark = currentPrice;
            lowWaterMark = currentPrice;
            levelsAgainstTrend = 0;
            lastProcessedLevel = currentPrice;
            
            Print("═══════════════════════════════════════════════════════════════");
            Print("📈 FIRST MOVE: UP → BUY MODE ACTIVATED");
            Print("═══════════════════════════════════════════════════════════════");
            UpdatePanel();
         }
         else
         {
            // Price moved DOWN - start SELL mode
            Print("╔════════════════════════════════════════════════════════════════╗");
            Print("║           📉 FIRST MOVE DETECTED: DOWN                         ║");
            Print("╚════════════════════════════════════════════════════════════════╝");
            Print("Start Price: $", DoubleToString(referencePrice, 2));
            Print("Current Price: $", DoubleToString(currentPrice, 2));
            Print("Movement: -$", DoubleToString(MathAbs(priceMove), 2));
            Print("Entering: SELL MODE");
            Print("═══════════════════════════════════════════════════════════════");
            
            currentMode = MODE_SELL;
            highWaterMark = currentPrice;
            lowWaterMark = currentPrice;
            levelsAgainstTrend = 0;
            lastProcessedLevel = currentPrice;
            
            Print("═══════════════════════════════════════════════════════════════");
            Print("📉 FIRST MOVE: DOWN → SELL MODE ACTIVATED");
            Print("═══════════════════════════════════════════════════════════════");
            UpdatePanel();
         }
      }
      return;  // In NEUTRAL mode, just detect first move
   }
   
   // Already in BUY or SELL mode - check for reversal
   if(currentMode == MODE_BUY)
   {
      // In BUY mode - track highest price reached
      if(currentPrice > highWaterMark)
      {
         highWaterMark = currentPrice;
         lastProcessedLevel = currentPrice;
         levelsAgainstTrend = 0;  // Reset counter when making new highs
      }
      else
      {
         // Price dropping - check if we've dropped enough levels to flip
         double priceDrop = highWaterMark - currentPrice;
         double levelsDropped = priceDrop / gridSpacing;
         
         // Only process if we've moved at least one full level from last processed
         if(MathAbs(currentPrice - lastProcessedLevel) >= gridSpacing)
         {
            levelsAgainstTrend = (int)levelsDropped;
            lastProcessedLevel = currentPrice;
            
            // Check if we should flip to SELL
            if(levelsAgainstTrend >= LevelsBeforeFlip)
            {
               FlipTrendDirection("DOWN");
            }
         }
      }
   }
   else if(currentMode == MODE_SELL)
   {
      // In SELL mode - track lowest price reached
      if(currentPrice < lowWaterMark)
      {
         lowWaterMark = currentPrice;
         lastProcessedLevel = currentPrice;
         levelsAgainstTrend = 0;  // Reset counter when making new lows
      }
      else
      {
         // Price rising - check if we've risen enough levels to flip
         double priceRise = currentPrice - lowWaterMark;
         double levelsRisen = priceRise / gridSpacing;
         
         // Only process if we've moved at least one full level from last processed
         if(MathAbs(currentPrice - lastProcessedLevel) >= gridSpacing)
         {
            levelsAgainstTrend = (int)levelsRisen;
            lastProcessedLevel = currentPrice;
            
            // Check if we should flip to BUY
            if(levelsAgainstTrend >= LevelsBeforeFlip)
            {
               FlipTrendDirection("UP");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| v3.1 DIRECTION NEUTRAL: FLIP TRADING DIRECTION                   |
//+------------------------------------------------------------------+
void FlipTrendDirection(string trendDirection)
{
   string oldMode = (currentMode == MODE_BUY) ? "BUY" : "SELL";
   
   // Flip the mode
   if(StringCompare(trendDirection, "UP") == 0)
      currentMode = MODE_BUY;
   else
      currentMode = MODE_SELL;
   
   string newMode = (currentMode == MODE_BUY) ? "BUY" : "SELL";
   
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   
   Print("╔════════════════════════════════════════════════════════════════╗");
   Print("║           🔄 TREND FLIP DETECTED                               ║");
   Print("╚════════════════════════════════════════════════════════════════╝");
   Print("Trend Direction: ", trendDirection);
   Print("Levels Against Trend: ", levelsAgainstTrend);
   Print("Flipping: ", oldMode, " → ", newMode);
   Print("Current Price: $", DoubleToString(currentPrice, 2));
   if(currentMode == MODE_BUY)
      Print("Low Water Mark: $", DoubleToString(lowWaterMark, 2));
   else
      Print("High Water Mark: $", DoubleToString(highWaterMark, 2));
   Print("═══════════════════════════════════════════════════════════════");
   
   // Reset tracking for new direction
   trendStartPrice = currentPrice;
   highWaterMark = currentPrice;
   lowWaterMark = currentPrice;
   levelsAgainstTrend = 0;
   lastProcessedLevel = currentPrice;
   
   // Alert user
   Print("═══════════════════════════════════════════════════════════════");
   Print("🔄 TREND FLIP: ", oldMode, " → ", newMode, " | Levels: ", levelsAgainstTrend);
   Print("═══════════════════════════════════════════════════════════════");
   
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| CHECK SESSION RESET (Daily or Per Session)                       |
//+------------------------------------------------------------------+
void CheckSessionReset()
{
   if(SessionProfitPercent <= 0) return;  // Disabled
   
   if(ResetSessionDaily)
   {
      // Reset daily at midnight
      MqlDateTime time;
      TimeToStruct(TimeCurrent(), time);
      
      if(time.day != currentDay)
      {
         // New day - reset session
         currentDay = time.day;
         sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
         sessionProfit = 0;
         sessionTargetReached = false;
         lastSessionReset = TimeCurrent();
         
         Print("🌅 NEW DAY - Session reset");
         Print("   Start Balance: $", DoubleToString(sessionStartBalance, 2));
         Print("   Profit Target: $", DoubleToString(sessionProfitTarget, 2));
      }
   }
   // If not daily reset, session only resets when EA is restarted
}

//+------------------------------------------------------------------+
//| CHECK SESSION PROFIT TARGET                                      |
//+------------------------------------------------------------------+
bool CheckSessionProfit()
{
   if(SessionProfitPercent <= 0) return false;  // Disabled
   
   // Calculate session profit
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionProfit = currentBalance - sessionStartBalance;
   
   // Check if target reached
   if(sessionProfit >= sessionProfitTarget)
   {
      Print("╔════════════════════════════════════════════════════════════════╗");
      Print("║            SESSION PROFIT TARGET REACHED                       ║");
      Print("╚════════════════════════════════════════════════════════════════╝");
      Print("Start Balance: $", DoubleToString(sessionStartBalance, 2));
      Print("Current Balance: $", DoubleToString(currentBalance, 2));
      Print("Session Profit: $", DoubleToString(sessionProfit, 2));
      Print("Target: $", DoubleToString(sessionProfitTarget, 2), " (", SessionProfitPercent, "%)");
      Print("*** EA PAUSED - Restart EA to resume trading ***");
      
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                              |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      
      request.action = TRADE_ACTION_DEAL;
      request.position = ticket;
      request.symbol = _Symbol;
      request.volume = PositionGetDouble(POSITION_VOLUME);
      request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      request.deviation = 10;
      request.magic = MagicNumber;
      request.type_filling = ORDER_FILLING_IOC;
      
      if(!OrderSend(request, result))
      {
         Print("⚠️ Failed to close position #", ticket, ": ", result.retcode);
      }
   }
   
   Print("🔄 All positions closed");
}

//+------------------------------------------------------------------+
//| CLOSE PROFITABLE POSITIONS ONLY                                  |
//+------------------------------------------------------------------+
void CloseAllProfitablePositions()
{
   int closedCount = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      
      if(profit > 0)
      {
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         
         request.action = TRADE_ACTION_DEAL;
         request.position = ticket;
         request.symbol = _Symbol;
         request.volume = PositionGetDouble(POSITION_VOLUME);
         request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         request.deviation = 10;
         request.magic = MagicNumber;
         request.type_filling = ORDER_FILLING_IOC;
         
         if(OrderSend(request, result))
            closedCount++;
      }
   }
   
   Print("✅ Closed ", closedCount, " profitable positions");
}

//+------------------------------------------------------------------+
//| RESET GRID                                                        |
//+------------------------------------------------------------------+
void ResetGrid()
{
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   
   referencePrice = 0;
   highestLevel = 0;
   lowestLevel = 0;
   ArrayResize(positions, 0);
   
   // v3.0: Reset trend tracking
   trendStartPrice = currentPrice;
   highWaterMark = currentPrice;
   lowWaterMark = currentPrice;
   levelsAgainstTrend = 0;
   lastProcessedLevel = currentPrice;
   
   Print("🔄 Grid Reset | Trend tracking reset at $", DoubleToString(currentPrice, 2));
}

//+------------------------------------------------------------------+
//| PANEL MANAGEMENT                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| CREATE PANEL                                                      |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 10, y = 20;
   int width = 380, height = 265;  // INCREASED height from 240 to 265 for session line
   
   // Background
   ObjectCreate(0, panelPrefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YSIZE, height);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BGCOLOR, C'20,20,20');  // Solid dark background
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BACK, false);  // On top, not behind!
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_ZORDER, 0);  // Highest priority
   
   // Header - Title and Status on same line
   CreateLabel(panelPrefix + "Title", x + 10, y + 10, EA_NAME + " v" + EA_VERSION, clrGold, 12, "Arial Bold");
   CreateLabel(panelPrefix + "Status", x + 250, y + 10, "ACTIVE", clrLimeGreen, 10, "Arial Bold");
   
   // Mode indicator
   CreateLabel(panelPrefix + "Mode", x + 10, y + 35, "Mode:", clrWhite, 10, "Arial");
   CreateLabel(panelPrefix + "ModeValue", x + 70, y + 35, "BUY ONLY", clrDodgerBlue, 11, "Arial Bold");
   
   // Buttons - all in two rows
   CreateButton(panelPrefix + "SwitchBtn", x + 10, y + 60, 90, 28, "SWITCH", clrGold, clrBlack);
   CreateButton(panelPrefix + "CloseProfitsBtn", x + 105, y + 60, 90, 28, "CLOSE +P/L", clrGreen, clrBlack);
   CreateButton(panelPrefix + "PauseBtn", x + 200, y + 60, 80, 28, "PAUSE", clrOrange, clrBlack);
   CreateButton(panelPrefix + "CloseAllBtn", x + 285, y + 60, 85, 28, "CLOSE ALL", clrRed, clrWhite);
   
   // Price, Grid, and Trend on compact lines
   CreateLabel(panelPrefix + "PriceLabel", x + 10, y + 100, "Price:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Price", x + 55, y + 100, "$0", clrWhite, 10, "Arial Bold");
   CreateLabel(panelPrefix + "GridLabel", x + 180, y + 100, "Grid:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "GridSpacing", x + 220, y + 100, "0.30%", clrWhite, 9, "Arial");
   
   // v3.0 TREND ADAPTIVE - Water marks
   CreateLabel(panelPrefix + "WaterMarkLabel", x + 10, y + 120, "WaterMark:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "WaterMark", x + 85, y + 120, "$0", clrCyan, 9, "Arial Bold");
   CreateLabel(panelPrefix + "FlipLabel", x + 180, y + 120, "Flip@:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "FlipLevel", x + 220, y + 120, "0", clrYellow, 9, "Arial Bold");
   
   // v3.0 Trend info
   CreateLabel(panelPrefix + "TrendLabel", x + 10, y + 140, "Trend:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "TrendInfo", x + 60, y + 140, "0/2 levels", clrWhite, 9, "Arial Bold");
   
   // Positions and P/L on same line
   CreateLabel(panelPrefix + "PositionsLabel", x + 10, y + 165, "Positions:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Positions", x + 80, y + 165, "0/30", clrWhite, 11, "Arial Bold");
   CreateLabel(panelPrefix + "PnLLabel", x + 180, y + 165, "P/L:", clrGray, 10, "Arial Bold");
   CreateLabel(panelPrefix + "PnL", x + 215, y + 165, "$0.00", clrWhite, 13, "Arial Black");  // LARGER for visibility
   
   // Equity and DD on same line
   CreateLabel(panelPrefix + "EquityLabel", x + 10, y + 190, "Equity:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Equity", x + 65, y + 190, "$0", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "DDLabel", x + 180, y + 190, "DD:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "DD", x + 210, y + 190, "0.0%", clrLimeGreen, 9, "Arial");
   
   // Session Profit on same line
   CreateLabel(panelPrefix + "SessionLabel", x + 10, y + 210, "Session:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "SessionProfit", x + 70, y + 210, "$0", clrWhite, 10, "Arial Bold");
   CreateLabel(panelPrefix + "TargetLabel", x + 180, y + 210, "Target:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "SessionTarget", x + 230, y + 210, "$0", clrGray, 9, "Arial");
   
   // TORAMA CAPITAL - BOLD and BIG on bottom right (moved down to avoid overlap)
   CreateLabel(panelPrefix + "Brand", x + 215, y + 240, "TORAMA CAPITAL", clrGold, 11, "Arial Black");
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!ShowPanel) return;
   
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Status (now just shows status without "Status:" label)
   if(sessionTargetReached)
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "🎯 TARGET");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrGold);
   }
   else if(emergencyStop)
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "🛑 STOP");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrRed);
   }
   else if(isPaused)
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "⏸️ PAUSED");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrOrange);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "✅ ACTIVE");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrLimeGreen);
   }
   
   // Mode (update value only) - v3.1 shows NEUTRAL/BUY/SELL
   string modeText = "";
   color modeColor = clrWhite;
   
   if(currentMode == MODE_NEUTRAL)
   {
      modeText = "⚪ NEUTRAL";
      modeColor = clrGray;
   }
   else if(currentMode == MODE_BUY)
   {
      modeText = "🔵 BUY";
      modeColor = clrDodgerBlue;
   }
   else
   {
      modeText = "🔴 SELL";
      modeColor = clrOrangeRed;
   }
   
   ObjectSetString(0, panelPrefix + "ModeValue", OBJPROP_TEXT, modeText);
   ObjectSetInteger(0, panelPrefix + "ModeValue", OBJPROP_COLOR, modeColor);
   
   // Pause button text
   ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, isPaused ? "RESUME" : "PAUSE");
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, isPaused ? clrGreen : clrOrange);
   
   // Price (value only)
   ObjectSetString(0, panelPrefix + "Price", OBJPROP_TEXT, 
                   "$" + DoubleToString(currentPrice, digits));
   
   // Grid (value only)
   ObjectSetString(0, panelPrefix + "GridSpacing", OBJPROP_TEXT,
                   DoubleToString(GridSpacingPercent, 2) + "% ($" + 
                   DoubleToString(currentPrice * GridSpacingPercent / 100.0, 2) + ")");
   
   // v3.1 TREND ADAPTIVE - Water mark display
   double waterMark = (currentMode == MODE_BUY) ? highWaterMark : lowWaterMark;
   string waterMarkLabel = (currentMode == MODE_NEUTRAL) ? "Ref" : (currentMode == MODE_BUY) ? "High" : "Low";
   ObjectSetString(0, panelPrefix + "WaterMark", OBJPROP_TEXT,
                   waterMarkLabel + ": $" + DoubleToString(waterMark, digits));
   
   // Flip level info
   int levelsToFlip = LevelsBeforeFlip - levelsAgainstTrend;
   color flipColor = (levelsAgainstTrend >= LevelsBeforeFlip - 1) ? clrRed : 
                     (levelsAgainstTrend >= 1) ? clrYellow : clrLimeGreen;
   ObjectSetString(0, panelPrefix + "FlipLevel", OBJPROP_TEXT,
                   IntegerToString(levelsToFlip) + " lvls");
   ObjectSetInteger(0, panelPrefix + "FlipLevel", OBJPROP_COLOR, flipColor);
   
   // Trend counter
   string trendText = IntegerToString(levelsAgainstTrend) + "/" + IntegerToString(LevelsBeforeFlip) + " levels";
   ObjectSetString(0, panelPrefix + "TrendInfo", OBJPROP_TEXT, trendText);
   
   // Positions (value only)
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT,
                   IntegerToString(ArraySize(positions)) + "/" + IntegerToString(MaxPositions));
   
   // P/L (value only)
   CalculateTotalProfit();
   color pnlColor = (totalProfit >= 0) ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "PnL", OBJPROP_TEXT,
                   (totalProfit >= 0 ? "+" : "") + "$" + DoubleToString(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "PnL", OBJPROP_COLOR, pnlColor);
   
   // Equity (value only)
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT,
                   "$" + DoubleToString(equity, 2));
   
   // Drawdown (value only)
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   color ddColor = (dd >= -5) ? clrLimeGreen : (dd >= -10) ? clrYellow : clrRed;
   ObjectSetString(0, panelPrefix + "DD", OBJPROP_TEXT,
                   DoubleToString(dd, 1) + "%");
   ObjectSetInteger(0, panelPrefix + "DD", OBJPROP_COLOR, ddColor);
   
   // Session Profit (value only)
   if(SessionProfitPercent > 0)
   {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      sessionProfit = currentBalance - sessionStartBalance;
      double sessionPercent = (sessionStartBalance > 0) ? (sessionProfit / sessionStartBalance * 100.0) : 0;
      
      color sessionColor = (sessionProfit >= sessionProfitTarget) ? clrGold : 
                           (sessionProfit >= 0) ? clrLimeGreen : clrRed;
      
      ObjectSetString(0, panelPrefix + "SessionProfit", OBJPROP_TEXT,
                      (sessionProfit >= 0 ? "+" : "") + "$" + DoubleToString(sessionProfit, 2) + 
                      " (" + DoubleToString(sessionPercent, 1) + "%)");
      ObjectSetInteger(0, panelPrefix + "SessionProfit", OBJPROP_COLOR, sessionColor);
      
      ObjectSetString(0, panelPrefix + "SessionTarget", OBJPROP_TEXT,
                      "$" + DoubleToString(sessionProfitTarget, 2));
   }
   else
   {
      ObjectSetString(0, panelPrefix + "SessionProfit", OBJPROP_TEXT, "DISABLED");
      ObjectSetInteger(0, panelPrefix + "SessionProfit", OBJPROP_COLOR, clrGray);
      ObjectSetString(0, panelPrefix + "SessionTarget", OBJPROP_TEXT, "OFF");
   }
}

//+------------------------------------------------------------------+
//| CREATE LABEL                                                      |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, string font)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| CREATE BUTTON                                                     |
//+------------------------------------------------------------------+
void CreateButton(string name, int x, int y, int width, int height, string text, color bgColor, color txtColor)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, txtColor);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrGold);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
}

//+------------------------------------------------------------------+
