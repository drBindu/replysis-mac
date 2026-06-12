using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Interactivity;

namespace InterviewCopilotMac6.Views
{
    public partial class SettingsWindow : Window
    {
        public bool SettingsChanged { get; set; } = false;
        public int SelectedDeviceIndex { get; set; } = -1;
        private List<int> deviceIndices = new List<int>();

        // ── Config file — persists in AppData ──
        private static string ConfigDir => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "InterviewCopilotMac6");

        private static string ConfigPath => Path.Combine(ConfigDir, "config.json");

        // ── Model definitions ──
        public static readonly string[] ModelIds = {
            "gpt-4.1",
            "gpt-4o-mini",
            "gpt-4o",
            "llama-3.3-70b-versatile",
            "gemini-2.0-flash",
        };

        public static readonly string[] ModelEndpoints = {
            "https://api.openai.com/v1/chat/completions",
            "https://api.openai.com/v1/chat/completions",
            "https://api.openai.com/v1/chat/completions",
            "https://api.groq.com/openai/v1/chat/completions",
            "https://generativelanguage.googleapis.com/v1beta/",
        };

        // ═══════════════════════════════════════════════════════════════
        // CONSTRUCTOR
        // ═══════════════════════════════════════════════════════════════
        public SettingsWindow()
        {
            InitializeComponent();
            LoadDevices();

            var cfg = LoadConfig();
            ModelCombo.SelectedIndex = Math.Clamp(cfg.ModelIndex, 0, ModelIds.Length - 1);
            ApiKeyBox.Text = cfg.ApiKey ?? "";
            CoopilotEmailBox.Text = cfg.CoopilotEmail ?? "";
            TempSlider.Value = cfg.Temperature;
            TempLabel.Text = cfg.Temperature.ToString("F1");

            AppVersionLabel.Text = $"Version {App.GetCurrentVersion()}";
            if (!string.IsNullOrEmpty(App.LastUpdateStatus))
                UpdateStatusLabel.Text = App.LastUpdateStatus;
            RestartUpdateBtn.IsVisible = App.PendingUpdate != null;

            double mainOpPct = Math.Round(cfg.MainWindowOpacity * 100);
            double overlayOpPct = Math.Round(cfg.OverlayOpacity * 100);
            MainOpacitySlider.Value = Math.Clamp(mainOpPct, 10, 100);
            OverlayOpacitySlider.Value = Math.Clamp(overlayOpPct, 10, 100);
            MainOpacityLabel.Text = $"{(int)MainOpacitySlider.Value}%";
            OverlayOpacityLabel.Text = $"{(int)OverlayOpacitySlider.Value}%";

            // Live API key validation feedback
            ApiKeyBox.TextChanged += (s, e) => ValidateApiKeyLive();
            ModelCombo.SelectionChanged += (s, e) => ValidateApiKeyLive();
            ValidateApiKeyLive();
        }

        /// <summary>
        /// Provides real-time coloured hint feedback on the API key format.
        /// </summary>
        private void ValidateApiKeyLive()
        {
            string key = ApiKeyBox.Text?.Trim() ?? "";
            int modelIdx = ModelCombo.SelectedIndex;

            if (string.IsNullOrEmpty(key))
            {
                ApiKeyHintLabel.Text = "Required — paste your API key above.";
                ApiKeyHintLabel.Foreground = Avalonia.Media.Brush.Parse("#f59e0b");
                return;
            }

            bool valid = modelIdx switch
            {
                0 or 1 or 2 => key.StartsWith("sk-", StringComparison.Ordinal),      // OpenAI
                3            => key.StartsWith("gsk_", StringComparison.Ordinal),     // Groq
                4            => key.StartsWith("AIza", StringComparison.Ordinal),     // Gemini
                _            => true
            };

            string expectedFormat = modelIdx switch
            {
                0 or 1 or 2 => "OpenAI key should start with sk-",
                3            => "Groq key should start with gsk_",
                4            => "Gemini key should start with AIza",
                _            => ""
            };

            if (valid)
            {
                ApiKeyHintLabel.Text = "✓ Key format looks correct.";
                ApiKeyHintLabel.Foreground = Avalonia.Media.Brush.Parse("#4ade80");
            }
            else
            {
                ApiKeyHintLabel.Text = $"⚠ {expectedFormat}";
                ApiKeyHintLabel.Foreground = Avalonia.Media.Brush.Parse("#ef4444");
            }
        }

