//+------------------------------------------------------------------+
//|                                      TORAMA_Momentum_Grid_v1_2.mq5 |
//|                                      Copyright 2025, TORAMA CAPITAL |
//|                                               https://torama.money |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "1.80"
#property description "Momentum Grid EA - BUYONLY/SELLONLY direction control"
#property description "Cycle tracking & auto-pause | Chart-based magic"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "=== GRID SETTINGS ==="
input double   GridSpacingPercent = 0.30;
input int      MaxPositionsPerSide = 30;
input double   LotSize = 0.01;

input group "=== TRADING DIRECTION ==="
input string   TradingDirection = "BOTH";        // Trading direction: BOTH, BUYONLY, SELLONLY

input group "=== PROFIT TARGETS (Dollars) ==="
input double   IndividualTPDollars = 50.0;
input double   IndividualSLDollars = 0.0;
input double   GlobalTPDollars = 200.0;
input double   GlobalSLDollars = 0.0;

input group "=== MOMENTUM LOGIC ==="
input int      ProfitableCountToClose = 5;       // Close profitable when X positions profitable
input bool     CloseBothSidesOnProfit = false;   // Close ALL positions when trigger reached
input int      MaxConsecutiveCycles = 5;         // Max consecutive cycles before pausing that direction

input group "=== RISK MANAGEMENT ==="
input double   SessionProfitPercent = 200.0;
input bool     ResetSessionDaily = true;
input double   MaxDrawdownPercent = 15.0;

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;
input int      BaseMagicNumber = 77740;
input bool     ShowPanel = true;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
struct PositionInfo { ulong ticket; double openPrice, lotSize; int type; };
PositionInfo buyPositions[], sellPositions[];

int MagicNumber = 0;
double referencePrice = 0, lastBuyLevel = 0, lastSellLevel = 0;
double sessionStartBalance = 0, sessionProfit = 0, sessionProfitTarget = 0;
double pointValue, tickValue, tickSize, minLot, maxLot, lotStep;
double normalizedLotSize = 0, currentGapSize = 0;
int digits = 0, currentDay = 0, lastTotalPositions = 0;
bool sessionTargetReached = false, needsRebuild = false, isPaused = false, panelVisible = true;
string panelPrefix = "MP_";

// Cycle tracking variables
int consecutiveBuyCycles = 0;      // Count of consecutive BUY cycles
int consecutiveSellCycles = 0;     // Count of consecutive SELL cycles
bool buyDirectionPaused = false;   // BUY direction paused flag
bool sellDirectionPaused = false;  // SELL direction paused flag

//+------------------------------------------------------------------+
//| INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   MagicNumber = (BaseMagicNumber * 10000) + (int)(ChartID() % 10000);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, false);
   
   // Initialize session
   sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
   MqlDateTime time; TimeToStruct(TimeCurrent(), time); currentDay = time.day;
   
   // Get symbol properties
   if(!InitSymbolProps()) return INIT_FAILED;
   
   referencePrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   currentGapSize = referencePrice * (GridSpacingPercent / 100.0);
   normalizedLotSize = NormalizeLot(LotSize);
   
   // Validate and normalize trading direction
   string dir = TradingDirection;
   StringToUpper(dir);
   if(dir != "BOTH" && dir != "BUYONLY" && dir != "SELLONLY") {
      Print("⚠️ WARNING: Invalid TradingDirection '", TradingDirection, "' - using BOTH");
      dir = "BOTH";
   }
   
   // Print startup info
   Print("╔═══════════════════════════════════════════╗");
   Print("║  TORAMA MOMENTUM GRID v1.7               ║");
   Print("╚═══════════════════════════════════════════╝");
   Print("Chart ID: ", ChartID(), " | Magic: ", MagicNumber);
   Print("Symbol: ", _Symbol, " | Ref Price: ", DoubleToString(referencePrice, digits));
   Print("Gap: ", GridSpacingPercent, "% = $", DoubleToString(currentGapSize, 2));
   Print("Lot: ", DoubleToString(normalizedLotSize, 2), " | TP: $", IndividualTPDollars);
   Print("Direction: ", dir, " | Max Cycles: ", MaxConsecutiveCycles);
   Print("Session Target: ", SessionProfitPercent, "% = $", DoubleToString(sessionProfitTarget, 2));
   Print("═══════════════════════════════════════════");
   
   SyncPositions();
   if(ShowPanel) CreatePanel();
   Print("✅ EA initialized successfully!");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) { if(ShowPanel) ObjectsDeleteAll(0, panelPrefix); }

