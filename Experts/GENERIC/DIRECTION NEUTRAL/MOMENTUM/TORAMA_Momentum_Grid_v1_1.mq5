//+------------------------------------------------------------------+
//|                                      TORAMA_Momentum_Grid_v1_1.mq5 |
//|                                      Copyright 2025, TORAMA CAPITAL |
//|                                               https://torama.money |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "1.10"
#property description "Momentum Grid EA - Buy rising, Sell falling"
#property description "Opens positions in direction of price movement from reference"
#property description "Chart-based magic numbers for multi-chart deployment"
#property description "Press 'H' to toggle panel visibility"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "=== GRID SETTINGS ==="
input double   GridSpacingPercent = 0.30;        // Grid spacing % of price
input int      MaxPositionsPerSide = 30;         // Max positions per side (BUY or SELL)
input double   LotSize = 0.01;                   // Lot size per position

input group "=== PROFIT TARGETS (Dollar Values) ==="
input double   IndividualTPDollars = 50.0;       // Individual TP in dollars per position
input double   IndividualSLDollars = 0.0;        // Individual SL in dollars per position (0 = disabled)
input double   GlobalTPDollars = 200.0;          // Global TP in dollars for all positions
input double   GlobalSLDollars = 0.0;            // Global SL in dollars for all positions (0 = disabled)

input group "=== MOMENTUM LOGIC ==="
input int      ProfitableCountToClose = 5;       // Close all when X positions profitable (per side)
input bool     CloseBothSidesOnProfit = false;   // Close both BUY and SELL when one side profits

input group "=== RISK MANAGEMENT ==="
input double   SessionProfitPercent = 200.0;     // Session/Daily profit target (% of starting balance)
input bool     ResetSessionDaily = true;         // Reset session profit daily
input double   MaxDrawdownPercent = 15.0;        // Max drawdown % (emergency stop)

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                 // Maximum spread (points)
input int      BaseMagicNumber = 77740;          // Base magic number (will be modified per chart)
input bool     ShowPanel = true;                 // Show info panel

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

// Chart-specific magic number
int MagicNumber = 0;

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
double referencePrice = 0;        // The reference price for momentum trades
double lastBuyLevel = 0;
double lastSellLevel = 0;
double highestBuyLevel = 0;
double lowestSellLevel = 0;

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
bool panelVisible = true;

// Panel
string panelPrefix = "MomentumPanel_";

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

