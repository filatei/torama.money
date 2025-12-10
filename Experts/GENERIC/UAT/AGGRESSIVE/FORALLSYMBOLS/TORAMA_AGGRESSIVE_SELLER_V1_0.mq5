//+------------------------------------------------------------------+
//|                    TORAMA Aggressive Trader EA v1.0              |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "1.0"
#property description "Aggressive Directional Grid Trader"
#property description "Trades ONLY in chosen direction as price moves"
#property description "Replaces closed positions automatically"
#property description ""
#property description "OPTIMIZED FOR: $100k Account | 0.01% Gap | 100 Max Positions"
#property description "RISK: Each trade risks 0.5% balance (configurable)"
#property description "SAFE: 100 positions × 0.5% = 50% max risk (emergency stop at 25%)"

#define EA_VERSION "1.0"
#define EA_NAME "TORAMA AGGRESSIVE TRADER"

//+------------------------------------------------------------------+
//| SETTINGS GUIDE FOR DIFFERENT ACCOUNT SIZES                       |
//+------------------------------------------------------------------+
/*
  FORMULA: With 0.5% SL risk per trade
  LotSize = Account size specific
  IndividualSLPercent = 0.5% (default, safer)
  Total Risk = MaxPositions × 0.5% = 50% theoretical max
  Emergency Stop = 25% (triggers before 50 positions hit SL)
  
  $10k Account:
  - LotSize: 0.02
  - MaxPositions: 100
  - Risk per trade: $50 (0.5%)
  - Total risk: $5,000 (50% theoretical, 25% emergency stop)
  
  $50k Account:
  - LotSize: 0.1
  - MaxPositions: 100
  - Risk per trade: $250 (0.5%)
  - Total risk: $25,000 (50% theoretical, 25% emergency stop)
  
  $100k Account (DEFAULT):
  - LotSize: 0.2
  - MaxPositions: 100
  - Risk per trade: $500 (0.5%)
  - Total risk: $50,000 (50% theoretical, 25% emergency stop)
  
  $250k Account:
  - LotSize: 0.5
  - MaxPositions: 100
  - Risk per trade: $1,250 (0.5%)
  - Total risk: $125,000 (50% theoretical, 25% emergency stop)
  
  NOTE: Emergency stop at 25% drawdown will close all positions
        BEFORE the theoretical 50% max risk is reached.
        Realistic: ~50 positions would need to hit SL = 25% loss
*/

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

enum ENUM_TRADE_DIRECTION
{
   BUYONLY,    // BUY ONLY - Buys up and down the grid
   SELLONLY    // SELL ONLY - Sells up and down the grid
};

input group "=== DIRECTION ==="
input ENUM_TRADE_DIRECTION Direction = SELLONLY;  // Trading Direction

input group "=== GRID SETTINGS ==="
input double   GridGapPercent = 0.01;             // Grid gap % (0.01 = tight, 0.3 = wide)
input int      MaxPositions = 100;                // Maximum positions
input double   LotSize = 0.2;                     // Lot size per position (0.2 for $100k account)

input group "=== TAKE PROFIT ==="
input double   IndividualTPFactor = 2.5;          // Individual TP factor (2.5 = 2.5x gap)
input double   GroupTPFactor = 100.0;             // Group TP factor (100 = 100x gap)

input group "=== STOP LOSS ==="
input double   IndividualSLPercent = 0.5;         // SL risk per trade (% of balance, 0.5 = safer)

input group "=== RISK MANAGEMENT ==="
input double   MaxDrawdownPercent = 25.0;         // Max drawdown % (emergency stop)
input double   DailyTargetPercent = 100.0;        // Daily profit target (% of start balance)

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                  // Maximum spread (points)
input bool     ShowPanel = true;                  // Show info panel

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

struct Position
{
   ulong    ticket;
   double   entryPrice;
   datetime entryTime;
};

Position positions[];

// Grid tracking
double referencePrice = 0;              // Starting reference price
double currentGapSize = 0;              // Current grid spacing in dollars

// Risk management
bool emergencyStop = false;
string emergencyReason = "";
double peakEquity = 0;
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

// Magic number (auto-generated)
int MagicNumber = 0;

// Panel
string panelPrefix = "TORAMA_AGG_";
bool panelVisible = true;

// Lot size validation
double validatedLotSize = 0;
double minLot = 0;
double maxLot = 0;
double lotStep = 0;

