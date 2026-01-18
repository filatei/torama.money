//+------------------------------------------------------------------+
//|                    TORAMA Aggressive Trader EA v6.0.0            |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "6.01"
#property description "Aggressive Directional Grid Trader"
#property description "Trades in chosen direction (BUY, SELL, or BOTH) at every grid level"
#property description "Replaces closed positions automatically"
#property description ""
#property description "V6.0.1: Added market trend display on panel (UP/DOWN/RANGING)"

#define EA_VERSION "6.0.1"
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

input group "=== DIRECTION ==="
input ENUM_TRADE_DIRECTION StartDirection = BUYONLY;  // Trading Direction (BUY, SELL, or BOTH)

input group "=== GRID SETTINGS ==="
input double   GridGapPercent = 0.05;                 // Grid gap % (0.01 = tight, 0.3 = wide)
input int      MaxPositions = 100;                    // Maximum positions
input double   LotSize = 0.1;                         // Lot size per position

input group "=== TAKE PROFIT ==="
input double   IndividualTPDollars = 50.0;            // Individual TP target ($50 per position)
input double   GroupTPDollars = 200.0;                // Group TP target ($200 total profit closes all)
input double   IndividualSLDollars = 0.0;             // SL risk per trade ($100 max loss, 0 = disabled)

input group "=== RISK MANAGEMENT ==="
input double   MaxDrawdownPercent = 50.0;             // Max drawdown % (SACROSANCT - based on starting balance)
input double   DailyTargetPercent = 300.0;            // Daily profit target (% of start balance)

input group "=== SETTINGS ==="
input int      MagicNumber = 777811;                  // Magic number for order identification
input int      MaxSpread = 2000;                      // Maximum spread (points)
input bool     ShowPanel = true;                      // Show info panel
input bool     EnableTimeFilter = false;              // Enable time-based trading filter
input int      TradingStartHour = 6;                  // Trading start hour (0-23, WAT)
input int      TradingStartMinute = 0;                // Trading start minute (0-59)
input int      TradingEndHour = 17;                   // Trading end hour (0-23, WAT)
input int      TradingEndMinute = 0;                  // Trading end minute (0-59)

