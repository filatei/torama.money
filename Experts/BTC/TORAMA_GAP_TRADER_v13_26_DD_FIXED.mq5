//+------------------------------------------------------------------+
//|                                     GapTrader Pro EA v13.26      |
//|        DRAWDOWN FIX - Peak Never Resets on Rebuild v13.26        |
//+------------------------------------------------------------------+
#property copyright "GapTrader Pro v13.26 DD FIX - TORAMA CAPITAL"
#property version   "13.26"
#property strict

#include <Trade\Trade.mqh>

enum ENUM_TRADE_DIRECTION { TRADE_BUY = 0, TRADE_SELL = 1, TRADE_BOTH = 2 };
enum ENUM_TRADING_MODE { MODE_MEAN_REVERSION = 0, MODE_MOMENTUM = 1 };

// Input Parameters - Streamlined
input group "=== Trading Parameters ==="
input ENUM_TRADE_DIRECTION TradeDirection = TRADE_BUY;
input double GapSize = 30.0;  // Gap size in dollars
input double TakeProfitPercent = 300.0;  // TP as % of Gap (e.g., 300 = 3x gap) - 0 to disable
input double StopLossPercent = 200.0;    // SL as % of Gap (e.g., 200 = 2x gap) - 0 to disable
input double GlobalTakeProfitPercent = 500.0;  // Global TP as % of Gap (e.g., 500 = 5x gap) - 0 to disable
input double GlobalSLPercent = 0.0;  // Global SL as % of Gap - 0 to disable
input int MaxPositions = 5, TradingHours = 0, MagicNumber = 66616;
input bool UseAutoLotSize = false;
input double AutoLotSize = 0.01;
input double AutoLotEquity = 500.0;
input double ManualLotSize = 0.1;

 //group "=== Progressive Lot Settings ==="
 bool UseProgressiveLots = false;  // Enable progressive lot sizing
 double LotIncrement = 0.01;      // Lot size increase per trade in same direction
 int MaxProgressiveTrades = 10;   // Maximum progressive trade count (safety cap)

// group "=== Risk Management (NEW v13.0) ==="
 int MaxPositionAgeHours = 0;    // Close positions after X hours (0 = disabled)
 double MaxLossPerPosition = 0.0;  // Close if position loses this amount (0 = disabled)
 bool UseTrailingStop = false;     // Enable trailing stop
 double TrailingStopDistance = 50.0;  // Trailing stop distance in dollars
 double TrailingStopActivation = 150.0; // Activate trailing after this profit

input group "=== Mode Settings ==="
input ENUM_TRADING_MODE DefaultTradingMode = MODE_MOMENTUM;  // OPTIMIZED for TRENDING markets (Sept-Nov 2025 data)
 bool EnableModeReversalOnMaxLoss = false;
 int MaxLosingTrades = 30;
 int ConsecutiveWinsToScale = 3;
 double LotScaleFactor = 1.5;

 // group "=== Rebuild Settings ==="
 bool EnableModeReversalOnRebuild = false;
 bool EnableAutoRebuild = false;
 int RebuildIntervalMinutes = 30, MaxRebuilds = 300;
 double MaxPositionMultiplier = 1.0;

input group "=== Panel Settings ==="
input int PanelX = 20, PanelY = 20, PanelWidth = 500, PanelHeight = 490;
input bool ShowPanelOnStart = true;

// Layout Constants
#define COL1_X 15
#define COL2_X 260
#define SEPARATOR_X 245


input group "=== Risk Management ==="
input double MaxDrawdownPercent = 20.0;  // Max Drawdown % - Stop trading and close all positions when reached

// Structures
struct TradeInfo {
   double startPrice, lastBuyPrice, lastSellPrice, totalProfit, currentGapSize, buyLotMult, sellLotMult;
   datetime startTime, nextAutoRebuild;
   bool isActive, gridRebuilt, tradingTimeUnlimited, isPaused;
   int buyPos, sellPos, maxPosPerSide, originalMaxPos, losingBuyStreak, losingSellStreak;
   int winningBuyStreak, winningSellStreak, modeChanges, autoRebuilds, maxTriggerRebuilds;
   int lastMaxBuyPos, lastMaxSellPos;
   // NEW: Progressive lot tracking
   int buyTradeCount, sellTradeCount;  // Count of consecutive trades in same direction
   ENUM_TRADING_MODE currentMode, originalMode;
};

// Globals
CTrade trade;
TradeInfo ti;
bool panelCreated = false, panelVisible = true;
bool stoppedByDrawdown = false;  // Track if EA was stopped due to max drawdown
int lastDealsCount = 0;
int previousTotalPositions = 0;  // Track previous position count for manual close detection
double peakEquity = 0;  // Track peak equity for drawdown calculation
double currentDrawdownPercent = 0;  // Current drawdown percentage

// State persistence
double savedData[10];
datetime savedTimes[3];
bool savedBools[3];
int savedInts[17];  // Increased from 15 to 17 for new progressive lot counters
ENUM_TRADING_MODE savedMode = MODE_MOMENTUM;

string FormatNumber(double value) {
   string str = DoubleToString(value, 2), result = "";
   int decimalPos = StringFind(str, "."), len = StringLen((decimalPos == -1) ? str : StringSubstr(str, 0, decimalPos));
   string intPart = (decimalPos == -1) ? str : StringSubstr(str, 0, decimalPos);
   
   for(int i = 0; i < len; i++) {
      if(i > 0 && (len - i) % 3 == 0) result += ",";
      result += StringSubstr(intPart, i, 1);
   }
   return result + ((decimalPos == -1) ? "" : StringSubstr(str, decimalPos));
}

string FormatTimeRemaining(datetime targetTime) {
   if(targetTime <= 0) return "DISABLED";
   
   int remainingSeconds = (int)(targetTime - TimeCurrent());
   if(remainingSeconds <= 0) return "DUE";
   
   int hours = remainingSeconds / 3600;
   int minutes = (remainingSeconds % 3600) / 60;
   int seconds = remainingSeconds % 60;
   
   if(hours > 0) return IntegerToString(hours) + "h " + IntegerToString(minutes) + "m";
   else if(minutes > 0) return IntegerToString(minutes) + "m " + IntegerToString(seconds) + "s";
   else return IntegerToString(seconds) + "s";
}

void CalcNetPositions(double &netBuyLots, double &netSellLots) {
   netBuyLots = 0; netSellLots = 0;
   
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol) {
            double volume = PositionGetDouble(POSITION_VOLUME);
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) netBuyLots += volume;
            else netSellLots += volume;
         }
      }
   }
}

