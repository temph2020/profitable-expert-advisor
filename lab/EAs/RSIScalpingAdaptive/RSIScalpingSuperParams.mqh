// RSIScalpingSuperParams.mqh — per-symbol H1 RSI scalping
// XAUUSD: MT5 genetic 2026-06-23. Forex: run MT5 Genetic per symbol (see SUPER_EA_README.md)
#ifndef RSI_SCALPING_SUPER_PARAMS_MQH
#define RSI_SCALPING_SUPER_PARAMS_MQH

#include "RSIScalpingSuperMagic.mqh"

#define RS_SUPER_SLOT_COUNT 9

struct RSSlotParams
{
   int    rsiPeriod;
   double rsiOverbought;
   double rsiOversold;
   double rsiTargetBuy;
   double rsiTargetSell;
   int    barsToWait;
   double lotSize;
};

struct RSSlotConfig
{
   string       symbol;
   int          magic;
   bool         enabled;
   RSSlotParams p;
};

const RSSlotConfig RS_SUPER_SLOTS[RS_SUPER_SLOT_COUNT] =
{
   // EURUSD — pending MT5 genetic (disable until optimized)
   { "EURUSD", RS_SUPER_MAGIC_BASE + 1, false,
     { 14, 8.0, 72.0, 85.0, 18.0, 8, 0.10 } },
   // GBPUSD — pending MT5 genetic
   { "GBPUSD", RS_SUPER_MAGIC_BASE + 2, false,
     { 12, 7.0, 70.0, 88.0, 22.0, 10, 0.10 } },
   // USDJPY — pending MT5 genetic
   { "USDJPY", RS_SUPER_MAGIC_BASE + 3, false,
     { 16, 5.0, 76.0, 82.0, 28.0, 9, 0.10 } },
   // AUDUSD — pending MT5 genetic
   { "AUDUSD", RS_SUPER_MAGIC_BASE + 4, false,
     { 15, 9.0, 68.0, 86.0, 20.0, 7, 0.10 } },
   // USDCHF — pending MT5 genetic
   { "USDCHF", RS_SUPER_MAGIC_BASE + 5, false,
     { 13, 6.0, 74.0, 84.0, 26.0, 11, 0.10 } },
   // USDCAD — pending MT5 genetic
   { "USDCAD", RS_SUPER_MAGIC_BASE + 6, false,
     { 14, 10.0, 66.0, 87.0, 16.0, 8, 0.10 } },
   // NZDUSD — pending MT5 genetic
   { "NZDUSD", RS_SUPER_MAGIC_BASE + 7, false,
     { 11, 8.0, 71.0, 89.0, 19.0, 9, 0.10 } },
   // EURJPY — pending MT5 genetic
   { "EURJPY", RS_SUPER_MAGIC_BASE + 8, false,
     { 18, 4.0, 77.0, 80.0, 30.0, 10, 0.10 } },
   // XAUUSD — MT5 genetic profit=$28,071 PF=1.47 DD=5.3% (2004–2026)
   { "XAUUSD", RS_SUPER_MAGIC_BASE + 9, true,
     { 14, 19.0, 68.0, 89.0, 20.0, 12, 0.10 } },
};

#endif
