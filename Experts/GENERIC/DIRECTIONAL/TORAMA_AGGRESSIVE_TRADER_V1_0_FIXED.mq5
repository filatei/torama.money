//+------------------------------------------------------------------+
//|                    TORAMA AGGRESSIVE TRADER v1.0                  |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "1.01"
#property description "Aggressive Single-Direction Grid Trader"
#property description "User sets direction: BUY ONLY or SELL ONLY"
#property description "Trades aggressively up and down within chosen direction"
#property description "No reversal logic - Pure directional trading"
#property description "FIXED: Button functionality and time filter"

#define EA_VERSION "1.01"
#define EA_NAME "TORAMA AGGRESSIVE"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "=== TRADING DIRECTION ==="
enum TradingDirection
{
   AUTO_DETECT,    // Auto-detect from first move
   BUY_ONLY,       // BUY ONLY (bullish bias)
   SELL_ONLY       // SELL ONLY (bearish bias)
};
input TradingDirection Direction = AUTO_DETECT;  // Trading Direction

input group "=== GRID SETTINGS ==="
input double   GridSpacingPercent = 0.25;        // Grid spacing % (0.15-0.50 recommended)
input int      MaxPositions = 30;                // Maximum grid positions
input double   LotSize = 0.15;                   // Base lot size per position

input group "=== LOT MULTIPLIER (Optional) ==="
input bool     UseLotMultiplier = true;          // Enable lot multiplier
input double   LotMultiplier = 1.3;              // Multiply lot by this factor
input int      MaxMultiplierLevel = 4;           // Max multiplier level

input group "=== PROFIT & RISK (% of Gap) ==="
input double   IndividualTPPercent = 300.0;      // Individual TP as % of gap (300 = 3x gap)
input double   IndividualSLPercent = 0.0;        // Individual SL as % of gap (0 = disabled)
input int      AutoCloseProfitableCount = 0;    // Auto-close when X positions profitable (0 = OFF)
input double   SessionProfitPercent = 100.0;     // Session profit target (% of starting balance)
input bool     ResetSessionDaily = true;         // Reset session profit daily
input double   MaxDrawdownPercent = 30.0;        // Max drawdown % (emergency stop)

input group "=== TIME SCHEDULING ==="
input bool     UseTimeSchedule = false;          // Enable time scheduling
input string   StartTime = "09:00";              // Trading start time (HH:MM)
input string   EndTime = "17:00";                // Trading end time (HH:MM)
input bool     StartPaused = true;               // Start EA in paused state

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                 // Maximum spread (points)
input int      MagicNumber = 88833;              // Magic number
input bool     ShowPanel = true;                 // Show info panel

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

// Trading state
TradingDirection activeDirection = AUTO_DETECT;  // Current active direction
double referencePrice = 0;                       // Grid reference price
double highestLevel = 0;                         // Highest grid level
double lowestLevel = 0;                          // Lowest grid level
double currentGapSize = 0;                       // Current grid spacing in dollars

// Lot multiplier tracking
int currentMultiplierLevel = 0;
double currentLotSize = 0;

// Risk management
double sessionStartBalance = 0;
double sessionProfit = 0;
double sessionProfitTarget = 0;
double peakEquity = 0;
double totalProfit = 0;
int totalTrades = 0;
bool sessionTargetReached = false;
bool emergencyStop = false;
string emergencyReason = "";
bool isPaused = false;
datetime lastResetDate = 0;

// Time scheduling
datetime startTimeSeconds = 0;
datetime endTimeSeconds = 0;
bool withinTradingHours = false;

// Validation
double validatedLotSize = 0;
int digits = 2;

// Panel
string panelPrefix = "TORAMA_AGG_";
bool panelVisible = true;

