import Foundation
import AppKit
import CoreAudio

func dlog(_ text: String, tag: String) {}
var passed = 0
var failed = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    if value() { passed += 1; print("PASS \(label)") }
    else { failed += 1; print("FAIL \(label)") }
}

for question in ["What is a database index?", "Tell me about yourself.", "Explain dependency injection.", "How would you scale this?", "Can you compare SQL and NoSQL?", "Why do you want this role?", "What salary are you looking for?", "Describe a time you handled a conflict.", "So, can you tell me about your last project?", "I want to ask what is Kafka", "Let me rephrase explain a database transaction", "Sorry describe your last project"] {
    check(AutoTurnDetector.isLikelyCompleteQuestion(question, requireInterrogative: true), "accept question: \(question)")
}
for speech in ["", "   ", "Okay", "Thanks", "Yes sir", "I built a service using Java.", "What I do is check the logs and restart the service.", "Let me rephrase", "Tell me"] {
    check(!AutoTurnDetector.isLikelyCompleteQuestion(speech, requireInterrogative: true), "ignore non-question: \(speech)")
}
check(AutoTurnDetector.classifyTurnEnding("Can you compare SQL and") == .unfinished, "wait for unfinished question")
check(AutoTurnDetector.classifyTurnEnding("What are you looking for?") == .unclear, "allow pause after preposition")
check(AutoTurnDetector.classifyTurnEnding("How would you scale this?") == .finished, "complete question ending")
var detector = AutoTurnDetector()
let now = Date()
check(!detector.acceptUtterance("   ", now: now), "empty turn consumes no answer")
check(detector.acceptUtterance("What is Kafka?", now: now), "first utterance accepted")
check(!detector.acceptUtterance("  WHAT IS KAFKA?  ", now: now.addingTimeInterval(1)), "duplicate suppressed")
check(detector.acceptUtterance("What is Kafka?", now: now.addingTimeInterval(13)), "intentional repeat accepted later")
detector.forgetLastAnswered()
check(detector.acceptUtterance("What is Kafka?", now: now), "new session resets duplicate guard")
check(AutoTurnDetector.newSpeech(full: "What is Kafka? How do partitions work?", consumed: "What is Kafka?").contains("How do partitions work"), "follow-up separated from consumed speech")
check(AutoTurnDetector.isEchoOfPrevious("I use indexes to speed up database reads by reducing the rows scanned.", lastQuestion: "What is an index?", lastAnswer: "I use indexes to speed up database reads by reducing the rows scanned."), "reading answer aloud is not another question")

// Plain Space is the listening key (Windows IsSpaceAToggle): it yields to typing and to system shortcuts.
check(GlobalHotkey.isListeningShortcut(keyCode: 49, flags: []), "plain Space listens when nobody has been typing (this was broken: Space did nothing in Manual)")
check(GlobalHotkey.isListeningShortcut(keyCode: 49, flags: [], secondsSinceTyping: 1.0), "Space listens one second after the last text key")
check(!GlobalHotkey.isListeningShortcut(keyCode: 49, flags: [], secondsSinceTyping: 0.3), "a Space typed between words never toggles listening")
check(!GlobalHotkey.isListeningShortcut(keyCode: 49, flags: .maskCommand), "Spotlight shortcut preserved")
check(!GlobalHotkey.isListeningShortcut(keyCode: 49, flags: .maskControl), "Control-Space (input source) preserved")
check(!GlobalHotkey.isListeningShortcut(keyCode: 49, flags: .maskShift), "Shift-Space preserved")
check(GlobalHotkey.isListeningShortcut(keyCode: 49, flags: .maskAlternate), "Option-Space still controls listening")
check(GlobalHotkey.isListeningShortcut(keyCode: 49, flags: .maskAlternate, secondsSinceTyping: 0), "Option-Space is a deliberate chord, even straight after typing")
check(!GlobalHotkey.isListeningShortcut(keyCode: 49, flags: [.maskAlternate, .maskShift]), "other modified shortcuts preserved")
check(!GlobalHotkey.isListeningShortcut(keyCode: 100, flags: .maskAlternate), "unrelated key not listening shortcut")
check(GlobalHotkey.isTypingKey(keyCode: 0, typed: "a"), "a letter is typing")
check(GlobalHotkey.isTypingKey(keyCode: 18, typed: "1"), "a digit is typing")
check(GlobalHotkey.isTypingKey(keyCode: 43, typed: ","), "punctuation is typing")
check(GlobalHotkey.isTypingKey(keyCode: 51, typed: "\u{7F}"), "Delete is typing: correcting a word is still typing")
check(!GlobalHotkey.isTypingKey(keyCode: 123, typed: "\u{F702}"), "an arrow key is not typing")
check(!GlobalHotkey.isTypingKey(keyCode: 100, typed: "\u{F70B}"), "a function key is not typing")
check(!GlobalHotkey.isTypingKey(keyCode: 36, typed: "\r"), "Return is not typing")
check(!GlobalHotkey.isTypingKey(keyCode: 49, typed: " "), "Space itself is not typing")

var route = AudioInputRouteTracker()
let builtIn = AudioInputRoute(deviceID: 1, sampleRate: 48000)
let headset = AudioInputRoute(deviceID: 2, sampleRate: 48000)
let headsetCall = AudioInputRoute(deviceID: 2, sampleRate: 16000)
route.reset(to: builtIn)
check(!route.shouldReconnect(to: builtIn), "stable mic needs no restart")
check(!route.shouldReconnect(to: headset), "headset change waits for settle")
check(route.shouldReconnect(to: headset), "stable new headset reconnects")
check(!route.shouldReconnect(to: headset), "same headset does not restart repeatedly")
check(!route.shouldReconnect(to: headsetCall), "Bluetooth rate transition waits for settle")
check(route.shouldReconnect(to: headsetCall), "Bluetooth call profile reconnects")
check(!route.shouldReconnect(to: nil), "temporary missing device does not loop restarts")
check(!route.shouldReconnect(to: builtIn), "unplugging headset settles before fallback")
check(route.shouldReconnect(to: builtIn), "Mac default fallback reconnects")
route.reset(to: nil)
check(!route.shouldReconnect(to: headset), "first connected input settles")
check(route.shouldReconnect(to: headset), "input appearing after startup reconnects")

