#!/usr/bin/env python3
"""A watched run of the REAL Mac app against the REAL server: spoken questions played out loud, a few things going wrong on
purpose, and a table of what happened. Developer builds only (it drives the app through its flow file).

    soak.py <path-to-signed-dev-app> [--quick]

What it does, in order:
  1. Sets the saved mode to Auto (the original settings are put back at the end), opens the app, starts an interview.
  2. Speaks 16 questions out loud with `say` (the app hears them through the system audio, as it hears an interviewer),
     14 s apart: small talk ("Hello. What's up?"), a question with a 2 s pause in the middle, a second question 5 s after
     the first, and ordinary interview questions.
  3. Kills the speech engine (it must come back by itself and keep answering).
  4. Turns Wi-Fi off for 30 s and on again (no false "cannot reach the speech service" banner afterwards, speech back, next
     question answered). Wi-Fi is switched back on by a trap whatever happens.
  5. Opens a coding problem picture in Preview and asks "Can you solve this problem on my screen?".
Everything goes to ~/replysis-soak/soak.csv and a short summary at the end.
"""
import csv, json, os, re, signal, statistics, subprocess, sys, time, shutil
from datetime import datetime

APP = os.path.expanduser(sys.argv[1]) if len(sys.argv) > 1 else os.path.expanduser("~/Desktop/Replysis-dev.app")
QUICK = "--quick" in sys.argv
HOME = os.path.expanduser("~")
LOG = f"{HOME}/Library/Logs/InterviewCopilot-debug.log"
DATA = f"{HOME}/Library/Application Support/InterviewCopilot"
SETTINGS = f"{DATA}/settings.json"
OUT = f"{HOME}/replysis-soak"
os.makedirs(OUT, exist_ok=True)
CSV = f"{OUT}/soak.csv"
SHOT = "/tmp/glass/lab/screen.png"

def now(): return datetime.now()
def say_(msg): print(f"[{now():%H:%M:%S}] {msg}", flush=True)

def log_lines(since):
    with open(LOG, errors="ignore") as f: return f.read().split("\n")[since:]
def log_len():
    with open(LOG, errors="ignore") as f: return len(f.read().split("\n"))
def stamp(line):
    m = re.match(r"\[(\d\d):(\d\d):(\d\d)\.(\d\d\d)\]", line)
    if not m: return None
    h, mi, s, ms = map(int, m.groups())
    t = now().replace(hour=h, minute=mi, second=s, microsecond=ms * 1000)
    return t.timestamp()
def cmd(action):
    with open(f"{DATA}/flow.cmd", "a") as f: f.write(action + "\n")

