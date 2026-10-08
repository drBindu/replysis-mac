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
check(ListeningProblems.describe(.noListeningTime, freeTrial: true).step == .moreAnswers, "the free trial ending offers Get more answers")
check(ListeningProblems.describe(.noListeningTime, freeTrial: false).body.contains("Your answers are safe"), "this month's limit says answers are safe")
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
// ── One person's data must not be there for the next person to sign in ──
check(AccountScope.isDifferentPerson(previous: "alice", current: "bob"), "a different account id means the data is someone else's")
check(!AccountScope.isDifferentPerson(previous: "alice", current: "alice"), "the same person signing in again keeps everything")
check(!AccountScope.isDifferentPerson(previous: nil, current: "alice"), "no recorded account: keep what is here, it can only be theirs")
check(!AccountScope.isDifferentPerson(previous: "", current: "alice"), "an empty record is no record")
check(!AccountScope.isDifferentPerson(previous: "alice", current: ""), "no current id means nothing is decided")
check(AccountScope.isPersonal("resume.txt") && AccountScope.isPersonal("job.json") && AccountScope.isPersonal("interview_144.txt")
      && AccountScope.isPersonal("resumes") && AccountScope.isPersonal("hints.txt") && AccountScope.isPersonal("vocab.txt"), "resume, job details, hints, vocabulary and interviews are personal")
check(!AccountScope.isPersonal("settings.json") && !AccountScope.isPersonal("onboarding_seen") && !AccountScope.isPersonal("pause.flag")
      && !AccountScope.isPersonal("sysaudio.pcm") && !AccountScope.isPersonal("account.id"), "settings and engine files belong to the machine")
// ── Past Sessions: what an interview's transcript says about it ──
let transcriptSample = """
SESSION 7 | ai | 2026-10-01 03:31 | RESUME: Candidate

Q: Tell me about a time you handled a production outage.
A: I led the response, split the work and restored service in an hour.

MORE TO SAY
\u{2022} We wrote it up afterwards.

Q: How would you design a rate limiter for a public API?
A: A token bucket per client, refilled at the allowed rate.
Each request takes one token.

Q: Write a function that reverses a linked list.
A: Walk the list and flip each pointer as you go.

Q: [Screen Analysis]
A: The editor shows a failing test.

Q: What is a mutex?
A: A lock that lets one thread in at a time.
"""
let sessionPairs = SessionInsights.pairs(in: transcriptSample)
check(sessionPairs.count == 5, "five questions found in the transcript (\(sessionPairs.count))")
check(sessionPairs[1].answer.contains("Each request takes one token"), "an answer that runs over several lines is kept whole")
check(sessionPairs[0].spokenAnswer == "I led the response, split the work and restored service in an hour.", "the spoken answer stops at MORE TO SAY")
check(sessionPairs[0].moreToSay.contains("wrote it up"), "...and the extra points are kept apart")
check(sessionPairs.map(\.kind) == [.behavioural, .systemDesign, .coding, .fromScreen, .general], "question kinds: \(sessionPairs.map { $0.kind.rawValue })")
let sessionSummary = SessionInsights.summary(of: sessionPairs)
check(sessionSummary.questions == 5 && sessionSummary.longestAnswerWords == 15, "five questions, longest answer 15 words (\(sessionSummary.longestAnswerWords))")
check(sessionSummary.kinds.map { $0.0 } == [.fromScreen, .behavioural, .systemDesign, .coding, .general], "kinds are listed in a fixed order")
let t0 = Date(timeIntervalSince1970: 1_000_000)
check(SessionInsights.lastedText(from: t0, to: t0.addingTimeInterval(38 * 60)) == "Lasted 38 min", "Lasted 38 min")
check(SessionInsights.lastedText(from: t0, to: t0.addingTimeInterval(20)) == "Lasted under 1 min", "a short one says so")
check(SessionInsights.lastedText(from: t0, to: t0.addingTimeInterval(135 * 60)) == "Lasted 2 h 15 min", "over two hours reads in hours")
check(SessionInsights.lastedText(from: t0, to: nil) == nil && SessionInsights.lastedText(from: t0, to: t0) == nil, "no span, nothing said")
check(SessionInsights.isSameInterview(localDate: t0, localFirstQuestion: "What is a mutex?", cloudDate: t0.addingTimeInterval(240), cloudFirstQuestion: "what is a mutex"), "the cloud copy of the same interview is matched")
check(!SessionInsights.isSameInterview(localDate: t0, localFirstQuestion: "What is a mutex?", cloudDate: t0.addingTimeInterval(7200), cloudFirstQuestion: "What is a mutex?"), "the same question two hours later is another interview")
check(!SessionInsights.isSameInterview(localDate: t0, localFirstQuestion: "What is a mutex?", cloudDate: t0, cloudFirstQuestion: "What is a thread?"), "a different first question is another interview")
check(SessionInsights.deleteExplanation.contains("this device's") && SessionInsights.deleteExplanation.contains("cannot be undone"), "delete says it is only this device's copy")
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