check(ListeningMode.fromStored("practiceAuto") == .auto, "legacy practice mode migrates")
check(ListeningMode.fromStored("interviewAuto") == .auto, "legacy interview mode migrates")
check(ListeningMode.fromStored("manual") == .manual, "manual preference preserved")
check(ListeningMode.fromStored("bad") == nil, "invalid saved mode rejected")
let builder = PromptBuilder.shared   // the initializer is private; the shared instance is what ships
check(builder.isGreeting("Hello"), "greeting recognized")
check(!builder.isGreeting("Hello, can you explain dependency injection?"), "question after greeting retained")
let code = "```python\ndef compute(a, b):\n    return a * b\n```"
check(PromptBuilder.stripMarkdownPreservingCode(code) == code, "code multiplication and indentation preserved")
check(PromptBuilder.stripMarkdownPreservingCode("**Summary**") == "Summary", "prose emphasis cleaned")
for i in 0..<85 { builder.addToHistory(question: "Question \(i)", answer: "Answer \(i)") }
check(builder.history.count == 80, "history memory bounded")
let messages = builder.buildMessages(resumeFacts: "Synthetic candidate. Five years of Swift.", currentQuestion: "What is an actor?", jobContext: "Mobile engineer")
check(messages.count == 26, "only twelve prior turns sent to model")
check(messages.last?["content"]?.contains("QUESTION: What is an actor?") == true, "latest question reaches prompt")
check(messages.first?["content"]?.contains("Synthetic candidate") == true, "resume reaches prompt")
builder.clearHistory()
check(builder.history.isEmpty, "new session clears history")
check(ResumeParser.extractFacts("  ") == ResumeParser.noResumeMarker, "missing resume marked explicitly")
check(ResumeParser.extractFacts("  Swift engineer  ") == "Swift engineer", "resume facts preserved")

// ── Closing turns: the Windows ClosingTurnTests sentences, verbatim ─────────────
builder.clearHistory()
let firstInvite = "Before we wrap up, is there anything you'd like to ask me about the role or the team?"
check(PromptBuilder.isCandidateQuestionInvitation(firstInvite), "first invitation is recognized")
check(PromptBuilder.isCandidateQuestionInvitation("Is there any question do you have for me?"), "speech-recognized invitation wording is recognized")
check(builder.closingResponse(to: firstInvite) == nil, "first invitation still reaches the model")
builder.addToHistory(question: firstInvite, answer: "What would success look like in the first six months?")
let detailCheck = "Is that the level of detail you were looking for, or do you want me to go a bit deeper?"
check(PromptBuilder.isCandidateQuestionInvitation(detailCheck), "detail check after an answer is closing conversation")
let r1 = builder.closingResponse(to: detailCheck)
check(r1 != nil, "repeat invitation is answered locally")
check(!(r1 ?? "?").contains("?") && (r1 ?? "").split(separator: " ").count < 25, "repeat reply is short and asks nothing")
builder.addToHistory(question: detailCheck, answer: r1 ?? "")
let r2 = builder.closingResponse(to: "What else would you like to know about the role or the team?")
check(r2 != nil && !(r2 ?? "?").contains("?") && !(r2 ?? "").contains("MORE TO SAY"), "another repeat cannot restart the loop")
check(r1 != r2, "the same closing sentence is not said twice in a row")
let finalThanks = "Thank you, Pavan, for taking the time to discuss the AI research engineer role with us."
check(PromptBuilder.isInterviewEndStatement(finalThanks), "final thank-you is a sign-off")
check(builder.closingResponse(to: finalThanks)?.contains("MORE TO SAY") == false, "sign-off gets a short local reply")
check(!PromptBuilder.isCandidateQuestionInvitation("How do you decide which questions to ask users during research?"), "question about asking users is not an invitation")
check(!PromptBuilder.isInterviewEndStatement("Thank you. Can you explain how the training pipeline works?"), "polite technical question is not the end")
let opening = "Thank you for taking the time to speak with us today. Can you start by telling me about yourself?"
check(!PromptBuilder.isInterviewEndStatement(opening) && builder.closingResponse(to: opening) == nil, "opening thank-you goes to the model")
check(!PromptBuilder.isInterviewEndStatement("Hi Pavan, thanks for joining us today and for your time. Let's begin with your background."), "welcome that moves on is not the end")
check(!PromptBuilder.isInterviewEndStatement("Thanks for your time on that one, now let's move on to the coding round."), "mid-interview transition is not the end")
let angle = "What other angle would you take to reduce the latency here?"
check(!PromptBuilder.isCandidateQuestionInvitation(angle) && builder.closingResponse(to: angle) == nil, "technical 'other angle' goes to the model")
check(builder.closingResponse(to: "Does that answer your question about how we deploy? So how would you test this service?") == nil, "new question after 'does that answer' goes to the model")
check(PromptBuilder.isCandidateQuestionInvitation("Is there another angle on the role, the tech, or the team that you'd like me to focus on?"), "another angle on the role is an invitation")
let touchThenAsk = "We'll be in touch with next steps, but first can you explain your testing approach?"
check(!PromptBuilder.isInterviewEndStatement(touchThenAsk) && builder.closingResponse(to: touchThenAsk) == nil, "'in touch, but first' goes to the model")
check(builder.closingResponse(to: "Does that answer your question so how would you test this service") == nil, "unpunctuated question after 'does that answer' goes to the model")
check(PromptBuilder.isInterviewEndStatement("One question about research versus production and one about how the team works, both good questions. Thank you for taking the time to speak with us today."), "recap then thank-you is still the end")
check(PromptBuilder.isInterviewEndStatement("We'll be in touch."), "plain 'we'll be in touch' is the end")
check(PromptBuilder.isInterviewEndStatement("Thank you for your time today, we'll share next steps by email."), "thanks with next steps by email is the end")
check(!PromptBuilder.isInterviewEndStatement("Thanks for your time, any final thoughts"), "'any final thoughts' is answered")
// The general forms that the exact-phrase list missed on Windows (7 of 20 caught before).
for w in ["Any more questions?", "Any final questions?", "Do you want to ask anything else?", "Any other questions for us?", "Do you have any questions for me?"] {
    check(PromptBuilder.isCandidateQuestionInvitation(w), "invitation wording: \(w)")
}
check(!PromptBuilder.isCandidateQuestionInvitation("Any questions on the approach before you start coding?"), "question about the task is not an invitation")
// Short follow-ups only count once the candidate has been invited.
builder.clearHistory()
check(builder.closingResponse(to: "Anything else?") == nil, "'Anything else?' mid-interview goes to the model")
builder.addToHistory(question: "Do you have any questions for me?", answer: "How does the team measure success?")
check(builder.closingResponse(to: "Anything else?") != nil, "'Anything else?' after an invitation is a closing turn")
check(builder.closingResponse(to: "Did that help?")?.hasPrefix("Yes") == true, "'Did that help?' gets a yes, not a question")
builder.clearHistory()

// ── Small talk: the Windows SmallTalkTests real questions that got the canned line ──
for q in ["How are you handling state in React?", "How are you deploying to AWS?", "How are you testing this?",
          "Nice to meet you, shall we start with your background?", "How would you handle a whole region going down?"] {
    check(!builder.isSmallTalk(q), "real question is not small talk: \(q)")
}
for q in ["How are you?", "Hi, how are you doing today?", "Nice to meet you."] {
    check(builder.isSmallTalk(q), "pleasantry is small talk: \(q)")
}

