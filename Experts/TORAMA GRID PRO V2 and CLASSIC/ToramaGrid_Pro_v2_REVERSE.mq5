//+------------------------------------------------------------------+
//|                                 ToramaGrid_Pro_v2_REVERSE.mq5 |
//|                                          TORAMA CAPITAL          |
//|                                          https://torama.money    |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "2.60"
#property description "REVERSE Grid: SELL UP (fade rallies) + BUY DOWN (fade dips)"
#property description "Features: Daily Target, Cumulative Profit, One Position Per Level"

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "=== Grid Settings ==="
input double InpGapPercent = 0.5;              // Gap Percentage of Price
input double InpBaseLotSize = 0.01;            // Base Lot Size
input int InpMaxPositionsPerSide = 20;         // Max Positions Per Side

input group "=== Risk Management ==="
input double InpGlobalTPDollar = 100.0;        // Global Take Profit (USD)
input double InpMaxDrawdownPercent = 20.0;     // Max Drawdown % (default 20%)
input double InpIndividualTPPercent = 0.0;     // Individual TP % of Gap (0=disabled)
input double InpDailyTargetPercent = 10.0;     // Daily Profit Target % (0=disabled)

input group "=== EA Settings ==="
input int InpMagicNumber = 0;                  // Magic Number (0=ChartID)
input string InpComment = "ToramaGridReverse"; // Trade Comment
input int InpMaxSlippage = 10;                 // Max Slippage in Points

//--- Global Variables
CTrade trade;
int magicNumber;
double refPrice = 0.0;
datetime startOfDay;
double startDayBalance;
bool eaPaused = false;

//--- Grid level tracking - STRICT ONE POSITION PER LEVEL
struct GridLevel
{
   double price;      // Exact grid level price
   ulong ticket;      // Position ticket at this level
   bool occupied;     // Is this level currently occupied?
};
GridLevel sellLevels[];  // SELL levels (price ABOVE reference - fade rallies)
GridLevel buyLevels[];   // BUY levels (price BELOW reference - fade dips)

//--- Broker limits
double minLot = 0.0;
double maxLot = 0.0;
double lotStep = 0.0;
int minStopLevel = 0;
int freezeLevel = 0;
double tickSize = 0.0;
double tickValue = 0.0;
int symbolDigits = 0;

//--- Trading control
datetime lastTradeTime = 0;
int minSecondsBetweenTrades = 1;

//--- Statistics
int tpHitCount = 0;
int individualTPCount = 0;
double globalProfit = 0.0;
int lastPositionCount = 0;
string eaStatus = "Active";

//--- Cumulative profit tracking
double cumulativeProfit = 0.0;
double sessionStartBalance = 0.0;
string globalVarPrefix = "";

//--- Daily profit target tracking
double dailyStartBalance = 0.0;
double dailyProfit = 0.0;
bool dailyTargetReached = false;
datetime currentDay = 0;

//--- Panel coordinates and sizes
int panelX = 20;
int panelY = 30;
int panelWidth = 300;
int panelHeight = 600;
int buttonHeight = 25;
int buttonWidth = 90;
int buttonSpacing = 5;

