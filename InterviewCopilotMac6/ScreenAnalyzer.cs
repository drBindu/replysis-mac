using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace InterviewCopilotMac6
{
    public static class ScreenAnalyzer
    {
        // Capped at 2000 chars — enough context for the next question without unbounded growth
        private const int MaxContextChars = 2000;
        public static string LastScreenContext { get; private set; } = "";

        // Pre-compiled regex for markdown stripping (shared by PostProcess and CleanContent)
        private static readonly Regex _rxBold2     = new(@"\*{2}([^*\n]+)\*{2}", RegexOptions.Compiled);
        private static readonly Regex _rxBold1     = new(@"\*([^*\n]+)\*",        RegexOptions.Compiled);
        private static readonly Regex _rxUnderline = new(@"_{1,2}([^_\n]+)_{1,2}", RegexOptions.Compiled);
        private static readonly Regex _rxHeading   = new(@"(?m)^#{1,6}\s+",       RegexOptions.Compiled);
        private static readonly Regex _rxCodeFence = new(@"```[a-zA-Z]*\r?\n?",   RegexOptions.Compiled);
        private static readonly Regex _rxBlankRuns = new(@"\n{3,}",               RegexOptions.Compiled);

        // Static prompt body — built once, reused on every capture
        private static readonly string _staticPromptBody = BuildStaticPromptBody();

        // ═════════════════════════════════════════════════════════════════════
        // CAPTURE — macOS screencapture CLI (no BitBlt)
        // ═════════════════════════════════════════════════════════════════════

        public static async Task<byte[]> CaptureScreenAsync(CancellationToken externalCt = default)
        {
            string tmpPath = Path.Combine(
                Path.GetTempPath(), $"interview_screen_{Guid.NewGuid():N}.png");
            try
            {
                using var proc = new Process();
                proc.StartInfo.FileName               = "screencapture";
                proc.StartInfo.Arguments              = $"-x -t png \"{tmpPath}\"";
                proc.StartInfo.UseShellExecute        = false;
                proc.StartInfo.RedirectStandardError  = true;
                proc.StartInfo.CreateNoWindow         = true;
                proc.Start();

                // Drain stderr concurrently — prevents pipe-buffer deadlock on verbose output
                var stderrTask = proc.StandardError.ReadToEndAsync();

                // 8-second hard timeout, also honouring external cancellation (e.g. app close)
                using var timeoutCts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
                using var linkedCts  = CancellationTokenSource.CreateLinkedTokenSource(
                                           timeoutCts.Token, externalCt);
                try { await proc.WaitForExitAsync(linkedCts.Token); }
                catch (OperationCanceledException)
                {
                    try { proc.Kill(); } catch { }
                    if (externalCt.IsCancellationRequested)
                        return Array.Empty<byte>();   // silent — user closed app
                    Views.DebugWindow.Log("SCREEN", "screencapture timed out");
                    return Array.Empty<byte>();
                }

                string stderr = await stderrTask;
                if (!string.IsNullOrWhiteSpace(stderr))
                    Views.DebugWindow.Log("SCREEN_STDERR", stderr.Trim());

                if (proc.ExitCode != 0)
                {
                    Views.DebugWindow.Log("SCREEN", $"screencapture failed with exit code {proc.ExitCode}");
                    return Array.Empty<byte>();
                }

                if (!File.Exists(tmpPath))
                {
                    Views.DebugWindow.Log("SCREEN", "screencapture produced no file");
                    return Array.Empty<byte>();
                }

                byte[] imageBytes = await File.ReadAllBytesAsync(tmpPath);

                // Resize to max 1280px wide using sips (built into macOS) — prevents 16MB payloads
                var resizedPath = tmpPath + "_resized.png";
                try
                {
                    var sips = new System.Diagnostics.ProcessStartInfo("sips",
                        $"--resampleWidth 1280 \"{tmpPath}\" --out \"{resizedPath}\"")
                    { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
                    var sipsProc = System.Diagnostics.Process.Start(sips);
                    await (sipsProc?.WaitForExitAsync(externalCt) ?? System.Threading.Tasks.Task.CompletedTask);
                    if (File.Exists(resizedPath))
                        imageBytes = await File.ReadAllBytesAsync(resizedPath, externalCt);
                }
                catch (Exception sipsEx)
                {
                    Views.DebugWindow.Log("SCREEN_SIPS", $"sips resize failed — using original image: {sipsEx.Message}");
                    // imageBytes already holds the unresized capture; continue with it
                }
                finally
                {
                    // Clean up regardless of success/cancellation/exception — otherwise a
                    // cancelled or failed resize leaves *_resized.png files behind forever.
                    try { if (File.Exists(resizedPath)) File.Delete(resizedPath); } catch { }
                }

                Views.DebugWindow.Log("SCREEN", $"Captured {imageBytes.Length / 1024} KB");
                return imageBytes;
            }
            catch (Exception ex)
            {
                Views.DebugWindow.Log("SCREEN_ERR", ex.Message);
                return Array.Empty<byte>();
            }
            finally
            {
                try { if (File.Exists(tmpPath)) File.Delete(tmpPath); } catch { }
            }
        }

        // ═════════════════════════════════════════════════════════════════════
        // VISION PROVIDER
        // ═════════════════════════════════════════════════════════════════════

        private static (string Endpoint, string Model) GetVisionProvider()
        {
            if (Views.SettingsWindow.IsGroq())
                return ("https://api.groq.com/openai/v1/chat/completions",
                        "meta-llama/llama-4-scout-17b-16e-instruct");
            return ("https://api.openai.com/v1/chat/completions", "gpt-4o");
        }

        // ═════════════════════════════════════════════════════════════════════
        // PROMPT — static body built once, resume context appended at call time
        // ═════════════════════════════════════════════════════════════════════

        private static string BuildScreenPrompt(string? resumeContext)
        {
            if (string.IsNullOrWhiteSpace(resumeContext))
                return _staticPromptBody;

            // Append resume section to the cached base — avoids rebuilding the whole prompt
            return _staticPromptBody +
                   "\n─────────────────────────────────────────────────────\n" +
                   "CANDIDATE BACKGROUND (reference only if directly relevant):\n" +
                   "─────────────────────────────────────────────────────\n" +
                   resumeContext + "\n";
        }

        private static string BuildStaticPromptBody()
        {
            // Pre-sized for the known content (~3.2 KB)
            var sb = new StringBuilder(4096);

            sb.AppendLine("You are an expert interview coach helping a candidate in a live interview.");
            sb.AppendLine("The screenshot is a FULL SCREEN CAPTURE taken while the Interview Copilot app was hidden — so you are seeing whatever was behind it: Zoom/Meet shared screens, browsers with coding problems, job descriptions, terminal output, etc.");
            sb.AppendLine("IMPORTANT: Look at the ENTIRE screenshot. Identify ALL visible content — browser windows, coding platforms (LeetCode, HackerRank, CoderPad), video call screens, error messages, design mockups, or any interview question text.");
            sb.AppendLine("Respond using the EXACT structure shown below for the matching content type.");
            sb.AppendLine();
            sb.AppendLine("CRITICAL OUTPUT RULES — OBEY EXACTLY:");
            sb.AppendLine("1. Use ━━━ TITLE ━━━ as section headers — nothing else (no ##, no **, no ---).");
            sb.AppendLine("2. One blank line after each section header, one blank line before the next header.");
            sb.AppendLine("3. Bullets use the • character only (never -, *, numbers).");
            sb.AppendLine("4. No markdown: no **bold**, no _italic_, no backtick code fences.");
            sb.AppendLine("5. Code goes directly after ━━━ SOLUTION ━━━ with no fences.");
            sb.AppendLine("6. Never truncate code — write the complete solution even if it's long.");
            sb.AppendLine("7. Keep non-code sections short and scannable.");
            sb.AppendLine();
            sb.AppendLine("─────────────────────────────────────────────────────");
            sb.AppendLine("IF SCREEN SHOWS A CODING / ALGORITHM PROBLEM, output:");
            sb.AppendLine("─────────────────────────────────────────────────────");
            sb.AppendLine();
            sb.AppendLine("━━━ PROBLEM ━━━");
            sb.AppendLine("[One sentence: what the problem is asking for]");
            sb.AppendLine();
            sb.AppendLine("━━━ APPROACH ━━━");
            sb.AppendLine("Brute force:  [brief — 1 sentence]  →  O(n²) time");
            sb.AppendLine("Optimal:      [brief — 1 sentence]  →  O(n) time");
            sb.AppendLine();
            sb.AppendLine("━━━ SOLUTION ━━━");
            sb.AppendLine("[Complete working code. Language = whatever is on screen, default Python.]");
            sb.AppendLine("[Inline comments on non-obvious lines. Handle edge cases. No truncation.]");
            sb.AppendLine();
            sb.AppendLine("━━━ COMPLEXITY ━━━");
            sb.AppendLine("Time: O(?)   |   Space: O(?)");
            sb.AppendLine();
            sb.AppendLine("━━━ SAY THIS ━━━");
            sb.AppendLine("• \"[Opening line to say to the interviewer before coding]\"");
            sb.AppendLine("• \"[What to narrate as you write the key part]\"");
            sb.AppendLine("• \"[How to wrap up and state the complexity]\"");
            sb.AppendLine();
            sb.AppendLine("─────────────────────────────────────────────────────");
            sb.AppendLine("IF SCREEN SHOWS A SYSTEM DESIGN / ARCHITECTURE DIAGRAM, output:");
            sb.AppendLine("─────────────────────────────────────────────────────");
            sb.AppendLine();
            sb.AppendLine("━━━ COMPONENTS ━━━");
            sb.AppendLine("• [Component name] — [what it does in 1 sentence]");
            sb.AppendLine();
            sb.AppendLine("━━━ DATA FLOW ━━━");
            sb.AppendLine("[2-3 sentences describing how data moves through the system]");
            sb.AppendLine();
            sb.AppendLine("━━━ TRADE-OFFS ━━━");
            sb.AppendLine("• [Scalability / bottleneck / consistency issue]");
            sb.AppendLine();
            sb.AppendLine("━━━ IMPROVEMENT ━━━");
            sb.AppendLine("[One concrete suggestion]");
            sb.AppendLine();
            sb.AppendLine("─────────────────────────────────────────────────────");
            sb.AppendLine("IF SCREEN SHOWS A MULTIPLE CHOICE / QUIZ QUESTION, output:");
            sb.AppendLine("─────────────────────────────────────────────────────");
            sb.AppendLine();
            sb.AppendLine("━━━ ANSWER ━━━");
            sb.AppendLine("[Correct option — state it directly]");
            sb.AppendLine();
            sb.AppendLine("━━━ WHY ━━━");
            sb.AppendLine("• Correct ([option]): [why it's right — 1 sentence]");
            sb.AppendLine("• Wrong ([option]):   [why it's wrong — 1 sentence]");
            sb.AppendLine();
            sb.AppendLine("━━━ WATCH OUT ━━━");
            sb.AppendLine("[Any trick or common misconception in this question]");
            sb.AppendLine();
            sb.AppendLine("─────────────────────────────────────────────────────");
            sb.AppendLine("IF SCREEN SHOWS A BEHAVIORAL / SITUATIONAL TEXT QUESTION, output:");
            sb.AppendLine("─────────────────────────────────────────────────────");
            sb.AppendLine();
            sb.AppendLine("━━━ SITUATION ━━━");
            sb.AppendLine("[Context: where, when, what was at stake — 1-2 sentences]");
            sb.AppendLine();
            sb.AppendLine("━━━ ACTION ━━━");
            sb.AppendLine("• [Specific step you took]");
            sb.AppendLine("• [Another concrete step]");
            sb.AppendLine();
            sb.AppendLine("━━━ RESULT ━━━");
            sb.AppendLine("[Outcome with a specific number or metric]");
            sb.AppendLine();
            sb.AppendLine("─────────────────────────────────────────────────────");
            sb.AppendLine("IF SCREEN SHOWS AN ERROR, BUG, OR STACK TRACE, output:");
            sb.AppendLine("─────────────────────────────────────────────────────");
            sb.AppendLine();
            sb.AppendLine("━━━ ROOT CAUSE ━━━");
            sb.AppendLine("[One sentence — the actual problem]");
            sb.AppendLine();
            sb.AppendLine("━━━ FIX ━━━");
            sb.AppendLine("[The corrected code line(s) — complete, ready to paste]");
            sb.AppendLine();
            sb.AppendLine("━━━ EXPLAIN ━━━");
            sb.AppendLine("[One sentence to say out loud to the interviewer]");
            sb.AppendLine();
            sb.AppendLine("─────────────────────────────────────────────────────");
            sb.AppendLine("IF SCREEN CONTENT DOES NOT MATCH ANY ABOVE (e.g. only desktop/wallpaper visible), output:");
            sb.AppendLine("─────────────────────────────────────────────────────");
            sb.AppendLine();
            sb.AppendLine("━━━ WHAT I SEE ━━━");
            sb.AppendLine("[Describe ALL visible windows, apps, and content — be specific about what applications are open]");
            sb.AppendLine("If the Interview Copilot app is visible, mention the current transcript and any question being discussed.");
            sb.AppendLine();
            sb.AppendLine("━━━ GUIDANCE ━━━");
            sb.AppendLine("• [Most relevant interview advice based on what you see]");
            sb.AppendLine("• TIP: For best results, keep your coding platform or the interviewer's shared screen visible on screen when using Screen Analysis");

            return sb.ToString();
        }

        // ═════════════════════════════════════════════════════════════════════
        // STREAMING ANALYSIS
        // ═════════════════════════════════════════════════════════════════════

        public static async IAsyncEnumerable<string> AnalyzeStreamAsync(
            byte[] imageBytes, string? resumeContext = null,
            [EnumeratorCancellation] CancellationToken ct = default)
        {
            string apiKey = Views.SettingsWindow.GetApiKey();
            if (string.IsNullOrWhiteSpace(apiKey))
            {
                yield return "⚠ No API key set for Screen Analysis.\n\n" +
                             "• Open ⚙ Settings → paste your key\n" +
                             "• Groq key (gsk_…) → free, uses Llama 4 Scout vision\n" +
                             "• OpenAI key (sk-…) → GPT-4o Vision";
                yield break;
            }

            var (endpoint, visionModel) = GetVisionProvider();

            // Base64-encode off the calling thread — PNG for a Retina screen can be 5–8 MB
            string base64 = await Task.Run(() => Convert.ToBase64String(imageBytes), ct);

            string prompt      = BuildScreenPrompt(resumeContext);
            string payloadJson = BuildVisionPayloadJson(visionModel, base64, prompt);

            var (res, sendError) = await SendVisionRequestSafeAsync(endpoint, apiKey, payloadJson, ct);
            if (res == null)
            {
                yield return sendError;
                yield break;
            }

            // Use 'using' so res is disposed exactly once regardless of code path
            using (res)
            {
                if (!res.IsSuccessStatusCode)
                {
                    string errMsg = await ParseVisionErrorSafeAsync(res, ct);
                    yield return errMsg;
                    yield break;
                }

                var accumulated = new StringBuilder();
                try
                {
                    await using var stream = await res.Content.ReadAsStreamAsync(ct);
                    using var reader = new StreamReader(stream);

                    while (!reader.EndOfStream && !ct.IsCancellationRequested)
                    {
                        // Pass ct so cancellation interrupts the read immediately
                        string? line = await reader.ReadLineAsync(ct);
                        if (string.IsNullOrWhiteSpace(line) || !line.StartsWith("data: ")) continue;
                        string data = line["data: ".Length..];
                        if (data == "[DONE]") break;

                        string token = ParseSseToken(data);
                        if (!string.IsNullOrEmpty(token))
                        {
                            accumulated.Append(token);
                            yield return token;
                        }
                    }
                }
                finally
                {
                    string full = CleanContent(accumulated.ToString());
                    // Only a complete, non-empty result becomes the new "last screen"
                    // context. A cancelled stream (partial/truncated text) or an empty
                    // response must not overwrite it with misleading data — keep
                    // whatever the last successful capture produced.
                    if (!ct.IsCancellationRequested && !string.IsNullOrWhiteSpace(full))
                        // Cap stored context — avoids unbounded growth across many captures
                        LastScreenContext = full.Length > MaxContextChars
                            ? full.Substring(0, MaxContextChars) + "…"
                            : full;
                }

                // Guard: if the model returned nothing, tell the user clearly
                if (accumulated.Length == 0)
                    yield return "⚠ The vision model returned an empty response. Try again or check your API key and quota.";

            }
        }

        // ═════════════════════════════════════════════════════════════════════
        // POST-PROCESSOR
        // ═════════════════════════════════════════════════════════════════════

        public static string PostProcess(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw)) return raw;

            raw = StripMarkdown(raw);

            var lines  = raw.Split('\n');
            var result = new List<string>(lines.Length);

            for (int i = 0; i < lines.Length; i++)
            {
                string line   = lines[i].TrimEnd();
                bool isHeader = line.StartsWith("━━━") && line.TrimEnd().EndsWith("━━━");

                if (isHeader)
                {
                    while (result.Count > 0 && result[^1] == "")
                        result.RemoveAt(result.Count - 1);
                    if (result.Count > 0) result.Add("");
                    result.Add(line);
                    result.Add("");
                }
                else
                {
                    if (line == "" && result.Count > 0 && result[^1] == "")
                        continue;
                    result.Add(line);
                }
            }

            while (result.Count > 0 && result[0]  == "") result.RemoveAt(0);
            while (result.Count > 0 && result[^1] == "") result.RemoveAt(result.Count - 1);

            return string.Join("\n", result);
        }

        // ═════════════════════════════════════════════════════════════════════
        // HELPERS
        // ═════════════════════════════════════════════════════════════════════

        private static async Task<(HttpResponseMessage? Response, string Error)>
            SendVisionRequestSafeAsync(
                string endpoint, string apiKey, string payloadJson, CancellationToken ct)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Post, endpoint);
                req.Headers.Add("Authorization", $"Bearer {apiKey}");
                req.Content = new StringContent(payloadJson, Encoding.UTF8, "application/json");
                var response = await SharedHttpClient.Http.SendAsync(
                    req, HttpCompletionOption.ResponseHeadersRead, ct);
                return (response, "");
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                // Our own HTTP client timeout — not user-initiated
                return (null, "⚠ Request timed out. Check your connection and try again.");
            }
            catch (OperationCanceledException)
            {
                // User-initiated cancellation — caller handles this silently
                throw;
            }
            catch (Exception ex)
            {
                return (null, $"⚠ Network error: {ex.Message}");
            }
        }

        private static async Task<string> ParseVisionErrorSafeAsync(
            HttpResponseMessage res, CancellationToken ct)
        {
            // Handle common HTTP status codes before parsing the body
            if (res.StatusCode == HttpStatusCode.Unauthorized)
                return "⚠ Invalid API key. Open ⚙ Settings → check your key.";
            if (res.StatusCode == HttpStatusCode.TooManyRequests)
                return "⚠ Rate limit hit. Wait a moment and try again.";
            if (res.StatusCode == HttpStatusCode.PaymentRequired)
                return "⚠ API quota exceeded. Check billing at your provider dashboard.";

            try
            {
                string body = await res.Content.ReadAsStringAsync(ct);
                Views.DebugWindow.Log("SCREEN_ERR", $"HTTP {(int)res.StatusCode}: {body}");

                using var doc = JsonDocument.Parse(body);
                string msg = "";
                if (doc.RootElement.TryGetProperty("error", out var errEl) &&
                    errEl.TryGetProperty("message", out var msgEl))
                    msg = msgEl.GetString() ?? "";

                if (string.IsNullOrEmpty(msg)) return $"⚠ Vision API error (HTTP {(int)res.StatusCode}).";
                if (msg.Contains("API key"))    return "⚠ Invalid API key. Open ⚙ Settings → check your key.";
                if (msg.Contains("quota") || msg.Contains("billing"))
                    return "⚠ API quota exceeded. Check billing at your provider dashboard.";
                if (msg.Contains("vision") || msg.Contains("image"))
                    return $"⚠ This model doesn't support vision. Switch to GPT-4o in Settings.\n{msg}";
                return $"⚠ API error: {msg}";
            }
            catch
            {
                return $"⚠ Vision API error (HTTP {(int)res.StatusCode}). Check your API key in Settings.";
            }
        }

        private static string ParseSseToken(string data)
        {
            try
            {
                using var doc = JsonDocument.Parse(data);
                var root = doc.RootElement;

                if (root.TryGetProperty("error", out var errProp))
                    return $"\n⚠ {errProp.GetString()}";

                if (!root.TryGetProperty("choices", out var choices) ||
                    choices.GetArrayLength() == 0) return "";

                var delta = choices[0].GetProperty("delta");
                return delta.TryGetProperty("content", out var cp) ? cp.GetString() ?? "" : "";
            }
            catch { return ""; }
        }

        private static string BuildVisionPayloadJson(string model, string base64, string prompt)
        {
            // Groq's vision API does not support the "detail" parameter — omit it for Groq.
            // OpenAI supports "auto" or "high"; use "high" for best accuracy on OpenAI.
            bool isGroq = Views.SettingsWindow.IsGroq();

            object imageContent = isGroq
                ? (object)new { type = "image_url",
                                image_url = new { url = $"data:image/png;base64,{base64}" } }
                : (object)new { type = "image_url",
                                image_url = new { url = $"data:image/png;base64,{base64}", detail = "high" } };

            var payload = new
            {
                model,
                max_tokens = 4096,
                stream     = true,
                messages   = new[]
                {
                    new
                    {
                        role    = "user",
                        content = new object[]
                        {
                            new { type = "text", text = prompt },
                            imageContent
                        }
                    }
                }
            };
            return JsonSerializer.Serialize(payload);
        }

        // Shared markdown stripper — used by both PostProcess and CleanContent
        private static string StripMarkdown(string text)
        {
            text = _rxBold2.Replace(text, "$1");
            text = _rxBold1.Replace(text, "$1");
            text = _rxUnderline.Replace(text, "$1");
            text = _rxHeading.Replace(text, "");
            text = _rxCodeFence.Replace(text, "");
            text = text.Replace("\r\n", "\n").Replace("\r", "\n");
            return text;
        }

        private static string CleanContent(string content)
        {
            if (string.IsNullOrEmpty(content)) return content;
            content = StripMarkdown(content);
            content = _rxBlankRuns.Replace(content, "\n\n");
            return content.Trim();
        }
    }
}
