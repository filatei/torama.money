//+------------------------------------------------------------------+
//|                    TORAMA Universal Grid EA v3.11                |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "3.11"
#property description "Universal Grid EA - Works on BTC, Gold, Forex, Indices & More"
#property description "v3.11: Universal lot size validation for all instruments"
#property description "v3.1: DIRECTION NEUTRAL - Follows first market move"
#property description "v3.0: Auto-flip trend detection with water marks"

#define EA_VERSION "3.11"
#define EA_NAME "TORAMA GRID"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "=== TREND ADAPTIVE MODE ==="
input int      LevelsBeforeFlip = 2;             // Levels against trend before flip (2-5 recommended)
input bool     CloseOnFlip = false;              // Close positions when flipping direction (default: NO)

input group "=== GRID SETTINGS ==="
input double   GridSpacingPercent = 0.30;        // Grid spacing % (0.2-0.5 recommended)
input int      MaxPositions = 30;                // Maximum grid positions
input double   LotSize = 0.1;                    // Lot size per position

input group "=== PROFIT & RISK (% of Gap) ==="
input double   IndividualTPPercent = 300.0;      // Individual TP as % of gap (300 = 3x gap)
input double   IndividualSLPercent = 0.0;        // Individual SL as % of gap (0 = disabled)
input double   GlobalTPPercent = 500.0;          // Global TP as % of gap (500 = 5x gap)
input double   GlobalSLPercent = 0.0;            // Global SL as % of gap (0 = disabled)
input int      AutoCloseProfitableCount = 5;    // Auto-close when X positions profitable (0 = OFF)
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
string panelPrefix = "TORAMA_";
bool panelVisible = true;  // Toggle with 'H' key

// v3.11: Lot size validation
double validatedLotSize = 0;
double minLot = 0;
double maxLot = 0;
double lotStep = 0;

//+------------------------------------------------------------------+
//| VALIDATE AND NORMALIZE LOT SIZE                                  |
//+------------------------------------------------------------------+
double ValidateLotSize(double requestedLots)
{
   // Get symbol lot specifications
   minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   // Check if requested lot is below minimum
   if(requestedLots < minLot)
   {
      Print("⚠️ WARNING: Requested lot size ", requestedLots, " is below minimum ", minLot, ". Using minimum.");
      return minLot;
   }
   
   // Check if requested lot is above maximum
   if(requestedLots > maxLot)
   {
      Print("⚠️ WARNING: Requested lot size ", requestedLots, " exceeds maximum ", maxLot, ". Using maximum.");
      return maxLot;
   }
   
   // Normalize to lot step
   double normalizedLots = MathFloor(requestedLots / lotStep) * lotStep;
   
   // Ensure we don't go below minimum after normalization
   if(normalizedLots < minLot)
      normalizedLots = minLot;
   
   // Round to proper decimal places
   int lotDigits = 2;
   if(lotStep >= 0.1) lotDigits = 1;
   else if(lotStep >= 1.0) lotDigits = 0;
   
   normalizedLots = NormalizeDouble(normalizedLots, lotDigits);
   
   if(normalizedLots != requestedLots)
   {
      Print("ℹ️ INFO: Lot size adjusted from ", requestedLots, " to ", normalizedLots, 
            " (min=", minLot, ", max=", maxLot, ", step=", lotStep, ")");
   }
   
   return normalizedLots;
}

