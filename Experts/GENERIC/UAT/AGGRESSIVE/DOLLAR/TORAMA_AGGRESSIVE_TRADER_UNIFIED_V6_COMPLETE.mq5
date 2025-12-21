//+------------------------------------------------------------------+
//|                    TORAMA Aggressive Trader UNIFIED v6.0         |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "6.00"
#property description "Unified BUY/SELL Grid - Dynamic Lot Scaling - READY TO USE"
#property description "Trades both BUY and SELL on single chart"
#property description "Automatically scales winning side when opposite saturates"
#property description "Entry delays prevent overtrading - Complete and functional"

#define EA_VERSION "6.00"
#define EA_NAME "TORAMA AGGRESSIVE UNIFIED"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "=== GRID SETTINGS ==="
input double   GridGapPercent = 0.01;                 // Grid gap % (0.01 = tight, 0.3 = wide)
input int      MaxPositionsPerSide = 15;              // Maximum positions per side (BUY/SELL)
input double   BaseLotSize = 0.2;                     // Base lot size per position

input group "=== DYNAMIC LOT SCALING ==="
input bool     EnableLotScaling = true;               // Enable dynamic lot scaling
input double   ScaleMultiplier_70 = 1.5;              // Multiplier when opposite at 70% max
input double   ScaleMultiplier_85 = 2.0;              // Multiplier when opposite at 85% max
input double   ScaleMultiplier_95 = 3.0;              // Multiplier when opposite at 95% max
input double   MaxLotMultiplier = 5.0;                // Maximum lot multiplier (safety cap)
input int      WinningSideMaxPositions = 3;           // Max winning positions before scaling stops

input group "=== ENTRY DELAY ==="
input bool     EnableEntryDelay = true;               // Enable entry delays for winning side
input int      BaseDelaySeconds = 300;                // Base delay when opposite at 70% (5 min)
input int      MaxDelaySeconds = 900;                 // Max delay when opposite at 95% (15 min)

input group "=== TAKE PROFIT ==="
input double   IndividualTPDollars = 50.0;            // Individual TP target ($50 per position)
input double   GroupTPDollars = 200.0;                // Group TP target ($200 total profit closes all)

input group "=== STOP LOSS ==="
input double   IndividualSLDollars = 0.0;             // SL risk per trade (0 = disabled)

input group "=== RISK MANAGEMENT ==="
input double   MaxDrawdownPercent = 25.0;             // Max drawdown % (emergency stop)
input double   MaxNetExposureLots = 5.0;              // Max net exposure (BUY lots - SELL lots)
input double   DailyTargetPercent = 200.0;            // Daily profit target (% of start balance)

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
   double   lotSize;
   datetime entryTime;
};

struct PositionSide
{
   Position positions[];
   double   totalLots;
   double   totalProfit;
   double   currentLotSize;
   datetime lastEntryTime;
   int      consecutiveWins;
};

