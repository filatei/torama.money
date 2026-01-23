//+------------------------------------------------------------------+
//|                    TORAMA Aggressive Trader EA v6.1.0            |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "6.10"
#property description "Aggressive Directional Grid Trader"
#property description "Trades in chosen direction (BUY, SELL, or BOTH) at every grid level"
#property description "Replaces closed positions automatically"
#property description ""
#property description "V6.1.0: Added trend-based trading direction filter"
#property description "         (BUY ONLY in uptrends, SELL ONLY in downtrends, BOTH in ranging markets)"

#define EA_VERSION "6.2.0"
#define EA_NAME "TORAMA AGGRESSIVE TRADER"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

enum ENUM_TRADE_DIRECTION
{
   BUYONLY,    // BUY ONLY - Buys up and down the grid
   SELLONLY,   // SELL ONLY - Sells up and down the grid
   BOTH        // BOTH - Places BUY and SELL at every grid level
};

input group "=== CORE SETTINGS ==="
input int      MagicNumber = 777811;                  // Magic number for order identification
input ENUM_TRADE_DIRECTION StartDirection = BUYONLY;  // Trading Direction (BUY, SELL, or BOTH)
input double   LotSize = 0.1;                         // Lot size per position
input bool     ShowPanel = true;                      // Show info panel

input group "=== GRID SETTINGS ==="
input double   GridGapPercent = 0.05;                 // Grid gap % (0.01 = tight, 0.3 = wide)
input int      MaxPositions = 100;                    // Maximum positions
int      MaxSpread = 2000;                      // Maximum spread (points)

input group "=== PROFIT & LOSS ==="
input double   IndividualTPDollars = 50.0;            // Individual TP target per position
input double   GroupTPDollars = 200.0;                // Group TP closes all positions
input double   IndividualSLDollars = 0.0;             // SL risk per trade (0 = disabled)
input double   MaxDrawdownPercent = 50.0;             // Max drawdown % (SACROSANCT)
input double   DailyTargetPercent = 300.0;            // Daily profit target %

input group "=== TIME FILTER ==="
input bool     EnableTimeFilter = false;              // Enable time-based trading
input int      TradingStartHour = 6;                  // Trading start hour (WAT)
input int      TradingStartMinute = 0;                // Trading start minute
input int      TradingEndHour = 17;                   // Trading end hour (WAT)
input int      TradingEndMinute = 0;                  // Trading end minute

input group "=== TREND DISPLAY ==="
input ENUM_TIMEFRAMES TrendTimeframe = PERIOD_H1;     // Timeframe for trend detection
input int      TrendMAPeriod = 20;                    // MA period for trend
input double   TrendThreshold = 0.1;                  // Trend threshold % (below = ranging)

input group "=== TREND FILTER ==="
input bool     EnableTrendFilter = false;             // Enable trend-based direction filter
input string   TrendFilterInfo = "BUY in UP, SELL in DOWN, BOTH in RANGING";  // Info

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

struct Position
{
   ulong    ticket;
   double   entryPrice;
   datetime entryTime;
   ENUM_POSITION_TYPE posType;  // Track if BUY or SELL
};

Position positions[];

// Current trading mode (can be switched manually via MODE button)
ENUM_TRADE_DIRECTION CurrentDirection;

// Grid tracking
double referencePrice = 0;
double currentGapSize = 0;

// Risk management - SACROSANCT VALUES
bool emergencyStop = false;
string emergencyReason = "";
double startingBalance = 0;                // SACRED: Set once at init, NEVER changes
double maxDrawdownStopLevel = 0;           // SACRED: Absolute equity level where EA stops
double totalProfit = 0;

// Daily profit tracking
double dailyStartBalance = 0;
double dailyProfit = 0;
double dailyTarget = 0;
datetime lastDayCheck = 0;
int currentDay = 0;
bool dailyTargetReached = false;

// Statistics
int totalTrades = 0;
bool isPaused = false;
int modeSwitchCount = 0;

// Panel
string panelPrefix = "TORAMA_AGG_";
bool panelVisible = true;

// Trend detection
int trendMAHandle = INVALID_HANDLE;
string currentTrend = "---";
int currentTrendState = 0;  // -1 = DOWN, 0 = RANGING, 1 = UP

// Symbol specifications (cached)
struct SymbolSpecs
{
   double contractSize;
   double tickValue;
   double tickSize;
   double point;
   long stopLevel;
   int digits;
   double minLot;
   double maxLot;
   double lotStep;
   double minStopDistance;
};

SymbolSpecs specs;
double validatedLotSize = 0;

