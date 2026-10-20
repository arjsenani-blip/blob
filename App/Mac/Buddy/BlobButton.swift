import SwiftUI
import AppKit

/// The tappable Blob in the corner: tucks away when idle, pops out on hover or when active.
struct BuddyBlobButton: View {
    @EnvironmentObject var buddy: BuddyController

    private var tucked: Bool { buddy.phase == .resting && !buddy.hovering }

    private var mood: BlobMood {
        if buddy.isError && buddy.phase != .resting { return .error }
        switch buddy.phase {
        case .confirming: return .asking
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .awake, .resting:
            if buddy.celebrating { return .happy }
            if buddy.hovering { return .curious }
            if buddy.sleeping { return .sleepy }
            return .idle
        }
    }

    var body: some View {
        BlobCharacter(mood: mood,
                      level: CGFloat(max(buddy.speechIn.level, buddy.speechOut.level)),
                      look: buddy.look,
                      paused: !buddy.panelVisible,
                      tucked: tucked)
            .frame(width: 92, height: 92)
            .scaleEffect(tucked ? 0.84 : 1)
            .rotationEffect(.degrees(tucked ? -20 : 0))
            .offset(x: tucked ? 50 : 0, y: tucked ? 48 : 0)
            .animation(.spring(duration: 0.55, bounce: 0.4), value: tucked)
            .contentShape(Circle().scale(0.8))
            .onTapGesture { buddy.activate() }
            .contextMenu {
                Button("Talk to Blob  (\(BuddyShortcut.current.label))") { buddy.activate() }
                Button("Type to Blob") { buddy.startTyping() }
                Button("Update Blob…") { buddy.startUpdateRequest() }
                Button("New conversation") { buddy.newConversation() }
                Divider()
                Button("Open Blob's Brain") {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                }
                Button("Hide Blob") { UserDefaults.standard.set(false, forKey: "buddyEnabled") }
            }
            .overlay(alignment: .topLeading) {
                if buddy.hovering && buddy.phase == .resting && !buddy.showBubble {
                    Text("Click or \(BuddyShortcut.current.label)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.75)))
                        .overlay(Capsule().stroke(BuddyColors.cyan.opacity(0.6)))
                        .fixedSize()
                        .offset(x: -58, y: -10)
                        .transition(.opacity)
                }
            }
    }
}

// MARK: - App icon artwork (rendered with `-renderIcons <folder>`)

/// Blob on a deep-navy squircle with a cyan bloom. `fullBleed` is the iOS version (iOS applies its own mask).
struct BlobIconArt: View {
    var fullBleed = false

    var body: some View {
        let size: CGFloat = 1024
        let tile: CGFloat = fullBleed ? size : 824
        ZStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.07, green: 0.14, blue: 0.24), Color(red: 0.01, green: 0.03, blue: 0.08)],
                               startPoint: .top, endPoint: .bottom)
                // Cyan bloom behind Blob
                RadialGradient(colors: [BuddyColors.cyan.opacity(0.42), BuddyColors.cyan.opacity(0.08), .clear],
                               center: UnitPoint(x: 0.5, y: 0.56), startRadius: 0, endRadius: tile * 0.55)
                // Faint floor reflection
                Ellipse()
                    .fill(RadialGradient(colors: [BuddyColors.cyan.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: tile * 0.22))
                    .frame(width: tile * 0.55, height: tile * 0.09)
                    .offset(y: tile * 0.37)
                BlobCharacter(mood: .idle, level: 0, look: CGPoint(x: 0, y: -0.15), fixedTime: 1.0)
                    .frame(width: tile * 0.72, height: tile * 0.72)
                    .offset(y: tile * 0.035)
                // Top glass sheen
                LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
            }
            .frame(width: tile, height: tile)
            .clipShape(RoundedRectangle(cornerRadius: fullBleed ? 0 : tile * 0.225, style: .continuous))
            .overlay {
                if !fullBleed {
                    RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 3)
                }
            }
            .shadow(color: .black.opacity(fullBleed ? 0 : 0.35), radius: 22, y: 12)
        }
        .frame(width: size, height: size)
    }

    @MainActor
    static func render(to folder: URL) {
        for (name, full) in [("mac-1024.png", false), ("ios-1024.png", true)] {
            let r = ImageRenderer(content: BlobIconArt(fullBleed: full))
            r.scale = 1
            r.isOpaque = full
            guard let cg = r.cgImage else { continue }
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
        }
    }
}

/// Monochrome Blob silhouette (body, visor, two eyes) for the menu bar. Template image, so it adapts to light/dark.
enum BlobMenuIcon {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 15, height: 15)).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: 4, y: 5.5, width: 10, height: 5.5), xRadius: 2.75, yRadius: 2.75).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(roundedRect: NSRect(x: 6.2, y: 6.6, width: 1.6, height: 3.3), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 10.2, y: 6.6, width: 1.6, height: 3.3), xRadius: 0.8, yRadius: 0.8).fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}
