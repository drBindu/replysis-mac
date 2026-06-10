using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace InterviewCopilotMac6
{
    /// <summary>
    /// Parses resume text and extracts real facts (dates, jobs, skills)
    /// so the AI cannot hallucinate experience or skills.
    /// </summary>
    public static class ResumeParser
    {
        private static readonly Dictionary<string, int> MonthMap =
            new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
            {
                {"jan",1},{"january",1},{"feb",2},{"february",2},
                {"mar",3},{"march",3},{"apr",4},{"april",4},
                {"may",5},{"jun",6},{"june",6},{"jul",7},{"july",7},
                {"aug",8},{"august",8},{"sep",9},{"sept",9},{"september",9},
                {"oct",10},{"october",10},{"nov",11},{"november",11},
                {"dec",12},{"december",12}
            };

        // Current date for "Present" calculations — evaluated at runtime
        private static int NOW_YEAR  => DateTime.Now.Year;
        private static int NOW_MONTH => DateTime.Now.Month;

        /// <summary>
        /// Returns a clean summary of real resume facts for use in AI prompts.
        /// </summary>
        public static string ExtractFacts(string resume)
        {
            if (string.IsNullOrWhiteSpace(resume) || resume.Length < 50)
                return "No resume provided.";

            var sb = new StringBuilder();

            // 1. Name — first short non-label line
            foreach (var line in resume.Split('\n'))
            {
                string t = line.Trim();
                if (t.Length > 2 && t.Length < 50 && !t.Contains(":") && !t.StartsWith("•"))
                {
                    sb.AppendLine("Name: " + t);
                    break;
                }
            }

            // 2. Jobs and durations
            var jobs = ExtractJobs(resume);
            int totalMonths = CalculateTotalMonths(jobs);

            sb.AppendLine($"Total Experience: {totalMonths / 12} years {totalMonths % 12} months");
            sb.AppendLine("Work History:");
            foreach (var job in jobs)
                sb.AppendLine($"  - {job.Label} | {job.DateRange} ({job.Months} months)");

            // 3. Skills
            sb.AppendLine("Skills:");
            bool inSkills = false;
            foreach (var line in resume.Split('\n'))
            {
                string t = line.Trim();
                string lower = t.ToLower();

                // Detect section header lines only (short lines that ARE the heading, not skill content)
                bool isHeader = t.Length < 40 && !t.StartsWith("•") && !t.StartsWith("-");

                if (lower.Contains("skill") || lower.Contains("expertise") || lower.Contains("key skill"))
                    inSkills = true;
                else if (inSkills && isHeader && (lower.Contains("experience") || lower.Contains("education") || lower.Contains("employment")))
                    inSkills = false;

                if (inSkills && t.Length > 5 && !lower.Contains("skill") && !lower.Contains("expertise"))
                    sb.AppendLine("  - " + t.TrimStart('•', '-', ' ', '\t'));
            }

            // 4. FULL RAW RESUME — so the AI can see location, contact, education,
            //    project descriptions etc. that the structured extraction above misses.
            //    The candidate's own location (e.g. "Illinois, USA") is often in the
            //    header next to phone/email and would otherwise be dropped.
            sb.AppendLine();
            sb.AppendLine("--- FULL RESUME TEXT (use for location, contact, education, project details) ---");
            sb.AppendLine(resume.Trim());

            return sb.ToString();
        }

        // ── Job extraction ──────────────────────────────────────────

        public class JobEntry
        {
            public string Label { get; set; } = "";
            public string DateRange { get; set; } = "";
            public int Months { get; set; }
            public int StartIdx { get; set; }
            public int EndIdx { get; set; }
        }

        private static readonly Regex DatePattern = new Regex(
            @"([A-Za-z]{3,9})\s+(\d{4})\s*[-–—]\s*(Present|Till\s*Date|[A-Za-z]{3,9}\s+\d{4})",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

        public static List<JobEntry> ExtractJobs(string resume)
        {
            var jobs = new List<JobEntry>();
            var lines = resume.Split('\n');
            string lastHeader = "";

            for (int i = 0; i < lines.Length; i++)
            {
                string t = lines[i].Trim();
                var match = DatePattern.Match(t);

                if (match.Success)
                {
                    var entry = ParseMatch(match);
                    if (entry == null) continue;

                    // Label is either the same line (minus dates) or the previous line
                    string label = t.Replace(match.Value, "").Trim().TrimEnd('|', '-', ' ');
                    if (label.Length < 3) label = lastHeader;

                    entry.Label = label;
                    jobs.Add(entry);
                }

                if (t.Length > 3 && !match.Success)
                    lastHeader = t;
            }

            return jobs;
        }

        private static JobEntry? ParseMatch(Match m)
        {
            try
            {
                string startMonthStr = m.Groups[1].Value;
                int startYear = int.Parse(m.Groups[2].Value);
                string endStr = m.Groups[3].Value.Trim();

                if (!MonthMap.TryGetValue(startMonthStr, out int startMonth)) return null;

                int startIdx = startYear * 12 + (startMonth - 1);
                int endIdx;

                if (endStr.ToLower().Contains("present") || endStr.ToLower().Replace(" ", "").Contains("tilldate"))
                {
                    endIdx = NOW_YEAR * 12 + (NOW_MONTH - 1);
                }
                else
                {
                    var parts = endStr.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length < 2) return null;
                    if (!MonthMap.TryGetValue(parts[0], out int endMonth)) return null;
                    if (!int.TryParse(parts[1], out int endYear)) return null;
                    endIdx = endYear * 12 + (endMonth - 1);
                }

                int months = Math.Max(0, endIdx - startIdx + 1);

                return new JobEntry
                {
                    DateRange = m.Value,
                    Months = months,
                    StartIdx = startIdx,
                    EndIdx = endIdx
                };
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[RESUME] ParseMatch failed: {ex.Message}");
                return null;
            }
        }

        private static int CalculateTotalMonths(List<JobEntry> jobs)
        {
            if (jobs.Count == 0) return 0;

            // Merge overlapping intervals to avoid double-counting
            var intervals = jobs
                .Select(j => (j.StartIdx, j.EndIdx))
                .OrderBy(x => x.StartIdx)
                .ToList();

            var merged = new List<(int s, int e)>();
            var cur = intervals[0];

            for (int i = 1; i < intervals.Count; i++)
            {
                if (intervals[i].StartIdx <= cur.EndIdx)
                    cur = (cur.StartIdx, Math.Max(cur.EndIdx, intervals[i].EndIdx));
                else
                {
                    merged.Add(cur);
                    cur = intervals[i];
                }
            }
            merged.Add(cur);

            return merged.Sum(x => x.e - x.s + 1);
        }
    }
}