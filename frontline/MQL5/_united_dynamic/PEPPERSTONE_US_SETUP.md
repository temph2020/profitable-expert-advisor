# Pepperstone US - Symbol Setup Guide

## Finding Correct Symbol Names in MetaTrader 5

### Step-by-Step Instructions:

1. **Open Market Watch Window**
   - Press `Ctrl+M` or go to `View > Market Watch`

2. **Show All Symbols**
   - Right-click in the Market Watch window
   - Select `Show All` or `Symbols`
   - This shows all available symbols from your broker

3. **Search for Your Symbols**
   - Use the search box in the Market Watch window
   - Search for: "AAPL", "MSFT", "NVDA", "TSLA", "BTCUSD", "XAUUSD"

4. **Note the Exact Symbol Name**
   - The symbol name shown in Market Watch is what you need to use
   - Common formats for Pepperstone US:
     - Stocks: `AAPL.US`, `MSFT.US`, `NVDA.US`, `TSLA.US`
     - Or: `NASDAQ:AAPL`, `NASDAQ:MSFT`, etc.
     - Or: Just `AAPL`, `MSFT`, etc. (if available)

5. **Add to Market Watch**
   - Double-click the symbol to add it to your Market Watch
   - Or right-click and select `Show`

6. **Update EA Inputs**
   - Open the EA inputs in MetaTrader 5
   - Update each symbol parameter with the exact name from Market Watch

## Common Pepperstone US Symbol Formats

### US Stocks:
- **Apple**: `AAPL.US` or `NASDAQ:AAPL` or `AAPL`
- **Microsoft**: `MSFT.US` or `NASDAQ:MSFT` or `MSFT`
- **NVIDIA**: `NVDA.US` or `NASDAQ:NVDA` or `NVDA`
- **Tesla**: `TSLA.US` or `NASDAQ:TSLA` or `TSLA`

### Cryptocurrencies:
- **Bitcoin**: `BTCUSD` or `BTC/USD` or `BTCUSD.c`

### Precious Metals:
- **Gold**: `XAUUSD` or `GOLD` or `XAU/USD`

## Important Notes:

1. **Symbol Names are Case-Sensitive**: Use exact capitalization
2. **Add Symbols to Market Watch**: Symbols must be in Market Watch for the EA to access them
3. **Check Trading Hours**: US stocks trade during US market hours (9:30 AM - 4:00 PM ET)
4. **CFD vs Stock**: Pepperstone offers CFDs on stocks, not actual stocks
5. **Spread**: Check the spread for each symbol - some may have wider spreads

## Troubleshooting:

### If Symbol Not Found:
1. Check if you're connected to Pepperstone US server
2. Verify your account type supports the symbol
3. Contact Pepperstone support for symbol availability
4. Check if symbol requires special account permissions

### If EA Shows "Symbol Not Available":
1. Make sure symbol is added to Market Watch
2. Verify symbol name matches exactly (including dots, colons, etc.)
3. Check broker connection status
4. Try different symbol format variations

## Testing Symbols:

You can test if a symbol works by:
1. Opening a chart with that symbol
2. If chart opens successfully, the symbol name is correct
3. Use that exact symbol name in the EA inputs
