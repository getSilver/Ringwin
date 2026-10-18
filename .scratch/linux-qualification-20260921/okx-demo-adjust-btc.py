#!/usr/bin/env python3
import base64
import datetime
import hashlib
import hmac
import json
import ssl
import sys
import urllib.request
import urllib.error
from decimal import Decimal


def load_env(path):
    values = {}
    with open(path, "r", encoding="utf-8") as source:
        for line in source:
            line = line.rstrip("\r\n")
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key] = value
    return values


env = load_env("/root/.ringwin/env.local")
base_url = env["OKX_DEMO_REST_BASE_URL"].rstrip("/")
path = "/api/v5/account/demo-adjust-balance"


def request(method, request_path, body=b""):
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    signature = base64.b64encode(hmac.new(
        env["OKX_DEMO_SECRET_KEY"].encode(),
        stamp.encode() + method.encode() + request_path.encode() + body,
        hashlib.sha256,
    ).digest()).decode()
    req = urllib.request.Request(base_url + request_path, data=body or None, method=method, headers={
        "OK-ACCESS-KEY": env["OKX_DEMO_API_KEY"],
        "OK-ACCESS-SIGN": signature,
        "OK-ACCESS-TIMESTAMP": stamp,
        "OK-ACCESS-PASSPHRASE": env["OKX_DEMO_PASSPHRASE"],
        "x-simulated-trading": "1",
        "Content-Type": "application/json",
        "User-Agent": "curl/8.21.0",
    })
    try:
        with urllib.request.urlopen(req, context=ssl.create_default_context(), timeout=10) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        payload = json.load(error)
        raise SystemExit("OKX rejected Demo balance adjustment: " + str(payload.get("code")) + " " + str(payload.get("msg")))


action = sys.argv[1] if len(sys.argv) == 2 else ""
if action == "increase":
    amount = Decimal("0.0001")
    adjustment_type = "increase"
elif action == "reduce-all":
    balance = request("GET", "/api/v5/account/balance?ccy=BTC")
    rows = [item for row in balance.get("data", []) for item in row.get("details", []) if item.get("ccy") == "BTC"]
    amount = sum((Decimal(item.get("cashBal") or "0") for item in rows), Decimal(0))
    if amount <= 0:
        print("demo_btc_adjustment=not_needed")
        raise SystemExit(0)
    if amount > Decimal("0.0001"):
        raise SystemExit("refusing to reduce more BTC than this qualification added")
    adjustment_type = "reduce"
else:
    raise SystemExit("usage: okx-demo-adjust-btc.py increase|reduce-all")

body = json.dumps({
    "type": adjustment_type,
    "adjustments": [{"ccy": "BTC", "amt": format(amount, "f")}],
}, separators=(",", ":")).encode()
result = request("POST", path, body)
if result.get("code") != "0":
    raise SystemExit("OKX rejected Demo balance adjustment: " + str(result.get("code")))
print("demo_btc_adjustment=" + adjustment_type)
