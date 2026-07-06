import os
import sys
import time
import argparse
import asyncio
import pyaudio
import wave
import threading
import ssl
import tempfile
import subprocess
import numpy as np

# ── Startup diagnostics ──────────────────────────────────────────────────────
print("", flush=True)
print("=" * 55, flush=True)
print("   SPEECHMATICS ENGINE STARTUP", flush=True)
print(f"   Python : {sys.executable}", flush=True)
print(f"   Version: {sys.version.split()[0]}", flush=True)
print(f"   pyaudio: {pyaudio.__version__}", flush=True)
print("=" * 55, flush=True)


def test_microphone():
    print("", flush=True)
    print("=" * 50, flush=True)
    print("   TESTING MICROPHONE...", flush=True)
    print("=" * 50, flush=True)
    try:
        p_test = pyaudio.PyAudio()
        num_devices = p_test.get_host_api_info_by_index(0).get('deviceCount', 0)
        print(f">>> Audio devices found: {num_devices}", flush=True)
        print(">>> Available INPUT devices:", flush=True)
        for i in range(p_test.get_device_count()):
            info = p_test.get_device_info_by_index(i)
            if info.get('maxInputChannels', 0) > 0:
                print(f"    [{i}] {info['name']} (rate={int(info['defaultSampleRate'])})", flush=True)
        default_input = p_test.get_default_input_device_info()
        print(f">>> Default input: {default_input['name']} (index {default_input['index']})", flush=True)
        test_stream = p_test.open(
            format=pyaudio.paInt16, channels=1, rate=16000,
            input=True, frames_per_buffer=4096
        )
        has_audio = False
        for _ in range(10):
            data = test_stream.read(4096, exception_on_overflow=False)
            max_val = max(
                abs(int.from_bytes(data[j:j+2], byteorder='little', signed=True))
                for j in range(0, min(len(data), 200), 2)
            )
            if max_val > 500:
                has_audio = True
        test_stream.stop_stream()
        test_stream.close()
        p_test.terminate()
        status = "Audio signal detected!" if has_audio else "Silent - hardware OK"
        print(f">>> MIC TEST: PASSED - {status}", flush=True)
        print("=" * 50, flush=True)
        return True
    except Exception as e:
        print(f">>> MIC TEST: FAILED - {e}", flush=True)
        print("    Fix: System Settings > Privacy > Microphone - allow app access", flush=True)
        print("=" * 50, flush=True)
        return False


def find_blackhole_device(p):
    for i in range(p.get_device_count()):
        info = p.get_device_info_by_index(i)
        name = info['name'].lower()
        if info.get('maxInputChannels', 0) > 0:
            if 'blackhole' in name or 'black hole' in name:
                print(f">>> BlackHole found: [{i}] {info['name']}", flush=True)
                return i
    print(">>> BlackHole NOT found.", flush=True)
    return None


try:
    from speechmatics.models import ConnectionSettings, TranscriptionConfig, AudioSettings
    from speechmatics.client import WebsocketClient
    import speechmatics
    sm_version = getattr(speechmatics, '__version__', 'unknown')
    print(f">>> speechmatics package: OK (version={sm_version})", flush=True)
except ImportError as e:
    print(f">>> FATAL: speechmatics package missing - {e}", flush=True)
    exit(1)

parser = argparse.ArgumentParser()
parser.add_argument("-key", type=str, default=os.environ.get("SPEECHMATICS_API_KEY", ""))
parser.add_argument("-device", type=int, default=None)
parser.add_argument("-sysdevice", type=int, default=None)
parser.add_argument("-max-delay", type=float, default=1.0)
parser.add_argument("-mode", type=str, default="mic", choices=["mic", "system", "both"])
parser.add_argument("-syscapture", type=str, default=None)
# -sysfifo: path to a FIFO the APP writes system audio to (16 kHz mono s16le).
# Preferred over -syscapture: the app runs the Core Audio tap in-process where the
# audio-recording permission actually applies, so it captures real audio (a separate
# helper process is fed silence by macOS).
parser.add_argument("-sysfifo", type=str, default=None)
args = parser.parse_args()

if not args.key:
    print(">>> FATAL: No Speechmatics API key. Pass -key or set SPEECHMATICS_API_KEY env var.", flush=True)
    exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# BUG-11 FIX: use APP_DATA_DIR env var (set by SpeechmaticsEngine.swift) so Swift and
# Python always agree on the data folder, even in sandboxed or non-standard HOME layouts.
APP_DATA = os.environ.get("APP_DATA_DIR", os.path.join(
    os.environ.get("HOME", tempfile.gettempdir()),
    "Library", "Application Support", "InterviewCopilot"
))
os.makedirs(APP_DATA, exist_ok=True)

