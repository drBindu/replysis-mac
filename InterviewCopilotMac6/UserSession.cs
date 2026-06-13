using System;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace InterviewCopilotMac6
{
    /// <summary>
    /// Holds the current logged-in user's session data in memory + persists to disk.
    /// </summary>
    public static class UserSession
    {
        private static string FirebaseApiKey => Views.SettingsWindow.GetFirebaseApiKey();
        private static HttpClient _http => SharedHttpClient.HttpShort;

        private static string SessionDir => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "InterviewCopilotMac6");

        private static string SessionPath => Path.Combine(SessionDir, "session.json");

        // ── In-memory state ──
        public static string   IdToken      { get; private set; } = "";
        public static string   RefreshToken { get; private set; } = "";
        public static string   Email        { get; private set; } = "";
        public static string   Name         { get; private set; } = "";
        public static string   UserId       { get; private set; } = "";
        private static DateTime _savedAt    = DateTime.MinValue;
        public static bool   IsLoggedIn   => !string.IsNullOrEmpty(IdToken);

        // ── Credits (refreshed from backend) ──
        public static int    Credits     { get; set; } = 0;
        public static string Plan        { get; set; } = "free";
        public static bool   IsUnlimited { get; set; } = false;

        // ── Speechmatics key (fetched from backend after login, never saved to disk) ──
        public static string SpeechmaticsKey { get; private set; } = "";

        public static async Task<bool> FetchSpeechmaticsKeyAsync()
        {
            try
            {
                if (string.IsNullOrEmpty(IdToken)) return false;
                using var req = new HttpRequestMessage(HttpMethod.Get, "https://coopilotxai.com/api/v1/stt/key");
                req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", IdToken);
                using var res = await _http.SendAsync(req);
                string body = await res.Content.ReadAsStringAsync();
                if (!res.IsSuccessStatusCode)
                {
                    System.Diagnostics.Debug.WriteLine($"[SESSION] /api/stt/key HTTP {(int)res.StatusCode}: {body}");
                    Views.DebugWindow.Log("STT_KEY", $"HTTP {(int)res.StatusCode}: {body[..Math.Min(body.Length, 120)]}");
                    return false;
                }
                using var doc = System.Text.Json.JsonDocument.Parse(body);
                string key = doc.RootElement.TryGetProperty("key", out var k) ? k.GetString() ?? "" : "";
                if (string.IsNullOrEmpty(key))
                {
                    Views.DebugWindow.Log("STT_KEY", $"200 OK but no 'key' field in response: {body[..Math.Min(body.Length, 120)]}");
                    return false;
                }
                SpeechmaticsKey = key;
                return true;
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[SESSION] FetchSpeechmaticsKeyAsync failed: {ex.Message}");
                return false;
            }
        }

        // ── Avatar initials ──
        public static string Initials => GetInitials(Name);

        public static string GetInitials(string name)
        {
            if (string.IsNullOrEmpty(name)) return "?";
            var parts = name.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length >= 2)
                return $"{parts[0][0]}{parts[1][0]}".ToUpper();
            return name.Length >= 2 ? name.Substring(0, 2).ToUpper() : name.ToUpper();
        }

        // ── Set session after login ──
        public static void SetSession(string idToken, string email, string name, string userId, string refreshToken = "")
        {
            IdToken      = idToken;
            RefreshToken = refreshToken;
            Email        = email;
            Name         = string.IsNullOrEmpty(name) ? email.Split('@')[0] : name;
            UserId       = userId;
            SaveToDisk();
        }

        // ── Clear on logout ──
        public static void Clear()
        {
            IdToken      = "";
            RefreshToken = "";
            Email        = "";
            Name         = "";
            UserId       = "";
            Credits         = 0;
            Plan            = "free";
            IsUnlimited     = false;
            SpeechmaticsKey = "";
            _savedAt     = DateTime.MinValue;
            try { if (File.Exists(SessionPath)) File.Delete(SessionPath); }
            catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"[SESSION] Delete session file failed: {ex.Message}"); }
        }

        // ── Persist session so user stays logged in between app restarts ──
        private static void SaveToDisk()
        {
            try
            {
                Directory.CreateDirectory(SessionDir);
                var data = new SessionData
                {
                    IdToken      = IdToken,
                    RefreshToken = RefreshToken,
                    Email        = Email,
                    Name         = Name,
                    UserId       = UserId,
                    SavedAt      = DateTime.UtcNow
                };
                File.WriteAllText(SessionPath,
                    JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true }));
                _savedAt = data.SavedAt;
            }
            catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"[SESSION] SaveToDisk failed: {ex.Message}"); }
        }

        // ── Load session from disk (on app start) ──
        // FIX 16 — when IdToken may be expired (SavedAt > 55 min ago), we still load credentials
        // so the caller can attempt TryRefreshAsync(), but we return false to signal a refresh is needed.
        public static bool TryLoadFromDisk()
        {
            try
            {
                if (!File.Exists(SessionPath)) return false;

                string json = File.ReadAllText(SessionPath);
                var data = JsonSerializer.Deserialize<SessionData>(json);
                if (data == null) return false;

                IdToken      = data.IdToken      ?? "";
                RefreshToken = data.RefreshToken ?? "";
                Email        = data.Email        ?? "";
                Name         = data.Name         ?? "";
                UserId       = data.UserId       ?? "";
                _savedAt     = data.SavedAt;

                // If no credentials at all, nothing to work with
                if (string.IsNullOrEmpty(RefreshToken) && string.IsNullOrEmpty(IdToken))
                    return false;

                // FIX 16 — if token is potentially expired, return false so the caller
                // attempts TryRefreshAsync() rather than using a stale IdToken.
                if (IsTokenExpired())
                    return false;

                return IsLoggedIn;
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[SESSION] TryLoadFromDisk failed: {ex.Message}");
                return false;
            }
        }

        public static bool IsTokenExpired() =>
            _savedAt == DateTime.MinValue || (DateTime.UtcNow - _savedAt).TotalMinutes > 55;

        // Serializes TryRefreshAsync — Firebase rotates refresh tokens on use, so two
        // concurrent refreshes with the same stored token would race (one succeeds and
        // rotates the token, the other fails with invalid_grant and looks like a sign-out).
        private static readonly SemaphoreSlim _refreshLock = new(1, 1);

        // ── Silently refresh the Firebase ID token using the stored refresh token ──
        public static async Task<bool> TryRefreshAsync()
        {
            if (string.IsNullOrEmpty(RefreshToken)) return false;
            if (!IsTokenExpired()) return true; // still valid

            await _refreshLock.WaitAsync();
            try
            {
                // A concurrent caller may have already refreshed while we were waiting.
                if (!IsTokenExpired()) return true;
                if (string.IsNullOrEmpty(RefreshToken)) return false;

                string url = $"https://securetoken.googleapis.com/v1/token?key={FirebaseApiKey}";
                var content = new System.Net.Http.FormUrlEncodedContent(new[]
                {
                    new System.Collections.Generic.KeyValuePair<string,string>("grant_type",    "refresh_token"),
                    new System.Collections.Generic.KeyValuePair<string,string>("refresh_token", RefreshToken),
                });
                using var res  = await _http.PostAsync(url, content);
                string body = await res.Content.ReadAsStringAsync();
                if (!res.IsSuccessStatusCode)
                {
                    System.Diagnostics.Debug.WriteLine($"[SESSION] TryRefreshAsync: HTTP {(int)res.StatusCode}");
                    return false;
                }

                using var doc = JsonDocument.Parse(body);
                string newIdToken = doc.RootElement.TryGetProperty("id_token",      out var t)  ? t.GetString()  ?? "" : "";
                string newRefresh = doc.RootElement.TryGetProperty("refresh_token", out var rt) ? rt.GetString() ?? "" : "";
                if (string.IsNullOrEmpty(newIdToken)) return false;

                IdToken      = newIdToken;
                RefreshToken = newRefresh;
                SaveToDisk();
                return true;
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[SESSION] TryRefreshAsync failed: {ex.Message}");
                return false;
            }
            finally
            {
                _refreshLock.Release();
            }
        }

        private class SessionData
        {
            public string   IdToken      { get; set; } = "";
            public string   RefreshToken { get; set; } = "";
            public string   Email        { get; set; } = "";
            public string   Name         { get; set; } = "";
            public string   UserId       { get; set; } = "";
            public DateTime SavedAt      { get; set; } = DateTime.UtcNow;
        }
    }
}
