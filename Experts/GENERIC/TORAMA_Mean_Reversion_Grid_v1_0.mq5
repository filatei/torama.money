//+------------------------------------------------------------------+
//|                                   TORAMA_Mean_Reversion_Grid_v1_0.mq5 |
//|                                      Copyright 2025, TORAMA CAPITAL |
//|                                               https://torama.money |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "1.00"
#property description "Mean Reversion Grid EA - Buy falling, Sell rising"
#property description "Takes profit when X positions become profitable"
#property description "Works with all symbols, fully broker-aware"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "=== GRID SETTINGS ==="
input double   GridSpacingPercent = 0.30;        // Grid spacing % of price
input int      MaxPositionsPerSide = 30;         // Max positions per side (BUY or SELL)
input double   LotSize = 0.01;                   // Lot size per position

input group "=== PROFIT TARGETS (% of Gap) ==="
input double   IndividualTPPercent = 300.0;      // Individual TP as % of gap (300 = 3x gap)
input double   IndividualSLPercent = 0.0;        // Individual SL as % of gap (0 = disabled)
input double   GlobalTPPercent = 500.0;          // Global TP for all positions (% of gap)
input double   GlobalSLPercent = 0.0;            // Global SL for all positions (% of gap)

input group "=== MEAN REVERSION LOGIC ==="
input int      ProfitableCountToClose = 5;       // Close all when X positions profitable (per side)
input bool     CloseBothSidesOnProfit = false;   // Close both BUY and SELL when one side profits

input group "=== RISK MANAGEMENT ==="
input double   SessionProfitPercent = 100.0;     // Session/Daily profit target (% of starting balance)
input bool     ResetSessionDaily = true;         // Reset session profit daily
input double   MaxDrawdownPercent = 15.0;        // Max drawdown % (emergency stop)

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                 // Maximum spread (points)
input int      MagicNumber = 77730;              // Magic number
input bool     ShowPanel = true;                 // Show info panel

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

// Position tracking
struct PositionInfo
{
   ulong ticket;
   double openPrice;
   double lotSize;
   int type;  // 0=BUY, 1=SELL
};

PositionInfo buyPositions[];
PositionInfo sellPositions[];

// Grid tracking
double lastBuyLevel = 0;
double lastSellLevel = 0;
double highestSellLevel = 0;
double lowestBuyLevel = 0;

// Risk management
double sessionStartBalance = 0;
double sessionProfit = 0;
double sessionProfitTarget = 0;
bool sessionTargetReached = false;
datetime lastSessionReset = 0;
int currentDay = 0;

// Grid rebuild control
bool needsRebuild = false;
int lastTotalPositions = 0;

// EA control
bool isPaused = false;

// Panel
string panelPrefix = "MeanRevPanel_";

// Symbol properties (broker-aware)
double pointValue = 0;
double tickValue = 0;
double tickSize = 0;
int digits = 0;
double minLot = 0;
double maxLot = 0;
double lotStep = 0;
double minVolume = 0;

// Normalized lot size (working variable)
double normalizedLotSize = 0;

// Calculated values
double currentGapSize = 0;
double individualTPDollars = 0;
double individualSLDollars = 0;
double globalTPDollars = 0;
double globalSLDollars = 0;

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize session tracking
   sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
   sessionProfit = 0;
   sessionTargetReached = false;
   lastSessionReset = TimeCurrent();
   
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   currentDay = time.day;
   
   // Get broker properties
   if(!InitializeSymbolProperties())
   {
      Print("❌ Failed to initialize symbol properties!");
      return INIT_FAILED;
   }
   
   // Calculate gap-based values
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   currentGapSize = currentPrice * (GridSpacingPercent / 100.0);
   
   // Calculate profit/loss targets in dollars
   individualTPDollars = currentGapSize * (IndividualTPPercent / 100.0);
   individualSLDollars = (IndividualSLPercent > 0) ? currentGapSize * (IndividualSLPercent / 100.0) : 0;
   globalTPDollars = currentGapSize * (GlobalTPPercent / 100.0);
   globalSLDollars = (GlobalSLPercent > 0) ? currentGapSize * (GlobalSLPercent / 100.0) : 0;
   
   // Validate and normalize lot size
   normalizedLotSize = NormalizeLotSize(LotSize);
   
   // Display initialization info
   Print("╔════════════════════════════════════════════════════════════════╗");
   Print("║     TORAMA MEAN REVERSION GRID EA v1.0                         ║");
   Print("╚════════════════════════════════════════════════════════════════╝");
   Print("Symbol: ", _Symbol);
   Print("Account: ", AccountInfoString(ACCOUNT_NAME), " (", AccountInfoString(ACCOUNT_SERVER), ")");
   Print("Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("═══════════════════════════════════════");
   
   Print("📊 MEAN REVERSION MODE");
   Print("Strategy: Buy falling, Sell rising");
   Print("Close when: ", ProfitableCountToClose, " positions profitable per side");
   Print("Close both sides: ", CloseBothSidesOnProfit ? "YES" : "NO");
   Print("Grid Spacing: ", GridSpacingPercent, "% = $", DoubleToString(currentGapSize, 2));
   Print("Max Positions: ", MaxPositionsPerSide, " per side (", MaxPositionsPerSide * 2, " total)");
   Print("Lot Size: ", DoubleToString(normalizedLotSize, 2), " (normalized from ", DoubleToString(LotSize, 2), ")");
   Print("Individual TP: ", IndividualTPPercent, "% of gap = $", DoubleToString(individualTPDollars, 2));
   Print("Individual SL: ", IndividualSLPercent > 0 ? DoubleToString(IndividualSLPercent, 0) + "% of gap = $" + DoubleToString(individualSLDollars, 2) : "DISABLED");
   Print("Global TP: ", GlobalTPPercent, "% of gap = $", DoubleToString(globalTPDollars, 2));
   Print("Global SL: ", GlobalSLPercent > 0 ? DoubleToString(GlobalSLPercent, 0) + "% of gap = $" + DoubleToString(globalSLDollars, 2) : "DISABLED");
   Print("Session Target: ", SessionProfitPercent, "% = $", DoubleToString(sessionProfitTarget, 2));
   Print("Max Drawdown: ", MaxDrawdownPercent, "%");
   Print("═══════════════════════════════════════");
   
   // Sync existing positions
   SyncPositions();
   
   Print("✅ EA initialized successfully!");
   Print("Waiting for price movement...");
   
   // Create panel
   if(ShowPanel) CreatePanel();
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Remove panel
   if(ShowPanel) DeletePanel();
   
   Print("EA removed: ", reason);
}

