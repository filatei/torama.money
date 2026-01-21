//+------------------------------------------------------------------+
//|                                   TORAMA_Inverse_Master.mq5       |
//|                                      TORAMA CAPITAL               |
//|                                      www.torama.money             |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "www.torama.money"
#property version   "1.00"
#property description "Master EA - Broadcasts trade signals for inverse copying"
#property description "Place on MASTER account to send signals"

//--- Input parameters
input group "=== Signal Broadcasting Settings ==="
input string   SignalFilePrefix = "TORAMA_INVERSE_";  // Signal file prefix
input int      MagicNumber = 0;                        // Magic number to monitor (0=all)
input string   SymbolFilter = "";                      // Symbol filter (empty=all, comma separated)
input bool     BroadcastPending = true;                // Broadcast pending orders

input group "=== Visual Settings ==="
input color    PanelColor = clrNavy;                   // Panel background color
input color    TextColor = clrWhite;                   // Text color
input int      PanelX = 20;                            // Panel X position
input int      PanelY = 30;                            // Panel Y position

//--- Global variables
string g_signalFile;
long g_chartID;
int g_signalCount = 0;
int g_activePositions = 0;
datetime g_lastUpdate;

//--- Position tracking structure
struct PositionInfo
{
   ulong ticket;
   string symbol;
   ENUM_POSITION_TYPE type;
   double volume;
   double openPrice;
   double sl;
   double tp;
   datetime openTime;
   string comment;
};

PositionInfo g_lastPositions[];
int g_lastPositionCount = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_chartID = ChartID();
   
   // Generate unique signal file name based on account number
   long accountNumber = AccountInfoInteger(ACCOUNT_LOGIN);
   g_signalFile = SignalFilePrefix + IntegerToString(accountNumber) + ".json";
   
   Print("=== TORAMA INVERSE MASTER INITIALIZED ===");
   Print("Account: ", accountNumber);
   Print("Signal File: ", g_signalFile);
   Print("Monitoring Magic: ", (MagicNumber == 0) ? "ALL" : IntegerToString(MagicNumber));
   
   // Create initial positions snapshot
   UpdatePositionSnapshot();
   
   // Create UI panel
   CreatePanel();
   UpdatePanel();
   
   // Set timer for periodic updates
   EventSetTimer(1);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   DeletePanel();
   
   Print("=== TORAMA INVERSE MASTER STOPPED ===");
   Print("Total signals sent: ", g_signalCount);
}

//+------------------------------------------------------------------+
//| Timer function                                                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| Trade transaction function                                         |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                       const MqlTradeRequest& request,
                       const MqlTradeResult& result)
{
   // Filter by magic number if specified
   if(MagicNumber != 0 && request.magic != MagicNumber)
      return;
   
   // Handle different transaction types
   switch(trans.type)
   {
      case TRADE_TRANSACTION_DEAL_ADD:
         HandleDealAdd(trans, request, result);
         break;
         
      case TRADE_TRANSACTION_POSITION:
         HandlePositionChange(trans, request, result);
         break;
         
      case TRADE_TRANSACTION_ORDER_ADD:
         if(BroadcastPending)
            HandleOrderAdd(trans, request, result);
         break;
         
      case TRADE_TRANSACTION_ORDER_DELETE:
         if(BroadcastPending)
            HandleOrderDelete(trans, request, result);
         break;
   }
}

//+------------------------------------------------------------------+
//| Handle deal addition (position open/close)                        |
//+------------------------------------------------------------------+
void HandleDealAdd(const MqlTradeTransaction& trans,
                   const MqlTradeRequest& request,
                   const MqlTradeResult& result)
{
   if(trans.deal == 0)
      return;
      
   // Get deal info
   if(!HistoryDealSelect(trans.deal))
      return;
      
   long dealEntry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   string symbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   
   // Apply symbol filter
   if(!IsSymbolAllowed(symbol))
      return;
   
   if(dealEntry == DEAL_ENTRY_IN)
   {
      // Position opened
      BroadcastPositionOpen(trans.deal);
   }
   else if(dealEntry == DEAL_ENTRY_OUT)
   {
      // Position closed
      BroadcastPositionClose(trans.deal);
   }
}

//+------------------------------------------------------------------+
//| Handle position change (SL/TP modification)                       |
//+------------------------------------------------------------------+
void HandlePositionChange(const MqlTradeTransaction& trans,
                         const MqlTradeRequest& request,
                         const MqlTradeResult& result)
{
   if(trans.position == 0)
      return;
      
   // Position was modified
   if(PositionSelectByTicket(trans.position))
   {
      string symbol = PositionGetString(POSITION_SYMBOL);
      
      // Apply symbol filter
      if(!IsSymbolAllowed(symbol))
         return;
         
      BroadcastPositionModify(trans.position);
   }
}

