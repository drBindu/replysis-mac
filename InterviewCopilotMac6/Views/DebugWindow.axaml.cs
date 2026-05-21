using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using System;
using System.Collections.Generic;
using Avalonia.Controls.Primitives;

namespace InterviewCopilotMac6.Views
{
    public class DebugWindow : Window
    {
        private static DebugWindow? _instance;
        private readonly List<string> _logs = new List<string>();
        private readonly DispatcherTimer _refreshTimer;
        private bool _allowClose = false;

        private readonly TextBlock _logBlock;
        private readonly ScrollViewer _scroll;
        private readonly TextBlock _statusBar;

        public DebugWindow()
        {
            Title = "Interview Copilot — Debug Log";
            Width = 520;
            Height = 440;
            Background = Brushes.Black;
            Topmost = true;
            WindowStartupLocation = WindowStartupLocation.Manual;
            Position = new PixelPoint(20, 20);
            ShowInTaskbar = false;
            SystemDecorations = SystemDecorations.BorderOnly;

            // Build layout in code (no .axaml needed)
            var grid = new Grid();
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            var header = new TextBlock
            {
                Text = "Interview Copilot — Debug Log  (F12 to hide)",
                Foreground = Brushes.Cyan,
                FontSize = 14,
                FontWeight = FontWeight.Bold,
                Margin = new Thickness(10, 10, 10, 5)
            };
            Grid.SetRow(header, 0);
            grid.Children.Add(header);

            _logBlock = new TextBlock
            {
                Foreground = Brushes.LimeGreen,
                FontFamily = new FontFamily("Courier New"),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap
            };

            _scroll = new ScrollViewer
            {
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                Margin = new Thickness(10, 0, 10, 10),
                Content = _logBlock
            };
            Grid.SetRow(_scroll, 1);
            grid.Children.Add(_scroll);

            _statusBar = new TextBlock
            {
                Text = "Waiting for events...",
                Foreground = Brushes.Yellow,
                FontFamily = new FontFamily("Courier New"),
                FontSize = 11,
                Margin = new Thickness(10, 5, 10, 10)
            };
            Grid.SetRow(_statusBar, 2);
            grid.Children.Add(_statusBar);

            Content = grid;

            _instance = this;

            _refreshTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(100)
            };
            _refreshTimer.Tick += (s, e) =>
            {
                if (!IsVisible || _logs.Count == 0) return;

                // Bulk-trim to 180 when over cap — one RemoveRange is O(n), not O(n²)
                if (_logs.Count > 200)
                    _logs.RemoveRange(0, _logs.Count - 180);

                _logBlock.Text = string.Join("\n", _logs);
                _scroll.ScrollToEnd();
                _statusBar.Text = $"Total events: {_logs.Count} | Last: {DateTime.Now:HH:mm:ss.fff}";
            };
            _refreshTimer.Start();

            Log("DEBUG", "Debug window started");
            Log("DEBUG", "Waiting for Space key events...");
            Log("DEBUG", "Press F12 to hide/show this window");
            Log("DEBUG", "-----------------------------------");
        }

        protected override void OnClosing(WindowClosingEventArgs e)
        {
            if (!_allowClose)
            {
                e.Cancel = true;
                this.Hide();
                return;
            }
            base.OnClosing(e);
        }

        public void ForceClose()
        {
            _allowClose = true;
            _refreshTimer.Stop();
            _instance = null;
            try { this.Close(); } catch { }
        }

        public static void Log(string source, string message)
        {
            string line = $"[{DateTime.Now:HH:mm:ss.fff}] [{source}] {message}";

            var inst = _instance;
            if (inst != null)
            {
                try
                {
                    Dispatcher.UIThread.Post(() =>
                    {
                        try { inst._logs?.Add(line); }
                        catch { }
                    });
                }
                catch { }
            }

            System.Diagnostics.Debug.WriteLine(line);
        }

        protected override void OnClosed(EventArgs e)
        {
            _refreshTimer.Stop();
            _instance = null;
            base.OnClosed(e);
        }
    }
}