//+------------------------------------------------------------------+
//| INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("═══════════════════════════════════════");
   Print("🚀 ", EA_NAME, " v", EA_VERSION);
   Print("═══════════════════════════════════════");
   
   // Log account information
   Print("💰 ACCOUNT INFO:");
   Print("   Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("   Equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("   Leverage: 1:", IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE)));
   Print("   Currency: ", AccountInfoString(ACCOUNT_CURRENCY));
   
   // Log magic number
   Print("🔢 Magic Number: ", MagicNumber);
   
   // Clean up any existing panel objects (from previous EA instances or other EAs)
   Print("🧹 Cleaning chart...");
   CleanUpOldPanels();
   
   // Initialize symbol specifications
   if(!InitializeSymbolSpecs())
   {
      Print("❌ FAILED: Could not initialize symbol specifications");
      return(INIT_FAILED);
   }
   
   // Validate and normalize lot size
   validatedLotSize = ValidateLotSize(LotSize);
   
   Print("📊 CONFIGURATION:");
   string startDirText = "";
   if(StartDirection == BOTH) startDirText = "BOTH (BUY + SELL at every level)";
   else if(StartDirection == BUYONLY) startDirText = "BUY ONLY";
   else startDirText = "SELL ONLY";
   
   Print("   Starting Direction: ", startDirText);
   Print("   Symbol: ", _Symbol);
   Print("   Lot Size: ", DoubleToString(validatedLotSize, 3));
   Print("   Max Positions: ", MaxPositions);
   
   // Log trend filter status
   if(EnableTrendFilter)
   {
      Print("═══════════════════════════════════════");
      Print("📈 TREND FILTER: ENABLED");
      Print("   - UP trend → BUY ONLY");
      Print("   - DOWN trend → SELL ONLY");
      Print("   - RANGING → BOTH directions");
      Print("   Timeframe: ", EnumToString(TrendTimeframe));
      Print("   MA Period: ", TrendMAPeriod);
      Print("   Threshold: ", DoubleToString(TrendThreshold, 2), "%");
   }
   
   // Set current direction to starting direction
   CurrentDirection = StartDirection;
   
   // Initialize time-based trading filter
   if(EnableTimeFilter)
   {
      Print("═══════════════════════════════════════");
      Print("⏰ TIME FILTER: ENABLED");
      Print("   Trading Hours: ", StringFormat("%02d:%02d", TradingStartHour, TradingStartMinute), 
            " - ", StringFormat("%02d:%02d", TradingEndHour, TradingEndMinute), " WAT");
      Print("   Current Time: ", TimeToString(TimeCurrent(), TIME_MINUTES));
      Print("   Status: ", IsWithinTradingHours() ? "✅ Trading Allowed" : "⏸ Trading Paused");
   }
   
   // Initialize reference price and grid
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(ask <= 0 || bid <= 0)
   {
      Print("❌ FAILED: Invalid price data");
      return(INIT_FAILED);
   }
   
   referencePrice = (ask + bid) / 2.0;
   currentGapSize = referencePrice * GridGapPercent / 100.0;
   
   // Validate grid gap
   if(!ValidateGridGap())
   {
      Print("⚠️ WARNING: Grid gap validation failed - proceed with caution");
   }
   
   Print("📍 STARTING REFERENCE: $", DoubleToString(referencePrice, specs.digits));
   Print("   Grid Spacing: ", DoubleToString(GridGapPercent, 2), "% ($", DoubleToString(currentGapSize, 2), ")");
   
   // SACROSANCT VALUES - Set once, NEVER change
   startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   maxDrawdownStopLevel = startingBalance * (1.0 - (MaxDrawdownPercent / 100.0));
   
   Print("═══════════════════════════════════════");
   Print("🛡️ RISK MANAGEMENT (SACROSANCT):");
   Print("   Starting Balance: $", DoubleToString(startingBalance, 2));
   Print("   Max Drawdown: ", DoubleToString(MaxDrawdownPercent, 1), "%");
   Print("   🔴 DD STOP LEVEL: $", DoubleToString(maxDrawdownStopLevel, 2));
   Print("   ⚠️ THIS LEVEL WILL NEVER CHANGE");
   
   // Initialize daily tracking
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyTarget = dailyStartBalance * (DailyTargetPercent / 100.0);
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   currentDay = dt.day;
   lastDayCheck = TimeCurrent();
   
   Print("═══════════════════════════════════════");
   Print("📅 DAILY PROFIT TARGET:");
   Print("   Day Start Balance: $", DoubleToString(dailyStartBalance, 2));
   Print("   Target: ", DoubleToString(DailyTargetPercent, 1), "% ($", DoubleToString(dailyTarget, 2), ")");
   
   // Initialize trend indicator
   trendMAHandle = iMA(_Symbol, TrendTimeframe, TrendMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(trendMAHandle == INVALID_HANDLE)
   {
      Print("⚠️ WARNING: Could not initialize trend MA indicator");
   }
   
   // Create panel if enabled
   if(ShowPanel)
   {
      CreateInfoPanel();
   }
   
   Print("═══════════════════════════════════════");
   Print("✅ INITIALIZATION COMPLETE");
   Print("═══════════════════════════════════════");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("═══════════════════════════════════════");
   Print("🛑 EA STOPPING - Reason: ", GetDeinitReasonText(reason));
   Print("═══════════════════════════════════════");
   
   // Clean up indicator
   if(trendMAHandle != INVALID_HANDLE)
   {
      IndicatorRelease(trendMAHandle);
   }
   
   // Remove panel
   DeletePanel();
   
   Print("Final Statistics:");
   Print("   Total Trades: ", totalTrades);
   Print("   Mode Switches: ", modeSwitchCount);
   Print("   Final P/L: $", DoubleToString(totalProfit, 2));
   
   Print("═══════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| MAIN TICK HANDLER                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
   // Update trend display
   UpdateTrendDetection();
   
   // Check for emergency stop
   if(CheckEmergencyStop())
   {
      if(emergencyStop)
      {
         Print("🚨 EMERGENCY STOP ACTIVE: ", emergencyReason);
         UpdatePanel();
         return;
      }
   }
   
   // Check daily profit target
   CheckDailyTarget();
   if(dailyTargetReached)
   {
      UpdatePanel();
      return;
   }
   
   // Check time filter
   if(EnableTimeFilter && !IsWithinTradingHours())
   {
      UpdatePanel();
      return;
   }
   
   // Skip if paused
   if(isPaused)
   {
      UpdatePanel();
      return;
   }
   
   // Check spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      UpdatePanel();
      return;
   }
   
   // Sync positions with actual trades
   SyncPositions();
   
   // Check group TP
   CalculateTotalProfit();
   if(totalProfit >= GroupTPDollars && ArraySize(positions) > 0)
   {
      Print("✅ GROUP TP REACHED: $", DoubleToString(totalProfit, 2), " >= $", DoubleToString(GroupTPDollars, 2));
      CloseAllPositions("Group TP Hit");
      ArrayResize(positions, 0);
      UpdatePanel();
      return;
   }
   
   // Get current effective direction (considering trend filter if enabled)
   ENUM_TRADE_DIRECTION effectiveDirection = GetEffectiveDirection();
   
   // Maintain grid
   MaintainGrid(effectiveDirection);
   
   // Update panel
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| GET EFFECTIVE TRADING DIRECTION                                   |
//+------------------------------------------------------------------+
ENUM_TRADE_DIRECTION GetEffectiveDirection()
{
   // If trend filter is disabled, use current direction as-is
   if(!EnableTrendFilter)
   {
      return CurrentDirection;
   }
   
   // If trend filter is enabled, override based on trend
   if(currentTrendState == 1)  // UP trend
   {
      return BUYONLY;
   }
   else if(currentTrendState == -1)  // DOWN trend
   {
      return SELLONLY;
   }
   else  // RANGING
   {
      return BOTH;
   }
}

//+------------------------------------------------------------------+
//| CHECK GRID - Trigger-based grid placement (FIXED GAP LOGIC)      |
//+------------------------------------------------------------------+
void MaintainGrid(ENUM_TRADE_DIRECTION direction)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   if(ask <= 0 || bid <= 0)
   {
      Print("⚠️ WARNING: Invalid price - Ask: ", ask, ", Bid: ", bid);
      return;
   }
   
   // Check max positions FIRST
   if(ArraySize(positions) >= MaxPositions)
   {
      return;
   }
   
   // Find nearest grid level to current price
   double distanceFromReference = currentPrice - referencePrice;
   int levelIndex = (int)MathRound(distanceFromReference / currentGapSize);
   double nearestGridLevel = referencePrice + (levelIndex * currentGapSize);
   
   // Calculate distance to nearest level
   double distanceToNearestLevel = MathAbs(currentPrice - nearestGridLevel);
   
   // CRITICAL: Trigger zone - only place orders when close to grid level
   // 12% of gap size = tight trigger zone
   double triggerPercent = 0.12;
   double triggerZone = currentGapSize * triggerPercent;
   
   // Only trigger if price is close to a grid level
   if(distanceToNearestLevel > triggerZone)
      return;  // Not close enough to grid level
   
   // Check if position already exists at this level (80% tolerance)
   bool levelHasPosition = false;
   double minDistanceBetweenPositions = currentGapSize * 0.8;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      double distToExistingPosition = MathAbs(positions[i].entryPrice - nearestGridLevel);
      
      if(distToExistingPosition < minDistanceBetweenPositions)
      {
         levelHasPosition = true;
         break;
      }
   }
   
   // Open position if level is empty
   if(!levelHasPosition)
   {
      // Place orders based on direction
      if(direction == BOTH)
      {
         // Both directions - place BUY and SELL
         PlaceMarketOrder(POSITION_TYPE_BUY, nearestGridLevel);
         if(ArraySize(positions) < MaxPositions)  // Check again after first order
         {
            PlaceMarketOrder(POSITION_TYPE_SELL, nearestGridLevel);
         }
      }
      else if(direction == BUYONLY)
      {
         PlaceMarketOrder(POSITION_TYPE_BUY, nearestGridLevel);
      }
      else if(direction == SELLONLY)
      {
         PlaceMarketOrder(POSITION_TYPE_SELL, nearestGridLevel);
      }
      
      Print("✅ Order placed at grid level: $", DoubleToString(nearestGridLevel, specs.digits),
            " (Gap: $", DoubleToString(currentGapSize, 2), ")");
   }
}

