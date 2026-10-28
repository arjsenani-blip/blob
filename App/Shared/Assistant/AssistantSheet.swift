import SwiftUI
import BrainCore

/// The assistant, opened from the + in the middle of the tab bar. Type or speak; changes show under the reply with Undo.
struct AssistantSheet: View {
    @EnvironmentObject var store: BrainStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var assistant = BlobAssistant.shared
    @StateObject private var dictation = Dictation()
    @State private var text = ""
    @FocusState private var focused: Bool

    private let suggestions = [
        "What's on today?",
        "Move fencing practice to 6pm",
        "Signing up for the tournament only takes 10 min",
        "Add dentist Friday at 3:30",
        "What's due this week?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let why = BlobAssistant.unavailableReason {
                            Text(why).font(.system(size: 13)).foregroundStyle(X.muted)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(X.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        if assistant.messages.isEmpty { welcome }
                        ForEach(assistant.messages) { m in bubble(m).id(m.id) }
                        if assistant.thinking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.system(size: 14)).foregroundStyle(X.muted)
                            }
                            .id("thinking")
                        }
                    }
                    .padding(20)
                }
                .onChange(of: assistant.messages.count) {
                    withAnimation { proxy.scrollTo(assistant.messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: assistant.thinking) { if assistant.thinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } } }
            }
            composer
        }
        .background(X.page.ignoresSafeArea())
        .sheetSize(minWidth: 560, minHeight: 680)
        .onAppear { assistant.prewarm(); focused = true }
        .onChange(of: dictation.transcript) { if dictation.isListening { text = dictation.transcript } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(X.purple, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text("Blob").font(.system(size: 17, weight: .bold)).foregroundStyle(X.ink)
                Text("On-device · private").font(.system(size: 12)).foregroundStyle(X.muted)
            }
            Spacer()
            if !assistant.messages.isEmpty {
                Button("Clear") { assistant.clear() }.buttonStyle(.plain).font(.system(size: 14, weight: .semibold)).foregroundStyle(X.muted)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(X.ink)
                    .frame(width: 30, height: 30).background(X.soft, in: Circle())
            }
            .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(X.line).frame(height: 1) }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hi! Ask about your day, or tell me what to add, move or change.")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(X.ink)
            FlowChips(items: suggestions) { s in send(s) }
        }
    }

    @ViewBuilder
    private func bubble(_ m: BlobAssistant.Message) -> some View {
        if m.fromUser {
            HStack {
                Spacer(minLength: 50)
                Text(m.text).font(.system(size: 15)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(X.purple, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(m.text).font(.system(size: 15)).foregroundStyle(X.ink)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(X.soft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
                ForEach(m.changes, id: \.self) { id in
                    if let c = assistant.change(id) { changeRow(c) }
                }
            }
            .padding(.trailing, 40)
        }
    }

    private func changeRow(_ c: AssistantChange) -> some View {
        let undone = assistant.undone.contains(c.id)
        return HStack(spacing: 10) {
            Image(systemName: undone ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(undone ? X.muted : Color(red: 0.18, green: 0.62, blue: 0.30))
            Text(c.summary).font(.system(size: 13, weight: .medium)).foregroundStyle(undone ? X.muted : X.body)
                .strikethrough(undone)
            Spacer(minLength: 0)
            if !undone {
                Button("Undo") { assistant.undo(c.id) }.buttonStyle(.plain)
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(X.purple)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(X.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(X.line))
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let p = dictation.problem { Text(p).font(.caption).foregroundStyle(X.now) }
            HStack(alignment: .bottom, spacing: 8) {
                Button { dictation.toggle(startingWith: text) } label: {
                    Image(systemName: dictation.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(dictation.isListening ? .white : X.ink)
                        .frame(width: 42, height: 42)
                        .background(dictation.isListening ? AnyShapeStyle(X.now) : AnyShapeStyle(X.soft), in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")
                TextField(dictation.isListening ? "Listening…" : "Ask Blob or tell it what to change", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 16)).lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { send(text) }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(X.soft, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
                Button { send(text) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(X.purple, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || assistant.thinking)
                .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty || assistant.thinking ? 0.45 : 1)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 14)
        .overlay(alignment: .top) { Rectangle().fill(X.line).frame(height: 1) }
    }

    private func send(_ s: String) {
        dictation.stop()
        let msg = s
        text = ""
        Task { await assistant.send(msg) }
    }
}

/// Chips that wrap onto new lines.
struct FlowChips: View {
    var items: [String]
    var tap: (String) -> Void
    var body: some View {
        WrapLayout(spacing: 8) {
            ForEach(items, id: \.self) { s in
                Button { tap(s) } label: {
                    Text(s).font(.system(size: 14, weight: .semibold)).foregroundStyle(X.ink)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(X.raised, in: Capsule())
                        .overlay(Capsule().strokeBorder(X.line))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { y += row + spacing; x = 0; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}
