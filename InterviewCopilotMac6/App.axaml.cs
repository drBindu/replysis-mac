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

namespace InterviewCopilotMac6;

public partial class App : Application
{
    // ── Sparkle auto-updater config ──────────────────────────────
    // PUBLIC key — safe to ship in the binary
    // The matching PRIVATE key lives in GitHub Actions secret SPARKLE_PRIVATE_KEY
    private const string SparklePublicKey =
        "GLZzMYoNz4KvKt7ExIndPLaootI0M56sjGZ5I/qYKGs=";

    private const string AppcastUrl =
        "https://raw.githubusercontent.com/moto123a/interview-copilot-mac/main/appcast.xml";

    internal static SparkleUpdater? Sparkle;

    // Prevent multiple update dialogs from stacking
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

        // First check: 5 s after launch so the main window is fully visible
        DispatcherTimer.RunOnce(
            () => _ = StartUpdateCheckAsync(),
            TimeSpan.FromSeconds(5));

        // Periodic check: every 4 hours while the app is running
        var periodicTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMinutes(1)
        };
        periodicTimer.Tick += async (_, _) => await StartUpdateCheckAsync();
        periodicTimer.Start();
    }

    // ── Silent background update check ──────────────────────────
    private static async System.Threading.Tasks.Task StartUpdateCheckAsync()
    {
        try
        {
            // Initialise once; reuse on periodic ticks
            Sparkle ??= new SparkleUpdater(
                AppcastUrl,
                new Ed25519Checker(SecurityMode.Strict, SparklePublicKey))
            {
                RelaunchAfterUpdate = true,
            };

            var info = await Sparkle.CheckForUpdatesQuietly();
            if (info?.Updates == null || info.Updates.Count == 0) return;

            // Don't stack dialogs if one is already open
            if (_updateDialogShowing) return;

            var update = info.Updates[0];
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                _updateDialogShowing = true;
                var win    = new UpdateWindow(Sparkle, update);
                var parent = GetMainWindow();

                win.Closed += (_, _) => _updateDialogShowing = false;

                // Use Show() — ShowDialog requires await and can silently fail
                if (parent != null)
                {
                    win.ShowDialog(parent);
                }
                else
                {
                    win.Show();
                }
            });
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[Updater] Check failed: {ex.Message}");
        }
    }

    private static Window? GetMainWindow()
    {
        if (Current?.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime d)
            return d.MainWindow;
        return null;
    }
}