input group "=== TREND DISPLAY ==="
input ENUM_TIMEFRAMES TrendTimeframe = PERIOD_H1;     // Timeframe for trend detection
input int      TrendMAPeriod = 20;                    // MA period for trend
input double   TrendThreshold = 0.1;                  // Trend threshold % (below = ranging)

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
   Print("📏 Grid Gap: $", DoubleToString(currentGapSize, specs.digits), " (", DoubleToString(GridGapPercent, 3), "%)");
   
   // ═══════════════════════════════════════════════════════════════
   // SACROSANCT MAX DRAWDOWN INITIALIZATION
   // ═══════════════════════════════════════════════════════════════
   startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   maxDrawdownStopLevel = startingBalance * (1.0 - MaxDrawdownPercent / 100.0);
   
   Print("═══════════════════════════════════════");
   Print("🛡️ SACROSANCT MAX DRAWDOWN:");
   Print("   Starting Balance: $", DoubleToString(startingBalance, 2), " (LOCKED)");
   Print("   Max Drawdown: ", DoubleToString(MaxDrawdownPercent, 1), "% (LOCKED)");
   Print("   Emergency Stop @ Equity: $", DoubleToString(maxDrawdownStopLevel, 2), " (LOCKED)");
   Print("   Current Equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(currentEquity <= maxDrawdownStopLevel)
   {
      Print("   ⚠️ CRITICAL: Current equity already at/below stop level!");
      Print("   EA will trigger emergency stop immediately");
   }
   else
   {
      double safetyBuffer = currentEquity - maxDrawdownStopLevel;
      double bufferPercent = (safetyBuffer / startingBalance) * 100.0;
      Print("   Safety Buffer: $", DoubleToString(safetyBuffer, 2), " (", DoubleToString(bufferPercent, 1), "%)");
   }
   Print("   ⚠️ These values are PERMANENT and will NOT change");
   Print("   ⚠️ Once equity hits $", DoubleToString(maxDrawdownStopLevel, 2), " → ALL positions closed + EA paused");
   
   // Daily target setup
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyTarget = dailyStartBalance * DailyTargetPercent / 100.0;
   Print("═══════════════════════════════════════");
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
   Print("   BUY ONLY: Buys at every grid level");
   Print("   SELL ONLY: Sells at every grid level");
   Print("   BOTH: Places BUY + SELL at every grid level");
   Print("   Manual mode switch: Press MODE button (cycles through)");
   Print("═══════════════════════════════════════");
   Print("⌨️ KEYBOARD SHORTCUTS:");
   Print("   Press 'D' - Full debug status report");
   Print("   Press 'S' - Sync positions & show tracking");
   Print("   Press 'G' - Grid check diagnostics");
   Print("   Press 'H' - Hide/show panel");
   Print("═══════════════════════════════════════");
   
   // Create panel
   if(ShowPanel) CreatePanel();
   
   // Sync existing positions
   Print("═══════════════════════════════════════");
   Print("🔍 SYNCING EXISTING POSITIONS:");
   Print("   Symbol: ", _Symbol);
   Print("   Magic Number: ", MagicNumber);
   Print("   Total Open Positions (All): ", PositionsTotal());
   
   // Check all positions
   int matchingPositions = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetTicket(i) > 0)
      {
         string posSymbol = PositionGetString(POSITION_SYMBOL);
         long posMagic = PositionGetInteger(POSITION_MAGIC);
         
         if(posSymbol == _Symbol)
         {
            Print("   Position #", i, ": Ticket=", PositionGetTicket(i), 
                  " Symbol=", posSymbol, " Magic=", posMagic);
            
            if(posMagic == MagicNumber)
            {
               matchingPositions++;
               Print("      ✅ MATCHES (will be tracked)");
            }
            else
            {
               Print("      ⚠️ Different magic (", posMagic, " vs ", MagicNumber, ")");
            }
         }
      }
   }
   
   SyncPositions();
   
   Print("   Result: ", ArraySize(positions), " position(s) synced");
   if(ArraySize(positions) > 0)
   {
      Print("   These positions will be managed by the EA");
      for(int i = 0; i < ArraySize(positions); i++)
      {
         if(PositionSelectByTicket(positions[i].ticket))
         {
            Print("      #", i+1, ": Ticket ", positions[i].ticket, 
                  " | Entry: $", DoubleToString(positions[i].entryPrice, specs.digits),
                  " | Type: ", PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL",
                  " | P/L: $", DoubleToString(PositionGetDouble(POSITION_PROFIT), 2));
         }
      }
   }
   else
   {
      Print("   No existing positions to manage");
   }
   Print("═══════════════════════════════════════");
   
   // Initialize trend indicator
   trendMAHandle = iMA(_Symbol, TrendTimeframe, TrendMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(trendMAHandle == INVALID_HANDLE)
   {
      Print("⚠️ WARNING: Could not create MA indicator for trend display");
   }
   else
   {
      Print("📊 Trend Detection: MA(", TrendMAPeriod, ") on ", EnumToString(TrendTimeframe));
   }
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| CHECK IF WITHIN TRADING HOURS (WAT timezone)                    |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
   if(!EnableTimeFilter) return true;  // Time filter disabled, always allow trading
   
   MqlDateTime currentTime;
   TimeToStruct(TimeCurrent(), currentTime);
   
   // Convert current time to minutes since midnight
   int currentMinutes = currentTime.hour * 60 + currentTime.min;
   int startMinutes = TradingStartHour * 60 + TradingStartMinute;
   int endMinutes = TradingEndHour * 60 + TradingEndMinute;
   
   // Handle cases where trading hours span midnight
   if(endMinutes <= startMinutes)
   {
      // Trading window crosses midnight (e.g., start = 22:00, end = 06:00)
      return (currentMinutes >= startMinutes || currentMinutes < endMinutes);
   }
   else
   {
      // Normal session (e.g., start = 06:00, end = 17:00)
      return (currentMinutes >= startMinutes && currentMinutes < endMinutes);
   }
}

//+------------------------------------------------------------------+
//| DETECT MARKET TREND                                               |
//+------------------------------------------------------------------+
string DetectTrend()
{
   if(trendMAHandle == INVALID_HANDLE) return "---";
   
   double maValues[];
   ArraySetAsSeries(maValues, true);
   
   // Get last 3 MA values
   if(CopyBuffer(trendMAHandle, 0, 0, 3, maValues) < 3) return "---";
   
   // Get current price
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(currentPrice <= 0) return "---";
   
   // Calculate price distance from MA as percentage
   double maDistance = ((currentPrice - maValues[0]) / maValues[0]) * 100.0;
   
   // Check MA slope (recent vs older)
   double maSlope = ((maValues[0] - maValues[2]) / maValues[2]) * 100.0;
   
   // Determine trend
   if(MathAbs(maDistance) < TrendThreshold && MathAbs(maSlope) < TrendThreshold * 0.5)
   {
      return "RANGING";
   }
   else if(currentPrice > maValues[0] && maSlope > 0)
   {
      return "UP ▲";
   }
   else if(currentPrice < maValues[0] && maSlope < 0)
   {
      return "DOWN ▼";
   }
   else if(currentPrice > maValues[0])
   {
      return "UP ▲";
   }
   else
   {
      return "DOWN ▼";
   }
}

