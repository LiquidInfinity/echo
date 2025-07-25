//
//  SpeechView.swift  (軽量モードBinding対応)
//

import SwiftUI
import Combine
import Speech
import AVFoundation
import AppKit
import SwiftUIIntrospect

// MARK: - InputBuffer
final class InputBuffer: ObservableObject {
    @Published var text: String = ""
}

// MARK: - Flowレイアウト & 文字アニメ（元ほぼ維持）
struct FlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth { x = 0; y += rowH; rowH = 0 }
            x += s.width; rowH = max(rowH, s.height)
        }
        return .init(width: maxWidth, height: y + rowH)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > b.maxX { x = b.minX; y += rowH; rowH = 0 }
            v.place(at: .init(x: x, y: y), proposal: .init(s))
            x += s.width; rowH = max(rowH, s.height)
        }
    }
}
private struct CharacterInfo: Identifiable { let char: String; let isNew: Bool; let id: Int }
struct AnimatedTextDisplay: View {
    private let chars: [CharacterInfo]
    init(fullText: String, highlight: Range<String.Index>?) {
        var a: [CharacterInfo] = []
        for (i, sc) in fullText.unicodeScalars.enumerated() {
            let idx = fullText.index(fullText.startIndex, offsetBy: i)
            a.append(.init(char: String(sc), isNew: highlight?.contains(idx) ?? false, id: i))
        }
        chars = a
    }
    var body: some View {
        FlowLayout {
            ForEach(chars) { info in
                Text(info.char)
                    .modifier(GlowFadeModifier(active: info.isNew))
            }
        }
    }
}
fileprivate struct GlowFadeModifier: ViewModifier, Animatable {
    @State private var p: Double
    private let maxR: CGFloat = 12
    private let glowColor = Color.white
    init(active: Bool) { p = active ? 0 : 1 }
    var animatableData: Double { get { p } set { p = newValue } }
    func body(content: Content) -> some View {
        content
            .foregroundColor(Color(white: 1 - p))
            .opacity(p)
            .overlay(
                content
                    .foregroundColor(glowColor)
                    .blur(radius: maxR * (1 - p))
                    .brightness(0.8 * (1 - p))
                    .opacity(0.9 * (1 - p))
                    .blendMode(.plusLighter)
            )
            .overlay(
                content
                    .foregroundColor(glowColor)
                    .blur(radius: maxR * 0.4 * (1 - p))
                    .opacity(0.8 * (1 - p))
                    .blendMode(.plusLighter)
            )
            .compositingGroup()
            .onAppear { if p == 0 { withAnimation(.easeOut(duration: 1)) { p = 1 } } }
    }
}

// MARK: - SpeechView
struct SpeechView: View {
    @ObservedObject var viewModel: SpeechRecognizerViewModel
    var onZoomToggle: ((_ newZoom: CGFloat) -> Void)?

    @Binding var isLightweightMode: Bool   // ←外部制御
    @Binding var isMinimized: Bool
    @Binding var pulseToken: Int

    @StateObject private var buffer = InputBuffer()
    @FocusState private var isEditing: Bool

    @StateObject private var textDelegate = TextEditorDelegate()
    @State private var currentTextView: NSTextView?
    @State private var shouldShowPlaceholder: Bool = true

    // 背景アニメ状態
    @State private var baseHue: Double = .random(in: 0..<360)
    @State private var glowRadius: CGFloat = 16
    @State private var whiteBorderRadius: CGFloat = 1
    @State private var rainbowLineWidth: CGFloat = 1.6

    @State private var isGray = false
    @State private var zoom: CGFloat = 1.0

    @State private var prevText = ""
    @State private var added: Range<String.Index>? = nil
    @State private var dynamicHeight: CGFloat = 36

    private let pulseHueOffset: Double = 60
    private let fieldWidth: CGFloat = 200
    private let autoSubmitDelay: TimeInterval = 0.8
    @State private var bag = Set<AnyCancellable>()

    @State private var isMainHover: Bool = false
    @State private var isOverlayHover: Bool = false
    @State private var showExitConfirm: Bool = false
    @ObservedObject private var speakerVM = SpeechSpeakerViewModel.shared

