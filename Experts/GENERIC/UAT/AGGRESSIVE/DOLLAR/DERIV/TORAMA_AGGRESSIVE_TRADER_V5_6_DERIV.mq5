//+------------------------------------------------------------------+
//|                    TORAMA Aggressive Trader EA v5.6 DERIV        |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "5.61"
#property description "Aggressive Directional Grid Trader - DERIV OPTIMIZED"
#property description "Trades ONLY in chosen direction as price moves"
#property description "Auto-detects Deriv broker and converts volumes correctly"
#property description ""
#property description "V5.6.1 DERIV: Automatic Deriv broker detection and volume handling"

#define EA_VERSION "5.6.1 DERIV"
#define EA_NAME "TORAMA AGGRESSIVE TRADER"

// Include necessary MQL5 libraries
#include <Trade\Trade.mqh>

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
 bool     EnableATRSwitch = false;                // Enable ATR-based mode switching
 int      ATRPeriod = 14;                        // ATR Period for mode switching
 double   ATRThresholdPercent = 70.0;            // ATR Threshold % (70 = 0.7 × ATR)
 bool     CloseOnModeSwitch = false;             // Close positions on mode switch (false = let them run)

input group "=== GRID SETTINGS ==="
input double   GridGapPercent = 0.5;                  // Grid gap % (0.5 = tight, 1.0 = medium, 2.0 = wide)
input int      MaxPositions = 100;                    // Maximum positions
input double   LotSize = 0.1;                         // Lot size per position (ACTUAL lots, not volume)

input group "=== TAKE PROFIT ==="
input double   IndividualTPDollars = 50.0;            // Individual TP target ($50 per position)
input double   GroupTPDollars = 200.0;                // Group TP target ($200 total profit closes all)


double   IndividualSLDollars = 0.0;           // SL risk per trade ($100 max loss, 0 = disabled)

input group "=== RISK MANAGEMENT ==="
input double   MaxDrawdownPercent = 20.0;             // Max drawdown % (emergency stop)
double   DailyTargetPercent = 200.0;            // Daily profit target (% of start balance)

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                      // Maximum spread (points)
bool     ShowPanel = true;                      // Show info panel

input group "=== TIME CONTROLS ==="
input bool     EnableTimeFilter = false;              // Enable time-based trading filter
input int      TradingStartHour = 6;                  // Trading start hour (0-23, WAT)
input int      TradingStartMinute = 0;                // Trading start minute (0-59)
input int      TradingEndHour = 17;                   // Trading end hour (0-23, WAT)
input int      TradingEndMinute = 0;                  // Trading end minute (0-59)

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

//+------------------------------------------------------------------+
//| DERIV-SPECIFIC BROKER DETECTION                                  |
//+------------------------------------------------------------------+
struct BrokerSpecs
{
   bool     isDerivBroker;           // Is this a Deriv broker?
   double   volumeMultiplier;        // Volume conversion multiplier
   string   brokerName;              // Broker company name
   string   volumeInterpretation;    // How volume is interpreted
};

BrokerSpecs brokerSpecs;

//+------------------------------------------------------------------+
//| SYMBOL SPECIFICATIONS                                             |
//+------------------------------------------------------------------+
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
//| DETECT DERIV BROKER AND VOLUME CONVENTION                        |
//+------------------------------------------------------------------+
bool DetectDerivBroker()
{
   string companyName = AccountInfoString(ACCOUNT_COMPANY);
   string serverName = AccountInfoString(ACCOUNT_SERVER);
   
   Print("🔍 BROKER DETECTION:");
   Print("   Company: ", companyName);
   Print("   Server: ", serverName);
   
   // Reset broker specs
   brokerSpecs.isDerivBroker = false;
   brokerSpecs.volumeMultiplier = 1.0;
   brokerSpecs.brokerName = companyName;
   brokerSpecs.volumeInterpretation = "Standard (Volume = Lots)";
   
   // Detect Deriv by company name or server name
   if(StringFind(companyName, "Deriv", 0) >= 0 || 
      StringFind(serverName, "Deriv", 0) >= 0 ||
      StringFind(companyName, "Binary", 0) >= 0)
   {
      brokerSpecs.isDerivBroker = true;
      brokerSpecs.volumeMultiplier = 100.0;  // Deriv: Volume 100 = 1.0 lot
      brokerSpecs.volumeInterpretation = "Deriv (Volume 100 = 1.0 lot)";
      
      Print("✅ DERIV BROKER DETECTED!");
      Print("   Volume Multiplier: ", brokerSpecs.volumeMultiplier);
      Print("   Interpretation: ", brokerSpecs.volumeInterpretation);
      return true;
   }
   
   // Additional detection: Check if symbol is volatility index
   string symbol = _Symbol;
   if(StringFind(symbol, "Volatility", 0) >= 0 || 
      StringFind(symbol, "V75", 0) >= 0 ||
      StringFind(symbol, "V100", 0) >= 0 ||
      StringFind(symbol, "V50", 0) >= 0 ||
      StringFind(symbol, "V25", 0) >= 0 ||
      StringFind(symbol, "V10", 0) >= 0)
   {
      // Likely Deriv even if company name not detected
      brokerSpecs.isDerivBroker = true;
      brokerSpecs.volumeMultiplier = 100.0;
      brokerSpecs.volumeInterpretation = "Deriv (Volume 100 = 1.0 lot) - Detected via symbol";
      
      Print("✅ DERIV DETECTED VIA SYMBOL (", symbol, ")");
      Print("   Volume Multiplier: ", brokerSpecs.volumeMultiplier);
      return true;
   }
   
   Print("ℹ️ Standard broker detected (non-Deriv)");
   return false;
}