// Button states
bool buttonCloseAllPressed = false;
bool buttonCloseProfitPressed = false;
bool buttonPausePressed = false;
bool buttonDirectionPressed = false;

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("═══════════════════════════════════════");
   Print("TORAMA AGGRESSIVE TRADER v", EA_VERSION);
   Print("═══════════════════════════════════════");
   
   // Get symbol info
   digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   // Validate lot size
   double volumeMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volumeMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   validatedLotSize = LotSize;
   if(validatedLotSize < volumeMin) validatedLotSize = volumeMin;
   if(validatedLotSize > volumeMax) validatedLotSize = volumeMax;
   
   // Normalize to step
   validatedLotSize = MathFloor(validatedLotSize / volumeStep) * volumeStep;
   
   // Round to proper decimal places
   int lotDigits = 2;
   if(volumeStep >= 1.0) lotDigits = 0;
   else if(volumeStep >= 0.1) lotDigits = 1;
   validatedLotSize = NormalizeDouble(validatedLotSize, lotDigits);
   
   if(validatedLotSize != LotSize)
   {
      Print("⚠️ Lot size adjusted: ", LotSize, " → ", validatedLotSize, " (broker limits)");
   }
   
   Print("Symbol: ", _Symbol);
   Print("Digits: ", digits);
   Print("Tick Size: ", tickSize);
   Print("Tick Value: $", tickValue);
   Print("Min Lot: ", volumeMin, " | Max Lot: ", volumeMax, " | Step: ", volumeStep);
   Print("Validated Lot: ", validatedLotSize);
   
   // Calculate initial gap
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   currentGapSize = currentPrice * GridSpacingPercent / 100.0;
   referencePrice = currentPrice;
   
   // Session tracking
   sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   lastResetDate = TimeCurrent();
   
   // Initialize paused state
   if(StartPaused)
   {
      isPaused = true;
      Print("⏸️ EA STARTED IN PAUSED STATE");
      Print("   Click ACTIVATE button or wait for scheduled start time");
   }
   
   // Parse time schedule
   if(UseTimeSchedule)
   {
      startTimeSeconds = StringToTime("1970.01.01 " + StartTime);
      endTimeSeconds = StringToTime("1970.01.01 " + EndTime);
      
      if(startTimeSeconds == 0 || endTimeSeconds == 0)
      {
         Print("⚠️ Invalid time format! Use HH:MM format (e.g., 09:00)");
         Print("   Time scheduling disabled");
      }
      else
      {
         Print("📅 TIME SCHEDULE ENABLED");
         Print("   Trading Hours: ", StartTime, " to ", EndTime);
         Print("   EA will activate/pause automatically");
         
         // Check if we're currently within trading hours
         datetime currentTime = TimeCurrent();
         MqlDateTime dt;
         TimeToStruct(currentTime, dt);
         datetime todaySeconds = dt.hour * 3600 + dt.min * 60 + dt.sec;
         
         if(startTimeSeconds <= endTimeSeconds)
         {
            withinTradingHours = (todaySeconds >= startTimeSeconds && todaySeconds <= endTimeSeconds);
         }
         else  // Overnight session (e.g., 22:00 to 02:00)
         {
            withinTradingHours = (todaySeconds >= startTimeSeconds || todaySeconds <= endTimeSeconds);
         }
         
         if(withinTradingHours && StartPaused)
         {
            isPaused = false;  // Auto-activate if within trading hours
            Print("✅ Within trading hours - EA ACTIVATED");
         }
      }
   }
   
   Print("═══════════════════════════════════════");
   Print("🎯 AGGRESSIVE SINGLE-DIRECTION TRADER");
   
   if(Direction == AUTO_DETECT)
   {
      Print("Direction: AUTO-DETECT (waits for first grid breach)");
      Print("   If price goes UP by 1 grid → BUY ONLY mode");
      Print("   If price goes DOWN by 1 grid → SELL ONLY mode");
   }
   else if(Direction == BUY_ONLY)
   {
      activeDirection = BUY_ONLY;
      Print("Direction: BUY ONLY (bullish)");
      Print("   Opens BUYs as price moves UP or DOWN");
   }
   else
   {
      activeDirection = SELL_ONLY;
      Print("Direction: SELL ONLY (bearish)");
      Print("   Opens SELLs as price moves UP or DOWN");
   }
   
   Print("═══════════════════════════════════════");
   Print("Grid Spacing: ", DoubleToString(GridSpacingPercent, 2), "% ($", DoubleToString(currentGapSize, digits), ")");
   Print("Max Positions: ", MaxPositions);
   Print("Base Lot: ", validatedLotSize);
   
   if(UseLotMultiplier)
   {
      Print("Lot Multiplier: ", DoubleToString(LotMultiplier, 1), "× (max level ", MaxMultiplierLevel, ")");
   }
   
   Print("Individual TP: ", DoubleToString(IndividualTPPercent, 0), "% of gap");
   if(IndividualSLPercent > 0)
      Print("Individual SL: ", DoubleToString(IndividualSLPercent, 0), "% of gap");
   
   if(AutoCloseProfitableCount > 0)
      Print("Auto-close: When ", AutoCloseProfitableCount, " positions profitable");
   
   Print("Session Target: $", DoubleToString(sessionProfitTarget, 2));
   Print("Max Drawdown: ", DoubleToString(MaxDrawdownPercent, 1), "%");
   Print("═══════════════════════════════════════");
   
   // Create panel
   if(ShowPanel)
   {
      CreatePanel();
      UpdatePanel();  // Initial update to sync all states
   }
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeletePanel();
   
   Print("═══════════════════════════════════════");
   Print("TORAMA AGGRESSIVE TRADER stopped");
   Print("Total Trades: ", totalTrades);
   Print("Final P/L: $", DoubleToString(totalProfit, 2));
   Print("═══════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| EXPERT TICK FUNCTION                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Update time schedule if enabled
   if(UseTimeSchedule)
   {
      UpdateTimeSchedule();
   }
   
   // Sync positions
   SyncPositions();
   
   // Calculate profit
   CalculateTotalProfit();
   
   // Check session reset
   if(ResetSessionDaily)
   {
      CheckSessionReset();
   }
   
   // Check emergency stop
   CheckDrawdown();
   
   // Check session target
   CheckSessionTarget();
   
   // Update panel
   if(ShowPanel && panelVisible)
   {
      UpdatePanel();
   }
   
   // If paused, emergency stopped, or target reached, don't trade
   if(isPaused || emergencyStop || sessionTargetReached)
   {
      return;
   }
   
   // Check spread
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = ask - bid;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int spreadPoints = (int)(spread / point);
   
   if(spreadPoints > MaxSpread)
   {
      return;
   }
   
   // Calculate current mid price
   double currentPrice = (ask + bid) / 2.0;
   
   // Update gap based on current price
   currentGapSize = currentPrice * GridSpacingPercent / 100.0;
   
   // Direction logic
   if(activeDirection == AUTO_DETECT)
   {
      // Check for initial direction breach
      double priceChange = currentPrice - referencePrice;
      
      if(priceChange >= currentGapSize)
      {
         // Price went UP → Enter BUY ONLY mode
         activeDirection = BUY_ONLY;
         referencePrice = currentPrice;
         highestLevel = currentPrice;
         lowestLevel = currentPrice;
         
         Print("🔵 DIRECTION LOCKED: BUY ONLY (price moved up)");
         Print("   Reference: $", DoubleToString(referencePrice, digits));
         
         // Open first buy
         OpenPosition(ORDER_TYPE_BUY, currentPrice);
      }
      else if(priceChange <= -currentGapSize)
      {
         // Price went DOWN → Enter SELL ONLY mode
         activeDirection = SELL_ONLY;
         referencePrice = currentPrice;
         highestLevel = currentPrice;
         lowestLevel = currentPrice;
         
         Print("🔴 DIRECTION LOCKED: SELL ONLY (price moved down)");
         Print("   Reference: $", DoubleToString(referencePrice, digits));
         
         // Open first sell
         OpenPosition(ORDER_TYPE_SELL, currentPrice);
      }
      
      return;
   }
   
   // For established direction, manage grid
   if(activeDirection == BUY_ONLY)
   {
      ManageBuyGrid(currentPrice);
   }
   else if(activeDirection == SELL_ONLY)
   {
      ManageSellGrid(currentPrice);
   }
   
   // Auto-close profitable if enabled
   if(AutoCloseProfitableCount > 0)
   {
      CheckAutoCloseProfitable();
   }
}