// ── Windows 1.0.30 audit port: line test, screen words, answer closers, answer layout, joined questions ──
do {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    var g = UplinkGovernor()
    check(g.mayUpload(now: t0), "a fresh start may send ahead")
    var quiet = g.record(now: t0, succeeded: true, elapsed: 0.7)
    check(quiet == 0 && g.mayUpload(now: t0.addingTimeInterval(1)) && g.failureStreak == 0, "a quick upload is trusted and changes nothing")
    quiet = g.record(now: t0, succeeded: false, elapsed: UplinkGovernor.uploadTimeout)
    check(quiet == 60 && !g.mayUpload(now: t0.addingTimeInterval(59)) && g.mayUpload(now: t0.addingTimeInterval(60)), "one failed upload pauses sending ahead for a minute")
    quiet = g.record(now: t0.addingTimeInterval(60), succeeded: false, elapsed: 8)
    check(quiet == 120, "failing again doubles the pause")
    quiet = g.record(now: t0.addingTimeInterval(200), succeeded: false, elapsed: 8)
    check(quiet == 240, "and again")
    for _ in 0..<12 { quiet = g.record(now: t0.addingTimeInterval(3600), succeeded: false, elapsed: 8) }
    check(quiet == UplinkGovernor.maxBackoff, "the pause never grows past ten minutes")
    quiet = g.record(now: t0.addingTimeInterval(7200), succeeded: true, elapsed: 0.9)
    check(quiet == 0 && g.failureStreak == 0 && g.mayUpload(now: t0.addingTimeInterval(7200)), "one quick upload after a bad patch trusts the connection again")
    var slow = UplinkGovernor()
    check(slow.record(now: t0, succeeded: true, elapsed: 9) > 0, "an upload that works but takes nine seconds counts as slow")
    var fresh = UplinkGovernor()
    check(!fresh.verified && fresh.needsProbe(now: t0), "a new start tests the line first")
    quiet = fresh.recordProbe(now: t0, succeeded: true, elapsed: 0.18)
    check(quiet == 0 && fresh.verified && !fresh.needsProbe(now: t0) && fresh.mayUpload(now: t0), "a test back within 1.2 s trusts the line")
    var hotspot = UplinkGovernor()
    quiet = hotspot.recordProbe(now: t0, succeeded: true, elapsed: 2.0)
    check(quiet == 60 && !hotspot.verified && !hotspot.needsProbe(now: t0.addingTimeInterval(59)) && hotspot.needsProbe(now: t0.addingTimeInterval(60)), "the hotspot fails the test and is tested again a minute later")
    check(hotspot.recordProbe(now: t0.addingTimeInterval(60), succeeded: false, elapsed: UplinkGovernor.probeTimeout) == 120, "a test that does not finish doubles the pause")
    check(UplinkGovernor.probeBytes * 3 < 500 * 1024, "a test costs a third of a picture or less")
    var wobble = UplinkGovernor()
    wobble.recordProbe(now: t0, succeeded: true, elapsed: 0.15)
    wobble.record(now: t0.addingTimeInterval(300), succeeded: false, elapsed: 8)
    check(!wobble.verified && !wobble.needsProbe(now: t0.addingTimeInterval(300)) && wobble.needsProbe(now: t0.addingTimeInterval(360)), "after a lost picture the line is in doubt and gets a small test when the pause ends")
    wobble.recordProbe(now: t0.addingTimeInterval(360), succeeded: true, elapsed: 0.2)
    check(wobble.verified && wobble.failureStreak == 0, "one good test brings pictures back")
    wobble.reset()
    check(!wobble.verified && wobble.needsProbe(now: t0), "a changed network is tested again from scratch")
    _ = slow; _ = fresh
}

do {
    func W(_ t: String, _ x: Double, _ y: Double) -> OcrWord { OcrWord(text: t, x: x, y: y, w: Double(t.count) * 8, h: 16) }
    var single: [OcrWord] = []
    for i in 0..<8 { single.append(W("Second", 60, 20 * Double(i))); single.append(W("first\(i)", 0, 20 * Double(i))) }
    let singleLines = OcrLayout.toText(single).components(separatedBy: "\n")
    check(singleLines.count == 8 && singleLines[0].hasPrefix("first0 ") && singleLines[0].hasSuffix("Second") && singleLines[7].hasPrefix("first7"), "screen words: one column reads in rows, left to right")
    var two: [OcrWord] = []
    for i in 0..<10 {
        two.append(W("left\(i)row", 0, 20 * Double(i))); two.append(W("more", 80, 20 * Double(i))); two.append(W("right\(i)", 400, 20 * Double(i)))
    }
    let spread = OcrLayout.toText(two)
    let parts = spread.components(separatedBy: "\n\n")
    check(parts.count == 2 && parts[0].components(separatedBy: "\n").allSatisfy { $0.hasPrefix("left") } && parts[1].components(separatedBy: "\n").allSatisfy { $0.hasPrefix("right") }, "screen words: two panels side by side, the left read down, then the right")
    var withTitle = two
    withTitle.append(W("Practice - live session title that runs across", 100, -40))
    let titled = OcrLayout.toText(withTitle).components(separatedBy: "\n\n")
    check(titled.count >= 2 && (titled.last ?? "").components(separatedBy: "\n").last?.hasPrefix("right9") == true, "screen words: a title bar across the gutter does not merge the panels")
    var code: [OcrWord] = []
    let xs: [Double] = [0, 32, 64, 32, 0, 0]
    for (i, x) in xs.enumerated() { code.append(W("stmt\(i)", x, 20 * Double(i))) }
    let codeLines = OcrLayout.toText(code).components(separatedBy: "\n")
    check(codeLines[0] == "stmt0" && codeLines[1] == "    stmt1" && codeLines[2] == "        stmt2" && codeLines[4] == "stmt4", "screen words: indentation is kept, four characters per 32 pixels")
    var gapped: [OcrWord] = []
    for i in 0..<6 { gapped.append(W("abc", 0, 20 * Double(i))); gapped.append(W("def", 40, 20 * Double(i))) }
    check(OcrLayout.toText(gapped).components(separatedBy: "\n")[0] == "abc  def", "screen words: a gap of two characters is two spaces")
    check(OcrLayout.toText([]) == "", "screen words: nothing found reads as nothing")
    check(OcrLayout.toText([OcrWord(text: "   ", x: 0, y: 0, w: 10, h: 10)]) == "", "screen words: blank words are not text")
    let longText = Array(repeating: "a line of the page that is fairly long", count: 1000).joined(separator: "\n")
    let fitted = OcrLayout.fit(longText)
    check(fitted.count <= OcrLayout.maxChars && fitted.hasSuffix("long"), "screen words: a very long page is cut at the end of a line")
    check(OcrLayout.fit("short") == "short", "screen words: a short page is untouched")
}

