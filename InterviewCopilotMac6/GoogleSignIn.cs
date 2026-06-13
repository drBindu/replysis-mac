using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace InterviewCopilotMac6
{
    /// <summary>
    /// "Continue with Google" sign-in via the installed-app loopback OAuth flow (RFC 8252) + PKCE,
    /// then exchanges the Google ID token for a Firebase session via signInWithIdp.
    /// </summary>
    public static class GoogleSignIn
    {
        public readonly record struct Result(
            bool Success,
            string IdToken,
            string RefreshToken,
            string Email,
            string DisplayName,
            string PhotoUrl,
            string UserId,
            string Error);

        public static async Task<Result> SignInAsync()
        {
            string clientId     = Views.SettingsWindow.GetGoogleClientId();
            string clientSecret = Views.SettingsWindow.GetGoogleClientSecret();

            HttpListener? listener = null;
            try
            {
                int port = FindFreeLocalPort();
                string redirectUri = $"http://127.0.0.1:{port}/";

                string codeVerifier  = GenerateCodeVerifier();
                string codeChallenge = GenerateCodeChallenge(codeVerifier);
                // CSRF protection — random per-attempt value, echoed back by Google and
                // validated against the redirect so a forged/replayed redirect can't
                // be accepted as a successful sign-in.
                string state = GenerateCodeVerifier();

                listener = new HttpListener();
                listener.Prefixes.Add(redirectUri);
                listener.Start();

                string authUrl = "https://accounts.google.com/o/oauth2/v2/auth" +
                    $"?client_id={Uri.EscapeDataString(clientId)}" +
                    $"&redirect_uri={Uri.EscapeDataString(redirectUri)}" +
                    "&response_type=code" +
                    "&scope=openid%20email%20profile" +
                    $"&code_challenge={Uri.EscapeDataString(codeChallenge)}" +
                    "&code_challenge_method=S256" +
                    $"&state={Uri.EscapeDataString(state)}";

                Process.Start(new ProcessStartInfo(authUrl) { UseShellExecute = true });

                var contextTask = listener.GetContextAsync();
                var winner = await Task.WhenAny(contextTask, Task.Delay(TimeSpan.FromMinutes(2)));
                if (winner != contextTask)
                {
                    // Observe the still-pending task's eventual result/exception so it
                    // doesn't surface as an UnobservedTaskException after we return.
                    _ = contextTask.ContinueWith(t =>
                    {
                        if (t.IsFaulted) System.Diagnostics.Debug.WriteLine($"[GoogleSignIn] late listener task faulted: {t.Exception?.GetBaseException().Message}");
                    }, TaskScheduler.Default);
                    return new Result(false, "", "", "", "", "", "", "Sign-in timed out. Please try again.");
                }

                var context = await contextTask;
                string? code         = context.Request.QueryString["code"];
                string? error        = context.Request.QueryString["error"];
                string? returnedState = context.Request.QueryString["state"];

                bool stateValid = string.Equals(returnedState, state, StringComparison.Ordinal);
                await RespondToBrowserAsync(context, success: error == null && !string.IsNullOrEmpty(code) && stateValid);

                if (!stateValid)
                {
                    System.Diagnostics.Debug.WriteLine("[GoogleSignIn] state mismatch — possible CSRF, aborting");
                    return new Result(false, "", "", "", "", "", "", "Sign-in failed a security check. Please try again.");
                }

                if (error != null || string.IsNullOrEmpty(code))
                    return new Result(false, "", "", "", "", "", "", "Google sign-in was cancelled.");

                // Exchange the authorization code for a Google ID token
                var tokenContent = new FormUrlEncodedContent(new[]
                {
                    new KeyValuePair<string, string>("code", code),
                    new KeyValuePair<string, string>("client_id", clientId),
                    new KeyValuePair<string, string>("client_secret", clientSecret),
                    new KeyValuePair<string, string>("redirect_uri", redirectUri),
                    new KeyValuePair<string, string>("code_verifier", codeVerifier),
                    new KeyValuePair<string, string>("grant_type", "authorization_code"),
                });

                using var tokenRes = await SharedHttpClient.HttpShort.PostAsync(
                    "https://oauth2.googleapis.com/token", tokenContent);
                string tokenBody = await tokenRes.Content.ReadAsStringAsync();
                if (!tokenRes.IsSuccessStatusCode)
                {
                    System.Diagnostics.Debug.WriteLine($"[GoogleSignIn] token exchange failed: {tokenBody}");
                    string detail = "";
                    try
                    {
                        using var errDoc = JsonDocument.Parse(tokenBody);
                        string err = errDoc.RootElement.TryGetProperty("error", out var e) ? e.GetString() ?? "" : "";
                        string errDesc = errDoc.RootElement.TryGetProperty("error_description", out var ed) ? ed.GetString() ?? "" : "";
                        detail = string.IsNullOrEmpty(errDesc) ? err : $"{err}: {errDesc}";
                    }
                    catch { /* ignore parse errors, fall back to generic message */ }

                    return new Result(false, "", "", "", "", "", "",
                        string.IsNullOrEmpty(detail)
                            ? "Google sign-in failed during token exchange."
                            : $"Google sign-in failed: {detail}");
                }

                using var tokenDoc = JsonDocument.Parse(tokenBody);
                string googleIdToken = tokenDoc.RootElement.TryGetProperty("id_token", out var idt) ? idt.GetString() ?? "" : "";
                if (string.IsNullOrEmpty(googleIdToken))
                    return new Result(false, "", "", "", "", "", "", "Google did not return an identity token.");

                // Exchange the Google ID token for a Firebase session
                string firebaseUrl = $"https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key={Views.SettingsWindow.GetFirebaseApiKey()}";
                var firebasePayload = new
                {
                    postBody = $"id_token={googleIdToken}&providerId=google.com",
                    requestUri = "http://localhost",
                    returnIdpCredential = true,
                    returnSecureToken = true
                };

                using var fbRequest = new HttpRequestMessage(HttpMethod.Post, firebaseUrl);
                fbRequest.Content = new StringContent(
                    JsonSerializer.Serialize(firebasePayload), Encoding.UTF8, "application/json");

                using var fbRes  = await SharedHttpClient.HttpShort.SendAsync(fbRequest);
                string fbBody = await fbRes.Content.ReadAsStringAsync();
                using var fbDoc = JsonDocument.Parse(fbBody);

                if (!fbRes.IsSuccessStatusCode)
                {
                    string errMsg = "Google sign-in failed.";
                    if (fbDoc.RootElement.TryGetProperty("error", out var err))
                    {
                        string msg = err.TryGetProperty("message", out var m) ? m.GetString() ?? "" : "";
                        errMsg = $"Google sign-in failed: {msg}";
                    }
                    return new Result(false, "", "", "", "", "", "", errMsg);
                }

                string fbIdToken      = fbDoc.RootElement.TryGetProperty("idToken",      out var t)  ? t.GetString()  ?? "" : "";
                string fbRefreshToken = fbDoc.RootElement.TryGetProperty("refreshToken", out var rt) ? rt.GetString() ?? "" : "";
                string fbEmail        = fbDoc.RootElement.TryGetProperty("email",        out var em) ? em.GetString() ?? "" : "";
                string fbUserId       = fbDoc.RootElement.TryGetProperty("localId",      out var id) ? id.GetString() ?? "" : "";
                string fbDisplayName  = fbDoc.RootElement.TryGetProperty("displayName",  out var dn) ? dn.GetString() ?? "" : "";
                string fbPhotoUrl     = fbDoc.RootElement.TryGetProperty("photoUrl",     out var pu) ? pu.GetString() ?? "" : "";

                if (string.IsNullOrEmpty(fbDisplayName))
                    fbDisplayName = fbEmail.Contains('@') ? fbEmail.Split('@')[0] : fbEmail;

                return new Result(true, fbIdToken, fbRefreshToken, fbEmail, fbDisplayName, fbPhotoUrl, fbUserId, "");
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[GoogleSignIn] SignInAsync failed: {ex}");
                return new Result(false, "", "", "", "", "", "", "Connection error. Check your internet connection.");
            }
            finally
            {
                try { listener?.Stop(); listener?.Close(); } catch { /* ignore */ }
            }
        }

        private static async Task RespondToBrowserAsync(HttpListenerContext context, bool success)
        {
            string title = success ? "Signed in!" : "Sign-in failed";
            string html = $@"<html><head><title>Interview Copilot</title></head>
<body style='font-family:-apple-system,sans-serif;text-align:center;padding-top:80px;background:#0d1117;color:#e6edf3;'>
<h2>{title}</h2>
<p>You can close this tab and return to Interview Copilot.</p>
</body></html>";

            byte[] buffer = Encoding.UTF8.GetBytes(html);
            context.Response.ContentType = "text/html; charset=utf-8";
            context.Response.ContentLength64 = buffer.Length;
            await context.Response.OutputStream.WriteAsync(buffer, 0, buffer.Length);
            context.Response.OutputStream.Close();
        }

        private static int FindFreeLocalPort()
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            listener.Stop();
            return port;
        }

        private static string GenerateCodeVerifier()
        {
            byte[] bytes = RandomNumberGenerator.GetBytes(32);
            return Base64UrlEncode(bytes);
        }

        private static string GenerateCodeChallenge(string codeVerifier)
        {
            byte[] hash = SHA256.HashData(Encoding.ASCII.GetBytes(codeVerifier));
            return Base64UrlEncode(hash);
        }

        private static string Base64UrlEncode(byte[] bytes) =>
            Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }
}
