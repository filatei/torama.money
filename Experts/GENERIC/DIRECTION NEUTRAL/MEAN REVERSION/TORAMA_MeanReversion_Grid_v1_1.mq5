//+------------------------------------------------------------------+
//|                                  TORAMA_MeanReversion_Grid_v1_0.mq5 |
//|                                      Copyright 2025, TORAMA CAPITAL |
//|                                               https://torama.money |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "1.10"
#property description "Mean Reversion Grid - Shows next BUY/SELL levels"
#property description "Chart-based magic numbers | Press 'H' to toggle panel"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "=== GRID SETTINGS ==="
input double   GridSpacingPercent = 0.30;       // Grid spacing % of price
input int      MaxPositionsPerSide = 30;        // Max positions per side (BUY or SELL)
input double   LotSize = 0.01;                  // Lot size per position

input group "=== PROFIT TARGETS (Dollars) ==="
input double   IndividualTPDollars = 50.0;      // Individual TP in dollars per position
input double   IndividualSLDollars = 0.0;       // Individual SL in dollars (0 = disabled)
input double   GlobalTPDollars = 200.0;         // Global TP in dollars for all positions
input double   GlobalSLDollars = 0.0;           // Global SL in dollars (0 = disabled)

input group "=== MEAN REVERSION LOGIC ==="
input int      ProfitableCountToClose = 5;      // Close profitable when X positions profitable
input bool     CloseBothSidesOnProfit = false;  // Close ALL positions when trigger reached

input group "=== RISK MANAGEMENT ==="
input double   SessionProfitPercent = 200.0;    // Session profit target (% of starting balance)
input bool     ResetSessionDaily = true;        // Reset session profit daily
input double   MaxDrawdownPercent = 15.0;       // Max drawdown % (emergency stop)

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                // Maximum spread (points)
input int      BaseMagicNumber = 77750;         // Base magic number (modified per chart)
input bool     ShowPanel = true;                // Show info panel

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
struct PositionInfo { ulong ticket; double openPrice, lotSize; int type; };
PositionInfo buyPositions[], sellPositions[];

int MagicNumber = 0;
double referencePrice = 0, lastBuyLevel = 0, lastSellLevel = 0;
double lowestBuyLevel = 0, highestSellLevel = 0;
double sessionStartBalance = 0, sessionProfit = 0, sessionProfitTarget = 0;
double pointValue, tickValue, tickSize, minLot, maxLot, lotStep;
double normalizedLotSize = 0, currentGapSize = 0;
int digits = 0, currentDay = 0, lastTotalPositions = 0;
bool sessionTargetReached = false, needsRebuild = false, isPaused = false, panelVisible = true;
string panelPrefix = "MRP_";

//+------------------------------------------------------------------+
//| INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   MagicNumber = (BaseMagicNumber * 10000) + (int)(ChartID() % 10000);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, false);
   
   sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
   MqlDateTime time; TimeToStruct(TimeCurrent(), time); currentDay = time.day;
   
   if(!InitSymbolProps()) return INIT_FAILED;
   
   referencePrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   currentGapSize = referencePrice * (GridSpacingPercent / 100.0);
   normalizedLotSize = NormalizeLot(LotSize);
   
   Print("╔═══════════════════════════════════════════╗");
   Print("║  TORAMA MEAN REVERSION GRID v1.0         ║");
   Print("╚═══════════════════════════════════════════╝");
   Print("Chart ID: ", ChartID(), " | Magic: ", MagicNumber);
   Print("Symbol: ", _Symbol, " | Ref Price: ", DoubleToString(referencePrice, digits));
   Print("Gap: ", GridSpacingPercent, "% = $", DoubleToString(currentGapSize, 2));
   Print("Lot: ", DoubleToString(normalizedLotSize, 2), " | TP: $", IndividualTPDollars);
   Print("Session Target: ", SessionProfitPercent, "% = $", DoubleToString(sessionProfitTarget, 2));
   Print("═══════════════════════════════════════════");
   Print("📉 MEAN REVERSION MODE");
   Print("Strategy: SELL rising prices, BUY falling prices");
   Print("Logic: Expect price to revert to reference");
   
   SyncPositions();
   if(ShowPanel) CreatePanel();
   Print("✅ EA initialized successfully!");
   
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { if(ShowPanel) ObjectsDeleteAll(0, panelPrefix); }