def pid_of_app():
    out = subprocess.run(["pgrep", "-f", f"{APP}/Contents/MacOS/InterviewCopilot"], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None
def engines(pid):
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout.split("\n")
    return [int(l.split()[0]) for l in out if l.strip() and "speechmatics_engine" in l and int(l.split()[1]) == pid]
def rss_mb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return round(int(out) / 1024) if out else 0

def snapshot_state():
    """Asks the app where it is (how many answers it holds and what the newest begins with)."""
    mark = log_len(); cmd("dump")
    for _ in range(12):
        time.sleep(0.4)
        for l in log_lines(mark):
            if "FLOWSTATE:" in l:
                h = re.search(r"history=(\d+)", l); a = re.search(r"answer='([^']*)'", l)
                return (int(h.group(1)) if h else 0), (a.group(1) if a else "")
    return None, ""

def wait_for(pattern, since, timeout):
    end = time.time() + timeout
    rx = re.compile(pattern)
    while time.time() < end:
        for l in log_lines(since):
            if rx.search(l): return l
        time.sleep(0.4)
    return None

rows = []
def record(kind, question, answered, first_after_speech_ms, first_mine_ms, detail, pid):
    rows.append(dict(time=f"{now():%H:%M:%S}", kind=kind, question=question, answered="yes" if answered else "no",
                     first_word_ms_app=first_after_speech_ms, first_word_ms_measured=first_mine_ms,
                     memory_mb=rss_mb(pid) if pid else 0, engines=len(engines(pid)) if pid else 0, detail=detail))
    with open(CSV, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)

def speak(text):
    subprocess.run(["say", "-r", "170", text])
    return time.time()

def ask_and_measure(question, pid, kind="question", wait=28, note=""):
    base, _ = snapshot_state()
    mark = log_len()
    spoke_at = speak(question)
    first_app = first_mine = None
    first_line = None
    got = None; prefix = ""
    end = time.time() + wait
    while time.time() < end:
        for l in log_lines(mark):
            if ("LATENCY: first token" in l or "LATENCY: screen first word" in l) and first_line is None:
                first_line = l
                m = re.search(r"([\d.]+)s after they stopped speaking", l)
                if m: first_app = round(float(m.group(1)) * 1000)
                t = stamp(l)
                if t: first_mine = round((t - spoke_at) * 1000)
        h, prefix = snapshot_state()
        if h is not None and base is not None and h > base: got = h; break
        time.sleep(1.0)
    answered = got is not None
    if answered and first_mine is None:
        first_mine = round((time.time() - spoke_at) * 1000)   # a short canned line: no model request to time
        note = (note + " canned line, no model request").strip()
    record(kind, question, answered, first_app, first_mine, (note + f" | answer begins: {prefix[:50]}").strip(" |"), pid)
    say_(f"{'ANSWERED' if answered else 'NO ANSWER'}  first word {first_app} ms after speech (measured {first_mine} ms)  | {question[:56]}  -> {prefix[:40]}")
    return answered, 1 if answered else 0, first_app

def wifi(on):
    subprocess.run(["networksetup", "-setairportpower", "en0", "on" if on else "off"], capture_output=True)

def restore():
    wifi(True)
    try: shutil.copy(f"{OUT}/settings.before.json", SETTINGS)
    except Exception: pass
    subprocess.run(["osascript", "-e", 'tell application id "com.bindualekhya.InterviewCopilot" to quit'], capture_output=True)

def main():
    signal.signal(signal.SIGTERM, lambda *a: (restore(), sys.exit(1)))
    existing = glob_crash()
    shutil.copy(SETTINGS, f"{OUT}/settings.before.json")
    s = json.load(open(SETTINGS)); s["listeningMode"] = "auto"; json.dump(s, open(SETTINGS, "w"))
    subprocess.run(["osascript", "-e", 'tell application id "com.bindualekhya.InterviewCopilot" to quit'], capture_output=True); time.sleep(2)
    mark = log_len()
    subprocess.Popen(["open", "-n", "--env", "REPLYSIS_FLOW_SCRIPT=watch", APP])
    say_("launched; waiting for speech to come online")
    if not wait_for(r"STATUS: ONLINE", mark, 60):
        say_("the speech engine never came online in 60 s"); restore(); sys.exit(2)
    pid = pid_of_app(); say_(f"app pid {pid}, memory {rss_mb(pid)} MB, engines {len(engines(pid))}")
    start_mem = rss_mb(pid)
    cmd("start"); time.sleep(14)

    questions = [
        ("Tell me about yourself.", ""),
        ("What is the difference between a process and a thread?", ""),
        ("Hello. What's up?", "small talk: must get the short friendly line, never a lecture"),
        ("Can you explain how a hash map handles collisions?", ""),
    ]
    for q, note in questions:
        ask_and_measure(q, pid, note=note); time.sleep(8 if not QUICK else 2)

    # One question with a 2 s pause in the middle.
    base, _ = snapshot_state()
    spoke_at = speak("Can you tell me how you would monitor a service in production"); time.sleep(2.0)
    speak("and what alerts you would set up?")
    time.sleep(32)
    h, _ = snapshot_state()
    ans = (h - base) if (h is not None and base is not None) else 0
    record("pause in the middle", "monitor a service ... [2 s] ... and what alerts you would set up", ans >= 1, None, None, f"{ans} answer(s)", pid)
    say_(f"pause in the middle: {ans} answer(s)")
    time.sleep(8 if not QUICK else 2)

    # A second question 5 s after the first.
    base, _ = snapshot_state()
    speak("What is a deadlock?"); time.sleep(5.0)
    speak("What is a race condition?")
    time.sleep(28)
    h, _ = snapshot_state()
    ans = (h - base) if (h is not None and base is not None) else 0
    record("second question 5 s later", "What is a deadlock? ... [5 s] ... What is a race condition?", ans >= 2, None, None, f"{ans} answer(s), wanted 2", pid)
    say_(f"two questions 5 s apart: {ans} answer(s)")
    time.sleep(6)

    more = ["How would you design a rate limiter?", "Why do you want this role?", "What is dependency injection?",
            "Explain the difference between REST and GraphQL.", "What is your biggest weakness?",
            "How do you handle conflict on a team?", "What is eventual consistency?"]
    for q in more:
        ask_and_measure(q, pid); time.sleep(10 if not QUICK else 2)

    # Chaos 1: kill the speech engine.
    say_("CHAOS 1: killing the speech engine")
    mark = log_len(); t0 = time.time()
    subprocess.run(["pkill", "-9", "-f", f"{APP}/Contents/Resources/speechmatics_engine"])
    back = wait_for(r"STATUS: ONLINE", mark, 40)
    secs = round(time.time() - t0, 1)
    record("engine killed", "(the speech engine was killed)", bool(back), None, None, f"back online in {secs} s; engines now {len(engines(pid))}", pid)
    say_(f"engine back online after {secs} s" if back else "ENGINE DID NOT COME BACK")
    time.sleep(3)
    ask_and_measure("What is a message queue used for?", pid, kind="after the engine was killed")
    time.sleep(8)

    # Chaos 2: Wi-Fi off 30 s.
    say_("CHAOS 2: Wi-Fi off for 30 s")
    mark = log_len(); wifi(False); time.sleep(30); wifi(True); t_on = time.time()
    for _ in range(40):
        r = subprocess.run(["curl", "-s", "-m", "3", "-o", "/dev/null", "-w", "%{http_code}", "https://replysis.com/api/v1/health/ready"], capture_output=True, text=True).stdout
        if r.startswith("2") or r.startswith("4") or r.startswith("5"): break
        time.sleep(1)
    net_back = round(time.time() - t_on, 1)
    online = wait_for(r"STATUS: ONLINE", mark, 40)
    speech_back = round(time.time() - t_on, 1)
    lines = log_lines(mark)
    banners = [re.sub(r"^\[[\d:.]+\] ", "", l)[:90] for l in lines if "Problem shown to the user" in l]
    false_banner = any("noSpeechService" in b for b in banners)
    record("Wi-Fi off 30 s", "(the network was off for 30 s)", bool(online) and not false_banner, None, None,
           f"network back {net_back} s, speech back {speech_back} s after Wi-Fi on; notices: {banners or 'none'}", pid)
    say_(f"network back after {net_back} s, speech back after {speech_back} s, notices: {banners or 'none'}")
    time.sleep(4)
    ask_and_measure("How do you test a REST API?", pid, kind="after the network came back")
    time.sleep(8)

    # The screen question, with a coding problem open.
    if os.path.exists(SHOT):
        say_("SCREEN: opening a coding problem in Preview")
        subprocess.run(["open", "-a", "Preview", SHOT]); time.sleep(4)
        ask_and_measure("Can you solve this problem on my screen?", pid, kind="screen", wait=40)
        time.sleep(4)
        subprocess.run(["osascript", "-e", 'tell application "Preview" to close every window'], capture_output=True)

    time.sleep(3)
    end_mem = rss_mb(pid)
    alive = pid_of_app() == pid
    crashes = [c for c in glob_crash() if c not in existing]
    first_words = [r["first_word_ms_app"] for r in rows if isinstance(r["first_word_ms_app"], int)]
    asked = [r for r in rows if r["kind"] in ("question", "after the engine was killed", "after the network came back", "screen")]
    answered = [r for r in asked if r["answered"] == "yes"]
    maxeng = max([r["engines"] for r in rows] or [0])
    summary = (f"questions asked {len(asked)}, answered {len(answered)}; first word median {int(statistics.median(first_words)) if first_words else 'n/a'} ms, "
               f"worst {max(first_words) if first_words else 'n/a'} ms; app alive {alive}; new crash reports {crashes or 'none'}; "
               f"memory {start_mem} to {end_mem} MB; most speech engines at once {maxeng}")
    say_("SUMMARY: " + summary)
    open(f"{OUT}/summary.txt", "w").write(summary + "\n")
    cmd("back"); time.sleep(3)
    restore()
    say_("settings put back, app closed, Wi-Fi on")

def glob_crash():
    d = f"{HOME}/Library/Logs/DiagnosticReports"
    try: return [f for f in os.listdir(d) if "InterviewCopilot" in f]
    except Exception: return []

try:
    main()
finally:
    wifi(True)
