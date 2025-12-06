//+------------------------------------------------------------------+
//|                  TORAMA Bitcoin Optimized EA v1.0                |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "1.20"
#property description "Bitcoin (BTCUSD) Optimized EA - CORRECT P&L CALCULATIONS"
#property description "Based on 69 days historical data | Uses OrderCalcProfit"
#property description "v1.1: PERMANENT STOP at max drawdown (requires manual restart)"
#property description "v1.2: FIXED - Direction buttons don't close opposite positions"

//--- EA Version (single source of truth)
#define EA_VERSION "1.2"
#define EA_NAME "BITCOIN GRID"

//--- Input Parameters
// input group "=== GRID SETTINGS ==="
input double   GridSpacingPercent = 0.30;  // OPTIMIZED: Moderate for BTC        // Grid spacing % (0.3-0.5 recommended)
input int      ReversalGaps = 5;  // OPTIMIZED: Wider confirmation for BTC                // Gaps to trigger reversal (3-4 recommended)
input int      MaxPositions = 50;               // Maximum positions per direction
input int      MaxSpread = 2000;                // Maximum spread in points (BTC ~1800)

// input group "=== POSITION MANAGEMENT ==="
input double   LotSize = 0.1;                  // Lot size per position
input int      MagicNumber = 77711;             // Magic number

// input group "=== PROFIT & RISK - INDIVIDUAL TP/SL (SACROSANCT!) ==="
input double   IndividualTPDollars = 50.0;  // OPTIMIZED: Covers spread + profit      // TP per position in dollars (SACROSANCT)
double   IndividualSLDollars = 5005.0;      // SL per position in dollars (SACROSANCT)
int      MaxConsecutiveSLs = 10;           // Max consecutive SLs before EA stops
input double   GlobalTPDollars = 500.0;  // OPTIMIZED: Realistic for BTC          // Global profit target in dollars (optional)
input double   MaxDrawdownPercent = 20.0;       // Max drawdown % (loss protection)
double   DailyProfitTarget = 10000.0;       // Daily profit target (0=disabled)
bool     EnableDailyTarget = false;       // Enable daily profit target

// input group "=== H4 SUPPORT/RESISTANCE ZONES ==="
bool     EnableH4Zones = false;            // Enable H4 S/R zone detection
int      H4LookbackBars = 100;            // H4 bars for S/R calculation
double   ZoneWidthPercent = 0.2;          // Zone width % (0.1-0.3 recommended)
int      MaxSRLevels = 3;                 // Max S/R levels to track (1-5)
bool     ResetGridAtZone = false;          // Reset grid when entering zone
bool     ShowH4Zones = true;              // Draw H4 zones on chart
input bool     PauseAtH4Zones = false;          // Pause at H4 resistance (BUY ONLY) or support (SELL ONLY)



enum TradingDirection
{
   TRADE_BOTH,      // Trade both BUY and SELL
   TRADE_BUY_ONLY,  // Trade BUY positions only
   TRADE_SELL_ONLY  // Trade SELL positions only
};

input TradingDirection AllowedDirection = TRADE_BUY_ONLY;  // Trading direction (BOTH/BUY ONLY/SELL ONLY)
input bool     BiDirectionalGrid = true;          // Grid both directions when BUY/SELL ONLY (true=grid both ways, false=trend-only)
int      StartupDelayBars = 0;            // Bars to wait before first trade (prevents immediate entries)

// input group "=== TRADING TIME WINDOWS (Abuja GMT+1) ==="
input bool     EnableTimeWindows = false;       // Enable trading time windows (false = trade anytime)
input string   Window1Start = "13:00";          // Window 1 start time (HH:MM format)
input int      Window1Duration = 10;            // Window 1 duration in minutes
input string   Window2Start = "15:00";          // Window 2 start time (HH:MM format)
input int      Window2Duration = 10;            // Window 2 duration in minutes
input int      BrokerGMTOffset = 3;             // Broker GMT offset (e.g., 3 for GMT+3)
input string   NewsTimeCustom = "";             // Custom news time HH:MM (leave empty to disable)
input int      NewsWindowMinutes = 2;           // Minutes before news to start trading

// input group "=== AUTO-DETECTION (ADAPTIVE MODE) ==="
bool     EnableAutoDetection = false;      // Enable automatic regime detection
ENUM_TIMEFRAMES RegimeDetectionTimeframe = PERIOD_H1;  // Timeframe for regime detection (M5/M15/H1/H4)
 double   ATRThresholdRanging = 8.0;       // ATR below this = RANGING
 double   ATRThresholdTrending = 12.0;     // ATR above this = TRENDING
 double   ADXThresholdRanging = 20.0;      // ADX below this = RANGING
 double   ADXThresholdTrending = 25.0;     // ADX above this = TRENDING
 double   BBWidthThresholdRanging = 15.0;  // BB Width below this = RANGING
 double   BBWidthThresholdTrending = 25.0; // BB Width above this = TRENDING
 int      RegimeCheckMinutes = 15;         // Check regime every N minutes

// input group "=== VISUAL ==="
input bool     ShowPanel = true;                // Show info panel
input bool     ShowGridLines = true;            // Show grid lines
input color    BuyLevelColor = clrDodgerBlue;   // Buy level color
input color    SellLevelColor = clrOrangeRed;   // Sell level color
input color    ResistanceZoneColor = clrCrimson;      // Resistance zone color
input color    SupportZoneColor = clrLimeGreen;       // Support zone color

//--- Global Variables
enum TrendDirection {
   TREND_BUYING,   // Buying mode (adds buys as price rises)
   TREND_SELLING,  // Selling mode (adds sells as price falls)
   TREND_WAITING   // Waiting for initial signal
};

enum MarketRegime {
   REGIME_RANGING,      // Ranging market
   REGIME_TRANSITION,   // Transition phase
   REGIME_TRENDING      // Trending market
};

struct PositionInfo {
   ulong    ticket;
   double   entryPrice;
   string   direction;
   datetime entryTime;
};

struct SRLevel {
   double   price;
   int      touches;
   bool     isResistance;
};

// SESSION STATISTICS (tracks performance since EA started)
struct SessionStats {
   int      totalClosedProfits;     // Count of profitable closed positions
   int      totalClosedLosses;      // Count of loss-making closed positions
   double   totalProfitAmount;      // $ amount from all profitable closes
   double   totalLossAmount;        // $ amount from all losing closes (negative)
   double   sessionNetPL;           // Net P&L for session
   double   sessionStartBalance;    // Balance when EA started
   datetime sessionStartTime;       // When session started
   double   largestWin;             // Largest winning trade
   double   largestLoss;            // Largest losing trade
   bool     isGroupClose;           // Flag: true when closing as group, false for individual
};

SessionStats sessionStats;

PositionInfo positions[];
SRLevel supportLevels[];
SRLevel resistanceLevels[];

TrendDirection currentTrend = TREND_WAITING;
double lastTrendPrice = 0;
double gridSpacing = 0;

//+------------------------------------------------------------------+
//| EMERGENCY STOP - Max Drawdown Protection                         |
//+------------------------------------------------------------------+
bool emergencyStop = false;              // Permanent stop flag when max DD hit
datetime emergencyStopTime = 0;          // Time when emergency stop triggered
string emergencyStopReason = "";         // Reason for emergency stop

// Auto-detection variables
MarketRegime currentRegime = REGIME_RANGING;
MarketRegime previousRegime = REGIME_RANGING;
datetime lastRegimeCheck = 0;
double currentATR = 0;
double currentADX = 0;
double currentBBWidth = 0;
int regimeScore = 0;

// Working parameters (can be modified by auto-detection)
double workingGridPercent;
int workingReversalGaps;
double workingTP;
double workingSL;
int workingMaxPos;

// Working direction (can be changed by buttons, starts with input value)
TradingDirection workingDirection;

// Risk tracking
double startingBalance;
double dailyStartBalance;
datetime lastDailyReset;
int totalTrades = 0;
bool dailyTargetReached = false;
double peakEquity;

// Consecutive SL tracking
int consecutiveSLs = 0;
bool eaStopped = false;
datetime lastPositionCloseTime = 0;
bool lastPositionWasWin = false;

// Spam prevention - track if we're in reversal ignored state
bool inReversalIgnoredState = false;
datetime lastReversalStateChange = 0;

// Trading time windows
bool inTradingWindow = false;
string currentWindowStatus = "Outside window";
datetime newsTime = 0;

// Panel
bool panelVisible = true;
bool tradingPaused = false;
string panelPrefix = "TMPanel_";

// Startup delay to prevent immediate trades
datetime eaStartTime = 0;
bool startupDelayPassed = false;
int startBarCount = 0;             // Bar count when EA started

// Tracking
double highestBuyPrice = 0;
double lowestBuyPrice = 0;
double highestSellPrice = 0;
double lowestSellPrice = 0;

// H4 S/R tracking
datetime lastH4Update = 0;
bool inSupportZone = false;
bool inResistanceZone = false;
string lastZoneType = "";

// Dynamic parameter storage (original values) - NOT USED in current version
// These would be used if we wanted to restore original values
// Currently we use input parameters as defaults and working variables for adjustments

//+------------------------------------------------------------------+
//| Parse time string (HH:MM format) to minutes since midnight      |
//+------------------------------------------------------------------+
int ParseTimeToMinutes(string timeStr)
{
   string parts[];
   int count = StringSplit(timeStr, ':', parts);
   if(count != 2) return -1;
   
   int hours = (int)StringToInteger(parts[0]);
   int minutes = (int)StringToInteger(parts[1]);
   
   if(hours < 0 || hours > 23 || minutes < 0 || minutes > 59)
      return -1;
   
   return hours * 60 + minutes;
}

//+------------------------------------------------------------------+
//| Convert Abuja time to broker time (minutes since midnight)      |
//+------------------------------------------------------------------+
int ConvertAbujaTimeToBrokerTime(int abujaMinutes)
{
   // Abuja is GMT+1, broker time varies
   // BrokerGMTOffset is broker's offset from GMT
   int offsetDiff = BrokerGMTOffset - 1; // Difference between broker and Abuja
   int brokerMinutes = abujaMinutes + (offsetDiff * 60);
   
   // Handle day wrap-around
   while(brokerMinutes < 0) brokerMinutes += 1440;
   while(brokerMinutes >= 1440) brokerMinutes -= 1440;
   
   return brokerMinutes;
}

//+------------------------------------------------------------------+
//| Check if current time is within any trading window              |
//+------------------------------------------------------------------+
bool IsInTradingWindow()
{
   // If time windows disabled, always return true (trade anytime)
   if(!EnableTimeWindows)
   {
      currentWindowStatus = "Time windows disabled - trading anytime";
      return true;
   }
   
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   int currentMinutes = now.hour * 60 + now.min;
   
   // Check custom news time first (if set)
   if(newsTime > 0)
   {
      MqlDateTime newsStruct;
      TimeToStruct(newsTime, newsStruct);
      
      // Check if it's the same day
      if(now.year == newsStruct.year && now.day_of_year == newsStruct.day_of_year)
      {
         int newsMinutes = newsStruct.hour * 60 + newsStruct.min;
         int newsWindowStart = newsMinutes - NewsWindowMinutes;
         
         if(currentMinutes >= newsWindowStart && currentMinutes < newsMinutes + NewsWindowMinutes)
         {
            int minutesToNews = newsMinutes - currentMinutes;
            if(minutesToNews > 0)
               currentWindowStatus = StringFormat("News window: %d min to news", minutesToNews);
            else
               currentWindowStatus = StringFormat("News window: %d min after news", -minutesToNews);
            return true;
         }
      }
   }
   
   // Check Window 1
   int window1StartMinutes = ParseTimeToMinutes(Window1Start);
   if(window1StartMinutes >= 0)
   {
      int window1BrokerStart = ConvertAbujaTimeToBrokerTime(window1StartMinutes);
      int window1BrokerEnd = window1BrokerStart + Window1Duration;
      
      if(currentMinutes >= window1BrokerStart && currentMinutes < window1BrokerEnd)
      {
         int remaining = window1BrokerEnd - currentMinutes;
         currentWindowStatus = StringFormat("Window 1 active: %d min remaining", remaining);
         return true;
      }
   }
   
   // Check Window 2
   int window2StartMinutes = ParseTimeToMinutes(Window2Start);
   if(window2StartMinutes >= 0)
   {
      int window2BrokerStart = ConvertAbujaTimeToBrokerTime(window2StartMinutes);
      int window2BrokerEnd = window2BrokerStart + Window2Duration;
      
      if(currentMinutes >= window2BrokerStart && currentMinutes < window2BrokerEnd)
      {
         int remaining = window2BrokerEnd - currentMinutes;
         currentWindowStatus = StringFormat("Window 2 active: %d min remaining", remaining);
         return true;
      }
   }
   
   // Outside all windows
   // Calculate time to next window
   string nextWindowInfo = CalculateTimeToNextWindow(currentMinutes);
   currentWindowStatus = "Outside windows - " + nextWindowInfo;
   return false;
}