//+------------------------------------------------------------------+
//| CHECK SACROSANCT MAX DRAWDOWN                                    |
//+------------------------------------------------------------------+
void CheckMaxDrawdown()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Check against the SACROSANCT stop level (locked at OnInit)
   if(currentEquity <= maxDrawdownStopLevel)
   {
      emergencyStop = true;
      emergencyReason = StringFormat("Equity ($%.2f) hit SACROSANCT max DD stop ($%.2f)", 
                                     currentEquity, maxDrawdownStopLevel);
      
      Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      Print("🚨 EMERGENCY STOP - MAX DRAWDOWN REACHED!");
      Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      Print("   Current Equity: $", DoubleToString(currentEquity, 2));
      Print("   SACROSANCT Stop: $", DoubleToString(maxDrawdownStopLevel, 2));
      Print("   Starting Balance: $", DoubleToString(startingBalance, 2));
      Print("   Max DD %: ", DoubleToString(MaxDrawdownPercent, 1), "%");
      Print("   ");
      Print("   ⚠️ THIS STOP LEVEL IS PERMANENT");
      Print("   ⚠️ It was locked at EA initialization");
      Print("   ⚠️ It will NEVER change, even with profits");
      Print("   ");
      Print("   🔴 CLOSING ALL POSITIONS...");
      
      CloseAllPositions();
      
      Print("   ✅ All positions closed");
      Print("   ⏸️ EA will remain paused");
      Print("   ℹ️ Press RESUME to manually restart");
      Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      
      UpdatePanel();
   }
}