//+------------------------------------------------------------------+
//| PLACE GRID ORDERS - DEPRECATED (kept for compatibility)          |
//+------------------------------------------------------------------+
void PlaceGridOrders(ENUM_POSITION_TYPE orderType, int levelsAbove, int levelsBelow)
{
   // This function is no longer used - CheckGrid approach is superior
   // Kept for code compatibility only
}

//+------------------------------------------------------------------+
//| CHECK IF POSITION EXISTS AT GRID LEVEL - DEPRECATED              |
//+------------------------------------------------------------------+
bool HasPositionAtLevel(double targetPrice, ENUM_POSITION_TYPE orderType)
{
   // This function is no longer used - CheckGrid handles this internally
   // Kept for code compatibility only
   return false;
}

//+------------------------------------------------------------------+
//| PLACE MARKET ORDER                                                |
//+------------------------------------------------------------------+
void PlaceMarketOrder(ENUM_POSITION_TYPE orderType, double gridLevel)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = validatedLotSize;
   request.type = (orderType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.deviation = 50;
   request.magic = MagicNumber;
   request.comment = StringFormat("%s_L%.0f", EA_NAME, gridLevel);
   
   // Set price
   if(orderType == POSITION_TYPE_BUY)
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   else
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Calculate TP and SL in dollars
   double tpPrice = 0;
   double slPrice = 0;
   
   if(IndividualTPDollars > 0)
   {
      tpPrice = CalculateTPPrice(orderType, request.price, IndividualTPDollars);
   }
   
   if(IndividualSLDollars > 0)
   {
      slPrice = CalculateSLPrice(orderType, request.price, IndividualSLDollars);
   }
   
   request.tp = tpPrice;
   request.sl = slPrice;
   
   // Send order
   if(!OrderSend(request, result))
   {
      Print("❌ ORDER FAILED: ", GetLastError(), " - ", result.comment);
      return;
   }
   
   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      // Add to positions array
      int size = ArraySize(positions);
      ArrayResize(positions, size + 1);
      
      positions[size].ticket = result.order;
      positions[size].entryPrice = request.price;
      positions[size].entryTime = TimeCurrent();
      positions[size].posType = orderType;
      
      totalTrades++;
      
      string typeText = (orderType == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      Print("✅ ", typeText, " #", result.order, " | Price: $", DoubleToString(request.price, specs.digits),
            " | Grid: $", DoubleToString(gridLevel, specs.digits), " | Lots: ", DoubleToString(validatedLotSize, 2));
   }
   else
   {
      Print("⚠️ ORDER WARNING: ", result.retcode, " - ", result.comment);
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TP PRICE FROM DOLLAR AMOUNT                             |
//+------------------------------------------------------------------+
double CalculateTPPrice(ENUM_POSITION_TYPE type, double entryPrice, double dollarTarget)
{
   if(dollarTarget <= 0) return 0;
   
   double pointValue = specs.tickValue / specs.tickSize * specs.point;
   if(pointValue <= 0) return 0;
   
   double pointsNeeded = dollarTarget / (validatedLotSize * pointValue);
   
   if(type == POSITION_TYPE_BUY)
      return NormalizeDouble(entryPrice + (pointsNeeded * specs.point), specs.digits);
   else
      return NormalizeDouble(entryPrice - (pointsNeeded * specs.point), specs.digits);
}

//+------------------------------------------------------------------+
//| CALCULATE SL PRICE FROM DOLLAR AMOUNT                             |
//+------------------------------------------------------------------+
double CalculateSLPrice(ENUM_POSITION_TYPE type, double entryPrice, double dollarRisk)
{
   if(dollarRisk <= 0) return 0;
   
   double pointValue = specs.tickValue / specs.tickSize * specs.point;
   if(pointValue <= 0) return 0;
   
   double pointsNeeded = dollarRisk / (validatedLotSize * pointValue);
   
   if(type == POSITION_TYPE_BUY)
      return NormalizeDouble(entryPrice - (pointsNeeded * specs.point), specs.digits);
   else
      return NormalizeDouble(entryPrice + (pointsNeeded * specs.point), specs.digits);
}

//+------------------------------------------------------------------+
//| SYNC POSITIONS WITH ACTUAL TRADES                                 |
//+------------------------------------------------------------------+
void SyncPositions()
{
   // Remove closed positions from array
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(positions[i].ticket))
      {
         // Position is closed, remove from array
         RemovePosition(i);
      }
   }
}