//+------------------------------------------------------------------+
//| INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("═══════════════════════════════════════");
   Print("🚀 ", EA_NAME, " v", EA_VERSION, " - UNIVERSAL");
   Print("═══════════════════════════════════════");
   
   // v3.11: Validate lot size for current symbol
   validatedLotSize = ValidateLotSize(LotSize);
   
   Print("📊 SYMBOL SPECIFICATIONS:");
   Print("Symbol: ", _Symbol);
   Print("Minimum Lot: ", minLot);
   Print("Maximum Lot: ", maxLot);
   Print("Lot Step: ", lotStep);
   Print("Requested Lot: ", LotSize);
   Print("✅ Validated Lot: ", validatedLotSize);
   
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
   
   Print("🎯 SIMPLIFIED GRID LOGIC");
   Print("Starting Mode: NEUTRAL (waiting for first grid level)");
   Print("Direction Signal: FIRST GRID BREACH (not half-movement)");
   Print("UP by 1 grid → BUY mode | DOWN by 1 grid → SELL mode");
   Print("Auto-Flip After: ", LevelsBeforeFlip, " levels against trend");
   Print("Close On Flip: ", CloseOnFlip ? "YES (closes opposite positions)" : "NO (keeps all positions)");
   Print("Grid Spacing: ", GridSpacingPercent, "% = $", DoubleToString(currentGapSize, 2));
   Print("First Position Opens: When price moves ±1 full grid level");
   Print("Individual TP: ", IndividualTPPercent, "% of gap = $", DoubleToString(individualTPDollars, 2));
   Print("Individual SL: ", IndividualSLPercent > 0 ? DoubleToString(IndividualSLPercent, 0) + "% of gap = $" + DoubleToString(individualSLDollars, 2) : "DISABLED");
   Print("Global TP: ", GlobalTPPercent, "% of gap = $", DoubleToString(globalTPDollars, 2));
   Print("Global SL: ", GlobalSLPercent > 0 ? DoubleToString(GlobalSLPercent, 0) + "% of gap = $" + DoubleToString(globalSLDollars, 2) : "DISABLED");
   Print("Auto-Close Profitable: ", AutoCloseProfitableCount > 0 ? IntegerToString(AutoCloseProfitableCount) + " positions" : "DISABLED");
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
   Print("═══════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| MAIN TICK FUNCTION                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   // Update panel
   if(ShowPanel) UpdatePanel();
   
   // Check for daily session reset
   if(ResetSessionDaily)
   {
      MqlDateTime time;
      TimeToStruct(TimeCurrent(), time);
      if(time.day != currentDay)
      {
         currentDay = time.day;
         sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         sessionProfit = 0;
         sessionTargetReached = false;
         Print("🔄 Daily session reset. New start balance: $", DoubleToString(sessionStartBalance, 2));
      }
   }
   
   // Check if paused
   if(isPaused)
      return;
   
   // Check emergency stop
   if(emergencyStop)
   {
      Print("⛔ Emergency stop active: ", emergencyReason);
      return;
   }
   
   // Check session target
   if(SessionProfitPercent > 0 && !sessionTargetReached)
   {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      sessionProfit = currentBalance - sessionStartBalance;
      if(sessionProfit >= sessionProfitTarget)
      {
         sessionTargetReached = true;
         Print("🎯 SESSION TARGET REACHED! Profit: $", DoubleToString(sessionProfit, 2));
         Print("Current balance: $", DoubleToString(currentBalance, 2));
         Print("Trading paused until next ", ResetSessionDaily ? "day" : "session");
         isPaused = true;
         return;
      }
   }
   
   // Update peak equity
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(currentEquity > peakEquity)
      peakEquity = currentEquity;
   
   // Check drawdown limit
   if(MaxDrawdownPercent > 0 && peakEquity > 0)
   {
      double currentDD = (currentEquity - peakEquity) / peakEquity * 100;
      if(currentDD <= -MaxDrawdownPercent)
      {
         emergencyStop = true;
         emergencyReason = StringFormat("Drawdown %.1f%% exceeded limit %.1f%%", currentDD, MaxDrawdownPercent);
         Print("🛑 EMERGENCY STOP: ", emergencyReason);
         CloseAllPositions();
         return;
      }
   }
   
   // Check spread
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPoints > MaxSpread)
   {
      return; // Wait for better spread
   }
   
   // Get current price
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   // Update current gap size based on current price
   currentGapSize = currentPrice * GridSpacingPercent / 100.0;
   
   // Sync positions
   SyncPositions();
   
   // Calculate total profit
   CalculateTotalProfit();
   
   // Auto-close profitable positions if enabled
   if(AutoCloseProfitableCount > 0)
   {
      CheckAutoCloseProfitable();
   }
   
   // Check global TP/SL
   CheckGlobalTPSL();
   
   // SIMPLIFIED DIRECTION LOGIC: First grid level = direction indicator
   if(currentMode == MODE_NEUTRAL && ArraySize(positions) == 0)
   {
      // Set reference price to current price
      referencePrice = currentPrice;
      highWaterMark = currentPrice;
      lowWaterMark = currentPrice;
      trendStartPrice = currentPrice;
      lastProcessedLevel = currentPrice;
   }
   
   // NEUTRAL MODE: Wait for price to hit first grid level (full gap)
   if(currentMode == MODE_NEUTRAL && ArraySize(positions) == 0)
   {
      // Debug logging every 100 ticks (reduce log spam)
      static int tickCounter = 0;
      tickCounter++;
      if(tickCounter % 100 == 0)
      {
         Print("⚪ NEUTRAL: Ref=$", DoubleToString(referencePrice, 2), 
               " Current=$", DoubleToString(currentPrice, 2),
               " Gap=$", DoubleToString(currentGapSize, 2),
               " Need: Up≥$", DoubleToString(referencePrice + currentGapSize, 2),
               " or Down≤$", DoubleToString(referencePrice - currentGapSize, 2));
      }
      
      // Price moved UP by one full grid level → Enter BUY mode
      if(currentPrice >= referencePrice + currentGapSize)
      {
         currentMode = MODE_BUY;
         referencePrice = currentPrice; // New reference at entry
         trendStartPrice = currentPrice;
         highWaterMark = currentPrice;
         levelsAgainstTrend = 0;
         lastProcessedLevel = currentPrice;
         Print("🔵 FIRST GRID UP BREACHED → BUY MODE at $", DoubleToString(currentPrice, 2));
         Print("   Ref was: $", DoubleToString(referencePrice - currentGapSize, 2), 
               " | Moved: $", DoubleToString(currentGapSize, 2));
         
         // Open first BUY position
         if(OpenPosition(ORDER_TYPE_BUY, currentPrice))
         {
            Print("✅ First BUY position opened");
         }
         return;
      }
      // Price moved DOWN by one full grid level → Enter SELL mode
      else if(currentPrice <= referencePrice - currentGapSize)
      {
         currentMode = MODE_SELL;
         referencePrice = currentPrice; // New reference at entry
         trendStartPrice = currentPrice;
         lowWaterMark = currentPrice;
         levelsAgainstTrend = 0;
         lastProcessedLevel = currentPrice;
         Print("🔴 FIRST GRID DOWN BREACHED → SELL MODE at $", DoubleToString(currentPrice, 2));
         Print("   Ref was: $", DoubleToString(referencePrice + currentGapSize, 2),
               " | Moved: $", DoubleToString(currentGapSize, 2));
         
         // Open first SELL position
         if(OpenPosition(ORDER_TYPE_SELL, currentPrice))
         {
            Print("✅ First SELL position opened");
         }
         return;
      }
      
      return; // Still waiting for first grid level breach
   }
   
   // SIMPLIFIED REVERSAL LOGIC: Track levels against current mode
   if(currentMode == MODE_BUY)
   {
      // Update high water mark in BUY mode
      if(currentPrice > highWaterMark)
      {
         highWaterMark = currentPrice;
         levelsAgainstTrend = 0; // Reset when making new highs
         lastProcessedLevel = currentPrice;
      }
      
      // Check if price dropped from high by enough levels
      if(currentPrice < lastProcessedLevel - currentGapSize)
      {
         int newLevels = (int)MathFloor((lastProcessedLevel - currentPrice) / currentGapSize);
         levelsAgainstTrend += newLevels;
         lastProcessedLevel = currentPrice;
         
         Print("📉 BUY mode: Dropped ", newLevels, " level(s). Total against: ", levelsAgainstTrend, "/", LevelsBeforeFlip);
         
         // Flip to SELL if dropped enough levels
         if(levelsAgainstTrend >= LevelsBeforeFlip)
         {
            Print("🔄 FLIPPING TO SELL after ", levelsAgainstTrend, " levels down from high");
            
            if(CloseOnFlip)
            {
               Print("🔒 Closing all BUY positions before flip...");
               ClosePositionsByType(ORDER_TYPE_BUY);
            }
            
            currentMode = MODE_SELL;
            referencePrice = currentPrice;
            trendStartPrice = currentPrice;
            lowWaterMark = currentPrice;
            levelsAgainstTrend = 0;
            lastProcessedLevel = currentPrice;
         }
      }
   }
   else if(currentMode == MODE_SELL)
   {
      // Update low water mark in SELL mode
      if(currentPrice < lowWaterMark)
      {
         lowWaterMark = currentPrice;
         levelsAgainstTrend = 0; // Reset when making new lows
         lastProcessedLevel = currentPrice;
      }
      
      // Check if price rose from low by enough levels
      if(currentPrice > lastProcessedLevel + currentGapSize)
      {
         int newLevels = (int)MathFloor((currentPrice - lastProcessedLevel) / currentGapSize);
         levelsAgainstTrend += newLevels;
         lastProcessedLevel = currentPrice;
         
         Print("📈 SELL mode: Rose ", newLevels, " level(s). Total against: ", levelsAgainstTrend, "/", LevelsBeforeFlip);
         
         // Flip to BUY if rose enough levels
         if(levelsAgainstTrend >= LevelsBeforeFlip)
         {
            Print("🔄 FLIPPING TO BUY after ", levelsAgainstTrend, " levels up from low");
            
            if(CloseOnFlip)
            {
               Print("🔒 Closing all SELL positions before flip...");
               ClosePositionsByType(ORDER_TYPE_SELL);
            }
            
            currentMode = MODE_BUY;
            referencePrice = currentPrice;
            trendStartPrice = currentPrice;
            highWaterMark = currentPrice;
            levelsAgainstTrend = 0;
            lastProcessedLevel = currentPrice;
         }
      }
   }
   
   // Normal grid trading logic (after mode is determined)
   if(currentMode != MODE_NEUTRAL && ArraySize(positions) < MaxPositions)
   {
      CheckGridLevels();
   }
}