//+------------------------------------------------------------------+
//| CONVERT LOT SIZE TO BROKER VOLUME                                |
//+------------------------------------------------------------------+
double ConvertLotsToVolume(double lots)
{
   // Apply broker-specific volume conversion
   double volume = lots * brokerSpecs.volumeMultiplier;
   
   // Normalize to broker's lot step
   volume = NormalizeDouble(volume / specs.lotStep, 0) * specs.lotStep;
   
   // Enforce min/max limits
   if(volume < specs.minLot) volume = specs.minLot;
   if(volume > specs.maxLot) volume = specs.maxLot;
   
   return volume;
}

//+------------------------------------------------------------------+
//| CONVERT BROKER VOLUME TO ACTUAL LOTS                             |
//+------------------------------------------------------------------+
double ConvertVolumeToLots(double volume)
{
   return volume / brokerSpecs.volumeMultiplier;
}

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
//| INITIALIZE SYMBOL SPECIFICATIONS                                 |
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
   Print("   Symbol: ", _Symbol);
   Print("   Digits: ", specs.digits);
   Print("   Point: ", specs.point);
   Print("   Tick Size: ", specs.tickSize);
   Print("   Tick Value: $", specs.tickValue);
   Print("   Contract Size: ", specs.contractSize);
   Print("   Min Volume: ", specs.minLot);
   Print("   Max Volume: ", specs.maxLot);
   Print("   Volume Step: ", specs.lotStep);
   Print("   Stop Level: ", specs.stopLevel);
   
   if(specs.tickValue == 0 || specs.tickSize == 0)
   {
      Print("❌ ERROR: Invalid tick value or tick size!");
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| VALIDATE LOT SIZE                                                 |
//+------------------------------------------------------------------+
double ValidateLotSize(double lots)
{
   // Convert user's lot input to broker volume
   double volume = ConvertLotsToVolume(lots);
   
   Print("💱 LOT SIZE CONVERSION:");
   Print("   User Input (Lots): ", DoubleToString(lots, 3));
   Print("   Broker Volume: ", DoubleToString(volume, 2));
   Print("   Actual Lots: ", DoubleToString(ConvertVolumeToLots(volume), 3));
   
   if(volume < specs.minLot)
   {
      Print("⚠️ Lot size ", volume, " below minimum ", specs.minLot, ". Using minimum.");
      volume = specs.minLot;
   }
   
   if(volume > specs.maxLot)
   {
      Print("⚠️ Lot size ", volume, " above maximum ", specs.maxLot, ". Using maximum.");
      volume = specs.maxLot;
   }
   
   // Return the validated volume (broker format)
   return volume;
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
   
   // CRITICAL: Detect Deriv broker FIRST
   DetectDerivBroker();
   
   // Generate persistent chart-based magic number
   MagicNumber = GenerateChartBasedMagicNumber();
   Print("🔢 Magic Number (Chart ID: ", ChartID(), "): ", MagicNumber);
   
   // Initialize symbol specifications
   if(!InitializeSymbolSpecs())
   {
      Print("❌ FAILED: Could not initialize symbol specifications");
      return(INIT_FAILED);
   }
   
   // Validate and normalize lot size with Deriv conversion
   validatedLotSize = ValidateLotSize(LotSize);
   
   Print("📊 CONFIGURATION:");
   Print("   Starting Direction: ", StartDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   Print("   Symbol: ", _Symbol);
   Print("   Input Lot Size: ", DoubleToString(LotSize, 3), " lots");
   Print("   Broker Volume: ", DoubleToString(validatedLotSize, 2));
   Print("   Actual Trade Size: ", DoubleToString(ConvertVolumeToLots(validatedLotSize), 3), " lots");
   Print("   Max Positions: ", MaxPositions);
   
   // Set current direction to starting direction
   CurrentDirection = StartDirection;
   
   // Initialize ATR mode switching
   if(EnableATRSwitch)
   {
      atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
      if(atrHandle == INVALID_HANDLE)
      {
         Print("❌ FAILED: Could not create ATR indicator");
         return(INIT_FAILED);
      }
      Print("✅ ATR Mode Switching: ENABLED");
      Print("   ATR Period: ", ATRPeriod);
      Print("   Threshold: ", ATRThresholdPercent, "% of ATR");
      Print("   Close on Switch: ", CloseOnModeSwitch ? "YES" : "NO");
   }
   else
   {
      Print("ℹ️ ATR Mode Switching: DISABLED");
   }
   
   // Initialize daily tracking
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   currentDay = time.day;
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyTarget = dailyStartBalance * (DailyTargetPercent / 100.0);
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Load existing positions
   LoadPositions();
   
   // Set reference price
   if(ArraySize(positions) > 0)
   {
      referencePrice = CalculateReferencePrice();
      Print("📍 Loaded existing grid with ", ArraySize(positions), " positions");
      Print("   Reference Price: $", DoubleToString(referencePrice, specs.digits));
   }
   else
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      referencePrice = (ask + bid) / 2.0;
      Print("📍 New grid initialized at $", DoubleToString(referencePrice, specs.digits));
   }
   
   // Calculate gap size (convert percentage to decimal: 0.5% = 0.005)
   currentGapSize = referencePrice * (GridGapPercent / 100.0);
   Print("   Grid Gap: $", DoubleToString(currentGapSize, specs.digits), " (", DoubleToString(GridGapPercent, 2), "%)");
   
   // Create panel
   if(ShowPanel)
   {
      CreatePanel();
   }
   
   Print("✅ EA INITIALIZED SUCCESSFULLY");
   Print("═══════════════════════════════════════");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("🛑 EA STOPPED - Reason: ", reason);
   
   if(atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(atrHandle);
   }
   
   DeletePanel();
   
   Print("Final Statistics:");
   Print("   Total Trades: ", totalTrades);
   Print("   Mode Switches: ", modeSwitchCount);
   Print("   Total P/L: $", DoubleToString(totalProfit, 2));
}

//+------------------------------------------------------------------+
//| LOAD EXISTING POSITIONS                                           |
//+------------------------------------------------------------------+
void LoadPositions()
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
            int idx = ArraySize(positions);
            ArrayResize(positions, idx + 1);
            positions[idx].ticket = ticket;
            positions[idx].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            positions[idx].entryTime = (datetime)PositionGetInteger(POSITION_TIME);
         }
      }
   }
   
   Print("📥 Loaded ", ArraySize(positions), " existing positions");
}

