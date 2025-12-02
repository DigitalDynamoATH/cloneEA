//+------------------------------------------------------------------+
//|                                            SignalReceiver.mq5    |
//|                        Signal Receiver EA - Receives signals     |
//|                        and opens trades with custom settings     |
//+------------------------------------------------------------------+
#property copyright "Signal Receiver"
#property version   "1.00"
#property strict

// Allow WebRequest for the API URL
#property description "IMPORTANT: Add the API URL to Tools -> Options -> Expert Advisors -> 'Allow WebRequest for listed URL'"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| ==================== BASIC SETTINGS ====================         |
//+------------------------------------------------------------------+
input group "=== BASIC SETTINGS ==="
input int      Magic_Number = 98765;           // Magic number for this EA
input int      Check_Interval_MS = 100;         // Check interval in milliseconds
input string   Ngrok_API_URL = "https://uncloven-megadont-elisa.ngrok-free.dev/api/signal";  // API endpoint (auto-updated by start_all.sh)

//+------------------------------------------------------------------+
//| ==================== TRADE SETTINGS ====================         |
//+------------------------------------------------------------------+
input group "=== TRADE SETTINGS ==="
input double   Volume_Number = 0.01;           // Lot size to open trades (exact volume used)
input double   Stop_Loss_EUR = 0.0;            // Stop Loss in EUR (0 = no SL)
input double   Take_Profit_EUR = 150.0;        // Take Profit in EUR (0 = no TP)
input int      Slippage = 30;                   // Maximum slippage in points
input string   Trade_Comment = "Copied Trade";  // Comment for opened trades

//+------------------------------------------------------------------+
//| ==================== SYMBOL SETTINGS ====================        |
//+------------------------------------------------------------------+
input group "=== SYMBOL SETTINGS ==="
input bool     Use_Custom_Symbol = false;      // Use custom symbol instead of signal's symbol
input string   Custom_Symbol = "XAUUSD";       // Custom symbol to trade (if Use_Custom_Symbol = true)

//+------------------------------------------------------------------+
//| ==================== TRADE MANAGEMENT ====================       |
//+------------------------------------------------------------------+
input group "=== TRADE MANAGEMENT ==="
input bool     Use_Smart_Mode = false;         // Enable SMART MODE (Break Even: 20% trigger, 5% lock | Trailing Stop: 15% distance)

//+------------------------------------------------------------------+
//| ==================== DAILY OPTIONS ====================          |
//+------------------------------------------------------------------+
input group "=== DAILY OPTIONS ==="
input bool     Use_Daily_Profit_Target = false; // Stop opening trades when daily profit target is reached
input double   Daily_Profit_Target_EUR = 1000.0; // Daily profit target in EUR (goal for progress bar)
input double   Commission_Per_Trade_EUR = 0.0;  // Commission per trade in EUR (added as loss to daily profit)
input bool     Use_Daily_Close = false;        // Close all trades at specific time daily
input int      Daily_Close_Hour = 22;           // Hour to close trades (0-23)
input int      Daily_Close_Minute = 0;          // Minute to close trades (0-59)
input bool     Close_Only_Profit = false;      // Close only profitable trades at daily close

//--- Global variables
CTrade trade;
datetime lastCheckTime = 0;
string lastProcessedSignal = "";
ulong processedTickets[];
int lastSignalId = 0;  // Track last received signal ID from API
datetime lastDailyCloseTime = 0;  // Track last daily close execution
datetime lastDailyReset = 0;  // Track daily profit reset time
bool dailyTargetReached = false;  // Track if daily profit target was reached (to close all trades once)

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(Magic_Number);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK); // Try FOK first, adjust if needed
   
   ArrayResize(processedTickets, 0);
   
   // Create progress bar panel on chart
   CreateProgressBar();
   
   string sep = "============================================================";
   Print(sep);
   Print("Signal Receiver EA initialized. Magic: ", Magic_Number);
   Print("Custom SL: ", Stop_Loss_EUR, " EUR, TP: ", Take_Profit_EUR, " EUR");
   Print("✅ Using DIRECT HTTP (no files)");
   if(Use_Smart_Mode)
      Print("🧠 SMART MODE: ENABLED (Break Even: 20% trigger, 5% lock | Trailing Stop: 15% distance)");
   if(Use_Daily_Close)
      Print("✅ Daily Close: ENABLED (", Daily_Close_Hour, ":", StringFormat("%02d", Daily_Close_Minute), ")");
   if(Use_Custom_Symbol)
      Print("✅ Custom Symbol: ENABLED (", Custom_Symbol, ")");
   if(Use_Daily_Profit_Target)
      Print("✅ Daily Profit Target: ENABLED (", Daily_Profit_Target_EUR, " EUR)");
   Print("API URL: ", Ngrok_API_URL);
   Print("⚠️  Make sure API URL is in allowed list:");
   Print("   Tools -> Options -> Expert Advisors -> 'Allow WebRequest for listed URL'");
   Print("   Add: ", Ngrok_API_URL);
   Print(sep);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Remove progress bar panel
   RemoveProgressBar();
   Print("Signal Receiver EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for new signals periodically
   if(GetTickCount() - lastCheckTime < Check_Interval_MS)
      return;
   
   lastCheckTime = GetTickCount();
   
   // Check for new signals
   CheckForNewSignals();
   
   // Manage open trades (SMART MODE or manual Trailing Stop/Break Even)
   if(Use_Smart_Mode)
      ManageOpenTrades();
   
   // Check for daily close time
   if(Use_Daily_Close)
      CheckDailyClose();
   
   // Check if daily profit target reached - close all trades immediately
   if(Use_Daily_Profit_Target)
   {
      double dailyProfit = GetDailyProfit();
      if(dailyProfit >= Daily_Profit_Target_EUR)
      {
         if(!dailyTargetReached)
         {
            Print("💰💰💰 DAILY PROFIT TARGET REACHED! 💰💰💰");
            Print("   Current Profit: ", dailyProfit, " EUR");
            Print("   Target: ", Daily_Profit_Target_EUR, " EUR");
            Print("   🚪 Closing ALL trades immediately...");
            
            CloseAllTradesForTarget();
            dailyTargetReached = true;
         }
         else
         {
            // If target already reached but trades still open, try to close again
            int openTrades = 0;
            for(int i = 0; i < PositionsTotal(); i++)
            {
               ulong ticket = PositionGetTicket(i);
               if(ticket > 0 && PositionSelectByTicket(ticket))
               {
                  if(PositionGetInteger(POSITION_MAGIC) == Magic_Number)
                     openTrades++;
               }
            }
            
            if(openTrades > 0)
            {
               Print("⚠️  Target reached but ", openTrades, " trades still open. Retrying to close...");
               CloseAllTradesForTarget();
            }
         }
      }
   }
   
   // Update progress bar
   UpdateProgressBar();
}

