// v1.0.72-restart-ux-test
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using InterviewCopilotMac6.ViewModels;
using InterviewCopilotMac6.Views;
using NetSparkleUpdater;
using NetSparkleUpdater.Enums;
using NetSparkleUpdater.SignatureVerifiers;
using System;
using System.IO;
using System.Net.Http;
using System.Text.RegularExpressions;

namespace InterviewCopilotMac6;

public partial class App : Application
{
    // ── Sparkle auto-updater config ──────────────────────────────
    private const string SparklePublicKey =
        "GLZzMYoNz4KvKt7ExIndPLaootI0M56sjGZ5I/qYKGs=";

    private const string AppcastUrl =
        "https://raw.githubusercontent.com/moto123a/interview-copilot-mac/main/appcast.xml";

    // FIX 2 — static HttpClient (not recreated every 30s)
    private static readonly HttpClient _httpClient = new HttpClient();

    // FIX 3 — stored reference so it can be stopped on exit
    private static DispatcherTimer? _periodicTimer;

    internal static SparkleUpdater? Sparkle;
    private static bool _updateDialogShowing = false;
    internal static string LastUpdateStatus { get; private set; } = "";

    // Pending update — set when user clicks "Restart Later"
    internal static AppCastItem? PendingUpdate { get; set; }
    internal static string? PendingUpdatePath { get; set; }
    internal static event Action<AppCastItem>? UpdateReadyToInstall;

