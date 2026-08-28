#!/usr/bin/env python3
"""Hold the Speechmatics account at its concurrent-session limit, on purpose.

Written so both platforms can WATCH their concurrency gate refuse a start, instead
of verifying it by construction and calling it done. Mac's gate and Windows' quota
path are each correct by inspection and neither has been seen to fire — which is
the same shape as the deafness detector and MAC_CATCHUP section 9, twice agreed to
be not enough.

    export SPEECHMATICS_API_KEY=<a freshly minted token>
    python3 tools/fill_quota.py

It decodes connection_quota from the token's own claims (the technique that found
the ceiling in the first place, when the portal was not available) and opens
exactly that many sessions — no more, so it cannot make the account worse than
full, and no fewer, so the next start is guaranteed to be refused.

While it holds, start the app. The expected result:

    Mac      SM start refused: account is at its concurrent-session limit ...
    Windows  ANOTHER DEVICE IS USING YOUR ACCOUNT

Ctrl-C releases every session cleanly — close, not kill. A killed session leaves
the slot reserved server-side until it times out, which is the leak both platforms
spent a day chasing, and this script must not reproduce it while testing for it.
"""
import asyncio, base64, json, os, sys, signal

try:
    import websockets
except ImportError:
    sys.exit("needs `websockets`:  pip install websockets")

URL = "wss://eu.rt.speechmatics.com/v2"

def claims(token: str) -> dict:
    """Decode the JWT payload. No signature check — we are reading, not trusting."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)          # restore stripped padding
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return {}

START = {
    "message": "StartRecognition",
    "audio_format": {"type": "raw", "encoding": "pcm_s16le", "sample_rate": 16000},
    "transcription_config": {"language": "en", "enable_partials": True},
}

async def hold(token: str, n: int, ready: asyncio.Event):
    """Open n sessions and keep them alive until cancelled."""
    async def one(i: int):
        async with websockets.connect(f"{URL}?jwt={token}", ping_interval=20) as ws:
            await ws.send(json.dumps(START))
            while True:
                msg = json.loads(await ws.recv())
                if msg.get("message") == "RecognitionStarted":
                    print(f"  session {i+1}/{n}: HOLDING", flush=True)
                    break
                if msg.get("message") == "Error":
                    print(f"  session {i+1}/{n}: REFUSED — {msg.get('reason')}", flush=True)
                    return
            # Silence keeps the session open without spending transcription.
            while True:
                await ws.send(b"\x00" * 3200)
                await asyncio.sleep(0.1)

    tasks = [asyncio.create_task(one(i)) for i in range(n)]
    await asyncio.sleep(2)
    ready.set()
    await asyncio.gather(*tasks, return_exceptions=True)

async def main():
    token = os.environ.get("SPEECHMATICS_API_KEY", "").strip()
    if not token:
        sys.exit("set SPEECHMATICS_API_KEY to a freshly minted token first")

    c = claims(token)
    quota = c.get("connection_quota")
    print(f"account_type={c.get('account_type', '?')}  connection_quota={quota}")
    if not isinstance(quota, int) or quota < 1:
        sys.exit("no connection_quota in the token's claims — cannot size the test safely")
    print(f"opening {quota} sessions to fill the account exactly\n")

    ready = asyncio.Event()
    task = asyncio.create_task(hold(token, quota, ready))
    await ready.wait()
    print(f"\nAccount is full. START THE APP NOW — its next session must be refused.")
    print("Ctrl-C here to release the sessions cleanly.\n")
    try:
        await task
    except asyncio.CancelledError:
        pass

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nreleasing sessions (closed, not killed)")