//+------------------------------------------------------------------+
//| SYNC POSITIONS                                                    |
//+------------------------------------------------------------------+
void SyncPositions()
{
   ArrayResize(positions, 0);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            int size = ArraySize(positions);
            ArrayResize(positions, size + 1);
            positions[size].ticket = ticket;
            positions[size].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            positions[size].entryTime = (datetime)PositionGetInteger(POSITION_TIME);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                            |
//+------------------------------------------------------------------+
void CalculateTotalProfit()
{
   totalProfit = 0;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         totalProfit += PositionGetDouble(POSITION_PROFIT);
      }
   }
}

//+------------------------------------------------------------------+
//| CHECK GRID LEVELS                                                 |
//+------------------------------------------------------------------+
void CheckGridLevels()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   // Update gap size
   currentGapSize = currentPrice * GridSpacingPercent / 100.0;
   
   // Determine which type to open based on mode
   ENUM_ORDER_TYPE orderType;
   if(currentMode == MODE_BUY)
      orderType = ORDER_TYPE_BUY;
   else if(currentMode == MODE_SELL)
      orderType = ORDER_TYPE_SELL;
   else
      return; // Shouldn't happen, but safety check
   
   // Check if we should open a new position
   bool shouldOpen = false;
   
   if(ArraySize(positions) == 0)
   {
      shouldOpen = true;
      referencePrice = currentPrice;
   }
   else
   {
      // Find highest and lowest positions
      double highestPrice = positions[0].entryPrice;
      double lowestPrice = positions[0].entryPrice;
      
      for(int i = 1; i < ArraySize(positions); i++)
      {
         if(positions[i].entryPrice > highestPrice)
            highestPrice = positions[i].entryPrice;
         if(positions[i].entryPrice < lowestPrice)
            lowestPrice = positions[i].entryPrice;
      }
      
      highestLevel = highestPrice;
      lowestLevel = lowestPrice;
      
      // Check if price has moved enough from existing positions
      if(orderType == ORDER_TYPE_BUY)
      {
         // For BUY mode, open new position if price is at least one grid above highest
         if(currentPrice >= highestPrice + currentGapSize)
         {
            shouldOpen = true;
         }
      }
      else // ORDER_TYPE_SELL
      {
         // For SELL mode, open new position if price is at least one grid below lowest
         if(currentPrice <= lowestPrice - currentGapSize)
         {
            shouldOpen = true;
         }
      }
   }
   
   if(shouldOpen && ArraySize(positions) < MaxPositions)
   {
      OpenPosition(orderType, currentPrice);
   }
}