//+------------------------------------------------------------------+
//| EXPERT TICK FUNCTION                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check if EA is paused
   if(isPaused)
   {
      UpdatePanel(); // Still update panel to show current status
      return;
   }
   
   // Sync positions
   SyncPositions();
   
   // Check for automatic grid rebuild (all positions closed)
   int totalPositions = ArraySize(buyPositions) + ArraySize(sellPositions);
   
   if(totalPositions == 0 && lastTotalPositions > 0)
   {
      // All positions just closed - trigger rebuild
      Print("🔄 All positions closed - Auto-rebuilding grid...");
      needsRebuild = true;
   }
   
   lastTotalPositions = totalPositions;
   
   // Execute rebuild if flagged
   if(needsRebuild)
   {
      RebuildGrid();
      needsRebuild = false;
   }
   
   // Check session reset
   CheckSessionReset();
   
   // Check session profit target
   if(SessionProfitPercent > 0 && !sessionTargetReached)
   {
      double totalProfit = CalculateTotalProfit();
      sessionProfit = totalProfit;
      
      if(sessionProfit >= sessionProfitTarget)
      {
         sessionTargetReached = true;
         Print("🎯 SESSION TARGET REACHED!");
         Print("   Target: $", DoubleToString(sessionProfitTarget, 2));
         Print("   Achieved: $", DoubleToString(sessionProfit, 2));
         Print("   EA paused until session reset");
         CloseAllPositions();
         UpdatePanel();
         return;
      }
   }
   
   // Check max drawdown
   if(MaxDrawdownPercent > 0)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double drawdownPercent = ((balance - equity) / balance) * 100.0;
      
      if(drawdownPercent >= MaxDrawdownPercent)
      {
         Print("🚨 MAX DRAWDOWN REACHED: ", DoubleToString(drawdownPercent, 2), "%");
         Print("   Emergency closing all positions!");
         CloseAllPositions();
         UpdatePanel();
         return;
      }
   }
   
   // Check spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      static datetime lastSpreadWarning = 0;
      if(TimeCurrent() - lastSpreadWarning >= 300) // Warn every 5 minutes
      {
         Print("⚠️ SPREAD TOO HIGH: ", spread, " > ", MaxSpread, " - Trading blocked");
         lastSpreadWarning = TimeCurrent();
      }
      UpdatePanel();
      return;
   }
   
   // Skip if session target reached
   if(sessionTargetReached)
   {
      static datetime lastSessionWarning = 0;
      if(TimeCurrent() - lastSessionWarning >= 300) // Warn every 5 minutes
      {
         Print("⚠️ SESSION TARGET REACHED - Trading blocked until reset");
         lastSessionWarning = TimeCurrent();
      }
      UpdatePanel();
      return;
   }
   
   // Check global TP/SL for BUY side
   CheckGlobalTPSL("BUY");
   
   // Check global TP/SL for SELL side
   CheckGlobalTPSL("SELL");
   
   // Check profitable count for BUY side
   if(CheckProfitableCount("BUY"))
   {
      UpdatePanel();
      return;
   }
   
   // Check profitable count for SELL side
   if(CheckProfitableCount("SELL"))
   {
      UpdatePanel();
      return;
   }
   
   // Main mean reversion logic
   ManageMeanReversionGrid();
   
   // Update panel
   if(ShowPanel) UpdatePanel();
}

//+------------------------------------------------------------------+
//| INITIALIZE SYMBOL PROPERTIES (Broker-Aware)                      |
//+------------------------------------------------------------------+
bool InitializeSymbolProperties()
{
   Print("🔍 Probing broker properties for ", _Symbol, "...");
   
   // Get symbol digits
   digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 0)
   {
      Print("❌ ERROR: Could not get SYMBOL_DIGITS for ", _Symbol);
      return false;
   }
   
   // Get tick size
   tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0)
   {
      Print("⚠️ WARNING: SYMBOL_TRADE_TICK_SIZE is 0, using SYMBOL_POINT");
      tickSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(tickSize == 0)
      {
         Print("❌ ERROR: Both SYMBOL_TRADE_TICK_SIZE and SYMBOL_POINT are 0");
         return false;
      }
   }
   
   // Get tick value
   tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue == 0)
   {
      Print("⚠️ WARNING: SYMBOL_TRADE_TICK_VALUE is 0, calculating manually...");
      // Try to calculate tick value for crypto/forex
      double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      if(contractSize > 0)
      {
         tickValue = tickSize * contractSize;
         Print("   Calculated tick value from contract size: $", tickValue);
      }
      else
      {
         Print("❌ ERROR: Cannot calculate tick value - no contract size");
         return false;
      }
   }
   
   // Get point value
   pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(pointValue == 0)
   {
      Print("❌ ERROR: SYMBOL_POINT is 0");
      return false;
   }
   
   // Get lot properties
   minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   
   if(minLot == 0)
   {
      Print("⚠️ WARNING: SYMBOL_VOLUME_MIN is 0, defaulting to 0.01");
      minLot = 0.01;
      minVolume = 0.01;
   }
   
   if(maxLot == 0)
   {
      Print("⚠️ WARNING: SYMBOL_VOLUME_MAX is 0, defaulting to 100");
      maxLot = 100.0;
   }
   
   if(lotStep == 0)
   {
      Print("⚠️ WARNING: SYMBOL_VOLUME_STEP is 0, defaulting to 0.01");
      lotStep = 0.01;
   }
   
   // Get filling mode
   int fillingMode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   string fillingModeStr = "";
   if((fillingMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      fillingModeStr += "FOK ";
   if((fillingMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      fillingModeStr += "IOC ";
   if((fillingMode & SYMBOL_FILLING_BOC) == SYMBOL_FILLING_BOC)
      fillingModeStr += "BOC ";
   if(fillingModeStr == "")
      fillingModeStr = "NONE";
   
   // Get trade mode
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   string tradeModeStr = "";
   switch(tradeMode)
   {
      case SYMBOL_TRADE_MODE_DISABLED: tradeModeStr = "DISABLED"; break;
      case SYMBOL_TRADE_MODE_LONGONLY: tradeModeStr = "LONG ONLY"; break;
      case SYMBOL_TRADE_MODE_SHORTONLY: tradeModeStr = "SHORT ONLY"; break;
      case SYMBOL_TRADE_MODE_CLOSEONLY: tradeModeStr = "CLOSE ONLY"; break;
      case SYMBOL_TRADE_MODE_FULL: tradeModeStr = "FULL"; break;
      default: tradeModeStr = "UNKNOWN";
   }
   
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("❌ ERROR: Trading is DISABLED for ", _Symbol);
      return false;
   }
   
   // Check if symbol is custom (crypto, etc)
   bool isCustom = SymbolInfoInteger(_Symbol, SYMBOL_CUSTOM);
   
   // Get contract size
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   
   // Get margin requirements
   double marginInitial = SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_INITIAL);
   double marginMaintenance = SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_MAINTENANCE);
   
   // Get stop levels
   int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   
   Print("╔════════════════════════════════════════════════════════════════╗");
   Print("║ BROKER PROPERTIES FOR ", _Symbol);
   Print("╠════════════════════════════════════════════════════════════════╣");
   Print("║ Symbol Type: ", isCustom ? "CUSTOM (Crypto/CFD)" : "STANDARD (Forex)");
   Print("║ Trade Mode: ", tradeModeStr);
   Print("║ Filling Mode: ", fillingModeStr);
   Print("╠════════════════════════════════════════════════════════════════╣");
   Print("║ Price Properties:");
   Print("║   Digits: ", digits);
   Print("║   Tick Size: ", DoubleToString(tickSize, digits));
   Print("║   Tick Value: $", DoubleToString(tickValue, 2));
   Print("║   Point Value: ", DoubleToString(pointValue, digits));
   Print("║   Contract Size: ", DoubleToString(contractSize, 2));
   Print("╠════════════════════════════════════════════════════════════════╣");
   Print("║ Volume Properties:");
   Print("║   Min Lot: ", DoubleToString(minLot, 2));
   Print("║   Max Lot: ", DoubleToString(maxLot, 2));
   Print("║   Lot Step: ", DoubleToString(lotStep, 2));
   Print("╠════════════════════════════════════════════════════════════════╣");
   Print("║ Stop Levels:");
   Print("║   Stop Level: ", stopLevel, " points");
   Print("║   Freeze Level: ", freezeLevel, " points");
   Print("╠════════════════════════════════════════════════════════════════╣");
   Print("║ Margin:");
   Print("║   Initial Margin: ", DoubleToString(marginInitial, 2));
   Print("║   Maintenance Margin: ", DoubleToString(marginMaintenance, 2));
   Print("╚════════════════════════════════════════════════════════════════╝");
   
   return true;
}

