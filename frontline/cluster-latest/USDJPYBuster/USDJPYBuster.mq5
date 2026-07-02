//+------------------------------------------------------------------+
//|                                               USDJPYBuster.mq5   |
//|  Standalone wrapper — logic in Strategies/USDJPYBusterStrategy.mqh |
//+------------------------------------------------------------------+
#property copyright "Lab"
#property link      ""
#property version   "1.02"
#property description "USDJPY Asian range breakout (Ian style). See cluster Strategies/USDJPYBusterStrategy.mqh."

#include <Trade/Trade.mqh>
#include "../Strategies/USDJPYBusterStrategy.mqh"

input group "=== Symbol ==="
input string              InpSymbol              = "USDJPY";

input group "=== Range session (broker server time) ==="
input int                 InpRangeStartHour      = 3;
input int                 InpRangeEndHour        = 6;
input int                 InpCloseHour           = 18;
input ENUM_TIMEFRAMES     InpRangeTF             = PERIOD_M20;
input int                 InpMinRangePoints      = 15;
input double              InpOrderBufferPoints   = 4.75;

input group "=== Breakout orders ==="
input bool                InpFirstTradeOnly      = false;
input bool                InpAllowLong           = true;
input bool                InpAllowShort          = true;
input bool                InpUseTakeProfit       = false;
input double              InpTakeProfitPoints      = 0.0;

input group "=== Risk ==="
input ENUM_UB_RISK_MODE   InpRiskMode            = UB_RISK_FIXED_LOTS;
input double              InpFixedRiskMoney      = 250.0;
input double              InpRiskPercent         = 0.1;
input double              InpFixedLots           = 0.01;
input int                 InpMagic               = 927002;
input int                 InpSlippagePoints      = 20;
input int                 InpMaxSpreadPoints     = 20;

input group "=== Debug ==="
input bool                InpDrawRange           = false;
input bool                InpDebugLog            = false;

USDJPYBusterData g_ub;

string WorkSymbol()
{
   string s = InpSymbol;
   StringTrimLeft(s);
   StringTrimRight(s);
   const int bar = StringFind(s, "|");
   if(bar >= 0)
      s = StringSubstr(s, 0, bar);
   StringTrimRight(s);
   return (StringLen(s) > 0 ? s : _Symbol);
}

int OnInit()
{
   return InitUSDJPYBuster(g_ub, WorkSymbol(),
                           InpRangeStartHour, InpRangeEndHour, InpCloseHour, InpRangeTF,
                           InpMinRangePoints, InpOrderBufferPoints,
                           InpFirstTradeOnly, InpAllowLong, InpAllowShort,
                           InpUseTakeProfit, InpTakeProfitPoints,
                           InpRiskMode, InpFixedRiskMoney, InpRiskPercent, InpFixedLots,
                           InpMagic, InpSlippagePoints, InpMaxSpreadPoints,
                           InpDrawRange, InpDebugLog) ? INIT_SUCCEEDED : INIT_FAILED;
}

void OnDeinit(const int reason)
{
   DeinitUSDJPYBuster(g_ub);
}

void OnTick()
{
   ProcessUSDJPYBuster(g_ub, InpFixedLots, 1.0);
}

//+------------------------------------------------------------------+