//+------------------------------------------------------------------+
//| VALIDATE AND NORMALIZE LOT SIZE                                  |
//+------------------------------------------------------------------+
double ValidateLotSize(double requestedLots)
{
   minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(requestedLots < minLot)
   {
      Print("⚠️ WARNING: Requested lot size ", requestedLots, " is below minimum ", minLot, ". Using minimum.");
      return minLot;
   }
   
   if(requestedLots > maxLot)
   {
      Print("⚠️ WARNING: Requested lot size ", requestedLots, " exceeds maximum ", maxLot, ". Using maximum.");
      return maxLot;
   }
   
   double normalizedLots = MathFloor(requestedLots / lotStep) * lotStep;
   
   if(normalizedLots < minLot)
      normalizedLots = minLot;
   
   int lotDigits = 2;
   if(lotStep >= 0.1) lotDigits = 1;
   else if(lotStep >= 1.0) lotDigits = 0;
   
   normalizedLots = NormalizeDouble(normalizedLots, lotDigits);
   
   if(normalizedLots != requestedLots)
   {
      Print("ℹ️ INFO: Lot size adjusted from ", requestedLots, " to ", normalizedLots);
   }
   
   return normalizedLots;
}

//+------------------------------------------------------------------+
//| INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("═══════════════════════════════════════");
   Print("🚀 ", EA_NAME, " v", EA_VERSION);
   Print("═══════════════════════════════════════");
   
   // Generate unique magic number from current time in milliseconds
   MagicNumber = (int)(GetTickCount() % 2147483647);  // Keep within int range
   Print("🔢 Generated Magic Number: ", MagicNumber);
   
   // Validate lot size
   validatedLotSize = ValidateLotSize(LotSize);
   
   Print("📊 CONFIGURATION:");
   Print("Direction: ", Direction == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   Print("Symbol: ", _Symbol);
   Print("Lot Size: ", validatedLotSize);
   Print("Max Positions: ", MaxPositions);
   
   // Initialize reference price
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   referencePrice = (ask + bid) / 2.0;
   currentGapSize = referencePrice * GridGapPercent / 100.0;
   
   // Get symbol specifications for validation
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Validate gap is reasonable for this symbol
   double minGap = tickSize * 50;  // At least 50 ticks
   if(currentGapSize < minGap)
   {
      Print("⚠️ WARNING: Grid gap $", DoubleToString(currentGapSize, digits), " is too small!");
      Print("   Minimum recommended: $", DoubleToString(minGap, digits), " (50 ticks)");
      Print("   Current tick size: $", DoubleToString(tickSize, digits));
   }
   
   // Check if gap is too large (symbol-specific recommendations)
   double recommendedMaxGap = referencePrice * 0.5 / 100.0;  // 0.5% max for most symbols
   if(currentGapSize > recommendedMaxGap)
   {
      Print("⚠️ WARNING: Grid gap $", DoubleToString(currentGapSize, 2), " might be too large!");
      Print("   For ", _Symbol, " at $", DoubleToString(referencePrice, digits));
      Print("   Recommended maximum: 0.5% = $", DoubleToString(recommendedMaxGap, 2));
      Print("   Consider reducing GridGapPercent parameter");
   }
   
   // Symbol-specific recommendations
   string symbolGroup = "";
   if(StringFind(_Symbol, "BTC") >= 0 || StringFind(_Symbol, "ETH") >= 0)
   {
      symbolGroup = "CRYPTO";
      Print("📊 Detected: CRYPTOCURRENCY");
      Print("   Recommended gap: 0.01-0.05% ($", DoubleToString(referencePrice * 0.01 / 100.0, 2), 
            " - $", DoubleToString(referencePrice * 0.05 / 100.0, 2), ")");
   }
   else if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
   {
      symbolGroup = "METAL";
      Print("📊 Detected: PRECIOUS METAL");
      Print("   Recommended gap: 0.01-0.02% ($", DoubleToString(referencePrice * 0.01 / 100.0, 2), 
            " - $", DoubleToString(referencePrice * 0.02 / 100.0, 2), ")");
   }
   else if(StringFind(_Symbol, "USD") >= 0 || StringFind(_Symbol, "EUR") >= 0 || StringFind(_Symbol, "GBP") >= 0)
   {
      symbolGroup = "FOREX";
      Print("📊 Detected: FOREX PAIR");
      Print("   Recommended gap: 0.05-0.1% (", DoubleToString(referencePrice * 0.05 / 100.0, digits), 
            " - ", DoubleToString(referencePrice * 0.1 / 100.0, digits), " pips)");
   }
   
   Print("📍 STARTING REFERENCE: $", DoubleToString(referencePrice, digits));
   Print("📏 Grid Gap: $", DoubleToString(currentGapSize, digits), " (", DoubleToString(GridGapPercent, 3), "%)");
   
   // Initialize peak equity
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Daily target setup
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyTarget = dailyStartBalance * DailyTargetPercent / 100.0;
   Print("🎯 Daily Target: $", DoubleToString(dailyTarget, 2), " (", DoubleToString(DailyTargetPercent, 0), "%)");
   
   // Risk analysis
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskPerTrade = balance * (IndividualSLPercent / 100.0);  // Configurable % per trade
   double totalRisk = riskPerTrade * MaxPositions;
   double totalRiskPercent = (totalRisk / balance) * 100.0;
   
   Print("═══════════════════════════════════════");
   Print("💰 RISK ANALYSIS:");
   Print("   Account Balance: $", DoubleToString(balance, 2));
   Print("   SL Risk Per Trade: ", DoubleToString(IndividualSLPercent, 2), "% = $", DoubleToString(riskPerTrade, 2));
   Print("   Max Positions: ", MaxPositions);
   Print("   Total Portfolio Risk: $", DoubleToString(totalRisk, 2), " (", DoubleToString(totalRiskPercent, 1), "%)");
   Print("   Max Drawdown Limit: ", DoubleToString(MaxDrawdownPercent, 1), "%");
   
   if(totalRiskPercent > MaxDrawdownPercent)
   {
      Print("⚠️ WARNING: Total risk (", DoubleToString(totalRiskPercent, 1), "%) exceeds max drawdown (", 
            DoubleToString(MaxDrawdownPercent, 1), "%)");
      Print("   However, emergency stop will trigger BEFORE all ", MaxPositions, " positions hit SL");
      Print("   Emergency stop at ", DoubleToString(MaxDrawdownPercent, 1), "% = $", 
            DoubleToString(balance * MaxDrawdownPercent / 100.0, 2), " loss");
   }
   else
   {
      Print("✅ Total risk (", DoubleToString(totalRiskPercent, 1), "%) is WITHIN max drawdown (", 
            DoubleToString(MaxDrawdownPercent, 1), "%)");
      Print("   Safe configuration - emergency stop will prevent excessive losses");
   }
   
   // Calculate how many positions could hit SL before emergency stop
   double emergencyStopLoss = balance * (MaxDrawdownPercent / 100.0);
   int maxPositionsBeforeStop = (int)MathFloor(emergencyStopLoss / riskPerTrade);
   Print("   Emergency stop triggers after ~", maxPositionsBeforeStop, " positions hit SL");
   Print("   (", DoubleToString(MaxDrawdownPercent, 1), "% drawdown protection active)");
   
   // TP/SL info
   double individualTP = currentGapSize * IndividualTPFactor;
   double groupTP = currentGapSize * GroupTPFactor;
   Print("═══════════════════════════════════════");
   Print("🎯 PROFIT & LOSS TARGETS:");
   Print("   Individual TP: $", DoubleToString(individualTP, 2), " (", DoubleToString(IndividualTPFactor, 1), "x gap)");
   Print("   Group TP: $", DoubleToString(groupTP, 2), " (", DoubleToString(GroupTPFactor, 1), "x gap)");
   Print("   Individual SL: ", DoubleToString(IndividualSLPercent, 2), "% of balance per trade");
   Print("   At $100k: ", DoubleToString(IndividualSLPercent, 2), "% = $", DoubleToString(balance * IndividualSLPercent / 100.0, 2), " risk per trade");
   
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   currentDay = time.day;
   lastDayCheck = TimeCurrent();
   
   Print("═══════════════════════════════════════");
   Print("⚡ AGGRESSIVE STRATEGY:");
   Print("   Direction: ", Direction == BUYONLY ? "BUY UP & DOWN" : "SELL UP & DOWN");
   Print("   Opens positions as price moves through grid");
   Print("   Replaces closed positions automatically");
   Print("   Takes profits aggressively");
   Print("═══════════════════════════════════════");
   Print("🔍 DEBUG: Press 'D' key for status");
   Print("👁️ PANEL: Press 'H' key to hide/show");
   Print("═══════════════════════════════════════");
   
   // Create panel
   if(ShowPanel) CreatePanel();
   
   // Sync existing positions
   SyncPositions();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, panelPrefix);
   ChartRedraw();
   
   Print("═══════════════════════════════════════");
   Print("👋 ", EA_NAME, " stopped");
   Print("Total trades: ", totalTrades);
   Print("═══════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| ON TICK                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check if paused
   if(isPaused)
   {
      UpdatePanel();
      return;
   }
   
   // Check emergency stop
   if(emergencyStop)
   {
      UpdatePanel();
      return;
   }
   
   // Check daily target
   if(dailyTargetReached)
   {
      UpdatePanel();
      return;
   }
   
   // Daily reset check
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   if(time.day != currentDay)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyProfit = 0;
      dailyTarget = dailyStartBalance * DailyTargetPercent / 100.0;
      dailyTargetReached = false;
      currentDay = time.day;
      lastDayCheck = TimeCurrent();
      Print("📅 New day - Daily profit reset. Target: $", DoubleToString(dailyTarget, 2));
   }
   
   // Check spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      UpdatePanel();
      return;
   }
   
   // Update peak equity and check drawdown
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > peakEquity)
      peakEquity = equity;
   
   double drawdown = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   if(drawdown < -MaxDrawdownPercent)
   {
      emergencyStop = true;
      emergencyReason = "Max drawdown exceeded";
      CloseAllPositions();
      Print("🛑 EMERGENCY STOP: ", emergencyReason);
      UpdatePanel();
      return;
   }
   
   // Check daily profit target
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - dailyStartBalance;
   
   if(dailyProfit >= dailyTarget)
   {
      dailyTargetReached = true;
      CloseAllPositions();
      Print("🎯 DAILY TARGET REACHED: $", DoubleToString(dailyProfit, 2));
      UpdatePanel();
      return;
   }
   
   // Sync positions
   SyncPositions();
   
   // Calculate total profit
   CalculateTotalProfit();
   
   // Check group TP/SL
   CheckGroupTPSL();
   
   // Grid logic
   CheckGrid();
   
   // Update panel
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| GRID LOGIC - REPLACES CLOSED POSITIONS                            |
//+------------------------------------------------------------------+
void CheckGrid()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Find the nearest grid level to current price
   double distanceFromReference = currentPrice - referencePrice;
   int levelIndex = (int)MathRound(distanceFromReference / currentGapSize);
   double nearestGridLevel = referencePrice + (levelIndex * currentGapSize);
   
   // Calculate how close we are to the nearest level
   double distanceToNearestLevel = MathAbs(currentPrice - nearestGridLevel);
   
   // Adaptive trigger zone based on symbol characteristics
   // For high-value symbols (like BTC), use tighter percentage
   // For low-value symbols (like forex), use wider percentage
   double triggerPercent = 0.05;  // Default 5%
   
   if(currentPrice > 10000)  // High-value symbols like BTC
   {
      triggerPercent = 0.02;  // 2% trigger zone
   }
   else if(currentPrice > 1000)  // Medium-value like Gold
   {
      triggerPercent = 0.03;  // 3% trigger zone
   }
   else  // Low-value like Forex pairs
   {
      triggerPercent = 0.05;  // 5% trigger zone
   }
   
   double triggerZone = currentGapSize * triggerPercent;
   
   // Only trigger if we're VERY close to a grid level
   if(distanceToNearestLevel > triggerZone)
      return;
   
   // Check if we already have a position at this level
   bool levelHasPosition = false;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      double entryDiff = MathAbs(positions[i].entryPrice - nearestGridLevel);
      if(entryDiff < (currentGapSize * 0.15))  // Within 15% of gap = same level
      {
         levelHasPosition = true;
         break;
      }
   }
   
   // If no position at this level and under max, open one
   if(!levelHasPosition && ArraySize(positions) < MaxPositions)
   {
      ENUM_ORDER_TYPE orderType = (Direction == BUYONLY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double openPrice = (Direction == BUYONLY) ? ask : bid;
      
      if(OpenPosition(orderType, openPrice, nearestGridLevel))
      {
         string dirStr = (Direction == BUYONLY) ? "BUY" : "SELL";
         Print("⚡ ", dirStr, " opened at grid level: $", DoubleToString(nearestGridLevel, digits));
         Print("   Distance from level: $", DoubleToString(distanceToNearestLevel, 6));
         Print("   Trigger zone: $", DoubleToString(triggerZone, 6), " (", DoubleToString(triggerPercent * 100, 1), "% of gap)");
      }
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
            Position pos;
            pos.ticket = ticket;
            pos.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            pos.entryTime = (datetime)PositionGetInteger(POSITION_TIME);
            
            int size = ArraySize(positions);
            ArrayResize(positions, size + 1);
            positions[size] = pos;
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
//| CHECK GROUP TP/SL                                                 |
//+------------------------------------------------------------------+
void CheckGroupTPSL()
{
   // Check Group TP
   if(GroupTPFactor > 0)
   {
      double groupTPDollars = currentGapSize * GroupTPFactor;
      
      // Debug output
      static datetime lastTPDebug = 0;
      if(TimeCurrent() - lastTPDebug >= 60)  // Every 60 seconds
      {
         lastTPDebug = TimeCurrent();
         Print("💰 GROUP TP CHECK: Current P/L: $", DoubleToString(totalProfit, 2), 
               " | Target: $", DoubleToString(groupTPDollars, 2),
               " | Gap: $", DoubleToString(currentGapSize, 2), 
               " | Factor: ", DoubleToString(GroupTPFactor, 1));
      }
      
      if(totalProfit >= groupTPDollars)
      {
         Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
         Print("🎯 GROUP TP HIT: $", DoubleToString(totalProfit, 2), " (Target: $", DoubleToString(groupTPDollars, 2), ")");
         CloseAllPositions();
         Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
         return;  // Exit after closing
      }
   }
   
   // Note: Individual 1% balance SL protects each position
   // No group SL needed - positions close individually at their SLs
}

//+------------------------------------------------------------------+
//| OPEN POSITION                                                     |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE orderType, double price, double levelPrice)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = validatedLotSize;
   request.type = orderType;
   request.price = price;
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = StringFormat("AGG_%.2f", levelPrice);
   
   // Set TP based on individual TP factor
   if(IndividualTPFactor > 0)
   {
      double tpDistance = currentGapSize * IndividualTPFactor;
      
      if(orderType == ORDER_TYPE_BUY)
      {
         request.tp = NormalizeDouble(price + tpDistance, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      }
      else
      {
         request.tp = NormalizeDouble(price - tpDistance, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      }
   }
   
   // ALWAYS set SL based on IndividualSLPercent
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (IndividualSLPercent / 100.0);  // Configurable % of balance
   
   // Get symbol specifications
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // Calculate value per point for 1 lot
   // For most symbols: value per point = (contract size × tick value) / tick size
   // But we need to be more precise
   double valuePerPointPerLot;
   
   if(tickSize > 0)
   {
      // Calculate how many points in one tick
      double pointsPerTick = tickSize / point;
      if(pointsPerTick > 0)
      {
         // Value per point = tick value / points per tick
         valuePerPointPerLot = tickValue / pointsPerTick;
      }
      else
      {
         // Fallback: use tick value directly
         valuePerPointPerLot = tickValue / point;
      }
   }
   else
   {
      // Fallback calculation
      valuePerPointPerLot = tickValue;
   }
   
   // Calculate value per point for our lot size
   double valuePerPoint = valuePerPointPerLot * validatedLotSize;
   
   // Calculate SL distance in points
   double slDistancePoints = riskAmount / valuePerPoint;
   
   // Convert points to price
   double slDistancePrice = slDistancePoints * point;
   
   // Apply SL
   if(orderType == ORDER_TYPE_BUY)
   {
      request.sl = NormalizeDouble(price - slDistancePrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   }
   else
   {
      request.sl = NormalizeDouble(price + slDistancePrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   }
   
   // Debug output
   Print("💰 SL Calculation:");
   Print("   Balance: $", DoubleToString(balance, 2));
   Print("   SL Risk: ", DoubleToString(IndividualSLPercent, 2), "% = $", DoubleToString(riskAmount, 2));
   Print("   Tick Value: $", DoubleToString(tickValue, 4));
   Print("   Tick Size: $", DoubleToString(tickSize, 6));
   Print("   Point: $", DoubleToString(point, 6));
   Print("   Contract Size: ", DoubleToString(contractSize, 2));
   Print("   Value/Point/Lot: $", DoubleToString(valuePerPointPerLot, 4));
   Print("   Value/Point (", DoubleToString(validatedLotSize, 2), " lots): $", DoubleToString(valuePerPoint, 4));
   Print("   SL Distance: ", DoubleToString(slDistancePoints, 2), " points = $", DoubleToString(slDistancePrice, 2));
   Print("   Entry: $", DoubleToString(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   Print("   SL: $", DoubleToString(request.sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   
   if(!OrderSend(request, result))
   {
      Print("❌ Order failed: ", result.retcode, " - ", result.comment);
      return false;
   }
   
   if(result.retcode == TRADE_RETCODE_DONE)
   {
      totalTrades++;
      string typeStr = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";
      Print("✅ ", typeStr, " position opened: Ticket #", result.order);
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   int closed = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            ClosePosition(ticket);
            closed++;
         }
      }
   }
   
   Print("🔒 Closed ", closed, " positions");
   SyncPositions();
}

//+------------------------------------------------------------------+
//| CLOSE PROFITABLE POSITIONS ONLY                                   |
//+------------------------------------------------------------------+
void CloseProfitablePositions()
{
   int closed = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            if(PositionSelectByTicket(ticket))
            {
               double profit = PositionGetDouble(POSITION_PROFIT);
               if(profit > 0)
               {
                  ClosePosition(ticket);
                  closed++;
               }
            }
         }
      }
   }
   
   Print("💰 Closed ", closed, " profitable positions");
   SyncPositions();
}

//+------------------------------------------------------------------+
//| REBUILD GRID AROUND CURRENT PRICE                                |
//+------------------------------------------------------------------+
void RebuildGrid()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   // Set new reference to current price
   referencePrice = currentPrice;
   
   // Recalculate gap
   currentGapSize = referencePrice * GridGapPercent / 100.0;
   
   Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
   Print("🔄 GRID REBUILT");
   Print("   New Reference: $", DoubleToString(referencePrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   Print("   Grid Gap: $", DoubleToString(currentGapSize, 2));
   Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
}

//+------------------------------------------------------------------+
//| CLOSE SINGLE POSITION                                             |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.deviation = 10;
   request.magic = MagicNumber;
   request.position = ticket;
   
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   
   if(type == POSITION_TYPE_BUY)
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
      Print("❌ Failed to close position #", ticket, ": ", result.retcode, " - ", result.comment);
   }
   else if(result.retcode != TRADE_RETCODE_DONE)
   {
      Print("⚠️ Close position #", ticket, " returned: ", result.retcode);
   }
}

//+------------------------------------------------------------------+
//| DEBUG STATUS                                                      |
//+------------------------------------------------------------------+
void PrintDebugStatus()
{
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   
   Print("╔══════════════════════════════════════════════════════════════╗");
   Print("║ ", EA_NAME, " v", EA_VERSION, "                              ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ GRID STATUS                                                  ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Direction:             ", Direction == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   Print("Current Price:         $", DoubleToString(currentPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   Print("Reference Price:       $", DoubleToString(referencePrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   Print("Grid Gap:              $", DoubleToString(currentGapSize, 2), " (", DoubleToString(GridGapPercent, 2), "%)");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ POSITIONS                                                    ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Active Positions:      ", ArraySize(positions), "/", MaxPositions);
   Print("Total Trades:          ", totalTrades);
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ PROFIT & RISK                                                ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Floating P/L:          ", (totalProfit >= 0 ? "+" : ""), "$", DoubleToString(totalProfit, 2));
   Print("Equity:                $", DoubleToString(equity, 2));
   Print("Balance:               $", DoubleToString(balance, 2));
   Print("Drawdown:              ", DoubleToString(dd, 2), "%");
   Print("Daily Profit:          $", DoubleToString(dailyProfit, 2));
   Print("Daily Target:          $", DoubleToString(dailyTarget, 2));
   Print("╚══════════════════════════════════════════════════════════════╝");
}

//+------------------------------------------------------------------+
//| CHART EVENT HANDLER                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_KEYDOWN)
   {
      // H key
      if(lparam == 72 || lparam == 104)
      {
         panelVisible = !panelVisible;
         TogglePanelVisibility();
         Print(panelVisible ? "👁️ Panel shown" : "👁️ Panel hidden");
      }
      // D key
      else if(lparam == 68 || lparam == 100)
      {
         PrintDebugStatus();
      }
   }
   
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      // CLOSE button - Works even when EA is paused
      if(sparam == panelPrefix + "CloseBtn")
      {
         ObjectSetInteger(0, panelPrefix + "CloseBtn", OBJPROP_STATE, false);
         if(ArraySize(positions) > 0)
         {
            Print("🔴 CLOSE button pressed - Closing all positions...");
            CloseAllPositions();
            Print("✅ All positions closed");
         }
         else
         {
            Print("ℹ️ No positions to close");
         }
      }
      // PAUSE/RESUME button
      else if(sparam == panelPrefix + "PauseBtn")
      {
         ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_STATE, false);
         isPaused = !isPaused;
         Print(isPaused ? "⏸️ EA PAUSED - No new positions will open" : "▶️ EA RESUMED - Trading active");
         Print(isPaused ? "   (CLOSE and TAKE TP buttons still work)" : "");
      }
      // TAKE TP button - Works even when EA is paused
      else if(sparam == panelPrefix + "TPBtn")
      {
         ObjectSetInteger(0, panelPrefix + "TPBtn", OBJPROP_STATE, false);
         Print("💰 TAKE TP button pressed - Closing profitable positions...");
         CloseProfitablePositions();
         Print("✅ Profitable positions closed");
      }
   }
}

//+------------------------------------------------------------------+
//| TOGGLE PANEL VISIBILITY                                          |
//+------------------------------------------------------------------+
void TogglePanelVisibility()
{
   string objects[] = {
      "Background", "Title", "Status",
      "CloseBtn", "PauseBtn", "TPBtn",
      "DirectionLabel", "Direction",
      "PriceLabel", "Price",
      "GridLabel", "GridSpacing",
      "SpreadLabel", "Spread",
      "RefLabel", "RefPrice",
      "PosLabel", "Positions",
      "PnLLabel", "PnL",
      "EquityLabel", "Equity",
      "DDLabel", "DD",
      "DailyLabel", "DailyProfit",
      "Brand"
   };
   
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
   int width = 280;
   int lineHeight = 20;
   
   // Background - SOLID, ON TOP OF EVERYTHING
   ObjectCreate(0, panelPrefix + "Background", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YSIZE, 310);  // Reduced height (removed REBUILD button)
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BGCOLOR, C'20,20,25');
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_ZORDER, 0);
   
   int yPos = y + 10;
   
   // Title
   CreateLabel(panelPrefix + "Title", x + 10, yPos, "AGGRESSIVE TRADER", clrGold, 10, "Arial Black");
   yPos += 25;
   
   // Status
   CreateLabel(panelPrefix + "Status", x + 10, yPos, "✅ ACTIVE", clrLimeGreen, 9, "Arial Black");
   yPos += lineHeight;
   
   // Buttons - Single Row
   CreateButton(panelPrefix + "CloseBtn", x + 10, yPos, 85, 25, "CLOSE", clrRed, clrWhite);
   CreateButton(panelPrefix + "PauseBtn", x + 100, yPos, 85, 25, "PAUSE", clrOrange, clrWhite);
   CreateButton(panelPrefix + "TPBtn", x + 190, yPos, 80, 25, "TAKE TP", clrGreen, clrWhite);
   yPos += 35;
   
   // Direction
   color dirColor = (Direction == BUYONLY) ? clrDodgerBlue : clrOrangeRed;
   CreateLabel(panelPrefix + "DirectionLabel", x + 10, yPos, "Direction:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Direction", x + 100, yPos, Direction == BUYONLY ? "BUY ONLY" : "SELL ONLY", dirColor, 9, "Arial Black");
   yPos += lineHeight;
   
   // Price
   CreateLabel(panelPrefix + "PriceLabel", x + 10, yPos, "Price:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Price", x + 100, yPos, "$0", clrWhite, 9, "Arial Black");
   yPos += lineHeight;
   
   // Grid
   CreateLabel(panelPrefix + "GridLabel", x + 10, yPos, "Grid Gap:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "GridSpacing", x + 100, yPos, "0.3%", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // Spread
   CreateLabel(panelPrefix + "SpreadLabel", x + 10, yPos, "Spread:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Spread", x + 100, yPos, "0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // Reference
   CreateLabel(panelPrefix + "RefLabel", x + 10, yPos, "Reference:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "RefPrice", x + 100, yPos, "$0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight + 5;
   
   // Positions
   CreateLabel(panelPrefix + "PosLabel", x + 10, yPos, "⚡ Positions:", clrGold, 9, "Arial Black");
   CreateLabel(panelPrefix + "Positions", x + 100, yPos, "0/20", clrWhite, 9, "Arial Black");
   yPos += lineHeight + 5;
   
   // P/L
   CreateLabel(panelPrefix + "PnLLabel", x + 10, yPos, "P/L:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "PnL", x + 100, yPos, "$0", clrWhite, 10, "Arial Black");
   yPos += lineHeight;
   
   // Equity
   CreateLabel(panelPrefix + "EquityLabel", x + 10, yPos, "Equity:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Equity", x + 100, yPos, "$0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // Drawdown
   CreateLabel(panelPrefix + "DDLabel", x + 10, yPos, "Drawdown:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DD", x + 100, yPos, "0%", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // Daily Profit
   CreateLabel(panelPrefix + "DailyLabel", x + 10, yPos, "Daily:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DailyProfit", x + 100, yPos, "$0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight + 10;
   
   // TORAMA CAPITAL BRANDING - Bottom right inside panel with 10px right margin
   // Using right anchor for proper alignment
   int brandX = x + width - 10;  // 10px from right edge of panel
   ObjectCreate(0, panelPrefix + "Brand", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_XDISTANCE, brandX);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_YDISTANCE, yPos);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_FONT, "Arial Black");
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_TEXT, "TORAMA CAPITAL");
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);  // Right-aligned
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_ZORDER, 0);
}

//+------------------------------------------------------------------+
//| FORMAT PRICE (REMOVE .00)                                         |
//+------------------------------------------------------------------+
string FormatPrice(double price, int digits)
{
   string priceStr = DoubleToString(price, digits);
   
   // Remove .00 or .0 at the end
   if(StringFind(priceStr, ".") >= 0)
   {
      while(StringSubstr(priceStr, StringLen(priceStr) - 1) == "0")
         priceStr = StringSubstr(priceStr, 0, StringLen(priceStr) - 1);
      
      if(StringSubstr(priceStr, StringLen(priceStr) - 1) == ".")
         priceStr = StringSubstr(priceStr, 0, StringLen(priceStr) - 1);
   }
   
   return priceStr;
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
   if(dailyTargetReached)
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
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "⏸️ PAUSED (Buttons Active)");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrOrange);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "✅ ACTIVE");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrLimeGreen);
   }
   
   // Pause button text
   ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, isPaused ? "RESUME" : "PAUSE");
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, isPaused ? clrGreen : clrOrange);
   
   // Price
   ObjectSetString(0, panelPrefix + "Price", OBJPROP_TEXT, "$" + FormatPrice(currentPrice, digits));
   
   // Grid
   ObjectSetString(0, panelPrefix + "GridSpacing", OBJPROP_TEXT,
                   FormatPrice(GridGapPercent, 2) + "% ($" + FormatPrice(currentGapSize, 2) + ")");
   
   // Spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   color spreadColor = (spread > MaxSpread) ? clrRed : (spread > MaxSpread * 0.7) ? clrOrange : clrLimeGreen;
   ObjectSetString(0, panelPrefix + "Spread", OBJPROP_TEXT, IntegerToString(spread) + "/" + IntegerToString(MaxSpread));
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_COLOR, spreadColor);
   
   // Reference
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, "$" + FormatPrice(referencePrice, digits));
   
   // Positions
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT,
                   IntegerToString(ArraySize(positions)) + "/" + IntegerToString(MaxPositions));
   
   // P/L
   CalculateTotalProfit();
   color pnlColor = (totalProfit >= 0) ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "PnL", OBJPROP_TEXT,
                   (totalProfit >= 0 ? "+" : "") + "$" + FormatPrice(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "PnL", OBJPROP_COLOR, pnlColor);
   
   // Equity
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT, "$" + FormatPrice(equity, 2));
   
   // Drawdown
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   color ddColor = (dd >= -5) ? clrLimeGreen : (dd >= -10) ? clrYellow : clrRed;
   ObjectSetString(0, panelPrefix + "DD", OBJPROP_TEXT, FormatPrice(dd, 1) + "%");
   ObjectSetInteger(0, panelPrefix + "DD", OBJPROP_COLOR, ddColor);
   
   // Daily Profit
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - dailyStartBalance;
   
   color dailyColor = (dailyProfit >= dailyTarget) ? clrGold : 
                      (dailyProfit >= 0) ? clrLimeGreen : clrRed;
   
   ObjectSetString(0, panelPrefix + "DailyProfit", OBJPROP_TEXT,
                   (dailyProfit >= 0 ? "+" : "") + "$" + FormatPrice(dailyProfit, 2));
   ObjectSetInteger(0, panelPrefix + "DailyProfit", OBJPROP_COLOR, dailyColor);
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
   ObjectSetInteger(0, name, OBJPROP_BACK, false);     // Keep on front
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);    // Hide from object list
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);       // Top layer
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
   ObjectSetInteger(0, name, OBJPROP_BACK, false);     // Keep on front
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);    // Hide from object list
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);       // Top layer
}

//+------------------------------------------------------------------+
