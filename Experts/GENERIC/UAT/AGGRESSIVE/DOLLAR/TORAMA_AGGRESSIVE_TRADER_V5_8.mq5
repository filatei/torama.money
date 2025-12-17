//+------------------------------------------------------------------+
//|                    TORAMA Aggressive Trader EA v5.7              |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "5.8"
#property description "Aggressive Directional Grid Trader with ATR-Based Mode Switching"
#property description "V5.8: Optimized core + Professional panel library + Fixed warnings"

#include <ToramaPanel.mqh>

#define EA_VERSION "5.8"
#define EA_NAME "TORAMA AGGRESSIVE TRADER"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
enum ENUM_TRADE_DIRECTION { BUYONLY, SELLONLY };

input group "=== DIRECTION & ATR MODE SWITCHING ==="
input ENUM_TRADE_DIRECTION StartDirection = BUYONLY;
input bool     EnableATRSwitch = true;
input int      ATRPeriod = 14;
input double   ATRThresholdPercent = 70.0;
input bool     CloseOnModeSwitch = false;

input group "=== GRID SETTINGS ==="
input double   GridGapPercent = 0.01;
input int      MaxPositions = 100;
input double   LotSize = 0.2;

input group "=== TAKE PROFIT ==="
input double   IndividualTPDollars = 50.0;
input double   GroupTPDollars = 200.0;

input group "=== STOP LOSS ==="
input double   IndividualSLDollars = 100.0;

input group "=== RISK MANAGEMENT ==="
input double   MaxDrawdownPercent = 25.0;
input double   DailyTargetPercent = 100.0;

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;
input bool     ShowPanel = true;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
struct Position { ulong ticket; double entryPrice; datetime entryTime; };
Position positions[];

ENUM_TRADE_DIRECTION CurrentDirection;
int atrHandle = INVALID_HANDLE;
double dayOpenPrice = 0, currentATR = 0, referencePrice = 0, currentGapSize = 0;
double nextBuyLevel = 0, nextSellLevel = 0;
datetime lastDayOpenUpdate = 0, lastModeSwitchTime = 0, lastGridCheck = 0, lastDayCheck = 0;
int modeSwitchCooldownBars = 100, modeSwitchCount = 0, MagicNumber = 0, totalTrades = 0, currentDay = 0;
uint gridCheckIntervalMs = 100;

bool emergencyStop = false, isPaused = false, dailyTargetReached = false;
string emergencyReason = "";
double peakEquity = 0, totalProfit = 0, dailyStartBalance = 0, dailyProfit = 0, dailyTarget = 0;
double validatedLotSize = 0;

struct SymbolSpecs {
   double contractSize, tickValue, tickSize, point, minStopDistance;
   long stopLevel;
   int digits;
   double minLot, maxLot, lotStep;
};
SymbolSpecs specs;

CToramaPanel* panel = NULL;

//+------------------------------------------------------------------+
//| GENERATE CHART-BASED MAGIC NUMBER                                |
//+------------------------------------------------------------------+
int GenerateChartBasedMagicNumber() {
   long chartId = ChartID();
   string symbolStr = _Symbol;
   int symbolHash = 0;
   
   for(int i = 0; i < StringLen(symbolStr); i++)
      symbolHash = (symbolHash * 31 + StringGetCharacter(symbolStr, i)) % 1000000;
   
   int magic = (int)((chartId % 1000000) * 1000 + symbolHash) % 2147483647;
   if(magic == 0) magic = (int)(chartId % 2147483647);
   if(magic == 0) magic = 123456;
   
   return magic;
}

//+------------------------------------------------------------------+
//| INITIALIZE SYMBOL SPECS                                          |
//+------------------------------------------------------------------+
bool InitializeSymbolSpecs() {
   specs.contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   specs.tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   specs.tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   specs.point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   specs.stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   specs.digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   specs.minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   specs.maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   specs.lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   specs.minStopDistance = specs.stopLevel * specs.point;
   
   return (specs.contractSize > 0 && specs.tickValue > 0 && specs.tickSize > 0);
}