//+------------------------------------------------------------------+
//| CALCULATE REFERENCE PRICE FROM EXISTING POSITIONS                |
//+------------------------------------------------------------------+
double CalculateReferencePrice()
{
   if(ArraySize(positions) == 0)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return (ask + bid) / 2.0;
   }
   
   double sum = 0;
   for(int i = 0; i < ArraySize(positions); i++)
   {
      sum += positions[i].entryPrice;
   }
   
   return sum / ArraySize(positions);
}

//+------------------------------------------------------------------+
//| ON TICK                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // Update panel
   if(ShowPanel && panelVisible)
   {
      UpdatePanel();
   }
   
   // Check emergency stop
   if(emergencyStop)
   {
      return;
   }
   
   // Check if paused
   if(isPaused)
   {
      return;
   }
   
   // Check time filter
   if(EnableTimeFilter && !IsWithinTradingHours())
   {
      return;
   }
   
   // Daily reset check
   CheckDailyReset();
   
   // ATR mode switching
   if(EnableATRSwitch)
   {
      CheckATRModeSwitch();
   }
   
   // Risk management
   CheckRiskManagement();
   
   if(emergencyStop) return;
   
   // Check spread
   if(!IsSpreadAcceptable())
   {
      return;
   }
   
   // Main trading logic
   ManageGrid();
   
   // Check profit targets
   CheckProfitTargets();
}