        // ═══════════════════════════════════════════════════════════════
        // AUDIO DEVICES
        // ═══════════════════════════════════════════════════════════════
        private void LoadDevices()
        {
            try
            {
                // Check multiple candidate locations — engine may write devices.txt to any of these
                string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                string[] candidates = {
                    Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "devices.txt"),
                    Path.Combine(home, "InterviewCopilot", "devices.txt"),
                    Path.Combine(home, "interview_copilot", "devices.txt"),
                    Path.Combine(ConfigDir, "devices.txt"),
                };

                string? path = null;
                foreach (string c in candidates)
                    if (File.Exists(c)) { path = c; break; }

                if (path != null)
                {
                    var lines = File.ReadAllLines(path);
                    foreach (var line in lines)
                    {
                        var parts = line.Split('|');
                        if (parts.Length >= 2 && int.TryParse(parts[0].Trim(), out int idx))
                        {
                            deviceIndices.Add(idx);
                            AudioDeviceCombo.Items.Add(parts[1].Trim());
                        }
                    }
                    if (AudioDeviceCombo.SelectedIndex == -1 && AudioDeviceCombo.ItemCount > 0)
                        AudioDeviceCombo.SelectedIndex = 0;
                }
                else
                {
                    AudioDeviceCombo.Items.Add("No devices — run engine first");
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[SETTINGS] LoadDevices failed: {ex.Message}");
                AudioDeviceCombo.Items.Add("Error loading devices");
            }
        }

        // ═══════════════════════════════════════════════════════════════
        // EVENT HANDLERS
        // ═══════════════════════════════════════════════════════════════
        private void TempSlider_ValueChanged(object? sender, RangeBaseValueChangedEventArgs e)
        {
            if (TempLabel != null)
                TempLabel.Text = e.NewValue.ToString("F1");
        }

        private void MainOpacitySlider_ValueChanged(object? sender, RangeBaseValueChangedEventArgs e)
        {
            if (MainOpacityLabel != null)
                MainOpacityLabel.Text = $"{(int)e.NewValue}%";
        }

        private void OverlayOpacitySlider_ValueChanged(object? sender, RangeBaseValueChangedEventArgs e)
        {
            if (OverlayOpacityLabel != null)
                OverlayOpacityLabel.Text = $"{(int)e.NewValue}%";
        }

        private void SaveBtn_Click(object? sender, RoutedEventArgs e)
        {
            string apiKey = ApiKeyBox.Text?.Trim() ?? "";

            // Warn if API key is empty — don't block save, but inform user
            if (string.IsNullOrEmpty(apiKey))
            {
                UpdateStatusLabel.Text = "⚠ No API key entered — Screen Analysis won't work without one.";
                UpdateStatusLabel.Foreground = Avalonia.Media.Brush.Parse("#f59e0b");
            }

            if (AudioDeviceCombo.SelectedIndex > -1 && deviceIndices.Count > AudioDeviceCombo.SelectedIndex)
                SelectedDeviceIndex = deviceIndices[AudioDeviceCombo.SelectedIndex];

            var cfg = new AppConfig
            {
                ModelIndex = ModelCombo.SelectedIndex >= 0 ? ModelCombo.SelectedIndex : 0,
                ApiKey = apiKey,
                CoopilotEmail = CoopilotEmailBox.Text?.Trim() ?? "",
                Temperature = Math.Round(TempSlider.Value, 1),
                MainWindowOpacity = Math.Round(MainOpacitySlider.Value / 100.0, 2),
                OverlayOpacity = Math.Round(OverlayOpacitySlider.Value / 100.0, 2),
            };
            // FIX 13 — check for save failure before closing
            if (!SaveConfig(cfg))
            {
                UpdateStatusLabel.Text = "⚠ Failed to save settings!";
                return;
            }

            SettingsChanged = true;
            this.Close();
        }