//+------------------------------------------------------------------+
//| MANAGE BUY GRID                                                   |
//+------------------------------------------------------------------+
void ManageBuyGrid(double currentPrice)
{
   int posCount = ArraySize(positions);
   
   // Position limits
   if(posCount >= MaxPositions)
   {
      return;
   }
   
   // Initialize levels if needed
   if(posCount == 0)
   {
      highestLevel = currentPrice;
      lowestLevel = currentPrice;
   }
   
   // Price moved UP → Open BUY at new high
   if(currentPrice >= highestLevel + currentGapSize)
   {
      double newLevel = highestLevel + currentGapSize;
      
      if(OpenPosition(ORDER_TYPE_BUY, newLevel))
      {
         highestLevel = newLevel;
         Print("📈 New HIGH level: $", DoubleToString(highestLevel, digits));
      }
   }
   
   // Price moved DOWN → Open BUY at new low
   if(currentPrice <= lowestLevel - currentGapSize)
   {
      double newLevel = lowestLevel - currentGapSize;
      
      if(OpenPosition(ORDER_TYPE_BUY, newLevel))
      {
         lowestLevel = newLevel;
         Print("📉 New LOW level: $", DoubleToString(lowestLevel, digits));
      }
   }
}

//+------------------------------------------------------------------+
//| MANAGE SELL GRID                                                  |
//+------------------------------------------------------------------+
void ManageSellGrid(double currentPrice)
{
   int posCount = ArraySize(positions);
   
   // Position limits
   if(posCount >= MaxPositions)
   {
      return;
   }
   
   // Initialize levels if needed
   if(posCount == 0)
   {
      highestLevel = currentPrice;
      lowestLevel = currentPrice;
   }
   
   // Price moved UP → Open SELL at new high
   if(currentPrice >= highestLevel + currentGapSize)
   {
      double newLevel = highestLevel + currentGapSize;
      
      if(OpenPosition(ORDER_TYPE_SELL, newLevel))
      {
         highestLevel = newLevel;
         Print("📈 New HIGH level: $", DoubleToString(highestLevel, digits));
      }
   }
   
   // Price moved DOWN → Open SELL at new low
   if(currentPrice <= lowestLevel - currentGapSize)
   {
      double newLevel = lowestLevel - currentGapSize;
      
      if(OpenPosition(ORDER_TYPE_SELL, newLevel))
      {
         lowestLevel = newLevel;
         Print("📉 New LOW level: $", DoubleToString(lowestLevel, digits));
      }
   }
}