    // ────────────────────────────────────────────────────────────

    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.MainWindow = new MainWindow
            {
                DataContext = new MainWindowViewModel(),
            };
        }

        base.OnFrameworkInitializationCompleted();

        DispatcherTimer.RunOnce(
            () => _ = CheckForUpdatesAsync(),
            TimeSpan.FromSeconds(1));

        // FIX 3 — use static field so we can stop it on exit
        _periodicTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        _periodicTimer.Tick += async (_, _) => await CheckForUpdatesAsync();
        _periodicTimer.Start();

        // FIX 3 — stop timer on application exit
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop2)
        {
            desktop2.Exit += (_, _) => _periodicTimer?.Stop();
        }
    }

    // ── Read version from Info.plist — assembly version unreliable in self-contained builds ──
    internal static string GetCurrentVersion() => GetAppVersion();
    private static string GetAppVersion()
    {
        try
        {
            var plistPath = Path.Combine(AppContext.BaseDirectory, "..", "Info.plist");
            if (File.Exists(plistPath))
            {
                var content = File.ReadAllText(plistPath);
                var m = Regex.Match(content,
                    @"<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>");
                if (m.Success) return m.Groups[1].Value.Trim();
            }
        }
        catch { }
        return System.Reflection.Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? "1.0.0";
    }

    private static string LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        "Library", "Logs", "interview-copilot-update.log");

    private static void Log(string msg)
    {
        try { File.AppendAllText(LogPath, $"[{DateTime.Now:HH:mm:ss}] {msg}\n"); } catch { }
        System.Diagnostics.Debug.WriteLine($"[Updater] {msg}");
    }

    // ── Fetch appcast manually and do version comparison ourselves ──
    internal static async System.Threading.Tasks.Task<string> CheckForUpdatesAsync(Action<string>? onStatus = null)
    {
        try
        {
            var currentVersionStr = GetAppVersion();
            Log($"installed={currentVersionStr}");
            onStatus?.Invoke("Checking…");

            if (!Version.TryParse(currentVersionStr, out var currentVersion))
                currentVersion = new Version(1, 0, 0);

            // FIX 2 — use static HttpClient instance
            var url = $"{AppcastUrl}?t={DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";
            var xml = await _httpClient.GetStringAsync(url);

            var versionMatch = Regex.Match(xml, @"<sparkle:version>([^<]+)</sparkle:version>");
            if (!versionMatch.Success) { Log("appcast parse failed"); onStatus?.Invoke("Could not check."); return "error"; }
            var remoteVersionStr = versionMatch.Groups[1].Value.Trim();
            Log($"remote={remoteVersionStr}");

            if (!Version.TryParse(remoteVersionStr, out var remoteVersion)) { onStatus?.Invoke("Could not check."); return "error"; }
            if (remoteVersion <= currentVersion) { Log("no update needed"); LastUpdateStatus = $"You're up to date  (v{currentVersionStr})"; onStatus?.Invoke(LastUpdateStatus); return "uptodate"; }

            if (_updateDialogShowing) { Log("dialog already showing"); return "showing"; }

            Log("update available — showing popup");

            var urlMatch   = Regex.Match(xml, @"url=""([^""]+)""");
            var sigMatch   = Regex.Match(xml, @"sparkle:edSignature=""([^""]+)""");
            var titleMatch = Regex.Match(xml, @"<title>Interview Copilot[^<]*</title>");

            var item = new AppCastItem
            {
                Version      = remoteVersionStr,
                Title        = titleMatch.Success
                                ? titleMatch.Value.Replace("<title>", "").Replace("</title>", "").Trim()
                                : $"Interview Copilot {remoteVersionStr}",
                DownloadLink = urlMatch.Success ? urlMatch.Groups[1].Value : string.Empty,
                DownloadSignature = sigMatch.Success ? sigMatch.Groups[1].Value : string.Empty,
            };

            Sparkle ??= new SparkleUpdater(
                AppcastUrl,
                new Ed25519Checker(SecurityMode.Strict, SparklePublicKey))
            {
                RelaunchAfterUpdate = true,
            };

            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                _updateDialogShowing = true;
                var win    = new UpdateWindow(Sparkle, item);
                var parent = GetMainWindow();
                win.Closed += (_, _) => _updateDialogShowing = false;
                if (parent != null) win.ShowDialog(parent);
                else                win.Show();
                Log("popup shown");
            });
            LastUpdateStatus = $"Update available: v{remoteVersionStr}";
            onStatus?.Invoke(LastUpdateStatus);
            return "available";
        }
        catch (Exception ex)
        {
            Log($"EXCEPTION: {ex}");
            onStatus?.Invoke("Check failed.");
            return "error";
        }
    }

    internal static void RaiseUpdateReadyToInstall(AppCastItem item)
        => UpdateReadyToInstall?.Invoke(item);

    internal static void InstallPendingUpdate()
    {
        if (PendingUpdatePath != null)
            LaunchInstallerAndQuit(PendingUpdatePath);
    }

    internal static void LaunchInstallerAndQuit(string zipPath)
    {
        try
        {
            var appBundle  = System.IO.Path.GetFullPath(System.IO.Path.Combine(AppContext.BaseDirectory, "../.."));
            var appParent  = System.IO.Path.GetDirectoryName(appBundle) ?? "/Applications";

            // FIX 9 — validate appBundle path ends with .app before proceeding
            if (!appBundle.EndsWith(".app", StringComparison.OrdinalIgnoreCase))
            {
                Log($"INSTALL ERROR: unexpected appBundle path: {appBundle}");
                return;
            }

            // FIX 4 — use unique temp path to avoid TOCTOU race
            var scriptPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"ic_relaunch_{Guid.NewGuid():N}.sh");
            var logPath    = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ic_relaunch.log");

            // FIX 5 — check unzip exit code before deleting old app; extract to temp dir first
            System.IO.File.WriteAllText(scriptPath,
                "#!/bin/bash\n" +
                $"ZIPFILE=\"{zipPath}\"\n" +
                $"APPBUNDLE=\"{appBundle}\"\n" +
                $"APPPARENT=\"{appParent}\"\n" +
                "TMPEXTRACT=$(mktemp -d)\n" +
                "sleep 3\n" +
                "unzip -o \"$ZIPFILE\" -d \"$TMPEXTRACT/\" || exit 1\n" +
                "rm -rf \"$APPBUNDLE\"\n" +
                "cp -R \"$TMPEXTRACT/InterviewCopilot.app\" \"$APPPARENT/\"\n" +
                "rm -rf \"$TMPEXTRACT\"\n" +
                "open \"$APPBUNDLE\"\n");

            System.Diagnostics.Process.Start(
                new System.Diagnostics.ProcessStartInfo("/bin/chmod", $"+x \"{scriptPath}\"")
                { UseShellExecute = false, CreateNoWindow = true })?.WaitForExit();

            System.Diagnostics.Process.Start(
                new System.Diagnostics.ProcessStartInfo(
                    "/bin/bash", $"-c \"nohup /bin/bash '{scriptPath}' > '{logPath}' 2>&1 &\"")
                { UseShellExecute = false, CreateNoWindow = true })?.WaitForExit();
        }
        catch { }

        System.Threading.Tasks.Task.Delay(1000).ContinueWith(_ => Environment.Exit(0));
    }

    private static Window? GetMainWindow()
    {
        if (Current?.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime d)
            return d.MainWindow;
        return null;
    }
}