int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   bool stateRestored = (savedData[0] > 0 && savedTimes[0] > 0);
   if(stateRestored) {
      RestoreState();
      // Always use current MaxPositions parameter, not saved state
      ti.maxPosPerSide = MaxPositions;
      ti.originalMaxPos = MaxPositions;
      // Ensure current mode always matches user's current input parameter
      ti.currentMode = DefaultTradingMode;
      ti.originalMode = DefaultTradingMode;
      Print("*** STATE RESTORED - EA CONTINUING | Mode set to: ", (ti.currentMode == MODE_MEAN_REVERSION ? "MEAN_REVERSION" : "MOMENTUM"), " ***");
      Print("*** MaxPositions updated to current parameter: ", MaxPositions, " ***");
      Print("*** Progressive Lots: BUY count=", ti.buyTradeCount, " | SELL count=", ti.sellTradeCount, " ***");
   } else {
      InitFreshState();
      Print("*** AUTO-STARTED - FRESH INITIALIZATION | Mode: ", (ti.currentMode == MODE_MEAN_REVERSION ? "MEAN_REVERSION" : "MOMENTUM"), " ***");
   }
   
   // Ensure timed rebuild is properly initialized
   if(EnableAutoRebuild && MaxRebuilds > 0 && ti.nextAutoRebuild == 0) {
      ti.nextAutoRebuild = TimeCurrent() + (RebuildIntervalMinutes * 60);
      Print("*** TIMED REBUILD INITIALIZED | Next rebuild in: ", RebuildIntervalMinutes, " minutes ***");
   }
   

   // Initialize drawdown tracking for fresh start
   stoppedByDrawdown = false;
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   currentDrawdownPercent = 0;
   panelVisible = ShowPanelOnStart;
   if(!CreatePanel()) return INIT_FAILED;
   
   SetPanelVisibility(panelVisible);
   UpdatePanel();
   
   Print("╔════════════════════════════════════════════════════════════════╗");
   Print("║ GapTrader Pro EA v13.24 MOMENTUM - TORAMA CAPITAL              ║");
   Print("║ TP/SL as % of Gap + Max Drawdown Input                        ║");
   Print("╚════════════════════════════════════════════════════════════════╝");
   Print("Magic Number: ", MagicNumber);
   Print("Gap Size: $", DoubleToString(GapSize, 2));
   Print("");
   Print("=== TP/SL SETTINGS (% of Gap) ===");
   double initTPDollars = GapSize * TakeProfitPercent / 100.0;
   double initSLDollars = GapSize * StopLossPercent / 100.0;
   Print("Take Profit: ", DoubleToString(TakeProfitPercent, 0), "% of gap = $", DoubleToString(initTPDollars, 2), TakeProfitPercent <= 0 ? " (DISABLED)" : "");
   Print("Stop Loss: ", DoubleToString(StopLossPercent, 0), "% of gap = $", DoubleToString(initSLDollars, 2), StopLossPercent <= 0 ? " (DISABLED)" : "");
   
   double initGlobalTPDollars = GapSize * GlobalTakeProfitPercent / 100.0;
   double initGlobalSLDollars = GapSize * GlobalSLPercent / 100.0;
   Print("Global TP: ", DoubleToString(GlobalTakeProfitPercent, 0), "% of gap = $", DoubleToString(initGlobalTPDollars, 2), GlobalTakeProfitPercent <= 0 ? " (DISABLED)" : "");
   Print("Global SL: ", DoubleToString(GlobalSLPercent, 0), "% of gap = $", DoubleToString(initGlobalSLDollars, 2), GlobalSLPercent <= 0 ? " (DISABLED)" : "");
   Print("");
   Print("=== TRADING MODE ===");
   Print("Default Mode: MOMENTUM (OPTIMIZED for trending markets)");
   Print("Current Mode: ", (ti.currentMode == MODE_MEAN_REVERSION ? "MEAN_REVERSION" : "MOMENTUM"));
   Print("Mode Reversal on Max Loss: ", EnableModeReversalOnMaxLoss ? "ENABLED" : "DISABLED");
   Print("Mode Reversal on Rebuild: ", EnableModeReversalOnRebuild ? "ENABLED" : "DISABLED");
   Print("");
   Print("=== PROGRESSIVE LOTS ===");
   Print("Progressive Lots: ", UseProgressiveLots ? "ENABLED" : "DISABLED");
   Print("Lot Increment: ", DoubleToString(LotIncrement, 3));
   Print("Max Progressive Trades: ", MaxProgressiveTrades, " (SAFETY CAP)");
   Print("");
   Print("=== RISK MANAGEMENT ===");
   Print("Max Drawdown: ", DoubleToString(MaxDrawdownPercent, 1), "% - Closes all positions and stops EA when reached");
   Print("Max Position Age: ", MaxPositionAgeHours > 0 ? IntegerToString(MaxPositionAgeHours) + " hours" : "DISABLED");
   Print("Max Loss Per Position: ", MaxLossPerPosition > 0 ? "$" + DoubleToString(MaxLossPerPosition, 2) : "DISABLED");
   Print("Trailing Stop: ", UseTrailingStop ? "ENABLED (Distance: $" + DoubleToString(TrailingStopDistance, 2) + ")" : "DISABLED");
   Print("");
   Print("=== POSITION LIMITS ===");
   Print("Max Positions per Side: ", MaxPositions, " (SACROSANCT)");
   if(TradeDirection == TRADE_BOTH) {
      Print("Total Max: ", MaxPositions, " BUY + ", MaxPositions, " SELL = ", MaxPositions * 2);
   }
   Print("Trading Direction: ", TradeDirection == TRADE_BOTH ? "BOTH SIDES" : (TradeDirection == TRADE_BUY ? "BUY ONLY" : "SELL ONLY"));
   Print("");
   Print("=== LOT SIZING ===");
   Print("Auto Lot Sizing: ", UseAutoLotSize ? "ENABLED" : "DISABLED");
   if(UseAutoLotSize) {
      double currentLot = GetLotSize(true);
      Print("Base Lot: ", DoubleToString(AutoLotSize, 2), " per $", DoubleToString(AutoLotEquity, 0));
      Print("Current Calculated: ", DoubleToString(currentLot, 2), " lots");
   } else {
      Print("Manual Lot Size: ", DoubleToString(ManualLotSize, 2));
   }
   Print("");
   Print("=== AUTO REBUILD ===");
   Print("Timed Auto Rebuild: ", EnableAutoRebuild ? "ENABLED" : "DISABLED");
   if(EnableAutoRebuild) {
      Print("Rebuild Interval: ", RebuildIntervalMinutes, " minutes | Max Rebuilds: ", MaxRebuilds);
      if(ti.nextAutoRebuild > 0) {
         Print("Next Auto Rebuild: ", TimeToString(ti.nextAutoRebuild, TIME_MINUTES), " (", FormatTimeRemaining(ti.nextAutoRebuild), " remaining)");
      }
   }
   Print("Mode Reversal on Max Loss: ", EnableModeReversalOnMaxLoss ? "ENABLED" : "DISABLED");
   Print("Mode Reversal on Rebuild: ", EnableModeReversalOnRebuild ? "ENABLED" : "DISABLED");
   Print("Trading Direction: ", TradeDirection == TRADE_BOTH ? "BOTH SIDES" : (TradeDirection == TRADE_BUY ? "BUY ONLY" : "SELL ONLY"));
   if(TradeDirection == TRADE_BOTH) {
      Print("SACROSANCT Position Limits: ", MaxPositions, " BUY max | ", MaxPositions, " SELL max | ", MaxPositions * 2, " total max");
   }
   
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   SaveState();
   
   // FIXED: Reset panelCreated flag BEFORE deleting objects
   // This ensures CreatePanel() can recreate the panel on parameter changes
   panelCreated = false;
   
   ObjectsDeleteAll(0, "GT_");
   ChartRedraw();
   
   if(reason != REASON_PARAMETERS && reason != REASON_RECOMPILE) {
      ClearState();
      Print("*** EA REMOVED - State Cleared ***");
   } else {
      // Parameter change or recompile - panel will be recreated in OnInit
      Print("*** SETTINGS CHANGED - Panel will be rebuilt ***");
   }
}

void OnTick() {
   // Always update panel so user can see status and use buttons (even when stopped)
   if(panelVisible) UpdatePanel();
   
   // If EA is stopped (including by max drawdown), only update panel - no trading
   if(!ti.isActive) return;
   
   CalcTotalPL();
   
   // Auto-rebuild when all positions are manually closed
   int currentTotalPositions = ti.buyPos + ti.sellPos;
   if(previousTotalPositions > 0 && currentTotalPositions == 0) {
      // All positions were manually closed - rebuild grid and reset
      Print("*** ALL POSITIONS MANUALLY CLOSED - Auto-rebuilding grid ***");
      RebuildGrid();
      previousTotalPositions = 0;
      return;  // Exit to allow grid to rebuild fresh
   }
   previousTotalPositions = currentTotalPositions;
   
   // Risk management checks
   CheckPositionAge();        // Close positions that are too old
   CheckPositionDrawdown();   // Close positions with excessive losses
   UpdateTrailingStops();     // Update trailing stops for profitable positions
   CheckMaxDrawdown();        // Stop trading if max drawdown exceeded
   
   // If we just stopped due to drawdown, exit early
   if(!ti.isActive) return;
   
   // Check for timed auto rebuild
   if(EnableAutoRebuild && ti.autoRebuilds < MaxRebuilds && ti.nextAutoRebuild > 0 && TimeCurrent() >= ti.nextAutoRebuild) {
      AutoRebuildGrid();
   }
   
   // Check for max position trigger rebuild with proper per-side calculation
   if((ti.autoRebuilds + ti.maxTriggerRebuilds) < MaxRebuilds) {
      int currentOriginalMax = ti.originalMaxPos > 0 ? ti.originalMaxPos : MaxPositions;
      // SACROSANCT: Each side gets full MaxPositions allocation
      int maxPerSide = currentOriginalMax;
      
      bool buyMaxReached = (TradeDirection != TRADE_SELL) && (ti.buyPos >= maxPerSide) && (ti.lastMaxBuyPos != ti.buyPos);
      bool sellMaxReached = (TradeDirection != TRADE_BUY) && (ti.sellPos >= maxPerSide) && (ti.lastMaxSellPos != ti.sellPos);
      
      if(buyMaxReached) { ti.lastMaxBuyPos = ti.buyPos; MaxPositionTriggerRebuild("BUY"); }
      else if(sellMaxReached) { ti.lastMaxSellPos = ti.sellPos; MaxPositionTriggerRebuild("SELL"); }
   }
   
   if(!ti.tradingTimeUnlimited && TimeCurrent() - ti.startTime >= TradingHours * 3600) {
      ti.isActive = false;
      Print("*** Trading time expired ***");
      return;
   }
   
   if(CheckGlobalTPSL()) {
      CloseAllProfitableTrades();
      RebuildGrid();
      Print("*** Global TP/SL reached - Profits closed and grid rebuilt ***");
      return;
   }
   
   if(EnableModeReversalOnMaxLoss) { CheckClosedTrades(); CheckModeReversal(); }
   CheckGapTrades();
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam) {
   if(id == CHARTEVENT_KEYDOWN && lparam == 72) {
      panelVisible = !panelVisible;
      SetPanelVisibility(panelVisible);
      if(panelVisible) UpdatePanel();
      return;
   }
   
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   
   if(sparam == "GT_CloseProfitsBtn") CloseAllProfitableTrades();
   else if(sparam == "GT_RebuildBtn") RebuildGrid();
   else if(sparam == "GT_ReversalRebuildBtn") ManualReversalRebuild();
   else if(sparam == "GT_PauseBtn") TogglePause();
   
   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   ChartRedraw();
}

