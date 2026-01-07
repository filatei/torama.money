//+------------------------------------------------------------------+
//|                                         ToramaGrid_Classic.mq5 |
//|                                          TORAMA CAPITAL          |
//|                                          https://torama.money    |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "1.00"
#property description "Classic Unidirectional Grid Trading"
#property description "Buy down/Sell up with individual TP & optional SL"

#include <Trade\Trade.mqh>

//--- Enumerations
enum ENUM_GRID_DIRECTION
{
   GRID_BUY_ONLY = 0,    // Buy Only (Buy on dips)
   GRID_SELL_ONLY = 1    // Sell Only (Sell on rallies)
};

//--- Input Parameters
input group "=== Grid Direction ==="
input ENUM_GRID_DIRECTION InpGridDirection = GRID_BUY_ONLY;  // Grid Direction

input group "=== Grid Settings ==="
input double InpGapPercent = 0.5;              // Gap Percentage of Price
input double InpBaseLotSize = 0.01;            // Base Lot Size
input int InpMaxPositions = 10;                // Max Grid Positions

input group "=== Take Profit Settings ==="
input double InpIndividualTPPercent = 100.0;   // Individual TP % of Gap (100=1 gap)
input double InpGlobalTPDollar = 50.0;         // Global Take Profit (USD, 0=disabled)

input group "=== Stop Loss Settings ==="
input double InpIndividualSLPercent = 0.0;     // Individual SL % of Gap (0=disabled, 100=1 gap back)

input group "=== Risk Management ==="
input double InpMaxDrawdownPercent = 20.0;     // Max Drawdown % (default 20%)

input group "=== EA Settings ==="
input int InpMagicNumber = 0;                  // Magic Number (0=ChartID)
input string InpComment = "ToramaClassic";     // Trade Comment

//--- Global Variables
CTrade trade;
int magicNumber;
double refPrice = 0.0;
bool eaPaused = false;

//--- Statistics
int globalTPHitCount = 0;
int individualTPCount = 0;
int slHitCount = 0;
double globalProfit = 0.0;
string eaStatus = "Active";

