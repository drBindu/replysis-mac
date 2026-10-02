import SwiftUI
import UniformTypeIdentifiers

/// One interview, from a transcript file on this Mac or from the cloud copy.
struct SessionEntry: Identifiable, Equatable {
    static func == (lhs: SessionEntry, rhs: SessionEntry) -> Bool { lhs.id == rhs.id }
    let id = UUID()
    let filename: String
    let content: String
    /// When the interview was started and when its transcript was last written.
    let date: Date
    let endDate: Date?
    let sessionNumber: Int
    var isCloud: Bool = false
    var cloudDocId: String? = nil

    let pairs: [QAPair]
    let summary: SessionInsights.Summary

    init(filename: String, content: String, date: Date, endDate: Date? = nil, sessionNumber: Int,
         isCloud: Bool = false, cloudDocId: String? = nil) {
        self.filename = filename; self.content = content; self.date = date; self.endDate = endDate
        self.sessionNumber = sessionNumber; self.isCloud = isCloud; self.cloudDocId = cloudDocId
        let p = SessionInsights.pairs(in: content)
        self.pairs = p
        self.summary = SessionInsights.summary(of: p)
    }

    var questionCount: Int { summary.questions }
    var lasted: String? { isCloud ? nil : SessionInsights.lastedText(from: date, to: endDate) }
    var formattedDate: String { Self.dateFmt.string(from: date) }
    var formattedTime: String { Self.timeFmt.string(from: date) }

    private static let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f }()
    private static let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
}

// The colours of Past Sessions: the app's own graphite and silver, with green kept for the one
// thing that is Replysis speaking. No blue and indigo of the earlier brand, no glow.
private enum SP {
    static let background = Color(hex: "#06090F")
    static let panel      = Color(hex: "#0A0F18")
    static let card       = Color.white.opacity(0.045)
    static let line       = Color.white.opacity(0.09)
    static let text       = Color(hex: "#F4F7FC")
    static let sub        = Color(hex: "#A4AFC0")
    static let faint      = Color(hex: "#6E7A8C")
    static let green      = Color(hex: "#4ADE80")
    static let greenFill  = Color(hex: "#4ADE80").opacity(0.07)
    static let greenLine  = Color(hex: "#4ADE80").opacity(0.22)

    static func color(for kind: QuestionKind) -> Color {
        switch kind {
        case .fromScreen:   return Color(hex: "#2DD4BF")
        case .behavioural:  return Color(hex: "#FBBF24")
        case .systemDesign: return Color(hex: "#A78BFA")
        case .coding:       return Color(hex: "#60A5FA")
        case .general:      return Color(hex: "#94A3B8")
        }
    }
}

