//+------------------------------------------------------------------+
//|                                                  ToramaPanel.mqh |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "1.00"

//+------------------------------------------------------------------+
//| Panel Data Structure                                              |
//+------------------------------------------------------------------+
struct SPanelData
{
   int currentDirection;        // 0 = BUYONLY, 1 = SELLONLY
   double gapPercent;
   double gapDollar;
   double nextBuyLevel;
   double nextSellLevel;
   double referencePrice;
   int positionsCount;
   int maxPositions;
   double totalProfit;
   double equity;
   double peakEquity;
   double dailyProfit;
   double dailyTarget;
   int modeSwitchCount;
   bool emergencyStop;
   string emergencyReason;
   bool dailyTargetReached;
   bool isPaused;
   string symbol;
   int digits;
};

//+------------------------------------------------------------------+
//| TORAMA Professional Panel Class                                  |
//+------------------------------------------------------------------+
class CToramaPanel
{
private:
   string            m_prefix;
   int               m_xBase;
   int               m_yBase;
   int               m_width;
   int               m_rowHeight;
   color             m_bgColor;
   color             m_borderColor;
   color             m_headerColor;
   color             m_textColor;
   color             m_labelColor;
   
   // Panel state
   bool              m_visible;
   
   //--- Helper methods
   void CreateBackground();
   void CreateHeader();
   void CreateLabels();
   void CreateButton(string name, int x, int y, int width, int height, string text, color bgColor, color txtColor);
   void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, string font, bool isValue = false);
   string FormatPrice(double price, int digits);
   string FormatPercent(double percent);
   
public:
   CToramaPanel();
   ~CToramaPanel();
   
   bool Create(string prefix);
   void Destroy();
   void Update(SPanelData &data);
   void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam);
};

//+------------------------------------------------------------------+
//| Constructor                                                       |
//+------------------------------------------------------------------+
CToramaPanel::CToramaPanel()
{
   m_prefix = "";
   m_xBase = 20;
   m_yBase = 30;
   m_width = 280;
   m_rowHeight = 22;
   m_bgColor = C'15,15,20';           // Dark background
   m_borderColor = C'218,165,32';      // Gold border
   m_headerColor = C'218,165,32';      // Gold header
   m_textColor = clrWhite;
   m_labelColor = C'180,180,180';      // Light gray for labels
   m_visible = true;
}

//+------------------------------------------------------------------+
//| Destructor                                                        |
//+------------------------------------------------------------------+
CToramaPanel::~CToramaPanel()
{
   Destroy();
}

//+------------------------------------------------------------------+
//| Format Price                                                      |
//+------------------------------------------------------------------+
string CToramaPanel::FormatPrice(double price, int digits)
{
   return DoubleToString(price, digits);
}

//+------------------------------------------------------------------+
//| Format Percent                                                    |
//+------------------------------------------------------------------+
string CToramaPanel::FormatPercent(double percent)
{
   return DoubleToString(percent, 2);
}

//+------------------------------------------------------------------+
//| Create Background                                                 |
//+------------------------------------------------------------------+
void CToramaPanel::CreateBackground()
{
   // Main background rectangle (solid, on top of all chart elements)
   string bgName = m_prefix + "BG";
   ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, m_xBase);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, m_yBase);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, m_width);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, 620);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, m_bgColor);
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bgName, OBJPROP_COLOR, m_borderColor);
   ObjectSetInteger(0, bgName, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
   ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bgName, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, bgName, OBJPROP_ZORDER, 1000);  // On top
}

