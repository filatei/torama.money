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
input double InpTakeProfitPercent = 0.3;       // TP % (before next grid level)
input int InpMaxGridLevelsSL = 2;              // Max Grid Levels for SL
input double InpBaseLotSize = 0.01;            // Base Lot Size

input group "=== Risk Management ==="
input double InpMaxDrawdownPercent = 5.0;     // Max Drawdown % (default 5%)
input double InpDailyProfitPercent = 10.0;    // Daily Profit Target % (default 10%)

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
double dailyPnL = 0.0;

//--- Panel coordinates and sizes
int panelX = 20;
int panelY = 30;
int panelWidth = 280;
int panelHeight = 520;
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
   
   //--- Update daily P/L
   UpdateDailyPnL();
   
   //--- Check risk limits
   if(CheckDrawdownLimit() || CheckDailyProfitTarget())
   {
      if(!eaPaused)
      {
         CloseAllPositions();
         eaPaused = true;
         Print("EA Paused due to risk limit breach");
      }
      return;
   }
   
   //--- Don't trade if paused
   if(eaPaused)
      return;
   
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
   
   //--- Calculate grid levels
   int levelsAbove = (int)MathFloor((currentPrice - refPrice) / gap);
   int levelsBelow = (int)MathFloor((refPrice - currentPrice) / gap);
   
   //--- Check for buy opportunities (price above reference)
   if(currentPrice > refPrice)
   {
      for(int i = 1; i <= levelsAbove; i++)
      {
         double gridLevel = refPrice + (i * gap);
         if(!HasPositionAtLevel(gridLevel, ORDER_TYPE_BUY))
         {
            if(currentPrice >= gridLevel)
            {
               OpenGridPosition(ORDER_TYPE_BUY, gridLevel);
            }
         }
      }
   }
   
   //--- Check for sell opportunities (price below reference)
   if(currentPrice < refPrice)
   {
      for(int i = 1; i <= levelsBelow; i++)
      {
         double gridLevel = refPrice - (i * gap);
         if(!HasPositionAtLevel(gridLevel, ORDER_TYPE_SELL))
         {
            if(currentPrice <= gridLevel)
            {
               OpenGridPosition(ORDER_TYPE_SELL, gridLevel);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if position exists at grid level                           |
//+------------------------------------------------------------------+
bool HasPositionAtLevel(double level, ENUM_ORDER_TYPE type)
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
   
   double gap = refPrice * InpGapPercent / 100.0;
   double tpDistance = gap * InpTakeProfitPercent / 100.0;
   double slDistance = gap * InpMaxGridLevelsSL;
   
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   //--- Calculate TP and SL
   double tp = 0, sl = 0;
   
   if(type == ORDER_TYPE_BUY)
   {
      tp = NormalizeDouble(gridLevel + tpDistance, _Digits);
      sl = NormalizeDouble(gridLevel - slDistance, _Digits);
   }
   else // SELL
   {
      tp = NormalizeDouble(gridLevel - tpDistance, _Digits);
      sl = NormalizeDouble(gridLevel + slDistance, _Digits);
   }
   
   //--- Validate SL and TP distances
   double minStopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   
   if(type == ORDER_TYPE_BUY)
   {
      if(tp - price < minStopLevel) tp = price + minStopLevel;
      if(price - sl < minStopLevel) sl = price - minStopLevel;
   }
   else
   {
      if(price - tp < minStopLevel) tp = price - minStopLevel;
      if(sl - price < minStopLevel) sl = price + minStopLevel;
   }
   
   //--- Open position
   bool result = false;
   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(lotSize, _Symbol, price, sl, tp, InpComment);
   else
      result = trade.Sell(lotSize, _Symbol, price, sl, tp, InpComment);
   
   if(result)
   {
      Print("Grid position opened: ", EnumToString(type), " at ", gridLevel, " TP: ", tp, " SL: ", sl);
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
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == magicNumber)
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            
            //--- Track TP and SL hits
            if(profit > 0)
            {
               double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
               double tp = PositionGetDouble(POSITION_TP);
               
               ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
               
               //--- Check if TP is hit
               if(posType == POSITION_TYPE_BUY && currentPrice >= tp)
               {
                  tpHitCount++;
               }
               else if(posType == POSITION_TYPE_SELL && currentPrice <= tp)
               {
                  tpHitCount++;
               }
            }
         }
      }
   }
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
//| Check daily profit target                                        |
//+------------------------------------------------------------------+
bool CheckDailyProfitTarget()
{
   double profitPercent = (dailyPnL / startDayBalance) * 100.0;
   
   if(profitPercent >= InpDailyProfitPercent)
   {
      Print("Daily Profit Target reached: ", profitPercent, "%");
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Update daily P/L                                                 |
//+------------------------------------------------------------------+
void UpdateDailyPnL()
{
   dailyPnL = 0.0;
   
   //--- Calculate from closed positions today
   datetime today = GetStartOfDay();
   
   if(!HistorySelect(today, TimeCurrent()))
      return;
   
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
      {
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
            HistoryDealGetInteger(ticket, DEAL_MAGIC) == magicNumber)
         {
            dailyPnL += HistoryDealGetDouble(ticket, DEAL_PROFIT);
            dailyPnL += HistoryDealGetDouble(ticket, DEAL_SWAP);
            dailyPnL += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         }
      }
   }
   
   //--- Add open positions profit
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == magicNumber)
         {
            dailyPnL += PositionGetDouble(POSITION_PROFIT);
            dailyPnL += PositionGetDouble(POSITION_SWAP);
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
      dailyPnL = 0.0;
      eaPaused = false;
      tpHitCount = 0;
      slHitCount = 0;
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
   
   int yOffset = panelY + 40;
   
   //--- Account Info
   CreateLabel("ToramaPanelLblBalance", "Balance:", panelX + 10, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValBalance", "", panelX + panelWidth - 10, yOffset, 8, clrLime, ANCHOR_RIGHT_UPPER);
   yOffset += 20;
   
   CreateLabel("ToramaPanelLblEquity", "Equity:", panelX + 10, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValEquity", "", panelX + panelWidth - 10, yOffset, 8, clrLime, ANCHOR_RIGHT_UPPER);
   yOffset += 20;
   
   CreateLabel("ToramaPanelLblMargin", "Margin:", panelX + 10, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValMargin", "", panelX + panelWidth - 10, yOffset, 8, clrYellow, ANCHOR_RIGHT_UPPER);
   yOffset += 20;
   
   CreateLabel("ToramaPanelLblDailyPL", "Daily P/L:", panelX + 10, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValDailyPL", "", panelX + panelWidth - 10, yOffset, 8, clrWhite, ANCHOR_RIGHT_UPPER);
   yOffset += 25;
   
   //--- Grid Info
   CreateLabel("ToramaPanelLblRefPrice", "Ref Price:", panelX + 10, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValRefPrice", "", panelX + panelWidth - 10, yOffset, 8, clrAqua, ANCHOR_RIGHT_UPPER);
   yOffset += 20;
   
   CreateLabel("ToramaPanelLblCurrPrice", "Curr Price:", panelX + 10, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValCurrPrice", "", panelX + panelWidth - 10, yOffset, 8, clrWhite, ANCHOR_RIGHT_UPPER);
   yOffset += 20;
   
   CreateLabel("ToramaPanelLblNextBuy", "Next Buy:", panelX + 10, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValNextBuy", "", panelX + panelWidth - 10, yOffset, 8, clrLime, ANCHOR_RIGHT_UPPER);
   yOffset += 20;
   
   CreateLabel("ToramaPanelLblNextSell", "Next Sell:", panelX + 10, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValNextSell", "", panelX + panelWidth - 10, yOffset, 8, clrRed, ANCHOR_RIGHT_UPPER);
   yOffset += 20;
   
   CreateLabel("ToramaPanelLblTPTarget", "TP Target:", panelX + 10, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValTPTarget", "", panelX + panelWidth - 10, yOffset, 8, clrLime, ANCHOR_RIGHT_UPPER);
   yOffset += 20;
   
   CreateLabel("ToramaPanelLblSLTarget", "SL Target:", panelX + 10, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValSLTarget", "", panelX + panelWidth - 10, yOffset, 8, clrRed, ANCHOR_RIGHT_UPPER);
   yOffset += 25;
   
   //--- Statistics
   CreateLabel("ToramaPanelLblTPHits", "TP Hits:", panelX + 10, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValTPHits", "", panelX + panelWidth - 10, yOffset, 8, clrLime, ANCHOR_RIGHT_UPPER);
   yOffset += 20;
   
   CreateLabel("ToramaPanelLblSLHits", "SL Hits:", panelX + 10, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValSLHits", "", panelX + panelWidth - 10, yOffset, 8, clrRed, ANCHOR_RIGHT_UPPER);
   yOffset += 20;
   
   CreateLabel("ToramaPanelLblMagic", "Magic No:", panelX + 10, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValMagic", "", panelX + panelWidth - 10, yOffset, 8, clrWhite, ANCHOR_RIGHT_UPPER);
   yOffset += 30;
   
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
   //--- Account info
   ObjectSetString(0, "ToramaPanelValBalance", OBJPROP_TEXT, DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   ObjectSetString(0, "ToramaPanelValEquity", OBJPROP_TEXT, DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   ObjectSetString(0, "ToramaPanelValMargin", OBJPROP_TEXT, DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2));
   
   //--- Daily P/L with color
   double plPercent = (dailyPnL / startDayBalance) * 100.0;
   string plText = DoubleToString(dailyPnL, 2) + " (" + DoubleToString(plPercent, 2) + "%)";
   ObjectSetString(0, "ToramaPanelValDailyPL", OBJPROP_TEXT, plText);
   ObjectSetInteger(0, "ToramaPanelValDailyPL", OBJPROP_COLOR, dailyPnL >= 0 ? clrLime : clrRed);
   
   //--- Grid info
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double gap = refPrice * InpGapPercent / 100.0;
   
   ObjectSetString(0, "ToramaPanelValRefPrice", OBJPROP_TEXT, DoubleToString(refPrice, _Digits));
   ObjectSetString(0, "ToramaPanelValCurrPrice", OBJPROP_TEXT, DoubleToString(currentPrice, _Digits));
   
   //--- Calculate next grid levels
   double nextBuy = 0, nextSell = 0;
   if(currentPrice > refPrice)
   {
      int levelsAbove = (int)MathCeil((currentPrice - refPrice) / gap);
      nextBuy = refPrice + (levelsAbove * gap);
      nextSell = refPrice;
   }
   else
   {
      int levelsBelow = (int)MathCeil((refPrice - currentPrice) / gap);
      nextBuy = refPrice;
      nextSell = refPrice - (levelsBelow * gap);
   }
   
   ObjectSetString(0, "ToramaPanelValNextBuy", OBJPROP_TEXT, DoubleToString(nextBuy, _Digits));
   ObjectSetString(0, "ToramaPanelValNextSell", OBJPROP_TEXT, DoubleToString(nextSell, _Digits));
   
   //--- TP and SL targets
   double tpDistance = gap * InpTakeProfitPercent / 100.0;
   double slDistance = gap * InpMaxGridLevelsSL;
   
   ObjectSetString(0, "ToramaPanelValTPTarget", OBJPROP_TEXT, DoubleToString(tpDistance, _Digits));
   ObjectSetString(0, "ToramaPanelValSLTarget", OBJPROP_TEXT, DoubleToString(slDistance, _Digits));
   
   //--- Statistics
   ObjectSetString(0, "ToramaPanelValTPHits", OBJPROP_TEXT, IntegerToString(tpHitCount));
   ObjectSetString(0, "ToramaPanelValSLHits", OBJPROP_TEXT, IntegerToString(slHitCount));
   ObjectSetString(0, "ToramaPanelValMagic", OBJPROP_TEXT, IntegerToString(magicNumber));
}

//+------------------------------------------------------------------+
