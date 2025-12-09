//+------------------------------------------------------------------+
//|                    TORAMA Mean Reversion Grid EA v1.0            |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "1.0"
#property description "Pure Mean Reversion Grid EA"
#property description "Buys as price falls, Sells as price rises"
#property description "Takes profit on reversals - Classic mean reversion"

#define EA_VERSION "1.0"
#define EA_NAME "TORAMA MEAN REVERSION"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "=== GRID SETTINGS ==="
input double   GridSpacingPercent = 0.30;        // Grid spacing % (0.2-0.5 recommended)
input int      MaxBuyPositions = 15;             // Maximum BUY positions
input int      MaxSellPositions = 15;            // Maximum SELL positions
input double   LotSize = 0.1;                    // Lot size per position

input group "=== TAKE PROFIT SETTINGS ==="
input double   IndividualTPFactor = 3.0;         // Individual TP factor (3 = 3x gap)
input double   GlobalTPFactor = 5.0;             // Global TP factor (5 = 5x gap)

input group "=== RISK MANAGEMENT ==="
input double   MaxDrawdownPercent = 20.0;        // Max drawdown % (emergency stop)
input double   SessionProfitPercent = 100.0;     // Session profit target (% of balance, 0=OFF)
input bool     ResetSessionDaily = true;         // Reset session profit daily

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                 // Maximum spread (points)
input int      MagicNumber = 77733;              // Magic number
input bool     ShowPanel = true;                 // Show info panel

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

struct Position
{
   ulong    ticket;
   double   entryPrice;
   datetime entryTime;
   int      type;  // 0=BUY, 1=SELL
};

Position buyPositions[];
Position sellPositions[];

// Reference and grid tracking
double referencePrice = 0;               // Starting reference price
double currentGapSize = 0;               // Current grid spacing in dollars
double lastBuyLevel = 0;                 // Last price level where we placed a BUY
double lastSellLevel = 0;                // Last price level where we placed a SELL

// Risk management
bool emergencyStop = false;
string emergencyReason = "";
double peakEquity = 0;
double totalProfit = 0;

// Session profit tracking
double sessionStartBalance = 0;
double sessionProfit = 0;
double sessionProfitTarget = 0;
datetime lastSessionReset = 0;
int currentDay = 0;
bool sessionTargetReached = false;

// Statistics
int totalTrades = 0;
bool isPaused = false;

// Panel
string panelPrefix = "TORAMA_MR_";
bool panelVisible = true;

// Lot size validation
double validatedLotSize = 0;
double minLot = 0;
double maxLot = 0;
double lotStep = 0;

