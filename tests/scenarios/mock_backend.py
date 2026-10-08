#!/usr/bin/env python3
"""A fake Replysis server that plays ONE account situation, so the real Mac app can be run
against it and checked for what the person actually sees. Python port of the Windows
tests/scenarios/mock-backend.mjs (same scenarios, same reasons), because this Mac has no Node.

    python3 mock_backend.py <scenario> <port> [start_delay_seconds]

Loopback only. Logs one line per request:  REQ GET /api/v1/stt/key -> 402 auth=stale
"""
import gzip, json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer as HTTPServer

scenario = sys.argv[1] if len(sys.argv) > 1 else "healthy-credits"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 18081
delay = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
FRESH = "Bearer fresh-token"
key_requests = 0
credit_requests = 0
live_credits = None

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
    # A brand-new Free account: 25 credits, which is 5 answers, once. Answers are charged and
    # refused at zero, as the real server does.
    "new-free-user": dict(credits=25, minutes=30, key=lambda h: (200, {"key": "", "expiresIn": 3600}, {})),
    # The balance request fails twice (a poor connection at launch), then works. The app must say
    # "checking", not "no answers left", and must ask again by itself.
    "credits-flaky": dict(credits=55, minutes=30, key=lambda h: (200, {"key": "", "expiresIn": 3600}, {})),
    # The screen path: /screen-cache keeps pictures and words, /analyze-screen answers in the SAY THIS /
    # DETAIL shape (the part to say first, the code later). MOCK_UPLINK_KBPS slows every request body to that
    # many KB a second, which is how a weak hotspot is imitated on loopback (the real one measured 66).
    # The saved sign-in is old and has to be refreshed before the window can open. The refresh service is not
    # reachable yet (a hotspot still joining) or refuses the saved sign-in. Run with REPLYSIS_TEST_SESSION=aged.
    "token-down":    dict(credits=55, minutes=30, key=lambda h: (200, {"key": "", "expiresIn": 3600}, {})),
    "token-refused": dict(credits=55, minutes=30, key=lambda h: (200, {"key": "", "expiresIn": 3600}, {})),
    # The speech key request answers with a (fake) key, so the real app starts the real speech engine, which
    # then cannot sign in anywhere. Used to watch the engine's life: one at a time, restarted on wake, gone on quit.
    "engine-lab": dict(credits=500, minutes=30, key=lambda h: (200, {"key": "fake-key-for-lifecycle-test", "expiresIn": 3600}, {})),
    "screen-lab": dict(credits=500, minutes=30, key=lambda h: (200, {"key": "", "expiresIn": 3600}, {})),
}
if scenario not in S:
    print("unknown scenario", scenario, list(S), file=sys.stderr); sys.exit(2)
s = S[scenario]


KBPS = float(os.environ.get("MOCK_UPLINK_KBPS") or 0)
stash = {}            # id -> ("picture"|"words", bytes_or_text)
asks = []             # one dict per /analyze-screen, for the test to read back
next_id = 0
lock = threading.Lock()

def read_body(h):
    """The request body, read no faster than the imitated uplink carries it."""
    n = int(h.headers.get("Content-Length") or 0)
    if not n: return b""
    out = _slow_read(h, n)
    # The real server reads a gzip body; so does this one.
    if (h.headers.get("Content-Encoding") or "").lower() == "gzip":
        try: return gzip.decompress(out)
        except Exception: return out
    return out

def _slow_read(h, n):
    if KBPS <= 0: return h.rfile.read(n)
    out = b""
    chunk = 4096
    while len(out) < n:
        piece = h.rfile.read(min(chunk, n - len(out)))
        if not piece: break
        out += piece
        time.sleep(len(piece) / (KBPS * 1024))
    return out

SCREEN_ANSWER_SPOKEN = ["SAY THIS\n", "I ", "would ", "use ", "a ", "hash ", "map ", "to ", "store ", "each ", "number's ", "index, ",
                        "so ", "one ", "pass ", "finds ", "the ", "pair. ", "That ", "gives ", "me ", "linear ", "time. "]
