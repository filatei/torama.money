//+------------------------------------------------------------------+
//|                    TORAMA Aggressive Trader EA v5.6              |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "5.6"
#property description "Aggressive Directional Grid Trader with ATR-Based Mode Switching"
#property description "Trades ONLY in chosen direction as price moves"
#property description "Replaces closed positions automatically"
#property description ""
#property description "V5.6: Shows next buy/sell levels + fast market optimizations"

#define EA_VERSION "5.6"
#define EA_NAME "TORAMA AGGRESSIVE TRADER"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

enum ENUM_TRADE_DIRECTION
{
   BUYONLY,    // BUY ONLY - Buys up and down the grid
   SELLONLY    // SELL ONLY - Sells up and down the grid
};

input group "=== DIRECTION & ATR MODE SWITCHING ==="
input ENUM_TRADE_DIRECTION StartDirection = BUYONLY;  // Starting Direction
input bool     EnableATRSwitch = true;                // Enable ATR-based mode switching
input int      ATRPeriod = 14;                        // ATR Period for mode switching
input double   ATRThresholdPercent = 70.0;            // ATR Threshold % (70 = 0.7 × ATR)
input bool     CloseOnModeSwitch = false;             // Close positions on mode switch (false = let them run)

input group "=== GRID SETTINGS ==="
input double   GridGapPercent = 0.01;                 // Grid gap % (0.01 = tight, 0.3 = wide)
input int      MaxPositions = 100;                    // Maximum positions
input double   LotSize = 0.2;                         // Lot size per position

input group "=== TAKE PROFIT ==="
input double   IndividualTPDollars = 50.0;            // Individual TP target ($50 per position)
input double   GroupTPDollars = 200.0;                // Group TP target ($200 total profit closes all)

input group "=== STOP LOSS ==="
input double   IndividualSLDollars = 100.0;           // SL risk per trade ($100 max loss, 0 = disabled)

input group "=== RISK MANAGEMENT ==="
input double   MaxDrawdownPercent = 25.0;             // Max drawdown % (emergency stop)
input double   DailyTargetPercent = 100.0;            // Daily profit target (% of start balance)

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                      // Maximum spread (points)
input bool     ShowPanel = true;                      // Show info panel

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

// Current trading mode (can be switched dynamically)
ENUM_TRADE_DIRECTION CurrentDirection;

// ATR Mode Switching
int atrHandle = INVALID_HANDLE;
double dayOpenPrice = 0;
double currentATR = 0;
datetime lastDayOpenUpdate = 0;
datetime lastModeSwitchTime = 0;
int modeSwitchCooldownBars = 100;

// Grid tracking
double referencePrice = 0;
double currentGapSize = 0;

// Next grid levels (NEW in v5.6)
double nextBuyLevel = 0;
double nextSellLevel = 0;

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
int modeSwitchCount = 0;

// Magic number
int MagicNumber = 0;

// Panel
string panelPrefix = "TORAMA_AGG_";
bool panelVisible = true;

// Fast market optimization (NEW in v5.6)
datetime lastGridCheck = 0;
uint gridCheckIntervalMs = 100;  // Check every 100ms in fast markets

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
//| GENERATE PERSISTENT CHART-BASED MAGIC NUMBER                     |
//+------------------------------------------------------------------+
int GenerateChartBasedMagicNumber()
{
   long chartId = ChartID();
   
   string symbolStr = _Symbol;
   int symbolHash = 0;
   
   for(int i = 0; i < StringLen(symbolStr); i++)
   {
      symbolHash = (symbolHash * 31 + StringGetCharacter(symbolStr, i)) % 1000000;
   }
   
   int magic = (int)((chartId % 1000000) * 1000 + symbolHash) % 2147483647;
   
   if(magic == 0) magic = (int)(chartId % 2147483647);
   if(magic == 0) magic = 123456;
   
   return magic;
}