//+------------------------------------------------------------------+
//| CHECK IF WITHIN TRADING HOURS                                    |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
   MqlDateTime timeStruct;
   TimeToStruct(TimeCurrent(), timeStruct);
   
   int currentMinutes = timeStruct.hour * 60 + timeStruct.min;
   int startMinutes = TradingStartHour * 60 + TradingStartMinute;
   int endMinutes = TradingEndHour * 60 + TradingEndMinute;
   
   if(startMinutes <= endMinutes)
   {
      return (currentMinutes >= startMinutes && currentMinutes < endMinutes);
   }
   else
   {
      return (currentMinutes >= startMinutes || currentMinutes < endMinutes);
   }
}

//+------------------------------------------------------------------+
//| CHECK DAILY RESET                                                 |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   int newDay = time.day;
   
   if(newDay != currentDay)
   {
      Print("📅 NEW DAY - Resetting daily tracking");
      currentDay = newDay;
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyTarget = dailyStartBalance * (DailyTargetPercent / 100.0);
      dailyTargetReached = false;
      
      Print("   Start Balance: $", DoubleToString(dailyStartBalance, 2));
      Print("   Daily Target: $", DoubleToString(dailyTarget, 2));
   }
}

//+------------------------------------------------------------------+
//| CHECK ATR MODE SWITCHING                                          |
//+------------------------------------------------------------------+
void CheckATRModeSwitch()
{
   // Update day open price
   MqlDateTime timeStruct;
   TimeToStruct(TimeCurrent(), timeStruct);
   
   if(timeStruct.hour == 0 && TimeCurrent() - lastDayOpenUpdate > 3600)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      dayOpenPrice = (ask + bid) / 2.0;
      lastDayOpenUpdate = TimeCurrent();
      
      Print("🌅 Day Open Price Updated: $", DoubleToString(dayOpenPrice, specs.digits));
   }
   
   if(dayOpenPrice == 0)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      dayOpenPrice = (ask + bid) / 2.0;
   }
   
   // Get current ATR
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) <= 0)
   {
      return;
   }
   currentATR = atr[0];
   
   // Calculate threshold
   double atrThreshold = currentATR * (ATRThresholdPercent / 100.0);
   
   // Current price
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   // Check for mode switch with cooldown
   int barsSinceSwitch = 0;
   if(lastModeSwitchTime > 0)
   {
      barsSinceSwitch = Bars(_Symbol, PERIOD_CURRENT, lastModeSwitchTime, TimeCurrent());
   }
   
   if(barsSinceSwitch >= modeSwitchCooldownBars || lastModeSwitchTime == 0)
   {
      // BUY mode: price falls below (dayOpen - threshold)
      if(CurrentDirection == BUYONLY && currentPrice < (dayOpenPrice - atrThreshold))
      {
         SwitchMode(SELLONLY);
      }
      // SELL mode: price rises above (dayOpen + threshold)
      else if(CurrentDirection == SELLONLY && currentPrice > (dayOpenPrice + atrThreshold))
      {
         SwitchMode(BUYONLY);
      }
   }
}

//+------------------------------------------------------------------+
//| SWITCH TRADING MODE                                               |
//+------------------------------------------------------------------+
void SwitchMode(ENUM_TRADE_DIRECTION newDirection)
{
   if(CurrentDirection == newDirection)
   {
      return;
   }
   
   string oldMode = (CurrentDirection == BUYONLY) ? "BUY" : "SELL";
   string newMode = (newDirection == BUYONLY) ? "BUY" : "SELL";
   
   Print("🔄 MODE SWITCH: ", oldMode, " → ", newMode);
   
   CurrentDirection = newDirection;
   modeSwitchCount++;
   lastModeSwitchTime = TimeCurrent();
   
   // Close positions if enabled
   if(CloseOnModeSwitch)
   {
      Print("   Closing all positions due to mode switch...");
      CloseAllPositions();
   }
   
   // Reset reference price
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   referencePrice = (ask + bid) / 2.0;
   
   Print("   New Reference: $", DoubleToString(referencePrice, specs.digits));
}