//+------------------------------------------------------------------+
//| OPEN POSITION                                                     |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE type, double priceLevel)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   // Lot size calculation with multiplier
   double lotToUse = validatedLotSize;
   if(UseLotMultiplier && currentMultiplierLevel > 0 && currentMultiplierLevel <= MaxMultiplierLevel)
   {
      lotToUse = validatedLotSize * MathPow(LotMultiplier, currentMultiplierLevel);
      
      // Validate against broker limits
      double volumeMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      if(lotToUse > volumeMax) lotToUse = volumeMax;
      
      // Normalize
      double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      lotToUse = MathFloor(lotToUse / volumeStep) * volumeStep;
      
      int lotDigits = 2;
      if(volumeStep >= 1.0) lotDigits = 0;
      else if(volumeStep >= 0.1) lotDigits = 1;
      lotToUse = NormalizeDouble(lotToUse, lotDigits);
   }
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotToUse;
   request.type = type;
   request.deviation = 10;
   request.magic = MagicNumber;
   
   if(type == ORDER_TYPE_BUY)
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   else
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Calculate TP and SL based on current gap
   double individualTPDollars = currentGapSize * IndividualTPPercent / 100.0;
   double individualSLDollars = currentGapSize * IndividualSLPercent / 100.0;
   
   if(IndividualTPPercent > 0)
   {
      if(type == ORDER_TYPE_BUY)
         request.tp = NormalizeDouble(request.price + individualTPDollars, digits);
      else
         request.tp = NormalizeDouble(request.price - individualTPDollars, digits);
   }
   
   if(IndividualSLPercent > 0)
   {
      if(type == ORDER_TYPE_BUY)
         request.sl = NormalizeDouble(request.price - individualSLDollars, digits);
      else
         request.sl = NormalizeDouble(request.price + individualSLDollars, digits);
   }
   
   if(!OrderSend(request, result))
   {
      Print("❌ Order failed: ", result.retcode, " - ", GetErrorDescription(result.retcode));
      Print("   Type: ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"));
      Print("   Volume: ", lotToUse);
      Print("   Price: ", request.price);
      return false;
   }
   
   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      totalTrades++;
      
      string multiplierInfo = "";
      if(UseLotMultiplier && currentMultiplierLevel > 0)
      {
         multiplierInfo = StringFormat(" [×%.1f^%d]", LotMultiplier, currentMultiplierLevel);
      }
      
      Print("✅ ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), " #", result.order, 
            " | Lots: ", DoubleToString(lotToUse, 2), multiplierInfo,
            " | Price: $", DoubleToString(request.price, digits), 
            " | TP: $", DoubleToString(request.tp, digits));
      
      IncrementMultiplierLevel();
      
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| GET ERROR DESCRIPTION                                             |
//+------------------------------------------------------------------+
string GetErrorDescription(int code)
{
   switch(code)
   {
      case 4756: return "Invalid order volume";
      case 10004: return "Requote";
      case 10006: return "Request rejected";
      case 10014: return "Invalid volume";
      case 10015: return "Invalid price";
      case 10016: return "Invalid stops";
      case 10018: return "Market closed";
      case 10019: return "Not enough money";
      default: return "Error " + IntegerToString(code);
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
            int size = ArraySize(positions);
            ArrayResize(positions, size + 1);
            positions[size].ticket = ticket;
            positions[size].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            positions[size].entryTime = (datetime)PositionGetInteger(POSITION_TIME);
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
//| CHECK AUTO-CLOSE PROFITABLE                                       |
//+------------------------------------------------------------------+
void CheckAutoCloseProfitable()
{
   if(AutoCloseProfitableCount <= 0) return;
   
   int profitableCount = 0;
   double totalProfitAmount = 0;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0)
         {
            profitableCount++;
            totalProfitAmount += profit;
         }
      }
   }
   
   if(profitableCount >= AutoCloseProfitableCount)
   {
      Print("🔒 Auto-close: ", profitableCount, " positions with combined profit $", DoubleToString(totalProfitAmount, 2));
      
      for(int i = ArraySize(positions) - 1; i >= 0; i--)
      {
         if(PositionSelectByTicket(positions[i].ticket))
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            if(profit > 0)
            {
               ClosePosition(positions[i].ticket);
            }
         }
      }
      
      // Force sync after closing
      SyncPositions();
   }
}

//+------------------------------------------------------------------+
//| CLOSE POSITION                                                    |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   if(!PositionSelectByTicket(ticket))
      return;
   
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = PositionGetString(POSITION_SYMBOL);
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.deviation = 10;
   request.magic = MagicNumber;
   
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   request.type = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = (posType == POSITION_TYPE_BUY) ? 
                   SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                   SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   if(!OrderSend(request, result))
   {
      Print("❌ Failed to close position #", ticket, ": ", result.retcode);
   }
   else if(result.retcode == TRADE_RETCODE_DONE)
   {
      Print("✅ Closed position #", ticket);
   }
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   Print("🔒 Closing all positions...");
   
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      ClosePosition(positions[i].ticket);
   }
   
   // Force sync after closing all
   SyncPositions();
}

