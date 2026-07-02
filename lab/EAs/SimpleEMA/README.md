# SimpleEMA — 练手实验室

双 EMA 金叉/死叉策略，默认货币对 **EURUSD H1**（流动性好、点差低，适合入门优化）。

## 策略逻辑

| 项目 | 规则 |
|------|------|
| 入场 | 快 EMA 上穿/下穿慢 EMA（收盘 K 确认） |
| 出场 | 反向交叉 / ATR 或固定 SL·TP / 最大持仓 K 线数 / 可选 trailing |
| 过滤 | 最大点差、最小 EMA 间距 |

## 文件

| 文件 | 用途 |
|------|------|
| `main.mq5` | MT5 EA（Strategy Tester / 实盘） |
| `SimpleEMA_EURUSD.set` | 默认参数 |
| `SimpleEMA_Genetic_Optimization.set` | 遗传优化范围 |
| `run_mt5_tester.py` | **调 MT5 原生 Strategy Tester**（你要的实时回测） |
| `run_backtest.py` | Python 快速回测（MT5 拉历史 K 线） |
| `run_optimize.py` | Python 随机搜索优化 |
| `trades.csv` | 逐单复盘（Python 回测产出） |

## 1. MT5 原生回测（推荐）

先确保 MT5 已登录，EURUSD H1 历史数据已下载。

```powershell
cd lab\EAs\SimpleEMA

# 单次回测（自动编译 EA → 启动 Strategy Tester → 生成 HTML 报告）
python run_mt5_tester.py backtest

# 可视化模式：看 K 线一根根跑（实时感最强）
python run_mt5_tester.py backtest --visual

# 遗传优化（Optimization=2，用 SimpleEMA_Genetic_Optimization.set）
python run_mt5_tester.py optimize
```

回测完成后：

- HTML 报告路径会打印在终端（通常在 `%APPDATA%\MetaQuotes\Terminal\...\SimpleEMA_EURUSD_backtest.htm`）
- 在 MT5 **结果 → 报告** 里可逐单查看开平仓、滑点、盈亏
- 优化结果在 **Optimization Results** 标签页，右键可 **Set as Input**

## 2. Python 快速迭代（改逻辑 → 立刻看 trades.csv）

```powershell
python run_backtest.py
python run_backtest.py --start 2024-01-01 --fast 10 --slow 30
```

产出：`trades.csv`（每单 side / 开平时间 / 价格 / profit / exit_reason）、`report.png`。

## 4. 多品种组合（20 品种）

### 分品种调参 + 组合（推荐）

```powershell
# 每个品种独立随机搜索，自动剔除 net<=0 / PF<1 的品种，再跑组合回测
python run_optimize_portfolio.py --trials 350

# 仅用已有 portfolio_params.json 重跑组合
python run_optimize_portfolio.py --skip-opt

# 验证组合
python run_portfolio_v5.py
```

产出：`portfolio_params.json`（每品种最优参数 + enabled 标记）、`portfolio_opt_trials/*.csv`、`best_run/portfolio_trades.csv`

### 统一参数（对比用）

```powershell
python run_portfolio_v5.py --shared-params best_params.json
```

| 文件 | 用途 |
|------|------|
| `portfolio_symbols.json` | 20 品种列表 + 各品种最大点差 |
| `portfolio_curated.json` | 全扫描后 net>0 的子集 |
| `run_portfolio_v5.py` | 组合回测，产出 `portfolio_report.json` |
| `main_portfolio.mq5` | MT5 多品种 EA（挂任意图表，监控 SymbolList 内全部品种） |

MT5 组合 EA：

```powershell
python run_mt5_tester.py backtest --ea main_portfolio.mq5 --period M15 --from 2020.01.01 --to 2026.01.01
```

## 3. Python 随机搜索优化

```powershell
python run_optimize.py --trials 500
```

产出：`optimize_trials.csv`、`best_params.json`、`best_run/trades.csv`。

把 `best_params.json` 里的值填回 `.set` 或 `main.mq5` input，再用 `run_mt5_tester.py optimize` 做 MT5 遗传精调。

## 5. MT5 回测（唯一准绳）

**2598 笔是 Python 组合模拟；`SimpleEMA_report.pdf` 只是单品种 EURUSD（~115 笔）。**

组合请以 MT5 为准：

```powershell
# 12 个启用品种各跑一遍 MT5 Strategy Tester（每品种独立 .set）
python run_mt5_portfolio.py --from 2020.01.01 --to 2026.01.01

# 从 MT5 HTML 报告汇总生成正式报告
python generate_mt5_portfolio_report.py
```

产出：
- `best_run/mt5_results.json` — MT5 汇总（交易数、净利）
- `best_run/mt5_reports/*.htm` — 各品种 MT5 原生报告（逐单复盘）
- `best_run/MT5_PORTFOLIO_REPORT.md` — 组合说明
- `best_run/SimpleEMA_report.png` — 由 MT5 数据生成的组合图

Python `portfolio_trades.csv` / `run_portfolio_v5.py` 仅用于快速迭代参数，**不作最终成绩**。

```
改 main.mq5 逻辑
    ↓
python run_backtest.py          ← 秒级验证 + trades.csv 逐单复盘
    ↓
python run_optimize.py          ← 粗搜参数空间
    ↓
python run_mt5_tester.py optimize  ← MT5 遗传优化确认
    ↓
python run_mt5_tester.py backtest --visual  ← 目视检查
```

## 手动在 MT5 里操作

1. 把 `main.mq5` 复制到 `MQL5/Experts/` 或用 MetaEditor 打开编译
2. Strategy Tester：Expert = `SimpleEMA`，Symbol = `EURUSD`，Period = `H1`
3. Inputs → Load → `SimpleEMA_EURUSD.set`
4. 优化时 Load → `SimpleEMA_Genetic_Optimization.set`，Optimization = **Genetic**