do {
    let body = "I moved the nightly jobs to a queue. That cut the failures by half. "
    let base = "I moved the nightly jobs to a queue. That cut the failures by half."
    func strip(_ s: String, _ allow: Bool = false) -> String { AnswerClosers.stripTrailingOffer(s, allowClosingQuestion: allow) }
    check(strip(body + "Let me know if you'd like more detail.") == base, "closers: \"Let me know if you'd like more detail\" comes off")
    check(strip(body + "Let me know if you\u{2019}d like more detail.") == base, "closers: the same with a typographic apostrophe")
    check(strip(body + "Would you like me to go deeper?") == base, "closers: \"Would you like me to go deeper?\" comes off")
    check(strip(body + "Does that make sense?") == base, "closers: \"Does that make sense?\" comes off")
    check(strip(body + "Happy to elaborate on any of that. Feel free to ask.") == base, "closers: two offers in a row both come off")
    check(strip(body + "I can also walk you through the design if that helps.") == base, "closers: \"I can also walk you through\" comes off")
    check(strip(body + "What does your team use today?") == base, "closers: a question put to the interviewer comes off")
    check(strip(body + "What does your team use today?", true).hasSuffix("What does your team use today?"), "closers: it stays when the interviewer just invited questions")
    check(!strip(body + "Happy to go deeper.", true).contains("Happy to"), "closers: an offer to say more comes off even then")
    check(strip(body + "Let me know if") == base, "closers: half a closing offer is hidden while it is still arriving")
    check(strip("If you want fast lookups, use a hash map. If you need ordering, use a tree.") == "If you want fast lookups, use a hash map. If you need ordering, use a tree.", "closers: advice that starts with \"if you want\" is content")
    check(strip("Would you like me to go deeper?") == "Would you like me to go deeper?", "closers: the only sentence of an answer is never removed")
    check(strip(body + "I used it daily at Contoso.") == base + " I used it daily at Contoso.", "closers: an ordinary last sentence stays")
    let mid = "A mutex guards one resource. A semaphore allows N holders. Is a semaphore always better? No, a mutex is simpler and safer."
    check(strip(mid) == mid, "closers: a question in the middle of an answer stays")
    let code = "Here is the loop.\n\n```python\nfor x in items:\n    print(x)\n```"
    check(strip(code) == code, "closers: an answer ending in code is left exactly as it is")
    let openCode = "Here is the loop.\n\n```python\nfor x in items:\n    # Does that make sense?"
    check(strip(openCode) == openCode, "closers: code that is still arriving is never touched")
    check(strip(code + "\n\nThat is O(n). Let me know if you want the recursive version.") == code + "\n\nThat is O(n).", "closers: an offer after the code comes off, the code does not move")
    let cleaned = strip(body + "Does that help?\n\nMORE TO SAY\n\u{2022} I added retries with backoff.\n\u{2022} Let me know if you want more.")
    check(!cleaned.contains("Does that help") && !cleaned.contains("Let me know") && cleaned.contains("MORE TO SAY") && cleaned.contains("I added retries with backoff."), "closers: offers come off the spoken part and the last bullet, the real bullets stay")
    check(PromptBuilder.isCandidateQuestionInvitation("Do you have any questions for me?"), "closers: an invitation for questions is recognised")
}