//+------------------------------------------------------------------+
//| INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("═══════════════════════════════════════");
   Print("🚀 ", EA_NAME, " v", EA_VERSION);
   Print("═══════════════════════════════════════");
   
   Print("💰 ACCOUNT INFO:");
   Print("   Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("   Equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("   Leverage: 1:", IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE)));
   Print("   Currency: ", AccountInfoString(ACCOUNT_CURRENCY));
   
   MagicNumber = GenerateChartBasedMagicNumber();
   Print("🔢 Magic Number (Chart ID: ", ChartID(), "): ", MagicNumber);
   
   if(!InitializeSymbolSpecs())
   {
      Print("❌ FAILED: Could not initialize symbol specifications");
      return(INIT_FAILED);
   }
   
   validatedLotSize = ValidateLotSize(LotSize);
   
   Print("📊 CONFIGURATION:");
   Print("   Starting Direction: ", StartDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   Print("   Symbol: ", _Symbol);
   Print("   Lot Size: ", DoubleToString(validatedLotSize, 3));
   Print("   Max Positions: ", MaxPositions);
   
   CurrentDirection = StartDirection;
   
   if(EnableATRSwitch)
   {
      Print("═══════════════════════════════════════");
      Print("📈 ATR MODE SWITCHING: ENABLED");
      Print("   ATR Period: ", ATRPeriod);
      Print("   ATR Threshold: ", DoubleToString(ATRThresholdPercent, 1), "% of ATR");
      Print("   Close on Switch: ", CloseOnModeSwitch ? "YES (close all positions)" : "NO (let positions run)");
      Print("   Logic: Price moves above open by 0.7×ATR → Switch to SELL");
      Print("          Price moves below open by 0.7×ATR → Switch to BUY");
      
      atrHandle = iATR(_Symbol, PERIOD_D1, ATRPeriod);
      if(atrHandle == INVALID_HANDLE)
      {
         Print("❌ FAILED: Could not create ATR indicator handle");
         return(INIT_FAILED);
      }
      
      UpdateDayOpenPrice();
      
      if(!WaitForIndicator(atrHandle))
      {
         Print("⚠️ WARNING: ATR indicator not ready, mode switching may be delayed");
      }
      else
      {
         double atr_buffer[];
         ArraySetAsSeries(atr_buffer, true);
         if(CopyBuffer(atrHandle, 0, 0, 1, atr_buffer) > 0)
         {
            currentATR = atr_buffer[0];
            Print("   Current Daily ATR: $", DoubleToString(currentATR, 2));
            Print("   Switch threshold: $", DoubleToString(currentATR * ATRThresholdPercent / 100.0, 2));
         }
      }
   }
   else
   {
      Print("═══════════════════════════════════════");
      Print("📈 ATR MODE SWITCHING: DISABLED");
      Print("   Direction will remain: ", CurrentDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   }
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(ask <= 0 || bid <= 0)
   {
      Print("❌ FAILED: Invalid price data");
      return(INIT_FAILED);
   }
   
   referencePrice = (ask + bid) / 2.0;
   currentGapSize = referencePrice * GridGapPercent / 100.0;
   
   if(!ValidateGridGap())
   {
      Print("⚠️ WARNING: Grid gap validation failed - proceed with caution");
   }
   
   Print("📍 STARTING REFERENCE: $", DoubleToString(referencePrice, specs.digits));
   Print("📏 Grid Gap: $", DoubleToString(currentGapSize, specs.digits), " (", DoubleToString(GridGapPercent, 3), "%)");
   
   // Calculate initial next levels (NEW in v5.6)
   CalculateNextGridLevels();
   
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyTarget = dailyStartBalance * DailyTargetPercent / 100.0;
   Print("🎯 Daily Target: $", DoubleToString(dailyTarget, 2), " (", DoubleToString(DailyTargetPercent, 0), "%)");
   
   PrintRiskAnalysis();
   
   Print("═══════════════════════════════════════");
   Print("🎯 PROFIT & LOSS TARGETS:");
   Print("   Individual TP: $", DoubleToString(IndividualTPDollars, 2));
   Print("   Group TP: $", DoubleToString(GroupTPDollars, 2));
   Print("   Individual SL: ", IndividualSLDollars > 0 ? "$" + DoubleToString(IndividualSLDollars, 2) : "DISABLED");
   
   double pointValue = specs.tickValue / specs.tickSize;
   double positionValue = pointValue * validatedLotSize;
   
   if(IndividualTPDollars > 0)
   {
      double tpDistance = IndividualTPDollars / positionValue;
      double tpPercent = (tpDistance / referencePrice) * 100.0;
      Print("   Expected TP Distance: $", DoubleToString(tpDistance, 4), " (", DoubleToString(tpPercent, 3), "%)");
   }
   
   if(IndividualSLDollars > 0)
   {
      double slDistance = IndividualSLDollars / positionValue;
      double slPercent = (slDistance / referencePrice) * 100.0;
      Print("   Expected SL Distance: $", DoubleToString(slDistance, 4), " (", DoubleToString(slPercent, 3), "%)");
   }
   
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   currentDay = time.day;
   lastDayCheck = TimeCurrent();
   
   Print("═══════════════════════════════════════");
   Print("⚡ AGGRESSIVE STRATEGY:");
   Print("   Opens positions as price moves through grid");
   Print("   Replaces closed positions automatically");
   Print("   Manual mode switch button available on panel");
   Print("═══════════════════════════════════════");
   Print("🆕 v5.6 FEATURES:");
   Print("   ✓ Shows next BUY and SELL price levels on panel");
   Print("   ✓ Optimized for fast-moving markets");
   Print("   ✓ Pre-calculated grid levels for quick execution");
   Print("═══════════════════════════════════════");
   Print("🔍 DEBUG: Press 'D' key for status");
   Print("👁️ PANEL: Press 'H' key to hide/show");
   Print("═══════════════════════════════════════");
   
   if(ShowPanel) CreatePanel();
   
   SyncPositions();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| CALCULATE NEXT GRID LEVELS (NEW in v5.6)                        |
//+------------------------------------------------------------------+
void CalculateNextGridLevels()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   // Find current grid level
   double distanceFromReference = currentPrice - referencePrice;
   int currentLevelIndex = (int)MathRound(distanceFromReference / currentGapSize);
   
   // Calculate next levels based on current direction
   if(CurrentDirection == BUYONLY)
   {
      // For BUY ONLY: we want to buy on both up and down moves
      // Next BUY below current price
      nextBuyLevel = referencePrice + ((currentLevelIndex - 1) * currentGapSize);
      
      // Also calculate next BUY above (for completeness)
      double nextBuyLevelUp = referencePrice + ((currentLevelIndex + 1) * currentGapSize);
      
      // Use the closest one to current price that doesn't have a position
      if(MathAbs(currentPrice - nextBuyLevel) > MathAbs(currentPrice - nextBuyLevelUp))
      {
         nextBuyLevel = nextBuyLevelUp;
      }
      
      nextSellLevel = 0;  // Not applicable in BUY ONLY mode
   }
   else  // SELLONLY
   {
      // For SELL ONLY: we want to sell on both up and down moves
      // Next SELL above current price
      nextSellLevel = referencePrice + ((currentLevelIndex + 1) * currentGapSize);
      
      // Also calculate next SELL below (for completeness)
      double nextSellLevelDown = referencePrice + ((currentLevelIndex - 1) * currentGapSize);
      
      // Use the closest one to current price that doesn't have a position
      if(MathAbs(currentPrice - nextSellLevel) > MathAbs(currentPrice - nextSellLevelDown))
      {
         nextSellLevel = nextSellLevelDown;
      }
      
      nextBuyLevel = 0;  // Not applicable in SELL ONLY mode
   }
   
   // Adjust for existing positions - find truly next empty level
   AdjustNextLevelsForExistingPositions();
}

//+------------------------------------------------------------------+
//| ADJUST NEXT LEVELS FOR EXISTING POSITIONS (NEW in v5.6)         |
//+------------------------------------------------------------------+
void AdjustNextLevelsForExistingPositions()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   double minDistanceBetweenPositions = currentGapSize * 0.8;
   
   if(CurrentDirection == BUYONLY && nextBuyLevel > 0)
   {
      // Check if next buy level has a position
      bool levelOccupied = true;
      int iterations = 0;
      
      while(levelOccupied && iterations < 50)  // Safety limit
      {
         levelOccupied = false;
         
         for(int i = 0; i < ArraySize(positions); i++)
         {
            if(MathAbs(positions[i].entryPrice - nextBuyLevel) < minDistanceBetweenPositions)
            {
               levelOccupied = true;
               // Move to next grid level (above or below current price)
               if(nextBuyLevel < currentPrice)
                  nextBuyLevel -= currentGapSize;
               else
                  nextBuyLevel += currentGapSize;
               break;
            }
         }
         
         iterations++;
      }
   }
   else if(CurrentDirection == SELLONLY && nextSellLevel > 0)
   {
      // Check if next sell level has a position
      bool levelOccupied = true;
      int iterations = 0;
      
      while(levelOccupied && iterations < 50)
      {
         levelOccupied = false;
         
         for(int i = 0; i < ArraySize(positions); i++)
         {
            if(MathAbs(positions[i].entryPrice - nextSellLevel) < minDistanceBetweenPositions)
            {
               levelOccupied = true;
               // Move to next grid level
               if(nextSellLevel > currentPrice)
                  nextSellLevel += currentGapSize;
               else
                  nextSellLevel -= currentGapSize;
               break;
            }
         }
         
         iterations++;
      }
   }
}