SCREEN_ANSWER_CODE = ["\n\nDETAIL\n```python\n", "def two_sum(nums, target):\n", "    seen = {}\n", "    for i, n in enumerate(nums):\n",
                      "        if target - n in seen:\n", "            return [seen[target - n], i]\n", "        seen[n] = i\n", "```\n\n",
                      "Time: O(n)\n", "Space: O(n)\n\n", "SCREEN NOTES\nLeetCode, Two Sum, Python3 editor, Run and Submit buttons\n"]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def parse_request(self):
        # One line per request with the two labels the app must send to our own server (Windows 1.0.31 item 28).
        ok = super().parse_request()
        if ok:
            print(f"HDR {self.command} {self.path.split('?')[0]} platform={self.headers.get('X-App-Platform')} version={self.headers.get('X-App-Version')}", flush=True)
        return ok
    def _do(self):
        global key_requests, credit_requests, live_credits
        if live_credits is None: live_credits = s["credits"]
        url = self.path.split("?")[0]
        status, body, headers = 200, {}, {}
        if url == "/token":
            if scenario == "token-down": status, body = 503, {"error": "unavailable"}
            elif scenario == "token-refused": status, body = 400, {"error": {"message": "TOKEN_EXPIRED"}}
            else: body = {"id_token": "fresh-token", "refresh_token": "refresh-2", "expires_in": "3600"}
        elif url == "/api/v1/stt/key":
            key_requests += 1; status, body, headers = s["key"](self)
        elif url == "/api/v1/interview/credits":
            credit_requests += 1
            if scenario == "credits-flaky" and credit_requests <= 2:
                status, body = 503, {"error": "temporarily unavailable"}
            else:
                body = {"credits": live_credits, "plan": "free", "isUnlimited": False}
        elif url == "/api/v1/interview/screen-cache" and self.command == "POST":
            raw = read_body(self)
            try: obj = json.loads(raw or b"{}")
            except Exception: obj = {}
            global next_id
            if obj.get("image"):
                with lock: next_id += 1; sid = "img-%d" % next_id; stash[sid] = ("picture", len(obj["image"]))
                status, body = 200, {"imageId": sid}
                print(f"REQ POST {url} -> 200 picture {len(raw)//1024} KB id={sid}", flush=True)
            elif obj.get("text"):
                with lock: next_id += 1; sid = "txt-%d" % next_id; stash[sid] = ("words", obj["text"])
                status, body = 200, {"imageId": sid}
                print(f"REQ POST {url} -> 200 words {len(obj['text'])} chars id={sid}", flush=True)
            else:
                # The line test: a body with no image. The real server answers 400 and keeps nothing.
                status, body = 400, {"error": "image missing"}
                print(f"REQ POST {url} -> 400 line test {len(raw)//1024} KB", flush=True)
        elif url == "/api/v1/interview/analyze-screen" and self.command == "POST":
            t0 = time.time()
            raw = read_body(self)
            try: obj = json.loads(raw or b"{}")
            except Exception: obj = {}
            prompt = obj.get("prompt") or ""
            q = ""
            if "THE QUESTION:" in prompt:
                tail = prompt.split("THE QUESTION:", 1)[1]
                q = tail.split("\n\nAnswer in this shape", 1)[0].strip()
            kinds = []
            ids = obj.get("imageIds") or []
            missing = [i for i in ids if i not in stash]
            for i in ids:
                if i in stash: kinds.append(stash.pop(i)[0])
            if obj.get("image"): kinds.append("inline-picture")
            if obj.get("screenText"): kinds.append("inline-words")
            ask = dict(question=q, has_question_marker="THE QUESTION:" in prompt, ids=ids, kinds=kinds, missing=missing,
                       body_kb=round(len(raw)/1024, 1), words=sum(len(stash_text) for stash_text in [obj.get("screenText") or ""]))
            with lock: asks.append(ask)
            if missing or not kinds:
                print(f"REQ POST {url} -> 400 {ask}", flush=True)
                status, body = 400, {"error": "imageId was unknown, expired, already used, or not yours"}
            elif live_credits < 5:
                status, body = 402, {"error": "No credits remaining"}
            else:
                live_credits -= 5
                print(f"REQ POST {url} -> 200 {ask}", flush=True)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                def chunk(text):
                    self.wfile.write(("data: " + json.dumps({"choices": [{"delta": {"content": text}}]}) + "\n\n").encode()); self.wfile.flush()
                if os.environ.get("MOCK_FIRST_DELAY"): time.sleep(float(os.environ["MOCK_FIRST_DELAY"]))   # a slow model: the app waits and thinks
                # The usage chunk some providers send first: no "choices" at all.
                self.wfile.write(b'data: {"usage":{"prompt_tokens":1}}\n\n'); self.wfile.flush()
                time.sleep(0.12)
                if os.environ.get("MOCK_SCREEN_NEED"):
                    # The problem runs past the bottom of the screen: one sentence, then NEED and what is missing.
                    for w in ["SAY THIS\n", "Let me scroll down and read the constraints before I answer.", "\n\nNEED\n", "The constraints section."]:
                        chunk(w); time.sleep(0.02)
                    self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
                    return
                for w in SCREEN_ANSWER_SPOKEN: chunk(w); time.sleep(0.015)
                time.sleep(0.5)    # the code is written later than the part to say
                for c in SCREEN_ANSWER_CODE: chunk(c); time.sleep(0.03)
                chunk("Let me know if you want me to walk through it. ")
                self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
                return
        elif url == "/__asks":
            body = asks
        elif url == "/api/v1/interview/ask" and self.command == "POST":
            n = int(self.headers.get("Content-Length") or 0)
            if n: self.rfile.read(n)             # the question; compressed or not, it is not needed here
            if live_credits < 5:
                status, body = 402, {"error": "No credits remaining"}
            else:
                live_credits -= 5
                print(f"REQ POST {url} -> 200 (charged 5, {live_credits} left)", flush=True)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                words = ["That", " is", " a", " test", " answer", " from", " the", " fake", " server."]
                # A spoken answer of realistic length, paced like a model: MOCK_ASK_WORDS words, 30 ms apart.
                words += [" word%d" % i for i in range(int(os.environ.get("MOCK_ASK_WORDS") or 0))]
                words += [" Let", " me", " know", " if", " you", " want", " more", " detail."]
                for word in words:
                    self.wfile.write(('data: {"choices":[{"delta":{"content":"%s"}}]}\n\n' % word).encode()); self.wfile.flush()
                    if os.environ.get("MOCK_ASK_WORDS"): time.sleep(0.03)
                self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
                return
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