//+------------------------------------------------------------------+
//| Handle pending order addition                                     |
//+------------------------------------------------------------------+
void HandleOrderAdd(const MqlTradeTransaction& trans,
                   const MqlTradeRequest& request,
                   const MqlTradeResult& result)
{
   if(trans.order == 0)
      return;
      
   if(OrderSelect(trans.order))
   {
      string symbol = OrderGetString(ORDER_SYMBOL);
      
      // Apply symbol filter
      if(!IsSymbolAllowed(symbol))
         return;
         
      BroadcastPendingOrder(trans.order, "PENDING_ADD");
   }
}

//+------------------------------------------------------------------+
//| Handle pending order deletion                                     |
//+------------------------------------------------------------------+
void HandleOrderDelete(const MqlTradeTransaction& trans,
                      const MqlTradeRequest& request,
                      const MqlTradeResult& result)
{
   if(trans.order == 0)
      return;
      
   BroadcastPendingOrderDelete(trans.order);
}

//+------------------------------------------------------------------+
//| Broadcast position open signal                                     |
//+------------------------------------------------------------------+
void BroadcastPositionOpen(ulong dealTicket)
{
   if(!HistoryDealSelect(dealTicket))
      return;
      
   string signal = "{";
   signal += "\"signal_id\":\"" + GenerateSignalID() + "\",";
   signal += "\"timestamp\":" + IntegerToString(TimeCurrent()) + ",";
   signal += "\"master_account\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ",";
   signal += "\"action\":\"OPEN\",";
   signal += "\"deal_ticket\":" + IntegerToString(dealTicket) + ",";
   signal += "\"position_ticket\":" + IntegerToString(HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID)) + ",";
   signal += "\"symbol\":\"" + HistoryDealGetString(dealTicket, DEAL_SYMBOL) + "\",";
   
   long dealType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   signal += "\"type\":\"" + ((dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL") + "\",";
   
   signal += "\"volume\":" + DoubleToString(HistoryDealGetDouble(dealTicket, DEAL_VOLUME), 2) + ",";
   signal += "\"price\":" + DoubleToString(HistoryDealGetDouble(dealTicket, DEAL_PRICE), _Digits) + ",";
   
   // Get position SL/TP
   ulong posTicket = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   double sl = 0, tp = 0;
   
   if(PositionSelectByTicket(posTicket))
   {
      sl = PositionGetDouble(POSITION_SL);
      tp = PositionGetDouble(POSITION_TP);
   }
   
   signal += "\"sl\":" + DoubleToString(sl, _Digits) + ",";
   signal += "\"tp\":" + DoubleToString(tp, _Digits) + ",";
   signal += "\"magic\":" + IntegerToString(HistoryDealGetInteger(dealTicket, DEAL_MAGIC)) + ",";
   signal += "\"comment\":\"" + HistoryDealGetString(dealTicket, DEAL_COMMENT) + "\"";
   signal += "}";
   
   WriteSignalFile(signal);
   
   g_signalCount++;
   Print("✓ Broadcast OPEN: Position #", posTicket);
}

//+------------------------------------------------------------------+
//| Broadcast position close signal                                    |
//+------------------------------------------------------------------+
void BroadcastPositionClose(ulong dealTicket)
{
   if(!HistoryDealSelect(dealTicket))
      return;
      
   string signal = "{";
   signal += "\"signal_id\":\"" + GenerateSignalID() + "\",";
   signal += "\"timestamp\":" + IntegerToString(TimeCurrent()) + ",";
   signal += "\"master_account\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ",";
   signal += "\"action\":\"CLOSE\",";
   signal += "\"deal_ticket\":" + IntegerToString(dealTicket) + ",";
   signal += "\"position_ticket\":" + IntegerToString(HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID)) + ",";
   signal += "\"symbol\":\"" + HistoryDealGetString(dealTicket, DEAL_SYMBOL) + "\",";
   signal += "\"volume\":" + DoubleToString(HistoryDealGetDouble(dealTicket, DEAL_VOLUME), 2) + ",";
   signal += "\"price\":" + DoubleToString(HistoryDealGetDouble(dealTicket, DEAL_PRICE), _Digits) + ",";
   signal += "\"profit\":" + DoubleToString(HistoryDealGetDouble(dealTicket, DEAL_PROFIT), 2);
   signal += "}";
   
   WriteSignalFile(signal);
   
   g_signalCount++;
   Print("✓ Broadcast CLOSE: Position #", HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID));
}