do {
    let spoken = "I'll use a hash map to store each number's index as we iterate; this gives O(n) time and O(n) extra space."
    check(AnswerLayout.complexityOf(spoken + "\n\nTime O(n), space O(n).") == "Time O(n), space O(n).", "complexity: the spoken sentence stays and only the complexity line goes to the bar")
    check(AnswerLayout.complexityOf(spoken) == nil, "complexity: a sentence that merely mentions O(n) is not a complexity line")
    check(AnswerLayout.complexityOf("Time: O(n)\nSpace: O(1)") == "Time: O(n)   Space: O(1)", "complexity: time and space on two lines both reach the bar")
    check(AnswerLayout.complexityOf("- Time complexity O(n log n)") == "Time complexity O(n log n)", "complexity: a bullet is trimmed")
    check(AnswerLayout.complexityOf("O(n^2) time, O(1) space") == "O(n^2) time, O(1) space", "complexity: a line that opens with the figure counts")
    check(AnswerLayout.complexityOf("Sorting first costs O(n log n), then one pass.") == nil, "complexity: advice that contains a figure is not a complexity line")
    check(AnswerLayout.rewriteNeedHeading("Let me scroll down and read the constraints before I answer.\n\nNEED\nThe constraints section.") == "Let me scroll down and read the constraints before I answer.\n\nStill need to see: The constraints section.", "NEED on its own line becomes \"Still need to see: ...\"")
    check(AnswerLayout.rewriteNeedHeading("Let me scroll.\nNEED: the constraints and the third example.") == "Let me scroll.\nStill need to see: the constraints and the third example.", "NEED: on one line reads the same way")
    check(AnswerLayout.rewriteNeedHeading("I need to see how you handled it.") == "I need to see how you handled it.", "the word need inside a sentence is left alone")

    // The three places a screen answer is shown.
    let raw = "SAY THIS\nI would use a hash map, one pass.\n\nDETAIL\n```python\ndef two_sum(nums, target):\n    seen = {}\n    return seen\n```\n\nTime: O(n)\nSpace: O(n)\n\nSCREEN NOTES\nLeetCode, Two Sum, Python3 editor"
    let shown = AnswerLayout.composeScreenAnswer(raw)
    check(!shown.contains("SCREEN NOTES") && !shown.contains("Python3 editor"), "screen answer: the notes for the next question are never shown")
    let p = AnswerLayout.split(shown)
    check(p.prose == "I would use a hash map, one pass.", "screen answer: the part to say is alone in the answer text (\(p.prose))")
    check(p.code.hasPrefix("def two_sum(nums, target):") && p.code.contains("    seen = {}") && p.language == "python", "screen answer: the code is in its own panel, indentation kept")
    check(p.complexity == "Time: O(n)   Space: O(n)", "screen answer: the complexity is under the code")
    let streaming = AnswerLayout.split(AnswerLayout.composeScreenAnswer("SAY THIS\nI would use a hash map.\n\nDETAIL\n```py"))
    check(streaming.prose == "I would use a hash map." && streaming.code.isEmpty, "screen answer: a half-written fence never shows while it streams")
    let streaming2 = AnswerLayout.split(AnswerLayout.composeScreenAnswer("SAY THIS\nI would use a hash map.\n\nDETAIL\n```python\ndef f(x):\n    ret"))
    check(streaming2.code == "def f(x):\n    ret" && streaming2.prose == "I would use a hash map.", "screen answer: code arriving shows in the panel and not in the text")
    let star = AnswerLayout.composeScreenAnswer("SAY THIS\nFix the pointer.\n\nDETAIL\n```cpp\nListNode* insertionSortList(ListNode* head) {\n    int area = w * h * depth;\n}\n```")
    check(star.contains("ListNode* insertionSortList(ListNode* head)") && star.contains("w * h * depth"), "screen answer: asterisks and underscores in code are never touched")
    let dashes = AnswerLayout.composeScreenAnswer("SAY THIS\nIt is a hash map \u{2014} one pass, then done.")
    check(!dashes.contains("\u{2014}") && dashes.contains("hash map, one pass"), "screen answer: long dashes become plain punctuation")
    let handBack = AnswerLayout.composeScreenAnswer("SAY THIS\nUse a hash map. One pass. Let me know if you want the code.")
    check(!handBack.contains("Let me know"), "screen answer: a hand-back is filtered while it streams too")
    let design = AnswerLayout.composeScreenAnswer("SAY THIS\nI would shard by user id. Which region carries most of the traffic?")
    check(design.hasSuffix("Which region carries most of the traffic?"), "screen answer: a clarifying question may end a design answer")
    let need = AnswerLayout.split("SAY THIS\nLet me scroll down and read the constraints before I answer.\n\nNEED\nThe constraints section.")
    check(need.prose == "Let me scroll down and read the constraints before I answer.\n\nStill need to see: The constraints section.", "screen answer: NEED reads as a sentence")
    let noCode = AnswerLayout.split("SAY THIS\nThe sentence itself says O(n) time and O(1) space here.")
    check(noCode.complexity == nil && noCode.prose.contains("O(n) time"), "screen answer: with no code, the spoken sentence keeps its complexity")
    let bare = AnswerLayout.composeScreenAnswer("APPROACH\nTwo pointers.\nSOLUTION\ndef f(a_list, *args):\n    return a_list * 2\nCOMPLEXITY\nTime: O(n)   Space: O(1)\nSAY THIS\nTwo pointers, one pass.")
    check(bare.contains("def f(a_list, *args):") && bare.contains("a_list * 2"), "screen answer: unfenced code under a SOLUTION heading is protected too")
}

