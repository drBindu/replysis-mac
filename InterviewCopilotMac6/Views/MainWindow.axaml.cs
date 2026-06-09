using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.IO;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Threading;

namespace InterviewCopilotMac6.Views
{
    public partial class MainWindow : Window
    {
        private const string BackendUrl = "https://coopilotxai.com";

        // ── Tunable constants ──────────────────────────────────────────
        private const int TranscriptPollMs         = 150;
        private const int ThinkingAnimMs           = 800;
        private const int CreditRefreshMinutes     = 5;
        private const int EngineMonitorSecs        = 3;
        private const int CreditsLowThreshold      = 20;
        private const int CreditsCriticalThreshold = 5;
        private const int TranscriptRetryCount     = 3;
        private const int TranscriptRetryDelayMs   = 10;

        private bool isMuted = true;
        private bool isListening = false;
        private bool isProcessing = false;
        private bool isRecording = false;
        private bool _resumeCollapsed = false;
        private bool _isCameraMode = false;
        private int _audioDeviceId = -1;
        private bool _justStartedListening = false;
        private int  _listenStartTicks = 0;
        private bool _isScreenAnalyzing = false;

        private AnswerWindow? _answerWindow;
        private Action? _cameraModeClosedHandler;

        private DispatcherTimer? transcriptTimer;
        private DispatcherTimer? thinkingTimer;
        private DispatcherTimer? creditsRefreshTimer;
        private DispatcherTimer? _sessionTimer;
        private DispatcherTimer? _engineMonitorTimer;
        private int _sessionSeconds = 0;
        private int thinkingStep = 0;

        private Process? speechmaticsProcess;
        private CancellationTokenSource _engineCts = new CancellationTokenSource();
        private string projectRoot = "";
        private string scriptFolder = "";

        private int sessionNumber = 1;
        private string sessionLogPath = "";

        private GlobalHotkey? _globalHotkey;
        private static DebugWindow? _debugWindowInst;
        private CancellationTokenSource _aiCts = new CancellationTokenSource();

        // HTTP — shared singletons
        private static HttpClient _backendClient => SharedHttpClient.Http;
        private static HttpClient _creditsClient => SharedHttpClient.HttpShort;

        // Cached once — avoids Directory.CreateDirectory on every 150ms timer tick
        private readonly string AppDataFolder = InitAppDataFolder();
        private static string InitAppDataFolder()
        {
            string p = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "Library", "Application Support", "InterviewCopilot");
            Directory.CreateDirectory(p);
            return p;
        }


