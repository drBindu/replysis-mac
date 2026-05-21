using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace InterviewCopilotMac6.Views
{
    public partial class SessionsWindow : Window
    {
        private static readonly FontFamily _uiFont =
            new FontFamily("SF Pro Display, Segoe UI, sans-serif");

        private string AppDataFolder => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library", "Application Support", "InterviewCopilot");

        private readonly ObservableCollection<SessionInfo> _sessions = new();
        private SessionInfo? _selectedSession;

        public SessionsWindow()
        {
            InitializeComponent();
            Opened += (s, e) => LoadSessions();
        }

        // ══════════════════════════════════════════════════════════════════════
        // LOAD & DISPLAY
        // ══════════════════════════════════════════════════════════════════════

        private void LoadSessions()
        {
            _sessions.Clear();

            if (!Directory.Exists(AppDataFolder))
            {
                ShowEmptyState();
                return;
            }

            var files = Directory.GetFiles(AppDataFolder, "interview_*.txt")
                .OrderByDescending(f => File.GetLastWriteTime(f))
                .ToList();

            if (files.Count == 0)
            {
                ShowEmptyState();
                return;
            }

            EmptyState.IsVisible = false;

            foreach (var file in files)
            {
                try
                {
                    var info = ParseSessionFile(file);
                    _sessions.Add(info);
                }
                catch { }
            }

            SessionsList.ItemsSource = _sessions;
            SubtitleLabel.Text = $"{_sessions.Count} session{(_sessions.Count != 1 ? "s" : "")} recorded";
        }

        private void ShowEmptyState()
        {
            EmptyState.IsVisible = true;
            SubtitleLabel.Text = "No sessions yet";
        }

        private static SessionInfo ParseSessionFile(string path)
        {
            var lines = File.ReadAllLines(path);
            var created = File.GetLastWriteTime(path);

            string header = lines.Length > 0 ? lines[0].Trim() : "";
            int sessionNum = 0;
            string modelName = "—";
            DateTime sessionDate = created;

            if (header.StartsWith("SESSION "))
            {
                var parts = header.Split('|');
                if (parts.Length >= 1)
                    int.TryParse(parts[0].Replace("SESSION", "").Trim(), out sessionNum);
                if (parts.Length >= 2)
                    modelName = parts[1].Trim();
                if (parts.Length >= 3 && DateTime.TryParse(parts[2].Trim(), out var parsed))
                    sessionDate = parsed;
            }

            int qCount = lines.Count(l => l.StartsWith("Q: "));
            int aCount = lines.Count(l => l.StartsWith("A: "));

            return new SessionInfo
            {
                FilePath = path,
                SessionNumber = sessionNum,
                CreatedAt = sessionDate,
                QuestionCount = qCount,
                AnswerCount = aCount,
                ModelName = modelName,
                AllLines = lines
            };
        }

        // ══════════════════════════════════════════════════════════════════════
        // Q&A PARSER
        // ══════════════════════════════════════════════════════════════════════

        private static List<(string Q, string A)> ParseQaPairs(string[] lines)
        {
            var pairs = new List<(string Q, string A)>();
            string currentQ = "";
            var currentA = new System.Text.StringBuilder();
            bool inAnswer = false;

            foreach (var line in lines)
            {
                if (line.StartsWith("Q: "))
                {
                    if (!string.IsNullOrWhiteSpace(currentQ))
                        pairs.Add((currentQ, currentA.ToString().Trim()));
                    currentQ = line.Substring(3).Trim();
                    currentA.Clear();
                    inAnswer = false;
                }
                else if (line.StartsWith("A: "))
                {
                    currentA.Clear();
                    currentA.AppendLine(line.Substring(3).Trim());
                    inAnswer = true;
                }
                else if (inAnswer && !string.IsNullOrWhiteSpace(line))
                {
                    currentA.AppendLine(line.Trim());
                }
            }

            if (!string.IsNullOrWhiteSpace(currentQ))
                pairs.Add((currentQ, currentA.ToString().Trim()));

            return pairs;
        }

        // ══════════════════════════════════════════════════════════════════════
        // TRANSCRIPT RENDERING
        // ══════════════════════════════════════════════════════════════════════

        private void SessionsList_SelectionChanged(object? sender, SelectionChangedEventArgs e)
        {
            if (SessionsList.SelectedItem is not SessionInfo info) return;
            _selectedSession = info;

            DetailHeader.IsVisible = true;
            DetailTitle.Text = info.DisplayTitle;
            DetailMeta.Text = $"{info.DisplayDate}  ·  {info.DisplayStats}  ·  {info.DisplayModel}";
            DeleteBtn.IsVisible = true;

            RenderTranscript(info);
        }

        private void RenderTranscript(SessionInfo info)
        {
            TranscriptPanel.Children.Clear();
            NoSelectionState.IsVisible = false;
            TranscriptScroll.IsVisible = true;

            var pairs = ParseQaPairs(info.AllLines);

            if (pairs.Count == 0)
            {
                AddTextBlock("No Q&A recorded in this session.", "#6b7280", 13, false);
                return;
            }

            var ff = _uiFont;
            int i = 1;

            foreach (var (q, a) in pairs)
            {
                // Exchange badge
                var badge = new Border
                {
                    Background = new SolidColorBrush(Color.Parse("#1E3A5F")),
                    CornerRadius = new CornerRadius(6),
                    Padding = new Thickness(8, 3, 8, 3),
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Margin = new Thickness(0, 0, 0, 8)
                };
                badge.Child = new TextBlock
                {
                    Text = $"Exchange {i}",
                    Foreground = new SolidColorBrush(Color.Parse("#38BDF8")),
                    FontSize = 10,
                    FontWeight = FontWeight.SemiBold,
                    FontFamily = ff
                };
                TranscriptPanel.Children.Add(badge);

                // Question block
                var qBorder = new Border
                {
                    Background = new SolidColorBrush(Color.FromArgb(180, 15, 20, 40)),
                    CornerRadius = new CornerRadius(8),
                    BorderBrush = new SolidColorBrush(Color.FromArgb(60, 255, 255, 255)),
                    BorderThickness = new Thickness(1),
                    Padding = new Thickness(14, 10, 14, 10),
                    Margin = new Thickness(0, 0, 0, 6)
                };
                var qStack = new StackPanel();
                qStack.Children.Add(new TextBlock
                {
                    Text = "INTERVIEWER",
                    Foreground = new SolidColorBrush(Color.Parse("#6b7280")),
                    FontSize = 9,
                    FontWeight = FontWeight.Bold,
                    FontFamily = ff,
                    Margin = new Thickness(0, 0, 0, 4)
                });
                qStack.Children.Add(new TextBlock
                {
                    Text = q,
                    Foreground = new SolidColorBrush(Color.Parse("#CBD5E1")),
                    FontSize = 13,
                    FontFamily = ff,
                    TextWrapping = TextWrapping.Wrap
                });
                qBorder.Child = qStack;
                TranscriptPanel.Children.Add(qBorder);

                // Answer block
                if (!string.IsNullOrWhiteSpace(a))
                {
                    var aBorder = new Border
                    {
                        Background = new SolidColorBrush(Color.FromArgb(180, 8, 15, 30)),
                        CornerRadius = new CornerRadius(8),
                        BorderBrush = new SolidColorBrush(Color.FromArgb(80, 30, 90, 80)),
                        BorderThickness = new Thickness(1),
                        Padding = new Thickness(14, 10, 14, 10),
                        Margin = new Thickness(20, 0, 0, 16)
                    };
                    var aStack = new StackPanel();
                    aStack.Children.Add(new TextBlock
                    {
                        Text = "CANDIDATE",
                        Foreground = new SolidColorBrush(Color.Parse("#4ade80")),
                        FontSize = 9,
                        FontWeight = FontWeight.Bold,
                        FontFamily = ff,
                        Margin = new Thickness(0, 0, 0, 4)
                    });
                    aStack.Children.Add(new TextBlock
                    {
                        Text = a,
                        Foreground = new SolidColorBrush(Color.Parse("#E2E8F0")),
                        FontSize = 13,
                        FontFamily = ff,
                        TextWrapping = TextWrapping.Wrap
                    });
                    aBorder.Child = aStack;
                    TranscriptPanel.Children.Add(aBorder);
                }
                i++;
            }

            // Scroll to top after render
            Dispatcher.UIThread.Post(() => TranscriptScroll.Offset = new Vector(0, 0),
                DispatcherPriority.Render);
        }

        private void AddTextBlock(string text, string hex, int size, bool bold)
        {
            TranscriptPanel.Children.Add(new TextBlock
            {
                Text = text,
                Foreground = new SolidColorBrush(Color.Parse(hex)),
                FontSize = size,
                FontWeight = bold ? FontWeight.Bold : FontWeight.Normal,
                FontFamily = _uiFont,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 8)
            });
        }

        // ══════════════════════════════════════════════════════════════════════
        // DELETE
        // ══════════════════════════════════════════════════════════════════════

        private async void DeleteBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            if (_selectedSession == null) return;

            bool confirmed = await ShowConfirmDialogAsync(
                $"Delete \"{_selectedSession.DisplayTitle}\" ({_selectedSession.DisplayDate})?\n\nThis cannot be undone.",
                "Delete Session");

            if (!confirmed) return;

            try
            {
                if (File.Exists(_selectedSession.FilePath))
                    File.Delete(_selectedSession.FilePath);

                TranscriptPanel.Children.Clear();
                TranscriptScroll.IsVisible = false;
                NoSelectionState.IsVisible = true;
                DetailHeader.IsVisible = false;
                DeleteBtn.IsVisible = false;
                _selectedSession = null;

                LoadSessions();
            }
            catch (Exception ex)
            {
                await ShowErrorDialogAsync($"Could not delete session: {ex.Message}");
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // COPY TRANSCRIPT
        // ══════════════════════════════════════════════════════════════════════

        private async void CopyTranscriptBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            if (_selectedSession == null) return;

            var pairs = ParseQaPairs(_selectedSession.AllLines);
            var sb = new System.Text.StringBuilder();
            sb.AppendLine(_selectedSession.DisplayTitle);
            sb.AppendLine(_selectedSession.DisplayDate);
            sb.AppendLine(_selectedSession.DisplayStats);
            sb.AppendLine(new string('─', 50));
            sb.AppendLine();

            int exchangeNum = 1;
            foreach (var (q, a) in pairs)
            {
                sb.AppendLine($"[Exchange {exchangeNum++}]");
                sb.AppendLine($"INTERVIEWER: {q}");
                sb.AppendLine($"CANDIDATE:   {a}");
                sb.AppendLine();
            }

            try
            {
                var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
                if (clipboard != null)
                    await clipboard.SetTextAsync(sb.ToString());

                CopyTranscriptBtn.Content = "✓ Copied!";
                var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
                timer.Tick += (s, _) => { CopyTranscriptBtn.Content = "📋 Copy Text"; timer.Stop(); };
                timer.Start();
            }
            catch (Exception ex)
            {
                await ShowErrorDialogAsync($"Copy failed: {ex.Message}");
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // EXPORT
        // ══════════════════════════════════════════════════════════════════════

        private async void ExportBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            if (_selectedSession == null) return;

            try
            {
                var sp = TopLevel.GetTopLevel(this)?.StorageProvider;
                if (sp == null) return;

                string defaultName = $"InterviewSession_{_selectedSession.SessionNumber}_{_selectedSession.CreatedAt:yyyy-MM-dd}.txt";

                var file = await sp.SaveFilePickerAsync(new Avalonia.Platform.Storage.FilePickerSaveOptions
                {
                    Title = "Export Session Transcript",
                    SuggestedFileName = defaultName,
                    FileTypeChoices = new[]
                    {
                        new Avalonia.Platform.Storage.FilePickerFileType("Text File")
                        {
                            Patterns = new[] { "*.txt" }
                        }
                    }
                });

                if (file == null) return;

                if (!File.Exists(_selectedSession.FilePath))
                {
                    await ShowErrorDialogAsync("Session file no longer exists on disk.");
                    return;
                }

                await using var dest = await file.OpenWriteAsync();
                await using var src  = File.OpenRead(_selectedSession.FilePath);
                await src.CopyToAsync(dest);
            }
            catch (Exception ex)
            {
                await ShowErrorDialogAsync($"Export failed: {ex.Message}");
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // DIALOG HELPER (replaces WPF MessageBox)
        // ══════════════════════════════════════════════════════════════════════

        private Task ShowErrorDialogAsync(string message) =>
            ShowConfirmDialogAsync(message, "Error", isConfirm: false);

        private async Task<bool> ShowConfirmDialogAsync(string message, string title, bool isConfirm = true)
        {
            bool result = false;

            var dialog = new Window
            {
                Title = title,
                Width = 400,
                Height = 180,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                Background = new SolidColorBrush(Color.Parse("#0d1117")),
                CanResize = false,
                SystemDecorations = SystemDecorations.BorderOnly
            };

            var panel = new StackPanel { Margin = new Thickness(24) };
            panel.Children.Add(new TextBlock
            {
                Text = message,
                Foreground = Brushes.White,
                FontSize = 13,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 16)
            });

            var btnRow = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right
            };

            if (isConfirm)
            {
                var cancelBtn = new Button
                {
                    Content = "Cancel",
                    Padding = new Thickness(14, 7),
                    Margin = new Thickness(0, 0, 8, 0),
                    Background = Brushes.Transparent,
                    Foreground = new SolidColorBrush(Color.Parse("#6b7280")),
                    BorderThickness = new Thickness(0)
                };
                cancelBtn.Click += (_, _) => dialog.Close();
                btnRow.Children.Add(cancelBtn);

                var yesBtn = new Button
                {
                    Content = "Delete",
                    Padding = new Thickness(14, 7),
                    Background = new SolidColorBrush(Color.Parse("#991b1b")),
                    Foreground = Brushes.White,
                    BorderThickness = new Thickness(0),
                    CornerRadius = new CornerRadius(6)
                };
                yesBtn.Click += (_, _) => { result = true; dialog.Close(); };
                btnRow.Children.Add(yesBtn);
            }
            else
            {
                var okBtn = new Button
                {
                    Content = "OK",
                    Padding = new Thickness(14, 7),
                    Background = new SolidColorBrush(Color.Parse("#1E3A5F")),
                    Foreground = Brushes.White,
                    BorderThickness = new Thickness(0),
                    CornerRadius = new CornerRadius(6)
                };
                okBtn.Click += (_, _) => dialog.Close();
                btnRow.Children.Add(okBtn);
            }

            panel.Children.Add(btnRow);
            dialog.Content = panel;

            await dialog.ShowDialog(this);
            return result;
        }

        // ══════════════════════════════════════════════════════════════════════
        // WINDOW CHROME
        // ══════════════════════════════════════════════════════════════════════

        private void TitleBar_PointerPressed(object? sender, PointerPressedEventArgs e)
        {
            try { BeginMoveDrag(e); } catch { }
        }

        private void CloseBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e) => Close();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // DATA MODEL
    // ══════════════════════════════════════════════════════════════════════════

    public class SessionInfo
    {
        public string FilePath { get; set; } = "";
        public int SessionNumber { get; set; }
        public DateTime CreatedAt { get; set; }
        public int QuestionCount { get; set; }
        public int AnswerCount { get; set; }
        public string ModelName { get; set; } = "";
        public string[] AllLines { get; set; } = Array.Empty<string>();

        public string DisplayTitle =>
            SessionNumber > 0 ? $"Session #{SessionNumber}" : "Session";

        public string DisplayDate =>
            CreatedAt.ToString("MMM dd, yyyy  ·  h:mm tt");

        public string DisplayStats =>
            $"{QuestionCount} question{(QuestionCount != 1 ? "s" : "")}";

        public string DisplayModel =>
            string.IsNullOrWhiteSpace(ModelName) || ModelName == "—"
                ? ""
                : ModelName.Length > 20 ? ModelName.Substring(0, 20) + "…" : ModelName;
    }
}
