//+------------------------------------------------------------------+
//|                                   TORAMA_Inverse_Slave.mq5        |
//|                                      TORAMA CAPITAL               |
//|                                      www.torama.money             |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "www.torama.money"
#property version   "1.00"
#property description "Slave EA - Executes inverse trades from master signals"
#property description "Place on SLAVE account to receive and inverse signals"

//--- Input parameters
input group "=== Signal Reception Settings ==="
input string   MasterAccountNumber = "";               // Master account number
input int      PollIntervalMS = 100;                   // Signal check interval (ms)
input double   LotMultiplier = 1.0;                    // Lot size multiplier
input int      MagicNumber = 999888;                   // Magic number for inverse trades
input int      Slippage = 50;                          // Maximum slippage in points

input group "=== Risk Management ==="
input int      MaxInversePositions = 10;               // Maximum inverse positions
input bool     EnableEmergencyStop = true;             // Enable emergency stop
input double   MaxDrawdownPercent = 30.0;              // Max drawdown % for emergency stop
input bool     InvertSLTP = true;                      // Invert SL/TP levels

input group "=== Trading Filters ==="
input string   SymbolFilter = "";                      // Symbol filter (empty=all)
input bool     CopyPendingOrders = true;               // Copy pending orders

input group "=== Visual Settings ==="
input color    PanelColor = clrDarkGreen;              // Panel background color
input color    TextColor = clrWhite;                   // Text color
input int      PanelX = 20;                            // Panel X position
input int      PanelY = 30;                            // Panel Y position

//--- Global variables
string g_signalFile;
long g_chartID;
datetime g_lastProcessedTime = 0;
int g_tradesExecuted = 0;
int g_tradesFailed = 0;
double g_initialBalance;
bool g_emergencyStopTriggered = false;

//--- Position mapping structure
struct PositionMapping
{
   ulong masterTicket;
   ulong slaveTicket;
   string symbol;
   double masterVolume;
   double slaveVolume;
   datetime mappingTime;
};

PositionMapping g_positionMap[];

//--- Trade execution structure
#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_chartID = ChartID();
   g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   // Validate master account number
   if(MasterAccountNumber == "")
   {
      Alert("ERROR: Master account number not specified!");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   // Generate signal file name
   g_signalFile = "TORAMA_INVERSE_" + MasterAccountNumber + ".json";
   
   // Setup trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetAsyncMode(false);
   
   Print("=== TORAMA INVERSE SLAVE INITIALIZED ===");
   Print("Slave Account: ", AccountInfoInteger(ACCOUNT_LOGIN));
   Print("Master Account: ", MasterAccountNumber);
   Print("Signal File: ", g_signalFile);
   Print("Lot Multiplier: ", LotMultiplier);
   
   // Create UI panel
   CreatePanel();
   UpdatePanel();
   
   // Set timer for signal polling
   EventSetMillisecondTimer(PollIntervalMS);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   DeletePanel();
   
   Print("=== TORAMA INVERSE SLAVE STOPPED ===");
   Print("Trades Executed: ", g_tradesExecuted);
   Print("Trades Failed: ", g_tradesFailed);
}

//+------------------------------------------------------------------+
//| Timer function - Poll for new signals                             |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Check emergency stop
   if(EnableEmergencyStop)
      CheckEmergencyStop();
   
   if(g_emergencyStopTriggered)
   {
      UpdatePanel();
      return;
   }
   
   // Read and process signal
   ProcessSignalFile();
   
   // Update UI
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| Process signal file                                                |
//+------------------------------------------------------------------+
void ProcessSignalFile()
{
   int fileHandle = FileOpen(g_signalFile, FILE_READ | FILE_COMMON | FILE_TXT | FILE_ANSI);
   
   if(fileHandle == INVALID_HANDLE)
      return; // No signal file yet
      
   string signalData = FileReadString(fileHandle);
   FileClose(fileHandle);
   
   if(StringLen(signalData) == 0)
      return;
   
   // Parse JSON signal
   ParseAndExecuteSignal(signalData);
}