//+------------------------------------------------------------------+
//| VALIDATE LOT SIZE                                                |
//+------------------------------------------------------------------+
double ValidateLotSize(double lot) {
   lot = MathMax(lot, specs.minLot);
   lot = MathMin(lot, specs.maxLot);
   lot = MathRound(lot / specs.lotStep) * specs.lotStep;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| WAIT FOR INDICATOR                                               |
//+------------------------------------------------------------------+
bool WaitForIndicator(int handle) {
   for(int i = 0; i < 50; i++) {
      if(BarsCalculated(handle) > 0) return true;
      Sleep(100);
   }
   return false;
}

//+------------------------------------------------------------------+
//| UPDATE DAY OPEN PRICE                                            |
//+------------------------------------------------------------------+
void UpdateDayOpenPrice() {
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime todayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   
   if(lastDayOpenUpdate < todayStart) {
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(_Symbol, PERIOD_D1, 0, 1, rates);
      if(copied > 0) {
         dayOpenPrice = rates[0].open;
         lastDayOpenUpdate = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
//| CALCULATE GRID GAP IN DOLLARS                                    |
//+------------------------------------------------------------------+
double CalculateGridGapInDollars() {
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double dollarGap = currentPrice * (GridGapPercent / 100.0);
   return NormalizeDouble(dollarGap, specs.digits);
}

//+------------------------------------------------------------------+
//| CALCULATE GRID GAP IN PERCENT                                    |
//+------------------------------------------------------------------+
double CalculateGridGapInPercent() {
   return NormalizeDouble(GridGapPercent, 2);
}

//+------------------------------------------------------------------+
//| SCAN AND REBUILD POSITIONS                                       |
//+------------------------------------------------------------------+
void ScanAndRebuildPositions() {
   ArrayFree(positions);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         int size = ArraySize(positions);
         ArrayResize(positions, size + 1);
         positions[size].ticket = ticket;
         positions[size].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         positions[size].entryTime = (datetime)PositionGetInteger(POSITION_TIME);
      }
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                           |
//+------------------------------------------------------------------+
double CalculateTotalProfit() {
   totalProfit = 0;
   for(int i = 0; i < ArraySize(positions); i++) {
      if(PositionSelectByTicket(positions[i].ticket))
         totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return totalProfit;
}

//+------------------------------------------------------------------+
//| CHECK SPREAD                                                      |
//+------------------------------------------------------------------+
bool CheckSpread() {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= MaxSpread);
}

//+------------------------------------------------------------------+
//| ATR MODE SWITCHING LOGIC                                         |
//+------------------------------------------------------------------+
void CheckATRModeSwitch() {
   if(!EnableATRSwitch || atrHandle == INVALID_HANDLE) return;
   
   UpdateDayOpenPrice();
   
   double atr_buffer[];
   ArraySetAsSeries(atr_buffer, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atr_buffer) <= 0) return;
   
   currentATR = atr_buffer[0];
   if(currentATR <= 0) return;
   
   double threshold = currentATR * (ATRThresholdPercent / 100.0);
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double priceMove = currentPrice - dayOpenPrice;
   
   ENUM_TRADE_DIRECTION newDirection = CurrentDirection;
   
   if(priceMove > threshold) newDirection = SELLONLY;
   else if(priceMove < -threshold) newDirection = BUYONLY;
   
   if(newDirection != CurrentDirection) {
      int barsSinceSwitch = Bars(_Symbol, PERIOD_CURRENT) - (int)(lastModeSwitchTime > 0 ? 
         Bars(_Symbol, PERIOD_CURRENT, lastModeSwitchTime, TimeCurrent()) : 0);
      
      if(barsSinceSwitch >= modeSwitchCooldownBars) {
         Print("🔄 MODE SWITCH: ", CurrentDirection == BUYONLY ? "BUY" : "SELL", " → ", 
               newDirection == BUYONLY ? "BUY" : "SELL");
         
         CurrentDirection = newDirection;
         modeSwitchCount++;
         lastModeSwitchTime = TimeCurrent();
         
         if(CloseOnModeSwitch) {
            for(int i = 0; i < ArraySize(positions); i++) {
               if(PositionSelectByTicket(positions[i].ticket)) {
                  MqlTradeRequest request = {};
                  MqlTradeResult result = {};
                  request.action = TRADE_ACTION_DEAL;
                  request.position = positions[i].ticket;
                  request.symbol = _Symbol;
                  request.volume = PositionGetDouble(POSITION_VOLUME);
                  request.type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 
                                 ORDER_TYPE_SELL : ORDER_TYPE_BUY;
                  request.price = request.type == ORDER_TYPE_SELL ? 
                                  SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                  request.deviation = 10;
                  if(!OrderSend(request, result)) {
                     Print("Close position failed: ", result.retcode, " - ", result.comment);
                  }
               }
            }
            ScanAndRebuildPositions();
         }
         
         referencePrice = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| OPEN POSITION                                                     |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE type, double price) {
   if(ArraySize(positions) >= MaxPositions) return false;
   if(!CheckSpread()) return false;
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = validatedLotSize;
   request.type = type;
   request.price = price;
   request.deviation = 10;
   request.magic = MagicNumber;
   
   if(IndividualSLDollars > 0) {
      double pointValue = specs.tickValue / specs.tickSize;
      double slPoints = (IndividualSLDollars / validatedLotSize) / pointValue;
      double slDistance = slPoints * specs.point;
      slDistance = MathMax(slDistance, specs.minStopDistance);
      request.sl = type == ORDER_TYPE_BUY ? price - slDistance : price + slDistance;
   }
   
   if(IndividualTPDollars > 0) {
      double pointValue = specs.tickValue / specs.tickSize;
      double tpPoints = (IndividualTPDollars / validatedLotSize) / pointValue;
      double tpDistance = tpPoints * specs.point;
      tpDistance = MathMax(tpDistance, specs.minStopDistance);
      request.tp = type == ORDER_TYPE_BUY ? price + tpDistance : price - tpDistance;
   }
   
   if(!OrderSend(request, result)) return false;
   if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED) return false;
   
   totalTrades++;
   return true;
}

//+------------------------------------------------------------------+
//| MANAGE GRID                                                       |
//+------------------------------------------------------------------+
void ManageGrid() {
   if(emergencyStop || dailyTargetReached || isPaused) return;
   
   uint currentTime = GetTickCount();
   if(currentTime - lastGridCheck < gridCheckIntervalMs) return;
   lastGridCheck = currentTime;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   if(referencePrice == 0) {
      referencePrice = currentPrice;
      currentGapSize = CalculateGridGapInDollars();
   }
   
   currentGapSize = CalculateGridGapInDollars();
   
   // Calculate next levels
   if(CurrentDirection == BUYONLY) {
      nextBuyLevel = referencePrice - currentGapSize;
      nextSellLevel = 0;
   } else {
      nextSellLevel = referencePrice + currentGapSize;
      nextBuyLevel = 0;
   }
   
   bool positionOpened = false;
   
   if(CurrentDirection == BUYONLY) {
      if(currentPrice <= referencePrice - currentGapSize) {
         if(OpenPosition(ORDER_TYPE_BUY, ask)) {
            referencePrice = currentPrice;
            positionOpened = true;
         }
      }
   } else {
      if(currentPrice >= referencePrice + currentGapSize) {
         if(OpenPosition(ORDER_TYPE_SELL, bid)) {
            referencePrice = currentPrice;
            positionOpened = true;
         }
      }
   }
   
   if(positionOpened) ScanAndRebuildPositions();
}

//+------------------------------------------------------------------+
//| CHECK RISK MANAGEMENT                                            |
//+------------------------------------------------------------------+
void CheckRiskManagement() {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > peakEquity) peakEquity = equity;
   
   double drawdown = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   
   if(drawdown <= -MaxDrawdownPercent && !emergencyStop) {
      emergencyStop = true;
      emergencyReason = StringFormat("Drawdown %.1f%% ≥ Max %.1f%%", drawdown, MaxDrawdownPercent);
      
      for(int i = 0; i < ArraySize(positions); i++) {
         if(PositionSelectByTicket(positions[i].ticket)) {
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            request.action = TRADE_ACTION_DEAL;
            request.position = positions[i].ticket;
            request.symbol = _Symbol;
            request.volume = PositionGetDouble(POSITION_VOLUME);
            request.type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 
                          ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            request.price = request.type == ORDER_TYPE_SELL ? 
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            request.deviation = 10;
            if(!OrderSend(request, result)) {
               Print("Emergency close failed: ", result.retcode, " - ", result.comment);
            }
         }
      }
      ScanAndRebuildPositions();
   }
   
   CalculateTotalProfit();
   if(GroupTPDollars > 0 && totalProfit >= GroupTPDollars) {
      for(int i = 0; i < ArraySize(positions); i++) {
         if(PositionSelectByTicket(positions[i].ticket)) {
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            request.action = TRADE_ACTION_DEAL;
            request.position = positions[i].ticket;
            request.symbol = _Symbol;
            request.volume = PositionGetDouble(POSITION_VOLUME);
            request.type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 
                          ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            request.price = request.type == ORDER_TYPE_SELL ? 
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            request.deviation = 10;
            if(!OrderSend(request, result)) {
               Print("Group TP close failed: ", result.retcode, " - ", result.comment);
            }
         }
      }
      ScanAndRebuildPositions();
   }
}

//+------------------------------------------------------------------+
//| CHECK DAILY PROFIT                                               |
//+------------------------------------------------------------------+
void CheckDailyProfit() {
   MqlDateTime dt;
   TimeCurrent(dt);
   int today = dt.day_of_year;
   
   if(today != currentDay) {
      currentDay = today;
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyTarget = dailyStartBalance * (DailyTargetPercent / 100.0);
      dailyTargetReached = false;
   }
   
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - dailyStartBalance;
   
   if(dailyProfit >= dailyTarget && !dailyTargetReached) {
      dailyTargetReached = true;
   }
}

//+------------------------------------------------------------------+
//| INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit() {
   Print("═══════════════════════════════════════");
   Print("🚀 ", EA_NAME, " v", EA_VERSION);
   Print("═══════════════════════════════════════");
   
   MagicNumber = GenerateChartBasedMagicNumber();
   
   if(!InitializeSymbolSpecs()) {
      Print("❌ FAILED: Could not initialize symbol specifications");
      return(INIT_FAILED);
   }
   
   validatedLotSize = ValidateLotSize(LotSize);
   CurrentDirection = StartDirection;
   
   if(EnableATRSwitch) {
      atrHandle = iATR(_Symbol, PERIOD_D1, ATRPeriod);
      if(atrHandle == INVALID_HANDLE) {
         Print("❌ FAILED: Could not create ATR indicator handle");
         return(INIT_FAILED);
      }
      UpdateDayOpenPrice();
      WaitForIndicator(atrHandle);
   }
   
   ScanAndRebuildPositions();
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   MqlDateTime dt;
   TimeCurrent(dt);
   currentDay = dt.day_of_year;
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyTarget = dailyStartBalance * (DailyTargetPercent / 100.0);
   
   if(ShowPanel) {
      panel = new CToramaPanel();
      if(panel != NULL) panel.Create("TORAMA_AGG_");
   }
   
   Print("✅ INITIALIZATION COMPLETE");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(panel != NULL) {
      panel.Destroy();
      delete panel;
   }
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| ON TICK                                                           |
//+------------------------------------------------------------------+
void OnTick() {
   if(EnableATRSwitch) CheckATRModeSwitch();
   ManageGrid();
   CheckRiskManagement();
   CheckDailyProfit();
   
   if(ShowPanel && panel != NULL) {
      SPanelData data;
      data.currentDirection = CurrentDirection;
      data.gapPercent = CalculateGridGapInPercent();
      data.gapDollar = CalculateGridGapInDollars();
      data.nextBuyLevel = nextBuyLevel;
      data.nextSellLevel = nextSellLevel;
      data.referencePrice = referencePrice;
      data.positionsCount = ArraySize(positions);
      data.maxPositions = MaxPositions;
      data.totalProfit = totalProfit;
      data.equity = AccountInfoDouble(ACCOUNT_EQUITY);
      data.peakEquity = peakEquity;
      data.dailyProfit = dailyProfit;
      data.dailyTarget = dailyTarget;
      data.modeSwitchCount = modeSwitchCount;
      data.emergencyStop = emergencyStop;
      data.emergencyReason = emergencyReason;
      data.dailyTargetReached = dailyTargetReached;
      data.isPaused = isPaused;
      data.symbol = _Symbol;
      data.digits = specs.digits;
      
      panel.Update(data);
   }
}

//+------------------------------------------------------------------+
//| ON CHART EVENT                                                    |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam) {
   if(panel != NULL) panel.OnChartEvent(id, lparam, dparam, sparam);
}
//+------------------------------------------------------------------+