//+------------------------------------------------------------------+
//| SWITCH TRADING MODE (MANUAL ONLY)                                |
//+------------------------------------------------------------------+
void SwitchTradingMode(ENUM_TRADE_DIRECTION newDirection)
{
   if(newDirection == CurrentDirection)
   {
      string modeName = "";
      if(CurrentDirection == BOTH) modeName = "BOTH";
      else if(CurrentDirection == BUYONLY) modeName = "BUY ONLY";
      else modeName = "SELL ONLY";
      
      Print("ℹ️ Mode is already ", modeName);
      return;
   }
   
   ENUM_TRADE_DIRECTION oldDirection = CurrentDirection;
   CurrentDirection = newDirection;
   modeSwitchCount++;
   
   string oldDirectionText = "";
   string newDirectionText = "";
   
   if(oldDirection == BOTH) oldDirectionText = "BOTH";
   else if(oldDirection == BUYONLY) oldDirectionText = "BUY ONLY";
   else oldDirectionText = "SELL ONLY";
   
   if(newDirection == BOTH) newDirectionText = "BOTH";
   else if(newDirection == BUYONLY) newDirectionText = "BUY ONLY";
   else newDirectionText = "SELL ONLY";
   
   Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
   Print("🔄 MODE SWITCH #", modeSwitchCount, " (Manual)");
   Print("   From: ", oldDirectionText);
   Print("   To: ", newDirectionText);
   
   // Log existing positions
   if(ArraySize(positions) > 0)
   {
      Print("   Existing ", ArraySize(positions), " position(s) will continue running");
      Print("   New positions will be ", newDirectionText);
   }
   else
   {
      Print("   No existing positions");
   }
   
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
      Print("   Protection: Emergency stop at ", DoubleToString(MaxDrawdownPercent, 1), "% of starting balance");
   }
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release trend indicator handle
   if(trendMAHandle != INVALID_HANDLE)
   {
      IndicatorRelease(trendMAHandle);
      trendMAHandle = INVALID_HANDLE;
   }
   
   ObjectsDeleteAll(0, panelPrefix);
   ChartRedraw();
   
   Print("═══════════════════════════════════════");
   Print("👋 ", EA_NAME, " stopped");
   Print("Total trades: ", totalTrades);
   Print("Mode switches: ", modeSwitchCount);
   
   if(emergencyStop)
   {
      Print("🚨 Emergency Stop: TRIGGERED");
      Print("   ", emergencyReason);
   }
   
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
   
   // Check spread FIRST before expensive calculations
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      UpdatePanel();
      return;
   }
   
   // Check if within trading hours
   if(!IsWithinTradingHours())
   {
      UpdatePanel();
      return;
   }
   
   // ═══════════════════════════════════════════════════════════════
   // CHECK SACROSANCT MAX DRAWDOWN (Priority check)
   // ═══════════════════════════════════════════════════════════════
   CheckMaxDrawdown();
   
   
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
   double triggerPercent = 0.15;  // Default 15% of gap
   
   if(currentPrice > 10000)
      triggerPercent = 0.10;  // 10% for high-value symbols (e.g., BTC $90k)
   else if(currentPrice > 1000)
      triggerPercent = 0.12;  // 12% for medium-value (e.g., Gold $4600)
   
   double triggerZone = currentGapSize * triggerPercent;
   
   // Grid debug logging (every 60 seconds)
   static datetime lastGridDebug = 0;
   if(TimeCurrent() - lastGridDebug >= 60)
   {
      lastGridDebug = TimeCurrent();
      Print("╔═══════════════════════════════════════════════════════════╗");
      Print("║ GRID STATUS                                               ║");
      Print("╠═══════════════════════════════════════════════════════════╣");
      Print("   Current Price:        $", DoubleToString(currentPrice, specs.digits));
      Print("   Reference Price:      $", DoubleToString(referencePrice, specs.digits));
      Print("   Grid Gap:             $", DoubleToString(currentGapSize, specs.digits), " (", DoubleToString(GridGapPercent, 3), "%)");
      Print("   Nearest Grid Level:   $", DoubleToString(nearestGridLevel, specs.digits), " (Level #", levelIndex, ")");
      Print("   Distance to Level:    $", DoubleToString(distanceToNearestLevel, specs.digits));
      Print("   Trigger Zone:         $", DoubleToString(triggerZone, specs.digits), " (", DoubleToString(triggerPercent * 100, 0), "% of gap)");
      
      if(distanceToNearestLevel <= triggerZone)
      {
         Print("   Status:               ✅ WITHIN TRIGGER ZONE");
         
         string directionText;
         if(CurrentDirection == BOTH)
            directionText = "BOTH (BUY + SELL)";
         else if(CurrentDirection == BUYONLY)
            directionText = "BUY ONLY";
         else
            directionText = "SELL ONLY";
         
         Print("   Direction:            ", directionText);
         
         // Check for existing positions at this level
         int buyPositionsAtLevel = 0;
         int sellPositionsAtLevel = 0;
         double minDistanceBetweenPositions = currentGapSize * 0.8;
         
         for(int i = 0; i < ArraySize(positions); i++)
         {
            double distToExisting = MathAbs(positions[i].entryPrice - nearestGridLevel);
            if(distToExisting < minDistanceBetweenPositions)
            {
               if(positions[i].posType == POSITION_TYPE_BUY)
                  buyPositionsAtLevel++;
               else
                  sellPositionsAtLevel++;
            }
         }
         
         if(buyPositionsAtLevel > 0 || sellPositionsAtLevel > 0)
         {
            Print("   Level Occupancy:      BUY:", buyPositionsAtLevel, " SELL:", sellPositionsAtLevel);
         }
         else
         {
            Print("   Level Status:         EMPTY - Ready to trade");
         }
      }
      else
      {
         double percentAway = (distanceToNearestLevel / currentGapSize) * 100.0;
         Print("   Status:               ⏸ Outside trigger zone");
         Print("   Distance:             ", DoubleToString(percentAway, 1), "% of gap away");
      }
      
      Print("   EA Positions:         ", ArraySize(positions), "/", MaxPositions);
      Print("╚═══════════════════════════════════════════════════════════╝");
   }
   
   // Only trigger if close to grid level
   if(distanceToNearestLevel > triggerZone)
      return;
   
   // Check if position exists near this level (by type for BOTH mode)
   double minDistanceBetweenPositions = currentGapSize * 0.8;
   
   bool hasBuyAtLevel = false;
   bool hasSellAtLevel = false;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      double distToExistingPosition = MathAbs(positions[i].entryPrice - nearestGridLevel);
      
      if(distToExistingPosition < minDistanceBetweenPositions)
      {
         if(positions[i].posType == POSITION_TYPE_BUY)
            hasBuyAtLevel = true;
         else if(positions[i].posType == POSITION_TYPE_SELL)
            hasSellAtLevel = true;
      }
   }
   
   // ═══════════════════════════════════════════════════════════════
   // TRADING LOGIC BASED ON DIRECTION MODE
   // ═══════════════════════════════════════════════════════════════
   
   if(CurrentDirection == BOTH)
   {
      // BOTH MODE: Place BUY and SELL at every level
      
      // Try to open BUY if not already there
      if(!hasBuyAtLevel && ArraySize(positions) < MaxPositions)
      {
         Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
         Print("⚡ GRID TRIGGER [BOTH MODE]: Opening BUY position");
         Print("   Grid Level:    $", DoubleToString(nearestGridLevel, specs.digits));
         Print("   Current Price: $", DoubleToString(currentPrice, specs.digits));
         
         if(OpenPosition(ORDER_TYPE_BUY, ask, nearestGridLevel))
         {
            Print("   ✅ BUY position opened successfully");
         }
         else
         {
            Print("   ❌ Failed to open BUY position");
         }
         Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      }
      
      // Try to open SELL if not already there
      if(!hasSellAtLevel && ArraySize(positions) < MaxPositions)
      {
         Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
         Print("⚡ GRID TRIGGER [BOTH MODE]: Opening SELL position");
         Print("   Grid Level:    $", DoubleToString(nearestGridLevel, specs.digits));
         Print("   Current Price: $", DoubleToString(currentPrice, specs.digits));
         
         if(OpenPosition(ORDER_TYPE_SELL, bid, nearestGridLevel))
         {
            Print("   ✅ SELL position opened successfully");
         }
         else
         {
            Print("   ❌ Failed to open SELL position");
         }
         Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      }
   }
   else if(CurrentDirection == BUYONLY)
   {
      // BUY ONLY MODE: Only place BUY positions
      if(!hasBuyAtLevel && ArraySize(positions) < MaxPositions)
      {
         Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
         Print("⚡ GRID TRIGGER: Opening BUY position");
         Print("   Grid Level:    $", DoubleToString(nearestGridLevel, specs.digits));
         Print("   Current Price: $", DoubleToString(currentPrice, specs.digits));
         
         if(OpenPosition(ORDER_TYPE_BUY, ask, nearestGridLevel))
         {
            Print("   ✅ BUY position opened successfully");
         }
         else
         {
            Print("   ❌ Failed to open position");
         }
         Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      }
   }
   else if(CurrentDirection == SELLONLY)
   {
      // SELL ONLY MODE: Only place SELL positions
      if(!hasSellAtLevel && ArraySize(positions) < MaxPositions)
      {
         Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
         Print("⚡ GRID TRIGGER: Opening SELL position");
         Print("   Grid Level:    $", DoubleToString(nearestGridLevel, specs.digits));
         Print("   Current Price: $", DoubleToString(currentPrice, specs.digits));
         
         if(OpenPosition(ORDER_TYPE_SELL, bid, nearestGridLevel))
         {
            Print("   ✅ SELL position opened successfully");
         }
         else
         {
            Print("   ❌ Failed to open position");
         }
         Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      }
   }
}

