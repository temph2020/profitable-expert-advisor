//+------------------------------------------------------------------+
//|                                          DarvasBoxStrategy.mqh   |
//+------------------------------------------------------------------+
#if defined(CLUSTER0_ORCHESTRATOR) || defined(UNITED_V2_DYNAMIC_LOTS)
extern double g_DB_LotSize;
#define DARVAS_TRADE_LOT (g_DB_LotSize)
#else
#define DARVAS_TRADE_LOT 0.01
#endif

bool InitDarvasBox(string symbol)
{
   dbData.symbol = symbol;
   dbData.boxHigh = 0;
   dbData.boxLow = 0;
   dbData.boxFormed = false;
   dbData.lastBoxTime = 0;
   dbData.boxName = "DarvasBox_" + IntegerToString(DB_MagicNumber) + "_";
   
   // Check if symbol exists
   if(!SymbolSelect(symbol, true))
   {
      Print("DarvasBox: Symbol '", symbol, "' not available in Market Watch. Please add it to Market Watch or check symbol name.");
      return false;
   }
   
   Sleep(100); // Wait for symbol to be ready
   
   dbData.point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   dbData.minStopLevel = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * dbData.point;
   
   dbData.maHandle = iMA(symbol, DB_TrendTimeframe, DB_MA_Period, 0, DB_MA_Method, DB_MA_Price);
   dbData.volumeHandle = iVolumes(symbol, PERIOD_CURRENT, VOLUME_TICK);
   
   if(dbData.maHandle == INVALID_HANDLE || dbData.volumeHandle == INVALID_HANDLE)
   {
      Print("DarvasBox: Error creating indicators for '", symbol, "'");
      return false;
   }
   
   dbData.trade.SetDeviationInPoints(10);
   dbData.trade.SetTypeFilling(ORDER_FILLING_IOC);
   dbData.trade.SetAsyncMode(false);
   dbData.trade.SetExpertMagicNumber(DB_MagicNumber);
   
   ObjectsDeleteAll(0, dbData.boxName);
   dbData.isInitialized = true;
   Print("DarvasBox: Successfully initialized for symbol '", symbol, "'");
   return true;
}

void DeinitDarvasBox()
{
   if(dbData.maHandle != INVALID_HANDLE) IndicatorRelease(dbData.maHandle);
   if(dbData.volumeHandle != INVALID_HANDLE) IndicatorRelease(dbData.volumeHandle);
   ObjectsDeleteAll(0, dbData.boxName);
}

void DrawDarvasBox()
{
   if(!dbData.boxFormed) return;
   
   datetime time1 = iTime(dbData.symbol, PERIOD_H1, DB_BoxPeriod);
   datetime time2 = iTime(dbData.symbol, PERIOD_H1, 0);
   
   ObjectsDeleteAll(0, dbData.boxName);
   
   ObjectCreate(0, dbData.boxName + "Top", OBJ_TREND, 0, time1, dbData.boxHigh, time2, dbData.boxHigh);
   ObjectCreate(0, dbData.boxName + "Bottom", OBJ_TREND, 0, time1, dbData.boxLow, time2, dbData.boxLow);
   
   ObjectSetInteger(0, dbData.boxName + "Top", OBJPROP_COLOR, DB_BoxColor);
   ObjectSetInteger(0, dbData.boxName + "Bottom", OBJPROP_COLOR, DB_BoxColor);
   ObjectSetInteger(0, dbData.boxName + "Top", OBJPROP_WIDTH, DB_BoxWidth);
   ObjectSetInteger(0, dbData.boxName + "Bottom", OBJPROP_WIDTH, DB_BoxWidth);
   ObjectSetInteger(0, dbData.boxName + "Top", OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, dbData.boxName + "Bottom", OBJPROP_RAY_RIGHT, true);
}

