using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Threading;
using NetSparkleUpdater;
using NetSparkleUpdater.Events;
using System;
using System.Reflection;

namespace InterviewCopilotMac6.Views
{
    public partial class UpdateWindow : Window
    {
        private readonly SparkleUpdater _sparkle;
        private readonly AppCastItem   _item;

        private enum State { Ready, Downloading, ReadyToInstall, Error }
        private State _state = State.Ready;

        // ── Constructor ────────────────────────────────────────────
        public UpdateWindow(SparkleUpdater sparkle, AppCastItem item)
        {
            InitializeComponent();
            _sparkle = sparkle;
            _item    = item;

            // Version info
            string current = Assembly.GetEntryAssembly()?
                .GetName().Version?.ToString(3) ?? "current";
            string newVer = item.Version ?? item.AppVersionInstalled ?? "new version";
            string appName = item.AppName?.Length > 0 ? item.AppName : "Interview Copilot";

            TitleText.Text    = $"{appName} {newVer} is here!";
            SubtitleText.Text = $"You have version {current} — {newVer} is ready.";

            DescText.Text = !string.IsNullOrWhiteSpace(item.Description)
                ? item.Description.Trim()
                : "• Stability improvements and bug fixes\n• Performance enhancements";

            // Wire up download events
            _sparkle.DownloadStarted     += OnDownloadStarted;
            _sparkle.DownloadMadeProgress += OnDownloadProgress;
            _sparkle.DownloadFinished    += OnDownloadFinished;
            _sparkle.DownloadHadError    += OnDownloadError;
        }

        // ── Button handlers ────────────────────────────────────────
        private void Later_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            DetachEvents();
            Close();
        }

        private async void Action_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            if (_state == State.Ready)
            {
                // Start download
                SetState(State.Downloading);
                try
                {
                    await _sparkle.InitAndBeginDownload(_item);
                }
                catch (Exception ex)
                {
                    ShowError($"Download failed: {ex.Message}");
                }
            }
            else if (_state == State.ReadyToInstall)
            {
                // Install — app will relaunch automatically
                ActionBtn.IsEnabled = false;
                ActionBtn.Content   = "Installing…";
                _sparkle.InstallUpdate(_item);
            }
        }

        private void Close_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            if (_state == State.Downloading) return; // don't close mid-download
            DetachEvents();
            Close();
        }

        // ── Download event handlers ────────────────────────────────
        private void OnDownloadStarted(AppCastItem item, string downloadFilePath)
        {
            Dispatcher.UIThread.Post(() =>
            {
                ProgressPanel.IsVisible = true;
                StatusText.Text         = "Downloading update…";
                PctText.Text            = "0%";
                ProgressBar.Value       = 0;
            });
        }

        private void OnDownloadProgress(object? sender, AppCastItem item,
            ItemDownloadProgressEventArgs args)
        {
            Dispatcher.UIThread.Post(() =>
            {
                int pct = (int)Math.Round(args.ProgressPercentage);
                ProgressBar.Value = pct;
                PctText.Text      = $"{pct}%";
                StatusText.Text   = pct >= 100 ? "Download complete" : "Downloading update…";
            });
        }

        private void OnDownloadFinished(AppCastItem item, string downloadFilePath)
        {
            Dispatcher.UIThread.Post(() =>
            {
                SetState(State.ReadyToInstall);
                ProgressPanel.IsVisible = true;
                ProgressBar.Value       = 100;
                PctText.Text            = "100%";
                StatusText.Text         = "Ready to install";
            });
        }

        private void OnDownloadError(AppCastItem item, string downloadFilePath, Exception ex)
        {
            Dispatcher.UIThread.Post(() => ShowError($"Download error: {ex.Message}"));
        }

        // ── UI state machine ───────────────────────────────────────
        private void SetState(State s)
        {
            _state = s;
            switch (s)
            {
                case State.Ready:
                    ActionBtn.Content   = "Update Now";
                    ActionBtn.IsEnabled = true;
                    LaterBtn.IsEnabled  = true;
                    ErrorPanel.IsVisible = false;
                    break;

                case State.Downloading:
                    ActionBtn.Content   = "Downloading…";
                    ActionBtn.IsEnabled = false;
                    LaterBtn.IsEnabled  = false;
                    ProgressPanel.IsVisible = true;
                    ErrorPanel.IsVisible = false;
                    break;

                case State.ReadyToInstall:
                    ActionBtn.Content   = "Relaunch & Install";
                    ActionBtn.IsEnabled = true;
                    LaterBtn.IsEnabled  = true;
                    break;

                case State.Error:
                    ActionBtn.Content   = "Retry";
                    ActionBtn.IsEnabled = true;
                    LaterBtn.IsEnabled  = true;
                    _state = State.Ready; // retry = go back to Ready
                    break;
            }
        }

        private void ShowError(string message)
        {
            ErrorText.Text      = message;
            ErrorPanel.IsVisible = true;
            SetState(State.Error);
        }

        private void DetachEvents()
        {
            _sparkle.DownloadStarted     -= OnDownloadStarted;
            _sparkle.DownloadMadeProgress -= OnDownloadProgress;
            _sparkle.DownloadFinished    -= OnDownloadFinished;
            _sparkle.DownloadHadError    -= OnDownloadError;
        }

        // ── Drag to move ───────────────────────────────────────────
        private void TitleBar_PointerPressed(object? sender, PointerPressedEventArgs e)
        {
            BeginMoveDrag(e);
        }
    }
}