//+------------------------------------------------------------------+
//| CHECK RISK MANAGEMENT                                             |
//+------------------------------------------------------------------+
void CheckRiskManagement()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Update peak equity
   if(equity > peakEquity)
   {
      peakEquity = equity;
   }
   
   // Check drawdown
   double drawdown = ((equity - peakEquity) / peakEquity) * 100;
   
   if(drawdown <= -MaxDrawdownPercent)
   {
      emergencyStop = true;
      emergencyReason = "Maximum drawdown reached: " + DoubleToString(drawdown, 2) + "%";
      Print("🚨 EMERGENCY STOP: ", emergencyReason);
      CloseAllPositions();
      return;
   }
   
   // Check daily target
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - dailyStartBalance;
   
   if(dailyProfit >= dailyTarget && !dailyTargetReached)
   {
      dailyTargetReached = true;
      Print("🎯 DAILY TARGET REACHED: $", DoubleToString(dailyProfit, 2));
      // Optional: Stop trading for the day
      // emergencyStop = true;
      // emergencyReason = "Daily target reached";
   }
}

//+------------------------------------------------------------------+
//| CHECK IF SPREAD IS ACCEPTABLE                                    |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = ask - bid;
   int spreadPoints = (int)(spread / specs.point);
   
   return (spreadPoints <= MaxSpread);
}

//+------------------------------------------------------------------+
//| MANAGE GRID                                                       |
//+------------------------------------------------------------------+
void ManageGrid()
{
   // Remove closed positions from tracking
   UpdatePositionsArray();
   
   // Check if we can open more positions
   if(ArraySize(positions) >= MaxPositions)
   {
      return;
   }
   
   // Get current price
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (CurrentDirection == BUYONLY) ? ask : bid;
   
   // Calculate grid levels
   double nextGridLevel = 0;
   
   if(ArraySize(positions) == 0)
   {
      // First position at current price
      nextGridLevel = referencePrice;
   }
   else
   {
      // Find furthest position
      double furthestPrice = FindFurthestPositionPrice();
      
      // Calculate next level based on direction
      if(CurrentDirection == BUYONLY)
      {
         // BUY mode: buy as price goes up AND down
         double levelAbove = furthestPrice + currentGapSize;
         double levelBelow = furthestPrice - currentGapSize;
         
         // Check if price has moved beyond existing levels
         if(currentPrice >= levelAbove)
         {
            nextGridLevel = levelAbove;
         }
         else if(currentPrice <= levelBelow)
         {
            nextGridLevel = levelBelow;
         }
      }
      else // SELLONLY
      {
         // SELL mode: sell as price goes up AND down
         double levelAbove = furthestPrice + currentGapSize;
         double levelBelow = furthestPrice - currentGapSize;
         
         if(currentPrice >= levelAbove)
         {
            nextGridLevel = levelAbove;
         }
         else if(currentPrice <= levelBelow)
         {
            nextGridLevel = levelBelow;
         }
      }
   }
   
   // Open position if we have a valid level
   if(nextGridLevel > 0)
   {
      OpenGridPosition(nextGridLevel);
   }
}

//+------------------------------------------------------------------+
//| FIND FURTHEST POSITION PRICE                                      |
//+------------------------------------------------------------------+
double FindFurthestPositionPrice()
{
   if(ArraySize(positions) == 0)
   {
      return referencePrice;
   }
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   double furthest = positions[0].entryPrice;
   double maxDistance = MathAbs(currentPrice - furthest);
   
   for(int i = 1; i < ArraySize(positions); i++)
   {
      double distance = MathAbs(currentPrice - positions[i].entryPrice);
      if(distance > maxDistance)
      {
         maxDistance = distance;
         furthest = positions[i].entryPrice;
      }
   }
   
   return furthest;
}