        public MainWindow()
        {
            InitializeComponent();

            projectRoot = AppDomain.CurrentDomain.BaseDirectory;
            scriptFolder = FindScriptFolder(projectRoot);

            this.Opened += async (s, e) =>
            {
                await Task.Delay(1500);
                IntroLayer.IsVisible = false;

                await NuclearKillOldProcesses();

                isMuted = true;
                isListening = false;
                WritePauseFlag();
                UpdateMicUi();

                SavePathLabel.Text = AppDataFolder;

                ApplyMainWindowOpacity();
                StartSpeechmaticsEngine();

                _answerWindow = new AnswerWindow();
                _cameraModeClosedHandler = () => Dispatcher.UIThread.Post(() => ExitCameraMode());
                _answerWindow.CameraModeClosedByUser += _cameraModeClosedHandler;
                _answerWindow.SpacePressed += () => HandleSpacePress("CAMERA_OVERLAY");

                try
                {
                    _globalHotkey = new GlobalHotkey(
                        onSpacePressed: () => Dispatcher.UIThread.Post(() => HandleSpacePress("GLOBAL")),
                        onF12Pressed:   () => Dispatcher.UIThread.Post(() => ToggleDebugMode()),
                        onKillPressed:  () => Dispatcher.UIThread.Post(() => Close()),
                        onF9Pressed:    () => Dispatcher.UIThread.Post(() => _ = RunScreenAnalysis()),
                        onF8Pressed:    () => Dispatcher.UIThread.Post(() => _ = RunScreenAnalysis())
                    );
                }
                catch (Exception ex) { DebugWindow.Log("HOTKEY_ERR", $"Global hotkey failed: {ex.Message}"); }

                _engineMonitorTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(EngineMonitorSecs) };
                _engineMonitorTimer.Tick += (s2, e2) => MonitorEngine();
                _engineMonitorTimer.Start();

                // ── Session restore with silent token refresh ──────────────
                bool sessionRestored = UserSession.TryLoadFromDisk();
                if (!sessionRestored && !string.IsNullOrEmpty(UserSession.RefreshToken))
                {
                    DebugWindow.Log("AUTH", "idToken expired — attempting silent refresh…");
                    sessionRestored = await UserSession.TryRefreshAsync();
                    if (sessionRestored)
                        DebugWindow.Log("AUTH", "Silent token refresh succeeded");
                    else
                        DebugWindow.Log("AUTH", "Silent refresh failed — user must re-login");
                }

                if (sessionRestored)
                {
                    await FetchAndDisplayCreditsAsync();
                    UpdateProfileUI();
                    StartNewSession();
                }
                else
                {
                    SetLoggedOutUI();
                }

                creditsRefreshTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(CreditRefreshMinutes) };
                creditsRefreshTimer.Tick += async (s2, e2) =>
                {
                    try { if (UserSession.IsLoggedIn) await FetchAndDisplayCreditsAsync(); }
                    catch (Exception ex) { DebugWindow.Log("CREDITS_TIMER", ex.Message); }
                };
                creditsRefreshTimer.Start();
            };

            transcriptTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(TranscriptPollMs) };
            transcriptTimer.Tick += (s, e) => UpdateTranscript();
            transcriptTimer.Start();

            thinkingTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(ThinkingAnimMs) };
            thinkingTimer.Tick += (s, e) =>
            {
                if (_isScreenAnalyzing) return;
                thinkingStep++;
                string dots = new string('.', thinkingStep % 4);
                ThinkingLabel.Text = "Thinking" + dots;
                if (_isCameraMode && _answerWindow != null)
                    _answerWindow.UpdateAnswer("Thinking" + dots);
            };
        }

        // ══════════════════════════════════════════════════════════════════════
        // LOGIN / LOGOUT
        // ══════════════════════════════════════════════════════════════════════
        private async void SignInHeaderBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            var loginWin = new LoginWindow();
            await loginWin.ShowDialog(this);
            if (loginWin.LoginSuccess)
            {
                UpdateProfileUI();
                await FetchAndDisplayCreditsAsync();
                StartNewSession();
                DebugWindow.Log("AUTH", $"Logged in: {UserSession.Email}");
            }
        }

        private async void ProfileBadge_Click(object? sender, PointerPressedEventArgs e)
        {
            var dialog = new Window
            {
                Title = "CoopilotX Account",
                Width = 360, Height = 160,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                Background = new SolidColorBrush(Color.Parse("#0d1117")),
                CanResize = false,
                SystemDecorations = SystemDecorations.BorderOnly
            };

            var panel = new StackPanel { Margin = new Thickness(24) };
            panel.Children.Add(new TextBlock
            {
                Text = $"Signed in as {UserSession.Email}\n\nSign out?",
                Foreground = Brushes.White,
                FontSize = 13,
                TextWrapping = Avalonia.Media.TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 16)
            });

            bool signOut = false;
            var btnRow = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right };
            var cancelBtn = new Button { Content = "Cancel", Padding = new Thickness(14, 7), Margin = new Thickness(0, 0, 8, 0), Background = Brushes.Transparent, Foreground = new SolidColorBrush(Color.Parse("#6b7280")), BorderThickness = new Thickness(0) };
            var yesBtn = new Button { Content = "Sign Out", Padding = new Thickness(14, 7), Background = new SolidColorBrush(Color.Parse("#991b1b")), Foreground = Brushes.White, BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(6) };
            cancelBtn.Click += (_, _) => dialog.Close();
            yesBtn.Click += (_, _) => { signOut = true; dialog.Close(); };
            btnRow.Children.Add(cancelBtn);
            btnRow.Children.Add(yesBtn);
            panel.Children.Add(btnRow);
            dialog.Content = panel;

            await dialog.ShowDialog(this);
            if (signOut)
            {
                UserSession.Clear();
                SetLoggedOutUI();
                DebugWindow.Log("AUTH", "Signed out");
            }
        }

        private void UpdateProfileUI()
        {
            if (!UserSession.IsLoggedIn) { SetLoggedOutUI(); return; }

            ProfileBadge.IsVisible    = true;
            SignInHeaderBtn.IsVisible = false;
            SessionsBtn.IsVisible     = true;
            AvatarInitials.Text       = UserSession.Initials;
            ProfileNameLabel.Text     = UserSession.Name.Split(' ')[0];
            ProfilePlanLabel.Text     = $"{UserSession.Plan} plan";

            AvatarInitials.Foreground = UserSession.IsUnlimited
                ? new SolidColorBrush(Color.Parse("#a78bfa"))
                : Brushes.White;
        }

        private void SetLoggedOutUI()
        {
            ProfileBadge.IsVisible    = false;
            SignInHeaderBtn.IsVisible = true;
            SessionsBtn.IsVisible     = false;
            CreditsLabel.Text         = "Sign in";
            CreditsLabel.Foreground   = new SolidColorBrush(Color.Parse("#6b7280"));
            CreditsPlanLabel.IsVisible = false;
            CreditsIcon.Text          = "⚡";
            SetCreditsBadgeStyle("#1a1f2e", "#33FFFFFF");

            if (isRecording) EndSession();
        }

        // ══════════════════════════════════════════════════════════════════════
        // CREDITS
        // ══════════════════════════════════════════════════════════════════════
        private async Task FetchAndDisplayCreditsAsync()
        {
            if (!UserSession.IsLoggedIn) return;
            await UserSession.TryRefreshAsync();
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get,
                    $"{BackendUrl}/api/v1/interview/credits");
                req.Headers.Add("Authorization", $"Bearer {UserSession.IdToken}");

                using var res = await _creditsClient.SendAsync(req);
                string body = await res.Content.ReadAsStringAsync();

                if (!res.IsSuccessStatusCode)
                {
                    DebugWindow.Log("CREDITS", $"HTTP {(int)res.StatusCode}: {body}");
                    Dispatcher.UIThread.Post(() => CreditsLabel.Text = "Offline");
                    return;
                }

                using var doc = JsonDocument.Parse(body);
                int credits     = doc.RootElement.TryGetProperty("credits",    out var c) ? c.GetInt32()    : 0;
                string plan     = doc.RootElement.TryGetProperty("plan",       out var p) ? p.GetString() ?? "free" : "free";
                bool isUnlimited = doc.RootElement.TryGetProperty("isUnlimited", out var u) ? u.GetBoolean() : false;

                UserSession.Credits     = credits;
                UserSession.Plan        = plan;
                UserSession.IsUnlimited = isUnlimited;

                Dispatcher.UIThread.Post(() =>
                {
                    CreditsPlanLabel.IsVisible = true;
                    ProfilePlanLabel.Text      = $"{plan} plan";

                    if (isUnlimited)
                    {
                        CreditsLabel.Text      = "∞  Pro";
                        CreditsLabel.Foreground = new SolidColorBrush(Color.Parse("#a78bfa"));
                        CreditsPlanLabel.Text  = "Unlimited";
                        CreditsIcon.Text       = "👑";
                        SetCreditsBadgeStyle("#1a0a2e", "#7c3aed");
                    }
                    else
                    {
                        string display = credits >= 1000 ? $"{credits / 1000.0:F1}k" : credits.ToString("N0");
                        CreditsLabel.Text  = $"⚡ {display}";
                        CreditsPlanLabel.Text = plan;
                        CreditsIcon.Text   = "";

                        if (credits > CreditsLowThreshold)
                        {
                            SetCreditsBadgeStyle("#0f2a1a", "#1a6b3a");
                            CreditsLabel.Foreground = new SolidColorBrush(Color.Parse("#4ade80"));
                        }
                        else if (credits > CreditsCriticalThreshold)
                        {
                            SetCreditsBadgeStyle("#2a1a0a", "#6b4a1a");
                            CreditsLabel.Foreground = new SolidColorBrush(Color.Parse("#f59e0b"));
                        }
                        else
                        {
                            SetCreditsBadgeStyle("#2a0a0a", "#6b1a1a");
                            CreditsLabel.Foreground = new SolidColorBrush(Color.Parse("#ef4444"));
                        }
                    }
                });

                DebugWindow.Log("CREDITS", $"{(isUnlimited ? "Unlimited" : $"{credits} credits")} | {plan}");
            }
            catch (Exception ex)
            {
                Dispatcher.UIThread.Post(() => CreditsLabel.Text = "—");
                DebugWindow.Log("CREDITS_ERR", ex.Message);
            }
        }

        private void SetCreditsBadgeStyle(string bg, string border)
        {
            CreditsBadge.Background  = new SolidColorBrush(Color.Parse(bg));
            CreditsBadge.BorderBrush = new SolidColorBrush(Color.Parse(border));
        }

        private void CreditsBadge_Click(object? sender, PointerPressedEventArgs e)
        {
            if (!UserSession.IsLoggedIn) { SignInHeaderBtn_Click(sender, new Avalonia.Interactivity.RoutedEventArgs()); return; }
            _ = FetchAndDisplayCreditsAsync().ContinueWith(t => {
                if (t.IsFaulted) DebugWindow.Log("CREDITS_ERR", t.Exception?.GetBaseException().Message ?? "unknown");
            }, TaskScheduler.Default);
        }

        // ══════════════════════════════════════════════════════════════════════
        // OPACITY / SCRIPT FOLDER
        // ══════════════════════════════════════════════════════════════════════
        private void ApplyMainWindowOpacity()
        {
            MainAppBorder.Opacity = SettingsWindow.GetMainWindowOpacity();
        }

        private static string FindPythonPath()
        {
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var candidates = new[]
            {
                Path.Combine(home, "interview_env",   "bin", "python3"),
                Path.Combine(home, "anaconda3",       "bin", "python3"),
                Path.Combine(home, "miniconda3",      "bin", "python3"),
                Path.Combine(home, "miniforge3",      "bin", "python3"),
                Path.Combine(home, "opt", "anaconda3","bin", "python3"),
                "/opt/homebrew/bin/python3",
                "/opt/homebrew/bin/python3.11",
                "/opt/homebrew/bin/python3.12",
                "/opt/homebrew/bin/python3.13",
                "/usr/local/bin/python3",
                "/usr/local/bin/python3.11",
                "/usr/local/bin/python3.12",
            };
            foreach (var c in candidates)
                if (File.Exists(c)) return c;
            return "python3";
        }

        private static string FindScriptFolder(string startDir)
        {
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string known = Path.Combine(home, "InterviewCopilot");
            // Check Contents/Resources — build workflow moves .py files there during signing
            string resourcesDir = Path.GetFullPath(Path.Combine(startDir, "..", "Resources"));
            if (File.Exists(Path.Combine(resourcesDir, "speechmatics_engine.py"))) return resourcesDir;
            if (File.Exists(Path.Combine(known, "speechmatics_engine.py"))) return known;
            if (File.Exists(Path.Combine(startDir, "speechmatics_engine.py"))) return startDir;
            string? dir = startDir;
            while (dir != null)
            {
                if (File.Exists(Path.Combine(dir, "speechmatics_engine.py"))) return dir;
                dir = Directory.GetParent(dir)?.FullName;
            }
            return known;
        }

        private static string FindOcrBinary()
        {
            // Walk up from BaseDirectory looking for ScreenOCR binary
            string? dir = AppDomain.CurrentDomain.BaseDirectory;
            while (dir != null)
            {
                string candidate = Path.Combine(dir, "ScreenOCR");
                if (File.Exists(candidate)) return candidate;
                dir = Directory.GetParent(dir)?.FullName;
            }
            return "";
        }

        // ══════════════════════════════════════════════════════════════════════
        // SESSIONS WINDOW
        // ══════════════════════════════════════════════════════════════════════
        private void SessionsBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            var win = new SessionsWindow();
            win.Show();
        }

        // ══════════════════════════════════════════════════════════════════════
        // SCREEN ANALYSIS  (F8 / F9 / button — vision AI, same as Windows)
        // ══════════════════════════════════════════════════════════════════════
        private void ScreenAnalyzeBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
            => _ = RunScreenAnalysis();

        private async Task RunScreenAnalysis()
        {
            if (isProcessing || _isScreenAnalyzing) return;

            if (!UserSession.IsLoggedIn)
            {
                AiAnswerBox.Text = "⚠ Please sign in to use Screen Analysis.\n\nClick the Sign In button in the top right.";
                return;
            }

            _isScreenAnalyzing = true;
            isProcessing = true;
            UpdateMicUi();

            double savedOpacity = this.Opacity;
            bool opacityRestored = false;

            try
            {
                // Cancel any in-progress AI request, set up fresh CT before capture
                // so OnClosed can interrupt the screencapture process if the app closes
                _aiCts.Cancel();
                _aiCts.Dispose();
                _aiCts = new CancellationTokenSource();
                var screenCt = _aiCts.Token;

                // ── Phase 1: capture ─────────────────────────────────────────────
                ThinkingLabel.Text      = "🔍  Capturing screen…";
                ThinkingHintLabel.IsVisible = false;
                ThinkingPanel.IsVisible = true;

                this.Opacity = 0;
                if (_answerWindow != null) _answerWindow.Opacity = 0;
                await Task.Delay(300);

                byte[] imageBytes = await ScreenAnalyzer.CaptureScreenAsync(screenCt);

                this.Opacity = savedOpacity;
                if (_answerWindow != null) _answerWindow.Opacity = SettingsWindow.GetOverlayOpacity();
                opacityRestored = true;

                if (imageBytes.Length == 0)
                {
                    AiAnswerBox.Text = "⚠ Screen capture failed.\n\nGrant Screen Recording permission:\nSystem Settings → Privacy & Security → Screen Recording → enable this app";
                    return;
                }

                // ── Phase 2: vision AI analysis ───────────────────────────────────
                string visionLabel = SettingsWindow.IsGroq() ? "Llama 4 Scout" : "GPT-4o";
                ThinkingLabel.Text = $"🤖  {visionLabel} analyzing…";

                string resumeCtx = ResumeParser.ExtractFacts(ResumeTextBox.Text ?? "");
                string timestamp = DateTime.Now.ToString("h:mm tt");
                string header    = $"📸 SCREEN ANALYSIS  [{timestamp}]\n\n";
                string sep       = "\n" + new string('─', 45) + "\n\n";

                bool isDefaultText = string.IsNullOrWhiteSpace(AiAnswerBox.Text)
                    || AiAnswerBox.Text.StartsWith("Ready")
                    || AiAnswerBox.Text.StartsWith("New session")
                    || AiAnswerBox.Text.StartsWith("Results will appear");
                string previousAnswers = isDefaultText ? "" : (AiAnswerBox.Text ?? "");

                var sb = new StringBuilder();
                int tokenCount = 0;

                try
                {
                    await foreach (var token in ScreenAnalyzer.AnalyzeStreamAsync(imageBytes, resumeCtx, screenCt))
                    {
                        sb.Append(token);
                        tokenCount++;

                        if (tokenCount == 1)
                            ThinkingPanel.IsVisible = false;

                        if (tokenCount % 3 == 0 || token.Contains('\n'))
                        {
                            AiAnswerBox.Text = $"{header}{sb}";
                            AiAnswerBox.CaretIndex = AiAnswerBox.Text.Length;
                            if (_isCameraMode && _answerWindow != null)
                                _answerWindow.UpdateAnswer(sb.ToString());
                        }
                    }
                }
                catch (OperationCanceledException)
                {
                    throw; // let outer catch handle cancellation cleanly
                }
                catch (Exception ex)
                {
                    DebugWindow.Log("SCREEN_ERR", $"Stream failed: {ex.Message}");
                    sb.Append($"\n⚠ Stream interrupted: {ex.Message}");
                }

                string finalResult = ScreenAnalyzer.PostProcess(sb.ToString());

                AiAnswerBox.Text = string.IsNullOrWhiteSpace(previousAnswers)
                    ? $"{header}{finalResult}"
                    : $"{header}{finalResult}\n{sep}{previousAnswers}";
                AiAnswerBox.CaretIndex = AiAnswerBox.Text.Length;

                if (_isCameraMode && _answerWindow != null)
                {
                    _answerWindow.UpdateAnswer(finalResult);
                    _answerWindow.UpdateQuestion("[Screen Analysis]");
                }

                AppendToSessionLog("[Screen Analysis]", finalResult);
                PromptBuilder.AddToHistory("Analyze what is currently on my screen", finalResult);

                DebugWindow.Log("SCREEN", $"Done — {tokenCount} tokens, {finalResult.Length} chars");
            }
            catch (OperationCanceledException)
            {
                DebugWindow.Log("SCREEN", "Screen analysis cancelled");
            }
            catch (Exception ex)
            {
                DebugWindow.Log("SCREEN_FATAL", $"RunScreenAnalysis failed: {ex.Message}");
                try { AiAnswerBox.Text = "⚠ Screen analysis encountered an error. Press F12 for details."; } catch { }
            }
            finally
            {
                // Restore window visibility if capture failed before we restored it
                if (!opacityRestored)
                {
                    try
                    {
                        this.Opacity = savedOpacity;
                        if (_answerWindow != null) _answerWindow.Opacity = SettingsWindow.GetOverlayOpacity();
                    }
                    catch { }
                }
                StopThinkingUi();
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // CAMERA MODE
        // ══════════════════════════════════════════════════════════════════════
        private void CameraMode_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            _isCameraMode = true;
            this.Hide();

            if (_answerWindow == null)
            {
                _answerWindow = new AnswerWindow();
                _cameraModeClosedHandler = () => Dispatcher.UIThread.Post(() => ExitCameraMode());
                _answerWindow.CameraModeClosedByUser += _cameraModeClosedHandler;
                _answerWindow.SpacePressed += () => HandleSpacePress("CAMERA_OVERLAY");
            }

            _answerWindow.ToggleCameraMode(true);
            _answerWindow.UpdateMicState(isListening, isProcessing);
        }

        private void ExitCameraMode_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
            => ExitCameraMode();

        private void ExitCameraMode()
        {
            _isCameraMode = false;
            _answerWindow?.ToggleCameraMode(false);
            this.Show();
            this.Height = 740;
            this.Width = 1120;
            ApplyMainWindowOpacity();
            Dispatcher.UIThread.Post(() => { this.Activate(); this.Focus(); });
        }

        // ══════════════════════════════════════════════════════════════════════
        // MIC / SPACE HANDLING
        // ══════════════════════════════════════════════════════════════════════
        private bool _spaceHandling = false;

        private void HandleSpacePress(string source)
        {
            if (_spaceHandling || isProcessing) return;
            _spaceHandling = true;
            try
            {
                if (isMuted)
                {
                    isMuted = false; isListening = true;
                    try { File.WriteAllText(Path.Combine(AppDataFolder, "latest.txt"), ""); } catch (Exception ex) { DebugWindow.Log("FILE", $"latest.txt clear failed: {ex.Message}"); }
                    try { File.WriteAllText(Path.Combine(AppDataFolder, "reset.flag"), "1"); } catch (Exception ex) { DebugWindow.Log("FILE", $"reset.flag write failed: {ex.Message}"); }
                    _justStartedListening = true;
                    _listenStartTicks = 0;
                    TranscriptTextBlock.Text = "";
                    TranscriptHint.IsVisible = true;
                    AiAnswerBox.Text = "";
                    if (_isCameraMode && _answerWindow != null) _answerWindow.ResetForNewQuestion();
                    DeletePauseFlag();
                    DebugWindow.Log("MIC", $"[{source}] UNMUTED");
                    UpdateMicUi();
                }
                else
                {
                    isListening = false; WritePauseFlag(); isMuted = true;
                    DebugWindow.Log("MIC", $"[{source}] MUTED — firing AI");
                    UpdateMicUi();
                    _ = AskAiAsync().ContinueWith(t =>
                    {
                        if (t.IsFaulted)
                        {
                            Exception ex = t.Exception?.GetBaseException() ?? t.Exception!;
                            DebugWindow.Log("AI_FATAL", ex.Message);
                            Dispatcher.UIThread.Post(() =>
                            {
                                AiAnswerBox.Text = "⚠ Unexpected error. Please try again. Press F12 for details.";
                                StopThinkingUi();
                            });
                        }
                    }, TaskScheduler.Default);
                }
            }
            finally { _spaceHandling = false; }
        }

        private void MicBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
            => HandleSpacePress("BUTTON");

        // ══════════════════════════════════════════════════════════════════════
        // AI
        // ══════════════════════════════════════════════════════════════════════
        private async Task AskAiAsync()
        {
            if (isProcessing) return;

            string q = "";
            try
            {
                string fullTranscript = TranscriptTextBlock.Text?.Trim() ?? "";
                if (string.IsNullOrWhiteSpace(fullTranscript)) { UpdateMicUi(); return; }

                q = ExtractLatestQuestion(fullTranscript);
                if (string.IsNullOrWhiteSpace(q)) { UpdateMicUi(); return; }

                if (UserSession.IsLoggedIn) await UserSession.TryRefreshAsync();

                if (!UserSession.IsLoggedIn)
                {
                    AiAnswerBox.Text = "⚠ Please sign in to use AI answers.\n\nClick the Sign In button in the top right.";
                    UpdateMicUi();
                    return;
                }

                if (!UserSession.IsUnlimited && UserSession.Credits < CreditsCriticalThreshold)
                {
                    AiAnswerBox.Text = $"⚠ Not enough credits ({UserSession.Credits} remaining).\n\nVisit coopilotxai.com/pricing to upgrade.";
                    UpdateMicUi();
                    return;
                }

                isProcessing = true; thinkingStep = 0;
                ThinkingPanel.IsVisible = true;
                thinkingTimer?.Start();
                UpdateMicUi();

                string sep = "\n" + new string('─', 45) + "\n\n";
                string old = AiAnswerBox.Text ?? "";
                if (old == "Results will appear here..." || old.StartsWith("Ready") || old.StartsWith("New session")) old = "";
                AiAnswerBox.Text = $"Q: {q}\n\n";
                if (_isCameraMode && _answerWindow != null) { _answerWindow.UpdateAnswer(""); _answerWindow.UpdateQuestion(q); }

                _aiCts.Cancel();
                _aiCts.Dispose();
                _aiCts = new CancellationTokenSource();
                var ct = _aiCts.Token;

                var sb = new StringBuilder();
                int tokenCount = 0;

                await foreach (var token in StreamFromBackend(q, ResumeTextBox.Text ?? "", ct))
                {
                    sb.Append(token);
                    tokenCount++;

                    if (tokenCount == 1)
                    {
                        thinkingTimer?.Stop();
                        ThinkingPanel.IsVisible = false;
                    }

                    if (tokenCount % 3 == 0 || token.Contains('\n'))
                    {
                        string soFar = sb.ToString();
                        AiAnswerBox.Text = $"Q: {q}\n\n{soFar}";
                        AiAnswerBox.CaretIndex = AiAnswerBox.Text.Length;
                        if (_isCameraMode && _answerWindow != null) _answerWindow.UpdateAnswer(soFar);
                    }
                }

                string final = CleanAiOutput(sb.ToString());
                AiAnswerBox.Text = $"Q: {q}\n\n{final}\n{sep}{old}";
                AiAnswerBox.CaretIndex = AiAnswerBox.Text.Length;
                if (_isCameraMode && _answerWindow != null) { _answerWindow.UpdateAnswer(final); _answerWindow.UpdateQuestion(q); }
                PromptBuilder.AddToHistory(q, final);
                AppendToSessionLog(q, final);
                DebugWindow.Log("AI", $"Done — {tokenCount} tokens");

                _ = FetchAndDisplayCreditsAsync().ContinueWith(t => {
                    if (t.IsFaulted) DebugWindow.Log("CREDITS_ERR", t.Exception?.GetBaseException().Message ?? "unknown");
                }, TaskScheduler.Default);
            }
            catch (OperationCanceledException)
            {
                DebugWindow.Log("AI", "Stream cancelled");
            }
            catch (Exception ex)
            {
                DebugWindow.Log("AI_ERR", ex.Message);
                AiAnswerBox.Text = $"{(string.IsNullOrWhiteSpace(q) ? "" : $"Q: {q}\n\n")}⚠ Something went wrong. Press F12 for details.";
            }
            finally { StopThinkingUi(); }
        }

        private async IAsyncEnumerable<string> StreamFromBackend(
            string question, string resume,
            [EnumeratorCancellation] CancellationToken ct = default)
        {
            if (PromptBuilder.IsGreeting(question)) { yield return PromptBuilder.GetGreetingResponse(); yield break; }
            if (PromptBuilder.IsSmallTalk(question)) { yield return PromptBuilder.GetSmallTalkResponse(); yield break; }

            using HttpResponseMessage res = await SendBackendRequestAsync(question, resume, ct);

            int status = (int)res.StatusCode;
            if (status == 402) { yield return "⚠ Not enough credits. Visit coopilotxai.com/pricing to upgrade."; yield break; }
            if (status == 401)
            {
                UserSession.Clear();
                Dispatcher.UIThread.Post(() => SetLoggedOutUI());
                yield return "⚠ Session expired. Please sign in again.";
                yield break;
            }
            if (!res.IsSuccessStatusCode) { yield return $"Backend error ({status}). Try again."; yield break; }

            // Stream tokens in real time — yield each token as it arrives rather than buffering
            await using var bodyStream = await res.Content.ReadAsStreamAsync(ct);
            using var reader = new StreamReader(bodyStream);

            while (!reader.EndOfStream && !ct.IsCancellationRequested)
            {
                string? line = await reader.ReadLineAsync(ct);
                if (string.IsNullOrWhiteSpace(line) || !line.StartsWith("data: ")) continue;
                string data = line["data: ".Length..];
                if (data == "[DONE]") break;

                string? token = TryParseSseToken(data);
                if (!string.IsNullOrEmpty(token)) yield return token;
            }
        }

        private async Task<HttpResponseMessage> SendBackendRequestAsync(
            string question, string resume, CancellationToken ct)
        {
            string resumeFacts = ResumeParser.ExtractFacts(resume);
            var (qType, isDrill) = PromptBuilder.ClassifyQuestion(question);
            var messages = PromptBuilder.BuildMessages(resumeFacts, question, qType, isDrill);
            string enhancedQuestion = PromptBuilder.BuildEnhancedQuestion(question, resumeFacts, qType, isDrill);
            var payload = new { question = enhancedQuestion, resume = resume ?? "", provider = "groq", messages };

            using var request = new HttpRequestMessage(HttpMethod.Post,
                $"{BackendUrl}/api/v1/interview/ask");
            request.Headers.Add("Authorization", $"Bearer {UserSession.IdToken}");
            request.Content = new StringContent(
                JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");

            try
            {
                return await _backendClient.SendAsync(
                    request, HttpCompletionOption.ResponseHeadersRead, ct);
            }
            catch (OperationCanceledException)
            {
                throw; // propagate — caller's OperationCanceledException handler shows clean message
            }
            catch (Exception ex)
            {
                DebugWindow.Log("AI_ERR", ex.Message);
                return new HttpResponseMessage(System.Net.HttpStatusCode.ServiceUnavailable);
            }
        }

        // Parse one SSE data line into a text token — returns null for empty/non-content events
        private static string? TryParseSseToken(string data)
        {
            try
            {
                using var doc = JsonDocument.Parse(data);
                if (doc.RootElement.TryGetProperty("error", out var errProp))
                    return $"⚠ Error: {errProp.GetString()}";
                if (!doc.RootElement.TryGetProperty("choices", out var choices) ||
                    choices.GetArrayLength() == 0) return null;
                var delta = choices[0].GetProperty("delta");
                return delta.TryGetProperty("content", out var cp) ? cp.GetString() : null;
            }
            catch { return null; }
        }

        private static string ExtractLatestQuestion(string transcript)
        {
            if (string.IsNullOrWhiteSpace(transcript)) return "";
            if (transcript.StartsWith("[Screen", StringComparison.OrdinalIgnoreCase)) return transcript;

            var sentences = _rxSentenceSplit.Split(transcript.Trim())
                                 .Select(s => s.Trim())
                                 .Where(s => s.Length > 4)
                                 .ToList();

            if (sentences.Count == 0) return transcript;
            int take = Math.Min(3, sentences.Count);
            string latest = string.Join(" ", sentences.TakeLast(take)).Trim();
            return latest.Length < 10 ? transcript : latest;
        }

        private static readonly Regex _rxSentenceSplit = new(@"(?<=[.!?])\s+",          RegexOptions.Compiled);
        private static readonly Regex _rxCodeFence     = new(@"```[a-z]*|```",          RegexOptions.Compiled);
        private static readonly Regex _rxBold        = new(@"\*{1,3}([^*\n]+)\*{1,3}", RegexOptions.Compiled);
        private static readonly Regex _rxItalicUs    = new(@"_{1,3}([^_\n]+)_{1,3}",  RegexOptions.Compiled);
        private static readonly Regex _rxHeading     = new(@"(?m)^#{1,6}\s+",          RegexOptions.Compiled);
        private static readonly Regex _rxMultiBlank  = new(@"\n{3,}",                  RegexOptions.Compiled);

        private static string CleanAiOutput(string ans)
        {
            ans = _rxCodeFence.Replace(ans, "").Trim();
            ans = _rxBold.Replace(ans, "$1");
            ans = _rxItalicUs.Replace(ans, "$1");
            ans = _rxHeading.Replace(ans, "");
            ans = ans.Replace("\r\n", "\n").Replace("\r", "\n");
            ans = _rxMultiBlank.Replace(ans, "\n\n");
            return ans.Trim();
        }

        private void StopThinkingUi()
        {
            thinkingTimer?.Stop();
            ThinkingPanel.IsVisible     = false;
            ThinkingHintLabel.IsVisible = true;
            ThinkingLabel.Text          = "Thinking...";
            isProcessing       = false;
            _isScreenAnalyzing = false;
            UpdateMicUi();
        }

        // ══════════════════════════════════════════════════════════════════════
        // SESSION
        // ══════════════════════════════════════════════════════════════════════
        private void StartNewSession()
        {
            // Guard against infinite loop on corrupted filesystem — cap at 10000 sessions
            while (sessionNumber < 10000 &&
                   File.Exists(Path.Combine(AppDataFolder, "interview_" + sessionNumber + ".txt")))
                sessionNumber++;

            sessionLogPath = Path.Combine(AppDataFolder, "interview_" + sessionNumber + ".txt");

            string header = $"SESSION {sessionNumber} | {SettingsWindow.GetActiveModelId()} | {DateTime.Now:yyyy-MM-dd HH:mm:ss}";
            try { File.WriteAllText(sessionLogPath, header + "\n\n"); }
            catch (Exception ex) { DebugWindow.Log("SESSION_ERR", $"Log create failed: {ex.Message}"); sessionLogPath = ""; }
            try { File.WriteAllText(Path.Combine(AppDataFolder, "record.flag"), "1"); }
            catch (Exception ex) { DebugWindow.Log("SESSION_ERR", $"record.flag write failed: {ex.Message}"); }
            isRecording = true;

            PromptBuilder.ClearHistory();

            _sessionSeconds = 0;
            SessionTimerLabel.Text      = "0:00";
            SessionTimerBadge.IsVisible = true;

            _sessionTimer?.Stop();
            _sessionTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _sessionTimer.Tick += (s, e) =>
            {
                _sessionSeconds++;
                int m = _sessionSeconds / 60, s2 = _sessionSeconds % 60;
                SessionTimerLabel.Text = $"{m}:{s2:D2}";
            };
            _sessionTimer.Start();

            RecordingBadge.IsVisible = true;
            DebugWindow.Log("SESSION", $"Started session #{sessionNumber}");
        }

        private void AppendToSessionLog(string q, string a)
        {
            if (string.IsNullOrEmpty(sessionLogPath)) return;
            try { File.AppendAllText(sessionLogPath, $"Q: {q}\nA: {a}\n\n"); }
            catch (Exception ex) { DebugWindow.Log("LOG_ERR", ex.Message); }
        }

        private void EndSession()
        {
            string f = Path.Combine(AppDataFolder, "record.flag");
            try { if (File.Exists(f)) File.Delete(f); } catch { }
            isRecording    = false;
            sessionLogPath = "";

            _sessionTimer?.Stop();
            SessionTimerBadge.IsVisible = false;
            RecordingBadge.IsVisible    = false;

            PromptBuilder.ClearHistory();
            DebugWindow.Log("SESSION", "Session ended");
        }

        // ══════════════════════════════════════════════════════════════════════
        // TOOLBAR BUTTONS
        // ══════════════════════════════════════════════════════════════════════
        private async void CopyAnswerBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            if (string.IsNullOrWhiteSpace(AiAnswerBox.Text)) return;
            var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
            if (clipboard != null)
                await clipboard.SetTextAsync(AiAnswerBox.Text);
        }

        private void ClearAnswerBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            TranscriptTextBlock.Text  = "";
            TranscriptHint.IsVisible  = true;
            AiAnswerBox.Text = "Ready — press SPACE to start listening, then SPACE again to get your answer.";
            if (_answerWindow != null) { _answerWindow.UpdateAnswer(""); _answerWindow.UpdateQuestion(""); }
            PromptBuilder.ClearHistory();
            try { File.WriteAllText(Path.Combine(AppDataFolder, "latest.txt"), ""); } catch { }
        }

        private void NewSessionBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            if (isProcessing) return;
            EndSession();
            sessionNumber++;
            TranscriptTextBlock.Text = "";
            TranscriptHint.IsVisible = true;
            AiAnswerBox.Text = "New session started — press SPACE to begin.";
            if (_answerWindow != null) { _answerWindow.UpdateAnswer(""); _answerWindow.UpdateQuestion(""); }
            StartNewSession();
        }

        private void MinimizeBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
            => WindowState = WindowState.Minimized;

        private void ResumeTextBox_TextChanged(object? sender, Avalonia.Controls.TextChangedEventArgs e)
        {
            ResumeWatermark.IsVisible = string.IsNullOrWhiteSpace(ResumeTextBox.Text);
        }

        // ══════════════════════════════════════════════════════════════════════
        // UI EVENTS
        // ══════════════════════════════════════════════════════════════════════
        private static readonly SolidColorBrush _brushThinking  = new(Colors.Orange);
        private static readonly SolidColorBrush _brushListening = new(Colors.LimeGreen);
        private static readonly SolidColorBrush _brushMuted     = new(Color.FromRgb(239, 68, 68));

        private void UpdateMicUi()
        {
            string label;
            SolidColorBrush brush;

            if (isProcessing)     { brush = _brushThinking;  label = "THINKING"; }
            else if (isListening) { brush = _brushListening; label = "LISTENING"; }
            else if (isMuted)     { brush = _brushMuted;     label = "MUTED"; }
            else                  { brush = _brushMuted;     label = isRecording ? "RECORDING" : "READY"; }

            MicIndicator.Fill     = brush;
            MicIndicatorText.Text = label;
            MicBtn.BorderBrush    = brush;

            if (_isCameraMode && _answerWindow != null)
                _answerWindow.UpdateMicState(isListening, isProcessing);
        }

        private void UpdateTranscript()
        {
            if (!isListening) return;

            // Suppress stale engine output for ~1050ms after unmute (7 ticks × 150ms)
            if (_justStartedListening)
            {
                _listenStartTicks++;
                TranscriptTextBlock.Text = "";
                if (_listenStartTicks >= 7) _justStartedListening = false;
                return;
            }

            try
            {
                string text = ReadLatestTxtSafe();
                if (text != TranscriptTextBlock.Text)
                {
                    TranscriptTextBlock.Text  = text;
                    TranscriptHint.IsVisible  = string.IsNullOrWhiteSpace(text);
                    TranscriptScroll.ScrollToEnd();
                    if (_isCameraMode && _answerWindow != null)
                        _answerWindow.UpdateQuestion(text);
                }
            }
            catch (Exception ex) { DebugWindow.Log("TRANSCRIPT", $"UpdateTranscript failed: {ex.Message}"); }
        }

        private string ReadLatestTxtSafe()
        {
            string path = Path.Combine(AppDataFolder, "latest.txt");
            try { return File.ReadAllText(path); }
            catch (IOException) { }
            catch (Exception ex) { DebugWindow.Log("TRANSCRIPT", $"ReadLatestTxt: {ex.Message}"); }
            return TranscriptTextBlock.Text ?? "";
        }

        // ══════════════════════════════════════════════════════════════════════
        // SPEECHMATICS ENGINE
        // ══════════════════════════════════════════════════════════════════════
        private void StartSpeechmaticsEngine()
        {
            try
            {
                _engineCts.Cancel();
                _engineCts.Dispose();
                _engineCts = new CancellationTokenSource();
                var ct = _engineCts.Token;

                KillAndDisposeEngine();

                string smKey = SettingsWindow.GetSpeechmaticsKey();
                if (string.IsNullOrWhiteSpace(smKey)) { DebugWindow.Log("ENGINE", "No SM key."); return; }

                // Prefer the bundled binary (ships with PyInstaller — no Python install needed)
                // Fall back to python + .py script for development
                string binaryEngine   = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "speechmatics_engine");
                string pyScript       = Path.Combine(scriptFolder, "speechmatics_engine.py");
                bool   hasBinary      = File.Exists(binaryEngine);
                bool   hasScript      = File.Exists(pyScript);

                if (!hasBinary && !hasScript)
                {
                    DebugWindow.Log("ENGINE", "Not found: " + scriptFolder);
                    return;
                }

                string syscapturePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "SystemAudioCapture");
                bool hasSysCapture = File.Exists(syscapturePath);

                DebugWindow.Log("ENGINE", $"Mode    : {(hasBinary ? "BINARY (bundled)" : "SCRIPT (python)")}");
                DebugWindow.Log("ENGINE", $"Binary  : {(hasBinary ? binaryEngine : "N/A")}");
                DebugWindow.Log("ENGINE", $"Script  : {(hasScript ? pyScript : "N/A")}");
                DebugWindow.Log("ENGINE", $"SysCap  : {(hasSysCapture ? syscapturePath : "NOT FOUND")}");

                string deviceArg     = _audioDeviceId >= 0 ? $" -device {_audioDeviceId}" : "";
                string modeArg       = hasSysCapture ? " -mode both" : " -mode mic";
                string syscaptureArg = hasSysCapture ? $" -syscapture \"{syscapturePath}\"" : "";
                const string maxDelayArg = " -max-delay 1.0";

                speechmaticsProcess = new Process();
                if (hasBinary)
                {
                    // Bundled binary — pass key as env var (keeps it out of `ps aux`)
                    speechmaticsProcess.StartInfo.FileName  = binaryEngine;
                    speechmaticsProcess.StartInfo.Arguments = $"{deviceArg}{modeArg}{syscaptureArg}{maxDelayArg}".TrimStart();
                    speechmaticsProcess.StartInfo.Environment["SPEECHMATICS_API_KEY"] = smKey;
                }
                else
                {
                    // Dev fallback — python + .py script
                    string pythonPath = FindPythonPath();
                    DebugWindow.Log("ENGINE", $"Python  : {pythonPath}");
                    speechmaticsProcess.StartInfo.FileName  = pythonPath;
                    speechmaticsProcess.StartInfo.Arguments = $"\"{pyScript}\"{deviceArg}{modeArg}{syscaptureArg}{maxDelayArg}";
                    speechmaticsProcess.StartInfo.Environment["SPEECHMATICS_API_KEY"] = smKey;
                }
                speechmaticsProcess.StartInfo.WorkingDirectory      = scriptFolder;
                speechmaticsProcess.StartInfo.CreateNoWindow        = true;
                speechmaticsProcess.StartInfo.UseShellExecute       = false;
                speechmaticsProcess.StartInfo.RedirectStandardOutput = true;
                speechmaticsProcess.StartInfo.RedirectStandardError  = true;
                if (!speechmaticsProcess.Start())
                {
                    DebugWindow.Log("ENGINE", "Process.Start() returned false — engine did not launch");
                    speechmaticsProcess.Dispose();
                    speechmaticsProcess = null;
                    return;
                }
                DebugWindow.Log("ENGINE", $"STARTED | PID: {speechmaticsProcess.Id}");

                var proc = speechmaticsProcess;
                _ = Task.Run(async () =>
                {
                    try
                    {
                        while (!ct.IsCancellationRequested)
                        {
                            string? line = await proc.StandardOutput.ReadLineAsync(ct).ConfigureAwait(false);
                            if (line == null) break;
                            Dispatcher.UIThread.Post(() => DebugWindow.Log("PY", line));
                        }
                    }
                    catch (OperationCanceledException) { }
                    catch (Exception ex) { DebugWindow.Log("PY_OUT", ex.Message); }
                }, ct);

                _ = Task.Run(async () =>
                {
                    try
                    {
                        while (!ct.IsCancellationRequested)
                        {
                            string? line = await proc.StandardError.ReadLineAsync(ct).ConfigureAwait(false);
                            if (line == null) break;
                            Dispatcher.UIThread.Post(() => DebugWindow.Log("PY_ERR", line));
                        }
                    }
                    catch (OperationCanceledException) { }
                    catch (Exception ex) { DebugWindow.Log("PY_ERR_READER", ex.Message); }
                }, ct);
            }
            catch (Exception ex) { DebugWindow.Log("ENGINE_ERR", ex.Message); }
        }

        private void KillAndDisposeEngine()
        {
            var proc = speechmaticsProcess;
            speechmaticsProcess = null;
            if (proc == null) return;
            try { proc.Kill(); } catch { }
            try { proc.Dispose(); } catch { }
        }

        private void WritePauseFlag()  { try { File.WriteAllText(Path.Combine(AppDataFolder, "pause.flag"), "1"); } catch (Exception ex) { DebugWindow.Log("FILE", ex.Message); } }
        private void DeletePauseFlag() { try { string f = Path.Combine(AppDataFolder, "pause.flag"); if (File.Exists(f)) File.Delete(f); } catch (Exception ex) { DebugWindow.Log("FILE", ex.Message); } }

        private async Task NuclearKillOldProcesses()
        {
            KillAndDisposeEngine();
            try
            {
                using var ps = new Process();
                ps.StartInfo.FileName               = "ps";
                ps.StartInfo.Arguments              = "ax -o pid,command";
                ps.StartInfo.UseShellExecute        = false;
                ps.StartInfo.RedirectStandardOutput = true;
                ps.StartInfo.CreateNoWindow         = true;
                ps.Start();
                string output = await ps.StandardOutput.ReadToEndAsync();
                await ps.WaitForExitAsync();

                foreach (string line in output.Split('\n'))
                {
                    if (!line.Contains("speechmatics_engine")) continue;
                    string trimmed = line.TrimStart();
                    int spaceIdx = trimmed.IndexOf(' ');
                    if (spaceIdx <= 0) continue;
                    if (!int.TryParse(trimmed[..spaceIdx], out int pid)) continue;
                    try { var p = Process.GetProcessById(pid); p.Kill(); p.Dispose(); DebugWindow.Log("ENGINE", $"Killed orphaned PID {pid}"); } catch { }
                }
            }
            catch (Exception ex) { DebugWindow.Log("ENGINE", $"NuclearKill ps failed: {ex.Message}"); }
        }

        private void MonitorEngine()
        {
            if (speechmaticsProcess == null || speechmaticsProcess.HasExited)
            {
                DebugWindow.Log("ENGINE", "Dead — restarting...");
                StartSpeechmaticsEngine();
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // DEBUG / KEYBOARD / WINDOW
        // ══════════════════════════════════════════════════════════════════════
        private void ToggleDebugMode()
        {
            if (_debugWindowInst == null || !_debugWindowInst.IsVisible)
            {
                if (_debugWindowInst == null) _debugWindowInst = new DebugWindow();
                _debugWindowInst.Show();
                _debugWindowInst.Activate();
            }
            else
            {
                _debugWindowInst.Hide();
            }
        }

        public void Window_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.Key == Key.F12) { e.Handled = true; ToggleDebugMode(); return; }
            if (e.Key == Key.F8)  { e.Handled = true; _ = RunScreenAnalysis(); return; }
            if (e.Key == Key.F9)  { e.Handled = true; _ = RunScreenAnalysis(); return; }
            if (e.Key == Key.Space)
            {
                if (ResumeTextBox != null && ResumeTextBox.IsFocused) return;
                e.Handled = true;
                HandleSpacePress("KEYBOARD");
            }
        }

        public void Border_PointerPressed(object? sender, PointerPressedEventArgs e)
        {
            BeginMoveDrag(e);
        }

        private void CloseBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e) => Close();

        private async void SettingsBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            var sw = new SettingsWindow();
            await sw.ShowDialog(this);

            ApplyMainWindowOpacity();
            _answerWindow?.ApplyOverlayOpacity();

            if (sw.SettingsChanged)
            {
                bool deviceChanged = sw.SelectedDeviceIndex >= 0 && sw.SelectedDeviceIndex != _audioDeviceId;
                if (deviceChanged) _audioDeviceId = sw.SelectedDeviceIndex;
                DebugWindow.Log("SETTINGS", "Settings changed — restarting engine");
                StartSpeechmaticsEngine();
            }

            if (UserSession.IsLoggedIn)
                _ = FetchAndDisplayCreditsAsync().ContinueWith(t => {
                    if (t.IsFaulted) DebugWindow.Log("CREDITS_ERR", t.Exception?.GetBaseException().Message ?? "unknown");
                }, TaskScheduler.Default);
        }

        private void ResumeToggleBtn_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
        {
            _resumeCollapsed = !_resumeCollapsed;
            ResumePanel.IsVisible    = !_resumeCollapsed;
            ResumeToggleBtn.Content  = _resumeCollapsed ? "▶" : "◀";
        }

        protected override void OnClosed(EventArgs e)
        {
            transcriptTimer?.Stop();
            thinkingTimer?.Stop();
            creditsRefreshTimer?.Stop();
            _engineMonitorTimer?.Stop();
            _sessionTimer?.Stop();

            if (_answerWindow != null && _cameraModeClosedHandler != null)
                _answerWindow.CameraModeClosedByUser -= _cameraModeClosedHandler;
            try { _answerWindow?.Close(); } catch { }
            _answerWindow = null;

            _globalHotkey?.Dispose();
            _debugWindowInst?.ForceClose();
            EndSession();

            try { File.WriteAllText(Path.Combine(AppDataFolder, "shutdown.flag"), "1"); } catch { }
            _aiCts.Cancel();
            _aiCts.Dispose();
            _engineCts.Cancel();
            _engineCts.Dispose();
            KillAndDisposeEngine();

            base.OnClosed(e);
        }
    }
}