//+------------------------------------------------------------------+
//| TICK HANDLER                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   if(ShowPanel && panelVisible) UpdatePanel();
   
   if(ResetSessionDaily) {
      MqlDateTime time; TimeToStruct(TimeCurrent(), time);
      if(time.day != currentDay) {
         currentDay = time.day;
         sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
         sessionProfit = 0; sessionTargetReached = false;
         Print("🔄 Daily reset | Target: $", DoubleToString(sessionProfitTarget, 2));
      }
   }
   
   if(isPaused || sessionTargetReached) return;
   
   // Grid rebuild logic
   int buyCount = ArraySize(buyPositions);
   int sellCount = ArraySize(sellPositions);
   int currentTotal = buyCount + sellCount;
   
   static int lastBuyCount = 0;
   static int lastSellCount = 0;
   
   if(currentTotal == 0 && lastTotalPositions > 0) needsRebuild = true;
   if(buyCount == 0 && lastBuyCount > 0) needsRebuild = true;
   if(sellCount == 0 && lastSellCount > 0) needsRebuild = true;
   
   if(needsRebuild) { RebuildGrid(); needsRebuild = false; }
   
   lastTotalPositions = currentTotal;
   lastBuyCount = buyCount;
   lastSellCount = sellCount;
   
   SyncPositions();
   
   double currentProfit = CalcTotalProfit();
   sessionProfit = AccountInfoDouble(ACCOUNT_BALANCE) - sessionStartBalance;
   
   if((sessionProfit / sessionStartBalance) * 100.0 < -MaxDrawdownPercent) {
      Print("🚨 EMERGENCY STOP: Drawdown limit");
      CloseAllPositions(); isPaused = true; return;
   }
   
   if(sessionProfit >= sessionProfitTarget) {
      Print("🎯 SESSION TARGET REACHED! $", DoubleToString(sessionProfit, 2));
      CloseAllPositions(); sessionTargetReached = true; return;
   }
   
   if(GlobalTPDollars > 0 && currentProfit >= GlobalTPDollars) {
      Print("💰 GLOBAL TP HIT! $", DoubleToString(currentProfit, 2));
      CloseAllPositions(); return;
   }
   
   if(GlobalSLDollars > 0 && currentProfit <= -GlobalSLDollars) {
      Print("🛑 GLOBAL SL HIT! $", DoubleToString(currentProfit, 2));
      CloseAllPositions(); return;
   }
   
   CheckProfitablePositions();
   
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpread) return;
   
   CheckMeanReversionSignals();
}

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS                                                  |
//+------------------------------------------------------------------+
bool InitSymbolProps()
{
   digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(pointValue == 0 || tickValue == 0 || tickSize == 0) {
      Print("❌ ERROR: Invalid symbol properties"); return false;
   }
   return true;
}

double NormalizeLot(double lots)
{
   double normalized = MathRound(lots / lotStep) * lotStep;
   if(normalized < minLot) normalized = minLot;
   if(normalized > maxLot) normalized = maxLot;
   return normalized;
}

void SyncPositions()
{
   ArrayResize(buyPositions, 0); ArrayResize(sellPositions, 0);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || 
         PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      PositionInfo pos;
      pos.ticket = ticket;
      pos.openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      pos.lotSize = PositionGetDouble(POSITION_VOLUME);
      pos.type = (int)PositionGetInteger(POSITION_TYPE);
      
      int size = (pos.type == POSITION_TYPE_BUY) ? ArraySize(buyPositions) : ArraySize(sellPositions);
      if(pos.type == POSITION_TYPE_BUY) {
         ArrayResize(buyPositions, size + 1); buyPositions[size] = pos;
      } else {
         ArrayResize(sellPositions, size + 1); sellPositions[size] = pos;
      }
   }
}