//+------------------------------------------------------------------+
//| OPEN GRID POSITION WITH DERIV VOLUME CONVERSION                  |
//+------------------------------------------------------------------+
void OpenGridPosition(double targetPrice)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   // Use validated lot size (already in broker volume format)
   double volume = validatedLotSize;
   
   // Calculate TP
   double tp = 0;
   if(IndividualTPDollars > 0)
   {
      double pointValue = specs.tickValue / specs.tickSize;
      double tpPoints = IndividualTPDollars / (pointValue * ConvertVolumeToLots(volume));
      
      if(CurrentDirection == BUYONLY)
      {
         tp = targetPrice + (tpPoints * specs.point);
      }
      else
      {
         tp = targetPrice - (tpPoints * specs.point);
      }
      
      tp = NormalizeDouble(tp, specs.digits);
   }
   
   // Calculate SL
   double sl = 0;
   if(IndividualSLDollars > 0)
   {
      double pointValue = specs.tickValue / specs.tickSize;
      double slPoints = IndividualSLDollars / (pointValue * ConvertVolumeToLots(volume));
      
      if(CurrentDirection == BUYONLY)
      {
         sl = targetPrice - (slPoints * specs.point);
      }
      else
      {
         sl = targetPrice + (slPoints * specs.point);
      }
      
      sl = NormalizeDouble(sl, specs.digits);
   }
   
   // Setup request
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = volume;  // Using Deriv-converted volume
   request.type = (CurrentDirection == BUYONLY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price = (CurrentDirection == BUYONLY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   request.sl = sl;
   request.tp = tp;
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = "AGG_" + EnumToString(CurrentDirection);
   request.type_filling = ORDER_FILLING_IOC;
   
   // Send order
   if(!OrderSend(request, result))
   {
      Print("❌ Order failed: ", GetLastError());
      Print("   Volume: ", volume, " (", DoubleToString(ConvertVolumeToLots(volume), 3), " lots)");
      return;
   }
   
   if(result.retcode != TRADE_RETCODE_DONE)
   {
      Print("❌ Order rejected: ", result.retcode, " - ", result.comment);
      return;
   }
   
   // Add to positions array
   int idx = ArraySize(positions);
   ArrayResize(positions, idx + 1);
   positions[idx].ticket = result.order;
   positions[idx].entryPrice = result.price;
   positions[idx].entryTime = TimeCurrent();
   
   totalTrades++;
   
   Print("✅ ", EnumToString(CurrentDirection), " #", result.order, 
         " | Volume: ", volume, " (", DoubleToString(ConvertVolumeToLots(volume), 3), " lots)",
         " | Price: $", DoubleToString(result.price, specs.digits),
         " | TP: $", (tp > 0 ? DoubleToString(tp, specs.digits) : "None"));
}

//+------------------------------------------------------------------+
//| UPDATE POSITIONS ARRAY                                            |
//+------------------------------------------------------------------+
void UpdatePositionsArray()
{
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(positions[i].ticket))
      {
         // Position closed, remove from array
         ArrayRemove(positions, i, 1);
      }
   }
}

//+------------------------------------------------------------------+
//| CHECK PROFIT TARGETS                                              |
//+------------------------------------------------------------------+
void CheckProfitTargets()
{
   if(GroupTPDollars <= 0)
   {
      return;
   }
   
   CalculateTotalProfit();
   
   if(totalProfit >= GroupTPDollars)
   {
      Print("🎯 GROUP TP HIT: $", DoubleToString(totalProfit, 2), " ≥ $", DoubleToString(GroupTPDollars, 2));
      CloseAllPositions();
      
      // Reset grid
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      referencePrice = (ask + bid) / 2.0;
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                            |
//+------------------------------------------------------------------+
double CalculateTotalProfit()
{
   totalProfit = 0;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         totalProfit += PositionGetDouble(POSITION_PROFIT);
      }
   }
   
   return totalProfit;
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   Print("🔴 Closing all positions...");
   
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
         request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         request.deviation = 10;
         request.magic = MagicNumber;
         request.type_filling = ORDER_FILLING_IOC;
         
         if(OrderSend(request, result))
         {
            Print("   Closed #", positions[i].ticket);
         }
      }
   }
   
   ArrayResize(positions, 0);
}

//+------------------------------------------------------------------+
//| ON CHART EVENT                                                    |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == panelPrefix + "BtnClose")
      {
         Print("🔴 CLOSE button pressed");
         CloseAllPositions();
         ObjectSetInteger(0, panelPrefix + "BtnClose", OBJPROP_STATE, false);
      }
      else if(sparam == panelPrefix + "BtnPause")
      {
         isPaused = !isPaused;
         ObjectSetString(0, panelPrefix + "BtnPause", OBJPROP_TEXT, isPaused ? "RESUME" : "PAUSE");
         ObjectSetInteger(0, panelPrefix + "BtnPause", OBJPROP_BGCOLOR, isPaused ? clrGreen : clrOrange);
         ObjectSetInteger(0, panelPrefix + "BtnPause", OBJPROP_STATE, false);
         Print(isPaused ? "⏸️ EA PAUSED" : "▶️ EA RESUMED");
      }
      else if(sparam == panelPrefix + "BtnTP")
      {
         Print("🎯 TP button pressed - Forcing profit target check");
         CheckProfitTargets();
         ObjectSetInteger(0, panelPrefix + "BtnTP", OBJPROP_STATE, false);
      }
      else if(sparam == panelPrefix + "BtnMode")
      {
         ENUM_TRADE_DIRECTION newDir = (CurrentDirection == BUYONLY) ? SELLONLY : BUYONLY;
         SwitchMode(newDir);
         ObjectSetInteger(0, panelPrefix + "BtnMode", OBJPROP_STATE, false);
      }
   }
}

