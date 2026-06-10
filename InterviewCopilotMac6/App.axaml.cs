// v1.0.59
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

    internal static SparkleUpdater? Sparkle;
    private static bool _updateDialogShowing = false;

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
            () => _ = StartUpdateCheckAsync(),
            TimeSpan.FromSeconds(1));

        var periodicTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
        periodicTimer.Tick += async (_, _) => await StartUpdateCheckAsync();
        periodicTimer.Start();
    }

    // ── Read version from Info.plist — assembly version unreliable in self-contained builds ──
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
    private static async System.Threading.Tasks.Task StartUpdateCheckAsync()
    {
        try
        {
            var currentVersionStr = GetAppVersion();
            Log($"installed={currentVersionStr}");

            if (!Version.TryParse(currentVersionStr, out var currentVersion))
                currentVersion = new Version(1, 0, 0);

            using var http = new HttpClient();
            var xml = await http.GetStringAsync(AppcastUrl);

            var versionMatch = Regex.Match(xml, @"<sparkle:version>([^<]+)</sparkle:version>");
            if (!versionMatch.Success) { Log("appcast parse failed"); return; }
            var remoteVersionStr = versionMatch.Groups[1].Value.Trim();
            Log($"remote={remoteVersionStr}");

            if (!Version.TryParse(remoteVersionStr, out var remoteVersion)) { Log("remote version parse failed"); return; }
            if (remoteVersion <= currentVersion) { Log("no update needed"); return; }

            if (_updateDialogShowing) { Log("dialog already showing"); return; }

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
        }
        catch (Exception ex)
        {
            Log($"EXCEPTION: {ex}");
        }
    }

    private static Window? GetMainWindow()
    {
        if (Current?.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime d)
            return d.MainWindow;
        return null;
    }
}
