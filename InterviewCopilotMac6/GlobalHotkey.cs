using Avalonia.Threading;
using System;
using System.Runtime.InteropServices;

namespace InterviewCopilotMac6
{
    /// <summary>
    /// Mac-compatible global hotkey listener using CGEventTap (macOS native).
    /// Replaces Windows WH_KEYBOARD_LL hook.
    /// </summary>
    public class GlobalHotkey : IDisposable
    {
        private readonly Action _onSpacePressed;
        private readonly Action? _onF12Pressed;
        private readonly Action? _onKillPressed;
        private readonly Action? _onF8Pressed;   // Capture All Screens
        private readonly Action? _onF9Pressed;   // Capture Screen

        private bool _disposed = false;
        private IntPtr _eventTap = IntPtr.Zero;
        private IntPtr _runLoopSource = IntPtr.Zero;
        private GCHandle _callbackHandle;

        public bool Enabled { get; set; } = true;

        // macOS key codes
        private const int kVK_Space = 0x31;
        private const int kVK_F12   = 0x6F;
        private const int kVK_F4    = 0x76;
        private const int kVK_F8    = 0x64;  // Capture All Screens hotkey
        private const int kVK_F9    = 0x65;  // Capture Screen hotkey

        // CGEventType
        private const int kCGEventKeyDown = 10;

        // CGEventTapLocation
        private const int kCGSessionEventTap = 1;

        // CGEventTapPlacement
        private const int kCGTailAppendEventTap = 1;

        // CGEventTapOptions
        private const int kCGEventTapOptionListenOnly = 1;

        // Modifier flags
        private const ulong kCGEventFlagMaskControl = 0x40000;
        private const ulong kCGEventFlagMaskShift   = 0x20000;

        private delegate IntPtr CGEventTapCallBack(
            IntPtr proxy, int type, IntPtr eventRef, IntPtr userInfo);

        public GlobalHotkey(
            Action onSpacePressed,
            Action? onF12Pressed = null,
            Action? onKillPressed = null,
            Action? onF8Pressed = null,
            Action? onF9Pressed = null)
        {
            _onSpacePressed = onSpacePressed;
            _onF12Pressed   = onF12Pressed;
            _onKillPressed  = onKillPressed;
            _onF8Pressed    = onF8Pressed;
            _onF9Pressed    = onF9Pressed;

            StartEventTap();
        }

        private void StartEventTap()
        {
            try
            {
                CGEventTapCallBack callback = HandleEvent;
                _callbackHandle = GCHandle.Alloc(callback);

                ulong eventMask = (1UL << kCGEventKeyDown);

                _eventTap = CGEventTapCreate(
                    kCGSessionEventTap,
                    kCGTailAppendEventTap,
                    kCGEventTapOptionListenOnly,
                    eventMask,
                    callback,
                    IntPtr.Zero);

                if (_eventTap == IntPtr.Zero)
                {
                    // Free GCHandle — tap never started so callback will never be called
                    if (_callbackHandle.IsAllocated) _callbackHandle.Free();
                    Views.DebugWindow.Log("HOOK",
                        "CGEventTap FAILED — check Accessibility permissions in System Settings");
                    return;
                }

                _runLoopSource = CFMachPortCreateRunLoopSource(IntPtr.Zero, _eventTap, 0);
                CFRunLoopAddSource(CFRunLoopGetCurrent(), _runLoopSource, kCFRunLoopCommonModes);
                CGEventTapEnable(_eventTap, true);

                Views.DebugWindow.Log("HOOK", "CGEventTap installed successfully");
            }
            catch (Exception ex)
            {
                if (_callbackHandle.IsAllocated) _callbackHandle.Free();
                Views.DebugWindow.Log("HOOK", $"StartEventTap error: {ex.Message}");
            }
        }