//+------------------------------------------------------------------+
//| CREATE PANEL                                                      |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 20;
   int y = 30;
   int lineHeight = 20;
   
   // Background
   ObjectCreate(0, panelPrefix + "Background", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XDISTANCE, x - 5);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YDISTANCE, y - 5);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XSIZE, 310);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YSIZE, 470);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BGCOLOR, C'20,20,20');
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_HIDDEN, true);
   
   // Title
   CreateLabel(panelPrefix + "Title", x + 50, y, EA_NAME, clrGold, 10, "Arial Black");
   y += lineHeight + 5;
   
   // Version
   CreateLabel(panelPrefix + "Version", x + 80, y, "v" + EA_VERSION, clrGray, 8, "Arial");
   y += lineHeight;
   
   // Status indicator
   CreateLabel(panelPrefix + "StatusLabel", x, y, "Status:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "Status", x + 55, y, "ACTIVE", clrLimeGreen, 9, "Arial Bold");
   y += lineHeight;
   
   // Broker info - NEW
   CreateLabel(panelPrefix + "BrokerLabel", x, y, "Broker:", clrWhite, 8, "Arial");
   string brokerText = brokerSpecs.isDerivBroker ? "DERIV" : "Standard";
   color brokerColor = brokerSpecs.isDerivBroker ? clrDodgerBlue : clrGray;
   CreateLabel(panelPrefix + "Broker", x + 55, y, brokerText, brokerColor, 8, "Arial Bold");
   y += lineHeight;
   
   // Mode
   CreateLabel(panelPrefix + "ModeLabel", x, y, "Mode:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "Mode", x + 55, y, "BUY", clrDodgerBlue, 9, "Arial Bold");
   y += lineHeight;
   
   // Price
   CreateLabel(panelPrefix + "PriceLabel", x, y, "Price:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "Price", x + 55, y, "$0.00", clrWhite, 9, "Arial Bold");
   y += lineHeight;
   
   // Grid
   CreateLabel(panelPrefix + "GridLabel", x, y, "Grid:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "Grid", x + 55, y, "0.05% ($0.37)", clrWhite, 9, "Arial");
   y += lineHeight;
   
   // Spread
   CreateLabel(panelPrefix + "SpreadLabel", x, y, "Spread:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "Spread", x + 55, y, "20/2000", clrLimeGreen, 9, "Arial");
   y += lineHeight;
   
   // Reference
   CreateLabel(panelPrefix + "RefLabel", x, y, "Reference:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "RefPrice", x + 80, y, "$735.52", clrYellow, 9, "Arial Bold");
   y += lineHeight;
   
   // EA Positions
   CreateLabel(panelPrefix + "PosLabel", x, y, "EA:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "Positions", x + 55, y, "0/10", clrWhite, 9, "Arial Bold");
   y += lineHeight;
   
   // Account Buy/Sell counts - ENHANCED with net position
   CreateLabel(panelPrefix + "AccLabel", x, y, "Acc:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "AccCounts", x + 55, y, "B:0 S:0 (0)", clrWhite, 9, "Arial");
   y += lineHeight;
   
   // P/L
   CreateLabel(panelPrefix + "PnLLabel", x, y, "P/L:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "PnL", x + 55, y, "+$0", clrLimeGreen, 9, "Arial Bold");
   y += lineHeight;
   
   // Equity
   CreateLabel(panelPrefix + "EquityLabel", x, y, "Equity:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "Equity", x + 55, y, "$10000", clrWhite, 9, "Arial");
   y += lineHeight;
   
   // Drawdown
   CreateLabel(panelPrefix + "DDLabel", x, y, "DD:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "DD", x + 55, y, "-0.1%", clrLimeGreen, 9, "Arial");
   y += lineHeight;
   
   // DD Trigger Price
   CreateLabel(panelPrefix + "DDTriggerLabel", x, y, "DD@:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "DDTrigger", x + 55, y, "$700", clrOrangeRed, 9, "Arial");
   y += lineHeight;
   
   // Daily Profit
   CreateLabel(panelPrefix + "DailyLabel", x, y, "Daily:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "DailyProfit", x + 55, y, "+$0", clrWhite, 9, "Arial");
   y += lineHeight;
   
   // Mode switches
   CreateLabel(panelPrefix + "SwitchLabel", x, y, "Switches:", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "SwitchCount", x + 80, y, "0", clrWhite, 9, "Arial");
   y += lineHeight + 5;
   
   // Buttons
   CreateButton(panelPrefix + "BtnClose", x, y, 60, 30, "CLOSE", clrRed, clrWhite);
   CreateButton(panelPrefix + "BtnPause", x + 70, y, 60, 30, "PAUSE", clrOrange, clrWhite);
   CreateButton(panelPrefix + "BtnTP", x + 140, y, 60, 30, "TP", clrGreen, clrWhite);
   CreateButton(panelPrefix + "BtnMode", x + 210, y, 80, 30, "MODE", clrDodgerBlue, clrWhite);
   y += 40;
   
   // Footer
   CreateLabel(panelPrefix + "Footer", x + 50, y, "© TORAMA CAPITAL", clrGold, 8, "Arial");
   CreateLabel(panelPrefix + "Website", x + 50, y + 15, "ca.torama.money", clrGray, 7, "Arial");
}

//+------------------------------------------------------------------+
//| DELETE PANEL                                                      |
//+------------------------------------------------------------------+
void DeletePanel()
{
   ObjectsDeleteAll(0, panelPrefix);
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Status
   color statusColor = emergencyStop ? clrRed : (isPaused ? clrOrange : clrLimeGreen);
   string statusText = emergencyStop ? "STOPPED" : (isPaused ? "PAUSED" : "ACTIVE");
   ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, statusText);
   ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, statusColor);
   
   // Mode
   string modeText = (CurrentDirection == BUYONLY) ? "BUY" : "SELL";
   color modeColor = (CurrentDirection == BUYONLY) ? clrDodgerBlue : clrOrangeRed;
   ObjectSetString(0, panelPrefix + "Mode", OBJPROP_TEXT, modeText);
   ObjectSetInteger(0, panelPrefix + "Mode", OBJPROP_COLOR, modeColor);
   
   // Price
   ObjectSetString(0, panelPrefix + "Price", OBJPROP_TEXT, "$" + DoubleToString((ask + bid) / 2.0, specs.digits));
   
   // Grid
   ObjectSetString(0, panelPrefix + "Grid", OBJPROP_TEXT,
                   DoubleToString(GridGapPercent, 2) + "% ($" + DoubleToString(currentGapSize, specs.digits) + ")");
   
   // Spread
   int spread = (int)((ask - bid) / specs.point);
   color spreadColor = (spread <= MaxSpread) ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "Spread", OBJPROP_TEXT,
                   IntegerToString(spread) + "/" + IntegerToString(MaxSpread));
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_COLOR, spreadColor);
   
   // Reference
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, "$" + DoubleToString(referencePrice, specs.digits));
   
   // EA Positions
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT,
                   IntegerToString(ArraySize(positions)) + "/" + IntegerToString(MaxPositions));
   
   // Account-wide BUY/SELL LOTS (all positions regardless of magic number)
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
            // Convert volume to actual lots for display
            double actualLots = ConvertVolumeToLots(volume);
            
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY)
               totalBuyLots += actualLots;
            else
               totalSellLots += actualLots;
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
                   (totalProfit >= 0 ? "+" : "") + "$" + DoubleToString(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "PnL", OBJPROP_COLOR, pnlColor);
   
   // Equity
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT, "$" + DoubleToString(equity, 2));
   
   // Drawdown
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   color ddColor = (dd >= -5) ? clrLimeGreen : (dd >= -10) ? clrYellow : clrRed;
   ObjectSetString(0, panelPrefix + "DD", OBJPROP_TEXT, DoubleToString(dd, 1) + "%");
   ObjectSetInteger(0, panelPrefix + "DD", OBJPROP_COLOR, ddColor);
   
   // Daily Profit
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - dailyStartBalance;
   
   color dailyColor = (dailyProfit >= dailyTarget) ? clrGold : 
                      (dailyProfit >= 0) ? clrLimeGreen : clrRed;
   
   ObjectSetString(0, panelPrefix + "DailyProfit", OBJPROP_TEXT,
                   (dailyProfit >= 0 ? "+" : "") + "$" + DoubleToString(dailyProfit, 2));
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
//| FORMAT PRICE                                                      |
//+------------------------------------------------------------------+
string FormatPrice(double price, int digits)
{
   return DoubleToString(price, digits);
}
//+------------------------------------------------------------------+
