//+------------------------------------------------------------------+
//|                                              ToramaGrid_Pro.mq5 |
//|                                          TORAMA CAPITAL          |
//|                                          https://torama.money    |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "=== Grid Settings ==="
input double InpGapPercent = 0.5;              // Gap Percentage of Price
input double InpBaseLotSize = 0.01;            // Base Lot Size

input group "=== Risk Management ==="
input double InpGlobalTPDollar = 100.0;        // Global Take Profit (USD)
input double InpMaxDrawdownPercent = 50.0;     // Max Drawdown % (default 50%)

input group "=== EA Settings ==="
input int InpMagicNumber = 0;                  // Magic Number (0=ChartID)
input string InpComment = "ToramaGrid";        // Trade Comment

//--- Global Variables
CTrade trade;
int magicNumber;
double refPrice = 0.0;
datetime startOfDay;
double startDayBalance;
bool eaPaused = false;

//--- Statistics
int tpHitCount = 0;
int slHitCount = 0;
double globalProfit = 0.0;
int lastPositionCount = 0;
string eaStatus = "Active";

//--- Panel coordinates and sizes
int panelX = 20;
int panelY = 30;
int panelWidth = 280;
int panelHeight = 380;
int buttonHeight = 25;
int buttonWidth = 85;
int buttonSpacing = 5;

