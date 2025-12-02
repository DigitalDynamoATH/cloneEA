//+------------------------------------------------------------------+
//|                                              SignalSender.mq5    |
//|                        Signal Sender EA - Detects and Sends      |
//|                        trading signals from purchased EA         |
//+------------------------------------------------------------------+
#property copyright "Signal Sender"
#property version   "1.00"
#property strict

// Allow WebRequest for the API URL
#property description "IMPORTANT: Add the API URL to Tools -> Options -> Expert Advisors -> 'Allow WebRequest for listed URL'"

//--- Input parameters
input string   EA_Magic_Number = "99999";        // Magic number of purchased EA to monitor
input int      Check_Interval_MS = 100;         // Check interval in milliseconds
input bool     Send_Buy_Signals = true;         // Send BUY signals
input bool     Send_Sell_Signals = true;        // Send SELL signals
input string   Ngrok_API_URL = "https://uncloven-megadont-elisa.ngrok-free.dev/api/signal";  // API endpoint (auto-updated by start_all.sh)

//--- Global variables
datetime lastCheckTime = 0;
ulong processedTickets[];  // Array to track all processed tickets (prevent duplicate sends)

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize processed tickets array
   ArrayResize(processedTickets, 0);
   
   string sep = "============================================================";
   Print(sep);
   Print("Signal Sender EA initialized");
   Print("Monitoring EA with magic: ", EA_Magic_Number);
   Print("✅ Using DIRECT HTTP (no files)");
   Print("✅ Duplicate prevention: Enabled (each ticket sent only once)");
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
   Print("Signal Sender EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for new trades periodically
   if(GetTickCount() - lastCheckTime < Check_Interval_MS)
      return;
   
   lastCheckTime = GetTickCount();
   
   // Check for new positions opened by the purchased EA
   CheckForNewTrades();
}