//+------------------------------------------------------------------+
//| Calculate time to next trading window                           |
//+------------------------------------------------------------------+
string CalculateTimeToNextWindow(int currentMinutes)
{
   int window1Start = ConvertAbujaTimeToBrokerTime(ParseTimeToMinutes(Window1Start));
   int window2Start = ConvertAbujaTimeToBrokerTime(ParseTimeToMinutes(Window2Start));
   
   int nextWindow = -1;
   int minDiff = 1440; // Max minutes in a day
   
   // Check Window 1
   if(window1Start > currentMinutes)
   {
      int diff = window1Start - currentMinutes;
      if(diff < minDiff)
      {
         minDiff = diff;
         nextWindow = 1;
      }
   }
   
   // Check Window 2
   if(window2Start > currentMinutes)
   {
      int diff = window2Start - currentMinutes;
      if(diff < minDiff)
      {
         minDiff = diff;
         nextWindow = 2;
      }
   }
   
   // If no window ahead today, next is Window 1 tomorrow
   if(nextWindow == -1)
   {
      minDiff = (1440 - currentMinutes) + window1Start;
      nextWindow = 1;
   }
   
   int hours = minDiff / 60;
   int mins = minDiff % 60;
   
   return StringFormat("Next window %d in %dh %dm", nextWindow, hours, mins);
}