//+------------------------------------------------------------------+
//| CREATE PANEL                                                      |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 20;
   int y = 50;
   int width = 340;
   int height = 340;
   
   // Background
   CreateRectangle(panelPrefix + "Background", x, y, width, height, clrBlack, clrDarkSlateGray, 2);
   
   // Title bar
   CreateLabel(panelPrefix + "Title", x + 10, y + 10, "TORAMA AGGRESSIVE TRADER v" + EA_VERSION, clrGold, 11, "Arial Bold");
   
   // Status
   CreateLabel(panelPrefix + "Status", x + 10, y + 32, "ACTIVE", clrLime, 10, "Arial Bold");
   
   // Time and schedule
   CreateLabel(panelPrefix + "TimeLabel", x + 10, y + 55, "Server Time:", clrGray, 8, "Arial");
   CreateLabel(panelPrefix + "ServerTime", x + 85, y + 55, "00:00:00", clrWhite, 9, "Arial");
   
   if(UseTimeSchedule)
   {
      CreateLabel(panelPrefix + "TradingHours", x + 160, y + 55, "Trading: 00:00-00:00", clrYellow, 8, "Arial");
   }
   
   // Direction
   CreateLabel(panelPrefix + "DirLabel", x + 10, y + 75, "Direction:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Direction", x + 85, y + 75, "AUTO", clrCyan, 10, "Arial Bold");
   
   // Reference & Gap
   CreateLabel(panelPrefix + "RefLabel", x + 10, y + 90, "Ref:", clrGray, 8, "Arial");
   CreateLabel(panelPrefix + "RefPrice", x + 45, y + 90, "$0.00", clrWhite, 9, "Arial");
   
   CreateLabel(panelPrefix + "GapLabel", x + 160, y + 90, "Gap:", clrGray, 8, "Arial");
   CreateLabel(panelPrefix + "Gap", x + 195, y + 90, "$0.00", clrWhite, 9, "Arial");
   
   // Positions
   CreateLabel(panelPrefix + "PosLabel", x + 10, y + 110, "Positions:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Positions", x + 85, y + 110, "0", clrWhite, 10, "Arial Bold");
   
   // Range
   CreateLabel(panelPrefix + "HighLabel", x + 10, y + 130, "High:", clrGray, 8, "Arial");
   CreateLabel(panelPrefix + "High", x + 50, y + 130, "$0.00", clrLime, 9, "Arial");
   
   CreateLabel(panelPrefix + "LowLabel", x + 160, y + 130, "Low:", clrGray, 8, "Arial");
   CreateLabel(panelPrefix + "Low", x + 195, y + 130, "$0.00", clrOrange, 9, "Arial");
   
   // Profit
   CreateLabel(panelPrefix + "ProfitLabel", x + 10, y + 150, "Profit:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Profit", x + 60, y + 150, "$0.00", clrLime, 11, "Arial Bold");
   
   // Account
   CreateLabel(panelPrefix + "BalanceLabel", x + 10, y + 175, "Balance:", clrGray, 8, "Arial");
   CreateLabel(panelPrefix + "Balance", x + 70, y + 175, "$0.00", clrWhite, 9, "Arial");
   
   CreateLabel(panelPrefix + "EquityLabel", x + 180, y + 175, "Equity:", clrGray, 8, "Arial");
   CreateLabel(panelPrefix + "Equity", x + 230, y + 175, "$0.00", clrWhite, 9, "Arial");
   
   // Session
   CreateLabel(panelPrefix + "SessionLabel", x + 10, y + 195, "Session:", clrGray, 8, "Arial");
   CreateLabel(panelPrefix + "SessionProfit", x + 70, y + 195, "$0.00", clrYellow, 9, "Arial");
   
   CreateLabel(panelPrefix + "TargetLabel", x + 180, y + 195, "Target:", clrGray, 8, "Arial");
   CreateLabel(panelPrefix + "SessionTarget", x + 230, y + 195, "$0.00", clrGray, 9, "Arial");
   
   // Lot
   CreateLabel(panelPrefix + "LotLabel", x + 10, y + 220, "Lot:", clrGray, 8, "Arial");
   CreateLabel(panelPrefix + "LotSize", x + 40, y + 220, DoubleToString(validatedLotSize, 2), clrLightBlue, 9, "Arial Bold");
   CreateLabel(panelPrefix + "MultiplierInfo", x + 80, y + 220, "", clrYellow, 8, "Arial");
   
   // BUTTONS (4 buttons in 2 rows)
   int buttonY = y + 245;
   int buttonWidth = 155;
   int buttonHeight = 30;
   int buttonSpacing = 10;
   
   // Row 1: Close Profit & Close All
   CreateButton(panelPrefix + "BtnCloseProfit", x + 10, buttonY, buttonWidth, buttonHeight, 
                "CLOSE PROFIT", clrGreen, clrBlack, 9);
   CreateButton(panelPrefix + "BtnCloseAll", x + 10 + buttonWidth + buttonSpacing, buttonY, buttonWidth, buttonHeight,
                "CLOSE ALL", clrOrangeRed, clrBlack, 9);
   
   // Row 2: Change Direction & Activate (renamed from Pause)
   CreateButton(panelPrefix + "BtnDirection", x + 10, buttonY + buttonHeight + 5, buttonWidth, buttonHeight,
                "CHANGE DIR", clrDodgerBlue, clrBlack, 9);
   CreateButton(panelPrefix + "BtnPause", x + 10 + buttonWidth + buttonSpacing, buttonY + buttonHeight + 5, buttonWidth, buttonHeight,
                isPaused ? "ACTIVATE EA" : "PAUSE EA", clrGold, clrBlack, 9);
   
   // Brand
   CreateLabel(panelPrefix + "Brand", x + width - 140, y + height - 20, "TORAMA CAPITAL", clrGold, 8, "Arial Bold");
   
   // Toggle hint
   CreateLabel(panelPrefix + "ToggleHint", x + 10, y + height - 20, "Press 'H' to hide panel", clrGray, 7, "Arial");
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   // Server time
   string timeStr = TimeToString(TimeCurrent(), TIME_SECONDS);
   ObjectSetString(0, panelPrefix + "ServerTime", OBJPROP_TEXT, timeStr);
   
   // Trading hours display
   if(UseTimeSchedule)
   {
      string hoursText = "Trading: " + StartTime + "-" + EndTime;
      ObjectSetString(0, panelPrefix + "TradingHours", OBJPROP_TEXT, hoursText);
      ObjectSetInteger(0, panelPrefix + "TradingHours", OBJPROP_COLOR, withinTradingHours ? clrLime : clrGray);
   }
   
   // Status
   string statusText = "ACTIVE";
   color statusColor = clrLime;
   
   if(emergencyStop)
   {
      statusText = "EMERGENCY STOP";
      statusColor = clrRed;
   }
   else if(sessionTargetReached)
   {
      statusText = "TARGET REACHED";
      statusColor = clrGold;
   }
   else if(isPaused)
   {
      statusText = "PAUSED";
      statusColor = clrOrange;
   }
   
   ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, statusText);
   ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, statusColor);
   
   // Direction
   string dirText = "AUTO";
   color dirColor = clrCyan;
   
   if(activeDirection == BUY_ONLY)
   {
      dirText = "BUY ONLY";
      dirColor = clrLime;
   }
   else if(activeDirection == SELL_ONLY)
   {
      dirText = "SELL ONLY";
      dirColor = clrOrange;
   }
   
   ObjectSetString(0, panelPrefix + "Direction", OBJPROP_TEXT, dirText);
   ObjectSetInteger(0, panelPrefix + "Direction", OBJPROP_COLOR, dirColor);
   
   // Reference & Gap
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, "$" + DoubleToString(referencePrice, digits));
   ObjectSetString(0, panelPrefix + "Gap", OBJPROP_TEXT, "$" + DoubleToString(currentGapSize, digits));
   
   // Positions
   int posCount = ArraySize(positions);
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT, IntegerToString(posCount));
   
   // Range
   ObjectSetString(0, panelPrefix + "High", OBJPROP_TEXT, "$" + DoubleToString(highestLevel, digits));
   ObjectSetString(0, panelPrefix + "Low", OBJPROP_TEXT, "$" + DoubleToString(lowestLevel, digits));
   
   // Profit
   color profitColor = (totalProfit >= 0) ? clrLime : clrRed;
   ObjectSetString(0, panelPrefix + "Profit", OBJPROP_TEXT, "$" + DoubleToString(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "Profit", OBJPROP_COLOR, profitColor);
   
   // Account
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   ObjectSetString(0, panelPrefix + "Balance", OBJPROP_TEXT, "$" + DoubleToString(balance, 2));
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT, "$" + DoubleToString(equity, 2));
   
   // Session
   sessionProfit = balance - sessionStartBalance;
   color sessionColor = (sessionProfit >= 0) ? clrYellow : clrRed;
   ObjectSetString(0, panelPrefix + "SessionProfit", OBJPROP_TEXT, "$" + DoubleToString(sessionProfit, 2));
   ObjectSetInteger(0, panelPrefix + "SessionProfit", OBJPROP_COLOR, sessionColor);
   
   ObjectSetString(0, panelPrefix + "SessionTarget", OBJPROP_TEXT, "$" + DoubleToString(sessionProfitTarget, 2));
   
   // Lot multiplier info
   if(UseLotMultiplier && currentMultiplierLevel > 0)
   {
      string multiplierText = StringFormat("×%.1f^%d", LotMultiplier, currentMultiplierLevel);
      ObjectSetString(0, panelPrefix + "MultiplierInfo", OBJPROP_TEXT, multiplierText);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "MultiplierInfo", OBJPROP_TEXT, "");
   }
   
   // Update pause button text
   string pauseText = isPaused ? "ACTIVATE EA" : "PAUSE EA";
   ObjectSetString(0, panelPrefix + "BtnPause", OBJPROP_TEXT, pauseText);
}

