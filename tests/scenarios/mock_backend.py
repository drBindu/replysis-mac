#!/usr/bin/env python3
"""A fake Replysis server that plays ONE account situation, so the real Mac app can be run
against it and checked for what the person actually sees. Python port of the Windows
tests/scenarios/mock-backend.mjs (same scenarios, same reasons), because this Mac has no Node.

    python3 mock_backend.py <scenario> <port> [start_delay_seconds]

Loopback only. Logs one line per request:  REQ GET /api/v1/stt/key -> 402 auth=stale
"""
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

scenario = sys.argv[1] if len(sys.argv) > 1 else "healthy-credits"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 18081
delay = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
FRESH = "Bearer fresh-token"
key_requests = 0
credit_requests = 0

def woke(h):   # a stale token is refused; a fresh one gets a real answer (fair use)
    return (402, {"error": "fair use", "reason": "audio-limit"}, {}) if h.headers.get("Authorization") == FRESH \
        else (401, {"error": "Invalid or missing token"}, {})

S = {
    "wake-token-rejected": dict(credits=55, minutes=0, key=woke),
    "wake-token-expired":  dict(credits=55, minutes=0, key=woke),
    "no-listening": dict(credits=55, minutes=0,  key=lambda h: (402, {"error": "fair use", "reason": "audio-limit"}, {})),
    "no-credits":   dict(credits=0,  minutes=30, key=lambda h: (402, {"error": "No credits remaining"}, {})),
    "signed-out":   dict(credits=55, minutes=30, key=lambda h: (401, {"error": "Invalid or missing token"}, {})),
    "service-down": dict(credits=55, minutes=30, key=lambda h: (503, {"error": "Speech service not configured on server"}, {})),
    "provider-busy":dict(credits=55, minutes=30, key=lambda h: (502, {"error": "Speechmatics rejected the mint"}, {})),
    "rate-limited": dict(credits=55, minutes=30, key=lambda h: (429, {"error": "Too many token requests."}, {"Retry-After": "60"})),
    "refused-then-rate-limited": dict(credits=55, minutes=0,
        key=lambda h: (402, {"error": "fair use", "reason": "audio-limit"}, {}) if key_requests == 1
        else (429, {"error": "Too many"}, {"Retry-After": "15"})),
    "healthy-credits": dict(credits=55, minutes=30, key=lambda h: (200, {"key": "", "expiresIn": 3600}, {})),
    # The balance request fails twice (a poor connection at launch), then works. The app must say
    # "checking", not "no answers left", and must ask again by itself.
    "credits-flaky": dict(credits=55, minutes=30, key=lambda h: (200, {"key": "", "expiresIn": 3600}, {})),
}
if scenario not in S:
    print("unknown scenario", scenario, list(S), file=sys.stderr); sys.exit(2)
s = S[scenario]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _do(self):
        global key_requests, credit_requests
        url = self.path.split("?")[0]
        status, body, headers = 200, {}, {}
        if url == "/token":
            body = {"id_token": "fresh-token", "refresh_token": "refresh-2", "expires_in": "3600"}
        elif url == "/api/v1/stt/key":
            key_requests += 1; status, body, headers = s["key"](self)
        elif url == "/api/v1/interview/credits":
            credit_requests += 1
            if scenario == "credits-flaky" and credit_requests <= 2:
                status, body = 503, {"error": "temporarily unavailable"}
            else:
                body = {"credits": s["credits"], "plan": "free", "isUnlimited": False}
        elif url == "/api/v1/usage/listening":
            body = {"remainingMinutes": s["minutes"], "usedMinutes": 15 - s["minutes"]}
        elif url == "/health":
            body = {"ok": True}
        extra = (" auth=" + ("fresh" if self.headers.get("Authorization") == FRESH else "stale/none")) if url == "/api/v1/stt/key" else ""
        print(f"REQ {self.command} {url} -> {status}{extra}", flush=True)
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        for k, v in headers.items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    do_GET = do_POST = do_HEAD = _do

if delay > 0:
    time.sleep(delay)   # "network late": nothing is listening for the first N seconds
print(f"READY {scenario} on {port}", flush=True)
HTTPServer(("127.0.0.1", port), H).serve_forever()
