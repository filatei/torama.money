//+------------------------------------------------------------------+
//|                    TORAMA Aggressive Trader EA v5.3              |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "5.3"
#property description "Aggressive Directional Grid Trader with ATR-Based Mode Switching"
#property description "Trades ONLY in chosen direction as price moves"
#property description "Replaces closed positions automatically"
#property description ""
#property description "V5.3: PANEL - Compact layout, reversal prices, account-wide BUY/SELL counts"

#define EA_VERSION "5.3"
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
int atrHandle = INVALID_HANDLE;            // ATR indicator handle (FIX #1)
double dayOpenPrice = 0;                   // Day's opening price
double currentATR = 0;                     // Current ATR value
datetime lastDayOpenUpdate = 0;            // Last time we updated day open
datetime lastModeSwitchTime = 0;           // Last mode switch time (FIX #2)
int modeSwitchCooldownBars = 100;          // Cooldown: 100 bars (~1.5h on M1)

// Grid tracking
double referencePrice = 0;
double currentGapSize = 0;

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
   
   // Generate unique magic number
   MagicNumber = (int)(GetTickCount() % 2147483647);
   Print("🔢 Magic Number: ", MagicNumber);
   
   // Initialize symbol specifications
   if(!InitializeSymbolSpecs())
   {
      Print("❌ FAILED: Could not initialize symbol specifications");
      return(INIT_FAILED);
   }
   
   // Validate and normalize lot size
   validatedLotSize = ValidateLotSize(LotSize);
   
   Print("📊 CONFIGURATION:");
   Print("   Starting Direction: ", StartDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   Print("   Symbol: ", _Symbol);
   Print("   Lot Size: ", DoubleToString(validatedLotSize, 3));
   Print("   Max Positions: ", MaxPositions);
   
   // Set current direction to starting direction
   CurrentDirection = StartDirection;
   
   // Initialize ATR mode switching
   if(EnableATRSwitch)
   {
      Print("═══════════════════════════════════════");
      Print("📈 ATR MODE SWITCHING: ENABLED");
      Print("   ATR Period: ", ATRPeriod);
      Print("   ATR Threshold: ", DoubleToString(ATRThresholdPercent, 1), "% of ATR");
      Print("   Close on Switch: ", CloseOnModeSwitch ? "YES (close all positions)" : "NO (let positions run)");
      Print("   Logic: Price moves above open by 0.7×ATR → Switch to SELL");
      Print("          Price moves below open by 0.7×ATR → Switch to BUY");
      
      // FIX #1: Create ATR indicator handle
      atrHandle = iATR(_Symbol, PERIOD_D1, ATRPeriod);
      if(atrHandle == INVALID_HANDLE)
      {
         Print("❌ FAILED: Could not create ATR indicator handle");
         return(INIT_FAILED);
      }
      
      // FIX #4: Initialize day's open price immediately
      UpdateDayOpenPrice();
      
      // Wait for ATR indicator to calculate
      if(!WaitForIndicator(atrHandle))
      {
         Print("⚠️ WARNING: ATR indicator not ready, mode switching may be delayed");
      }
      else
      {
         // Get initial ATR value
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
   Print("📏 Grid Gap: $", DoubleToString(currentGapSize, specs.digits), " (", DoubleToString(GridGapPercent, 3), "%)");
   
   // Initialize peak equity
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Daily target setup
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyTarget = dailyStartBalance * DailyTargetPercent / 100.0;
   Print("🎯 Daily Target: $", DoubleToString(dailyTarget, 2), " (", DoubleToString(DailyTargetPercent, 0), "%)");
   
   // Risk analysis
   PrintRiskAnalysis();
   
   // TP/SL info
   Print("═══════════════════════════════════════");
   Print("🎯 PROFIT & LOSS TARGETS:");
   Print("   Individual TP: $", DoubleToString(IndividualTPDollars, 2));
   Print("   Group TP: $", DoubleToString(GroupTPDollars, 2));
   Print("   Individual SL: ", IndividualSLDollars > 0 ? "$" + DoubleToString(IndividualSLDollars, 2) : "DISABLED");
   
   // Calculate expected TP/SL distances using correct formula
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
//| UPDATE DAY OPEN PRICE                                            |
//+------------------------------------------------------------------+
void UpdateDayOpenPrice()
{
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   
   // Create datetime for today's open (00:00:00)
   time.hour = 0;
   time.min = 0;
   time.sec = 0;
   datetime todayOpen = StructToTime(time);
   
   // Get the open price of the current day
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
   
   // FIX #2: Check cooldown period to prevent rapid switching
   if(TimeCurrent() - lastModeSwitchTime < modeSwitchCooldownBars * PeriodSeconds())
      return;  // Still in cooldown
   
   // FIX #1: Update ATR value using indicator handle
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
         if(TimeCurrent() - lastATRWarning > 3600) // Warn once per hour
         {
            Print("⚠️ WARNING: Could not read ATR buffer for mode switching");
            lastATRWarning = TimeCurrent();
         }
         return;
      }
   }
   else
   {
      return;  // No valid ATR handle
   }
   
   if(currentATR <= 0) return;
   
   if(dayOpenPrice <= 0) return;
   
   // Get current price
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   // Calculate distance from day's open
   double distanceFromOpen = currentPrice - dayOpenPrice;
   double atrThreshold = currentATR * (ATRThresholdPercent / 100.0);
   
   // Check for mode switch conditions
   bool shouldSwitch = false;
   ENUM_TRADE_DIRECTION newDirection = CurrentDirection;
   
   // Price moved ABOVE open by 70% ATR → Switch to SELL (if not already SELL)
   if(distanceFromOpen >= atrThreshold && CurrentDirection == BUYONLY)
   {
      newDirection = SELLONLY;
      shouldSwitch = true;
   }
   // Price moved BELOW open by 70% ATR → Switch to BUY (if not already BUY)
   else if(distanceFromOpen <= -atrThreshold && CurrentDirection == SELLONLY)
   {
      newDirection = BUYONLY;
      shouldSwitch = true;
   }
   
   // Execute mode switch
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
   
   // FIX #2: Set cooldown timestamp
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
   
   // Handle existing positions based on CloseOnModeSwitch setting
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
         
         // Log existing positions for tracking
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
   
   // Reset reference price to current price (for new positions only)
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   referencePrice = (ask + bid) / 2.0;
   
   // FIX #3: Update grid gap size for new reference price
   currentGapSize = referencePrice * GridGapPercent / 100.0;
   
   Print("   New Reference Price: $", DoubleToString(referencePrice, specs.digits));
   Print("   New Grid Gap: $", DoubleToString(currentGapSize, specs.digits));
   Print("   Cooldown: ", modeSwitchCooldownBars, " bars");
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
   
   // Validate critical values
   if(specs.contractSize <= 0 || specs.point <= 0 || specs.minLot <= 0)
   {
      Print("❌ ERROR: Invalid symbol specifications");
      Print("   Contract Size: ", specs.contractSize);
      Print("   Point: ", specs.point);
      Print("   Min Lot: ", specs.minLot);
      return false;
   }
   
   // Calculate minimum stop distance
   specs.minStopDistance = specs.stopLevel * specs.point;
   
   // If broker returns 0, use reasonable minimum based on spread
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
   
   int lotDigits = 2;
   if(specs.lotStep >= 0.1) lotDigits = 1;
   else if(specs.lotStep >= 1.0) lotDigits = 0;
   
   normalizedLots = NormalizeDouble(normalizedLots, lotDigits);
   
   if(normalizedLots != requestedLots)
   {
      Print("ℹ️ INFO: Lot size adjusted from ", requestedLots, " to ", normalizedLots);
   }
   
   return normalizedLots;
}

//+------------------------------------------------------------------+
//| VALIDATE GRID GAP                                                 |
//+------------------------------------------------------------------+
bool ValidateGridGap()
{
   bool isValid = true;
   
   // Check if gap is too small
   double minGap = specs.tickSize * 50;
   if(currentGapSize < minGap)
   {
      Print("⚠️ WARNING: Grid gap $", DoubleToString(currentGapSize, specs.digits), " is too small!");
      Print("   Minimum recommended: $", DoubleToString(minGap, specs.digits), " (50 ticks)");
      isValid = false;
   }
   
   // Check if gap is too large
   double recommendedMaxGap = referencePrice * 0.5 / 100.0;
   if(currentGapSize > recommendedMaxGap)
   {
      Print("⚠️ WARNING: Grid gap $", DoubleToString(currentGapSize, 2), " might be too large!");
      Print("   Recommended maximum: 0.5% = $", DoubleToString(recommendedMaxGap, 2));
      isValid = false;
   }
   
   // Symbol-specific recommendations
   if(StringFind(_Symbol, "BTC") >= 0 || StringFind(_Symbol, "ETH") >= 0)
   {
      Print("📊 CRYPTOCURRENCY: Recommended gap 0.01-0.05%");
   }
   else if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
   {
      Print("📊 PRECIOUS METAL: Recommended gap 0.01-0.02%");
   }
   else if(StringFind(_Symbol, "USD") >= 0 || StringFind(_Symbol, "EUR") >= 0)
   {
      Print("📊 FOREX: Recommended gap 0.05-0.1%");
   }
   
   return isValid;
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
      
      // Calculate positions before emergency stop
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
   // Release ATR indicator handle
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
      
      // Update day's open price for ATR calculations
      if(EnableATRSwitch)
      {
         UpdateDayOpenPrice();
      }
   }
   
   // FIX #5: Check spread FIRST before expensive calculations
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      UpdatePanel();
      return;
   }
   
   // Check ATR mode switching (after spread check)
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
   
   // Grid logic - only if under MaxPositions limit
   if(ArraySize(positions) < MaxPositions)
   {
      CheckGrid();
   }
   
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
   
   // Find nearest grid level
   double distanceFromReference = currentPrice - referencePrice;
   int levelIndex = (int)MathRound(distanceFromReference / currentGapSize);
   double nearestGridLevel = referencePrice + (levelIndex * currentGapSize);
   
   // Calculate distance to nearest level
   double distanceToNearestLevel = MathAbs(currentPrice - nearestGridLevel);
   
   // Adaptive trigger zone based on symbol price
   double triggerPercent = 0.05;  // Default 5%
   
   if(currentPrice > 10000)
      triggerPercent = 0.02;  // 2% for high-value symbols
   else if(currentPrice > 1000)
      triggerPercent = 0.03;  // 3% for medium-value
   
   double triggerZone = currentGapSize * triggerPercent;
   
   // Only trigger if close to grid level
   if(distanceToNearestLevel > triggerZone)
      return;
   
   // Check if position exists near this level
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
   
   // Open position if level is empty (use CurrentDirection, not StartDirection)
   if(!levelHasPosition && ArraySize(positions) < MaxPositions)
   {
      ENUM_ORDER_TYPE orderType = (CurrentDirection == BUYONLY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double openPrice = (CurrentDirection == BUYONLY) ? ask : bid;
      
      if(OpenPosition(orderType, openPrice, nearestGridLevel))
      {
         string dirStr = (CurrentDirection == BUYONLY) ? "BUY" : "SELL";
         Print("⚡ ", dirStr, " opened at grid level: $", DoubleToString(nearestGridLevel, specs.digits));
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
//| CHECK GROUP TP                                                    |
//+------------------------------------------------------------------+
void CheckGroupTP()
{
   if(GroupTPDollars <= 0) return;
   
   // Debug output every 60 seconds
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
//| OPEN POSITION WITH FIXED TP/SL CALCULATION                       |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE orderType, double price, double levelPrice)
{
   // Verify MaxPositions limit
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
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = StringFormat("AGG_%.2f", levelPrice);
   
   Print("📊 Opening ", (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"), " position:");
   Print("   Entry: $", DoubleToString(price, specs.digits));
   Print("   Lot Size: ", DoubleToString(validatedLotSize, 3));
   Print("   Tick Value: $", DoubleToString(specs.tickValue, 4));
   Print("   Tick Size: $", DoubleToString(specs.tickSize, 5));
   
   // Calculate point value (value per 1.0 price unit)
   double pointValue = specs.tickValue / specs.tickSize;
   double positionValue = pointValue * validatedLotSize;
   
   Print("   Point Value: $", DoubleToString(pointValue, 4), " per 1.0 price unit");
   Print("   Position Value: $", DoubleToString(positionValue, 4), " per 1.0 price move");
   
   // Set TP based on dollar target
   if(IndividualTPDollars > 0)
   {
      // CORRECT FORMULA (from percentage-based EA):
      // Distance = Target$ / (PointValue × LotSize)
      double tpDistance = IndividualTPDollars / positionValue;
      
      Print("   TP Target: $", DoubleToString(IndividualTPDollars, 2));
      Print("   TP Distance: $", DoubleToString(tpDistance, 4), " (", DoubleToString((tpDistance/price)*100, 3), "%)");
      
      // Ensure meets minimum stop distance
      if(tpDistance < specs.minStopDistance)
      {
         Print("   ⚠️ TP distance too small, adjusting to minimum");
         tpDistance = specs.minStopDistance * 1.5;
      }
      
      // Sanity check: TP should not exceed 10% of entry price
      double maxTPDistance = price * 0.10;
      if(tpDistance > maxTPDistance)
      {
         Print("   ⚠️ WARNING: TP distance exceeds 10% of price!");
         Print("   This suggests IndividualTPDollars ($", DoubleToString(IndividualTPDollars, 2), 
               ") is too high for lot size ", DoubleToString(validatedLotSize, 3));
         tpDistance = maxTPDistance;
      }
      
      // Calculate TP level based on order type
      if(orderType == ORDER_TYPE_BUY)
      {
         request.tp = NormalizeDouble(price + tpDistance, specs.digits);
         Print("   TP Level: $", DoubleToString(request.tp, specs.digits), " (+", DoubleToString(tpDistance, 4), ")");
      }
      else
      {
         request.tp = NormalizeDouble(price - tpDistance, specs.digits);
         Print("   TP Level: $", DoubleToString(request.tp, specs.digits), " (-", DoubleToString(tpDistance, 4), ")");
      }
      
      // Verify expected profit
      double expectedProfit = tpDistance * positionValue;
      Print("   Verified TP Profit: $", DoubleToString(expectedProfit, 2));
   }
   
   // Set SL based on dollar risk
   if(IndividualSLDollars > 0)
   {
      // CORRECT FORMULA (from percentage-based EA):
      // Distance = Risk$ / (PointValue × LotSize)
      double slDistance = IndividualSLDollars / positionValue;
      
      Print("   SL Risk Target: $", DoubleToString(IndividualSLDollars, 2));
      Print("   SL Distance: $", DoubleToString(slDistance, 4), " (", DoubleToString((slDistance/price)*100, 3), "%)");
      
      // Ensure meets minimum stop distance
      if(slDistance < specs.minStopDistance)
      {
         Print("   ⚠️ SL distance too small, adjusting to minimum");
         slDistance = specs.minStopDistance * 1.5;
      }
      
      // Sanity check: SL should not exceed 20% of entry price
      double maxSLDistance = price * 0.20;
      if(slDistance > maxSLDistance)
      {
         Print("   ❌ ERROR: SL distance exceeds 20% of price!");
         Print("   Requested SL: $", DoubleToString(IndividualSLDollars, 2), " risk");
         Print("   Calculated distance: $", DoubleToString(slDistance, 4), " (", DoubleToString((slDistance/price)*100, 1), "%)");
         Print("   This suggests IndividualSLDollars is too high for lot size ", DoubleToString(validatedLotSize, 3));
         Print("   Trade NOT opened - adjust settings!");
         return false;
      }
      
      // Calculate SL level based on order type
      if(orderType == ORDER_TYPE_BUY)
      {
         request.sl = NormalizeDouble(price - slDistance, specs.digits);
         Print("   SL Level: $", DoubleToString(request.sl, specs.digits), " (-", DoubleToString(slDistance, 4), ")");
      }
      else
      {
         request.sl = NormalizeDouble(price + slDistance, specs.digits);
         Print("   SL Level: $", DoubleToString(request.sl, specs.digits), " (+", DoubleToString(slDistance, 4), ")");
      }
      
      // Verify expected loss
      double expectedLoss = slDistance * positionValue;
      Print("   Verified SL Risk: $", DoubleToString(expectedLoss, 2));
      
      // Final safety check
      if(slDistance > price * 0.5)
      {
         Print("❌ CRITICAL ERROR: SL is more than 50% away from entry!");
         return false;
      }
   }
   
   // Send order
   if(!OrderSend(request, result))
   {
      Print("❌ Order failed: ", result.retcode, " - ", result.comment);
      return false;
   }
   
   if(result.retcode == TRADE_RETCODE_DONE)
   {
      totalTrades++;
      Print("✅ Position opened: Ticket #", result.order);
      return true;
   }
   
   Print("❌ Order not completed: ", result.retcode);
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
            if(ClosePosition(ticket))
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
                  if(ClosePosition(ticket))
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
      return false;
   }
   
   if(result.retcode != TRADE_RETCODE_DONE)
   {
      Print("⚠️ Close position #", ticket, " returned: ", result.retcode);
      return false;
   }
   
   return true;
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
   Print("║ MODE & ATR STATUS                                            ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Current Mode:          ", CurrentDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   Print("Mode Switches:         ", modeSwitchCount);
   Print("ATR Switching:         ", EnableATRSwitch ? "ENABLED" : "DISABLED");
   
   if(EnableATRSwitch)
   {
      Print("Day Open:              $", DoubleToString(dayOpenPrice, specs.digits));
      Print("Current Price:         $", DoubleToString(currentPrice, specs.digits));
      double distFromOpen = currentPrice - dayOpenPrice;
      Print("Distance from Open:    ", distFromOpen >= 0 ? "+" : "", DoubleToString(distFromOpen, 2));
      Print("ATR (D1, ", ATRPeriod, "):        $", DoubleToString(currentATR, 2));
      Print("Switch Threshold:      ±$", DoubleToString(currentATR * ATRThresholdPercent / 100.0, 2), " (", DoubleToString(ATRThresholdPercent, 0), "% ATR)");
   }
   
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ GRID STATUS                                                  ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Reference Price:       $", DoubleToString(referencePrice, specs.digits));
   Print("Grid Gap:              $", DoubleToString(currentGapSize, 2), " (", DoubleToString(GridGapPercent, 2), "%)");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ POSITIONS                                                    ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Active Positions:      ", ArraySize(positions), "/", MaxPositions);
   
   // Count BUY and SELL positions separately
   int buyCount = 0;
   int sellCount = 0;
   double buyProfit = 0;
   double sellProfit = 0;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double profit = PositionGetDouble(POSITION_PROFIT);
         
         if(type == POSITION_TYPE_BUY)
         {
            buyCount++;
            buyProfit += profit;
         }
         else
         {
            sellCount++;
            sellProfit += profit;
         }
      }
   }
   
   if(buyCount > 0 || sellCount > 0)
   {
      Print("  └─ BUY Positions:    ", buyCount, " (P/L: $", DoubleToString(buyProfit, 2), ")");
      Print("  └─ SELL Positions:   ", sellCount, " (P/L: $", DoubleToString(sellProfit, 2), ")");
      
      if(buyCount > 0 && sellCount > 0)
      {
         Print("  └─ Status:           MIXED MODE (old positions running)");
      }
   }
   
   Print("Total Trades:          ", totalTrades);
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ PROFIT & RISK                                                ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Floating P/L:          $", DoubleToString(totalProfit, 2));
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
      // H key - toggle panel
      if(lparam == 72 || lparam == 104)
      {
         panelVisible = !panelVisible;
         TogglePanelVisibility();
         Print(panelVisible ? "👁️ Panel shown" : "👁️ Panel hidden");
      }
      // D key - debug status
      else if(lparam == 68 || lparam == 100)
      {
         PrintDebugStatus();
      }
   }
   
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      // CLOSE button
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
         Print(isPaused ? "⏸️ EA PAUSED" : "▶️ EA RESUMED");
      }
      // TAKE TP button
      else if(sparam == panelPrefix + "TPBtn")
      {
         ObjectSetInteger(0, panelPrefix + "TPBtn", OBJPROP_STATE, false);
         Print("💰 TAKE TP button pressed - Closing profitable positions...");
         CloseProfitablePositions();
         Print("✅ Profitable positions closed");
      }
      // SWITCH MODE button (NEW)
      else if(sparam == panelPrefix + "SwitchBtn")
      {
         ObjectSetInteger(0, panelPrefix + "SwitchBtn", OBJPROP_STATE, false);
         ENUM_TRADE_DIRECTION newDirection = (CurrentDirection == BUYONLY) ? SELLONLY : BUYONLY;
         SwitchTradingMode(newDirection, "Manual Override");
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
      "CloseBtn", "PauseBtn", "TPBtn", "SwitchBtn",
      "DirectionLabel", "Direction",
      "PriceLabel", "Price",
      "GridLabel", "GridSpacing",
      "SpreadLabel", "Spread",
      "ATRLabel", "ATRValue",
      "DayOpenLabel", "DayOpenValue",
      "ReversalLabel", "ReversalSell", "ReversalLabel2", "ReversalBuy",
      "RefLabel", "RefPrice",
      "PosLabel", "Positions",
      "AccLabel", "AccCounts",
      "PnLLabel", "PnL",
      "EquityLabel", "Equity",
      "DDLabel", "DD",
      "DailyLabel", "DailyProfit",
      "SwitchCountLabel", "SwitchCount",
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
   int width = 300;
   int lineHeight = 20;  // Increased from 18 for larger fonts
   
   // Background - adjusted height for larger fonts
   ObjectCreate(0, panelPrefix + "Background", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YSIZE, 330);  // Increased from 310
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BGCOLOR, C'20,20,25');
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_HIDDEN, true);
   
   int yPos = y + 10;
   
   // Title + Status on same line (larger fonts)
   CreateLabel(panelPrefix + "Title", x + 10, yPos, "AGGRESSIVE TRADER", clrGold, 10, "Arial Black");
   CreateLabel(panelPrefix + "Status", x + width - 75, yPos, "✅ ACTIVE", clrLimeGreen, 9, "Arial Bold");
   yPos += 24;
   
   // Buttons - Single row
   CreateButton(panelPrefix + "CloseBtn", x + 10, yPos, 60, 24, "CLOSE", clrRed, clrWhite);
   CreateButton(panelPrefix + "PauseBtn", x + 75, yPos, 60, 24, "PAUSE", clrOrange, clrWhite);
   CreateButton(panelPrefix + "TPBtn", x + 140, yPos, 50, 24, "TP", clrGreen, clrWhite);
   CreateButton(panelPrefix + "SwitchBtn", x + 195, yPos, 50, 24, "MODE", clrDodgerBlue, clrWhite);
   yPos += 30;
   
   // Mode + Price on same line (larger fonts)
   color dirColor = (CurrentDirection == BUYONLY) ? clrDodgerBlue : clrOrangeRed;
   CreateLabel(panelPrefix + "DirectionLabel", x + 10, yPos, "Mode:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Direction", x + 60, yPos, CurrentDirection == BUYONLY ? "BUY" : "SELL", dirColor, 10, "Arial Black");
   CreateLabel(panelPrefix + "PriceLabel", x + 140, yPos, "Price:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Price", x + 190, yPos, "$0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // Grid + Spread on same line (larger fonts)
   CreateLabel(panelPrefix + "GridLabel", x + 10, yPos, "Grid:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "GridSpacing", x + 60, yPos, "0%", clrWhite, 9, "Arial Bold");
   CreateLabel(panelPrefix + "SpreadLabel", x + 140, yPos, "Spread:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Spread", x + 200, yPos, "0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // ATR reversal prices (if enabled) - larger fonts
   if(EnableATRSwitch)
   {
      // ATR + Day Open on same line
      CreateLabel(panelPrefix + "ATRLabel", x + 10, yPos, "ATR:", clrGold, 9, "Arial Bold");
      CreateLabel(panelPrefix + "ATRValue", x + 60, yPos, "$0", clrAqua, 9, "Arial Bold");
      CreateLabel(panelPrefix + "DayOpenLabel", x + 140, yPos, "Open:", clrGold, 9, "Arial Bold");
      CreateLabel(panelPrefix + "DayOpenValue", x + 190, yPos, "$0", clrAqua, 9, "Arial Bold");
      yPos += lineHeight;
      
      // REVERSAL PRICES - larger and bolder
      CreateLabel(panelPrefix + "ReversalLabel", x + 10, yPos, "↑SELL @:", clrOrangeRed, 9, "Arial Black");
      CreateLabel(panelPrefix + "ReversalSell", x + 75, yPos, "$0", clrOrangeRed, 9, "Arial Bold");
      CreateLabel(panelPrefix + "ReversalLabel2", x + 140, yPos, "↓BUY @:", clrDodgerBlue, 9, "Arial Black");
      CreateLabel(panelPrefix + "ReversalBuy", x + 200, yPos, "$0", clrDodgerBlue, 9, "Arial Bold");
      yPos += lineHeight;
   }
   
   // Reference - larger font
   CreateLabel(panelPrefix + "RefLabel", x + 10, yPos, "Reference:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "RefPrice", x + 90, yPos, "$0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight + 3;
   
   // EA Positions + Account-wide counts on same line - larger fonts
   CreateLabel(panelPrefix + "PosLabel", x + 10, yPos, "⚡EA:", clrGold, 9, "Arial Black");
   CreateLabel(panelPrefix + "Positions", x + 55, yPos, "0/0", clrWhite, 9, "Arial Black");
   CreateLabel(panelPrefix + "AccLabel", x + 140, yPos, "Acc:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "AccCounts", x + 180, yPos, "B:0 S:0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight + 3;
   
   // P/L + Equity on same line - larger fonts
   CreateLabel(panelPrefix + "PnLLabel", x + 10, yPos, "P/L:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "PnL", x + 55, yPos, "$0", clrWhite, 10, "Arial Black");
   CreateLabel(panelPrefix + "EquityLabel", x + 140, yPos, "Equity:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Equity", x + 195, yPos, "$0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // Drawdown + Daily on same line - larger fonts
   CreateLabel(panelPrefix + "DDLabel", x + 10, yPos, "DD:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DD", x + 55, yPos, "0%", clrWhite, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DailyLabel", x + 140, yPos, "Daily:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DailyProfit", x + 195, yPos, "$0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // Mode switches - larger font
   CreateLabel(panelPrefix + "SwitchCountLabel", x + 10, yPos, "Switches:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "SwitchCount", x + 90, yPos, "0", clrCyan, 9, "Arial Bold");
   yPos += lineHeight + 10;
   
   // TORAMA CAPITAL BRANDING - LARGER, BOLDER, RIGHT-ALIGNED at bottom right corner
   int brandX = x + width - 10;  // 10px margin from right edge
   ObjectCreate(0, panelPrefix + "Brand", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_XDISTANCE, brandX);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_YDISTANCE, yPos);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_FONTSIZE, 11);  // Increased from 9
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_FONT, "Arial Black");
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_TEXT, "TORAMA CAPITAL");
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);  // Right-aligned
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| FORMAT PRICE                                                      |
//+------------------------------------------------------------------+
string FormatPrice(double price, int digits)
{
   string priceStr = DoubleToString(price, digits);
   
   // Remove trailing zeros
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
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "⏸️ PAUSED");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrOrange);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "✅ ACTIVE");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrLimeGreen);
   }
   
   // Pause button
   ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, isPaused ? "RESUME" : "PAUSE");
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, isPaused ? clrGreen : clrOrange);
   
   // Direction - with position mix indicator
   color dirColor = (CurrentDirection == BUYONLY) ? clrDodgerBlue : clrOrangeRed;
   string directionText = CurrentDirection == BUYONLY ? "BUY" : "SELL";
   
   // Check if we have positions from opposite direction
   if(!CloseOnModeSwitch && ArraySize(positions) > 0)
   {
      bool hasBuyPositions = false;
      bool hasSellPositions = false;
      
      for(int i = 0; i < ArraySize(positions); i++)
      {
         if(PositionSelectByTicket(positions[i].ticket))
         {
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY)
               hasBuyPositions = true;
            else
               hasSellPositions = true;
         }
      }
      
      // If we have mixed positions, show it
      if(hasBuyPositions && hasSellPositions)
      {
         directionText = "MIXED";
         dirColor = clrYellow;
      }
   }
   
   ObjectSetString(0, panelPrefix + "Direction", OBJPROP_TEXT, directionText);
   ObjectSetInteger(0, panelPrefix + "Direction", OBJPROP_COLOR, dirColor);
   
   // Price
   ObjectSetString(0, panelPrefix + "Price", OBJPROP_TEXT, "$" + FormatPrice(currentPrice, specs.digits));
   
   // Grid
   ObjectSetString(0, panelPrefix + "GridSpacing", OBJPROP_TEXT,
                   FormatPrice(GridGapPercent, 2) + "% ($" + FormatPrice(currentGapSize, 2) + ")");
   
   // Spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   color spreadColor = (spread > MaxSpread) ? clrRed : (spread > MaxSpread * 0.7) ? clrOrange : clrLimeGreen;
   ObjectSetString(0, panelPrefix + "Spread", OBJPROP_TEXT, IntegerToString(spread) + "/" + IntegerToString(MaxSpread));
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_COLOR, spreadColor);
   
   // ATR info and reversal prices
   if(EnableATRSwitch)
   {
      ObjectSetString(0, panelPrefix + "ATRValue", OBJPROP_TEXT, "$" + FormatPrice(currentATR, 2));
      ObjectSetString(0, panelPrefix + "DayOpenValue", OBJPROP_TEXT, "$" + FormatPrice(dayOpenPrice, specs.digits));
      
      // Calculate reversal prices
      double atrThreshold = currentATR * (ATRThresholdPercent / 100.0);
      double reversalToSell = dayOpenPrice + atrThreshold;  // Price moves above this → SELL
      double reversalToBuy = dayOpenPrice - atrThreshold;   // Price moves below this → BUY
      
      ObjectSetString(0, panelPrefix + "ReversalSell", OBJPROP_TEXT, "$" + FormatPrice(reversalToSell, specs.digits));
      ObjectSetString(0, panelPrefix + "ReversalBuy", OBJPROP_TEXT, "$" + FormatPrice(reversalToBuy, specs.digits));
      
      // Color code based on proximity to reversal
      double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
      double distToSell = reversalToSell - currentPrice;
      double distToBuy = currentPrice - reversalToBuy;
      
      // Highlight reversal price if close (within 25% of threshold)
      color sellColor = (distToSell > 0 && distToSell < atrThreshold * 0.25) ? clrYellow : clrOrangeRed;
      color buyColor = (distToBuy > 0 && distToBuy < atrThreshold * 0.25) ? clrYellow : clrDodgerBlue;
      
      ObjectSetInteger(0, panelPrefix + "ReversalSell", OBJPROP_COLOR, sellColor);
      ObjectSetInteger(0, panelPrefix + "ReversalBuy", OBJPROP_COLOR, buyColor);
   }
   
   // Reference
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, "$" + FormatPrice(referencePrice, specs.digits));
   
   // EA Positions
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT,
                   IntegerToString(ArraySize(positions)) + "/" + IntegerToString(MaxPositions));
   
   // Account-wide BUY/SELL counts (all positions regardless of magic number)
   int totalBuyCount = 0;
   int totalSellCount = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)  // Only this symbol
         {
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY)
               totalBuyCount++;
            else
               totalSellCount++;
         }
      }
   }
   
   string accCountsText = "B:" + IntegerToString(totalBuyCount) + " S:" + IntegerToString(totalSellCount);
   ObjectSetString(0, panelPrefix + "AccCounts", OBJPROP_TEXT, accCountsText);
   
   // Color code: highlight if imbalanced
   color accColor = clrWhite;
   if(totalBuyCount > totalSellCount * 2)
      accColor = clrDodgerBlue;  // Heavy BUY
   else if(totalSellCount > totalBuyCount * 2)
      accColor = clrOrangeRed;   // Heavy SELL
   
   ObjectSetInteger(0, panelPrefix + "AccCounts", OBJPROP_COLOR, accColor);
   
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
