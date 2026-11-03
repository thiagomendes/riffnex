import AVFoundation
import DesignSystem
import MusicCore
import SwiftUI

/// Plays reference string sounds for tuning by ear: a plucked-string synthesis (Karplus–Strong)
/// of the exact pitch, repeated every couple of seconds while a string is selected.
@MainActor
final class ReferenceTones {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var cache: [Int: AVAudioPCMBuffer] = [:]
    private var repeater: Task<Void, Never>?
    private var started = false

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Plucks `midi` now and again every 2.4 s until `stop()`.
    func play(_ midi: Int) {
        stop()
        guard start(), let buffer = buffer(for: midi) else { return }
        repeater = Task { [weak self] in
            while !Task.isCancelled {
                self?.pluck(buffer)
                try? await Task.sleep(for: .milliseconds(2400))
            }
        }
    }

    func stop() {
        repeater?.cancel()
        repeater = nil
        node.stop()
    }

    private func pluck(_ buffer: AVAudioPCMBuffer) {
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        node.play()
    }

    private func start() -> Bool {
        if started, engine.isRunning { return true }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            started = true
            return true
        } catch {
            return false
        }
    }

    /// 2.6 s of a plucked string at the exact pitch (A4 = 440 Hz).
    private func buffer(for midi: Int) -> AVAudioPCMBuffer? {
        if let cached = cache[midi] { return cached }
        let rate = format.sampleRate
        let frequency = 440 * pow(2, Double(midi - 69) / 12)
        let length = AVAudioFrameCount(rate * 2.6)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = length
        // Karplus–Strong with a fractional delay (allpass) so the pitch is exact, not rounded to a sample.
        // Loop delay = n samples + 0.5 (the two-point average) + d (the allpass), so the pitch is exact.
        let period = rate / frequency
        var n = Int(period - 0.5)
        var d = period - 0.5 - Double(n)
        if d < 0.1 { n -= 1; d += 1 } // keep the allpass in its well-behaved range
        let c = Float((1 - d) / (1 + d))
        var ring = (0..<n).map { _ in Float.random(in: -1...1) }
        // Soften the attack: a few passes of smoothing make it sound like a pick on a wound string.
        for _ in 0..<2 { for i in 0..<n { ring[i] = 0.5 * (ring[i] + ring[(i + 1) % n]) } }
        var index = 0
        var allpassIn: Float = 0, allpassOut: Float = 0
        let decay: Float = midi < 50 ? 0.9985 : 0.997
        var peak: Float = 0
        for i in 0..<Int(length) {
            let a = ring[index], b = ring[(index + 1) % n]
            let averaged = decay * 0.5 * (a + b)
            let out = c * averaged + allpassIn - c * allpassOut
            allpassIn = averaged
            allpassOut = out
            ring[index] = out
            data[i] = a
            peak = max(peak, abs(a))
            index = (index + 1) % n
        }
        let gain = 0.8 / max(peak, 1e-6)
        let fadeStart = Int(length) - Int(rate * 0.3)
        for i in 0..<Int(length) {
            var v = data[i] * gain
            if i > fadeStart { v *= Float(Int(length) - i) / Float(Int(length) - fadeStart) }
            data[i] = v
        }
        cache[midi] = buffer
        return buffer
    }
}

/// Choose the tuning for the neck and tune the guitar by ear.
struct TuningSheet: View {
    let current: TuningPreset
    let currentShifted: Bool
    let suggestion: TuningSuggestion?
    let choose: (TuningPreset, Bool) -> Void
    @State private var selected: TuningPreset
    @State private var shifted: Bool
    @State private var playing: Int?
    @State private var tones = ReferenceTones()
    @Environment(\.dismiss) private var dismiss