    var body: some View {
        ZStack {
            backgroundView
            if !isMinimized { contentView }
        }
        .saturation(isGray ? 0 : 1)
        .background(shadowBackground)
        .frame(width: isMinimized ? 48 * zoom : nil,
               height: isMinimized ? 48 * zoom : nil)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture {
            if isMinimized { withAnimation(.spring()) { isMinimized = false } }
        }
        .onReceive(viewModel.$transcript) { t in
            buffer.text = (t == "…") ? "" : t
        }
        .onReceive(buffer.$text) { t in
            calcAddedRange(t)
            guard !t.isEmpty else { return }
            if !isLightweightMode {
                pulseGlow(); pulseHue(); pulseWhiteBorder(); pulseRainbowBorder()
            }
        }
        .onAppear {
            configPipeline()
            if !isLightweightMode { startBreathing() }
            if !viewModel.isListening { viewModel.startRecording() }
        }
        .onChange(of: isLightweightMode) { on in
            if on {
                glowRadius = 6 * zoom
                whiteBorderRadius = 1
                rainbowLineWidth = 1.2
            } else {
                startBreathing()
            }
        }
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.2)) { isMainHover = h }
        }
        .padding(.bottom, isMinimized ? 0 : 40 * zoom)
        .overlay(isMinimized ? nil : terminalIconOverlay, alignment: .bottom)
        .onChange(of: pulseToken) { _ in
            if !isLightweightMode {
                pulseGlow(); pulseHue(); pulseWhiteBorder(); pulseRainbowBorder()
            }
        }
    }

    // 背景
    @ViewBuilder
    private var backgroundView: some View {
        if isLightweightMode {
            #if os(macOS)
            let fillColor = Color(NSColor.windowBackgroundColor)
            #else
            let fillColor = Color(.secondarySystemBackground)
            #endif
            RoundedRectangle(cornerRadius: 24 * zoom, style: .continuous)
                .fill(fillColor)
        } else {
            TimelineView(.animation) { tl in
                let time      = tl.date.timeIntervalSinceReferenceDate
                let baseRate  = 0.002
                let rawAngle  = time * baseRate
                let cosAbs    = abs(cos(Angle(degrees: rawAngle).radians))
                let speedK    = 0.9 + 0.1 * (1 - cosAbs)
                let angleDeg  = rawAngle * speedK
                let hueShift  = time * 15
                let hue       = baseHue + hueShift
                let θ         = Angle(degrees: angleDeg).radians
                let dx        = CGFloat(cos(θ))
                let dy        = CGFloat(sin(θ))
                let startPt   = UnitPoint(x: (1 - dx) * 0.5, y: (1 - dy) * 0.5)
                let endPt     = UnitPoint(x: (1 + dx) * 0.5, y: (1 + dy) * 0.5)

                GeometryReader { _ in
                    let radius    = 24 * zoom
                    let rectShape = RoundedRectangle(cornerRadius: radius, style: .continuous)

                    ZStack {
                        let θ        = Angle(degrees: angleDeg).radians
                        let cosθAbs  = abs(cos(θ))
                        let maxSpan  = 180.0
                        let minSpan  = 1.0
                        let span     = minSpan + (maxSpan - minSpan) * Double(cosθAbs)
                        let step     = span / 3

                        rectShape
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(stops: [
                                        .init(color: color(hue +   0      ), location: 0.00),
                                        .init(color: color(hue +   step   ), location: 0.33),
                                        .init(color: color(hue + 2*step   ), location: 0.66),
                                        .init(color: color(hue + 3*step   ), location: 1.00)
                                    ]),
                                    startPoint: startPt,
                                    endPoint:   endPt
                                )
                            )
                        rectShape
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(stops: [
                                        .init(color: color(hue +   0), location: 0.00),
                                        .init(color: color(hue +  60), location: 0.33),
                                        .init(color: color(hue + 120), location: 0.66),
                                        .init(color: color(hue + 180), location: 1.00)
                                    ]),
                                    startPoint: startPt,
                                    endPoint:   endPt
                                )
                            )
                            .compositingGroup()
                            .blur(radius: min(15 * zoom, 60))
                            .blendMode(.plusLighter)
                    }
                    .compositingGroup()
                    .overlay(rainbowBorder(shape: rectShape, angle: angleDeg, hue: hue))
                    .overlay(whiteBorder(shape: rectShape))
                    .overlay(outerGlow(shape: rectShape))
                }
            }
        }
    }
    private func color(_ h: Double) -> Color {
        Color(hue: (h.truncatingRemainder(dividingBy: 360)) / 360,
              saturation: 0.7,
              brightness: 0.95)
    }
    private func rainbowBorder(shape: RoundedRectangle, angle: Double, hue: Double) -> some View {
        shape
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: stride(from: 0, through: 360, by: 60).map {
                        color(hue + Double($0))
                    }),
                    center: .center,
                    angle: .degrees(angle)
                ),
                lineWidth: rainbowLineWidth * zoom
            )
            .blendMode(.screen)
    }
    private func whiteBorder(shape: RoundedRectangle) -> some View {
        shape
            .stroke(Color.white.opacity(0.6), lineWidth: 5.0 * zoom * whiteBorderRadius)
            .blur(radius: 3.0 * zoom * whiteBorderRadius)
            .blendMode(.screen)
    }
    private func outerGlow(shape: RoundedRectangle) -> some View {
        shape
            .stroke(Color.white.opacity(0.8), lineWidth: 4 * zoom)
            .blur(radius: glowRadius * zoom)
            .blendMode(.screen)
    }
    private var shadowBackground: some View {
        RoundedRectangle(cornerRadius: 24 * zoom, style: .continuous)
            .fill(Color.white.opacity(0.18))
            .shadow(color: Color.black.opacity(0.18), radius: 8 * zoom, y: 3 * zoom)
            .allowsHitTesting(false)
    }

    // コンテンツ
    private var contentView: some View {
        HStack(spacing: 8 * zoom) {
            textInputView
            if !viewModel.isListening && !buffer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sendButton
            }
            micButton
            zoomButton
            lightweightToggleButton
            minimizeButton
        }
        .padding(.horizontal, 14 * zoom)
        .padding(.vertical, 10 * zoom)
    }

    private var textInputView: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.isListening {
                if buffer.text.isEmpty {
                    Text("Echoにタイプ入力")
                        .font(.system(size: 17 * zoom))
                        .foregroundColor(.gray.opacity(0.7))
                        .padding(.top, 8 * zoom)
                        .padding(.leading, 5 * zoom)
                        .allowsHitTesting(false)
                } else {
                    AnimatedTextDisplay(fullText: buffer.text, highlight: added)
                        .font(.system(size: 17 * zoom))
                        .padding(.vertical, 8 * zoom)
                        .padding(.leading, 5 * zoom)
                        .allowsHitTesting(false)
                }
            } else {
                ZStack(alignment: .topLeading) {
                    if shouldShowPlaceholder {
                        Text("Echoにタイプ入力")
                            .font(.system(size: 17 * zoom))
                            .foregroundColor(.gray.opacity(0.7))
                            .padding(.top, 8 * zoom)
                            .padding(.leading, 8 * zoom)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $buffer.text)
                        .font(.system(size: 17 * zoom))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .scrollIndicators(.never)
                        .contentShape(Rectangle())
                        .padding(.top, 8 * zoom)
                        .padding(.leading, 3 * zoom)
                        .focused($isEditing)
                        .introspect(.textEditor, on: .macOS(.v13, .v14, .v15)) { textView in
                            setupTextViewDelegate(textView)
                        }
                }
            }
        }
        .frame(minWidth: fieldWidth * zoom,
               minHeight: dynamicHeight * zoom,
               maxHeight: 200 * zoom,
               alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sendButton: some View {
        Button { sendText() } label: {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 16 * zoom))
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
    }
    private var micButton: some View {
        Button {
            viewModel.isListening ? viewModel.stopRecording() : viewModel.startRecording()
        } label: {
            Image(systemName: viewModel.isListening ? "mic.fill" : "mic")
                .font(.system(size: 20 * zoom))
                .foregroundStyle(viewModel.isListening ? .red : .accentColor)
        }
        .buttonStyle(.plain)
    }
    private var zoomButton: some View {
        Button {
            let nz = zoom == 1.0 ? 2.5 : 1.0
            onZoomToggle?(nz)
            withAnimation(.easeInOut(duration: 0.3)) { zoom = nz }
        } label: {
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 20 * zoom))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
    private var lightweightToggleButton: some View {
        Button {
            withAnimation(.spring()) { isLightweightMode.toggle() }
        } label: {
            Image(systemName: isLightweightMode ? "bolt.slash.fill" : "bolt.fill")
                .font(.system(size: 20 * zoom))
                .foregroundStyle(isLightweightMode ? .gray : .yellow)
                .help("軽量モード切替")
        }
        .buttonStyle(.plain)
    }
    private var minimizeButton: some View {
        Button {
            withAnimation(.spring()) { isMinimized = true }
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 18 * zoom))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28 * zoom, height: 28 * zoom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // アニメ系（軽量考慮）
    private func startBreathing() {
        guard !isLightweightMode else { return }
        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
            glowRadius = 9 * zoom
        }
    }
    private func pulseGlow() {
        guard !isLightweightMode else { return }
        withAnimation(.easeOut(duration: 0.1)) { glowRadius = 16 * zoom }
        withAnimation(.easeIn(duration: 1.4).delay(0.1)) { glowRadius = 6 * zoom }
    }
    private func pulseWhiteBorder() {
        guard !isLightweightMode else { return }
        withAnimation(.easeOut(duration: 0.15)) { whiteBorderRadius = 3 }
        withAnimation(.easeIn(duration: 0.8).delay(0.1)) { whiteBorderRadius = 1 }
    }
    private func pulseRainbowBorder() {
        guard !isLightweightMode else { return }
        withAnimation(.easeOut(duration: 0.1)) { rainbowLineWidth = 8.0 }
        withAnimation(.easeIn(duration: 0.2).delay(0.1)) { rainbowLineWidth = 1.6 }
    }
    private func pulseHue() {
        guard !isLightweightMode else { return }
        withAnimation(.easeInOut(duration: 2)) {
            baseHue = (baseHue + pulseHueOffset).truncatingRemainder(dividingBy: 360)
        }
    }

    // 差分判定
    private func calcAddedRange(_ new: String) {
        defer { prevText = new }
        guard new.count > prevText.count,
              new.hasPrefix(prevText),
              prevText.endIndex <= new.endIndex
        else { added = nil; return }
        added = prevText.endIndex..<new.endIndex
    }

    // Combine
    private func configPipeline() {
        buffer.$text
            .sink { _ in }
            .store(in: &bag)
    }

    // Terminal overlay
    private var terminalIconOverlay: some View {
        let show = isMainHover || isOverlayHover
        return HStack(spacing: 8 * zoom) {
            Button(action: openTerminal) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 18 * zoom))
                    .padding(6 * zoom)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Circle())
                    .foregroundColor(.black)
                    .shadow(radius: 4 * zoom)
            }
            .frame(width: 34 * zoom, height: 34 * zoom)
            .contentShape(Rectangle())
            .buttonStyle(.plain)

            Button(action: { speakerVM.isSpeechEnabled.toggle() }) {
                Image(systemName: speakerVM.isSpeechEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 18 * zoom))
                    .padding(6 * zoom)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Circle())
                    .foregroundColor(.blue)
                    .shadow(radius: 4 * zoom)
            }
            .frame(width: 34 * zoom, height: 34 * zoom)
            .contentShape(Rectangle())
            .buttonStyle(.plain)

            Button(action: { showExitConfirm = true }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18 * zoom))
                    .padding(6 * zoom)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Circle())
                    .foregroundColor(.red)
                    .shadow(radius: 4 * zoom)
            }
            .frame(width: 34 * zoom, height: 34 * zoom)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
        }
        .padding(10 * zoom)
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.2)) { isOverlayHover = h }
        }
        .opacity(show ? 1 : 0)
        .offset(y: show ? 10 * zoom : 0)
        .allowsHitTesting(show)
        .animation(.interpolatingSpring(stiffness: 300, damping: 40), value: show)
        .overlay {
            if showExitConfirm {
                ExitConfirmDialog(zoom: zoom) {
                    NSApp.terminate(nil)
                } onCancel: {
                    withAnimation(.easeInOut(duration: 0.2)) { showExitConfirm = false }
                }
                .frame(minWidth: 220 * zoom, maxWidth: 320 * zoom)
            }
        }
    }
    private func openTerminal() {
        if let delegate = AppDelegate.shared {
            delegate.toggleTerminalWindow()
        } else {
            (NSApplication.shared.delegate as? AppDelegate)?.toggleTerminalWindow()
        }
    }

    // NSTextView delegateセット
    private func setupTextViewDelegate(_ textView: NSTextView) {
        currentTextView = textView
        textView.delegate = textDelegate
        textDelegate.onEnterPressed = { txt in sendTextDirectly(txt) }
        textDelegate.onShiftEnterPressed = { }
        textDelegate.onCommandEnterPressed = { txt in sendTextDirectly(txt) }
        textDelegate.onPlaceholderStateChanged = { show in
            DispatchQueue.main.async { self.shouldShowPlaceholder = show }
        }
        textDelegate.onTextHeightChanged = { newH in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.dynamicHeight = max(36, min(200, newH))
                }
            }
        }
        DispatchQueue.main.async {
            self.textDelegate.updatePlaceholderState(for: textView)
            self.textDelegate.updateTextHeight(for: textView)
        }
    }

    private func sendTextDirectly(_ text: String) {
        let cleaned = text.replacingOccurrences(of: "\n", with: "")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { viewModel.typePhrase(trimmed) }
        DispatchQueue.main.async {
            self.buffer.text = ""
            if let tv = self.currentTextView {
                tv.string = ""
                self.textDelegate.updatePlaceholderState(for: tv)
                self.textDelegate.updateTextHeight(for: tv)
                withAnimation(.easeInOut(duration: 0.2)) { self.dynamicHeight = 36 }
            }
        }
    }
    private func sendText() {
        let cleaned = buffer.text.replacingOccurrences(of: "\n", with: "")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { viewModel.typePhrase(trimmed) }
        DispatchQueue.main.async { self.buffer.text = "" }
    }
}