//+------------------------------------------------------------------+
//| REMOVE POSITION FROM ARRAY                                        |
//+------------------------------------------------------------------+
void RemovePosition(int index)
{
   int size = ArraySize(positions);
   if(index < 0 || index >= size) return;
   
   for(int i = index; i < size - 1; i++)
   {
      positions[i] = positions[i + 1];
   }
   
   ArrayResize(positions, size - 1);
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                            |
//+------------------------------------------------------------------+
void CalculateTotalProfit()
{
   totalProfit = 0;
   
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                               |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   Print("🔴 CLOSING ALL POSITIONS: ", reason);
   
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         
         request.action = TRADE_ACTION_DEAL;
         request.position = positions[i].ticket;
         request.symbol = _Symbol;
         request.volume = PositionGetDouble(POSITION_VOLUME);
         request.deviation = 50;
         request.magic = MagicNumber;
         
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         
         if(posType == POSITION_TYPE_BUY)
         {
            request.type = ORDER_TYPE_SELL;
            request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         }
         else
         {
            request.type = ORDER_TYPE_BUY;
            request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         }
         
         if(!OrderSend(request, result))
         {
            Print("❌ CLOSE FAILED: Ticket ", positions[i].ticket, " - Error: ", GetLastError());
         }
         else
         {
            Print("✅ CLOSED: Ticket ", positions[i].ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CLOSE PROFITABLE POSITIONS ONLY                                   |
//+------------------------------------------------------------------+
void CloseProfitablePositions()
{
   int closed = 0;
   
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         
         if(profit > 0)
         {
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            
            request.action = TRADE_ACTION_DEAL;
            request.position = positions[i].ticket;
            request.symbol = _Symbol;
            request.volume = PositionGetDouble(POSITION_VOLUME);
            request.deviation = 50;
            request.magic = MagicNumber;
            
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            if(posType == POSITION_TYPE_BUY)
            {
               request.type = ORDER_TYPE_SELL;
               request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            }
            else
            {
               request.type = ORDER_TYPE_BUY;
               request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            }
            
            if(OrderSend(request, result))
            {
               closed++;
               Print("✅ CLOSED PROFITABLE: Ticket ", positions[i].ticket, " | Profit: $", DoubleToString(profit, 2));
            }
         }
      }
   }
   
   Print("💰 Closed ", closed, " profitable position(s)");
}

//+------------------------------------------------------------------+
//| CHECK EMERGENCY STOP CONDITIONS                                   |
//+------------------------------------------------------------------+
bool CheckEmergencyStop()
{
   if(emergencyStop) return true;
   
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Check drawdown against SACROSANCT level
   if(currentEquity <= maxDrawdownStopLevel)
   {
      emergencyStop = true;
      emergencyReason = StringFormat("MAX DRAWDOWN REACHED - Equity: $%.2f <= Stop: $%.2f",
                                    currentEquity, maxDrawdownStopLevel);
      
      Print("═══════════════════════════════════════");
      Print("🚨🚨🚨 EMERGENCY STOP 🚨🚨🚨");
      Print(emergencyReason);
      Print("═══════════════════════════════════════");
      
      CloseAllPositions("Emergency Stop - Max DD");
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| CHECK DAILY TARGET                                                |
//+------------------------------------------------------------------+
void CheckDailyTarget()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // Reset at new day
   if(dt.day != currentDay)
   {
      currentDay = dt.day;
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyTarget = dailyStartBalance * (DailyTargetPercent / 100.0);
      dailyTargetReached = false;
      
      Print("═══════════════════════════════════════");
      Print("📅 NEW DAY STARTED");
      Print("   Day Start Balance: $", DoubleToString(dailyStartBalance, 2));
      Print("   Daily Target: $", DoubleToString(dailyTarget, 2));
      Print("═══════════════════════════════════════");
   }
   
   // Check if target reached
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - dailyStartBalance;
   
   if(!dailyTargetReached && dailyProfit >= dailyTarget)
   {
      dailyTargetReached = true;
      
      Print("═══════════════════════════════════════");
      Print("🎯 DAILY TARGET REACHED!");
      Print("   Profit: $", DoubleToString(dailyProfit, 2));
      Print("   Target: $", DoubleToString(dailyTarget, 2));
      Print("   EA will pause trading for the day");
      Print("═══════════════════════════════════════");
      
      CloseAllPositions("Daily Target Reached");
   }
}

//+------------------------------------------------------------------+
//| CHECK TIME FILTER                                                 |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
   if(!EnableTimeFilter) return true;
   
   MqlDateTime currentTime;
   TimeToStruct(TimeCurrent(), currentTime);
   
   int currentMinutes = currentTime.hour * 60 + currentTime.min;
   int startMinutes = TradingStartHour * 60 + TradingStartMinute;
   int endMinutes = TradingEndHour * 60 + TradingEndMinute;
   
   if(startMinutes <= endMinutes)
   {
      return (currentMinutes >= startMinutes && currentMinutes <= endMinutes);
   }
   else
   {
      return (currentMinutes >= startMinutes || currentMinutes <= endMinutes);
   }
}

//+------------------------------------------------------------------+
//| UPDATE TREND DETECTION                                            |
//+------------------------------------------------------------------+
void UpdateTrendDetection()
{
   if(trendMAHandle == INVALID_HANDLE)
   {
      currentTrend = "---";
      currentTrendState = 0;
      return;
   }
   
   double maBuffer[];
   ArraySetAsSeries(maBuffer, true);
   
   if(CopyBuffer(trendMAHandle, 0, 0, 3, maBuffer) < 3)
   {
      currentTrend = "---";
      currentTrendState = 0;
      return;
   }
   
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ma0 = maBuffer[0];
   double ma1 = maBuffer[1];
   double ma2 = maBuffer[2];
   
   // Calculate trend strength
   double priceDistancePercent = ((currentPrice - ma0) / ma0) * 100.0;
   double maSlope = ((ma0 - ma2) / ma2) * 100.0;
   
   // Determine trend
   if(MathAbs(maSlope) < TrendThreshold && MathAbs(priceDistancePercent) < TrendThreshold)
   {
      currentTrend = "RANGING";
      currentTrendState = 0;
   }
   else if(currentPrice > ma0 && ma0 > ma1 && ma1 > ma2)
   {
      currentTrend = StringFormat("UP %.1f%%", MathAbs(maSlope));
      currentTrendState = 1;
   }
   else if(currentPrice < ma0 && ma0 < ma1 && ma1 < ma2)
   {
      currentTrend = StringFormat("DOWN %.1f%%", MathAbs(maSlope));
      currentTrendState = -1;
   }
   else
   {
      currentTrend = "RANGING";
      currentTrendState = 0;
   }
}

//+------------------------------------------------------------------+
//| INITIALIZE SYMBOL SPECIFICATIONS                                  |
//+------------------------------------------------------------------+
bool InitializeSymbolSpecs()
{
   specs.contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   specs.tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   specs.tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   specs.point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   specs.stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   specs.digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   specs.minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   specs.maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   specs.lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   specs.minStopDistance = specs.stopLevel * specs.point;
   
   Print("📊 SYMBOL SPECIFICATIONS:");
   Print("   Contract Size: ", specs.contractSize);
   Print("   Tick Value: $", DoubleToString(specs.tickValue, 5));
   Print("   Tick Size: ", DoubleToString(specs.tickSize, specs.digits));
   Print("   Point: ", DoubleToString(specs.point, specs.digits));
   Print("   Digits: ", specs.digits);
   Print("   Min Lot: ", specs.minLot);
   Print("   Max Lot: ", specs.maxLot);
   Print("   Lot Step: ", specs.lotStep);
   Print("   Stop Level: ", specs.stopLevel, " points");
   
   return (specs.tickValue > 0 && specs.tickSize > 0 && specs.point > 0);
}

//+------------------------------------------------------------------+
//| VALIDATE LOT SIZE                                                 |
//+------------------------------------------------------------------+
double ValidateLotSize(double requestedLots)
{
   double lots = requestedLots;
   
   // Round to lot step
   lots = MathFloor(lots / specs.lotStep) * specs.lotStep;
   
   // Clamp to min/max
   if(lots < specs.minLot)
      lots = specs.minLot;
   if(lots > specs.maxLot)
      lots = specs.maxLot;
   
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| VALIDATE GRID GAP                                                 |
//+------------------------------------------------------------------+
bool ValidateGridGap()
{
   if(currentGapSize < specs.minStopDistance)
   {
      Print("⚠️ WARNING: Grid gap ($", DoubleToString(currentGapSize, specs.digits),
            ") is smaller than minimum stop distance ($", DoubleToString(specs.minStopDistance, specs.digits), ")");
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| CHART EVENT HANDLER                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      // CLOSE ALL button
      if(sparam == panelPrefix + "CloseBtn")
      {
         ObjectSetInteger(0, panelPrefix + "CloseBtn", OBJPROP_STATE, false);
         if(ArraySize(positions) > 0)
         {
            Print("🔴 CLOSE button pressed - Closing all positions...");
            CloseAllPositions("Manual Close All");
            ArrayResize(positions, 0);
            Print("✅ All positions closed");
         }
         else
         {
            Print("ℹ️ No positions to close");
         }
         UpdatePanel();
      }
      
      // PAUSE/RESUME button
      else if(sparam == panelPrefix + "PauseBtn")
      {
         ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_STATE, false);
         
         // If emergency stop is active, allow resume
         if(emergencyStop)
         {
            emergencyStop = false;
            emergencyReason = "";
            isPaused = false;
            Print("▶️ EA RESUMED - Emergency stop cleared");
            Print("⚠️ WARNING: Max drawdown protection still active");
         }
         else
         {
            isPaused = !isPaused;
            Print(isPaused ? "⏸️ EA PAUSED" : "▶️ EA RESUMED");
         }
         UpdatePanel();
      }
      
      // TP button - Close profitable positions
      else if(sparam == panelPrefix + "TPBtn")
      {
         ObjectSetInteger(0, panelPrefix + "TPBtn", OBJPROP_STATE, false);
         Print("💰 TP button pressed - Closing profitable positions...");
         CloseProfitablePositions();
         Print("✅ Profitable positions closed");
         UpdatePanel();
      }
      
      // HIDE PANEL button
      else if(sparam == panelPrefix + "HideBtn")
      {
         ObjectSetInteger(0, panelPrefix + "HideBtn", OBJPROP_STATE, false);
         panelVisible = !panelVisible;
         
         // Toggle visibility of all panel elements except hide button
         string objects[];
         int totalObjects = ObjectsTotal(0, 0, OBJ_LABEL);
         ArrayResize(objects, totalObjects);
         
         for(int i = 0; i < totalObjects; i++)
         {
            string name = ObjectName(0, i, 0, OBJ_LABEL);
            if(StringFind(name, panelPrefix) >= 0 && name != panelPrefix + "HideBtn")
            {
               ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, panelVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
            }
         }
         
         // Toggle buttons
         totalObjects = ObjectsTotal(0, 0, OBJ_BUTTON);
         for(int i = 0; i < totalObjects; i++)
         {
            string name = ObjectName(0, i, 0, OBJ_BUTTON);
            if(StringFind(name, panelPrefix) >= 0 && name != panelPrefix + "HideBtn")
            {
               ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, panelVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
            }
         }
         
         // Toggle background
         ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_TIMEFRAMES, panelVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
         
         ObjectSetString(0, panelPrefix + "HideBtn", OBJPROP_TEXT, panelVisible ? "HIDE PANEL" : "SHOW PANEL");
      }
   }
}

//+------------------------------------------------------------------+
//| CLEAN UP OLD PANELS FROM CHART - AGGRESSIVE                      |
//+------------------------------------------------------------------+
void CleanUpOldPanels()
{
   int totalObjects = ObjectsTotal(0);
   int cleaned = 0;
   
   Print("   Scanning ", totalObjects, " chart objects for cleanup...");
   
   // Remove ALL graphical objects except indicators
   for(int i = totalObjects - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      ENUM_OBJECT objType = (ENUM_OBJECT)ObjectGetInteger(0, name, OBJPROP_TYPE);
      
      // Remove labels, buttons, rectangles, edits (typical panel objects)
      if(objType == OBJ_LABEL || 
         objType == OBJ_BUTTON || 
         objType == OBJ_RECTANGLE_LABEL || 
         objType == OBJ_EDIT ||
         objType == OBJ_BITMAP_LABEL)
      {
         // Skip MT5 built-in objects, remove panel objects
         bool isBuiltIn = (StringFind(name, "ChartObject") >= 0 || StringFind(name, "Period") >= 0);
         bool isPanelObject = (StringFind(name, "Info") >= 0 ||
                               StringFind(name, "Panel") >= 0 ||
                               StringFind(name, "EA") >= 0 ||
                               StringFind(name, "TORAMA") >= 0 ||
                               StringFind(name, "Btn") >= 0 ||
                               StringFind(name, "Label") >= 0 ||
                               StringFind(name, "Background") >= 0 ||
                               StringFind(name, "BG") >= 0);
         
         if(!isBuiltIn && isPanelObject)
         {
            ObjectDelete(0, name);
            cleaned++;
         }
      }
   }
   
   if(cleaned > 0)
   {
      Print("   ✓ Removed ", cleaned, " old object(s) from chart");
   }
   else
   {
      Print("   ✓ Chart is clean");
   }
   
   ChartRedraw();
   Sleep(100);  // Allow chart to redraw
}

//+------------------------------------------------------------------+
//| DELETE PANEL                                                      |
//+------------------------------------------------------------------+
void DeletePanel()
{
   int totalObjects = ObjectsTotal(0);
   
   for(int i = totalObjects - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, panelPrefix) >= 0)
      {
         ObjectDelete(0, name);
      }
   }
}