//+------------------------------------------------------------------+
//| Check for new signals from API                                   |
//+------------------------------------------------------------------+
void CheckForNewSignals()
{
   // Get signal directly from API via HTTP
   string signal = GetSignalViaHTTP();
   if(signal != "" && signal != lastProcessedSignal)
   {
      lastProcessedSignal = signal;
      ProcessSignal(signal);
   }
}

//+------------------------------------------------------------------+
//| Get signal directly from API via HTTP (using WebRequest)        |
//+------------------------------------------------------------------+
string GetSignalViaHTTP()
{
   // Build URL with last_id parameter
   string url = Ngrok_API_URL;
   if(lastSignalId > 0)
      url += "?last_id=" + IntegerToString(lastSignalId);
   
   // Prepare headers
   string headers = "ngrok-skip-browser-warning: true\r\n";
   headers += "\r\n";  // End headers with double CRLF
   
   char result[];
   string result_headers;
   
   // Send GET request (use simpler signature without cookie for GET)
   // Increased timeout to 10 seconds for better reliability
   char empty[];
   int res = WebRequest("GET", url, headers, 10000, empty, result, result_headers);
   
   if(res == 200) // HTTP 200 OK - New signal received
   {
      string response = CharArrayToString(result);
      
      // Parse JSON response (simple parsing)
      // Expected format: {"id":1,"signal":"ACTION=OPEN|...","timestamp":"..."}
      int idPos = StringFind(response, "\"id\":");
      int signalPos = StringFind(response, "\"signal\":\"");
      
      if(idPos >= 0 && signalPos >= 0)
      {
         // Extract signal ID
         string idStr = "";
         int idStart = idPos + 5;
         int idEnd = StringFind(response, ",", idStart);
         if(idEnd < 0) idEnd = StringFind(response, "}", idStart);
         if(idEnd > idStart)
            idStr = StringSubstr(response, idStart, idEnd - idStart);
         
         // Remove whitespace from idStr
         string cleanIdStr = idStr;
         StringReplace(cleanIdStr, " ", "");
         StringReplace(cleanIdStr, "\t", "");
         StringReplace(cleanIdStr, "\n", "");
         StringReplace(cleanIdStr, "\r", "");
         lastSignalId = (int)StringToInteger(cleanIdStr);
         
         // Extract signal - handle escaped quotes in JSON
         int signalStart = signalPos + 10;
         int signalEnd = signalStart;
         int searchPos = signalStart;
         
         // Find the closing quote, handling escaped quotes (\")
         while(searchPos < StringLen(response))
         {
            int nextQuote = StringFind(response, "\"", searchPos);
            if(nextQuote < 0) break;
            
            // Check if this quote is escaped (preceded by backslash)
            if(nextQuote > 0 && StringGetCharacter(response, nextQuote - 1) == '\\')
            {
               // Escaped quote, continue searching
               searchPos = nextQuote + 1;
            }
            else
            {
               // Found the closing quote
               signalEnd = nextQuote;
               break;
            }
         }
         
         if(signalEnd > signalStart)
         {
            string signal = StringSubstr(response, signalStart, signalEnd - signalStart);
            
            // Unescape JSON escape sequences
            StringReplace(signal, "\\\"", "\"");  // Unescape quotes
            StringReplace(signal, "\\\\", "\\"); // Unescape backslashes
            StringReplace(signal, "\\n", "\n");  // Unescape newlines
            StringReplace(signal, "\\r", "\r");  // Unescape carriage returns
            
            string sep = "============================================================";
            Print(sep);
            Print("✅ SIGNAL RECEIVED FROM API!");
            Print("Signal ID: ", lastSignalId);
            Print("Signal: ", signal);
            Print(sep);
            
            return signal;
         }
      }
   }
   else if(res == 204) // HTTP 204 No Content - No new signal
   {
      // No new signal, this is normal
      return "";
   }
   else if(res == -1)
   {
      int errorCode = GetLastError();
      Print("❌ WebRequest failed. Error code: ", errorCode);
      
      if(errorCode == 4060) // ERR_WEBREQUEST_INVALID_ADDRESS
      {
         Print("⚠️  URL not in allowed list!");
         Print("   Tools -> Options -> Expert Advisors -> 'Allow WebRequest for listed URL'");
         Print("   Add: https://uncloven-megadont-elisa.ngrok-free.dev");
      }
      else if(errorCode == 5203) // ERR_WEBREQUEST_CONNECT_FAILED
      {
         Print("⚠️  Connection failed! Check:");
         Print("   1. Is API server running? (./start_all.sh)");
         Print("   2. Is ngrok running?");
         Print("   3. Is the URL correct? ", Ngrok_API_URL);
      }
      else
      {
         Print("⚠️  Error details: ", errorCode);
         Print("   Check network connection and API server status");
      }
   }
   else if(res == 1001)
   {
      Print("❌ HTTP Error 1001: Connection timeout or network error");
      Print("   URL: ", url);
      Print("   ⚠️  MOST COMMON ISSUE: URL not in allowed list!");
      Print("   Check:");
      Print("   1. Tools -> Options -> Expert Advisors -> 'Allow WebRequest for listed URL'");
      Print("   2. Add this EXACT URL: https://uncloven-megadont-elisa.ngrok-free.dev");
      Print("   3. Restart MT5 after adding URL");
      Print("   4. Is API server running? (./start_all.sh on Mac)");
      Print("   5. Is ngrok tunnel active?");
      Print("   Response: ", CharArrayToString(result));
   }
   else
   {
      Print("❌ HTTP Error: ", res);
      Print("   URL: ", url);
      Print("   Response: ", CharArrayToString(result));
   }
   
   return "";
}

