using Avalonia;
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace InterviewCopilotMac6;

sealed class Program
{
        [STAThread]
        public static void Main(string[] args)
        {
                    // Single-instance guard — prevents duplicate dock icons when opened twice.
                    string lockFile = Path.Combine(Path.GetTempPath(), "InterviewCopilot.lock");
                    try
                    {
                                    if (File.Exists(lockFile))
                                    {
                                                        string pidStr = File.ReadAllText(lockFile).Trim();
                                                        if (int.TryParse(pidStr, out int existingPid))
                                                        {
                                                                                try
                                                                                {
                                                                                                            var existing = Process.GetProcessById(existingPid);
                                                                                                            if (!existing.HasExited)
                                                                                                            {
                                                                                                                                            Process.Start("osascript", "-e 'tell application \"Interview Copilot\" to activate'");
                                                                                                                                            return;
                                                                                                            }
                                                                                }
                                                                                catch { }
                                                        }
                                    }
                                    File.WriteAllText(lockFile, Environment.ProcessId.ToString());
                    }
                    catch { }

                    try
                    {
                                    BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
                    }
                    finally
                    {
                                    try { File.Delete(lockFile); } catch { }
                    }
        }

        public static AppBuilder BuildAvaloniaApp()
                    => AppBuilder.Configure<App>()
                        .UsePlatformDetect()
                        .WithInterFont()
                        .LogToTrace();
}