// Debug
datetime lastDebugTime = 0;
int debugTickCounter = 0;
bool debugVerbose = true;

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
   
   // Validate lot size
   validatedLotSize = ValidateLotSize(LotSize);
   
   Print("📊 SYMBOL SPECIFICATIONS:");
   Print("Symbol: ", _Symbol);
   Print("Minimum Lot: ", minLot);
   Print("Maximum Lot: ", maxLot);
   Print("Lot Step: ", lotStep);
   Print("✅ Validated Lot: ", validatedLotSize);
   
   // Initialize reference price
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   referencePrice = (ask + bid) / 2.0;
   currentGapSize = referencePrice * GridSpacingPercent / 100.0;
   
   // Set initial levels
   lastBuyLevel = referencePrice;
   lastSellLevel = referencePrice;
   
   Print("📍 STARTING REFERENCE: $", DoubleToString(referencePrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   Print("📏 Grid Gap: $", DoubleToString(currentGapSize, 2), " (", DoubleToString(GridSpacingPercent, 2), "%)");
   
   // Initialize peak equity
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Session profit setup
   sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(SessionProfitPercent > 0)
   {
      sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
      Print("🎯 Session Target: $", DoubleToString(sessionProfitTarget, 2), " (", DoubleToString(SessionProfitPercent, 0), "%)");
   }
   
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   currentDay = time.day;
   
   Print("═══════════════════════════════════════");
   Print("📈 MEAN REVERSION STRATEGY:");
   Print("   BUY positions: Open as price FALLS below grid levels");
   Print("   SELL positions: Open as price RISES above grid levels");
   Print("   Profit Target: Reversal to mean (opposite direction)");
   Print("   Max BUY positions: ", MaxBuyPositions);
   Print("   Max SELL positions: ", MaxSellPositions);
   Print("═══════════════════════════════════════");
   Print("🔍 DEBUG: Press 'D' key for status");
   Print("👁️ PANEL: Press 'H' key to hide/show");
   Print("═══════════════════════════════════════");
   
   // Create panel
   if(ShowPanel) CreatePanel();
   
   // Sync existing positions
   SyncPositions();
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, panelPrefix);
   Print("EA stopped. Total trades: ", totalTrades);
   Print("═══════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| MAIN TICK FUNCTION                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   // Debug logging
   debugTickCounter++;
   datetime currentTime = TimeCurrent();
   bool shouldDebug = (debugTickCounter % 50 == 0) || (currentTime - lastDebugTime >= 30);
   
   if(debugVerbose && shouldDebug)
   {
      lastDebugTime = currentTime;
      Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      Print("🔍 DEBUG TICK #", debugTickCounter);
      Print("Time: ", TimeToString(currentTime, TIME_DATE|TIME_SECONDS));
      Print("BUY Positions: ", ArraySize(buyPositions), "/", MaxBuyPositions);
      Print("SELL Positions: ", ArraySize(sellPositions), "/", MaxSellPositions);
      Print("Status: ", isPaused ? "PAUSED" : (emergencyStop ? "STOPPED" : (sessionTargetReached ? "TARGET" : "ACTIVE")));
      Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
   }
   
   // Update panel
   if(ShowPanel) UpdatePanel();
   
   // Check for daily session reset
   if(ResetSessionDaily)
   {
      MqlDateTime time;
      TimeToStruct(TimeCurrent(), time);
      if(time.day != currentDay)
      {
         currentDay = time.day;
         sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         sessionProfit = 0;
         sessionTargetReached = false;
         Print("🔄 Daily session reset. New start balance: $", DoubleToString(sessionStartBalance, 2));
      }
   }
   
   // Check if paused
   if(isPaused)
   {
      if(debugVerbose && debugTickCounter % 200 == 0)
      {
         Print("⏸️ EA PAUSED - Not trading");
         if(sessionTargetReached)
            Print("   Reason: Session profit target reached ($", DoubleToString(sessionProfit, 2), ")");
      }
      return;
   }
   
   // Check emergency stop
   if(emergencyStop)
   {
      if(debugVerbose && debugTickCounter % 200 == 0)
      {
         Print("🛑 EMERGENCY STOP ACTIVE!");
         Print("   Reason: ", emergencyReason);
      }
      return;
   }
   
   // Check session target
   if(SessionProfitPercent > 0 && !sessionTargetReached)
   {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      sessionProfit = currentBalance - sessionStartBalance;
      if(sessionProfit >= sessionProfitTarget)
      {
         sessionTargetReached = true;
         Print("🎯 SESSION TARGET REACHED! Profit: $", DoubleToString(sessionProfit, 2));
         isPaused = true;
         return;
      }
   }
   
   // Update peak equity
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(currentEquity > peakEquity)
      peakEquity = currentEquity;
   
   // Check drawdown limit
   if(MaxDrawdownPercent > 0 && peakEquity > 0)
   {
      double currentDD = (currentEquity - peakEquity) / peakEquity * 100;
      if(currentDD <= -MaxDrawdownPercent)
      {
         emergencyStop = true;
         emergencyReason = StringFormat("Drawdown %.1f%% exceeded limit %.1f%%", currentDD, MaxDrawdownPercent);
         Print("🛑 EMERGENCY STOP: ", emergencyReason);
         CloseAllPositions();
         return;
      }
   }
   
   // Check spread
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPoints > MaxSpread)
   {
      if(debugVerbose && debugTickCounter % 100 == 0)
      {
         Print("⚠️ HIGH SPREAD: ", spreadPoints, " points (max: ", MaxSpread, ")");
      }
      return;
   }
   
   // Get current price
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   // Update gap size based on current price
   currentGapSize = currentPrice * GridSpacingPercent / 100.0;
   
   // Sync positions
   SyncPositions();
   
   // Calculate total profit
   CalculateTotalProfit();
   
   // Check global TP
   CheckGlobalTP();
   
   // MEAN REVERSION LOGIC
   CheckForBuyOpportunities(currentPrice, ask);
   CheckForSellOpportunities(currentPrice, bid);
}

