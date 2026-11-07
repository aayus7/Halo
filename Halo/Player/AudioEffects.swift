import AVFoundation
import Foundation
import MediaToolbox
import os

/// Parameters the render thread reads. Written on the main thread, read under a lock on the audio thread.
final class DSPParameters: @unchecked Sendable {
    struct Values: Equatable {
        var enabled = false
        var gains: [Double] = Array(repeating: 0, count: 10)
        var preamp = 0.0
        var bassBoost = 0.0
        var width = 1.0
    }

    static let shared = DSPParameters()

    private let lock = OSAllocatedUnfairLock(initialState: (Values(), 0))

    func update(_ values: Values) {
        lock.withLock { state in
            if state.0 != values {
                state.0 = values
                state.1 += 1
            }
        }
    }

    /// Returns new values only when they changed since `version`.
    func read(ifNewerThan version: Int) -> (Values, Int)? {
        lock.withLockIfAvailable { state in state.1 != version ? (state.0, state.1) : nil } ?? nil
    }
}

/// RBJ-cookbook biquad, direct form I, per channel.
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    static func peaking(freq: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * min(freq, sampleRate * 0.45) / sampleRate
        let alpha = sin(w) / (2 * q)
        let cosw = cos(w)
        let a0 = 1 + alpha / a
        var f = Biquad()
        f.b0 = (1 + alpha * a) / a0
        f.b1 = (-2 * cosw) / a0
        f.b2 = (1 - alpha * a) / a0
        f.a1 = (-2 * cosw) / a0
        f.a2 = (1 - alpha / a) / a0
        return f
    }

    static func lowShelf(freq: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * freq / sampleRate
        let cosw = cos(w)
        let alpha = sin(w) / 2 * sqrt(2)
        let sqa = 2 * sqrt(a) * alpha
        let a0 = (a + 1) + (a - 1) * cosw + sqa
        var f = Biquad()
        f.b0 = a * ((a + 1) - (a - 1) * cosw + sqa) / a0
        f.b1 = 2 * a * ((a - 1) - (a + 1) * cosw) / a0
        f.b2 = a * ((a + 1) - (a - 1) * cosw - sqa) / a0
        f.a1 = -2 * ((a - 1) + (a + 1) * cosw) / a0
        f.a2 = ((a + 1) + (a - 1) * cosw - sqa) / a0
        return f
    }

    /// Keeps the running state when swapping coefficients, so changes don't click.
    mutating func setCoefficients(from other: Biquad) {
        b0 = other.b0; b1 = other.b1; b2 = other.b2; a1 = other.a1; a2 = other.a2
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

/// State owned by one tap. Only touched on the audio thread after prepare.
final class TapContext {
    var sampleRate = 44100.0
    var channels = 2
    var isFloat = true
    var isInterleaved = false
    var version = -1
    var values = DSPParameters.Values()
    var filters: [[Biquad]] = []   // [channel][band + bass shelf]
    var linearPreamp = 1.0
    var active = false

    func prepare(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44100
        channels = Int(format.mChannelsPerFrame)
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        version = -1
        filters = []
    }

    private func rebuild() {
        let freqs = AppSettingsDefaults.eqFrequencies
        var bank: [Biquad] = []
        for (i, f) in freqs.enumerated() {
            let g = i < values.gains.count ? values.gains[i] : 0
            bank.append(Biquad.peaking(freq: f, gainDB: g, q: 1.1, sampleRate: sampleRate))
        }
        bank.append(Biquad.lowShelf(freq: 110, gainDB: values.bassBoost, sampleRate: sampleRate))
        if filters.count == channels, filters.first?.count == bank.count {
            for c in 0..<channels { for i in 0..<bank.count { filters[c][i].setCoefficients(from: bank[i]) } }
        } else {
            filters = Array(repeating: bank, count: channels)
        }
        // Headroom: drop the preamp by the largest boost so the EQ doesn't clip.
        let maxBoost = max(0, (values.gains.max() ?? 0), values.bassBoost * 0.8)
        linearPreamp = pow(10, (values.preamp - maxBoost * 0.85) / 20)
        active = values.enabled
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        if let (v, ver) = DSPParameters.shared.read(ifNewerThan: version) {
            values = v
            version = ver
            rebuild()
        }
        guard active, isFloat, frames > 0, !filters.isEmpty else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)

        if isInterleaved {
            guard let buffer = buffers.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = max(1, Int(buffer.mNumberChannels))
            for f in 0..<frames {
                for c in 0..<min(ch, filters.count) {
                    let idx = f * ch + c
                    var x = Double(data[idx]) * linearPreamp
                    for b in 0..<filters[c].count { x = filters[c][b].process(x) }
                    data[idx] = Float(max(-1, min(1, x)))
                }
                if ch == 2, values.width != 1 { widen(&data[f * 2], &data[f * 2 + 1]) }
            }
        } else {
            for (c, buffer) in buffers.enumerated() where c < filters.count {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<frames {
                    var x = Double(data[f]) * linearPreamp
                    for b in 0..<filters[c].count { x = filters[c][b].process(x) }
                    data[f] = Float(max(-1, min(1, x)))
                }
            }
            if buffers.count == 2, values.width != 1,
               let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
               let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                for f in 0..<frames { widen(&l[f], &r[f]) }
            }
        }
    }

    @inline(__always)
    private func widen(_ l: inout Float, _ r: inout Float) {
        let mid = (l + r) * 0.5
        let side = (l - r) * 0.5 * Float(values.width)
        l = max(-1, min(1, mid + side))
        r = max(-1, min(1, mid - side))
    }
}

/// The EQ band centres, readable off the main actor.
enum AppSettingsDefaults {
    static let eqFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
}

enum AudioEffects {
    /// Attaches the DSP tap to a player item. HLS items have no audio tracks to tap and play untouched.
    static func attach(to item: AVPlayerItem) async {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
        guard let tap = makeTap() else { return }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        await MainActor.run { item.audioMix = mix }
    }

    private static func makeTap() -> MTAudioProcessingTap? {
        let context = TapContext()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: nil,
            process: tapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        if status != noErr {
            Unmanaged<TapContext>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        return tap
    }
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
    guard status == noErr else { return }
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        .process(bufferList, frames: Int(framesOut.pointee))
}
