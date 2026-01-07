//+------------------------------------------------------------------+
//|                                           ToramaGrid_Pro_v2.mq5 |
//|                                          TORAMA CAPITAL          |
//|                                          https://torama.money    |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "2.00"
#property description "Bidirectional Hedging Grid - Profits from trending markets"

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
input string InpComment = "ToramaGridPro";     // Trade Comment

//--- Global Variables
CTrade trade;
int magicNumber;
double refPrice = 0.0;
datetime startOfDay;
double startDayBalance;
bool eaPaused = false;

//--- Statistics
int tpHitCount = 0;
int individualTPCount = 0;
double globalProfit = 0.0;
int lastPositionCount = 0;
string eaStatus = "Active";

//--- Cumulative profit tracking
double cumulativeProfit = 0.0;        // Total realized profit since EA start
double sessionStartBalance = 0.0;     // Balance when EA first started
string globalVarPrefix = "";          // Prefix for global variables

//--- Daily profit target tracking
double dailyStartBalance = 0.0;       // Balance at start of day
double dailyProfit = 0.0;             // Profit made today
bool dailyTargetReached = false;      // Flag for daily target reached
datetime currentDay = 0;              // Current trading day

//--- Panel coordinates and sizes
int panelX = 20;
int panelY = 30;
int panelWidth = 300;
int panelHeight = 560;  // Increased for daily profit section
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
   
   //--- Setup global variable prefix
   globalVarPrefix = "ToramaGrid_" + _Symbol + "_" + IntegerToString(magicNumber) + "_";
   
   //--- Load or initialize cumulative profit tracking
   LoadCumulativeStats();
   
   //--- Initialize reference price
   if(refPrice == 0.0)
   {
      refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
   
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
   
   Print("ToramaGrid Pro v2 initialized. Magic: ", magicNumber, " RefPrice: ", refPrice);
   Print("Individual TP: ", InpIndividualTPPercent > 0 ? "Enabled" : "Disabled");
   Print("Cumulative Profit: $", DoubleToString(cumulativeProfit, 2));
   
   if(InpDailyTargetPercent > 0)
   {
      double targetAmount = dailyStartBalance * (InpDailyTargetPercent / 100.0);
      Print("Daily Target: ", InpDailyTargetPercent, "% ($", DoubleToString(targetAmount, 2), ")");
      if(dailyTargetReached)
         Print("Daily target already reached today - EA will resume tomorrow");
   }
   
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
   Print("ToramaGrid Pro v2 deinitialized. Total Cumulative Profit: $", DoubleToString(cumulativeProfit, 2));
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
               " (Target: $", DoubleToString(targetAmount, 2), ") - Trading paused until tomorrow");
      }
      return;
   }
   
   //--- Check for global TP reached
   if(CheckGlobalTP())
   {
      //--- Add to cumulative profit before closing
      cumulativeProfit += globalProfit;
      SaveCumulativeStats();
      
      CloseAllPositions();
      ResetGridAfterClose();
      tpHitCount++;
      Print("Global TP reached: $", globalProfit, " - Grid reset. Total Cumulative: $", cumulativeProfit);
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
   
   //--- Track individual position closures and add to cumulative
   TrackClosedPositions();
   
   //--- Check for position closure (manual or SL hit)
   int currentPositionCount = CountMyPositions();
   if(lastPositionCount > 0 && currentPositionCount == 0)
   {
      ResetGridAfterClose();
   }
   lastPositionCount = currentPositionCount;
   
   //--- Manage existing positions (check individual TPs)
   if(InpIndividualTPPercent > 0)
   {
      ManageIndividualTPs();
   }
   
   //--- Check for new grid entries
   CheckGridLevels();
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
         
         //--- Manually resume trading (override daily target)
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
//| Check grid levels and open positions                             |
//+------------------------------------------------------------------+
void CheckGridLevels()
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double gap = refPrice * InpGapPercent / 100.0;
   
   if(gap <= 0)
   {
      Print("Error: Invalid gap calculation");
      return;
   }
   
   //--- Count current positions per side
   int buys = 0, sells = 0;
   CountBuysSells(buys, sells);
   
   //--- Check if we should open a BUY at current level (above reference)
   if(currentPrice > refPrice && buys < InpMaxPositionsPerSide)
   {
      // Calculate which grid level we're at (starting from 1)
      int level = (int)MathCeil((currentPrice - refPrice) / gap);
      if(level < 1) level = 1;
      
      double gridLevel = refPrice + (level * gap);
      
      // Check if we're close enough to a grid level
      if(MathAbs(currentPrice - gridLevel) <= gap * 0.1) // 10% of gap tolerance
      {
         if(!HasActivePositionAtLevel(gridLevel, ORDER_TYPE_BUY))
         {
            OpenGridPosition(ORDER_TYPE_BUY, gridLevel);
         }
      }
   }
   
   //--- Check if we should open a SELL at current level (below reference)
   if(currentPrice < refPrice && sells < InpMaxPositionsPerSide)
   {
      // Calculate which grid level we're at (starting from 1)
      int level = (int)MathCeil((refPrice - currentPrice) / gap);
      if(level < 1) level = 1;
      
      double gridLevel = refPrice - (level * gap);
      
      // Check if we're close enough to a grid level
      if(MathAbs(currentPrice - gridLevel) <= gap * 0.1) // 10% of gap tolerance
      {
         if(!HasActivePositionAtLevel(gridLevel, ORDER_TYPE_SELL))
         {
            OpenGridPosition(ORDER_TYPE_SELL, gridLevel);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if ACTIVE position exists at grid level                    |
//+------------------------------------------------------------------+
bool HasActivePositionAtLevel(double level, ENUM_ORDER_TYPE type)
{
   double tolerance = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 50;
   
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
            
            if(MathAbs(openPrice - level) < tolerance)
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
//| Open grid position with optional individual TP                   |
//+------------------------------------------------------------------+
void OpenGridPosition(ENUM_ORDER_TYPE type, double gridLevel)
{
   double lotSize = NormalizeLotSize(InpBaseLotSize);
   if(lotSize <= 0)
   {
      Print("Error: Invalid lot size");
      return;
   }
   
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double gap = refPrice * InpGapPercent / 100.0;
   
   //--- Calculate individual TP if enabled
   double tp = 0;
   if(InpIndividualTPPercent > 0)
   {
      double tpDistance = gap * (InpIndividualTPPercent / 100.0);
      if(type == ORDER_TYPE_BUY)
         tp = price + tpDistance;
      else
         tp = price - tpDistance;
   }
   
   //--- Open position
   bool result = false;
   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(lotSize, _Symbol, price, 0, tp, InpComment);
   else
      result = trade.Sell(lotSize, _Symbol, price, 0, tp, InpComment);
   
   if(result)
   {
      string tpInfo = (tp > 0) ? " TP: " + DoubleToString(tp, _Digits) : " (Global TP only)";
      Print("Grid position opened: ", EnumToString(type), " at ", DoubleToString(gridLevel, _Digits), 
            " (Lot: ", lotSize, ")", tpInfo);
   }
   else
   {
      Print("Error opening position: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Manage individual TPs                                            |
//+------------------------------------------------------------------+
void ManageIndividualTPs()
{
   // TPs are set at order opening, MT5 handles execution
   // This function can be used for TP modification if needed
   // Currently positions close automatically when TP is hit
}

//+------------------------------------------------------------------+
//| Normalize lot size to broker requirements                        |
//+------------------------------------------------------------------+
double NormalizeLotSize(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(lots < minLot)
      lots = minLot;
   
   if(lots > maxLot)
      lots = maxLot;
   
   lots = MathFloor(lots / lotStep) * lotStep;
   
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Check global TP                                                  |
//+------------------------------------------------------------------+
bool CheckGlobalTP()
{
   if(globalProfit >= InpGlobalTPDollar)
   {
      Print("Global TP reached: $", globalProfit);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check drawdown limit                                             |
//+------------------------------------------------------------------+
bool CheckDrawdownLimit()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   if(balance <= 0)
      return false;
   
   double drawdown = ((balance - equity) / balance) * 100.0;
   
   if(drawdown >= InpMaxDrawdownPercent)
   {
      Print("Max Drawdown reached: ", DoubleToString(drawdown, 2), "%");
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Update global profit                                             |
//+------------------------------------------------------------------+
void UpdateGlobalProfit()
{
   globalProfit = 0.0;
   
   //--- Calculate from all open positions
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
//| Check if new day                                                 |
//+------------------------------------------------------------------+
void CheckNewDay()
{
   datetime newDay = GetStartOfDay();
   
   if(newDay > currentDay)
   {
      //--- New day started - reset daily tracking
      currentDay = newDay;
      startOfDay = newDay;
      startDayBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyProfit = 0.0;
      dailyTargetReached = false;
      
      //--- Resume trading if it was paused for daily target
      if(eaStatus == "Daily Target Hit")
      {
         eaPaused = false;
         eaStatus = "Active";
         Print("New day started. Daily target reset. Trading resumed. Balance: $", dailyStartBalance);
      }
      else
      {
         Print("New day started. Balance: $", startDayBalance);
      }
      
      SaveDailyTargetStatus();
   }
}

//+------------------------------------------------------------------+
//| Get start of current day                                         |
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
//| Count my positions                                                |
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
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count buys and sells separately                                  |
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
//| Reset grid after all positions closed                            |
//+------------------------------------------------------------------+
void ResetGridAfterClose()
{
   refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   Print("Grid reset after position closure. New reference: ", refPrice);
}

//+------------------------------------------------------------------+
//| Close all positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == magicNumber)
         {
            if(!trade.PositionClose(ticket))
            {
               Print("Error closing position ", ticket, ": ", trade.ResultRetcode());
            }
         }
      }
   }
   Print("All positions closed");
}

//+------------------------------------------------------------------+
//| Reset reference price                                            |
//+------------------------------------------------------------------+
void ResetReference()
{
   refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   eaPaused = false;
   eaStatus = "Active";
   Print("Reference price reset to: ", refPrice);
}

//+------------------------------------------------------------------+
//| Create UI Panel                                                  |
//+------------------------------------------------------------------+
void CreatePanel()
{
   //--- Main panel background
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
   ObjectSetInteger(0, "ToramaPanelBG", OBJPROP_ZORDER, 0);
   
   //--- Title
   CreateLabel("ToramaPanelTitle", "TORAMA GRID PRO V2", panelX + 10, panelY + 8, 10, clrWhiteSmoke, ANCHOR_LEFT_UPPER);
   
   int yOffset = panelY + 35;
   int col1 = panelX + 10;
   int col2 = panelX + 160;
   
   //--- Status
   CreateLabel("ToramaPanelLblStatus", "Status:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValStatus", "", col1 + 45, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   yOffset += 20;
   
   //--- Balance & Equity on same line
   CreateLabel("ToramaPanelLblBalance", "Bal:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValBalance", "", col1 + 30, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblEquity", "Eq:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValEquity", "", col2 + 25, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Margin & Global Profit on same line
   CreateLabel("ToramaPanelLblMargin", "Margin:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValMargin", "", col1 + 45, yOffset, 8, clrYellow, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblGlobalPnL", "Profit:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValGlobalPnL", "", col2 + 40, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 22;
   
   //--- Global TP Target
   CreateLabel("ToramaPanelLblGlobalTP", "Global TP Target:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValGlobalTP", "", col1 + 105, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   yOffset += 22;
   
   //--- Daily Profit & Target (if enabled)
   CreateLabel("ToramaPanelLblDailyProfit", "Today's Profit:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValDailyProfit", "", col1 + 85, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   CreateLabel("ToramaPanelLblDailyTarget", "Daily Target:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValDailyTarget", "", col1 + 75, yOffset, 8, clrYellow, ANCHOR_LEFT_UPPER);
   yOffset += 22;
   
   //--- Gap Info
   CreateLabel("ToramaPanelLblGap", "Gap:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValGapPct", "", col1 + 30, yOffset, 8, clrAqua, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValGapUSD", "", col2 + 15, yOffset, 8, clrAqua, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Ref Price & Current Price on same line
   CreateLabel("ToramaPanelLblRefPrice", "Ref:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValRefPrice", "", col1 + 30, yOffset, 8, clrAqua, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblCurrPrice", "Curr:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValCurrPrice", "", col2 + 35, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Next Buy & Next Sell on same line
   CreateLabel("ToramaPanelLblNextBuy", "Buy:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValNextBuy", "", col1 + 30, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblNextSell", "Sell:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValNextSell", "", col2 + 30, yOffset, 8, clrRed, ANCHOR_LEFT_UPPER);
   yOffset += 22;
   
   //--- Max Positions
   CreateLabel("ToramaPanelLblMaxPos", "Max Pos/Side:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValMaxPos", "", col1 + 80, yOffset, 8, clrYellow, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Grid Cycles & Position Count on same line
   CreateLabel("ToramaPanelLblTPHits", "Cycles:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValTPHits", "", col1 + 45, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblPosCount", "Total:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValPosCount", "", col2 + 35, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Buys & Sells on same line
   CreateLabel("ToramaPanelLblBuys", "Buys:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValBuys", "", col1 + 40, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblSells", "Sells:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValSells", "", col2 + 35, yOffset, 8, clrRed, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Net Position
   CreateLabel("ToramaPanelLblNet", "Net:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValNet", "", col1 + 30, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Individual TP Info
   CreateLabel("ToramaPanelLblIndTP", "Ind. TP:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValIndTP", "", col1 + 50, yOffset, 8, clrAqua, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Magic Number
   CreateLabel("ToramaPanelLblMagic", "Magic:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValMagic", "", col1 + 40, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 22;
   
   //--- Separator line
   CreateLabel("ToramaPanelSeparator", "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", col1, yOffset, 8, clrGray, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- CUMULATIVE PROFIT (Highlighted)
   CreateLabel("ToramaPanelLblCumulative", "TOTAL PROFIT:", col1, yOffset, 9, clrYellow, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValCumulative", "", col1 + 85, yOffset, 9, clrLime, ANCHOR_LEFT_UPPER);
   ObjectSetString(0, "ToramaPanelLblCumulative", OBJPROP_FONT, "Arial Bold");
   ObjectSetString(0, "ToramaPanelValCumulative", OBJPROP_FONT, "Arial Bold");
   yOffset += 25;
   
   //--- Buttons
   int btnY = yOffset;
   CreateButton("ToramaPanelBtnReset", "RESET REF", panelX + 10, btnY, buttonWidth, buttonHeight);
   CreateButton("ToramaPanelBtnClose", "CLOSE ALL", panelX + 10 + buttonWidth + buttonSpacing, btnY, buttonWidth, buttonHeight);
   
   //--- Resume button (shown when daily target hit)
   btnY += buttonHeight + buttonSpacing;
   CreateButton("ToramaPanelBtnResume", "RESUME", panelX + 10, btnY, (buttonWidth * 2) + buttonSpacing, buttonHeight);
   ObjectSetInteger(0, "ToramaPanelBtnResume", OBJPROP_BGCOLOR, C'200,50,50'); // Red color
   ObjectSetInteger(0, "ToramaPanelBtnResume", OBJPROP_HIDDEN, true); // Hidden by default
   
   //--- Branding
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
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1);
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
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 2);
}

//+------------------------------------------------------------------+
//| Update panel with current values                                 |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   //--- Status with color
   ObjectSetString(0, "ToramaPanelValStatus", OBJPROP_TEXT, eaStatus);
   color statusColor = clrLime;
   if(StringFind(eaStatus, "Stopped") >= 0)
      statusColor = clrRed;
   ObjectSetInteger(0, "ToramaPanelValStatus", OBJPROP_COLOR, statusColor);
   
   //--- Account info
   ObjectSetString(0, "ToramaPanelValBalance", OBJPROP_TEXT, DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   ObjectSetString(0, "ToramaPanelValEquity", OBJPROP_TEXT, DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   ObjectSetString(0, "ToramaPanelValMargin", OBJPROP_TEXT, DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2));
   
   //--- Global Profit with color and progress
   string profitText = "$" + DoubleToString(globalProfit, 2);
   double progress = (globalProfit / InpGlobalTPDollar) * 100.0;
   profitText += " (" + DoubleToString(progress, 1) + "%)";
   ObjectSetString(0, "ToramaPanelValGlobalPnL", OBJPROP_TEXT, profitText);
   ObjectSetInteger(0, "ToramaPanelValGlobalPnL", OBJPROP_COLOR, globalProfit >= 0 ? clrLime : clrRed);
   
   //--- Global TP Target
   ObjectSetString(0, "ToramaPanelValGlobalTP", OBJPROP_TEXT, "$" + DoubleToString(InpGlobalTPDollar, 2));
   
   //--- Daily Profit & Target
   if(InpDailyTargetPercent > 0)
   {
      double targetAmount = dailyStartBalance * (InpDailyTargetPercent / 100.0);
      double dailyProgress = (dailyProfit / targetAmount) * 100.0;
      
      string dailyProfitText = "$" + DoubleToString(dailyProfit, 2);
      dailyProfitText += " (" + DoubleToString(dailyProgress, 1) + "%)";
      
      ObjectSetString(0, "ToramaPanelValDailyProfit", OBJPROP_TEXT, dailyProfitText);
      ObjectSetInteger(0, "ToramaPanelValDailyProfit", OBJPROP_COLOR, dailyProfit >= 0 ? clrLime : clrRed);
      
      string dailyTargetText = DoubleToString(InpDailyTargetPercent, 1) + "% ($" + DoubleToString(targetAmount, 2) + ")";
      ObjectSetString(0, "ToramaPanelValDailyTarget", OBJPROP_TEXT, dailyTargetText);
      
      if(dailyTargetReached)
      {
         ObjectSetInteger(0, "ToramaPanelValDailyTarget", OBJPROP_COLOR, clrLime);
         ObjectSetInteger(0, "ToramaPanelLblDailyTarget", OBJPROP_COLOR, clrLime);
      }
      else
      {
         ObjectSetInteger(0, "ToramaPanelValDailyTarget", OBJPROP_COLOR, clrYellow);
         ObjectSetInteger(0, "ToramaPanelLblDailyTarget", OBJPROP_COLOR, textColor);
      }
   }
   else
   {
      ObjectSetString(0, "ToramaPanelValDailyProfit", OBJPROP_TEXT, "$" + DoubleToString(dailyProfit, 2));
      ObjectSetInteger(0, "ToramaPanelValDailyProfit", OBJPROP_COLOR, dailyProfit >= 0 ? clrLime : clrRed);
      ObjectSetString(0, "ToramaPanelValDailyTarget", OBJPROP_TEXT, "Disabled");
      ObjectSetInteger(0, "ToramaPanelValDailyTarget", OBJPROP_COLOR, clrGray);
   }
   
   //--- Gap in % and USD
   double gap = refPrice * InpGapPercent / 100.0;
   string gapPctText = DoubleToString(InpGapPercent, 2) + "%";
   string gapUsdText = "($" + DoubleToString(gap, _Digits) + ")";
   ObjectSetString(0, "ToramaPanelValGapPct", OBJPROP_TEXT, gapPctText);
   ObjectSetString(0, "ToramaPanelValGapUSD", OBJPROP_TEXT, gapUsdText);
   
   //--- Grid info
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   ObjectSetString(0, "ToramaPanelValRefPrice", OBJPROP_TEXT, DoubleToString(refPrice, _Digits));
   ObjectSetString(0, "ToramaPanelValCurrPrice", OBJPROP_TEXT, DoubleToString(currentPrice, _Digits));
   
   //--- Calculate next grid levels
   double nextBuy = refPrice + gap;
   double nextSell = refPrice - gap;
   
   if(currentPrice > refPrice)
   {
      int level = (int)MathCeil((currentPrice - refPrice) / gap);
      if(level < 1) level = 1;
      nextBuy = refPrice + (level * gap);
   }
   else if(currentPrice < refPrice)
   {
      int level = (int)MathCeil((refPrice - currentPrice) / gap);
      if(level < 1) level = 1;
      nextSell = refPrice - (level * gap);
   }
   
   ObjectSetString(0, "ToramaPanelValNextBuy", OBJPROP_TEXT, DoubleToString(nextBuy, _Digits));
   ObjectSetString(0, "ToramaPanelValNextSell", OBJPROP_TEXT, DoubleToString(nextSell, _Digits));
   
   //--- Max Positions
   ObjectSetString(0, "ToramaPanelValMaxPos", OBJPROP_TEXT, IntegerToString(InpMaxPositionsPerSide));
   
   //--- Statistics
   int buys = 0, sells = 0;
   CountBuysSells(buys, sells);
   int net = buys - sells;
   
   ObjectSetString(0, "ToramaPanelValTPHits", OBJPROP_TEXT, IntegerToString(tpHitCount));
   ObjectSetString(0, "ToramaPanelValPosCount", OBJPROP_TEXT, IntegerToString(CountMyPositions()));
   
   ObjectSetString(0, "ToramaPanelValBuys", OBJPROP_TEXT, IntegerToString(buys));
   ObjectSetString(0, "ToramaPanelValSells", OBJPROP_TEXT, IntegerToString(sells));
   
   //--- Net position with color indication
   string netText = IntegerToString(net);
   if(net > 0)
      netText = "+" + netText + " (Long)";
   else if(net < 0)
      netText = netText + " (Short)";
   else
      netText = netText + " (Flat)";
   
   ObjectSetString(0, "ToramaPanelValNet", OBJPROP_TEXT, netText);
   color netColor = clrWhite;
   if(net > 0) netColor = clrLime;
   else if(net < 0) netColor = clrRed;
   ObjectSetInteger(0, "ToramaPanelValNet", OBJPROP_COLOR, netColor);
   
   //--- Individual TP status
   string indTPText = (InpIndividualTPPercent > 0) ? DoubleToString(InpIndividualTPPercent, 1) + "% gap" : "Disabled";
   ObjectSetString(0, "ToramaPanelValIndTP", OBJPROP_TEXT, indTPText);
   ObjectSetInteger(0, "ToramaPanelValIndTP", OBJPROP_COLOR, (InpIndividualTPPercent > 0) ? clrLime : clrGray);
   
   ObjectSetString(0, "ToramaPanelValMagic", OBJPROP_TEXT, IntegerToString(magicNumber));
   
   //--- Cumulative Profit (Total since EA activated)
   ObjectSetString(0, "ToramaPanelValCumulative", OBJPROP_TEXT, "$" + DoubleToString(cumulativeProfit, 2));
   ObjectSetInteger(0, "ToramaPanelValCumulative", OBJPROP_COLOR, cumulativeProfit >= 0 ? clrLime : clrRed);
   
   //--- Show/Hide RESUME button based on daily target status
   if(dailyTargetReached && eaPaused)
   {
      ObjectSetInteger(0, "ToramaPanelBtnResume", OBJPROP_HIDDEN, false);
   }
   else
   {
      ObjectSetInteger(0, "ToramaPanelBtnResume", OBJPROP_HIDDEN, true);
   }
}

//+------------------------------------------------------------------+
//| Update daily profit                                              |
//+------------------------------------------------------------------+
void UpdateDailyProfit()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   //--- Daily profit = (Current Equity - Starting Balance for the day)
   dailyProfit = currentEquity - dailyStartBalance;
}

//+------------------------------------------------------------------+
//| Check if daily target reached                                    |
//+------------------------------------------------------------------+
bool CheckDailyTarget()
{
   if(InpDailyTargetPercent <= 0)
      return false;
   
   double targetAmount = dailyStartBalance * (InpDailyTargetPercent / 100.0);
   
   if(dailyProfit >= targetAmount)
   {
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Load daily target status from GlobalVariables                    |
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
      
      //--- If same day, load previous status
      if(savedDay == currentDay)
      {
         dailyStartBalance = GlobalVariableGet(varDailyBalance);
         dailyProfit = GlobalVariableGet(varDailyProfit);
         dailyTargetReached = (bool)GlobalVariableGet(varTargetReached);
         
         if(dailyTargetReached)
         {
            eaPaused = true;
            eaStatus = "Daily Target Hit";
            Print("Loaded daily status: Target already reached today");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Save daily target status to GlobalVariables                      |
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
//| Load cumulative statistics from GlobalVariables                  |
//+------------------------------------------------------------------+
void LoadCumulativeStats()
{
   string varCumProfit = globalVarPrefix + "CumulativeProfit";
   string varTPHits = globalVarPrefix + "TPHits";
   string varStartBalance = globalVarPrefix + "StartBalance";
   string varLastDeal = globalVarPrefix + "LastDealTicket";
   
   //--- Check if global variables exist
   if(GlobalVariableCheck(varCumProfit))
   {
      cumulativeProfit = GlobalVariableGet(varCumProfit);
      tpHitCount = (int)GlobalVariableGet(varTPHits);
      sessionStartBalance = GlobalVariableGet(varStartBalance);
      
      Print("Loaded cumulative stats - Profit: $", cumulativeProfit, " | TP Hits: ", tpHitCount);
   }
   else
   {
      //--- First time initialization
      cumulativeProfit = 0.0;
      tpHitCount = 0;
      sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      
      //--- Save initial values
      SaveCumulativeStats();
      
      Print("Initialized new session - Starting Balance: $", sessionStartBalance);
   }
}

//+------------------------------------------------------------------+
//| Save cumulative statistics to GlobalVariables                    |
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
//| Track closed positions and add to cumulative profit              |
//+------------------------------------------------------------------+
void TrackClosedPositions()
{
   static ulong lastCheckedDeal = 0;
   string varLastDeal = globalVarPrefix + "LastDealTicket";
   
   //--- Load last checked deal ticket
   if(lastCheckedDeal == 0 && GlobalVariableCheck(varLastDeal))
   {
      lastCheckedDeal = (ulong)GlobalVariableGet(varLastDeal);
   }
   
   //--- Get total number of deals in history
   HistorySelect(0, TimeCurrent());
   int totalDeals = HistoryDealsTotal();
   
   //--- Check recent deals
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket <= lastCheckedDeal)
         break; // Already processed this deal
      
      //--- Check if deal belongs to this EA
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == magicNumber &&
         HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol)
      {
         //--- Check if it's a position exit (not entry)
         ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(dealEntry == DEAL_ENTRY_OUT)
         {
            double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            double dealSwap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            double dealCommission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            
            double netProfit = dealProfit + dealSwap + dealCommission;
            
            //--- Add to cumulative (but not if we just closed all for global TP)
            // Global TP closure is handled separately to avoid double counting
            if(CountMyPositions() > 0)  // Still have positions, so this was individual TP
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
//| Reset cumulative statistics (called from button or manually)     |
//+------------------------------------------------------------------+
void ResetCumulativeStats()
{
   cumulativeProfit = 0.0;
   tpHitCount = 0;
   sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   SaveCumulativeStats();
   
   Print("Cumulative statistics reset. New starting balance: $", sessionStartBalance);
}

//+------------------------------------------------------------------+