//+------------------------------------------------------------------+
//| Create Header                                                     |
//+------------------------------------------------------------------+
void CToramaPanel::CreateHeader()
{
   int y = m_yBase + 10;
   
   // EA Name
   CreateLabel(m_prefix + "Title", m_xBase + 10, y, "TORAMA AGGRESSIVE", m_headerColor, 11, "Arial Black");
   y += 20;
   CreateLabel(m_prefix + "Title2", m_xBase + 10, y, "TRADER v5.8", m_headerColor, 11, "Arial Black");
   y += 25;
   
   // Separator line
   string sepName = m_prefix + "Sep1";
   ObjectCreate(0, sepName, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, sepName, OBJPROP_XDISTANCE, m_xBase + 10);
   ObjectSetInteger(0, sepName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, sepName, OBJPROP_XSIZE, m_width - 20);
   ObjectSetInteger(0, sepName, OBJPROP_YSIZE, 2);
   ObjectSetInteger(0, sepName, OBJPROP_BGCOLOR, m_borderColor);
   ObjectSetInteger(0, sepName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, sepName, OBJPROP_READONLY, true);
   ObjectSetInteger(0, sepName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, sepName, OBJPROP_BACK, false);
   ObjectSetInteger(0, sepName, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, sepName, OBJPROP_ZORDER, 1001);
}

