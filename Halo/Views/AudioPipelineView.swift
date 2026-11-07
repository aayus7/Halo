import AVFoundation
import SwiftUI

/// "Lossless" / "Hi-Res Lossless" / "AAC" label for what's playing.
enum QualityBadge {
    static let losslessCodecs: Set<String> = ["flac", "alac", "wav", "aiff", "aif", "pcm", "caf"]

    static func codec(stream: StreamInfo?, track: Track?) -> String? {
        if let c = stream?.codec?.lowercased(), !c.isEmpty { return c }
        if case .local(let file) = track?.source { return (file as NSString).pathExtension.lowercased() }
        if let ext = stream?.url.pathExtension.lowercased(), !ext.isEmpty, ext.count <= 4 { return ext }
        return nil
    }

    static func label(stream: StreamInfo?, track: Track?) -> String? {
        guard let codec = codec(stream: stream, track: track) else { return stream?.quality }
        if losslessCodecs.contains(codec) {
            let hiRes = (stream?.bitDepth ?? 16) > 16 || (stream?.sampleRate ?? 44100) > 48000
            return hiRes ? "Hi-Res Lossless" : "Lossless"
        }
        switch codec {
        case "mp4", "m4a", "aac", "he-aac": return "AAC"
        case "eac3_joc", "eac3", "ec-3": return "Dolby Atmos"
        default: return codec.uppercased()
        }
    }
}

struct QualityBadgeButton: View {
    @Environment(PlayerEngine.self) private var player
    @State private var showPipeline = false

    var body: some View {
        if let label = QualityBadge.label(stream: player.currentStream, track: player.playingAs ?? player.currentTrack) {
            Button { showPipeline = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: label.contains("Lossless") ? "headphones" : "waveform")
                        .font(.system(size: 12, weight: .bold))
                    Text(label).font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showPipeline) { AudioPipelineView() }
        }
    }
}