//+------------------------------------------------------------------+
//| CREATE INFO PANEL - Clean Design (matching v5.6.2)                |
//+------------------------------------------------------------------+
void CreateInfoPanel()
{
   int x = 20;
   int y = 30;
   int width = 320;
   int lineHeight = 20;  // Reduced from 22
   
   // Background - Dark with gold border, ON TOP of chart
   ObjectCreate(0, panelPrefix + "Background", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YSIZE, EnableTrendFilter ? 360 : 340);  // Reduced height
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BGCOLOR, C'20,20,25');  // Very dark
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BACK, false);  // FRONT - on top
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_ZORDER, 0);  // Topmost layer
   
   int yPos = y + 10;  // Reduced from 12
   
   // === TITLE + STATUS ROW ===
   CreateLabel(panelPrefix + "Title", x + 10, yPos, "AGGRESSIVE TRADER", clrGold, 11, "Arial Black");
   CreateLabel(panelPrefix + "Status", x + width - 95, yPos, "RUNNING", clrLimeGreen, 9, "Arial Bold");
   yPos += 24;  // Reduced from 26
   
   // === BUTTONS ROW ===
   CreateButton(panelPrefix + "CloseBtn", x + 10, yPos, 65, 26, "CLOSE", clrRed, clrWhite);
   CreateButton(panelPrefix + "PauseBtn", x + 80, yPos, 65, 26, "PAUSE", clrOrange, clrWhite);
   CreateButton(panelPrefix + "TPBtn", x + 150, yPos, 55, 26, "TP", clrGreen, clrWhite);
   CreateButton(panelPrefix + "ModeBtn", x + 210, yPos, 55, 26, "MODE", clrDodgerBlue, clrWhite);
   yPos += 32;  // Reduced from 34
   
   // === MODE + TREND ROW ===
   CreateLabel(panelPrefix + "ModeLabel", x + 10, yPos, "Mode:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Mode", x + 65, yPos, "BUY", clrDodgerBlue, 10, "Arial Black");
   CreateLabel(panelPrefix + "TrendLabel", x + 165, yPos, "Trend:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Trend", x + 230, yPos, "UP ▲", clrLimeGreen, 9, "Arial Bold");
   yPos += lineHeight;
   
   // === PRICE ROW ===
   CreateLabel(panelPrefix + "PriceLabel", x + 10, yPos, "Price:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Price", x + 65, yPos, "$0", clrWhite, 10, "Arial Bold");
   yPos += lineHeight;
   
   // === GRID + SPREAD ROW ===
   CreateLabel(panelPrefix + "GridLabel", x + 10, yPos, "Grid:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "GridSpacing", x + 65, yPos, "0%", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "SpreadLabel", x + 165, yPos, "Spread:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Spread", x + 235, yPos, "0/2000", clrWhite, 9, "Arial");
   yPos += lineHeight;
   
   // === REFERENCE ROW ===
   CreateLabel(panelPrefix + "RefLabel", x + 10, yPos, "Reference:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "RefPrice", x + 95, yPos, "$0", clrWhite, 9, "Arial");
   yPos += lineHeight + 2;  // Small gap
   
   // === EA POSITIONS ROW ===
   CreateLabel(panelPrefix + "PosLabel", x + 10, yPos, "⚡EA:", clrGold, 9, "Arial Black");
   CreateLabel(panelPrefix + "Positions", x + 60, yPos, "0/100", clrWhite, 10, "Arial Black");
   yPos += lineHeight;
   
   // === ACCOUNT POSITIONS ROW ===
   CreateLabel(panelPrefix + "AccLabel", x + 10, yPos, "Acc:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "AccCounts", x + 60, yPos, "B:0.00 S:0.00 (0)", clrWhite, 9, "Arial");
   yPos += lineHeight + 2;  // Small gap
   
   // === P/L ROW ===
   CreateLabel(panelPrefix + "PnLLabel", x + 10, yPos, "P/L:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "PnL", x + 60, yPos, "$0", clrWhite, 11, "Arial Black");
   yPos += lineHeight;
   
   // === EQUITY + START (COMBINED) ===
   CreateLabel(panelPrefix + "EquityLabel", x + 10, yPos, "Equity:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Equity", x + 70, yPos, "$0", clrWhite, 9, "Arial");
   yPos += lineHeight;
   
   CreateLabel(panelPrefix + "StartCapLabel", x + 10, yPos, "Start:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "StartCap", x + 70, yPos, "$0", clrLimeGreen, 9, "Arial Bold");
   yPos += lineHeight;
   
   // === DD + DAILY ROW ===
   CreateLabel(panelPrefix + "DDLabel", x + 10, yPos, "DD:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DD", x + 60, yPos, "0%", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "DailyLabel", x + 165, yPos, "Daily:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DailyProfit", x + 225, yPos, "$0", clrWhite, 9, "Arial");
   yPos += lineHeight;
   
   // === DD TRIGGER ROW ===
   CreateLabel(panelPrefix + "DDTriggerLabel", x + 10, yPos, "🛑 DD@:", clrOrangeRed, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DDTrigger", x + 70, yPos, "$0", clrOrangeRed, 9, "Arial Bold");
   yPos += lineHeight;
   
   // === SWITCHES ROW ===
   CreateLabel(panelPrefix + "SwitchCountLabel", x + 10, yPos, "Switches:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "SwitchCount", x + 90, yPos, "0", clrCyan, 9, "Arial");
   yPos += lineHeight + 10;  // Reduced from 15
   
   // === BRANDING - Bottom Right ===
   int brandY = y + (EnableTrendFilter ? 360 : 340) - 32;  // Adjusted for new height
   int brandX = x + width - 12;
   
   ObjectCreate(0, panelPrefix + "Brand", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_XDISTANCE, brandX);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_YDISTANCE, brandY);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_FONT, "Arial Black");
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_TEXT, "© TORAMA CAPITAL");
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_ZORDER, 0);
   
   ObjectCreate(0, panelPrefix + "Email", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_XDISTANCE, brandX);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_YDISTANCE, brandY + 14);  // Reduced from 16
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_COLOR, C'150,150,100');
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_FONTSIZE, 7);
   ObjectSetString(0, panelPrefix + "Email", OBJPROP_FONT, "Arial");
   ObjectSetString(0, panelPrefix + "Email", OBJPROP_TEXT, "ea@torama.money");
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_ZORDER, 0);
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!ShowPanel) return;
   
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Status
   string statusText = "RUNNING";
   color statusColor = clrLimeGreen;
   
   if(emergencyStop)
   {
      statusText = "🚨 EMERGENCY STOP";
      statusColor = clrRed;
   }
   else if(dailyTargetReached)
   {
      statusText = "🎯 DAILY TARGET";
      statusColor = clrGold;
   }
   else if(isPaused)
   {
      statusText = "⏸ PAUSED";
      statusColor = clrYellow;
   }
   else if(EnableTimeFilter && !IsWithinTradingHours())
   {
      statusText = "⏰ TIME FILTER";
      statusColor = clrYellow;
   }
   
   ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, statusText);
   ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, statusColor);
   
   // Update PAUSE/RESUME button text
   if(isPaused || emergencyStop)
   {
      ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, "RESUME");
      ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, C'0,100,0');  // Dark green
   }
   else
   {
      ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, "PAUSE");
      ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, C'150,80,0');  // Orange
   }
   
   // Mode - Show effective direction if trend filter is enabled
   ENUM_TRADE_DIRECTION effectiveDirection = GetEffectiveDirection();
   string modeText = "";
   color modeColor = clrDodgerBlue;
   
   if(EnableTrendFilter)
   {
      // Show what trend filter is forcing
      if(effectiveDirection == BUYONLY)
      {
         modeText = "BUY ONLY (↑)";
         modeColor = clrDodgerBlue;
      }
      else if(effectiveDirection == SELLONLY)
      {
         modeText = "SELL ONLY (↓)";
         modeColor = clrOrangeRed;
      }
      else
      {
         modeText = "BOTH (↔)";
         modeColor = clrYellow;
      }
   }
   else
   {
      // Show manual mode
      if(CurrentDirection == BUYONLY)
         modeText = "BUY ONLY";
      else if(CurrentDirection == SELLONLY)
         modeText = "SELL ONLY";
      else
         modeText = "BOTH";
   }
   
   ObjectSetString(0, panelPrefix + "Mode", OBJPROP_TEXT, modeText);
   ObjectSetInteger(0, panelPrefix + "Mode", OBJPROP_COLOR, modeColor);
   
   // Trend
   color trendColor = clrWhite;
   if(StringFind(currentTrend, "UP") >= 0)
      trendColor = clrDodgerBlue;
   else if(StringFind(currentTrend, "DOWN") >= 0)
      trendColor = clrOrangeRed;
   else if(currentTrend == "RANGING")
      trendColor = clrYellow;
   
   ObjectSetString(0, panelPrefix + "Trend", OBJPROP_TEXT, currentTrend);
   ObjectSetInteger(0, panelPrefix + "Trend", OBJPROP_COLOR, trendColor);
   
   // Time Status (if time filter enabled)
   if(EnableTimeFilter)
   {
      MqlDateTime currentTime;
      TimeToStruct(TimeCurrent(), currentTime);
      
      string timeText = StringFormat("%02d:%02d", currentTime.hour, currentTime.min);
      ObjectSetString(0, panelPrefix + "TimeStatus", OBJPROP_TEXT, timeText);
      
      bool withinHours = IsWithinTradingHours();
      string statusText = withinHours ? "✅ TRADING" : "⏸ PAUSED";
      color statusColor = withinHours ? clrLimeGreen : clrYellow;
      
      ObjectSetString(0, panelPrefix + "TimeAllowed", OBJPROP_TEXT, statusText);
      ObjectSetInteger(0, panelPrefix + "TimeAllowed", OBJPROP_COLOR, statusColor);
   }
   
   // Price
   ObjectSetString(0, panelPrefix + "Price", OBJPROP_TEXT, "$" + FormatWithCommas(currentPrice, specs.digits));
   
   // Grid
   ObjectSetString(0, panelPrefix + "GridSpacing", OBJPROP_TEXT,
                   FormatPrice(GridGapPercent, 2) + "% ($" + FormatWithCommas(currentGapSize, 2) + ")");
   
   // Spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   color spreadColor = (spread > MaxSpread) ? clrRed : (spread > MaxSpread * 0.7) ? clrOrange : clrLimeGreen;
   ObjectSetString(0, panelPrefix + "Spread", OBJPROP_TEXT, FormatWithCommas(spread, 0) + "/" + FormatWithCommas(MaxSpread, 0));
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_COLOR, spreadColor);
   
   
   // Reference
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, "$" + FormatWithCommas(referencePrice, specs.digits));
   
   // EA Positions
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT,
                   IntegerToString(ArraySize(positions)) + "/" + IntegerToString(MaxPositions));
   
   // Account-wide BUY/SELL LOTS
   double totalBuyLots = 0;
   double totalSellLots = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            double volume = PositionGetDouble(POSITION_VOLUME);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY)
               totalBuyLots += volume;
            else
               totalSellLots += volume;
         }
      }
   }
   
   // Calculate net position
   double netPosition = totalBuyLots - totalSellLots;
   string netText = "";
   color netColor = clrWhite;
   
   if(MathAbs(netPosition) < 0.01)
   {
      netText = "(0)";
      netColor = clrWhite;
   }
   else if(netPosition > 0)
   {
      netText = "(+" + FormatWithCommas(netPosition, 2) + "B)";
      netColor = clrDodgerBlue;
   }
   else
   {
      netText = "(" + FormatWithCommas(MathAbs(netPosition), 2) + "S)";
      netColor = clrOrangeRed;
   }
   
   string accLotsText = "B:" + FormatWithCommas(totalBuyLots, 2) + " S:" + FormatWithCommas(totalSellLots, 2) + " " + netText;
   ObjectSetString(0, panelPrefix + "AccCounts", OBJPROP_TEXT, accLotsText);
   ObjectSetInteger(0, panelPrefix + "AccCounts", OBJPROP_COLOR, netColor);
   
   // P/L
   CalculateTotalProfit();
   color pnlColor = (totalProfit >= 0) ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "PnL", OBJPROP_TEXT,
                   (totalProfit >= 0 ? "+" : "") + "$" + FormatWithCommas(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "PnL", OBJPROP_COLOR, pnlColor);
   
   // Equity
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT, "$" + FormatWithCommas(currentEquity, 2));
   
   // Starting Capital (SACROSANCT)
   ObjectSetString(0, panelPrefix + "StartCap", OBJPROP_TEXT, "$" + FormatWithCommas(startingBalance, 2));
   
   // ═══════════════════════════════════════════════════════════════
   // DRAWDOWN - NOW BASED ON SACROSANCT STARTING BALANCE
   // ═══════════════════════════════════════════════════════════════
   double currentDD = 0;
   if(startingBalance > 0)
   {
      currentDD = ((currentEquity - startingBalance) / startingBalance) * 100.0;
   }
   
   // Color code based on proximity to max DD
   color ddColor = clrLimeGreen;
   double ddProximity = MathAbs(currentDD / MaxDrawdownPercent);
   
   if(ddProximity >= 0.9)
      ddColor = clrRed;
   else if(ddProximity >= 0.7)
      ddColor = clrOrange;
   else if(ddProximity >= 0.5)
      ddColor = clrYellow;
   
   ObjectSetString(0, panelPrefix + "DD", OBJPROP_TEXT, FormatPrice(currentDD, 1) + "%");
   ObjectSetInteger(0, panelPrefix + "DD", OBJPROP_COLOR, ddColor);
   
   // Daily Profit
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - dailyStartBalance;
   
   color dailyColor = (dailyProfit >= dailyTarget) ? clrGold : 
                      (dailyProfit >= 0) ? clrLimeGreen : clrRed;
   
   ObjectSetString(0, panelPrefix + "DailyProfit", OBJPROP_TEXT,
                   (dailyProfit >= 0 ? "+" : "") + "$" + FormatWithCommas(dailyProfit, 2));
   ObjectSetInteger(0, panelPrefix + "DailyProfit", OBJPROP_COLOR, dailyColor);
   
   // ═══════════════════════════════════════════════════════════════
   // DD TRIGGER - NOW SHOWS ABSOLUTE SACROSANCT STOP LEVEL
   // ═══════════════════════════════════════════════════════════════
   string ddTriggerText = "$" + FormatWithCommas(maxDrawdownStopLevel, 2);
   color ddTriggerColor = clrOrangeRed;
   
   // Color code based on proximity to stop
   double bufferToStop = currentEquity - maxDrawdownStopLevel;
   double bufferPercent = (bufferToStop / startingBalance) * 100.0;
   
   if(bufferPercent <= 5.0)
      ddTriggerColor = clrRed;
   else if(bufferPercent <= 10.0)
      ddTriggerColor = clrOrange;
   else
      ddTriggerColor = clrOrangeRed;
   
   ObjectSetString(0, panelPrefix + "DDTrigger", OBJPROP_TEXT, ddTriggerText);
   ObjectSetInteger(0, panelPrefix + "DDTrigger", OBJPROP_COLOR, ddTriggerColor);
   
   // Mode switches
   ObjectSetString(0, panelPrefix + "SwitchCount", OBJPROP_TEXT, FormatWithCommas(modeSwitchCount, 0));
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
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);  // Front
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);  // On top
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
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);  // On top
}