//+------------------------------------------------------------------+
//| Create Labels                                                     |
//+------------------------------------------------------------------+
void CToramaPanel::CreateLabels()
{
   int y = m_yBase + 70;
   int labelX = m_xBase + 15;
   int valueX = m_xBase + m_width - 95;
   
   // STATUS SECTION
   CreateLabel(m_prefix + "StatusLabel", labelX, y, "STATUS", m_headerColor, 9, "Arial Bold");
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "ModeLabel", labelX, y, "Mode:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "Mode", valueX, y, "BUY ONLY", clrDodgerBlue, 9, "Arial Bold", true);
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "StateLabel", labelX, y, "State:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "State", valueX, y, "ACTIVE", clrLimeGreen, 9, "Arial Bold", true);
   y += m_rowHeight + 5;
   
   // GRID SECTION
   string sepName2 = m_prefix + "Sep2";
   ObjectCreate(0, sepName2, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, sepName2, OBJPROP_XDISTANCE, m_xBase + 10);
   ObjectSetInteger(0, sepName2, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, sepName2, OBJPROP_XSIZE, m_width - 20);
   ObjectSetInteger(0, sepName2, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, sepName2, OBJPROP_BGCOLOR, C'50,50,60');
   ObjectSetInteger(0, sepName2, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, sepName2, OBJPROP_READONLY, true);
   ObjectSetInteger(0, sepName2, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, sepName2, OBJPROP_BACK, false);
   ObjectSetInteger(0, sepName2, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, sepName2, OBJPROP_ZORDER, 1001);
   y += 10;
   
   CreateLabel(m_prefix + "GridLabel", labelX, y, "GRID SETTINGS", m_headerColor, 9, "Arial Bold");
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "GapPercentLabel", labelX, y, "Gap %:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "GapPercent", valueX, y, "0.00%", m_textColor, 9, "Arial Bold", true);
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "GapDollarLabel", labelX, y, "Gap $:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "GapDollar", valueX, y, "$0.00", m_textColor, 9, "Arial Bold", true);
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "RefPriceLabel", labelX, y, "Reference:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "RefPrice", valueX, y, "$0.00", m_textColor, 9, "Arial Bold", true);
   y += m_rowHeight + 5;
   
   // NEXT LEVELS SECTION
   string sepName3 = m_prefix + "Sep3";
   ObjectCreate(0, sepName3, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, sepName3, OBJPROP_XDISTANCE, m_xBase + 10);
   ObjectSetInteger(0, sepName3, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, sepName3, OBJPROP_XSIZE, m_width - 20);
   ObjectSetInteger(0, sepName3, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, sepName3, OBJPROP_BGCOLOR, C'50,50,60');
   ObjectSetInteger(0, sepName3, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, sepName3, OBJPROP_READONLY, true);
   ObjectSetInteger(0, sepName3, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, sepName3, OBJPROP_BACK, false);
   ObjectSetInteger(0, sepName3, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, sepName3, OBJPROP_ZORDER, 1001);
   y += 10;
   
   CreateLabel(m_prefix + "NextLabel", labelX, y, "NEXT LEVELS", m_headerColor, 9, "Arial Bold");
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "NextBuyLabel", labelX, y, "↓ Next Buy:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "NextBuy", valueX, y, "$0.00", clrDodgerBlue, 9, "Arial Bold", true);
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "NextSellLabel", labelX, y, "↑ Next Sell:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "NextSell", valueX, y, "$0.00", clrOrangeRed, 9, "Arial Bold", true);
   y += m_rowHeight + 5;
   
   // POSITIONS SECTION
   string sepName4 = m_prefix + "Sep4";
   ObjectCreate(0, sepName4, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, sepName4, OBJPROP_XDISTANCE, m_xBase + 10);
   ObjectSetInteger(0, sepName4, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, sepName4, OBJPROP_XSIZE, m_width - 20);
   ObjectSetInteger(0, sepName4, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, sepName4, OBJPROP_BGCOLOR, C'50,50,60');
   ObjectSetInteger(0, sepName4, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, sepName4, OBJPROP_READONLY, true);
   ObjectSetInteger(0, sepName4, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, sepName4, OBJPROP_BACK, false);
   ObjectSetInteger(0, sepName4, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, sepName4, OBJPROP_ZORDER, 1001);
   y += 10;
   
   CreateLabel(m_prefix + "PosLabel", labelX, y, "POSITIONS", m_headerColor, 9, "Arial Bold");
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "PositionsLabel", labelX, y, "EA Positions:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "Positions", valueX, y, "0/100", m_textColor, 9, "Arial Bold", true);
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "AccountLotsLabel", labelX, y, "Account Lots:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "AccLots", valueX, y, "B:0 S:0", m_textColor, 8, "Arial Bold", true);
   y += m_rowHeight + 5;
   
   // P&L SECTION
   string sepName5 = m_prefix + "Sep5";
   ObjectCreate(0, sepName5, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, sepName5, OBJPROP_XDISTANCE, m_xBase + 10);
   ObjectSetInteger(0, sepName5, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, sepName5, OBJPROP_XSIZE, m_width - 20);
   ObjectSetInteger(0, sepName5, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, sepName5, OBJPROP_BGCOLOR, C'50,50,60');
   ObjectSetInteger(0, sepName5, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, sepName5, OBJPROP_READONLY, true);
   ObjectSetInteger(0, sepName5, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, sepName5, OBJPROP_BACK, false);
   ObjectSetInteger(0, sepName5, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, sepName5, OBJPROP_ZORDER, 1001);
   y += 10;
   
   CreateLabel(m_prefix + "PLLabel", labelX, y, "PROFIT & LOSS", m_headerColor, 9, "Arial Bold");
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "TotalPLLabel", labelX, y, "Total P/L:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "PnL", valueX, y, "+$0.00", clrLimeGreen, 10, "Arial Black", true);
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "EquityLabel", labelX, y, "Equity:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "Equity", valueX, y, "$0.00", m_textColor, 9, "Arial Bold", true);
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "DrawdownLabel", labelX, y, "Drawdown:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "DD", valueX, y, "0.0%", clrLimeGreen, 9, "Arial Bold", true);
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "DailyPLLabel", labelX, y, "Daily P/L:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "DailyProfit", valueX, y, "+$0.00", m_textColor, 9, "Arial Bold", true);
   y += m_rowHeight + 5;
   
   // STATISTICS SECTION
   string sepName6 = m_prefix + "Sep6";
   ObjectCreate(0, sepName6, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, sepName6, OBJPROP_XDISTANCE, m_xBase + 10);
   ObjectSetInteger(0, sepName6, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, sepName6, OBJPROP_XSIZE, m_width - 20);
   ObjectSetInteger(0, sepName6, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, sepName6, OBJPROP_BGCOLOR, C'50,50,60');
   ObjectSetInteger(0, sepName6, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, sepName6, OBJPROP_READONLY, true);
   ObjectSetInteger(0, sepName6, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, sepName6, OBJPROP_BACK, false);
   ObjectSetInteger(0, sepName6, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, sepName6, OBJPROP_ZORDER, 1001);
   y += 10;
   
   CreateLabel(m_prefix + "StatsLabel", labelX, y, "STATISTICS", m_headerColor, 9, "Arial Bold");
   y += m_rowHeight;
   
   CreateLabel(m_prefix + "SwitchLabel", labelX, y, "Mode Switches:", m_labelColor, 8, "Arial");
   CreateLabel(m_prefix + "SwitchCount", valueX, y, "0", m_textColor, 9, "Arial Bold", true);
   y += m_rowHeight + 10;
   
   // TORAMA BRANDING
   CreateLabel(m_prefix + "Brand", labelX, y, "TORAMA CAPITAL", C'218,165,32', 8, "Arial Bold");
   y += 18;
   CreateLabel(m_prefix + "Website", labelX, y, "www.torama.money", C'150,150,150', 7, "Arial");
}

