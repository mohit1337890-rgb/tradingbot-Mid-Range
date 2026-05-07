//+------------------------------------------------------------------+
//|                                         Fibo Newton.mq5          |
//|                                      Fixed Risk/Reward Ratio     |
//+------------------------------------------------------------------+
#property copyright "OptiTrade Pro"
#property version   "2.00"
#property strict

// --- INPUTS ---
input int      InpBreakPeriod = 30;           // Breakout Period
input int      InpFiboLookback = 14;          // Fibo Lookback
input double   InpNewtonSens = 0.9;           // Newton Sensitivity (REDUCED for gold)
input int      InpNewtonPeriod = 5;           // Newton Period
input bool     InpUseMidTrend = true;        // Use Mid-Term Trend Filter (DISABLED by default)

// --- TP/SL SETTINGS (FIXED RISK/REWARD) ---
input double   InpTp1Perc = 1.2;              // TP1 % (SAME as SL for breakeven)
input double   InpTp2Perc = 2.0;              // TP2 % (Better reward)
input double   InpTp3Perc = 3.0;              // TP3 % (Good reward)
input double   InpSlPerc = 1.0;               // Stop Loss % (REDUCED to 1%)

// --- TRAILING STOP SETTINGS ---
input bool     InpUseTrailing = true;         // Use Dynamic Trailing Stop
input double   InpTrailingStart = 0.5;        // Trail Start (% profit) - EARLIER
input double   InpTrailingStep = 0.2;         // Trail Step (%)
input bool     InpUseATRTrailing = true;      // Use ATR for Trailing
input int      InpATRPeriod = 14;             // ATR Period
input double   InpATRMultiplier = 1.2;        // ATR Multiplier for trailing (REDUCED)

// --- POSITION SIZING ---
input double   InpLotSize = 0.01;             // Fixed Lot Size
input bool     InpUseRiskPercent = true;      // Use Risk % Based Sizing
input double   InpRiskPercent = 1.0;          // Risk % per Trade (REDUCED)

// --- GOLD SPECIFIC SETTINGS ---
input double   InpMaxSpread = 30;             // Max Spread in points (REDUCED)
input bool     InpUseSessionFilter = true;    // Use Trading Session Filter (ENABLED)
input int      InpStartHour = 8;              // Start Hour (London open)
input int      InpEndHour = 17;               // End Hour (NY close)

// --- SIGNAL FILTERS ---
input bool     InpUseADXFilter = true;        // Use ADX for trend strength
input double   InpADXThreshold = 20;          // ADX threshold (below 20 = ranging)

// --- MAGIC NUMBER ---
input int      InpMagicNumber = 20250324;     // EA Magic Number

// Global Variables
int    g_magicNumber;
double g_tp1, g_tp2, g_tp3, g_sl;
double g_entryPrice;
datetime g_entryTime;
double g_point;
int g_digits;
bool g_partialTP1Executed = true;
bool g_partialTP2Executed = true;

// Indicator Handles
int g_ma21_handle;
int g_ma50_handle;
int g_ma200_handle;
int g_atr_handle;
int g_adx_handle;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_magicNumber = InpMagicNumber;
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Initialize indicator handles
   g_ma21_handle = iMA(_Symbol, _Period, 21, 0, (ENUM_MA_METHOD)MODE_EMA, PRICE_CLOSE);
   g_ma50_handle = iMA(_Symbol, _Period, 50, 0, (ENUM_MA_METHOD)MODE_EMA, PRICE_CLOSE);
   g_ma200_handle = iMA(_Symbol, _Period, 200, 0, (ENUM_MA_METHOD)MODE_EMA, PRICE_CLOSE);
   g_atr_handle = iATR(_Symbol, _Period, 14);
   g_adx_handle = iADX(_Symbol, _Period, 14);
   
   if(g_ma21_handle == INVALID_HANDLE || g_ma50_handle == INVALID_HANDLE || 
      g_ma200_handle == INVALID_HANDLE || g_atr_handle == INVALID_HANDLE ||
      g_adx_handle == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles. Error: ", GetLastError());
      return INIT_FAILED;
   }
   
   Print("=== OptiTrade Pro EA for GOLD FIXED VERSION ===");
   Print("Risk/Reward Ratio: ", InpSlPerc, "% SL vs ", InpTp1Perc, "% TP1 (", DoubleToString(InpTp1Perc/InpSlPerc, 2), ":1)");
   Print("Newton Sensitivity: ", InpNewtonSens);
   Print("Use ADX Filter: ", InpUseADXFilter ? "ON (Min " + DoubleToString(InpADXThreshold, 0) + ")" : "OFF");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_ma21_handle != INVALID_HANDLE) IndicatorRelease(g_ma21_handle);
   if(g_ma50_handle != INVALID_HANDLE) IndicatorRelease(g_ma50_handle);
   if(g_ma200_handle != INVALID_HANDLE) IndicatorRelease(g_ma200_handle);
   if(g_atr_handle != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   if(g_adx_handle != INVALID_HANDLE) IndicatorRelease(g_adx_handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!CheckSpread()) return;
   if(InpUseSessionFilter && !IsTradingSession()) return;
   
   bool hasPosition = PositionExists();
   
   if(hasPosition)
   {
      ManagePartialTP();
      if(InpUseTrailing) UpdateTrailingStop();
   }
   else
   {
      CheckForSignals();
      g_partialTP1Executed = false;
      g_partialTP2Executed = false;
   }
}