//+------------------------------------------------------------------+
//| NORMALIZE LOT SIZE                                                |
//+------------------------------------------------------------------+
double NormalizeLotSize(double lots)
{
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = MathFloor(lots / lotStep) * lotStep;
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| MEAN REVERSION GRID MANAGEMENT                                    |
//+------------------------------------------------------------------+
void ManageMeanReversionGrid()
{
   static datetime lastLogTime = 0;
   datetime currentTime = TimeCurrent();
   
   // Validate prices
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(ask == 0 || bid == 0)
   {
      Print("⚠️ WARNING: Invalid prices (ASK=", ask, ", BID=", bid, "), skipping grid management");
      return;
   }
   
   if(ask < bid)
   {
      Print("⚠️ WARNING: ASK < BID (ASK=", ask, ", BID=", bid, "), skipping grid management");
      return;
   }
   
   double currentPrice = (ask + bid) / 2.0;
   double gridSpacing = currentPrice * (GridSpacingPercent / 100.0);
   
   // Validate grid spacing
   if(gridSpacing <= 0)
   {
      Print("❌ ERROR: Invalid grid spacing: ", gridSpacing);
      return;
   }
   
   int buyCount = ArraySize(buyPositions);
   int sellCount = ArraySize(sellPositions);
   
   // Periodic diagnostic logging (every 60 seconds)
   if(currentTime - lastLogTime >= 60)
   {
      lastLogTime = currentTime;
      Print("📊 Grid Status Check:");
      Print("   Current Price: $", DoubleToString(currentPrice, digits));
      Print("   Grid Spacing: $", DoubleToString(gridSpacing, 2), " (", GridSpacingPercent, "%)");
      Print("   BUY Positions: ", buyCount, "/", MaxPositionsPerSide);
      Print("   SELL Positions: ", sellCount, "/", MaxPositionsPerSide);
      if(buyCount > 0)
         Print("   Lowest BUY: $", DoubleToString(lowestBuyLevel, digits), " | Next: $", DoubleToString(lowestBuyLevel - gridSpacing, digits));
      else if(lastBuyLevel > 0)
         Print("   First BUY Level: $", DoubleToString(lastBuyLevel, digits), " | Current: $", DoubleToString(currentPrice, digits));
      if(sellCount > 0)
         Print("   Highest SELL: $", DoubleToString(highestSellLevel, digits), " | Next: $", DoubleToString(highestSellLevel + gridSpacing, digits));
      else if(lastSellLevel > 0)
         Print("   First SELL Level: $", DoubleToString(lastSellLevel, digits), " | Current: $", DoubleToString(currentPrice, digits));
   }
   
   // Initialize grid if no positions - but DON'T return, let it place first trades
   if(buyCount == 0 && sellCount == 0)
   {
      // Only initialize if levels are not set
      if(lastBuyLevel == 0 && lastSellLevel == 0)
      {
         lastBuyLevel = currentPrice - gridSpacing;
         lastSellLevel = currentPrice + gridSpacing;
         lowestBuyLevel = lastBuyLevel;
         highestSellLevel = lastSellLevel;
         Print("📍 Grid initialized - Waiting for price to cross levels:");
         Print("   First BUY level: $", DoubleToString(lastBuyLevel, digits));
         Print("   First SELL level: $", DoubleToString(lastSellLevel, digits));
         Print("   Current price: $", DoubleToString(currentPrice, digits));
      }
   }
   
   // MEAN REVERSION: Buy when falling
   if(buyCount < MaxPositionsPerSide)
   {
      if(buyCount == 0)
      {
         // First BUY position - place when price drops below level
         if(currentPrice <= lastBuyLevel && lastBuyLevel > 0)
         {
            Print("🎯 First BUY trigger: Price ", DoubleToString(currentPrice, digits), 
                  " <= Level ", DoubleToString(lastBuyLevel, digits));
            if(OpenPosition("BUY", currentPrice))
            {
               lastBuyLevel = currentPrice;
               lowestBuyLevel = currentPrice;
            }
         }
      }
      else
      {
         // Add BUY when price drops another grid level
         if(currentPrice <= lowestBuyLevel - gridSpacing)
         {
            Print("🎯 Additional BUY trigger: Price ", DoubleToString(currentPrice, digits), 
                  " <= ", DoubleToString(lowestBuyLevel - gridSpacing, digits));
            if(OpenPosition("BUY", currentPrice))
            {
               lowestBuyLevel = currentPrice;
               lastBuyLevel = currentPrice;
            }
         }
      }
   }
   
   // MEAN REVERSION: Sell when rising
   if(sellCount < MaxPositionsPerSide)
   {
      if(sellCount == 0)
      {
         // First SELL position - place when price rises above level
         if(currentPrice >= lastSellLevel && lastSellLevel > 0)
         {
            Print("🎯 First SELL trigger: Price ", DoubleToString(currentPrice, digits), 
                  " >= Level ", DoubleToString(lastSellLevel, digits));
            if(OpenPosition("SELL", currentPrice))
            {
               lastSellLevel = currentPrice;
               highestSellLevel = currentPrice;
            }
         }
      }
      else
      {
         // Add SELL when price rises another grid level
         if(currentPrice >= highestSellLevel + gridSpacing)
         {
            Print("🎯 Additional SELL trigger: Price ", DoubleToString(currentPrice, digits), 
                  " >= ", DoubleToString(highestSellLevel + gridSpacing, digits));
            if(OpenPosition("SELL", currentPrice))
            {
               highestSellLevel = currentPrice;
               lastSellLevel = currentPrice;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OPEN POSITION                                                     |
//+------------------------------------------------------------------+
bool OpenPosition(string direction, double price)
{
   // Validate inputs
   if(direction != "BUY" && direction != "SELL")
   {
      Print("❌ ERROR: Invalid direction: ", direction);
      return false;
   }
   
   // Use the normalized lot size
   double lots = normalizedLotSize;
   
   // Validate lot size
   if(lots < minLot)
   {
      Print("⚠️ WARNING: Lot size ", lots, " below minimum ", minLot, ", adjusting...");
      lots = minLot;
   }
   
   if(lots > maxLot)
   {
      Print("⚠️ WARNING: Lot size ", lots, " above maximum ", maxLot, ", adjusting...");
      lots = maxLot;
   }
   
   // Calculate TP and SL distances
   double tpDistance = CalculateTPSLDistance(individualTPDollars, lots, direction);
   double slDistance = (individualSLDollars > 0) ? CalculateTPSLDistance(individualSLDollars, lots, direction) : 0;
   
   ENUM_ORDER_TYPE orderType = (direction == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   // Get current prices
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(ask == 0 || bid == 0)
   {
      Print("❌ ERROR: Cannot get prices (ASK=", ask, ", BID=", bid, ")");
      return false;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lots;
   request.type = orderType;
   request.price = (orderType == ORDER_TYPE_BUY) ? ask : bid;
   request.deviation = 50; // Increased slippage tolerance for crypto/volatile markets
   request.magic = MagicNumber;
   request.comment = "MeanRev_" + direction;
   request.type_time = ORDER_TIME_GTC;
   
   // Set appropriate filling mode
   int fillingMode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      request.type_filling = ORDER_FILLING_FOK;
   else if((fillingMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      request.type_filling = ORDER_FILLING_IOC;
   else
      request.type_filling = ORDER_FILLING_RETURN;
   
   // Set TP/SL if enabled
   if(tpDistance > 0)
   {
      if(orderType == ORDER_TYPE_BUY)
         request.tp = NormalizeDouble(request.price + tpDistance, digits);
      else
         request.tp = NormalizeDouble(request.price - tpDistance, digits);
   }
   
   if(slDistance > 0)
   {
      if(orderType == ORDER_TYPE_BUY)
         request.sl = NormalizeDouble(request.price - slDistance, digits);
      else
         request.sl = NormalizeDouble(request.price + slDistance, digits);
   }
   
   // Retry logic for order sending
   int maxRetries = 3;
   int retryCount = 0;
   
   while(retryCount < maxRetries)
   {
      // Reset result
      ZeroMemory(result);
      
      // Update price before each attempt
      if(retryCount > 0)
      {
         ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         request.price = (orderType == ORDER_TYPE_BUY) ? ask : bid;
         
         // Recalculate TP/SL with new price
         if(tpDistance > 0)
         {
            if(orderType == ORDER_TYPE_BUY)
               request.tp = NormalizeDouble(request.price + tpDistance, digits);
            else
               request.tp = NormalizeDouble(request.price - tpDistance, digits);
         }
         
         if(slDistance > 0)
         {
            if(orderType == ORDER_TYPE_BUY)
               request.sl = NormalizeDouble(request.price - slDistance, digits);
            else
               request.sl = NormalizeDouble(request.price + slDistance, digits);
         }
      }
      
      if(!OrderSend(request, result))
      {
         int error = GetLastError();
         Print("❌ OrderSend failed (Attempt ", retryCount + 1, "/", maxRetries, "): ", error);
         Print("   Direction: ", direction);
         Print("   Price: ", DoubleToString(request.price, digits));
         Print("   Volume: ", DoubleToString(request.volume, 2));
         Print("   Error Description: ", ErrorDescription(error));
         
         retryCount++;
         if(retryCount < maxRetries)
         {
            Sleep(1000); // Wait 1 second before retry
            continue;
         }
         return false;
      }
      
      // Check result code
      if(result.retcode == TRADE_RETCODE_DONE)
      {
         Print("✅ ", direction, " position opened successfully!");
         Print("   Ticket: ", result.order);
         Print("   Price: $", DoubleToString(result.price, digits));
         Print("   Volume: ", DoubleToString(result.volume, 2));
         if(tpDistance > 0)
            Print("   TP: $", DoubleToString(request.tp, digits));
         if(slDistance > 0)
            Print("   SL: $", DoubleToString(request.sl, digits));
         
         return true;
      }
      else
      {
         Print("⚠️ Order not executed (Attempt ", retryCount + 1, "/", maxRetries, ")");
         Print("   Return Code: ", result.retcode);
         Print("   Description: ", TradeRetcodeDescription(result.retcode));
         
         // Handle specific return codes
         if(result.retcode == TRADE_RETCODE_REQUOTE || 
            result.retcode == TRADE_RETCODE_PRICE_OFF ||
            result.retcode == TRADE_RETCODE_PRICE_CHANGED)
         {
            retryCount++;
            if(retryCount < maxRetries)
            {
               Sleep(500);
               continue;
            }
         }
         else if(result.retcode == TRADE_RETCODE_INVALID_VOLUME)
         {
            Print("   Attempting to adjust volume...");
            lots = NormalizeLotSize(lots);
            request.volume = lots;
            retryCount++;
            if(retryCount < maxRetries)
               continue;
         }
         else
         {
            // Other errors - don't retry
            return false;
         }
      }
      
      retryCount++;
   }
   
   Print("❌ Failed to open position after ", maxRetries, " attempts");
   return false;
}

//+------------------------------------------------------------------+
//| CALCULATE TP/SL DISTANCE FOR DESIRED PROFIT                      |
//+------------------------------------------------------------------+
double CalculateTPSLDistance(double desiredProfitDollars, double lotSize, string direction)
{
   if(desiredProfitDollars <= 0) return 0;
   
   double currentPrice = (direction == "BUY") ? 
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
                         SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Test with $100 price movement
   double testDistance = 100.0;
   double testPrice = (direction == "BUY") ? currentPrice + testDistance : currentPrice - testDistance;
   
   // Calculate profit for test distance
   double priceChange = MathAbs(testPrice - currentPrice);
   double ticks = priceChange / tickSize;
   double profitForTest = ticks * tickValue * lotSize;
   
   if(profitForTest == 0) return 0;
   
   // Scale to desired profit
   double requiredDistance = (desiredProfitDollars / profitForTest) * testDistance;
   
   return NormalizeDouble(requiredDistance, digits);
}

//+------------------------------------------------------------------+
//| CHECK GLOBAL TP/SL                                                |
//+------------------------------------------------------------------+
void CheckGlobalTPSL(string side)
{
   if(GlobalTPPercent <= 0 && GlobalSLPercent <= 0) return;
   
   PositionInfo positions[];
   if(side == "BUY")
      ArrayCopy(positions, buyPositions);
   else
      ArrayCopy(positions, sellPositions);
   
   if(ArraySize(positions) == 0) return;
   
   double totalPL = 0;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(!PositionSelectByTicket(positions[i].ticket)) continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT);
      double swap = PositionGetDouble(POSITION_SWAP);
      totalPL += profit + swap;
   }
   
   // Check Global TP
   if(GlobalTPPercent > 0 && totalPL >= globalTPDollars)
   {
      Print("🎯 GLOBAL TP HIT for ", side, " side!");
      Print("   Target: $", DoubleToString(globalTPDollars, 2));
      Print("   Achieved: $", DoubleToString(totalPL, 2));
      
      if(CloseBothSidesOnProfit)
      {
         Print("   Closing BOTH sides (CloseBothSidesOnProfit = true)");
         CloseAllPositions();
      }
      else
      {
         Print("   Closing ", side, " side only");
         ClosePositionsSide(side);
      }
   }
   
   // Check Global SL
   if(GlobalSLPercent > 0 && totalPL <= -globalSLDollars)
   {
      Print("🚨 GLOBAL SL HIT for ", side, " side!");
      Print("   Limit: -$", DoubleToString(globalSLDollars, 2));
      Print("   Current: $", DoubleToString(totalPL, 2));
      Print("   Closing ", side, " side");
      ClosePositionsSide(side);
   }
}

//+------------------------------------------------------------------+
//| CHECK PROFITABLE COUNT                                            |
//+------------------------------------------------------------------+
bool CheckProfitableCount(string side)
{
   if(ProfitableCountToClose <= 0) return false;
   
   PositionInfo positions[];
   if(side == "BUY")
      ArrayCopy(positions, buyPositions);
   else
      ArrayCopy(positions, sellPositions);
   
   if(ArraySize(positions) == 0) return false;
   
   int profitableCount = 0;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(!PositionSelectByTicket(positions[i].ticket)) continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT);
      double swap = PositionGetDouble(POSITION_SWAP);
      double totalPL = profit + swap;
      
      if(totalPL > 0)
      {
         profitableCount++;
      }
   }
   
   if(profitableCount >= ProfitableCountToClose)
   {
      Print("💰 PROFITABLE COUNT REACHED for ", side, " side!");
      Print("   Profitable positions: ", profitableCount, " >= ", ProfitableCountToClose);
      
      if(CloseBothSidesOnProfit)
      {
         Print("   Closing BOTH sides (CloseBothSidesOnProfit = true)");
         CloseAllPositions();
      }
      else
      {
         Print("   Closing ", side, " side only");
         ClosePositionsSide(side);
      }
      
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| CLOSE POSITIONS FOR ONE SIDE                                      |
//+------------------------------------------------------------------+
void ClosePositionsSide(string side)
{
   if(side != "BUY" && side != "SELL")
   {
      Print("❌ ERROR: Invalid side: ", side);
      return;
   }
   
   PositionInfo positions[];
   if(side == "BUY")
      ArrayCopy(positions, buyPositions);
   else
      ArrayCopy(positions, sellPositions);
   
   int posCount = ArraySize(positions);
   if(posCount == 0)
   {
      Print("ℹ️ No ", side, " positions to close");
      return;
   }
   
   Print("🔄 Closing ", posCount, " ", side, " position(s)...");
   
   int closed = 0;
   int failed = 0;
   
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(positions[i].ticket))
      {
         Print("⚠️ Position ", positions[i].ticket, " not found (already closed?)");
         continue;
      }
      
      // Get position details
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double profit = PositionGetDouble(POSITION_PROFIT);
      
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      
      request.action = TRADE_ACTION_DEAL;
      request.position = positions[i].ticket;
      request.symbol = _Symbol;
      request.volume = volume;
      request.deviation = 50;
      request.magic = MagicNumber;
      request.type = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      // Set filling mode
      int fillingMode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
      if((fillingMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
         request.type_filling = ORDER_FILLING_FOK;
      else if((fillingMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
         request.type_filling = ORDER_FILLING_IOC;
      else
         request.type_filling = ORDER_FILLING_RETURN;
      
      // Retry logic for closing
      int maxRetries = 3;
      bool success = false;
      
      for(int retry = 0; retry < maxRetries; retry++)
      {
         // Update price for retry
         if(retry > 0)
         {
            Sleep(500);
            request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         }
         
         if(!OrderSend(request, result))
         {
            int error = GetLastError();
            Print("❌ Close failed for ticket ", positions[i].ticket, " (Attempt ", retry + 1, "/", maxRetries, ")");
            Print("   Error: ", ErrorDescription(error));
            continue;
         }
         
         if(result.retcode == TRADE_RETCODE_DONE)
         {
            Print("✅ Closed ticket ", positions[i].ticket, " | Volume: ", DoubleToString(volume, 2), 
                  " | Entry: $", DoubleToString(openPrice, digits), 
                  " | Exit: $", DoubleToString(result.price, digits),
                  " | P/L: $", DoubleToString(profit, 2));
            closed++;
            success = true;
            break;
         }
         else
         {
            Print("⚠️ Close attempt ", retry + 1, " failed for ticket ", positions[i].ticket);
            Print("   Retcode: ", TradeRetcodeDescription(result.retcode));
            
            if(result.retcode == TRADE_RETCODE_REQUOTE || 
               result.retcode == TRADE_RETCODE_PRICE_OFF ||
               result.retcode == TRADE_RETCODE_PRICE_CHANGED)
            {
               continue; // Retry
            }
            else
            {
               break; // Don't retry for other errors
            }
         }
      }
      
      if(!success)
      {
         failed++;
         Print("❌ Failed to close ticket ", positions[i].ticket, " after ", maxRetries, " attempts");
      }
   }
   
   Print("═══════════════════════════════════════");
   Print("Close Summary for ", side, " positions:");
   Print("   Closed: ", closed);
   Print("   Failed: ", failed);
   Print("   Total: ", posCount);
   Print("═══════════════════════════════════════");
   
   // Reset levels for this side
   if(side == "BUY")
   {
      lastBuyLevel = 0;
      lowestBuyLevel = 0;
   }
   else
   {
      lastSellLevel = 0;
      highestSellLevel = 0;
   }
   
   SyncPositions();
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   ClosePositionsSide("BUY");
   ClosePositionsSide("SELL");
}

//+------------------------------------------------------------------+
//| SYNC POSITIONS                                                    |
//+------------------------------------------------------------------+
void SyncPositions()
{
   ArrayResize(buyPositions, 0);
   ArrayResize(sellPositions, 0);
   
   int total = PositionsTotal();
   
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      PositionInfo pos;
      pos.ticket = ticket;
      pos.openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      pos.lotSize = PositionGetDouble(POSITION_VOLUME);
      pos.type = (int)PositionGetInteger(POSITION_TYPE);
      
      if(pos.type == POSITION_TYPE_BUY)
      {
         int size = ArraySize(buyPositions);
         ArrayResize(buyPositions, size + 1);
         buyPositions[size] = pos;
      }
      else
      {
         int size = ArraySize(sellPositions);
         ArrayResize(sellPositions, size + 1);
         sellPositions[size] = pos;
      }
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                            |
//+------------------------------------------------------------------+
double CalculateTotalProfit()
{
   double totalProfit = 0;
   
   for(int i = 0; i < ArraySize(buyPositions); i++)
   {
      if(PositionSelectByTicket(buyPositions[i].ticket))
         totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   
   for(int i = 0; i < ArraySize(sellPositions); i++)
   {
      if(PositionSelectByTicket(sellPositions[i].ticket))
         totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   
   return totalProfit;
}

//+------------------------------------------------------------------+
//| CHECK SESSION RESET                                               |
//+------------------------------------------------------------------+
void CheckSessionReset()
{
   if(SessionProfitPercent <= 0) return;
   
   if(ResetSessionDaily)
   {
      MqlDateTime time;
      TimeToStruct(TimeCurrent(), time);
      
      if(time.day != currentDay)
      {
         currentDay = time.day;
         sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
         sessionProfit = 0;
         sessionTargetReached = false;
         lastSessionReset = TimeCurrent();
         
         Print("🌅 NEW DAY - Session reset");
         Print("   Start Balance: $", DoubleToString(sessionStartBalance, 2));
         Print("   Profit Target: $", DoubleToString(sessionProfitTarget, 2));
      }
   }
}

//+------------------------------------------------------------------+
//| CREATE PANEL                                                      |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 20;
   int y = 50;
   int width = 280;
   int rowHeight = 20;
   
   // Background
   ObjectCreate(0, panelPrefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YSIZE, 420);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BACK, false);
   
   int row = 0;
   
   // Title
   CreateLabel(panelPrefix + "Title", "MEAN REVERSION GRID v1.0", x + 10, y + 10 + (row++ * rowHeight), clrYellow);
   row++; // Skip row
   
   // Position counts on same line
   CreateLabel(panelPrefix + "BuyPos", "BUY: 0", x + 10, y + 10 + (row * rowHeight), clrLime);
   CreateLabel(panelPrefix + "SellPos", "SELL: 0", x + 100, y + 10 + (row++ * rowHeight), clrRed);
   
   // P/L on same line
   CreateLabel(panelPrefix + "BuyProfit", "BUY P/L: $0.00", x + 10, y + 10 + (row * rowHeight), clrWhite);
   CreateLabel(panelPrefix + "SellProfit", "SELL P/L: $0.00", x + 150, y + 10 + (row++ * rowHeight), clrWhite);
   CreateLabel(panelPrefix + "TotalProfit", "Total P/L: $0.00", x + 10, y + 10 + (row++ * rowHeight), clrAqua);
   row++; // Skip row
   
   // Session stats on same line
   CreateLabel(panelPrefix + "SessionProfit", "Session: $0.00", x + 10, y + 10 + (row * rowHeight), clrGold);
   CreateLabel(panelPrefix + "SessionTarget", "Target: $0.00", x + 150, y + 10 + (row++ * rowHeight), clrWhite);
   
   // Spread and Drawdown on same line
   CreateLabel(panelPrefix + "Spread", "Spread: 0", x + 10, y + 10 + (row * rowHeight), clrWhite);
   CreateLabel(panelPrefix + "Drawdown", "DD: 0.0%", x + 150, y + 10 + (row++ * rowHeight), clrWhite);
   row++; // Skip row
   
   // Gap and Next levels
   CreateLabel(panelPrefix + "Gap", "Gap: 0.00% ($0.00)", x + 10, y + 10 + (row++ * rowHeight), clrCyan);
   CreateLabel(panelPrefix + "NextBuy", "Next BUY: 0.00000", x + 10, y + 10 + (row++ * rowHeight), clrLime);
   CreateLabel(panelPrefix + "NextSell", "Next SELL: 0.00000", x + 10, y + 10 + (row++ * rowHeight), clrRed);
   
   // Buttons - 2x2 grid
   row++;
   CreateButton(panelPrefix + "CloseBuyBtn", "CLOSE BUYS", x + 10, y + 10 + (row * rowHeight), 130, 25);
   CreateButton(panelPrefix + "CloseSellBtn", "CLOSE SELLS", x + 145, y + 10 + (row++ * rowHeight), 130, 25);
   CreateButton(panelPrefix + "RebuildBtn", "REBUILD", x + 10, y + 10 + (row * rowHeight), 130, 25);
   CreateButton(panelPrefix + "PauseBtn", "⏸ PAUSE", x + 145, y + 10 + (row++ * rowHeight), 130, 25);
   CreateButton(panelPrefix + "CloseAllBtn", "CLOSE ALL", x + 10, y + 10 + (row++ * rowHeight), 265, 25);
   
   // Branding - bold, chalk white
   row++;
   CreateLabel(panelPrefix + "Brand", "TORAMA CAPITAL", x + width - 150, y + 10 + (row * rowHeight), clrWhite);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_FONTSIZE, 12);
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_FONT, "Arial Black");
}

//+------------------------------------------------------------------+
//| CREATE LABEL                                                      |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
}

//+------------------------------------------------------------------+
//| CREATE BUTTON                                                     |
//+------------------------------------------------------------------+
void CreateButton(string name, string text, int x, int y, int width, int height)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clrDarkBlue);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrWhite);
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!ShowPanel) return;
   
   int buyCount = ArraySize(buyPositions);
   int sellCount = ArraySize(sellPositions);
   
   // Calculate P/L
   double buyPL = 0, sellPL = 0;
   
   for(int i = 0; i < buyCount; i++)
   {
      if(PositionSelectByTicket(buyPositions[i].ticket))
         buyPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   
   for(int i = 0; i < sellCount; i++)
   {
      if(PositionSelectByTicket(sellPositions[i].ticket))
         sellPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   
   double totalPL = buyPL + sellPL;
   
   // Update labels
   ObjectSetString(0, panelPrefix + "BuyPos", OBJPROP_TEXT, "BUY: " + IntegerToString(buyCount));
   ObjectSetString(0, panelPrefix + "SellPos", OBJPROP_TEXT, "SELL: " + IntegerToString(sellCount));
   
   ObjectSetString(0, panelPrefix + "BuyProfit", OBJPROP_TEXT, "BUY P/L: $" + DoubleToString(buyPL, 2));
   ObjectSetInteger(0, panelPrefix + "BuyProfit", OBJPROP_COLOR, (buyPL >= 0) ? clrLime : clrRed);
   
   ObjectSetString(0, panelPrefix + "SellProfit", OBJPROP_TEXT, "SELL P/L: $" + DoubleToString(sellPL, 2));
   ObjectSetInteger(0, panelPrefix + "SellProfit", OBJPROP_COLOR, (sellPL >= 0) ? clrLime : clrRed);
   
   ObjectSetString(0, panelPrefix + "TotalProfit", OBJPROP_TEXT, "Total P/L: $" + DoubleToString(totalPL, 2));
   ObjectSetInteger(0, panelPrefix + "TotalProfit", OBJPROP_COLOR, (totalPL >= 0) ? clrAqua : clrRed);
   
   ObjectSetString(0, panelPrefix + "SessionProfit", OBJPROP_TEXT, "Session: $" + DoubleToString(sessionProfit, 2));
   ObjectSetInteger(0, panelPrefix + "SessionProfit", OBJPROP_COLOR, (sessionProfit >= 0) ? clrGold : clrRed);
   
   ObjectSetString(0, panelPrefix + "SessionTarget", OBJPROP_TEXT, "Target: $" + DoubleToString(sessionProfitTarget, 2));
   
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   ObjectSetString(0, panelPrefix + "Spread", OBJPROP_TEXT, "Spread: " + IntegerToString(spread));
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_COLOR, (spread > MaxSpread) ? clrRed : clrLime);
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double drawdown = ((balance - equity) / balance) * 100.0;
   ObjectSetString(0, panelPrefix + "Drawdown", OBJPROP_TEXT, "DD: " + DoubleToString(drawdown, 1) + "%");
   ObjectSetInteger(0, panelPrefix + "Drawdown", OBJPROP_COLOR, (drawdown > MaxDrawdownPercent * 0.8) ? clrRed : clrLime);
   
   // Calculate and display Gap
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double gapSize = currentPrice * (GridSpacingPercent / 100.0);
   ObjectSetString(0, panelPrefix + "Gap", OBJPROP_TEXT, "Gap: " + DoubleToString(GridSpacingPercent, 2) + "% ($" + DoubleToString(gapSize, 2) + ")");
   
   // Calculate next levels
   double nextBuyLevel = 0;
   double nextSellLevel = 0;
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   int buyCount2 = ArraySize(buyPositions);
   int sellCount2 = ArraySize(sellPositions);
   
   if(buyCount2 > 0)
   {
      // Find lowest buy level
      double lowestBuy = buyPositions[0].openPrice;
      for(int i = 1; i < buyCount2; i++)
      {
         if(buyPositions[i].openPrice < lowestBuy)
            lowestBuy = buyPositions[i].openPrice;
      }
      nextBuyLevel = lowestBuy - gapSize;
   }
   else
   {
      // First buy will be one gap below current price
      nextBuyLevel = bid - gapSize;
   }
   
   if(sellCount2 > 0)
   {
      // Find highest sell level
      double highestSell = sellPositions[0].openPrice;
      for(int i = 1; i < sellCount2; i++)
      {
         if(sellPositions[i].openPrice > highestSell)
            highestSell = sellPositions[i].openPrice;
      }
      nextSellLevel = highestSell + gapSize;
   }
   else
   {
      // First sell will be one gap above current price
      nextSellLevel = ask + gapSize;
   }
   
   ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, "Next BUY: " + DoubleToString(nextBuyLevel, digits));
   ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, "Next SELL: " + DoubleToString(nextSellLevel, digits));
   
   // Update pause button
   if(isPaused)
   {
      ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, "▶ RESUME");
      ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, clrDarkGreen);
      ObjectSetString(0, panelPrefix + "Title", OBJPROP_TEXT, "MEAN REVERSION GRID v1.0 [PAUSED]");
      ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_COLOR, clrOrange);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, "⏸ PAUSE");
      ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, clrDarkBlue);
      ObjectSetString(0, panelPrefix + "Title", OBJPROP_TEXT, "MEAN REVERSION GRID v1.0");
      ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_COLOR, clrYellow);
   }
}

