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
        private bool   _downloading = false;
        private string? _downloadedPath = null;

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
            NoteText.Text           = "Downloading in background — you can close this window.";
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
            _downloadedPath = path;
            Dispatcher.UIThread.Post(() =>
            {
                ProgressBar.Value       = 100;
                PctText.Text            = "100%";
                ProgressPanel.IsVisible = false;
                NoteText.IsVisible      = false;
                RestartPanel.IsVisible  = true;
            });
        }

        private void RestartNow_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            if (_downloadedPath != null)
                App.LaunchInstallerAndQuit(_downloadedPath);
        }

        private void RestartLater_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            // FIX 8 — null guard: don't set PendingUpdatePath if download path is null
            if (_downloadedPath == null) return;
            App.PendingUpdate     = _item;
            App.PendingUpdatePath = _downloadedPath;
            App.RaiseUpdateReadyToInstall(_item);
            DetachEvents();
            Close();
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

        // FIX 7 — detach events when window is closed via OS (e.g. red traffic-light button)
        protected override void OnClosed(EventArgs e)
        {
            DetachEvents();
            base.OnClosed(e);
        }

        private void TitleBar_PointerPressed(object? sender, PointerPressedEventArgs e)
            => BeginMoveDrag(e);
    }
}
