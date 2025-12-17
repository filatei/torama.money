//+------------------------------------------------------------------+
//|                    TORAMA Aggressive Trader EA v5.9              |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "5.9"
#property description "Aggressive Directional Grid Trader with ATR-Based Mode Switching"
#property description "V5.9: Integrated professional panel - No external dependencies"

#define EA_VERSION "5.9"
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
double nextBuyLevelUp = 0, nextBuyLevelDown = 0;
double nextSellLevelUp = 0, nextSellLevelDown = 0;
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

// Panel variables
string panelPrefix = "TORAMA_AGG_";
int panelX = 20, panelY = 30, panelWidth = 280, panelRowHeight = 20;

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS                                                  |
//+------------------------------------------------------------------+
string FormatPrice(double price, int digits) {
   return DoubleToString(price, digits);
}

string FormatPercent(double percent) {
   return DoubleToString(percent, 2);
}

//+------------------------------------------------------------------+
//| CREATE PANEL LABEL                                                |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, string font) {
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1002);
}

//+------------------------------------------------------------------+
//| CREATE PANEL                                                      |
//+------------------------------------------------------------------+
void CreatePanel() {
   color bgColor = C'15,15,20';
   color borderColor = C'218,165,32';
   color headerColor = C'218,165,32';
   color labelColor = C'180,180,180';
   
   // Main background
   string bgName = panelPrefix + "BG";
   ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, panelX);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, panelY);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, panelWidth);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, 560);  // Reduced from 600 to 560
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bgName, OBJPROP_COLOR, borderColor);
   ObjectSetInteger(0, bgName, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
   ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bgName, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, bgName, OBJPROP_ZORDER, 1000);
   
   int y = panelY + 8;
   int labelX = panelX + 15;
   int valueX = panelX + panelWidth - 95;
   
   // Header
   CreateLabel(panelPrefix + "Title", panelX + 10, y, "TORAMA AGGRESSIVE", headerColor, 11, "Arial Black");
   y += 18;
   CreateLabel(panelPrefix + "Title2", panelX + 10, y, "TRADER v5.9", headerColor, 11, "Arial Black");
   y += 20;
   
   // Separator 1
   string sep1 = panelPrefix + "Sep1";
   ObjectCreate(0, sep1, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, sep1, OBJPROP_XDISTANCE, panelX + 10);
   ObjectSetInteger(0, sep1, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, sep1, OBJPROP_XSIZE, panelWidth - 20);
   ObjectSetInteger(0, sep1, OBJPROP_YSIZE, 2);
   ObjectSetInteger(0, sep1, OBJPROP_BGCOLOR, borderColor);
   ObjectSetInteger(0, sep1, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, sep1, OBJPROP_READONLY, true);
   ObjectSetInteger(0, sep1, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, sep1, OBJPROP_BACK, false);
   ObjectSetInteger(0, sep1, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, sep1, OBJPROP_ZORDER, 1001);
   y += 10;
   
   // STATUS
   CreateLabel(panelPrefix + "StatusLabel", labelX, y, "STATUS", headerColor, 9, "Arial Bold");
   y += panelRowHeight;
   CreateLabel(panelPrefix + "ModeLabel", labelX, y, "Mode:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "Mode", valueX, y, "BUY ONLY", clrDodgerBlue, 9, "Arial Bold");
   y += panelRowHeight;
   CreateLabel(panelPrefix + "StateLabel", labelX, y, "State:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "State", valueX, y, "ACTIVE", clrLimeGreen, 9, "Arial Bold");
   y += panelRowHeight + 3;
   
   // Separator 2
   string sep2 = panelPrefix + "Sep2";
   ObjectCreate(0, sep2, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, sep2, OBJPROP_XDISTANCE, panelX + 10);
   ObjectSetInteger(0, sep2, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, sep2, OBJPROP_XSIZE, panelWidth - 20);
   ObjectSetInteger(0, sep2, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, sep2, OBJPROP_BGCOLOR, C'50,50,60');
   ObjectSetInteger(0, sep2, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, sep2, OBJPROP_READONLY, true);
   ObjectSetInteger(0, sep2, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, sep2, OBJPROP_BACK, false);
   ObjectSetInteger(0, sep2, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, sep2, OBJPROP_ZORDER, 1001);
   y += 10;
   
   // GRID SETTINGS
   CreateLabel(panelPrefix + "GridLabel", labelX, y, "GRID SETTINGS", headerColor, 9, "Arial Bold");
   y += panelRowHeight;
   CreateLabel(panelPrefix + "GapPercentLabel", labelX, y, "Gap %:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "GapPercent", valueX, y, "0.00%", clrWhite, 9, "Arial Bold");
   y += panelRowHeight;
   CreateLabel(panelPrefix + "GapDollarLabel", labelX, y, "Gap $:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "GapDollar", valueX, y, "$0.00", clrWhite, 9, "Arial Bold");
   y += panelRowHeight;
   CreateLabel(panelPrefix + "RefPriceLabel", labelX, y, "Reference:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "RefPrice", valueX, y, "$0.00", clrWhite, 9, "Arial Bold");
   y += panelRowHeight + 3;
   
   // Separator 3
   string sep3 = panelPrefix + "Sep3";
   ObjectCreate(0, sep3, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, sep3, OBJPROP_XDISTANCE, panelX + 10);
   ObjectSetInteger(0, sep3, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, sep3, OBJPROP_XSIZE, panelWidth - 20);
   ObjectSetInteger(0, sep3, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, sep3, OBJPROP_BGCOLOR, C'50,50,60');
   ObjectSetInteger(0, sep3, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, sep3, OBJPROP_READONLY, true);
   ObjectSetInteger(0, sep3, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, sep3, OBJPROP_BACK, false);
   ObjectSetInteger(0, sep3, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, sep3, OBJPROP_ZORDER, 1001);
   y += 10;
   
   // NEXT LEVELS (2 columns: Buy left, Sell right)
   CreateLabel(panelPrefix + "NextLabel", labelX, y, "NEXT LEVELS", headerColor, 9, "Arial Bold");
   y += panelRowHeight;
   
   int leftCol = labelX;
   int rightCol = labelX + 130;
   
   CreateLabel(panelPrefix + "NextBuyUpLabel", leftCol, y, "↑ Buy Up:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "NextBuyUp", leftCol + 70, y, "$0.00", clrDodgerBlue, 8, "Arial Bold");
   CreateLabel(panelPrefix + "NextSellUpLabel", rightCol, y, "↑ Sell Up:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "NextSellUp", rightCol + 70, y, "$0.00", clrOrangeRed, 8, "Arial Bold");
   y += panelRowHeight;
   
   CreateLabel(panelPrefix + "NextBuyDownLabel", leftCol, y, "↓ Buy Down:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "NextBuyDown", leftCol + 70, y, "$0.00", clrDodgerBlue, 8, "Arial Bold");
   CreateLabel(panelPrefix + "NextSellDownLabel", rightCol, y, "↓ Sell Down:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "NextSellDown", rightCol + 70, y, "$0.00", clrOrangeRed, 8, "Arial Bold");
   y += panelRowHeight + 3;
   
   // Separator 4
   string sep4 = panelPrefix + "Sep4";
   ObjectCreate(0, sep4, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, sep4, OBJPROP_XDISTANCE, panelX + 10);
   ObjectSetInteger(0, sep4, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, sep4, OBJPROP_XSIZE, panelWidth - 20);
   ObjectSetInteger(0, sep4, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, sep4, OBJPROP_BGCOLOR, C'50,50,60');
   ObjectSetInteger(0, sep4, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, sep4, OBJPROP_READONLY, true);
   ObjectSetInteger(0, sep4, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, sep4, OBJPROP_BACK, false);
   ObjectSetInteger(0, sep4, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, sep4, OBJPROP_ZORDER, 1001);
   y += 10;
   
   // POSITIONS
   CreateLabel(panelPrefix + "PosLabel", labelX, y, "POSITIONS", headerColor, 9, "Arial Bold");
   y += panelRowHeight;
   CreateLabel(panelPrefix + "PositionsLabel", labelX, y, "EA Positions:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "Positions", valueX, y, "0/100", clrWhite, 9, "Arial Bold");
   y += panelRowHeight;
   CreateLabel(panelPrefix + "AccountLotsLabel", labelX, y, "Account Lots:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "AccLots", valueX, y, "B:0 S:0", clrWhite, 8, "Arial Bold");
   y += panelRowHeight + 3;
   
   // Separator 5
   string sep5 = panelPrefix + "Sep5";
   ObjectCreate(0, sep5, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, sep5, OBJPROP_XDISTANCE, panelX + 10);
   ObjectSetInteger(0, sep5, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, sep5, OBJPROP_XSIZE, panelWidth - 20);
   ObjectSetInteger(0, sep5, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, sep5, OBJPROP_BGCOLOR, C'50,50,60');
   ObjectSetInteger(0, sep5, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, sep5, OBJPROP_READONLY, true);
   ObjectSetInteger(0, sep5, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, sep5, OBJPROP_BACK, false);
   ObjectSetInteger(0, sep5, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, sep5, OBJPROP_ZORDER, 1001);
   y += 10;
   
   // PROFIT & LOSS
   CreateLabel(panelPrefix + "PLLabel", labelX, y, "PROFIT & LOSS", headerColor, 9, "Arial Bold");
   y += panelRowHeight;
   CreateLabel(panelPrefix + "TotalPLLabel", labelX, y, "Total P/L:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "PnL", valueX, y, "+$0.00", clrLimeGreen, 10, "Arial Black");
   y += panelRowHeight;
   CreateLabel(panelPrefix + "EquityLabel", labelX, y, "Equity:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "Equity", valueX, y, "$0.00", clrWhite, 9, "Arial Bold");
   y += panelRowHeight;
   CreateLabel(panelPrefix + "DrawdownLabel", labelX, y, "Drawdown:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "DD", valueX, y, "0.0%", clrLimeGreen, 9, "Arial Bold");
   y += panelRowHeight;
   CreateLabel(panelPrefix + "DailyPLLabel", labelX, y, "Daily P/L:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "DailyProfit", valueX, y, "+$0.00", clrWhite, 9, "Arial Bold");
   y += panelRowHeight + 3;
   
   // Separator 6
   string sep6 = panelPrefix + "Sep6";
   ObjectCreate(0, sep6, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, sep6, OBJPROP_XDISTANCE, panelX + 10);
   ObjectSetInteger(0, sep6, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, sep6, OBJPROP_XSIZE, panelWidth - 20);
   ObjectSetInteger(0, sep6, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, sep6, OBJPROP_BGCOLOR, C'50,50,60');
   ObjectSetInteger(0, sep6, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, sep6, OBJPROP_READONLY, true);
   ObjectSetInteger(0, sep6, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, sep6, OBJPROP_BACK, false);
   ObjectSetInteger(0, sep6, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, sep6, OBJPROP_ZORDER, 1001);
   y += 10;
   
   // STATISTICS
   CreateLabel(panelPrefix + "StatsLabel", labelX, y, "STATISTICS", headerColor, 9, "Arial Bold");
   y += panelRowHeight;
   CreateLabel(panelPrefix + "SwitchLabel", labelX, y, "Mode Switches:", labelColor, 8, "Arial");
   CreateLabel(panelPrefix + "SwitchCount", valueX, y, "0", clrWhite, 9, "Arial Bold");
   y += panelRowHeight + 8;
   
   // BRANDING
   CreateLabel(panelPrefix + "Brand", labelX, y, "TORAMA CAPITAL", C'218,165,32', 8, "Arial Bold");
   y += 16;
   CreateLabel(panelPrefix + "Website", labelX, y, "www.torama.money", C'150,150,150', 7, "Arial");
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel() {
   // Mode
   string modeText = (CurrentDirection == BUYONLY) ? "BUY ONLY" : "SELL ONLY";
   color modeColor = (CurrentDirection == BUYONLY) ? clrDodgerBlue : clrOrangeRed;
   ObjectSetString(0, panelPrefix + "Mode", OBJPROP_TEXT, modeText);
   ObjectSetInteger(0, panelPrefix + "Mode", OBJPROP_COLOR, modeColor);
   
   // State
   string stateText = "ACTIVE";
   color stateColor = clrLimeGreen;
   if(emergencyStop) {
      stateText = "⛔ EMERGENCY";
      stateColor = clrRed;
   } else if(dailyTargetReached) {
      stateText = "✓ TARGET HIT";
      stateColor = clrGold;
   } else if(isPaused) {
      stateText = "⏸ PAUSED";
      stateColor = clrYellow;
   }
   ObjectSetString(0, panelPrefix + "State", OBJPROP_TEXT, stateText);
   ObjectSetInteger(0, panelPrefix + "State", OBJPROP_COLOR, stateColor);
   
   // Gap
   ObjectSetString(0, panelPrefix + "GapPercent", OBJPROP_TEXT, FormatPercent(GridGapPercent) + "%");
   ObjectSetString(0, panelPrefix + "GapDollar", OBJPROP_TEXT, "$" + FormatPrice(currentGapSize, specs.digits));
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, "$" + FormatPrice(referencePrice, specs.digits));
   
   // Next levels (2 columns)
   if(CurrentDirection == BUYONLY) {
      if(nextBuyLevelUp > 0) {
         ObjectSetString(0, panelPrefix + "NextBuyUp", OBJPROP_TEXT, "$" + FormatPrice(nextBuyLevelUp, specs.digits));
         ObjectSetInteger(0, panelPrefix + "NextBuyUp", OBJPROP_COLOR, clrDodgerBlue);
      } else {
         ObjectSetString(0, panelPrefix + "NextBuyUp", OBJPROP_TEXT, "N/A");
         ObjectSetInteger(0, panelPrefix + "NextBuyUp", OBJPROP_COLOR, clrGray);
      }
      
      if(nextBuyLevelDown > 0) {
         ObjectSetString(0, panelPrefix + "NextBuyDown", OBJPROP_TEXT, "$" + FormatPrice(nextBuyLevelDown, specs.digits));
         ObjectSetInteger(0, panelPrefix + "NextBuyDown", OBJPROP_COLOR, clrDodgerBlue);
      } else {
         ObjectSetString(0, panelPrefix + "NextBuyDown", OBJPROP_TEXT, "N/A");
         ObjectSetInteger(0, panelPrefix + "NextBuyDown", OBJPROP_COLOR, clrGray);
      }
      
      ObjectSetString(0, panelPrefix + "NextSellUp", OBJPROP_TEXT, "N/A");
      ObjectSetInteger(0, panelPrefix + "NextSellUp", OBJPROP_COLOR, clrGray);
      ObjectSetString(0, panelPrefix + "NextSellDown", OBJPROP_TEXT, "N/A");
      ObjectSetInteger(0, panelPrefix + "NextSellDown", OBJPROP_COLOR, clrGray);
   } else {
      if(nextSellLevelUp > 0) {
         ObjectSetString(0, panelPrefix + "NextSellUp", OBJPROP_TEXT, "$" + FormatPrice(nextSellLevelUp, specs.digits));
         ObjectSetInteger(0, panelPrefix + "NextSellUp", OBJPROP_COLOR, clrOrangeRed);
      } else {
         ObjectSetString(0, panelPrefix + "NextSellUp", OBJPROP_TEXT, "N/A");
         ObjectSetInteger(0, panelPrefix + "NextSellUp", OBJPROP_COLOR, clrGray);
      }
      
      if(nextSellLevelDown > 0) {
         ObjectSetString(0, panelPrefix + "NextSellDown", OBJPROP_TEXT, "$" + FormatPrice(nextSellLevelDown, specs.digits));
         ObjectSetInteger(0, panelPrefix + "NextSellDown", OBJPROP_COLOR, clrOrangeRed);
      } else {
         ObjectSetString(0, panelPrefix + "NextSellDown", OBJPROP_TEXT, "N/A");
         ObjectSetInteger(0, panelPrefix + "NextSellDown", OBJPROP_COLOR, clrGray);
      }
      
      ObjectSetString(0, panelPrefix + "NextBuyUp", OBJPROP_TEXT, "N/A");
      ObjectSetInteger(0, panelPrefix + "NextBuyUp", OBJPROP_COLOR, clrGray);
      ObjectSetString(0, panelPrefix + "NextBuyDown", OBJPROP_TEXT, "N/A");
      ObjectSetInteger(0, panelPrefix + "NextBuyDown", OBJPROP_COLOR, clrGray);
   }
   
   // Positions
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT, 
                   IntegerToString(ArraySize(positions)) + "/" + IntegerToString(MaxPositions));
   
   // Account lots
   double totalBuyLots = 0, totalSellLots = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol) {
         double volume = PositionGetDouble(POSITION_VOLUME);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if(type == POSITION_TYPE_BUY) totalBuyLots += volume;
         else totalSellLots += volume;
      }
   }
   
   double netPosition = totalBuyLots - totalSellLots;
   string netText = "";
   color netColor = clrWhite;
   
   if(MathAbs(netPosition) < 0.01) {
      netText = " (0)";
   } else if(netPosition > 0) {
      netText = " (+" + DoubleToString(netPosition, 2) + "B)";
      netColor = clrDodgerBlue;
   } else {
      netText = " (" + DoubleToString(MathAbs(netPosition), 2) + "S)";
      netColor = clrOrangeRed;
   }
   
   string lotsText = "B:" + DoubleToString(totalBuyLots, 2) + " S:" + DoubleToString(totalSellLots, 2) + netText;
   ObjectSetString(0, panelPrefix + "AccLots", OBJPROP_TEXT, lotsText);
   ObjectSetInteger(0, panelPrefix + "AccLots", OBJPROP_COLOR, netColor);
   
   // P/L
   color pnlColor = (totalProfit >= 0) ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "PnL", OBJPROP_TEXT,
                   (totalProfit >= 0 ? "+" : "") + "$" + FormatPrice(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "PnL", OBJPROP_COLOR, pnlColor);
   
   // Equity
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT, "$" + FormatPrice(equity, 2));
   
   // Drawdown
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   color ddColor = (dd >= -5) ? clrLimeGreen : (dd >= -10) ? clrYellow : clrRed;
   ObjectSetString(0, panelPrefix + "DD", OBJPROP_TEXT, FormatPercent(dd) + "%");
   ObjectSetInteger(0, panelPrefix + "DD", OBJPROP_COLOR, ddColor);
   
   // Daily P/L
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - dailyStartBalance;
   
   color dailyColor = (dailyProfit >= dailyTarget) ? clrGold : 
                      (dailyProfit >= 0) ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "DailyProfit", OBJPROP_TEXT,
                   (dailyProfit >= 0 ? "+" : "") + "$" + FormatPrice(dailyProfit, 2));
   ObjectSetInteger(0, panelPrefix + "DailyProfit", OBJPROP_COLOR, dailyColor);
   
   // Mode switches
   ObjectSetString(0, panelPrefix + "SwitchCount", OBJPROP_TEXT, IntegerToString(modeSwitchCount));
}

//+------------------------------------------------------------------+
//| DESTROY PANEL                                                     |
//+------------------------------------------------------------------+
void DestroyPanel() {
   ObjectsDeleteAll(0, panelPrefix);
}

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
//| ADJUST NEXT LEVELS FOR EXISTING POSITIONS                        |
//+------------------------------------------------------------------+
void AdjustNextLevelsForExistingPositions() {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   double minDistanceBetweenPositions = currentGapSize * 0.8;
   
   if(CurrentDirection == BUYONLY) {
      if(nextBuyLevelUp > 0) {
         bool levelOccupied = true;
         int iterations = 0;
         
         while(levelOccupied && iterations < 50) {
            levelOccupied = false;
            
            for(int i = 0; i < ArraySize(positions); i++) {
               if(MathAbs(positions[i].entryPrice - nextBuyLevelUp) < minDistanceBetweenPositions) {
                  levelOccupied = true;
                  nextBuyLevelUp += currentGapSize;
                  break;
               }
            }
            iterations++;
         }
      }
      
      if(nextBuyLevelDown > 0) {
         bool levelOccupied = true;
         int iterations = 0;
         
         while(levelOccupied && iterations < 50) {
            levelOccupied = false;
            
            for(int i = 0; i < ArraySize(positions); i++) {
               if(MathAbs(positions[i].entryPrice - nextBuyLevelDown) < minDistanceBetweenPositions) {
                  levelOccupied = true;
                  nextBuyLevelDown -= currentGapSize;
                  break;
               }
            }
            iterations++;
         }
      }
   } else {
      if(nextSellLevelUp > 0) {
         bool levelOccupied = true;
         int iterations = 0;
         
         while(levelOccupied && iterations < 50) {
            levelOccupied = false;
            
            for(int i = 0; i < ArraySize(positions); i++) {
               if(MathAbs(positions[i].entryPrice - nextSellLevelUp) < minDistanceBetweenPositions) {
                  levelOccupied = true;
                  nextSellLevelUp += currentGapSize;
                  break;
               }
            }
            iterations++;
         }
      }
      
      if(nextSellLevelDown > 0) {
         bool levelOccupied = true;
         int iterations = 0;
         
         while(levelOccupied && iterations < 50) {
            levelOccupied = false;
            
            for(int i = 0; i < ArraySize(positions); i++) {
               if(MathAbs(positions[i].entryPrice - nextSellLevelDown) < minDistanceBetweenPositions) {
                  levelOccupied = true;
                  nextSellLevelDown -= currentGapSize;
                  break;
               }
            }
            iterations++;
         }
      }
   }
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
   
   static int lastPosCount = -1;
   if(ArraySize(positions) != lastPosCount) {
      lastPosCount = ArraySize(positions);
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
            CloseAllPositions();
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
      // Calculate how much price must move to hit SL in dollars
      // Profit/Loss = (Price Movement) × Contract Size × Lot Size × (Tick Value / Tick Size)
      // Price Movement = Dollars / (Contract Size × Lot Size × Tick Value / Tick Size)
      double valuePerPoint = specs.contractSize * validatedLotSize * (specs.tickValue / specs.tickSize);
      double slDistance = IndividualSLDollars / valuePerPoint;
      slDistance = NormalizeDouble(slDistance, specs.digits);
      slDistance = MathMax(slDistance, specs.minStopDistance);
      
      request.sl = type == ORDER_TYPE_BUY ? price - slDistance : price + slDistance;
   }
   
   if(IndividualTPDollars > 0) {
      // Calculate how much price must move to hit TP in dollars
      // Profit/Loss = (Price Movement) × Contract Size × Lot Size × (Tick Value / Tick Size)
      // Price Movement = Dollars / (Contract Size × Lot Size × Tick Value / Tick Size)
      double valuePerPoint = specs.contractSize * validatedLotSize * (specs.tickValue / specs.tickSize);
      double tpDistance = IndividualTPDollars / valuePerPoint;
      tpDistance = NormalizeDouble(tpDistance, specs.digits);
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
   
   double distanceFromReference = currentPrice - referencePrice;
   int currentLevelIndex = (int)MathRound(distanceFromReference / currentGapSize);
   
   if(CurrentDirection == BUYONLY) {
      nextBuyLevelDown = referencePrice + ((currentLevelIndex - 1) * currentGapSize);
      nextBuyLevelUp = referencePrice + ((currentLevelIndex + 1) * currentGapSize);
      nextSellLevelUp = 0;
      nextSellLevelDown = 0;
      
      if(MathAbs(currentPrice - nextBuyLevelDown) < MathAbs(currentPrice - nextBuyLevelUp))
         nextBuyLevel = nextBuyLevelDown;
      else
         nextBuyLevel = nextBuyLevelUp;
   } else {
      nextSellLevelUp = referencePrice + ((currentLevelIndex + 1) * currentGapSize);
      nextSellLevelDown = referencePrice + ((currentLevelIndex - 1) * currentGapSize);
      nextBuyLevelUp = 0;
      nextBuyLevelDown = 0;
      
      if(MathAbs(currentPrice - nextSellLevelUp) < MathAbs(currentPrice - nextSellLevelDown))
         nextSellLevel = nextSellLevelUp;
      else
         nextSellLevel = nextSellLevelDown;
   }
   
   AdjustNextLevelsForExistingPositions();
   
   bool positionOpened = false;
   
   if(CurrentDirection == BUYONLY) {
      double minDistanceBetweenPositions = currentGapSize * 0.8;
      double nearestGridLevel = referencePrice + (currentLevelIndex * currentGapSize);
      double distanceToGrid = MathAbs(currentPrice - nearestGridLevel);
      double triggerZone = currentGapSize * 0.05;
      
      if(distanceToGrid <= triggerZone) {
         bool levelHasPosition = false;
         for(int i = 0; i < ArraySize(positions); i++) {
            if(MathAbs(positions[i].entryPrice - nearestGridLevel) < minDistanceBetweenPositions) {
               levelHasPosition = true;
               break;
            }
         }
         
         if(!levelHasPosition && ArraySize(positions) < MaxPositions) {
            if(OpenPosition(ORDER_TYPE_BUY, ask)) {
               positionOpened = true;
            }
         }
      }
   } else {
      double minDistanceBetweenPositions = currentGapSize * 0.8;
      double nearestGridLevel = referencePrice + (currentLevelIndex * currentGapSize);
      double distanceToGrid = MathAbs(currentPrice - nearestGridLevel);
      double triggerZone = currentGapSize * 0.05;
      
      if(distanceToGrid <= triggerZone) {
         bool levelHasPosition = false;
         for(int i = 0; i < ArraySize(positions); i++) {
            if(MathAbs(positions[i].entryPrice - nearestGridLevel) < minDistanceBetweenPositions) {
               levelHasPosition = true;
               break;
            }
         }
         
         if(!levelHasPosition && ArraySize(positions) < MaxPositions) {
            if(OpenPosition(ORDER_TYPE_SELL, bid)) {
               positionOpened = true;
            }
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
      CloseAllPositions();
   }
   
   CalculateTotalProfit();
   if(GroupTPDollars > 0 && totalProfit >= GroupTPDollars) {
      CloseAllPositions();
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
//| CLOSE ALL POSITIONS                                              |
//+------------------------------------------------------------------+
void CloseAllPositions() {
   for(int i = 0; i < ArraySize(positions); i++) {
      ClosePosition(positions[i].ticket);
   }
   ScanAndRebuildPositions();
}

//+------------------------------------------------------------------+
//| CLOSE SINGLE POSITION                                            |
//+------------------------------------------------------------------+
bool ClosePosition(ulong ticket) {
   if(!PositionSelectByTicket(ticket)) return false;
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = _Symbol;
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 
                  ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = request.type == ORDER_TYPE_SELL ? 
                   SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   request.deviation = 10;
   
   if(!OrderSend(request, result)) {
      Print("Close position #", ticket, " failed: ", result.retcode);
      return false;
   }
   
   return (result.retcode == TRADE_RETCODE_DONE);
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
      CreatePanel();
   }
   
   Print("✅ INITIALIZATION COMPLETE");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   DestroyPanel();
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
   
   if(ShowPanel) {
      UpdatePanel();
   }
}
//+------------------------------------------------------------------+