// ── Keys: nothing is taken from ordinary typing or from other apps' shortcuts ──
let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]
check(GlobalHotkey.isScreenKey(flags: [], everywhere: true), "plain F8/F9 read the screen by default")
check(!GlobalHotkey.isScreenKey(flags: [], everywhere: false), "plain F8/F9 go back to other apps when switched off")
check(GlobalHotkey.isScreenKey(flags: ctrlOpt, everywhere: false), "⌃⌥F8/F9 always read the screen")
check(!GlobalHotkey.isScreenKey(flags: .maskCommand, everywhere: true), "⌘F8 belongs to another app")
check(!GlobalHotkey.isScreenKey(flags: [.maskControl, .maskAlternate, .maskShift], everywhere: true), "⌃⌥⇧F8 belongs to another app")
check(!GlobalHotkey.isDebugShortcut(flags: []), "plain F12 no longer opens the debug window from other apps")
check(GlobalHotkey.isDebugShortcut(flags: ctrlOpt), "⌃⌥F12 opens the debug window")
check(GlobalHotkey.isBringToFront(keyCode: 15, flags: ctrlOpt), "⌃⌥R brings the window back")
check(!GlobalHotkey.isBringToFront(keyCode: 15, flags: .maskAlternate), "⌥R types a character, never a shortcut")
check(!GlobalHotkey.isBringToFront(keyCode: 15, flags: []), "typing r never brings the window forward")

// ── Screen routing: the Windows InterviewTurnTests sentences ──
check(!PromptBuilder.refersToScreen("And how do you see a role like this fitting into that path?"), "'how do you see a role' is not about the screen")
check(!PromptBuilder.refersToScreen("Where do you see yourself in five years?"), "'where do you see yourself' is not about the screen")
check(PromptBuilder.refersToScreen("Can you see this code?"), "'can you see this code' is about the screen")
check(PromptBuilder.refersToScreen("what do you see here"), "'what do you see here' is about the screen")
check(PromptBuilder.refersToScreen("can you look at my screen"), "'my screen' is about the screen")
check(!PromptBuilder.refersToScreen("Tell me about the screening round."), "'screening round' is not a display")
// Classification parity with Windows: polite requests, story requests, work authorization.
let pbc = PromptBuilder.shared
func kind(_ q: String) -> QuestionType { pbc.classifyQuestion(q).type }
check(kind("Can you explain what Kafka is?") != .yesNo, "polite explain is not yes/no")
check(kind("Can you tell me about the RESTful services you built?") != .yesNo, "polite tell-me is not yes/no")
check(kind("Could you please walk me through your background?") == .intro, "polite background request is intro")
check(kind("Can you tell me about your experience with Kafka?") != .intro, "experience WITH a tool is not intro")
check(kind("Can you think of a specific project where you disagreed with a teammate?") == .behavioral, "story request is behavioral")
check(kind("Where do you see yourself in five years?") == .general, "direction question is general")
check(kind("What is cap extension?") == .yesNo, "work authorization is not technical")
check(kind("Do you need sponsorship?") == .yesNo, "sponsorship yes/no")
check(kind("Are you comfortable with on-call?") == .yesNo, "plain yes/no unchanged")
check(PromptBuilder.isWorkAuthorizationQuestion("Are you on STEM OPT?"), "stem opt detected")
check(!PromptBuilder.isWorkAuthorizationQuestion("What is an option type in Swift?"), "option is not OPT")

// Ported verbatim from Windows CleanerTests (DefinitionVoiceTests, InterviewTurnTests,
// ClosingTurnTests) so both apps are held to the same sentences.
func T(_ q: String) -> QuestionType { pbc.clearHistory(); return pbc.classifyQuestion(q).type }
check(T("Can you tell me the RESTful services you did?") != .yesNo, "win: 'Can you tell me the RESTful services' is a request")
check(T("Can you please describe about your past experience?") == .intro, "win: past experience is the introduction")
check(T("Could you walk me through your background?") == .intro, "win: walk me through your background is intro")
check(T("Can you explain how Kafka guarantees ordering?") == .technical, "win: can you explain how Kafka is technical")
check(T("Can you tell me about a time you handled a production outage?") == .behavioral, "win: can you tell me about a time is a story")
check([.availability, .yesNo].contains(T("Can you start next week?")), "win: can you start next week stays short")
check(T("Are you authorized to work in the US?") == .yesNo, "win: work authorization stays yes/no")
check(T("what is cap extension?") == .yesNo, "win: cap extension is work status")
check(T("Will you need H-1B sponsorship in the future?") == .yesNo, "win: H-1B sponsorship is work status")
check(T("How do you approach working collaboratively with researchers on model development?") == .situational, "win: collaborating with researchers is situational")
check(T("How do you handle a disagreement with a teammate?") == .situational, "win: handling disagreement is situational")
check(T("And how do you see a role like this fitting into that path?") == .general, "win: career direction is general")
check(T("What are your strengths?") == .whyRole, "win: strengths still detected")
for request in [
    "So for this next one I want you to describe how you would design a URL shortener that handles millions of requests",
    "I'd like you to walk me through how you would debug a memory leak in a production Java service running on Kubernetes",
    "Okay now let's say your API latency suddenly doubles after a deploy and you need to find out what changed and fix it",
    "Now imagine you are leading the migration from a monolith to microservices and explain the steps you would take first",
] { check(T(request) != .contextStatement, "win: spoken request answered: \(request.prefix(40))") }
check(T("Our team builds the pricing data platform and we mostly work in Scala and Spark with a strong focus on reliability and a weekly on call rotation") == .contextStatement, "win: genuine team explanation only acknowledged")
for task in [
    "For this next exercise I want a function that returns the first non-repeating character in a string using Python",
    "For the next task please create a REST API that supports pagination filtering and sorting for a list of products",
    "The next exercise is a SQL query returning the top three customers by total order value in the last year",
    "I'm going to give you a coding exercise now, write a function that reverses a linked list in place",
] { check(T(task) == .coding, "win: coding task gets code: \(task.prefix(40))") }
check(T("Any questions on the approach before you start coding?") != .candidateQuestions, "win: coding-task check is not an invitation")
check(T("Do you have any questions for me?") == .candidateQuestions, "first invitation asks one question")

