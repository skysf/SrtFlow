import Foundation

// MARK: - K 加权（BS.1770-4，48 kHz 的系数；纯值）
//
// 管什么：一个声道的 K 加权滤波器（前置高架 + 高通，两个二阶节），量响度之前先过它。系数是标准里表 1、表 2 给的
// 48 kHz 常数，只认 48 kHz。
// 用在哪：成片的整段响度（ExportLoudnessMeter）和合成音效的最大瞬时响度（SoundEffectBuffer.maxMomentaryLoudness）——
// 同一套系数只写在这一处。
// 不管什么：分块、门限、算 LUFS（各自的表自己做）。

struct AudioKWeighting {
    static let sampleRate = 48_000
    /// BS.1770 的偏置：让 1 kHz 满幅正弦在一个声道里读出 −3.01 LKFS。
    static let offsetLU = -0.691

    private var shelf = Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                               a1: -1.69065929318241, a2: 0.73248077421585)
    private var highpass = Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)

    init() {}

    mutating func process(_ x: Double) -> Double { highpass.process(shelf.process(x)) }

    /// 直接给系数的二阶节（转置直接 II 型）。
    private struct Biquad {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        private var z1 = 0.0, z2 = 0.0

        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
}