//+------------------------------------------------------------------+
//| Create Label                                                      |
//+------------------------------------------------------------------+
void CToramaPanel::CreateLabel(string name, int x, int y, string text, color clr, int fontSize, string font, bool isValue = false)
{
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
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1002);  // Above background
}

//+------------------------------------------------------------------+
//| Create                                                            |
//+------------------------------------------------------------------+
bool CToramaPanel::Create(string prefix)
{
   m_prefix = prefix;
   
   CreateBackground();
   CreateHeader();
   CreateLabels();
   
   ChartRedraw();
   return true;
}

//+------------------------------------------------------------------+
//| Destroy                                                           |
//+------------------------------------------------------------------+
void CToramaPanel::Destroy()
{
   ObjectsDeleteAll(0, m_prefix);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update                                                            |
//+------------------------------------------------------------------+
void CToramaPanel::Update(SPanelData &data)
{
   if(!m_visible) return;
   
   // Mode
   string modeText = (data.currentDirection == 0) ? "BUY ONLY" : "SELL ONLY";
   color modeColor = (data.currentDirection == 0) ? clrDodgerBlue : clrOrangeRed;
   ObjectSetString(0, m_prefix + "Mode", OBJPROP_TEXT, modeText);
   ObjectSetInteger(0, m_prefix + "Mode", OBJPROP_COLOR, modeColor);
   
   // State
   string stateText = "ACTIVE";
   color stateColor = clrLimeGreen;
   if(data.emergencyStop) {
      stateText = "⛔ EMERGENCY";
      stateColor = clrRed;
   } else if(data.dailyTargetReached) {
      stateText = "✓ TARGET HIT";
      stateColor = clrGold;
   } else if(data.isPaused) {
      stateText = "⏸ PAUSED";
      stateColor = clrYellow;
   }
   ObjectSetString(0, m_prefix + "State", OBJPROP_TEXT, stateText);
   ObjectSetInteger(0, m_prefix + "State", OBJPROP_COLOR, stateColor);
   
   // Gap
   ObjectSetString(0, m_prefix + "GapPercent", OBJPROP_TEXT, FormatPercent(data.gapPercent) + "%");
   ObjectSetString(0, m_prefix + "GapDollar", OBJPROP_TEXT, "$" + FormatPrice(data.gapDollar, data.digits));
   
   // Reference
   ObjectSetString(0, m_prefix + "RefPrice", OBJPROP_TEXT, "$" + FormatPrice(data.referencePrice, data.digits));
   
   // Next levels
   if(data.currentDirection == 0) {  // BUY ONLY
      if(data.nextBuyLevel > 0) {
         ObjectSetString(0, m_prefix + "NextBuy", OBJPROP_TEXT, "$" + FormatPrice(data.nextBuyLevel, data.digits));
         ObjectSetInteger(0, m_prefix + "NextBuy", OBJPROP_COLOR, clrDodgerBlue);
      } else {
         ObjectSetString(0, m_prefix + "NextBuy", OBJPROP_TEXT, "N/A");
         ObjectSetInteger(0, m_prefix + "NextBuy", OBJPROP_COLOR, clrGray);
      }
      ObjectSetString(0, m_prefix + "NextSell", OBJPROP_TEXT, "N/A");
      ObjectSetInteger(0, m_prefix + "NextSell", OBJPROP_COLOR, clrGray);
   } else {  // SELL ONLY
      if(data.nextSellLevel > 0) {
         ObjectSetString(0, m_prefix + "NextSell", OBJPROP_TEXT, "$" + FormatPrice(data.nextSellLevel, data.digits));
         ObjectSetInteger(0, m_prefix + "NextSell", OBJPROP_COLOR, clrOrangeRed);
      } else {
         ObjectSetString(0, m_prefix + "NextSell", OBJPROP_TEXT, "N/A");
         ObjectSetInteger(0, m_prefix + "NextSell", OBJPROP_COLOR, clrGray);
      }
      ObjectSetString(0, m_prefix + "NextBuy", OBJPROP_TEXT, "N/A");
      ObjectSetInteger(0, m_prefix + "NextBuy", OBJPROP_COLOR, clrGray);
   }
   
   // Positions
   ObjectSetString(0, m_prefix + "Positions", OBJPROP_TEXT, 
                   IntegerToString(data.positionsCount) + "/" + IntegerToString(data.maxPositions));
   
   // Account lots
   double totalBuyLots = 0, totalSellLots = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == data.symbol) {
         double volume = PositionGetDouble(POSITION_VOLUME);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if(type == POSITION_TYPE_BUY) totalBuyLots += volume;
         else totalSellLots += volume;
      }
   }
   
   double netPosition = totalBuyLots - totalSellLots;
   string netText = "";
   color netColor = m_textColor;
   
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
   ObjectSetString(0, m_prefix + "AccLots", OBJPROP_TEXT, lotsText);
   ObjectSetInteger(0, m_prefix + "AccLots", OBJPROP_COLOR, netColor);
   
   // P/L
   color pnlColor = (data.totalProfit >= 0) ? clrLimeGreen : clrRed;
   ObjectSetString(0, m_prefix + "PnL", OBJPROP_TEXT,
                   (data.totalProfit >= 0 ? "+" : "") + "$" + FormatPrice(data.totalProfit, 2));
   ObjectSetInteger(0, m_prefix + "PnL", OBJPROP_COLOR, pnlColor);
   
   // Equity
   ObjectSetString(0, m_prefix + "Equity", OBJPROP_TEXT, "$" + FormatPrice(data.equity, 2));
   
   // Drawdown
   double dd = (data.peakEquity > 0) ? ((data.equity - data.peakEquity) / data.peakEquity * 100) : 0;
   color ddColor = (dd >= -5) ? clrLimeGreen : (dd >= -10) ? clrYellow : clrRed;
   ObjectSetString(0, m_prefix + "DD", OBJPROP_TEXT, FormatPercent(dd) + "%");
   ObjectSetInteger(0, m_prefix + "DD", OBJPROP_COLOR, ddColor);
   
   // Daily P/L
   color dailyColor = (data.dailyProfit >= data.dailyTarget) ? clrGold : 
                      (data.dailyProfit >= 0) ? clrLimeGreen : clrRed;
   ObjectSetString(0, m_prefix + "DailyProfit", OBJPROP_TEXT,
                   (data.dailyProfit >= 0 ? "+" : "") + "$" + FormatPrice(data.dailyProfit, 2));
   ObjectSetInteger(0, m_prefix + "DailyProfit", OBJPROP_COLOR, dailyColor);
   
   // Mode switches
   ObjectSetString(0, m_prefix + "SwitchCount", OBJPROP_TEXT, IntegerToString(data.modeSwitchCount));
}

//+------------------------------------------------------------------+
//| On Chart Event                                                    |
//+------------------------------------------------------------------+
void CToramaPanel::OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Handle button clicks if needed in future
}
//+------------------------------------------------------------------+