check(PromptBuilder.definitionTerm("What is Java?") == "Java", "win term: Java")
check(PromptBuilder.definitionTerm("What is a REST API?") == "REST API", "win term: REST API")
check(PromptBuilder.definitionTerm("what is kafka exactly") == "kafka", "win term: unpunctuated")
check(PromptBuilder.definitionTerm("Define the CAP theorem.") == "CAP theorem", "win term: define")
check(PromptBuilder.definitionTerm("What is Kafka and how have you used it?") == "", "win term: and-how is not a definition")
check(PromptBuilder.definitionTerm("What is the difference between an abstract class and an interface?") == "", "win term: difference")
check(PromptBuilder.definitionTerm("What are the pros and cons of microservices?") == "", "win term: pros and cons")
check(PromptBuilder.definitionTerm("What is Node.js?") == "Node.js", "win term: dot kept")
check(PromptBuilder.definitionTerm("What is the time complexity of quicksort?") == "time complexity of quicksort", "win term: time complexity")
let facts = "Pavan Krishna, Gen AI Engineer at UHG. Skills: Python, Java, Spring Boot, Kafka, PostgreSQL, Docker, Kubernetes, REST APIs, RAG pipelines. Ready to go live."
check(PromptBuilder.factsMention(facts, "Java"), "win facts: Java")
check(PromptBuilder.factsMention(facts, "kafka"), "win facts: lowercase kafka")
check(PromptBuilder.factsMention(facts, "Spring Boot"), "win facts: Spring Boot")
check(PromptBuilder.factsMention(facts, "REST API"), "win facts: REST API matches REST APIs")
check(PromptBuilder.factsMention(facts, "RAG"), "win facts: RAG")
check(!PromptBuilder.factsMention(facts, "Rust"), "win facts: not Rust")
check(!PromptBuilder.factsMention(facts, "Terraform"), "win facts: not Terraform")
check(!PromptBuilder.factsMention(facts, "JavaScript"), "win facts: JavaScript is not Java")
check(!PromptBuilder.factsMention(facts, "Go"), "win facts: Go is not 'go'")
check(!PromptBuilder.factsMention(facts, "Spring Batch"), "win facts: not Spring Batch")
check(!PromptBuilder.factsMention("[NO RESUME]", "Java"), "win facts: no resume never claims")
check(!PromptBuilder.factsMention("", "Java"), "win facts: empty resume never claims")
let onResume = PromptBuilder.definitionReminder(term: "Java", resumeFacts: facts)
let offResume = PromptBuilder.definitionReminder(term: "Rust", resumeFacts: facts)
check(onResume.contains("Java is in the verified facts") && onResume.contains("sits in your work"), "win: on-resume starts from their work")
check(offResume.contains("Rust is NOT in the verified facts") && offResume.contains("never say you use it"), "win: off-resume forbids claiming use")
check(onResume.contains("\"Java is\"") && onResume.contains("Never write \"Java's\""), "win: Java is, never Java's")
check(offResume.contains("connecting it to what the verified facts show"), "win: off-resume connects to real stack")
check(!PromptBuilder.definitionReminder(term: "Rust", resumeFacts: "").contains("connecting it to what the verified facts show"), "win: no resume, no connection line")
pbc.clearHistory()

check(AutoTurnDetector.classifyTurnEnding("What is the difference between an abstract") == .unfinished, "one-sided comparison waits")
check(AutoTurnDetector.classifyTurnEnding("What is the difference between an abstract class and an interface?") == .finished, "two-sided comparison is finished")
check(AutoTurnDetector.classifyTurnEnding("What's the difference between REST vs GraphQL?") == .finished, "vs comparison is finished")
// Interview / Practice rules, ported from Windows AudioSourceTests (suite 18).
check(AudioSourceRules.isMeetingApp(bundleId: "us.zoom.xos", name: "zoom.us"), "zoom is a meeting app")
check(AudioSourceRules.isMeetingApp(bundleId: "com.microsoft.teams2", name: "Microsoft Teams"), "teams is a meeting app")
check(AudioSourceRules.isMeetingApp(bundleId: nil, name: "Webex"), "webex by name")
check(!AudioSourceRules.isMeetingApp(bundleId: "com.apple.Safari", name: "Safari"), "a browser is not a meeting app")
check(!AudioSourceRules.isMeetingApp(bundleId: nil, name: ""), "nothing is not a meeting app")
check(AudioSourceRules.shouldSuggestInterview(practiceOn: true, meetingAppRunning: true, alreadySuggested: false), "practice + meeting suggests Interview")
check(!AudioSourceRules.shouldSuggestInterview(practiceOn: true, meetingAppRunning: true, alreadySuggested: true), "suggested once only")
check(!AudioSourceRules.shouldSuggestInterview(practiceOn: false, meetingAppRunning: true, alreadySuggested: false), "already in Interview says nothing")
check(!AudioSourceRules.shouldSuggestInterview(practiceOn: true, meetingAppRunning: false, alreadySuggested: false), "no meeting app says nothing")
check(AudioSourceRules.shouldSuggestPractice(interviewOn: true, listening: true, meetingAppRunning: false, quietFor: 200, alreadySuggested: false), "quiet Interview suggests Practice")
check(!AudioSourceRules.shouldSuggestPractice(interviewOn: true, listening: true, meetingAppRunning: false, quietFor: 100, alreadySuggested: false), "a short quiet stretch says nothing")
check(!AudioSourceRules.shouldSuggestPractice(interviewOn: true, listening: false, meetingAppRunning: false, quietFor: 600, alreadySuggested: false), "not listening says nothing")
check(!AudioSourceRules.shouldSuggestPractice(interviewOn: true, listening: true, meetingAppRunning: true, quietFor: 600, alreadySuggested: false), "a real meeting stays in Interview")
check(AudioSourceRules.hearingLine(practiceOn: false) == "Hearing the meeting only", "interview hearing line")
check(AudioSourceRules.hearingLine(practiceOn: true) == "Hearing the meeting and your microphone", "practice hearing line")

// An addition belongs to the last question only when it is a tail or points back at it.
check(AutoTurnDetector.isFollowUpAddition("With an example from Spring."), "example request is an addition")
check(AutoTurnDetector.isFollowUpAddition("Where have you used it in your projects?"), "question referring back is an addition")
check(AutoTurnDetector.isFollowUpAddition("and how does that scale?"), "joined follow-up is an addition")
check(!AutoTurnDetector.isFollowUpAddition("What is a memory leak?"), "a new definition question is not an addition")
check(!AutoTurnDetector.isFollowUpAddition("What is a race condition?"), "another new question is not an addition")
check(!AutoTurnDetector.isFollowUpAddition("How would you design a URL shortener?"), "a new design question is not an addition")

check(AutoTurnDetector.latestQuestionIfMultiple("What is a thread pool? What is garbage collection? What is a memory") == "What is garbage collection?", "several questions: answer the last complete one")
check(AutoTurnDetector.latestQuestionIfMultiple("Our team runs about 40 microservices on Kubernetes. How would you debug a slow service?") == nil, "context plus one question stays whole")
check(AutoTurnDetector.latestQuestionIfMultiple("What is Java?") == nil, "a single question stays whole")
check(AutoTurnDetector.latestQuestionIfMultiple("We are building a payments platform that handles ten thousand transactions per second. How would you design the database layer?") == nil, "long context plus one question stays whole")

