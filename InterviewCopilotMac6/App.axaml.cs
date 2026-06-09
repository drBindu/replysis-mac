using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using InterviewCopilotMac6.ViewModels;
using InterviewCopilotMac6.Views;
using NetSparkleUpdater;
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

        // Start silent update check after the UI is visible
        Dispatcher.UIThread.Post(StartUpdateCheckAsync, DispatcherPriority.Background);
    }

    // ── Silent background update check ──────────────────────────
    private static async void StartUpdateCheckAsync()
    {
        try
        {
            Sparkle = new SparkleUpdater(
                AppcastUrl,
                new Ed25519Checker(SecurityMode.Strict, SparklePublicKey))
            {
                RelaunchAfterUpdate = true,
                ShowsUIOnMainThread = true,
            };

            var info = await Sparkle.CheckForUpdatesQuietly();
            if (info?.Updates == null || info.Updates.Count == 0) return;

            // Update found — show our custom dialog on the UI thread
            var update = info.Updates[0];
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                var win    = new UpdateWindow(Sparkle, update);
                var parent = GetMainWindow();
                if (parent != null) win.ShowDialog(parent);
                else                win.Show();
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