        private IntPtr HandleEvent(IntPtr proxy, int type, IntPtr eventRef, IntPtr userInfo)
        {
            try
            {
                if (type != kCGEventKeyDown) return eventRef;

                long keyCode = CGEventGetIntegerValueField(eventRef, 9); // kCGKeyboardEventKeycode = 9
                ulong flags  = CGEventGetFlags(eventRef);

                bool ctrl  = (flags & kCGEventFlagMaskControl) != 0;
                bool shift = (flags & kCGEventFlagMaskShift)   != 0;

                // F12 — toggle debug window
                if (keyCode == kVK_F12 && _onF12Pressed != null)
                {
                    Dispatcher.UIThread.Post(() => _onF12Pressed.Invoke());
                }

                // Ctrl+Shift+F4 — kill app
                if (keyCode == kVK_F4 && ctrl && shift && _onKillPressed != null)
                {
                    Views.DebugWindow.Log("HOOK", "Ctrl+Shift+F4 detected — killing app");
                    Dispatcher.UIThread.Post(() => _onKillPressed.Invoke());
                }

                // F8 — capture all screens and auto-answer (respects Enabled flag)
                if (keyCode == kVK_F8 && Enabled && _onF8Pressed != null)
                {
                    Views.DebugWindow.Log("HOOK", "F8 detected — triggering screen capture");
                    Dispatcher.UIThread.Post(() => _onF8Pressed.Invoke());
                }

                // F9 — capture screen and auto-answer (respects Enabled flag)
                if (keyCode == kVK_F9 && Enabled && _onF9Pressed != null)
                {
                    Views.DebugWindow.Log("HOOK", "F9 detected — triggering screen capture");
                    Dispatcher.UIThread.Post(() => _onF9Pressed.Invoke());
                }

                // Space — global trigger when enabled
                if (keyCode == kVK_Space && Enabled)
                {
                    Views.DebugWindow.Log("HOOK", "SPACE detected globally — firing callback");
                    Dispatcher.UIThread.Post(() => _onSpacePressed.Invoke());
                }
            }
            catch (Exception ex)
            {
                Views.DebugWindow.Log("HOOK", $"HandleEvent error: {ex.Message}");
            }

            return eventRef;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;

            // Disable and remove each native resource independently so that a failure
            // in one step does not skip freeing the GCHandle (which would leak the delegate).
            try
            {
                if (_eventTap != IntPtr.Zero)
                {
                    try { CGEventTapEnable(_eventTap, false); } catch { }
                    _eventTap = IntPtr.Zero;
                }
                if (_runLoopSource != IntPtr.Zero)
                {
                    try { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _runLoopSource, kCFRunLoopCommonModes); } catch { }
                    _runLoopSource = IntPtr.Zero;
                }
            }
            finally
            {
                if (_callbackHandle.IsAllocated)
                    _callbackHandle.Free();

                Views.DebugWindow.Log("HOOK", "GlobalHotkey disposed");
            }
        }

        // ── macOS native APIs ──────────────────────────────────────────

        private static readonly IntPtr kCFRunLoopCommonModes =
            CFStringCreateWithCString(IntPtr.Zero, "kCFRunLoopCommonModes", 0);

        [DllImport("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")]
        private static extern IntPtr CGEventTapCreate(
            int tap, int place, int options,
            ulong eventsOfInterest,
            CGEventTapCallBack callback,
            IntPtr userInfo);

        [DllImport("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")]
        private static extern void CGEventTapEnable(IntPtr tap, bool enable);

        [DllImport("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")]
        private static extern long CGEventGetIntegerValueField(IntPtr eventRef, int field);

        [DllImport("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")]
        private static extern ulong CGEventGetFlags(IntPtr eventRef);

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        private static extern IntPtr CFMachPortCreateRunLoopSource(
            IntPtr allocator, IntPtr port, int order);

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        private static extern IntPtr CFRunLoopGetCurrent();

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        private static extern void CFRunLoopAddSource(
            IntPtr rl, IntPtr source, IntPtr mode);

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        private static extern void CFRunLoopRemoveSource(
            IntPtr rl, IntPtr source, IntPtr mode);

        [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
        private static extern IntPtr CFStringCreateWithCString(
            IntPtr alloc, string cStr, int encoding);
    }
}