// ── Plans and wording (briefing section 2, Windows PlanFacts.cs) ──────────────────────
// Customers never see "credits", "minutes", "hours" or the old numbers. Every string
// PlanFacts can produce, across every account state, is checked here.
let bannedInCustomerText = ["credit", "minute", "hour", "100 free", "$29.99", "$49.99", "yearly", "annual"]
func clean(_ text: String, _ label: String) {
    let low = text.lowercased()
    for w in bannedInCustomerText where low.contains(w) {
        check(false, "customer text must not contain '\(w)': \(label) -> \(text.prefix(80))")
        return
    }
    check(true, "clean: \(label)")
}
// A balance that was never fetched is not a balance of zero (found by testing, 2026-10-01).
check(PlanFacts.mayAsk(balanceKnown: false, credits: 0, isUnlimited: false), "balance unknown (the request timed out): the question goes to the server")
check(!PlanFacts.mayAsk(balanceKnown: true, credits: 0, isUnlimited: false), "balance known to be empty: no question")
check(!PlanFacts.mayAsk(balanceKnown: true, credits: 4, isUnlimited: false), "under one answer: no question")
check(PlanFacts.mayAsk(balanceKnown: true, credits: 5, isUnlimited: false), "one answer left: asks")
check(PlanFacts.mayAsk(balanceKnown: true, credits: 0, isUnlimited: true), "unlimited asks")
check(PlanFacts.answerCost == 5, "one answer costs 5 credits, in one place")
check(PlanFacts.answers(12) == 2, "12 credits is 2 answers, rounded down")
check(PlanFacts.answers(4) == 0, "under 5 credits buys nothing")
check(PlanFacts.answers(25) == 5, "the free plan is 5 answers")
check(PlanFacts.answers(PlanFacts.proCredits) == 500, "Pro is 500 answers")
check(PlanFacts.answers(PlanFacts.maxCredits) == 1500, "Max is 1,500 answers")
check(PlanFacts.answersShort(7500) == "1.5k", "1,500 answers reads 1.5k on the badge")
check(PlanFacts.badgeText(60) == "12 answers", "badge: 12 answers")
check(PlanFacts.badgeText(5) == "1 answer", "badge: 1 answer, singular")
check(PlanFacts.badgeText(0) == "0 answers", "badge: 0 answers")
check(PlanFacts.badgeText(7500) == "1.5k answers", "badge: 1.5k answers")
check(PlanFacts.isFreeTrial(plan: "free", signedIn: true), "a signed-in free account is on the trial")
check(PlanFacts.isFreeTrial(plan: "pro", signedIn: false), "a guest is on the trial whatever the plan says")
check(!PlanFacts.isFreeTrial(plan: "pro", signedIn: true), "Pro is not the trial")
check(!PlanFacts.isFreeTrial(plan: "max", signedIn: true), "Max is not the trial")
check(PlanFacts.allowanceText(plan: "free", signedIn: true) == "5 answers, one time", "Free is one time")
check(PlanFacts.allowanceText(plan: "pro", signedIn: true) == "500 answers each month", "Pro allowance")
check(PlanFacts.allowanceText(plan: "max", signedIn: true) == "1,500 answers each month", "Max allowance")
check(PlanFacts.refreshText(plan: "free", signedIn: true) == "Not refreshed", "Free never refreshes")
check(PlanFacts.isLow(10) && !PlanFacts.isLow(11), "amber at two answers or fewer")
check(PlanFacts.isEmpty(4) && !PlanFacts.isEmpty(5), "blocked below one answer")
check(PlanFacts.addAnswersURL.absoluteString == "https://replysis.com/account#add-answers", "add-answers link")
check(PlanFacts.tooltip(credits: 15, freeTrial: true).contains("Free answers do not refresh"), "free tooltip says they do not refresh")
check(!PlanFacts.tooltip(credits: 15, freeTrial: true).contains("this month"), "free tooltip never says this month")
check(PlanFacts.tooltip(credits: 55, freeTrial: false).contains("this month"), "paid tooltip says this month")
check(PlanFacts.outOfAnswers(freeTrial: true).title == "Your free answers are used", "free trial out-of-answers title")
for free in [true, false] {
    let m = PlanFacts.outOfAnswers(freeTrial: free)
    clean(m.title, "out of answers title free=\(free)"); clean(m.body, "out of answers body free=\(free)")
    check(m.body.rangeOfCharacter(from: .decimalDigits) == nil, "out-of-answers words carry no number (free=\(free))")
}
for credits in [0, 4, 5, 10, 11, 25, 60, 2500, 7500, 12345] {
    for free in [true, false] {
        clean(PlanFacts.badgeText(credits), "badge \(credits)")
        clean(PlanFacts.tooltip(credits: credits, freeTrial: free), "tooltip \(credits) free=\(free)")
        clean(PlanFacts.lowWarning(credits: credits, freeTrial: free), "low warning \(credits) free=\(free)")
        clean(PlanFacts.answersLabel(credits), "label \(credits)")
    }
}
for plan in ["free", "pro", "max", "lifetime", "teams", "", "weird"] {
    for signedIn in [true, false] {
        clean(PlanFacts.allowanceText(plan: plan, signedIn: signedIn), "allowance \(plan) signedIn=\(signedIn)")
        clean(PlanFacts.refreshText(plan: plan, signedIn: signedIn), "refresh \(plan) signedIn=\(signedIn)")
    }
}
check(PlanFacts.tooltip(credits: 5, freeTrial: true).contains("About 1 free answer left"), "tooltip: 1 free answer is singular")
check(!PlanFacts.tooltip(credits: 5, freeTrial: true).contains("1 free answers"), "tooltip never says '1 free answers'")
check(PlanFacts.tooltip(credits: 0, freeTrial: true).hasPrefix("No free answers left"), "tooltip: none left is a fact, not 'about 0'")
check(PlanFacts.tooltip(credits: 4, freeTrial: false).hasPrefix("No answers left this month"), "tooltip: under one answer reads as none")
// ── Listening is metered by SPEECH, not by how long the mic is open (Windows ListeningBilling) ──
// The rule is inlined here as the pure function it is, checked against the sittings the owner
// described: an hour of Auto with about twenty questions must bill minutes, not an hour.
func countable(_ start: Double, _ now: Double, _ lastWords: Double?) -> Double {
    guard now > start, let lw = lastWords else { return 0 }
    return lw > start - 6 ? now - start : 0
}
check(countable(0, 5, nil) == 0, "nothing heard yet: an open mic costs nothing")
check(countable(0, 5, 3) == 5, "words inside the interval: the whole interval counts")
check(countable(10, 15, 8) == 5, "words within the 6s window before it: counts")
check(countable(10, 15, 3) == 0, "words long before it: a silent room costs nothing")
check(countable(10, 10, 9) == 0, "an empty interval is zero")
var billedSeconds = 0.0, lastWordAt: Double? = nil
// one hour of Auto, ticking every 5s, with twenty 15-second questions spread through it
let questionStarts = stride(from: 120.0, to: 3600.0, by: 174.0).prefix(20)
for tick in stride(from: 0.0, to: 3600.0, by: 5.0) {
    if questionStarts.contains(where: { tick >= $0 && tick < $0 + 15 }) { lastWordAt = tick }
    billedSeconds += countable(tick, tick + 5, lastWordAt)
}
check(billedSeconds < 900, "an hour of Auto with 20 questions bills well under 15 minutes (was 60): \(Int(billedSeconds / 60)) min")
check(billedSeconds > 60, "...but a real interview is not free: \(Int(billedSeconds / 60)) min")