//+------------------------------------------------------------------+
//| Check Spread                                                     |
//+------------------------------------------------------------------+
bool CheckSpread()
{
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - 
                    SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
   
   if(spread > InpMaxSpread) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Check Trading Session                                            |
//+------------------------------------------------------------------+
bool IsTradingSession()
{
   datetime now = TimeCurrent();
   MqlDateTime timeStruct;
   TimeToStruct(now, timeStruct);
   int currentHour = timeStruct.hour;
   return (currentHour >= InpStartHour && currentHour < InpEndHour);
}

//+------------------------------------------------------------------+
//| Get ATR Value                                                    |
//+------------------------------------------------------------------+
double GetATRValue(int period)
{
   double atr[1];
   if(CopyBuffer(g_atr_handle, 0, 0, 1, atr) > 0)
      return atr[0];
   return 0;
}

//+------------------------------------------------------------------+
//| Get ADX Value                                                    |
//+------------------------------------------------------------------+
double GetADXValue()
{
   double adx[1];
   if(CopyBuffer(g_adx_handle, 0, 0, 1, adx) > 0)
      return adx[0];
   return 0;
}

//+------------------------------------------------------------------+
//| Get EMA Value from handle                                        |
//+------------------------------------------------------------------+
double GetEMAValue(int handle, int shift)
{
   double ema[1];
   if(CopyBuffer(handle, 0, shift, 1, ema) > 0)
      return ema[0];
   return 0;
}

//+------------------------------------------------------------------+
//| Get Close Price                                                  |
//+------------------------------------------------------------------+
double GetClosePrice(int shift)
{
   double close[];
   ArraySetAsSeries(close, true);
   CopyClose(_Symbol, _Period, shift, 1, close);
   return close[0];
}

//+------------------------------------------------------------------+
//| Get Highest High                                                 |
//+------------------------------------------------------------------+
double GetHighestHigh(int count, int start)
{
   double high[];
   ArraySetAsSeries(high, true);
   CopyHigh(_Symbol, _Period, start, count, high);
   int maxIdx = ArrayMaximum(high, 0, count);
   return high[maxIdx];
}

//+------------------------------------------------------------------+
//| Get Lowest Low                                                   |
//+------------------------------------------------------------------+
double GetLowestLow(int count, int start)
{
   double low[];
   ArraySetAsSeries(low, true);
   CopyLow(_Symbol, _Period, start, count, low);
   int minIdx = ArrayMinimum(low, 0, count);
   return low[minIdx];
}

//+------------------------------------------------------------------+
//| Get Newton Acceleration Signal                                   |
//+------------------------------------------------------------------+
double GetNewtonSignal()
{
   double sum = 0;
   for(int i = 0; i < 3; i++)
   {
      double mom = GetClosePrice(i) - GetClosePrice(i + InpNewtonPeriod);
      double prevMom = GetClosePrice(i + InpNewtonPeriod) - GetClosePrice(i + InpNewtonPeriod * 2);
      double acc = mom - prevMom;
      double atrVal = GetATRValue(14);
      if(atrVal <= 0) atrVal = 1;
      sum += acc / atrVal;
   }
   return sum / 3;
}

//+------------------------------------------------------------------+
//| Get Previous Newton Signal                                       |
//+------------------------------------------------------------------+
double GetPrevNewtonSignal()
{
   double sum = 0;
   for(int i = 1; i < 4; i++)
   {
      double mom = GetClosePrice(i) - GetClosePrice(i + InpNewtonPeriod);
      double prevMom = GetClosePrice(i + InpNewtonPeriod) - GetClosePrice(i + InpNewtonPeriod * 2);
      double acc = mom - prevMom;
      double atrVal = GetATRValue(14);
      if(atrVal <= 0) atrVal = 1;
      sum += acc / atrVal;
   }
   return sum / 3;
}

//+------------------------------------------------------------------+
//| Get Fibonacci 50% Level                                          |
//+------------------------------------------------------------------+
double GetFibLevel50()
{
   double highest = GetHighestHigh(InpFiboLookback, 1);
   double lowest = GetLowestLow(InpFiboLookback, 1);
   return lowest + (highest - lowest) * 0.5;
}

//+------------------------------------------------------------------+
//| Check for buy/sell signals                                       |
//+------------------------------------------------------------------+
void CheckForSignals()
{
   double newtonSignal = GetNewtonSignal();
   double prevNewtonSignal = GetPrevNewtonSignal();
   double fib50 = GetFibLevel50();
   double ema21 = GetEMAValue(g_ma21_handle, 0);
   double ema50 = GetEMAValue(g_ma50_handle, 0);
   double ema200 = GetEMAValue(g_ma200_handle, 0);
   double close = GetClosePrice(0);
   double adx = GetADXValue();
   
   // ADX filter - avoid ranging markets
   if(InpUseADXFilter && adx < InpADXThreshold) return;
   
   bool midTrendBull = (close > ema50 && ema50 > ema200);
   bool midTrendBear = (close < ema50 && ema50 < ema200);
   
   bool newtonCrossoverUp = (prevNewtonSignal <= InpNewtonSens && newtonSignal > InpNewtonSens);
   bool newtonCrossoverDown = (prevNewtonSignal >= -InpNewtonSens && newtonSignal < -InpNewtonSens);
   
   bool buySignalRaw = newtonCrossoverUp && close > fib50 && close > ema21;
   bool sellSignalRaw = newtonCrossoverDown && close < fib50 && close < ema21;
   
   bool buySignal = InpUseMidTrend ? (buySignalRaw && midTrendBull) : buySignalRaw;
   bool sellSignal = InpUseMidTrend ? (sellSignalRaw && midTrendBear) : sellSignalRaw;
   
   if(buySignal) OpenPosition(ORDER_TYPE_BUY);
   else if(sellSignal) OpenPosition(ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
//| Manage Partial Take Profits                                      |
//+------------------------------------------------------------------+
void ManagePartialTP()
{
   if(!PositionSelect(_Symbol)) return;
   
   double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentLot = PositionGetDouble(POSITION_VOLUME);
   int positionType = (int)PositionGetInteger(POSITION_TYPE);
   ulong ticket = PositionGetInteger(POSITION_TICKET);
   
   double currentProfitPct = 0;
   if(positionType == POSITION_TYPE_BUY)
      currentProfitPct = (currentPrice - openPrice) / openPrice * 100;
   else
      currentProfitPct = (openPrice - currentPrice) / openPrice * 100;
   
   // Close 33% at TP1
   if(!g_partialTP1Executed && currentProfitPct >= InpTp1Perc)
   {
      double closeLot = NormalizeDouble(currentLot * 0.33, 2);
      if(closeLot > 0)
      {
         ClosePartialPosition(ticket, closeLot);
         g_partialTP1Executed = true;
         Print("TP1 hit - Closed 33% at ", DoubleToString(currentPrice, g_digits));
      }
   }
   
   // Close another 33% at TP2
   if(g_partialTP1Executed && !g_partialTP2Executed && currentProfitPct >= InpTp2Perc)
   {
      double remainingLot = PositionGetDouble(POSITION_VOLUME);
      double closeLot = NormalizeDouble(remainingLot * 0.5, 2);
      if(closeLot > 0)
      {
         ClosePartialPosition(ticket, closeLot);
         g_partialTP2Executed = true;
         Print("TP2 hit - Closed 50% of remaining at ", DoubleToString(currentPrice, g_digits));
      }
   }
}

//+------------------------------------------------------------------+
//| Close Partial Position                                           |
//+------------------------------------------------------------------+
void ClosePartialPosition(ulong ticket, double volume)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = volume;
   request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.position = ticket;
   request.price = SymbolInfoDouble(_Symbol, request.type == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
   request.deviation = 10;
   request.magic = g_magicNumber;
   
   if(!OrderSend(request, result))
   {
      Print("Partial close failed. Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Open Position                                                    |
//+------------------------------------------------------------------+
void OpenPosition(int orderType)
{
   double price = (orderType == ORDER_TYPE_BUY) ? 
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
                  SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   g_entryPrice = price;
   
   double slPrice = CalculateSL(orderType, price);
   double tp1Price = CalculateTP(orderType, price, InpTp1Perc / 100);
   double tp2Price = CalculateTP(orderType, price, InpTp2Perc / 100);
   double tp3Price = CalculateTP(orderType, price, InpTp3Perc / 100);
   
   g_tp1 = tp1Price;
   g_tp2 = tp2Price;
   g_tp3 = tp3Price;
   g_sl = slPrice;
   
   double lotSize = CalculateLotSize(orderType, slPrice);
   if(lotSize <= 0) return;
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.type = (ENUM_ORDER_TYPE)orderType;
   request.price = price;
   request.sl = slPrice;
   request.tp = tp3Price;
   request.deviation = 20;
   request.magic = g_magicNumber;
   request.comment = "OptiTrade";
   
   if(!OrderSend(request, result))
   {
      Print("Order failed. Error: ", GetLastError());
      return;
   }
   
   Print("=== POSITION OPENED ===");
   Print("Type: ", orderType == ORDER_TYPE_BUY ? "BUY" : "SELL");
   Print("Entry: ", DoubleToString(price, g_digits));
   Print("SL: ", DoubleToString(slPrice, g_digits), " (", InpSlPerc, "%)");
   Print("TP1: ", DoubleToString(tp1Price, g_digits), " (", InpTp1Perc, "%)");
   Print("TP2: ", DoubleToString(tp2Price, g_digits), " (", InpTp2Perc, "%)");
   Print("TP3: ", DoubleToString(tp3Price, g_digits), " (", InpTp3Perc, "%)");
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize(int orderType, double slPrice)
{
   if(InpUseRiskPercent)
   {
      double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmount = accountBalance * (InpRiskPercent / 100);
      double slDistance = MathAbs(g_entryPrice - slPrice);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double lotRisk = slDistance / tickSize * tickValue;
      double lotSize = riskAmount / lotRisk;
      
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      
      lotSize = MathRound(lotSize / stepLot) * stepLot;
      return MathMax(minLot, MathMin(maxLot, lotSize));
   }
   return InpLotSize;
}

//+------------------------------------------------------------------+
//| Calculate Stop Loss                                              |
//+------------------------------------------------------------------+
double CalculateSL(int orderType, double entryPrice)
{
   if(orderType == ORDER_TYPE_BUY)
      return entryPrice * (1 - InpSlPerc / 100);
   else
      return entryPrice * (1 + InpSlPerc / 100);
}

//+------------------------------------------------------------------+
//| Calculate Take Profit                                            |
//+------------------------------------------------------------------+
double CalculateTP(int orderType, double entryPrice, double percent)
{
   if(orderType == ORDER_TYPE_BUY)
      return entryPrice * (1 + percent);
   else
      return entryPrice * (1 - percent);
}

//+------------------------------------------------------------------+
//| Update Trailing Stop                                             |
//+------------------------------------------------------------------+
void UpdateTrailingStop()
{
   if(!PositionSelect(_Symbol)) return;
   
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   int positionType = (int)PositionGetInteger(POSITION_TYPE);
   double currentProfitPct = 0;
   
   if(positionType == POSITION_TYPE_BUY)
      currentProfitPct = (currentPrice - openPrice) / openPrice * 100;
   else
      currentProfitPct = (openPrice - currentPrice) / openPrice * 100;
   
   if(currentProfitPct < InpTrailingStart) return;
   
   double newSL = currentSL;
   double trailDistance;
   
   if(InpUseATRTrailing)
   {
      double atr = GetATRValue(InpATRPeriod);
      trailDistance = atr * InpATRMultiplier * (InpTrailingStep / 100);
   }
   else
   {
      trailDistance = openPrice * (InpTrailingStep / 100);
   }
   
   double minStep = g_point * 10;
   
   if(positionType == POSITION_TYPE_BUY)
   {
      double potentialSL = currentPrice - trailDistance;
      if(potentialSL > currentSL && potentialSL > openPrice + minStep)
         newSL = potentialSL;
   }
   else
   {
      double potentialSL = currentPrice + trailDistance;
      if((currentSL == 0 || potentialSL < currentSL) && potentialSL < openPrice - minStep)
         newSL = potentialSL;
   }
   
   if(newSL != currentSL && newSL > 0)
   {
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      
      request.action = TRADE_ACTION_SLTP;
      request.symbol = _Symbol;
      request.sl = newSL;
      request.position = PositionGetInteger(POSITION_TICKET);
      
      if(!OrderSend(request, result))
      {
         Print("Trailing stop update failed. Error: ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Check if position exists                                         |
//+------------------------------------------------------------------+
bool PositionExists()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == g_magicNumber)
         {
            return true;
         }
      }
   }
   return false;
}
//+------------------------------------------------------------------+
