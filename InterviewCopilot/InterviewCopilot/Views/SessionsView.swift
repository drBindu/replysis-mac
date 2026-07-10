import SwiftUI
import UniformTypeIdentifiers

struct SessionEntry: Identifiable, Equatable {
    static func == (lhs: SessionEntry, rhs: SessionEntry) -> Bool { lhs.id == rhs.id }
    let id = UUID()
    let filename: String
    let header: String
    let content: String
    let date: Date
    let sessionNumber: Int
    var isCloud: Bool = false
    var cloudDocId: String? = nil
    var questionCount: Int { content.components(separatedBy: "\n").filter { $0.hasPrefix("Q:") }.count }
    var model: String {
        // Cloud sessions come from the website's real-interview page, which has no
        // local "groq/openai" header line to parse — badge them distinctly instead.
        if isCloud { return "Web" }
        // Session headers are written by appendToSessionLog as "groq" or "openai" —
        // those two must be recognized here or every session badge just says "AI".
        if header.lowercased().contains("groq") { return "Groq" }
        if header.lowercased().contains("gpt-4o") || header.lowercased().contains("openai") { return "GPT-4o" }
        if header.lowercased().contains("gpt-4") { return "GPT-4" }
        if header.lowercased().contains("gpt") { return "GPT" }
        if header.lowercased().contains("claude") { return "Claude" }
        if header.lowercased().contains("gemini") { return "Gemini" }
        return "AI"
    }
    var formattedDate: String { Self.dateFmt.string(from: date) }
    var formattedTime: String { Self.timeFmt.string(from: date) }

    // Shared formatters — created once, not per row render
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
}

struct QABlock: Identifiable {
    let id = UUID()
    let question: String
    let answer: String
}