//+------------------------------------------------------------------+
//| DELETE PANEL                                                      |
//+------------------------------------------------------------------+
void DeletePanel()
{
   ObjectsDeleteAll(0, panelPrefix);
}

//+------------------------------------------------------------------+
//| CREATE LABEL                                                      |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, string font)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| CREATE RECTANGLE                                                  |
//+------------------------------------------------------------------+
void CreateRectangle(string name, int x, int y, int width, int height, color bgColor, color borderColor, int borderWidth)
{
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, borderColor);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, borderWidth);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| CREATE BUTTON                                                     |
//+------------------------------------------------------------------+
void CreateButton(string name, int x, int y, int width, int height, string text, color bgColor, color textColor, int fontSize)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| CHECK DRAWDOWN                                                    |
//+------------------------------------------------------------------+
void CheckDrawdown()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   if(equity > peakEquity)
   {
      peakEquity = equity;
   }
   
   double drawdown = ((peakEquity - equity) / peakEquity) * 100.0;
   
   if(drawdown >= MaxDrawdownPercent && !emergencyStop)
   {
      emergencyStop = true;
      emergencyReason = StringFormat("Max drawdown reached: %.1f%%", drawdown);
      
      Print("🚨 EMERGENCY STOP: ", emergencyReason);
      Print("   Peak: $", DoubleToString(peakEquity, 2));
      Print("   Current: $", DoubleToString(equity, 2));
      Print("   All new positions stopped");
      Print("   Existing positions remain open");
      Print("   Click ACTIVATE button to resume");
      
      isPaused = true;
   }
}

