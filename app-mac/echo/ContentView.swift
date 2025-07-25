//
//  ContentView.swift
//

import SwiftUI
import Speech
import AVFoundation

// ───────── メッセージモデル ─────────
enum MessageType: String { case text, error, toolStart = "tool_start", toolEnd = "tool_end", user }

struct Message: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let type: MessageType
}

// ───────── メッセージ制限 ─────────
private let MESSAGE_LIMIT = 10

// ───────── ScrollClip Modifier ─────────
struct ScrollClipModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.scrollClipDisabled()
        } else {
            content
        }
    }
}

#if os(macOS)
import AppKit
private struct WindowKey: EnvironmentKey { static let defaultValue: NSWindow? = nil }
extension EnvironmentValues {
    var window: NSWindow? {
        get { self[WindowKey.self] }
        set { self[WindowKey.self] = newValue }
    }
}
struct WindowFinder: NSViewRepresentable {
    var callback: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { callback(v.window) }
        return v
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
#endif

struct ContentView: View {

    // MARK: ViewModels / State
    @StateObject private var speechVM = SpeechRecognizerViewModel()
    @State private var isMono = false     // 彩度制御
    @StateObject private var streamVM  = StreamViewModel()
    @State private var zoomScale: CGFloat = 1.0

    @State private var messages: [Message] = []

    // 軽量モード（SpeechView ↔ ChatBubble共有）
    @State private var isLightweightMode: Bool = false

    #if os(macOS)
    @State private var window:     NSWindow? = nil
    @State private var startFrame: NSRect?   = nil
    @State private var startMouse: NSPoint?  = nil
    @State private var hasCentered          = false
    @State private var topPadding: CGFloat = 30
    #endif

    // スクロール設定
    private let scrollAnimDuration: Double = 0.1
    private let scrollAnimDelay:    Double = 0.25
    
    // ズーム対応の動的サイズ計算（現状未使用）
    @State private var dynamicMaxWidth: CGFloat = 1000
    
    // ズームコールバック
    var onZoomToggle: ((_ zoomValue: CGFloat) -> Void)?
    
    // 最小化制御
    @State private var isMinimized: Bool = false
    @State private var pulseToken: Int = 0

    // チャットメッセージ表示
    @ViewBuilder
    private var chatMessagesView: some View {
        ForEach(messages) { msg in
            ChatBubble(
                message: msg,
                zoomValue: zoomScale,
                isLightweight: isLightweightMode              // ←ここで反映
            )
            .id(msg.id)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var messagesSection: some View {
        Section {
            VStack(spacing: 16) {
                if !isMinimized {
                    chatMessagesView
                }
            }
            .padding(.top, -40 * zoomScale)
        } header: {
            SpeechView(
                viewModel: speechVM,
                onZoomToggle: { zoomValue in
                    onZoomToggle?(zoomValue)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        zoomScale = zoomValue
                    }
                },
                isLightweightMode: $isLightweightMode,   // ←Binding渡し
                isMinimized: $isMinimized,
                pulseToken: $pulseToken
            )
            .saturation(isMono ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    var body: some View {
        GeometryReader { _ in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                        messagesSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .modifier(ScrollClipModifier())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // メッセージ追加時スクロール
                .onChange(of: messages) { _ in
                    scrollToBottom(proxy, animated: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + scrollAnimDelay) {
                        scrollToBottom(proxy, duration: scrollAnimDuration)
                    }
                }
            }
            #if os(macOS)
            .padding(.top, topPadding)
            .padding([.leading, .trailing, .bottom], 30 * zoomScale)
            #else
            .padding(30 * zoomScale)
            #endif
        }
        .onChange(of: zoomScale) { _ in
            #if os(macOS)
            updateTopPadding()
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        
        // macOS ウインドウ調整
        #if os(macOS)
        .background(WindowFinder { win in
            self.window = win
            if let w = win, !hasCentered { centerWindow(w); hasCentered = true }
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)) { _ in
            updateTopPadding()
        }
        #endif

        // ViewModel Hooks
        .task {
            // 音声確定 → user
            speechVM.onPhraseFinalized = { phrase in
                SpeechSpeakerViewModel.shared.prepareForNewTurn()
                messages.append(Message(text: phrase, type: .user))
                if messages.count > MESSAGE_LIMIT {
                    messages.removeFirst(messages.count - MESSAGE_LIMIT)
                }
                streamVM.send(phrase)
                AudioPlayerManager.shared.playSound(fileName: "success")
            }
            // ストリーム応答
            streamVM.onMessage = { msg, rawType in
                let mType = MessageType(rawValue: rawType) ?? .text
                messages.append(Message(text: msg, type: mType))
                if messages.count > MESSAGE_LIMIT {
                    messages.removeFirst(messages.count - MESSAGE_LIMIT)
                }
                switch mType {
                case .text:
                    AudioPlayerManager.shared.playSound(fileName: "notification")
                    let selectedVoiceId = UserDefaults.standard.string(forKey: "SelectedVoiceStyleId") ?? "1937616896"
                    SpeechSpeakerViewModel.shared.speak(text: msg, id: selectedVoiceId)
                case .error:
                    AudioPlayerManager.shared.playSound(fileName: "error")
                case .toolStart:
                    AudioPlayerManager.shared.playSound(fileName: "alert")
                case .toolEnd:
                    AudioPlayerManager.shared.playSound(fileName: "end")
                case .user: break
                }
                pulseToken &+= 1
            }
        }
    }

    // MARK: Helpers
    private func scrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool = true,
        duration: Double = 0.45
    ) {
        guard let last = messages.last else { return }
        let action = { proxy.scrollTo(last.id, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: duration), action)
        } else {
            action()
        }
    }

    #if os(macOS)
    private func centerWindow(_ win: NSWindow) {
        guard let screen = win.screen else { return }
        win.setContentSize(NSSize(width: 480, height: 640))
        var f = win.frame
        f.origin.x = screen.frame.midX - f.width / 2
        f.origin.y = screen.frame.midY - f.height / 2
        win.setFrame(f, display: true)
    }
    private func updateTopPadding() {
        guard let win = window, let screen = win.screen else { return }
        let visibleTop = screen.visibleFrame.maxY
        let buffer: CGFloat = 5
        let distance = max(0, visibleTop - win.frame.maxY + buffer)
        let base = 30 * zoomScale
        let newVal = min(base, distance)
        if abs(newVal - topPadding) > 0.5 {
            topPadding = newVal
        }
    }
    #endif
}