        private void CancelBtn_Click(object? sender, RoutedEventArgs e)
        {
            this.Close();
        }

        private void RestartUpdateBtn_Click(object? sender, RoutedEventArgs e)
        {
            App.InstallPendingUpdate();
        }

        private async void CheckUpdatesBtn_Click(object? sender, RoutedEventArgs e)
        {
            CheckUpdatesBtn.IsEnabled = false;
            UpdateStatusLabel.Foreground = Avalonia.Media.Brushes.Gray;
            UpdateStatusLabel.Text = "Checking…";
            await App.CheckForUpdatesAsync(status =>
            {
                Avalonia.Threading.Dispatcher.UIThread.Post(() =>
                {
                    UpdateStatusLabel.Text = status;
                    UpdateStatusLabel.Foreground = status.StartsWith("You're up to date")
                        ? Avalonia.Media.Brush.Parse("#4ade80")
                        : status.StartsWith("Update")
                            ? Avalonia.Media.Brush.Parse("#fb923c")
                            : Avalonia.Media.Brush.Parse("#6b7280");
                });
            });
            CheckUpdatesBtn.IsEnabled = true;
        }

        // ═══════════════════════════════════════════════════════════════
        // CONFIG MODEL
        // ═══════════════════════════════════════════════════════════════
        public class AppConfig
        {
            public int ModelIndex { get; set; } = 0;
            public string ApiKey { get; set; } = "";
            public string SpeechmaticsKey { get; set; } = "";
            public string BackendUrl { get; set; } = "https://ai-powered-developer-assistance-platform.onrender.com/api/config/keys";
            public string CoopilotEmail { get; set; } = "";
            // Firebase Web API key — stored in config; falls back to compiled default if blank.
            public string FirebaseApiKey { get; set; } = "";
            // Google OAuth "Desktop app" client credentials — required for "Continue with Google".
            public string GoogleClientId { get; set; } = "";
            public string GoogleClientSecret { get; set; } = "";
            // Remembered account shown as "Continue as..." on the login screen after sign-out.
            public string LastAccountEmail { get; set; } = "";
            public string LastAccountName { get; set; } = "";
            public string LastAccountPhotoUrl { get; set; } = "";
            public string LastAccountProvider { get; set; } = ""; // "google" or "password"
            // 0.7 gives natural human variation in word choice + sentence rhythm,
            // making answers harder to detect as AI. 0.2 was too deterministic/robotic.
            public double Temperature { get; set; } = 0.7;
            public double MainWindowOpacity { get; set; } = 0.98;
            public double OverlayOpacity { get; set; } = 0.90;
        }

        // ═══════════════════════════════════════════════════════════════
        // PERSISTENCE
        // ═══════════════════════════════════════════════════════════════
        private static AppConfig? _cachedConfig;
        private static DateTime _cacheTime = DateTime.MinValue;
        private const double CacheTtlSec = 60.0;