PositionSide BuySide;
PositionSide SellSide;

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
//| GENERATE PERSISTENT CHART-BASED MAGIC NUMBER                     |
//+------------------------------------------------------------------+
int GenerateChartBasedMagicNumber()
{
   // Use chart ID as the unique identifier
   // Chart ID remains constant even when EA parameters change
   long chartId = ChartID();
   
   // Generate hash from symbol name for additional uniqueness
   string symbolStr = _Symbol;
   int symbolHash = 0;
   
   for(int i = 0; i < StringLen(symbolStr); i++)
   {
      symbolHash = (symbolHash * 31 + StringGetCharacter(symbolStr, i)) % 1000000;
   }
   
   // Combine chart ID and symbol hash to create unique magic number
   // Chart ID is typically a large number, so we take modulo and combine with symbol hash
   int magic = (int)((chartId % 1000000) * 1000 + symbolHash) % 2147483647;
   
   // Ensure magic number is not zero
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
   
   // Log account information
   Print("💰 ACCOUNT INFO:");
   Print("   Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("   Equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("   Leverage: 1:", IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE)));
   Print("   Currency: ", AccountInfoString(ACCOUNT_CURRENCY));
   
   // Generate persistent chart-based magic number
   MagicNumber = GenerateChartBasedMagicNumber();
   Print("🔢 Magic Number (Chart ID: ", ChartID(), "): ", MagicNumber);
   
   // Initialize symbol specifications
   if(!InitializeSymbolSpecs())
   {
      Print("❌ FAILED: Could not initialize symbol specifications");
      return(INIT_FAILED);
   }
   
   // Validate and normalize lot size
   validatedLotSize = ValidateLotSize(BaseLotSize);
   
   Print("📊 CONFIGURATION:");

   Print("   Symbol: ", _Symbol);
   Print("   Base Lot Size: ", DoubleToString(validatedLotSize, 3));
   Print("   Max Positions per Side: ", MaxPositionsPerSide);
   
   // V6: Unified system - both BUY and SELL active from start
   
   // V6: No ATR mode switching - unified BUY/SELL system
   Print("═══════════════════════════════════════");
   Print("📈 UNIFIED SYSTEM: BUY + SELL ACTIVE");
   Print("   Both sides trade simultaneously");
   Print("   Dynamic lot scaling enabled:", EnableLotScaling ? "YES" : "NO");
   Print("   Entry delays enabled:", EnableEntryDelay ? "YES" : "NO");
   
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
   Print("⚡ UNIFIED STRATEGY:");
   Print("   Opens BUY and SELL positions on same chart");
   Print("   Scales lot size when one side saturates");
   Print("   Entry delays prevent overtrading winning side");
   Print("   Net exposure limits protect from imbalance");
   Print("═══════════════════════════════════════");
   Print("🔍 DEBUG: Press 'D' key for status");
   Print("👁️ PANEL: Press 'H' key to hide/show");
   Print("═══════════════════════════════════════");
   
   
   Print("✅ EA Initialized - Ready to trade at current grid level");
   
   // Create panel
   if(ShowPanel) CreatePanel();
   
   // Sync existing positions
   SyncPositions();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| UPDATE DAY OPEN PRICE                                            |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| CHECK ATR MODE SWITCHING                                         |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| SWITCH TRADING MODE                                              |