void InitFreshState() {
   ZeroMemory(ti);
   ti.isActive = true;
   ti.isPaused = false;  // Start unpaused
   ti.startTime = TimeCurrent();
   ti.startPrice = ti.lastBuyPrice = ti.lastSellPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ti.currentMode = ti.originalMode = DefaultTradingMode;
   ti.maxPosPerSide = ti.originalMaxPos = MaxPositions;
   ti.currentGapSize = GapSize;
   ti.buyLotMult = ti.sellLotMult = 1.0;
   ti.tradingTimeUnlimited = (TradingHours == 0);
   ti.lastMaxBuyPos = ti.lastMaxSellPos = 0;
   
   // Initialize progressive lot counters
   ti.buyTradeCount = 0;
   ti.sellTradeCount = 0;
   
   // Set up timed rebuild
   if(EnableAutoRebuild && MaxRebuilds > 0) {
      ti.nextAutoRebuild = ti.startTime + (RebuildIntervalMinutes * 60);
   } else {
      ti.nextAutoRebuild = 0;
   }
}

void SaveState() {
   savedData[0] = ti.startPrice; savedData[1] = ti.lastBuyPrice; savedData[2] = ti.lastSellPrice;
   savedData[3] = ti.currentGapSize; savedData[4] = ti.buyLotMult; savedData[5] = ti.sellLotMult;
   savedTimes[0] = ti.startTime; savedTimes[1] = ti.nextAutoRebuild;
   savedBools[0] = ti.isActive; savedBools[1] = ti.gridRebuilt; savedBools[2] = ti.isPaused;
   savedInts[0] = ti.buyPos; savedInts[1] = ti.sellPos; savedInts[2] = ti.losingBuyStreak;
   savedInts[3] = ti.losingSellStreak; savedInts[4] = ti.winningBuyStreak; savedInts[5] = ti.winningSellStreak;
   savedInts[6] = ti.modeChanges; savedInts[7] = ti.maxPosPerSide; savedInts[8] = ti.originalMaxPos;
   savedInts[9] = ti.autoRebuilds; savedInts[10] = ti.maxTriggerRebuilds;
   savedInts[11] = ti.lastMaxBuyPos; savedInts[12] = ti.lastMaxSellPos;
   // Save progressive lot counters
   savedInts[13] = ti.buyTradeCount; savedInts[14] = ti.sellTradeCount;
   savedMode = ti.currentMode;
}

void RestoreState() {
   ti.startPrice = savedData[0]; ti.lastBuyPrice = savedData[1]; ti.lastSellPrice = savedData[2];
   ti.currentGapSize = savedData[3]; ti.buyLotMult = savedData[4]; ti.sellLotMult = savedData[5];
   ti.startTime = savedTimes[0]; ti.nextAutoRebuild = savedTimes[1];
   ti.isActive = savedBools[0]; ti.gridRebuilt = savedBools[1]; ti.isPaused = savedBools[2];
   ti.buyPos = savedInts[0]; ti.sellPos = savedInts[1]; ti.losingBuyStreak = savedInts[2];
   ti.losingSellStreak = savedInts[3]; ti.winningBuyStreak = savedInts[4]; ti.winningSellStreak = savedInts[5];
   ti.modeChanges = savedInts[6]; 
   // Don't restore maxPosPerSide and originalMaxPos - use current parameter instead
   ti.autoRebuilds = savedInts[9]; ti.maxTriggerRebuilds = savedInts[10];
   ti.lastMaxBuyPos = savedInts[11]; ti.lastMaxSellPos = savedInts[12];
   // Restore progressive lot counters
   ti.buyTradeCount = savedInts[13]; ti.sellTradeCount = savedInts[14];
   ti.currentMode = savedMode; ti.originalMode = DefaultTradingMode;
   ti.tradingTimeUnlimited = (TradingHours == 0);
}

void ClearState() {
   ArrayInitialize(savedData, 0); ArrayInitialize(savedTimes, 0); ArrayInitialize(savedBools, false);
   ArrayInitialize(savedInts, 0); savedMode = DefaultTradingMode;
}

double GetNextBuyPrice() {
   return (ti.currentMode == MODE_MEAN_REVERSION) ? ti.lastBuyPrice - ti.currentGapSize : ti.lastBuyPrice + ti.currentGapSize;
}

double GetNextSellPrice() {
   return (ti.currentMode == MODE_MEAN_REVERSION) ? ti.lastSellPrice + ti.currentGapSize : ti.lastSellPrice - ti.currentGapSize;
}

double GetLotSize(bool isBuy = true) {
   double lot;
   if(UseAutoLotSize) {
      lot = (AccountInfoDouble(ACCOUNT_EQUITY) / AutoLotEquity) * AutoLotSize;
      lot = MathMax(lot, 0.1); // Minimum lot size increased to 0.1
      
      // Round to one decimal place properly (not always up)
      lot = MathRound(lot * 10.0) / 10.0;  // OPTIMIZED: Proper rounding
   } else {
      lot = ManualLotSize;
   }
   
   lot = MathMax(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   lot = MathMin(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));
   
   // Apply lot multiplier from win streaks
   lot = lot * (isBuy ? ti.buyLotMult : ti.sellLotMult);
   
   // OPTIMIZED: Apply progressive lot increment with safety cap
   if(UseProgressiveLots) {
      int tradeCount = isBuy ? ti.buyTradeCount : ti.sellTradeCount;
      tradeCount = MathMin(tradeCount, MaxProgressiveTrades);  // CAP IT!
      lot = lot + (LotIncrement * tradeCount);
      
      // Ensure we don't exceed broker limits
      lot = MathMin(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));
   }
   
   return lot;
}

