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
        /// Sentinel returned by <see cref="ExtractFacts"/> when no usable resume text is available.
        public const string NoResumeMarker = "No resume provided.";

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
                return NoResumeMarker;

            var sb = new StringBuilder();

            // 1. Name — first short non-label line
            string name = ExtractName(resume);
            if (!string.IsNullOrEmpty(name))
                sb.AppendLine("Name: " + name);

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

                // Only a HEADER line containing "skill"/"expertise" starts the skills
                // section — otherwise a bullet like "Trained staff on lab skills" would
                // falsely flip inSkills on mid-Experience section.
                if (isHeader && (lower.Contains("skill") || lower.Contains("expertise")))
                    inSkills = true;
                else if (inSkills && isHeader && (lower.Contains("experience") || lower.Contains("education") || lower.Contains("employment") || lower.Contains("project")))
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

        /// <summary>
        /// Returns the candidate's name — the first short non-label line of the resume —
        /// or "" if the resume is empty or no such line is found.
        /// </summary>
        public static string ExtractName(string resume)
        {
            if (string.IsNullOrWhiteSpace(resume)) return "";

            foreach (var line in resume.Split('\n'))
            {
                string t = line.Trim();
                if (t.Length > 2 && t.Length < 50 && !t.Contains(":") && !t.StartsWith("•"))
                    return t;
            }
            return "";
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

        // "Jan 2020 - Present" / "January 2020 - Dec 2022"
        private static readonly Regex DatePatternMonthName = new Regex(
            @"([A-Za-z]{3,9})\s+(\d{4})\s*[-–—]\s*(Present|Current|Till\s*Date|[A-Za-z]{3,9}\s+\d{4})",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

        // "01/2020 - 06/2022" / "1-2020 - Present"
        private static readonly Regex DatePatternNumeric = new Regex(
            @"(\d{1,2})[/\-](\d{4})\s*[-–—]\s*(Present|Current|Till\s*Date|\d{1,2}[/\-]\d{4})",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

        // "2020 - 2022" / "2020 - Present" (year-only ranges)
        private static readonly Regex DatePatternYearOnly = new Regex(
            @"(?<!\d)(\d{4})\s*[-–—]\s*(Present|Current|Till\s*Date|\d{4})(?!\d)",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

        private enum DateFormat { MonthName, Numeric, YearOnly }

        public static List<JobEntry> ExtractJobs(string resume)
        {
            var jobs = new List<JobEntry>();
            var lines = resume.Split('\n');
            string lastHeader = "";

            for (int i = 0; i < lines.Length; i++)
            {
                string t = lines[i].Trim();

                var match = DatePatternMonthName.Match(t);
                var fmt = DateFormat.MonthName;
                if (!match.Success) { match = DatePatternNumeric.Match(t); fmt = DateFormat.Numeric; }
                if (!match.Success) { match = DatePatternYearOnly.Match(t); fmt = DateFormat.YearOnly; }

                if (match.Success)
                {
                    var entry = ParseMatch(match, fmt);
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

        // Sanity bounds for bare-year ranges so things like zip codes or arbitrary
        // 4-digit numbers ("2020-2024" copyright lines, etc.) don't get treated as jobs.
        private const int MinValidYear = 1950;
        private static int MaxValidYear => NOW_YEAR + 1;

        private static JobEntry? ParseMatch(Match m, DateFormat fmt)
        {
            try
            {
                string endStr = m.Groups[3].Value.Trim();
                string endLower = endStr.ToLower().Replace(" ", "");
                bool isOpenEnded = endLower.Contains("present") || endLower.Contains("current") || endLower.Contains("tilldate");

                int startIdx, endIdx;

                switch (fmt)
                {
                    case DateFormat.MonthName:
                    {
                        if (!MonthMap.TryGetValue(m.Groups[1].Value, out int startMonth)) return null;
                        int startYear = int.Parse(m.Groups[2].Value);
                        startIdx = startYear * 12 + (startMonth - 1);

                        if (isOpenEnded)
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
                        break;
                    }

                    case DateFormat.Numeric:
                    {
                        if (!int.TryParse(m.Groups[1].Value, out int startMonth) || startMonth < 1 || startMonth > 12) return null;
                        int startYear = int.Parse(m.Groups[2].Value);
                        if (startYear < MinValidYear || startYear > MaxValidYear) return null;
                        startIdx = startYear * 12 + (startMonth - 1);

                        if (isOpenEnded)
                        {
                            endIdx = NOW_YEAR * 12 + (NOW_MONTH - 1);
                        }
                        else
                        {
                            var parts = endStr.Split(new[] { '/', '-' }, StringSplitOptions.RemoveEmptyEntries);
                            if (parts.Length < 2) return null;
                            if (!int.TryParse(parts[0], out int endMonth) || endMonth < 1 || endMonth > 12) return null;
                            if (!int.TryParse(parts[1], out int endYear)) return null;
                            endIdx = endYear * 12 + (endMonth - 1);
                        }
                        break;
                    }

                    case DateFormat.YearOnly:
                    default:
                    {
                        int startYear = int.Parse(m.Groups[1].Value);
                        if (startYear < MinValidYear || startYear > MaxValidYear) return null;
                        startIdx = startYear * 12; // January

                        if (isOpenEnded)
                        {
                            endIdx = NOW_YEAR * 12 + (NOW_MONTH - 1);
                        }
                        else
                        {
                            if (!int.TryParse(endStr, out int endYear) || endYear < MinValidYear || endYear > MaxValidYear) return null;
                            endIdx = endYear * 12 + 11; // December
                        }
                        break;
                    }
                }

                // Clamp so a garbled/reversed date range (end before start) can't produce
                // a negative segment length when intervals are merged in CalculateTotalMonths.
                endIdx = Math.Max(endIdx, startIdx);
                int months = endIdx - startIdx + 1;

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