//+------------------------------------------------------------------+
//| OPEN POSITION                                                     |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE type, double price)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = validatedLotSize;  // v3.11: Use validated lot size
   request.type = type;
   request.price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   request.deviation = 10;
   request.magic = MagicNumber;
   
   // Calculate TP and SL in price
   double individualTPDollars = currentGapSize * IndividualTPPercent / 100.0;
   double individualSLDollars = (IndividualSLPercent > 0) ? (currentGapSize * IndividualSLPercent / 100.0) : 0;
   
   if(type == ORDER_TYPE_BUY)
   {
      if(IndividualTPPercent > 0)
         request.tp = request.price + individualTPDollars;
      if(IndividualSLPercent > 0)
         request.sl = request.price - individualSLDollars;
   }
   else
   {
      if(IndividualTPPercent > 0)
         request.tp = request.price - individualTPDollars;
      if(IndividualSLPercent > 0)
         request.sl = request.price + individualSLDollars;
   }
   
   // Normalize prices
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   request.tp = NormalizeDouble(request.tp, digits);
   request.sl = NormalizeDouble(request.sl, digits);
   
   // Send order
   if(!OrderSend(request, result))
   {
      Print("❌ Order failed: ", result.retcode, " - ", GetErrorDescription(result.retcode));
      Print("   Type: ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"));
      Print("   Volume: ", validatedLotSize);
      Print("   Price: ", request.price);
      return false;
   }
   
   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      totalTrades++;
      Print("✅ ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), " #", result.order, " | Lots: ", validatedLotSize, 
            " | Price: $", DoubleToString(request.price, digits), 
            " | TP: $", DoubleToString(request.tp, digits));
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| GET ERROR DESCRIPTION                                             |
//+------------------------------------------------------------------+
string GetErrorDescription(int code)
{
   switch(code)
   {
      case 4756: return "Invalid order volume (check symbol lot specifications)";
      case 10004: return "Requote";
      case 10006: return "Request rejected";
      case 10007: return "Request canceled by trader";
      case 10008: return "Order placed";
      case 10009: return "Request completed";
      case 10010: return "Only part of request completed";
      case 10011: return "Request processing error";
      case 10012: return "Request canceled by timeout";
      case 10013: return "Invalid request";
      case 10014: return "Invalid volume in request";
      case 10015: return "Invalid price in request";
      case 10016: return "Invalid stops in request";
      case 10017: return "Trade disabled";
      case 10018: return "Market closed";
      case 10019: return "No money";
      case 10020: return "Prices changed";
      case 10021: return "No quotes to process request";
      case 10022: return "Invalid order expiration";
      case 10023: return "Order state changed";
      case 10024: return "Too frequent requests";
      case 10025: return "No changes in request";
      case 10026: return "Autotrading disabled by server";
      case 10027: return "Autotrading disabled by client";
      case 10028: return "Request locked for processing";
      case 10029: return "Order or position frozen";
      case 10030: return "Invalid order filling type";
      case 10031: return "No connection";
      case 10032: return "Operation allowed only for live accounts";
      case 10033: return "Number of pending orders reached limit";
      case 10034: return "Volume of orders and positions reached limit";
      case 10035: return "Invalid or prohibited order type";
      case 10036: return "Position already closed";
      default: return "Unknown error";
   }
}

