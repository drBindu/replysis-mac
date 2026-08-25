#!/usr/bin/env python3
"""
Does the engine still emit everything this app is built to read?

    python3 verify_engine_contract.py

REQUIRES macOS. It runs the real engine against a real FIFO with real audio, and
asserts every line ENGINE_CONTRACT.md says this client depends on. It is the Mac
half; Windows owns tests/verify_engine_contract.py in the Windows repo and asserts
its own. Each half must run on the platform it describes — a Mac assertion that
only ever executes on Windows is a skipped test reading as coverage.

WHY THIS EXISTS. Three times a capability only this client used was missing from
the shared engine and nothing caught it until a live session failed: --sysfifo,
the single-dash argument convention, and the turn-end signal. Each was found by
running the thing; none was visible from the Windows side. The check that would
have caught them was cheaper than the investigation that did — four times now,
counting the probe that could not fail.

Every dependency here is a STRING MATCH on stdout. A rename is invisible at build
time, invisible in review, and produces an app that starts, connects and does
nothing, because every signal it emits says healthy.

The expected strings are extracted from the Swift and from the build script, never
listed here. A hand-written copy is a second spelling that drifts, and drift is the
thing being guarded.
"""
import os, re, subprocess, sys, tempfile, time, wave, hashlib, json, urllib.request

REPO = os.path.dirname(os.path.abspath(__file__))
SWIFT = os.path.join(REPO, "InterviewCopilot/InterviewCopilot/Models/SpeechmaticsEngine.swift")
BUILD_SCRIPT = os.path.join(REPO, "build-engine.sh")
ENGINE = os.path.join(REPO, ".engine-build/dist/speechmatics_engine/speechmatics_engine")

def fail(msg):
    print(f"  FAIL  {msg}")
    return 1

def extract_expected():
    """The strings the app matches on, read from the source that matches them.

    Only lines annotated // CONTRACT:RUNTIME or // CONTRACT:ONFAIL are engine-stdout
    dependencies. Guessing from syntax alone swept up file paths — SystemAudioCapture,
    speechmatics_engine — and reported them as missing engine output, which is a check
    that cries wolf and therefore a check nobody keeps.

    RUNTIME must appear in any normal session. ONFAIL only appears when a session drops,
    so it is verified against the engine source instead: a happy-path run cannot prove a
    failure-path line still exists, and asserting it there would fail every clean run.
    """
    src = open(SWIFT).read()
    runtime, onfail = set(), set()
    # Scan FORWARD past comment lines to the statement. Matching only the immediately
    # following line was position-dependent, and adding an explanatory comment under the
    # marker silently dropped a dependency from the check — the script reported ALL PASS
    # while verifying less than it had a minute earlier. A check that quietly stops
    # checking is worse than no check, because the green result is now evidence of nothing.
    lines = src.splitlines()
    for i, line in enumerate(lines):
        m = re.search(r'// CONTRACT:(RUNTIME|ONFAIL)(?:\("([^"]+)"\))?', line)
        if not m:
            continue
        kind = m.group(1)
        # A marker may declare its string inline when the statement below has none —
        # charCount() parses a number out of the line rather than matching a sentence.
        if m.group(2):
            (runtime if kind == "RUNTIME" else onfail).add(m.group(2))
            continue
        found = False
        for stmt in lines[i + 1:i + 12]:
            t = stmt.strip()
            if not t or t.startswith("//"):
                continue
            for lit in re.findall(r'"([^"]+)"', stmt):
                (runtime if kind == "RUNTIME" else onfail).add(lit)
                found = True
            break
        if not found:
            raise SystemExit(f"CONTRACT marker at line {i+1} has no string literal under it — "
                             f"the annotation and the code it describes have come apart.")
    # The provenance banner is NOT printed by the shared engine — the runtime hook the
    # build script generates prints it, because the shared source must not be edited to
    # stamp it. A contract reading only the engine source would report it missing.
    for m in re.finditer(r'>>> (ENGINE BUILD):', open(BUILD_SCRIPT).read()):
        runtime.add(m.group(1))
    return runtime, onfail

def engine_source():
    """The shared engine source, for checking failure-path lines without forcing a failure."""
    for cand in [os.path.join(REPO, "../replysis-windows/speechmatics_engine.py"),
                 os.path.join(REPO, ".engine-build/speechmatics_engine.py")]:
        if os.path.exists(cand):
            return open(cand).read()
    return None

def speech_fixture(path):
    aiff, wav = path + ".aiff", path + ".wav"
    subprocess.run(["say", "-o", aiff, "Tell me about a time you turned around a project."], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav], check=True)
    w = wave.open(wav, "rb")
    assert w.getnchannels() == 1 and w.getframerate() == 16000 and w.getsampwidth() == 2
    return w.readframes(w.getnframes())