void CalculateDarvasBox()
{
   double high = 0;
   double low = DBL_MAX;
   
   // Find highest high and lowest low in the period - EXACTLY like original
   for(int i = 0; i < DB_BoxPeriod; i++)
   {
      high = MathMax(high, iHigh(dbData.symbol, PERIOD_H1, i));
      low = MathMin(low, iLow(dbData.symbol, PERIOD_H1, i));
   }
   
   double range = high - low;
   double allowedRange = DB_BoxDeviation * dbData.point;  // Use dbData.point instead of _Point
   
   if(DB_EnableLogging)
   {
      Print("DarvasBox: Box Calculation - High: ", high, " Low: ", low, " Range: ", range, " Allowed Range: ", allowedRange);
   }
   
   // Check if box is formed - EXACTLY like original
   if(range <= allowedRange)
   {
      dbData.boxHigh = high;
      dbData.boxLow = low;
      dbData.boxFormed = true;
      dbData.lastBoxTime = iTime(dbData.symbol, PERIOD_CURRENT, 0);
      
      // Draw the box
      DrawDarvasBox();
      
      if(DB_EnableLogging)
         Print("DarvasBox: Box Formed - High: ", dbData.boxHigh, " Low: ", dbData.boxLow, " Time: ", dbData.lastBoxTime);
   }
   else
   {
      dbData.boxFormed = false;
      // Delete box if it exists
      ObjectsDeleteAll(0, dbData.boxName);
   }
}

bool ValidateStopLevels(double price, double &sl, double &tp, ENUM_ORDER_TYPE orderType)
{
   double minSlDistance = MathMax(dbData.minStopLevel, DB_StopLoss * dbData.point);
   double minTpDistance = MathMax(dbData.minStopLevel, DB_TakeProfit * dbData.point);
   
   if(orderType == ORDER_TYPE_BUY)
   {
      sl = price - minSlDistance;
      tp = price + minTpDistance;
   }
   else
   {
      sl = price + minSlDistance;
      tp = price - minTpDistance;
   }
   
   return true;
}

bool IsTrendFavorable(ENUM_ORDER_TYPE orderType)
{
   double ma[];
   ArraySetAsSeries(ma, true);
   
   if(CopyBuffer(dbData.maHandle, 0, 0, 2, ma) <= 0)
      return false;
      
   double currentPrice = SymbolInfoDouble(dbData.symbol, SYMBOL_ASK);
   double trendStrength = MathAbs(currentPrice - ma[0]) / dbData.point;
   
   if(orderType == ORDER_TYPE_BUY)
      return (currentPrice > ma[0] && trendStrength > DB_TrendThreshold);
   else
      return (currentPrice < ma[0] && trendStrength > DB_TrendThreshold);
}

bool CheckVolumeConditions()
{
   double volumes[];
   ArraySetAsSeries(volumes, true);
   
   if(CopyBuffer(dbData.volumeHandle, 0, 0, DB_VolumeMA_Period + 1, volumes) <= 0)
      return false;
      
   double volumeMA = 0;
   for(int i = 1; i <= DB_VolumeMA_Period; i++)
      volumeMA += volumes[i];
   volumeMA /= DB_VolumeMA_Period;
   
   double currentVolume = volumes[0];
   double volumeRatio = currentVolume / volumeMA;
   
   return (volumeRatio > DB_VolumeThresholdMultiplier);
}

bool PlaceOrder(ENUM_ORDER_TYPE orderType, double price, double sl, double tp)
{
   if(!ValidateStopLevels(price, sl, tp, orderType))
   {
      if(DB_EnableLogging)
         Print("DarvasBox: Order rejected - Stop levels validation failed");
      return false;
   }
   
   if(!IsTrendFavorable(orderType))
   {
      if(DB_EnableLogging)
         Print("DarvasBox: Order rejected - Trend not favorable for ", EnumToString(orderType));
      return false;
   }
   
   if(!CheckVolumeConditions())
   {
      if(DB_EnableLogging)
         Print("DarvasBox: Order rejected - Volume conditions not met");
      return false;
   }
   
   bool result = false;
   
   // Use market price (0) instead of explicit price - this ensures market order execution
   // In backtesting, explicit price might fail if price has moved
   if(orderType == ORDER_TYPE_BUY)
      result = dbData.trade.Buy(DARVAS_TRADE_LOT, dbData.symbol, 0, sl, tp, "Darvas Box Breakout");
   else
      result = dbData.trade.Sell(DARVAS_TRADE_LOT, dbData.symbol, 0, sl, tp, "Darvas Box Breakdown");
   
   // Always log errors, success only if logging enabled
   if(result)
   {
      if(DB_EnableLogging)
         Print("DarvasBox: ", (orderType == ORDER_TYPE_BUY ? "Buy" : "Sell"), " Order Placed Successfully");
   }
   else
   {
      // Always log failures with detailed info
      uint retcode_uint = dbData.trade.ResultRetcode();
      int retcode = (int)retcode_uint;
      string desc = dbData.trade.ResultRetcodeDescription();
      ulong deal = dbData.trade.ResultDeal();
      ulong order = dbData.trade.ResultOrder();
      Print("DarvasBox: ", (orderType == ORDER_TYPE_BUY ? "Buy" : "Sell"), 
            " Order Failed - Retcode: ", retcode, 
            ", Description: ", desc,
            ", Deal: ", deal,
            ", Order: ", order,
            ", Symbol: ", dbData.symbol,
            ", Requested Price: ", price,
            ", SL: ", sl,
            ", TP: ", tp);
   }
   
   return result;
}