//+------------------------------------------------------------------+
//| CHECK FOR BUY OPPORTUNITIES (Price falling)                      |
//+------------------------------------------------------------------+
void CheckForBuyOpportunities(double currentPrice, double ask)
{
   // Can we open more BUY positions?
   if(ArraySize(buyPositions) >= MaxBuyPositions)
      return;
   
   // Calculate how many grid levels down from last BUY level
   double priceDropFromLastBuy = lastBuyLevel - currentPrice;
   
   // Has price fallen by at least one full grid level?
   if(priceDropFromLastBuy >= currentGapSize)
   {
      // Calculate how many levels down we are
      int levelsFallen = (int)MathFloor(priceDropFromLastBuy / currentGapSize);
      
      // Open BUY positions for each grid level we've crossed
      for(int i = 0; i < levelsFallen; i++)
      {
         if(ArraySize(buyPositions) >= MaxBuyPositions)
            break;
         
         // Calculate the exact level price
         double levelPrice = lastBuyLevel - ((i + 1) * currentGapSize);
         
         // Only open if current price is still below this level
         if(currentPrice <= levelPrice)
         {
            if(OpenPosition(ORDER_TYPE_BUY, ask, levelPrice))
            {
               Print("📉 BUY opened at grid level: $", DoubleToString(levelPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
               Print("   (Price fell from $", DoubleToString(lastBuyLevel, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)), ")");
            }
         }
      }
      
      // Update last BUY level to current price (rounded to nearest grid)
      lastBuyLevel = currentPrice;
   }
}

//+------------------------------------------------------------------+
//| CHECK FOR SELL OPPORTUNITIES (Price rising)                      |
//+------------------------------------------------------------------+
void CheckForSellOpportunities(double currentPrice, double bid)
{
   // Can we open more SELL positions?
   if(ArraySize(sellPositions) >= MaxSellPositions)
      return;
   
   // Calculate how many grid levels up from last SELL level
   double priceRiseFromLastSell = currentPrice - lastSellLevel;
   
   // Has price risen by at least one full grid level?
   if(priceRiseFromLastSell >= currentGapSize)
   {
      // Calculate how many levels up we are
      int levelsRisen = (int)MathFloor(priceRiseFromLastSell / currentGapSize);
      
      // Open SELL positions for each grid level we've crossed
      for(int i = 0; i < levelsRisen; i++)
      {
         if(ArraySize(sellPositions) >= MaxSellPositions)
            break;
         
         // Calculate the exact level price
         double levelPrice = lastSellLevel + ((i + 1) * currentGapSize);
         
         // Only open if current price is still above this level
         if(currentPrice >= levelPrice)
         {
            if(OpenPosition(ORDER_TYPE_SELL, bid, levelPrice))
            {
               Print("📈 SELL opened at grid level: $", DoubleToString(levelPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
               Print("   (Price rose from $", DoubleToString(lastSellLevel, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)), ")");
            }
         }
      }
      
      // Update last SELL level to current price (rounded to nearest grid)
      lastSellLevel = currentPrice;
   }
}

//+------------------------------------------------------------------+
//| SYNC POSITIONS                                                    |
//+------------------------------------------------------------------+
void SyncPositions()
{
   ArrayResize(buyPositions, 0);
   ArrayResize(sellPositions, 0);
   
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
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                            |
//+------------------------------------------------------------------+
void CalculateTotalProfit()
{
   totalProfit = 0;
   
   for(int i = 0; i < ArraySize(buyPositions); i++)
   {
      if(PositionSelectByTicket(buyPositions[i].ticket))
      {
         totalProfit += PositionGetDouble(POSITION_PROFIT);
      }
   }
   
   for(int i = 0; i < ArraySize(sellPositions); i++)
   {
      if(PositionSelectByTicket(sellPositions[i].ticket))
      {
         totalProfit += PositionGetDouble(POSITION_PROFIT);
      }
   }
}

//+------------------------------------------------------------------+
//| CHECK GLOBAL TP                                                   |
//+------------------------------------------------------------------+
void CheckGlobalTP()
{
   if(GlobalTPFactor <= 0)
      return;
   
   double globalTPDollars = currentGapSize * GlobalTPFactor;
   
   if(totalProfit >= globalTPDollars)
   {
      Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      Print("💰 GLOBAL TP HIT! Profit: $", DoubleToString(totalProfit, 2));
      Print("   Target was: $", DoubleToString(globalTPDollars, 2));
      Print("   Closing all positions...");
      CloseAllPositions();
      
      // Reset reference to current price
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      referencePrice = (ask + bid) / 2.0;
      lastBuyLevel = referencePrice;
      lastSellLevel = referencePrice;
      
      Print("   New reference: $", DoubleToString(referencePrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
      Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
   }
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
   request.comment = StringFormat("MR_%.2f", levelPrice);
   
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
   lastBuyLevel = currentPrice;
   lastSellLevel = currentPrice;
   
   // Recalculate gap
   currentGapSize = referencePrice * GridSpacingPercent / 100.0;
   
   Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
   Print("🔄 GRID REBUILT");
   Print("   New Reference: $", DoubleToString(referencePrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   Print("   Grid Gap: $", DoubleToString(currentGapSize, 2));
   Print("   Next BUY: $", DoubleToString(lastBuyLevel - currentGapSize, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   Print("   Next SELL: $", DoubleToString(lastSellLevel + currentGapSize, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
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
   
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   request.type = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   if(!OrderSend(request, result))
   {
      Print("❌ Close failed: ", result.retcode);
   }
}

//+------------------------------------------------------------------+
//| PRINT DEBUG STATUS                                                |
//+------------------------------------------------------------------+
void PrintDebugStatus()
{
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   
   Print("╔══════════════════════════════════════════════════════════════╗");
   Print("║          TORAMA MEAN REVERSION EA - DEBUG STATUS v1.0       ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ TRADING STATUS                                               ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Strategy:              PURE MEAN REVERSION");
   Print("EA Status:             ", isPaused ? "PAUSED" : (emergencyStop ? "STOPPED" : (sessionTargetReached ? "TARGET" : "ACTIVE")));
   if(emergencyStop) Print("Stop Reason:           ", emergencyReason);
   Print("BUY Positions:         ", ArraySize(buyPositions), "/", MaxBuyPositions);
   Print("SELL Positions:        ", ArraySize(sellPositions), "/", MaxSellPositions);
   Print("Total Trades:          ", totalTrades);
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ PRICE & GRID                                                 ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Current Price:         $", DoubleToString(currentPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   Print("Reference Price:       $", DoubleToString(referencePrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   Print("Grid Gap:              $", DoubleToString(currentGapSize, 2), " (", DoubleToString(GridSpacingPercent, 2), "%)");
   Print("Last BUY Level:        $", DoubleToString(lastBuyLevel, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   Print("Last SELL Level:       $", DoubleToString(lastSellLevel, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   Print("Next BUY at:           $", DoubleToString(lastBuyLevel - currentGapSize, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)), " (", DoubleToString(lastBuyLevel - currentPrice, 2), " away)");
   Print("Next SELL at:          $", DoubleToString(lastSellLevel + currentGapSize, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)), " (", DoubleToString(currentPrice - lastSellLevel, 2), " away)");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("║ PROFIT & RISK                                                ║");
   Print("╠══════════════════════════════════════════════════════════════╣");
   Print("Floating P/L:          ", (totalProfit >= 0 ? "+" : ""), "$", DoubleToString(totalProfit, 2));
   Print("Equity:                $", DoubleToString(equity, 2));
   Print("Balance:               $", DoubleToString(balance, 2));
   Print("Drawdown:              ", DoubleToString(dd, 2), "%");
   if(SessionProfitPercent > 0)
   {
      Print("Session Profit:        $", DoubleToString(sessionProfit, 2));
      Print("Session Target:        $", DoubleToString(sessionProfitTarget, 2));
   }
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
      if(sparam == panelPrefix + "CloseBtn")
      {
         ObjectSetInteger(0, panelPrefix + "CloseBtn", OBJPROP_STATE, false);
         if(ArraySize(buyPositions) + ArraySize(sellPositions) > 0)
         {
            CloseAllPositions();
         }
      }
      else if(sparam == panelPrefix + "PauseBtn")
      {
         ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_STATE, false);
         isPaused = !isPaused;
         Print(isPaused ? "⏸️ EA PAUSED" : "▶️ EA RESUMED");
      }
      else if(sparam == panelPrefix + "TPBtn")
      {
         ObjectSetInteger(0, panelPrefix + "TPBtn", OBJPROP_STATE, false);
         CloseProfitablePositions();
      }
      else if(sparam == panelPrefix + "RebuildBtn")
      {
         ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_STATE, false);
         RebuildGrid();
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
      "CloseBtn", "PauseBtn", "TPBtn", "RebuildBtn",
      "PriceLabel", "Price",
      "NextBuyLabel", "NextBuy",
      "NextSellLabel", "NextSell",
      "GridLabel", "GridSpacing",
      "RefLabel", "RefPrice",
      "BuyLabel", "BuyPositions",
      "SellLabel", "SellPositions",
      "PnLLabel", "PnL",
      "EquityLabel", "Equity",
      "DDLabel", "DD",
      "SessionLabel", "SessionProfit",
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
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YSIZE, 380);  // Increased height for new elements
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BGCOLOR, C'20,20,25');  // Solid dark background
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BACK, false);  // FRONT (on top)
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_ZORDER, 0);  // Top layer
   
   int yPos = y + 10;
   
   // Title
   CreateLabel(panelPrefix + "Title", x + 10, yPos, "TORAMA MEAN REVERSION", clrGold, 10, "Arial Black");
   yPos += 25;
   
   // Status
   CreateLabel(panelPrefix + "Status", x + 10, yPos, "✅ ACTIVE", clrLimeGreen, 9, "Arial Black");
   yPos += lineHeight;
   
   // Buttons Row 1
   CreateButton(panelPrefix + "CloseBtn", x + 10, yPos, 80, 25, "CLOSE", clrRed, clrWhite);
   CreateButton(panelPrefix + "PauseBtn", x + 95, yPos, 80, 25, "PAUSE", clrOrange, clrWhite);
   CreateButton(panelPrefix + "TPBtn", x + 180, yPos, 90, 25, "TAKE TP", clrGreen, clrWhite);
   yPos += 30;
   
   // Buttons Row 2
   CreateButton(panelPrefix + "RebuildBtn", x + 10, yPos, 260, 25, "REBUILD GRID", clrDodgerBlue, clrWhite);
   yPos += 35;
   
   // Price
   CreateLabel(panelPrefix + "PriceLabel", x + 10, yPos, "Price:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Price", x + 100, yPos, "$0", clrWhite, 9, "Arial Black");
   yPos += lineHeight;
   
   // Next BUY Level
   CreateLabel(panelPrefix + "NextBuyLabel", x + 10, yPos, "Next BUY:", clrDodgerBlue, 9, "Arial Bold");
   CreateLabel(panelPrefix + "NextBuy", x + 100, yPos, "$0", clrDodgerBlue, 9, "Arial Black");
   yPos += lineHeight;
   
   // Next SELL Level
   CreateLabel(panelPrefix + "NextSellLabel", x + 10, yPos, "Next SELL:", clrOrangeRed, 9, "Arial Bold");
   CreateLabel(panelPrefix + "NextSell", x + 100, yPos, "$0", clrOrangeRed, 9, "Arial Black");
   yPos += lineHeight;
   
   // Grid
   CreateLabel(panelPrefix + "GridLabel", x + 10, yPos, "Grid Gap:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "GridSpacing", x + 100, yPos, "0.3%", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // Reference
   CreateLabel(panelPrefix + "RefLabel", x + 10, yPos, "Reference:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "RefPrice", x + 100, yPos, "$0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight + 5;
   
   // BUY Positions
   CreateLabel(panelPrefix + "BuyLabel", x + 10, yPos, "📉 BUY Pos:", clrDodgerBlue, 9, "Arial Black");
   CreateLabel(panelPrefix + "BuyPositions", x + 100, yPos, "0/15", clrDodgerBlue, 9, "Arial Black");
   yPos += lineHeight;
   
   // SELL Positions
   CreateLabel(panelPrefix + "SellLabel", x + 10, yPos, "📈 SELL Pos:", clrOrangeRed, 9, "Arial Black");
   CreateLabel(panelPrefix + "SellPositions", x + 100, yPos, "0/15", clrOrangeRed, 9, "Arial Black");
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
   
   // Session Profit
   CreateLabel(panelPrefix + "SessionLabel", x + 10, yPos, "Session:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "SessionProfit", x + 100, yPos, "$0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight + 5;
   
   // TORAMA CAPITAL BRANDING - Bottom right with margins, SOLID bold big gold
   CreateLabel(panelPrefix + "Brand", x + width - 155, yPos, "TORAMA CAPITAL", clrGold, 11, "Arial Black");
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
   if(sessionTargetReached)
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
   
   // Pause button text
   ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, isPaused ? "RESUME" : "PAUSE");
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, isPaused ? clrGreen : clrOrange);
   
   // Price
   ObjectSetString(0, panelPrefix + "Price", OBJPROP_TEXT, "$" + FormatPrice(currentPrice, digits));
   
   // Next BUY level (one gap below current price)
   double nextBuyLevel = lastBuyLevel - currentGapSize;
   ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, "$" + FormatPrice(nextBuyLevel, digits));
   
   // Next SELL level (one gap above current price)
   double nextSellLevel = lastSellLevel + currentGapSize;
   ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, "$" + FormatPrice(nextSellLevel, digits));
   
   // Grid
   ObjectSetString(0, panelPrefix + "GridSpacing", OBJPROP_TEXT,
                   FormatPrice(GridSpacingPercent, 2) + "% ($" + FormatPrice(currentGapSize, 2) + ")");
   
   // Reference
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, "$" + FormatPrice(referencePrice, digits));
   
   // Positions
   ObjectSetString(0, panelPrefix + "BuyPositions", OBJPROP_TEXT,
                   IntegerToString(ArraySize(buyPositions)) + "/" + IntegerToString(MaxBuyPositions));
   
   ObjectSetString(0, panelPrefix + "SellPositions", OBJPROP_TEXT,
                   IntegerToString(ArraySize(sellPositions)) + "/" + IntegerToString(MaxSellPositions));
   
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
   
   // Session Profit
   if(SessionProfitPercent > 0)
   {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      sessionProfit = currentBalance - sessionStartBalance;
      
      color sessionColor = (sessionProfit >= sessionProfitTarget) ? clrGold : 
                           (sessionProfit >= 0) ? clrLimeGreen : clrRed;
      
      ObjectSetString(0, panelPrefix + "SessionProfit", OBJPROP_TEXT,
                      (sessionProfit >= 0 ? "+" : "") + "$" + FormatPrice(sessionProfit, 2));
      ObjectSetInteger(0, panelPrefix + "SessionProfit", OBJPROP_COLOR, sessionColor);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "SessionProfit", OBJPROP_TEXT, "DISABLED");
      ObjectSetInteger(0, panelPrefix + "SessionProfit", OBJPROP_COLOR, clrGray);
   }
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
}

//+------------------------------------------------------------------+