void CheckGapTrades() {
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   // PAUSE: Don't open new trades if paused (existing trades keep running)
   if(ti.isPaused) return;

   
   // SACROSANCT: MaxPositions applies to EACH side independently
   // If MaxPositions = 5, you can have 5 BUY + 5 SELL simultaneously
   int maxBuyPos = ti.maxPosPerSide;  // Full MaxPositions for BUY
   int maxSellPos = ti.maxPosPerSide; // Full MaxPositions for SELL
   
   if(TradeDirection != TRADE_SELL) {
      bool canTrade = (ti.buyPos < maxBuyPos);  // FIXED: MaxPositions is SACROSANCT - no exceptions!
      bool condition = (ti.currentMode == MODE_MEAN_REVERSION) ? (price <= ti.lastBuyPrice - ti.currentGapSize) : (price >= ti.lastBuyPrice + ti.currentGapSize);
      
      if(canTrade && condition && OpenBuy()) { 
         ti.lastBuyPrice = price; 
         ti.buyPos++; 
         ti.buyTradeCount++;  // Increment progressive counter
         Print("*** BUY TRADE #", ti.buyTradeCount, " | Position: ", ti.buyPos, "/", maxBuyPos, " | Lot Size: ", DoubleToString(GetLotSize(true), 2), " ***");
      }
   }
   
   if(TradeDirection != TRADE_BUY) {
      bool canTrade = (ti.sellPos < maxSellPos);  // FIXED: MaxPositions is SACROSANCT - no exceptions!
      bool condition = (ti.currentMode == MODE_MEAN_REVERSION) ? (price >= ti.lastSellPrice + ti.currentGapSize) : (price <= ti.lastSellPrice - ti.currentGapSize);
      
      if(canTrade && condition && OpenSell()) { 
         ti.lastSellPrice = price; 
         ti.sellPos++; 
         ti.sellTradeCount++;  // Increment progressive counter
         Print("*** SELL TRADE #", ti.sellTradeCount, " | Position: ", ti.sellPos, "/", maxSellPos, " | Lot Size: ", DoubleToString(GetLotSize(false), 2), " ***");
      }
   }
}

bool OpenBuy() {
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK), lot = GetLotSize(true), tp = 0, sl = 0;
   
   // Calculate TP/SL as percentage of current gap size (in PRICE DISTANCE, not profit)
   double tpDistance = (TakeProfitPercent > 0) ? (ti.currentGapSize * TakeProfitPercent / 100.0) : 0;
   double slDistance = (StopLossPercent > 0) ? (ti.currentGapSize * StopLossPercent / 100.0) : 0;
   
   // For dollar-quoted instruments (BTCUSD, XAUUSD), gap size IS the price distance
   if(tpDistance > 0) {
      tp = price + tpDistance;
   }
   
   if(slDistance > 0) {
      sl = price - slDistance;
   }
   
   return trade.Buy(lot, _Symbol, price, sl, tp, "GT18-Buy");
}

bool OpenSell() {
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID), lot = GetLotSize(false), tp = 0, sl = 0;
   
   // Calculate TP/SL as percentage of current gap size (in PRICE DISTANCE, not profit)
   double tpDistance = (TakeProfitPercent > 0) ? (ti.currentGapSize * TakeProfitPercent / 100.0) : 0;
   double slDistance = (StopLossPercent > 0) ? (ti.currentGapSize * StopLossPercent / 100.0) : 0;
   
   // For dollar-quoted instruments (BTCUSD, XAUUSD), gap size IS the price distance
   if(tpDistance > 0) {
      tp = price - tpDistance;
   }
   
   if(slDistance > 0) {
      sl = price + slDistance;
   }
   
   return trade.Sell(lot, _Symbol, price, sl, tp, "GT18-Sell");
}

void CalcTotalPL() {
   ti.totalProfit = 0; ti.buyPos = ti.sellPos = 0;
   
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            ti.totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ti.buyPos++;
            else ti.sellPos++;
         }
      }
   }
}

bool CheckGlobalTPSL() {
   // Calculate Global TP/SL as percentage of gap size (in dollars)
   double globalTPDollars = (GlobalTakeProfitPercent > 0) ? (ti.currentGapSize * GlobalTakeProfitPercent / 100.0) : 0;
   double globalSLDollars = (GlobalSLPercent > 0) ? (ti.currentGapSize * GlobalSLPercent / 100.0) : 0;
   
   return (globalTPDollars > 0 && ti.totalProfit >= globalTPDollars) || (globalSLDollars > 0 && ti.totalProfit <= -globalSLDollars);
}

//+------------------------------------------------------------------+
//| NEW v13.0: Risk Management Functions                             |
//+------------------------------------------------------------------+

void CheckPositionAge() {
   if(MaxPositionAgeHours <= 0) return;  // Disabled
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            int ageHours = (int)((TimeCurrent() - openTime) / 3600);
            
            if(ageHours >= MaxPositionAgeHours) {
               double profit = PositionGetDouble(POSITION_PROFIT);
               string type = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL";
               
               if(trade.PositionClose(ticket)) {
                  Print("*** POSITION CLOSED BY AGE: ", type, " | Age: ", ageHours, "h | P/L: $", DoubleToString(profit, 2), " ***");
                  
                  // Update position counters
                  if(type == "BUY") ti.buyPos--;
                  else ti.sellPos--;
               }
            }
         }
      }
   }
}

void CheckPositionDrawdown() {
   if(MaxLossPerPosition <= 0) return;  // Disabled
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            
            if(profit <= -MaxLossPerPosition) {
               string type = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL";
               datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
               int ageMinutes = (int)((TimeCurrent() - openTime) / 60);
               
               if(trade.PositionClose(ticket)) {
                  Print("*** POSITION CLOSED BY MAX LOSS: ", type, " | Loss: $", DoubleToString(profit, 2), 
                        " | Age: ", ageMinutes, "min ***");
                  
                  // Update position counters
                  if(type == "BUY") ti.buyPos--;
                  else ti.sellPos--;
               }
            }
         }
      }
   }
}

void CheckMaxDrawdown() {
   if(MaxDrawdownPercent <= 0) return;  // Disabled
   
   // Calculate current equity (balance + floating P/L)
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Update peak equity
   if(peakEquity == 0) peakEquity = balance;  // Initialize on first run
   if(equity > peakEquity) peakEquity = equity;
   
   // Calculate current drawdown percentage
   currentDrawdownPercent = ((peakEquity - equity) / peakEquity) * 100.0;
   
   // Check if max drawdown exceeded
   if(currentDrawdownPercent >= MaxDrawdownPercent) {
      Print("╔════════════════════════════════════════════════════════════════╗");
      Print("║           CRITICAL: MAX DRAWDOWN PROTECTION TRIGGERED          ║");
      Print("╚════════════════════════════════════════════════════════════════╝");
      Print("Peak Equity: $", DoubleToString(peakEquity, 2));
      Print("Current Equity: $", DoubleToString(equity, 2));
      Print("Drawdown: ", DoubleToString(currentDrawdownPercent, 2), "% (Limit: ", DoubleToString(MaxDrawdownPercent, 2), "%)");
      
      // Close all positions managed by this EA
      CloseAllPositions();
      
      // Stop trading and mark as stopped by drawdown
      ti.isActive = false;
      stoppedByDrawdown = true;
      
      Print("*** ALL EA POSITIONS CLOSED | EA DEACTIVATED ***");
      Print("*** To resume trading, restart the EA or click REBUILD GRID ***");
      
      // Send alert
      Alert("GapTrader EA STOPPED - Max Drawdown ", DoubleToString(MaxDrawdownPercent, 1), "% reached!");
   }
}

