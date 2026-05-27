# United EA Strategy Configuration Summary

## Strategy Symbols and Magic Numbers

### Strategy 1: DarvasBox
- **Symbol**: XAUUSD (Gold/USD)
- **Magic Number**: 135790

### Strategy 2: EMASlopeDistance
- **Symbol**: XAUUSD (Gold/USD)
- **Magic Number**: 12350

### Strategy 3: RSICrossOverReversal
- **Symbol**: XAUUSD (Gold/USD)
- **Magic Number**: 7

### Strategy 4: RSIMidPointHijack
- **Symbol**: XAUUSD (Gold/USD)
- **Magic Numbers**: 
  - RSIFollow: 1001
  - RSIReverse: 1002
  - EMACross: 1003

### Strategy 5: RSI Scalping APPL (Apple)
- **Symbol**: AAPL (Apple stock)
- **Magic Number**: 20001
- **Note**: Changed from "APPL" to "AAPL" (correct ticker symbol)

### Strategy 6: RSI Scalping BTCUSD
- **Symbol**: BTCUSD (Bitcoin/USD)
- **Magic Number**: 123459123

### Strategy 7: RSI Scalping MSFT
- **Symbol**: MSFT (Microsoft stock)
- **Magic Number**: 20002

### Strategy 8: RSI Scalping NVDA
- **Symbol**: NVDA (NVIDIA stock)
- **Magic Number**: 20003

### Strategy 9: RSI Scalping TSLA
- **Symbol**: TSLA (Tesla stock)
- **Magic Number**: 125421321

### Strategy 10: RSI Scalping XAUUSD
- **Symbol**: XAUUSD (Gold/USD)
- **Magic Number**: 129102315

## Important Notes

1. **Stock Symbols**: Stock symbols (AAPL, MSFT, NVDA, TSLA) must be:
   - Added to Market Watch in MetaTrader 5
   - Available from your broker
   - Use the correct ticker symbol (e.g., "AAPL" not "APPL")

2. **Magic Numbers**: All strategies have unique magic numbers to prevent interference:
   - Each strategy can be identified by its magic number
   - RSIMidPointHijack uses 3 magic numbers (one for each sub-strategy)

3. **Symbol Configuration**: Each strategy trades on its own symbol:
   - You can change symbols in the input parameters
   - The EA will log warnings if a symbol is not available
   - Strategies with unavailable symbols will be skipped (EA continues running)

4. **RSI Scalping Strategies**: 
   - Each RSI Scalping variant trades on a different symbol
   - They all use the same strategy logic but with different parameters
   - Buy and sell signals are generated based on RSI levels for each symbol

## Troubleshooting

If stock symbols are not working:
1. Check if the symbol exists in your broker's symbol list
2. Add the symbol to Market Watch in MetaTrader 5
3. Verify the symbol name matches your broker's naming convention
4. Some brokers use prefixes/suffixes (e.g., "NASDAQ:AAPL" or "AAPL.US")