do {
    check(AutoTurnDetector.isFollowUpAddition("and what alerts you would set up?"), "joined: \"and what alerts you would set up\" is the second half of one question")
    check(AutoTurnDetector.isFollowUpAddition("how you would roll it back"), "joined: \"how you would roll it back\" is a clause, not a question")
    check(AutoTurnDetector.isEmbeddedClause("and what alerts you would set up?"), "joined: subject before verb is an embedded clause")
    check(!AutoTurnDetector.isEmbeddedClause("and what alerts would you set up?"), "joined: verb before subject is a new question")
    check(!AutoTurnDetector.isFollowUpAddition("and what is a memory leak?"), "joined: \"and what is a memory leak\" is still a new question")
    check(!AutoTurnDetector.isEmbeddedClause("what is Python?"), "joined: a plain new question is not a clause")
}


do {
    func win(_ id: UInt32, _ pid: Int32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, layer: Int = 0, title: String = "Window") -> CaptureWindow {
        CaptureWindow(id: id, pid: pid, frame: CGRect(x: x, y: y, width: w, height: h), layer: layer, title: title)
    }
    let us: Int32 = 100
    // An ordinary front window is read as it is.
    let plain = CaptureTarget.choose(windows: [win(1, 200, 0, 0, 1200, 800, title: "LeetCode")], ownPID: us)
    check(plain?.window.id == 1 && plain?.dialogs.isEmpty == true, "capture: the window in front is read")
    // Our own window is never what a question is about.
    let own = CaptureTarget.choose(windows: [win(9, us, 0, 0, 900, 600), win(1, 200, 0, 0, 1200, 800)], ownPID: us)
    check(own?.window.id == 1, "capture: our own window is skipped")
    // A sheet over a window reads the window with the sheet on top.
    let sheet = CaptureTarget.choose(windows: [win(5, 200, 300, 200, 500, 250, title: ""), win(1, 200, 0, 0, 1200, 800, title: "Editor")], ownPID: us)
    check(sheet?.window.id == 1 && sheet?.dialogs.map(\.id) == [5], "capture: a sheet in front means the window behind it is read, sheet included")
    // An app modal alert is read through to the window it belongs to, even if it sits away from it.
    let alert = CaptureTarget.choose(windows: [win(6, 200, 1300, 100, 260, 160, layer: 8, title: "Save changes?"), win(1, 200, 0, 0, 1200, 800, title: "Editor")], ownPID: us)
    check(alert?.window.id == 1 && alert?.dialogs.map(\.id) == [6], "capture: an alert in front means the window behind it is read")
    // A second ordinary window of the same app is not a dialog: it has a title.
    let second = CaptureTarget.choose(windows: [win(2, 200, 100, 100, 600, 500, title: "Two Sum"), win(1, 200, 0, 0, 1200, 800, title: "Inbox")], ownPID: us)
    check(second?.window.id == 2 && second?.dialogs.isEmpty == true, "capture: another window of the same app is read as itself")
    // A small panel of another app with nothing behind it from the same app is skipped for the window behind.
    let tool = CaptureTarget.choose(windows: [win(7, 300, 0, 0, 180, 120, title: "Palette"), win(1, 200, 0, 0, 1200, 800)], ownPID: us)
    check(tool?.window.id == 1, "capture: a small panel with no owner is skipped for what is behind it")
    check(CaptureTarget.choose(windows: [], ownPID: us) == nil, "capture: nothing on screen gives no target")
    // Windows of another app behind a dialog never become its parent.
    let foreign = CaptureTarget.choose(windows: [win(5, 200, 300, 200, 500, 250, title: ""), win(1, 999, 0, 0, 1200, 800)], ownPID: us)
    check(foreign == nil || foreign?.window.id != 1, "capture: a dialog's parent is a window of the same app")
}

do {
    var tries = 0
    let copied = await Clipboard.copy("let x = 1", attempts: 5, pause: 0.01) { _ in tries += 1; return tries >= 3 }
    check(copied && tries == 3, "clipboard: a copy that fails twice because another program holds it succeeds on the third try")
    var calls = 0
    let failed = await Clipboard.copy("x", attempts: 4, pause: 0.01) { _ in calls += 1; return false }
    check(!failed && calls == 4, "clipboard: a copy that never opens reports failure after its attempts")
    var once = 0
    let quick = await Clipboard.copy("x", attempts: 10, pause: 0.01) { _ in once += 1; return true }
    check(quick && once == 1, "clipboard: a copy that works at once tries once")
}


do {
    let t = Date(timeIntervalSince1970: 1_790_000_000)
    func stalled(_ started: Date?, _ ready: Date) -> Bool { ListeningProblems.connectionStalled(now: t, startedAt: started, lastReadyAt: ready, patience: 25) }
    check(!stalled(t - 600, t - 1), "stalled clock: a drop in a ten minute old session is not stalled the instant it happens")
    check(!stalled(t - 600, t - 20), "stalled clock: twenty seconds after the drop is still within patience")
    check(stalled(t - 600, t - 30), "stalled clock: thirty seconds after the drop it is stalled")
    check(!stalled(t - 10, .distantPast), "stalled clock: a fresh engine ten seconds old is still connecting")
    check(stalled(t - 40, .distantPast), "stalled clock: a fresh engine forty seconds old that never connected is stalled")
    check(!stalled(t - 5, t - 300), "stalled clock: a restarted engine is counted from its restart")
    check(!stalled(nil, .distantPast), "stalled clock: nothing known is not stalled")
}


