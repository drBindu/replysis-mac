using System;
using System.Net.Http;

namespace InterviewCopilotMac6
{
    /// <summary>
    /// Shared singleton HttpClient instances — reuse across the app to avoid socket exhaustion.
    /// Http       : 120-second timeout for streaming AI responses (complex code answers can be slow).
    /// HttpShort  : 15-second timeout for quick calls (credits, login, token refresh).
    /// </summary>
    public static class SharedHttpClient
    {
        public static readonly HttpClient Http = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(120)
        };

        public static readonly HttpClient HttpShort = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(15)
        };
    }
}