void UpdateTrailingStops() {
   if(!UseTrailingStop) return;
   
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            
            double profit = PositionGetDouble(POSITION_PROFIT);
            
            // Only activate trailing stop after certain profit level
            if(profit >= TrailingStopActivation) {
               double currentSL = PositionGetDouble(POSITION_SL);
               double currentTP = PositionGetDouble(POSITION_TP);
               double lotSize = PositionGetDouble(POSITION_VOLUME);
               
               // Calculate stop distance in price
               double slDistance = TrailingStopDistance / (lotSize * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE));
               double slPoints = slDistance * _Point;
               
               if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
                  double newSL = currentPrice - slPoints;
                  
                  // Only move SL up, never down
                  if(newSL > currentSL && newSL < currentPrice) {
                     if(trade.PositionModify(ticket, newSL, currentTP)) {
                        Print("*** TRAILING STOP UPDATED: BUY | New SL: ", DoubleToString(newSL, _Digits), 
                              " | Profit: $", DoubleToString(profit, 2), " ***");
                     }
                  }
               } else {  // SELL
                  double newSL = currentPrice + slPoints;
                  
                  // Only move SL down, never up (for SELL positions, lower SL is better)
                  if((currentSL == 0 || newSL < currentSL) && newSL > currentPrice) {
                     if(trade.PositionModify(ticket, newSL, currentTP)) {
                        Print("*** TRAILING STOP UPDATED: SELL | New SL: ", DoubleToString(newSL, _Digits), 
                              " | Profit: $", DoubleToString(profit, 2), " ***");
                     }
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+

void CheckClosedTrades() {
   if(!HistorySelect(0, TimeCurrent())) return;
   
   int dealsCount = HistoryDealsTotal();
   if(dealsCount <= lastDealsCount) return;
   
   for(int i = lastDealsCount; i < dealsCount; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0 && HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && 
         HistoryDealGetInteger(ticket, DEAL_MAGIC) == MagicNumber) {
         
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         bool isBuy = (HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_BUY);
         
         if(profit < 0) {
            if(isBuy) { ti.losingBuyStreak++; ti.losingSellStreak = ti.winningBuyStreak = 0; ti.buyLotMult = 1.0; }
            else { ti.losingSellStreak++; ti.losingBuyStreak = ti.winningSellStreak = 0; ti.sellLotMult = 1.0; }
         } else if(profit > 0) {
            if(isBuy) {
               ti.winningBuyStreak++; ti.losingBuyStreak = 0;
               if(ti.winningBuyStreak == ConsecutiveWinsToScale) ti.buyLotMult = LotScaleFactor;
            } else {
               ti.winningSellStreak++; ti.losingSellStreak = 0;
               if(ti.winningSellStreak == ConsecutiveWinsToScale) ti.sellLotMult = LotScaleFactor;
            }
         }
      }
   }
   lastDealsCount = dealsCount;
}

void CheckModeReversal() {
   if(ti.losingBuyStreak >= MaxLosingTrades || ti.losingSellStreak >= MaxLosingTrades) {
      ENUM_TRADING_MODE oldMode = ti.currentMode;
      ti.currentMode = (ti.currentMode == MODE_MEAN_REVERSION) ? MODE_MOMENTUM : MODE_MEAN_REVERSION;
      ti.modeChanges++;
      
      // Adjust gap size based on mode changes
      double gapFactor[] = {0.8, 0.6, 0.4};
      int idx = MathMin(ti.modeChanges - 1, 2);
      
      ti.currentGapSize = GapSize * gapFactor[idx];
      
      // FIXED: MaxPositions is SACROSANCT - never scale it!
      // Previously this line violated MaxPositions limit:
      // ti.maxPosPerSide = (int)(MaxPositions * scaleFactor[idx]);
      // Now we ALWAYS respect the MaxPositions parameter:
      ti.maxPosPerSide = MaxPositions;  // SACROSANCT!
      
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ti.lastBuyPrice = ti.lastSellPrice = price;
      ti.losingBuyStreak = ti.losingSellStreak = 0;
      ti.gridRebuilt = true;
      
      // Reset progressive lot counters on mode reversal
      ti.buyTradeCount = 0;
      ti.sellTradeCount = 0;
      
      Print("*** MODE REVERSAL #", ti.modeChanges, " | ", 
            (oldMode == MODE_MEAN_REVERSION ? "MEAN_REV" : "MOMENTUM"), " -> ",
            (ti.currentMode == MODE_MEAN_REVERSION ? "MEAN_REV" : "MOMENTUM"),
            " | Gap: $", ti.currentGapSize, " | Max Pos: ", ti.maxPosPerSide, " (SACROSANCT)",
            " | Progressive Lots RESET");
   }
}

void RebuildGrid() {
   // Reactivate trading and reset timer when rebuild button is clicked
   ti.isActive = true;
   ti.startTime = TimeCurrent();  // Reset start time to prevent immediate time expiry
   
   // CRITICAL FIX v13.26: Don't reset drawdown protection state
   // Peak equity should track LIFETIME maximum, not reset on rebuild
   stoppedByDrawdown = false;
   
   // FIXED: Only update peak if current equity is higher
   // This prevents resetting peak on rebuilds, which was bypassing DD protection
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(currentEquity > peakEquity || peakEquity == 0) {
      peakEquity = currentEquity;
      Print("🔄 RebuildGrid: Peak Equity updated to $", DoubleToString(peakEquity, 2));
   } else {
      Print("🔄 RebuildGrid: Peak Equity maintained at $", DoubleToString(peakEquity, 2), 
            " (current: $", DoubleToString(currentEquity, 2), ")");
   }
   
   // Recalculate current drawdown
   currentDrawdownPercent = ((peakEquity - currentEquity) / peakEquity) * 100.0;
   Print("   Current Drawdown: ", DoubleToString(currentDrawdownPercent, 2), "% (Limit: ", 
         DoubleToString(MaxDrawdownPercent, 2), "%)");
   
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID), oldPrice = ti.startPrice;
   ti.startPrice = ti.lastBuyPrice = ti.lastSellPrice = price;
   ti.losingBuyStreak = ti.losingSellStreak = 0;
   ti.gridRebuilt = true;
   
   // Reset progressive lot counters on manual rebuild
   ti.buyTradeCount = 0;
   ti.sellTradeCount = 0;
   
   // Reset timed rebuild if enabled
   if(EnableAutoRebuild && MaxRebuilds > 0) {
      ti.nextAutoRebuild = TimeCurrent() + (RebuildIntervalMinutes * 60);
   }
   
   Print("*** MANUAL GRID REBUILD | Old: ", oldPrice, " | New: ", price, " | Shift: $", DoubleToString(price - oldPrice, 2), 
         " | Status: REACTIVATED | Drawdown RESET | Progressive Lots RESET | Timer RESET ***");
}

void TogglePause() {
   ti.isPaused = !ti.isPaused;
   
   // Update button appearance
   if(ti.isPaused) {
      ObjectSetString(0, "GT_PauseBtn", OBJPROP_TEXT, "RESUME");
      ObjectSetInteger(0, "GT_PauseBtn", OBJPROP_BGCOLOR, clrGreen);
      Print("*** TRADING PAUSED - No new trades, existing positions still active ***");
   } else {
      ObjectSetString(0, "GT_PauseBtn", OBJPROP_TEXT, "PAUSE");
      ObjectSetInteger(0, "GT_PauseBtn", OBJPROP_BGCOLOR, clrDarkOrange);
      Print("*** TRADING RESUMED - EA will open new trades ***");
   }
   
   ChartRedraw();
}

void AutoRebuildGrid() {
   if(!ti.isActive || ti.autoRebuilds >= MaxRebuilds) return;
   
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID), oldPrice = ti.startPrice;
   int oldMaxPos = ti.maxPosPerSide;
   
   if(ti.autoRebuilds == 0 && ti.maxTriggerRebuilds == 0 && ti.originalMaxPos == 0) ti.originalMaxPos = MaxPositions;
   
   int totalRebuilds = ti.autoRebuilds + ti.maxTriggerRebuilds;
   ti.maxPosPerSide = (int)(ti.originalMaxPos * MathPow(MaxPositionMultiplier, totalRebuilds + 1));
   
   ti.startPrice = ti.lastBuyPrice = ti.lastSellPrice = price;
   ti.losingBuyStreak = ti.losingSellStreak = 0;
   ti.gridRebuilt = true;
   ti.autoRebuilds++;
   
   // Reset progressive lot counters on auto rebuild
   ti.buyTradeCount = 0;
   ti.sellTradeCount = 0;
   
   // Set next timed rebuild
   if(EnableAutoRebuild && (ti.autoRebuilds + ti.maxTriggerRebuilds) < MaxRebuilds) {
      ti.nextAutoRebuild = TimeCurrent() + (RebuildIntervalMinutes * 60);
   } else {
      ti.nextAutoRebuild = 0; // No more rebuilds
   }
   
   Print("*** TIMED AUTO REBUILD #", ti.autoRebuilds, "/", MaxRebuilds, " | Old: ", oldPrice, " | New: ", price, 
         " | Max Pos: ", oldMaxPos, " -> ", ti.maxPosPerSide, " | Progressive Lots RESET");
   
   if(ti.nextAutoRebuild > 0) {
      Print("*** Next Timed Rebuild: ", TimeToString(ti.nextAutoRebuild, TIME_MINUTES), " (", RebuildIntervalMinutes, " minutes) ***");
   } else {
      Print("*** All Timed Rebuilds Complete ***");
   }
}

