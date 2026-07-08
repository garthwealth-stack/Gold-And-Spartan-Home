"""
alerts.py — optional Telegram alerts. No-op if token not set.
"""
import urllib.request
import urllib.parse
import config


def send(msg: str):
    token = config.TELEGRAM_BOT_TOKEN.strip()
    chat = config.TELEGRAM_CHAT_ID.strip()
    if not token or not chat:
        return False
    try:
        url = f"https://api.telegram.org/bot{token}/sendMessage"
        data = urllib.parse.urlencode({"chat_id": chat, "text": msg}).encode()
        urllib.request.urlopen(url, data=data, timeout=10)
        return True
    except Exception as e:
        print("Telegram alert failed:", e)
        return False