//+------------------------------------------------------------------+

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
   double totalRisk = riskPerTrade * (MaxPositionsPerSide * 2);  // Both sides
   double totalRiskPercent = (totalRisk / balance) * 100.0;
   
   Print("═══════════════════════════════════════");
   Print("💰 RISK ANALYSIS:");
   Print("   Account Balance: $", DoubleToString(balance, 2));
   
   if(IndividualSLDollars > 0)
   {
      Print("   SL Risk Per Trade: $", DoubleToString(riskPerTrade, 2), " (", DoubleToString((riskPerTrade/balance)*100, 2), "%)");
      Print("   Max Positions per Side: ", MaxPositionsPerSide);
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

//+------------------------------------------------------------------+
//| CALCULATE DYNAMIC LOT SIZE                                        |
//+------------------------------------------------------------------+
double CalculateDynamicLot(string side)
{
   bool isBuySide = (side == "BUY");
   
   int winningCount = isBuySide ? ArraySize(BuySide.positions) : ArraySize(SellSide.positions);
   int losingCount = isBuySide ? ArraySize(SellSide.positions) : ArraySize(BuySide.positions);
   
   double baseLot = BaseLotSize;
   double multiplier = 1.0;
   
   if (!EnableLotScaling || winningCount > WinningSideMaxPositions)
   {
      return ValidateLotSize(baseLot);
   }
   
   double saturationPercent = (double)losingCount / MaxPositionsPerSide * 100.0;
   
   if (saturationPercent >= 95.0)
      multiplier = ScaleMultiplier_95;
   else if (saturationPercent >= 85.0)
      multiplier = ScaleMultiplier_85;
   else if (saturationPercent >= 70.0)
      multiplier = ScaleMultiplier_70;
   
   multiplier = MathMin(multiplier, MaxLotMultiplier);
   
   double scaledLot = baseLot * multiplier;
   
   // Equity-based safety
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxLotByEquity = equity / 10000.0;
   scaledLot = MathMin(scaledLot, maxLotByEquity);
   
   return ValidateLotSize(scaledLot);
}

//+------------------------------------------------------------------+
//| CHECK IF ENTRY SHOULD BE DELAYED                                  |
//+------------------------------------------------------------------+
bool ShouldDelayEntry(string side, datetime currentTime)
{
   if (!EnableEntryDelay)
      return false;
   
   bool isBuySide = (side == "BUY");
   
   datetime lastEntry = isBuySide ? BuySide.lastEntryTime : SellSide.lastEntryTime;
   int losingCount = isBuySide ? ArraySize(SellSide.positions) : ArraySize(BuySide.positions);
   
   if (lastEntry == 0)
      return false;
   
   double saturationPercent = (double)losingCount / MaxPositionsPerSide * 100.0;
   
   if (saturationPercent < 70.0)
      return false;
   
   int delaySeconds = BaseDelaySeconds;
   if (saturationPercent >= 95.0)
      delaySeconds = MaxDelaySeconds;
   else if (saturationPercent >= 85.0)
      delaySeconds = (BaseDelaySeconds + MaxDelaySeconds) / 2;
   
   return (currentTime - lastEntry < delaySeconds);
}

//+------------------------------------------------------------------+
//| CHECK NET EXPOSURE LIMIT                                          |
//+------------------------------------------------------------------+
bool ExceedsNetExposure(string side, double proposedLot)
{
   double buyLots = BuySide.totalLots;
   double sellLots = SellSide.totalLots;
   
   double futureNet;
   if (side == "BUY")
      futureNet = MathAbs((buyLots + proposedLot) - sellLots);
   else
      futureNet = MathAbs(buyLots - (sellLots + proposedLot));
   
   return (futureNet > MaxNetExposureLots);
}

//+------------------------------------------------------------------+
//| CHECK IF POSITION EXISTS NEAR GRID LEVEL                          |
//+------------------------------------------------------------------+
bool HasPositionNearLevel(double gridLevel, Position &posArray[])
{
   double minDistance = currentGapSize * 0.8;
   
   for (int i = 0; i < ArraySize(posArray); i++)
   {
      if (MathAbs(posArray[i].entryPrice - gridLevel) < minDistance)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // V6: No ATR indicator to release
   ObjectsDeleteAll(0, panelPrefix);
   ChartRedraw();
   
   Print("═══════════════════════════════════════");
   Print("👋 ", EA_NAME, " stopped");
   Print("Total trades: ", totalTrades);
   Print("Unified BUY/SELL system");
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
      
      // V6: No ATR calculations needed
   }
   
   // Check spread before any trading operations
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
   
   // Check group TP
   CheckGroupTP();
   
   // Grid logic - unified BUY/SELL check
   CheckGridUnified();
   
   // Update panel
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| UNIFIED GRID LOGIC - BOTH BUY AND SELL                            |
//+------------------------------------------------------------------+
void CheckGridUnified()
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
   double triggerPercent = 0.05;
   if(currentPrice > 10000)
      triggerPercent = 0.02;
   else if(currentPrice > 1000)
      triggerPercent = 0.03;
   
   double triggerZone = currentGapSize * triggerPercent;
   
   if(distanceToNearestLevel > triggerZone)
      return;
   
   // Try opening BUY position
   if(ArraySize(BuySide.positions) < MaxPositionsPerSide)
   {
      if(!ShouldDelayEntry("BUY", TimeCurrent()))
      {
         if(!HasPositionNearLevel(nearestGridLevel, BuySide.positions))
         {
            double lotSize = CalculateDynamicLot("BUY");
            
            if(!ExceedsNetExposure("BUY", lotSize))
            {
               if(OpenPositionUnified(ORDER_TYPE_BUY, ask, lotSize, nearestGridLevel))
               {
                  BuySide.lastEntryTime = TimeCurrent();
                  Print("⚡ BUY opened: ", DoubleToString(lotSize, 2), " lots @ $", DoubleToString(nearestGridLevel, specs.digits));
               }
            }
         }
      }
   }
   
   // Try opening SELL position
   if(ArraySize(SellSide.positions) < MaxPositionsPerSide)
   {
      if(!ShouldDelayEntry("SELL", TimeCurrent()))
      {
         if(!HasPositionNearLevel(nearestGridLevel, SellSide.positions))
         {
            double lotSize = CalculateDynamicLot("SELL");
            
            if(!ExceedsNetExposure("SELL", lotSize))
            {
               if(OpenPositionUnified(ORDER_TYPE_SELL, bid, lotSize, nearestGridLevel))
               {
                  SellSide.lastEntryTime = TimeCurrent();
                  Print("⚡ SELL opened: ", DoubleToString(lotSize, 2), " lots @ $", DoubleToString(nearestGridLevel, specs.digits));
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| SYNC POSITIONS - UNIFIED BUY/SELL TRACKING                        |
//+------------------------------------------------------------------+
void SyncPositions()
{
   // Clear both sides
   ArrayResize(BuySide.positions, 0);
   ArrayResize(SellSide.positions, 0);
   
   BuySide.totalLots = 0;
   SellSide.totalLots = 0;
   BuySide.totalProfit = 0;
   SellSide.totalProfit = 0;
   
   // Scan all positions
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
            pos.lotSize = PositionGetDouble(POSITION_VOLUME);
            pos.entryTime = (datetime)PositionGetInteger(POSITION_TIME);
            
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double profit = PositionGetDouble(POSITION_PROFIT);
            
            if(type == POSITION_TYPE_BUY)
            {
               int size = ArraySize(BuySide.positions);
               ArrayResize(BuySide.positions, size + 1);
               BuySide.positions[size] = pos;
               BuySide.totalLots += pos.lotSize;
               BuySide.totalProfit += profit;
            }
            else
            {
               int size = ArraySize(SellSide.positions);
               ArrayResize(SellSide.positions, size + 1);
               SellSide.positions[size] = pos;
               SellSide.totalLots += pos.lotSize;
               SellSide.totalProfit += profit;
            }
         }
      }
   }
   
   totalProfit = BuySide.totalProfit + SellSide.totalProfit;
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT - UNIFIED                                  |
//+------------------------------------------------------------------+
double CalculateTotalProfit()
{
   double profit = 0;
   
   for(int i = 0; i < ArraySize(BuySide.positions); i++)
   {
      if(PositionSelectByTicket(BuySide.positions[i].ticket))
      {
         profit += PositionGetDouble(POSITION_PROFIT);
      }
   }
   
   for(int i = 0; i < ArraySize(SellSide.positions); i++)
   {
      if(PositionSelectByTicket(SellSide.positions[i].ticket))
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
//| OPEN POSITION UNIFIED - TRACKS LOT SIZE                           |
//+------------------------------------------------------------------+
bool OpenPositionUnified(ENUM_ORDER_TYPE orderType, double price, double lotSize, double levelPrice)
{
   // Note: MaxPositions check is done in CheckGridUnified before calling this function
   // This function focuses on actually placing the order
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.type = orderType;
   request.price = price;
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = StringFormat("UNI_%.2f_%.2f", levelPrice, lotSize);
   
   Print("📊 Opening ", (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"), " position:");
   Print("   Entry: $", DoubleToString(price, specs.digits));
   Print("   Base Lot Size: ", DoubleToString(validatedLotSize, 3));
   Print("   Tick Value: $", DoubleToString(specs.tickValue, 4));
   Print("   Tick Size: $", DoubleToString(specs.tickSize, 5));
   
   // Calculate point value (value per 1.0 price unit)
   double pointValue = specs.tickValue / specs.tickSize;
   double positionValue = pointValue * lotSize;
   
   Print("   Point Value: $", DoubleToString(pointValue, 4), " per 1.0 price unit");
   Print("   Position Value: $", DoubleToString(positionValue, 4), " per 1.0 price move");
   
   // Set TP based on dollar target
   if(IndividualTPDollars > 0)
   {
      // Check if opposite side is saturated (80%+) AND we have scaled lot
      // If YES: MULTIPLY TP by 6x for maximum profit capture!
      double tpTargetDollars = IndividualTPDollars;
      int oppositeCount = 0;
      
      if(orderType == ORDER_TYPE_BUY)
      {
         // Opening BUY - check SELL saturation
         oppositeCount = ArraySize(SellSide.positions);
      }
      else
      {
         // Opening SELL - check BUY saturation
         oppositeCount = ArraySize(BuySide.positions);
      }
      
      double oppositeSaturation = (double)oppositeCount / MaxPositionsPerSide * 100.0;
      
      // Calculate current lot multiplier to check if we're scaled
      double lotMultiplier = lotSize / validatedLotSize;
      
      // TP MULTIPLIER: 6x when opposite >= 80% AND lot is scaled
      if(oppositeSaturation >= 80.0 && lotMultiplier > 1.0)
      {
         tpTargetDollars = IndividualTPDollars * 6.0;  // 6X TP!
         Print("   🎯 6X TP ACTIVATED!");
         Print("   Opposite saturation: ", DoubleToString(oppositeSaturation, 1), "%");
         Print("   Lot scaling: ", DoubleToString(lotMultiplier, 1), "x");
         Print("   TP Target: $", DoubleToString(tpTargetDollars, 2), " (6x normal)");
      }
      
      // CORRECT FORMULA (from percentage-based EA):
      // Distance = Target$ / (PointValue × LotSize)
      double tpDistance = tpTargetDollars / positionValue;
      
      Print("   TP Target: $", DoubleToString(tpTargetDollars, 2));
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
         Print("   This suggests IndividualTPDollars ($", DoubleToString(tpTargetDollars, 2), 
               ") is too high for lot size ", DoubleToString(lotSize, 3));
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
         Print("   This suggests IndividualSLDollars is too high for lot size ", DoubleToString(lotSize, 3));
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
   Print("║ UNIFIED SYSTEM STATUS                                        ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Trading Mode:          UNIFIED (BUY + SELL)");
   Print("Lot Scaling:           ", EnableLotScaling ? "ENABLED" : "DISABLED");
   Print("Entry Delays:          ", EnableEntryDelay ? "ENABLED" : "DISABLED");
   Print("BUY Positions:         ", ArraySize(BuySide.positions), "/", MaxPositionsPerSide);
   Print("SELL Positions:        ", ArraySize(SellSide.positions), "/", MaxPositionsPerSide);
   Print("Net Exposure Limit:    ", DoubleToString(MaxNetExposureLots, 2), " lots");
   
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ GRID STATUS                                                  ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Reference Price:       $", DoubleToString(referencePrice, specs.digits));
   Print("Grid Gap:              $", DoubleToString(currentGapSize, 2), " (", DoubleToString(GridGapPercent, 2), "%)");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ POSITIONS                                                    ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Active Positions:      BUY:", ArraySize(BuySide.positions), " SELL:", ArraySize(SellSide.positions));
   
   // Count BUY and SELL positions separately
   int buyCount = 0;
   int sellCount = 0;
   double buyProfit = 0;
   double sellProfit = 0;
   
   // Combined position tracking in unified system
   for(int i = 0; i < ArraySize(BuySide.positions); i++)
   {
      if(PositionSelectByTicket(BuySide.positions[i].ticket))
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
   
   // SELL side
   for (int i = 0; i < ArraySize(SellSide.positions); i++)
   {
      if(PositionSelectByTicket(SellSide.positions[i].ticket))
      {
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double profit = PositionGetDouble(POSITION_PROFIT);
         
         if(type == POSITION_TYPE_SELL)
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
         if(ArraySize(BuySide.positions) + ArraySize(SellSide.positions) > 0)
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
      // V6: No mode switch button in unified system
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
      "ScalingLabel", "BuyMultiplier", "SellMultiplier",
      "RefLabel", "RefPrice",
      "NextBuyLabel", "NextBuy", "NextSellLabel", "NextSell",
      "PosLabel", "Positions",
      "AccLabel", "AccCounts",
      "PnLLabel", "PnL",
      "EquityLabel", "Equity",
      "DDLabel", "DD",
      "DailyLabel", "DailyProfit",
      "DDTriggerLabel", "DDTrigger",
      "Brand", "Email"
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
   int width = 320;  // Wider for better spacing
   int lineHeight = 22;  // More spacing between lines
   
   // Background with increased height for better layout
   ObjectCreate(0, panelPrefix + "Background", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YSIZE, 405);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BGCOLOR, C'20,20,25');
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_HIDDEN, true);
   
   int yPos = y + 12;
   
   // === TITLE ROW ===
   CreateLabel(panelPrefix + "Title", x + 10, yPos, "AGGRESSIVE TRADER", clrGold, 11, "Arial Black");
   CreateLabel(panelPrefix + "Status", x + width - 80, yPos, "✅ ACTIVE", clrLimeGreen, 9, "Arial Bold");
   yPos += 26;
   
   // === BUTTONS ROW ===
   CreateButton(panelPrefix + "CloseBtn", x + 10, yPos, 65, 26, "CLOSE", clrRed, clrWhite);
   CreateButton(panelPrefix + "PauseBtn", x + 80, yPos, 65, 26, "PAUSE", clrOrange, clrWhite);
   CreateButton(panelPrefix + "TPBtn", x + 150, yPos, 55, 26, "TP", clrGreen, clrWhite);
   yPos += 34;
   
   // === MODE ROW ===
   CreateLabel(panelPrefix + "DirectionLabel", x + 10, yPos, "Mode:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Direction", x + 65, yPos, "UNIFIED", clrLimeGreen, 10, "Arial Black");
   yPos += lineHeight;
   
   // === PRICE ROW ===
   CreateLabel(panelPrefix + "PriceLabel", x + 10, yPos, "Price:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Price", x + 65, yPos, "$0", clrWhite, 10, "Arial Bold");
   yPos += lineHeight;
   
   // === GRID ROW ===
   CreateLabel(panelPrefix + "GridLabel", x + 10, yPos, "Grid:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "GridSpacing", x + 65, yPos, "0%", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "SpreadLabel", x + 170, yPos, "Spread:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Spread", x + 235, yPos, "0/2000", clrWhite, 9, "Arial");
   yPos += lineHeight;
   
   // === SCALING ROW ===
   CreateLabel(panelPrefix + "ScalingLabel", x + 10, yPos, "Scaling:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "BuyMultiplier", x + 85, yPos, "B:1.0x", clrDodgerBlue, 9, "Arial Bold");
   CreateLabel(panelPrefix + "SellMultiplier", x + 155, yPos, "S:1.0x", clrOrangeRed, 9, "Arial Bold");
   yPos += lineHeight;
   
   // === REFERENCE ROW ===
   CreateLabel(panelPrefix + "RefLabel", x + 10, yPos, "Reference:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "RefPrice", x + 95, yPos, "$0", clrWhite, 9, "Arial");
   yPos += lineHeight;
   
   // === NEXT LEVELS ROW ===
   CreateLabel(panelPrefix + "NextBuyLabel", x + 10, yPos, "↑Next:", clrDodgerBlue, 9, "Arial Bold");
   CreateLabel(panelPrefix + "NextBuy", x + 70, yPos, "$0", clrDodgerBlue, 9, "Arial Bold");
   CreateLabel(panelPrefix + "NextSellLabel", x + 170, yPos, "↓Next:", clrOrangeRed, 9, "Arial Bold");
   CreateLabel(panelPrefix + "NextSell", x + 230, yPos, "$0", clrOrangeRed, 9, "Arial Bold");
   yPos += lineHeight + 4;
   
   // === EA POSITIONS ROW ===
   CreateLabel(panelPrefix + "PosLabel", x + 10, yPos, "⚡EA:", clrGold, 9, "Arial Black");
   CreateLabel(panelPrefix + "Positions", x + 60, yPos, "B:0 S:0", clrWhite, 10, "Arial Black");
   yPos += lineHeight;
   
   // === ACCOUNT POSITIONS ROW ===
   CreateLabel(panelPrefix + "AccLabel", x + 10, yPos, "Acc:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "AccCounts", x + 60, yPos, "B:0.00 S:0.00 (0)", clrWhite, 9, "Arial");
   yPos += lineHeight + 4;
   
   // === P/L ROW ===
   CreateLabel(panelPrefix + "PnLLabel", x + 10, yPos, "P/L:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "PnL", x + 60, yPos, "$0", clrWhite, 11, "Arial Black");
   yPos += lineHeight;
   
   // === EQUITY ROW ===
   CreateLabel(panelPrefix + "EquityLabel", x + 10, yPos, "Equity:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Equity", x + 70, yPos, "$0", clrWhite, 9, "Arial");
   yPos += lineHeight;
   
   // === DRAWDOWN ROW ===
   CreateLabel(panelPrefix + "DDLabel", x + 10, yPos, "DD:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DD", x + 60, yPos, "0%", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "DailyLabel", x + 170, yPos, "Daily:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DailyProfit", x + 220, yPos, "$0", clrWhite, 9, "Arial");
   yPos += lineHeight;
   
   // === DD TRIGGER ROW ===
   CreateLabel(panelPrefix + "DDTriggerLabel", x + 10, yPos, "🛑 DD@:", clrOrangeRed, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DDTrigger", x + 70, yPos, "$0", clrOrangeRed, 9, "Arial Bold");
   yPos += lineHeight + 15;
   
   // === BRANDING - Bottom Right Corner ===
   int brandY = y + 405 - 35;  // 35px from bottom
   int brandX = x + width - 12;  // 12px from right edge
   
   // Main branding
   ObjectCreate(0, panelPrefix + "Brand", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_XDISTANCE, brandX);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_YDISTANCE, brandY);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_FONT, "Arial Black");
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_TEXT, "© TORAMA CAPITAL");
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_HIDDEN, true);
   
   // Email below branding
   ObjectCreate(0, panelPrefix + "Email", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_XDISTANCE, brandX);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_YDISTANCE, brandY + 16);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_COLOR, C'150,150,100');  // Dimmed gold
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_FONTSIZE, 7);
   ObjectSetString(0, panelPrefix + "Email", OBJPROP_FONT, "Arial");
   ObjectSetString(0, panelPrefix + "Email", OBJPROP_TEXT, "ea@torama.money");
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_HIDDEN, true);
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
   
   // Get prices for calculations
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
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
   // V6: Unified system - no single direction
   string directionText = "UNIFIED BUY+SELL";
   color dirColor = clrLimeGreen;  // Default color
   
   // Check if we have positions from opposite direction
   if(ArraySize(BuySide.positions) + ArraySize(SellSide.positions) > 0)
   {
      bool hasBuyPositions = false;
      bool hasSellPositions = false;
      
      // Combined position tracking in unified system
   for(int i = 0; i < ArraySize(BuySide.positions); i++)
      {
         if(PositionSelectByTicket(BuySide.positions[i].ticket))
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
   
   
   // Reference
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, "$" + FormatPrice(referencePrice, specs.digits));
   
   // Next Buy/Sell Levels - Calculate from current price (using currentPrice already declared at top)
   double distanceFromReference = currentPrice - referencePrice;
   int levelIndex = (int)MathRound(distanceFromReference / currentGapSize);
   double currentGridLevel = referencePrice + (levelIndex * currentGapSize);
   
   // Next levels are +/- one grid gap from current
   double nextBuyLevel = currentGridLevel + currentGapSize;
   double nextSellLevel = currentGridLevel - currentGapSize;
   
   ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, "$" + FormatPrice(nextBuyLevel, specs.digits));
   ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, "$" + FormatPrice(nextSellLevel, specs.digits));
   
   // EA Positions - BUY and SELL
   string posText = "B:" + IntegerToString(ArraySize(BuySide.positions)) + " S:" + IntegerToString(ArraySize(SellSide.positions));
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT, posText);
   
   // Account-wide BUY/SELL LOTS (all positions regardless of magic number)
   double totalBuyLots = 0;
   double totalSellLots = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)  // Only this symbol
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
   
   if(MathAbs(netPosition) < 0.01)  // Effectively zero
   {
      netText = "(0)";
      netColor = clrWhite;
   }
   else if(netPosition > 0)
   {
      netText = "(+" + DoubleToString(netPosition, 2) + "B)";
      netColor = clrDodgerBlue;  // Net BUY
   }
   else
   {
      netText = "(" + DoubleToString(MathAbs(netPosition), 2) + "S)";
      netColor = clrOrangeRed;  // Net SELL
   }
   
   // Format: "B:40.5 S:45.0 (4.5S)"
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
   
   // Drawdown trigger price calculation - NEW in v5.4
   double ddTriggerEquity = peakEquity * (1.0 - MaxDrawdownPercent / 100.0);
   double currentFloatingPL = CalculateTotalProfit();
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double plNeededForDDTrigger = ddTriggerEquity - currentEquity;
   
   // Calculate price where DD would trigger
   double ddTriggerPrice = 0;
   bool hasDDCalc = false;
   
   if((ArraySize(BuySide.positions) + ArraySize(SellSide.positions)) > 0 && MathAbs(currentFloatingPL) > 0.01)
   {
      // Calculate total volume for both sides
      double buyVolume = 0;
      double sellVolume = 0;
      
      // Calculate BUY side volume
      for(int i = 0; i < ArraySize(BuySide.positions); i++)
      {
         if(PositionSelectByTicket(BuySide.positions[i].ticket))
         {
            buyVolume += PositionGetDouble(POSITION_VOLUME);
         }
      }
      
      // Calculate SELL side volume
      for(int i = 0; i < ArraySize(SellSide.positions); i++)
      {
         if(PositionSelectByTicket(SellSide.positions[i].ticket))
         {
            sellVolume += PositionGetDouble(POSITION_VOLUME);
         }
      }
      
      double totalVolume = buyVolume + sellVolume;
      
      if(totalVolume > 0)
      {
         // For Gold/BTC: tickValue / tickSize = point value
         double pointValue = specs.tickValue / specs.tickSize;
         double plPerPointMove = pointValue * totalVolume;
         
         if(plPerPointMove > 0)
         {
            double pointsMoveToDDTrigger = plNeededForDDTrigger / plPerPointMove;
            
            // V6: Use net position direction for DD calculation
            // If net long (more buys), DD triggers on downward move
            // If net short (more sells), DD triggers on upward move
            if(buyVolume > sellVolume)
            {
               ddTriggerPrice = (ask + bid) / 2.0 - MathAbs(pointsMoveToDDTrigger);  // Net long - DD on drop
            }
            else
            {
               ddTriggerPrice = (ask + bid) / 2.0 + MathAbs(pointsMoveToDDTrigger);  // Net short - DD on rise
            }
            hasDDCalc = true;
         }
      }
   }
   
   // Display with color coding
   string ddTriggerText;
   if(hasDDCalc)
   {
      ddTriggerText = "$" + FormatPrice(ddTriggerPrice, specs.digits);
   }
   else
   {
      // No positions - show equity trigger level instead
      ddTriggerText = "EQ $" + FormatPrice(ddTriggerEquity, 2);
   }
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
   
   // V6: Lot scaling multipliers
   double buyMultiplier = CalculateDynamicLot("BUY") / BaseLotSize;
   double sellMultiplier = CalculateDynamicLot("SELL") / BaseLotSize;
   
   ObjectSetString(0, panelPrefix + "BuyMultiplier", OBJPROP_TEXT, "B:" + DoubleToString(buyMultiplier, 1) + "x");
   ObjectSetString(0, panelPrefix + "SellMultiplier", OBJPROP_TEXT, "S:" + DoubleToString(sellMultiplier, 1) + "x");
   
   // Color code based on if scaling is active
   color buyColor = (buyMultiplier > 1.1) ? clrLimeGreen : clrDodgerBlue;
   color sellColor = (sellMultiplier > 1.1) ? clrLimeGreen : clrOrangeRed;
   ObjectSetInteger(0, panelPrefix + "BuyMultiplier", OBJPROP_COLOR, buyColor);
   ObjectSetInteger(0, panelPrefix + "SellMultiplier", OBJPROP_COLOR, sellColor);
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