void MaxPositionTriggerRebuild(string triggerSide) {
   if(!ti.isActive || (ti.autoRebuilds + ti.maxTriggerRebuilds) >= MaxRebuilds) return;
   
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID), oldPrice = ti.startPrice;
   int oldMaxPos = ti.maxPosPerSide;
   
   if(ti.autoRebuilds == 0 && ti.maxTriggerRebuilds == 0 && ti.originalMaxPos == 0) ti.originalMaxPos = MaxPositions;
   
   int totalRebuilds = ti.autoRebuilds + ti.maxTriggerRebuilds;
   ti.maxPosPerSide = (int)(ti.originalMaxPos * MathPow(MaxPositionMultiplier, totalRebuilds + 1));
   
   // Mode reversal on rebuild (if enabled)
   ENUM_TRADING_MODE oldMode = ti.currentMode;
   if(EnableModeReversalOnRebuild) {
      ti.currentMode = (ti.maxTriggerRebuilds % 2 == 0) ? 
                       ((DefaultTradingMode == MODE_MEAN_REVERSION) ? MODE_MOMENTUM : MODE_MEAN_REVERSION) :
                       DefaultTradingMode;
      
      if(oldMode != ti.currentMode) {
         Print("*** MODE ALTERNATION ON REBUILD: ", 
               (oldMode == MODE_MEAN_REVERSION ? "MEAN_REV" : "MOMENTUM"), " -> ", 
               (ti.currentMode == MODE_MEAN_REVERSION ? "MEAN_REV" : "MOMENTUM"));
      }
   }
   
   ti.startPrice = ti.lastBuyPrice = ti.lastSellPrice = price;
   ti.losingBuyStreak = ti.losingSellStreak = 0;
   ti.gridRebuilt = true;
   ti.maxTriggerRebuilds++;
   
   // Reset progressive lot counters on max trigger rebuild
   ti.buyTradeCount = 0;
   ti.sellTradeCount = 0;
   
   // Reset timed rebuild if it's enabled and we still have rebuilds left
   if(EnableAutoRebuild && (ti.autoRebuilds + ti.maxTriggerRebuilds) < MaxRebuilds) {
      ti.nextAutoRebuild = TimeCurrent() + (RebuildIntervalMinutes * 60);
   }
   
   Print("*** MAX POSITION TRIGGER REBUILD (", triggerSide, " SIDE) #", ti.maxTriggerRebuilds, "/", MaxRebuilds,
         " | Old Center: ", oldPrice, " | New Center: ", price, " | Max Pos: ", oldMaxPos, " -> ", ti.maxPosPerSide,
         " | Mode: ", (ti.currentMode == MODE_MEAN_REVERSION ? "MEAN_REV" : "MOMENTUM"), " | Progressive Lots RESET");
}

void ManualReversalRebuild() {
   if(!ti.isActive) return;
   
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID), oldPrice = ti.startPrice;
   ENUM_TRADING_MODE oldMode = ti.currentMode;
   
   // Reverse the mode
   ti.currentMode = (ti.currentMode == MODE_MEAN_REVERSION) ? MODE_MOMENTUM : MODE_MEAN_REVERSION;
   
   // Reset grid center and streaks
   ti.startPrice = ti.lastBuyPrice = ti.lastSellPrice = price;
   ti.losingBuyStreak = ti.losingSellStreak = 0;
   ti.gridRebuilt = true;
   
   // Reset progressive lot counters
   ti.buyTradeCount = 0;
   ti.sellTradeCount = 0;
   
   Print("*** MANUAL REVERSAL REBUILD | Mode: ", 
         (oldMode == MODE_MEAN_REVERSION ? "MEAN_REV" : "MOMENTUM"), " -> ",
         (ti.currentMode == MODE_MEAN_REVERSION ? "MEAN_REV" : "MOMENTUM"),
         " | Old Center: ", oldPrice, " | New Center: ", price, " | Progressive Lots RESET");
}

void CloseAllProfitableTrades() {
   int closedCount = 0;
   double totalProfitClosed = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            if(profit > 0) {
               totalProfitClosed += profit;
               if(trade.PositionClose(ticket)) closedCount++;
            }
         }
      }
   }
   Print("*** CLOSED ", closedCount, " PROFITABLE TRADES | Total Profit: $", DoubleToString(totalProfitClosed, 2), " ***");
}

void CloseAllPositions() {
   int closedCount = 0;
   double totalProfitClosed = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            totalProfitClosed += profit;
            if(trade.PositionClose(ticket)) closedCount++;
         }
      }
   }
   Print("*** CLOSED ALL ", closedCount, " POSITIONS | Total P/L: $", DoubleToString(totalProfitClosed, 2), " ***");
}

// UI Functions
bool CreatePanel() {
   // FIXED: Defensive deletion - ensure old objects are removed before creating new ones
   // This handles edge cases where objects might still exist
   ObjectsDeleteAll(0, "GT_");
   panelCreated = false;
   
   if(!ObjectCreate(0, "GT_Panel", OBJ_RECTANGLE_LABEL, 0, 0, 0)) return false;
   
   ObjectSetInteger(0, "GT_Panel", OBJPROP_XDISTANCE, PanelX);
   ObjectSetInteger(0, "GT_Panel", OBJPROP_YDISTANCE, PanelY);
   ObjectSetInteger(0, "GT_Panel", OBJPROP_XSIZE, PanelWidth);
   ObjectSetInteger(0, "GT_Panel", OBJPROP_YSIZE, PanelHeight);
   ObjectSetInteger(0, "GT_Panel", OBJPROP_BGCOLOR, C'248,248,248');
   ObjectSetInteger(0, "GT_Panel", OBJPROP_BORDER_COLOR, C'70,70,70');
   ObjectSetInteger(0, "GT_Panel", OBJPROP_BORDER_TYPE, BORDER_RAISED);
   ObjectSetInteger(0, "GT_Panel", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "GT_Panel", OBJPROP_BACK, false);
   ObjectSetInteger(0, "GT_Panel", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "GT_Panel", OBJPROP_HIDDEN, true);
   
   CreateLabel("GT_Title", "GapTrader Pro v13.24 MOMENTUM - TORAMA (Press H to toggle)", 15, 8, 12, clrNavy);
   CreateButton("GT_CloseProfitsBtn", "CLOSE PROFITS", 15, 30, 100, 25, clrGreen);
   CreateButton("GT_RebuildBtn", "REBUILD GRID", 125, 30, 100, 25, clrBlue);
   CreateButton("GT_ReversalRebuildBtn", "REVERSAL REBUILD", 235, 30, 120, 25, clrOrange);
   CreateButton("GT_PauseBtn", "PAUSE", 365, 30, 80, 25, clrDarkOrange);
   CreateVerticalLine("GT_Separator", SEPARATOR_X, 65, PanelHeight - 80);
   
   // Create labels for all sections - streamlined
   string labelNames[] = {"GT_Status", "GT_Direction", "GT_Mode", "GT_TakeProfit", "GT_GlobalTP", "GT_BalanceEquity", 
                          "GT_Margin", "GT_MaxDrawdown", "GT_StartPrice", "GT_CurrentPrice", "GT_NextBuy", "GT_NextSell", "GT_Positions", 
                          "GT_NetPositions", "GT_TotalPL", "GT_ModeReversalStatus", "GT_ModeChanges", "GT_WinStreaks", 
                          "GT_LoseStreaks", "GT_GapSize", "GT_MaxPositions", "GT_LotInfo", "GT_ProgressiveLots",
                          "GT_RebuildModes", "GT_TimedRebuilds", "GT_NextRebuild", "GT_MaxTriggerRebuilds", "GT_TotalRebuilds"};
   
   int yPositions[] = {85, 105, 125, 170, 190, 235, 255, 275, 300, 320, 340, 360,
                       85, 105, 125, 155, 175, 195, 215, 260, 280, 300, 320,
                       365, 385, 405, 425, 445};
   
   int xPositions[] = {COL1_X, COL1_X, COL1_X, COL1_X, COL1_X, COL1_X, COL1_X, COL1_X, COL1_X, COL1_X, COL1_X, COL1_X,
                       COL2_X, COL2_X, COL2_X, COL2_X, COL2_X, COL2_X, COL2_X, COL2_X, COL2_X, COL2_X, COL2_X,
                       COL2_X, COL2_X, COL2_X, COL2_X, COL2_X};
   
   for(int i = 0; i < ArraySize(labelNames); i++) CreateLabel(labelNames[i], "", xPositions[i], yPositions[i], 10, clrBlack);
   
   // Create section headers - cleaned up
   string headers[] = {"STATUS", "TAKE PROFITS", "ACCOUNT", "LEVELS", "PERFORMANCE", "MODE REVERSAL", "GRID INFO", "REBUILD SYSTEM"};
   int headerY[] = {65, 150, 215, 280, 65, 135, 240, 345};
   int headerX[] = {COL1_X, COL1_X, COL1_X, COL1_X, COL1_X, COL2_X, COL2_X, COL2_X, COL2_X};
   
   for(int i = 0; i < ArraySize(headers); i++) CreateSectionHeader(headers[i], headerX[i], headerY[i]);
   
   panelCreated = true;
   return true;
}

