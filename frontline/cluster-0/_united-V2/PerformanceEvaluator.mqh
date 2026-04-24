//+------------------------------------------------------------------+
//|                                          PerformanceEvaluator.mqh |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

//+------------------------------------------------------------------+
//| Performance Metrics Structure                                    |
//+------------------------------------------------------------------+
struct StrategyPerformance {
   string strategyName;
   string symbol;              // Store symbol to determine if it's a stock
   int magicNumber;
   double initialLotSize;
   double currentLotSize;
   double quarterProfit;
   double quarterTrades;
   double quarterWins;
   double quarterLosses;
   double maxDrawdown;
   double winRate;
   datetime quarterStart;
   datetime quarterEnd;
   bool isActive;
   bool inPenaltyMode;        // True if strategy is in penalty (worst performer)
   double lotSizeBeforePenalty; // Store lot size before penalty
   datetime penaltyStartTime;   // When penalty started
};

//+------------------------------------------------------------------+
//| Global Performance Tracking                                      |
//+------------------------------------------------------------------+
StrategyPerformance strategyPerformances[];
int totalStrategies = 0;
datetime lastMonthCheck = 0;
datetime currentMonthStart = 0;
datetime currentMonthEnd = 0;

//+------------------------------------------------------------------+
//| Performance Adjustment Parameters                                 |
//+------------------------------------------------------------------+
input group "=== Performance Evaluation Settings ==="
input bool PE_EnableAutoAdjustment = true;  // Enable automatic lot size adjustment
input double PE_LotSizeIncreasePercent = 10.0;  // % increase for top-ranked strategies
input double PE_LotSizeDecreasePercent = 10.0;  // % decrease for bottom-ranked strategies
input double PE_MinLotSize = 0.01;            // Minimum lot size for forex/crypto
input double PE_MinLotSizeStocks = 5.0;       // Minimum lot size for stocks (5-10 range)
input double PE_MaxLotSize = 100.0;           // Maximum lot size after adjustment
input int PE_TopPerformersCount = 3;          // Number of top strategies to increase lot size
input int PE_BottomPerformersCount = 3;       // Number of bottom strategies to decrease lot size
input bool PE_UseWinRateWeight = true;        // Consider win rate in ranking (50% profit, 50% win rate)
input bool PE_EnableBlitzPlay = true;         // Enable blitz play: worst performer gets minimum lot size penalty
input bool PE_EnableLogging = true;           // Enable performance logging

//+------------------------------------------------------------------+
//| Initialize Performance Tracking                                  |
//+------------------------------------------------------------------+
void InitPerformanceTracking()
{
   // Calculate current month dates
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // Determine month start (first day of current month)
   dt.day = 1;
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   currentMonthStart = StructToTime(dt);
   
   // Calculate month end (first day of next month - 1 second)
   dt.mon += 1;
   if(dt.mon > 12)
   {
      dt.mon = 1;
      dt.year++;
   }
   currentMonthEnd = StructToTime(dt) - 1; // End of last day of month
   
   lastMonthCheck = TimeCurrent();
   
   if(PE_EnableLogging)
   {
      Print("Performance Evaluator: Initialized");
      Print("Current Month Start: ", TimeToString(currentMonthStart));
      Print("Current Month End: ", TimeToString(currentMonthEnd));
   }
}