//+------------------------------------------------------------------+
//| DELETE PANEL                                                      |
//+------------------------------------------------------------------+
void DeletePanel()
{
   ObjectsDeleteAll(0, panelPrefix);
}

//+------------------------------------------------------------------+
//| REBUILD GRID                                                      |
//+------------------------------------------------------------------+
void RebuildGrid()
{
   Print("🔄 REBUILDING GRID...");
   
   // Clear all position tracking
   ArrayResize(buyPositions, 0);
   ArrayResize(sellPositions, 0);
   
   // Reset grid levels
   lastBuyLevel = 0;
   lastSellLevel = 0;
   highestSellLevel = 0;
   lowestBuyLevel = 0;
   
   // Recalculate gap based on current price
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   currentGapSize = currentPrice * (GridSpacingPercent / 100.0);
   
   // Recalculate profit/loss targets
   individualTPDollars = currentGapSize * (IndividualTPPercent / 100.0);
   individualSLDollars = (IndividualSLPercent > 0) ? currentGapSize * (IndividualSLPercent / 100.0) : 0;
   globalTPDollars = currentGapSize * (GlobalTPPercent / 100.0);
   globalSLDollars = (GlobalSLPercent > 0) ? currentGapSize * (GlobalSLPercent / 100.0) : 0;
   
   Print("✅ Grid rebuilt successfully!");
   Print("   Current Price: ", DoubleToString(currentPrice, digits));
   Print("   New Gap Size: $", DoubleToString(currentGapSize, 2));
   Print("   Individual TP: $", DoubleToString(individualTPDollars, 2));
   Print("   Global TP: $", DoubleToString(globalTPDollars, 2));
   Print("   Waiting for price movement to place first orders...");
}