//+------------------------------------------------------------------+
//| CHECK AUTO CLOSE PROFITABLE                                       |
//+------------------------------------------------------------------+
void CheckAutoCloseProfitable()
{
   if(AutoCloseProfitableCount <= 0) return;
   
   int profitableCount = 0;
   
   // Count profitable positions
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0)
            profitableCount++;
      }
   }
   
   // Close all if threshold reached
   if(profitableCount >= AutoCloseProfitableCount)
   {
      Print("🎯 Auto-closing ", profitableCount, " profitable positions (threshold: ", AutoCloseProfitableCount, ")");
      CloseAllPositions();
   }
}

//+------------------------------------------------------------------+
//| CHECK GLOBAL TP/SL                                                |
//+------------------------------------------------------------------+
void CheckGlobalTPSL()
{
   if(GlobalTPPercent <= 0 && GlobalSLPercent <= 0) return;
   if(ArraySize(positions) == 0) return;
   
   CalculateTotalProfit();
   
   double globalTPDollars = currentGapSize * GlobalTPPercent / 100.0;
   double globalSLDollars = (GlobalSLPercent > 0) ? (currentGapSize * GlobalSLPercent / 100.0) : 0;
   
   // Check global TP
   if(GlobalTPPercent > 0 && totalProfit >= globalTPDollars)
   {
      Print("🎯 Global TP reached: $", DoubleToString(totalProfit, 2), " >= $", DoubleToString(globalTPDollars, 2));
      CloseAllPositions();
      return;
   }
   
   // Check global SL
   if(GlobalSLPercent > 0 && totalProfit <= -globalSLDollars)
   {
      Print("🛑 Global SL hit: $", DoubleToString(totalProfit, 2), " <= -$", DoubleToString(globalSLDollars, 2));
      CloseAllPositions();
      return;
   }
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      ClosePosition(positions[i].ticket);
   }
   
   SyncPositions();
}

