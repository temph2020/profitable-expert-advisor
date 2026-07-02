# RSIScalpingAdaptive XAUUSD — MT5 Strategy Tester

## 快速开始（MT5 原生回测）

1. 复制整个 `RSIScalpingAdaptive` 文件夹到 `MQL5\Experts\`
2. MetaEditor 编译 `main.mq5`
3. **或用脚本自动编译 + 启动 Tester**：

```powershell
cd lab\EAs\RSIScalpingAdaptive

# 单次回测 2004→现在
python run_mt5_tester.py backtest --symbol XAUUSD --from 2004.01.01 --to 2026.01.01

# 遗传算法优化（MT5 Strategy Tester → Genetic）
python run_mt5_tester.py optimize --symbol XAUUSD --from 2004.01.01 --to 2026.01.01
```

脚本会：编译 EA → 写入 `.ini` → 启动 `terminal64.exe /config:...` → 解析 HTML 报告。

## 手动在 MT5 里测

1. 策略测试器 → 专家：`RSIScalpingAdaptive.ex5`
2. 品种：**XAUUSD**，周期：**H1**
3. 日期：**2004.01.01** — **2026.01.01**
4. 模式：每个 tick 基于真实 tick / 1分钟 OHLC
5. Inputs → Load → `XAUUSD_Backtest.set`（固定参数）或 `XAUUSD_Genetic_Optimization.set`（遗传优化）
6. **EnableAdaptive 必须 = false**（Tester 里 EA 直接用 Inputs，不做 walk-forward 网格）

## 当前 XAUUSD 参数（MT5 Demo 2004–2026 验证）

| 参数 | 值 | 说明 |
|------|-----|------|
| TimeFrame | H1 | |
| RSI_Overbought | **6** | 反转 RSI 带（低值=卖入场） |
| RSI_Oversold | **66** | 买入场 |
| RSI_Target_Buy | 98 | 多单止盈 |
| RSI_Target_Sell | 52 | 空单止盈 |
| BarsToWait | 12 | RSI 反向等待 K 线 |
| LotSize | 0.1 | |
| EnableAdaptive | false | Tester 固定参数 |

**MT5 回测结果（MetaQuotes Demo，$10,000 初始）：**
- 净利润 ≈ **$25,287**
- 盈利因子 **1.38**
- 夏普 **1.30**
- 交易 **1552** 笔

## 文件

| 文件 | 用途 |
|------|------|
| `run_mt5_tester.py` | 启动 MT5 Strategy Tester |
| `XAUUSD_Backtest.set` | 固定参数回测 |
| `XAUUSD_Genetic_Optimization.set` | 遗传优化搜索范围 |
| `XAUUSD_Adaptive.set` | 实盘 adaptive（EnableAdaptive=true） |

## 实盘 adaptive

挂 XAUUSD H1，`EnableAdaptive=true`，每月自动用上月数据选参。  
**Tester 里请关闭 adaptive**，否则每次 OnInit 会跑网格搜索，极慢且干扰优化。