//+------------------------------------------------------------------+
//| MEAN REVERSION SIGNALS - OPPOSITE OF MOMENTUM                    |
//+------------------------------------------------------------------+
void CheckMeanReversionSignals()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0 || currentGapSize <= 0) return;
   
   double currentPrice = (ask + bid) / 2.0;
   
   // MEAN REVERSION: SELL when price rises (expect it to fall back)
   if(currentPrice > referencePrice) {
      double nextLevel = (lastSellLevel == 0) ? referencePrice + currentGapSize : lastSellLevel + currentGapSize;
      if(currentPrice >= nextLevel && ArraySize(sellPositions) < MaxPositionsPerSide) {
         if(OpenPosition(ORDER_TYPE_SELL, bid)) {
            lastSellLevel = nextLevel;
            if(nextLevel > highestSellLevel) highestSellLevel = nextLevel;
            Print("📉 SELL (mean reversion) #", ArraySize(sellPositions), " @ ", DoubleToString(bid, digits));
            Print("   Logic: Price rising → SELL expecting reversion");
         }
      }
   }
   
   // MEAN REVERSION: BUY when price falls (expect it to rise back)
   if(currentPrice < referencePrice) {
      double nextLevel = (lastBuyLevel == 0) ? referencePrice - currentGapSize : lastBuyLevel - currentGapSize;
      if(currentPrice <= nextLevel && ArraySize(buyPositions) < MaxPositionsPerSide) {
         if(OpenPosition(ORDER_TYPE_BUY, ask)) {
            lastBuyLevel = nextLevel;
            if(nextLevel < lowestBuyLevel || lowestBuyLevel == 0) lowestBuyLevel = nextLevel;
            Print("📈 BUY (mean reversion) #", ArraySize(buyPositions), " @ ", DoubleToString(ask, digits));
            Print("   Logic: Price falling → BUY expecting reversion");
         }
      }
   }
}

bool OpenPosition(ENUM_ORDER_TYPE type, double price)
{
   MqlTradeRequest request = {}; MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = normalizedLotSize;
   request.type = type;
   request.price = price;
   request.deviation = 50;
   request.magic = MagicNumber;
   request.comment = "ToramaMeanRev";
   
   if(IndividualTPDollars > 0) {
      double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      if(contractSize <= 1.0) {
         double tvPerLot = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         if(ts > 0) contractSize = tvPerLot / ts;
      }
      double tpDist = IndividualTPDollars / (normalizedLotSize * contractSize);
      request.tp = NormalizeDouble((type == ORDER_TYPE_BUY) ? price + tpDist : price - tpDist, digits);
   }
   
   if(IndividualSLDollars > 0) {
      double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      if(contractSize <= 1.0) {
         double tvPerLot = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         if(ts > 0) contractSize = tvPerLot / ts;
      }
      double slDist = IndividualSLDollars / (normalizedLotSize * contractSize);
      request.sl = NormalizeDouble((type == ORDER_TYPE_BUY) ? price - slDist : price + slDist, digits);
   }
   
   return (OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE);
}

void CheckProfitablePositions()
{
   if(ProfitableCountToClose <= 0) return;
   
   int profitBuys = 0, profitSells = 0;
   
   for(int i = 0; i < ArraySize(buyPositions); i++)
      if(PositionSelectByTicket(buyPositions[i].ticket) && PositionGetDouble(POSITION_PROFIT) > 0)
         profitBuys++;
   
   for(int i = 0; i < ArraySize(sellPositions); i++)
      if(PositionSelectByTicket(sellPositions[i].ticket) && PositionGetDouble(POSITION_PROFIT) > 0)
         profitSells++;
   
   if(profitBuys >= ProfitableCountToClose && ArraySize(buyPositions) > 0) {
      Print("🎯 ", profitBuys, " BUY positions profitable - closing profitable only");
      if(CloseBothSidesOnProfit) CloseAllPositions();
      else CloseProfitablePositionsOnly(POSITION_TYPE_BUY);
   }
   
   if(profitSells >= ProfitableCountToClose && ArraySize(sellPositions) > 0) {
      Print("🎯 ", profitSells, " SELL positions profitable - closing profitable only");
      if(CloseBothSidesOnProfit) CloseAllPositions();
      else CloseProfitablePositionsOnly(POSITION_TYPE_SELL);
   }
}