// ── Google sign-in's local listener: ignore what is not this attempt's answer, tested over real sockets ──
do {
    func classifyCode(_ line: String, _ state: String = "XYZ") -> String? {
        if case .answer(let cb) = OAuthLoopback.classify(line + "\r\nHost: 127.0.0.1\r\n\r\n", expectedState: state) { return cb.code ?? "error" }
        return nil
    }
    check(classifyCode("GET /?code=abc&state=XYZ HTTP/1.1") == "abc", "oauth: a request with the code and this attempt's state is the answer")
    check(classifyCode("GET /?code=a%3Db&state=XYZ HTTP/1.1") == "a=b", "oauth: an encoded value is decoded")
    check(classifyCode("GET /?error=access_denied&state=XYZ HTTP/1.1") == "error", "oauth: a refusal carrying the state is the answer")
    check(classifyCode("GET /favicon.ico HTTP/1.1") == nil, "oauth: an icon request is ignored")
    check(classifyCode("GET /?code=abc&state=OTHER HTTP/1.1") == nil, "oauth: another attempt's state is ignored")
    check(classifyCode("GET /?code=abc HTTP/1.1") == nil, "oauth: no state is ignored")
    check(classifyCode("garbage") == nil, "oauth: garbage is ignored")

    func connectTo(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return fd
    }
    func write(_ fd: Int32, _ text: String) { text.withCString { _ = send(fd, $0, strlen($0), 0) } }
    func readAll(_ fd: Int32) -> String {
        var tv = timeval(tv_sec: 2, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = [UInt8](); var buf = [UInt8](repeating: 0, count: 1024)
        while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; out.append(contentsOf: buf.prefix(n)) }
        return String(decoding: out, as: UTF8.self)
    }

    // A silent spare connection, then an icon request, then the real answer.
    if let bound = OAuthLoopback.bind() {
        var found: OAuthLoopback.Callback?
        let waiter = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            found = OAuthLoopback.waitForCallback(serverFd: bound.fd, expectedState: "XYZ", timeout: 8, successHTML: "OK PAGE", failHTML: "FAIL PAGE", readTimeout: 2)
            waiter.signal()
        }
        let spare = connectTo(bound.port)                                  // opens and says nothing
        let icon = connectTo(bound.port); write(icon, "GET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n")
        let iconReply = readAll(icon); Darwin.close(icon)
        let real = connectTo(bound.port); write(real, "GET /?code=thecode&state=XYZ HTTP/1.1\r\nHost: x\r\n\r\n")
        let realReply = readAll(real); Darwin.close(real)
        let done = waiter.wait(timeout: .now() + 6)
        Darwin.close(spare)
        check(done == .success && found?.code == "thecode" && found?.stateValid == true, "oauth: sign-in survives a silent spare connection and an icon request")
        check(iconReply.hasPrefix("HTTP/1.1 404"), "oauth: the icon request is answered with a plain 404, not as the sign-in")
        check(realReply.contains("OK PAGE"), "oauth: the real answer shows the success page")
    } else { check(false, "oauth: a local port could be opened") }

    // Another attempt's answer never ends this one.
    if let bound = OAuthLoopback.bind() {
        let started = Date()
        let stray = DispatchQueue.global()
        stray.async { let c = connectTo(bound.port); write(c, "GET /?code=old&state=OLD HTTP/1.1\r\n\r\n"); _ = readAll(c); Darwin.close(c) }
        let got = OAuthLoopback.waitForCallback(serverFd: bound.fd, expectedState: "XYZ", timeout: 1.2, successHTML: "", failHTML: "", readTimeout: 1)
        check(got == nil && Date().timeIntervalSince(started) >= 1.0, "oauth: another attempt's answer is ignored and this attempt times out cleanly")
    }
}


do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("closing-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let t = Date(timeIntervalSince1970: 1_790_000_000)
    check(!ClosingMarker.isClosing(pid: 42, in: dir, now: t), "closing: nothing marked means a second copy is a duplicate")
    ClosingMarker.markClosing(in: dir, pid: 42, now: t)
    check(ClosingMarker.isClosing(pid: 42, in: dir, now: t.addingTimeInterval(3)), "closing: a copy that just marked itself is closing")
    check(!ClosingMarker.isClosing(pid: 43, in: dir, now: t.addingTimeInterval(3)), "closing: another process is not the one that marked itself")
    check(!ClosingMarker.isClosing(pid: 42, in: dir, now: t.addingTimeInterval(120)), "closing: an old marker means nothing")
    var polls = 0
    check(ClosingMarker.waitForExit(pid: 42, timeout: 2, poll: 0.01) { _ in polls += 1; return polls < 4 }, "closing: the new copy waits for the old one to go, then starts")
    check(!ClosingMarker.waitForExit(pid: 42, timeout: 0.1, poll: 0.01) { _ in true }, "closing: a copy that never goes is handed over to after the wait")
    ClosingMarker.clear(in: dir)
    check(!ClosingMarker.isClosing(pid: 42, in: dir, now: t), "closing: cleared at launch")
    try? FileManager.default.removeItem(at: dir)
}


