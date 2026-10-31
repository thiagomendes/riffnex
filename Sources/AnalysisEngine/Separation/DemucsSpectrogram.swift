import Accelerate
import Foundation

/// The STFT and inverse STFT exactly as HTDemucs computes them (`HTDemucs._spec` / `_ispec`,
/// which wrap `torch.stft`/`torch.istft` with `normalized=True`, a periodic Hann window, and
/// Demucs' own reflect padding). The Core ML model contains only the network; these two
/// transforms run here, with vDSP.
///
/// For a signal of N samples, hop H = nfft / 4 and `le = ceil(N / H)` frames: frame j covers the
/// original samples `[j·H − 1.5·H, j·H − 1.5·H + nfft)`, with reflect padding outside the signal,
/// and keeps bins `0 ..< nfft/2` (the Nyquist bin is dropped).
final class DemucsSpectrogram: @unchecked Sendable {
    let nfft: Int
    let hop: Int
    let bins: Int
    private let window: [Float]
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    /// Factor that turns vDSP's inverse real DFT of a *true* spectrum into the time signal. vDSP's
    /// scaling conventions differ between routines, so it is measured once instead of assumed.
    private let inverseScale: Float

    init(nfft: Int = 4096) {
        self.nfft = nfft
        hop = nfft / 4
        bins = nfft / 2
        // torch.hann_window(n) is periodic: 0.5 − 0.5·cos(2πk/n).
        window = (0..<nfft).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(nfft)) }
        forwardSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nfft), .FORWARD)!
        inverseSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nfft), .INVERSE)!
        inverseScale = Self.calibrate(forward: forwardSetup, inverse: inverseSetup, n: nfft)
    }

    /// Runs forward then inverse on a known signal. The forward output is 2·DFT (verified against
    /// torch in the tests), so feeding the inverse a true spectrum X gives (roundTrip / 2)·x;
    /// the returned factor maps that back to x.
    private static func calibrate(forward: vDSP_DFT_Setup, inverse: vDSP_DFT_Setup, n: Int) -> Float {
        let half = n / 2
        let signal = (0..<n).map { i -> Float in
            let t = Float(i)
            return sin(t * 0.013) + 0.5 * cos(t * 0.37 + 1) + 0.25 * sin(t * 1.9)
        }
        let even = (0..<half).map { signal[2 * $0] }
        let odd = (0..<half).map { signal[2 * $0 + 1] }
        var fr = [Float](repeating: 0, count: half)
        var fi = [Float](repeating: 0, count: half)
        vDSP_DFT_Execute(forward, even, odd, &fr, &fi)
        var be = [Float](repeating: 0, count: half)
        var bo = [Float](repeating: 0, count: half)
        vDSP_DFT_Execute(inverse, fr, fi, &be, &bo)
        var dot: Float = 0
        var norm: Float = 0
        for k in 0..<half {
            dot += be[k] * even[k] + bo[k] * odd[k]
            norm += even[k] * even[k] + odd[k] * odd[k]
        }
        let roundTrip = dot / max(norm, 1e-12) // 2N for vDSP's documented real-DFT conventions
        return 2 / roundTrip
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    func frameCount(forSamples n: Int) -> Int { (n + hop - 1) / hop }

    /// Index into `signal` for a possibly out-of-range position, with torch "reflect" padding.
    @inline(__always) static func reflect(_ i: Int, _ n: Int) -> Int {
        guard n > 1 else { return 0 }
        var index = i
        let period = 2 * (n - 1)
        index %= period
        if index < 0 { index += period }
        return index < n ? index : period - index
    }

    /// Forward transform of one channel. Writes `real[f * frames + t]`, `imag[f * frames + t]`
    /// (frequency-major, like the model's `[F, T]` planes).
    func forward(_ signal: UnsafeBufferPointer<Float>, frames: Int, real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>) {
        let n = signal.count
        let half = nfft / 2
        let scale = 0.5 / sqrt(Float(nfft)) // vDSP real DFT returns 2·X; torch normalized=True divides by √nfft
        var even = [Float](repeating: 0, count: half)
        var odd = [Float](repeating: 0, count: half)
        var outR = [Float](repeating: 0, count: half)
        var outI = [Float](repeating: 0, count: half)
        for t in 0..<frames {
            let start = t * hop - hop / 2 * 3
            for k in 0..<half {
                let i0 = start + 2 * k
                let i1 = i0 + 1
                let s0 = (i0 >= 0 && i0 < n) ? signal[i0] : signal[Self.reflect(i0, n)]
                let s1 = (i1 >= 0 && i1 < n) ? signal[i1] : signal[Self.reflect(i1, n)]
                even[k] = s0 * window[2 * k]
                odd[k] = s1 * window[2 * k + 1]
            }
            vDSP_DFT_Execute(forwardSetup, even, odd, &outR, &outI)
            // Packed output: outR[0] = DC, outI[0] = Nyquist (dropped), bins 1..<half in outR/outI.
            real[t] = outR[0] * scale
            imag[t] = 0
            for f in 1..<half {
                real[f * frames + t] = outR[f] * scale
                imag[f * frames + t] = outI[f] * scale
            }
        }
    }

    /// Inverse transform of one channel's `[bins, frames]` spectrogram back to `length` samples.
    func inverse(real: UnsafePointer<Float>, imag: UnsafePointer<Float>, frames: Int, length: Int,
                 into output: UnsafeMutablePointer<Float>) {
        let half = nfft / 2
        let pad = hop / 2 * 3
        // Overlap-add buffer of torch.istft for frames + 4 frames (two zero frames on each side).
        let total = (frames + 3) * hop + nfft
        var accum = [Float](repeating: 0, count: total)
        var envelope = [Float](repeating: 0, count: total)
        var inR = [Float](repeating: 0, count: half)
        var inI = [Float](repeating: 0, count: half)
        var outEven = [Float](repeating: 0, count: half)
        var outOdd = [Float](repeating: 0, count: half)
        // istft(normalized=True) multiplies the spectrum by √nfft before the inverse DFT.
        let scale = sqrt(Float(nfft)) * inverseScale
        let squared = window.map { $0 * $0 }

        for frame in 0..<(frames + 4) {
            let base = frame * hop
            for k in 0..<nfft { envelope[base + k] += squared[k] }
            let t = frame - 2
            guard t >= 0, t < frames else { continue } // the two padded frames on each side are zero
            inR[0] = real[t] // DC
            inI[0] = 0       // Nyquist, set to zero like Demucs' F.pad
            for f in 1..<half {
                inR[f] = real[f * frames + t]
                inI[f] = imag[f * frames + t]
            }
            vDSP_DFT_Execute(inverseSetup, inR, inI, &outEven, &outOdd)
            for k in 0..<half {
                accum[base + 2 * k] += outEven[k] * scale * window[2 * k]
                accum[base + 2 * k + 1] += outOdd[k] * scale * window[2 * k + 1]
            }
        }
        // istft(center=True) drops nfft/2 samples, then Demucs drops `pad` more: output sample i is
        // overlap-add buffer index i + pad + nfft/2 (frame t + 2 starts at buffer index (t + 2)·hop).
        for i in 0..<length {
            let p = i + pad + nfft / 2
            guard p < total else { output[i] = 0; continue }
            let e = envelope[p]
            output[i] = e > 1e-11 ? accum[p] / e : 0
        }
    }
}