//+------------------------------------------------------------------+
//| UPDATE DAY OPEN PRICE                                            |
//+------------------------------------------------------------------+
void UpdateDayOpenPrice()
{
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   
   time.hour = 0;
   time.min = 0;
   time.sec = 0;
   datetime todayOpen = StructToTime(time);
   
   MqlRates rates[];
   int copied = CopyRates(_Symbol, PERIOD_D1, 0, 1, rates);
   
   if(copied > 0)
   {
      dayOpenPrice = rates[0].open;
      lastDayOpenUpdate = TimeCurrent();
      
      Print("📅 Day Open Price Updated: $", DoubleToString(dayOpenPrice, specs.digits));
   }
   else
   {
      Print("⚠️ WARNING: Could not retrieve day's open price");
   }
}

//+------------------------------------------------------------------+
//| CHECK ATR MODE SWITCHING                                         |
//+------------------------------------------------------------------+
void CheckATRModeSwitch()
{
   if(!EnableATRSwitch) return;
   
   if(TimeCurrent() - lastModeSwitchTime < modeSwitchCooldownBars * PeriodSeconds())
      return;
   
   if(atrHandle != INVALID_HANDLE)
   {
      double atr_buffer[];
      ArraySetAsSeries(atr_buffer, true);
      
      if(CopyBuffer(atrHandle, 0, 0, 1, atr_buffer) > 0)
      {
         currentATR = atr_buffer[0];
      }
      else
      {
         static datetime lastATRWarning = 0;
         if(TimeCurrent() - lastATRWarning > 3600)
         {
            Print("⚠️ WARNING: Could not read ATR buffer for mode switching");
            lastATRWarning = TimeCurrent();
         }
         return;
      }
   }
   else
   {
      return;
   }
   
   if(currentATR <= 0) return;
   if(dayOpenPrice <= 0) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   double distanceFromOpen = currentPrice - dayOpenPrice;
   double atrThreshold = currentATR * (ATRThresholdPercent / 100.0);
   
   bool shouldSwitch = false;
   ENUM_TRADE_DIRECTION newDirection = CurrentDirection;
   
   if(distanceFromOpen >= atrThreshold && CurrentDirection == BUYONLY)
   {
      newDirection = SELLONLY;
      shouldSwitch = true;
   }
   else if(distanceFromOpen <= -atrThreshold && CurrentDirection == SELLONLY)
   {
      newDirection = BUYONLY;
      shouldSwitch = true;
   }
   
   if(shouldSwitch)
   {
      SwitchTradingMode(newDirection, "ATR Threshold");
   }
}

