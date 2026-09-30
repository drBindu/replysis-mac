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

check(!GlobalHotkey.isListeningShortcut(keyCode: 49, flags: []), "typing a space never toggles listening")
check(!GlobalHotkey.isListeningShortcut(keyCode: 49, flags: .maskCommand), "Spotlight shortcut preserved")
check(GlobalHotkey.isListeningShortcut(keyCode: 49, flags: .maskAlternate), "Option-Space controls listening")
check(!GlobalHotkey.isListeningShortcut(keyCode: 49, flags: [.maskAlternate, .maskShift]), "other modified shortcuts preserved")
check(!GlobalHotkey.isListeningShortcut(keyCode: 100, flags: .maskAlternate), "unrelated key not listening shortcut")

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
let messages = builder.buildMessages(resumeFacts: "Synthetic candidate. Five years of Swift.", currentQuestion: "What is an actor?", jobContext: "Mobile engineer", concise: true)
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

print("RESULT: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