LATEST_FILE    = os.path.join(APP_DATA, "latest.txt")
PAUSE_FLAG     = os.path.join(APP_DATA, "pause.flag")
RESET_FLAG     = os.path.join(APP_DATA, "reset.flag")
RECORD_FLAG    = os.path.join(APP_DATA, "record.flag")
RECORDINGS_DIR = APP_DATA

print(f">>> Script folder : {SCRIPT_DIR}", flush=True)
print(f">>> Data folder   : {APP_DATA}", flush=True)
print(f">>> API key       : {args.key[:8]}...", flush=True)
print(f">>> Audio mode    : {args.mode}", flush=True)

if args.mode == "mic":
    mic_ok = test_microphone()
    if not mic_ok:
        print(">>> FATAL: Microphone unavailable. Exiting.", flush=True)
        exit(1)

recording_frames = []
is_recording = False
record_lock = threading.Lock()


def save_recording():
    global recording_frames
    with record_lock:
        if not recording_frames:
            return
        frames_to_save = recording_frames[:]
        recording_frames = []
    # BUG-15 FIX: use O_CREAT|O_EXCL to atomically claim the filename — prevents two
    # concurrent save threads picking the same n and truncating each other's file.
    n = 1
    while True:
        filename = os.path.join(RECORDINGS_DIR, f"interview_{n}.wav")
        try:
            fd = os.open(filename, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            os.close(fd)
            break
        except FileExistsError:
            n += 1
    try:
        wf = wave.open(filename, 'wb')
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(16000)
        wf.writeframes(b''.join(frames_to_save))
        wf.close()
        print(f">>> Recording saved: {filename}", flush=True)
    except Exception as ex:
        print(f">>> Save error: {ex}", flush=True)


CHUNK_FRAMES = 1024   # 64 ms per chunk — audio reaches server twice as fast (was 2048/128ms)
SAMPLE_RATE  = 16000
# Maximum SCK buffer size: 2 seconds worth of audio.
# If the engine falls behind, old audio is dropped so we always transcribe fresh speech.
SCK_BUF_MAX  = SAMPLE_RATE * 2 * 2  # 2s × 16000 samples × 2 bytes
SILENCE      = b"\x00" * (CHUNK_FRAMES * 2)

# ── Noise gate — adaptive, with hysteresis ───────────────────────────────────
#
# Three-phase design:
#   1. Calibration  (~1 s): measure ambient RMS, set initial threshold.
#   2. Hysteresis gate: requires N consecutive loud frames to OPEN, holds
#      open for HOLD frames after silence so words don't get chopped.
#   3. Live EMA drift: slowly tracks the noise floor during quiet periods
#      so the gate self-adjusts if the TV gets louder or softer.
#
# Confidence filtering happens on the transcript side (see build_text_from_results).
CONFIDENCE_THRESHOLD = 0.65   # per-word minimum — below this = noise hallucination
SEGMENT_CONF_FLOOR   = 0.50   # reject entire segment if average confidence < this

_noise_calibrating   = True
_noise_cal_samples: list = []
_noise_gate_rms      = 0
_ema_noise_floor     = None   # updated during quiet frames
_NOISE_CAL_CHUNKS    = 20     # ~1.3 s calibration (was 50/~3s) — faster startup
_EMA_ALPHA           = 0.005  # very slow drift — stable but self-correcting

# Hysteresis state
_gate_open           = False
_gate_loud_streak    = 0
_gate_hold_counter   = 0
_GATE_OPEN_STREAK    = 2      # consecutive loud frames needed to open
_GATE_HOLD_FRAMES    = 20     # frames to hold open after going quiet (~400 ms)


def reset_gate_transient_state():
    """BUG-19 FIX: reset per-session hysteresis counters on reconnect so a hold counter
    from a previous session doesn't bleed into the calibration phase of the new one."""
    global _gate_open, _gate_loud_streak, _gate_hold_counter
    _gate_open = False
    _gate_loud_streak = 0
    _gate_hold_counter = 0


def apply_noise_gate(data: bytes) -> bytes:
    global _noise_calibrating, _noise_cal_samples, _noise_gate_rms, _ema_noise_floor
    global _gate_open, _gate_loud_streak, _gate_hold_counter

    arr = np.frombuffer(data, dtype=np.int16).astype(np.float32)
    rms = int(np.sqrt(np.mean(arr ** 2))) if len(arr) > 0 else 0

    # Phase 1 — calibration
    if _noise_calibrating:
        _noise_cal_samples.append(rms)
        if len(_noise_cal_samples) >= _NOISE_CAL_CHUNKS:
            s            = sorted(_noise_cal_samples)
            floor        = s[int(len(s) * 0.50)]          # 50th-percentile (median) ambient
            _ema_noise_floor = float(floor)
            _noise_gate_rms  = max(int(floor * 2.0), 150)
            _noise_gate_rms  = min(_noise_gate_rms, 1000)
            _noise_calibrating = False
            print(f">>> NOISE GATE ready — floor={floor}  threshold={_noise_gate_rms} RMS", flush=True)
        return data

    # Phase 2 — gate with hysteresis
    is_loud = rms >= _noise_gate_rms

    if is_loud:
        _gate_loud_streak  += 1
        _gate_hold_counter  = _GATE_HOLD_FRAMES
        if _gate_loud_streak >= _GATE_OPEN_STREAK:
            _gate_open = True
    else:
        _gate_loud_streak = 0
        # Phase 3 — EMA drift during quiet frames
        if _ema_noise_floor is not None:
            _ema_noise_floor = _EMA_ALPHA * rms + (1.0 - _EMA_ALPHA) * _ema_noise_floor
            updated = max(int(_ema_noise_floor * 2.0), 150)
            _noise_gate_rms = min(updated, 1000)
        if _gate_open:
            if _gate_hold_counter > 0:
                _gate_hold_counter -= 1
            else:
                _gate_open = False

    return data if _gate_open else SILENCE

mic_stream = None
sys_stream = None
p = None

def open_mic(fatal=True):
    """Open the default (or selected) microphone into the global mic_stream.
    Called at startup for mic/both modes, and as a runtime fallback if
    system-audio capture fails — so transcription keeps working (with the
    orange mic indicator) instead of the audio thread crashing on a None
    stream. Returns True on success. No-op if the mic is already open."""
    global p, mic_stream
    if mic_stream is not None:
        return True
    try:
        if p is None:
            p = pyaudio.PyAudio()

        # ── List ALL audio devices so they appear in the debug log ──
        print(">>> ALL AUDIO DEVICES:", flush=True)
        for _i in range(p.get_device_count()):
            _info = p.get_device_info_by_index(_i)
            _in   = _info.get('maxInputChannels',  0)
            _out  = _info.get('maxOutputChannels', 0)
            _rate = int(_info.get('defaultSampleRate', 0))
            _flag = ""
            if _in  > 0: _flag += "IN "
            if _out > 0: _flag += "OUT"
            print(f"    [{_i}] {_info['name']:40s}  {_flag.strip():5s}  {_rate}Hz", flush=True)

        mic_kwargs = dict(
            format=pyaudio.paInt16,
            channels=1,
            rate=SAMPLE_RATE,
            input=True,
            frames_per_buffer=CHUNK_FRAMES,
        )
        if args.device is not None:
            mic_kwargs["input_device_index"] = args.device
            dev_name = p.get_device_info_by_index(args.device)['name']
            print(f">>> MIC device [{args.device}]: {dev_name}", flush=True)
        else:
            default_in = p.get_default_input_device_info()
            print(f">>> MIC: default input device [{default_in['index']}] {default_in['name']}", flush=True)
        mic_stream = p.open(**mic_kwargs)
        print(">>> MIC stream opened OK", flush=True)
        return True
    except Exception as e:
        print(f">>> {'FATAL' if fatal else 'WARNING'}: Cannot open mic stream - {e}", flush=True)
        if fatal:
            exit(1)
        return False

if args.mode == "mic":
    open_mic(fatal=True)
elif args.mode == "both":
    # In both-mode the mic is a best-effort add-on: if it can't open (permission
    # denied, no input device) we keep going with system audio only instead of dying.
    if not open_mic(fatal=False):
        print(">>> BOTH mode: mic unavailable — continuing with SYSTEM audio only", flush=True)
        args.mode = "system"

# BlackHole fallback for system audio (when no SystemAudioCapture binary)
if args.mode == "both" and args.syscapture is None:
    if p is None:
        p = pyaudio.PyAudio()
    sys_device_index = args.sysdevice if args.sysdevice is not None else find_blackhole_device(p)
    if sys_device_index is not None:
        try:
            sys_stream = p.open(
                format=pyaudio.paInt16,
                channels=1,
                rate=SAMPLE_RATE,
                input=True,
                input_device_index=sys_device_index,
                frames_per_buffer=CHUNK_FRAMES,
            )
            sys_name = p.get_device_info_by_index(sys_device_index)['name']
            print(f">>> SYSTEM AUDIO (BlackHole): [{sys_device_index}] {sys_name}", flush=True)
        except Exception as e:
            print(f">>> WARNING: BlackHole stream failed: {e}", flush=True)

# ScreenCaptureKit system audio capture
sys_capture_proc   = None
sys_capture_buffer = bytearray()
sys_capture_lock   = threading.Lock()


def start_sys_fifo():
    """Read system audio (16 kHz mono s16le) from a FIFO the APP writes to.
    The app runs the Core Audio tap in-process, where the audio-recording
    permission the user granted actually applies — so it captures real audio
    (a separate helper process gets fed silence by macOS)."""
    path = args.sysfifo
    print(f">>> SysFIFO: reading system audio from {path}", flush=True)

    def reader():
        bytes_received = 0
        last_log = 0
        while True:
            try:
                # open() blocks until the app opens the FIFO for writing.
                f = open(path, "rb", buffering=0)
            except Exception as e:
                print(f">>> SysFIFO: open failed: {e}", flush=True)
                threading.Event().wait(0.5)
                continue
            print(">>> SysFIFO: connected — app is streaming system audio", flush=True)
            try:
                while True:
                    chunk = f.read(CHUNK_FRAMES * 2)
                    if not chunk:
                        break   # writer closed → reopen
                    with sys_capture_lock:
                        sys_capture_buffer.extend(chunk)
                        if len(sys_capture_buffer) > SCK_BUF_MAX:
                            del sys_capture_buffer[:len(sys_capture_buffer) - SCK_BUF_MAX]
                        buf_size = len(sys_capture_buffer)
                    bytes_received += len(chunk)
                    now = int(bytes_received / 32000)
                    if now != last_log:
                        last_log = now
                        print(f">>> SysFIFO: {now}s captured  buffer={buf_size//32:.0f}ms", flush=True)
            except Exception as e:
                print(f">>> SysFIFO: read error: {e}", flush=True)
            finally:
                try:
                    f.close()
                except Exception:
                    pass
            print(">>> SysFIFO: writer closed — waiting to reconnect", flush=True)

    threading.Thread(target=reader, daemon=True).start()
    return True


def start_sys_capture():
    global sys_capture_proc
    if not args.syscapture or not os.path.exists(args.syscapture):
        print(f">>> WARNING: SystemAudioCapture binary not found at {args.syscapture}", flush=True)
        return False
    try:
        sys_capture_proc = subprocess.Popen(
            [args.syscapture],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0
        )
        print(f">>> ScreenCaptureKit: started PID {sys_capture_proc.pid}", flush=True)

        # Use an Event to signal when the binary confirms it is ready
        ready_event    = threading.Event()
        failed_event   = threading.Event()

        def read_stderr():
            for line in iter(sys_capture_proc.stderr.readline, b''):
                msg = line.decode('utf-8', errors='ignore').strip()
                if not msg:
                    continue
                print(f">>> SysCapture: {msg}", flush=True)
                if "SYSTEM_AUDIO_READY" in msg:
                    ready_event.set()
                if "PERMISSION_DENIED" in msg:
                    print(">>> ERROR: Screen Recording permission needed! Grant it in System Settings → Privacy → Screen Recording", flush=True)
                    failed_event.set()
                if "ERROR:" in msg:
                    failed_event.set()

        threading.Thread(target=read_stderr, daemon=True).start()

        def buffer_audio():
            bytes_received = 0
            last_log = 0
            while sys_capture_proc.poll() is None:
                chunk = sys_capture_proc.stdout.read(CHUNK_FRAMES * 2)
                if chunk:
                    with sys_capture_lock:
                        sys_capture_buffer.extend(chunk)
                        if len(sys_capture_buffer) > SCK_BUF_MAX:
                            excess = len(sys_capture_buffer) - SCK_BUF_MAX
                            del sys_capture_buffer[:excess]
                        # BUG-16 FIX: read buf_size inside the lock — avoids data race
                        buf_size = len(sys_capture_buffer)
                    bytes_received += len(chunk)
                    now = int(bytes_received / 32000)  # log every ~1s of audio
                    if now != last_log:
                        last_log = now
                        print(f">>> SysCapture: {now}s captured  buffer={buf_size//32:.0f}ms", flush=True)
            print(f">>> SysCapture: process exited (code {sys_capture_proc.returncode})", flush=True)
            if not ready_event.is_set():
                failed_event.set()

        threading.Thread(target=buffer_audio, daemon=True).start()

        # Wait up to 6 seconds for SYSTEM_AUDIO_READY (permission prompt can take a few seconds)
        print(">>> ScreenCaptureKit: waiting for SYSTEM_AUDIO_READY (up to 6s)...", flush=True)
        ready = ready_event.wait(timeout=6.0)
        if not ready or failed_event.is_set():
            # Check if process already died
            if sys_capture_proc.poll() is not None:
                print(f">>> ScreenCaptureKit: process died early (code {sys_capture_proc.returncode})", flush=True)
            else:
                print(">>> ScreenCaptureKit: timed out waiting for SYSTEM_AUDIO_READY", flush=True)
                print(">>> Hint: open System Settings → Privacy & Security → Screen Recording and allow this app", flush=True)
                try:
                    sys_capture_proc.kill()
                except Exception:
                    pass
            return False

        print(">>> ScreenCaptureKit: READY — system audio capture active", flush=True)
        return True
    except Exception as e:
        print(f">>> WARNING: Could not start SystemAudioCapture: {e}", flush=True)
        return False


def read_sys_capture_chunk(num_frames):
    """Non-blocking system-audio read (used in BOTH mode, where the blocking mic
    read paces the loop). Returns whatever is buffered, or silence if empty."""
    needed = num_frames * 2
    with sys_capture_lock:
        # If buffer has grown beyond 2 seconds, drop the oldest audio so we
        # always transcribe the freshest speech (prevents growing lag).
        if len(sys_capture_buffer) > SCK_BUF_MAX:
            excess = len(sys_capture_buffer) - SCK_BUF_MAX
            del sys_capture_buffer[:excess]
            print(f">>> SysCapture: buffer trimmed ({excess} bytes dropped to stay real-time)", flush=True)
        if len(sys_capture_buffer) >= needed:
            data = bytes(sys_capture_buffer[:needed])
            del sys_capture_buffer[:needed]
            return data
    return SILENCE


def read_sys_capture_chunk_paced(num_frames):
    """Blocking, real-time-paced system-audio read (used in SYSTEM-only mode).

    CRITICAL: this must never return instantly when the buffer is empty. The
    Speechmatics SDK calls read() in a tight loop — if we return synthetic
    silence immediately, the websocket gets flooded with fabricated silence far
    faster than real time, real captured audio queues behind it, the 2s cap
    trims it away, and the transcript stays empty forever (the 'buffer=2000ms
    pegged / empty PARTIAL' failure). Instead we wait up to one chunk-duration
    for real audio, and only then emit ONE real-time-paced silence chunk."""
    needed = num_frames * 2
    deadline = time.monotonic() + (num_frames / SAMPLE_RATE)
    while True:
        with sys_capture_lock:
            if len(sys_capture_buffer) > SCK_BUF_MAX:
                excess = len(sys_capture_buffer) - SCK_BUF_MAX
                del sys_capture_buffer[:excess]
            if len(sys_capture_buffer) >= needed:
                data = bytes(sys_capture_buffer[:needed])
                del sys_capture_buffer[:needed]
                return data
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return SILENCE   # nothing playing — emit silence at real-time pace
        time.sleep(min(0.005, remaining))


using_screencapturekit = False
if args.sysfifo and args.mode in ("system", "both"):
    # Preferred path: the app captures system audio in-process (permission applies)
    # and streams it to this FIFO. No helper process, no silence.
    using_screencapturekit = start_sys_fifo()
    print(">>> Audio mode: in-app Core Audio tap via FIFO", flush=True)
elif args.syscapture and args.mode in ("system", "both"):
    using_screencapturekit = start_sys_capture()
    if using_screencapturekit:
        print(">>> Audio mode: ScreenCaptureKit active", flush=True)
    else:
        # ScreenCaptureKit failed — try BlackHole virtual audio device
        print(">>> ScreenCaptureKit failed — trying BlackHole fallback...", flush=True)
        if p is None:
            p = pyaudio.PyAudio()
        bh_index = find_blackhole_device(p)
        if bh_index is not None:
            try:
                sys_stream = p.open(
                    format=pyaudio.paInt16,
                    channels=1,
                    rate=SAMPLE_RATE,
                    input=True,
                    input_device_index=bh_index,
                    frames_per_buffer=CHUNK_FRAMES,
                )
                bh_name = p.get_device_info_by_index(bh_index)['name']
                print(f">>> SYSTEM AUDIO (BlackHole fallback): [{bh_index}] {bh_name}", flush=True)
            except Exception as e:
                print(f">>> WARNING: BlackHole fallback failed: {e}", flush=True)
                print(">>> Falling back to mic only", flush=True)
                open_mic(fatal=False)   # ensure the mic is open before switching modes
                args.mode = "mic"
        else:
            print(">>> No BlackHole found — falling back to mic only", flush=True)
            open_mic(fatal=False)       # ensure the mic is open before switching modes
            args.mode = "mic"


_mix_log_counter = 0

def mix_audio(mic_data, sys_data):
    global _mix_log_counter
    mic_arr = np.frombuffer(mic_data, dtype=np.int16).astype(np.float32)
    sys_arr = np.frombuffer(sys_data, dtype=np.int16).astype(np.float32)

    # Weight system audio higher (0.85) than mic (0.45) so interview
    # questions from YouTube/video come through clearly.
    # Mic still captured so user's spoken answers are also transcribed.
    mixed_f = mic_arr * 0.45 + sys_arr * 0.85

    # Normalise if clipping — preserves relative levels without distortion
    peak = np.abs(mixed_f).max()
    if peak > 32767:
        mixed_f = mixed_f * (32767.0 / peak)

    mixed = mixed_f.clip(-32768, 32767).astype(np.int16)

    # Log audio levels every ~50 chunks (~3 seconds) so we can see signal strength
    _mix_log_counter += 1
    if _mix_log_counter % 50 == 0:
        mic_rms = int(np.sqrt(np.mean(mic_arr ** 2)))
        sys_rms = int(np.sqrt(np.mean(sys_arr ** 2)))
        mix_rms = int(np.sqrt(np.mean(mixed_f ** 2)))
        print(f">>> AUDIO LEVELS — mic RMS: {mic_rms:5d}  sys RMS: {sys_rms:5d}  mix RMS: {mix_rms:5d}", flush=True)

    return mixed.tobytes()


def build_text_from_results(results):
    # ── Segment-level guard ───────────────────────────────────────────────────
    # If the average word confidence across the whole segment is too low, drop
    # the entire segment. Background audio in a foreign language consistently
    # produces low average confidence; genuine English speech rarely does.
    word_confs = [
        r["alternatives"][0].get("confidence", 1.0)
        for r in results
        if r.get("type") == "word" and r.get("alternatives")
    ]
    if word_confs:
        avg_conf = sum(word_confs) / len(word_confs)
        if avg_conf < SEGMENT_CONF_FLOOR:
            print(f">>> Segment rejected — avg_conf={avg_conf:.2f} (background noise)", flush=True)
            return ""

    # ── Word-level filter ────────────────────────────────────────────────────
    text    = ""
    skipped = 0
    for res in results:
        if not res.get("alternatives"):
            continue
        alt        = res["alternatives"][0]
        word       = alt["content"]
        confidence = alt.get("confidence", 1.0)
        is_punc    = res.get("type") == "punctuation"

        if not is_punc and confidence < CONFIDENCE_THRESHOLD:
            skipped += 1
            continue

        if is_punc:
            text = text.rstrip() + word + " "
        else:
            text += word + " "

    if skipped:
        print(f">>> Dropped {skipped} low-confidence word(s)", flush=True)

    return text


class SmartAudioStream:
    def read(self, num_frames, exception_on_overflow=False):
        global is_recording, recording_frames

        if os.path.exists(PAUSE_FLAG):
            if mic_stream:
                try:
                    mic_stream.read(num_frames, exception_on_overflow=False)
                except Exception:
                    pass
            else:
                # No mic stream to pace the loop — sleep one chunk-duration so the
                # paused stream emits silence at REAL-TIME rate, never in a tight loop.
                time.sleep(num_frames / SAMPLE_RATE)
            # Drain captured system audio too — the ScreenCaptureKit thread keeps
            # filling sys_capture_buffer while paused, so without this up to ~2s of
            # audio captured during mute gets transcribed right after unmute,
            # undermining mute for system audio.
            if using_screencapturekit:
                with sys_capture_lock:
                    sys_capture_buffer.clear()
            return SILENCE

        mode = args.mode

        if mode == "mic":
            # BUG-5 FIX: catch OSError/IOError (device disconnect, driver hiccup) so a
            # transient hardware error doesn't propagate up and kill the audio thread.
            # Guard against mic_stream being None (e.g. a system→mic fallback where the
            # mic couldn't be opened) so we degrade to silence instead of crashing.
            try:
                data = mic_stream.read(num_frames, exception_on_overflow=False) if mic_stream else SILENCE
            except OSError:
                data = SILENCE
            data = apply_noise_gate(data)
        elif mode == "system":
            if using_screencapturekit:
                # Paced read — blocks until real audio arrives (or one chunk-duration
                # passes), so the websocket is never flooded with synthetic silence.
                data = read_sys_capture_chunk_paced(num_frames)
            elif sys_stream:
                data = sys_stream.read(num_frames, exception_on_overflow=False)
            else:
                data = SILENCE
        elif mode == "both":
            # The blocking mic read paces this loop at real time.
            try:
                raw_mic = mic_stream.read(num_frames, exception_on_overflow=False) if mic_stream else SILENCE
            except OSError:
                raw_mic = SILENCE
            if not mic_stream:
                time.sleep(num_frames / SAMPLE_RATE)   # keep real-time pace without a mic
            mic_data = apply_noise_gate(raw_mic)   # gate before mixing
            if using_screencapturekit:
                sys_data = read_sys_capture_chunk(num_frames)
            elif sys_stream:
                try:
                    sys_data = sys_stream.read(num_frames, exception_on_overflow=False)
                except Exception:
                    sys_data = SILENCE
            else:
                sys_data = SILENCE
            data = mix_audio(mic_data, sys_data)
        else:
            time.sleep(num_frames / SAMPLE_RATE)   # unknown mode — pace, never tight-loop
            data = SILENCE

        if os.path.exists(RECORD_FLAG):
            if not is_recording:
                is_recording = True
                print(">>> Recording started", flush=True)
            with record_lock:
                recording_frames.append(data)
        else:
            if is_recording:
                is_recording = False
                print(">>> Recording stopped - saving...", flush=True)
                threading.Thread(target=save_recording, daemon=True).start()

        return data


async def main():
    global recording_frames, is_recording

    print("", flush=True)
    print("===============================================", flush=True)
    print("   SPEECHMATICS ENGINE: READY", flush=True)
    print(f"   MODE: {args.mode.upper()}", flush=True)
    if using_screencapturekit:
        print("   SYSTEM AUDIO: ScreenCaptureKit OK", flush=True)
    elif sys_stream:
        print("   SYSTEM AUDIO: BlackHole OK", flush=True)
    print(f"   max_delay={args.max_delay}s  chunk={CHUNK_FRAMES}frames", flush=True)
    print("===============================================", flush=True)

    endpoints = [
        "wss://us.rt.speechmatics.com/v2",
        "wss://eu.rt.speechmatics.com/v2",
    ]

    attempt      = 0
    audio_stream = SmartAudioStream()

    # ── Transcript state — OUTSIDE both reconnect loops ──────────────────────
    # BUG-1/2 FIX: declared here so a network hiccup or endpoint failover never
    # silently wipes the in-progress transcript.
    confirmed_text      = ""
    partial_text        = ""
    last_final_end_time = 0.0    # BUG-10: tracks end-time of last confirmed final
    _reset_lock         = threading.Lock()  # BUG-4: serialises _consume_reset check+remove

    # BUG-14 FIX: _write defined BEFORE _consume_reset which calls it.
    # BUG-12 FIX: write to a tmp file then os.replace() — atomic on POSIX, no partial-read tearing.
    def _write(text):
        tmp = LATEST_FILE + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, LATEST_FILE)
        except Exception as fe:
            print(f">>> File write error: {fe}", flush=True)

    # BUG-4 FIX: lock serialises the exists+remove pair so two concurrent async callbacks
    # (e.g. a partial and a final arriving in the same event-loop turn) can't both pass
    # the os.path.exists check and call _write("") twice, potentially clearing new content.
    def _consume_reset():
        nonlocal confirmed_text, partial_text
        with _reset_lock:
            if not os.path.exists(RESET_FLAG):
                return False
            confirmed_text = ""
            partial_text   = ""
            try:
                _write("")
            except Exception:
                pass
            try:
                os.remove(RESET_FLAG)
            except (FileNotFoundError, OSError):
                pass
        print(">>> RESET: cleared transcript state", flush=True)
        return True

    def handle_final(msg):
        nonlocal confirmed_text, partial_text, last_final_end_time
        if _consume_reset():
            return
        if os.path.exists(PAUSE_FLAG):
            return
        segment = build_text_from_results(msg.get("results", []))
        if not segment.strip():
            return
        confirmed_text += segment
        partial_text    = ""
        # BUG-10 FIX: record latest end-time so handle_partial can discard stale events
        results  = msg.get("results", [])
        end_vals = [r.get("end_time", 0.0) for r in results if "end_time" in r]
        if end_vals:
            last_final_end_time = max(end_vals)
        display = confirmed_text.strip()
        print(f">>> FINAL: {display}", flush=True)
        _write(display)

    def handle_partial(msg):
        nonlocal confirmed_text, partial_text
        if _consume_reset():
            return
        if os.path.exists(PAUSE_FLAG):
            return
        results = msg.get("results", [])
        # BUG-10 FIX: discard stale partial whose start_time precedes the last confirmed
        # final — prevents a delayed partial event from briefly overwriting a final.
        if results:
            partial_start = results[0].get("start_time", float("inf"))
            if partial_start < last_final_end_time:
                return
        segment      = build_text_from_results(results)
        partial_text = segment
        display = (confirmed_text + partial_text).strip()
        print(f">>> PARTIAL: {display}", flush=True)
        _write(display)

    while True:
        # BUG-3 FIX: reset delay at the start of every attempt cycle so that after a bad
        # network patch the engine reconnects quickly again instead of being stuck at 30s.
        reconnect_delay = 3
        last_final_end_time = 0.0  # timing resets per-session (BUG-10)
        attempt += 1
        connected = False

        # BUG-19 FIX: reset hysteresis counters so a hold counter from the previous
        # session doesn't bleed into the calibration phase of the new connection.
        reset_gate_transient_state()

        for endpoint in endpoints:
            try:
                print(f">>>[Attempt {attempt}] Connecting to {endpoint}...", flush=True)

                # BUG-17 FIX: use certifi CA bundle so TLS cert verification is on — this
                # protects the API key in transit. Fall back to disabled verification only
                # when certifi is absent (should never happen: it ships with speechmatics).
                try:
                    import certifi
                    ssl_ctx = ssl.create_default_context(cafile=certifi.where())
                except (ImportError, Exception):
                    ssl_ctx = ssl.create_default_context()
                    ssl_ctx.check_hostname = False
                    ssl_ctx.verify_mode    = ssl.CERT_NONE
                    print(">>> WARNING: certifi unavailable — TLS cert verification disabled", flush=True)

                settings = ConnectionSettings(
                    url=endpoint,
                    auth_token=args.key.strip(),
                    ssl_context=ssl_ctx,
                )

                ws = WebsocketClient(settings)

                ws.add_event_handler("AddTranscript",        handle_final)
                ws.add_event_handler("AddPartialTranscript", handle_partial)
                ws.add_event_handler("RecognitionStarted",
                                     lambda m: print(">>> STATUS: ONLINE", flush=True))
                ws.add_event_handler("Error",
                                     lambda e: print(f">>> WS ERROR: {e}", flush=True))

                conf = TranscriptionConfig(
                    language="en",
                    operating_point="enhanced",
                    max_delay=args.max_delay,
                    # "fixed" enforces a hard ceiling on latency (max_delay) instead of
                    # letting the engine extend it for tricky words — keeps transcripts
                    # arriving as fast and predictably as possible for real-time use.
                    max_delay_mode="fixed",
                    enable_partials=True,
                    punctuation_overrides={
                        "permitted_marks": [".", ",", "?", "!"],
                        "sensitivity": 0.5,
                    },
                    enable_entities=True,
                    disfluencies=False,
                    additional_vocab=[],  # BUG-18 FIX: removed stale pharma vocab that
                                         # interfered with non-pharma interviews
                )

                audio_conf = AudioSettings(
                    encoding="pcm_s16le",
                    sample_rate=SAMPLE_RATE,
                    chunk_size=CHUNK_FRAMES,
                )

                await ws.run(audio_stream, conf, audio_conf)
                connected = True
                print(f">>> Disconnected from {endpoint} cleanly.", flush=True)
                break

            except Exception as e:
                err = str(e)
                print(f">>> ERROR on {endpoint}: {err}", flush=True)
                if "401" in err or "Unauthorized" in err:
                    print(">>> FATAL: API key rejected. Check your Speechmatics key.", flush=True)
                    exit(1)
                if "Audio Usage Exceeded" in err or "usage" in err.lower():
                    print(">>> Usage limit hit - trying next region...", flush=True)
                    continue
                if "404" in err:
                    print(">>> 404 - try: pip install --upgrade speechmatics", flush=True)
                    continue
                print(">>> Trying next endpoint...", flush=True)
                continue

        if not connected:
            print(f">>> All endpoints failed. Retrying in {reconnect_delay}s...", flush=True)

        await asyncio.sleep(reconnect_delay)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print(">>> Shutting down...", flush=True)
    finally:
        try:
            if is_recording:
                save_recording()
            if mic_stream:
                mic_stream.stop_stream()
                mic_stream.close()
            if sys_stream:
                sys_stream.stop_stream()
                sys_stream.close()
            if p:
                p.terminate()
            if sys_capture_proc:
                sys_capture_proc.terminate()
            print(">>> Audio cleaned up.", flush=True)
        except Exception:
            pass