def speech_key():
    # timeout is NOT belt-and-braces here. If the keychain item's ACL does not already
    # trust this binary, `security` blocks on a SecurityAgent dialog forever — and that is
    # the NORMAL state on a fresh machine or after the app is re-signed, which is exactly
    # when this script is worth running. Observed live: hung 8 minutes with no output, no
    # engine, and no way to tell it apart from slow work.
    try:
        blob = subprocess.run(["security", "find-generic-password", "-s",
                               "com.coopilotx.InterviewCopilot.session", "-a", "session", "-w"],
                              capture_output=True, text=True, timeout=20).stdout.strip()
    except subprocess.TimeoutExpired:
        print("  keychain read blocked (SecurityAgent prompt) — click Always Allow, or export "
              "SPEECHMATICS_API_KEY to skip the keychain entirely")
        return None
    if not blob: return None
    tok = json.loads(blob).get("idToken", "")
    req = urllib.request.Request("https://replysis.com/api/v1/stt/key",
                                 headers={"Authorization": "Bearer " + tok})
    try:
        return json.load(urllib.request.urlopen(req, timeout=15)).get("key")
    except Exception:
        return None

def main():
    if sys.platform != "darwin":
        print("SKIP: macOS only. This half asserts the MAC client's dependencies and must "
              "run where a kernel FIFO and CoreAudio exist. Run it before merging any "
              "change to the engine or to how this app reads it.")
        return 0
    if not os.access(ENGINE, os.X_OK):
        return fail("engine not built — run ./build-engine.sh first")

    runtime, onfail = extract_expected()
    print(f"engine contract — {len(runtime)} runtime + {len(onfail)} failure-path strings, "
          f"extracted from the source that reads them\n")

    key = os.environ.get("SPEECHMATICS_API_KEY") or speech_key()
    if not key:
        return fail("no speech key (sign in to the app first, or set SPEECHMATICS_API_KEY)")

    tmp = tempfile.mkdtemp()
    fifo = os.path.join(tmp, "sysaudio.pcm")
    os.mkfifo(fifo)
    env = dict(os.environ, APP_DATA_DIR=tmp, SPEECHMATICS_API_KEY=key)
    log = open(os.path.join(tmp, "engine.log"), "w+")
    # Single-dash options, which is what this app passes.
    proc = subprocess.Popen([ENGINE, "-mode", "system", "-sysfifo", fifo, "-max-delay", "0.7"],
                            stdout=log, stderr=subprocess.STDOUT, env=env)
    try:
        time.sleep(10)
        # A dead engine is the single most important thing this script can report, and until
        # now it was the one thing it could not: opening the FIFO for write BLOCKS until a
        # reader appears, so an engine that exited during startup left this script wedged
        # forever instead of failing. Check it is alive, and say what it said on the way out.
        if proc.poll() is not None:
            log.flush(); log.seek(0)
            tail = "\n".join(log.read().splitlines()[-15:])
            return fail(f"engine exited during startup (rc={proc.returncode}) before any audio "
                        f"was sent. Last output:\n{tail}")
        raw = speech_fixture(os.path.join(tmp, "q"))
        # Non-blocking open with a deadline, for the same reason: never wedge, always report.
        deadline, fd = time.time() + 20, None
        while time.time() < deadline:
            try:
                fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK); break
            except OSError:
                time.sleep(0.25)
        if fd is None:
            return fail("engine never opened the system-audio FIFO for reading — it is running "
                        "but not consuming -sysfifo, so no audio can reach it")
        os.set_blocking(fd, True)
        with os.fdopen(fd, "wb") as f:                    # realtime, then silence to end the turn
            for chunk in [b"\0" * 3200] * 8 + [raw[i:i+3200] for i in range(0, len(raw), 3200)] + [b"\0" * 3200] * 35:
                f.write(chunk); f.flush(); time.sleep(0.1)
        time.sleep(2)
    finally:
        proc.kill()
    log.flush(); log.seek(0)
    out = log.read()

    bad = 0
    for want in sorted(runtime):
        if want in out:
            print(f"  ok    {want}")
        else:
            bad += fail(f"{want}  — the app matches on this and the engine no longer prints it")

    # Failure-path lines: a clean run cannot exercise them, so check the source still has them.
    esrc = engine_source()
    for want in sorted(onfail):
        if esrc is None:
            print(f"  ??    {want}  — engine source not found beside this repo, cannot verify")
        elif want in esrc:
            print(f"  ok    {want}  (failure path, verified in engine source)")
        else:
            bad += fail(f"{want}  — the app matches on this and it is gone from the engine")

    transcript = open(os.path.join(tmp, "latest.txt")).read().strip() if \
        os.path.exists(os.path.join(tmp, "latest.txt")) else ""
    if transcript:
        print(f"  ok    APP_DATA_DIR honoured — transcript written: {transcript[:48]!r}")
    else:
        bad += fail("APP_DATA_DIR — no latest.txt, so the engine wrote where the app never reads")

    print()
    print("ALL PASS" if not bad else f"{bad} FAILURE(S) — do not ship this engine")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