struct SessionsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var sessions: [SessionEntry] = []
    @State private var selected: SessionEntry?
    @State private var searchText = ""
    @State private var copied = false
    @State private var deletedToast = false
    @State private var showDeleteConfirm = false
    @State private var loadingCloud = false
    private let preview: Bool

    /// `preview` fills the list with the given interviews and loads nothing, for the debug snapshot.
    init(preview: [SessionEntry]? = nil) {
        self.preview = preview != nil
        _sessions = State(initialValue: preview ?? [])
        _selected = State(initialValue: preview?.first)
    }

    private var filtered: [SessionEntry] {
        guard !searchText.isEmpty else { return sessions }
        let q = searchText.lowercased()
        return sessions.filter { $0.content.lowercased().contains(q) || $0.formattedDate.lowercased().contains(q) }
    }

    var body: some View {
        ZStack {
            SP.background.ignoresSafeArea()
            HStack(spacing: 0) {
                listPanel.frame(width: 270)
                Rectangle().fill(SP.line).frame(width: 1)
                detailPanel
            }
            if deletedToast {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(SP.green)
                        Text("Removed from this device").font(.system(size: 12, weight: .semibold)).foregroundColor(SP.text)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#111826")))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(SP.line, lineWidth: 1))
                    .padding(.bottom, 18)
                }
                .transition(.opacity)
            }
        }
        .frame(width: 880, height: 580)
        .preferredColorScheme(.dark)
        .onAppear { if !preview { loadSessions() } }
    }

    // MARK: - List

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).foregroundColor(SP.sub)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(SP.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SP.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Return to the interview")
                .accessibilityLabel("Return to the interview")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Past sessions").font(.system(size: 16, weight: .semibold)).foregroundColor(SP.text)
                    Text("\(sessions.count) \(sessions.count == 1 ? "session" : "sessions") recorded")
                        .font(.system(size: 11)).foregroundColor(SP.faint)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(SP.faint)
                TextField("", text: $searchText, prompt: Text("Search interviews").foregroundColor(SP.faint))
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(SP.text)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(SP.faint)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(SP.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(SP.line, lineWidth: 1))
            .padding(.horizontal, 14).padding(.bottom, 14)

            Text("INTERVIEWS").font(.system(size: 9, weight: .bold)).foregroundColor(SP.faint)
                .padding(.horizontal, 18).padding(.bottom, 6)

            if sessions.isEmpty {
                Spacer()   // the empty message is said once, on the right
            } else {
                MaybeScroll(flat: preview) {
                    LazyVStack(spacing: 4) {
                        ForEach(filtered) { row($0) }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 10)
                }
            }

            if loadingCloud {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading your interviews...").font(.system(size: 11)).foregroundColor(SP.faint)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SP.panel)
    }

    private func row(_ s: SessionEntry) -> some View {
        let on = selected?.id == s.id
        return Button(action: { selected = s }) {
            HStack(spacing: 0) {
                Rectangle().fill(on ? SP.green : Color.clear).frame(width: 2).padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(s.formattedDate).font(.system(size: 12.5, weight: .semibold)).foregroundColor(on ? SP.text : SP.sub)
                        if s.isCloud {
                            Image(systemName: "icloud").font(.system(size: 10)).foregroundColor(SP.faint).help("Cloud copy")
                        }
                        Spacer()
                        Text(s.formattedTime).font(.system(size: 10.5)).foregroundColor(SP.faint)
                    }
                    HStack(spacing: 8) {
                        Text("\(s.questionCount) \(s.questionCount == 1 ? "question" : "questions")")
                            .font(.system(size: 10.5)).foregroundColor(SP.faint)
                        if let lasted = s.lasted {
                            Text(lasted.replacingOccurrences(of: "Lasted ", with: ""))
                                .font(.system(size: 10.5)).foregroundColor(SP.faint)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Color.white.opacity(0.07) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Color.white.opacity(0.12) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    private func chip(_ text: String, color: Color = SP.sub, filled: Bool = false) -> some View {
        Text(text).font(.system(size: 10.5, weight: filled ? .bold : .medium)).foregroundColor(color)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(filled ? color.opacity(0.12) : Color.white.opacity(0.05)))
            .overlay(Capsule().stroke(filled ? color.opacity(0.28) : SP.line, lineWidth: 1))
    }

    private func action(_ label: String, icon: String, danger: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                Text(label).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundColor(danger ? Color(hex: "#F87171") : SP.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(danger ? Color(hex: "#F87171").opacity(0.08) : SP.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(danger ? Color(hex: "#F87171").opacity(0.25) : SP.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var detailPanel: some View {
        if let s = selected {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        Text("\(s.formattedDate), \(s.formattedTime)")
                            .font(.system(size: 18, weight: .semibold)).foregroundColor(SP.text)
                        Spacer(minLength: 12)
                        HStack(spacing: 7) {
                            action(copied ? "Copied" : "Copy", icon: copied ? "checkmark" : "doc.on.doc") { copy(s) }
                            action("Export", icon: "square.and.arrow.up") { exportSession(s) }
                            if !s.isCloud { action("Delete", icon: "trash", danger: true) { showDeleteConfirm = true } }
                        }
                    }
                    // One run of chips that flows onto a second row when the window is narrow,
                    // instead of squeezing each chip until its words break in half.
                    FlowLayout(spacing: 7) {
                        if let lasted = s.lasted { chip(lasted) }
                        chip("\(s.questionCount) \(s.questionCount == 1 ? "question" : "questions")")
                        if s.summary.longestAnswerWords > 0 { chip("Longest answer \(s.summary.longestAnswerWords) words") }
                        ForEach(s.summary.kinds, id: \.0) { kind, n in
                            chip("\(kind.rawValue) \(n)", color: SP.color(for: kind), filled: true)
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)

                Rectangle().fill(SP.line).frame(height: 1)

                if s.pairs.isEmpty {
                    VStack { Spacer(); Text("Nothing was asked in this interview").font(.system(size: 13)).foregroundColor(SP.faint); Spacer() }
                        .frame(maxWidth: .infinity)
                } else {
                    MaybeScroll(flat: preview) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(s.pairs) { pairBlock($0) }
                        }
                        .padding(24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .confirmationDialog("Remove this interview from this device?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Remove from this device", role: .destructive) { deleteSession(s) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(SessionInsights.deleteExplanation)
            }
        } else {
            VStack(spacing: 6) {
                Spacer()
                Text(sessions.isEmpty ? "No sessions yet" : "Choose an interview")
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(SP.sub)
                Text(sessions.isEmpty ? "Finished interviews appear here" : "Pick one from the list to read its questions and answers")
                    .font(.system(size: 12)).foregroundColor(SP.faint)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func pairBlock(_ p: QAPair) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("INTERVIEWER").font(.system(size: 9, weight: .bold)).foregroundColor(SP.faint)
                    Text(p.kind.rawValue).font(.system(size: 8.5, weight: .bold)).foregroundColor(SP.color(for: p.kind))
                }
                Text(p.question).font(.system(size: 13, weight: .medium)).foregroundColor(SP.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(SP.card))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(SP.line, lineWidth: 1))

            if !p.answer.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI ANSWER").font(.system(size: 9, weight: .bold)).foregroundColor(SP.green)
                    Text(p.spokenAnswer).font(.system(size: 12.5)).foregroundColor(Color(hex: "#DCE4F0"))
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    if !p.moreToSay.isEmpty {
                        Text("MORE TO SAY").font(.system(size: 8.5, weight: .bold)).foregroundColor(SP.faint).padding(.top, 4)
                        Text(p.moreToSay).font(.system(size: 11.5)).foregroundColor(SP.sub)
                            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11).fill(SP.greenFill))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(SP.greenLine, lineWidth: 1))
            }
        }
    }

    // MARK: - Actions

    private func copy(_ s: SessionEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.content, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    private func exportSession(_ session: SessionEntry) {
        let panel = NSSavePanel()
        panel.title = "Export interview"
        panel.nameFieldStringValue = "\(session.filename).txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? session.content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Only this device's copy. The cloud backup is not touched, so it can appear in the list again.
    private func deleteSession(_ session: SessionEntry) {
        let url = SpeechmaticsEngine.shared.appDataFolder.appendingPathComponent("\(session.filename).txt")
        try? FileManager.default.removeItem(at: url)
        sessions.removeAll { $0.id == session.id }
        selected = sessions.first
        withAnimation { deletedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { deletedToast = false } }
    }

    // MARK: - Data

    private func loadSessions() {
        let dir = SpeechmaticsEngine.shared.appDataFolder
        let signedIn = UserSession.shared.isLoggedIn && !UserSession.shared.isGuestSession
        loadingCloud = signedIn
        Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
            let local = files
                .filter { $0.lastPathComponent.hasPrefix("interview_") && $0.pathExtension == "txt" }
                .compactMap { url -> SessionEntry? in
                    guard let content = try? String(contentsOf: url, encoding: .utf8), content.contains("Q:") else { return nil }
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    let name = url.deletingPathExtension().lastPathComponent
                    return SessionEntry(filename: name, content: content,
                                        date: values?.creationDate ?? Date(), endDate: values?.contentModificationDate,
                                        sessionNumber: Int(name.replacingOccurrences(of: "interview_", with: "")) ?? 0)
                }
                .sorted { $0.date > $1.date }
            await MainActor.run {
                self.sessions = local
                self.selected = local.first
            }

            // The cloud copy, matched against this Mac's files so one interview never shows twice.
            guard signedIn else { return }
            if await UserSession.shared.tokenNeedsRefresh { _ = await UserSession.shared.tryRefreshAsync() }
            let cloud = await NetworkClient.shared.fetchCloudSessions()
            let stamp = DateFormatter(); stamp.dateFormat = "MMM-d"
            let extra: [SessionEntry] = (cloud ?? []).compactMap { cs in
                let entry = SessionEntry(filename: "web-\(stamp.string(from: cs.date))", content: cs.content,
                                         date: cs.date, sessionNumber: 0, isCloud: true, cloudDocId: cs.id)
                let first = entry.pairs.first?.question ?? ""
                let duplicate = local.contains {
                    SessionInsights.isSameInterview(localDate: $0.date, localFirstQuestion: $0.pairs.first?.question ?? "",
                                                    cloudDate: entry.date, cloudFirstQuestion: first)
                }
                return duplicate ? nil : entry
            }
            await MainActor.run {
                self.loadingCloud = false
                guard !extra.isEmpty else { return }
                let merged = (self.sessions + extra).sorted { $0.date > $1.date }
                self.sessions = merged
                if self.selected == nil { self.selected = merged.first }
            }
        }
    }
}


/// Items laid out left to right, starting a new row when the next one does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += rowHeight + spacing; x = bounds.minX; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}
