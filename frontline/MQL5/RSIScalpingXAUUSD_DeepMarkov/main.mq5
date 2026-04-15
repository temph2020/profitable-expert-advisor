//+------------------------------------------------------------------+
//|                                   RSIScalpingXAUUSD_DeepMarkov.mq5 |
//| RSI scalping with online deep Markov regime filter + self-tune.  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.00"

#include "MagicNumberHelpers.mqh"
#include "DeepMarkovRegimeModel.mqh"

//--- Input parameters
input group "=== Chart / RSI ==="
input ENUM_TIMEFRAMES      TimeFrame = PERIOD_H1;
input int                  RSI_Period = 14;
input ENUM_APPLIED_PRICE   RSI_Applied_Price = PRICE_CLOSE;

input group "=== Base RSI levels (Markov blends & learns offsets) ==="
input double              RSI_Overbought = 71;
input double              RSI_Oversold = 57;
input double              RSI_Target_Buy = 80;
input double              RSI_Target_Sell = 57;
input int                 BarsToWait = 4;

input group "=== Execution ==="
input double              LotSize = 0.1;
input int                 MagicNumber = 129102316;
input int                 Slippage = 3;

input group "=== Deep Markov self-optimization ==="
input double              DMR_LearnTransition = 0.05;
input double              DMR_LearnEmission = 0.02;
input double              DMR_LearnWin = 0.03;
input double              DMR_LearnLoss = 0.015;
input bool                DMR_PersistGlobals = true;
input string              DMR_GlobalPrefix = "DMR_XAU_";
input bool                DMR_LogEachBar = false;

//--- Global variables
CTrade trade;
CDeepMarkovRegimeModel g_dm;

int rsi_handle;
int atr_fast_handle;
int atr_slow_handle;
double rsi_buffer[];
double rsi_prev, rsi_current, rsi_two_bars_ago;
double atr_fast, atr_slow;

bool position_open = false;
int position_ticket = 0;
ENUM_POSITION_TYPE current_position_type = POSITION_TYPE_BUY;
datetime last_bar_time = 0;
bool rsi_against_position = false;
int bars_against_count = 0;

int entry_regime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   rsi_handle = iRSI(_Symbol, TimeFrame, RSI_Period, RSI_Applied_Price);
   if(rsi_handle == INVALID_HANDLE)
      return(INIT_FAILED);

   atr_fast_handle = iATR(_Symbol, TimeFrame, 8);
   atr_slow_handle = iATR(_Symbol, TimeFrame, 34);
   if(atr_fast_handle == INVALID_HANDLE || atr_slow_handle == INVALID_HANDLE)
      return(INIT_FAILED);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   ArraySetAsSeries(rsi_buffer, true);

   g_dm.SetSeed(MagicNumber);
   g_dm.SetLearningRates(DMR_LearnTransition, DMR_LearnEmission, DMR_LearnWin, DMR_LearnLoss);
   g_dm.SetBaseThresholds(RSI_Overbought, RSI_Oversold, RSI_Target_Buy, RSI_Target_Sell, BarsToWait);

   if(DMR_PersistGlobals)
   {
      if(g_dm.LoadFromGlobals(DMR_GlobalPrefix))
         Print("RSIScalpingXAUUSD_DeepMarkov: loaded persisted Markov state from globals.");
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(DMR_PersistGlobals)
      g_dm.SaveToGlobals(DMR_GlobalPrefix);

   if(rsi_handle != INVALID_HANDLE)
      IndicatorRelease(rsi_handle);
   if(atr_fast_handle != INVALID_HANDLE)
      IndicatorRelease(atr_fast_handle);
   if(atr_slow_handle != INVALID_HANDLE)
      IndicatorRelease(atr_slow_handle);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(Bars(_Symbol, TimeFrame) < RSI_Period + 5)
      return;

   datetime current_bar_time = iTime(_Symbol, TimeFrame, 0);
   if(current_bar_time == last_bar_time)
      return;

   last_bar_time = current_bar_time;

   if(!UpdateRSI())
      return;

   if(!UpdateATR())
      return;

   const double f0 = rsi_current / 100.0;
   const double dr = rsi_current - rsi_prev;
   const double f1 = MathTanh(dr / 10.0) * 0.5 + 0.5;
   double ratio = 1.0;
   if(atr_slow > 1.0e-12)
      ratio = atr_fast / atr_slow;
   if(ratio < 0.15)
      ratio = 0.15;
   if(ratio > 2.5)
      ratio = 2.5;
   const double f2 = ratio / 2.5;

   g_dm.Update(f0, f1, f2);

   if(DMR_LogEachBar)
      Print(g_dm.DebugStateLine());

   ResyncPositionFromMarket();

   CheckExistingPosition();

   if(!position_open && !PositionExistsByMagic(_Symbol, (ulong)MagicNumber))
      CheckEntrySignals();
}

//+------------------------------------------------------------------+
bool UpdateRSI()
{
   if(CopyBuffer(rsi_handle, 0, 0, 3, rsi_buffer) < 3)
      return false;

   rsi_current = rsi_buffer[0];
   rsi_prev = rsi_buffer[1];
   rsi_two_bars_ago = rsi_buffer[2];
   return true;
}