double CalcTotalProfit()
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return total;
}

void CloseAllPositions()
{
   Print("🔴 Closing all positions...");
   int closed = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || 
         PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action = TRADE_ACTION_DEAL;
      req.position = ticket;
      req.symbol = _Symbol;
      req.volume = PositionGetDouble(POSITION_VOLUME);
      req.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price = (req.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      req.deviation = 50;
      req.magic = MagicNumber;
      
      if(OrderSend(req, res)) closed++;
   }
   
   Print("✅ Closed ", closed, " positions");
   needsRebuild = true;
}

void ClosePositionsSide(ENUM_POSITION_TYPE targetType)
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || 
         PositionGetInteger(POSITION_MAGIC) != MagicNumber || 
         PositionGetInteger(POSITION_TYPE) != targetType) continue;
      
      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action = TRADE_ACTION_DEAL;
      req.position = ticket;
      req.symbol = _Symbol;
      req.volume = PositionGetDouble(POSITION_VOLUME);
      req.type = (targetType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price = (req.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      req.deviation = 50;
      req.magic = MagicNumber;
      
      if(OrderSend(req, res)) closed++;
   }
   Print("✅ Closed ", closed, " ", (targetType == POSITION_TYPE_BUY ? "BUY" : "SELL"), " positions");
}

void CloseProfitablePositionsOnly(ENUM_POSITION_TYPE targetType)
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || 
         PositionGetInteger(POSITION_MAGIC) != MagicNumber || 
         PositionGetInteger(POSITION_TYPE) != targetType) continue;
      
      if(PositionGetDouble(POSITION_PROFIT) <= 0) continue;
      
      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action = TRADE_ACTION_DEAL;
      req.position = ticket;
      req.symbol = _Symbol;
      req.volume = PositionGetDouble(POSITION_VOLUME);
      req.type = (targetType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price = (req.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      req.deviation = 50;
      req.magic = MagicNumber;
      
      if(OrderSend(req, res)) closed++;
   }
   Print("✅ Closed ", closed, " profitable ", (targetType == POSITION_TYPE_BUY ? "BUY" : "SELL"), " positions");
}

void RebuildGrid()
{
   Print("🔄 REBUILDING GRID...");
   ArrayResize(buyPositions, 0); ArrayResize(sellPositions, 0);
   lastBuyLevel = 0; lastSellLevel = 0;
   lowestBuyLevel = 0; highestSellLevel = 0;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) { Print("❌ Invalid prices"); return; }
   
   referencePrice = (ask + bid) / 2.0;
   currentGapSize = referencePrice * (GridSpacingPercent / 100.0);
   if(currentGapSize <= 0) currentGapSize = referencePrice * 0.001;
   
   Print("✅ Grid rebuilt | Ref: ", DoubleToString(referencePrice, digits), " | Gap: $", DoubleToString(currentGapSize, 2));
}

