#!/usr/bin/env python3
import base64
import datetime
import hashlib
import hmac
import json
import ssl
import urllib.request
from decimal import Decimal


def load_env(path):
    values = {}
    with open(path, "r", encoding="utf-8") as source:
        for line in source:
            line = line.rstrip("\r\n")
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key] = value
    return values


env = load_env("/root/.ringwin/env.local")
base_url = env["OKX_DEMO_REST_BASE_URL"].rstrip("/")


def get(path):
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    payload = (stamp + "GET" + path).encode()
    signature = base64.b64encode(hmac.new(env["OKX_DEMO_SECRET_KEY"].encode(), payload, hashlib.sha256).digest()).decode()
    request = urllib.request.Request(base_url + path, headers={
        "OK-ACCESS-KEY": env["OKX_DEMO_API_KEY"],
        "OK-ACCESS-SIGN": signature,
        "OK-ACCESS-TIMESTAMP": stamp,
        "OK-ACCESS-PASSPHRASE": env["OKX_DEMO_PASSPHRASE"],
        "x-simulated-trading": "1",
        "User-Agent": "curl/8.21.0",
        "Accept": "application/json",
    })
    with urllib.request.urlopen(request, context=ssl.create_default_context(), timeout=10) as response:
        body = json.load(response)
    if body.get("code") != "0":
        raise RuntimeError("OKX rejected read-only diagnostic")
    return body["data"]


balance_rows = get("/api/v5/account/balance?ccy=BTC,USDT")
details = [detail for row in balance_rows for detail in row.get("details", [])]
btc = [row for row in details if row.get("ccy") == "BTC"]
usdt = [row for row in details if row.get("ccy") == "USDT"]
positions = [row for row in get("/api/v5/account/positions") if Decimal(row.get("pos") or "0") != 0]
pending_orders = get("/api/v5/trade/orders-pending?limit=20")

def amount(row, *names):
    for name in names:
        value = row.get(name)
        if value not in (None, ""):
            return Decimal(value)
    return Decimal(0)


btc_zero = len(btc) <= 1 and all(amount(row, "eq", "cashBal") == 0 for row in btc)
usdt_unique = len(usdt) == 1
usdt_total = amount(usdt[0], "eq", "cashBal") if usdt_unique else Decimal(0)
usdt_available = amount(usdt[0], "availBal", "availEq") if usdt_unique else Decimal(0)
liability_zero = all(amount(row, "liab") == 0 and amount(row, "isoLiab") == 0 and amount(row, "crossLiab") == 0 for row in details)

print("btc_zero=" + str(btc_zero).lower())
print("usdt_unique=" + str(usdt_unique).lower())
print("usdt_total_positive=" + str(usdt_total > 0).lower())
if usdt_unique:
    for field in ("availBal", "availEq", "eq", "frozenBal"):
        print(field + "_present=" + str(usdt[0].get(field) not in (None, "")).lower())
for threshold in (17, 20, 25):
    print(f"usdt_available_ge_{threshold}=" + str(usdt_available >= threshold).lower())
print("usdt_available_lte_total=" + str(usdt_available <= usdt_total).lower())
print("liability_zero=" + str(liability_zero).lower())
print("nonzero_positions=" + str(len(positions)))
print("pending_orders=" + str(len(pending_orders)))

def scale(value):
    if value in (None, ""):
        return -1
    return max(0, -Decimal(value).as_tuple().exponent)

if balance_rows:
    for field in ("totalEq", "adjEq", "imr", "mmr", "mgnRatio", "isoEq"):
        print("account_" + field + "_scale=" + str(scale(balance_rows[0].get(field))))
if usdt_unique:
    for field in ("cashBal", "availBal", "eq", "frozenBal", "liab", "isoLiab", "crossLiab"):
        print("usdt_" + field + "_scale=" + str(scale(usdt[0].get(field))))
