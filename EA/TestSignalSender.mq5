//+------------------------------------------------------------------+
//|                                          TestSignalSender.mq5    |
//|                        Test EA - Sends random signals every 1min|
//+------------------------------------------------------------------+
#property copyright "Test Trade Opener"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input string   EA_Magic_Number = "99999";        // Magic number for this test EA
input int      Trade_Interval_Seconds = 60;     // Open trade every X seconds (60 = 1 minute)
input double   Volume = 0.01;                   // Volume for test trades
input double   SL_Pips = 200;                   // Stop Loss in pips
input double   TP_Pips = 200;                   // Take Profit in pips

//--- Global variables
CTrade trade;
datetime lastTradeTime = 0;
int tradeCounter = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber((long)StringToInteger(EA_Magic_Number));
   
   // Get symbol and timeframe from chart automatically
   string chartSymbol = _Symbol;
   ENUM_TIMEFRAMES chartTimeframe = _Period;
   
   string sep = "============================================================";
   Print(sep);
   Print("Test Trade Opener initialized");
   Print("Will open random trades every ", Trade_Interval_Seconds, " seconds");
   Print("Magic Number: ", EA_Magic_Number);
   Print("Symbol: ", chartSymbol, " (from chart)");
   Print("Timeframe: ", EnumToString(chartTimeframe), " (from chart)");
   Print("NOTE: This EA ONLY opens trades - it does NOT send signals!");
   Print(sep);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("Test Trade Opener deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check if it's time to open a trade
   if(TimeCurrent() - lastTradeTime >= Trade_Interval_Seconds)
   {
      OpenRandomTrade();
      lastTradeTime = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Open random trade                                                |
//+------------------------------------------------------------------+
void OpenRandomTrade()
{
   tradeCounter++;
   
   // Get symbol from chart automatically
   string symbol = _Symbol;
   
   // Random BUY or SELL
   ENUM_ORDER_TYPE orderType = (MathRand() % 2 == 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   string typeStr = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   
   // Get current price
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double price = (orderType == ORDER_TYPE_BUY) ? ask : bid;
   
   // Calculate SL and TP with proper validation
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   // Get minimum stop level (in points)
   long stopLevel = (long)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopLevel * point;
   
   // Calculate SL and TP distances
   double slDistance = SL_Pips * point * 10;  // Convert pips to price
   double tpDistance = TP_Pips * point * 10;
   
   // Ensure minimum distance
   if(slDistance < minStopDistance)
      slDistance = minStopDistance;
   if(tpDistance < minStopDistance)
      tpDistance = minStopDistance;
   
   double sl = 0, tp = 0;
   if(orderType == ORDER_TYPE_BUY)
   {
      sl = NormalizeDouble(price - slDistance, digits);
      tp = NormalizeDouble(price + tpDistance, digits);
   }
   else
   {
      sl = NormalizeDouble(price + slDistance, digits);
      tp = NormalizeDouble(price - tpDistance, digits);
   }
   
   // Validate stops are not too close (ask and bid already defined above)
   if(orderType == ORDER_TYPE_BUY)
   {
      if(sl >= ask - minStopDistance)
         sl = NormalizeDouble(ask - minStopDistance - point, digits);
      if(tp <= ask + minStopDistance)
         tp = NormalizeDouble(ask + minStopDistance + point, digits);
   }
   else
   {
      if(sl <= bid + minStopDistance)
         sl = NormalizeDouble(bid + minStopDistance + point, digits);
      if(tp >= bid - minStopDistance)
         tp = NormalizeDouble(bid - minStopDistance - point, digits);
   }
   
   // Open trade
   bool result = false;
   if(orderType == ORDER_TYPE_BUY)
      result = trade.Buy(Volume, symbol, 0, sl, tp, "Test Trade");
   else
      result = trade.Sell(Volume, symbol, 0, sl, tp, "Test Trade");
   
   string separator = "============================================================";
   Print(separator);
   
   if(result)
   {
      ulong ticket = trade.ResultOrder();
      Print("[TEST TRADE #", tradeCounter, "] OPENED: ", typeStr, " ", symbol, 
            " @ ", DoubleToString(price, 5), " SL: ", DoubleToString(sl, 5), " TP: ", DoubleToString(tp, 5));
      Print("Ticket: ", ticket);
      Print("Timeframe: ", EnumToString(_Period));
   }
   else
   {
      Print("[TEST TRADE #", tradeCounter, "] FAILED: ", typeStr, " ", symbol);
      Print("Error: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
   
   Print(separator);
   
   // NOTE: This EA ONLY opens trades, it does NOT send signals
}


//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Open trade on timer as well
   if(TimeCurrent() - lastTradeTime >= Trade_Interval_Seconds)
   {
      OpenRandomTrade();
      lastTradeTime = TimeCurrent();
   }
}