bool CreateLabel(string name, string text, int x, int y, int size, color clr) {
   if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0)) return false;
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, PanelX + x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, PanelY + y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
}

bool CreateVerticalLine(string name, int x, int yStart, int height) {
   if(!ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0)) return false;
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, PanelX + x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, PanelY + yStart);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, 1);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'200,200,200');
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'200,200,200');
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
}

bool CreateSectionHeader(string text, int x, int y) {
   string name = "GT_Header_" + text;
   StringReplace(name, " ", ""); StringReplace(name, "&", "");
   if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0)) return false;
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, PanelX + x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, PanelY + y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrDarkSlateGray);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetString(0, name, OBJPROP_TEXT, "━━━ " + text + " ━━━");
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
}

bool CreateButton(string name, string text, int x, int y, int w, int h, color clr) {
   if(!ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0)) return false;
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, PanelX + x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, PanelY + y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   return true;
}

void SetPanelVisibility(bool visible) {
   if(!panelCreated) return;
   long timeframes = visible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS;
   
   string objects[] = {"GT_Panel", "GT_Title", "GT_CloseProfitsBtn", "GT_RebuildBtn", "GT_ReversalRebuildBtn", "GT_PauseBtn", "GT_Separator", 
                       "GT_Status", "GT_Direction", "GT_Mode", "GT_TakeProfit", "GT_GlobalTP", "GT_BalanceEquity", 
                       "GT_Margin", "GT_MaxDrawdown", "GT_StartPrice", "GT_CurrentPrice", "GT_NextBuy", "GT_NextSell", "GT_Positions", 
                       "GT_NetPositions", "GT_TotalPL", "GT_ModeReversalStatus", "GT_ModeChanges", "GT_WinStreaks", 
                       "GT_LoseStreaks", "GT_GapSize", "GT_MaxPositions", "GT_LotInfo", "GT_ProgressiveLots", "GT_RebuildModes", 
                       "GT_TimedRebuilds", "GT_NextRebuild", "GT_MaxTriggerRebuilds", "GT_TotalRebuilds", "GT_Header_STATUS", 
                       "GT_Header_TAKEPROFITS", "GT_Header_ACCOUNT", "GT_Header_LEVELS", "GT_Header_PERFORMANCE", 
                       "GT_Header_MODEREVERSAL", "GT_Header_GRIDINFO", "GT_Header_REBUILDSYSTEM"};
   
   for(int i = 0; i < ArraySize(objects); i++) ObjectSetInteger(0, objects[i], OBJPROP_TIMEFRAMES, timeframes);
   ChartRedraw();
}