//+------------------------------------------------------------------+
//| CHECK SESSION TARGET                                              |
//+------------------------------------------------------------------+
void CheckSessionTarget()
{
   if(sessionTargetReached) return;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionProfit = balance - sessionStartBalance;
   
   if(sessionProfit >= sessionProfitTarget)
   {
      sessionTargetReached = true;
      
      Print("🎯 SESSION TARGET REACHED!");
      Print("   Target: $", DoubleToString(sessionProfitTarget, 2));
      Print("   Profit: $", DoubleToString(sessionProfit, 2));
      Print("   All new positions stopped");
      Print("   Existing positions remain open");
      Print("   Click ACTIVATE button to resume");
      
      isPaused = true;
   }
}

//+------------------------------------------------------------------+
//| CHECK SESSION RESET                                               |
//+------------------------------------------------------------------+
void CheckSessionReset()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime dtNow, dtLast;
   TimeToStruct(currentTime, dtNow);
   TimeToStruct(lastResetDate, dtLast);
   
   if(dtNow.day != dtLast.day || dtNow.mon != dtLast.mon || dtNow.year != dtLast.year)
   {
      Print("📅 NEW DAY - Resetting session tracking");
      Print("   Previous session profit: $", DoubleToString(sessionProfit, 2));
      
      sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
      sessionProfit = 0;
      peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      sessionTargetReached = false;
      lastResetDate = currentTime;
      
      Print("   New session target: $", DoubleToString(sessionProfitTarget, 2));
   }
}

//+------------------------------------------------------------------+
//| INCREMENT MULTIPLIER LEVEL                                        |
//+------------------------------------------------------------------+
void IncrementMultiplierLevel()
{
   if(!UseLotMultiplier) return;
   
   if(currentMultiplierLevel < MaxMultiplierLevel)
   {
      currentMultiplierLevel++;
   }
}

//+------------------------------------------------------------------+
//| RESET MULTIPLIER LEVEL                                            |
//+------------------------------------------------------------------+
void ResetMultiplierLevel()
{
   currentMultiplierLevel = 0;
}

//+------------------------------------------------------------------+
//| UPDATE TIME SCHEDULE                                              |
//+------------------------------------------------------------------+
void UpdateTimeSchedule()
{
   if(startTimeSeconds == 0 || endTimeSeconds == 0) return;
   
   static bool wasWithinHours = false;
   
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   datetime todaySeconds = dt.hour * 3600 + dt.min * 60 + dt.sec;
   
   // Check if within trading hours (FIXED: Using <= for proper boundary check)
   bool nowWithinHours = false;
   if(startTimeSeconds <= endTimeSeconds)
   {
      nowWithinHours = (todaySeconds >= startTimeSeconds && todaySeconds <= endTimeSeconds);
   }
   else  // Overnight session
   {
      nowWithinHours = (todaySeconds >= startTimeSeconds || todaySeconds <= endTimeSeconds);
   }
   
   // State change: entered trading hours
   if(nowWithinHours && !wasWithinHours)
   {
      isPaused = false;
      withinTradingHours = true;
      Print("⏰ ", TimeToString(currentTime, TIME_DATE|TIME_MINUTES), " - Trading hours started - EA ACTIVATED");
   }
   
   // State change: exited trading hours
   if(!nowWithinHours && wasWithinHours)
   {
      isPaused = true;
      withinTradingHours = false;
      Print("⏰ ", TimeToString(currentTime, TIME_DATE|TIME_MINUTES), " - Trading hours ended - EA PAUSED");
      
      // Optionally close all positions at end of trading hours
      // Uncomment next line if you want to close all positions when trading hours end
      // CloseAllPositions();
   }
   
   wasWithinHours = nowWithinHours;
}