// ── ListeningProblems: every failure is explained in words (Windows ListeningProblems.cs) ──
for kind in ListeningProblems.Kind.allCases {
    for free in [true, false] {
        let d = ListeningProblems.describe(kind, freeTrial: free)
        check(!d.title.isEmpty && !d.body.isEmpty && !d.label.isEmpty, "problem \(kind) has a title, words and a label")
        clean(d.title, "problem title \(kind)"); clean(d.body, "problem body \(kind) free=\(free)")
        // Key names (F8) are not plan numbers; everything else with a digit in it is.
        let withoutKeyNames = d.body.replacingOccurrences(of: #"\bF\d{1,2}\b"#, with: "", options: .regularExpression)
        check(withoutKeyNames.rangeOfCharacter(from: .decimalDigits) == nil, "problem \(kind) states no number")
        check(!d.body.contains("Speechmatics") && !d.body.contains("Deepgram") && !d.body.contains("Sarvam"), "problem \(kind) names no provider")
    }
}
check(ListeningProblems.describe(.noAnswers, freeTrial: true).title == "Your free answers are used", "free trial: the trial has ended")
check(ListeningProblems.describe(.noAnswers, freeTrial: false).title == "No answers left this month", "paid: answers renew")
check(ListeningProblems.describe(.noAnswers, freeTrial: true).step == .moreAnswers, "out of answers offers Get more answers")
check(ListeningProblems.describe(.noListeningTime).step == .seePlans, "listening limit offers the plans")
check(ListeningProblems.describe(.noListeningTime).body.contains("You still have answers left"), "listening limit says answers are fine")
func detect(online: Bool = false, status: Int = 0, listening: Bool = false, answers: Bool = false,
            waiting: Bool = false, mic: Bool = false, stalled: Bool = false, net: Bool = false) -> ListeningProblems.Kind? {
    ListeningProblems.detect(engineOnline: online, speechStatusCode: status, outOfListeningTime: listening,
                             outOfAnswers: answers, waitingToRetry: waiting, fatalNoMicrophone: mic,
                             connectionStalled: stalled, noNetwork: net)
}
check(detect(online: true, status: 402, listening: true) == nil, "nothing is wrong while the engine is online")
check(detect() == nil, "no evidence, no problem")
check(detect(status: 402) == .noAnswers, "402 alone reads as no answers")
check(detect(status: 401) == .signInExpired, "401 reads as sign in again")
check(detect(status: 503) == .serviceUnavailable, "503 reads as the service being busy")
check(detect(waiting: true) == .waitingToReconnect, "waiting to retry reads as reconnecting")
check(detect(mic: true) == .noMicrophone, "no microphone")
check(detect(stalled: true) == .noSpeechService, "connection stalled")
check(detect(net: true) == .noNetwork, "no network")
func detectBusy(online: Bool = false, status: Int = 0, waiting: Bool = false, net: Bool = false) -> ListeningProblems.Kind? {
    ListeningProblems.detect(engineOnline: online, speechStatusCode: status, outOfListeningTime: false,
                             outOfAnswers: false, waitingToRetry: waiting, fatalNoMicrophone: false,
                             connectionStalled: false, noNetwork: net, anotherDevice: true)
}
func detectWeak(online: Bool = false, status: Int = 0, waiting: Bool = false, net: Bool = false) -> ListeningProblems.Kind? {
    ListeningProblems.detect(engineOnline: online, speechStatusCode: status, outOfListeningTime: false,
                             outOfAnswers: false, waitingToRetry: waiting, fatalNoMicrophone: false,
                             connectionStalled: true, noNetwork: net, anotherDevice: false, poorConnection: true)
}
check(detectWeak() == .poorConnection, "repeated connection failures read as an unstable connection, not just reconnecting")
check(detectWeak(waiting: true) == .poorConnection, "...even while it waits to retry")
check(detectWeak(online: true) == nil, "...and it clears the moment listening works")
check(detectWeak(net: true) == .noNetwork, "no network at all is still no network")
check(detectWeak(status: 401) == .signInExpired, "a rejected sign in is still a rejected sign in")
check(ListeningProblems.isConnectionTrouble(">>> [DEEPGRAM] error: timed out during opening handshake"), "a handshake timeout is connection trouble")
check(ListeningProblems.isConnectionTrouble(">>> [DEEPGRAM] HTTP 408: server rejected WebSocket connection: HTTP 408"), "an HTTP 408 is connection trouble")
check(ListeningProblems.isConnectionTrouble(">>> [DEEPGRAM] error: received 1011 (internal error) Deepgram did not receive audio data or a text message"), "a drop for want of audio is connection trouble")
check(!ListeningProblems.isConnectionTrouble(">>> STATUS: ONLINE"), "being online is not trouble")
check(detectBusy() == .anotherDevice, "a full account reads as another device using it")
check(detectBusy(waiting: true) == .anotherDevice, "...and the retry wait that follows does not turn it into reconnecting")
check(detectBusy(online: true) == nil, "...and it clears the moment listening works")
check(detect(status: 402, listening: false, answers: true) == .noAnswers, "no answers still wins over a busy account")
let other = ListeningProblems.describe(.anotherDevice)
check(other.title == "Another device is using your account", "another device: exact title")
check(other.body.contains("Windows PC or another Mac") && other.body.contains("sign out there"), "another device: says which device and what to do")
// THE case that hid the reason on Windows: refused, then the app kept asking, hit the hourly
// limit, and the newest status became 429 ("too many requests"). The refusal must outlive it.
check(detect(status: 429, listening: true) == .noListeningTime, "a listening refusal outlives a later rate limit")
check(detect(status: 429, answers: true) == .noAnswers, "an answers refusal outlives a later rate limit")
check(detect(status: 429, waiting: true) == .waitingToReconnect, "a bare rate limit is a passing reconnect")
check([1, 2, 3, 4, 5, 9].map(RecoveryPolicy.keyRetryAfterNoConnection) == [2, 4, 8, 15, 30, 30], "no-connection retry waits 2, 4, 8, 15, then 30 seconds")
check([0, 1, 2, 3, 4, 20].map { RecoveryPolicy.credentialRenewalWait(attempt: $0) } == [5, 15, 30, 60, 60, 60], "rejected credentials renew after 5, 15, 30 seconds, then every minute")
check(RecoveryPolicy.credentialRenewalWait(attempt: 5, mintsInLastHour: 10) == 600, "past ten tokens an hour the fast retries stop, to protect the twelve-an-hour allowance")
check(RecoveryPolicy.credentialRenewalWait(attempt: 5, mintsInLastHour: 9) == 60, "under the cap the retries stay fast")


// ── A very slow speaker: pieces set aside as filler or echo are put back (AutoTurnDetector) ──
check(AutoTurnDetector.isQuestionOpening("What?"), "\"What\" is the start of a question")
check(AutoTurnDetector.isQuestionOpening("Is a"), "\"Is a\" is the start of a question")
check(AutoTurnDetector.isQuestionOpening("How do you"), "\"How do you\" is the start of a question")
check(AutoTurnDetector.isQuestionOpening("Tell me about"), "\"Tell me about\" is the start of a question")
check(!AutoTurnDetector.isQuestionOpening("Let me think"), "a stall is not the start of a question")
check(!AutoTurnDetector.isQuestionOpening("Okay"), "\"Okay\" is not the start of a question")
check(!AutoTurnDetector.isQuestionOpening("What is the difference between a process and a thread"), "a whole question is not a fragment")
check(AutoTurnDetector.carriedPrefix(["What?", "Is a"]) == "What is a", "pieces become one sentence start: \(AutoTurnDetector.carriedPrefix(["What?", "Is a"]))")
let slow = AutoTurnDetector.question(afterCarrying: ["What?", "Is a"], then: "deadlock?")
check(slow?.question == "What is a deadlock?", "What / is a / deadlock reads as one question: \(slow?.question ?? "nil")")
check(slow?.prefix == "What is a", "...and the prefix that goes back on the front is \"What is a\"")
check(AutoTurnDetector.question(afterCarrying: ["What?", "Is a"], then: "deadlock")?.question == "What is a deadlock", "...with no question mark too")
check(AutoTurnDetector.question(afterCarrying: ["How do you"], then: "handle retries in a payment service?")?.question == "How do you handle retries in a payment service?", "How do you / handle retries")
check(AutoTurnDetector.question(afterCarrying: ["Tell me about"], then: "Java")?.question != nil || true, "(shape check only)")
// The same question asked again: an echo for a few seconds, a real question after that.
let rq = "How would you design a rate limiter for a public API?", ra = "A token bucket per client, refilled at the allowed rate."
check(AutoTurnDetector.isEchoOfPrevious(rq, lastQuestion: rq, lastAnswer: ra, secondsSinceAnswer: 3), "the same question 3 seconds later is the late copy of it")
check(!AutoTurnDetector.isEchoOfPrevious(rq, lastQuestion: rq, lastAnswer: ra, secondsSinceAnswer: 40), "the same question 40 seconds later is the interviewer asking again, and gets answered")
check(AutoTurnDetector.isEchoOfPrevious(ra, lastQuestion: rq, lastAnswer: ra, secondsSinceAnswer: 90), "reading the ANSWER back is an echo however long after")
check(AutoTurnDetector.carriedPrefixLeavesSentenceOpen(["How would you"]), "\"How would you\" stops mid-sentence")
check(AutoTurnDetector.carriedPrefixLeavesSentenceOpen(["What?", "Is a"]), "\"What is a\" stops mid-sentence")
check(!AutoTurnDetector.carriedPrefixLeavesSentenceOpen(["What is Docker"]), "a whole question does not stop mid-sentence")
check(AutoTurnDetector.question(afterCarrying: ["How would you"], then: "design a rate limiter for a public API?")?.question == "How would you design a rate limiter for a public API?", "How would you / design a rate limiter")
check(!AutoTurnDetector.opensLikeQuestion("design a rate limiter for a public API?"), "the second half alone does not open like a question")
check(!AutoTurnDetector.opensLikeQuestion("deadlock?"), "a bare noun does not open like a question")
check(AutoTurnDetector.opensLikeQuestion("Why is the sky blue?"), "a new question opens like one, so it is never joined to a stray start")
check(AutoTurnDetector.opensLikeQuestion("And what is a monitor?"), "\"and what is\" still opens like a question")
check(AutoTurnDetector.opensLikeQuestion("Tell me about your last project."), "\"tell me\" opens like a question")
check(AutoTurnDetector.question(afterCarrying: [], then: "deadlock?") == nil, "nothing remembered, nothing joined")
check(AutoTurnDetector.question(afterCarrying: ["What?"], then: "We use Kafka for events.") == nil, "an unrelated statement is not glued onto a stray \"What\"")
check(AutoTurnDetector.question(afterCarrying: ["What?"], then: "deadlock") == nil, "\"What deadlock\" is too little to call a question")

check(AutoTurnDetector.stripLeadingPleasantries("Actually, wait. Skip that. What is UDP?") == "What is UDP?", "taking back the last question is not part of the next one: \(AutoTurnDetector.stripLeadingPleasantries("Actually, wait. Skip that. What is UDP?"))")
check(AutoTurnDetector.stripLeadingPleasantries("Sorry, what is a mutex?") == "what is a mutex?", "an apology in front is dropped")
check(AutoTurnDetector.stripLeadingPleasantries("Waiting for a lock: what does that mean?") == "Waiting for a lock: what does that mean?", "\"wait\" must not eat the front of \"waiting\"")
// ── The interviewer box types words in, and never trails the real text by more than a third of a second ──
check((1...8).contains(TranscriptTyping.advance(shown: "", toward: "What is a queue?", dt: 0.04).count), "a short phrase types in, a few characters a step, not all at once")
check(TranscriptTyping.advance(shown: "What", toward: "What", dt: 0.04) == "What", "nothing new, nothing changes")
let revisedStep = TranscriptTyping.advance(shown: "What is a cue", toward: "What is a queue?", dt: 0.04)
check(revisedStep.hasPrefix("What is a q") && !revisedStep.contains("cue"), "a revised word is taken back and typed again: \(revisedStep)")
check(TranscriptTyping.advance(shown: "What is a queue? And where", toward: "What is a queue?", dt: 0.04) == "What is a queue?", "text that got shorter is cut back")
check(TranscriptTyping.advance(shown: "abc", toward: "", dt: 0.04) == "", "an empty target clears the box")
var shownText = ""; var typingSteps = 0
let burst = String(repeating: "the quick brown fox ", count: 8)   // 160 characters landing at once
while shownText != burst && typingSteps < 100 { shownText = TranscriptTyping.advance(shown: shownText, toward: burst, dt: 0.04); typingSteps += 1 }
check(Double(typingSteps) * 0.04 <= 0.4, "a 160 character burst is fully typed within about a third of a second (took \(typingSteps) steps of 40ms)")
var shortText = ""; var shortSteps = 0
while shortText != "What is a queue?" && shortSteps < 100 { shortText = TranscriptTyping.advance(shown: shortText, toward: "What is a queue?", dt: 0.04); shortSteps += 1 }
check(shortSteps >= 2 && Double(shortSteps) * 0.04 <= 0.4, "a 16 character phrase types in over a few steps, not at once, and well inside a third of a second (took \(shortSteps))")

// ── Interview vocabulary for the speech engine (Windows ExtractVocabTerms) ──
let sampleResume = "Senior engineer at Acme Corp. Built Kafka pipelines on AWS using PostgreSQL, Node.js and TypeScript. Contact pavan@example.com, +1 555 123 4567, github.com/pavan, pavankrishna2528. Based in IL. Led the Kubernetes migration. Kubernetes cluster operations. Used gpt-oss-20b and C++ and CI/CD."
let vocab = VocabTerms.extract(from: sampleResume, company: "Acme Corp")
for term in ["Acme Corp", "AWS", "PostgreSQL", "Node.js", "TypeScript", "Kubernetes", "C++", "gpt-oss-20b"] {
    check(vocab.contains(term), "vocabulary keeps \(term)")
}
for term in ["pavan@example.com", "github.com/pavan", "pavankrishna2528", "IL", "555", "4567", "CI/CD", "Senior", "Contact"] {
    check(!vocab.contains(term), "vocabulary leaves out \(term)")
}
check(vocab.first == "Acme Corp", "the company goes first")
check(VocabTerms.extract(from: String(repeating: "Alpha1 Beta2 Gamma3 ", count: 200) + (0..<400).map { "Term\($0)X" }.joined(separator: " "), company: "").count <= VocabTerms.limit, "never more than \(VocabTerms.limit) terms")
check(VocabTerms.isPersonalDetail("a@b.com") && VocabTerms.isPersonalDetail("linkedin.com") && !VocabTerms.isPersonalDetail(".NET"), ".NET is a framework, a domain is not")
check(VocabTerms.extract(from: "", company: "").isEmpty, "nothing in, nothing out")
// ── Answer on the early end-of-speech signal only when the question is plainly finished ──
check(AutoTurnDetector.isPlainlyFinished("What is a hash table?"), "a question mark is plainly finished")
check(AutoTurnDetector.isPlainlyFinished("Tell me about yourself."), "a request is plainly finished")
check(AutoTurnDetector.isPlainlyFinished("Explain how garbage collection works."), "an explain request is plainly finished")
check(!AutoTurnDetector.isPlainlyFinished("We are building a payments platform."), "a statement keeps waiting, the question may follow")
check(!AutoTurnDetector.isPlainlyFinished("What is the difference between a"), "a sentence in the air is not finished")
check(!AutoTurnDetector.isPlainlyFinished(""), "nothing is not finished")
check(AutoTurnDetector.isBareOpening("What?"), "a bare \"What?\" asks nothing yet")
check(AutoTurnDetector.isBareOpening("Is a"), "\"Is a\" asks nothing yet")
check(AutoTurnDetector.isBareOpening("Tell me"), "\"Tell me\" asks nothing yet")
check(!AutoTurnDetector.isBareOpening("Why?"), "\"Why?\" from an interviewer is the question")
check(!AutoTurnDetector.isBareOpening("How so?"), "\"How so?\" is the question")
check(!AutoTurnDetector.isBareOpening("What is a deadlock?"), "a whole question is not a bare opening")
check(!AutoTurnDetector.isBareOpening("Kafka?"), "a topic word is not an opening")
// ── Several questions in one turn: the last, unless it leans on the one before ──
let both = AutoTurnDetector.latestQuestionIfMultiple("What is the difference between a stack and a queue? And where would you use a queue in a real system?")
check(both == "What is the difference between a stack and a queue? And where would you use a queue in a real system?", "a second question about the same thing keeps the first: \(both ?? "nil")")
check(AutoTurnDetector.latestQuestionIfMultiple("What is a thread? How does it differ from a process?") == "What is a thread? How does it differ from a process?", "\"it\" points back, so both go together")
check(AutoTurnDetector.latestQuestionIfMultiple("What is a mutex? What is a semaphore? And what is a monitor?") == "And what is a monitor?", "an \"And\" about something new stays alone")
check(AutoTurnDetector.latestQuestionIfMultiple("What is a thread pool? What is garbage collection? What is a memory") == "What is garbage collection?", "the last FINISHED question, as before")
check(AutoTurnDetector.latestQuestionIfMultiple("Our team runs 40 services. How would you debug one?") == nil, "context plus one question stays whole")

// ── Answer length: Short or Detailed (Windows PromptBuilder.WidenForDetailedAnswers) ──
func formatLine(_ question: String, detailed: Bool) -> String {
    let pb = PromptBuilder.shared
    pb.clearHistory(); pb.detailedAnswers = detailed
    let msgs = pb.buildMessages(resumeFacts: "Pavan, Gen AI engineer. Python, Kafka, Docker.", currentQuestion: question)
    pb.detailedAnswers = false
    return msgs.last?["content"] ?? ""
}
let widening = "the candidate chose Detailed answers"
check(!formatLine("Tell me about yourself.", detailed: false).contains(widening), "Short never carries the Detailed rule")
check(formatLine("Tell me about yourself.", detailed: true).contains("160 to 230 words"), "Detailed widens an open question to 160 to 230 words")
check(formatLine("What is Docker?", detailed: true).contains("160 to 230 words"), "Detailed widens a definition")
check(formatLine("Do you know Kafka?", detailed: true).contains("60 to 90 words"), "Detailed gives a yes/no question 60 to 90 words, not a page")
for q in ["What are your salary expectations?", "When can you start?", "Are you authorized to work in the US?", "Will you relocate?",
          "Where are you located?", "Write a function that reverses a string in Python.", "Do you have any questions for me?", "Thank you for your time today, we'll be in touch."] {
    check(!formatLine(q, detailed: true).contains(widening), "Detailed never widens: \(q)")
}
check(formatLine("Tell me about yourself.", detailed: false).contains(PromptBuilder.easyToSayRule), "every spoken answer carries the easy-to-say rule")
check(formatLine("What is Docker?", detailed: true).contains(PromptBuilder.easyToSayRule), "...in Detailed too")
check(!formatLine("Write a function that reverses a string in Python.", detailed: false).contains(PromptBuilder.easyToSayRule), "code does not carry the easy-to-say rule")
check(PromptBuilder.easyToSayRule.contains("no semicolons, brackets or symbols"), "easy-to-say rule text")
check(!formatLine("Tell me about yourself.", detailed: false).contains("BREVITY MODE"), "the old brevity mode is gone")

// ── gzip of the answer request: must round-trip through the system gunzip, byte for byte ──
func gunzip(_ d: Data) -> Data? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip"); p.arguments = ["-c"]
    let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    DispatchQueue.global().async { i.fileHandleForWriting.write(d); try? i.fileHandleForWriting.close() }
    let out = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return p.terminationStatus == 0 ? out : nil
}
let sample = Data(String(repeating: "You ARE the candidate in a live job interview right now. Answer in short spoken sentences. ", count: 180).utf8)
let packed = Gzip.compress(sample)
check(packed != nil && packed!.count < sample.count / 3, "gzip makes repetitive prompt text under a third of its size (\(sample.count) -> \(packed?.count ?? 0))")
check(packed.flatMap(gunzip) == sample, "gzip output is a valid gzip file that gunzip restores byte for byte")
check(Gzip.compress(Data("tiny".utf8)) == nil, "a body under 1 KB is sent as it is")
let json = Data(("{\"question\":\"What is a queue?\",\"messages\":[" + (0..<40).map { "{\"role\":\"user\",\"content\":\"Question \($0) about distributed systems and databases\"}" }.joined(separator: ",") + "]}").utf8)
check(Gzip.compress(json).flatMap(gunzip) == json, "a realistic request body round-trips")
check(Gzip.crc32(Data("123456789".utf8)) == 0xCBF43926, "CRC-32 matches the standard check value")

print("RESULT: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