void UpdatePanel() {
   if(!panelCreated) return;
   
   // Status section - show specific reason if stopped by drawdown
   string status;
   color statusColor;
   if(stoppedByDrawdown) {
      status = "Status: STOPPED (MAX DD)";
      statusColor = clrDarkRed;
   } else if(ti.isActive) {
      status = "Status: " + (ti.isPaused ? "PAUSED" : "ACTIVE");
      statusColor = ti.isPaused ? clrOrange : clrGreen;
   } else {
      status = "Status: STOPPED";
      statusColor = clrRed;
   }
   ObjectSetString(0, "GT_Status", OBJPROP_TEXT, status);
   ObjectSetInteger(0, "GT_Status", OBJPROP_COLOR, statusColor);
   
   string dir[] = {"BUY", "SELL", "BOTH"};
   ObjectSetString(0, "GT_Direction", OBJPROP_TEXT, "Direction: " + dir[TradeDirection]);
   
   string mode = "Mode: " + (ti.currentMode == MODE_MEAN_REVERSION ? "MEAN REV" : "MOMENTUM");
   ObjectSetString(0, "GT_Mode", OBJPROP_TEXT, mode);
   ObjectSetInteger(0, "GT_Mode", OBJPROP_COLOR, ti.currentMode == MODE_MEAN_REVERSION ? clrBlue : clrRed);
   
   // Take Profits section - show percentage and calculated dollar value
   double tpDollars = (TakeProfitPercent > 0) ? (ti.currentGapSize * TakeProfitPercent / 100.0) : 0;
   double slDollars = (StopLossPercent > 0) ? (ti.currentGapSize * StopLossPercent / 100.0) : 0;
   string tpText = (TakeProfitPercent > 0) ? DoubleToString(TakeProfitPercent, 0) + "% = $" + DoubleToString(tpDollars, 2) : "OFF";
   string slText = (StopLossPercent > 0) ? DoubleToString(StopLossPercent, 0) + "% = $" + DoubleToString(slDollars, 2) : "OFF";
   ObjectSetString(0, "GT_TakeProfit", OBJPROP_TEXT, "TP: " + tpText + " | SL: " + slText);
   
   // Global TP/SL section - also show percentage and calculated dollar value
   double globalTPDollars = (GlobalTakeProfitPercent > 0) ? (ti.currentGapSize * GlobalTakeProfitPercent / 100.0) : 0;
   double globalSLDollars = (GlobalSLPercent > 0) ? (ti.currentGapSize * GlobalSLPercent / 100.0) : 0;
   string globalTPText = (GlobalTakeProfitPercent > 0) ? DoubleToString(GlobalTakeProfitPercent, 0) + "% = $" + DoubleToString(globalTPDollars, 2) : "OFF";
   string globalSLText = (GlobalSLPercent > 0) ? DoubleToString(GlobalSLPercent, 0) + "% = $" + DoubleToString(globalSLDollars, 2) : "OFF";
   ObjectSetString(0, "GT_GlobalTP", OBJPROP_TEXT, "Global TP: " + globalTPText + " | SL: " + globalSLText);
   
   // Account section
   double balance = AccountInfoDouble(ACCOUNT_BALANCE), equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ObjectSetString(0, "GT_BalanceEquity", OBJPROP_TEXT, "Bal: $" + FormatNumber(balance) + " | Eq: $" + FormatNumber(equity));
   
   double margin = AccountInfoDouble(ACCOUNT_MARGIN), freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   ObjectSetString(0, "GT_Margin", OBJPROP_TEXT, "Used: $" + FormatNumber(margin) + " | Free: $" + FormatNumber(freeMargin));
   
   // Max Drawdown display
   string ddText = "Drawdown: " + DoubleToString(currentDrawdownPercent, 2) + "% | Peak: $" + FormatNumber(peakEquity) + " | Limit: " + DoubleToString(MaxDrawdownPercent, 1) + "%";
   ObjectSetString(0, "GT_MaxDrawdown", OBJPROP_TEXT, ddText);
   color ddColor = currentDrawdownPercent >= MaxDrawdownPercent * 0.9 ? clrRed : (currentDrawdownPercent >= MaxDrawdownPercent * 0.7 ? clrOrange : clrGreen);
   ObjectSetInteger(0, "GT_MaxDrawdown", OBJPROP_COLOR, ddColor);
   
   // Trading levels
   ObjectSetString(0, "GT_StartPrice", OBJPROP_TEXT, "Grid Center: " + DoubleToString(ti.startPrice, _Digits));
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ObjectSetString(0, "GT_CurrentPrice", OBJPROP_TEXT, "Current: " + DoubleToString(currentPrice, _Digits));
   ObjectSetString(0, "GT_NextBuy", OBJPROP_TEXT, "Next Buy: " + DoubleToString(GetNextBuyPrice(), _Digits));
   ObjectSetString(0, "GT_NextSell", OBJPROP_TEXT, "Next Sell: " + DoubleToString(GetNextSellPrice(), _Digits));
   
   // Performance section - EA positions only
   int totalPos = ti.buyPos + ti.sellPos;
   ObjectSetString(0, "GT_Positions", OBJPROP_TEXT, "EA: " + IntegerToString(ti.buyPos) + "B | " + IntegerToString(ti.sellPos) + "S | " + IntegerToString(totalPos) + " Total");
   
   // Net positions for all symbol positions
   double netBuyLots, netSellLots;
   CalcNetPositions(netBuyLots, netSellLots);
   string netPosText;
   if(netBuyLots > netSellLots) {
      netPosText = "Net Positions: BUY (" + DoubleToString(netBuyLots - netSellLots, 1) + " lots)";
      ObjectSetInteger(0, "GT_NetPositions", OBJPROP_COLOR, clrGreen);
   } else if(netSellLots > netBuyLots) {
      netPosText = "Net Positions: SELL (" + DoubleToString(netSellLots - netBuyLots, 1) + " lots)";
      ObjectSetInteger(0, "GT_NetPositions", OBJPROP_COLOR, clrRed);
   } else {
      netPosText = "Net Positions: NEUTRAL (0 lots)";
      ObjectSetInteger(0, "GT_NetPositions", OBJPROP_COLOR, clrGray);
   }
   ObjectSetString(0, "GT_NetPositions", OBJPROP_TEXT, netPosText);
   
   string pl = "P/L: " + (ti.totalProfit >= 0 ? "+" : "") + "$" + FormatNumber(ti.totalProfit);
   ObjectSetString(0, "GT_TotalPL", OBJPROP_TEXT, pl);
   ObjectSetInteger(0, "GT_TotalPL", OBJPROP_COLOR, ti.totalProfit >= 0 ? clrGreen : clrRed);
   
   // Mode Reversal section
   string reversalStatus = "Max Loss Reversal: " + (EnableModeReversalOnMaxLoss ? "ON" : "OFF") + 
                          " | Rebuild Reversal: " + (EnableModeReversalOnRebuild ? "ON" : "OFF");
   ObjectSetString(0, "GT_ModeReversalStatus", OBJPROP_TEXT, reversalStatus);
   ObjectSetInteger(0, "GT_ModeReversalStatus", OBJPROP_COLOR, (EnableModeReversalOnMaxLoss || EnableModeReversalOnRebuild) ? clrGreen : clrGray);
   
   ObjectSetString(0, "GT_ModeChanges", OBJPROP_TEXT, "Mode Changes: " + IntegerToString(ti.modeChanges) + " | Max Loss Trigger: " + IntegerToString(MaxLosingTrades));
   
   ObjectSetString(0, "GT_WinStreaks", OBJPROP_TEXT, "Win Streaks: B" + IntegerToString(ti.winningBuyStreak) + " | S" + IntegerToString(ti.winningSellStreak));
   ObjectSetString(0, "GT_LoseStreaks", OBJPROP_TEXT, "Lose Streaks: B" + IntegerToString(ti.losingBuyStreak) + " | S" + IntegerToString(ti.losingSellStreak));
   
   // Grid info section with proper position distribution display
   ObjectSetString(0, "GT_GapSize", OBJPROP_TEXT, "Gap Size: $" + DoubleToString(ti.currentGapSize, 2) + " (Orig: $" + DoubleToString(GapSize, 2) + ")");
   
   int originalMax = ti.originalMaxPos > 0 ? ti.originalMaxPos : MaxPositions;
   string maxPosText;
   if(TradeDirection == TRADE_BOTH) {
      // SACROSANCT: Each side gets full MaxPositions allocation
      maxPosText = "Max Pos: " + IntegerToString(ti.maxPosPerSide) + " per side (" + IntegerToString(ti.maxPosPerSide * 2) + " total, Orig: " + IntegerToString(originalMax) + " each)";
   } else {
      maxPosText = "Max Pos: " + IntegerToString(ti.maxPosPerSide) + " (Orig: " + IntegerToString(originalMax) + ")";
   }
   ObjectSetString(0, "GT_MaxPositions", OBJPROP_TEXT, maxPosText);
   
   string lotSizeText;
   if(UseAutoLotSize) {
      double currentLot = GetLotSize(true);
      lotSizeText = DoubleToString(AutoLotSize, 2) + " per $" + DoubleToString(AutoLotEquity, 0) + " (Base: " + DoubleToString(currentLot / (1 + ti.buyLotMult + (ti.buyTradeCount * LotIncrement)), 1) + ")";
   } else {
      lotSizeText = "MANUAL: " + DoubleToString(ManualLotSize, 2);
   }
   ObjectSetString(0, "GT_LotInfo", OBJPROP_TEXT, "Lot: " + lotSizeText + " | Scale: x" + DoubleToString(LotScaleFactor, 1));
   
   // Progressive lot info
   string progText = "Progressive: " + (UseProgressiveLots ? "ON" : "OFF") + " | Inc: " + DoubleToString(LotIncrement, 2) + 
                     " | B-Count: " + IntegerToString(ti.buyTradeCount) + " | S-Count: " + IntegerToString(ti.sellTradeCount);
   ObjectSetString(0, "GT_ProgressiveLots", OBJPROP_TEXT, progText);
   ObjectSetInteger(0, "GT_ProgressiveLots", OBJPROP_COLOR, UseProgressiveLots ? clrGreen : clrGray);
   
   // Next buy/sell lot sizes
   double nextBuyLot = GetLotSize(true);
   double nextSellLot = GetLotSize(false);
   
   // Rebuild system section
   string rebuildModesText = "Auto=" + (EnableAutoRebuild ? "ON" : "OFF") + " | Reversal on Rebuild=" + (EnableModeReversalOnRebuild ? "ON" : "OFF");
   ObjectSetString(0, "GT_RebuildModes", OBJPROP_TEXT, rebuildModesText);
   
   ObjectSetString(0, "GT_TimedRebuilds", OBJPROP_TEXT, "Timed: " + IntegerToString(ti.autoRebuilds) + "/" + IntegerToString(MaxRebuilds) + " | Interval: " + IntegerToString(RebuildIntervalMinutes) + "min");
   
   // Next rebuild countdown
   string nextRebuildText;
   if(!EnableAutoRebuild) {
      nextRebuildText = "Next Rebuild: DISABLED";
      ObjectSetInteger(0, "GT_NextRebuild", OBJPROP_COLOR, clrGray);
   } else if(ti.nextAutoRebuild <= 0) {
      nextRebuildText = "Next Rebuild: COMPLETE";
      ObjectSetInteger(0, "GT_NextRebuild", OBJPROP_COLOR, clrGray);
   } else {
      string remaining = FormatTimeRemaining(ti.nextAutoRebuild);
      if(remaining == "DUE") {
         nextRebuildText = "Next Rebuild: DUE NOW";
         ObjectSetInteger(0, "GT_NextRebuild", OBJPROP_COLOR, clrRed);
      } else {
         nextRebuildText = "Next Rebuild: " + remaining;
         ObjectSetInteger(0, "GT_NextRebuild", OBJPROP_COLOR, clrOrange);
      }
   }
   ObjectSetString(0, "GT_NextRebuild", OBJPROP_TEXT, nextRebuildText);
   
   ObjectSetString(0, "GT_MaxTriggerRebuilds", OBJPROP_TEXT, "Max Triggers: " + IntegerToString(ti.maxTriggerRebuilds) + "/" + IntegerToString(MaxRebuilds));
   
   int totalRebuilds = ti.autoRebuilds + ti.maxTriggerRebuilds;
   ObjectSetString(0, "GT_TotalRebuilds", OBJPROP_TEXT, "Total: " + IntegerToString(totalRebuilds) + "/" + IntegerToString(MaxRebuilds) + " | Mult: x" + DoubleToString(MaxPositionMultiplier, 1));
   ObjectSetInteger(0, "GT_TotalRebuilds", OBJPROP_COLOR, totalRebuilds >= MaxRebuilds ? clrRed : clrOrange);
   
   // Sync pause button with current state
   if(ti.isPaused) {
      ObjectSetString(0, "GT_PauseBtn", OBJPROP_TEXT, "RESUME");
      ObjectSetInteger(0, "GT_PauseBtn", OBJPROP_BGCOLOR, clrGreen);
   } else {
      ObjectSetString(0, "GT_PauseBtn", OBJPROP_TEXT, "PAUSE");
      ObjectSetInteger(0, "GT_PauseBtn", OBJPROP_BGCOLOR, clrDarkOrange);
   }
}