//--- Colors
color bgColor = C'40,40,40';
color textColor = clrWhite;
color buttonColor = C'70,70,70';
color brandColor = clrWhiteSmoke;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Set magic number
   magicNumber = (InpMagicNumber == 0) ? (int)ChartID() : InpMagicNumber;
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetDeviationInPoints(InpMaxSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetAsyncMode(false);
   
   //--- Load broker limits
   if(!LoadBrokerLimits())
   {
      Print("ERROR: Failed to load broker limits");
      return INIT_FAILED;
   }
   
   //--- Validate inputs
   if(!ValidateInputs())
   {
      return INIT_FAILED;
   }
   
   //--- Setup global variable prefix
   globalVarPrefix = "ToramaGridRev_" + _Symbol + "_" + IntegerToString(magicNumber) + "_";
   
   //--- Load or initialize cumulative profit tracking
   LoadCumulativeStats();
   
   //--- Initialize reference price
   if(refPrice == 0.0)
   {
      refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
   
   //--- Initialize grid level tracking
   InitializeGridLevels();
   
   //--- Initialize day tracking
   startOfDay = GetStartOfDay();
   startDayBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   //--- Initialize daily profit target tracking
   currentDay = GetStartOfDay();
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = 0.0;
   dailyTargetReached = false;
   
   //--- Load daily target status if same day
   LoadDailyTargetStatus();
   
   //--- Create UI Panel
   CreatePanel();
   
   //--- Set timer for panel updates
   EventSetTimer(1);
   
   Print("========================================");
   Print("ToramaGrid Pro v2 REVERSE initialized");
   Print("Strategy: SELL UP (fade rallies) + BUY DOWN (fade dips)");
   Print("Magic: ", magicNumber, " | RefPrice: ", DoubleToString(refPrice, symbolDigits));
   Print("Gap: ", InpGapPercent, "% | Lot: ", InpBaseLotSize);
   Print("Individual TP: ", InpIndividualTPPercent > 0 ? "Enabled" : "Disabled");
   Print("Cumulative Profit: $", DoubleToString(cumulativeProfit, 2));
   
   if(InpDailyTargetPercent > 0)
   {
      double targetAmount = dailyStartBalance * (InpDailyTargetPercent / 100.0);
      Print("Daily Target: ", InpDailyTargetPercent, "% ($", DoubleToString(targetAmount, 2), ")");
      if(dailyTargetReached)
         Print("Daily target already reached - EA will resume tomorrow");
   }
   
   Print("Broker: MinLot=", minLot, " MaxLot=", maxLot, " Step=", lotStep);
   Print("StopLevel=", minStopLevel, " FreezeLevel=", freezeLevel);
   Print("Grid: ", ArraySize(sellLevels), " SELL (up) + ", ArraySize(buyLevels), " BUY (down) levels");
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Save cumulative stats before closing
   SaveCumulativeStats();
   
   EventKillTimer();
   ObjectsDeleteAll(0, "ToramaPanel");
   Print("ToramaGrid Pro v2 REVERSE deinitialized. Total Cumulative: $", DoubleToString(cumulativeProfit, 2));
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Check if new day (auto-resume trading)
   CheckNewDay();
   
   //--- Update global profit
   UpdateGlobalProfit();
   
   //--- Calculate daily profit
   UpdateDailyProfit();
   
   //--- Check if daily target reached
   if(InpDailyTargetPercent > 0 && CheckDailyTarget())
   {
      if(!dailyTargetReached)
      {
         CloseAllPositions();
         dailyTargetReached = true;
         eaPaused = true;
         eaStatus = "Daily Target Hit";
         SaveDailyTargetStatus();
         
         double targetAmount = dailyStartBalance * (InpDailyTargetPercent / 100.0);
         Print("Daily Target Reached! Profit: $", DoubleToString(dailyProfit, 2), 
               " (Target: $", DoubleToString(targetAmount, 2), ")");
      }
      return;
   }
   
   //--- Check for global TP reached
   if(CheckGlobalTP())
   {
      cumulativeProfit += globalProfit;
      SaveCumulativeStats();
      
      CloseAllPositions();
      ResetGridAfterClose();
      tpHitCount++;
      Print("Global TP: $", DoubleToString(globalProfit, 2), " | Total: $", DoubleToString(cumulativeProfit, 2));
      return;
   }
   
   //--- Check risk limits
   if(CheckDrawdownLimit())
   {
      if(!eaPaused)
      {
         CloseAllPositions();
         eaPaused = true;
         eaStatus = "Stopped - Max DD";
         Print("EA Paused - Max Drawdown reached");
      }
      return;
   }
   
   //--- Don't trade if paused
   if(eaPaused)
      return;
   
   //--- Track individual position closures
   TrackClosedPositions();
   
   //--- Check for position closure
   int currentPositionCount = CountMyPositions();
   if(lastPositionCount > 0 && currentPositionCount == 0)
   {
      ResetGridAfterClose();
   }
   lastPositionCount = currentPositionCount;
   
   //--- Update grid occupancy - CRITICAL FOR STRICT ENFORCEMENT
   UpdateGridOccupancy();
   
   //--- Check for new grid entries with STRICT enforcement - REVERSE LOGIC
   CheckGridLevelsStrictReverse();
}

//+------------------------------------------------------------------+
//| Timer function for UI updates                                    |
//+------------------------------------------------------------------+
void OnTimer()
{
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| Chart Event function                                             |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == "ToramaPanelBtnReset")
      {
         ObjectSetInteger(0, "ToramaPanelBtnReset", OBJPROP_STATE, false);
         ResetReference();
      }
      else if(sparam == "ToramaPanelBtnClose")
      {
         ObjectSetInteger(0, "ToramaPanelBtnClose", OBJPROP_STATE, false);
         CloseAllPositions();
      }
      else if(sparam == "ToramaPanelBtnResume")
      {
         ObjectSetInteger(0, "ToramaPanelBtnResume", OBJPROP_STATE, false);
         
         if(dailyTargetReached || eaPaused)
         {
            eaPaused = false;
            eaStatus = "Active";
            Print("Trading manually resumed by user");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Load broker trading limits                                       |
//+------------------------------------------------------------------+
bool LoadBrokerLimits()
{
   minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   minStopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   symbolDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   if(minLot <= 0 || maxLot <= 0 || lotStep <= 0)
   {
      Print("ERROR: Invalid broker lot settings");
      return false;
   }
   
   if(tickSize <= 0 || tickValue <= 0)
   {
      Print("ERROR: Invalid tick settings");
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Validate input parameters                                        |
//+------------------------------------------------------------------+
bool ValidateInputs()
{
   if(InpGapPercent <= 0 || InpGapPercent > 50)
   {
      Print("ERROR: Gap Percent must be between 0 and 50");
      return false;
   }
   
   if(InpBaseLotSize < minLot || InpBaseLotSize > maxLot)
   {
      Print("ERROR: Base Lot (", InpBaseLotSize, ") outside limits [", minLot, "-", maxLot, "]");
      return false;
   }
   
   if(InpMaxPositionsPerSide < 1 || InpMaxPositionsPerSide > 100)
   {
      Print("ERROR: Max Positions must be 1-100");
      return false;
   }
   
   if(InpGlobalTPDollar < 0)
   {
      Print("ERROR: Global TP must be >= 0");
      return false;
   }
   
   if(InpMaxDrawdownPercent < 0 || InpMaxDrawdownPercent > 100)
   {
      Print("ERROR: Max Drawdown must be 0-100%");
      return false;
   }
   
   if(InpDailyTargetPercent < 0 || InpDailyTargetPercent > 100)
   {
      Print("ERROR: Daily Target must be 0-100%");
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Initialize grid levels - REVERSE LOGIC                           |
//| SELL levels ABOVE reference (fade rallies)                       |
//| BUY levels BELOW reference (fade dips)                           |
//+------------------------------------------------------------------+
void InitializeGridLevels()
{
   ArrayResize(sellLevels, InpMaxPositionsPerSide);
   ArrayResize(buyLevels, InpMaxPositionsPerSide);
   
   double gap = refPrice * InpGapPercent / 100.0;
   
   //--- Initialize SELL levels (ABOVE reference - fade rallies)
   for(int i = 0; i < InpMaxPositionsPerSide; i++)
   {
      sellLevels[i].price = refPrice + ((i + 1) * gap);
      sellLevels[i].ticket = 0;
      sellLevels[i].occupied = false;
   }
   
   //--- Initialize BUY levels (BELOW reference - fade dips)
   for(int i = 0; i < InpMaxPositionsPerSide; i++)
   {
      buyLevels[i].price = refPrice - ((i + 1) * gap);
      buyLevels[i].ticket = 0;
      buyLevels[i].occupied = false;
   }
   
   Print("REVERSE Grid initialized: ", InpMaxPositionsPerSide, " SELL (up) + ", InpMaxPositionsPerSide, " BUY (down)");
}

//+------------------------------------------------------------------+
//| Update grid occupancy from current positions                     |
//+------------------------------------------------------------------+
void UpdateGridOccupancy()
{
   //--- Reset all levels
   for(int i = 0; i < ArraySize(sellLevels); i++)
   {
      sellLevels[i].occupied = false;
      sellLevels[i].ticket = 0;
   }
   
   for(int i = 0; i < ArraySize(buyLevels); i++)
   {
      buyLevels[i].occupied = false;
      buyLevels[i].ticket = 0;
   }
   
   //--- Mark occupied levels
   double gap = refPrice * InpGapPercent / 100.0;
   double levelTolerance = gap * 0.25;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == magicNumber)
         {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            if(posType == POSITION_TYPE_SELL)
            {
               for(int j = 0; j < ArraySize(sellLevels); j++)
               {
                  if(MathAbs(openPrice - sellLevels[j].price) < levelTolerance)
                  {
                     sellLevels[j].occupied = true;
                     sellLevels[j].ticket = ticket;
                     break;
                  }
               }
            }
            else if(posType == POSITION_TYPE_BUY)
            {
               for(int j = 0; j < ArraySize(buyLevels); j++)
               {
                  if(MathAbs(openPrice - buyLevels[j].price) < levelTolerance)
                  {
                     buyLevels[j].occupied = true;
                     buyLevels[j].ticket = ticket;
                     break;
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| REVERSE GRID LOGIC: SELL UP + BUY DOWN                          |
//| SELLs open as price RISES (fade rallies)                        |
//| BUYs open as price FALLS (fade dips)                            |
//+------------------------------------------------------------------+
void CheckGridLevelsStrictReverse()
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double gap = refPrice * InpGapPercent / 100.0;
   
   if(gap <= 0)
      return;
   
   //--- Anti-spam rate limiting
   if(TimeCurrent() - lastTradeTime < minSecondsBetweenTrades)
      return;
   
   //--- REVERSE: Check SELL levels (price ABOVE reference - fade the rally)
   if(currentPrice > refPrice)
   {
      for(int i = 0; i < ArraySize(sellLevels); i++)
      {
         if(!sellLevels[i].occupied)
         {
            double levelPrice = sellLevels[i].price;
            double distanceToLevel = MathAbs(currentPrice - levelPrice);
            double entryTolerance = gap * 0.15;
            
            if(distanceToLevel <= entryTolerance && 
               currentPrice >= levelPrice - entryTolerance)
            {
               if(!PositionExistsAtPrice(levelPrice, ORDER_TYPE_SELL, gap * 0.25))
               {
                  if(OpenGridPositionRobust(ORDER_TYPE_SELL, levelPrice, i))
                  {
                     sellLevels[i].occupied = true;
                     lastTradeTime = TimeCurrent();
                     Print("REVERSE: SELL opened at rally level ", i+1);
                     return;
                  }
               }
            }
         }
      }
   }
   
   //--- REVERSE: Check BUY levels (price BELOW reference - fade the dip)
   if(currentPrice < refPrice)
   {
      for(int i = 0; i < ArraySize(buyLevels); i++)
      {
         if(!buyLevels[i].occupied)
         {
            double levelPrice = buyLevels[i].price;
            double distanceToLevel = MathAbs(currentPrice - levelPrice);
            double entryTolerance = gap * 0.15;
            
            if(distanceToLevel <= entryTolerance && 
               currentPrice <= levelPrice + entryTolerance)
            {
               if(!PositionExistsAtPrice(levelPrice, ORDER_TYPE_BUY, gap * 0.25))
               {
                  if(OpenGridPositionRobust(ORDER_TYPE_BUY, levelPrice, i))
                  {
                     buyLevels[i].occupied = true;
                     lastTradeTime = TimeCurrent();
                     Print("REVERSE: BUY opened at dip level ", i+1);
                     return;
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if position exists at price                                |
//+------------------------------------------------------------------+
bool PositionExistsAtPrice(double targetPrice, ENUM_ORDER_TYPE type, double tolerance)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == magicNumber)
         {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            if(MathAbs(openPrice - targetPrice) < tolerance)
            {
               if((type == ORDER_TYPE_BUY && posType == POSITION_TYPE_BUY) ||
                  (type == ORDER_TYPE_SELL && posType == POSITION_TYPE_SELL))
               {
                  return true;
               }
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Open position with COMPREHENSIVE error handling                  |
//+------------------------------------------------------------------+
bool OpenGridPositionRobust(ENUM_ORDER_TYPE type, double gridLevel, int levelIndex)
{
   double lotSize = NormalizeLotSize(InpBaseLotSize);
   if(lotSize <= 0)
   {
      Print("ERROR: Invalid lot size");
      return false;
   }
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(ask <= 0 || bid <= 0)
   {
      Print("ERROR: Invalid prices");
      return false;
   }
   
   double price = (type == ORDER_TYPE_BUY) ? ask : bid;
   double gap = refPrice * InpGapPercent / 100.0;
   
   //--- Calculate TP - REVERSE LOGIC
   // For SELL: TP is BELOW entry (price falls back)
   // For BUY: TP is ABOVE entry (price rises back)
   double tp = 0;
   if(InpIndividualTPPercent > 0)
   {
      double tpDistance = gap * (InpIndividualTPPercent / 100.0);
      
      if(type == ORDER_TYPE_SELL)
      {
         // SELL TP is BELOW entry (profit when price drops back)
         tp = price - tpDistance;
      }
      else // ORDER_TYPE_BUY
      {
         // BUY TP is ABOVE entry (profit when price rises back)
         tp = price + tpDistance;
      }
      
      tp = NormalizePrice(tp);
      
      double tpDistancePoints = MathAbs(tp - price) / tickSize;
      if(minStopLevel > 0 && tpDistancePoints < minStopLevel)
         tp = 0;
   }
   
   //--- Check margin
   double marginRequired = 0;
   if(!OrderCalcMargin(type, _Symbol, lotSize, price, marginRequired))
   {
      Print("ERROR: Margin calc failed");
      return false;
   }
   
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(marginRequired > freeMargin * 0.95)
   {
      Print("ERROR: Insufficient margin. Need:", marginRequired, " Have:", freeMargin);
      return false;
   }
   
   //--- Open position
   bool result = false;
   ResetLastError();
   
   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(lotSize, _Symbol, price, 0, tp, InpComment);
   else
      result = trade.Sell(lotSize, _Symbol, price, 0, tp, InpComment);
   
   if(result)
   {
      string direction = (type == ORDER_TYPE_BUY) ? "BUY↓" : "SELL↑";
      string tpInfo = (tp > 0) ? " TP:" + DoubleToString(tp, symbolDigits) : "";
      Print("SUCCESS: ", direction, " L", levelIndex+1, " @", DoubleToString(gridLevel, symbolDigits), 
            " #", trade.ResultOrder(), tpInfo);
      return true;
   }
   else
   {
      uint errorCode = trade.ResultRetcode();
      Print("ERROR: ", errorCode, " - ", trade.ResultRetcodeDescription());
      HandleTradeError(errorCode);
      return false;
   }
}

//+------------------------------------------------------------------+
//| Handle trade errors                                              |
//+------------------------------------------------------------------+
void HandleTradeError(uint errorCode)
{
   switch(errorCode)
   {
      case 10004: Print("Requote - will retry"); break;
      case 10006: Print("Request rejected"); break;
      case 10013: Print("Invalid volume"); break;
      case 10014: Print("Invalid price"); break;
      case 10015: Print("Invalid stops"); break;
      case 10016: Print("Trading disabled"); break;
      case 10017: Print("Market closed"); break;
      case 10018: Print("No money"); break;
      case 10019: Print("Price changed"); break;
      case 10023: Print("Too many requests"); Sleep(1000); break;
      case 10030: Print("No connection"); break;
   }
}

//+------------------------------------------------------------------+
//| Normalize lot size                                               |
//+------------------------------------------------------------------+
double NormalizeLotSize(double lots)
{
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   lots = MathFloor(lots / lotStep) * lotStep;
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Normalize price to tick size                                     |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   if(tickSize <= 0)
      return NormalizeDouble(price, symbolDigits);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, symbolDigits);
}

//+------------------------------------------------------------------+
//| Check global TP                                                  |
//+------------------------------------------------------------------+
bool CheckGlobalTP()
{
   return (globalProfit >= InpGlobalTPDollar);
}

//+------------------------------------------------------------------+
//| Check drawdown limit                                             |
//+------------------------------------------------------------------+
bool CheckDrawdownLimit()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   if(balance <= 0) return false;
   
   double drawdown = ((balance - equity) / balance) * 100.0;
   return (drawdown >= InpMaxDrawdownPercent);
}

//+------------------------------------------------------------------+
//| Update global profit                                             |
//+------------------------------------------------------------------+
void UpdateGlobalProfit()
{
   globalProfit = 0.0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == magicNumber)
         {
            globalProfit += PositionGetDouble(POSITION_PROFIT);
            globalProfit += PositionGetDouble(POSITION_SWAP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Update daily profit                                              |
//+------------------------------------------------------------------+
void UpdateDailyProfit()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   dailyProfit = currentEquity - dailyStartBalance;
}

//+------------------------------------------------------------------+
//| Check daily target                                               |
//+------------------------------------------------------------------+
bool CheckDailyTarget()
{
   if(InpDailyTargetPercent <= 0) return false;
   
   double targetAmount = dailyStartBalance * (InpDailyTargetPercent / 100.0);
   return (dailyProfit >= targetAmount);
}

//+------------------------------------------------------------------+
//| Check new day                                                    |
//+------------------------------------------------------------------+
void CheckNewDay()
{
   datetime newDay = GetStartOfDay();
   
   if(newDay > currentDay)
   {
      currentDay = newDay;
      startOfDay = newDay;
      startDayBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyProfit = 0.0;
      dailyTargetReached = false;
      
      if(eaStatus == "Daily Target Hit")
      {
         eaPaused = false;
         eaStatus = "Active";
         Print("New day - Trading resumed");
      }
      
      SaveDailyTargetStatus();
   }
}

//+------------------------------------------------------------------+
//| Get start of day                                                 |
//+------------------------------------------------------------------+
datetime GetStartOfDay()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   tm.hour = 0;
   tm.min = 0;
   tm.sec = 0;
   return StructToTime(tm);
}

//+------------------------------------------------------------------+
//| Count positions                                                  |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == magicNumber)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count buys and sells                                             |
//+------------------------------------------------------------------+
void CountBuysSells(int &buys, int &sells)
{
   buys = 0;
   sells = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == magicNumber)
         {
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            if(posType == POSITION_TYPE_BUY)
               buys++;
            else if(posType == POSITION_TYPE_SELL)
               sells++;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Reset grid after close                                           |
//+------------------------------------------------------------------+
void ResetGridAfterClose()
{
   refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   InitializeGridLevels();
   Print("REVERSE Grid reset: Ref=", DoubleToString(refPrice, symbolDigits));
}

//+------------------------------------------------------------------+
//| Close all positions                                              |
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
            PositionGetInteger(POSITION_MAGIC) == magicNumber)
         {
            if(trade.PositionClose(ticket))
               closed++;
         }
      }
   }
   
   Print("Closed ", closed, " positions");
}

//+------------------------------------------------------------------+
//| Reset reference                                                  |
//+------------------------------------------------------------------+
void ResetReference()
{
   refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   InitializeGridLevels();
   eaPaused = false;
   eaStatus = "Active";
   Print("Reference reset: ", DoubleToString(refPrice, symbolDigits));
}

//+------------------------------------------------------------------+
//| Load daily target status                                         |
//+------------------------------------------------------------------+
void LoadDailyTargetStatus()
{
   string varDay = globalVarPrefix + "CurrentDay";
   string varDailyBalance = globalVarPrefix + "DailyStartBalance";
   string varDailyProfit = globalVarPrefix + "DailyProfit";
   string varTargetReached = globalVarPrefix + "DailyTargetReached";
   
   if(GlobalVariableCheck(varDay))
   {
      datetime savedDay = (datetime)GlobalVariableGet(varDay);
      
      if(savedDay == currentDay)
      {
         dailyStartBalance = GlobalVariableGet(varDailyBalance);
         dailyProfit = GlobalVariableGet(varDailyProfit);
         dailyTargetReached = (bool)GlobalVariableGet(varTargetReached);
         
         if(dailyTargetReached)
         {
            eaPaused = true;
            eaStatus = "Daily Target Hit";
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Save daily target status                                         |
//+------------------------------------------------------------------+
void SaveDailyTargetStatus()
{
   string varDay = globalVarPrefix + "CurrentDay";
   string varDailyBalance = globalVarPrefix + "DailyStartBalance";
   string varDailyProfit = globalVarPrefix + "DailyProfit";
   string varTargetReached = globalVarPrefix + "DailyTargetReached";
   
   GlobalVariableSet(varDay, (double)currentDay);
   GlobalVariableSet(varDailyBalance, dailyStartBalance);
   GlobalVariableSet(varDailyProfit, dailyProfit);
   GlobalVariableSet(varTargetReached, (double)dailyTargetReached);
}

//+------------------------------------------------------------------+
//| Load cumulative statistics                                       |
//+------------------------------------------------------------------+
void LoadCumulativeStats()
{
   string varCumProfit = globalVarPrefix + "CumulativeProfit";
   string varTPHits = globalVarPrefix + "TPHits";
   string varStartBalance = globalVarPrefix + "StartBalance";
   
   if(GlobalVariableCheck(varCumProfit))
   {
      cumulativeProfit = GlobalVariableGet(varCumProfit);
      tpHitCount = (int)GlobalVariableGet(varTPHits);
      sessionStartBalance = GlobalVariableGet(varStartBalance);
   }
   else
   {
      cumulativeProfit = 0.0;
      tpHitCount = 0;
      sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      SaveCumulativeStats();
   }
}

//+------------------------------------------------------------------+
//| Save cumulative statistics                                       |
//+------------------------------------------------------------------+
void SaveCumulativeStats()
{
   string varCumProfit = globalVarPrefix + "CumulativeProfit";
   string varTPHits = globalVarPrefix + "TPHits";
   string varStartBalance = globalVarPrefix + "StartBalance";
   
   GlobalVariableSet(varCumProfit, cumulativeProfit);
   GlobalVariableSet(varTPHits, (double)tpHitCount);
   GlobalVariableSet(varStartBalance, sessionStartBalance);
}

//+------------------------------------------------------------------+
//| Track closed positions                                           |
//+------------------------------------------------------------------+
void TrackClosedPositions()
{
   static ulong lastCheckedDeal = 0;
   string varLastDeal = globalVarPrefix + "LastDealTicket";
   
   if(lastCheckedDeal == 0 && GlobalVariableCheck(varLastDeal))
      lastCheckedDeal = (ulong)GlobalVariableGet(varLastDeal);
   
   HistorySelect(0, TimeCurrent());
   int totalDeals = HistoryDealsTotal();
   
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket <= lastCheckedDeal)
         break;
      
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == magicNumber &&
         HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol)
      {
         ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(dealEntry == DEAL_ENTRY_OUT)
         {
            double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            double dealSwap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            double dealCommission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            
            double netProfit = dealProfit + dealSwap + dealCommission;
            
            if(CountMyPositions() > 0)
            {
               cumulativeProfit += netProfit;
               SaveCumulativeStats();
               
               if(netProfit > 0)
                  individualTPCount++;
            }
         }
      }
      
      lastCheckedDeal = dealTicket;
      GlobalVariableSet(varLastDeal, (double)lastCheckedDeal);
   }
}

//+------------------------------------------------------------------+
//| Create UI Panel                                                  |
//+------------------------------------------------------------------+
void CreatePanel()
{
   ObjectCreate(0, "ToramaPanelBG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "ToramaPanelBG", OBJPROP_XDISTANCE, panelX);
   ObjectSetInteger(0, "ToramaPanelBG", OBJPROP_YDISTANCE, panelY);
   ObjectSetInteger(0, "ToramaPanelBG", OBJPROP_XSIZE, panelWidth);
   ObjectSetInteger(0, "ToramaPanelBG", OBJPROP_YSIZE, panelHeight);
   ObjectSetInteger(0, "ToramaPanelBG", OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, "ToramaPanelBG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, "ToramaPanelBG", OBJPROP_COLOR, clrGray);
   ObjectSetInteger(0, "ToramaPanelBG", OBJPROP_BACK, false);
   ObjectSetInteger(0, "ToramaPanelBG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "ToramaPanelBG", OBJPROP_HIDDEN, true);
   
   CreateLabel("ToramaPanelTitle", "TORAMA GRID REVERSE", panelX + 10, panelY + 8, 10, clrWhiteSmoke, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelSubtitle", "SELL UP ↑ | BUY DOWN ↓", panelX + 10, panelY + 22, 7, clrYellow, ANCHOR_LEFT_UPPER);
   
   int yOffset = panelY + 40;
   int col1 = panelX + 10;
   int col2 = panelX + 160;
   
   CreateLabel("ToramaPanelLblStatus", "Status:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValStatus", "", col1 + 45, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   yOffset += 20;
   
   CreateLabel("ToramaPanelLblBalance", "Bal:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValBalance", "", col1 + 30, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblEquity", "Eq:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValEquity", "", col2 + 25, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   CreateLabel("ToramaPanelLblMargin", "Margin:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValMargin", "", col1 + 45, yOffset, 8, clrYellow, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblGlobalPnL", "Profit:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValGlobalPnL", "", col2 + 40, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 22;
   
   CreateLabel("ToramaPanelLblGlobalTP", "Global TP Target:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValGlobalTP", "", col1 + 105, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   yOffset += 22;
   
   CreateLabel("ToramaPanelLblDailyProfit", "Today's Profit:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValDailyProfit", "", col1 + 85, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   CreateLabel("ToramaPanelLblDailyTarget", "Daily Target:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValDailyTarget", "", col1 + 75, yOffset, 8, clrYellow, ANCHOR_LEFT_UPPER);
   yOffset += 22;
   
   CreateLabel("ToramaPanelLblGap", "Gap:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValGapPct", "", col1 + 30, yOffset, 8, clrAqua, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValGapUSD", "", col2 + 15, yOffset, 8, clrAqua, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   CreateLabel("ToramaPanelLblRefPrice", "Ref:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValRefPrice", "", col1 + 30, yOffset, 8, clrAqua, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblCurrPrice", "Curr:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValCurrPrice", "", col2 + 35, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   CreateLabel("ToramaPanelLblNextSell", "Sell↑:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValNextSell", "", col1 + 35, yOffset, 8, clrRed, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblNextBuy", "Buy↓:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValNextBuy", "", col2 + 30, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   yOffset += 22;
   
   CreateLabel("ToramaPanelLblMaxPos", "Max Pos/Side:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValMaxPos", "", col1 + 80, yOffset, 8, clrYellow, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   CreateLabel("ToramaPanelLblTPHits", "Cycles:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValTPHits", "", col1 + 45, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblPosCount", "Total:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValPosCount", "", col2 + 35, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   CreateLabel("ToramaPanelLblSells", "Sells↑:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValSells", "", col1 + 45, yOffset, 8, clrRed, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblBuys", "Buys↓:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValBuys", "", col2 + 35, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   CreateLabel("ToramaPanelLblNet", "Net:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValNet", "", col1 + 30, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   CreateLabel("ToramaPanelLblIndTP", "Ind. TP:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValIndTP", "", col1 + 50, yOffset, 8, clrAqua, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   CreateLabel("ToramaPanelLblMagic", "Magic:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValMagic", "", col1 + 40, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 22;
   
   CreateLabel("ToramaPanelSeparator", "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", col1, yOffset, 8, clrGray, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   CreateLabel("ToramaPanelLblCumulative", "TOTAL PROFIT:", col1, yOffset, 9, clrYellow, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValCumulative", "", col1 + 85, yOffset, 9, clrLime, ANCHOR_LEFT_UPPER);
   ObjectSetString(0, "ToramaPanelLblCumulative", OBJPROP_FONT, "Arial Bold");
   ObjectSetString(0, "ToramaPanelValCumulative", OBJPROP_FONT, "Arial Bold");
   yOffset += 25;
   
   int btnY = yOffset;
   CreateButton("ToramaPanelBtnReset", "RESET REF", panelX + 10, btnY, buttonWidth, buttonHeight);
   CreateButton("ToramaPanelBtnClose", "CLOSE ALL", panelX + 10 + buttonWidth + buttonSpacing, btnY, buttonWidth, buttonHeight);
   
   btnY += buttonHeight + buttonSpacing;
   CreateButton("ToramaPanelBtnResume", "RESUME", panelX + 10, btnY, (buttonWidth * 2) + buttonSpacing, buttonHeight);
   ObjectSetInteger(0, "ToramaPanelBtnResume", OBJPROP_BGCOLOR, C'200,50,50');
   ObjectSetInteger(0, "ToramaPanelBtnResume", OBJPROP_HIDDEN, true);
   
   CreateLabel("ToramaPanelBrand", "TORAMA CAPITAL", panelX + panelWidth - 10, panelY + panelHeight - 20, 9, brandColor, ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, "ToramaPanelBrand", OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, "ToramaPanelBrand", OBJPROP_FONT, "Arial Black");
}

//+------------------------------------------------------------------+
//| Create label                                                     |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, int fontSize, color clr, ENUM_ANCHOR_POINT anchor)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
}

//+------------------------------------------------------------------+
//| Create button                                                    |
//+------------------------------------------------------------------+
void CreateButton(string name, string text, int x, int y, int width, int height)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, buttonColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrGray);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Update panel                                                     |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   ObjectSetString(0, "ToramaPanelValStatus", OBJPROP_TEXT, eaStatus);
   color statusColor = StringFind(eaStatus, "Stopped") >= 0 ? clrRed : clrLime;
   ObjectSetInteger(0, "ToramaPanelValStatus", OBJPROP_COLOR, statusColor);
   
   ObjectSetString(0, "ToramaPanelValBalance", OBJPROP_TEXT, DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   ObjectSetString(0, "ToramaPanelValEquity", OBJPROP_TEXT, DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   ObjectSetString(0, "ToramaPanelValMargin", OBJPROP_TEXT, DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2));
   
   string profitText = "$" + DoubleToString(globalProfit, 2);
   double progress = (globalProfit / InpGlobalTPDollar) * 100.0;
   profitText += " (" + DoubleToString(progress, 1) + "%)";
   ObjectSetString(0, "ToramaPanelValGlobalPnL", OBJPROP_TEXT, profitText);
   ObjectSetInteger(0, "ToramaPanelValGlobalPnL", OBJPROP_COLOR, globalProfit >= 0 ? clrLime : clrRed);
   
   ObjectSetString(0, "ToramaPanelValGlobalTP", OBJPROP_TEXT, "$" + DoubleToString(InpGlobalTPDollar, 2));
   
   if(InpDailyTargetPercent > 0)
   {
      double targetAmount = dailyStartBalance * (InpDailyTargetPercent / 100.0);
      double dailyProgress = (dailyProfit / targetAmount) * 100.0;
      
      string dailyProfitText = "$" + DoubleToString(dailyProfit, 2) + " (" + DoubleToString(dailyProgress, 1) + "%)";
      ObjectSetString(0, "ToramaPanelValDailyProfit", OBJPROP_TEXT, dailyProfitText);
      ObjectSetInteger(0, "ToramaPanelValDailyProfit", OBJPROP_COLOR, dailyProfit >= 0 ? clrLime : clrRed);
      
      string dailyTargetText = DoubleToString(InpDailyTargetPercent, 1) + "% ($" + DoubleToString(targetAmount, 2) + ")";
      ObjectSetString(0, "ToramaPanelValDailyTarget", OBJPROP_TEXT, dailyTargetText);
      ObjectSetInteger(0, "ToramaPanelValDailyTarget", OBJPROP_COLOR, dailyTargetReached ? clrLime : clrYellow);
   }
   else
   {
      ObjectSetString(0, "ToramaPanelValDailyProfit", OBJPROP_TEXT, "$" + DoubleToString(dailyProfit, 2));
      ObjectSetInteger(0, "ToramaPanelValDailyProfit", OBJPROP_COLOR, dailyProfit >= 0 ? clrLime : clrRed);
      ObjectSetString(0, "ToramaPanelValDailyTarget", OBJPROP_TEXT, "Disabled");
      ObjectSetInteger(0, "ToramaPanelValDailyTarget", OBJPROP_COLOR, clrGray);
   }
   
   double gap = refPrice * InpGapPercent / 100.0;
   ObjectSetString(0, "ToramaPanelValGapPct", OBJPROP_TEXT, DoubleToString(InpGapPercent, 2) + "%");
   ObjectSetString(0, "ToramaPanelValGapUSD", OBJPROP_TEXT, "($" + DoubleToString(gap, symbolDigits) + ")");
   
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ObjectSetString(0, "ToramaPanelValRefPrice", OBJPROP_TEXT, DoubleToString(refPrice, symbolDigits));
   ObjectSetString(0, "ToramaPanelValCurrPrice", OBJPROP_TEXT, DoubleToString(currentPrice, symbolDigits));
   
   // REVERSE: Next SELL is above, next BUY is below
   double nextSell = refPrice + gap;
   double nextBuy = refPrice - gap;
   
   if(currentPrice > refPrice)
   {
      int level = (int)MathCeil((currentPrice - refPrice) / gap);
      if(level < 1) level = 1;
      nextSell = refPrice + (level * gap);
   }
   else if(currentPrice < refPrice)
   {
      int level = (int)MathCeil((refPrice - currentPrice) / gap);
      if(level < 1) level = 1;
      nextBuy = refPrice - (level * gap);
   }
   
   ObjectSetString(0, "ToramaPanelValNextSell", OBJPROP_TEXT, DoubleToString(nextSell, symbolDigits));
   ObjectSetString(0, "ToramaPanelValNextBuy", OBJPROP_TEXT, DoubleToString(nextBuy, symbolDigits));
   
   ObjectSetString(0, "ToramaPanelValMaxPos", OBJPROP_TEXT, IntegerToString(InpMaxPositionsPerSide));
   
   int buys = 0, sells = 0;
   CountBuysSells(buys, sells);
   int net = buys - sells;
   
   ObjectSetString(0, "ToramaPanelValTPHits", OBJPROP_TEXT, IntegerToString(tpHitCount));
   ObjectSetString(0, "ToramaPanelValPosCount", OBJPROP_TEXT, IntegerToString(CountMyPositions()));
   
   ObjectSetString(0, "ToramaPanelValSells", OBJPROP_TEXT, IntegerToString(sells));
   ObjectSetString(0, "ToramaPanelValBuys", OBJPROP_TEXT, IntegerToString(buys));
   
   string netText = IntegerToString(net);
   if(net > 0)
      netText = "+" + netText + " (Long)";
   else if(net < 0)
      netText = netText + " (Short)";
   else
      netText = netText + " (Flat)";
   
   ObjectSetString(0, "ToramaPanelValNet", OBJPROP_TEXT, netText);
   color netColor = net > 0 ? clrLime : (net < 0 ? clrRed : clrWhite);
   ObjectSetInteger(0, "ToramaPanelValNet", OBJPROP_COLOR, netColor);
   
   string indTPText = (InpIndividualTPPercent > 0) ? DoubleToString(InpIndividualTPPercent, 1) + "% gap" : "Disabled";
   ObjectSetString(0, "ToramaPanelValIndTP", OBJPROP_TEXT, indTPText);
   ObjectSetInteger(0, "ToramaPanelValIndTP", OBJPROP_COLOR, (InpIndividualTPPercent > 0) ? clrLime : clrGray);
   
   ObjectSetString(0, "ToramaPanelValMagic", OBJPROP_TEXT, IntegerToString(magicNumber));
   
   ObjectSetString(0, "ToramaPanelValCumulative", OBJPROP_TEXT, "$" + DoubleToString(cumulativeProfit, 2));
   ObjectSetInteger(0, "ToramaPanelValCumulative", OBJPROP_COLOR, cumulativeProfit >= 0 ? clrLime : clrRed);
   
   ObjectSetInteger(0, "ToramaPanelBtnResume", OBJPROP_HIDDEN, !(dailyTargetReached && eaPaused));
}

//+------------------------------------------------------------------+