//+------------------------------------------------------------------+
//| Check for new trades opened by monitored EA                      |
//+------------------------------------------------------------------+
void CheckForNewTrades()
{
   // Clean up processed tickets for closed positions (every 100 checks to avoid overhead)
   static int cleanupCounter = 0;
   cleanupCounter++;
   if(cleanupCounter >= 100)
   {
      CleanupProcessedTickets();
      cleanupCounter = 0;
   }
   
   // Debug: Log total positions
   int totalPositions = PositionsTotal();
   
   // Get all open positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      // Check if this position belongs to the monitored EA
      if(PositionSelectByTicket(ticket))
      {
         string posComment = PositionGetString(POSITION_COMMENT);
         long posMagic = PositionGetInteger(POSITION_MAGIC);
         string posSymbol = PositionGetString(POSITION_SYMBOL);
         
         // Check if magic number matches (convert string to long)
         long magicToCheck = (long)StringToInteger(EA_Magic_Number);
         
         // Debug logging
         if(totalPositions > 0 && i == PositionsTotal() - 1)  // Log only once per check
         {
            Print("[DEBUG] Checking positions. Total: ", totalPositions, " | Looking for magic: ", EA_Magic_Number);
         }
         
         // Also check if comment contains the magic number (some EAs use comment)
         bool isMonitoredEA = (posMagic == magicToCheck) || 
                              (StringFind(posComment, EA_Magic_Number) >= 0);
         
         if(isMonitoredEA)
         {
            // Check if this ticket has already been processed
            if(IsTicketProcessed(ticket))
            {
               // Already sent, skip it
               continue;
            }
            
            Print("[DEBUG] ✓ Found matching position! Ticket: ", ticket, " | Magic: ", posMagic, " | Symbol: ", posSymbol);
            
            // New trade detected!
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            Print("[DEBUG] ✓ New trade detected! Type: ", EnumToString(posType), " | Ticket: ", ticket);
            
            if((posType == POSITION_TYPE_BUY && Send_Buy_Signals) ||
               (posType == POSITION_TYPE_SELL && Send_Sell_Signals))
            {
               Print("[DEBUG] → Sending signal...");
               SendSignal(ticket, posType);
               // Mark ticket as processed (sent only once!)
               AddProcessedTicket(ticket);
            }
            else
            {
               Print("[DEBUG] ✗ Signal type disabled (BUY:", Send_Buy_Signals, " SELL:", Send_Sell_Signals, ")");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Send signal directly to API via HTTP                             |
//+------------------------------------------------------------------+
void SendSignal(ulong ticket, ENUM_POSITION_TYPE posType)
{
   // Get position details
   string symbol = PositionGetString(POSITION_SYMBOL);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double price = (posType == POSITION_TYPE_BUY) ? 
                  PositionGetDouble(POSITION_PRICE_OPEN) : 
                  PositionGetDouble(POSITION_PRICE_OPEN);
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   
   // Create signal string
   string signal = "";
   signal += "ACTION=OPEN|";
   signal += "SYMBOL=" + symbol + "|";
   signal += "TYPE=" + (posType == POSITION_TYPE_BUY ? "BUY" : "SELL") + "|";
   signal += "VOLUME=" + DoubleToString(volume, 2) + "|";
   signal += "PRICE=" + DoubleToString(price, 5) + "|";
   signal += "TICKET=" + IntegerToString(ticket) + "|";
   signal += "TIME=" + IntegerToString(openTime) + "|";
   signal += "MAGIC=" + EA_Magic_Number;
   
   // Send directly to API via HTTP
   SendSignalViaHTTP(signal);
}

//+------------------------------------------------------------------+
//| Send signal directly to API via HTTP (using WebRequest)       |
//+------------------------------------------------------------------+
void SendSignalViaHTTP(string signal)
{
   // Create form-encoded payload: signal=ACTION=OPEN|SYMBOL=...
   // MT5 WebRequest will handle URL encoding automatically
   // The API server will decode it properly using unquote_plus
   string formData = "signal=" + signal;
   
   // Prepare headers - Use form-encoded content type
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   headers += "ngrok-skip-browser-warning: true\r\n";
   headers += "\r\n";  // End headers with double CRLF
   
   // Convert form data to bytes
   char post[];
   char result[];
   string result_headers;
   
   StringToCharArray(formData, post, 0, StringLen(formData));
   int postSize = ArraySize(post);
   
   // Retry logic: Try up to 3 times if we get timeout errors
   int maxRetries = 3;
   int res = -1;
   
   for(int attempt = 1; attempt <= maxRetries; attempt++)
   {
      // Send POST request using WebRequest (with cookie and size parameters)
      // Increased timeout to 15 seconds for better reliability
      res = WebRequest("POST", Ngrok_API_URL, headers, "", 15000, post, postSize, result, result_headers);
      
      // If successful, break out of retry loop
      if(res == 200)
         break;
      
      // If it's a timeout (1001) and we have retries left, wait and retry
      if(res == 1001 && attempt < maxRetries)
      {
         Print("⚠️  Attempt ", attempt, " failed with timeout. Retrying in 1 second...");
         Sleep(1000);  // Wait 1 second before retry
         continue;
      }
      
      // For other errors or last attempt, break and handle error
      break;
   }
   
   if(res == 200) // HTTP 200 OK
   {
      string sep = "============================================================";
      Print(sep);
      Print("✅ SIGNAL SENT DIRECTLY TO API!");
      Print("URL: ", Ngrok_API_URL);
      Print("Signal: ", signal);
      Print("Response: ", CharArrayToString(result));
      Print(sep);
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
      Print("❌ HTTP Error 1001: Connection timeout or network error (after 3 attempts)");
      Print("   URL: ", Ngrok_API_URL);
      Print("   Signal that failed: ", signal);
      Print("   ⚠️  This is usually a temporary network issue.");
      Print("   Check:");
      Print("   1. Is API server running? (./start_all.sh on Mac)");
      Print("   2. Is ngrok tunnel active?");
      Print("   3. Network connectivity from VPS to internet");
      Print("   4. Ngrok free tier may have rate limits");
      Print("   Response: ", CharArrayToString(result));
   }
   else
   {
      Print("❌ HTTP Error: ", res);
      Print("   URL: ", Ngrok_API_URL);
      Print("   Response: ", CharArrayToString(result));
   }
}

//+------------------------------------------------------------------+
//| Check if ticket was already processed (sent)                     |
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
//| Add ticket to processed list (prevent duplicate sends)          |
//+------------------------------------------------------------------+
void AddProcessedTicket(ulong ticket)
{
   int size = ArraySize(processedTickets);
   ArrayResize(processedTickets, size + 1);
   processedTickets[size] = ticket;
}

//+------------------------------------------------------------------+
//| Clean up processed tickets that no longer exist (closed positions) |
//+------------------------------------------------------------------+
void CleanupProcessedTickets()
{
   // Keep only tickets that still exist as open positions
   ulong tempTickets[];
   int tempSize = 0;
   
   for(int i = 0; i < ArraySize(processedTickets); i++)
   {
      ulong ticket = processedTickets[i];
      // Check if this ticket still exists as an open position
      if(PositionSelectByTicket(ticket))
      {
         ArrayResize(tempTickets, tempSize + 1);
         tempTickets[tempSize] = ticket;
         tempSize++;
      }
   }
   
   // Replace old array with cleaned one
   ArrayResize(processedTickets, tempSize);
   for(int i = 0; i < tempSize; i++)
   {
      processedTickets[i] = tempTickets[i];
   }
}

//+------------------------------------------------------------------+
//| Timer function (alternative to OnTick for less frequent checks)   |
//+------------------------------------------------------------------+
void OnTimer()
{
   CheckForNewTrades();
}