//--- Panel coordinates and sizes
int panelX = 20;
int panelY = 30;
int panelWidth = 300;
int panelHeight = 450;
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
   
   //--- Initialize reference price
   if(refPrice == 0.0)
   {
      refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
   
   //--- Create UI Panel
   CreatePanel();
   
   //--- Set timer for panel updates
   EventSetTimer(1);
   
   string directionText = (InpGridDirection == GRID_BUY_ONLY) ? "BUY ONLY" : "SELL ONLY";
   Print("ToramaGrid Classic initialized. Direction: ", directionText);
   Print("Magic: ", magicNumber, " RefPrice: ", refPrice);
   Print("Individual TP: ", InpIndividualTPPercent, "% | SL: ", InpIndividualSLPercent, "%");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, "ToramaPanel");
   Print("ToramaGrid Classic deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Update global profit
   UpdateGlobalProfit();
   
   //--- Check for global TP reached (if enabled)
   if(InpGlobalTPDollar > 0 && CheckGlobalTP())
   {
      CloseAllPositions();
      ResetGridAfterClose();
      globalTPHitCount++;
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
   
   //--- Check if all positions closed (SL hit or manual close)
   if(CountMyPositions() == 0)
   {
      ResetGridAfterClose();
      slHitCount++;
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
         ResetGridAfterClose();
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
   
   //--- Check position count
   int currentPositions = CountMyPositions();
   if(currentPositions >= InpMaxPositions)
      return;
   
   //--- BUY ONLY Grid (Buy on dips - below reference)
   if(InpGridDirection == GRID_BUY_ONLY)
   {
      if(currentPrice < refPrice)
      {
         // Calculate which grid level we're at
         int level = (int)MathCeil((refPrice - currentPrice) / gap);
         if(level < 1) level = 1;
         
         double gridLevel = refPrice - (level * gap);
         
         // Check if we're close enough to a grid level
         if(MathAbs(currentPrice - gridLevel) <= gap * 0.1)
         {
            if(!HasActivePositionAtLevel(gridLevel, ORDER_TYPE_BUY))
            {
               OpenGridPosition(ORDER_TYPE_BUY, gridLevel);
            }
         }
      }
   }
   
   //--- SELL ONLY Grid (Sell on rallies - above reference)
   if(InpGridDirection == GRID_SELL_ONLY)
   {
      if(currentPrice > refPrice)
      {
         // Calculate which grid level we're at
         int level = (int)MathCeil((currentPrice - refPrice) / gap);
         if(level < 1) level = 1;
         
         double gridLevel = refPrice + (level * gap);
         
         // Check if we're close enough to a grid level
         if(MathAbs(currentPrice - gridLevel) <= gap * 0.1)
         {
            if(!HasActivePositionAtLevel(gridLevel, ORDER_TYPE_SELL))
            {
               OpenGridPosition(ORDER_TYPE_SELL, gridLevel);
            }
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
//| Open grid position with TP and optional SL                       |
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
   
   //--- Calculate Individual TP (always enabled for classic grid)
   double tp = 0;
   double tpDistance = gap * (InpIndividualTPPercent / 100.0);
   
   if(type == ORDER_TYPE_BUY)
   {
      tp = price + tpDistance;
   }
   else
   {
      tp = price - tpDistance;
   }
   
   //--- Calculate Individual SL (optional)
   double sl = 0;
   if(InpIndividualSLPercent > 0)
   {
      double slDistance = gap * (InpIndividualSLPercent / 100.0);
      
      if(type == ORDER_TYPE_BUY)
      {
         sl = price - slDistance;
      }
      else
      {
         sl = price + slDistance;
      }
   }
   
   //--- Open position
   bool result = false;
   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(lotSize, _Symbol, price, sl, tp, InpComment);
   else
      result = trade.Sell(lotSize, _Symbol, price, sl, tp, InpComment);
   
   if(result)
   {
      string slInfo = (sl > 0) ? " SL: " + DoubleToString(sl, _Digits) : " (No SL)";
      Print("Grid position opened: ", EnumToString(type), " at ", DoubleToString(gridLevel, _Digits), 
            " TP: ", DoubleToString(tp, _Digits), slInfo, " (Lot: ", lotSize, ")");
   }
   else
   {
      Print("Error opening position: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
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
   Print("Grid reset. New reference: ", refPrice);
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
   CreateLabel("ToramaPanelTitle", "TORAMA GRID CLASSIC", panelX + 10, panelY + 8, 10, clrWhiteSmoke, ANCHOR_LEFT_UPPER);
   
   int yOffset = panelY + 35;
   int col1 = panelX + 10;
   int col2 = panelX + 160;
   
   //--- Direction
   CreateLabel("ToramaPanelLblDirection", "Direction:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValDirection", "", col1 + 60, yOffset, 8, clrYellow, ANCHOR_LEFT_UPPER);
   yOffset += 20;
   
   //--- Status
   CreateLabel("ToramaPanelLblStatus", "Status:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValStatus", "", col1 + 45, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   yOffset += 20;
   
   //--- Balance & Equity
   CreateLabel("ToramaPanelLblBalance", "Bal:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValBalance", "", col1 + 30, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblEquity", "Eq:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValEquity", "", col2 + 25, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Margin & Global Profit
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
   
   //--- Ref Price & Current Price
   CreateLabel("ToramaPanelLblRefPrice", "Ref:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValRefPrice", "", col1 + 30, yOffset, 8, clrAqua, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblCurrPrice", "Curr:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValCurrPrice", "", col2 + 35, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Next Grid Level
   CreateLabel("ToramaPanelLblNextLevel", "Next Level:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValNextLevel", "", col1 + 65, yOffset, 8, clrYellow, ANCHOR_LEFT_UPPER);
   yOffset += 22;
   
   //--- Individual TP/SL
   CreateLabel("ToramaPanelLblIndTP", "Ind. TP:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValIndTP", "", col1 + 50, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblIndSL", "SL:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValIndSL", "", col2 + 25, yOffset, 8, clrRed, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Max Positions & Current Positions
   CreateLabel("ToramaPanelLblMaxPos", "Max Pos:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValMaxPos", "", col1 + 55, yOffset, 8, clrYellow, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelLblCurrPos", "Open:", col2, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValCurrPos", "", col2 + 35, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Statistics
   CreateLabel("ToramaPanelLblGlobalTP", "Global TP Hits:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValGlobalTPHits", "", col1 + 90, yOffset, 8, clrLime, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   CreateLabel("ToramaPanelLblSLHits", "Grid Resets:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValSLHits", "", col1 + 75, yOffset, 8, clrRed, ANCHOR_LEFT_UPPER);
   yOffset += 18;
   
   //--- Magic Number
   CreateLabel("ToramaPanelLblMagic", "Magic:", col1, yOffset, 8, textColor, ANCHOR_LEFT_UPPER);
   CreateLabel("ToramaPanelValMagic", "", col1 + 40, yOffset, 8, clrWhite, ANCHOR_LEFT_UPPER);
   yOffset += 25;
   
   //--- Buttons
   int btnY = yOffset;
   CreateButton("ToramaPanelBtnReset", "RESET REF", panelX + 10, btnY, buttonWidth, buttonHeight);
   CreateButton("ToramaPanelBtnClose", "CLOSE ALL", panelX + 10 + buttonWidth + buttonSpacing, btnY, buttonWidth, buttonHeight);
   
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
   //--- Direction
   string directionText = (InpGridDirection == GRID_BUY_ONLY) ? "BUY ONLY" : "SELL ONLY";
   color directionColor = (InpGridDirection == GRID_BUY_ONLY) ? clrLime : clrRed;
   ObjectSetString(0, "ToramaPanelValDirection", OBJPROP_TEXT, directionText);
   ObjectSetInteger(0, "ToramaPanelValDirection", OBJPROP_COLOR, directionColor);
   
   //--- Status
   ObjectSetString(0, "ToramaPanelValStatus", OBJPROP_TEXT, eaStatus);
   color statusColor = clrLime;
   if(StringFind(eaStatus, "Stopped") >= 0)
      statusColor = clrRed;
   ObjectSetInteger(0, "ToramaPanelValStatus", OBJPROP_COLOR, statusColor);
   
   //--- Account info
   ObjectSetString(0, "ToramaPanelValBalance", OBJPROP_TEXT, DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   ObjectSetString(0, "ToramaPanelValEquity", OBJPROP_TEXT, DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   ObjectSetString(0, "ToramaPanelValMargin", OBJPROP_TEXT, DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2));
   
   //--- Global Profit
   string profitText = "$" + DoubleToString(globalProfit, 2);
   if(InpGlobalTPDollar > 0)
   {
      double progress = (globalProfit / InpGlobalTPDollar) * 100.0;
      profitText += " (" + DoubleToString(progress, 1) + "%)";
   }
   ObjectSetString(0, "ToramaPanelValGlobalPnL", OBJPROP_TEXT, profitText);
   ObjectSetInteger(0, "ToramaPanelValGlobalPnL", OBJPROP_COLOR, globalProfit >= 0 ? clrLime : clrRed);
   
   //--- Global TP Target
   string globalTPText = (InpGlobalTPDollar > 0) ? "$" + DoubleToString(InpGlobalTPDollar, 2) : "Disabled";
   ObjectSetString(0, "ToramaPanelValGlobalTP", OBJPROP_TEXT, globalTPText);
   ObjectSetInteger(0, "ToramaPanelValGlobalTP", OBJPROP_COLOR, (InpGlobalTPDollar > 0) ? clrLime : clrGray);
   
   //--- Gap
   double gap = refPrice * InpGapPercent / 100.0;
   ObjectSetString(0, "ToramaPanelValGapPct", OBJPROP_TEXT, DoubleToString(InpGapPercent, 2) + "%");
   ObjectSetString(0, "ToramaPanelValGapUSD", OBJPROP_TEXT, "($" + DoubleToString(gap, _Digits) + ")");
   
   //--- Prices
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ObjectSetString(0, "ToramaPanelValRefPrice", OBJPROP_TEXT, DoubleToString(refPrice, _Digits));
   ObjectSetString(0, "ToramaPanelValCurrPrice", OBJPROP_TEXT, DoubleToString(currentPrice, _Digits));
   
   //--- Next Grid Level
   double nextLevel = 0;
   if(InpGridDirection == GRID_BUY_ONLY)
   {
      if(currentPrice < refPrice)
      {
         int level = (int)MathCeil((refPrice - currentPrice) / gap);
         if(level < 1) level = 1;
         nextLevel = refPrice - (level * gap);
      }
      else
      {
         nextLevel = refPrice - gap;
      }
   }
   else
   {
      if(currentPrice > refPrice)
      {
         int level = (int)MathCeil((currentPrice - refPrice) / gap);
         if(level < 1) level = 1;
         nextLevel = refPrice + (level * gap);
      }
      else
      {
         nextLevel = refPrice + gap;
      }
   }
   ObjectSetString(0, "ToramaPanelValNextLevel", OBJPROP_TEXT, DoubleToString(nextLevel, _Digits));
   
   //--- Individual TP/SL
   ObjectSetString(0, "ToramaPanelValIndTP", OBJPROP_TEXT, DoubleToString(InpIndividualTPPercent, 1) + "% gap");
   
   string slText = (InpIndividualSLPercent > 0) ? DoubleToString(InpIndividualSLPercent, 1) + "% gap" : "Disabled";
   ObjectSetString(0, "ToramaPanelValIndSL", OBJPROP_TEXT, slText);
   ObjectSetInteger(0, "ToramaPanelValIndSL", OBJPROP_COLOR, (InpIndividualSLPercent > 0) ? clrRed : clrGray);
   
   //--- Positions
   ObjectSetString(0, "ToramaPanelValMaxPos", OBJPROP_TEXT, IntegerToString(InpMaxPositions));
   ObjectSetString(0, "ToramaPanelValCurrPos", OBJPROP_TEXT, IntegerToString(CountMyPositions()));
   
   //--- Statistics
   ObjectSetString(0, "ToramaPanelValGlobalTPHits", OBJPROP_TEXT, IntegerToString(globalTPHitCount));
   ObjectSetString(0, "ToramaPanelValSLHits", OBJPROP_TEXT, IntegerToString(slHitCount));
   
   ObjectSetString(0, "ToramaPanelValMagic", OBJPROP_TEXT, IntegerToString(magicNumber));
}

//+------------------------------------------------------------------+
