using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Threading;
using System;

namespace InterviewCopilotMac6.Views
{
    public partial class AnswerWindow : Window
    {
        public bool IsCameraModeActive = false;
        public event Action? CameraModeClosedByUser;
        public event Action? SpacePressed;

        private static readonly SolidColorBrush _brushThinking  = new(Colors.Orange);
        private static readonly SolidColorBrush _brushListening = new(Colors.LimeGreen);
        private static readonly SolidColorBrush _brushMuted     = new(Color.FromRgb(239, 68, 68));

        public AnswerWindow()
        {
            InitializeComponent();

            this.Opened += (s, e) =>
            {
                // Position: top-center of screen
                var screen = Screens.Primary;
                if (screen != null)
                {
                    var workArea = screen.WorkingArea;
                    this.Position = new PixelPoint(
                        (int)((workArea.Width / screen.Scaling - this.Width) / 2),
                        8
                    );
                }

                ApplyOverlayOpacity();

                // Grab focus so keyboard events work immediately
                this.Focus();
            };

            CloseButton.Click += HideOverlay_Click;
        }

        public void ApplyOverlayOpacity()
        {
            double opacity = SettingsWindow.GetOverlayOpacity();
            MainBorder.Opacity = IsCameraModeActive ? opacity : 0;
        }

        public void ToggleCameraMode(bool active)
        {
            IsCameraModeActive = active;
            if (active)
            {
                this.Show();
                MainBorder.Opacity = SettingsWindow.GetOverlayOpacity();

                // Force focus to this window so spacebar works immediately
                Dispatcher.UIThread.Post(() =>
                {
                    this.Activate();
                    this.Focus();
                });
            }
            else
            {
                MainBorder.Opacity = 0;
                this.Hide();
            }
        }

        public void UpdateMicState(bool isListening, bool isProcessing)
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (isProcessing)
                {
                    MicStatusLabel.Text   = "THINKING...";
                    MiniMicIndicator.Fill = _brushThinking;
                }
                else if (isListening)
                {
                    MicStatusLabel.Text   = "LISTENING";
                    MiniMicIndicator.Fill = _brushListening;
                }
                else
                {
                    MicStatusLabel.Text   = "READY";
                    MiniMicIndicator.Fill = _brushMuted;
                }
            });
        }

        public void UpdateQuestion(string text)
        {
            Dispatcher.UIThread.Post(() =>
            {
                QuestionTextBlock.Text = string.IsNullOrWhiteSpace(text)
                    ? "Waiting for audio..."
                    : text;
            });
        }

        public void UpdateAnswer(string text)
        {
            Dispatcher.UIThread.Post(() =>
            {
                if (string.IsNullOrWhiteSpace(text))
                {
                    AnswerTextBlock.Text = "";
                    return;
                }
                AnswerTextBlock.Text = FormatForReading(text);
                // Keep the latest streamed text in view as the answer grows.
                AnswerScroll.ScrollToEnd();
            });
        }

        // Called by MainWindow to reset UI for a fresh question
        public void ResetForNewQuestion()
        {
            Dispatcher.UIThread.Post(() =>
            {
                AnswerTextBlock.Text = "Listening...";
                QuestionTextBlock.Text = "Waiting for audio...";
                AnswerScroll.ScrollToHome();
            });
        }

        private static string FormatForReading(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return text;
            text = text.Replace("\r\n", "\n").Replace("\r", "\n");

            if (text.Contains("•"))
            {
                var lines = text.Split('\n');
                var result = new System.Text.StringBuilder();
                foreach (var line in lines)
                {
                    string trimmed = line.Trim();
                    if (trimmed.StartsWith("•"))
                    {
                        if (result.Length > 0)
                            result.AppendLine();
                        result.AppendLine(trimmed);
                    }
                    else if (!string.IsNullOrWhiteSpace(trimmed))
                    {
                        result.AppendLine(trimmed);
                    }
                }
                return result.ToString().Trim();
            }
            return text.Trim();
        }

        // Space key — fires SpacePressed event back to MainWindow
        private void Window_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.Key == Key.Space)
            {
                e.Handled = true; // prevent space from triggering any button
                SpacePressed?.Invoke();
            }
        }

        private void HideOverlay_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            ToggleCameraMode(false);
            CameraModeClosedByUser?.Invoke();
        }
    }
}