//--- Colors
color bgColor = C'40,40,40';
color textColor = clrWhite;
color buttonColor = C'70,70,70';
color buttonPressedColor = C'100,100,100';
color brandColor = clrWhiteSmoke;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Set magic number
   magicNumber = (InpMagicNumber == 0) ? (int)ChartID() : InpMagicNumber;
   trade.SetExpertMagicNumber(magicNumber);
   
   //--- Initialize reference price
   if(refPrice == 0.0)
   {
      refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
   
   //--- Initialize day tracking
   startOfDay = GetStartOfDay();
   startDayBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   //--- Create UI Panel
   CreatePanel();
   
   //--- Set timer for panel updates
   EventSetTimer(1);
   
   Print("ToramaGrid Pro initialized. Magic: ", magicNumber, " RefPrice: ", refPrice);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Kill timer
   EventKillTimer();
   
   //--- Delete all objects
   ObjectsDeleteAll(0, "ToramaPanel");
   
   Print("ToramaGrid Pro deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Check if new day
   CheckNewDay();
   
   //--- Update global profit
   UpdateGlobalProfit();
   
   //--- Check for global TP reached
   if(CheckGlobalTP())
   {
      CloseAllPositions();
      ResetGridAfterClose();
      tpHitCount++;
      Print("Global TP reached: $", globalProfit, " - Grid reset");
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
   
   //--- Check for position closure (manual or SL hit)
   int currentPositionCount = CountMyPositions();
   if(lastPositionCount > 0 && currentPositionCount == 0)
   {
      ResetGridAfterClose();
      slHitCount++;
   }
   lastPositionCount = currentPositionCount;
   
   //--- Check and manage existing positions
   ManagePositions();
   
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
      else if(sparam == "ToramaPanelBtnTP")
      {
         ObjectSetInteger(0, "ToramaPanelBtnTP", OBJPROP_STATE, false);
         TakeAllProfits();
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
   
   //--- Check if we should open a BUY at current level (above reference)
   if(currentPrice > refPrice)
   {
      // Calculate which grid level we're at (starting from 1)
      int level = (int)MathRound((currentPrice - refPrice) / gap);
      if(level < 1) level = 1; // Ensure we start from first level, not at reference
      
      double gridLevel = refPrice + (level * gap);
      
      // Check if we're close enough to a grid level
      if(MathAbs(currentPrice - gridLevel) <= SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 50)
      {
         if(!HasActivePositionAtLevel(gridLevel, ORDER_TYPE_BUY))
         {
            OpenGridPosition(ORDER_TYPE_BUY, gridLevel);
         }
      }
   }
   
   //--- Check if we should open a SELL at current level (below reference)
   if(currentPrice < refPrice)
   {
      // Calculate which grid level we're at (starting from 1)
      int level = (int)MathRound((refPrice - currentPrice) / gap);
      if(level < 1) level = 1; // Ensure we start from first level, not at reference
      
      double gridLevel = refPrice - (level * gap);
      
      // Check if we're close enough to a grid level
      if(MathAbs(currentPrice - gridLevel) <= SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 50)
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
   double tolerance = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   
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
//| Open grid position                                                |
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
   
   //--- Open position without TP/SL (global TP management)
   bool result = false;
   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(lotSize, _Symbol, price, 0, 0, InpComment);
   else
      result = trade.Sell(lotSize, _Symbol, price, 0, 0, InpComment);
   
   if(result)
   {
      Print("Grid position opened: ", EnumToString(type), " at ", gridLevel, " (Lot: ", lotSize, ")");
   }
   else
   {
      Print("Error opening position: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Manage existing positions                                        |
//+------------------------------------------------------------------+
void ManagePositions()
{
   // Position management handled by global TP check
   // No individual TP/SL management needed
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
   double drawdown = ((balance - equity) / balance) * 100.0;
   
   if(drawdown >= InpMaxDrawdownPercent)
   {
      Print("Max Drawdown reached: ", drawdown, "%");
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
   datetime currentDay = GetStartOfDay();
   
   if(currentDay > startOfDay)
   {
      startOfDay = currentDay;
      startDayBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      eaPaused = false;
      eaStatus = "Active";
      Print("New day started. Balance: ", startDayBalance);
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
//| Take all profits (close profitable positions)                    |
//+------------------------------------------------------------------+
void TakeAllProfits()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == magicNumber)
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            if(profit > 0)
            {
               if(!trade.PositionClose(ticket))
               {
                  Print("Error closing profitable position ", ticket, ": ", trade.ResultRetcode());
               }
            }
         }
      }
   }
   Print("All profitable positions closed");
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
   CreateLabel("ToramaPanelTitle", "TORAMA GRID PRO", panelX + 10, panelY + 8, 10, clrWhiteSmoke, ANCHOR_LEFT_UPPER);
   
   int yOffset = panelY + 35;
   int col1 = panelX + 10;
   int col2 = panelX + 145;
   
   //--- Status
   CreateLabel("ToramaPanelLblStatus", "Status:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValStatus", "", col1 + 45, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   yOffset += 20;
   
   //--- Balance & Equity on same line
   CreateLabel("ToramaPanelLblBalance", "Bal:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValBalance", "", col1 + 30, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblEquity", "Eq:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValEquity", "", col2 + 25, yOffset, 8, clrLime, ANCHOR_RIGHT_UPPER);
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
   
   //--- Grid Cycles & Position Count on same line
   CreateLabel("ToramaPanelLblTPHits", "Cycles:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValTPHits", "", col1 + 45, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblPosCount", "Pos:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValPosCount", "", col2 + 30, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Magic Number
   CreateLabel("ToramaPanelLblMagic", "Magic:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValMagic", "", col1 + 40, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 25;
   
   //--- Buttons
   int btnY = yOffset;
   CreateButton("ToramaPanelBtnReset", "RESET REF", panelX + 10, btnY, buttonWidth, buttonHeight);
   CreateButton("ToramaPanelBtnClose", "CLOSE ALL", panelX + 10 + buttonWidth + buttonSpacing, btnY, buttonWidth, buttonHeight);
   CreateButton("ToramaPanelBtnTP", "TAKE TP", panelX + 10 + (buttonWidth + buttonSpacing) * 2, btnY, buttonWidth, buttonHeight);
   
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
   
   //--- Calculate next grid levels (first level away from reference)
   double nextBuy = refPrice + gap;  // First buy level above reference
   double nextSell = refPrice - gap; // First sell level below reference
   
   // If price is above reference, find next buy level
   if(currentPrice > refPrice)
   {
      int level = (int)MathCeil((currentPrice - refPrice) / gap);
      if(level < 1) level = 1;
      nextBuy = refPrice + (level * gap);
      
      // If we're past the first sell level, next sell is at reference - gap
      nextSell = refPrice - gap;
   }
   // If price is below reference, find next sell level
   else if(currentPrice < refPrice)
   {
      int level = (int)MathCeil((refPrice - currentPrice) / gap);
      if(level < 1) level = 1;
      nextSell = refPrice - (level * gap);
      
      // If we're past the first buy level, next buy is at reference + gap
      nextBuy = refPrice + gap;
   }
   
   ObjectSetString(0, "ToramaPanelValNextBuy", OBJPROP_TEXT, DoubleToString(nextBuy, _Digits));
   ObjectSetString(0, "ToramaPanelValNextSell", OBJPROP_TEXT, DoubleToString(nextSell, _Digits));
   
   //--- Statistics
   ObjectSetString(0, "ToramaPanelValTPHits", OBJPROP_TEXT, IntegerToString(tpHitCount));
   ObjectSetString(0, "ToramaPanelValPosCount", OBJPROP_TEXT, IntegerToString(CountMyPositions()));
   ObjectSetString(0, "ToramaPanelValMagic", OBJPROP_TEXT, IntegerToString(magicNumber));
}

//+------------------------------------------------------------------+