//+------------------------------------------------------------------+
//| Process received signal                                          |
//+------------------------------------------------------------------+
void ProcessSignal(string signal)
{
   Print("Processing signal: ", signal);
   
   // Check daily profit target first
   if(Use_Daily_Profit_Target)
   {
      double dailyProfit = GetDailyProfit();
      if(dailyProfit >= Daily_Profit_Target_EUR)
      {
         Print("💰 Daily profit target reached! Current: ", dailyProfit, " EUR | Target: ", Daily_Profit_Target_EUR, " EUR");
         Print("⏸️  Stopping new trades for today");
         return;
      }
   }
   
   // Parse signal string - ONLY use TYPE from signal
   // IGNORE: VOLUME, SL, TP from signal (use custom settings instead)
   string action = GetValue(signal, "ACTION");
   string symbol = GetValue(signal, "SYMBOL");
   string typeStr = GetValue(signal, "TYPE");
   string ticketStr = GetValue(signal, "TICKET");
   string magicStr = GetValue(signal, "MAGIC");
   
   // Note: We IGNORE volume from signal - we use Volume_Number from settings
   
   if(action != "OPEN")
   {
      Print("Unknown action: ", action);
      return;
   }
   
   // Use custom symbol if enabled
   if(Use_Custom_Symbol)
   {
      symbol = Custom_Symbol;
      Print("📊 Using custom symbol: ", symbol, " (instead of signal's symbol)");
   }
   
   // Check if we already processed this ticket
   ulong ticket = (ulong)StringToInteger(ticketStr);
   if(IsTicketProcessed(ticket))
   {
      Print("Ticket already processed: ", ticket);
      return;
   }
   
   // Get order type from signal (BUY/SELL)
   ENUM_ORDER_TYPE orderType = (typeStr == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   // Get current market price (we use current price, not signal's price)
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double price = (orderType == ORDER_TYPE_BUY) ? ask : bid;
   
   // Use Volume_Number from settings (exact lot size you want)
   double volume = Volume_Number;
   
   // Normalize volume to symbol's step
   double minVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   // Round to nearest step instead of floor (more accurate)
   if(stepVolume > 0)
      volume = MathRound(volume / stepVolume) * stepVolume;
   
   // Clamp to min/max
   volume = MathMax(minVolume, MathMin(maxVolume, volume));
   
   // Simple SL/TP calculation in EUR
   // We ONLY use BUY/SELL from signal - we IGNORE signal's SL/TP
   // We calculate SL/TP so when price hits TP → you get exactly Take_Profit_EUR
   // When price hits SL → you lose exactly Stop_Loss_EUR
   double sl = 0, tp = 0;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopsLevel * point;
   
   string accountCurrency = AccountInfoString(ACCOUNT_CURRENCY);
   
   // Get EUR rate
   double eurRate = 1.0;
   if(accountCurrency == "USD")
   {
      eurRate = SymbolInfoDouble("EURUSD", SYMBOL_BID);
      if(eurRate == 0) eurRate = 1.0;
   }
   else if(accountCurrency == "EUR")
   {
      eurRate = 1.0;
   }
   
   // Calculate SL - find price that gives exact EUR loss
   if(Stop_Loss_EUR > 0 && volume > 0)
   {
      // Try binary search first
      double minDist = minStopDistance;
      double maxDist = 50000.0 * point;
      bool found = false;
      
      for(int i = 0; i < 500; i++)
      {
         if((maxDist - minDist) <= point) break;
         
         double testDist = (minDist + maxDist) / 2.0;
         double testSL = (orderType == ORDER_TYPE_BUY) ? price - testDist : price + testDist;
         testSL = NormalizeDouble(testSL, digits);
         
         double profit = 0;
         if(OrderCalcProfit((ENUM_ORDER_TYPE)orderType, symbol, volume, price, testSL, profit))
         {
            double lossEUR = MathAbs(profit) / eurRate;
            
            if(MathAbs(lossEUR - Stop_Loss_EUR) < 0.1)
            {
               sl = testSL;
               found = true;
               break;
            }
            else if(lossEUR > Stop_Loss_EUR)
               maxDist = testDist;
            else
               minDist = testDist;
         }
         else
         {
            minDist = testDist;
         }
      }
      
      // If binary search failed, use tick-based with refinement
      if(!found)
      {
         double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
         double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
         
         if(tickValue > 0 && tickSize > 0)
         {
            double targetLoss = Stop_Loss_EUR * eurRate;
            double profitPerTick = tickValue * volume;
            
            if(profitPerTick > 0)
            {
               double ticksNeeded = targetLoss / profitPerTick;
               double slDistance = ticksNeeded * tickSize;
               
               if(slDistance < minStopDistance && minStopDistance > 0)
                  slDistance = minStopDistance;
               
               double initialSL = (orderType == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
               initialSL = NormalizeDouble(initialSL, digits);
               
               // Refine using OrderCalcProfit
               double bestSL = initialSL;
               double bestDiff = 999999.0;
               
               for(int refine = -10; refine <= 10; refine++)
               {
                  double testSL = initialSL + (refine * tickSize);
                  testSL = NormalizeDouble(testSL, digits);
                  
                  double profit = 0;
                  if(OrderCalcProfit((ENUM_ORDER_TYPE)orderType, symbol, volume, price, testSL, profit))
                  {
                     double lossEUR = MathAbs(profit) / eurRate;
                     double diff = MathAbs(lossEUR - Stop_Loss_EUR);
                     
                     if(diff < bestDiff)
                     {
                        bestDiff = diff;
                        bestSL = testSL;
                     }
                  }
               }
               
               sl = bestSL;
            }
         }
      }
      
      if(sl > 0)
      {
         double verify = 0;
         if(OrderCalcProfit((ENUM_ORDER_TYPE)orderType, symbol, volume, price, sl, verify))
         {
            double verifyEUR = MathAbs(verify) / eurRate;
            Print("✅ SL: ", sl, " = ", verifyEUR, " EUR loss (Target: ", Stop_Loss_EUR, " EUR)");
         }
      }
   }
   
   // Calculate TP - find price that gives exact EUR profit
   if(Take_Profit_EUR > 0 && volume > 0)
   {
      // Try binary search first
      double minDist = minStopDistance;
      double maxDist = 50000.0 * point;
      bool found = false;
      
      for(int i = 0; i < 500; i++)
      {
         if((maxDist - minDist) <= point) break;
         
         double testDist = (minDist + maxDist) / 2.0;
         double testTP = (orderType == ORDER_TYPE_BUY) ? price + testDist : price - testDist;
         testTP = NormalizeDouble(testTP, digits);
         
         double profit = 0;
         if(OrderCalcProfit((ENUM_ORDER_TYPE)orderType, symbol, volume, price, testTP, profit))
         {
            double profitEUR = profit / eurRate;
            
            if(MathAbs(profitEUR - Take_Profit_EUR) < 0.1)
            {
               tp = testTP;
               found = true;
               break;
            }
            else if(profitEUR > Take_Profit_EUR)
               maxDist = testDist;
            else
               minDist = testDist;
         }
         else
         {
            minDist = testDist;
         }
      }
      
      // If binary search failed, use tick-based with refinement
      if(!found)
      {
         double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
         double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
         
         if(tickValue > 0 && tickSize > 0)
         {
            double targetProfit = Take_Profit_EUR * eurRate;
            double profitPerTick = tickValue * volume;
            
            if(profitPerTick > 0)
            {
               double ticksNeeded = targetProfit / profitPerTick;
               double tpDistance = ticksNeeded * tickSize;
               
               if(tpDistance < minStopDistance && minStopDistance > 0)
                  tpDistance = minStopDistance;
               
               double initialTP = (orderType == ORDER_TYPE_BUY) ? price + tpDistance : price - tpDistance;
               initialTP = NormalizeDouble(initialTP, digits);
               
               // Refine using OrderCalcProfit
               double bestTP = initialTP;
               double bestDiff = 999999.0;
               
               for(int refine = -10; refine <= 10; refine++)
               {
                  double testTP = initialTP + (refine * tickSize);
                  testTP = NormalizeDouble(testTP, digits);
                  
                  double profit = 0;
                  if(OrderCalcProfit((ENUM_ORDER_TYPE)orderType, symbol, volume, price, testTP, profit))
                  {
                     double profitEUR = profit / eurRate;
                     double diff = MathAbs(profitEUR - Take_Profit_EUR);
                     
                     if(diff < bestDiff)
                     {
                        bestDiff = diff;
                        bestTP = testTP;
                     }
                  }
               }
               
               tp = bestTP;
            }
         }
      }
      
      if(tp > 0)
      {
         double verify = 0;
         if(OrderCalcProfit((ENUM_ORDER_TYPE)orderType, symbol, volume, price, tp, verify))
         {
            double verifyEUR = verify / eurRate;
            Print("✅ TP: ", tp, " = ", verifyEUR, " EUR profit (Target: ", Take_Profit_EUR, " EUR)");
         }
      }
   }
   
   Print("📊 Trade parameters: Type=", typeStr, " | Symbol=", symbol, " | Volume=", volume, " | SL=", sl, " | TP=", tp);
   
   // Open trade
   bool result = false;
   if(orderType == ORDER_TYPE_BUY)
      result = trade.Buy(volume, symbol, price, sl, tp, Trade_Comment);
   else
      result = trade.Sell(volume, symbol, price, sl, tp, Trade_Comment);
   
   if(result)
   {
      ulong newTicket = trade.ResultOrder();
      AddProcessedTicket(ticket);
      Print("Trade opened successfully. Ticket: ", newTicket, 
            " Symbol: ", symbol, " Type: ", typeStr,
            " Volume: ", volume, " SL: ", sl, " TP: ", tp);
   }
   else
   {
      Print("Failed to open trade. Error: ", trade.ResultRetcode(), 
            " Description: ", trade.ResultRetcodeDescription());
      
      // Try different filling type if FOK failed
      if(trade.ResultRetcode() == 10004) // ORDER_FILLING_RETURNED
      {
         trade.SetTypeFilling(ORDER_FILLING_IOC);
         if(orderType == ORDER_TYPE_BUY)
            result = trade.Buy(volume, symbol, 0, sl, tp, Trade_Comment);
         else
            result = trade.Sell(volume, symbol, 0, sl, tp, Trade_Comment);
            
         if(result)
         {
            AddProcessedTicket(ticket);
            Print("Trade opened with IOC filling. Ticket: ", trade.ResultOrder());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get value from signal string                                    |
//+------------------------------------------------------------------+
string GetValue(string signal, string key)
{
   int startPos = StringFind(signal, key + "=");
   if(startPos < 0) return "";
   
   startPos += StringLen(key) + 1;
   int endPos = StringFind(signal, "|", startPos);
   if(endPos < 0) endPos = StringLen(signal);
   
   return StringSubstr(signal, startPos, endPos - startPos);
}

//+------------------------------------------------------------------+
//| Check if ticket was already processed                           |
//+------------------------------------------------------------------+
bool IsTicketProcessed(ulong ticket)
{
   for(int i = 0; i < ArraySize(processedTickets); i++)
   {
      if(processedTickets[i] == ticket)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Add ticket to processed list                                    |
//+------------------------------------------------------------------+
void AddProcessedTicket(ulong ticket)
{
   int size = ArraySize(processedTickets);
   ArrayResize(processedTickets, size + 1);
   processedTickets[size] = ticket;
}

//+------------------------------------------------------------------+
//| Manage open trades (Trailing Stop, Break Even)                   |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionSelectByTicket(ticket))
      {
         // Check if this position belongs to this EA
         if(PositionGetInteger(POSITION_MAGIC) != Magic_Number)
            continue;
         
         string symbol = PositionGetString(POSITION_SYMBOL);
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);
         double volume = PositionGetDouble(POSITION_VOLUME);
         
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
         double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
         int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
         long stopsLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
         double minStopDistance = stopsLevel * point;
         
         // Get tick info for EUR calculations
         double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
         double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
         string accountCurrency = AccountInfoString(ACCOUNT_CURRENCY);
         
         double currentPrice = (posType == POSITION_TYPE_BUY) ? bid : ask;
         
         // Calculate profit in points
         double profit = PositionGetDouble(POSITION_PROFIT);
         double profitInPoints = 0;
         if(profit != 0)
         {
            // Calculate profit in points: (current price - open price) / point
            if(posType == POSITION_TYPE_BUY)
               profitInPoints = (currentPrice - openPrice) / point;
            else
               profitInPoints = (openPrice - currentPrice) / point;
         }
         
         bool needModify = false;
         double newSL = currentSL;
         
         // SMART MODE Logic (percentage-based)
         if(Use_Smart_Mode)
         {
            // Calculate total distance D
            double distance = 0;
            
            if(currentTP > 0)
            {
               // If TP exists: D = |TP - Entry|
               distance = MathAbs(currentTP - openPrice);
            }
            else
            {
               // If no TP: Use SL distance * 2 as target distance, or default 100 points
               if(currentSL > 0)
               {
                  // Use SL distance * 2 as target (assume TP would be at double distance from SL)
                  double slDistance = MathAbs(currentSL - openPrice);
                  distance = slDistance * 2.0;
               }
               else
               {
                  // If no SL either, use a default distance (100 points)
                  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
                  distance = 100.0 * point;
               }
            }
            
            if(distance > 0)
            {
               // Calculate current progress: how far we are from entry
               // For BUY: progress = (currentPrice - openPrice) / distance
               // For SELL: progress = (openPrice - currentPrice) / distance
               double progress = 0;
               if(posType == POSITION_TYPE_BUY)
                  progress = (currentPrice - openPrice) / distance; // 0 = entry, 1 = target
               else
                  progress = (openPrice - currentPrice) / distance; // 0 = entry, 1 = target
               
               // Break Even: Trigger at 20% of distance, lock profit at 5%
               if(progress >= 0.20)
               {
                  // Lock profit at 5% of distance
                  double lockedProfitDistance = 0.05 * distance;
                  double breakEvenSL = 0;
                  
                  if(posType == POSITION_TYPE_BUY)
                     breakEvenSL = NormalizeDouble(openPrice + lockedProfitDistance, digits);
                  else
                     breakEvenSL = NormalizeDouble(openPrice - lockedProfitDistance, digits);
                  
                  // Only move SL if it's better than current AND (TP exists OR currentSL is 0)
                  // If no TP and SL exists, don't move SL (keep original SL)
                  bool shouldMoveSL = false;
                  
                  if(currentTP > 0)
                  {
                     // TP exists: always move SL if better
                     shouldMoveSL = true;
                  }
                  else if(currentSL == 0)
                  {
                     // No TP and no SL: move SL to break even
                     shouldMoveSL = true;
                  }
                  else
                  {
                     // No TP but SL exists: don't move SL (keep original SL)
                     shouldMoveSL = false;
                     Print("🧠 SMART MODE: Break Even triggered at 20% progress, but keeping original SL (no TP)");
                  }
                  
                  if(shouldMoveSL)
                  {
                     if(posType == POSITION_TYPE_BUY)
                     {
                        if(currentSL == 0 || breakEvenSL > currentSL)
                        {
                           newSL = breakEvenSL;
                           needModify = true;
                           Print("🧠 SMART MODE: Break Even triggered at 20% progress | Locked profit at 5% (", breakEvenSL, ")");
                        }
                     }
                     else // SELL
                     {
                        if(currentSL == 0 || breakEvenSL < currentSL)
                        {
                           newSL = breakEvenSL;
                           needModify = true;
                           Print("🧠 SMART MODE: Break Even triggered at 20% progress | Locked profit at 5% (", breakEvenSL, ")");
                        }
                     }
                  }
                  
                  // Trailing Stop: After break even, trail at 15% distance from current price
                  // Works the same way whether TP exists or not
                  if(progress > 0.20)
                  {
                     double trailingDistance = 0.15 * distance;
                     double trailingSL = 0;
                     
                     if(posType == POSITION_TYPE_BUY)
                     {
                        trailingSL = NormalizeDouble(currentPrice - trailingDistance, digits);
                        // Ensure trailing SL is at least at break even level
                        if(trailingSL < breakEvenSL)
                           trailingSL = breakEvenSL;
                        
                        // Only move SL up, never down (trailingSL must be better than currentSL)
                        // If no TP and original SL exists, only move if trailingSL is better than original SL
                        if(currentTP > 0)
                        {
                           // TP exists: move SL normally
                           if(currentSL == 0 || trailingSL > currentSL)
                           {
                              newSL = trailingSL;
                              needModify = true;
                              Print("🧠 SMART MODE: Trailing Stop at 15% distance (", trailingSL, ") | Progress: ", (progress * 100), "%");
                           }
                        }
                        else
                        {
                           // No TP: move SL if trailingSL is better than current SL (even if original SL exists)
                           if(currentSL == 0 || trailingSL > currentSL)
                           {
                              newSL = trailingSL;
                              needModify = true;
                              Print("🧠 SMART MODE: Trailing Stop at 15% distance (", trailingSL, ") | Progress: ", (progress * 100), "% | No TP");
                           }
                        }
                     }
                     else // SELL
                     {
                        trailingSL = NormalizeDouble(currentPrice + trailingDistance, digits);
                        // Ensure trailing SL is at least at break even level
                        if(trailingSL > breakEvenSL)
                           trailingSL = breakEvenSL;
                        
                        // Only move SL down, never up (trailingSL must be better than currentSL)
                        // If no TP and original SL exists, only move if trailingSL is better than original SL
                        if(currentTP > 0)
                        {
                           // TP exists: move SL normally
                           if(currentSL == 0 || trailingSL < currentSL)
                           {
                              newSL = trailingSL;
                              needModify = true;
                              Print("🧠 SMART MODE: Trailing Stop at 15% distance (", trailingSL, ") | Progress: ", (progress * 100), "%");
                           }
                        }
                        else
                        {
                           // No TP: move SL if trailingSL is better than current SL (even if original SL exists)
                           if(currentSL == 0 || trailingSL < currentSL)
                           {
                              newSL = trailingSL;
                              needModify = true;
                              Print("🧠 SMART MODE: Trailing Stop at 15% distance (", trailingSL, ") | Progress: ", (progress * 100), "% | No TP");
                           }
                        }
                     }
                  }
               }
            }
         }
         
         
         // Modify position if needed
         if(needModify)
         {
            // Final validation before modify: ensure SL is valid
            double finalSlDistance = MathAbs(currentPrice - newSL);
            if(finalSlDistance < minStopDistance && minStopDistance > 0)
            {
               Print("❌ Cannot modify: SL distance (", finalSlDistance, ") is less than minimum (", minStopDistance, "). Skipping.");
            }
            else if(currentTP > 0)
            {
               // Check SL-TP distance
               double slTpDist = MathAbs(newSL - currentTP);
               if(slTpDist < minStopDistance && minStopDistance > 0)
               {
                  Print("❌ Cannot modify: SL-TP distance (", slTpDist, ") is less than minimum (", minStopDistance, "). Skipping.");
               }
               else
               {
                  if(trade.PositionModify(ticket, newSL, currentTP))
                  {
                     Print("✅ Position modified. Ticket: ", ticket, " | New SL: ", newSL, " | Distance from price: ", finalSlDistance);
                  }
                  else
                  {
                     Print("❌ Failed to modify position. Ticket: ", ticket, " | Error: ", trade.ResultRetcodeDescription());
                     Print("   Attempted SL: ", newSL, " | Current Price: ", currentPrice, " | Distance: ", finalSlDistance);
                     Print("   Current TP: ", currentTP, " | SL-TP Distance: ", slTpDist);
                  }
               }
            }
            else
            {
               // No TP, just check SL distance
               if(trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("✅ Position modified. Ticket: ", ticket, " | New SL: ", newSL, " | Distance from price: ", finalSlDistance);
               }
               else
               {
                  Print("❌ Failed to modify position. Ticket: ", ticket, " | Error: ", trade.ResultRetcodeDescription());
                  Print("   Attempted SL: ", newSL, " | Current Price: ", currentPrice, " | Distance: ", finalSlDistance);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check and execute daily close time                              |
//+------------------------------------------------------------------+
void CheckDailyClose()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // Check if it's the daily close time
   if(dt.hour == Daily_Close_Hour && dt.min == Daily_Close_Minute)
   {
      // Only execute once per day
      MqlDateTime lastClose;
      TimeToStruct(lastDailyCloseTime, lastClose);
      
      if(lastDailyCloseTime == 0 || dt.day != lastClose.day)
      {
         Print("🕐 Daily close time reached (", Daily_Close_Hour, ":", StringFormat("%02d", Daily_Close_Minute), ")");
         CloseAllTrades();
         lastDailyCloseTime = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
//| Close all trades when daily profit target is reached            |
//+------------------------------------------------------------------+
void CloseAllTradesForTarget()
{
   int closedCount = 0;
   int failedCount = 0;
   
   // Get all positions first
   ulong tickets[];
   int totalPositions = PositionsTotal();
   ArrayResize(tickets, 0);
   
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == Magic_Number)
         {
            int size = ArraySize(tickets);
            ArrayResize(tickets, size + 1);
            tickets[size] = ticket;
         }
      }
   }
   
   Print("🎯 Attempting to close ", ArraySize(tickets), " trades...");
   
   // Close all positions
   for(int i = 0; i < ArraySize(tickets); i++)
   {
      ulong ticket = tickets[i];
      
      if(PositionSelectByTicket(ticket))
      {
         string symbol = PositionGetString(POSITION_SYMBOL);
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double profit = PositionGetDouble(POSITION_PROFIT);
         double volume = PositionGetDouble(POSITION_VOLUME);
         
         Print("   Closing ticket ", ticket, " | Symbol: ", symbol, " | Type: ", EnumToString(posType), " | Volume: ", volume, " | Profit: ", profit);
         
         // Try to close with retry
         bool closed = false;
         for(int attempt = 1; attempt <= 3; attempt++)
         {
            if(trade.PositionClose(ticket))
            {
               closed = true;
               closedCount++;
               Print("✅ Target reached - Closed ticket ", ticket, " | Symbol: ", symbol, " | Type: ", EnumToString(posType), " | Profit: ", profit);
               break;
            }
            else
            {
               Print("   Attempt ", attempt, " failed: ", trade.ResultRetcodeDescription());
               if(attempt < 3)
                  Sleep(100); // Wait 100ms before retry
            }
         }
         
         if(!closed)
         {
            failedCount++;
            Print("❌ Failed to close ticket ", ticket, " after 3 attempts");
         }
      }
   }
   
   if(closedCount > 0)
   {
      Print("🎯 Daily Profit Target: Successfully closed ", closedCount, " trades");
   }
   
   if(failedCount > 0)
   {
      Print("⚠️  Warning: Failed to close ", failedCount, " trades");
   }
}

//+------------------------------------------------------------------+
//| Close all trades (for daily close)                              |
//+------------------------------------------------------------------+
void CloseAllTrades()
{
   int closedCount = 0;
   int skippedCount = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionSelectByTicket(ticket))
      {
         // Check if this position belongs to this EA
         if(PositionGetInteger(POSITION_MAGIC) != Magic_Number)
            continue;
         
         // If Close_Only_Profit is enabled, check if trade is profitable
         if(Close_Only_Profit)
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            if(profit <= 0)
            {
               skippedCount++;
               continue;
            }
         }
         
         string symbol = PositionGetString(POSITION_SYMBOL);
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         
         if(trade.PositionClose(ticket))
         {
            closedCount++;
            Print("✅ Daily close: Closed ticket ", ticket, " | Symbol: ", symbol, " | Type: ", EnumToString(posType));
         }
         else
         {
            Print("❌ Failed to close ticket ", ticket, " | Error: ", trade.ResultRetcodeDescription());
         }
      }
   }
   
   if(closedCount > 0 || skippedCount > 0)
   {
      Print("📊 Daily close summary: Closed ", closedCount, " trades");
      if(Close_Only_Profit && skippedCount > 0)
         Print("   Skipped ", skippedCount, " unprofitable trades");
   }
}

//+------------------------------------------------------------------+
//| Get daily profit in account currency (EUR)                     |
//+------------------------------------------------------------------+
double GetDailyProfit()
{
   // Reset daily profit counter at midnight
   MqlDateTime dt, lastReset;
   TimeToStruct(TimeCurrent(), dt);
   
   if(lastDailyReset == 0)
   {
      TimeToStruct(TimeCurrent(), lastReset);
      lastReset.hour = 0;
      lastReset.min = 0;
      lastReset.sec = 0;
      lastDailyReset = StructToTime(lastReset);
   }
   else
   {
      TimeToStruct(lastDailyReset, lastReset);
   }
   
   // Reset at midnight
   if(dt.day != lastReset.day)
   {
      lastDailyReset = StructToTime(dt);
      lastDailyReset = lastDailyReset - (lastDailyReset % 86400); // Set to midnight
      dailyTargetReached = false; // Reset daily target flag for new day
      Print("📅 New day - Resetting daily profit counter");
   }
   
   double dailyProfit = 0.0;
   datetime todayStart = lastDailyReset;
   datetime todayEnd = todayStart + 86400; // 24 hours
   
   // Get account currency
   string accountCurrency = AccountInfoString(ACCOUNT_CURRENCY);
   
   // Calculate profit from closed deals today
   int closedTradesCount = 0; // Count closed trades for commission calculation
   if(HistorySelect(todayStart, todayEnd))
   {
      int totalDeals = HistoryDealsTotal();
      ulong processedPositions[]; // Track processed positions to count trades, not deals
      ArrayResize(processedPositions, 0);
      
      for(int i = 0; i < totalDeals; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket > 0)
         {
            // Check if this deal belongs to this EA
            if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == Magic_Number)
            {
               double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
               double swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
               double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
               
               // Add to daily profit (profit + swap - commission)
               dailyProfit += (profit + swap - commission);
               
               // Count unique positions (trades) for commission calculation
               ulong positionId = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
               if(positionId > 0)
               {
                  bool found = false;
                  for(int j = 0; j < ArraySize(processedPositions); j++)
                  {
                     if(processedPositions[j] == positionId)
                     {
                        found = true;
                        break;
                     }
                  }
                  if(!found)
                  {
                     int size = ArraySize(processedPositions);
                     ArrayResize(processedPositions, size + 1);
                     processedPositions[size] = positionId;
                     closedTradesCount++;
                  }
               }
            }
         }
      }
   }
   
   // Subtract commission for closed trades
   if(Commission_Per_Trade_EUR > 0 && closedTradesCount > 0)
   {
      dailyProfit -= (Commission_Per_Trade_EUR * closedTradesCount);
   }
   
   // Add profit from open positions opened today
   int openTradesCount = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == Magic_Number)
         {
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            if(openTime >= todayStart)
            {
               double profit = PositionGetDouble(POSITION_PROFIT);
               double swap = PositionGetDouble(POSITION_SWAP);
               dailyProfit += (profit + swap);
               openTradesCount++;
            }
         }
      }
   }
   
   // Subtract commission for open trades
   if(Commission_Per_Trade_EUR > 0 && openTradesCount > 0)
   {
      dailyProfit -= (Commission_Per_Trade_EUR * openTradesCount);
   }
   
   // Convert to EUR if account currency is different
   if(accountCurrency != "EUR")
   {
      // Get EUR rate (simplified - you might need to adjust based on your broker)
      double eurRate = 1.0;
      if(accountCurrency == "USD")
      {
         // Get EURUSD rate (simplified)
         eurRate = SymbolInfoDouble("EURUSD", SYMBOL_BID);
         if(eurRate == 0) eurRate = 1.0; // Fallback
      }
      // Add more currency conversions if needed
      
      dailyProfit = dailyProfit / eurRate;
   }
   
   return dailyProfit;
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   CheckForNewSignals();
   
   // Also manage trades on timer (SMART MODE)
   if(Use_Smart_Mode)
      ManageOpenTrades();
   
   if(Use_Daily_Close)
      CheckDailyClose();
   
   // Check daily profit target on timer too (more frequent check)
   if(Use_Daily_Profit_Target)
   {
      double dailyProfit = GetDailyProfit();
      if(dailyProfit >= Daily_Profit_Target_EUR)
      {
         if(!dailyTargetReached)
         {
            Print("💰💰💰 DAILY PROFIT TARGET REACHED (Timer)! 💰💰💰");
            Print("   Current Profit: ", dailyProfit, " EUR");
            Print("   Target: ", Daily_Profit_Target_EUR, " EUR");
            Print("   🚪 Closing ALL trades immediately...");
            
            CloseAllTradesForTarget();
            dailyTargetReached = true;
         }
         else
         {
            // Check if trades still open and retry
            int openTrades = 0;
            for(int i = 0; i < PositionsTotal(); i++)
            {
               ulong ticket = PositionGetTicket(i);
               if(ticket > 0 && PositionSelectByTicket(ticket))
               {
                  if(PositionGetInteger(POSITION_MAGIC) == Magic_Number)
                     openTrades++;
               }
            }
            
            if(openTrades > 0)
            {
               Print("⚠️  Target reached but ", openTrades, " trades still open. Retrying to close...");
               CloseAllTradesForTarget();
            }
         }
      }
   }
   
   // Update progress bar on timer too
   UpdateProgressBar();
}

//+------------------------------------------------------------------+
//| Create progress bar panel on chart                               |
//+------------------------------------------------------------------+
void CreateProgressBar()
{
   string prefix = "SR_Progress_";
   
   // Panel background
   ObjectCreate(0, prefix + "Panel", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "Panel", OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, prefix + "Panel", OBJPROP_YDISTANCE, 30);
   ObjectSetInteger(0, prefix + "Panel", OBJPROP_XSIZE, 300);
   ObjectSetInteger(0, prefix + "Panel", OBJPROP_YSIZE, 100);
   ObjectSetInteger(0, prefix + "Panel", OBJPROP_BGCOLOR, clrDarkSlateGray);
   ObjectSetInteger(0, prefix + "Panel", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, prefix + "Panel", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "Panel", OBJPROP_BACK, false);
   ObjectSetInteger(0, prefix + "Panel", OBJPROP_SELECTABLE, false);
   
   // Title
   ObjectCreate(0, prefix + "Title", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "Title", OBJPROP_XDISTANCE, 30);
   ObjectSetInteger(0, prefix + "Title", OBJPROP_YDISTANCE, 40);
   ObjectSetString(0, prefix + "Title", OBJPROP_TEXT, "Daily Profit Progress");
   ObjectSetInteger(0, prefix + "Title", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, prefix + "Title", OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, prefix + "Title", OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, prefix + "Title", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   
   // Goal label
   ObjectCreate(0, prefix + "GoalLabel", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "GoalLabel", OBJPROP_XDISTANCE, 30);
   ObjectSetInteger(0, prefix + "GoalLabel", OBJPROP_YDISTANCE, 60);
   ObjectSetString(0, prefix + "GoalLabel", OBJPROP_TEXT, "Goal: 1000 EUR");
   ObjectSetInteger(0, prefix + "GoalLabel", OBJPROP_COLOR, clrLightGray);
   ObjectSetInteger(0, prefix + "GoalLabel", OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, prefix + "GoalLabel", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   
   // Progress bar background
   ObjectCreate(0, prefix + "BarBG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "BarBG", OBJPROP_XDISTANCE, 30);
   ObjectSetInteger(0, prefix + "BarBG", OBJPROP_YDISTANCE, 80);
   ObjectSetInteger(0, prefix + "BarBG", OBJPROP_XSIZE, 240);
   ObjectSetInteger(0, prefix + "BarBG", OBJPROP_YSIZE, 20);
   ObjectSetInteger(0, prefix + "BarBG", OBJPROP_BGCOLOR, clrDarkGray);
   ObjectSetInteger(0, prefix + "BarBG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, prefix + "BarBG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "BarBG", OBJPROP_BACK, false);
   
   // Progress bar fill
   ObjectCreate(0, prefix + "BarFill", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "BarFill", OBJPROP_XDISTANCE, 30);
   ObjectSetInteger(0, prefix + "BarFill", OBJPROP_YDISTANCE, 80);
   ObjectSetInteger(0, prefix + "BarFill", OBJPROP_XSIZE, 0);
   ObjectSetInteger(0, prefix + "BarFill", OBJPROP_YSIZE, 20);
   ObjectSetInteger(0, prefix + "BarFill", OBJPROP_BGCOLOR, clrLimeGreen);
   ObjectSetInteger(0, prefix + "BarFill", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, prefix + "BarFill", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "BarFill", OBJPROP_BACK, false);
   
   // Current profit text
   ObjectCreate(0, prefix + "Current", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "Current", OBJPROP_XDISTANCE, 30);
   ObjectSetInteger(0, prefix + "Current", OBJPROP_YDISTANCE, 105);
   ObjectSetInteger(0, prefix + "Current", OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, prefix + "Current", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Remove progress bar panel                                        |
//+------------------------------------------------------------------+
void RemoveProgressBar()
{
   string prefix = "SR_Progress_";
   ObjectDelete(0, prefix + "Panel");
   ObjectDelete(0, prefix + "Title");
   ObjectDelete(0, prefix + "GoalLabel");
   ObjectDelete(0, prefix + "BarBG");
   ObjectDelete(0, prefix + "BarFill");
   ObjectDelete(0, prefix + "Current");
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update progress bar with current stats                            |
//+------------------------------------------------------------------+
void UpdateProgressBar()
{
   string prefix = "SR_Progress_";
   
   // Get daily profit
   double dailyProfit = GetDailyProfit();
   
   // Get goal
   double goal = Daily_Profit_Target_EUR;
   
   // Update goal label
   string goalText = "Goal: " + DoubleToString(goal, 0) + " EUR";
   ObjectSetString(0, prefix + "GoalLabel", OBJPROP_TEXT, goalText);
   
   // Calculate progress percentage (0-100%)
   double progressPercent = 0.0;
   if(goal > 0)
   {
      progressPercent = (dailyProfit / goal) * 100.0;
      if(progressPercent > 100.0) progressPercent = 100.0;
      if(progressPercent < 0.0) progressPercent = 0.0;
   }
   
   // Update progress bar width (240 is max width)
   int barWidth = (int)(240 * progressPercent / 100.0);
   ObjectSetInteger(0, prefix + "BarFill", OBJPROP_XSIZE, barWidth);
   
   // Change color based on progress
   color barColor = clrLimeGreen; // Green for positive
   if(dailyProfit < 0)
      barColor = clrRed; // Red for negative
   else if(progressPercent >= 100.0)
      barColor = clrGold; // Gold when goal reached
   
   ObjectSetInteger(0, prefix + "BarFill", OBJPROP_BGCOLOR, barColor);
   
   // Update current profit text
   double remaining = goal - dailyProfit;
   string currentText = "";
   if(dailyProfit >= goal)
   {
      currentText = "✅ GOAL REACHED! Current: " + DoubleToString(dailyProfit, 2) + " EUR";
   }
   else if(remaining > 0)
   {
      currentText = "Current: " + DoubleToString(dailyProfit, 2) + " EUR | Remaining: " + DoubleToString(remaining, 2) + " EUR";
   }
   else
   {
      currentText = "Current: " + DoubleToString(dailyProfit, 2) + " EUR | Need: " + DoubleToString(-remaining, 2) + " EUR more";
   }
   
   color textColor = (dailyProfit >= 0) ? clrLimeGreen : clrRed;
   if(progressPercent >= 100.0)
      textColor = clrGold;
   
   ObjectSetString(0, prefix + "Current", OBJPROP_TEXT, currentText);
   ObjectSetInteger(0, prefix + "Current", OBJPROP_COLOR, textColor);
   
   ChartRedraw();
}