//+------------------------------------------------------------------+
//| PANEL FUNCTIONS                                                   |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 10, y = 20, w = 280, h = 420;
   color bg = C'20,20,25', txt = clrWhite, hdr = C'255,150,0';  // Orange for mean reversion
   
   ObjectCreate(0, panelPrefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XSIZE, w);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YSIZE, h);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_COLOR, hdr);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_ZORDER, 0);
   
   int cy = y + 10;
   
   CreateLbl("H", "══ TORAMA MEAN REVERSION ══", x + 10, cy, hdr, 9, "Arial Bold"); cy += 23;
   CreateLbl("M", "Magic: " + IntegerToString(MagicNumber), x + 10, cy, txt, 8); cy += 18;
   CreateLbl("S", "Status: ACTIVE", x + 10, cy, clrLime, 8); cy += 21;
   CreateLbl("L1", "─────────────────────────────────", x + 10, cy, C'50,50,50', 8); cy += 18;
   CreateLbl("GI", "GRID INFORMATION", x + 10, cy, hdr, 8, "Arial Bold"); cy += 18;
   CreateLbl("R", "Reference: 0.00000", x + 10, cy, txt, 8); cy += 18;
   CreateLbl("G", "Gap: $0.00", x + 10, cy, txt, 8); cy += 18;
   CreateLbl("NB", "Next BUY: $0.00", x + 10, cy, clrDodgerBlue, 8); cy += 18;
   CreateLbl("NS", "Next SELL: $0.00", x + 10, cy, clrOrangeRed, 8); cy += 18;
   CreateLbl("BC", "BUY: 0 / " + IntegerToString(MaxPositionsPerSide), x + 10, cy, clrDodgerBlue, 8); cy += 18;
   CreateLbl("SC", "SELL: 0 / " + IntegerToString(MaxPositionsPerSide), x + 10, cy, clrOrangeRed, 8); cy += 21;
   CreateLbl("L2", "─────────────────────────────────", x + 10, cy, C'50,50,50', 8); cy += 18;
   CreateLbl("PI", "PROFIT & RISK", x + 10, cy, hdr, 8, "Arial Bold"); cy += 18;
   CreateLbl("BP", "BUY P&L: $0.00", x + 10, cy, txt, 8); cy += 18;
   CreateLbl("SP", "SELL P&L: $0.00", x + 10, cy, txt, 8); cy += 18;
   CreateLbl("TP", "Total P&L: $0.00", x + 10, cy, txt, 8, "Arial Bold"); cy += 18;
   CreateLbl("SS", "Session: $0 / $0", x + 10, cy, txt, 8); cy += 21;
   CreateLbl("L3", "─────────────────────────────────", x + 10, cy, C'50,50,50', 8); cy += 18;
   CreateLbl("CT", "CONTROLS", x + 10, cy, hdr, 8, "Arial Bold"); cy += 21;
   
   CreateBtn("CBB", "Close BUY", x + 10, cy, 80, 25, clrDodgerBlue);
   CreateBtn("CSB", "Close SELL", x + 95, cy, 80, 25, clrOrangeRed);
   CreateBtn("CAB", "Close ALL", x + 180, cy, 90, 25, clrRed); cy += 30;
   CreateBtn("RB", "Rebuild", x + 10, cy, 130, 25, clrGold);
   CreateBtn("PB", "Pause", x + 145, cy, 125, 25, clrOrange); cy += 30;
   CreateLbl("F", "Press 'H' to hide panel", x + 10, cy, C'100,100,100', 7);
   
   ChartRedraw(0);
}

void CreateLbl(string id, string text, int x, int y, color clr, int size = 8, string font = "Arial")
{
   string name = panelPrefix + id;
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1);
}

void CreateBtn(string id, string text, int x, int y, int w, int h, color clr)
{
   string name = panelPrefix + id;
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1);
}