//+------------------------------------------------------------------+
//| TICK HANDLER                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   if(ShowPanel && panelVisible) UpdatePanel();
   
   // Daily reset check
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
   
   // Grid rebuild logic - check if either side fully closed
   int buyCount = ArraySize(buyPositions);
   int sellCount = ArraySize(sellPositions);
   int currentTotal = buyCount + sellCount;
   
   // Rebuild if all positions closed OR if one side went from positions to zero
   static int lastBuyCount = 0;
   static int lastSellCount = 0;
   
   if(currentTotal == 0 && lastTotalPositions > 0) needsRebuild = true;
   
   // BUY side cleared - count as cycle and check pause
   if(buyCount == 0 && lastBuyCount > 0) {
      needsRebuild = true;
      consecutiveBuyCycles++;
      consecutiveSellCycles = 0;  // Reset SELL counter
      Print("🔄 BUY Cycle #", consecutiveBuyCycles, " completed");
      
      if(consecutiveBuyCycles >= MaxConsecutiveCycles) {
         buyDirectionPaused = true;
         Print("⏸ BUY direction PAUSED after ", MaxConsecutiveCycles, " consecutive cycles");
         Print("💡 Manual intervention required: Click 'Resume BUY' button");
      }
   }
   
   // SELL side cleared - count as cycle and check pause
   if(sellCount == 0 && lastSellCount > 0) {
      needsRebuild = true;
      consecutiveSellCycles++;
      consecutiveBuyCycles = 0;  // Reset BUY counter
      Print("🔄 SELL Cycle #", consecutiveSellCycles, " completed");
      
      if(consecutiveSellCycles >= MaxConsecutiveCycles) {
         sellDirectionPaused = true;
         Print("⏸ SELL direction PAUSED after ", MaxConsecutiveCycles, " consecutive cycles");
         Print("💡 Manual intervention required: Click 'Resume SELL' button");
      }
   }
   
   if(needsRebuild) { RebuildGrid(); needsRebuild = false; }
   
   lastTotalPositions = currentTotal;
   lastBuyCount = buyCount;
   lastSellCount = sellCount;
   
   SyncPositions();
   
   double currentProfit = CalcTotalProfit();
   sessionProfit = AccountInfoDouble(ACCOUNT_BALANCE) - sessionStartBalance;
   
   // Risk checks
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
   
   CheckMomentumSignals();
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