    init(current: TuningPreset, currentShifted: Bool, suggestion: TuningSuggestion?,
         choose: @escaping (TuningPreset, Bool) -> Void) {
        self.current = current
        self.currentShifted = currentShifted
        self.suggestion = suggestion
        self.choose = choose
        _selected = State(initialValue: current)
        _shifted = State(initialValue: currentShifted)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RX.Space.l) {
                    presets
                    shiftOption
                    tuner
                }
                .padding(RX.Space.m)
            }
            .background(RX.Palette.base.ignoresSafeArea())
            .navigationTitle("Afinação")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Usar") { choose(selected, shifted && selected.playableShift != nil); dismiss() }
                        .disabled(selected == current && (shifted && selected.playableShift != nil) == currentShifted)
                }
            }
        }
        .presentationDetents([.large])
        .onDisappear { tones.stop() }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: RX.Space.xs) {
            Text("AFINAÇÃO DA MÚSICA").font(.rxHUD(10)).foregroundStyle(RX.Palette.textTertiary)
            ForEach(TuningPreset.allCases) { preset in
                Button {
                    selected = preset
                    tones.stop()
                    playing = nil
                } label: {
                    HStack(spacing: RX.Space.s) {
                        Image(systemName: selected == preset ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected == preset ? RX.Palette.fireLight : RX.Palette.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(preset.title).font(.body.weight(.semibold)).foregroundStyle(RX.Palette.textPrimary)
                                if suggestion?.preset == preset {
                                    Text("SUGERIDA").font(.rxHUD(8)).foregroundStyle(RX.Palette.magenta)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(RX.Palette.magenta.opacity(0.16)))
                                }
                                if current == preset {
                                    Text("EM USO").font(.rxHUD(8)).foregroundStyle(RX.Palette.cyan)
                                }
                            }
                            Text(preset.stringNames).font(.rxHUD(11, weight: .medium)).foregroundStyle(RX.Palette.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(RX.Space.s)
                    .background(RoundedRectangle(cornerRadius: 10).fill(selected == preset ? RX.Palette.raised : RX.Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected == preset ? RX.Palette.fireLight.opacity(0.5) : RX.Palette.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == preset ? .isSelected : [])
            }
            if let suggestion {
                Text(suggestion.reason).font(.footnote).foregroundStyle(RX.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The tuning your guitar should be in: the song's, or its standard equivalent when raising the song.
    private var guitarTuning: TuningPreset {
        shifted ? (selected.playableShift?.target ?? selected) : selected
    }

    @ViewBuilder
    private var shiftOption: some View {
        if let shift = selected.playableShift {
            VStack(alignment: .leading, spacing: RX.Space.xs) {
                Toggle(isOn: $shifted.animation(RX.Motion.touch)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tocar com a guitarra em \(shift.target.title.lowercased())")
                            .font(.body.weight(.semibold)).foregroundStyle(RX.Palette.textPrimary)
                        Text(shift.semitones == 1
                             ? "O app sobe a música meio tom, sem mudar a velocidade. Você não precisa reafinar a guitarra."
                             : "O app sobe a música um tom, sem mudar a velocidade. Você não precisa reafinar a guitarra.")
                            .font(.footnote).foregroundStyle(RX.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(RX.Palette.magenta)
                .onChange(of: shifted) { tones.stop(); playing = nil }
            }
            .padding(RX.Space.s)
            .background(RoundedRectangle(cornerRadius: 10).fill(RX.Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(shifted ? RX.Palette.magenta.opacity(0.6) : RX.Palette.hairline))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var tuner: some View {
        VStack(alignment: .leading, spacing: RX.Space.s) {
            Text("AFINAR DE OUVIDO").font(.rxHUD(10)).foregroundStyle(RX.Palette.textTertiary)
            Text("Toque numa corda: o app repete a nota certa. Toque a mesma corda na guitarra e gire a tarraxa até os dois sons ficarem iguais, sem aquele \"vai e volta\" no som.")
                .font(.footnote)
                .foregroundStyle(RX.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // From the 6th (lowest) string at the top, as you see the guitar when you look down at it.
            VStack(spacing: 0) {
                ForEach(Array(guitarTuning.openStrings.enumerated()), id: \.offset) { index, midi in
                    StringRow(number: 6 - index, midi: midi, color: NeckScene.laneColors[index],
                              thickness: CGFloat(4.2 - 0.5 * Double(index)), playing: playing == index,
                              preferFlats: guitarTuning == .halfDown) {
                        if playing == index {
                            tones.stop()
                            playing = nil
                        } else {
                            tones.play(midi)
                            playing = index
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x1A1040)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RX.Palette.hairline))
            Text("Dica: comece pela 6ª corda (a mais grossa). Afinar a guitarra desta música não muda as outras músicas.")
                .font(.caption)
                .foregroundStyle(RX.Palette.textTertiary)
        }
    }
}

private struct StringRow: View {
    let number: Int
    let midi: Int
    let color: Color
    let thickness: CGFloat
    let playing: Bool
    let preferFlats: Bool
    let action: () -> Void

    var body: some View {
        let note = MIDINote(unchecked: midi)
        let name = NoteNaming.letters.name(of: note.pitchClass, preferFlats: preferFlats)
        Button(action: action) {
            HStack(spacing: RX.Space.s) {
                Text("\(number)ª").font(.rxHUD(11)).foregroundStyle(RX.Palette.textTertiary).frame(width: 28, alignment: .leading)
                Text(name).font(.rxBig(20)).foregroundStyle(playing ? color : RX.Palette.textPrimary).frame(width: 44, alignment: .leading)
                ZStack {
                    Capsule().fill(color.opacity(playing ? 1 : 0.55)).frame(height: thickness)
                        .shadow(color: playing ? color : .clear, radius: 8)
                        .offset(y: playing ? 0 : 0)
                    if playing {
                        Capsule().fill(.white.opacity(0.7)).frame(height: max(1, thickness / 2))
                    }
                }
                Text(String(format: "%.1f Hz", note.frequency())).font(.rxHUD(10, weight: .medium).monospacedDigit())
                    .foregroundStyle(RX.Palette.textTertiary).frame(width: 62, alignment: .trailing)
                Image(systemName: playing ? "speaker.wave.2.fill" : "play.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(playing ? color : RX.Palette.textSecondary)
                    .frame(width: 24)
            }
            .padding(.horizontal, RX.Space.s)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(number)ª corda, \(name)")
        .accessibilityHint(playing ? "Toque para parar o som" : "Toque para ouvir a nota de referência")
    }
}