//+------------------------------------------------------------------+
//| FORMAT WITH COMMAS                                                |
//+------------------------------------------------------------------+
string FormatWithCommas(double value, int decimals)
{
   string result = DoubleToString(MathAbs(value), decimals);
   
   int dotPos = StringFind(result, ".");
   if(dotPos == -1) dotPos = StringLen(result);
   
   string intPart = StringSubstr(result, 0, dotPos);
   string decPart = (dotPos < StringLen(result)) ? StringSubstr(result, dotPos) : "";
   
   string formatted = "";
   int len = StringLen(intPart);
   
   for(int i = 0; i < len; i++)
   {
      if(i > 0 && (len - i) % 3 == 0)
         formatted += ",";
      formatted += StringSubstr(intPart, i, 1);
   }
   
   return (value < 0 ? "-" : "") + formatted + decPart;
}

//+------------------------------------------------------------------+
//| FORMAT PRICE                                                      |
//+------------------------------------------------------------------+
string FormatPrice(double value, int decimals)
{
   return DoubleToString(value, decimals);
}

//+------------------------------------------------------------------+
//| GET DEINIT REASON TEXT                                            |
//+------------------------------------------------------------------+
string GetDeinitReasonText(int reason)
{
   switch(reason)
   {
      case REASON_PROGRAM: return "EA removed from chart";
      case REASON_REMOVE: return "EA removed from chart";
      case REASON_RECOMPILE: return "EA recompiled";
      case REASON_CHARTCHANGE: return "Chart symbol/period changed";
      case REASON_CHARTCLOSE: return "Chart closed";
      case REASON_PARAMETERS: return "Input parameters changed";
      case REASON_ACCOUNT: return "Account changed";
      case REASON_TEMPLATE: return "Template changed";
      case REASON_INITFAILED: return "Initialization failed";
      case REASON_CLOSE: return "Terminal closing";
      default: return "Unknown reason (" + IntegerToString(reason) + ")";
   }
}

//+------------------------------------------------------------------+