//+------------------------------------------------------------------+
//| GENERATE CHART-BASED MAGIC NUMBER                                |
//+------------------------------------------------------------------+
int GenerateChartMagicNumber(int baseNumber)
{
   // Get chart ID (unique for each chart window)
   long chartID = ChartID();
   
   // Use modulo to keep magic number within reasonable range
   // This creates a unique number for each chart while keeping it manageable
   int chartSuffix = (int)(chartID % 10000);  // Last 4 digits of chart ID
   
   // Combine base number with chart ID
   // Base: 77740, Chart suffix: 0-9999
   // Result range: 777400000 - 777409999
   int uniqueMagicNumber = (baseNumber * 10000) + chartSuffix;
   
   return uniqueMagicNumber;
}

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   // Generate unique magic number for this chart
   MagicNumber = GenerateChartMagicNumber(BaseMagicNumber);
   
   // Enable keyboard event detection
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, false);
   
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
   
   // Set initial reference price
   referencePrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   
   // Calculate gap-based values
   currentGapSize = referencePrice * (GridSpacingPercent / 100.0);
   
   // Validate and normalize lot size
   normalizedLotSize = NormalizeLotSize(LotSize);
   
   // Display initialization info
   Print("╔════════════════════════════════════════════════════════════════╗");
   Print("║     TORAMA MOMENTUM GRID EA v1.1                               ║");
   Print("╚════════════════════════════════════════════════════════════════╝");
   Print("Chart ID: ", ChartID());
   Print("Magic Number: ", MagicNumber, " (Base: ", BaseMagicNumber, " + Chart: ", (MagicNumber - BaseMagicNumber * 10000), ")");
   Print("Symbol: ", _Symbol);
   Print("Account: ", AccountInfoString(ACCOUNT_NAME), " (", AccountInfoString(ACCOUNT_SERVER), ")");
   Print("Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("═══════════════════════════════════════");
   
   Print("📈 MOMENTUM MODE");
   Print("Strategy: Buy rising, Sell falling");
   Print("Reference Price: ", DoubleToString(referencePrice, digits));
   Print("Close when: ", ProfitableCountToClose, " positions profitable per side");
   Print("Close both sides: ", CloseBothSidesOnProfit ? "YES" : "NO");
   Print("Grid Spacing: ", GridSpacingPercent, "% = $", DoubleToString(currentGapSize, 2));
   Print("Max Positions: ", MaxPositionsPerSide, " per side (", MaxPositionsPerSide * 2, " total)");
   Print("Lot Size: ", DoubleToString(normalizedLotSize, 2), " (normalized from ", DoubleToString(LotSize, 2), ")");
   Print("Individual TP: $", DoubleToString(IndividualTPDollars, 2), " per position");
   Print("Individual SL: ", IndividualSLDollars > 0 ? "$" + DoubleToString(IndividualSLDollars, 2) + " per position" : "DISABLED");
   Print("Global TP: $", DoubleToString(GlobalTPDollars, 2), " total");
   Print("Global SL: ", GlobalSLDollars > 0 ? "$" + DoubleToString(GlobalSLDollars, 2) + " total" : "DISABLED");
   Print("Session Target: ", SessionProfitPercent, "% = $", DoubleToString(sessionProfitTarget, 2));
   Print("Max Drawdown: ", MaxDrawdownPercent, "%");
   Print("═══════════════════════════════════════");
   Print("💡 Press 'H' to toggle panel visibility");
   
   // Sync existing positions
   SyncPositions();
   
   Print("✅ EA initialized successfully!");
   Print("Waiting for price movement from reference...");
   
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
   // Update panel if visible
   if(ShowPanel && panelVisible) UpdatePanel();
   
   // Check for daily session reset
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
         Print("🔄 Daily session reset at ", TimeToString(TimeCurrent()));
         Print("   New target: $", DoubleToString(sessionProfitTarget, 2));
      }
   }
   
   // Check if EA is paused
   if(isPaused)
   {
      return;
   }
   
   // Check if session target reached
   if(sessionTargetReached)
   {
      return;
   }
   
   // Check if grid needs rebuild
   int currentTotal = ArraySize(buyPositions) + ArraySize(sellPositions);
   if(currentTotal == 0 && lastTotalPositions > 0 && !needsRebuild)
   {
      needsRebuild = true;
      Print("🔄 All positions closed. Grid rebuild scheduled.");
   }
   
   if(needsRebuild)
   {
      RebuildGrid();
      needsRebuild = false;
   }
   
   lastTotalPositions = currentTotal;
   
   // Update positions arrays
   SyncPositions();
   
   // Calculate current profit
   double currentProfit = CalculateTotalProfit();
   sessionProfit = AccountInfoDouble(ACCOUNT_BALANCE) - sessionStartBalance;
   
   // Check max drawdown (emergency stop)
   double currentDrawdown = (sessionProfit / sessionStartBalance) * 100.0;
   if(currentDrawdown < -MaxDrawdownPercent)
   {
      Print("🚨 EMERGENCY STOP: Max drawdown reached (", DoubleToString(currentDrawdown, 2), "%)");
      CloseAllPositions();
      isPaused = true;
      return;
   }
   
   // Check session profit target
   if(sessionProfit >= sessionProfitTarget)
   {
      Print("🎯 SESSION TARGET REACHED! Profit: $", DoubleToString(sessionProfit, 2));
      CloseAllPositions();
      sessionTargetReached = true;
      return;
   }
   
   // Check global profit target
   if(GlobalTPDollars > 0 && currentProfit >= GlobalTPDollars)
   {
      Print("💰 GLOBAL TP HIT! Total profit: $", DoubleToString(currentProfit, 2));
      CloseAllPositions();
      return;
   }
   
   // Check global stop loss
   if(GlobalSLDollars > 0 && currentProfit <= -GlobalSLDollars)
   {
      Print("🛑 GLOBAL SL HIT! Total loss: $", DoubleToString(currentProfit, 2));
      CloseAllPositions();
      return;
   }
   
   // Check profitable position count trigger
   CheckProfitablePositions();
   
   // Check spread
   if(!IsSpreadAcceptable())
   {
      return;
   }
   
   // Check for momentum opportunities
   CheckMomentumSignals();
}