//+------------------------------------------------------------------+
//| SYNC POSITIONS                                                    |
//+------------------------------------------------------------------+
void SyncPositions()
{
   ArrayResize(positions, 0);
   int syncCount = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetTicket(i) > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            Position pos;
            pos.ticket = PositionGetTicket(i);
            pos.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            pos.entryTime = (datetime)PositionGetInteger(POSITION_TIME);
            pos.posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            int size = ArraySize(positions);
            ArrayResize(positions, size + 1);
            positions[size] = pos;
            syncCount++;
         }
      }
   }
   
   // Debug logging every 60 seconds
   static datetime lastSyncDebug = 0;
   if(TimeCurrent() - lastSyncDebug >= 60 && syncCount > 0)
   {
      lastSyncDebug = TimeCurrent();
      Print("📊 SYNC: Found ", syncCount, " EA positions (Magic: ", MagicNumber, ")");
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                            |
//+------------------------------------------------------------------+
double CalculateTotalProfit()
{
   double profit = 0;
   int validPositions = 0;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         double posProfit = PositionGetDouble(POSITION_PROFIT);
         profit += posProfit;
         validPositions++;
      }
   }
   
   totalProfit = profit;
   
   // Debug output every 60 seconds
   static datetime lastProfitDebug = 0;
   if(TimeCurrent() - lastProfitDebug >= 60 && ArraySize(positions) > 0)
   {
      lastProfitDebug = TimeCurrent();
      Print("💰 PROFIT CALC: Positions tracked: ", ArraySize(positions), 
            " | Valid: ", validPositions, " | Total P/L: $", DoubleToString(profit, 2));
   }
   
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
   
   // ============================================================================
   // FIXED TP/SL CALCULATION (v5.6.2)
   // ============================================================================
   // Calculate tick value for this specific position
   double tickValueForPosition = specs.tickValue * validatedLotSize;
   
   Print("   Tick Value/Position: $", DoubleToString(tickValueForPosition, 4), " per tick");
   
   // Set TP based on dollar target
   if(IndividualTPDollars > 0)
   {
      // CORRECT FORMULA: Calculate ticks needed, then convert to price distance
      // Ticks needed = Target$ / TickValue per position
      // Price distance = Ticks × TickSize
      double ticksNeeded = IndividualTPDollars / tickValueForPosition;
      double tpDistance = ticksNeeded * specs.tickSize;
      
      Print("   TP Target: $", DoubleToString(IndividualTPDollars, 2));
      Print("   Ticks Needed: ", DoubleToString(ticksNeeded, 2));
      Print("   TP Distance: $", DoubleToString(tpDistance, specs.digits), " (", DoubleToString((tpDistance/price)*100, 3), "%)");
      
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
      double verifyTicks = tpDistance / specs.tickSize;
      double expectedProfit = verifyTicks * tickValueForPosition;
      Print("   Verified TP Profit: $", DoubleToString(expectedProfit, 2));
      
      if(MathAbs(expectedProfit - IndividualTPDollars) > 0.5)
      {
         Print("   ⚠️ WARNING: Verification mismatch! Expected $", DoubleToString(IndividualTPDollars, 2),
               " but calculated $", DoubleToString(expectedProfit, 2));
      }
   }
   
   // Set SL based on dollar risk
   if(IndividualSLDollars > 0)
   {
      // CORRECT FORMULA: Calculate ticks needed, then convert to price distance
      double ticksNeeded = IndividualSLDollars / tickValueForPosition;
      double slDistance = ticksNeeded * specs.tickSize;
      
      Print("   SL Risk Target: $", DoubleToString(IndividualSLDollars, 2));
      Print("   Ticks Needed: ", DoubleToString(ticksNeeded, 2));
      Print("   SL Distance: $", DoubleToString(slDistance, specs.digits), " (", DoubleToString((slDistance/price)*100, 3), "%)");
      
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
      double verifyTicks = slDistance / specs.tickSize;
      double expectedLoss = verifyTicks * tickValueForPosition;
      Print("   Verified SL Risk: $", DoubleToString(expectedLoss, 2));
      
      if(MathAbs(expectedLoss - IndividualSLDollars) > 0.5)
      {
         Print("   ⚠️ WARNING: Verification mismatch! Expected $", DoubleToString(IndividualSLDollars, 2),
               " but calculated $", DoubleToString(expectedLoss, 2));
      }
      
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
   
   // Calculate drawdown from STARTING BALANCE (SACROSANCT)
   double currentDD = 0;
   if(startingBalance > 0)
   {
      currentDD = ((equity - startingBalance) / startingBalance) * 100.0;
   }
   
   Print("╔══════════════════════════════════════════════════════════════╗");
   Print("║ ", EA_NAME, " v", EA_VERSION, "                              ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ MODE STATUS                                            ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Current Mode:          ", CurrentDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   Print("Mode Switches:         ", modeSwitchCount);
   
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
   Print("║ SACROSANCT MAX DRAWDOWN                                      ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Starting Balance:      $", DoubleToString(startingBalance, 2), " (LOCKED)");
   Print("Max DD Allowed:        ", DoubleToString(MaxDrawdownPercent, 1), "% (LOCKED)");
   Print("Emergency Stop @:      $", DoubleToString(maxDrawdownStopLevel, 2), " (LOCKED)");
   Print("Current Equity:        $", DoubleToString(equity, 2));
   Print("Current DD:            ", DoubleToString(currentDD, 2), "%");
   
   double bufferToStop = equity - maxDrawdownStopLevel;
   Print("Buffer to Stop:        $", DoubleToString(bufferToStop, 2));
   
   if(emergencyStop)
   {
      Print("Status:                🚨 EMERGENCY STOP ACTIVE");
   }
   else if(bufferToStop < startingBalance * 0.10)
   {
      Print("Status:                ⚠️ APPROACHING STOP LEVEL");
   }
   else
   {
      Print("Status:                ✅ Safe");
   }
   
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ PROFIT & RISK                                                ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Floating P/L:          $", DoubleToString(totalProfit, 2));
   Print("Balance:               $", DoubleToString(balance, 2));
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
      // S key - sync positions and show status
      else if(lparam == 83 || lparam == 115)
      {
         Print("═══════════════════════════════════════");
         Print("🔄 MANUAL SYNC TRIGGERED");
         Print("   Total positions in account: ", PositionsTotal());
         
         // Show all positions
         for(int i = 0; i < PositionsTotal(); i++)
         {
            if(PositionGetTicket(i) > 0)
            {
               string posSymbol = PositionGetString(POSITION_SYMBOL);
               long posMagic = PositionGetInteger(POSITION_MAGIC);
               ulong ticket = PositionGetTicket(i);
               double profit = PositionGetDouble(POSITION_PROFIT);
               
               Print("   #", i+1, ": Ticket=", ticket, 
                     " Symbol=", posSymbol, 
                     " Magic=", posMagic,
                     " P/L=$", DoubleToString(profit, 2));
            }
         }
         
         SyncPositions();
         CalculateTotalProfit();
         
         Print("   EA tracking ", ArraySize(positions), " position(s) with magic ", MagicNumber);
         Print("   Total P/L: $", DoubleToString(totalProfit, 2));
         Print("═══════════════════════════════════════");
         
         UpdatePanel();
      }
      // G key - force grid check with detailed diagnostics
      else if(lparam == 71 || lparam == 103)
      {
         Print("═══════════════════════════════════════");
         Print("🎯 MANUAL GRID CHECK TRIGGERED");
         
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double currentPrice = (ask + bid) / 2.0;
         
         double distanceFromReference = currentPrice - referencePrice;
         int levelIndex = (int)MathRound(distanceFromReference / currentGapSize);
         double nearestGridLevel = referencePrice + (levelIndex * currentGapSize);
         double distanceToNearestLevel = MathAbs(currentPrice - nearestGridLevel);
         
         double triggerPercent = 0.15;
         if(currentPrice > 10000) triggerPercent = 0.10;
         else if(currentPrice > 1000) triggerPercent = 0.12;
         
         double triggerZone = currentGapSize * triggerPercent;
         
         Print("   Current Price:      $", DoubleToString(currentPrice, specs.digits));
         Print("   Reference:          $", DoubleToString(referencePrice, specs.digits));
         Print("   Grid Gap:           $", DoubleToString(currentGapSize, specs.digits));
         Print("   Nearest Level:      $", DoubleToString(nearestGridLevel, specs.digits), " (#", levelIndex, ")");
         Print("   Distance to Level:  $", DoubleToString(distanceToNearestLevel, specs.digits));
         Print("   Trigger Zone:       $", DoubleToString(triggerZone, specs.digits));
         Print("   Within Zone?        ", distanceToNearestLevel <= triggerZone ? "✅ YES" : "❌ NO");
         Print("   Direction:          ", CurrentDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
         Print("   EA Positions:       ", ArraySize(positions), "/", MaxPositions);
         
         if(distanceToNearestLevel <= triggerZone)
         {
            // Check for existing position
            bool hasPosition = false;
            double minDist = currentGapSize * 0.8;
            
            for(int i = 0; i < ArraySize(positions); i++)
            {
               double dist = MathAbs(positions[i].entryPrice - nearestGridLevel);
               if(dist < minDist)
               {
                  hasPosition = true;
                  Print("   Level Status:       OCCUPIED by ticket #", positions[i].ticket);
                  break;
               }
            }
            
            if(!hasPosition)
            {
               Print("   Level Status:       EMPTY ✅");
               Print("   → Would open ", CurrentDirection == BUYONLY ? "BUY" : "SELL", " position here");
            }
         }
         else
         {
            double percentAway = (distanceToNearestLevel / currentGapSize) * 100.0;
            Print("   Status:             Price is ", DoubleToString(percentAway, 1), "% of gap away from level");
            Print("   → Must move $", DoubleToString(distanceToNearestLevel - triggerZone, specs.digits), " closer to trigger");
         }
         
         Print("═══════════════════════════════════════");
         
         // Force a grid check
         CheckGrid();
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
         
         // If emergency stop is active, allow resume
         if(emergencyStop)
         {
            emergencyStop = false;
            emergencyReason = "";
            isPaused = false;
            Print("▶️ EA RESUMED - Emergency stop cleared");
            Print("⚠️ WARNING: Max drawdown protection still active");
            Print("   Stop level: $", DoubleToString(maxDrawdownStopLevel, 2));
         }
         else
         {
            isPaused = !isPaused;
            Print(isPaused ? "⏸️ EA PAUSED" : "▶️ EA RESUMED");
         }
      }
      // TAKE TP button
      else if(sparam == panelPrefix + "TPBtn")
      {
         ObjectSetInteger(0, panelPrefix + "TPBtn", OBJPROP_STATE, false);
         Print("💰 TAKE TP button pressed - Closing profitable positions...");
         CloseProfitablePositions();
         Print("✅ Profitable positions closed");
      }
      // SWITCH MODE button
      else if(sparam == panelPrefix + "SwitchBtn")
      {
         ObjectSetInteger(0, panelPrefix + "SwitchBtn", OBJPROP_STATE, false);
         
         // Cycle through modes: BUY → SELL → BOTH → BUY
         ENUM_TRADE_DIRECTION newDirection;
         if(CurrentDirection == BUYONLY)
            newDirection = SELLONLY;
         else if(CurrentDirection == SELLONLY)
            newDirection = BOTH;
         else
            newDirection = BUYONLY;
         
         SwitchTradingMode(newDirection);
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
      "ReversalLabel", "ReversalSell", "ReversalLabel2", "ReversalBuy",
      "RefLabel", "RefPrice",
      "TimeLabel", "TimeStatus", "TimeAllowed",
      "PosLabel", "Positions",
      "AccLabel", "AccCounts",
      "PnLLabel", "PnL",
      "EquityLabel", "Equity",
      "StartCapLabel", "StartCap",
      "DDLabel", "DD",
      "DailyLabel", "DailyProfit",
      "DDTriggerLabel", "DDTrigger",
      "SwitchCountLabel", "SwitchCount",
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
   int width = 320;
   int lineHeight = 22;
   
   // Calculate dynamic height
   int panelHeight = 380;
   if(EnableTimeFilter) panelHeight += lineHeight;
   
   // Background with dynamic height
   ObjectCreate(0, panelPrefix + "Background", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YSIZE, panelHeight);
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
   CreateButton(panelPrefix + "SwitchBtn", x + 210, yPos, 55, 26, "MODE", clrDodgerBlue, clrWhite);
   yPos += 34;
   
   // === MODE ROW ===
   color dirColor = clrWhite;
   string dirText = "";
   if(CurrentDirection == BOTH)
   {
      dirColor = clrYellow;
      dirText = "BOTH";
   }
   else if(CurrentDirection == BUYONLY)
   {
      dirColor = clrDodgerBlue;
      dirText = "BUY";
   }
   else
   {
      dirColor = clrOrangeRed;
      dirText = "SELL";
   }
   
   CreateLabel(panelPrefix + "DirectionLabel", x + 10, yPos, "Mode:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Direction", x + 65, yPos, dirText, dirColor, 10, "Arial Black");
   
   // Add Trend on same row (right side)
   CreateLabel(panelPrefix + "TrendLabel", x + 140, yPos, "Trend:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Trend", x + 190, yPos, "---", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // === TIME STATUS ROW (if time filter enabled) ===
   if(EnableTimeFilter)
   {
      CreateLabel(panelPrefix + "TimeLabel", x + 10, yPos, "Time:", clrGold, 9, "Arial Bold");
      CreateLabel(panelPrefix + "TimeStatus", x + 65, yPos, "00:00", clrWhite, 9, "Arial");
      CreateLabel(panelPrefix + "TimeAllowed", x + 150, yPos, "⏸ PAUSED", clrYellow, 9, "Arial Bold");
      yPos += lineHeight;
   }
   
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
   
   
   // === REFERENCE ROW ===
   CreateLabel(panelPrefix + "RefLabel", x + 10, yPos, "Reference:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "RefPrice", x + 95, yPos, "$0", clrWhite, 9, "Arial");
   yPos += lineHeight + 4;
   
   // === EA POSITIONS ROW ===
   CreateLabel(panelPrefix + "PosLabel", x + 10, yPos, "⚡EA:", clrGold, 9, "Arial Black");
   CreateLabel(panelPrefix + "Positions", x + 60, yPos, "0/100", clrWhite, 10, "Arial Black");
   yPos += lineHeight;
   
   // === ACCOUNT POSITIONS ROW ===
   CreateLabel(panelPrefix + "AccLabel", x + 10, yPos, "Acc:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "AccCounts", x + 60, yPos, "B:0.00 S:0.00 (0)", clrWhite, 9, "Arial Bold");  // Made bold for net position
   yPos += lineHeight + 4;
   
   // === P/L ROW ===
   CreateLabel(panelPrefix + "PnLLabel", x + 10, yPos, "P/L:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "PnL", x + 60, yPos, "$0", clrWhite, 11, "Arial Black");
   yPos += lineHeight;
   
   // === EQUITY ROW ===
   CreateLabel(panelPrefix + "EquityLabel", x + 10, yPos, "Equity:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Equity", x + 70, yPos, "$0", clrWhite, 9, "Arial");
   yPos += lineHeight;
   
   // === STARTING CAPITAL ROW ===
   CreateLabel(panelPrefix + "StartCapLabel", x + 10, yPos, "Start:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "StartCap", x + 70, yPos, "$0", clrLimeGreen, 9, "Arial Black");  // Bold
   yPos += lineHeight;
   
   // === DRAWDOWN ROW ===
   CreateLabel(panelPrefix + "DDLabel", x + 10, yPos, "DD:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DD", x + 60, yPos, "0%", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "DailyLabel", x + 170, yPos, "Daily:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DailyProfit", x + 220, yPos, "$0", clrWhite, 9, "Arial");
   yPos += lineHeight;
   
   // === DD TRIGGER ROW (changed from price to equity level) ===
   CreateLabel(panelPrefix + "DDTriggerLabel", x + 10, yPos, "🛑 DD@:", clrOrangeRed, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DDTrigger", x + 70, yPos, "$0", clrOrangeRed, 9, "Arial Bold");
   yPos += lineHeight;
   
   // === SWITCHES ROW ===
   CreateLabel(panelPrefix + "SwitchCountLabel", x + 10, yPos, "Switches:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "SwitchCount", x + 90, yPos, "0", clrCyan, 9, "Arial");
   yPos += lineHeight + 15;
   
   // === BRANDING - Bottom Right Corner ===
   int brandY = y + panelHeight - 35;
   int brandX = x + width - 12;
   
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
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_COLOR, C'150,150,100');
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
//+------------------------------------------------------------------+
//| FORMAT NUMBER WITH COMMA THOUSANDS SEPARATOR                      |
//+------------------------------------------------------------------+
string FormatWithCommas(double value, int decimals = 2)
{
   string result = "";
   string valueStr = DoubleToString(MathAbs(value), decimals);
   
   // Split into integer and decimal parts
   int dotPos = StringFind(valueStr, ".");
   string intPart = "";
   string decPart = "";
   
   if(dotPos >= 0)
   {
      intPart = StringSubstr(valueStr, 0, dotPos);
      decPart = StringSubstr(valueStr, dotPos);
   }
   else
   {
      intPart = valueStr;
      decPart = "";
   }
   
   // Add commas to integer part (from right to left)
   int len = StringLen(intPart);
   for(int i = 0; i < len; i++)
   {
      if(i > 0 && (i % 3) == 0)
         result = "," + result;
      result = StringSubstr(intPart, len - i - 1, 1) + result;
   }
   
   // Add decimal part
   result = result + decPart;
   
   // Add negative sign if needed
   if(value < 0)
      result = "-" + result;
   
   return result;
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
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Status - prioritize emergency stop, then daily target
   if(emergencyStop)
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "🚨 DD.STOP");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrRed);
   }
   else if(dailyTargetReached)
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "🎯 TARGET");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrGold);
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
   
   // Pause button - show RESUME if emergency stop or paused
   if(emergencyStop || isPaused)
   {
      ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, "RESUME");
      ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, clrGreen);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, "PAUSE");
      ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, clrOrange);
   }
   
   // Direction - with position mix indicator
   color dirColor = clrWhite;
   string directionText = "";
   
   if(CurrentDirection == BOTH)
   {
      directionText = "BOTH";
      dirColor = clrYellow;
   }
   else if(CurrentDirection == BUYONLY)
   {
      directionText = "BUY";
      dirColor = clrDodgerBlue;
   }
   else
   {
      directionText = "SELL";
      dirColor = clrOrangeRed;
   }
   
   ObjectSetInteger(0, panelPrefix + "Direction", OBJPROP_COLOR, dirColor);
   
   // Update Trend display
   currentTrend = DetectTrend();
   color trendColor = clrWhite;
   if(StringFind(currentTrend, "UP") >= 0)
      trendColor = clrLimeGreen;
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