void CheckMomentumSignals()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0 || currentGapSize <= 0) return;
   
   double currentPrice = (ask + bid) / 2.0;
   
   // Normalize direction string
   string dir = TradingDirection;
   StringToUpper(dir);
   
   // BUY momentum (only if not paused and direction allows)
   if(currentPrice > referencePrice && !buyDirectionPaused && (dir == "BOTH" || dir == "BUYONLY")) {
      double nextLevel = (lastBuyLevel == 0) ? referencePrice + currentGapSize : lastBuyLevel + currentGapSize;
      if(currentPrice >= nextLevel && ArraySize(buyPositions) < MaxPositionsPerSide) {
         if(OpenPosition(ORDER_TYPE_BUY, ask)) {
            lastBuyLevel = nextLevel;
            Print("📈 BUY #", ArraySize(buyPositions), " @ ", DoubleToString(ask, digits));
         }
      }
   }
   
   // SELL momentum (only if not paused and direction allows)
   if(currentPrice < referencePrice && !sellDirectionPaused && (dir == "BOTH" || dir == "SELLONLY")) {
      double nextLevel = (lastSellLevel == 0) ? referencePrice - currentGapSize : lastSellLevel - currentGapSize;
      if(currentPrice <= nextLevel && ArraySize(sellPositions) < MaxPositionsPerSide) {
         if(OpenPosition(ORDER_TYPE_SELL, bid)) {
            lastSellLevel = nextLevel;
            Print("📉 SELL #", ArraySize(sellPositions), " @ ", DoubleToString(bid, digits));
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
   request.comment = "ToramaMomentum";
   
   if(IndividualTPDollars > 0) {
      // Get contract size - but some brokers return 1 instead of actual size
      double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      
      // If contractSize is 1 or invalid, calculate from tick value
      // For gold: tickValue = $10 per lot per $1 move
      // contractSize = tickValue / tickSize
      if(contractSize <= 1.0) {
         double tvPerLot = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         if(ts > 0) contractSize = tvPerLot / ts;
      }
      
      // Calculate price distance for target profit
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
      
      // Only close if position is profitable
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
   int x = 10, y = 20, w = 280, h = 430;  // Increased for taller buttons
   color bg = C'20,20,25', txt = clrWhite, hdr = C'0,150,255';
   
   // Solid background with border
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
   
   int cy = y + 8;
   
   CreateLbl("H", "═══ TORAMA MOMENTUM GRID ═══", x + 10, cy, hdr, 10, "Arial Bold"); cy += 22;  // Increased from 9 to 10
   CreateLbl("M", "Magic: " + IntegerToString(MagicNumber), x + 10, cy, txt, 8);  // Increased from 7 to 8
   CreateLbl("S", "Status: ACTIVE", x + 150, cy, clrLime, 8); cy += 18;  // Increased from 7 to 8
   
   CreateLbl("L1", "─────────────────────────────────", x + 10, cy, C'50,50,50', 8); cy += 15;  // Increased spacing
   CreateLbl("GI", "GRID INFO", x + 10, cy, hdr, 9, "Arial Bold"); cy += 18;  // Increased from 8 to 9
   CreateLbl("R", "Ref: 0.00", x + 10, cy, txt, 8);  // Increased from 7 to 8
   CreateLbl("G", "Gap: $0.00", x + 150, cy, txt, 8); cy += 18;  // Increased from 7 to 8
   CreateLbl("NB", "Next BUY: $0.00", x + 10, cy, clrDodgerBlue, 8); cy += 18;  // Increased from 7 to 8
   CreateLbl("NS", "Next SELL: $0.00", x + 10, cy, clrOrangeRed, 8); cy += 18;  // Increased from 7 to 8
   CreateLbl("BC", "BUY: 0/30", x + 10, cy, clrDodgerBlue, 8);  // Increased from 7 to 8
   CreateLbl("SC", "SELL: 0/30", x + 150, cy, clrOrangeRed, 8); cy += 18;  // Increased from 7 to 8
   
   // Cycle tracking display
   CreateLbl("CC", "Cycles: B:0/5  S:0/5", x + 10, cy, clrGold, 8); cy += 18;
   
   CreateLbl("L2", "─────────────────────────────────", x + 10, cy, C'50,50,50', 8); cy += 15;
   CreateLbl("PI", "P&L", x + 10, cy, hdr, 9, "Arial Bold"); cy += 18;  // Increased from 8 to 9
   CreateLbl("BP", "BUY: $0.00", x + 10, cy, txt, 8);  // Increased from 7 to 8
   CreateLbl("SP", "SELL: $0.00", x + 150, cy, txt, 8); cy += 18;  // Increased from 7 to 8
   CreateLbl("TP", "Total: $0.00", x + 10, cy, txt, 9, "Arial Bold"); cy += 18;  // Increased from 7 to 9
   CreateLbl("SS", "Session: $0/$0", x + 10, cy, txt, 8); cy += 18;  // Increased from 7 to 8
   
   CreateLbl("L3", "─────────────────────────────────", x + 10, cy, C'50,50,50', 8); cy += 15;
   CreateLbl("CT", "CONTROLS", x + 10, cy, hdr, 9, "Arial Bold"); cy += 20;  // Increased from 8 to 9
   
   CreateBtn("CBB", "BUY", x + 10, cy, 60, 26, C'30,120,220');  // Darker blue, taller button
   CreateBtn("CSB", "SELL", x + 75, cy, 60, 26, C'220,50,50');  // Darker red
   CreateBtn("CAB", "ALL", x + 140, cy, 60, 26, C'180,30,30');  // Dark red
   CreateBtn("RB", "Rebuild", x + 205, cy, 65, 26, C'200,160,0'); cy += 30;  // Darker gold
   CreateBtn("RBB", "Resume BUY", x + 10, cy, 125, 26, C'30,120,220');  // Darker blue
   CreateBtn("RSB", "Resume SELL", x + 140, cy, 130, 26, C'220,50,50'); cy += 30;  // Darker red
   CreateBtn("PB", "Pause/Resume", x + 10, cy, 260, 26, C'220,130,0'); cy += 30;  // Darker orange
   CreateLbl("F", "Press 'H' to hide", x + 10, cy, C'100,100,100', 8);  // Increased from 7 to 8
   
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
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);  // White text for contrast
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'80,80,85');  // Subtle border
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);  // Increased from 9 to 10
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Black");  // Bolder font for visibility
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
   
   ObjectSetString(0, panelPrefix + "R", OBJPROP_TEXT, "Ref: " + DoubleToString(referencePrice, digits));
   ObjectSetString(0, panelPrefix + "G", OBJPROP_TEXT, "Gap: $" + DoubleToString(currentGapSize, 2));
   
   // Calculate next levels
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double nextBuyLevel = 0;
   double nextSellLevel = 0;
   
   // Momentum: BUY above reference, SELL below reference
   if(currentPrice > referencePrice) {
      // Price rising - next BUY level
      nextBuyLevel = (lastBuyLevel == 0) ? referencePrice + currentGapSize : lastBuyLevel + currentGapSize;
   } else {
      // Price at or below reference - show first BUY level above
      nextBuyLevel = (lastBuyLevel == 0) ? referencePrice + currentGapSize : lastBuyLevel;
   }
   
   if(currentPrice < referencePrice) {
      // Price falling - next SELL level
      nextSellLevel = (lastSellLevel == 0) ? referencePrice - currentGapSize : lastSellLevel - currentGapSize;
   } else {
      // Price at or above reference - show first SELL level below
      nextSellLevel = (lastSellLevel == 0) ? referencePrice - currentGapSize : lastSellLevel;
   }
   
   ObjectSetString(0, panelPrefix + "NB", OBJPROP_TEXT, "Next BUY: $" + DoubleToString(nextBuyLevel, digits));
   ObjectSetString(0, panelPrefix + "NS", OBJPROP_TEXT, "Next SELL: $" + DoubleToString(nextSellLevel, digits));
   
   int bc = ArraySize(buyPositions), sc = ArraySize(sellPositions);
   ObjectSetString(0, panelPrefix + "BC", OBJPROP_TEXT, "BUY: " + IntegerToString(bc) + "/" + IntegerToString(MaxPositionsPerSide));
   ObjectSetString(0, panelPrefix + "SC", OBJPROP_TEXT, "SELL: " + IntegerToString(sc) + "/" + IntegerToString(MaxPositionsPerSide));
   
   // Update cycle tracking display
   string cycleText = "Cycles: B:" + IntegerToString(consecutiveBuyCycles) + "/" + IntegerToString(MaxConsecutiveCycles);
   cycleText += "  S:" + IntegerToString(consecutiveSellCycles) + "/" + IntegerToString(MaxConsecutiveCycles);
   ObjectSetString(0, panelPrefix + "CC", OBJPROP_TEXT, cycleText);
   
   // Color code based on pause status
   color cycleColor = clrGold;
   if(buyDirectionPaused) cycleColor = clrOrangeRed;
   else if(sellDirectionPaused) cycleColor = clrOrangeRed;
   else if(consecutiveBuyCycles >= MaxConsecutiveCycles - 1 || consecutiveSellCycles >= MaxConsecutiveCycles - 1) 
      cycleColor = clrOrange;  // Warning color
   ObjectSetInteger(0, panelPrefix + "CC", OBJPROP_COLOR, cycleColor);
   
   double bp = 0, sp = 0;
   for(int i = 0; i < bc; i++)
      if(PositionSelectByTicket(buyPositions[i].ticket))
         bp += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   
   for(int i = 0; i < sc; i++)
      if(PositionSelectByTicket(sellPositions[i].ticket))
         sp += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   
   double tp = bp + sp;
   
   ObjectSetString(0, panelPrefix + "BP", OBJPROP_TEXT, "BUY: $" + DoubleToString(bp, 2));
   ObjectSetInteger(0, panelPrefix + "BP", OBJPROP_COLOR, bp > 0 ? clrLime : (bp < 0 ? clrRed : clrWhite));
   
   ObjectSetString(0, panelPrefix + "SP", OBJPROP_TEXT, "SELL: $" + DoubleToString(sp, 2));
   ObjectSetInteger(0, panelPrefix + "SP", OBJPROP_COLOR, sp > 0 ? clrLime : (sp < 0 ? clrRed : clrWhite));
   
   ObjectSetString(0, panelPrefix + "TP", OBJPROP_TEXT, "Total: $" + DoubleToString(tp, 2));
   ObjectSetInteger(0, panelPrefix + "TP", OBJPROP_COLOR, tp > 0 ? clrLime : (tp < 0 ? clrRed : clrWhite));
   
   ObjectSetString(0, panelPrefix + "SS", OBJPROP_TEXT, "Session: $" + DoubleToString(sessionProfit, 2) + "/$" + DoubleToString(sessionProfitTarget, 2));
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
      else if(sparam == panelPrefix + "RBB") {
         // Resume BUY direction
         buyDirectionPaused = false;
         consecutiveBuyCycles = 0;
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         Print("▶ BUY direction RESUMED - cycle counter reset");
      }
      else if(sparam == panelPrefix + "RSB") {
         // Resume SELL direction
         sellDirectionPaused = false;
         consecutiveSellCycles = 0;
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         Print("▶ SELL direction RESUMED - cycle counter reset");
      }
      else if(sparam == panelPrefix + "PB") {
         isPaused = !isPaused;
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
         Print(isPaused ? "⏸ PAUSED" : "▶ RESUMED");
      }
      UpdatePanel();
   }
}
//+------------------------------------------------------------------+