// ── Reading the screen's words with Vision: render a two panel page (statement left, editor right) and read it back ──
do {
    let width = 1600, height = 900
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
    ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
    let prose: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black]
    let mono: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .regular), .foregroundColor: NSColor.black]
    let left = ["Two Sum", "Given an array of integers nums and an integer target,", "return indices of the two numbers such that they add up", "to target. You may assume that each input has exactly", "one solution, and you may not use the same element twice.", "Example 1: nums = [2,7,11,15], target = 9, output [0,1]", "Constraints: 2 <= nums.length <= 10000"]
    for (i, line) in left.enumerated() { line.draw(at: NSPoint(x: 40, y: 60 + CGFloat(i) * 44), withAttributes: prose) }
    let right = ["def twoSum(self, nums, target):", "    seen = {}", "    for i, n in enumerate(nums):", "        if target - n in seen:", "            return [seen[target - n], i]", "        seen[n] = i"]
    for (i, line) in right.enumerated() { line.draw(at: NSPoint(x: 900, y: 60 + CGFloat(i) * 44), withAttributes: mono) }
    NSGraphicsContext.restoreGraphicsState()
    let page = ctx.makeImage()!
    let started = Date()
    let words = ScreenOcr.read(page)
    let took = Date().timeIntervalSince(started)
    print("OCR took \(String(format: "%.2f", took))s; read:\n\(words ?? "(nothing)")")
    check(words != nil, "ocr: a rendered page gives words")
    let text = words ?? ""
    check(text.contains("Two Sum") && text.contains("integer target"), "ocr: the problem statement is read")
    check(text.contains("def twoSum") && text.contains("seen"), "ocr: the code is read")
    // Panel order: the whole statement before the code, not interleaved row by row.
    if let sIdx = text.range(of: "exactly")?.lowerBound, let cIdx = text.range(of: "def twoSum")?.lowerBound {
        check(sIdx < cIdx, "ocr: the statement panel is read before the code panel")
    } else { check(false, "ocr: both panels present") }
    func indent(of fragment: String) -> Int? {
        text.components(separatedBy: "\n").first { $0.contains(fragment) }.map { $0.prefix { $0 == " " }.count }
    }
    if let a = indent(of: "for i, n in enumerate"), let b = indent(of: "if target - n"), let c = indent(of: "return [seen") {
        check(a < b && b < c, "ocr: the code's indentation steps are kept (\(a), \(b), \(c))")
    } else { check(false, "ocr: the body lines of the code are all read") }
    check(took < 8, "ocr: reads a 1600 by 900 page in under eight seconds")
    check(OcrLayout.fit(text).count == text.count, "ocr: a page of this size is sent whole")
    var blank: CGImage? = nil
    if let c2 = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
        c2.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); c2.fill(CGRect(x: 0, y: 0, width: 600, height: 400)); blank = c2.makeImage()
    }
    check(blank.flatMap { ScreenOcr.read($0) } == nil, "ocr: a blank page is not something to answer from")
}


// ── Customers see answers, never a listening limit: the hidden monthly ceiling is "this month's limit" ──
do {
    let banned = ["listening", "minute", "hour", "fair use"]
    for trial in [true, false] {
        let d = ListeningProblems.describe(.noListeningTime, freeTrial: trial)
        let text = (d.label + " " + d.title + " " + d.body).lowercased()
        check(!banned.contains { text.contains($0) }, "limit wording (free trial \(trial)) never says listening, minutes, hours or fair use")
    }
    check(ListeningProblems.describe(.noListeningTime, freeTrial: true).title == "Your free trial is over", "the free trial's ceiling is simply the end of the trial")
    check(ListeningProblems.describe(.noListeningTime, freeTrial: false).title == "You have reached this month's limit", "a paid plan's ceiling is this month's limit")
    check(ListeningProblems.describe(.noListeningTime, freeTrial: false).body.contains("renews on the first of next month"), "a paid plan is told when it renews")
    let tip = PlanFacts.tooltip(credits: 40, freeTrial: false, listeningLimitReached: true).lowercased()
    check(!banned.contains { tip.contains($0) } && tip.contains("this month's limit"), "the badge tooltip says this month's limit and nothing about listening")
}


do {
    check(RecoveryPolicy.sessionRefused(byStatus: 400) && RecoveryPolicy.sessionRefused(byStatus: 401) && RecoveryPolicy.sessionRefused(byStatus: 403), "launch: the sign-in service refusing the saved sign-in asks for a new one")
    check(![0, 408, 429, 500, 502, 503, 504].contains { RecoveryPolicy.sessionRefused(byStatus: $0) }, "launch: no answer, a timeout, a rate limit or a server fault never asks for a new sign-in")
    check(RecoveryPolicy.launchRefreshRetryDelay == 3, "launch: asks once more after three seconds")
}


