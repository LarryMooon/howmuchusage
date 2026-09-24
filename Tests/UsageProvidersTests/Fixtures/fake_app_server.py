#!/usr/bin/env python3
"""Minimal stand-in for `codex app-server` used by tests (stdio, JSONL, no "jsonrpc" field)."""
import json
import sys

RATE_LIMITS = {
    "ordinaryUsageAllowed": True,
    "rateLimits": {
        "limitId": "codex",
        "primary": {"usedPercent": 40, "windowDurationMins": 300, "resetsAt": 1790000000},
        "secondary": {"usedPercent": 52, "windowDurationMins": 10080, "resetsAt": 1790400000},
        "credits": None,
        "planType": "pro",
        "rateLimitReachedType": None,
    },
    "rateLimitsByLimitId": None,
    "rateLimitResetCredits": None,
    "accountId": None,
    "rateLimitUpsell": None,
}


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


PUSH = {"method": "account/rateLimits/updated", "params": {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 45, "windowDurationMins": 300, "resetsAt": 1790000000}, "secondary": None, "credits": None, "planType": None}}}
limits_read = False

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    message = json.loads(raw)
    method = message.get("method")
    request_id = message.get("id")
    if request_id is None:
        continue  # notification such as "initialized"
    if method == "initialize":
        send({"id": request_id, "result": {"userAgent": "fake/1.0", "codexHome": "/tmp/codex", "platformFamily": "unix", "platformOs": "macos"}})
    elif method == "account/read":
        if limits_read:
            send(PUSH)  # sparse rolling update arrives between reads
        send({"id": request_id, "result": {"account": {"type": "chatgpt", "email": "me@example.com", "planType": "pro"}, "requiresOpenaiAuth": True}})
    elif method == "account/rateLimits/read":
        send({"id": request_id, "result": RATE_LIMITS})
        limits_read = True
    elif method == "account/login/start":
        send({"id": request_id, "result": {"type": "chatgpt", "loginId": "login-1", "authUrl": "https://auth.example.com/start"}})
        send({"method": "account/login/completed", "params": {"loginId": "login-1", "success": True, "error": None}})
    elif method == "test/serverRequest":
        # Server-initiated request the client must answer with an error.
        send({"id": "srv-1", "method": "item/commandExecution/requestApproval", "params": {}})
        send({"id": request_id, "result": {}})
    elif method == "test/silent":
        pass  # never answers: exercises the client timeout
    elif method == "test/exit":
        sys.exit(3)
    else:
        send({"id": request_id, "error": {"code": -32601, "message": "unknown method " + str(method)}})
