import os
import sys
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
args = parser.parse_args()

if not args.key:
    print(">>> FATAL: No Speechmatics API key. Pass -key or set SPEECHMATICS_API_KEY env var.", flush=True)
    exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
APP_DATA = os.path.join(
    os.environ.get("HOME", tempfile.gettempdir()),
    "Library", "Application Support", "InterviewCopilot"
)
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

if args.mode in ("mic", "both"):
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
    n = 1
    while os.path.exists(os.path.join(RECORDINGS_DIR, f"interview_{n}.wav")):
        n += 1
    filename = os.path.join(RECORDINGS_DIR, f"interview_{n}.wav")
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


CHUNK_FRAMES = 2048   # 128 ms per chunk — halved for lower latency (was 4096 / 256 ms)
SAMPLE_RATE  = 16000
# Maximum SCK buffer size: 2 seconds worth of audio.
# If the engine falls behind, old audio is dropped so we always transcribe fresh speech.
SCK_BUF_MAX  = SAMPLE_RATE * 2 * 2  # 2s × 16000 samples × 2 bytes
SILENCE      = b"\x00" * (CHUNK_FRAMES * 2)

mic_stream = None
sys_stream = None
p = None

if args.mode in ("mic", "both"):
    try:
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
    except Exception as e:
        print(f">>> FATAL: Cannot open mic stream - {e}", flush=True)
        exit(1)

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
                        # Cap the buffer here too — drop oldest audio if we fall behind.
                        # This prevents a growing lag when the Speechmatics connection
                        # is slow to start or the engine is briefly behind.
                        if len(sys_capture_buffer) > SCK_BUF_MAX:
                            excess = len(sys_capture_buffer) - SCK_BUF_MAX
                            del sys_capture_buffer[:excess]
                    bytes_received += len(chunk)
                    now = int(bytes_received / 32000)  # log every ~1s of audio
                    if now != last_log:
                        last_log = now
                        buf_size = len(sys_capture_buffer)
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


using_screencapturekit = False
if args.syscapture and args.mode in ("system", "both"):
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
                args.mode = "mic"
        else:
            print(">>> No BlackHole found — falling back to mic only", flush=True)
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
    text = ""
    for res in results:
        if not res.get("alternatives"):
            continue
        word    = res["alternatives"][0]["content"]
        is_punc = res.get("type") == "punctuation"
        if is_punc:
            text = text.rstrip() + word + " "
        else:
            text += word + " "
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
            return SILENCE

        mode = args.mode

        if mode == "mic":
            data = mic_stream.read(num_frames, exception_on_overflow=False)
        elif mode == "system":
            if using_screencapturekit:
                data = read_sys_capture_chunk(num_frames)
            elif sys_stream:
                data = sys_stream.read(num_frames, exception_on_overflow=False)
            else:
                data = SILENCE
        elif mode == "both":
            mic_data = mic_stream.read(num_frames, exception_on_overflow=False) if mic_stream else SILENCE
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

    reconnect_delay = 3
    attempt         = 0
    audio_stream    = SmartAudioStream()

    while True:
        attempt += 1
        connected = False

        for endpoint in endpoints:
            try:
                print(f">>>[Attempt {attempt}] Connecting to {endpoint}...", flush=True)

                bypass_ssl_ctx = ssl.create_default_context()
                bypass_ssl_ctx.check_hostname = False
                bypass_ssl_ctx.verify_mode    = ssl.CERT_NONE

                settings = ConnectionSettings(
                    url=endpoint,
                    auth_token=args.key.strip(),
                    ssl_context=bypass_ssl_ctx,
                )

                ws = WebsocketClient(settings)

                confirmed_text = ""
                partial_text   = ""

                def handle_final(msg):
                    nonlocal confirmed_text, partial_text
                    if os.path.exists(PAUSE_FLAG):
                        return
                    if os.path.exists(RESET_FLAG):
                        confirmed_text = ""
                        partial_text   = ""
                        try:
                            os.remove(RESET_FLAG)
                        except Exception:
                            pass
                        return
                    segment = build_text_from_results(msg.get("results", []))
                    if not segment.strip():
                        return
                    confirmed_text += segment
                    partial_text    = ""
                    display = confirmed_text.strip()
                    print(f">>> FINAL: {display}", flush=True)
                    _write(display)

                def handle_partial(msg):
                    nonlocal partial_text
                    if os.path.exists(PAUSE_FLAG):
                        return
                    if os.path.exists(RESET_FLAG):
                        return
                    segment      = build_text_from_results(msg.get("results", []))
                    partial_text = segment
                    display = (confirmed_text + partial_text).strip()
                    print(f">>> PARTIAL: {display}", flush=True)
                    _write(display)

                def _write(text):
                    try:
                        with open(LATEST_FILE, "w", encoding="utf-8") as f:
                            f.write(text)
                    except Exception as fe:
                        print(f">>> File write error: {fe}", flush=True)

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
                    enable_partials=True,
                    punctuation_overrides={
                        "permitted_marks": [".", ",", "?", "!"],
                        "sensitivity": 0.5,
                    },
                    enable_entities=True,
                    disfluencies=False,
                    additional_vocab=[
                        {"content": "AVA",               "sounds_like": ["AY-VAH", "AY-VA"]},
                        {"content": "AVA Inc"},
                        {"content": "HPLC",              "sounds_like": ["H-P-L-C"]},
                        {"content": "FTIR",              "sounds_like": ["F-T-I-R"]},
                        {"content": "GMP"},
                        {"content": "GC"},
                        {"content": "ALCOA"},
                        {"content": "LIMS"},
                        {"content": "OOS"},
                        {"content": "OOT"},
                        {"content": "CAPA"},
                        {"content": "IQ/OQ/PQ"},
                        {"content": "Waters Empower"},
                        {"content": "Agilent ChemStation"},
                        {"content": "Willowbrook"},
                    ]
                )

                audio_conf = AudioSettings(
                    encoding="pcm_s16le",
                    sample_rate=SAMPLE_RATE,
                    chunk_size=CHUNK_FRAMES,
                )

                await ws.run(audio_stream, conf, audio_conf)
                connected = True
                reconnect_delay = 3
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
        reconnect_delay = min(reconnect_delay * 2, 30)


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