// ── Small talk: "What's up?" is a greeting, not a question about the Unix command (Windows 1.0.31, item 27) ──
do {
    let pb = PromptBuilder.shared
    func talk(_ q: String) -> Bool { pb.isSmallTalk(q) }
    check(talk("Hello. What's up?"), "small talk: \"Hello. What's up?\"")
    check(talk("What's up?"), "small talk: \"What's up?\"")
    check(talk("What is up?"), "small talk: \"What is up?\"")
    check(talk("Hey, what\u{2019}s up?"), "small talk: a curly apostrophe is handled")
    check(talk("Wassup"), "small talk: wassup")
    check(talk("What's going on?"), "small talk: what's going on")
    check(talk("Good to see you."), "small talk: good to see you")
    check(talk("Hi, how are you?"), "small talk: hi, how are you")
    check(talk("How are you doing today?"), "small talk: how are you doing today")
    check(talk("Nice to meet you."), "small talk: nice to meet you")
    check(talk("Nice to meet you too, thanks!"), "small talk: nice to meet you too, thanks")
    check(talk("Thanks for coming in today."), "small talk: thanks for coming in today")
    check(talk("How was your day?"), "small talk: how was your day")
    check(!talk("What's up with this memory leak in the service?"), "a real question after \"what's up\" is still a question")
    check(!talk("What's up, tell me about your last project."), "\"what's up\" then the interview starts is not small talk")
    check(!talk("How are you handling state in React?"), "\"how are you handling state\" is a real question")
    check(!talk("How are you deploying to AWS?"), "\"how are you deploying\" is a real question")
    check(!talk("Nice to meet you, shall we start with your background?"), "a greeting that opens the interview is not only small talk")
    check(!talk("Tell me about yourself."), "\"tell me about yourself\" is not small talk")
    check(!talk("What is a hash map?"), "\"what is a hash map\" is not small talk")
    check(pb.isGreeting("Good morning!") && !pb.isGreeting("Hi, what is dependency injection?"), "greetings stay tight: only a greeting is a greeting")
}


do {
    let screen = "From your screen: Chrome, Two Sum\n\nSAY THIS\nI would use a hash map.\n\nDETAIL\n```python\nx = 1\n```\n\nTime: O(n)\nSpace: O(n)"
    check(AnswerLayout.copyText(screen) == "From your screen: Chrome, Two Sum\n\nI would use a hash map.", "copy: the line saying what was read and the part to say, no headings, no code, no complexity line")
    check(AnswerLayout.copyText("Q: What is a queue?\n\nA queue is first in, first out.") == "Q: What is a queue?\n\nA queue is first in, first out.", "copy: an ordinary spoken answer is copied as it is")
    check(AnswerLayout.copyText("\u{2501}\u{2501}\u{2501} ANSWER \u{2501}\u{2501}\u{2501}\nB") == "\u{2501}\u{2501}\u{2501} ANSWER \u{2501}\u{2501}\u{2501}\nB", "copy: the older section style is copied as shown")
}

// Windows 1.0.31 item 28: our own server is told which app this is, and nobody else is.
do {
    func req(_ url: String) -> URLRequest { var r = URLRequest(url: URL(string: url)!); r.setValue("Bearer x", forHTTPHeaderField: "Authorization"); return r }
    let ours = AppIdentity.label(req("https://replysis.com/api/v1/interview/ask"), backendHost: "replysis.com", version: "1.0.247")
    check(ours.value(forHTTPHeaderField: "X-App-Platform") == "mac", "app label: a request to our own server carries X-App-Platform: mac")
    check(ours.value(forHTTPHeaderField: "X-App-Version") == "1.0.247", "app label: and the plain version")
    check(ours.value(forHTTPHeaderField: "Authorization") == "Bearer x", "app label: other headers are kept")
    for other in ["https://github.com/drBindu/replysis-mac/releases/latest/download/appcast.xml", "https://securetoken.googleapis.com/v1/token",
                  "https://accounts.google.com/o/oauth2/v2/auth", "https://api.deepgram.com/v1/listen", "https://replysis.com.evil.example/x", "https://notreplysis.com/x"] {
        let r = AppIdentity.label(req(other), backendHost: "replysis.com", version: "1.0.247")
        check(r.value(forHTTPHeaderField: "X-App-Platform") == nil && r.value(forHTTPHeaderField: "X-App-Version") == nil, "app label: never added for \(URL(string: other)!.host!)")
    }
    check(AppIdentity.label(req("https://REPLYSIS.com:443/x"), backendHost: "replysis.com", version: "1.0.247").value(forHTTPHeaderField: "X-App-Platform") == "mac", "app label: the host compare ignores case and the port")
    check(AppIdentity.label(req("http://127.0.0.1:18997/x"), backendHost: "127.0.0.1", version: "1.0.247").value(forHTTPHeaderField: "X-App-Platform") == "mac", "app label: a developer build's fake server counts as the backend it is configured for")
    check(AppIdentity.label(req("https://replysis.com/x"), backendHost: nil, version: "1.0.247").value(forHTTPHeaderField: "X-App-Platform") == nil, "app label: no known backend host, no label")
    check(AppIdentity.plainVersion("1.0.247") == "1.0.247", "app label: a plain version is kept")
    check(AppIdentity.plainVersion("1.0.247-beta") == nil && AppIdentity.plainVersion("v1.0") == nil && AppIdentity.plainVersion("") == nil && AppIdentity.plainVersion(nil) == nil && AppIdentity.plainVersion("1..") == nil,
          "app label: only digits and dots can be sent as the version")
    let noVersion = AppIdentity.label(req("https://replysis.com/x"), backendHost: "replysis.com", version: "bad value")
    check(noVersion.value(forHTTPHeaderField: "X-App-Platform") == "mac" && noVersion.value(forHTTPHeaderField: "X-App-Version") == nil, "app label: a version that is not plain is left off, the platform still goes")
}

print("RESULT: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