/// The live signal path, decoder to output.
struct AudioPipelineView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let stats = DSPStats.shared.snapshot
                let session = AVAudioSession.sharedInstance()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        stage("Track Info", icon: "doc", rows: trackRows(stats))
                        stage("Decoder", icon: "cpu", rows: [
                            ("Decoder", "AudioToolbox · \(codecName)"),
                            ("Format", formatLine(stats)),
                        ])
                        stage("Resampler", icon: "slider.horizontal.3", rows: resamplerRows(stats, session))
                        stage("DSP", icon: "waveform", rows: dspRows(stats))
                        stage("Output", icon: "hifispeaker", rows: outputRows(session), last: true)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("Audio Pipeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Audio Pipeline").font(.headline)
                        Text("Live signal path, decoder to output").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Rows

    private var stream: StreamInfo? { player.currentStream }
    private var track: Track? { player.playingAs ?? player.currentTrack }

    private var codecName: String {
        QualityBadge.codec(stream: stream, track: track)?.uppercased() ?? "—"
    }

    private func trackRows(_ stats: DSPStats.Snapshot) -> [(String, String)] {
        let rate = stream?.sampleRate ?? (stats.sampleRate > 0 ? stats.sampleRate : nil)
        let channels = stats.channels > 0 ? stats.channels : 2
        var bitrate = "—"
        if let codec = QualityBadge.codec(stream: stream, track: track), QualityBadge.losslessCodecs.contains(codec),
           let r = rate {
            bitrate = "\(Int(r * Double(stream?.bitDepth ?? 16) * Double(channels) / 1000)) kbps"
        } else if let b = player.accessLogBitrate {
            bitrate = "\(Int(b / 1000)) kbps"
        }
        return [
            ("Source", player.sourceName),
            ("Format", codecName),
            ("Bit Depth", stream?.bitDepth.map { "\($0)-bit" } ?? "—"),
            ("Sample Rate", rate.map { "\(Int($0)) Hz" } ?? "—"),
            ("Bitrate", bitrate),
            ("Channels", channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels) ch"),
        ]
    }

    private func formatLine(_ s: DSPStats.Snapshot) -> String {
        guard s.sampleRate > 0 else { return "—" }
        let sample = s.isFloat ? "Float\(s.bitsPerChannel)" : "Int\(s.bitsPerChannel)"
        return "\(Int(s.sampleRate)) Hz · \(s.channels) ch · \(sample) \(s.interleaved ? "interleaved" : "non-interleaved")"
    }

    private func resamplerRows(_ s: DSPStats.Snapshot, _ session: AVAudioSession) -> [(String, String)] {
        let input = s.sampleRate > 0 ? s.sampleRate : (stream?.sampleRate ?? 0)
        let output = session.sampleRate
        let same = input == 0 || abs(input - output) < 1
        return [
            ("I/O Rate", input > 0 ? "\(Int(input)) Hz → \(Int(output)) Hz" : "—"),
            ("Type", same ? "None" : "System (AudioConverter)"),
            ("Quality", same ? "Passthrough" : "Mastering"),
        ]
    }

    private func dspRows(_ s: DSPStats.Snapshot) -> [(String, String)] {
        let live = Date().timeIntervalSinceReferenceDate - s.updatedAt < 2
        let preset: String
        if !settings.eqEnabled {
            preset = "Off"
        } else {
            preset = EQPreset.all.first { $0.gains == settings.eqGains }?.name ?? "Custom"
        }
        return [
            ("PCM Format", s.sampleRate > 0 ? "\(s.isFloat ? "Float\(s.bitsPerChannel)" : "Int\(s.bitsPerChannel)") \(s.interleaved ? "interleaved" : "non-interleaved")" : "—"),
            ("Sample Rate", s.sampleRate > 0 ? "\(Int(s.sampleRate)) Hz" : "—"),
            ("Gain", String(format: "%+.1f dB", s.gainDB)),
            ("Level (RMS)", live ? String(format: "%.1f dBFS", s.rmsDB) : "—"),
            ("Peak", live ? String(format: "%.1f dBFS", s.peakDB) : "—"),
            ("EQ Preset", preset),
            ("Bass Boost", settings.eqEnabled && settings.bassBoost > 0 ? String(format: "+%.1f dB", settings.bassBoost) : "Off"),
            ("Stereo Expand", "\(Int((settings.eqEnabled ? settings.stereoWidth : 1) * 100))%"),
            ("Speed", String(format: "%g×", settings.speed) + (settings.speed != 1 ? (settings.keepPitch ? " · pitch kept" : " · varispeed") : "")),
            ("Path", s.processing ? "Halo DSP" : (stream?.url.pathExtension == "m3u8" ? "Bypassed (HLS)" : "Bit-transparent")),
        ]
    }

    private func outputRows(_ session: AVAudioSession) -> [(String, String)] {
        let port = session.currentRoute.outputs.first
        return [
            ("Device", port?.portName ?? "—"),
            ("Type", port.map { Self.portType($0.portType) } ?? "—"),
            ("Sample Rate", "\(Int(session.sampleRate)) Hz"),
            ("Channels", "\(session.outputNumberOfChannels)"),
            ("Buffer", String(format: "%.1f ms", session.ioBufferDuration * 1000)),
            ("Latency", String(format: "%.1f ms", session.outputLatency * 1000)),
        ]
    }

    private static func portType(_ t: AVAudioSession.Port) -> String {
        switch t {
        case .builtInSpeaker: return "Speaker"
        case .builtInReceiver: return "Receiver"
        case .headphones: return "Wired headphones"
        case .bluetoothA2DP: return "Bluetooth (A2DP)"
        case .bluetoothLE: return "Bluetooth LE"
        case .bluetoothHFP: return "Bluetooth (HFP)"
        case .airPlay: return "AirPlay"
        case .usbAudio: return "USB audio"
        case .carAudio: return "CarPlay"
        case .HDMI: return "HDMI"
        default: return t.rawValue
        }
    }

    // MARK: Layout

    private func stage(_ title: String, icon: String, rows: [(String, String)], last: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                if !last {
                    Rectangle().fill(Color.white.opacity(0.25)).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.title3.weight(.bold)).padding(.top, 3)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(row.1).multilineTextAlignment(.trailing)
                    }
                    .font(.callout)
                }
            }
            .padding(.bottom, 22)
        }
    }
}
