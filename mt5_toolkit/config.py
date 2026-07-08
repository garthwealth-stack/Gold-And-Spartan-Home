"""
config.py — central settings for the MT5 toolkit.
Edit this file, then run monitor.py or executor.py.

SAFETY: everything defaults to READ-ONLY / MONITOR. You must explicitly set
LIVE_EXECUTE = True to let the executor place real orders.
"""

# ----------------------------------------------------------------------
# MT5 connection
# ----------------------------------------------------------------------
# Leave LOGIN/PASSWORD/SERVER as None to attach to the terminal that is
# already open and logged in (recommended). Fill them only if you want the
# script to log in itself.
MT5_LOGIN     = None          # e.g. 123456789  (your Exness account number)
MT5_PASSWORD  = None          # e.g. "your_password"
MT5_SERVER    = None          # e.g. "Exness-MT5Real8"
MT5_PATH      = None          # e.g. r"C:\Program Files\MetaTrader 5\terminal64.exe"

# ----------------------------------------------------------------------
# Instruments & EA magic numbers  (match your .set files)
# ----------------------------------------------------------------------
GOLD_SYMBOL    = "XAUUSDm"
BTC_SYMBOL     = "BTCUSDm"

GOLD_MAGIC     = 990045       # set InpMagicNumber in AdaptiveGoldEngine to this
SPARTAN_MAGIC  = 793030       # SpartanFade aggressive uses 793031; conservative 793030

# ----------------------------------------------------------------------
# Account / risk
# ----------------------------------------------------------------------
ACCOUNT_START_BALANCE = 1500.0

# Portfolio guardrails (enforced by BOTH monitor alerts and executor)
MAX_ACCOUNT_DRAWDOWN_PCT = 25.0   # kill-switch: stop executing if equity drops this % from peak
MAX_OPEN_POSITIONS       = 4      # hard ceiling on concurrent EA positions
DAILY_LOSS_LIMIT_USD     = 60.0   # stop opening new trades once daily realised loss hits this

# ----------------------------------------------------------------------
# Execution mode  (executor.py only)
# ----------------------------------------------------------------------
LIVE_EXECUTE = False    # <<< MUST be True to place real orders. Default = dry-run.
BROKER_GMT_OFFSET = 0   # Exness = 0

# Per-strategy risk (percent of current balance risked at the stop)
GOLD_RISK_PCT    = 1.0
SPARTAN_RISK_PCT = 2.5

# ----------------------------------------------------------------------
# Alerts (optional — leave token blank to disable Telegram)
# ----------------------------------------------------------------------
TELEGRAM_BOT_TOKEN = ""       # from @BotFather
TELEGRAM_CHAT_ID   = ""       # your chat id (get from @userinfobot)

# ----------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------
LOG_DIR = "logs"
POLL_SECONDS = 30             # how often monitor refreshes