//+------------------------------------------------------------------+
//| CHART EVENT HANDLER                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == panelPrefix + "CloseBuyBtn")
      {
         ClosePositionsSide("BUY");
         ObjectSetInteger(0, panelPrefix + "CloseBuyBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      else if(sparam == panelPrefix + "CloseSellBtn")
      {
         ClosePositionsSide("SELL");
         ObjectSetInteger(0, panelPrefix + "CloseSellBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      else if(sparam == panelPrefix + "CloseAllBtn")
      {
         CloseAllPositions();
         ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      else if(sparam == panelPrefix + "RebuildBtn")
      {
         RebuildGrid();
         ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      else if(sparam == panelPrefix + "PauseBtn")
      {
         isPaused = !isPaused;
         ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_STATE, false);
         
         if(isPaused)
            Print("⏸ EA PAUSED - No new positions will be opened");
         else
            Print("▶ EA RESUMED - Trading active");
            
         UpdatePanel();
      }
   }
}
//+------------------------------------------------------------------+
//| ERROR DESCRIPTION HELPER                                          |
//+------------------------------------------------------------------+
string ErrorDescription(int error)
{
   switch(error)
   {
      case 0: return "No error";
      case 1: return "No error, trade server returned no error code";
      case 2: return "Common error";
      case 3: return "Invalid trade parameters";
      case 4: return "Trade server is busy";
      case 5: return "Old version of the client terminal";
      case 6: return "No connection with trade server";
      case 7: return "Not enough rights";
      case 8: return "Too frequent requests";
      case 9: return "Malfunctional trade operation";
      case 64: return "Account disabled";
      case 65: return "Invalid account";
      case 128: return "Trade timeout";
      case 129: return "Invalid price";
      case 130: return "Invalid stops";
      case 131: return "Invalid trade volume";
      case 132: return "Market is closed";
      case 133: return "Trade is disabled";
      case 134: return "Not enough money";
      case 135: return "Price changed";
      case 136: return "Off quotes";
      case 137: return "Broker is busy";
      case 138: return "Requote";
      case 139: return "Order is locked";
      case 140: return "Long positions only allowed";
      case 141: return "Too many requests";
      case 145: return "Modification denied because order too close to market";
      case 146: return "Trade context is busy";
      case 147: return "Expirations are denied by broker";
      case 148: return "Amount of open and pending orders has reached the limit";
      case 149: return "Hedging is prohibited";
      case 150: return "Prohibited by FIFO rules";
      default: return "Unknown error " + IntegerToString(error);
   }
}

//+------------------------------------------------------------------+
//| TRADE RETCODE DESCRIPTION HELPER                                  |
//+------------------------------------------------------------------+
string TradeRetcodeDescription(uint retcode)
{
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE: return "Requote";
      case TRADE_RETCODE_REJECT: return "Request rejected";
      case TRADE_RETCODE_CANCEL: return "Request canceled by trader";
      case TRADE_RETCODE_PLACED: return "Order placed";
      case TRADE_RETCODE_DONE: return "Request completed";
      case TRADE_RETCODE_DONE_PARTIAL: return "Request partially completed";
      case TRADE_RETCODE_ERROR: return "Request processing error";
      case TRADE_RETCODE_TIMEOUT: return "Request timeout";
      case TRADE_RETCODE_INVALID: return "Invalid request";
      case TRADE_RETCODE_INVALID_VOLUME: return "Invalid volume";
      case TRADE_RETCODE_INVALID_PRICE: return "Invalid price";
      case TRADE_RETCODE_INVALID_STOPS: return "Invalid stops";
      case TRADE_RETCODE_TRADE_DISABLED: return "Trade is disabled";
      case TRADE_RETCODE_MARKET_CLOSED: return "Market is closed";
      case TRADE_RETCODE_NO_MONEY: return "Not enough money";
      case TRADE_RETCODE_PRICE_CHANGED: return "Price changed";
      case TRADE_RETCODE_PRICE_OFF: return "No prices";
      case TRADE_RETCODE_INVALID_EXPIRATION: return "Invalid order expiration";
      case TRADE_RETCODE_ORDER_CHANGED: return "Order state changed";
      case TRADE_RETCODE_TOO_MANY_REQUESTS: return "Too many requests";
      case TRADE_RETCODE_NO_CHANGES: return "No changes in request";
      case TRADE_RETCODE_SERVER_DISABLES_AT: return "Autotrading disabled by server";
      case TRADE_RETCODE_CLIENT_DISABLES_AT: return "Autotrading disabled by client";
      case TRADE_RETCODE_LOCKED: return "Request locked for processing";
      case TRADE_RETCODE_FROZEN: return "Order or position frozen";
      case TRADE_RETCODE_INVALID_FILL: return "Invalid order filling type";
      case TRADE_RETCODE_CONNECTION: return "No connection";
      case TRADE_RETCODE_ONLY_REAL: return "Only real accounts allowed";
      case TRADE_RETCODE_LIMIT_ORDERS: return "Limit orders limit reached";
      case TRADE_RETCODE_LIMIT_VOLUME: return "Volume limit reached";
      default: return "Unknown retcode " + IntegerToString(retcode);
   }
}
//+------------------------------------------------------------------+