//+------------------------------------------------------------------+
bool UpdateATR()
{
   double af[], as[];
   ArrayResize(af, 1);
   ArrayResize(as, 1);
   ArraySetAsSeries(af, true);
   ArraySetAsSeries(as, true);
   if(CopyBuffer(atr_fast_handle, 0, 0, 1, af) < 1)
      return false;
   if(CopyBuffer(atr_slow_handle, 0, 0, 1, as) < 1)
      return false;
   atr_fast = af[0];
   atr_slow = as[0];
   return true;
}

//+------------------------------------------------------------------+
void ResyncPositionFromMarket()
{
   if(position_open)
      return;
   ulong t = GetPositionTicketByMagic(_Symbol, (ulong)MagicNumber);
   if(t == 0 || !PositionSelectByTicket(t))
      return;
   position_ticket = (int)t;
   position_open = true;
   current_position_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   entry_regime = g_dm.ArgMaxPi();
}

//+------------------------------------------------------------------+
double EffectiveOverbought() { return g_dm.EffectiveOverbought(); }
double EffectiveOversold() { return g_dm.EffectiveOversold(); }
double EffectiveTargetBuy() { return g_dm.EffectiveTargetBuy(); }
double EffectiveTargetSell() { return g_dm.EffectiveTargetSell(); }
int EffectiveBarsToWait() { return g_dm.EffectiveBarsToWait(); }

//+------------------------------------------------------------------+
void CheckExistingPosition()
{
   if(!position_open)
      return;

   if(!PositionSelectByTicketAndMagic((ulong)position_ticket, (ulong)MagicNumber))
   {
      position_open = false;
      position_ticket = 0;
      rsi_against_position = false;
      bars_against_count = 0;
      return;
   }

   const double ob = EffectiveOverbought();
   const double os = EffectiveOversold();
   const double tb = EffectiveTargetBuy();
   const double ts = EffectiveTargetSell();
   const int bw = EffectiveBarsToWait();

   if(current_position_type == POSITION_TYPE_BUY)
   {
      if(rsi_current < os)
      {
         if(!rsi_against_position)
         {
            rsi_against_position = true;
            bars_against_count = 1;
         }
         else
            bars_against_count++;

         if(bars_against_count >= bw)
         {
            ClosePosition();
            return;
         }
      }
      else
      {
         if(rsi_against_position)
         {
            rsi_against_position = false;
            bars_against_count = 0;
         }
         if(rsi_current >= tb)
            ClosePosition();
      }
   }
   else if(current_position_type == POSITION_TYPE_SELL)
   {
      if(rsi_current > ob)
      {
         if(!rsi_against_position)
         {
            rsi_against_position = true;
            bars_against_count = 1;
         }
         else
            bars_against_count++;

         if(bars_against_count >= bw)
         {
            ClosePosition();
            return;
         }
      }
      else
      {
         if(rsi_against_position)
         {
            rsi_against_position = false;
            bars_against_count = 0;
         }
         if(rsi_current <= ts)
            ClosePosition();
      }
   }
}

//+------------------------------------------------------------------+
void CheckEntrySignals()
{
   const double os = EffectiveOversold();
   const double ob = EffectiveOverbought();

   if(rsi_two_bars_ago <= os && rsi_prev > os)
      OpenBuyPosition();

   if(rsi_two_bars_ago >= ob && rsi_prev < ob)
      OpenSellPosition();
}

//+------------------------------------------------------------------+
void OpenBuyPosition()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   entry_regime = g_dm.ArgMaxPi();

   if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "RSI DM Buy"))
   {
      ulong pt = GetPositionTicketByMagic(_Symbol, (ulong)MagicNumber);
      position_ticket = (int)pt;
      position_open = true;
      current_position_type = POSITION_TYPE_BUY;
   }
}

//+------------------------------------------------------------------+
void OpenSellPosition()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   entry_regime = g_dm.ArgMaxPi();

   if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "RSI DM Sell"))
   {
      ulong pt = GetPositionTicketByMagic(_Symbol, (ulong)MagicNumber);
      position_ticket = (int)pt;
      position_open = true;
      current_position_type = POSITION_TYPE_SELL;
   }
}

//+------------------------------------------------------------------+
void ClosePosition()
{
   double profit = 0.0;
   if(PositionSelectByTicket(position_ticket))
      profit = PositionGetDouble(POSITION_PROFIT);

   const int regime = entry_regime;

   if(ClosePositionByMagic(trade, _Symbol, (ulong)MagicNumber))
   {
      position_open = false;
      position_ticket = 0;
      rsi_against_position = false;
      bars_against_count = 0;
      g_dm.OnTradeClosed(regime, profit);
      return;
   }
   if(!PositionExistsByMagic(_Symbol, (ulong)MagicNumber))
   {
      position_open = false;
      position_ticket = 0;
      rsi_against_position = false;
      bars_against_count = 0;
      g_dm.OnTradeClosed(regime, profit);
      return;
   }
   Print("RSIScalpingXAUUSD_DeepMarkov: close failed (will retry). retcode=",
         trade.ResultRetcode(), " lastError=", GetLastError());
}