void ProcessDarvasBox(string symbol)
{
   // Skip if not initialized (symbol not available)
   if(!dbData.isInitialized)
      return;
      
   dbData.symbol = symbol; // Update symbol in case it changed
   
   // Calculate new box levels - EXACTLY like original (called every tick)
   CalculateDarvasBox();
   
   // Check for trading signals - EXACTLY like original (checked every tick)
   if(dbData.boxFormed)
   {
      double currentPrice = SymbolInfoDouble(dbData.symbol, SYMBOL_ASK);
      long currentVolume_long = iVolume(dbData.symbol, PERIOD_CURRENT, 0);
      double currentVolume = (double)currentVolume_long;
      
      if(DB_EnableLogging)
      {
         Print("DarvasBox: Current Price: ", currentPrice, " Box High: ", dbData.boxHigh, " Box Low: ", dbData.boxLow);
         Print("DarvasBox: Current Volume: ", currentVolume, " Volume Threshold: ", DB_VolumeThreshold);
      }
      
      // Check for breakout above box - EXACTLY like original
      if(currentPrice > dbData.boxHigh && currentVolume > DB_VolumeThreshold)
      {
         if(DB_EnableLogging)
            Print("DarvasBox: Breakout Signal Detected - Price above box high");
            
         // Buy signal
         if(!PositionExistsByMagic(dbData.symbol, (ulong)DB_MagicNumber)) // No existing positions with our magic number
         {
            double sl = currentPrice - DB_StopLoss * dbData.point;
            double tp = currentPrice + DB_TakeProfit * dbData.point;
            
            if(DB_EnableLogging)
               Print("DarvasBox: Preparing Buy Order - Price: ", currentPrice, " SL: ", sl, " TP: ", tp);
            
            PlaceOrder(ORDER_TYPE_BUY, currentPrice, sl, tp);
         }
         else if(DB_EnableLogging)
            Print("DarvasBox: Skipping Buy Signal - Position already exists");
      }
      
      // Check for breakdown below box - EXACTLY like original
      if(currentPrice < dbData.boxLow && currentVolume > DB_VolumeThreshold)
      {
         if(DB_EnableLogging)
            Print("DarvasBox: Breakdown Signal Detected - Price below box low");
            
         // Sell signal
         if(!PositionExistsByMagic(dbData.symbol, (ulong)DB_MagicNumber)) // No existing positions with our magic number
         {
            double sl = currentPrice + DB_StopLoss * dbData.point;
            double tp = currentPrice - DB_TakeProfit * dbData.point;
            
            if(DB_EnableLogging)
               Print("DarvasBox: Preparing Sell Order - Price: ", currentPrice, " SL: ", sl, " TP: ", tp);
            
            PlaceOrder(ORDER_TYPE_SELL, currentPrice, sl, tp);
         }
         else if(DB_EnableLogging)
            Print("DarvasBox: Skipping Sell Signal - Position already exists");
      }
   }
   else if(DB_EnableLogging)
      Print("DarvasBox: No Box Formed - Waiting for consolidation");
}

//+------------------------------------------------------------------+
