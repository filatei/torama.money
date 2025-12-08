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
      UpdatePanel();
      return;
   }
   
   // Skip if session target reached
   if(sessionTargetReached)
   {
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
   digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0)
   {
      Print("❌ Error: SYMBOL_TRADE_TICK_SIZE is 0");
      return false;
   }
   
   tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue == 0)
   {
      Print("❌ Error: SYMBOL_TRADE_TICK_VALUE is 0");
      return false;
   }
   
   pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   
   Print("📊 Symbol Properties:");
   Print("   Digits: ", digits);
   Print("   Tick Size: ", tickSize);
   Print("   Tick Value: $", tickValue);
   Print("   Point Value: ", pointValue);
   Print("   Min Lot: ", minLot);
   Print("   Max Lot: ", maxLot);
   Print("   Lot Step: ", lotStep);
   
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
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double gridSpacing = currentPrice * (GridSpacingPercent / 100.0);
   
   int buyCount = ArraySize(buyPositions);
   int sellCount = ArraySize(sellPositions);
   
   // Initialize grid if no positions
   if(buyCount == 0 && sellCount == 0)
   {
      lastBuyLevel = currentPrice - gridSpacing;
      lastSellLevel = currentPrice + gridSpacing;
      lowestBuyLevel = lastBuyLevel;
      highestSellLevel = lastSellLevel;
      return;
   }
   
   // MEAN REVERSION: Buy when falling
   if(buyCount < MaxPositionsPerSide)
   {
      if(buyCount == 0)
      {
         // First BUY position - place below current price
         if(currentPrice <= lastBuyLevel || lastBuyLevel == 0)
         {
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
         // First SELL position - place above current price
         if(currentPrice >= lastSellLevel || lastSellLevel == 0)
         {
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
   // Use the normalized lot size
   double lots = normalizedLotSize;
   
   // Calculate TP and SL distances
   double tpDistance = CalculateTPSLDistance(individualTPDollars, lots, direction);
   double slDistance = (individualSLDollars > 0) ? CalculateTPSLDistance(individualSLDollars, lots, direction) : 0;
   
   ENUM_ORDER_TYPE orderType = (direction == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lots;
   request.type = orderType;
   request.price = (orderType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = "MeanRev_" + direction;
   
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
   
   if(!OrderSend(request, result))
   {
      Print("❌ OrderSend failed: ", GetLastError());
      Print("   Direction: ", direction);
      Print("   Price: ", request.price);
      Print("   Volume: ", request.volume);
      return false;
   }
   
   if(result.retcode != TRADE_RETCODE_DONE)
   {
      Print("⚠️ Order not executed: ", result.retcode);
      return false;
   }
   
   Print("✅ ", direction, " position opened at $", DoubleToString(request.price, 2));
   if(tpDistance > 0)
      Print("   TP: $", DoubleToString(request.tp, 2));
   if(slDistance > 0)
      Print("   SL: $", DoubleToString(request.sl, 2));
   
   return true;
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
   PositionInfo positions[];
   if(side == "BUY")
      ArrayCopy(positions, buyPositions);
   else
      ArrayCopy(positions, sellPositions);
   
   int closed = 0;
   
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(positions[i].ticket)) continue;
      
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      
      request.action = TRADE_ACTION_DEAL;
      request.position = positions[i].ticket;
      request.symbol = _Symbol;
      request.volume = PositionGetDouble(POSITION_VOLUME);
      request.deviation = 10;
      request.magic = MagicNumber;
      
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      request.type = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      if(OrderSend(request, result))
      {
         if(result.retcode == TRADE_RETCODE_DONE)
         {
            closed++;
         }
      }
   }
   
   Print("✅ Closed ", closed, " ", side, " position(s)");
   
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
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YSIZE, 570);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BACK, false);
   
   int row = 0;
   
   // Title
   CreateLabel(panelPrefix + "Title", "MEAN REVERSION GRID v1.0", x + 10, y + 10 + (row++ * rowHeight), clrYellow);
   row++; // Skip row
   
   // Stats
   CreateLabel(panelPrefix + "BuyPos", "BUY Positions: 0", x + 10, y + 10 + (row++ * rowHeight), clrLime);
   CreateLabel(panelPrefix + "SellPos", "SELL Positions: 0", x + 10, y + 10 + (row++ * rowHeight), clrRed);
   CreateLabel(panelPrefix + "BuyProfit", "BUY P/L: $0.00", x + 10, y + 10 + (row++ * rowHeight), clrWhite);
   CreateLabel(panelPrefix + "SellProfit", "SELL P/L: $0.00", x + 10, y + 10 + (row++ * rowHeight), clrWhite);
   CreateLabel(panelPrefix + "TotalProfit", "Total P/L: $0.00", x + 10, y + 10 + (row++ * rowHeight), clrAqua);
   row++; // Skip row
   
   CreateLabel(panelPrefix + "SessionProfit", "Session: $0.00", x + 10, y + 10 + (row++ * rowHeight), clrGold);
   CreateLabel(panelPrefix + "SessionTarget", "Target: $0.00", x + 10, y + 10 + (row++ * rowHeight), clrWhite);
   row++; // Skip row
   
   CreateLabel(panelPrefix + "Spread", "Spread: 0", x + 10, y + 10 + (row++ * rowHeight), clrWhite);
   CreateLabel(panelPrefix + "Drawdown", "Drawdown: 0.0%", x + 10, y + 10 + (row++ * rowHeight), clrWhite);
   row++; // Skip row
   
   CreateLabel(panelPrefix + "Gap", "Gap: 0.00% ($0.00)", x + 10, y + 10 + (row++ * rowHeight), clrCyan);
   CreateLabel(panelPrefix + "NextBuy", "Next BUY: 0.00000", x + 10, y + 10 + (row++ * rowHeight), clrLime);
   CreateLabel(panelPrefix + "NextSell", "Next SELL: 0.00000", x + 10, y + 10 + (row++ * rowHeight), clrRed);
   
   // Buttons
   row++;
   CreateButton(panelPrefix + "CloseBuyBtn", "CLOSE BUYS", x + 10, y + 10 + (row++ * rowHeight), 120, 25);
   CreateButton(panelPrefix + "CloseSellBtn", "CLOSE SELLS", x + 150, y + 10 + (row * rowHeight), 120, 25);
   row++;
   CreateButton(panelPrefix + "CloseAllBtn", "CLOSE ALL", x + 10, y + 10 + (row++ * rowHeight), 260, 25);
   CreateButton(panelPrefix + "RebuildBtn", "REBUILD GRID", x + 10, y + 10 + (row++ * rowHeight), 260, 25);
   CreateButton(panelPrefix + "PauseBtn", "⏸ PAUSE EA", x + 10, y + 10 + (row++ * rowHeight), 260, 25);
   
   // Branding
   row += 2;
   CreateLabel(panelPrefix + "Brand", "TORAMA CAPITAL", x + width - 140, y + 10 + (row * rowHeight), clrGold);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_FONTSIZE, 11);
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_FONT, "Arial Bold");
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
   ObjectSetString(0, panelPrefix + "BuyPos", OBJPROP_TEXT, "BUY Positions: " + IntegerToString(buyCount));
   ObjectSetString(0, panelPrefix + "SellPos", OBJPROP_TEXT, "SELL Positions: " + IntegerToString(sellCount));
   
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
   ObjectSetString(0, panelPrefix + "Drawdown", OBJPROP_TEXT, "Drawdown: " + DoubleToString(drawdown, 1) + "%");
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
      ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, "▶ RESUME EA");
      ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, clrDarkGreen);
      ObjectSetString(0, panelPrefix + "Title", OBJPROP_TEXT, "MEAN REVERSION GRID v1.0 [PAUSED]");
      ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_COLOR, clrOrange);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, "⏸ PAUSE EA");
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