//+------------------------------------------------------------------+
//| Parse and set custom news time                                  |
//+------------------------------------------------------------------+
void ParseNewsTime()
{
   newsTime = 0;
   
   if(NewsTimeCustom == "") return;
   
   int newsMinutes = ParseTimeToMinutes(NewsTimeCustom);
   if(newsMinutes < 0)
   {
      Print("⚠️ Invalid news time format: ", NewsTimeCustom, " (use HH:MM)");
      return;
   }
   
   // Convert to broker time
   int newsBrokerMinutes = ConvertAbujaTimeToBrokerTime(newsMinutes);
   
   // Set for today
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   now.hour = newsBrokerMinutes / 60;
   now.min = newsBrokerMinutes % 60;
   now.sec = 0;
   
   newsTime = StructToTime(now);
   
   Print("📰 News time set: ", TimeToString(newsTime, TIME_DATE|TIME_MINUTES), 
         " (", NewsWindowMinutes, " min window)");
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // CRITICAL: Validate input parameters FIRST!
   if(GridSpacingPercent <= 0.0 || GridSpacingPercent > 5.0)
   {
      Alert("❌ CRITICAL ERROR: GridSpacingPercent = ", GridSpacingPercent, "% is INVALID!");
      Alert("Must be between 0.01% and 5.0%. Recommended: 0.2-0.5% for Gold");
      Print("❌ GridSpacingPercent validation FAILED! EA will NOT load.");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(MaxPositions <= 0 || MaxPositions > 100)
   {
      Alert("❌ CRITICAL ERROR: MaxPositions = ", MaxPositions, " is INVALID!");
      Alert("Must be between 1 and 100.");
      Print("❌ MaxPositions validation FAILED! EA will NOT load.");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(ReversalGaps <= 0 || ReversalGaps > 20)
   {
      Alert("❌ CRITICAL ERROR: ReversalGaps = ", ReversalGaps, " is INVALID!");
      Alert("Must be between 1 and 20.");
      Print("❌ ReversalGaps validation FAILED! EA will NOT load.");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   Print("✅ Parameters validated - EA initializing...");
   Print("   GridSpacingPercent: ", GridSpacingPercent, "%");
   Print("   MaxPositions: ", MaxPositions);
   Print("   ReversalGaps: ", ReversalGaps);
   Print("   workingDirection: ", (int)workingDirection, " (0=BOTH, 1=BUY_ONLY, 2=SELL_ONLY)");
   Print("   BiDirectionalGrid: ", BiDirectionalGrid);
   
   startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyStartBalance = startingBalance;
   peakEquity = startingBalance;
   lastDailyReset = TimeCurrent();
   
   // Initialize session statistics
   sessionStats.totalClosedProfits = 0;
   sessionStats.totalClosedLosses = 0;
   sessionStats.totalProfitAmount = 0;
   sessionStats.totalLossAmount = 0;
   sessionStats.sessionNetPL = 0;
   sessionStats.sessionStartBalance = startingBalance;
   sessionStats.sessionStartTime = TimeCurrent();
   sessionStats.largestWin = 0;
   sessionStats.largestLoss = 0;
   sessionStats.isGroupClose = false;
   
   Print("📊 Session Statistics Initialized:");
   Print("   Start Time: ", TimeToString(sessionStats.sessionStartTime, TIME_DATE|TIME_MINUTES));
   Print("   Start Balance: $", DoubleToString(sessionStats.sessionStartBalance, 2));
   
   // Initialize startup delay
   eaStartTime = TimeCurrent();
   startBarCount = Bars(_Symbol, PERIOD_CURRENT);
   startupDelayPassed = false;
   
   panelVisible = ShowPanel;
   
   // Initialize working parameters with input values
   workingGridPercent = GridSpacingPercent;
   workingReversalGaps = ReversalGaps;
   workingTP = IndividualTPDollars;
   workingSL = IndividualSLDollars;
   workingMaxPos = MaxPositions;
   workingDirection = AllowedDirection;  // Initialize with input setting
   
   
   // Auto-enable H4 zones if PauseAtH4Zones is enabled
   if(PauseAtH4Zones && !EnableH4Zones)
   {
      EnableH4Zones = true;
      Print("ℹ️ H4 zones auto-enabled because PauseAtH4Zones is ON");
   }
   if(panelVisible)
      CreateInfoPanel();
   
   
   // ALWAYS calculate H4 S/R for panel display (information only)
   CalculateH4SupportResistance();
   
   // Parse custom news time
   ParseNewsTime();
   
   // Check initial time window status
   inTradingWindow = IsInTradingWindow();
   
   // Initialize auto-detection system
   if(EnableAutoDetection)
   {
      // Initial regime check
      CheckMarketRegime();
      
      Print("--- AUTO-DETECTION (ADAPTIVE MODE) ---");
      Print("Auto-Detection: ENABLED");
      Print("Check Interval: ", RegimeCheckMinutes, " minutes");
      Print("ATR Thresholds: <", ATRThresholdRanging, " (RANGING) | >", ATRThresholdTrending, " (TRENDING)");
      Print("ADX Thresholds: <", ADXThresholdRanging, " (RANGING) | >", ADXThresholdTrending, " (TRENDING)");
      Print("BB Thresholds: <", BBWidthThresholdRanging, " (RANGING) | >", BBWidthThresholdTrending, " (TRENDING)");
      Print("Initial Regime: ", GetRegimeName(currentRegime));
   }
   else
   {
      Print("--- AUTO-DETECTION ---");
      Print("Auto-Detection: DISABLED (using manual parameters)");
   }
   
   Print("====================================================================");
   Print("TORAMA Dynamic Momentum Grid EA v4.2 - H4 S/R + AUTO-DETECTION");
   Print("SACROSANCT INDIVIDUAL TP/SL ENABLED");
   Print("Grid Spacing: ", GridSpacingPercent, "%");
   Print("Reversal Gaps: ", ReversalGaps);
   Print("Individual TP: $", IndividualTPDollars, " (SACROSANCT - cannot be overridden)");
   Print("Individual SL: $", IndividualSLDollars, " (SACROSANCT - cannot be overridden)");
   Print("Max Consecutive SLs: ", MaxConsecutiveSLs, " (EA stops after this)");
   Print("Global TP: $", GlobalTPDollars, " (optional additional exit)");
   Print("Max Drawdown: ", MaxDrawdownPercent, "% (LOSS PROTECTION)");
   
   // Trading time windows
   Print("--- TRADING TIME WINDOWS ---");
   Print("Time Windows: ", EnableTimeWindows ? "ENABLED" : "DISABLED (trade anytime)");
   if(EnableTimeWindows)
   {
      Print("Window 1: ", Window1Start, " Abuja time for ", Window1Duration, " minutes");
      Print("Window 2: ", Window2Start, " Abuja time for ", Window2Duration, " minutes");
      Print("Broker GMT Offset: GMT+", BrokerGMTOffset);
      if(NewsTimeCustom != "")
         Print("Custom News Time: ", NewsTimeCustom, " Abuja (", NewsWindowMinutes, " min window)");
      Print("Current Status: ", currentWindowStatus);
   }
   
   Print("--- H4 ZONES ---");
   Print("H4 Zones: ", EnableH4Zones ? "ENABLED" : "DISABLED");
   if(EnableH4Zones)
   {
      Print("Zone Width: ", ZoneWidthPercent, "%");
      Print("Reset at Zone: ", ResetGridAtZone ? "YES" : "NO");
      Print("Max S/R Levels: ", MaxSRLevels);
   }
   
   Print("--- POSITION MANAGEMENT ---");
   string directionText = "";
   if(workingDirection == TRADE_BOTH)
      directionText = "BOTH BUY & SELL";
   else if(workingDirection == TRADE_BUY_ONLY)
      directionText = "BUY ONLY";
   else if(workingDirection == TRADE_SELL_ONLY)
      directionText = "SELL ONLY";
   Print("Trading Direction: ", directionText);
   Print("Startup Delay: ", StartupDelayBars, " bars (prevents immediate trades)");
   Print("Max Positions: ", MaxPositions);
   Print("Lot Size: ", LotSize);
   Print("====================================================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteInfoPanel();
   ObjectsDeleteAll(0, "GridLevel_");
   ObjectsDeleteAll(0, "H4Zone_");
   ObjectsDeleteAll(0, "H4Label_");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check if EA stopped due to consecutive SLs
   if(eaStopped)
   {
      UpdateInfoPanel();
      return;
   }
   
   CheckDailyReset();
   
   if(dailyTargetReached && EnableDailyTarget)
   {
      UpdateInfoPanel();
      return;
   }
   
   //+------------------------------------------------------------------+
   //| EMERGENCY STOP CHECK - Must be first priority                    |
   //+------------------------------------------------------------------+
   if(emergencyStop)
   {
      // EA is in emergency stop mode - do not trade!
      static datetime lastEmergencyMessage = 0;
      
      // Print message every 5 minutes as reminder
      if(TimeCurrent() - lastEmergencyMessage > 300)
      {
         Print("🛑 EA IN EMERGENCY STOP MODE");
         Print("   Reason: ", emergencyStopReason);
         Print("   Stopped at: ", TimeToString(emergencyStopTime));
         Print("   ⚠️ MANUAL RESTART REQUIRED");
         Print("   Remove EA from chart and re-attach to restart");
         lastEmergencyMessage = TimeCurrent();
      }
      
      UpdateInfoPanel();  // Update panel to show stopped status
      return;  // Exit - no trading allowed
   }
   
   if(tradingPaused)
   {
      UpdateInfoPanel();
      return;
   }
   
   // H4 ZONE PAUSE FEATURE (only if enabled)
   if(PauseAtH4Zones && CheckH4ZonePause())
   {
      UpdateInfoPanel();
      return;  // Don't trade, we're paused at H4 zone
   }
   
   // Check if we're in a trading time window
   inTradingWindow = IsInTradingWindow();
   if(!inTradingWindow)
   {
      // Outside trading window - don't open new positions, but keep monitoring
      UpdateInfoPanel();
      return;
   }
   
   // Startup delay - wait for confirmation bars before first trade
   if(!startupDelayPassed && currentTrend == TREND_WAITING && ArraySize(positions) == 0)
   {
      int currentBarCount = Bars(_Symbol, PERIOD_CURRENT);
      int barsSinceStart = currentBarCount - startBarCount;
      
      if(barsSinceStart >= StartupDelayBars)
      {
         startupDelayPassed = true;
         Print("✅ Startup delay completed (", barsSinceStart, " bars) - EA ready to trade");
      }
      else
      {
         // Still in startup delay - just observe
         string waitText = StringFormat("⏳ Waiting for %d more bars before trading (%d/%d)", 
                                       StartupDelayBars - barsSinceStart, 
                                       barsSinceStart, 
                                       StartupDelayBars);
         Comment(waitText);
         UpdateInfoPanel();
         return;
      }
   }
   
   // Check for closed positions and track consecutive SLs
   CheckClosedPositions();
   
   UpdatePositionTracking();
   
   // Auto-detection: Check market regime periodically
   if(EnableAutoDetection)
   {
      datetime currentTime = TimeCurrent();
      if(lastRegimeCheck == 0 || (currentTime - lastRegimeCheck) >= RegimeCheckMinutes * 60)
      {
         CheckMarketRegime();
         lastRegimeCheck = currentTime;
      }
   }
   
   // Update H4 S/R zones periodically
   if(EnableH4Zones)
   {
      MqlDateTime current_time;
      TimeToStruct(TimeCurrent(), current_time);
      
      // Update every H4 candle close
      if(current_time.hour % 4 == 0 && current_time.min == 0)
      {
         if(lastH4Update != TimeCurrent())
         {
            CalculateH4SupportResistance();
            lastH4Update = TimeCurrent();
            if(ShowH4Zones)
               DrawH4Zones();
         }
      }
      
      
      // Check if price entered/exited S/R zones (for tracking and display)
      if(EnableH4Zones)
      {
         CheckZoneEntry();
      }
   }
   
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2;
   gridSpacing = currentPrice * GridSpacingPercent / 100.0;
   
   // Check for profit target
   if(ArraySize(positions) > 0)
   {
      double globalPnL = CalculateGlobalPnL();
      
      if(globalPnL >= GlobalTPDollars)
      {
         Print("✅ GLOBAL PROFIT TARGET HIT: $", DoubleToString(globalPnL, 2));
         CloseAllPositions("Global Profit Target");
         currentTrend = TREND_WAITING;
         lastTrendPrice = 0;
         UpdateInfoPanel();
         return;
      }
      
      if(CheckDrawdownLimit())
      {
         // Emergency stop already set inside CheckDrawdownLimit()
         Print("🛑 CLOSING ALL POSITIONS - EMERGENCY STOP ACTIVE");
         CloseAllPositions("EMERGENCY STOP - Max Drawdown Protection");
         
         // Don't set TREND_WAITING - EA is permanently stopped now
         // emergencyStop flag prevents any further trading
         
         Print("");
         Print("═══════════════════════════════════════════════════════════");
         Print("📌 TO RESTART EA:");
         Print("   1. Remove EA from chart");
         Print("   2. Re-attach EA to chart");
         Print("   3. Check settings before clicking OK");
         Print("═══════════════════════════════════════════════════════════");
         
         UpdateInfoPanel();
         return;
      }
   }
   
   // Trading logic
   if(currentTrend == TREND_WAITING)
   {
      if(lastTrendPrice == 0)
      {
         lastTrendPrice = currentPrice;
         return;
      }
      
      double priceChange = ((currentPrice - lastTrendPrice) / lastTrendPrice) * 100.0;
      double reversalThreshold = ReversalGaps * GridSpacingPercent;
      
      // Check for BUY signal (price rising)
      if(priceChange >= GridSpacingPercent)
      {
         if(workingDirection == TRADE_BOTH || workingDirection == TRADE_BUY_ONLY)
         {
            // TRADE_BOTH MODE: Start BUYING when price rises
            // NEWS TRADING: Opens BUY on upward momentum
            if(OpenPosition("BUY", currentPrice))
            {
               currentTrend = TREND_BUYING;
               lastTrendPrice = currentPrice;
               Print("🔵 MOMENTUM SIGNAL: Price rose +", DoubleToString(priceChange, 2), "%, START BUYING");
            }
         }
         else
         {
            // BUY signal but SELL ONLY mode - update reference price
            lastTrendPrice = currentPrice;
         }
      }
      // Check for SELL signal (price falling)
      else if(priceChange <= -GridSpacingPercent)
      {
         if(workingDirection == TRADE_BOTH || workingDirection == TRADE_SELL_ONLY)
         {
            // TRADE_BOTH MODE: Start SELLING when price falls
            // NEWS TRADING: Opens SELL on downward momentum
            if(OpenPosition("SELL", currentPrice))
            {
               currentTrend = TREND_SELLING;
               lastTrendPrice = currentPrice;
               Print("🔴 MOMENTUM SIGNAL: Price fell ", DoubleToString(priceChange, 2), "%, START SELLING");
            }
         }
         else
         {
            // SELL signal but BUY ONLY mode - update reference price
            lastTrendPrice = currentPrice;
         }
      }
      // NEW: Counter-trend entry for directional modes (buy the dip / sell the rally)
      else if(workingDirection == TRADE_BUY_ONLY && priceChange <= -reversalThreshold)
      {
         // BUY ONLY mode: Price has fallen by reversal gap amount - BUY THE DIP!
         if(OpenPosition("BUY", currentPrice))
         {
            currentTrend = TREND_BUYING;
            lastTrendPrice = currentPrice;
            Print("🔵 BUY THE DIP: Price fell ", DoubleToString(MathAbs(priceChange), 2), 
                  "% (", ReversalGaps, " gaps) - Opening BUY position");
         }
      }
      else if(workingDirection == TRADE_SELL_ONLY && priceChange >= reversalThreshold)
      {
         // SELL ONLY mode: Price has risen by reversal gap amount - SELL THE RALLY!
         if(OpenPosition("SELL", currentPrice))
         {
            currentTrend = TREND_SELLING;
            lastTrendPrice = currentPrice;
            Print("🔴 SELL THE RALLY: Price rose +", DoubleToString(priceChange, 2), 
                  "% (", ReversalGaps, " gaps) - Opening SELL position");
         }
      }
   }
   else
   {
      if(currentTrend == TREND_BUYING)
      {
         double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         
         // Add more BUY positions as price rises (normal grid behavior)
         if(highestBuyPrice > 0 && currentAsk >= (highestBuyPrice + gridSpacing))
         {
            if(CountActualPositions() < MaxPositions)
            {
               OpenPosition("BUY", currentAsk);
            }
         }
         
         // BiDirectionalGrid: Add BUY positions as price falls (counter-trend grid)
         if(BiDirectionalGrid && workingDirection == TRADE_BUY_ONLY)
         {
            if(lowestBuyPrice > 0 && currentBid <= (lowestBuyPrice - gridSpacing))
            {
               if(CountActualPositions() < MaxPositions)
               {
                  Print("📊 BIDIRECTIONAL GRID: Adding BUY on dip");
                  OpenPosition("BUY", currentBid);
               }
            }
         }
         
         // Check for reversal to SELLING
         if(ShouldReverse(currentPrice))
         {
            if(BiDirectionalGrid && workingDirection == TRADE_BUY_ONLY)
            {
               // BiDirectionalGrid BUY ONLY: Don't reverse, keep buying
               // Only print ONCE when entering this state
               if(!inReversalIgnoredState)
               {
                  Print("📊 BIDIRECTIONAL GRID: Reversal signal ignored - continuing BUY ONLY");
                  inReversalIgnoredState = true;
                  lastReversalStateChange = TimeCurrent();
               }
               lastTrendPrice = currentPrice;
            }
            else if(workingDirection == TRADE_BOTH)
            {
               // TRADE_BOTH: Don't close positions, just switch trend
               Print("🔄 BOTH MODE: Downward reversal - keeping BUYs, allowing SELLs");
               currentTrend = TREND_SELLING;
               lastTrendPrice = currentPrice;
            }
            else if(workingDirection == TRADE_SELL_ONLY)
            {
               // SELL ONLY mode: DON'T close BUY positions - let them manage to TP/SL
               // Just prevent new BUY positions and switch trend to allow SELLs
               if(!BiDirectionalGrid)
               {
                  // Non-bidirectional: just switch trend, BUYs will be managed by their TP/SL
                  Print("🔄 REVERSAL in SELL ONLY mode - BUYs remain open, switching to SELLING");
                  currentTrend = TREND_SELLING;
                  lastTrendPrice = currentPrice;
               }
               else
               {
                  // BiDirectional already handled above, should not reach here
                  lastTrendPrice = currentPrice;
               }
            }
            else
            {
               // BUY ONLY mode (non-bidirectional) with downward reversal
               // BUYs remain open and managed by TP/SL, just don't add new ones
               Print("🔄 REVERSAL SIGNAL in BUY ONLY mode - BUYs remain open, waiting");
               currentTrend = TREND_WAITING;
               lastTrendPrice = currentPrice;
            }
         }
         else
         {
            // Reset state when reversal condition no longer true
            inReversalIgnoredState = false;
         }
      }
      else if(currentTrend == TREND_SELLING)
      {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         
         // Add more SELL positions as price falls (normal grid behavior)
         if(lowestSellPrice > 0 && currentBid <= (lowestSellPrice - gridSpacing))
         {
            if(CountActualPositions() < MaxPositions)
            {
               OpenPosition("SELL", currentBid);
            }
         }
         
         // BiDirectionalGrid: Add SELL positions as price rises (counter-trend grid)
         if(BiDirectionalGrid && workingDirection == TRADE_SELL_ONLY)
         {
            if(highestSellPrice > 0 && currentAsk >= (highestSellPrice + gridSpacing))
            {
               if(CountActualPositions() < MaxPositions)
               {
                  Print("📊 BIDIRECTIONAL GRID: Adding SELL on rally");
                  OpenPosition("SELL", currentAsk);
               }
            }
         }
         
         // Check for reversal to BUYING
         if(ShouldReverse(currentPrice))
         {
            if(BiDirectionalGrid && workingDirection == TRADE_SELL_ONLY)
            {
               // BiDirectionalGrid SELL ONLY: Don't reverse, keep selling
               // Only print ONCE when entering this state
               if(!inReversalIgnoredState)
               {
                  Print("📊 BIDIRECTIONAL GRID: Reversal signal ignored - continuing SELL ONLY");
                  inReversalIgnoredState = true;
                  lastReversalStateChange = TimeCurrent();
               }
               lastTrendPrice = currentPrice;
            }
            else if(workingDirection == TRADE_BOTH)
            {
               // TRADE_BOTH: Don't close positions, just switch trend
               Print("🔄 BOTH MODE: Upward reversal - keeping SELLs, allowing BUYs");
               currentTrend = TREND_BUYING;
               lastTrendPrice = currentPrice;
            }
            else if(workingDirection == TRADE_BUY_ONLY)
            {
               // BUY ONLY mode: DON'T close SELL positions - let them manage to TP/SL
               // Just prevent new SELL positions and switch trend to allow BUYs
               if(!BiDirectionalGrid)
               {
                  // Non-bidirectional: just switch trend, SELLs will be managed by their TP/SL
                  Print("🔄 REVERSAL in BUY ONLY mode - SELLs remain open, switching to BUYING");
                  currentTrend = TREND_BUYING;
                  lastTrendPrice = currentPrice;
               }
               else
               {
                  // BiDirectional already handled above, should not reach here
                  lastTrendPrice = currentPrice;
               }
            }
            else
            {
               // SELL ONLY mode (non-bidirectional) with upward reversal
               // SELLs remain open and managed by TP/SL, just don't add new ones
               Print("🔄 REVERSAL SIGNAL in SELL ONLY mode - SELLs remain open, waiting");
               currentTrend = TREND_WAITING;
               lastTrendPrice = currentPrice;
            }
         }
         else
         {
            // Reset state when reversal condition no longer true
            inReversalIgnoredState = false;
         }
      }
   }
   
   UpdateInfoPanel();
   if(ShowGridLines)
      DrawGridLevels();
   if(ShowH4Zones && EnableH4Zones)
      DrawH4Zones();
}

//+------------------------------------------------------------------+
//| Calculate H4 Support and Resistance levels                       |
//+------------------------------------------------------------------+
void CalculateH4SupportResistance()
{
   ArrayResize(supportLevels, 0);
   ArrayResize(resistanceLevels, 0);
   
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   
   int copied_high = CopyHigh(_Symbol, PERIOD_H4, 0, H4LookbackBars, highs);
   int copied_low = CopyLow(_Symbol, PERIOD_H4, 0, H4LookbackBars, lows);
   
   if(copied_high <= 0 || copied_low <= 0)
   {
      Print("⚠️ Failed to copy H4 price data");
      return;
   }
   
   // Find swing highs (resistance)
   for(int i = 2; i < H4LookbackBars - 2; i++)
   {
      if(highs[i] > highs[i-1] && highs[i] > highs[i-2] && 
         highs[i] > highs[i+1] && highs[i] > highs[i+2])
      {
         // Check if this level already exists
         bool exists = false;
         for(int j = 0; j < ArraySize(resistanceLevels); j++)
         {
            if(MathAbs(resistanceLevels[j].price - highs[i]) < (highs[i] * 0.001)) // Within 0.1%
            {
               exists = true;
               resistanceLevels[j].touches++;
               break;
            }
         }
         
         if(!exists && ArraySize(resistanceLevels) < MaxSRLevels)
         {
            int newSize = ArraySize(resistanceLevels) + 1;
            ArrayResize(resistanceLevels, newSize);
            resistanceLevels[newSize-1].price = highs[i];
            resistanceLevels[newSize-1].touches = 1;
            resistanceLevels[newSize-1].isResistance = true;
         }
      }
   }
   
   // Find swing lows (support)
   for(int i = 2; i < H4LookbackBars - 2; i++)
   {
      if(lows[i] < lows[i-1] && lows[i] < lows[i-2] && 
         lows[i] < lows[i+1] && lows[i] < lows[i+2])
      {
         bool exists = false;
         for(int j = 0; j < ArraySize(supportLevels); j++)
         {
            if(MathAbs(supportLevels[j].price - lows[i]) < (lows[i] * 0.001))
            {
               exists = true;
               supportLevels[j].touches++;
               break;
            }
         }
         
         if(!exists && ArraySize(supportLevels) < MaxSRLevels)
         {
            int newSize = ArraySize(supportLevels) + 1;
            ArrayResize(supportLevels, newSize);
            supportLevels[newSize-1].price = lows[i];
            supportLevels[newSize-1].touches = 1;
            supportLevels[newSize-1].isResistance = false;
         }
      }
   }
   
   // Sort by proximity to current price (most relevant first)
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2;
   SortSRLevelsByProximity(supportLevels, currentPrice);
   SortSRLevelsByProximity(resistanceLevels, currentPrice);
   
   Print("📊 H4 S/R Updated: ", ArraySize(supportLevels), " Support, ", 
         ArraySize(resistanceLevels), " Resistance levels found");
}

//+------------------------------------------------------------------+
//| Sort S/R levels by proximity to current price                    |
//+------------------------------------------------------------------+
void SortSRLevelsByProximity(SRLevel &levels[], double currentPrice)
{
   int size = ArraySize(levels);
   if(size <= 1) return;
   
   // Simple bubble sort by distance
   for(int i = 0; i < size - 1; i++)
   {
      for(int j = 0; j < size - i - 1; j++)
      {
         double dist1 = MathAbs(levels[j].price - currentPrice);
         double dist2 = MathAbs(levels[j+1].price - currentPrice);
         
         if(dist1 > dist2)
         {
            SRLevel temp = levels[j];
            levels[j] = levels[j+1];
            levels[j+1] = temp;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if price entered S/R zone                                  |
//+------------------------------------------------------------------+
void CheckZoneEntry()
{
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2;
   double zoneWidth = currentPrice * ZoneWidthPercent / 100.0;
   
   bool nowInSupport = false;
   bool nowInResistance = false;
   
   // Check support zones
   for(int i = 0; i < ArraySize(supportLevels); i++)
   {
      if(currentPrice >= (supportLevels[i].price - zoneWidth) && 
         currentPrice <= (supportLevels[i].price + zoneWidth))
      {
         nowInSupport = true;
         break;
      }
   }
   
   // Check resistance zones
   for(int i = 0; i < ArraySize(resistanceLevels); i++)
   {
      if(currentPrice >= (resistanceLevels[i].price - zoneWidth) && 
         currentPrice <= (resistanceLevels[i].price + zoneWidth))
      {
         nowInResistance = true;
         break;
      }
   }
   
   // Entered support zone (was not in before, now in)
   if(nowInSupport && !inSupportZone && lastZoneType != "SUPPORT")
   {
      Print("🟢 ENTERED H4 SUPPORT ZONE");
      if(ResetGridAtZone)
      {
         Print("   → Closing all positions (ResetGridAtZone = true)");
         CloseAllPositions("H4 Support Zone Entry");
         currentTrend = TREND_WAITING;
         lastTrendPrice = 0;
      }
      else
      {
         Print("   → Keeping positions open (ResetGridAtZone = false)");
      }
      inSupportZone = true;
      inResistanceZone = false;
      lastZoneType = "SUPPORT";
   }
   // Entered resistance zone (was not in before, now in)
   else if(nowInResistance && !inResistanceZone && lastZoneType != "RESISTANCE")
   {
      Print("🔴 ENTERED H4 RESISTANCE ZONE");
      if(ResetGridAtZone)
      {
         Print("   → Closing all positions (ResetGridAtZone = true)");
         CloseAllPositions("H4 Resistance Zone Entry");
         currentTrend = TREND_WAITING;
         lastTrendPrice = 0;
      }
      else
      {
         Print("   → Keeping positions open (ResetGridAtZone = false)");
      }
      inResistanceZone = true;
      inSupportZone = false;
      lastZoneType = "RESISTANCE";
   }
   
   // Exited zones
   if(!nowInSupport && inSupportZone)
   {
      Print("⬆️ EXITED H4 Support Zone");
      inSupportZone = false;
      lastZoneType = "";
   }
   
   if(!nowInResistance && inResistanceZone)
   {
      Print("⬇️ EXITED H4 Resistance Zone");
      inResistanceZone = false;
      lastZoneType = "";
   }
}

//+------------------------------------------------------------------+
//| Draw H4 zones on chart                                           |
//+------------------------------------------------------------------+
void DrawH4Zones()
{
   ObjectsDeleteAll(0, "H4Zone_");
   ObjectsDeleteAll(0, "H4Label_");
   
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2;
   double zoneWidth = currentPrice * ZoneWidthPercent / 100.0;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Draw resistance zones
   for(int i = 0; i < ArraySize(resistanceLevels); i++)
   {
      string zoneName = "H4Zone_R" + IntegerToString(i);
      string labelName = "H4Label_R" + IntegerToString(i);
      
      double upper = resistanceLevels[i].price + zoneWidth;
      double lower = resistanceLevels[i].price - zoneWidth;
      
      ObjectCreate(0, zoneName, OBJ_RECTANGLE, 0, TimeCurrent() - 86400*7, upper, TimeCurrent() + 86400, lower);
      ObjectSetInteger(0, zoneName, OBJPROP_COLOR, ResistanceZoneColor);
      ObjectSetInteger(0, zoneName, OBJPROP_FILL, true);
      ObjectSetInteger(0, zoneName, OBJPROP_BACK, true);
      ObjectSetInteger(0, zoneName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, zoneName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, zoneName, OBJPROP_STYLE, STYLE_SOLID);
      
      // Label
      ObjectCreate(0, labelName, OBJ_TEXT, 0, TimeCurrent(), resistanceLevels[i].price);
      ObjectSetString(0, labelName, OBJPROP_TEXT, "R" + IntegerToString(i+1) + " (" + IntegerToString(resistanceLevels[i].touches) + ")");
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, ResistanceZoneColor);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 11);
      ObjectSetString(0, labelName, OBJPROP_FONT, "Segoe UI Semibold");
      ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_RIGHT);
      ObjectSetInteger(0, labelName, OBJPROP_BACK, true);
   }
   
   // Draw support zones
   for(int i = 0; i < ArraySize(supportLevels); i++)
   {
      string zoneName = "H4Zone_S" + IntegerToString(i);
      string labelName = "H4Label_S" + IntegerToString(i);
      
      double upper = supportLevels[i].price + zoneWidth;
      double lower = supportLevels[i].price - zoneWidth;
      
      ObjectCreate(0, zoneName, OBJ_RECTANGLE, 0, TimeCurrent() - 86400*7, upper, TimeCurrent() + 86400, lower);
      ObjectSetInteger(0, zoneName, OBJPROP_COLOR, SupportZoneColor);
      ObjectSetInteger(0, zoneName, OBJPROP_FILL, true);
      ObjectSetInteger(0, zoneName, OBJPROP_BACK, true);
      ObjectSetInteger(0, zoneName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, zoneName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, zoneName, OBJPROP_STYLE, STYLE_SOLID);
      
      // Label
      ObjectCreate(0, labelName, OBJ_TEXT, 0, TimeCurrent(), supportLevels[i].price);
      ObjectSetString(0, labelName, OBJPROP_TEXT, "S" + IntegerToString(i+1) + " (" + IntegerToString(supportLevels[i].touches) + ")");
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, SupportZoneColor);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 11);
      ObjectSetString(0, labelName, OBJPROP_FONT, "Segoe UI Semibold");
      ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_RIGHT);
      ObjectSetInteger(0, labelName, OBJPROP_BACK, true);
   }
}

//+------------------------------------------------------------------+
//| Calculate ATR (Average True Range) on H1 timeframe               |
//+------------------------------------------------------------------+
double CalculateATR(int period = 14)
{
   double atr[];
   ArraySetAsSeries(atr, true);
   
   int handle = iATR(_Symbol, RegimeDetectionTimeframe, period);
   if(handle == INVALID_HANDLE)
   {
      Print("❌ Failed to create ATR indicator handle");
      return 0;
   }
   
   if(CopyBuffer(handle, 0, 0, 1, atr) <= 0)
   {
      Print("❌ Failed to copy ATR buffer");
      IndicatorRelease(handle);
      return 0;
   }
   
   double result = atr[0];
   IndicatorRelease(handle);
   
   return result;
}

//+------------------------------------------------------------------+
//| Calculate ADX (Average Directional Index) on H1 timeframe        |
//+------------------------------------------------------------------+
double CalculateADX(int period = 14)
{
   double adx[];
   ArraySetAsSeries(adx, true);
   
   int handle = iADX(_Symbol, RegimeDetectionTimeframe, period);
   if(handle == INVALID_HANDLE)
   {
      Print("❌ Failed to create ADX indicator handle");
      return 0;
   }
   
   // ADX is in buffer 0 (MAIN_LINE)
   if(CopyBuffer(handle, 0, 0, 1, adx) <= 0)
   {
      Print("❌ Failed to copy ADX buffer");
      IndicatorRelease(handle);
      return 0;
   }
   
   double result = adx[0];
   IndicatorRelease(handle);
   
   return result;
}

//+------------------------------------------------------------------+
//| Calculate Bollinger Bands Width on H1 timeframe                  |
//+------------------------------------------------------------------+
double CalculateBBWidth(int period = 20, double deviation = 2.0)
{
   double upper[], lower[];
   ArraySetAsSeries(upper, true);
   ArraySetAsSeries(lower, true);
   
   int handle = iBands(_Symbol, RegimeDetectionTimeframe, period, 0, deviation, PRICE_CLOSE);
   if(handle == INVALID_HANDLE)
   {
      Print("❌ Failed to create Bollinger Bands indicator handle");
      return 0;
   }
   
   // iBands buffers: 0=BASE_LINE, 1=UPPER_BAND, 2=LOWER_BAND
   if(CopyBuffer(handle, 1, 0, 1, upper) <= 0 || CopyBuffer(handle, 2, 0, 1, lower) <= 0)
   {
      Print("❌ Failed to copy Bollinger Bands buffers");
      IndicatorRelease(handle);
      return 0;
   }
   
   double width = upper[0] - lower[0];
   IndicatorRelease(handle);
   
   return width;
}

//+------------------------------------------------------------------+
//| Get regime name as string                                        |
//+------------------------------------------------------------------+
string GetRegimeName(MarketRegime regime)
{
   switch(regime)
   {
      case REGIME_RANGING: return "RANGING";
      case REGIME_TRANSITION: return "TRANSITION";
      case REGIME_TRENDING: return "TRENDING";
      default: return "UNKNOWN";
   }
}

//+------------------------------------------------------------------+
//| Check market regime and adjust parameters                        |
//+------------------------------------------------------------------+
void CheckMarketRegime()
{
   // Calculate indicators
   currentATR = CalculateATR(14);
   currentADX = CalculateADX(14);
   currentBBWidth = CalculateBBWidth(20, 2.0);
   
   // Calculate regime score (0-9)
   regimeScore = 0;
   
   // ATR scoring (0-3 points)
   if(currentATR < ATRThresholdRanging)
      regimeScore += 0;  // RANGING signal
   else if(currentATR > ATRThresholdTrending)
      regimeScore += 3;  // TRENDING signal
   else
      regimeScore += 2;  // TRANSITION
   
   // ADX scoring (0-3 points)
   if(currentADX < ADXThresholdRanging)
      regimeScore += 0;  // RANGING signal
   else if(currentADX > ADXThresholdTrending)
      regimeScore += 3;  // TRENDING signal
   else
      regimeScore += 2;  // TRANSITION
   
   // BB Width scoring (0-3 points)
   if(currentBBWidth < BBWidthThresholdRanging)
      regimeScore += 0;  // RANGING signal
   else if(currentBBWidth > BBWidthThresholdTrending)
      regimeScore += 3;  // TRENDING signal
   else
      regimeScore += 2;  // TRANSITION
   
   // Determine regime from score
   previousRegime = currentRegime;
   
   if(regimeScore <= 3)
      currentRegime = REGIME_RANGING;
   else if(regimeScore <= 6)
      currentRegime = REGIME_TRANSITION;
   else
      currentRegime = REGIME_TRENDING;
   
   // If regime changed, adjust parameters
   if(currentRegime != previousRegime)
   {
      AdjustParametersForRegime();
      
      // Log the regime change
      Print("═══════════════════════════════════════════════════════════════");
      Print("🔄 REGIME CHANGE DETECTED!");
      Print("Previous: ", GetRegimeName(previousRegime), " → New: ", GetRegimeName(currentRegime));
      Print("Regime Score: ", regimeScore, "/9");
      Print("ATR: ", DoubleToString(currentATR, 2), " | ADX: ", DoubleToString(currentADX, 1), 
            " | BB Width: $", DoubleToString(currentBBWidth, 2));
      Print("═══════════════════════════════════════════════════════════════");
   }
   
   lastRegimeCheck = TimeCurrent();
}

//+------------------------------------------------------------------+
//| Adjust EA parameters based on detected regime                    |
//+------------------------------------------------------------------+
void AdjustParametersForRegime()
{
   switch(currentRegime)
   {
      case REGIME_RANGING:
         // RANGING mode - tight grid, quick profits
         workingGridPercent = 0.25;
         workingReversalGaps = 3;
         workingTP = 35.0;
         workingSL = 25.0;
         workingMaxPos = 12;
         
         Print("📊 RANGING MODE ACTIVATED");
         Print("Grid Spacing: 0.25% (tight)");
         Print("Reversal Gaps: 3 (quick)");
         Print("TP/SL: $35/$25 (small)");
         Print("Max Positions: 12 (moderate)");
         break;
         
      case REGIME_TRANSITION:
         // TRANSITION mode - moderate settings
         workingGridPercent = 0.3;
         workingReversalGaps = 4;
         workingTP = 40.0;
         workingSL = 27.0;
         workingMaxPos = 15;
         
         Print("⚠️ TRANSITION MODE ACTIVATED");
         Print("Grid Spacing: 0.3% (moderate)");
         Print("Reversal Gaps: 4 (balanced)");
         Print("TP/SL: $40/$27 (medium)");
         Print("Max Positions: 15 (balanced)");
         break;
         
      case REGIME_TRENDING:
         // TRENDING mode - wide grid, bigger profits
         workingGridPercent = 0.4;
         workingReversalGaps = 5;
         workingTP = 50.0;
         workingSL = 30.0;
         workingMaxPos = 20;
         
         Print("🚀 TRENDING MODE ACTIVATED");
         Print("Grid Spacing: 0.4% (wide)");
         Print("Reversal Gaps: 5 (patient)");
         Print("TP/SL: $50/$30 (large)");
         Print("Max Positions: 20 (high capacity)");
         break;
   }
   
   // Recalculate grid spacing for current price
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2;
   gridSpacing = currentPrice * workingGridPercent / 100.0;
   
   Print("Grid Spacing Recalculated: $", DoubleToString(gridSpacing, 2));
}

//+------------------------------------------------------------------+
//| Check if should reverse trend direction                          |
//+------------------------------------------------------------------+
bool ShouldReverse(double currentPrice)
{
   if(ArraySize(positions) == 0)
      return false;
   
   double reversalDistance = gridSpacing * ReversalGaps;
   
   if(currentTrend == TREND_BUYING)
   {
      if(highestBuyPrice > 0)
      {
         if(currentPrice < (highestBuyPrice - reversalDistance))
         {
            return true;
         }
      }
   }
   else if(currentTrend == TREND_SELLING)
   {
      if(lowestSellPrice > 0)
      {
         if(currentPrice > (lowestSellPrice + reversalDistance))
         {
            return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Count actual open positions in MT5 with our magic number         |
//+------------------------------------------------------------------+
int CountActualPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Calculate global P&L across all positions                        |
//+------------------------------------------------------------------+
double CalculateGlobalPnL()
{
   // CORRECTED VERSION - Uses OrderCalcProfit for accurate calculations
   // Works for ANY broker, ANY contract size, ANY symbol
   
   double totalPnL = 0;
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      double positionProfit = 0;
      
      if(positions[i].direction == "BUY")
      {
         // BUY: Close at BID price
         if(OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, LotSize, 
                           positions[i].entryPrice, currentBid, positionProfit))
         {
            totalPnL += positionProfit;
         }
      }
      else  // SELL
      {
         // SELL: Close at ASK price
         if(OrderCalcProfit(ORDER_TYPE_SELL, _Symbol, LotSize, 
                           positions[i].entryPrice, currentAsk, positionProfit))
         {
            totalPnL += positionProfit;
         }
      }
   }
   
   return totalPnL;
}

//+------------------------------------------------------------------+
//| Check drawdown limit - TRIGGERS PERMANENT EMERGENCY STOP         |
//+------------------------------------------------------------------+
bool CheckDrawdownLimit()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double floatingPnL = CalculateGlobalPnL();
   double currentEquity = currentBalance + floatingPnL;
   
   if(currentEquity > peakEquity)
      peakEquity = currentEquity;
   
   double drawdownPct = ((currentEquity - peakEquity) / peakEquity) * 100.0;
   
   if(drawdownPct <= -MaxDrawdownPercent)
   {
      // CRITICAL: Max drawdown exceeded - PERMANENT STOP!
      Print("═══════════════════════════════════════════════════════════");
      Print("🛑 EMERGENCY STOP ACTIVATED");
      Print("═══════════════════════════════════════════════════════════");
      Print("⚠️ MAX DRAWDOWN LIMIT EXCEEDED: ", DoubleToString(drawdownPct, 2), "%");
      Print("   Max Allowed: ", MaxDrawdownPercent, "%");
      Print("   Peak Equity: $", DoubleToString(peakEquity, 2));
      Print("   Current Equity: $", DoubleToString(currentEquity, 2));
      Print("   Loss: $", DoubleToString(peakEquity - currentEquity, 2));
      Print("");
      Print("🚨 EA WILL STOP PERMANENTLY");
      Print("   All positions will be closed");
      Print("   No further trading allowed");
      Print("   Manual restart required");
      Print("═══════════════════════════════════════════════════════════");
      
      // Set emergency stop flag - EA will not trade again
      emergencyStop = true;
      emergencyStopTime = TimeCurrent();
      emergencyStopReason = StringFormat("Max Drawdown %.1f%% exceeded (limit: %.0f%%)", 
                                        MathAbs(drawdownPct), MaxDrawdownPercent);
      
      // Send alert to trader
      Alert("🛑 EA EMERGENCY STOP: Max Drawdown ", DoubleToString(MathAbs(drawdownPct), 1), 
            "% exceeded! Remove and re-attach EA to restart.");
      
      return true;
   }

   
   return false;
}

//+------------------------------------------------------------------+
//| Check if should pause at H4 zone                                 |
//+------------------------------------------------------------------+
bool CheckH4ZonePause()
{
   // Only pause if H4 zones are enabled
   if(!EnableH4Zones)
      return false;
   
   // BUY ONLY mode: Pause at H4 RESISTANCE
   if(workingDirection == TRADE_BUY_ONLY && inResistanceZone)
   {
      static datetime lastPausePrint = 0;
      if(TimeCurrent() - lastPausePrint > 300)  // Print once every 5 minutes
      {
         Print("⏸️ BUY ONLY: Paused at H4 RESISTANCE zone");
         Print("   Waiting for price to exit resistance before resuming...");
         lastPausePrint = TimeCurrent();
      }
      return true;  // Pause trading
   }
   
   // SELL ONLY mode: Pause at H4 SUPPORT
   if(workingDirection == TRADE_SELL_ONLY && inSupportZone)
   {
      static datetime lastPausePrint2 = 0;
      if(TimeCurrent() - lastPausePrint2 > 300)  // Print once every 5 minutes
      {
         Print("⏸️ SELL ONLY: Paused at H4 SUPPORT zone");
         Print("   Waiting for price to exit support before resuming...");
         lastPausePrint2 = TimeCurrent();
      }
      return true;  // Pause trading
   }
   
   // TRADE BOTH mode: Don't pause (trade both directions)
   return false;
}


//+------------------------------------------------------------------+
//| Open a position                                                  |
//+------------------------------------------------------------------+
bool OpenPosition(string direction, double price)
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      Print("❌ No connection to trade server");
      return false;
   }
   
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("❌ Trading not allowed in terminal");
      return false;
   }
   
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("❌ EA trading not allowed");
      return false;
   }
   
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > MaxSpread)
   {
      Print("⚠️ Spread too high: ", currentSpread, " > ", MaxSpread);
      return false;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.type = (direction == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price = (direction == "BUY") ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = "Momentum v4.1 H4SR";
   request.type_filling = ORDER_FILLING_IOC;
   
   // UNIVERSAL TP/SL CALCULATION v3 - With cent account detection
   // Uses tick value to calculate profit per price unit
   
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // ==================================================================
   // UNIVERSAL TP/SL CALCULATOR v4.0 - ITERATIVE LOT SIZE APPROACH
   // Works on ANY account type, ANY broker, ANY contract size!
   // ==================================================================
   
   Print("📊 Starting UNIVERSAL TP/SL Calculation v4.0...");
   Print("   Symbol: ", _Symbol);
   Print("   User Settings:");
   Print("   - Individual TP: $", IndividualTPDollars);
   Print("   - Individual SL: $", IndividualSLDollars);
   Print("   - User Lot Size: ", LotSize);
   
   // Get current price for testing
   double testPrice = (direction == "BUY") ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // STEP 1: Find what lot size gives us desired TP profit
   // We'll test with a small price movement (0.1% of price)
   double testDistance = testPrice * 0.001;  // 0.1% price movement
   double testPriceTo = testPrice + testDistance;
   
   Print("🔍 Testing profit calculation:");
   Print("   Test from: ", testPrice);
   Print("   Test to: ", testPriceTo);
   Print("   Test distance: ", testDistance, " (0.1% of price)");
   
   // Test profit for 1.0 lot with test distance
   double testProfit = 0;
   ENUM_ORDER_TYPE testOrderType = (direction == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   if(OrderCalcProfit(testOrderType, _Symbol, 1.0, testPrice, testPriceTo, testProfit))
   {
      double profitPer1Lot = MathAbs(testProfit);
      Print("   Profit for 1.0 lot over test distance: $", profitPer1Lot);
      
      if(profitPer1Lot > 0.000001)
      {
         // Calculate what lot size we need for desired TP
         double neededLotForTP = IndividualTPDollars / (profitPer1Lot / testDistance);
         Print("   Calculated lot needed for TP: ", neededLotForTP);
         
         // Calculate actual distances using USER's lot size
         double actualProfitPerDistance = profitPer1Lot * LotSize;
         double tpDistance = (IndividualTPDollars / actualProfitPerDistance) * testDistance;
         double slDistance = (IndividualSLDollars / actualProfitPerDistance) * testDistance;
         
         Print("📊 Final TP/SL Calculation:");
         Print("   Profit per ", testDistance, " price units at ", LotSize, " lot: $", actualProfitPerDistance);
         Print("   TP Distance needed: ", DoubleToString(tpDistance, 3), " price units");
         Print("   SL Distance needed: ", DoubleToString(slDistance, 3), " price units");
         
         // Sanity check
         double tpPercent = (tpDistance / testPrice) * 100.0;
         double slPercent = (slDistance / testPrice) * 100.0;
         
         Print("   TP Distance: ", DoubleToString(tpPercent, 2), "% of price");
         Print("   SL Distance: ", DoubleToString(slPercent, 2), "% of price");
         
         if(tpDistance > testPrice * 0.5 || slDistance > testPrice * 0.5)
         {
            Print("⚠️ WARNING: TP/SL distances > 50% of price!");
            Print("   This will likely cause Error 10016");
            Print("   SOLUTION: Increase LotSize significantly");
            Print("   Recommended lot: ", DoubleToString(neededLotForTP, 2));
            Print("   Your current lot: ", LotSize);
            Print("   Multiplier needed: ", DoubleToString(neededLotForTP / LotSize, 1), "x");
         }
         
         // Set TP and SL prices
         if(direction == "BUY")
         {
            request.tp = request.price + tpDistance;
            request.sl = request.price - slDistance;
         }
         else  // SELL
         {
            request.tp = request.price - tpDistance;
            request.sl = request.price + slDistance;
         }
         
         // CRITICAL SAFETY CHECK: Prevent negative or invalid TP/SL
         if(request.sl <= 0 || request.tp <= 0)
         {
            Print("❌ CRITICAL ERROR: TP/SL calculation produced invalid prices!");
            Print("   Entry: ", request.price);
            Print("   TP: ", request.tp);
            Print("   SL: ", request.sl);
            Print("   ");
            Print("🛑 YOUR LOT SIZE IS TOO SMALL FOR THIS BROKER!");
            Print("   Current lot: ", LotSize);
            Print("   Recommended lot: ", DoubleToString(neededLotForTP, 2));
            Print("   ");
            Print("💡 TWO OPTIONS:");
            Print("   1. Increase LotSize to ", DoubleToString(neededLotForTP, 2));
            Print("   2. Switch to standard Gold contract (XAUUSDc not XAUUSDc.M)");
            Print("   ");
            Print("⚠️ Trading without TP/SL to prevent Error 10016");
            Print("   EA will use Global TP/SL only");
            
            // Clear TP/SL and continue
            request.tp = 0;
            request.sl = 0;
         }
         
         Print("   Entry: ", request.price);
         Print("   TP: ", request.tp);
         Print("   SL: ", request.sl);
      }
      else
      {
         Print("❌ ERROR: Profit calculation returned zero!");
         Print("   Cannot calculate TP/SL distances");
         return false;
      }
   }
   else
   {
      Print("❌ ERROR: OrderCalcProfit failed!");
      Print("   Falling back to NO TP/SL");
      request.tp = 0;
      request.sl = 0;
   }
   
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   request.price = NormalizeDouble(request.price, digits);
   request.tp = NormalizeDouble(request.tp, digits);
   request.sl = NormalizeDouble(request.sl, digits);
   
   double margin;
   if(!OrderCalcMargin(request.type, _Symbol, LotSize, request.price, margin))
   {
      Print("❌ Cannot calculate margin");
      return false;
   }
   
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > freeMargin * 0.5)
   {
      Print("⚠️ Insufficient margin: need ", margin, ", available ", freeMargin);
      return false;
   }
   
   int attempts = 0;
   bool success = false;
   
   while(attempts < 3 && !success)
   {
      ResetLastError();
      
      if(OrderSend(request, result))
      {
         if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
         {
            success = true;
            totalTrades++;
            
            int newSize = ArraySize(positions) + 1;
            ArrayResize(positions, newSize);
            positions[newSize-1].ticket = result.order;
            positions[newSize-1].entryPrice = result.price;
            positions[newSize-1].direction = direction;
            positions[newSize-1].entryTime = TimeCurrent();
            
            if(direction == "BUY")
            {
               if(highestBuyPrice == 0 || result.price > highestBuyPrice)
                  highestBuyPrice = result.price;
               if(lowestBuyPrice == 0 || result.price < lowestBuyPrice)
                  lowestBuyPrice = result.price;
            }
            else
            {
               if(highestSellPrice == 0 || result.price > highestSellPrice)
                  highestSellPrice = result.price;
               if(lowestSellPrice == 0 || result.price < lowestSellPrice)
                  lowestSellPrice = result.price;
            }
            
            Print("✅ ", direction, " opened at ", DoubleToString(result.price, digits), 
                  " | TP: $", DoubleToString(IndividualTPDollars, 2),
                  " | SL: $", DoubleToString(IndividualSLDollars, 2),
                  " | Positions: ", ArraySize(positions), "/", MaxPositions);
            
            return true;
         }
      }
      
      Print("⚠️ Order attempt ", attempts+1, " failed: ", GetErrorDescription(result.retcode));
      attempts++;
      
      if(attempts < 3)
      {
         Sleep(1000);
         request.price = (direction == "BUY") ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         request.price = NormalizeDouble(request.price, digits);
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Close all positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   if(ArraySize(positions) == 0)
      return;
   
   Print("🔄 Closing all ", ArraySize(positions), " positions - Reason: ", reason);
   
   // Set group close flag (for TP/SL protection logic)
   sessionStats.isGroupClose = true;
   
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      ClosePositionByTicket(positions[i].ticket);
   }
   
   // Update session stats from closed deals
   UpdateSessionStatsFromHistory();
   
   // Reset group close flag
   sessionStats.isGroupClose = false;
   
   ArrayResize(positions, 0);
   highestBuyPrice = 0;
   lowestBuyPrice = 0;
   highestSellPrice = 0;
   lowestSellPrice = 0;
}

//+------------------------------------------------------------------+
//| Close position by ticket                                         |
//+------------------------------------------------------------------+
bool ClosePositionByTicket(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = PositionGetString(POSITION_SYMBOL);
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   request.deviation = 10;
   request.magic = MagicNumber;
   request.type_filling = ORDER_FILLING_IOC;
   
   int attempts = 0;
   while(attempts < 3)
   {
      if(OrderSend(request, result))
      {
         if(result.retcode == TRADE_RETCODE_DONE)
            return true;
      }
      
      attempts++;
      if(attempts < 3)
         Sleep(500);
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Update session statistics from closed deals                      |
//+------------------------------------------------------------------+
void UpdateSessionStatsFromHistory()
{
   // Get current balance to calculate net P&L
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   // Check deals history from session start
   if(!HistorySelect(sessionStats.sessionStartTime, TimeCurrent()))
      return;
   
   // Reset counters (we'll recalculate from all history)
   int profitCount = 0;
   int lossCount = 0;
   double profitAmount = 0;
   double lossAmount = 0;
   double largestWin = 0;
   double largestLoss = 0;
   
   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      
      // Only count deals for this EA (by magic number and symbol)
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber)
         continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
         continue;
      
      // Only count OUT deals (position closes)
      ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(dealEntry != DEAL_ENTRY_OUT)
         continue;
      
      double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      double dealSwap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      double dealCommission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      double dealNetProfit = dealProfit + dealSwap + dealCommission;
      
      if(dealNetProfit > 0)
      {
         profitCount++;
         profitAmount += dealNetProfit;
         if(dealNetProfit > largestWin)
            largestWin = dealNetProfit;
      }
      else if(dealNetProfit < 0)
      {
         lossCount++;
         lossAmount += dealNetProfit;  // Already negative
         if(dealNetProfit < largestLoss)
            largestLoss = dealNetProfit;
      }
   }
   
   // Update session stats
   sessionStats.totalClosedProfits = profitCount;
   sessionStats.totalClosedLosses = lossCount;
   sessionStats.totalProfitAmount = profitAmount;
   sessionStats.totalLossAmount = lossAmount;
   sessionStats.sessionNetPL = profitAmount + lossAmount;
   sessionStats.largestWin = largestWin;
   sessionStats.largestLoss = largestLoss;
}

//+------------------------------------------------------------------+
//| Update position tracking                                         |
//+------------------------------------------------------------------+
void UpdatePositionTracking()
{
   ArrayResize(positions, 0);
   highestBuyPrice = 0;
   lowestBuyPrice = 0;
   highestSellPrice = 0;
   lowestSellPrice = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            int newSize = ArraySize(positions) + 1;
            ArrayResize(positions, newSize);
            
            positions[newSize-1].ticket = ticket;
            positions[newSize-1].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            positions[newSize-1].direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
            positions[newSize-1].entryTime = (datetime)PositionGetInteger(POSITION_TIME);
            
            if(positions[newSize-1].direction == "BUY")
            {
               if(highestBuyPrice == 0 || positions[newSize-1].entryPrice > highestBuyPrice)
                  highestBuyPrice = positions[newSize-1].entryPrice;
               if(lowestBuyPrice == 0 || positions[newSize-1].entryPrice < lowestBuyPrice)
                  lowestBuyPrice = positions[newSize-1].entryPrice;
            }
            else
            {
               if(highestSellPrice == 0 || positions[newSize-1].entryPrice > highestSellPrice)
                  highestSellPrice = positions[newSize-1].entryPrice;
               if(lowestSellPrice == 0 || positions[newSize-1].entryPrice < lowestSellPrice)
                  lowestSellPrice = positions[newSize-1].entryPrice;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check for closed positions and track consecutive SLs            |
//+------------------------------------------------------------------+
void CheckClosedPositions()
{
   // Check deal history for recently closed positions
   if(!HistorySelect(lastPositionCloseTime, TimeCurrent()))
      return;
   
   int dealsTotal = HistoryDealsTotal();
   
   for(int i = dealsTotal - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket > 0)
      {
         if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol &&
            HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == MagicNumber)
         {
            long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
            
            // Only process position exits (not entries)
            if(dealEntry == DEAL_ENTRY_OUT)
            {
               double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
               double swap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
               double commission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
               double totalPnL = profit + swap + commission;
               
               datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
               
               // Update last close time
               if(dealTime > lastPositionCloseTime)
               {
                  lastPositionCloseTime = dealTime;
                  
                  // Update session statistics
                  UpdateSessionStatsFromHistory();
                  
                  // Only check for individual SL if NOT in group close mode
                  if(!sessionStats.isGroupClose)
                  {
                     // Check if this was a stop loss (loss close to SL amount)
                     double expectedSLLoss = -IndividualSLDollars;
                     bool wasSL = (totalPnL < 0 && totalPnL >= expectedSLLoss - 5.0 && totalPnL <= expectedSLLoss + 5.0);
                     
                     if(wasSL)
                     {
                        // This was a stop loss
                        consecutiveSLs++;
                        lastPositionWasWin = false;
                        
                        Print("❌ STOP LOSS HIT #", consecutiveSLs, " | Loss: $", DoubleToString(totalPnL, 2));
                        
                        // Check if we've hit the max consecutive SLs
                        if(consecutiveSLs >= MaxConsecutiveSLs)
                        {
                           Print("⛔ MAX CONSECUTIVE STOP LOSSES HIT (", consecutiveSLs, "/", MaxConsecutiveSLs, ")");
                           Print("⛔ EA STOPPED - Close all positions and halt trading");
                           
                           // Close all remaining positions
                           CloseAllPositions("Max Consecutive SLs");
                           
                           // Stop EA
                           eaStopped = true;
                           tradingPaused = true;
                           
                           UpdateInfoPanel();
                           
                           Alert("⛔ MOMENTUM EA STOPPED: ", consecutiveSLs, " consecutive stop losses!");
                           
                           return;
                        }
                     }
                     else if(totalPnL > 0)
                     {
                        // This was a winning trade - reset counter
                        if(consecutiveSLs > 0)
                        {
                           Print("✅ WINNING TRADE - Consecutive SL counter reset from ", consecutiveSLs, " to 0");
                        }
                        consecutiveSLs = 0;
                        lastPositionWasWin = true;
                     }
                  }
                  else
                  {
                     Print("📊 Group close detected - skipping individual SL protection");
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check and reset daily tracking                                   |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   
   MqlDateTime last;
   TimeToStruct(lastDailyReset, last);
   
   if(now.day != last.day)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      lastDailyReset = TimeCurrent();
      dailyTargetReached = false;
      Print("📅 Daily reset - New day started");
   }
   
   if(EnableDailyTarget && !dailyTargetReached)
   {
      double dailyProfit = AccountInfoDouble(ACCOUNT_BALANCE) - dailyStartBalance;
      if(dailyProfit >= DailyProfitTarget)
      {
         Print("🎯 Daily profit target reached: $", DoubleToString(dailyProfit, 2));
         CloseAllPositions("Daily Target Reached");
         dailyTargetReached = true;
         currentTrend = TREND_WAITING;
      }
   }
}

//+------------------------------------------------------------------+
//| Chart event handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_KEYDOWN)
   {
      if(lparam == 'H' || lparam == 'h')
      {
         panelVisible = !panelVisible;
         if(panelVisible)
            CreateInfoPanel();
         else
            DeleteInfoPanel();
      }
   }
   
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == panelPrefix + "BtnCloseAll")
      {
         HandleCloseAllButton();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      }
      else if(sparam == panelPrefix + "BtnProfits")
      {
         HandleCloseProfitsButton();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      }
      else if(sparam == panelPrefix + "BtnPause")
      {
         HandlePauseButton();
      }
      // DIRECTION SWITCH BUTTONS (NO POSITION CLOSING!)
      else if(sparam == panelPrefix + "BtnBuyOnly")
      {
         HandleDirectionSwitch(TRADE_BUY_ONLY);
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      }
      else if(sparam == panelPrefix + "BtnSellOnly")
      {
         HandleDirectionSwitch(TRADE_SELL_ONLY);
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      }
      else if(sparam == panelPrefix + "BtnBoth")
      {
         HandleDirectionSwitch(TRADE_BOTH);
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      }
   }
}

//+------------------------------------------------------------------+
//| Handle buttons                                                    |
//+------------------------------------------------------------------+
void HandleCloseAllButton()
{
   CloseAllPositions("Manual Close All");
   currentTrend = TREND_WAITING;
   lastTrendPrice = 0;
   UpdateInfoPanel();
}

void HandleCloseProfitsButton()
{
   int closed = 0;
   
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      double pnl = 0;
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      
      if(positions[i].direction == "BUY")
         pnl = (currentBid - positions[i].entryPrice) * LotSize * 100;
      else
         pnl = (positions[i].entryPrice - currentAsk) * LotSize * 100;
      
      if(pnl > 0)
      {
         if(ClosePositionByTicket(positions[i].ticket))
            closed++;
      }
   }
   
   Print("✅ Closed ", closed, " profitable positions");
   UpdatePositionTracking();
   
   // CRITICAL FIX: Reset trend if ALL positions closed
   if(ArraySize(positions) == 0)
   {
      Print("🔄 All positions closed - Resetting to WAITING mode");
      currentTrend = TREND_WAITING;
      lastTrendPrice = 0;
      highestBuyPrice = 0;
      lowestBuyPrice = 0;
      highestSellPrice = 0;
      lowestSellPrice = 0;
   }
   
   UpdateInfoPanel();
   DrawGridLevels();
}

void HandlePauseButton()
{
   tradingPaused = !tradingPaused;
   
   string buttonText = tradingPaused ? "▶ RESUME" : "⏸ PAUSE";
   color buttonColor = tradingPaused ? clrLimeGreen : clrOrange;
   
   ObjectSetString(0, panelPrefix + "BtnPause", OBJPROP_TEXT, buttonText);
   ObjectSetInteger(0, panelPrefix + "BtnPause", OBJPROP_BGCOLOR, buttonColor);
   
   Print(tradingPaused ? "⏸ EA PAUSED" : "▶ EA RESUMED");
}

//+------------------------------------------------------------------+
//| Handle Direction Switch Button (NO POSITION CLOSING!)            |
//+------------------------------------------------------------------+
void HandleDirectionSwitch(TradingDirection newDirection)
{
   TradingDirection oldDirection = workingDirection;
   workingDirection = newDirection;
   
   // Update button colors to show active direction
   UpdateDirectionButtons();
   
   string directionText = "";
   if(newDirection == TRADE_BUY_ONLY)
      directionText = "BUY ONLY";
   else if(newDirection == TRADE_SELL_ONLY)
      directionText = "SELL ONLY";
   else
      directionText = "BOTH";
   
   Print("🔄 DIRECTION SWITCHED: ", directionText);
   Print("   Existing positions: ", ArraySize(positions), " (NOT CLOSED)");
   Print("   New trades will follow: ", directionText, " mode");
   
   // IMPORTANT: We do NOT close existing positions!
   // We do NOT reset trend
   // We only change what NEW positions can be opened
   
   UpdateInfoPanel();
}

//+------------------------------------------------------------------+
//| Update Direction Button Colors                                   |
//+------------------------------------------------------------------+
void UpdateDirectionButtons()
{
   // Reset all buttons to inactive color
   ObjectSetInteger(0, panelPrefix + "BtnBuyOnly", OBJPROP_BGCOLOR, C'50,80,120');    // Dim blue
   ObjectSetInteger(0, panelPrefix + "BtnSellOnly", OBJPROP_BGCOLOR, C'120,50,50');   // Dim red
   ObjectSetInteger(0, panelPrefix + "BtnBoth", OBJPROP_BGCOLOR, C'50,80,50');        // Dim green
   
   // Highlight active button
   if(workingDirection == TRADE_BUY_ONLY)
      ObjectSetInteger(0, panelPrefix + "BtnBuyOnly", OBJPROP_BGCOLOR, clrDodgerBlue);  // Bright blue
   else if(workingDirection == TRADE_SELL_ONLY)
      ObjectSetInteger(0, panelPrefix + "BtnSellOnly", OBJPROP_BGCOLOR, clrOrangeRed);  // Bright red
   else if(workingDirection == TRADE_BOTH)
      ObjectSetInteger(0, panelPrefix + "BtnBoth", OBJPROP_BGCOLOR, clrGreen);          // Bright green
}

//+------------------------------------------------------------------+
//| Get error description                                            |
//+------------------------------------------------------------------+
string GetErrorDescription(uint retcode)
{
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE: return "Requote";
      case TRADE_RETCODE_REJECT: return "Reject";
      case TRADE_RETCODE_TIMEOUT: return "Timeout";
      case TRADE_RETCODE_INVALID_PRICE: return "Invalid price";
      case TRADE_RETCODE_PRICE_CHANGED: return "Price changed";
      case TRADE_RETCODE_NO_MONEY: return "No money";
      case TRADE_RETCODE_MARKET_CLOSED: return "Market closed";
      case TRADE_RETCODE_CONNECTION: return "Connection error";
      default: return "Error " + IntegerToString(retcode);
   }
}

//+------------------------------------------------------------------+
//| Draw grid levels                                                 |
//+------------------------------------------------------------------+
void DrawGridLevels()
{
   ObjectsDeleteAll(0, "GridLevel_");
   
   if(!ShowGridLines)
      return;
   
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2;
   
   // Draw existing position levels
   for(int i = 0; i < ArraySize(positions); i++)
   {
      string name = "GridLevel_" + IntegerToString(i);
      color lineColor = (positions[i].direction == "BUY") ? BuyLevelColor : SellLevelColor;
      
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, positions[i].entryPrice);
      ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);
      
      string labelName = name + "_Label";
      string labelText = positions[i].direction + " " + DoubleToString(positions[i].entryPrice, digits);
      
      ObjectCreate(0, labelName, OBJ_TEXT, 0, TimeCurrent(), positions[i].entryPrice);
      ObjectSetString(0, labelName, OBJPROP_TEXT, labelText);
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, lineColor);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 11);
      ObjectSetString(0, labelName, OBJPROP_FONT, "Segoe UI Semibold");
      ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, labelName, OBJPROP_BACK, true);
      ObjectSetInteger(0, labelName, OBJPROP_ZORDER, 1);
   }
   
   // Draw NEXT potential grid levels
   if(currentTrend == TREND_BUYING && highestBuyPrice > 0)
   {
      // Next BUY level
      double nextBuyPrice = highestBuyPrice + gridSpacing;
      string name = "GridLevel_NextBuy";
      
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, nextBuyPrice);
      ObjectSetInteger(0, name, OBJPROP_COLOR, BuyLevelColor);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);
      
      string labelName = name + "_Label";
      string labelText = "NEXT BUY → " + DoubleToString(nextBuyPrice, digits);
      
      ObjectCreate(0, labelName, OBJ_TEXT, 0, TimeCurrent(), nextBuyPrice);
      ObjectSetString(0, labelName, OBJPROP_TEXT, labelText);
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, BuyLevelColor);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 11);
      ObjectSetString(0, labelName, OBJPROP_FONT, "Segoe UI");
      ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, labelName, OBJPROP_BACK, true);
      ObjectSetInteger(0, labelName, OBJPROP_ZORDER, 1);
   }
   else if(currentTrend == TREND_SELLING && lowestSellPrice > 0)
   {
      // Next SELL level
      double nextSellPrice = lowestSellPrice - gridSpacing;
      string name = "GridLevel_NextSell";
      
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, nextSellPrice);
      ObjectSetInteger(0, name, OBJPROP_COLOR, SellLevelColor);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);
      
      string labelName = name + "_Label";
      string labelText = "NEXT SELL → " + DoubleToString(nextSellPrice, digits);
      
      ObjectCreate(0, labelName, OBJ_TEXT, 0, TimeCurrent(), nextSellPrice);
      ObjectSetString(0, labelName, OBJPROP_TEXT, labelText);
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, SellLevelColor);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 11);
      ObjectSetString(0, labelName, OBJPROP_FONT, "Segoe UI");
      ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, labelName, OBJPROP_BACK, true);
      ObjectSetInteger(0, labelName, OBJPROP_ZORDER, 1);
   }
   else if(currentTrend == TREND_WAITING)
   {
      // Show potential first positions for MOMENTUM TRADING
      // BUY when price RISES (momentum up), SELL when price FALLS (momentum down)
      double potentialBuyPrice = currentPrice + gridSpacing;   // BUY ABOVE current price
      double potentialSellPrice = currentPrice - gridSpacing;  // SELL BELOW current price
      
      // Potential BUY (only show if BUY is allowed)
      if(workingDirection == TRADE_BOTH || workingDirection == TRADE_BUY_ONLY)
      {
         string nameBuy = "GridLevel_PotentialBuy";
         ObjectCreate(0, nameBuy, OBJ_HLINE, 0, 0, potentialBuyPrice);
         ObjectSetInteger(0, nameBuy, OBJPROP_COLOR, BuyLevelColor);
         ObjectSetInteger(0, nameBuy, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(0, nameBuy, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, nameBuy, OBJPROP_BACK, true);
         ObjectSetInteger(0, nameBuy, OBJPROP_SELECTABLE, false);
         
         string labelBuy = nameBuy + "_Label";
         ObjectCreate(0, labelBuy, OBJ_TEXT, 0, TimeCurrent(), potentialBuyPrice);
         ObjectSetString(0, labelBuy, OBJPROP_TEXT, "BUY? " + DoubleToString(potentialBuyPrice, digits));
         ObjectSetInteger(0, labelBuy, OBJPROP_COLOR, BuyLevelColor);
         ObjectSetInteger(0, labelBuy, OBJPROP_FONTSIZE, 11);
         ObjectSetInteger(0, labelBuy, OBJPROP_ANCHOR, ANCHOR_LEFT);
         ObjectSetInteger(0, labelBuy, OBJPROP_BACK, true);
      }
      
      // Potential SELL (only show if SELL is allowed)
      if(workingDirection == TRADE_BOTH || workingDirection == TRADE_SELL_ONLY)
      {
         string nameSell = "GridLevel_PotentialSell";
         ObjectCreate(0, nameSell, OBJ_HLINE, 0, 0, potentialSellPrice);
         ObjectSetInteger(0, nameSell, OBJPROP_COLOR, SellLevelColor);
         ObjectSetInteger(0, nameSell, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(0, nameSell, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, nameSell, OBJPROP_BACK, true);
         ObjectSetInteger(0, nameSell, OBJPROP_SELECTABLE, false);
         
         string labelSell = nameSell + "_Label";
         ObjectCreate(0, labelSell, OBJ_TEXT, 0, TimeCurrent(), potentialSellPrice);
         ObjectSetString(0, labelSell, OBJPROP_TEXT, "SELL? " + DoubleToString(potentialSellPrice, digits));
         ObjectSetInteger(0, labelSell, OBJPROP_COLOR, SellLevelColor);
         ObjectSetInteger(0, labelSell, OBJPROP_FONTSIZE, 11);
         ObjectSetInteger(0, labelSell, OBJPROP_ANCHOR, ANCHOR_LEFT);
         ObjectSetInteger(0, labelSell, OBJPROP_BACK, true);
      }
   }
}

//+------------------------------------------------------------------+
//| Panel functions                                                  |
//+------------------------------------------------------------------+
void CreateInfoPanel()
{
   DeleteInfoPanel();
   
   int x = 10, y = 20, width = 360, height = 368;  // Increased for direction buttons
   
   ObjectCreate(0, panelPrefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YSIZE, height);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BGCOLOR, C'20,20,25');
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_COLOR, C'218,165,32');
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_ZORDER, 100);
   
   // HEADER
   CreatePanelLabel(panelPrefix + "Header", x + 12, y + 8, EA_NAME + " v" + EA_VERSION, C'218,165,32', 10);
   
   // ROW 1: Trend + Mode
   CreatePanelLabel(panelPrefix + "Trend", x + 12, y + 28, "", clrWhite, 9);
   CreatePanelLabel(panelPrefix + "Mode", x + 180, y + 28, "", clrSilver, 8);
   
   // ROW 2: Current Price (BIG)
   CreatePanelLabel(panelPrefix + "CurrentPrice", x + 12, y + 48, "", clrYellow, 12);
   
   // ROW 3: Next Buy/Sell levels
   CreatePanelLabel(panelPrefix + "NextBuy", x + 12, y + 72, "", clrDodgerBlue, 8);
   CreatePanelLabel(panelPrefix + "NextSell", x + 180, y + 72, "", clrOrangeRed, 8);
   
   // ROW 4: Positions + Global P&L
   CreatePanelLabel(panelPrefix + "Positions", x + 12, y + 92, "", clrWhite, 9);
   CreatePanelLabel(panelPrefix + "GlobalPnL", x + 180, y + 92, "", clrWhite, 9);
   
   // ROW 5: Balance + Equity
   CreatePanelLabel(panelPrefix + "Balance", x + 12, y + 112, "", clrWhite, 8);
   CreatePanelLabel(panelPrefix + "Equity", x + 180, y + 112, "", clrWhite, 9);
   
   // ROW 6: Margin Level + DD%
   CreatePanelLabel(panelPrefix + "Margin", x + 12, y + 132, "", clrWhite, 8);
   CreatePanelLabel(panelPrefix + "Drawdown", x + 180, y + 132, "", clrWhite, 8);
   
   // ROW 7: Daily P&L + Session P&L
   CreatePanelLabel(panelPrefix + "Daily", x + 12, y + 152, "", clrWhite, 8);
   CreatePanelLabel(panelPrefix + "SessionPL", x + 180, y + 152, "", clrWhite, 8);
   
   // ROW 8: Win Rate + Closed Stats
   CreatePanelLabel(panelPrefix + "WinRate", x + 12, y + 172, "", clrWhite, 8);
   CreatePanelLabel(panelPrefix + "ClosedStats", x + 100, y + 172, "", clrSilver, 8);
   
   // ROW 9: Grid + TP/SL
   CreatePanelLabel(panelPrefix + "Grid", x + 12, y + 192, "", clrSilver, 8);
   CreatePanelLabel(panelPrefix + "TPSL", x + 180, y + 192, "", clrSilver, 8);
   
   // ROW 10: Consecutive SLs + Max DD
   CreatePanelLabel(panelPrefix + "ConsecSLs", x + 12, y + 212, "", clrWhite, 8);
   CreatePanelLabel(panelPrefix + "MaxDD", x + 180, y + 212, "", clrSilver, 8);
   
   // ROW 11: Auto-detection or H4 status (optional)
   CreatePanelLabel(panelPrefix + "Regime", x + 12, y + 232, "", clrSilver, 8);
   
   
   // ROW 12: H4 Resistance + Support values (BOLD)
   CreatePanelLabel(panelPrefix + "H4Resistance", x + 12, y + 250, "", clrOrangeRed, 10);
   CreatePanelLabel(panelPrefix + "H4Support", x + 180, y + 250, "", clrLimeGreen, 10);
   
   // BUTTONS ROW 1: Direction Switch
   CreatePanelButton(panelPrefix + "BtnBuyOnly", x + 12, y + 273, 108, 26, "BUY ONLY", clrDodgerBlue, clrWhite, 8);
   CreatePanelButton(panelPrefix + "BtnSellOnly", x + 126, y + 273, 108, 26, "SELL ONLY", clrOrangeRed, clrWhite, 8);
   CreatePanelButton(panelPrefix + "BtnBoth", x + 240, y + 273, 108, 26, "BOTH", clrGreen, clrWhite, 8);
   
   // BUTTONS ROW 2: Actions
   CreatePanelButton(panelPrefix + "BtnCloseAll", x + 12, y + 303, 108, 26, "CLOSE ALL", clrDarkRed, clrWhite, 8);
   CreatePanelButton(panelPrefix + "BtnProfits", x + 126, y + 303, 108, 26, "PROFITS", clrDarkGreen, clrWhite, 8);
   CreatePanelButton(panelPrefix + "BtnPause", x + 240, y + 303, 108, 26, "PAUSE", clrOrange, clrWhite, 8);
   
   // FOOTER
   CreatePanelLabel(panelPrefix + "Footer", x + 12, y + 338, "TORAMA | torama.money", C'218,165,32', 7);
}