//+------------------------------------------------------------------+
//| SWITCH TRADING MODE                                              |
//+------------------------------------------------------------------+
void SwitchTradingMode(ENUM_TRADE_DIRECTION newDirection, string reason)
{
   if(newDirection == CurrentDirection)
   {
      Print("ℹ️ Mode is already ", newDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
      return;
   }
   
   ENUM_TRADE_DIRECTION oldDirection = CurrentDirection;
   CurrentDirection = newDirection;
   modeSwitchCount++;
   
   lastModeSwitchTime = TimeCurrent();
   
   Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
   Print("🔄 MODE SWITCH #", modeSwitchCount);
   Print("   Reason: ", reason);
   Print("   From: ", oldDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   Print("   To: ", CurrentDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   
   if(EnableATRSwitch)
   {
      double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
      double distanceFromOpen = currentPrice - dayOpenPrice;
      Print("   Price vs Day Open: ", distanceFromOpen >= 0 ? "+" : "", DoubleToString(distanceFromOpen, 2));
      Print("   ATR Threshold: ±", DoubleToString(currentATR * ATRThresholdPercent / 100.0, 2));
   }
   
   if(ArraySize(positions) > 0)
   {
      if(CloseOnModeSwitch)
      {
         Print("   CloseOnModeSwitch = TRUE: Closing all ", ArraySize(positions), " existing positions...");
         CloseAllPositions();
      }
      else
      {
         Print("   CloseOnModeSwitch = FALSE: Keeping ", ArraySize(positions), " existing positions open");
         Print("   → Existing ", oldDirection == BUYONLY ? "BUY" : "SELL", 
               " positions will run to their TP/SL");
         Print("   → New positions will be ", CurrentDirection == BUYONLY ? "BUY" : "SELL", " only");
         
         Print("   Open Positions:");
         for(int i = 0; i < ArraySize(positions); i++)
         {
            if(PositionSelectByTicket(positions[i].ticket))
            {
               double profit = PositionGetDouble(POSITION_PROFIT);
               Print("      #", positions[i].ticket, " ", 
                     oldDirection == BUYONLY ? "BUY" : "SELL",
                     " @ $", DoubleToString(positions[i].entryPrice, specs.digits),
                     " | P/L: $", DoubleToString(profit, 2));
            }
         }
      }
   }
   else
   {
      Print("   No existing positions to manage");
   }
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   referencePrice = (ask + bid) / 2.0;
   
   currentGapSize = referencePrice * GridGapPercent / 100.0;
   
   Print("   New Reference Price: $", DoubleToString(referencePrice, specs.digits));
   Print("   New Grid Gap: $", DoubleToString(currentGapSize, specs.digits));
   Print("   Cooldown: ", modeSwitchCooldownBars, " bars");
   
   // Recalculate next levels for new direction (NEW in v5.6)
   CalculateNextGridLevels();
   
   Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
   
   UpdatePanel();
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
   
   if(specs.contractSize <= 0 || specs.point <= 0 || specs.minLot <= 0)
   {
      Print("❌ ERROR: Invalid symbol specifications");
      Print("   Contract Size: ", specs.contractSize);
      Print("   Point: ", specs.point);
      Print("   Min Lot: ", specs.minLot);
      return false;
   }
   
   specs.minStopDistance = specs.stopLevel * specs.point;
   
   if(specs.minStopDistance == 0 || specs.stopLevel == 0)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      specs.minStopDistance = MathMax(spread * specs.point * 2, specs.point * 10);
   }
   
   Print("🔧 SYMBOL SPECIFICATIONS:");
   Print("   Contract Size: ", DoubleToString(specs.contractSize, 2));
   Print("   Tick Value: $", DoubleToString(specs.tickValue, 4));
   Print("   Tick Size: ", DoubleToString(specs.tickSize, 5));
   Print("   Point: ", DoubleToString(specs.point, 5));
   Print("   Stop Level: ", specs.stopLevel, " points");
   Print("   Min Stop Distance: $", DoubleToString(specs.minStopDistance, 5));
   Print("   Digits: ", specs.digits);
   Print("   Lot Range: ", DoubleToString(specs.minLot, 2), " - ", DoubleToString(specs.maxLot, 2));
   Print("   Lot Step: ", DoubleToString(specs.lotStep, 3));
   
   return true;
}

//+------------------------------------------------------------------+
//| WAIT FOR INDICATOR TO BE READY                                   |
//+------------------------------------------------------------------+
bool WaitForIndicator(int handle, int timeout_ms = 5000)
{
   int start = (int)GetTickCount();
   
   while((int)GetTickCount() - start < timeout_ms)
   {
      if(BarsCalculated(handle) > 0)
         return true;
      
      Sleep(100);
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| VALIDATE LOT SIZE                                                 |
//+------------------------------------------------------------------+
double ValidateLotSize(double requestedLots)
{
   if(requestedLots < specs.minLot)
   {
      Print("⚠️ WARNING: Lot size ", requestedLots, " below minimum ", specs.minLot, ". Using minimum.");
      return specs.minLot;
   }
   
   if(requestedLots > specs.maxLot)
   {
      Print("⚠️ WARNING: Lot size ", requestedLots, " exceeds maximum ", specs.maxLot, ". Using maximum.");
      return specs.maxLot;
   }
   
   double normalizedLots = MathFloor(requestedLots / specs.lotStep) * specs.lotStep;
   
   if(normalizedLots < specs.minLot)
      normalizedLots = specs.minLot;
   
   return normalizedLots;
}

//+------------------------------------------------------------------+
//| VALIDATE GRID GAP                                                 |
//+------------------------------------------------------------------+
bool ValidateGridGap()
{
   if(currentGapSize < specs.minStopDistance)
   {
      Print("⚠️ WARNING: Grid gap ($", DoubleToString(currentGapSize, specs.digits), 
            ") smaller than minimum stop distance ($", DoubleToString(specs.minStopDistance, specs.digits), ")");
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| PRINT RISK ANALYSIS                                               |
//+------------------------------------------------------------------+
void PrintRiskAnalysis()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskPerTrade = IndividualSLDollars;
   double totalRisk = riskPerTrade * MaxPositions;
   double totalRiskPercent = (totalRisk / balance) * 100.0;
   
   Print("═══════════════════════════════════════");
   Print("💰 RISK ANALYSIS:");
   Print("   Account Balance: $", DoubleToString(balance, 2));
   
   if(IndividualSLDollars > 0)
   {
      Print("   SL Risk Per Trade: $", DoubleToString(riskPerTrade, 2), " (", DoubleToString((riskPerTrade/balance)*100, 2), "%)");
      Print("   Max Positions: ", MaxPositions);
      Print("   Total Portfolio Risk: $", DoubleToString(totalRisk, 2), " (", DoubleToString(totalRiskPercent, 1), "%)");
      Print("   Max Drawdown Limit: ", DoubleToString(MaxDrawdownPercent, 1), "%");
      
      if(totalRiskPercent > MaxDrawdownPercent)
      {
         Print("⚠️ WARNING: Total risk exceeds max drawdown");
         Print("   Emergency stop will trigger BEFORE all positions hit SL");
      }
      
      double emergencyStopLoss = balance * (MaxDrawdownPercent / 100.0);
      int maxPositionsBeforeStop = (int)MathFloor(emergencyStopLoss / riskPerTrade);
      Print("   Emergency stop triggers after ~", maxPositionsBeforeStop, " positions hit SL");
   }
   else
   {
      Print("   Individual SL: DISABLED");
      Print("   ⚠️ WARNING: Trading without stop losses!");
      Print("   Protection: Emergency stop at ", DoubleToString(MaxDrawdownPercent, 1), "%");
   }
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(atrHandle);
   }
   
   ObjectsDeleteAll(0, panelPrefix);
   ChartRedraw();
   
   Print("═══════════════════════════════════════");
   Print("👋 ", EA_NAME, " stopped");
   Print("Total trades: ", totalTrades);
   Print("Mode switches: ", modeSwitchCount);
   Print("═══════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| ON TICK - OPTIMIZED FOR FAST MARKETS (v5.6)                     |
//+------------------------------------------------------------------+
void OnTick()
{
   // Early exit checks for performance
   if(isPaused || emergencyStop || dailyTargetReached)
   {
      UpdatePanel();
      return;
   }
   
   // Spread check FIRST (fast exit)
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
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
      
      if(EnableATRSwitch)
      {
         UpdateDayOpenPrice();
      }
   }
   
   // ATR mode switching check
   CheckATRModeSwitch();
   
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
   
   // Check group TP
   CheckGroupTP();
   
   // OPTIMIZED GRID LOGIC (NEW in v5.6)
   // In fast markets, check grid more frequently but with throttling
   if(ArraySize(positions) < MaxPositions)
   {
      // Get current tick count
      datetime currentTime = TimeCurrent();
      uint currentTick = GetTickCount();
      
      // Check if enough time has passed since last check
      // This prevents excessive grid checks during volatility
      static uint lastTickCheck = 0;
      
      if(currentTick - lastTickCheck >= gridCheckIntervalMs || lastTickCheck == 0)
      {
         CheckGridOptimized();  // Use optimized version
         lastTickCheck = currentTick;
      }
   }
   
   // Update panel (less frequently in fast markets)
   static uint lastPanelUpdate = 0;
   uint currentTick = GetTickCount();
   
   if(currentTick - lastPanelUpdate >= 500 || lastPanelUpdate == 0)  // Update every 500ms
   {
      UpdatePanel();
      lastPanelUpdate = currentTick;
   }
}

//+------------------------------------------------------------------+
//| OPTIMIZED GRID LOGIC - FAST MARKET VERSION (NEW in v5.6)        |
//+------------------------------------------------------------------+
void CheckGridOptimized()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   // Pre-calculate grid level
   double distanceFromReference = currentPrice - referencePrice;
   int levelIndex = (int)MathRound(distanceFromReference / currentGapSize);
   double nearestGridLevel = referencePrice + (levelIndex * currentGapSize);
   
   // Adaptive trigger zone
   double triggerPercent = 0.05;
   
   if(currentPrice > 10000)
      triggerPercent = 0.02;
   else if(currentPrice > 1000)
      triggerPercent = 0.03;
   
   double triggerZone = currentGapSize * triggerPercent;
   double distanceToNearestLevel = MathAbs(currentPrice - nearestGridLevel);
   
   // Quick exit if not near grid level
   if(distanceToNearestLevel > triggerZone)
   {
      return;
   }
   
   // Fast position check using pre-calculated distances
   bool levelHasPosition = false;
   double minDistanceBetweenPositions = currentGapSize * 0.8;
   
   int posCount = ArraySize(positions);
   for(int i = 0; i < posCount; i++)
   {
      // Quick distance check
      double dist = MathAbs(positions[i].entryPrice - nearestGridLevel);
      
      if(dist < minDistanceBetweenPositions)
      {
         levelHasPosition = true;
         break;  // Early exit
      }
   }
   
   // Open position if level is empty
   if(!levelHasPosition && posCount < MaxPositions)
   {
      ENUM_ORDER_TYPE orderType = (CurrentDirection == BUYONLY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double openPrice = (CurrentDirection == BUYONLY) ? ask : bid;
      
      if(OpenPositionFast(orderType, openPrice, nearestGridLevel))
      {
         string dirStr = (CurrentDirection == BUYONLY) ? "BUY" : "SELL";
         Print("⚡ FAST ", dirStr, " opened at: $", DoubleToString(nearestGridLevel, specs.digits));
         
         // Update next levels immediately after opening position
         CalculateNextGridLevels();
      }
   }
}

//+------------------------------------------------------------------+
//| FAST POSITION OPENING (NEW in v5.6)                             |
//+------------------------------------------------------------------+
bool OpenPositionFast(ENUM_ORDER_TYPE orderType, double price, double levelPrice)
{
   if(ArraySize(positions) >= MaxPositions)
   {
      return false;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = validatedLotSize;
   request.type = orderType;
   request.price = price;
   request.deviation = 20;  // Increased deviation for fast markets
   request.magic = MagicNumber;
   request.comment = StringFormat("AGG_%.2f", levelPrice);
   
   // Pre-calculate TP/SL for speed
   double pointValue = specs.tickValue / specs.tickSize;
   double positionValue = pointValue * validatedLotSize;
   
   if(IndividualTPDollars > 0)
   {
      double tpDistance = IndividualTPDollars / positionValue;
      
      if(orderType == ORDER_TYPE_BUY)
         request.tp = NormalizeDouble(price + tpDistance, specs.digits);
      else
         request.tp = NormalizeDouble(price - tpDistance, specs.digits);
   }
   
   if(IndividualSLDollars > 0)
   {
      double slDistance = IndividualSLDollars / positionValue;
      
      if(orderType == ORDER_TYPE_BUY)
         request.sl = NormalizeDouble(price - slDistance, specs.digits);
      else
         request.sl = NormalizeDouble(price + slDistance, specs.digits);
   }
   
   // Send order with minimal logging for speed
   if(!OrderSend(request, result))
   {
      Print("❌ Order failed: ", result.retcode, " - ", GetTradeErrorDescription(result.retcode));
      return false;
   }
   
   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      totalTrades++;
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
   
   // Recalculate next levels if positions changed
   static int lastPosCount = -1;
   if(ArraySize(positions) != lastPosCount)
   {
      CalculateNextGridLevels();
      lastPosCount = ArraySize(positions);
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                            |
//+------------------------------------------------------------------+
double CalculateTotalProfit()
{
   double profit = 0;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         profit += PositionGetDouble(POSITION_PROFIT);
      }
   }
   
   totalProfit = profit;
   return profit;
}

//+------------------------------------------------------------------+
//| CHECK GROUP TP                                                    |
//+------------------------------------------------------------------+
void CheckGroupTP()
{
   if(GroupTPDollars <= 0) return;
   
   static datetime lastTPDebug = 0;
   if(TimeCurrent() - lastTPDebug >= 60)
   {
      lastTPDebug = TimeCurrent();
      Print("💰 GROUP TP CHECK: Current P/L: $", DoubleToString(totalProfit, 2), 
            " | Target: $", DoubleToString(GroupTPDollars, 2));
   }
   
   if(totalProfit >= GroupTPDollars)
   {
      Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      Print("🎯 GROUP TP HIT: $", DoubleToString(totalProfit, 2));
      CloseAllPositions();
      Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
   }
}

//+------------------------------------------------------------------+
//| OPEN POSITION (STANDARD VERSION)                                 |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE orderType, double price, double levelPrice)
{
   if(ArraySize(positions) >= MaxPositions)
   {
      Print("🛑 Cannot open position - MaxPositions limit reached (", MaxPositions, ")");
      return false;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = validatedLotSize;
   request.type = orderType;
   request.price = price;
   request.deviation = 20;
   request.magic = MagicNumber;
   request.comment = StringFormat("AGG_%.2f", levelPrice);
   
   Print("📊 Opening ", (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"), " position:");
   Print("   Entry: $", DoubleToString(price, specs.digits));
   Print("   Lot Size: ", DoubleToString(validatedLotSize, 3));
   
   double pointValue = specs.tickValue / specs.tickSize;
   double positionValue = pointValue * validatedLotSize;
   
   if(IndividualTPDollars > 0)
   {
      double tpDistance = IndividualTPDollars / positionValue;
      
      if(orderType == ORDER_TYPE_BUY)
         request.tp = NormalizeDouble(price + tpDistance, specs.digits);
      else
         request.tp = NormalizeDouble(price - tpDistance, specs.digits);
      
      Print("   TP: $", DoubleToString(request.tp, specs.digits), " (Distance: $", DoubleToString(tpDistance, 4), ")");
   }
   
   if(IndividualSLDollars > 0)
   {
      double slDistance = IndividualSLDollars / positionValue;
      
      if(orderType == ORDER_TYPE_BUY)
         request.sl = NormalizeDouble(price - slDistance, specs.digits);
      else
         request.sl = NormalizeDouble(price + slDistance, specs.digits);
      
      Print("   SL: $", DoubleToString(request.sl, specs.digits), " (Distance: $", DoubleToString(slDistance, 4), ")");
   }
   
   if(!OrderSend(request, result))
   {
      Print("❌ Order failed: ", result.retcode);
      Print("   Error: ", GetTradeErrorDescription(result.retcode));
      return false;
   }
   
   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      totalTrades++;
      Print("✅ Position opened successfully");
      Print("   Ticket: #", result.order);
      Print("   Price: $", DoubleToString(result.price, specs.digits));
      return true;
   }
   
   Print("⚠️ Order not executed: ", result.retcode);
   Print("   ", GetTradeErrorDescription(result.retcode));
   return false;
}

//+------------------------------------------------------------------+
//| GET TRADE ERROR DESCRIPTION                                       |
//+------------------------------------------------------------------+
string GetTradeErrorDescription(uint retcode)
{
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE: return "Requote";
      case TRADE_RETCODE_REJECT: return "Request rejected";
      case TRADE_RETCODE_CANCEL: return "Request canceled";
      case TRADE_RETCODE_PLACED: return "Order placed";
      case TRADE_RETCODE_DONE: return "Done";
      case TRADE_RETCODE_DONE_PARTIAL: return "Done partially";
      case TRADE_RETCODE_ERROR: return "Common error";
      case TRADE_RETCODE_TIMEOUT: return "Timeout";
      case TRADE_RETCODE_INVALID: return "Invalid request";
      case TRADE_RETCODE_INVALID_VOLUME: return "Invalid volume";
      case TRADE_RETCODE_INVALID_PRICE: return "Invalid price";
      case TRADE_RETCODE_INVALID_STOPS: return "Invalid stops";
      case TRADE_RETCODE_TRADE_DISABLED: return "Trade disabled";
      case TRADE_RETCODE_MARKET_CLOSED: return "Market closed";
      case TRADE_RETCODE_NO_MONEY: return "Insufficient funds";
      case TRADE_RETCODE_PRICE_CHANGED: return "Price changed";
      case TRADE_RETCODE_PRICE_OFF: return "No prices";
      case TRADE_RETCODE_INVALID_EXPIRATION: return "Invalid expiration";
      case TRADE_RETCODE_ORDER_CHANGED: return "Order changed";
      case TRADE_RETCODE_TOO_MANY_REQUESTS: return "Too many requests";
      case TRADE_RETCODE_NO_CHANGES: return "No changes";
      case TRADE_RETCODE_SERVER_DISABLES_AT: return "Autotrading disabled by server";
      case TRADE_RETCODE_CLIENT_DISABLES_AT: return "Autotrading disabled by client";
      case TRADE_RETCODE_LOCKED: return "Locked";
      case TRADE_RETCODE_FROZEN: return "Frozen";
      case TRADE_RETCODE_INVALID_FILL: return "Invalid fill";
      case TRADE_RETCODE_CONNECTION: return "No connection";
      case TRADE_RETCODE_ONLY_REAL: return "Only real account allowed";
      case TRADE_RETCODE_LIMIT_ORDERS: return "Orders limit reached";
      case TRADE_RETCODE_LIMIT_VOLUME: return "Volume limit reached";
      default: return "Unknown error: " + IntegerToString(retcode);
   }
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   Print("🔴 Closing all positions...");
   
   int closed = 0;
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      if(ClosePosition(positions[i].ticket))
         closed++;
   }
   
   Print("✅ Closed ", closed, " positions");
   SyncPositions();
}

//+------------------------------------------------------------------+
//| CLOSE SINGLE POSITION                                             |
//+------------------------------------------------------------------+
bool ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.position = ticket;
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.deviation = 10;
   request.magic = MagicNumber;
   
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   request.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   return OrderSend(request, result) && (result.retcode == TRADE_RETCODE_DONE);
}

//+------------------------------------------------------------------+
//| FORMAT PRICE                                                      |
//+------------------------------------------------------------------+
string FormatPrice(double price, int digits)
{
   return DoubleToString(price, digits);
}

//+------------------------------------------------------------------+
//| ON CHART EVENT                                                    |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Button clicks
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == panelPrefix + "PauseBtn")
      {
         isPaused = !isPaused;
         ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_STATE, false);
         Print(isPaused ? "⏸️ EA PAUSED" : "▶️ EA RESUMED");
         UpdatePanel();
      }
      else if(sparam == panelPrefix + "CloseBtn")
      {
         CloseAllPositions();
         ObjectSetInteger(0, panelPrefix + "CloseBtn", OBJPROP_STATE, false);
      }
      else if(sparam == panelPrefix + "SwitchBtn")
      {
         // Manual mode switch
         ENUM_TRADE_DIRECTION newDir = (CurrentDirection == BUYONLY) ? SELLONLY : BUYONLY;
         SwitchTradingMode(newDir, "Manual Switch");
         ObjectSetInteger(0, panelPrefix + "SwitchBtn", OBJPROP_STATE, false);
      }
   }
   
   // Keyboard shortcuts
   if(id == CHARTEVENT_KEYDOWN)
   {
      if(lparam == 'H' || lparam == 'h')
      {
         panelVisible = !panelVisible;
         ShowHidePanel();
      }
      else if(lparam == 'D' || lparam == 'd')
      {
         PrintDebugInfo();
      }
   }
}

//+------------------------------------------------------------------+
//| SHOW/HIDE PANEL                                                   |
//+------------------------------------------------------------------+
void ShowHidePanel()
{
   string objects[];
   int total = ObjectsTotal(0, 0, OBJ_LABEL);
   ArrayResize(objects, total);
   
   for(int i = 0; i < total; i++)
   {
      string name = ObjectName(0, i, 0, OBJ_LABEL);
      if(StringFind(name, panelPrefix) == 0)
      {
         ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, panelVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
      }
   }
   
   total = ObjectsTotal(0, 0, OBJ_BUTTON);
   for(int i = 0; i < total; i++)
   {
      string name = ObjectName(0, i, 0, OBJ_BUTTON);
      if(StringFind(name, panelPrefix) == 0)
      {
         ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, panelVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
      }
   }
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| PRINT DEBUG INFO                                                  |
//+------------------------------------------------------------------+
void PrintDebugInfo()
{
   Print("═══════════════════════════════════════");
   Print("🔍 DEBUG INFO - ", EA_NAME, " v", EA_VERSION);
   Print("═══════════════════════════════════════");
   Print("TIME: ", TimeToString(TimeCurrent()));
   Print("SYMBOL: ", _Symbol);
   Print("SPREAD: ", SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), " points");
   Print("═══════════════════════════════════════");
   Print("ACCOUNT:");
   Print("  Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("  Equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("  Margin: $", DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2));
   Print("  Free Margin: $", DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2));
   Print("═══════════════════════════════════════");
   Print("CURRENT MODE: ", CurrentDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   Print("POSITIONS: ", ArraySize(positions), "/", MaxPositions);
   Print("TOTAL TRADES: ", totalTrades);
   Print("MODE SWITCHES: ", modeSwitchCount);
   Print("═══════════════════════════════════════");
   Print("GRID:");
   Print("  Reference: $", DoubleToString(referencePrice, specs.digits));
   Print("  Gap Size: $", DoubleToString(currentGapSize, specs.digits));
   Print("  Next BUY: ", nextBuyLevel > 0 ? "$" + DoubleToString(nextBuyLevel, specs.digits) : "N/A");
   Print("  Next SELL: ", nextSellLevel > 0 ? "$" + DoubleToString(nextSellLevel, specs.digits) : "N/A");
   Print("═══════════════════════════════════════");
   Print("P/L:");
   Print("  Current: $", DoubleToString(totalProfit, 2));
   Print("  Daily: $", DoubleToString(dailyProfit, 2), " / $", DoubleToString(dailyTarget, 2));
   Print("  Peak Equity: $", DoubleToString(peakEquity, 2));
   Print("  Drawdown: ", DoubleToString((AccountInfoDouble(ACCOUNT_EQUITY) - peakEquity) / peakEquity * 100, 2), "%");
   Print("═══════════════════════════════════════");
   Print("STATUS:");
   Print("  Paused: ", isPaused ? "YES" : "NO");
   Print("  Emergency Stop: ", emergencyStop ? "YES - " + emergencyReason : "NO");
   Print("  Daily Target Reached: ", dailyTargetReached ? "YES" : "NO");
   Print("═══════════════════════════════════════");
   
   if(EnableATRSwitch)
   {
      Print("ATR MODE SWITCHING:");
      Print("  Day Open: $", DoubleToString(dayOpenPrice, specs.digits));
      Print("  Current ATR: $", DoubleToString(currentATR, 2));
      Print("  Threshold: $", DoubleToString(currentATR * ATRThresholdPercent / 100.0, 2));
      
      double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
      double distFromOpen = currentPrice - dayOpenPrice;
      Print("  Distance from Open: ", distFromOpen >= 0 ? "+" : "", DoubleToString(distFromOpen, 2));
      Print("  Cooldown: ", TimeCurrent() - lastModeSwitchTime < modeSwitchCooldownBars * PeriodSeconds() ? "ACTIVE" : "READY");
      Print("═══════════════════════════════════════");
   }
}

//+------------------------------------------------------------------+
//| CREATE PANEL                                                      |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 10;
   int y = 30;
   int lineHeight = 20;
   color bgColor = clrBlack;
   color headerColor = clrGold;
   color labelColor = clrWhite;
   color valueColor = clrLimeGreen;
   
   // Header
   CreateLabel(panelPrefix + "Header", x, y, "TORAMA AGGRESSIVE TRADER v" + EA_VERSION, headerColor, 10, "Arial Bold");
   y += lineHeight + 5;
   
   // Status
   CreateLabel(panelPrefix + "StatusLabel", x, y, "Status:", labelColor, 9, "Arial");
   CreateLabel(panelPrefix + "Status", x + 80, y, "ACTIVE", valueColor, 9, "Arial Bold");
   y += lineHeight;
   
   // Direction
   CreateLabel(panelPrefix + "DirLabel", x, y, "Direction:", labelColor, 9, "Arial");
   CreateLabel(panelPrefix + "Direction", x + 80, y, CurrentDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY", 
               CurrentDirection == BUYONLY ? clrDodgerBlue : clrOrangeRed, 9, "Arial Bold");
   y += lineHeight;
   
   // ATR Reversal Prices (only if ATR switching enabled)
   if(EnableATRSwitch)
   {
      CreateLabel(panelPrefix + "ReversalLabel", x, y, "ATR Switch:", labelColor, 9, "Arial");
      y += lineHeight;
      
      CreateLabel(panelPrefix + "ReversalSellLabel", x + 10, y, "→ SELL:", labelColor, 8, "Arial");
      CreateLabel(panelPrefix + "ReversalSell", x + 70, y, "$0.00", clrOrangeRed, 8, "Arial");
      y += lineHeight;
      
      CreateLabel(panelPrefix + "ReversalBuyLabel", x + 10, y, "→ BUY:", labelColor, 8, "Arial");
      CreateLabel(panelPrefix + "ReversalBuy", x + 70, y, "$0.00", clrDodgerBlue, 8, "Arial");
      y += lineHeight;
   }
   
   // NEXT LEVELS - NEW IN V5.6
   CreateLabel(panelPrefix + "NextLevelsLabel", x, y, "Next Levels:", headerColor, 9, "Arial Bold");
   y += lineHeight;
   
   CreateLabel(panelPrefix + "NextBuyLabel", x + 10, y, "Next BUY:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "NextBuy", x + 80, y, "$0.00", clrDodgerBlue, 9, "Arial Bold");
   y += lineHeight;
   
   CreateLabel(panelPrefix + "NextSellLabel", x + 10, y, "Next SELL:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "NextSell", x + 80, y, "$0.00", clrOrangeRed, 9, "Arial Bold");
   y += lineHeight + 5;
   
   // Reference Price
   CreateLabel(panelPrefix + "RefLabel", x, y, "Reference:", labelColor, 9, "Arial");
   CreateLabel(panelPrefix + "RefPrice", x + 80, y, "$0.00", valueColor, 9, "Arial");
   y += lineHeight;
   
   // Positions
   CreateLabel(panelPrefix + "PosLabel", x, y, "EA Positions:", labelColor, 9, "Arial");
   CreateLabel(panelPrefix + "Positions", x + 100, y, "0/100", valueColor, 9, "Arial");
   y += lineHeight;
   
   // Account Lot Counts
   CreateLabel(panelPrefix + "AccLabel", x, y, "Account Lots:", labelColor, 9, "Arial");
   CreateLabel(panelPrefix + "AccCounts", x + 100, y, "B:0 S:0", valueColor, 9, "Arial");
   y += lineHeight;
   
   // P/L
   CreateLabel(panelPrefix + "PnLLabel", x, y, "P/L:", labelColor, 9, "Arial");
   CreateLabel(panelPrefix + "PnL", x + 80, y, "+$0.00", valueColor, 9, "Arial Bold");
   y += lineHeight;
   
   // Equity
   CreateLabel(panelPrefix + "EquityLabel", x, y, "Equity:", labelColor, 9, "Arial");
   CreateLabel(panelPrefix + "Equity", x + 80, y, "$0.00", valueColor, 9, "Arial");
   y += lineHeight;
   
   // Drawdown
   CreateLabel(panelPrefix + "DDLabel", x, y, "Drawdown:", labelColor, 9, "Arial");
   CreateLabel(panelPrefix + "DD", x + 80, y, "0%", valueColor, 9, "Arial");
   y += lineHeight;
   
   // DD Trigger Price
   CreateLabel(panelPrefix + "DDTriggerLabel", x, y, "DD Trigger @:", labelColor, 9, "Arial");
   CreateLabel(panelPrefix + "DDTrigger", x + 100, y, "$0.00", clrOrangeRed, 9, "Arial");
   y += lineHeight;
   
   // Daily Profit
   CreateLabel(panelPrefix + "DailyLabel", x, y, "Daily:", labelColor, 9, "Arial");
   CreateLabel(panelPrefix + "DailyProfit", x + 80, y, "+$0.00", valueColor, 9, "Arial");
   y += lineHeight;
   
   // Mode Switches
   CreateLabel(panelPrefix + "SwitchLabel", x, y, "Mode Switches:", labelColor, 9, "Arial");
   CreateLabel(panelPrefix + "SwitchCount", x + 110, y, "0", valueColor, 9, "Arial");
   y += lineHeight + 10;
   
   // Control buttons
   CreateButton(panelPrefix + "PauseBtn", x, y, 80, 25, isPaused ? "RESUME" : "PAUSE", clrNavy, clrWhite);
   CreateButton(panelPrefix + "CloseBtn", x + 90, y, 80, 25, "CLOSE ALL", clrDarkRed, clrWhite);
   CreateButton(panelPrefix + "SwitchBtn", x + 180, y, 100, 25, "SWITCH MODE", clrDarkSlateGray, clrGold);
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!ShowPanel) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Status
   string statusText = "ACTIVE";
   color statusColor = clrLimeGreen;
   
   if(isPaused)
   {
      statusText = "PAUSED";
      statusColor = clrYellow;
   }
   else if(emergencyStop)
   {
      statusText = "EMERGENCY STOP";
      statusColor = clrRed;
   }
   else if(dailyTargetReached)
   {
      statusText = "TARGET REACHED";
      statusColor = clrGold;
   }
   
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread && !emergencyStop && !dailyTargetReached)
   {
      statusText = "HIGH SPREAD";
      statusColor = clrOrange;
   }
   
   ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, statusText);
   ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, statusColor);
   
   // Update button text
   ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, isPaused ? "RESUME" : "PAUSE");
   
   // Direction
   string dirText = (CurrentDirection == BUYONLY) ? "BUY ONLY" : "SELL ONLY";
   color dirColor = (CurrentDirection == BUYONLY) ? clrDodgerBlue : clrOrangeRed;
   ObjectSetString(0, panelPrefix + "Direction", OBJPROP_TEXT, dirText);
   ObjectSetInteger(0, panelPrefix + "Direction", OBJPROP_COLOR, dirColor);
   
   // ATR Reversal Prices
   if(EnableATRSwitch && currentATR > 0 && dayOpenPrice > 0)
   {
      double atrThreshold = currentATR * (ATRThresholdPercent / 100.0);
      double reversalToSell = dayOpenPrice + atrThreshold;
      double reversalToBuy = dayOpenPrice - atrThreshold;
      
      ObjectSetString(0, panelPrefix + "ReversalSell", OBJPROP_TEXT, "$" + FormatPrice(reversalToSell, specs.digits));
      ObjectSetString(0, panelPrefix + "ReversalBuy", OBJPROP_TEXT, "$" + FormatPrice(reversalToBuy, specs.digits));
      
      double currentPrice = (ask + bid) / 2.0;
      double distToSell = reversalToSell - currentPrice;
      double distToBuy = currentPrice - reversalToBuy;
      
      color sellColor = (distToSell > 0 && distToSell < atrThreshold * 0.25) ? clrYellow : clrOrangeRed;
      color buyColor = (distToBuy > 0 && distToBuy < atrThreshold * 0.25) ? clrYellow : clrDodgerBlue;
      
      ObjectSetInteger(0, panelPrefix + "ReversalSell", OBJPROP_COLOR, sellColor);
      ObjectSetInteger(0, panelPrefix + "ReversalBuy", OBJPROP_COLOR, buyColor);
   }
   
   // NEXT LEVELS - NEW IN V5.6
   if(CurrentDirection == BUYONLY)
   {
      if(nextBuyLevel > 0)
      {
         ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, "$" + FormatPrice(nextBuyLevel, specs.digits));
         ObjectSetInteger(0, panelPrefix + "NextBuy", OBJPROP_COLOR, clrDodgerBlue);
      }
      else
      {
         ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, "N/A");
         ObjectSetInteger(0, panelPrefix + "NextBuy", OBJPROP_COLOR, clrGray);
      }
      
      ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, "N/A");
      ObjectSetInteger(0, panelPrefix + "NextSell", OBJPROP_COLOR, clrGray);
   }
   else  // SELLONLY
   {
      if(nextSellLevel > 0)
      {
         ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, "$" + FormatPrice(nextSellLevel, specs.digits));
         ObjectSetInteger(0, panelPrefix + "NextSell", OBJPROP_COLOR, clrOrangeRed);
      }
      else
      {
         ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, "N/A");
         ObjectSetInteger(0, panelPrefix + "NextSell", OBJPROP_COLOR, clrGray);
      }
      
      ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, "N/A");
      ObjectSetInteger(0, panelPrefix + "NextBuy", OBJPROP_COLOR, clrGray);
   }
   
   // Reference
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, "$" + FormatPrice(referencePrice, specs.digits));
   
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
      netText = "(+" + DoubleToString(netPosition, 2) + "B)";
      netColor = clrDodgerBlue;
   }
   else
   {
      netText = "(" + DoubleToString(MathAbs(netPosition), 2) + "S)";
      netColor = clrOrangeRed;
   }
   
   string accLotsText = "B:" + DoubleToString(totalBuyLots, 2) + " S:" + DoubleToString(totalSellLots, 2) + " " + netText;
   ObjectSetString(0, panelPrefix + "AccCounts", OBJPROP_TEXT, accLotsText);
   ObjectSetInteger(0, panelPrefix + "AccCounts", OBJPROP_COLOR, netColor);
   
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
   
   // Drawdown trigger price
   double ddTriggerEquity = peakEquity * (1.0 - MaxDrawdownPercent / 100.0);
   double currentFloatingPL = CalculateTotalProfit();
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double plNeededForDDTrigger = ddTriggerEquity - currentEquity;
   
   double ddTriggerPrice = (ask + bid) / 2.0;
   
   if(ArraySize(positions) > 0 && MathAbs(currentFloatingPL) > 0.01)
   {
      double totalVolume = 0;
      
      for(int i = 0; i < ArraySize(positions); i++)
      {
         if(PositionSelectByTicket(positions[i].ticket))
         {
            totalVolume += PositionGetDouble(POSITION_VOLUME);
         }
      }
      
      if(totalVolume > 0)
      {
         double pointValue = specs.tickValue / specs.tickSize;
         double plPerPointMove = pointValue * totalVolume;
         
         if(plPerPointMove > 0)
         {
            double pointsMoveToDDTrigger = plNeededForDDTrigger / plPerPointMove;
            
            if(CurrentDirection == BUYONLY)
            {
               ddTriggerPrice = (ask + bid) / 2.0 + pointsMoveToDDTrigger;
            }
            else
            {
               ddTriggerPrice = (ask + bid) / 2.0 - pointsMoveToDDTrigger;
            }
         }
      }
   }
   
   string ddTriggerText = "$" + FormatPrice(ddTriggerPrice, specs.digits);
   color ddTriggerColor = clrOrangeRed;
   
   double currentDD = (peakEquity > 0) ? ((currentEquity - peakEquity) / peakEquity * 100) : 0;
   double ddProximity = MathAbs(currentDD / MaxDrawdownPercent * 100);
   
   if(ddProximity > 80)
      ddTriggerColor = clrRed;
   else if(ddProximity > 50)
      ddTriggerColor = clrOrange;
   else
      ddTriggerColor = clrOrangeRed;
   
   ObjectSetString(0, panelPrefix + "DDTrigger", OBJPROP_TEXT, ddTriggerText);
   ObjectSetInteger(0, panelPrefix + "DDTrigger", OBJPROP_COLOR, ddTriggerColor);
   
   // Mode switches
   ObjectSetString(0, panelPrefix + "SwitchCount", OBJPROP_TEXT, IntegerToString(modeSwitchCount));
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
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
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
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