//+------------------------------------------------------------------+
//| Check if Symbol is a Stock                                       |
//+------------------------------------------------------------------+
bool IsStockSymbol(string symbol)
{
   // Check if symbol contains common stock indicators
   if(StringFind(symbol, ".US") >= 0) return true;
   if(StringFind(symbol, "NASDAQ:") >= 0) return true;
   if(StringFind(symbol, "NYSE:") >= 0) return true;
   
   // Note: Symbol category check removed to avoid enum conversion issues
   // String-based checks (.US, NASDAQ:, NYSE:, common tickers) are sufficient
   
   // Common stock tickers (without .US suffix)
   string commonStocks[] = {"AAPL", "MSFT", "NVDA", "TSLA", "GOOGL", "AMZN", "META", "NFLX"};
   for(int i = 0; i < ArraySize(commonStocks); i++)
   {
      if(StringFind(symbol, commonStocks[i]) == 0) return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Get Minimum Lot Size for Symbol                                  |
//+------------------------------------------------------------------+
double GetMinLotSizeForSymbol(string symbol)
{
   if(IsStockSymbol(symbol))
      return PE_MinLotSizeStocks;
   else
      return PE_MinLotSize;
}

//+------------------------------------------------------------------+
//| Register Strategy for Performance Tracking                       |
//+------------------------------------------------------------------+
void RegisterStrategy(string strategyName, int magicNumber, double initialLotSize, string symbol = "")
{
   // Check if strategy already registered
   for(int i = 0; i < ArraySize(strategyPerformances); i++)
   {
      if(strategyPerformances[i].strategyName == strategyName && 
         strategyPerformances[i].magicNumber == magicNumber)
      {
         if(PE_EnableLogging)
            Print("Performance Evaluator: Strategy '", strategyName, "' already registered");
         return;
      }
   }
   
   // Add new strategy
   int newSize = ArraySize(strategyPerformances) + 1;
   ArrayResize(strategyPerformances, newSize);
   
   strategyPerformances[newSize - 1].strategyName = strategyName;
   strategyPerformances[newSize - 1].symbol = symbol;
   strategyPerformances[newSize - 1].magicNumber = magicNumber;
   strategyPerformances[newSize - 1].initialLotSize = initialLotSize;
   // Start with minimum lot size for safety (symbol-specific minimum)
   double minLot = GetMinLotSizeForSymbol(symbol);
   strategyPerformances[newSize - 1].currentLotSize = minLot;
   strategyPerformances[newSize - 1].quarterProfit = 0.0;
   strategyPerformances[newSize - 1].quarterTrades = 0;
   strategyPerformances[newSize - 1].quarterWins = 0;
   strategyPerformances[newSize - 1].quarterLosses = 0;
   strategyPerformances[newSize - 1].maxDrawdown = 0.0;
   strategyPerformances[newSize - 1].winRate = 0.0;
   strategyPerformances[newSize - 1].quarterStart = currentMonthStart;
   strategyPerformances[newSize - 1].quarterEnd = currentMonthEnd;
   strategyPerformances[newSize - 1].isActive = true;
   strategyPerformances[newSize - 1].inPenaltyMode = false;
   strategyPerformances[newSize - 1].lotSizeBeforePenalty = initialLotSize;
   strategyPerformances[newSize - 1].penaltyStartTime = 0;
   
   totalStrategies = newSize;
   
   if(PE_EnableLogging)
      Print("Performance Evaluator: Registered strategy '", strategyName, 
            "' (Magic: ", magicNumber, ", Initial Lot: ", initialLotSize, ")");
}

//+------------------------------------------------------------------+
//| Update Strategy Performance Metrics                              |
//+------------------------------------------------------------------+
void UpdateStrategyPerformance(string strategyName, int magicNumber)
{
   for(int i = 0; i < ArraySize(strategyPerformances); i++)
   {
      if(strategyPerformances[i].strategyName == strategyName && 
         strategyPerformances[i].magicNumber == magicNumber &&
         strategyPerformances[i].isActive)
      {
         // Calculate performance for current quarter
         double totalProfit = 0.0;
         int totalTrades = 0;
         int wins = 0;
         int losses = 0;
         double maxDD = 0.0;
         double peakBalance = 0.0;
         
         // Scan all closed deals in current quarter
         datetime quarterStart = strategyPerformances[i].quarterStart;
         datetime quarterEnd = strategyPerformances[i].quarterEnd;
         
         // Select history for the quarter
         if(HistorySelect(quarterStart, quarterEnd))
         {
            int totalDeals = HistoryDealsTotal();
            for(int j = 0; j < totalDeals; j++)
            {
               ulong ticket = HistoryDealGetTicket(j);
               if(ticket > 0)
               {
                  long dealMagic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
                  if(dealMagic == magicNumber)
                  {
                     double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
                     double swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
                     double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
                     double totalDealProfit = profit + swap + commission;
                     
                     totalProfit += totalDealProfit;
                     totalTrades++;
                     
                     if(totalDealProfit > 0)
                        wins++;
                     else if(totalDealProfit < 0)
                        losses++;
                  }
               }
            }
         }
         
         // Calculate win rate
         double winRate = 0.0;
         if(totalTrades > 0)
            winRate = (double)wins / (double)totalTrades * 100.0;
         
         // Update metrics
         strategyPerformances[i].quarterProfit = totalProfit;
         strategyPerformances[i].quarterTrades = totalTrades;
         strategyPerformances[i].quarterWins = wins;
         strategyPerformances[i].quarterLosses = losses;
         strategyPerformances[i].winRate = winRate;
         
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| Strategy Ranking Structure                                       |
//+------------------------------------------------------------------+
struct StrategyRank {
   int index;
   double score;
};

//+------------------------------------------------------------------+
//| Calculate Strategy Score for Ranking                             |
//+------------------------------------------------------------------+
double CalculateStrategyScore(int strategyIndex)
{
   double profit = strategyPerformances[strategyIndex].quarterProfit;
   double winRate = strategyPerformances[strategyIndex].winRate;
   double trades = strategyPerformances[strategyIndex].quarterTrades;
   
   // Normalize profit (scale to 0-100 range, assuming max profit of $1000)
   double normalizedProfit = MathMin(profit / 10.0, 100.0);
   if(profit < 0) normalizedProfit = profit / 5.0; // Penalize losses more
   
   // Calculate score
   double score = 0.0;
   if(PE_UseWinRateWeight)
   {
      // 50% profit, 50% win rate (if enough trades)
      if(trades >= 5)
         score = (normalizedProfit * 0.5) + (winRate * 0.5);
      else
         score = normalizedProfit; // Not enough trades, use profit only
   }
   else
   {
      // Profit only
      score = normalizedProfit;
   }
   
   return score;
}

//+------------------------------------------------------------------+
//| Check if Month Ended and Evaluate Performance                    |
//+------------------------------------------------------------------+
void CheckMonthEnd()
{
   datetime now = TimeCurrent();
   
   // Check if we've entered a new month
   if(now >= currentMonthEnd)
   {
      if(PE_EnableLogging)
         Print("Performance Evaluator: Month ended. Evaluating and ranking strategies...");
      
      // Update performance metrics for all strategies
      for(int i = 0; i < ArraySize(strategyPerformances); i++)
      {
         if(strategyPerformances[i].isActive)
         {
            UpdateStrategyPerformance(strategyPerformances[i].strategyName, 
                                     strategyPerformances[i].magicNumber);
         }
      }
      
      // Rank strategies
      int activeCount = 0;
      for(int i = 0; i < ArraySize(strategyPerformances); i++)
      {
         if(strategyPerformances[i].isActive)
            activeCount++;
      }
      
      if(activeCount > 0)
      {
         // Create ranking array
         StrategyRank ranks[];
         ArrayResize(ranks, activeCount);
         int rankIndex = 0;
         
         for(int i = 0; i < ArraySize(strategyPerformances); i++)
         {
            if(strategyPerformances[i].isActive)
            {
               ranks[rankIndex].index = i;
               ranks[rankIndex].score = CalculateStrategyScore(i);
               rankIndex++;
            }
         }
         
         // Sort by score (descending - highest score first)
         for(int i = 0; i < activeCount - 1; i++)
         {
            for(int j = i + 1; j < activeCount; j++)
            {
               if(ranks[j].score > ranks[i].score)
               {
                  StrategyRank temp = ranks[i];
                  ranks[i] = ranks[j];
                  ranks[j] = temp;
               }
            }
         }
         
         // Adjust lot sizes based on ranking
         if(PE_EnableAutoAdjustment)
         {
            // Increase top performers (skip if in penalty mode)
            int topCount = MathMin(PE_TopPerformersCount, activeCount);
            for(int i = 0; i < topCount; i++)
            {
               int strategyIdx = ranks[i].index;
               
               // Skip if strategy is in penalty mode
               if(strategyPerformances[strategyIdx].inPenaltyMode)
                  continue;
               
               double oldLotSize = strategyPerformances[strategyIdx].currentLotSize;
               double newLotSize = oldLotSize * (1.0 + PE_LotSizeIncreasePercent / 100.0);
               
               if(newLotSize > PE_MaxLotSize)
                  newLotSize = PE_MaxLotSize;
               
               strategyPerformances[strategyIdx].currentLotSize = newLotSize;
               
               if(PE_EnableLogging)
                  Print("Performance Evaluator: Rank #", (i+1), " - Increasing '", 
                        strategyPerformances[strategyIdx].strategyName, 
                        "' lot size from ", oldLotSize, " to ", newLotSize,
                        " (Score: ", DoubleToString(ranks[i].score, 2), 
                        ", Profit: $", DoubleToString(strategyPerformances[strategyIdx].quarterProfit, 2),
                        ", Win Rate: ", DoubleToString(strategyPerformances[strategyIdx].winRate, 2), "%)");
            }
            
            // Decrease bottom performers (skip worst one if blitz play is enabled)
            int bottomCount = MathMin(PE_BottomPerformersCount, activeCount);
            int startIdx = activeCount - bottomCount;
            
            // If blitz play is enabled, skip the worst performer (it will get minimum penalty)
            if(PE_EnableBlitzPlay && activeCount > 0)
               startIdx = activeCount - bottomCount + 1;
            
            for(int i = startIdx; i < activeCount; i++)
            {
               int strategyIdx = ranks[i].index;
               
               // Skip if strategy is in penalty mode
               if(strategyPerformances[strategyIdx].inPenaltyMode)
                  continue;
               
               double oldLotSize = strategyPerformances[strategyIdx].currentLotSize;
               double newLotSize = oldLotSize * (1.0 - PE_LotSizeDecreasePercent / 100.0);
               
               // Use symbol-specific minimum lot size
               double minLot = GetMinLotSizeForSymbol(strategyPerformances[strategyIdx].symbol);
               if(newLotSize < minLot)
                  newLotSize = minLot;
               
               strategyPerformances[strategyIdx].currentLotSize = newLotSize;
               
               if(PE_EnableLogging)
                  Print("Performance Evaluator: Rank #", (i+1), " - Decreasing '", 
                        strategyPerformances[strategyIdx].strategyName, 
                        "' lot size from ", oldLotSize, " to ", newLotSize,
                        " (Score: ", DoubleToString(ranks[i].score, 2), 
                        ", Profit: $", DoubleToString(strategyPerformances[strategyIdx].quarterProfit, 2),
                        ", Win Rate: ", DoubleToString(strategyPerformances[strategyIdx].winRate, 2), "%)");
            }
         }
         
         // Blitz Play: Apply penalty to worst performer
         if(PE_EnableBlitzPlay && activeCount > 0)
         {
            // Find worst performer (last in ranking)
            int worstIdx = ranks[activeCount - 1].index;
            
            // Remove penalty from previous worst performer (if any)
            for(int i = 0; i < ArraySize(strategyPerformances); i++)
            {
               if(strategyPerformances[i].isActive && strategyPerformances[i].inPenaltyMode)
               {
                  // Check if penalty period has passed (one month)
                  if(now - strategyPerformances[i].penaltyStartTime >= 2592000) // ~30 days
                  {
                     // Restore lot size to before penalty
                     strategyPerformances[i].currentLotSize = strategyPerformances[i].lotSizeBeforePenalty;
                     strategyPerformances[i].inPenaltyMode = false;
                     strategyPerformances[i].penaltyStartTime = 0;
                     
                     if(PE_EnableLogging)
                        Print("Blitz Play: Penalty removed from '", strategyPerformances[i].strategyName, 
                              "'. Lot size restored to ", strategyPerformances[i].currentLotSize);
                  }
               }
            }
            
            // Apply penalty to new worst performer
            if(!strategyPerformances[worstIdx].inPenaltyMode)
            {
               strategyPerformances[worstIdx].lotSizeBeforePenalty = strategyPerformances[worstIdx].currentLotSize;
               // Use symbol-specific minimum lot size
               double minLot = GetMinLotSizeForSymbol(strategyPerformances[worstIdx].symbol);
               strategyPerformances[worstIdx].currentLotSize = minLot;
               strategyPerformances[worstIdx].inPenaltyMode = true;
               strategyPerformances[worstIdx].penaltyStartTime = now;
               
               if(PE_EnableLogging)
                  Print("Blitz Play: WORST PERFORMER - '", strategyPerformances[worstIdx].strategyName, 
                        "' penalized! Lot size reduced from ", strategyPerformances[worstIdx].lotSizeBeforePenalty, 
                        " to minimum ", minLot, " (Score: ", DoubleToString(ranks[activeCount - 1].score, 2), 
                        ", Profit: $", DoubleToString(strategyPerformances[worstIdx].quarterProfit, 2), ")");
            }
         }
         
         // Log performance report
         if(PE_EnableLogging)
         {
            Print("=== Monthly Performance Ranking ===");
            for(int i = 0; i < activeCount; i++)
            {
               int strategyIdx = ranks[i].index;
               Print("Rank #", (i+1), ": ", strategyPerformances[strategyIdx].strategyName,
                     " - Score: ", DoubleToString(ranks[i].score, 2),
                     ", Profit: $", DoubleToString(strategyPerformances[strategyIdx].quarterProfit, 2),
                     ", Win Rate: ", DoubleToString(strategyPerformances[strategyIdx].winRate, 2), "%",
                     ", Trades: ", (int)strategyPerformances[strategyIdx].quarterTrades,
                     ", Lot Size: ", DoubleToString(strategyPerformances[strategyIdx].currentLotSize, 2));
            }
            Print("===================================");
         }
      }
      
      // Reset month metrics for all strategies
      for(int i = 0; i < ArraySize(strategyPerformances); i++)
      {
         if(strategyPerformances[i].isActive)
         {
            strategyPerformances[i].quarterProfit = 0.0;
            strategyPerformances[i].quarterTrades = 0;
            strategyPerformances[i].quarterWins = 0;
            strategyPerformances[i].quarterLosses = 0;
            strategyPerformances[i].maxDrawdown = 0.0;
            strategyPerformances[i].winRate = 0.0;
         }
      }
      
      // Update month dates
      MqlDateTime dt;
      TimeToStruct(now, dt);
      
      // First day of current month
      dt.day = 1;
      dt.hour = 0;
      dt.min = 0;
      dt.sec = 0;
      currentMonthStart = StructToTime(dt);
      
      // First day of next month - 1 second
      dt.mon += 1;
      if(dt.mon > 12)
      {
         dt.mon = 1;
         dt.year++;
      }
      currentMonthEnd = StructToTime(dt) - 1;
      
      // Update month dates for all strategies
      for(int i = 0; i < ArraySize(strategyPerformances); i++)
      {
         strategyPerformances[i].quarterStart = currentMonthStart;
         strategyPerformances[i].quarterEnd = currentMonthEnd;
      }
      
      lastMonthCheck = now;
   }
}

//+------------------------------------------------------------------+
//| Get Current Lot Size for Strategy                                 |
//+------------------------------------------------------------------+
double GetStrategyLotSize(string strategyName, int magicNumber)
{
   for(int i = 0; i < ArraySize(strategyPerformances); i++)
   {
      if(strategyPerformances[i].strategyName == strategyName && 
         strategyPerformances[i].magicNumber == magicNumber &&
         strategyPerformances[i].isActive)
      {
         return strategyPerformances[i].currentLotSize;
      }
   }
   return 0.0;
}

//+------------------------------------------------------------------+
//| Process Performance Evaluation (call from OnTick)               |
//+------------------------------------------------------------------+
void ProcessPerformanceEvaluation()
{
   // Check if month ended
   CheckMonthEnd();
   
   // Check for penalty expiration (blitz play)
   if(PE_EnableBlitzPlay)
   {
      datetime now = TimeCurrent();
      for(int i = 0; i < ArraySize(strategyPerformances); i++)
      {
         if(strategyPerformances[i].isActive && strategyPerformances[i].inPenaltyMode)
         {
            // Check if penalty period has passed (one month = ~30 days)
            if(now - strategyPerformances[i].penaltyStartTime >= 2592000)
            {
               // Restore lot size to before penalty
               strategyPerformances[i].currentLotSize = strategyPerformances[i].lotSizeBeforePenalty;
               strategyPerformances[i].inPenaltyMode = false;
               strategyPerformances[i].penaltyStartTime = 0;
               
               if(PE_EnableLogging)
                  Print("Blitz Play: Penalty expired for '", strategyPerformances[i].strategyName, 
                        "'. Lot size restored to ", strategyPerformances[i].currentLotSize);
            }
         }
      }
   }
   
   // Update performance metrics periodically (every hour)
   static datetime lastUpdate = 0;
   if(TimeCurrent() - lastUpdate >= 3600)
   {
      for(int i = 0; i < ArraySize(strategyPerformances); i++)
      {
         if(strategyPerformances[i].isActive)
         {
            UpdateStrategyPerformance(strategyPerformances[i].strategyName, 
                                     strategyPerformances[i].magicNumber);
         }
      }
      lastUpdate = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Get Performance Summary                                           |
//+------------------------------------------------------------------+
string GetPerformanceSummary()
{
   string summary = "\n=== Performance Summary ===\n";
   summary += "Current Month: " + TimeToString(currentMonthStart) + " to " + TimeToString(currentMonthEnd) + "\n\n";
   
   for(int i = 0; i < ArraySize(strategyPerformances); i++)
   {
      if(strategyPerformances[i].isActive)
      {
         summary += strategyPerformances[i].strategyName + ":\n";
         summary += "  Profit: $" + DoubleToString(strategyPerformances[i].quarterProfit, 2) + "\n";
         summary += "  Trades: " + IntegerToString((int)strategyPerformances[i].quarterTrades) + "\n";
         summary += "  Win Rate: " + DoubleToString(strategyPerformances[i].winRate, 2) + "%\n";
         summary += "  Lot Size: " + DoubleToString(strategyPerformances[i].currentLotSize, 2) + "\n\n";
      }
   }
   
   return summary;
}

//+------------------------------------------------------------------+