struct SessionsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var sessions: [SessionEntry] = []
    @State private var selected: SessionEntry?
    @State private var cachedQABlocks: [QABlock] = []
    @State private var searchText = ""
    @State private var copiedToast = false
    @State private var deletedToast = false
    @State private var showDeleteConfirm = false

    var filtered: [SessionEntry] {
        if searchText.isEmpty { return sessions }
        let q = searchText.lowercased()
        return sessions.filter {
            "session #\($0.sessionNumber)".contains(q) ||
            $0.content.lowercased().contains(q) ||
            $0.formattedDate.lowercased().contains(q)
        }
    }

    private func computeQABlocks(for sel: SessionEntry?) -> [QABlock] {
        guard let sel else { return [] }
        let lines = sel.content.components(separatedBy: "\n")
        var blocks: [QABlock] = []
        var currentQ = ""
        var currentA = ""
        var inAnswer = false

        for line in lines {
            if line.hasPrefix("Q:") {
                if !currentQ.isEmpty {
                    blocks.append(QABlock(question: currentQ, answer: currentA.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentQ = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                currentA = ""
                inAnswer = false
            } else if line.hasPrefix("A:") {
                currentA = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                inAnswer = true
            } else if inAnswer && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                currentA += "\n" + line.trimmingCharacters(in: .whitespaces)
            }
        }
        if !currentQ.isEmpty {
            blocks.append(QABlock(question: currentQ, answer: currentA.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return blocks
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "#060b14"), Color(hex: "#0a1020")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()

            HStack(spacing: 0) {
                sidebarPanel.frame(width: 260)
                Rectangle().fill(Color(hex: "#111d2e")).frame(width: 1)
                detailPanel
            }

            if copiedToast {
                toastBanner(icon: "checkmark.circle.fill", text: "Copied to clipboard", color: Color(hex: "#22c55e"))
            }
            if deletedToast {
                toastBanner(icon: "trash.fill", text: "Session deleted", color: Color(hex: "#ef4444"))
            }
        }
        .frame(width: 900, height: 580)
        .onAppear { loadSessions() }
        .onChange(of: selected) { _, newSel in cachedQABlocks = computeQABlocks(for: newSel) }
    }

    // MARK: - Sidebar

    var sidebarPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "#38bdf8"))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Interview Sessions")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text("\(sessions.count) sessions recorded")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#4b5563"))
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "#374151"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#4b5563"))
                TextField("Search sessions...", text: $searchText)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .textFieldStyle(.plain)
                    .accentColor(Color(hex: "#38bdf8"))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#4b5563"))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(hex: "#0d1623"))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(hex: "#1e2d40"), lineWidth: 1))
            .cornerRadius(7)
            .padding(.horizontal, 12).padding(.bottom, 8)

            Rectangle().fill(Color(hex: "#111d2e")).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filtered) { session in
                        sessionCard(session)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }

            Rectangle().fill(Color(hex: "#111d2e")).frame(height: 1)

            HStack(spacing: 0) {
                statPill(icon: "questionmark.circle", value: "\(sessions.reduce(0) { $0 + $1.questionCount })", label: "Q&As")
                Rectangle().fill(Color(hex: "#1e2d40")).frame(width: 1, height: 24)
                statPill(icon: "calendar", value: "\(sessions.count)", label: "Sessions")
            }
            .padding(.vertical, 8)
        }
        .background(Color(hex: "#070e1a"))
    }

    func sessionCard(_ session: SessionEntry) -> some View {
        let isSelected = selected?.id == session.id
        return Button(action: { selected = session }) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color(hex: "#0369a1") : Color(hex: "#0d1a2b"))
                        .frame(width: 36, height: 36)
                    if session.isCloud {
                        Image(systemName: "icloud.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isSelected ? .white : Color(hex: "#38bdf8"))
                    } else {
                        Text("#\(session.sessionNumber)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(isSelected ? .white : Color(hex: "#38bdf8"))
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(session.formattedDate)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(isSelected ? .white : Color(hex: "#cbd5e1"))
                        Spacer()
                        Text(session.formattedTime)
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "#4b5563"))
                    }
                    HStack(spacing: 5) {
                        Label("\(session.questionCount) Q&As", systemImage: "text.bubble")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(isSelected ? Color(hex: "#7dd3fc") : Color(hex: "#374151"))
                        Spacer()
                        Text(session.model)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(isSelected ? Color(hex: "#38bdf8") : Color(hex: "#1e3a50"))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(isSelected ? Color(hex: "#0c2a40") : Color(hex: "#0a1520"))
                            .cornerRadius(4)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color(hex: "#0c2240") : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color(hex: "#0e4c7c") : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    func statPill(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Spacer()
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(Color(hex: "#374151"))
            Text(value).font(.system(size: 11, weight: .bold)).foregroundColor(Color(hex: "#6b7280"))
            Text(label).font(.system(size: 10)).foregroundColor(Color(hex: "#374151"))
            Spacer()
        }
    }

    // MARK: - Detail Panel

    var detailPanel: some View {
        ZStack {
            if let sel = selected {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sel.isCloud ? "Session (Web)" : "Session #\(sel.sessionNumber)")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                            HStack(spacing: 8) {
                                Label(sel.formattedDate + " · " + sel.formattedTime, systemImage: "calendar")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#4b5563"))
                                Label("\(sel.questionCount) questions", systemImage: "questionmark.circle")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#4b5563"))
                                Text(sel.model)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(hex: "#38bdf8"))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color(hex: "#082032"))
                                    .cornerRadius(5)
                            }
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            actionBtn(icon: "doc.on.doc", label: "Copy", color: Color(hex: "#38bdf8")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sel.content, forType: .string)
                                withAnimation { copiedToast = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    withAnimation { copiedToast = false }
                                }
                            }
                            actionBtn(icon: "arrow.down.circle", label: "Export", color: Color(hex: "#6366f1")) {
                                exportSession(sel)
                            }
                            // No delete API for cloud sessions yet — only the local .txt
                            // file has a matching delete path.
                            if !sel.isCloud {
                                actionBtn(icon: "trash", label: "Delete", color: Color(hex: "#ef4444")) {
                                    showDeleteConfirm = true
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(Color(hex: "#070e1a"))

                    Rectangle().fill(Color(hex: "#111d2e")).frame(height: 1)

                    if cachedQABlocks.isEmpty {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 28))
                                .foregroundColor(Color(hex: "#1e2a3a"))
                            Text("No Q&A content in this session")
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "#374151"))
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(cachedQABlocks.enumerated()), id: \.element.id) { idx, block in
                                    qaBlockView(index: idx + 1, block: block)
                                }
                            }
                            .padding(20)
                        }
                    }
                }
                .confirmationDialog("Delete this session?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { deleteSession(sel) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Session #\(sel.sessionNumber) will be permanently removed.")
                }
            } else {
                VStack(spacing: 16) {
                    ZStack {
                        Circle().fill(Color(hex: "#0a1620")).frame(width: 80, height: 80)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 32))
                            .foregroundColor(Color(hex: "#0e4c7c"))
                    }
                    Text("Select a session")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(hex: "#374151"))
                    Text("Choose a past interview from the list on the left\nto review your questions and AI responses.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#1f2937"))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(hex: "#080f1c"))
    }

    func qaBlockView(index: Int, block: QABlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color(hex: "#0e3a5a")).frame(width: 24, height: 24)
                    Text("Q").font(.system(size: 11, weight: .black)).foregroundColor(Color(hex: "#38bdf8"))
                }
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("QUESTION \(index)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "#0369a1"))
                        .tracking(0.8)
                    Text(block.question)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: "#e2e8f0"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: "#050e1a"))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#0e2a40"), lineWidth: 1))
            )

            if !block.answer.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(Color(hex: "#1a1040")).frame(width: 24, height: 24)
                        Text("A").font(.system(size: 11, weight: .black)).foregroundColor(Color(hex: "#818cf8"))
                    }
                    .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AI RESPONSE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(hex: "#4338ca"))
                            .tracking(0.8)
                        Text(block.answer)
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#cbd5e1"))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(hex: "#070512"))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#1e1660"), lineWidth: 1))
                )
            }
        }
    }

    func actionBtn(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.3), lineWidth: 1))
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
    }

    func toastBanner(icon: String, text: String, color: Color) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundColor(color)
                Text(text).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(hex: "#111827"))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.4), lineWidth: 1))
            .cornerRadius(10)
            .shadow(color: .black.opacity(0.4), radius: 12)
            .padding(.bottom, 16)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Data

    func loadSessions() {
        let dir = SpeechmaticsEngine.shared.appDataFolder
        Task.detached(priority: .userInitiated) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.creationDateKey]) else { return }
            let localEntries = files
                .filter { $0.lastPathComponent.hasPrefix("interview_") && $0.pathExtension == "txt" }
                .compactMap { url -> SessionEntry? in
                    guard let content = try? String(contentsOf: url, encoding: .utf8),
                          content.contains("Q:") else { return nil }
                    let lines = content.components(separatedBy: "\n")
                    let header = lines.first ?? url.lastPathComponent
                    let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                    let name = url.deletingPathExtension().lastPathComponent
                    let num = Int(name.replacingOccurrences(of: "interview_", with: "")) ?? 0
                    return SessionEntry(filename: name, header: header, content: content, date: date, sessionNumber: num)
                }

            await MainActor.run {
                self.sessions = localEntries.sorted { $0.date > $1.date }
                let first = self.sessions.first
                self.selected = first
                self.cachedQABlocks = self.computeQABlocks(for: first)
            }

            // Cloud-backed-up sessions — same Firestore collection the website's
            // real-interview dashboard reads from. Skipped for guests (no account).
            guard await UserSession.shared.isLoggedIn, await !UserSession.shared.isGuestSession else { return }
            if await UserSession.shared.tokenNeedsRefresh { _ = await UserSession.shared.tryRefreshAsync() }
            guard let cloudSessions = await NetworkClient.shared.fetchCloudSessions() else { return }

            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "MMM-d"
            let cloudEntries = cloudSessions.map { cs -> SessionEntry in
                var e = SessionEntry(filename: "web-\(dateFmt.string(from: cs.date))", header: "",
                                      content: cs.content, date: cs.date, sessionNumber: 0)
                e.isCloud = true
                e.cloudDocId = cs.id
                return e
            }
            await MainActor.run {
                let merged = (self.sessions + cloudEntries).sorted { $0.date > $1.date }
                self.sessions = merged
                if self.selected == nil {
                    self.selected = merged.first
                    self.cachedQABlocks = self.computeQABlocks(for: merged.first)
                }
            }
        }
    }

    func exportSession(_ session: SessionEntry) {
        let panel = NSSavePanel()
        panel.title = "Export Session"
        panel.nameFieldStringValue = "\(session.filename).txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? session.content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func deleteSession(_ session: SessionEntry) {
        let dir = SpeechmaticsEngine.shared.appDataFolder
        let url = dir.appendingPathComponent("\(session.filename).txt")
        try? FileManager.default.removeItem(at: url)
        sessions.removeAll { $0.id == session.id }
        selected = sessions.first
        withAnimation { deletedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { deletedToast = false }
        }
    }
}