void DeleteInfoPanel()
{
   ObjectsDeleteAll(0, panelPrefix);
}

void CreatePanelLabel(string name, int x, int y, string text, color clr, int size)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI Semibold");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 101);
}

void CreatePanelButton(string name, int x, int y, int width, int height, string text, color bgColor, color textColor, int fontSize)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'100,100,100');
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI Semibold");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 102);
}

void UpdateInfoPanel()
{
   if(!panelVisible)
      return;
   
   // Update direction button colors
   UpdateDirectionButtons();
   
   // Get current price
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (currentAsk + currentBid) / 2.0;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // ROW 1: Trend + Mode
   string trendText = "";
   color trendColor = clrWhite;
   if(emergencyStop)
   {
      // EMERGENCY STOP has highest priority
      trendText = "🛑 EMERGENCY STOP";
      trendColor = clrRed;
   }
   else if(eaStopped)
   {
      trendText = "⛔ STOPPED";
      trendColor = clrRed;
   }
   else if(currentTrend == TREND_BUYING)
   {
      trendText = "🔵 BUYING UP";
      trendColor = clrDodgerBlue;
   }
   else if(currentTrend == TREND_SELLING)
   {
      trendText = "🔴 SELLING DOWN";
      trendColor = clrOrangeRed;
   }
   else if(tradingPaused)
   {
      trendText = "⏸ PAUSED";
      trendColor = clrOrange;
   }
   else
   {
      trendText = "⏳ WAITING";
      trendColor = clrGray;
   }
   
   ObjectSetString(0, panelPrefix + "Trend", OBJPROP_TEXT, trendText);
   ObjectSetInteger(0, panelPrefix + "Trend", OBJPROP_COLOR, trendColor);
   
   // Mode
   string modeText = "";
   if(workingDirection == TRADE_BOTH)
      modeText = "Mode: BOTH";
   else if(workingDirection == TRADE_BUY_ONLY)
      modeText = "Mode: BUY ONLY";
   else if(workingDirection == TRADE_SELL_ONLY)
      modeText = "Mode: SELL ONLY";
   
   ObjectSetString(0, panelPrefix + "Mode", OBJPROP_TEXT, modeText);
   
   // Show emergency stop reason if active
   if(emergencyStop && ObjectFind(0, panelPrefix + "EmergencyReason") >= 0)
   {
      ObjectSetString(0, panelPrefix + "EmergencyReason", OBJPROP_TEXT, emergencyStopReason);
      ObjectSetInteger(0, panelPrefix + "EmergencyReason", OBJPROP_COLOR, clrRed);
   }
   
   // ROW 2: Current Price (BIG)
   string priceText = StringFormat("PRICE: %s", DoubleToString(currentPrice, digits));
   ObjectSetString(0, panelPrefix + "CurrentPrice", OBJPROP_TEXT, priceText);
   
   // ROW 3: Next Buy/Sell levels
   string nextBuyText = "";
   string nextSellText = "";
   
   if(gridSpacing > 0)
   {
      double nextBuyPrice = 0;
      double nextSellPrice = 0;
      
      if(currentTrend == TREND_BUYING && highestBuyPrice > 0)
      {
         nextBuyPrice = highestBuyPrice + gridSpacing;
         nextBuyText = StringFormat("Next BUY: %s", DoubleToString(nextBuyPrice, digits));
      }
      else if(currentTrend == TREND_WAITING && (workingDirection == TRADE_BOTH || workingDirection == TRADE_BUY_ONLY))
      {
         nextBuyPrice = currentPrice + (currentPrice * GridSpacingPercent / 100.0);
         nextBuyText = StringFormat("Next BUY: %s", DoubleToString(nextBuyPrice, digits));
      }
      
      if(currentTrend == TREND_SELLING && lowestSellPrice > 0)
      {
         nextSellPrice = lowestSellPrice - gridSpacing;
         nextSellText = StringFormat("Next SELL: %s", DoubleToString(nextSellPrice, digits));
      }
      else if(currentTrend == TREND_WAITING && (workingDirection == TRADE_BOTH || workingDirection == TRADE_SELL_ONLY))
      {
         nextSellPrice = currentPrice - (currentPrice * GridSpacingPercent / 100.0);
         nextSellText = StringFormat("Next SELL: %s", DoubleToString(nextSellPrice, digits));
      }
   }
   
   ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, nextBuyText);
   ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, nextSellText);
   
   // ROW 4: Positions + Global P&L
   int buyCount = 0, sellCount = 0;
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(positions[i].direction == "BUY") buyCount++;
      else sellCount++;
   }
   
   string posText = StringFormat("Pos: %d/%d (B:%d S:%d)", 
                                  ArraySize(positions), MaxPositions, buyCount, sellCount);
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT, posText);
   
   double globalPnL = CalculateGlobalPnL();
   color pnlColor = (globalPnL >= 0) ? clrLimeGreen : clrRed;
   string pnlText = StringFormat("P&L: $%.2f/$%.0f", globalPnL, GlobalTPDollars);
   ObjectSetString(0, panelPrefix + "GlobalPnL", OBJPROP_TEXT, pnlText);
   ObjectSetInteger(0, panelPrefix + "GlobalPnL", OBJPROP_COLOR, pnlColor);
   
   // ROW 5: Balance + Equity
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);  // Use actual account equity!
   
   string balText = StringFormat("Bal: $%.2f", balance);
   ObjectSetString(0, panelPrefix + "Balance", OBJPROP_TEXT, balText);
   
   color equityColor = clrWhite;
   if(equity > balance) equityColor = clrLimeGreen;
   else if(equity < balance) equityColor = clrOrange;
   
   string equityText = StringFormat("Eq: $%.2f", equity);
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT, equityText);
   ObjectSetInteger(0, panelPrefix + "Equity", OBJPROP_COLOR, equityColor);
   
   // ROW 6: Margin Level + DD%
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double marginLevel = (margin > 0) ? (equity / margin * 100) : 0;
   
   color marginColor = clrWhite;
   if(marginLevel > 500) marginColor = clrLimeGreen;
   else if(marginLevel > 200) marginColor = clrYellow;
   else marginColor = clrRed;
   
   string marginText = StringFormat("Margin: %.0f%%", marginLevel);
   ObjectSetString(0, panelPrefix + "Margin", OBJPROP_TEXT, marginText);
   ObjectSetInteger(0, panelPrefix + "Margin", OBJPROP_COLOR, marginColor);
   
   double ddPct = peakEquity > 0 ? ((equity - peakEquity) / peakEquity * 100) : 0;
   color ddColor = (ddPct >= -5) ? clrLimeGreen : (ddPct >= -10) ? clrYellow : clrRed;
   string ddText = StringFormat("DD: %.1f%%", ddPct);
   ObjectSetString(0, panelPrefix + "Drawdown", OBJPROP_TEXT, ddText);
   ObjectSetInteger(0, panelPrefix + "Drawdown", OBJPROP_COLOR, ddColor);
   
   // ROW 7: Daily P&L + Session P&L
   double dailyPnL = balance - dailyStartBalance;
   color dailyColor = (dailyPnL >= 0) ? clrLimeGreen : clrRed;
   string dailyText = StringFormat("Daily: $%.2f", dailyPnL);
   ObjectSetString(0, panelPrefix + "Daily", OBJPROP_TEXT, dailyText);
   ObjectSetInteger(0, panelPrefix + "Daily", OBJPROP_COLOR, dailyColor);
   
   // SESSION STATISTICS
   UpdateSessionStatsFromHistory();
   
   int totalClosed = sessionStats.totalClosedProfits + sessionStats.totalClosedLosses;
   double winRate = (totalClosed > 0) ? (sessionStats.totalClosedProfits * 100.0 / totalClosed) : 0;
   
   color sessionColor = (sessionStats.sessionNetPL >= 0) ? clrLimeGreen : clrRed;
   string sessionText = StringFormat("Sess: $%.2f", sessionStats.sessionNetPL);
   ObjectSetString(0, panelPrefix + "SessionPL", OBJPROP_TEXT, sessionText);
   ObjectSetInteger(0, panelPrefix + "SessionPL", OBJPROP_COLOR, sessionColor);
   
   // ROW 8: Win Rate + Closed Stats
   string winRateText = StringFormat("Win: %.0f%%", winRate);
   ObjectSetString(0, panelPrefix + "WinRate", OBJPROP_TEXT, winRateText);
   
   string closedText = StringFormat("W:%d L:%d",
                                     sessionStats.totalClosedProfits,
                                     sessionStats.totalClosedLosses);
   ObjectSetString(0, panelPrefix + "ClosedStats", OBJPROP_TEXT, closedText);
   
   // ROW 9: Grid + TP/SL
   string gridText = StringFormat("Grid: %.2f%%", GridSpacingPercent);
   ObjectSetString(0, panelPrefix + "Grid", OBJPROP_TEXT, gridText);
   
   string tpslText = StringFormat("TP:$%.0f SL:$%.0f", IndividualTPDollars, IndividualSLDollars);
   ObjectSetString(0, panelPrefix + "TPSL", OBJPROP_TEXT, tpslText);
   
   // ROW 10: Consecutive SLs + Max DD
   color slColor = (consecutiveSLs == 0) ? clrLimeGreen : (consecutiveSLs >= MaxConsecutiveSLs - 1) ? clrRed : clrOrange;
   string slText = StringFormat("SLs: %d/%d", consecutiveSLs, MaxConsecutiveSLs);
   ObjectSetString(0, panelPrefix + "ConsecSLs", OBJPROP_TEXT, slText);
   ObjectSetInteger(0, panelPrefix + "ConsecSLs", OBJPROP_COLOR, slColor);
   
   string maxDDText = StringFormat("MaxDD: %.0f%%", MaxDrawdownPercent);
   ObjectSetString(0, panelPrefix + "MaxDD", OBJPROP_TEXT, maxDDText);
   
   // ROW 11: Regime/Auto-detection
   string regimeText = "";
   if(EnableAutoDetection)
   {
      if(currentRegime == REGIME_RANGING)
         regimeText = "🟢 RANGING";
      else if(currentRegime == REGIME_TRANSITION)
         regimeText = "⚠️ TRANSITION";
      else if(currentRegime == REGIME_TRENDING)
         regimeText = "🚀 TRENDING";
   }
   else if(EnableH4Zones)
   {
      if(inResistanceZone)
      {
         regimeText = "🔴 RESISTANCE";
         if(PauseAtH4Zones && workingDirection == TRADE_BUY_ONLY)
            regimeText += " ⏸";  // Show pause indicator
      }
      else if(inSupportZone)
      {
         regimeText = "🟢 SUPPORT";
         if(PauseAtH4Zones && workingDirection == TRADE_SELL_ONLY)
            regimeText += " ⏸";  // Show pause indicator
      }
      else
         regimeText = "H4: CLEAR";
   }
   else
   {
      regimeText = "Manual Mode";
   }
   
   ObjectSetString(0, panelPrefix + "Regime", OBJPROP_TEXT, regimeText);
   
   // ROW 12: H4 Resistance + Support values (ALWAYS show if available)
   if(ArraySize(resistanceLevels) > 0 || ArraySize(supportLevels) > 0)
   {
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      
      // Show closest resistance
      string resistanceText = "";
      if(ArraySize(resistanceLevels) > 0)
      {
         resistanceText = "R: " + DoubleToString(resistanceLevels[0].price, digits);
      }
      else
      {
         resistanceText = "R: ---";
      }
      ObjectSetString(0, panelPrefix + "H4Resistance", OBJPROP_TEXT, resistanceText);
      
      // Show closest support
      string supportText = "";
      if(ArraySize(supportLevels) > 0)
      {
         supportText = "S: " + DoubleToString(supportLevels[0].price, digits);
      }
      else
      {
         supportText = "S: ---";
      }
      ObjectSetString(0, panelPrefix + "H4Support", OBJPROP_TEXT, supportText);
   }
   else
   {
      // No H4 levels calculated yet or H4 zones disabled
      ObjectSetString(0, panelPrefix + "H4Resistance", OBJPROP_TEXT, "R: ---");
      ObjectSetString(0, panelPrefix + "H4Support", OBJPROP_TEXT, "S: ---");
   }
}

//+------------------------------------------------------------------+