//+------------------------------------------------------------------+
//| CLOSE POSITIONS BY TYPE                                           |
//+------------------------------------------------------------------+
void ClosePositionsByType(ENUM_ORDER_TYPE type)
{
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         bool shouldClose = false;
         
         if(type == ORDER_TYPE_BUY && posType == POSITION_TYPE_BUY)
            shouldClose = true;
         else if(type == ORDER_TYPE_SELL && posType == POSITION_TYPE_SELL)
            shouldClose = true;
         
         if(shouldClose)
            ClosePosition(positions[i].ticket);
      }
   }
   
   SyncPositions();
}

//+------------------------------------------------------------------+
//| CLOSE POSITION                                                    |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = PositionGetString(POSITION_SYMBOL);
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.deviation = 10;
   request.magic = MagicNumber;
   
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   request.type = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   if(!OrderSend(request, result))
   {
      Print("❌ Close position failed: ", result.retcode);
   }
}

//+------------------------------------------------------------------+
//| CHART EVENT HANDLER                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Handle keyboard events for panel toggle
   if(id == CHARTEVENT_KEYDOWN)
   {
      // H key = 72, h key = 104
      if(lparam == 72 || lparam == 104)
      {
         panelVisible = !panelVisible;
         TogglePanelVisibility();
         Print(panelVisible ? "👁️ Panel shown" : "👁️ Panel hidden (Press H to show)");
      }
   }
   
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == panelPrefix + "SwitchBtn")
      {
         ObjectSetInteger(0, panelPrefix + "SwitchBtn", OBJPROP_STATE, false);
         
         // v3.1: Cycle through NEUTRAL → BUY → SELL → NEUTRAL
         if(currentMode == MODE_NEUTRAL)
         {
            currentMode = MODE_BUY;
            trendStartPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
            highWaterMark = trendStartPrice;
            levelsAgainstTrend = 0;
            Print("🔵 Manual switch: NEUTRAL → BUY");
         }
         else if(currentMode == MODE_BUY)
         {
            currentMode = MODE_SELL;
            trendStartPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
            lowWaterMark = trendStartPrice;
            levelsAgainstTrend = 0;
            Print("🔴 Manual switch: BUY → SELL");
         }
         else
         {
            currentMode = MODE_NEUTRAL;
            double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
            referencePrice = currentPrice;
            highWaterMark = currentPrice;
            lowWaterMark = currentPrice;
            levelsAgainstTrend = 0;
            Print("⚪ Manual switch: SELL → NEUTRAL");
         }
      }
      else if(sparam == panelPrefix + "CloseBtn")
      {
         ObjectSetInteger(0, panelPrefix + "CloseBtn", OBJPROP_STATE, false);
         
         if(ArraySize(positions) > 0)
         {
            double profitBeforeClose = totalProfit;
            CloseAllPositions();
            Print("🔒 Manual close: ", ArraySize(positions), " positions | P/L: $", DoubleToString(profitBeforeClose, 2));
         }
      }
      else if(sparam == panelPrefix + "PauseBtn")
      {
         ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_STATE, false);
         isPaused = !isPaused;
         Print(isPaused ? "⏸️ EA PAUSED" : "▶️ EA RESUMED");
      }
      else if(sparam == panelPrefix + "CloseAllBtn")
      {
         ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_STATE, false);
         
         if(ArraySize(positions) > 0)
         {
            double profitBeforeClose = totalProfit;
            CloseAllPositions();
            Print("🔒 CLOSE ALL: ", ArraySize(positions), " positions | P/L: $", DoubleToString(profitBeforeClose, 2));
            
            // v3.1: Return to NEUTRAL after closing all
            currentMode = MODE_NEUTRAL;
            double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
            referencePrice = currentPrice;
            highWaterMark = currentPrice;
            lowWaterMark = currentPrice;
            levelsAgainstTrend = 0;
            Print("⚪ Returned to NEUTRAL mode");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| TOGGLE PANEL VISIBILITY                                          |
//+------------------------------------------------------------------+
void TogglePanelVisibility()
{
   // Get list of all panel objects
   string objects[] = {
      "Background", "Title", "Status", "ModeLabel", "ModeValue",
      "SwitchBtn", "CloseBtn", "PauseBtn", "CloseAllBtn",
      "PriceLabel", "Price", "GridLabel", "GridSpacing",
      "WaterMark", "FlipLabel", "FlipLevel",
      "GridRefLabel", "GridRef",
      "TrendLabel", "TrendInfo",
      "PositionsLabel", "Positions",
      "PnLLabel", "PnL",
      "EquityLabel", "Equity",
      "DDLabel", "DD",
      "SessionLabel", "SessionProfit",
      "TargetLabel", "SessionTarget",
      "LotLabel", "LotSize",
      "Brand", "ToggleHint"
   };
   
   // Toggle visibility for all panel objects
   for(int i = 0; i < ArraySize(objects); i++)
   {
      string objName = panelPrefix + objects[i];
      if(ObjectFind(0, objName) >= 0)
      {
         ObjectSetInteger(0, objName, OBJPROP_TIMEFRAMES, panelVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
      }
   }
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| CREATE PANEL                                                      |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 20;
   int y = 30;
   int width = 320;
   int height = 270;
   
   // Main panel background - SOLID BLACK, on top of all chart elements
   ObjectCreate(0, panelPrefix + "Background", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YSIZE, height);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BACK, false);  // false = on top of chart
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_ZORDER, 0);  // Top layer
   
   // Header - BIGGER and BOLDER
   CreateLabel(panelPrefix + "Title", x + 10, y + 8, EA_NAME + " v" + EA_VERSION, clrGold, 12, "Arial Black");
   
   // Status indicator (top right)
   CreateLabel(panelPrefix + "Status", x + 240, y + 8, "ACTIVE", clrLimeGreen, 10, "Arial Bold");
   
   // Mode section
   CreateLabel(panelPrefix + "ModeLabel", x + 10, y + 35, "Mode:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "ModeValue", x + 60, y + 35, "BUY", clrDodgerBlue, 10, "Arial Bold");
   
   // Buttons - BIGGER and more visible (moved to top)
   CreateButton(panelPrefix + "SwitchBtn", x + 10, y + 55, 95, 25, "SWITCH", clrGold, clrBlack);
   CreateButton(panelPrefix + "CloseBtn", x + 110, y + 55, 95, 25, "CLOSE +P/L", clrGreen, clrBlack);
   CreateButton(panelPrefix + "PauseBtn", x + 210, y + 55, 95, 25, "PAUSE", clrOrange, clrBlack);
   CreateButton(panelPrefix + "CloseAllBtn", x + 110, y + 85, 95, 25, "CLOSE ALL", clrRed, clrWhite);
   
   // Price section
   CreateLabel(panelPrefix + "PriceLabel", x + 10, y + 120, "Price:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Price", x + 60, y + 120, "$0", clrWhite, 10, "Arial Bold");
   
   // Grid section
   CreateLabel(panelPrefix + "GridLabel", x + 180, y + 120, "Grid:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "GridSpacing", x + 220, y + 120, "0%", clrWhite, 9, "Arial");
   
   // v3.1 TREND ADAPTIVE - Water mark tracking
   CreateLabel(panelPrefix + "WaterMark", x + 10, y + 85, "High: $0", clrYellow, 9, "Arial Bold");
   CreateLabel(panelPrefix + "FlipLabel", x + 210, y + 85, "Flip@:", clrGray, 8, "Arial");
   CreateLabel(panelPrefix + "FlipLevel", x + 250, y + 85, "0 lvls", clrLimeGreen, 9, "Arial Bold");
   
   // Grid Reference Price - Base price for all grid calculations
   CreateLabel(panelPrefix + "GridRefLabel", x + 10, y + 107, "Ref:", clrGray, 8, "Arial");
   CreateLabel(panelPrefix + "GridRef", x + 40, y + 107, "$0", clrCyan, 9, "Arial Bold");
   
   // Trend counter
   CreateLabel(panelPrefix + "TrendLabel", x + 10, y + 140, "Trend:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "TrendInfo", x + 60, y + 140, "0/2 levels", clrWhite, 9, "Arial");
   
   // Positions section
   CreateLabel(panelPrefix + "PositionsLabel", x + 10, y + 160, "Positions:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Positions", x + 80, y + 160, "0/30", clrWhite, 9, "Arial");
   
   // P/L section
   CreateLabel(panelPrefix + "PnLLabel", x + 180, y + 160, "P/L:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "PnL", x + 220, y + 160, "$0.00", clrWhite, 10, "Arial Bold");
   
   // Equity section
   CreateLabel(panelPrefix + "EquityLabel", x + 10, y + 180, "Equity:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Equity", x + 60, y + 180, "$0", clrWhite, 9, "Arial");
   
   // Drawdown section
   CreateLabel(panelPrefix + "DDLabel", x + 180, y + 180, "DD:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "DD", x + 220, y + 180, "0.0%", clrWhite, 9, "Arial");
   
   // Session profit section
   CreateLabel(panelPrefix + "SessionLabel", x + 10, y + 200, "Session:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "SessionProfit", x + 70, y + 200, "$0.00", clrGray, 9, "Arial");
   
   // Target section
   CreateLabel(panelPrefix + "TargetLabel", x + 180, y + 200, "Target:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "SessionTarget", x + 230, y + 200, "$0", clrGray, 9, "Arial");
   
   // v3.11: LOT SIZE INDICATOR (bottom left area)
   CreateLabel(panelPrefix + "LotLabel", x + 10, y + 230, "Lot:", clrGray, 8, "Arial");
   CreateLabel(panelPrefix + "LotSize", x + 40, y + 230, DoubleToString(validatedLotSize, 2), clrLightBlue, 9, "Arial Bold");
   
   // TORAMA CAPITAL - Bottom right corner inside panel with proper margin
   CreateLabel(panelPrefix + "Brand", x + width - 145, y + height - 30, "TORAMA CAPITAL", clrGold, 10, "Arial Black");
   
   // Toggle hint - Bottom left, small text
   CreateLabel(panelPrefix + "ToggleHint", x + 10, y + height - 15, "Press H to hide/show", clrDimGray, 7, "Arial");
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!ShowPanel) return;
   
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Status
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
   
   // Mode
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
   
   // Price
   ObjectSetString(0, panelPrefix + "Price", OBJPROP_TEXT, 
                   "$" + DoubleToString(currentPrice, digits));
   
   // Grid
   ObjectSetString(0, panelPrefix + "GridSpacing", OBJPROP_TEXT,
                   DoubleToString(GridSpacingPercent, 2) + "% ($" + 
                   DoubleToString(currentPrice * GridSpacingPercent / 100.0, 2) + ")");
   
   // Water mark
   double waterMark = (currentMode == MODE_BUY) ? highWaterMark : lowWaterMark;
   string waterMarkLabel = (currentMode == MODE_NEUTRAL) ? "Ref" : (currentMode == MODE_BUY) ? "High" : "Low";
   ObjectSetString(0, panelPrefix + "WaterMark", OBJPROP_TEXT,
                   waterMarkLabel + ": $" + DoubleToString(waterMark, digits));
   
   // Grid Reference Price - Shows the base price from which all grid levels are calculated
   ObjectSetString(0, panelPrefix + "GridRef", OBJPROP_TEXT,
                   "$" + DoubleToString(referencePrice, digits));
   
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
   
   // Positions
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT,
                   IntegerToString(ArraySize(positions)) + "/" + IntegerToString(MaxPositions));
   
   // P/L
   CalculateTotalProfit();
   color pnlColor = (totalProfit >= 0) ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "PnL", OBJPROP_TEXT,
                   (totalProfit >= 0 ? "+" : "") + "$" + DoubleToString(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "PnL", OBJPROP_COLOR, pnlColor);
   
   // Equity
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT,
                   "$" + DoubleToString(equity, 2));
   
   // Drawdown
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   color ddColor = (dd >= -5) ? clrLimeGreen : (dd >= -10) ? clrYellow : clrRed;
   ObjectSetString(0, panelPrefix + "DD", OBJPROP_TEXT,
                   DoubleToString(dd, 1) + "%");
   ObjectSetInteger(0, panelPrefix + "DD", OBJPROP_COLOR, ddColor);
   
   // Session Profit
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
   
   // v3.11: Update lot size display
   ObjectSetString(0, panelPrefix + "LotSize", OBJPROP_TEXT, DoubleToString(validatedLotSize, 2));
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