//+------------------------------------------------------------------+
//| Broadcast position modify signal                                   |
//+------------------------------------------------------------------+
void BroadcastPositionModify(ulong positionTicket)
{
   if(!PositionSelectByTicket(positionTicket))
      return;
      
   string signal = "{";
   signal += "\"signal_id\":\"" + GenerateSignalID() + "\",";
   signal += "\"timestamp\":" + IntegerToString(TimeCurrent()) + ",";
   signal += "\"master_account\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ",";
   signal += "\"action\":\"MODIFY\",";
   signal += "\"position_ticket\":" + IntegerToString(positionTicket) + ",";
   signal += "\"symbol\":\"" + PositionGetString(POSITION_SYMBOL) + "\",";
   signal += "\"sl\":" + DoubleToString(PositionGetDouble(POSITION_SL), _Digits) + ",";
   signal += "\"tp\":" + DoubleToString(PositionGetDouble(POSITION_TP), _Digits);
   signal += "}";
   
   WriteSignalFile(signal);
   
   g_signalCount++;
   Print("✓ Broadcast MODIFY: Position #", positionTicket);
}

//+------------------------------------------------------------------+
//| Broadcast pending order signal                                     |
//+------------------------------------------------------------------+
void BroadcastPendingOrder(ulong orderTicket, string action)
{
   if(!OrderSelect(orderTicket))
      return;
      
   string signal = "{";
   signal += "\"signal_id\":\"" + GenerateSignalID() + "\",";
   signal += "\"timestamp\":" + IntegerToString(TimeCurrent()) + ",";
   signal += "\"master_account\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ",";
   signal += "\"action\":\"" + action + "\",";
   signal += "\"order_ticket\":" + IntegerToString(orderTicket) + ",";
   signal += "\"symbol\":\"" + OrderGetString(ORDER_SYMBOL) + "\",";
   signal += "\"type\":\"" + EnumToString((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)) + "\",";
   signal += "\"volume\":" + DoubleToString(OrderGetDouble(ORDER_VOLUME_CURRENT), 2) + ",";
   signal += "\"price\":" + DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), _Digits) + ",";
   signal += "\"sl\":" + DoubleToString(OrderGetDouble(ORDER_SL), _Digits) + ",";
   signal += "\"tp\":" + DoubleToString(OrderGetDouble(ORDER_TP), _Digits);
   signal += "}";
   
   WriteSignalFile(signal);
   
   g_signalCount++;
   Print("✓ Broadcast ", action, ": Order #", orderTicket);
}

//+------------------------------------------------------------------+
//| Broadcast pending order deletion                                   |
//+------------------------------------------------------------------+
void BroadcastPendingOrderDelete(ulong orderTicket)
{
   string signal = "{";
   signal += "\"signal_id\":\"" + GenerateSignalID() + "\",";
   signal += "\"timestamp\":" + IntegerToString(TimeCurrent()) + ",";
   signal += "\"master_account\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ",";
   signal += "\"action\":\"PENDING_DELETE\",";
   signal += "\"order_ticket\":" + IntegerToString(orderTicket);
   signal += "}";
   
   WriteSignalFile(signal);
   
   g_signalCount++;
   Print("✓ Broadcast PENDING_DELETE: Order #", orderTicket);
}