// MARK: - TextEditorDelegate
class TextEditorDelegate: NSObject, ObservableObject, NSTextViewDelegate {
    var onEnterPressed: ((String) -> Void)?
    var onShiftEnterPressed: (() -> Void)?
    var onCommandEnterPressed: ((String) -> Void)?
    var onPlaceholderStateChanged: ((Bool) -> Void)?
    var onTextHeightChanged: ((CGFloat) -> Void)?

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        updateTextHeight(for: textView)
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if textView.hasMarkedText() { return false }
            guard let event = NSApp.currentEvent else {
                onEnterPressed?(textView.string); return true
            }
            let mods = event.modifierFlags
            if mods.contains(.shift) {
                onShiftEnterPressed?(); return false
            } else if mods.contains(.command) {
                onCommandEnterPressed?(textView.string); return true
            } else {
                onEnterPressed?(textView.string); return true
            }
        }
        return false
    }
    func textDidChange(_ n: Notification) {
        guard let tv = n.object as? NSTextView else { return }
        updatePlaceholderState(for: tv)
        updateTextHeight(for: tv)
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn r: NSRange, replacementString: String?) -> Bool {
        DispatchQueue.main.async {
            self.updatePlaceholderState(for: textView)
            self.updateTextHeight(for: textView)
        }
        return true
    }
    func textViewDidChangeSelection(_ n: Notification) {
        guard let tv = n.object as? NSTextView else { return }
        updateTextHeight(for: tv)
    }
    func updatePlaceholderState(for tv: NSTextView) {
        let hasText = !tv.string.isEmpty
        let hasMarked = tv.hasMarkedText()
        onPlaceholderStateChanged?(!(hasText || hasMarked))
    }
    func updateTextHeight(for tv: NSTextView) {
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let contentH = tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 36
        let totalH = contentH + 16
        let clamped = max(36, min(200, totalH))
        onTextHeightChanged?(clamped)
    }
}

// MARK: - ExitConfirmDialog
fileprivate struct ExitConfirmDialog: View {
    let zoom: CGFloat
    let onConfirm: () -> Void
    let onCancel: () -> Void
    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture { onCancel() }
            VStack(spacing: 12 * zoom) {
                Text("本当に終了しますか？")
                    .font(.system(size: 16 * zoom, weight: .medium))
                HStack(spacing: 20 * zoom) {
                    Button("キャンセル", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("終了", role: .destructive, action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24 * zoom)
            .background(
                RoundedRectangle(cornerRadius: 12 * zoom, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .shadow(radius: 20 * zoom)
            )
            .frame(minWidth: 220 * zoom, maxWidth: 320 * zoom)
        }
        .transition(.opacity.combined(with: .scale))
    }
}
