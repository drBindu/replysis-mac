using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Threading;
using NetSparkleUpdater;
using NetSparkleUpdater.Events;
using System;
using System.IO;
using System.Reflection;
using System.Threading.Tasks;

namespace InterviewCopilotMac6.Views
{
    public partial class UpdateWindow : Window
    {
        private readonly SparkleUpdater _sparkle;
        private readonly AppCastItem   _item;
        private bool _downloading = false;

        // ── Constructor ────────────────────────────────────────────
        public UpdateWindow(SparkleUpdater sparkle, AppCastItem item)
        {
            InitializeComponent();
            _sparkle = sparkle;
            _item    = item;

            // Version labels
            string current = Assembly.GetEntryAssembly()?
                .GetName().Version?.ToString(3) ?? "current";
            string newVer  = item.Version ?? "new version";
            string appName = "Interview Copilot";

            TitleText.Text    = $"{appName} {newVer} is here!";
            SubtitleText.Text = $"You have {current} — {newVer} is ready.";

            DescText.Text = !string.IsNullOrWhiteSpace(item.Description)
                ? item.Description.Trim()
                : "• Stability improvements and bug fixes\n• Performance enhancements";

            // Wire download events
            _sparkle.DownloadStarted      += OnDownloadStarted;
            _sparkle.DownloadMadeProgress += OnDownloadProgress;
            _sparkle.DownloadFinished     += OnDownloadFinished;
            _sparkle.DownloadHadError     += OnDownloadError;
        }

        // ── Buttons ────────────────────────────────────────────────
        private async void Action_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            if (_downloading) return;
            _downloading = true;

            // Hide buttons, show progress panel
            ActionBtn.IsVisible     = false;
            LaterBtn.IsVisible      = false;
            ProgressPanel.IsVisible = true;
            StatusText.Text         = "Downloading update…";
            NoteText.Text           = "App will restart automatically when ready.";
            NoteText.IsVisible      = true;

            try
            {
                await _sparkle.InitAndBeginDownload(_item);
            }
            catch (Exception ex)
            {
                ShowError($"Download failed: {ex.Message}");
            }
        }

        private void Later_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            DetachEvents();
            Close();
        }

        private void Close_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            DetachEvents();
            Close();
        }

        // ── Download events ────────────────────────────────────────
        private void OnDownloadStarted(AppCastItem item, string path)
        {
            Dispatcher.UIThread.Post(() =>
            {
                ProgressBar.Value = 0;
                PctText.Text      = "0%";
            });
        }

        private void OnDownloadProgress(object? sender, AppCastItem item,
            ItemDownloadProgressEventArgs args)
        {
            Dispatcher.UIThread.Post(() =>
            {
                int pct           = (int)Math.Round((double)args.ProgressPercentage);
                ProgressBar.Value = pct;
                PctText.Text      = $"{pct}%";
                StatusText.Text   = "Downloading update…";
            });
        }

        private void OnDownloadFinished(AppCastItem item, string path)
        {
            Dispatcher.UIThread.Post(() =>
            {
                ProgressBar.Value = 100;
                PctText.Text      = "100%";
                StatusText.Text   = "Installing…";
                NoteText.Text     = "Relaunching in a moment…";
                LaunchInstallerAndQuit(path);
            });
        }

        private static void LaunchInstallerAndQuit(string zipPath)
        {
            try
            {
                // Resolve the .app bundle (BaseDirectory = .../InterviewCopilot.app/Contents/MacOS/)
                var appBundle = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../.."));
                var appParent = Path.GetDirectoryName(appBundle) ?? "/Applications";
                var scriptPath = "/tmp/ic_relaunch.sh";
                var logPath    = "/tmp/ic_relaunch.log";

                File.WriteAllText(scriptPath,
                    "#!/bin/bash\n" +
                    "sleep 3\n" +
                    $"rm -rf \"{appBundle}\"\n" +
                    $"unzip -o \"{zipPath}\" -d \"{appParent}/\"\n" +
                    $"open \"{appBundle}\"\n");

                // Make executable
                System.Diagnostics.Process.Start(
                    new System.Diagnostics.ProcessStartInfo("/bin/chmod", $"+x \"{scriptPath}\"")
                    { UseShellExecute = false, CreateNoWindow = true })?.WaitForExit();

                // Launch with nohup so the script survives after this app quits
                System.Diagnostics.Process.Start(
                    new System.Diagnostics.ProcessStartInfo(
                        "/bin/bash",
                        $"-c \"nohup /bin/bash '{scriptPath}' > '{logPath}' 2>&1 &\"")
                    { UseShellExecute = false, CreateNoWindow = true })?.WaitForExit();
            }
            catch { }

            Task.Delay(1000).ContinueWith(_ => Environment.Exit(0));
        }

        private void OnDownloadError(AppCastItem item, string? path, Exception ex)
        {
            Dispatcher.UIThread.Post(() => ShowError($"Download error: {ex.Message}"));
        }

        // ── Error state ────────────────────────────────────────────
        private void ShowError(string message)
        {
            _downloading            = false;
            ErrorText.Text          = message;
            ErrorPanel.IsVisible    = true;
            ProgressPanel.IsVisible = false;
            NoteText.IsVisible      = false;
            ActionBtn.IsVisible     = true;
            LaterBtn.IsVisible      = true;
            ActionBtn.Content       = "Retry";
        }

        private void DetachEvents()
        {
            _sparkle.DownloadStarted      -= OnDownloadStarted;
            _sparkle.DownloadMadeProgress -= OnDownloadProgress;
            _sparkle.DownloadFinished     -= OnDownloadFinished;
            _sparkle.DownloadHadError     -= OnDownloadError;
        }

        private void TitleBar_PointerPressed(object? sender, PointerPressedEventArgs e)
            => BeginMoveDrag(e);
    }
}