void UpdatePanel()
{
   if(!panelVisible) return;
   
   string status = isPaused ? "PAUSED" : (sessionTargetReached ? "TARGET REACHED" : "ACTIVE");
   color sClr = isPaused ? clrOrange : (sessionTargetReached ? clrGold : clrLime);
   ObjectSetString(0, panelPrefix + "S", OBJPROP_TEXT, "Status: " + status);
   ObjectSetInteger(0, panelPrefix + "S", OBJPROP_COLOR, sClr);
   
   ObjectSetString(0, panelPrefix + "R", OBJPROP_TEXT, "Reference: " + DoubleToString(referencePrice, digits));
   ObjectSetString(0, panelPrefix + "G", OBJPROP_TEXT, "Gap: $" + DoubleToString(currentGapSize, 2));
   
   // Calculate next levels
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double nextBuyLevel = 0;
   double nextSellLevel = 0;
   
   // Mean Reversion: BUY below reference, SELL above reference
   if(currentPrice < referencePrice) {
      // Price falling - next BUY level
      nextBuyLevel = (lastBuyLevel == 0) ? referencePrice - currentGapSize : lastBuyLevel - currentGapSize;
   } else {
      // Price at or above reference - show first BUY level below
      nextBuyLevel = (lastBuyLevel == 0) ? referencePrice - currentGapSize : lastBuyLevel;
   }
   
   if(currentPrice > referencePrice) {
      // Price rising - next SELL level
      nextSellLevel = (lastSellLevel == 0) ? referencePrice + currentGapSize : lastSellLevel + currentGapSize;
   } else {
      // Price at or below reference - show first SELL level above
      nextSellLevel = (lastSellLevel == 0) ? referencePrice + currentGapSize : lastSellLevel;
   }
   
   ObjectSetString(0, panelPrefix + "NB", OBJPROP_TEXT, "Next BUY: $" + DoubleToString(nextBuyLevel, digits));
   ObjectSetString(0, panelPrefix + "NS", OBJPROP_TEXT, "Next SELL: $" + DoubleToString(nextSellLevel, digits));
   
   int bc = ArraySize(buyPositions), sc = ArraySize(sellPositions);
   ObjectSetString(0, panelPrefix + "BC", OBJPROP_TEXT, "BUY: " + IntegerToString(bc) + " / " + IntegerToString(MaxPositionsPerSide));
   ObjectSetString(0, panelPrefix + "SC", OBJPROP_TEXT, "SELL: " + IntegerToString(sc) + " / " + IntegerToString(MaxPositionsPerSide));
   
   double bp = 0, sp = 0;
   for(int i = 0; i < bc; i++)
      if(PositionSelectByTicket(buyPositions[i].ticket))
         bp += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   
   for(int i = 0; i < sc; i++)
      if(PositionSelectByTicket(sellPositions[i].ticket))
         sp += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   
   double tp = bp + sp;
   
   ObjectSetString(0, panelPrefix + "BP", OBJPROP_TEXT, "BUY P&L: $" + DoubleToString(bp, 2));
   ObjectSetInteger(0, panelPrefix + "BP", OBJPROP_COLOR, bp > 0 ? clrLime : (bp < 0 ? clrRed : clrWhite));
   
   ObjectSetString(0, panelPrefix + "SP", OBJPROP_TEXT, "SELL P&L: $" + DoubleToString(sp, 2));
   ObjectSetInteger(0, panelPrefix + "SP", OBJPROP_COLOR, sp > 0 ? clrLime : (sp < 0 ? clrRed : clrWhite));
   
   ObjectSetString(0, panelPrefix + "TP", OBJPROP_TEXT, "Total P&L: $" + DoubleToString(tp, 2));
   ObjectSetInteger(0, panelPrefix + "TP", OBJPROP_COLOR, tp > 0 ? clrLime : (tp < 0 ? clrRed : clrWhite));
   
   ObjectSetString(0, panelPrefix + "SS", OBJPROP_TEXT, "Session: $" + DoubleToString(sessionProfit, 2) + " / $" + DoubleToString(sessionProfitTarget, 2));
   ObjectSetInteger(0, panelPrefix + "SS", OBJPROP_COLOR, sessionProfit > 0 ? clrLime : (sessionProfit < 0 ? clrRed : clrWhite));
}

//+------------------------------------------------------------------+
//| EVENT HANDLER                                                     |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_KEYDOWN && (lparam == 72 || lparam == 104)) {
      panelVisible = !panelVisible;
      for(int i = ObjectsTotal(0) - 1; i >= 0; i--) {
         string name = ObjectName(0, i);
         if(StringFind(name, panelPrefix) == 0)
            ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, panelVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
      }
      ChartRedraw(0);
      Print(panelVisible ? "📊 Panel shown" : "👁 Panel hidden");
   }
   
   if(id == CHARTEVENT_OBJECT_CLICK) {
      if(sparam == panelPrefix + "CBB") { ClosePositionsSide(POSITION_TYPE_BUY); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); }
      else if(sparam == panelPrefix + "CSB") { ClosePositionsSide(POSITION_TYPE_SELL); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); }
      else if(sparam == panelPrefix + "CAB") { CloseAllPositions(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); }
      else if(sparam == panelPrefix + "RB") { RebuildGrid(); ObjectSetInteger(0, sparam, OBJPROP_STATE, false); }
      else if(sparam == panelPrefix + "PB") {
         isPaused = !isPaused;
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         Print(isPaused ? "⏸ PAUSED" : "▶ RESUMED");
      }
      UpdatePanel();
   }
}
//+------------------------------------------------------------------+
