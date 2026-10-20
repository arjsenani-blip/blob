import SwiftUI
import AppKit


/// Everything inside the corner panel: the bubble on top, Blob in the bottom-right.
struct BuddyOverlay: View {
    @EnvironmentObject var buddy: BuddyController

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            if buddy.showBubble {
                BuddyBubble()
                    .padding(.trailing, 18)
                    .padding(.bottom, BuddyController.blobArea.height - 22)
                    .transition(.scale(scale: 0.4, anchor: .bottomTrailing).combined(with: .opacity))
            }
            BuddyBlobButton()
                .frame(width: BuddyController.blobArea.width, height: BuddyController.blobArea.height)
        }
        .frame(width: BuddyController.panelSize.width, height: BuddyController.panelSize.height)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Speech bubble

struct BuddyBubble: View {
    @EnvironmentObject var buddy: BuddyController
    @FocusState private var fieldFocused: Bool
    @ObservedObject private var updater = BlobUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(BuddyColors.cyan).frame(width: 7, height: 7).shadow(color: BuddyColors.cyan, radius: 4)
                Text("Blob").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(BuddyColors.light)
                Text(phaseLabel).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button { buddy.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }

            if !buddy.heard.isEmpty || buddy.phase == .listening {
                HStack(alignment: .top, spacing: 8) {
                    if buddy.phase == .listening { Waveform(level: CGFloat(buddy.speechIn.level)).frame(width: 26, height: 18) }
                    Text(buddy.phase == .listening ? (buddy.speechIn.transcript.isEmpty ? "Listening…" : buddy.speechIn.transcript) : "“\(buddy.heard)”")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(buddy.phase == .listening && buddy.speechIn.transcript.isEmpty ? 0.5 : 0.75))
                        .italic(buddy.phase != .listening)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if case .working(_, let since) = updater.state {
                UpdateProgressView(since: since, steps: updater.progress)
            }

            if buddy.phase == .thinking {
                HStack(spacing: 8) {
                    ThinkingDots()
                    Text(buddy.status.isEmpty ? "Thinking…" : buddy.status)
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(BuddyColors.light.opacity(0.85))
                }
            }

            if let prompt = buddy.confirmPrompt {
                confirmView(prompt)
            } else if !buddy.reply.isEmpty && buddy.phase != .thinking && buddy.phase != .listening {
                ScrollView {
                    Text(buddy.reply)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(buddy.isError ? BuddyColors.red : .white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 210)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField(buddy.updateMode ? "Describe a change to Blob…" : "Type to Blob…", text: $buddy.typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .rounded))
                    .focused($fieldFocused)
                    .onSubmit { buddy.submitTyped() }
                Button { buddy.activate() } label: {
                    Image(systemName: buddy.phase == .listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(BuddyColors.cyan))
                        .shadow(color: BuddyColors.cyan.opacity(0.8), radius: 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.07)))
        }
        .padding(14)
        .frame(width: 330)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.03, green: 0.07, blue: 0.11).opacity(0.92))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(BuddyColors.cyan.opacity(0.55), lineWidth: 1))
        .shadow(color: BuddyColors.cyan.opacity(0.35), radius: 16)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { buddy.bubbleFrame = $0 }
        .onDisappear { buddy.bubbleFrame = .zero }
    }

    private var phaseLabel: String {
        switch buddy.phase {
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "talking"
        case .confirming: return "needs your OK"
        default: return ""
        }
    }

    private func confirmView(_ prompt: String) -> some View {
        let lines = prompt.components(separatedBy: "\n\n")
        return VStack(alignment: .leading, spacing: 8) {
            Label(lines.first ?? "", systemImage: "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(BuddyColors.amber)
            if lines.count > 1 {
                ScrollView {
                    Text(lines.dropFirst().joined(separator: "\n\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.5)))
            }
            HStack {
                Spacer()
                Button("Not now") { buddy.answerPermission(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { buddy.answerPermission(true) }
                    .keyboardShortcut(.defaultAction)
                    .tint(BuddyColors.cyan)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
    }
}

struct Waveform: View {
    var level: CGFloat
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule().fill(BuddyColors.cyan)
                        .frame(width: 3, height: 4 + (level * 14) * CGFloat(0.5 + 0.5 * sin(t * 12 + Double(i) * 1.3)))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(BuddyColors.cyan)
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * (sin(t * 5 - Double(i) * 0.9) + 1) / 2)
                }
            }
        }
    }
}

/// Live view of Claude Code working on an update.
struct UpdateProgressView: View {
    var since: Date
    var steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(BuddyColors.cyan)
                Text("Updating Blob with Claude Code")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(BuddyColors.light)
                Spacer()
                Text(since, style: .timer)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(Array(steps.suffix(5).enumerated()), id: \.offset) { i, step in
                let isLast = i == min(steps.count, 5) - 1
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isLast ? "circle.dotted" : "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isLast ? BuddyColors.cyan : .white.opacity(0.4))
                        .frame(width: 12)
                        .padding(.top, 2)
                    Text(step)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(isLast ? 0.9 : 0.5))
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(BuddyColors.cyan.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BuddyColors.cyan.opacity(0.25)))
        .animation(.easeOut(duration: 0.2), value: steps)
    }
}