//+------------------------------------------------------------------+
//| CHART EVENT HANDLER                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Handle keyboard events
   if(id == CHARTEVENT_KEYDOWN)
   {
      // H key to toggle panel
      if(lparam == 'H' || lparam == 'h')
      {
         panelVisible = !panelVisible;
         
         string objects[] = {
            "Background", "Title", "Status", 
            "TimeLabel", "ServerTime", "TradingHours",
            "DirLabel", "Direction",
            "RefLabel", "RefPrice", "GapLabel", "Gap",
            "PosLabel", "Positions", "HighLabel", "High", "LowLabel", "Low",
            "ProfitLabel", "Profit", "BalanceLabel", "Balance", "EquityLabel", "Equity",
            "SessionLabel", "SessionProfit", "TargetLabel", "SessionTarget",
            "LotLabel", "LotSize", "MultiplierInfo",
            "BtnCloseProfit", "BtnCloseProfit_Label",
            "BtnCloseAll", "BtnCloseAll_Label",
            "BtnDirection", "BtnDirection_Label",
            "BtnPause", "BtnPause_Label",
            "Brand", "ToggleHint"
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
   }
   
   // Handle mouse click events on buttons
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      // CLOSE PROFIT button
      if(sparam == panelPrefix + "BtnCloseProfit")
      {
         Print("🔘 CLOSE PROFIT button pressed");
         CloseProfitablePositions();
         ObjectSetInteger(0, panelPrefix + "BtnCloseProfit", OBJPROP_STATE, false);
         UpdatePanel();  // Update panel immediately
         ChartRedraw();
      }
      
      // CLOSE ALL button
      else if(sparam == panelPrefix + "BtnCloseAll")
      {
         Print("🔘 CLOSE ALL button pressed");
         CloseAllPositions();
         ObjectSetInteger(0, panelPrefix + "BtnCloseAll", OBJPROP_STATE, false);
         UpdatePanel();  // Update panel immediately
         ChartRedraw();
      }
      
      // CHANGE DIRECTION button
      else if(sparam == panelPrefix + "BtnDirection")
      {
         Print("🔘 CHANGE DIRECTION button pressed");
         ChangeDirection();
         ObjectSetInteger(0, panelPrefix + "BtnDirection", OBJPROP_STATE, false);
         UpdatePanel();  // Update panel immediately to show new direction
         ChartRedraw();
      }
      
      // PAUSE/RESUME button
      else if(sparam == panelPrefix + "BtnPause")
      {
         Print("🔘 PAUSE/RESUME button pressed");
         TogglePause();
         ObjectSetInteger(0, panelPrefix + "BtnPause", OBJPROP_STATE, false);
         UpdatePanel();  // Update panel immediately to show new button text
         ChartRedraw();
      }
   }
}

//+------------------------------------------------------------------+
//| CLOSE PROFITABLE POSITIONS                                        |
//+------------------------------------------------------------------+
void CloseProfitablePositions()
{
   int closedCount = 0;
   double totalProfitClosed = 0;
   
   Print("🔒 Closing profitable positions...");
   
   // Create array of profitable tickets first
   ulong profitableTickets[];
   ArrayResize(profitableTickets, 0);
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0)
         {
            int size = ArraySize(profitableTickets);
            ArrayResize(profitableTickets, size + 1);
            profitableTickets[size] = positions[i].ticket;
            totalProfitClosed += profit;
         }
      }
   }
   
   // Now close all profitable positions
   for(int i = 0; i < ArraySize(profitableTickets); i++)
   {
      ClosePosition(profitableTickets[i]);
      closedCount++;
   }
   
   // Force sync after closing
   SyncPositions();
   
   if(closedCount > 0)
   {
      Print("✅ Closed ", closedCount, " profitable positions | Total profit: $", DoubleToString(totalProfitClosed, 2));
   }
   else
   {
      Print("⚠️ No profitable positions to close");
   }
}

//+------------------------------------------------------------------+
//| CHANGE DIRECTION (WITHOUT CLOSING POSITIONS)                     |
//+------------------------------------------------------------------+
void ChangeDirection()
{
   TradingDirection oldDirection = activeDirection;
   
   // Cycle through directions: AUTO → BUY → SELL → AUTO
   if(activeDirection == AUTO_DETECT)
   {
      activeDirection = BUY_ONLY;
   }
   else if(activeDirection == BUY_ONLY)
   {
      activeDirection = SELL_ONLY;
   }
   else if(activeDirection == SELL_ONLY)
   {
      activeDirection = AUTO_DETECT;
   }
   
   string oldDirText = (oldDirection == AUTO_DETECT ? "AUTO-DETECT" : 
                        (oldDirection == BUY_ONLY ? "BUY ONLY" : "SELL ONLY"));
   string newDirText = (activeDirection == AUTO_DETECT ? "AUTO-DETECT" : 
                        (activeDirection == BUY_ONLY ? "BUY ONLY" : "SELL ONLY"));
   
   Print("🔄 DIRECTION CHANGED: ", oldDirText, " → ", newDirText);
   Print("   Existing positions remain open");
   Print("   New positions will follow new direction");
   
   // Reset reference for new direction
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   referencePrice = currentPrice;
   
   if(activeDirection == AUTO_DETECT)
   {
      Print("   Waiting for first grid breach to confirm direction");
   }
}

//+------------------------------------------------------------------+
//| TOGGLE PAUSE/RESUME                                               |
//+------------------------------------------------------------------+
void TogglePause()
{
   isPaused = !isPaused;
   
   if(isPaused)
   {
      Print("⏸️ EA PAUSED - No new positions will be opened");
      Print("   Existing positions remain active");
      Print("   Click ACTIVATE EA button to resume");
   }
   else
   {
      Print("▶️ EA ACTIVATED - Trading active");
      
      // Clear emergency stop if it was set
      if(emergencyStop)
      {
         emergencyStop = false;
         emergencyReason = "";
         Print("   Emergency stop cleared");
      }
      
      // Clear session target if it was reached
      if(sessionTargetReached)
      {
         sessionTargetReached = false;
         Print("   Session target flag cleared");
      }
   }
}
//+------------------------------------------------------------------+