        public static AppConfig LoadConfig()
        {
            if (_cachedConfig != null && (DateTime.UtcNow - _cacheTime).TotalSeconds < CacheTtlSec)
                return _cachedConfig;

            try
            {
                if (File.Exists(ConfigPath))
                {
                    string json = File.ReadAllText(ConfigPath);
                    _cachedConfig = JsonSerializer.Deserialize<AppConfig>(json) ?? new AppConfig();
                    _cacheTime = DateTime.UtcNow;
                    return _cachedConfig;
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[SETTINGS] LoadConfig failed: {ex.Message}");
            }
            _cachedConfig = new AppConfig();
            _cacheTime = DateTime.UtcNow;
            return _cachedConfig;
        }

        // FIX 13 — return bool so callers can detect failure
        public static bool SaveConfig(AppConfig cfg)
        {
            try
            {
                Directory.CreateDirectory(ConfigDir);
                string json = JsonSerializer.Serialize(cfg, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(ConfigPath, json);
                _cachedConfig = cfg;
                _cacheTime = DateTime.UtcNow;
                return true;
            }
            catch { return false; }
        }

        // ═══════════════════════════════════════════════════════════════
        // STATIC HELPERS
        // ═══════════════════════════════════════════════════════════════
        public static string GetActiveModelId()
        {
            var cfg = LoadConfig();
            int idx = Math.Clamp(cfg.ModelIndex, 0, ModelIds.Length - 1);
            return ModelIds[idx];
        }

        public static string GetActiveEndpoint()
        {
            var cfg = LoadConfig();
            int idx = Math.Clamp(cfg.ModelIndex, 0, ModelEndpoints.Length - 1);
            return ModelEndpoints[idx];
        }

        // FIX 6 — default key kept in a private field; not exposed as default property value
        private static readonly string _defaultFirebaseKey = "AIzaSyAGGmuFpR0qkCHLI3q2cPv_o3cQlbIU8lE";
        public static string GetApiKey() => LoadConfig().ApiKey ?? "";
        public static string GetFirebaseApiKey()
        {
            var key = LoadConfig().FirebaseApiKey;
            return string.IsNullOrEmpty(key) ? _defaultFirebaseKey : key;
        }
        private static readonly string _defaultGoogleClientId = "745433477203-lvqmnnip9pb241vkfp628qmue8313cre.apps.googleusercontent.com";
        private static readonly string _defaultGoogleClientSecret = "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";
        public static string GetGoogleClientId()
        {
            var id = LoadConfig().GoogleClientId;
            return string.IsNullOrEmpty(id) ? _defaultGoogleClientId : id;
        }
        public static string GetGoogleClientSecret()
        {
            var secret = LoadConfig().GoogleClientSecret;
            return string.IsNullOrEmpty(secret) ? _defaultGoogleClientSecret : secret;
        }

        public static (string Email, string Name, string PhotoUrl, string Provider) GetLastAccount()
        {
            var cfg = LoadConfig();
            return (cfg.LastAccountEmail ?? "", cfg.LastAccountName ?? "", cfg.LastAccountPhotoUrl ?? "", cfg.LastAccountProvider ?? "");
        }

        public static void SaveLastAccount(string email, string name, string photoUrl, string provider)
        {
            var cfg = LoadConfig();
            cfg.LastAccountEmail    = email;
            cfg.LastAccountName     = name;
            cfg.LastAccountPhotoUrl = photoUrl;
            cfg.LastAccountProvider = provider;
            SaveConfig(cfg);
        }
        public static string GetSpeechmaticsKey() => LoadConfig().SpeechmaticsKey ?? "";
        public static string GetBackendUrl() => LoadConfig().BackendUrl ?? "";
        public static string GetCoopilotEmail() => LoadConfig().CoopilotEmail ?? "";
        public static double GetTemperature() => LoadConfig().Temperature;
        public static bool IsGemini() => LoadConfig().ModelIndex == 4;
        public static bool IsGroq() => LoadConfig().ModelIndex == 3;

        public static double GetMainWindowOpacity()
        {
            double v = LoadConfig().MainWindowOpacity;
            return Math.Clamp(v > 0 ? v : 0.98, 0.10, 1.0);
        }

        public static double GetOverlayOpacity()
        {
            double v = LoadConfig().OverlayOpacity;
            return Math.Clamp(v > 0 ? v : 0.90, 0.10, 1.0);
        }
    }
}