//+------------------------------------------------------------------+
//| Parse and execute signal                                           |
//+------------------------------------------------------------------+
void ParseAndExecuteSignal(string json)
{
   // Extract timestamp to avoid reprocessing
   datetime signalTime = (datetime)ExtractJSONValue(json, "timestamp");
   
   if(signalTime <= g_lastProcessedTime)
      return; // Already processed
      
   g_lastProcessedTime = signalTime;
   
   // Extract signal data
   string action = ExtractJSONValue(json, "action");
   string symbol = ExtractJSONValue(json, "symbol");
   
   // Apply symbol filter
   if(!IsSymbolAllowed(symbol))
      return;
   
   // Execute based on action
   if(action == "OPEN")
   {
      ExecuteInverseOpen(json);
   }
   else if(action == "CLOSE")
   {
      ExecuteInverseClose(json);
   }
   else if(action == "MODIFY")
   {
      ExecuteInverseModify(json);
   }
   else if(action == "PENDING_ADD" && CopyPendingOrders)
   {
      ExecuteInversePendingOrder(json);
   }
   else if(action == "PENDING_DELETE" && CopyPendingOrders)
   {
      ExecuteInversePendingDelete(json);
   }
}

//+------------------------------------------------------------------+
//| Execute inverse position open                                      |
//+------------------------------------------------------------------+
void ExecuteInverseOpen(string json)
{
   // Check position limit
   if(CountInversePositions() >= MaxInversePositions)
   {
      Print("⚠ Max positions limit reached. Skipping signal.");
      return;
   }
   
   // Extract trade data
   ulong masterTicket = (ulong)StringToInteger(ExtractJSONValue(json, "position_ticket"));
   string symbol = ExtractJSONValue(json, "symbol");
   string type = ExtractJSONValue(json, "type");
   double volume = StringToDouble(ExtractJSONValue(json, "volume")) * LotMultiplier;
   double price = StringToDouble(ExtractJSONValue(json, "price"));
   double sl = StringToDouble(ExtractJSONValue(json, "sl"));
   double tp = StringToDouble(ExtractJSONValue(json, "tp"));
   
   // Normalize volume
   volume = NormalizeVolume(symbol, volume);
   
   if(volume <= 0)
   {
      Print("ERROR: Invalid volume after normalization");
      g_tradesFailed++;
      return;
   }
   
   // Inverse the trade type
   ENUM_ORDER_TYPE inverseType = (type == "BUY") ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   
   // Inverse SL/TP if enabled
   double inverseSL = 0, inverseTP = 0;
   if(InvertSLTP)
   {
      double currentPrice = (inverseType == ORDER_TYPE_BUY) ? 
                           SymbolInfoDouble(symbol, SYMBOL_ASK) : 
                           SymbolInfoDouble(symbol, SYMBOL_BID);
      
      if(tp > 0)
      {
         double tpDistance = MathAbs(price - tp);
         inverseSL = (inverseType == ORDER_TYPE_BUY) ? 
                     currentPrice - tpDistance : 
                     currentPrice + tpDistance;
      }
      
      if(sl > 0)
      {
         double slDistance = MathAbs(price - sl);
         inverseTP = (inverseType == ORDER_TYPE_BUY) ? 
                     currentPrice + slDistance : 
                     currentPrice - slDistance;
      }
   }
   else
   {
      inverseSL = sl;
      inverseTP = tp;
   }
   
   // Execute trade
   bool result = false;
   string comment = "INVERSE_" + IntegerToString(masterTicket);
   
   if(inverseType == ORDER_TYPE_BUY)
   {
      result = trade.Buy(volume, symbol, 0, inverseSL, inverseTP, comment);
   }
   else
   {
      result = trade.Sell(volume, symbol, 0, inverseSL, inverseTP, comment);
   }
   
   if(result)
   {
      ulong slaveTicket = trade.ResultOrder();
      
      // Wait for position to appear
      Sleep(100);
      
      // Find actual position ticket
      for(int i = 0; i < PositionsTotal(); i++)
      {
         if(PositionGetTicket(i) > 0)
         {
            if(PositionGetString(POSITION_COMMENT) == comment)
            {
               slaveTicket = PositionGetInteger(POSITION_TICKET);
               break;
            }
         }
      }
      
      // Map positions
      AddPositionMapping(masterTicket, slaveTicket, symbol, 
                        StringToDouble(ExtractJSONValue(json, "volume")), volume);
      
      g_tradesExecuted++;
      Print("✓ Inverse OPEN executed: ", symbol, " ", EnumToString(inverseType), 
            " ", volume, " lots | Slave ticket: ", slaveTicket);
   }
   else
   {
      g_tradesFailed++;
      Print("✗ Failed to open inverse position: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Execute inverse position close                                     |
//+------------------------------------------------------------------+
void ExecuteInverseClose(string json)
{
   ulong masterTicket = (ulong)StringToInteger(ExtractJSONValue(json, "position_ticket"));
   double masterVolume = StringToDouble(ExtractJSONValue(json, "volume"));
   
   // Find mapped slave position
   ulong slaveTicket = FindSlaveTicket(masterTicket);
   
   if(slaveTicket == 0)
   {
      Print("⚠ No mapped slave position found for master #", masterTicket);
      return;
   }
   
   if(!PositionSelectByTicket(slaveTicket))
   {
      Print("⚠ Slave position #", slaveTicket, " not found");
      RemovePositionMapping(masterTicket);
      return;
   }
   
   double slaveVolume = PositionGetDouble(POSITION_VOLUME);
   PositionMapping mapping = GetPositionMapping(masterTicket);
   
   // Calculate close volume (handle partial closes)
   double closeVolume = slaveVolume;
   
   if(masterVolume < mapping.masterVolume) // Partial close
   {
      double closeProportion = masterVolume / mapping.masterVolume;
      closeVolume = NormalizeVolume(PositionGetString(POSITION_SYMBOL), 
                                    slaveVolume * closeProportion);
   }
   
   // Close position
   bool result = trade.PositionClose(slaveTicket);
   
   if(result)
   {
      // Update or remove mapping
      if(closeVolume < slaveVolume) // Partial close
      {
         UpdatePositionMapping(masterTicket, mapping.masterVolume - masterVolume, 
                              slaveVolume - closeVolume);
      }
      else // Full close
      {
         RemovePositionMapping(masterTicket);
      }
      
      g_tradesExecuted++;
      Print("✓ Inverse CLOSE executed: Position #", slaveTicket, " | Volume: ", closeVolume);
   }
   else
   {
      g_tradesFailed++;
      Print("✗ Failed to close inverse position: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Execute inverse position modify                                    |
//+------------------------------------------------------------------+
void ExecuteInverseModify(string json)
{
   ulong masterTicket = (ulong)StringToInteger(ExtractJSONValue(json, "position_ticket"));
   double sl = StringToDouble(ExtractJSONValue(json, "sl"));
   double tp = StringToDouble(ExtractJSONValue(json, "tp"));
   
   // Find mapped slave position
   ulong slaveTicket = FindSlaveTicket(masterTicket);
   
   if(slaveTicket == 0)
   {
      Print("⚠ No mapped slave position found for modify");
      return;
   }
   
   if(!PositionSelectByTicket(slaveTicket))
   {
      Print("⚠ Slave position not found for modify");
      return;
   }
   
   string symbol = PositionGetString(POSITION_SYMBOL);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   
   // Inverse SL/TP if enabled
   double inverseSL = 0, inverseTP = 0;
   
   if(InvertSLTP)
   {
      double currentPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      
      if(tp > 0)
      {
         double masterPrice = StringToDouble(ExtractJSONValue(json, "price"));
         if(masterPrice == 0)
            masterPrice = currentPrice;
            
         double tpDistance = MathAbs(masterPrice - tp);
         inverseSL = (posType == POSITION_TYPE_BUY) ? 
                     currentPrice - tpDistance : 
                     currentPrice + tpDistance;
      }
      
      if(sl > 0)
      {
         double masterPrice = StringToDouble(ExtractJSONValue(json, "price"));
         if(masterPrice == 0)
            masterPrice = currentPrice;
            
         double slDistance = MathAbs(masterPrice - sl);
         inverseTP = (posType == POSITION_TYPE_BUY) ? 
                     currentPrice + slDistance : 
                     currentPrice - slDistance;
      }
   }
   else
   {
      inverseSL = sl;
      inverseTP = tp;
   }
   
   // Modify position
   bool result = trade.PositionModify(slaveTicket, inverseSL, inverseTP);
   
   if(result)
   {
      Print("✓ Inverse MODIFY executed: Position #", slaveTicket);
   }
   else
   {
      Print("✗ Failed to modify inverse position: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Execute inverse pending order                                      |
//+------------------------------------------------------------------+
void ExecuteInversePendingOrder(string json)
{
   // Extract order data
   string symbol = ExtractJSONValue(json, "symbol");
   string typeStr = ExtractJSONValue(json, "type");
   double volume = StringToDouble(ExtractJSONValue(json, "volume")) * LotMultiplier;
   double price = StringToDouble(ExtractJSONValue(json, "price"));
   double sl = StringToDouble(ExtractJSONValue(json, "sl"));
   double tp = StringToDouble(ExtractJSONValue(json, "tp"));
   
   volume = NormalizeVolume(symbol, volume);
   
   // Inverse order type
   ENUM_ORDER_TYPE inverseType = ORDER_TYPE_BUY_LIMIT; // Default
   
   if(typeStr == "ORDER_TYPE_BUY_LIMIT")
      inverseType = ORDER_TYPE_SELL_LIMIT;
   else if(typeStr == "ORDER_TYPE_SELL_LIMIT")
      inverseType = ORDER_TYPE_BUY_LIMIT;
   else if(typeStr == "ORDER_TYPE_BUY_STOP")
      inverseType = ORDER_TYPE_SELL_STOP;
   else if(typeStr == "ORDER_TYPE_SELL_STOP")
      inverseType = ORDER_TYPE_BUY_STOP;
   
   // Place inverse pending order
   bool result = trade.OrderOpen(symbol, inverseType, volume, 0, price, sl, tp);
   
   if(result)
   {
      Print("✓ Inverse PENDING order placed: ", symbol, " ", EnumToString(inverseType));
   }
   else
   {
      Print("✗ Failed to place inverse pending order: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Execute inverse pending order deletion                             |
//+------------------------------------------------------------------+
void ExecuteInversePendingDelete(string json)
{
   ulong masterOrderTicket = (ulong)StringToInteger(ExtractJSONValue(json, "order_ticket"));
   
   // Find corresponding slave order (would need mapping system for pending orders)
   // For now, just log
   Print("⚠ Pending order delete signal received for master order #", masterOrderTicket);
}

//+------------------------------------------------------------------+
//| Position mapping functions                                         |
//+------------------------------------------------------------------+
void AddPositionMapping(ulong masterTicket, ulong slaveTicket, string symbol, 
                       double masterVol, double slaveVol)
{
   int size = ArraySize(g_positionMap);
   ArrayResize(g_positionMap, size + 1);
   
   g_positionMap[size].masterTicket = masterTicket;
   g_positionMap[size].slaveTicket = slaveTicket;
   g_positionMap[size].symbol = symbol;
   g_positionMap[size].masterVolume = masterVol;
   g_positionMap[size].slaveVolume = slaveVol;
   g_positionMap[size].mappingTime = TimeCurrent();
}

ulong FindSlaveTicket(ulong masterTicket)
{
   for(int i = 0; i < ArraySize(g_positionMap); i++)
   {
      if(g_positionMap[i].masterTicket == masterTicket)
         return g_positionMap[i].slaveTicket;
   }
   return 0;
}

PositionMapping GetPositionMapping(ulong masterTicket)
{
   PositionMapping emptyMapping;
   
   for(int i = 0; i < ArraySize(g_positionMap); i++)
   {
      if(g_positionMap[i].masterTicket == masterTicket)
         return g_positionMap[i];
   }
   return emptyMapping;
}

void RemovePositionMapping(ulong masterTicket)
{
   for(int i = 0; i < ArraySize(g_positionMap); i++)
   {
      if(g_positionMap[i].masterTicket == masterTicket)
      {
         // Shift array
         for(int j = i; j < ArraySize(g_positionMap) - 1; j++)
         {
            g_positionMap[j] = g_positionMap[j + 1];
         }
         ArrayResize(g_positionMap, ArraySize(g_positionMap) - 1);
         return;
      }
   }
}

void UpdatePositionMapping(ulong masterTicket, double newMasterVol, double newSlaveVol)
{
   for(int i = 0; i < ArraySize(g_positionMap); i++)
   {
      if(g_positionMap[i].masterTicket == masterTicket)
      {
         g_positionMap[i].masterVolume = newMasterVol;
         g_positionMap[i].slaveVolume = newSlaveVol;
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Utility functions                                                  |
//+------------------------------------------------------------------+
string ExtractJSONValue(string json, string key)
{
   string searchKey = "\"" + key + "\":";
   int startPos = StringFind(json, searchKey);
   
   if(startPos < 0)
      return "";
      
   startPos += StringLen(searchKey);
   
   // Skip whitespace and quotes
   while(startPos < StringLen(json) && 
         (StringGetCharacter(json, startPos) == ' ' || 
          StringGetCharacter(json, startPos) == '\"'))
      startPos++;
   
   int endPos = startPos;
   bool inString = (StringGetCharacter(json, startPos - 1) == '\"');
   
   while(endPos < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, endPos);
      
      if(inString && ch == '\"')
         break;
      if(!inString && (ch == ',' || ch == '}'))
         break;
         
      endPos++;
   }
   
   return StringSubstr(json, startPos, endPos - startPos);
}

double NormalizeVolume(string symbol, double volume)
{
   double minVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   if(volume < minVolume)
      volume = minVolume;
   if(volume > maxVolume)
      volume = maxVolume;
      
   volume = MathFloor(volume / stepVolume) * stepVolume;
   
   return NormalizeDouble(volume, 2);
}

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

int CountInversePositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0)
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            count++;
      }
   }
   return count;
}

void CheckEmergencyStop()
{
   if(g_emergencyStopTriggered)
      return;
      
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double drawdown = ((g_initialBalance - currentBalance) / g_initialBalance) * 100;
   
   if(drawdown >= MaxDrawdownPercent)
   {
      g_emergencyStopTriggered = true;
      
      Alert("⚠ EMERGENCY STOP TRIGGERED! Drawdown: ", drawdown, "%");
      
      // Close all inverse positions
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(PositionGetTicket(i) > 0)
         {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
               trade.PositionClose(PositionGetInteger(POSITION_TICKET));
            }
         }
      }
      
      Print("=== EMERGENCY STOP: All inverse positions closed ===");
   }
}

//+------------------------------------------------------------------+
//| UI Panel functions                                                 |
//+------------------------------------------------------------------+
void CreatePanel()
{
   string prefix = "TORAMA_INV_SLAVE_";
   
   // Panel background
   ObjectCreate(g_chartID, prefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_XDISTANCE, PanelX);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_YDISTANCE, PanelY);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_XSIZE, 300);
   ObjectSetInteger(g_chartID, prefix + "BG", OBJPROP_YSIZE, 210);
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
   ObjectSetString(g_chartID, prefix + "TITLE", OBJPROP_TEXT, "TORAMA INVERSE SLAVE");
   ObjectSetString(g_chartID, prefix + "TITLE", OBJPROP_FONT, "Arial Black");
   ObjectSetInteger(g_chartID, prefix + "TITLE", OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(g_chartID, prefix + "TITLE", OBJPROP_COLOR, clrLime);
   ObjectSetInteger(g_chartID, prefix + "TITLE", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   
   // Info labels
   string labels[] = {"STATUS", "MASTER", "SLAVE", "EXECUTED", "FAILED", "POSITIONS", "MAPPINGS"};
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

void UpdatePanel()
{
   string prefix = "TORAMA_INV_SLAVE_";
   
   string status = g_emergencyStopTriggered ? "⚠ EMERGENCY STOP" : "ACTIVE";
   color statusColor = g_emergencyStopTriggered ? clrRed : clrLime;
   
   ObjectSetString(g_chartID, prefix + "STATUS", OBJPROP_TEXT, "Status: " + status);
   ObjectSetInteger(g_chartID, prefix + "STATUS", OBJPROP_COLOR, statusColor);
   
   ObjectSetString(g_chartID, prefix + "MASTER", OBJPROP_TEXT, 
                   "Master: " + MasterAccountNumber);
                   
   ObjectSetString(g_chartID, prefix + "SLAVE", OBJPROP_TEXT, 
                   "Slave: " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
                   
   ObjectSetString(g_chartID, prefix + "EXECUTED", OBJPROP_TEXT, 
                   "Executed: " + IntegerToString(g_tradesExecuted));
                   
   ObjectSetString(g_chartID, prefix + "FAILED", OBJPROP_TEXT, 
                   "Failed: " + IntegerToString(g_tradesFailed));
                   
   ObjectSetString(g_chartID, prefix + "POSITIONS", OBJPROP_TEXT, 
                   "Positions: " + IntegerToString(CountInversePositions()));
                   
   ObjectSetString(g_chartID, prefix + "MAPPINGS", OBJPROP_TEXT, 
                   "Mappings: " + IntegerToString(ArraySize(g_positionMap)));
}

void DeletePanel()
{
   string prefix = "TORAMA_INV_SLAVE_";
   ObjectDelete(g_chartID, prefix + "BG");
   ObjectDelete(g_chartID, prefix + "TITLE");
   ObjectDelete(g_chartID, prefix + "STATUS");
   ObjectDelete(g_chartID, prefix + "MASTER");
   ObjectDelete(g_chartID, prefix + "SLAVE");
   ObjectDelete(g_chartID, prefix + "EXECUTED");
   ObjectDelete(g_chartID, prefix + "FAILED");
   ObjectDelete(g_chartID, prefix + "POSITIONS");
   ObjectDelete(g_chartID, prefix + "MAPPINGS");
}
//+------------------------------------------------------------------+
