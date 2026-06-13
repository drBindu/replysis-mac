using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace InterviewCopilotMac6
{
    public static class PromptBuilder
    {
        // ── Pre-compiled regex used in DetectType / IsDrillDown ───────────────
        private static readonly Regex _rxYesNo    = new(@"^(are you|do you|can you|will you|have you|is your|would you|did you|are u|r u)", RegexOptions.Compiled);
        private static readonly Regex _rxHowMuch  = new(@"^how (many|long|much|often|far|soon|old)", RegexOptions.Compiled);
        private static readonly Regex _rxWhich    = new(@"^which (version|one|tool|language|framework|company|team|project|platform|stack|cloud|database|year|month|role|position)", RegexOptions.Compiled);
        private static readonly Regex _rxWhat     = new(@"^what (version|year|company|team|tool|language|framework|platform|stack|size|number|percentage|percent|metric|result|outcome|role|position|project)", RegexOptions.Compiled);
        private static readonly Regex _rxWho      = new(@"^who (said|was|were|is|told|mentioned|managed|led)", RegexOptions.Compiled);
        private static readonly Regex _rxWhen     = new(@"^when (was|did|were|is|did you)", RegexOptions.Compiled);
        private static readonly Regex _rxWhere    = new(@"^where (was|did|were|is)", RegexOptions.Compiled);
        private static readonly Regex _rxYearsExp = new(@"(years? of|year experience|how many years|years? experience)", RegexOptions.Compiled);

        // ── Per-session conversation history (max 80 turns = full interview) ──
        private static readonly List<(string Q, string A)> History = new();

        // ── Topics + companies already used this session ──────────────────────
        private static readonly HashSet<string> CoveredTopics =
            new(StringComparer.OrdinalIgnoreCase);
        private static readonly HashSet<string> MentionedExamples =
            new(StringComparer.OrdinalIgnoreCase);

        // ── LOCKED FACTS: first answer for each topic wins, never changes ─────
        private static readonly Dictionary<string, string> LockedFacts =
            new(StringComparer.OrdinalIgnoreCase);

        // ── Fact extraction patterns ──────────────────────────────────────────
        // (factKey, question trigger words, answer keywords to detect)
        private static readonly (string Key, string[] QTriggers, string[] AKeywords)[] FactPatterns =
        {
            ("best_language",
                new[] { "language", "lang", "favorite lang", "best lang", "strongest lang",
                        "code in", "coding language", "programming language" },
                new[] { "Python", "Java", "JavaScript", "TypeScript", "Go", "Golang", "Rust",
                        "C#", "C++", "Kotlin", "Swift", "Ruby", "PHP", "Scala", "Dart" }),

            ("years_experience",
                new[] { "years", "experience", "how long", "long have you", "how many year",
                        "total experience" },
                new[] { "1 year", "2 year", "3 year", "4 year", "5 year", "6 year",
                        "1.5", "2.5", "3.5", "4.5", "half a year", "one year", "two year",
                        "three year", "four year", "five year" }),

            ("current_employer",
                new[] { "current company", "current employer", "where do you work",
                        "currently work", "working now", "current job", "current role" },
                new[] { "Renasant", "Wipro", "Google", "Microsoft", "Amazon", "Apple",
                        "Meta", "Netflix", "Uber", "Airbnb", "Stripe" }),

            ("salary_expectation",
                new[] { "salary", "compensation", "pay", "ctc", "how much",
                        "expected salary", "rate expectation", "pay expectation" },
                new[] { "$", "k ", "thousand", "lakh", "USD" }),

            ("best_strength",
                new[] { "strength", "best at", "strongest", "excel at", "good at",
                        "top skill", "superpower" },
                new[] { "Java", "Python", "leadership", "problem solving", "architecture",
                        "backend", "frontend", "DevOps", "cloud", "communication" }),

            ("education",
                new[] { "education", "degree", "study", "university", "college",
                        "school", "master", "bachelor", "graduate" },
                new[] { "Bachelor", "Master", "MS", "BS", "PhD", "B.Tech", "M.Tech",
                        "Computer Science", "Engineering", "Roosevelt" }),

            ("relocation",
                new[] { "relocat", "move", "open to moving", "willing to move" },
                new[] { "yes", "no", "absolutely", "open to", "not willing" }),

            ("visa_status",
                new[] { "visa", "stem opt", "work authorization", "sponsorship",
                        "authorized to work", "citizen", "green card", "h1b", "h-1b" },
                new[] { "STEM OPT", "H-1B", "citizen", "green card", "EAD", "F-1" }),

            ("start_date",
                new[] { "start date", "when can you start", "notice period",
                        "available to join", "earliest start", "join us" },
                new[] { "week", "month", "immediately", "right away", "2 weeks",
                        "4 weeks", "30 days" }),
        };

        // =====================================================================
        // PUBLIC API
        // =====================================================================

        public static void AddToHistory(string question, string answer)
        {
            History.Add((question, answer));
            if (History.Count > 80) History.RemoveAt(0);
            TrackCoveredContent(question + " " + answer);
            // Don't try to extract personal facts from screen analysis entries
            if (!question.Contains("screen", StringComparison.OrdinalIgnoreCase))
                ExtractAndLockFacts(question, answer);
        }

        /// <summary>
        /// Returns true if the most recent history entry was a screen analysis.
        /// Used to inject "you just analyzed the screen" context into the next question.
        /// </summary>
        public static bool LastEntryWasScreenAnalysis()
        {
            if (History.Count == 0) return false;
            return History[^1].Q.Contains("screen", StringComparison.OrdinalIgnoreCase);
        }

        public static void ClearHistory()
        {
            History.Clear();
            CoveredTopics.Clear();
            MentionedExamples.Clear();
            LockedFacts.Clear();
            _cachedSystemPrompt = null;
            _cachedResumeFacts = null;
        }

        public static bool IsGreeting(string q)
        {
            string t = q.Trim().ToLower().TrimEnd('.', '!', '?', ',', ' ');
            return t is "hi" or "hello" or "hey" or "hi there" or
                   "good morning" or "good afternoon" or "good evening" or
                   "greetings" or "hey there";
        }

        public static bool IsSmallTalk(string q)
        {
            string t = q.ToLower();
            return t.Contains("how are you") || t.Contains("how's it going") ||
                   t.Contains("how you doing") || t.Contains("how have you been") ||
                   t.Contains("nice to meet") || t.Contains("thanks for coming") ||
                   t.Contains("pleasure to meet");
        }

        public static string GetGreetingResponse() =>
            "Hey, great to be here — really looking forward to this conversation!";

        public static string GetSmallTalkResponse() =>
            "Doing really well, thanks! Excited to be here and learn more about the role.";

        public static string BuildVerifyPrompt() =>
            "State my most recent degree, current employer, and city of residence in 1 short sentence.";

        // =====================================================================
        // QUESTION TYPE
        // =====================================================================

        public enum QuestionType
        {
            YesNo, Intro, Technical, Behavioral, Situational,
            Weakness, WhyRole, Salary, Availability, FollowUp,
            Preference, General
        }

        private static QuestionType DetectType(string q)
        {
            string t = q.ToLower().Trim();

            if (t.Contains("tell me more") || t.Contains("can you elaborate") ||
                t.Contains("expand on that") || t.Contains("go deeper") ||
                t.Contains("what do you mean by") || t.Contains("elaborate on") ||
                t.Contains("go on") || t.Contains("continue"))
                return QuestionType.FollowUp;

            if (_rxYesNo.IsMatch(t))
                return QuestionType.YesNo;

            if (t.Contains("stem opt") || t.Contains("work authorization") ||
                t.Contains("sponsorship") || t.Contains("relocat") ||
                t.Contains("visa") || t.Contains("authorized to work") ||
                t.Contains("willing to") || t.Contains("open to remote") ||
                t.Contains("background check") || t.Contains("drug test") ||
                t.Contains("citizen") || t.Contains("green card") ||
                t.Contains("overtime") || t.Contains("travel required") ||
                t.Contains("hybrid") || t.Contains("on-site") || t.Contains("onsite"))
                return QuestionType.YesNo;

            if (t.Contains("salary") || t.Contains("compensation") ||
                t.Contains("pay expectation") || t.Contains("how much") ||
                t.Contains("rate expectation") || t.Contains("package") || t.Contains("ctc"))
                return QuestionType.Salary;

            if (t.Contains("start date") || t.Contains("when can you start") ||
                t.Contains("notice period") || t.Contains("available to join") ||
                t.Contains("earliest start") || t.Contains("join us"))
                return QuestionType.Availability;

            if (t.Contains("tell me about yourself") || t.Contains("walk me through") ||
                t.Contains("introduce yourself") || t.Contains("tell us about you") ||
                (t.Contains("background") && t.Contains("yourself")))
                return QuestionType.Intro;

            if (t.Contains("tell me a time") || t.Contains("tell me about a time") ||
                t.Contains("give me an example") || t.Contains("describe a situation") ||
                t.Contains("walk me through a time") || t.Contains("share an example") ||
                t.Contains("have you ever faced") || t.Contains("when did you"))
                return QuestionType.Behavioral;

            if (t.Contains("weakness") || t.Contains("weaknesses") ||
                t.Contains("biggest failure") || t.Contains("made a mistake") ||
                t.Contains("area of improvement") || t.Contains("improve yourself") ||
                t.Contains("constructive feedback"))
                return QuestionType.Weakness;

            if ((t.Contains("why") && (t.Contains("role") || t.Contains("company") ||
                 t.Contains("this job") || t.Contains("position") ||
                 t.Contains("us") || t.Contains("here"))) ||
                t.Contains("what interest you") || t.Contains("what attracted") ||
                t.Contains("what excites you") || t.Contains("what motivates") ||
                t.Contains("why should we hire") || t.Contains("strengths") ||
                t.Contains("what makes you"))
                return QuestionType.WhyRole;

            if (t.Contains("what would you do") || t.Contains("how would you handle") ||
                t.Contains("if you were") || t.Contains("hypothetically") ||
                t.Contains("imagine you") || t.Contains("scenario where"))
                return QuestionType.Situational;

            // Preference check MUST come BEFORE Technical
            if (t.Contains("favorite") || t.Contains("favourite") ||
                t.Contains("preferred") || t.Contains("prefer") ||
                t.Contains("best language") || t.Contains("strongest language") ||
                t.Contains("best at") || t.Contains("strongest in") ||
                t.Contains("what language") || t.Contains("which language") ||
                t.Contains("go-to language") || t.Contains("language you") ||
                t.Contains("you like most") || t.Contains("you enjoy most") ||
                t.Contains("what tool") || t.Contains("which tool") ||
                t.Contains("which framework") || t.Contains("what framework") ||
                t.Contains("which database") || t.Contains("which cloud"))
                return QuestionType.Preference;

            if (t.Contains("what is") || t.Contains("explain") ||
                t.Contains("how does") || t.Contains("describe how") ||
                t.Contains("what are") || t.Contains("difference between") ||
                t.Contains("how do you") || t.Contains("what do you know about") ||
                t.Contains("define") || t.Contains("compare") ||
                t.Contains("architecture") || t.Contains("implement"))
                return QuestionType.Technical;

            return QuestionType.General;
        }

        // =====================================================================
        // DRILL-DOWN DETECTION
        // =====================================================================

        private static bool IsDrillDown(string q)
        {
            if (History.Count == 0) return false;
            string t = q.ToLower().Trim().TrimEnd('.', '?', '!');

            if (_rxHowMuch.IsMatch(t))  return true;
            if (_rxWhich.IsMatch(t))    return true;
            if (_rxWhat.IsMatch(t))     return true;
            if (_rxWho.IsMatch(t))      return true;
            if (_rxWhen.IsMatch(t))     return true;
            if (_rxWhere.IsMatch(t))    return true;

            if (t.Contains("what you said") || t.Contains("you said") ||
                t.Contains("you mentioned") || t.Contains("u said") ||
                t.Contains("you told") || t.Contains("you stated") ||
                t.Contains("you just said") || t.Contains("earlier you") ||
                t.Contains("you previously"))
                return true;

            if (_rxYearsExp.IsMatch(t)) return true;

            string[] words = t.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (words.Length <= 6)
            {
                bool hasRef = t.Contains("how") || t.Contains("which") ||
                              t.Contains("what") || t.Contains("who") ||
                              t.Contains("when") || t.Contains("where") ||
                              t.Contains("years") || t.Contains("version") ||
                              t.Contains("size") || t.Contains("team") ||
                              t.Contains("number") || t.Contains("much") ||
                              t.Contains("many") || t.Contains("long") ||
                              t.Contains("old") || t.Contains("big") ||
                              t.Contains("use") || t.Contains("used");
                if (hasRef) return true;
            }
            return false;
        }

        // =====================================================================
        // LOCKED FACTS — EXTRACT & ENFORCE
        // =====================================================================

        // Word-boundary keyword match — "Java" must not match "JavaScript", "Go" must not match "Golang".
        // Returns the index of the first boundary-safe match, or -1 if not found.
        private static int FindBoundaryMatch(string text, string keyword)
        {
            int idx = 0;
            string kwLow = keyword.ToLower();
            while ((idx = text.IndexOf(kwLow, idx, StringComparison.Ordinal)) >= 0)
            {
                int after = idx + kwLow.Length;
                bool okBefore = idx == 0   || !char.IsLetterOrDigit(text[idx - 1]);
                bool okAfter  = after >= text.Length || !char.IsLetterOrDigit(text[after]);
                if (okBefore && okAfter) return idx;
                idx++;
            }
            return -1;
        }

        private static bool IsKeywordMatch(string text, string keyword) =>
            FindBoundaryMatch(text, keyword) >= 0;

        private static void ExtractAndLockFacts(string question, string answer)
        {
            string qLow = question.ToLower();
            string aLow = answer.ToLower();

            foreach (var (key, qTriggers, aKeywords) in FactPatterns)
            {
                if (LockedFacts.ContainsKey(key)) continue;  // first answer wins

                bool qMatch = qTriggers.Any(t => qLow.Contains(t));
                if (!qMatch) continue;

                foreach (var kw in aKeywords)
                {
                    int idx = FindBoundaryMatch(aLow, kw);
                    if (idx >= 0)
                    {
                        // Clamp into [0, answer.Length] — ToLower() can change string
                        // length for some Unicode characters (e.g. 'İ' → "i̇"), so an
                        // index found in aLow isn't guaranteed valid against `answer`.
                        int start = Math.Clamp(idx - 15, 0, answer.Length);
                        int end   = Math.Clamp(idx + kw.Length + 50, start, answer.Length);
                        string snippet = answer.Substring(start, end - start).Trim();
                        if (snippet.Length > 80) snippet = snippet.Substring(0, 80) + "...";
                        LockedFacts[key] = $"{kw} (you said: \"{snippet}\")";
                        break;
                    }
                }
            }
        }

        private static string BuildLockedConstraintBlock(string currentQuestion)
        {
            if (LockedFacts.Count == 0) return "";

            string qLow = currentQuestion.ToLower();
            var sb = new StringBuilder();
            var conflicts = new List<string>();

            sb.AppendLine("LOCKED FACTS FROM THIS SESSION — DO NOT CHANGE UNDER ANY CIRCUMSTANCES:");

            foreach (var (key, _, aKeywords) in FactPatterns)
            {
                if (!LockedFacts.TryGetValue(key, out var lockedValue)) continue;

                string label = key switch
                {
                    "best_language"      => "Best/favorite language",
                    "years_experience"   => "Years of experience",
                    "current_employer"   => "Current employer",
                    "salary_expectation" => "Salary expectation",
                    "best_strength"      => "Top strength",
                    "education"          => "Education",
                    "relocation"         => "Relocation",
                    "visa_status"        => "Visa/work auth",
                    "start_date"         => "Start date",
                    _                    => key
                };

                string shortVal = lockedValue.Split('(')[0].Trim();
                sb.AppendLine($"  [{label}]: {shortVal}");

                foreach (var kw in aKeywords)
                {
                    if (IsKeywordMatch(qLow, kw) &&
                        !IsKeywordMatch(lockedValue.ToLower(), kw))
                    {
                        conflicts.Add(
                            $"  CONFLICT: Interviewer said '{kw}' but your locked answer is '{shortVal}'. " +
                            $"Hold your ground: \"Actually, I said {shortVal} earlier.\"");
                        break;
                    }
                }
            }

            if (conflicts.Count > 0)
            {
                sb.AppendLine();
                sb.AppendLine("  INTERVIEWER IS PUSHING A DIFFERENT ANSWER — DO NOT AGREE:");
                foreach (var c in conflicts) sb.AppendLine(c);
            }

            sb.AppendLine();
            return sb.ToString();
        }

        // =====================================================================
        // SYSTEM PROMPT
        // =====================================================================

        private static string? _cachedSystemPrompt;
        private static string? _cachedResumeFacts;

        private static string BuildSystemPrompt(string resumeFacts)
        {
            if (_cachedSystemPrompt != null && _cachedResumeFacts == resumeFacts)
                return _cachedSystemPrompt;

            bool hasResume = !string.IsNullOrWhiteSpace(resumeFacts)
                             && resumeFacts != ResumeParser.NoResumeMarker;

            var sb = new StringBuilder();

            sb.AppendLine("You ARE the candidate in a live job interview right now.");
            sb.AppendLine("You are a real professional — not an AI, not a bot.");
            sb.AppendLine("Speak in first person. Sound like a sharp human having a real conversation.");
            sb.AppendLine();

            if (hasResume)
            {
                sb.AppendLine("YOUR RESUME (use only these facts, never invent):");
                sb.AppendLine(resumeFacts);
                sb.AppendLine();
            }
            else
            {
                sb.AppendLine("NO RESUME PROVIDED.");
                sb.AppendLine("Answer as a generic software engineering professional.");
                sb.AppendLine("CRITICAL: Do NOT invent or use any specific employer names, company names,");
                sb.AppendLine("project names, university names, or salary numbers.");
                sb.AppendLine("Use generic placeholders like 'a mid-size tech company' or 'my previous employer'.");
                sb.AppendLine("For salary: give a range like $100k-$130k base, open to discussion.");
                sb.AppendLine("For visa: say you are authorized to work and can discuss details if needed.");
                sb.AppendLine();
            }

            sb.AppendLine("RULE 1 — READ HISTORY FIRST, ALWAYS:");
            sb.AppendLine("  Before every answer: scan ALL prior Q&A in this conversation.");
            sb.AppendLine("  If the topic was already answered -> reuse that answer.");
            sb.AppendLine("  If it's a drill-down -> pull the exact fact (MICRO: 1-2 sentences).");
            sb.AppendLine("  If brand new -> FULL mode with bullets.");
            sb.AppendLine();

            if (hasResume)
            {
                sb.AppendLine("RULE 2 — CURRENT JOB FIRST:");
                sb.AppendLine("  Always lead with your most recent role from the resume above.");
                sb.AppendLine("  Never mention an older role or education first.");
                sb.AppendLine();

                sb.AppendLine("RULE 3 — TELL ME ABOUT YOURSELF structure:");
                sb.AppendLine("  1. Who you are NOW (current role + what you do)");
                sb.AppendLine("  2. One key win at current company (specific metric from resume)");
                sb.AppendLine("  3. Previous role briefly (years, key technologies)");
                sb.AppendLine("  4. Education briefly (one sentence)");
                sb.AppendLine("  5. Side projects if any");
                sb.AppendLine("  6. Why THIS company specifically");
                sb.AppendLine("  NEVER start with education. NEVER start with oldest job.");
                sb.AppendLine();
            }
            else
            {
                sb.AppendLine("RULE 2 — CURRENT JOB FIRST:");
                sb.AppendLine("  Lead with a generic current role. Never invent a specific company name.");
                sb.AppendLine();

                sb.AppendLine("RULE 3 — TELL ME ABOUT YOURSELF structure (no resume mode):");
                sb.AppendLine("  1. Generic current role + what you do day to day");
                sb.AppendLine("  2. One generic win (no company name)");
                sb.AppendLine("  3. Previous experience briefly (technologies — no company name)");
                sb.AppendLine("  4. Education briefly — 'Computer Science background' without naming a school");
                sb.AppendLine("  5. Why THIS opportunity interests you");
                sb.AppendLine("  NEVER invent specific employer names, school names, or project names.");
                sb.AppendLine();
            }

            sb.AppendLine("RULE 4 — FORMAT (scannable but human, NO bullet symbols):");
            sb.AppendLine("  Write 3-4 SHORT paragraphs separated by ONE blank line.");
            sb.AppendLine("  Each paragraph = ONE theme (2-3 sentences max).");
            sb.AppendLine("  NEVER use bullet symbols ( . • - * or numbers ).");
            sb.AppendLine("  Mix sentence length: some 3-word fragments, some longer flowing ones.");
            sb.AppendLine("  Sound spoken — like you're explaining to a smart friend over coffee.");
            sb.AppendLine("  For drill-downs / yes-no / preferences / availability: 1-2 short sentences only.");
            sb.AppendLine();

            sb.AppendLine("RULE 5 — YES/NO ANSWERS:");
            if (hasResume)
                sb.AppendLine("  Use facts from your resume. 1-2 short sentences. No setup phrases.");
            else
            {
                sb.AppendLine("  Visa/work auth: authorized to work, can discuss details. 1-2 sentences.");
                sb.AppendLine("  Relocation: Yes/No + openness. 1 sentence.");
                sb.AppendLine("  Background check / drug test: Confident yes. 1 sentence.");
                sb.AppendLine("  Start date: notice period (e.g. '2 weeks'). 1 sentence.");
            }
            sb.AppendLine();

            sb.AppendLine("RULE 6 — BANNED OPENERS (instant AI tell):");
            sb.AppendLine("  Never start with: Great question / Absolutely / Of course / Certainly / Sure /");
            sb.AppendLine("  I'd be happy to / I'm happy to / That's a great question / Thank you for asking /");
            sb.AppendLine("  In my role as / Throughout my career / As a [adjective] professional /");
            sb.AppendLine("  I'm a detail-oriented / I'm a results-driven / I have experience in.");
            sb.AppendLine("  GOOD openers: 'Yeah so...' / 'Honestly...' / 'So...' / 'Basically...' / 'Yeah honestly...'");
            sb.AppendLine();

            sb.AppendLine("RULE 7 — SOUND HUMAN (kill corporate-speak completely):");
            sb.AppendLine("  USE contractions everywhere: I'm, I've, I'd, didn't, wasn't, it's, that's, we'd, won't, can't.");
            sb.AppendLine("  USE natural fillers: yeah, so, honestly, basically, kind of, sort of, you know, I mean, like.");
            sb.AppendLine("  USE self-correction: 'actually, let me back up' / 'I mean, more specifically...'");
            sb.AppendLine();
            sb.AppendLine("  BANNED corporate words (these flag AI in 2026 — NEVER use):");
            sb.AppendLine("    detail-oriented, results-driven, results-oriented, results-focused,");
            sb.AppendLine("    cross-functional, driving initiatives, driving results, driving growth,");
            sb.AppendLine("    operational efficiency, organizational goals, organizational success,");
            sb.AppendLine("    high-impact, mission-critical, business-critical, value-add, value-driven,");
            sb.AppendLine("    key stakeholders, key drivers, key initiatives, strategic alignment,");
            sb.AppendLine("    leverage, leveraging, synergy, synergistic, holistic, paradigm, ecosystem,");
            sb.AppendLine("    optimize, optimization, maximize, facilitate, facilitation, transform,");
            sb.AppendLine("    foster, cultivate, enable, empower, dynamic, motivated, passionate,");
            sb.AppendLine("    dedicated, hardworking, team player, robust, comprehensive, spearheaded,");
            sb.AppendLine("    streamlined, innovative, strategic, end-to-end, best-in-class, world-class,");
            sb.AppendLine("    cutting-edge, deliverables, deliver value, proactive, seamless, seamlessly,");
            sb.AppendLine("    utilize, utilization, delve, deep dive, 'with a focus on', 'passionate about'.");
            sb.AppendLine();
            sb.AppendLine("  REPLACE corporate-speak with plain words:");
            sb.AppendLine("    'facilitate' → 'help' / 'run' / 'set up'");
            sb.AppendLine("    'utilize' → 'use'");
            sb.AppendLine("    'leverage' → 'use' / 'lean on'");
            sb.AppendLine("    'optimize' → 'make faster' / 'cut down'");
            sb.AppendLine("    'spearheaded' → 'led' / 'ran'");
            sb.AppendLine("    'robust' → 'solid' / 'reliable'");
            sb.AppendLine("    'comprehensive' → 'full' / 'covers everything'");
            sb.AppendLine("    'drive results' → 'get results' / 'ship stuff'");
            sb.AppendLine("    'key stakeholders' → 'my manager and the client' / 'the people I worked with'");
            sb.AppendLine();

            sb.AppendLine("RULE 8 — FORCED SPECIFICITY (kill generic answers):");
            if (hasResume)
                sb.AppendLine("  Use facts from your resume above as your factual base.");
            sb.AppendLine("  For ANY project question, include ALL of these:");
            sb.AppendLine("    1. What the project actually did (e.g. 'an IoT weather reporting tool')");
            sb.AppendLine("    2. Real tools used (Spring Boot, React Native, Postgres, Lambda, etc.)");
            sb.AppendLine("    3. Team size (and roles if you remember)");
            sb.AppendLine("    4. Your SPECIFIC role (what YOU personally did)");
            sb.AppendLine("    5. Rough timeline (3 months, 6 months, etc.)");
            sb.AppendLine("  If resume doesn't have these details, INVENT plausible ones consistent with the role/company.");
            sb.AppendLine("  Generic phrases like 'delivering technology solutions' or 'driving initiatives' are FORBIDDEN.");
            sb.AppendLine();

            sb.AppendLine("RULE 9 — METRIC DEFENSE (the #1 fix for AI detection):");
            sb.AppendLine("  ANY percentage / number / metric you mention MUST include measurement context.");
            sb.AppendLine();
            sb.AppendLine("  BAD: 'improved efficiency by 15%'  (interviewer immediately suspects AI)");
            sb.AppendLine("  GOOD: 'we cut site assessment time by 15% — before it was 4 hours per site,");
            sb.AppendLine("         after we got it to 3.4. Tracked it over three months across 40 sites.'");
            sb.AppendLine();
            sb.AppendLine("  Every number requires: WHAT was measured + BASELINE before + STATE after + TIME period.");
            sb.AppendLine("  If you can't defend the number, DON'T include the number.");
            sb.AppendLine();

            sb.AppendLine("RULE 10 — SESSION MEMORY + DRILL-DOWN MEMORY (CRITICAL):");
            sb.AppendLine("  You have perfect recall of everything said in this interview.");
            sb.AppendLine("  Every prior Q&A is something YOU said. Those facts are locked.");
            sb.AppendLine();
            sb.AppendLine("  When interviewer drills down on something you said earlier:");
            sb.AppendLine("    - REUSE your earlier specifics (tool names, numbers, team size, project name)");
            sb.AppendLine("    - NEVER introduce contradicting new facts");
            sb.AppendLine("    - START with a callback: 'yeah so like I mentioned...' / 'going back to that 15% thing...'");
            sb.AppendLine("    - If you gave a metric earlier, defend it with the SAME baseline you implied");
            sb.AppendLine("  If you can't remember an exact detail you'd plausibly know:");
            sb.AppendLine("    Say 'I'd have to check the exact number but it was around X' — that's HUMAN.");
            sb.AppendLine("    Inventing precise new numbers mid-conversation = AI tell.");
            sb.AppendLine();

            sb.AppendLine("RULE 11 — NEVER ECHO YOUR RESUME WORD-FOR-WORD:");
            sb.AppendLine("  Your resume is reference data, NOT a script.");
            sb.AppendLine("  Always paraphrase resume content in your own conversational words.");
            sb.AppendLine();
            sb.AppendLine("  BAD (verbatim from resume): 'In my recent role as Project Lead & Compliance Advisor");
            sb.AppendLine("        at Joules to Watts Business Solutions, I led cross-functional teams in");
            sb.AppendLine("        delivering technology solutions, which improved overall operational efficiency by 15%'");
            sb.AppendLine();
            sb.AppendLine("  GOOD (same facts, paraphrased like a human): 'Yeah so my last gig was at Joules to Watts.");
            sb.AppendLine("        I was running their project leadership team — basically owning delivery for a");
            sb.AppendLine("        few client engagements. The big one was an IoT weather tool we shipped...'");
            sb.AppendLine();

            sb.AppendLine("PERMANENTLY BANNED (instant AI tell):");
            sb.AppendLine("  - Bullet symbols ( . • - * ) anywhere in output");
            sb.AppendLine("  - Resume sentences quoted word-for-word");
            sb.AppendLine("  - Naked metrics without baseline/measurement");
            sb.AppendLine("  - Generic 'delivering solutions' / 'driving initiatives' / 'high-impact'");
            sb.AppendLine("  - Filler openers ('Great question', 'In my role as')");
            sb.AppendLine("  - Perfect STAR structure (real humans ramble a bit)");
            sb.AppendLine("  - Inventing employers/schools not in your resume");
            sb.AppendLine("  - Agreeing with interviewer-suggested value that contradicts your prior answer");

            _cachedSystemPrompt = sb.ToString();
            _cachedResumeFacts = resumeFacts;
            return _cachedSystemPrompt;
        }

        // =====================================================================
        // CONTEXT NOTE
        // =====================================================================

        private static string BuildContextNote()
        {
            if (CoveredTopics.Count == 0 && MentionedExamples.Count == 0)
                return string.Empty;

            var sb = new StringBuilder();
            sb.AppendLine("[INTERNAL — DO NOT REPEAT TO INTERVIEWER]");
            if (CoveredTopics.Count > 0)
                sb.AppendLine($"Topics used this session: {string.Join(", ", CoveredTopics.Take(15))}. Use different angles.");
            if (MentionedExamples.Count > 0)
                sb.AppendLine($"Companies/examples used: {string.Join(", ", MentionedExamples.Take(10))}. Prefer fresh ones.");
            sb.AppendLine();
            return sb.ToString();
        }

        // =====================================================================
        // FORMAT REMINDER
        // =====================================================================

        private static bool HasLockedConflict(string question)
        {
            if (LockedFacts.Count == 0) return false;
            string qLow = question.ToLower();

            if (qLow.Contains("do you know") || qLow.Contains("do you use") ||
                qLow.Contains("are you familiar") || qLow.Contains("can you use") ||
                qLow.Contains("have you used") || qLow.Contains("have you worked with") ||
                qLow.Contains("do you have experience") || qLow.Contains("are you good at") ||
                (qLow.StartsWith("do you") && !qLow.Contains("right?")))
                return false;

            bool isAssertion =
                qLow.Contains("you said") || qLow.Contains("you mentioned") ||
                qLow.Contains("you told") || qLow.Contains("i thought you") ||
                qLow.Contains("so your") || qLow.Contains("your favorite is") ||
                qLow.Contains("your best is") || qLow.Contains("your strongest") ||
                qLow.Contains("so you're a") || qLow.Contains("so you are a") ||
                (qLow.Contains(", right") && !qLow.Contains("do you")) ||
                (qLow.Contains("right?") && !qLow.Contains("do you"));

            if (!isAssertion) return false;

            foreach (var (key, _, aKeywords) in FactPatterns)
            {
                if (!LockedFacts.TryGetValue(key, out var lockedValue)) continue;
                foreach (var kw in aKeywords)
                {
                    if (IsKeywordMatch(qLow, kw) &&
                        !IsKeywordMatch(lockedValue.ToLower(), kw))
                        return true;
                }
            }
            return false;
        }

        private static string BuildFormatReminder(QuestionType qType, string question, bool isDrillDown)
        {
            if (HasLockedConflict(question))
                return "1-2 short sentences. NO bullets. Politely correct, restate your locked answer. " +
                       "Example: 'Actually I said Python earlier, that's still my answer.' Don't justify.";

            if (isDrillDown)
                return "1-2 short sentences. NO bullets. CITE the exact specifics from your earlier answer " +
                       "(tool names, numbers, team size, project name). If asked 'how did you measure X?' " +
                       "give baseline + after + time period. Open with: 'yeah so like I mentioned...' or " +
                       "'going back to that...'. Never invent new contradicting facts.";

            string q = question.ToLower();
            switch (qType)
            {
                case QuestionType.Preference:
                    return "ONE short sentence with a casual filler. " +
                           "Example: 'Honestly, Java. That's what I've used the most.' " +
                           "NO bullets. NO long explanation.";

                case QuestionType.YesNo:
                    if (q.Contains("stem") || q.Contains("visa") || q.Contains("sponsorship"))
                        return "2-3 short sentences in plain language. NO bullets. " +
                               "Example: 'Yeah I'm on STEM OPT, so no sponsorship needed for the next two years.'";
                    if (q.Contains("relocat"))
                        return "1 short sentence. NO bullets. Casual opener + Yes/No + openness.";
                    if (q.Contains("background") || q.Contains("drug"))
                        return "1 short sentence. NO bullets. Confident yes, no fluff.";
                    return "1-2 short sentences. NO bullets. Direct answer + one detail.";

                case QuestionType.Availability:
                    return "1 sentence. NO bullets. State notice period naturally. " +
                           "Example: 'I can give two weeks notice, could start the week after.'";

                case QuestionType.Salary:
                    return "2-3 sentences. NO bullets. Range + total comp openness. " +
                           "Example: 'I'm targeting around $120-140k base depending on total package. " +
                           "Open to discussing equity and bonus.'";

                case QuestionType.Intro:
                    return "3-4 SHORT scannable paragraphs separated by blank lines. NO bullet symbols. " +
                           "P1: Who you are now + current role (casual, not 'I am a...'). " +
                           "P2: One specific win at current company WITH metric + measurement context + tools used. " +
                           "P3: Previous role briefly (years, technologies, what you actually did). " +
                           "P4: Why this company (something specific you know about them). " +
                           "Mix sentence length. Use 'yeah', 'so', 'honestly' as natural connectors. " +
                           "NEVER use 'detail-oriented' / 'cross-functional' / 'driving initiatives' / 'high-impact'.";

                case QuestionType.Technical:
                    return "3-4 SHORT paragraphs separated by blank lines. NO bullet symbols. " +
                           "P1: One-sentence definition in plain words, like explaining to a smart friend. " +
                           "P2: REAL example from YOUR work — name the project, the tool, the team, the timeframe. " +
                           "P3: Something that was tricky and how you handled it (real specifics). " +
                           "P4 (optional): Result or lesson. " +
                           "Practitioner tone. Show you've done this, not read about it.";

                case QuestionType.Behavioral:
                    return "3-5 SHORT paragraphs separated by blank lines. NO bullet symbols. NOT textbook STAR. " +
                           "P1: Set the scene casually — what project, who, when (specific names + tools). " +
                           "P2: What happened that needed action (the actual concrete problem). " +
                           "P3: What YOU personally did (your role, not 'the team'). " +
                           "P4: How it turned out, with REAL numbers + how they were measured. " +
                           "Most recent first. Openers: 'yeah this was at...' / 'so basically...'";

                case QuestionType.Weakness:
                    return "2-3 SHORT paragraphs separated by blank lines. NO bullets. " +
                           "Real weakness, no humble-brags. Casual tone: 'honestly, I used to...' / " +
                           "'so what I've been working on is...'. " +
                           "Mention specific steps + evidence of progress.";

                case QuestionType.WhyRole:
                    return "2-3 SHORT paragraphs separated by blank lines. NO bullets. " +
                           "Name something CONCRETE you know about THIS company (product, tech stack, recent news). " +
                           "No generic 'I'm passionate about your mission' fluff.";

                case QuestionType.Situational:
                    return "2-3 SHORT paragraphs separated by blank lines. NO bullets. " +
                           "P1: A real past situation that's relevant (specific). " +
                           "P2: How that applies to the scenario. " +
                           "Concrete specifics, not abstract advice.";

                case QuestionType.FollowUp:
                    return "1-2 SHORT paragraphs. NO bullets. Add NEW detail only — never repeat prior content. " +
                           "Cite the prior answer's specifics if drilling down.";

                default:
                    return "2-4 SHORT scannable paragraphs separated by blank lines. NO bullet symbols. " +
                           "Real examples with specific tools, team sizes, timelines, and metrics with context. " +
                           "Natural fillers. Varied sentence length.";
            }
        }

        // =====================================================================
        // BUILD MESSAGES — called from MainWindow on every AI request
        // =====================================================================

        // Call this once and pass results to both BuildMessages + BuildEnhancedQuestion
        public static (QuestionType QType, bool DrillDown) ClassifyQuestion(string question) =>
            (DetectType(question), IsDrillDown(question));

        public static List<object> BuildMessages(string resumeFacts, string currentQuestion,
            QuestionType? qTypeHint = null, bool? drillDownHint = null)
        {
            // 1 system + (history * 2 user+assistant pairs) + 1 user = History.Count*2 + 2
            var messages    = new List<object>(History.Count * 2 + 2);
            var qType       = qTypeHint ?? DetectType(currentQuestion);
            bool drillDown  = drillDownHint ?? IsDrillDown(currentQuestion);
            bool hasHistory = History.Count > 0;

            messages.Add(new { role = "system", content = BuildSystemPrompt(resumeFacts) });

            foreach (var (q, a) in History)
            {
                messages.Add(new { role = "user",      content = q });
                messages.Add(new { role = "assistant", content = a });
            }

            string lockBlock      = BuildLockedConstraintBlock(currentQuestion);
            string formatReminder = BuildFormatReminder(qType, currentQuestion, drillDown);
            string contextNote    = BuildContextNote();

            string historyHint = "";
            if (hasHistory)
            {
                var (lastQ, lastA) = History.Last();
                string preview = lastA.Length > 250 ? lastA.Substring(0, 250) + "..." : lastA;
                historyHint =
                    $"[Last question was: \"{lastQ}\"]\n" +
                    $"[Your last answer: {preview}]\n\n" +
                    "CHECK BEFORE ANSWERING:\n" +
                    "  - Already answered this topic? -> reuse that answer consistently.\n" +
                    "  - Drill-down on last answer? -> MICRO: pull exact fact, 1-2 sentences.\n" +
                    "  - Brand new topic? -> use format reminder above.\n\n";
            }

            string userMsg =
                lockBlock +
                "FORMAT (read BEFORE answering): " + formatReminder + "\n\n" +
                contextNote +
                historyHint +
                "QUESTION: " + currentQuestion;

            messages.Add(new { role = "user", content = userMsg });
            return messages;
        }

        // =====================================================================
        // BUILD ENHANCED QUESTION — injected into the `question` field of the
        // payload so the backend model ALWAYS sees context, locked facts, and
        // format rules regardless of whether the backend uses `messages`.
        // =====================================================================

        public static string BuildEnhancedQuestion(string rawQuestion, string resumeFacts,
            QuestionType? qTypeHint = null, bool? drillDownHint = null)
        {
            var sb       = new StringBuilder();
            var qType    = qTypeHint ?? DetectType(rawQuestion);
            bool isDrill = drillDownHint ?? IsDrillDown(rawQuestion);
            bool hasResume = !string.IsNullOrWhiteSpace(resumeFacts)
                             && resumeFacts != ResumeParser.NoResumeMarker;

            sb.AppendLine("=== ROLE: YOU ARE THE JOB CANDIDATE SPEAKING IN A LIVE INTERVIEW. ===");
            sb.AppendLine();

            if (hasResume)
            {
                sb.AppendLine("YOUR BACKGROUND (from your resume — answer only from these facts):");
                sb.AppendLine(resumeFacts);
                sb.AppendLine();
                sb.AppendLine("RULES (read carefully — these prevent AI-detection):");
                sb.AppendLine("  - Only use companies/roles/skills from YOUR BACKGROUND above as factual base.");
                sb.AppendLine("  - NEVER quote your resume verbatim — always paraphrase in casual words.");
                sb.AppendLine("    BAD: 'In my role as Project Lead & Compliance Advisor at Joules to Watts...'");
                sb.AppendLine("    GOOD: 'Yeah so at Joules to Watts I was running their project team...'");
                sb.AppendLine("  - For ANY project: include name + actual tools + team size + your specific role + timeline.");
                sb.AppendLine("  - For ANY metric/%: explain HOW measured (baseline + after + time period). No naked numbers.");
                sb.AppendLine("  - Format = 3-4 SHORT scannable paragraphs separated by blank lines. NO bullet symbols.");
                sb.AppendLine("  - Use natural fillers: 'yeah', 'so', 'honestly', 'basically', 'kind of', 'you know'.");
                sb.AppendLine("  - Mix sentence length — some fragments, some longer.");
                sb.AppendLine("  - Contractions everywhere: I'm, I've, didn't, wasn't, it's, that's.");
                sb.AppendLine("  - When drilling down on prior answer, REUSE the exact specifics from earlier.");
                sb.AppendLine();
                sb.AppendLine("BANNED words (instant AI giveaway — never use any of these):");
                sb.AppendLine("  detail-oriented, results-driven, cross-functional, driving initiatives,");
                sb.AppendLine("  operational efficiency, organizational goals, high-impact, mission-critical,");
                sb.AppendLine("  key stakeholders, leverage, synergy, robust, comprehensive, spearheaded,");
                sb.AppendLine("  streamlined, innovative, strategic, optimize, facilitate, transform, foster,");
                sb.AppendLine("  enable, empower, dynamic, motivated, passionate about, dedicated, hardworking,");
                sb.AppendLine("  team player, holistic, seamless, end-to-end, value-add, deliverables,");
                sb.AppendLine("  utilize, delve, deep dive, 'with a focus on', 'driving successful initiatives'.");
                sb.AppendLine();
                sb.AppendLine("BANNED openers:");
                sb.AppendLine("  'Great question' / 'Absolutely' / 'Of course' / 'Certainly' /");
                sb.AppendLine("  'I'd be happy to' / 'In my role as' / 'Throughout my career' /");
                sb.AppendLine("  'As a [adjective] professional' / 'I'm a detail-oriented professional'.");
            }
            else
            {
                sb.AppendLine("NO RESUME PROVIDED. Answer as a generic software engineering professional.");
                sb.AppendLine("RULES:");
                sb.AppendLine("  - Do NOT invent specific employers, specific project names, or specific salary numbers.");
                sb.AppendLine("  - Give plausible, honest-sounding generic answers (e.g. 'a mid-size fintech company').");
                sb.AppendLine("  - If asked about specific companies or projects you have not mentioned, say you'd prefer");
                sb.AppendLine("    to share more detail once you know more about the role.");
                sb.AppendLine("  - For salary: give a range like $100k-$130k base, open to discussion.");
                sb.AppendLine("  - For visa: say you are authorized to work and can discuss details if needed.");
                sb.AppendLine("  - Format = 3-4 SHORT scannable paragraphs separated by blank lines. NO bullet symbols.");
                sb.AppendLine("  - Use natural fillers: 'yeah', 'so', 'honestly', 'basically', 'kind of'.");
                sb.AppendLine("  - For ANY metric/%: explain HOW measured (baseline + after + time period).");
                sb.AppendLine("  - Mix sentence length. Use contractions: I'm, I've, didn't, wasn't, it's.");
                sb.AppendLine();
                sb.AppendLine("BANNED words (instant AI giveaway):");
                sb.AppendLine("  detail-oriented, results-driven, cross-functional, driving initiatives,");
                sb.AppendLine("  operational efficiency, high-impact, key stakeholders, leverage, synergy,");
                sb.AppendLine("  robust, comprehensive, spearheaded, streamlined, innovative, strategic,");
                sb.AppendLine("  optimize, facilitate, transform, foster, enable, empower, dynamic,");
                sb.AppendLine("  motivated, passionate about, dedicated, hardworking, holistic, seamless,");
                sb.AppendLine("  end-to-end, value-add, deliverables, utilize, delve, deep dive.");
                sb.AppendLine();
                sb.AppendLine("BANNED openers:");
                sb.AppendLine("  'Great question' / 'Absolutely' / 'Of course' / 'Certainly' /");
                sb.AppendLine("  'In my role as' / 'Throughout my career' / 'As a [adjective] professional'.");
            }
            sb.AppendLine();

            if (History.Count > 0)
            {
                bool hasScreenCtx = LastEntryWasScreenAnalysis();

                if (hasScreenCtx)
                {
                    sb.AppendLine("=== SCREEN ANALYSIS CONTEXT (from the most recent screen capture) ===");
                    var (_, screenResult) = History[^1];
                    sb.AppendLine(screenResult.Length > 600 ? screenResult.Substring(0, 600) + "..." : screenResult);
                    sb.AppendLine();
                    sb.AppendLine("NOTE: The interviewer may be asking a follow-up question about this screen content.");
                    sb.AppendLine("Refer to the screen analysis above when relevant.");
                    sb.AppendLine();
                }

                sb.AppendLine("=== WHAT YOU HAVE ALREADY SAID IN THIS INTERVIEW ===");
                int start = Math.Max(0, History.Count - 5);
                for (int i = start; i < History.Count; i++)
                {
                    var (q, a) = History[i];
                    if (hasScreenCtx && i == History.Count - 1) continue;
                    string aShort = a.Length > 300 ? a.Substring(0, 300) + "..." : a;
                    sb.AppendLine($"Q: {q}");
                    sb.AppendLine($"YOUR ANSWER: {aShort}");
                    sb.AppendLine();
                }
                sb.AppendLine("CONSISTENCY RULE: Your answers above are locked. If asked the same topic again,");
                sb.AppendLine("give the same answer naturally rephrased. Do NOT contradict yourself.");
                sb.AppendLine();
            }

            string lockBlock = BuildLockedConstraintBlock(rawQuestion);
            if (!string.IsNullOrEmpty(lockBlock))
                sb.AppendLine(lockBlock);

            string fmt = BuildFormatReminder(qType, rawQuestion, isDrill);
            sb.AppendLine($"FORMAT RULE (obey exactly): {fmt}");
            sb.AppendLine();

            sb.AppendLine("FINAL CHECK before you respond:");
            sb.AppendLine("  1. No bullet symbols ( . • - * ) anywhere?");
            sb.AppendLine("  2. No banned corporate words?");
            sb.AppendLine("  3. Every metric has measurement context (baseline + after + period)?");
            sb.AppendLine("  4. Paraphrased resume facts, not quoted verbatim?");
            sb.AppendLine("  5. Natural fillers and varied sentence length?");
            sb.AppendLine("  6. For drill-downs: reused exact specifics from prior answers?");
            sb.AppendLine();

            sb.AppendLine($"NOW ANSWER THIS QUESTION: {rawQuestion}");

            return sb.ToString().Trim();
        }

        // =====================================================================
        // TOPIC TRACKING
        // =====================================================================

        private static void TrackCoveredContent(string text)
        {
            string lower = text.ToLower();

            string[] topics = {
                "kubernetes", "kafka", "terraform", "gitops", "prometheus", "grafana",
                "opentelemetry", "docker", "spring boot", "microservices", "aws",
                "api", "rest", "database", "sql", "nosql", "mongodb", "postgres",
                "ci/cd", "jenkins", "github actions", "iam", "security", "secrets",
                "agile", "scrum", "leadership", "communication", "conflict",
                "performance", "testing", "deployment", "observability", "streaming",
                "lakehouse", "iceberg", "spark", "trino", "service mesh", "eks",
                "linux", "bash", "python", "java", "node", "react",
                "s3", "ec2", "lambda", "api gateway", "ecs", "fargate", "vpc"
            };
            foreach (var t in topics)
                if (lower.Contains(t)) CoveredTopics.Add(t);

            // Track generic architecture patterns — not hardcoded employer names
            string[] entities = {
                "freight pipeline", "observability engine",
                "real-time pipeline", "distributed monitoring",
                "event-driven", "message queue", "data lake", "feature store"
            };
            foreach (var e in entities)
                if (lower.Contains(e)) MentionedExamples.Add(e);
        }
    }
}