//+------------------------------------------------------------------+
//| INITIALIZE SYMBOL PROPERTIES                                      |
//+------------------------------------------------------------------+
bool InitializeSymbolProperties()
{
   // Get symbol properties
   digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   
   // Validate
   if(pointValue == 0 || tickValue == 0 || tickSize == 0)
   {
      Print("❌ ERROR: Invalid symbol properties");
      return false;
   }
   
   Print("📊 Symbol Properties:");
   Print("   Digits: ", digits);
   Print("   Point: ", pointValue);
   Print("   Tick Value: $", DoubleToString(tickValue, 2));
   Print("   Tick Size: ", DoubleToString(tickSize, digits));
   Print("   Min Lot: ", DoubleToString(minLot, 2));
   Print("   Max Lot: ", DoubleToString(maxLot, 2));
   Print("   Lot Step: ", DoubleToString(lotStep, 2));
   
   return true;
}

//+------------------------------------------------------------------+
//| NORMALIZE LOT SIZE                                                |
//+------------------------------------------------------------------+
double NormalizeLotSize(double lots)
{
   // Round to lot step
   double normalized = MathRound(lots / lotStep) * lotStep;
   
   // Clamp to broker limits
   if(normalized < minLot) normalized = minLot;
   if(normalized > maxLot) normalized = maxLot;
   
   return normalized;
}

//+------------------------------------------------------------------+
//| GET SAFE PRICE                                                    |
//+------------------------------------------------------------------+
double GetSafePrice(ENUM_SYMBOL_INFO_DOUBLE priceType)
{
   double price = SymbolInfoDouble(_Symbol, priceType);
   
   if(price <= 0)
   {
      Print("⚠️ WARNING: Invalid price from broker (", EnumToString(priceType), "), retrying...");
      Sleep(100);
      price = SymbolInfoDouble(_Symbol, priceType);
   }
   
   return price;
}

//+------------------------------------------------------------------+
//| SYNC POSITIONS                                                    |
//+------------------------------------------------------------------+
void SyncPositions()
{
   // Clear arrays
   ArrayResize(buyPositions, 0);
   ArrayResize(sellPositions, 0);
   
   // Scan all positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
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
      else if(pos.type == POSITION_TYPE_SELL)
      {
         int size = ArraySize(sellPositions);
         ArrayResize(sellPositions, size + 1);
         sellPositions[size] = pos;
      }
   }
}