//+------------------------------------------------------------------+
//| Write signal to file                                               |
//+------------------------------------------------------------------+
void WriteSignalFile(string signalData)
{
   int fileHandle = FileOpen(g_signalFile, FILE_WRITE | FILE_COMMON | FILE_TXT | FILE_ANSI);
   
   if(fileHandle != INVALID_HANDLE)
   {
      FileWriteString(fileHandle, signalData);
      FileClose(fileHandle);
      g_lastUpdate = TimeCurrent();
   }
   else
   {
      Print("ERROR: Failed to write signal file. Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Generate unique signal ID                                          |
//+------------------------------------------------------------------+
string GenerateSignalID()
{
   return IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + 
          IntegerToString(TimeCurrent()) + "_" + 
          IntegerToString(GetMicrosecondCount());
}

//+------------------------------------------------------------------+
//| Check if symbol is allowed                                         |
//+------------------------------------------------------------------+
bool IsSymbolAllowed(string symbol)
{
   if(SymbolFilter == "")
      return true;
      
   string symbols[];
   int count = StringSplit(SymbolFilter, ',', symbols);
   
   for(int i = 0; i < count; i++)
   {
      string filterSymbol = symbols[i];
      StringTrimLeft(filterSymbol);
      StringTrimRight(filterSymbol);
      
      if(filterSymbol == symbol)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Update position snapshot                                           |
//+------------------------------------------------------------------+
void UpdatePositionSnapshot()
{
   g_activePositions = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(MagicNumber == 0 || PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            string symbol = PositionGetString(POSITION_SYMBOL);
            if(IsSymbolAllowed(symbol))
               g_activePositions++;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Create UI panel                                                    |
//+------------------------------------------------------------------+
void CreatePanel()
{
   string prefix = "TORAMA_INV_MASTER_";
   
   // Panel background
   ObjectCreate(g_chartID, prefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_XDISTANCE, PanelX);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_YDISTANCE, PanelY);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_XSIZE, 280);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_YSIZE, 160);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_BGCOLOR, PanelColor);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_WIDTH, 2);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_BACK, true);
   
   // Title
   ObjectCreate(g_chartID, prefix + "TITLE", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(g_chartID, prefix + "TITLE", OBJPROP_XDISTANCE, PanelX + 10);
   ObjectSetInteger(g_chartID, prefix + "TITLE", OBJPROP_YDISTANCE, PanelY + 8);
   ObjectSetString(g_chartID, prefix + "TITLE", OBJPROP_TEXT, "TORAMA INVERSE MASTER");
   ObjectSetString(g_chartID, prefix + "TITLE", OBJPROP_FONT, "Arial Black");
   ObjectSetInteger(g_chartID, prefix + "TITLE", OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(g_chartID, prefix + "TITLE", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(g_chartID, prefix + "TITLE", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   
   // Info labels
   string labels[] = {"STATUS", "ACCOUNT", "SIGNALS", "POSITIONS", "LAST_UPDATE"};
   for(int i = 0; i < ArraySize(labels); i++)
   {
      ObjectCreate(g_chartID, prefix + labels[i], OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(g_chartID, prefix + labels[i], OBJPROP_XDISTANCE, PanelX + 10);
      ObjectSetInteger(g_chartID, prefix + labels[i], OBJPROP_YDISTANCE, PanelY + 35 + (i * 25));
      ObjectSetString(g_chartID, prefix + labels[i], OBJPROP_FONT, "Consolas");
      ObjectSetInteger(g_chartID, prefix + labels[i], OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(g_chartID, prefix + labels[i], OBJPROP_COLOR, TextColor);
      ObjectSetInteger(g_chartID, prefix + labels[i], OBJPROP_CORNER, CORNER_LEFT_UPPER);
   }
}

//+------------------------------------------------------------------+
//| Update UI panel                                                    |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   string prefix = "TORAMA_INV_MASTER_";
   
   UpdatePositionSnapshot();
   
   ObjectSetString(g_chartID, prefix + "STATUS", OBJPROP_TEXT, 
                   "Status: BROADCASTING");
                   
   ObjectSetString(g_chartID, prefix + "ACCOUNT", OBJPROP_TEXT, 
                   "Account: " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
                   
   ObjectSetString(g_chartID, prefix + "SIGNALS", OBJPROP_TEXT, 
                   "Signals Sent: " + IntegerToString(g_signalCount));
                   
   ObjectSetString(g_chartID, prefix + "POSITIONS", OBJPROP_TEXT, 
                   "Active Positions: " + IntegerToString(g_activePositions));
                   
   ObjectSetString(g_chartID, prefix + "LAST_UPDATE", OBJPROP_TEXT, 
                   "Last Signal: " + ((g_lastUpdate > 0) ? TimeToString(g_lastUpdate, TIME_DATE | TIME_SECONDS) : "None"));
}

//+------------------------------------------------------------------+
//| Delete UI panel                                                    |
//+------------------------------------------------------------------+
void DeletePanel()
{
   string prefix = "TORAMA_INV_MASTER_";
   ObjectDelete(g_chartID, prefix + "BG");
   ObjectDelete(g_chartID, prefix + "TITLE");
   ObjectDelete(g_chartID, prefix + "STATUS");
   ObjectDelete(g_chartID, prefix + "ACCOUNT");
   ObjectDelete(g_chartID, prefix + "SIGNALS");
   ObjectDelete(g_chartID, prefix + "POSITIONS");
   ObjectDelete(g_chartID, prefix + "LAST_UPDATE");
}
//+------------------------------------------------------------------+
