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

            double mainOpPct = Math.Round(cfg.MainWindowOpacity * 100);
            double overlayOpPct = Math.Round(cfg.OverlayOpacity * 100);
            MainOpacitySlider.Value = Math.Clamp(mainOpPct, 10, 100);
            OverlayOpacitySlider.Value = Math.Clamp(overlayOpPct, 10, 100);
            MainOpacityLabel.Text = $"{(int)MainOpacitySlider.Value}%";
            OverlayOpacityLabel.Text = $"{(int)OverlayOpacitySlider.Value}%";
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
            catch { }
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
            if (AudioDeviceCombo.SelectedIndex > -1 && deviceIndices.Count > AudioDeviceCombo.SelectedIndex)
                SelectedDeviceIndex = deviceIndices[AudioDeviceCombo.SelectedIndex];

            var cfg = new AppConfig
            {
                ModelIndex = ModelCombo.SelectedIndex >= 0 ? ModelCombo.SelectedIndex : 0,
                ApiKey = ApiKeyBox.Text?.Trim() ?? "",
                CoopilotEmail = CoopilotEmailBox.Text?.Trim() ?? "",
                Temperature = Math.Round(TempSlider.Value, 1),
                MainWindowOpacity = Math.Round(MainOpacitySlider.Value / 100.0, 2),
                OverlayOpacity = Math.Round(OverlayOpacitySlider.Value / 100.0, 2),
            };
            SaveConfig(cfg);

            SettingsChanged = true;
            this.Close();
        }

        private void CancelBtn_Click(object? sender, RoutedEventArgs e)
        {
            this.Close();
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
            // Firebase Web API key — safe to include in desktop app config for your own project.
            public string FirebaseApiKey { get; set; } = "AIzaSyAGGmuFpR0qkCHLI3q2cPv_o3cQlbIU8lE";
            public double Temperature { get; set; } = 0.2;
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
            catch { }
            _cachedConfig = new AppConfig();
            _cacheTime = DateTime.UtcNow;
            return _cachedConfig;
        }

        public static void SaveConfig(AppConfig cfg)
        {
            try
            {
                Directory.CreateDirectory(ConfigDir);
                string json = JsonSerializer.Serialize(cfg, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(ConfigPath, json);
                _cachedConfig = cfg;
                _cacheTime = DateTime.UtcNow;
            }
            catch { }
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

        public static string GetApiKey() => LoadConfig().ApiKey ?? "";
        public static string GetFirebaseApiKey() => LoadConfig().FirebaseApiKey;
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