//+------------------------------------------------------------------+
//| CHECK MOMENTUM SIGNALS                                            |
//+------------------------------------------------------------------+
void CheckMomentumSignals()
{
   double ask = GetSafePrice(SYMBOL_ASK);
   double bid = GetSafePrice(SYMBOL_BID);
   
   if(ask <= 0 || bid <= 0)
   {
      Print("⚠️ WARNING: Invalid prices, skipping momentum check");
      return;
   }
   
   double currentPrice = (ask + bid) / 2.0;
   
   // Validate gap size
   if(currentGapSize <= 0)
   {
      Print("❌ CRITICAL: Gap size is zero or negative: ", currentGapSize);
      return;
   }
   
   // BUY MOMENTUM: Price rising above reference
   if(currentPrice > referencePrice)
   {
      double priceAboveRef = currentPrice - referencePrice;
      
      // Determine next BUY level
      double nextBuyLevel;
      if(lastBuyLevel == 0)
      {
         // First BUY position - place at first gap above reference
         nextBuyLevel = referencePrice + currentGapSize;
      }
      else
      {
         // Subsequent BUY positions
         nextBuyLevel = lastBuyLevel + currentGapSize;
      }
      
      // Check if we should open a BUY
      if(currentPrice >= nextBuyLevel && ArraySize(buyPositions) < MaxPositionsPerSide)
      {
         if(OpenPosition(ORDER_TYPE_BUY, ask))
         {
            lastBuyLevel = nextBuyLevel;
            if(nextBuyLevel > highestBuyLevel) highestBuyLevel = nextBuyLevel;
            
            Print("📈 BUY MOMENTUM TRADE #", ArraySize(buyPositions));
            Print("   Entry: ", DoubleToString(ask, digits));
            Print("   Gap from reference: $", DoubleToString(priceAboveRef, 2));
            Print("   Level: ", DoubleToString(nextBuyLevel, digits));
         }
      }
   }
   
   // SELL MOMENTUM: Price falling below reference
   if(currentPrice < referencePrice)
   {
      double priceBelowRef = referencePrice - currentPrice;
      
      // Determine next SELL level
      double nextSellLevel;
      if(lastSellLevel == 0)
      {
         // First SELL position - place at first gap below reference
         nextSellLevel = referencePrice - currentGapSize;
      }
      else
      {
         // Subsequent SELL positions
         nextSellLevel = lastSellLevel - currentGapSize;
      }
      
      // Check if we should open a SELL
      if(currentPrice <= nextSellLevel && ArraySize(sellPositions) < MaxPositionsPerSide)
      {
         if(OpenPosition(ORDER_TYPE_SELL, bid))
         {
            lastSellLevel = nextSellLevel;
            if(nextSellLevel < lowestSellLevel || lowestSellLevel == 0) lowestSellLevel = nextSellLevel;
            
            Print("📉 SELL MOMENTUM TRADE #", ArraySize(sellPositions));
            Print("   Entry: ", DoubleToString(bid, digits));
            Print("   Gap from reference: $", DoubleToString(priceBelowRef, 2));
            Print("   Level: ", DoubleToString(nextSellLevel, digits));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OPEN POSITION                                                     |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE type, double price)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = normalizedLotSize;
   request.type = type;
   request.price = price;
   request.deviation = 50;
   request.magic = MagicNumber;
   request.comment = "ToramaMomentum";
   
   // Calculate TP/SL if enabled
   if(IndividualTPDollars > 0 || IndividualSLDollars > 0)
   {
      double tpPrice = 0;
      double slPrice = 0;
      
      if(IndividualTPDollars > 0)
      {
         double tpDistance = (IndividualTPDollars / tickValue) * tickSize;
         tpPrice = (type == ORDER_TYPE_BUY) ? price + tpDistance : price - tpDistance;
         tpPrice = NormalizeDouble(tpPrice, digits);
         request.tp = tpPrice;
      }
      
      if(IndividualSLDollars > 0)
      {
         double slDistance = (IndividualSLDollars / tickValue) * tickSize;
         slPrice = (type == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
         slPrice = NormalizeDouble(slPrice, digits);
         request.sl = slPrice;
      }
   }
   
   // Send order
   bool sent = OrderSend(request, result);
   
   if(sent && result.retcode == TRADE_RETCODE_DONE)
   {
      Print("✅ Position opened: ", result.order);
      return true;
   }
   else
   {
      Print("❌ Failed to open position: ", TradeRetcodeDescription(result.retcode));
      return false;
   }
}

//+------------------------------------------------------------------+
//| CHECK PROFITABLE POSITIONS                                        |
//+------------------------------------------------------------------+
void CheckProfitablePositions()
{
   if(ProfitableCountToClose <= 0) return;
   
   // Count profitable BUY positions
   int profitableBuys = 0;
   for(int i = 0; i < ArraySize(buyPositions); i++)
   {
      if(PositionSelectByTicket(buyPositions[i].ticket))
      {
         if(PositionGetDouble(POSITION_PROFIT) > 0)
            profitableBuys++;
      }
   }
   
   // Count profitable SELL positions
   int profitableSells = 0;
   for(int i = 0; i < ArraySize(sellPositions); i++)
   {
      if(PositionSelectByTicket(sellPositions[i].ticket))
      {
         if(PositionGetDouble(POSITION_PROFIT) > 0)
            profitableSells++;
      }
   }
   
   // Check BUY side
   if(profitableBuys >= ProfitableCountToClose && ArraySize(buyPositions) > 0)
   {
      Print("🎯 ", profitableBuys, " BUY positions profitable - closing ", 
            CloseBothSidesOnProfit ? "ALL" : "BUY side");
      
      if(CloseBothSidesOnProfit)
         CloseAllPositions();
      else
         ClosePositionsSide("BUY");
   }
   
   // Check SELL side
   if(profitableSells >= ProfitableCountToClose && ArraySize(sellPositions) > 0)
   {
      Print("🎯 ", profitableSells, " SELL positions profitable - closing ", 
            CloseBothSidesOnProfit ? "ALL" : "SELL side");
      
      if(CloseBothSidesOnProfit)
         CloseAllPositions();
      else
         ClosePositionsSide("SELL");
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                            |
//+------------------------------------------------------------------+
double CalculateTotalProfit()
{
   double total = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   
   return total;
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   Print("🔴 Closing all positions...");
   
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      
      request.action = TRADE_ACTION_DEAL;
      request.position = ticket;
      request.symbol = _Symbol;
      request.volume = PositionGetDouble(POSITION_VOLUME);
      request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      request.deviation = 50;
      request.magic = MagicNumber;
      
      if(OrderSend(request, result))
         closed++;
   }
   
   Print("✅ Closed ", closed, " positions");
   needsRebuild = true;
}

//+------------------------------------------------------------------+
//| CLOSE POSITIONS BY SIDE                                          |
//+------------------------------------------------------------------+
void ClosePositionsSide(string side)
{
   Print("🔴 Closing ", side, " positions...");
   
   ENUM_POSITION_TYPE targetType = (side == "BUY") ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   int closed = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetInteger(POSITION_TYPE) != targetType) continue;
      
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      
      request.action = TRADE_ACTION_DEAL;
      request.position = ticket;
      request.symbol = _Symbol;
      request.volume = PositionGetDouble(POSITION_VOLUME);
      request.type = (targetType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      request.deviation = 50;
      request.magic = MagicNumber;
      
      if(OrderSend(request, result))
         closed++;
   }
   
   Print("✅ Closed ", closed, " ", side, " positions");
}

//+------------------------------------------------------------------+
//| IS SPREAD ACCEPTABLE                                              |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= MaxSpread);
}

//+------------------------------------------------------------------+
//| CREATE PANEL                                                      |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 10;
   int y = 20;
   int width = 280;
   int lineHeight = 18;
   color bgColor = clrBlack;
   color textColor = clrWhite;
   color headerColor = C'0,150,255';  // TORAMA blue
   
   // Background
   ObjectCreate(0, panelPrefix + "Background", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YSIZE, 420);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_COLOR, headerColor);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BACK, true);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_HIDDEN, true);
   
   int currentY = y + 10;
   
   // Header
   CreateLabel(panelPrefix + "Header", "═══ TORAMA MOMENTUM GRID ═══", x + 10, currentY, headerColor, 9, "Arial Bold");
   currentY += lineHeight + 5;
   
   // Magic Number
   CreateLabel(panelPrefix + "MagicLabel", "Magic: " + IntegerToString(MagicNumber), x + 10, currentY, textColor, 8);
   currentY += lineHeight;
   
   // Status
   CreateLabel(panelPrefix + "Status", "Status: ACTIVE", x + 10, currentY, clrLime, 8);
   currentY += lineHeight + 3;
   
   // Separator
   CreateLabel(panelPrefix + "Sep1", "─────────────────────────────────", x + 10, currentY, C'50,50,50', 8);
   currentY += lineHeight;
   
   // Grid info
   CreateLabel(panelPrefix + "GridInfo", "GRID INFORMATION", x + 10, currentY, headerColor, 8, "Arial Bold");
   currentY += lineHeight;
   
   CreateLabel(panelPrefix + "Reference", "Reference: 0.00000", x + 10, currentY, textColor, 8);
   currentY += lineHeight;
   
   CreateLabel(panelPrefix + "GapSize", "Gap: $0.00", x + 10, currentY, textColor, 8);
   currentY += lineHeight;
   
   CreateLabel(panelPrefix + "BuyCount", "BUY Positions: 0 / " + IntegerToString(MaxPositionsPerSide), x + 10, currentY, clrDodgerBlue, 8);
   currentY += lineHeight;
   
   CreateLabel(panelPrefix + "SellCount", "SELL Positions: 0 / " + IntegerToString(MaxPositionsPerSide), x + 10, currentY, clrOrangeRed, 8);
   currentY += lineHeight + 3;
   
   // Separator
   CreateLabel(panelPrefix + "Sep2", "─────────────────────────────────", x + 10, currentY, C'50,50,50', 8);
   currentY += lineHeight;
   
   // Profit info
   CreateLabel(panelPrefix + "ProfitInfo", "PROFIT & RISK", x + 10, currentY, headerColor, 8, "Arial Bold");
   currentY += lineHeight;
   
   CreateLabel(panelPrefix + "BuyProfit", "BUY P&L: $0.00", x + 10, currentY, textColor, 8);
   currentY += lineHeight;
   
   CreateLabel(panelPrefix + "SellProfit", "SELL P&L: $0.00", x + 10, currentY, textColor, 8);
   currentY += lineHeight;
   
   CreateLabel(panelPrefix + "TotalProfit", "Total P&L: $0.00", x + 10, currentY, textColor, 8, "Arial Bold");
   currentY += lineHeight;
   
   CreateLabel(panelPrefix + "SessionProfit", "Session: $0.00 / $0.00", x + 10, currentY, textColor, 8);
   currentY += lineHeight + 3;
   
   // Separator
   CreateLabel(panelPrefix + "Sep3", "─────────────────────────────────", x + 10, currentY, C'50,50,50', 8);
   currentY += lineHeight;
   
   // Control buttons
   CreateLabel(panelPrefix + "Controls", "CONTROLS", x + 10, currentY, headerColor, 8, "Arial Bold");
   currentY += lineHeight + 3;
   
   // Close BUY button
   CreateButton(panelPrefix + "CloseBuyBtn", "Close BUY", x + 10, currentY, 80, 25, clrDodgerBlue);
   
   // Close SELL button
   CreateButton(panelPrefix + "CloseSellBtn", "Close SELL", x + 95, currentY, 80, 25, clrOrangeRed);
   
   // Close All button
   CreateButton(panelPrefix + "CloseAllBtn", "Close ALL", x + 180, currentY, 90, 25, clrRed);
   currentY += 30;
   
   // Rebuild button
   CreateButton(panelPrefix + "RebuildBtn", "Rebuild Grid", x + 10, currentY, 130, 25, clrGold);
   
   // Pause button
   CreateButton(panelPrefix + "PauseBtn", "Pause/Resume", x + 145, currentY, 125, 25, clrOrange);
   currentY += 30;
   
   // Footer
   CreateLabel(panelPrefix + "Footer", "Press 'H' to hide/show panel", x + 10, currentY, C'100,100,100', 7);
   
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| CREATE LABEL                                                      |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr, int fontSize = 8, string font = "Arial")
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| CREATE BUTTON                                                     |
//+------------------------------------------------------------------+
void CreateButton(string name, string text, int x, int y, int width, int height, color clr)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!panelVisible) return;
   
   // Status
   string status = isPaused ? "PAUSED" : (sessionTargetReached ? "TARGET REACHED" : "ACTIVE");
   color statusColor = isPaused ? clrOrange : (sessionTargetReached ? clrGold : clrLime);
   ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "Status: " + status);
   ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, statusColor);
   
   // Grid info
   ObjectSetString(0, panelPrefix + "Reference", OBJPROP_TEXT, 
      "Reference: " + DoubleToString(referencePrice, digits));
   ObjectSetString(0, panelPrefix + "GapSize", OBJPROP_TEXT, 
      "Gap: $" + DoubleToString(currentGapSize, 2));
   
   // Position counts
   int buyCount = ArraySize(buyPositions);
   int sellCount = ArraySize(sellPositions);
   
   ObjectSetString(0, panelPrefix + "BuyCount", OBJPROP_TEXT, 
      "BUY Positions: " + IntegerToString(buyCount) + " / " + IntegerToString(MaxPositionsPerSide));
   ObjectSetString(0, panelPrefix + "SellCount", OBJPROP_TEXT, 
      "SELL Positions: " + IntegerToString(sellCount) + " / " + IntegerToString(MaxPositionsPerSide));
   
   // Calculate profits
   double buyProfit = 0;
   double sellProfit = 0;
   
   for(int i = 0; i < buyCount; i++)
   {
      if(PositionSelectByTicket(buyPositions[i].ticket))
         buyProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   
   for(int i = 0; i < sellCount; i++)
   {
      if(PositionSelectByTicket(sellPositions[i].ticket))
         sellProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   
   double totalProfit = buyProfit + sellProfit;
   
   // Update profit labels
   ObjectSetString(0, panelPrefix + "BuyProfit", OBJPROP_TEXT, 
      "BUY P&L: $" + DoubleToString(buyProfit, 2));
   ObjectSetInteger(0, panelPrefix + "BuyProfit", OBJPROP_COLOR, 
      buyProfit > 0 ? clrLime : (buyProfit < 0 ? clrRed : clrWhite));
   
   ObjectSetString(0, panelPrefix + "SellProfit", OBJPROP_TEXT, 
      "SELL P&L: $" + DoubleToString(sellProfit, 2));
   ObjectSetInteger(0, panelPrefix + "SellProfit", OBJPROP_COLOR, 
      sellProfit > 0 ? clrLime : (sellProfit < 0 ? clrRed : clrWhite));
   
   ObjectSetString(0, panelPrefix + "TotalProfit", OBJPROP_TEXT, 
      "Total P&L: $" + DoubleToString(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "TotalProfit", OBJPROP_COLOR, 
      totalProfit > 0 ? clrLime : (totalProfit < 0 ? clrRed : clrWhite));
   
   ObjectSetString(0, panelPrefix + "SessionProfit", OBJPROP_TEXT, 
      "Session: $" + DoubleToString(sessionProfit, 2) + " / $" + DoubleToString(sessionProfitTarget, 2));
   ObjectSetInteger(0, panelPrefix + "SessionProfit", OBJPROP_COLOR, 
      sessionProfit > 0 ? clrLime : (sessionProfit < 0 ? clrRed : clrWhite));
}

//+------------------------------------------------------------------+
//| DELETE PANEL                                                      |
//+------------------------------------------------------------------+
void DeletePanel()
{
   ObjectsDeleteAll(0, panelPrefix);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| TOGGLE PANEL VISIBILITY                                          |
//+------------------------------------------------------------------+
void TogglePanelVisibility()
{
   panelVisible = !panelVisible;
   
   // Toggle visibility of all panel objects
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      string objName = ObjectName(0, i);
      if(StringFind(objName, panelPrefix) == 0)
      {
         ObjectSetInteger(0, objName, OBJPROP_TIMEFRAMES, panelVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
      }
   }
   
   ChartRedraw(0);
   Print(panelVisible ? "📊 Panel shown" : "👁 Panel hidden");
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
   highestBuyLevel = 0;
   lowestSellLevel = 0;
   
   // Reset reference price to current with validation
   double ask = GetSafePrice(SYMBOL_ASK);
   double bid = GetSafePrice(SYMBOL_BID);
   
   if(ask <= 0 || bid <= 0)
   {
      Print("❌ ERROR: Cannot rebuild grid - Invalid prices");
      return;
   }
   
   double currentPrice = (ask + bid) / 2.0;
   referencePrice = currentPrice;
   
   // Recalculate gap based on new reference price with validation
   if(GridSpacingPercent <= 0 || GridSpacingPercent > 100)
   {
      Print("❌ ERROR: Invalid GridSpacingPercent: ", GridSpacingPercent);
      return;
   }
   
   currentGapSize = referencePrice * (GridSpacingPercent / 100.0);
   
   // Validate gap size
   if(currentGapSize <= 0)
   {
      Print("❌ CRITICAL: Gap size calculated as zero or negative: ", currentGapSize);
      currentGapSize = referencePrice * 0.001; // 0.1% fallback
      Print("   Using fallback gap: ", currentGapSize);
   }
   
   Print("✅ Grid rebuilt successfully!");
   Print("   Reference Price: ", DoubleToString(referencePrice, digits));
   Print("   New Gap Size: $", DoubleToString(currentGapSize, 2));
   Print("   Individual TP: $", DoubleToString(IndividualTPDollars, 2));
   Print("   Global TP: $", DoubleToString(GlobalTPDollars, 2));
   Print("   Waiting for price movement from reference...");
}

//+------------------------------------------------------------------+
//| CHART EVENT HANDLER                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Handle keyboard events
   if(id == CHARTEVENT_KEYDOWN)
   {
      // Check for 'H' key (both uppercase and lowercase)
      if(lparam == 72 || lparam == 104)  // 'H' or 'h'
      {
         TogglePanelVisibility();
      }
   }
   
   // Handle button clicks
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
