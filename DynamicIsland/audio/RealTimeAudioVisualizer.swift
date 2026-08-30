/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Selectable real-time render styles for the audio-reactive waveform,
 * analogous to cliamp's `v`-key visualizer cycle -- every style renders
 * from the same AudioTap magnitude bands, only the shape differs.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import Defaults

/// Vertical rounded bars, one per magnitude band -- the original (and still
/// default) style, matching the look of the retired CAShapeLayer-based
/// `RealTimeAudioSpectrum`.
struct BarsVisualizerShape: Shape {
    var magnitudes: [Float]

    var animatableData: AnimatableVector {
        get { AnimatableVector(values: magnitudes) }
        set { magnitudes = newValue.values }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = magnitudes.count
        guard count > 0 else { return path }

        let spacing: CGFloat = 2
        let barWidth = max(1, (rect.width - CGFloat(count - 1) * spacing) / CGFloat(count))

        for (index, magnitude) in magnitudes.enumerated() {
            let scale = max(0.2, min(1.0, CGFloat(magnitude) * 1.5 + 0.2))
            let barHeight = rect.height * scale
            let x = rect.minX + CGFloat(index) * (barWidth + spacing)
            let barRect = CGRect(x: x, y: rect.maxY - barHeight, width: barWidth, height: barHeight)
            path.addRoundedRect(in: barRect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        return path
    }
}

/// A dot per band riding atop a thin stem, like cliamp's peak-capped bars.
struct DotsVisualizerShape: Shape {
    var magnitudes: [Float]

    var animatableData: AnimatableVector {
        get { AnimatableVector(values: magnitudes) }
        set { magnitudes = newValue.values }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = magnitudes.count
        guard count > 0 else { return path }

        let spacing: CGFloat = 2
        let colWidth = max(2, (rect.width - CGFloat(count - 1) * spacing) / CGFloat(count))
        let dotDiameter = min(colWidth, 6)
        let stemWidth: CGFloat = max(1, colWidth * 0.3)

        for (index, magnitude) in magnitudes.enumerated() {
            let scale = max(0.15, min(1.0, CGFloat(magnitude) * 1.5 + 0.15))
            let stemHeight = rect.height * scale
            let centerX = rect.minX + CGFloat(index) * (colWidth + spacing) + colWidth / 2
            let dotCenterY = rect.maxY - stemHeight

            let stemRect = CGRect(x: centerX - stemWidth / 2, y: dotCenterY, width: stemWidth, height: stemHeight)
            path.addRect(stemRect)

            let dotRect = CGRect(x: centerX - dotDiameter / 2, y: dotCenterY - dotDiameter / 2, width: dotDiameter, height: dotDiameter)
            path.addEllipse(in: dotRect)
        }
        return path
    }
}

/// Bars extending symmetrically above and below a horizontal center axis.
struct MirrorVisualizerShape: Shape {
    var magnitudes: [Float]

    var animatableData: AnimatableVector {
        get { AnimatableVector(values: magnitudes) }
        set { magnitudes = newValue.values }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = magnitudes.count
        guard count > 0 else { return path }

        let spacing: CGFloat = 2
        let barWidth = max(1, (rect.width - CGFloat(count - 1) * spacing) / CGFloat(count))
        let centerY = rect.midY

        for (index, magnitude) in magnitudes.enumerated() {
            let scale = max(0.15, min(1.0, CGFloat(magnitude) * 1.5 + 0.15))
            let halfHeight = (rect.height / 2) * scale
            let x = rect.minX + CGFloat(index) * (barWidth + spacing)
            let barRect = CGRect(x: x, y: centerY - halfHeight, width: barWidth, height: halfHeight * 2)
            path.addRoundedRect(in: barRect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        return path
    }
}

/// Same bar layout as `BarsVisualizerShape` but hollow -- cliamp's
/// `BarsOutline`. Built as a stroked path rather than a filled/unfilled
/// rect pair so it still composites correctly as a `.mask {}` silhouette.
struct OutlineVisualizerShape: Shape {
    var magnitudes: [Float]

    var animatableData: AnimatableVector {
        get { AnimatableVector(values: magnitudes) }
        set { magnitudes = newValue.values }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = magnitudes.count
        guard count > 0 else { return path }

        let spacing: CGFloat = 2
        let barWidth = max(1, (rect.width - CGFloat(count - 1) * spacing) / CGFloat(count))

        for (index, magnitude) in magnitudes.enumerated() {
            let scale = max(0.2, min(1.0, CGFloat(magnitude) * 1.5 + 0.2))
            let barHeight = rect.height * scale
            let x = rect.minX + CGFloat(index) * (barWidth + spacing)
            let barRect = CGRect(x: x, y: rect.maxY - barHeight, width: barWidth, height: barHeight)
            path.addRoundedRect(in: barRect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        return path.strokedPath(StrokeStyle(lineWidth: 1.25, lineJoin: .round))
    }
}

/// Stacked LED-meter segments per band, like cliamp's `ClassicLED` --
/// distinct blocks with gaps instead of one continuous bar.
struct BlocksVisualizerShape: Shape {
    var magnitudes: [Float]

    var animatableData: AnimatableVector {
        get { AnimatableVector(values: magnitudes) }
        set { magnitudes = newValue.values }
    }

    private let segmentHeight: CGFloat = 3
    private let segmentGap: CGFloat = 1.5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = magnitudes.count
        guard count > 0 else { return path }

        let spacing: CGFloat = 2
        let barWidth = max(1, (rect.width - CGFloat(count - 1) * spacing) / CGFloat(count))
        let totalSegments = max(1, Int(rect.height / (segmentHeight + segmentGap)))

        for (index, magnitude) in magnitudes.enumerated() {
            let scale = max(0.2, min(1.0, CGFloat(magnitude) * 1.5 + 0.2))
            let litSegments = max(1, Int((scale * CGFloat(totalSegments)).rounded()))
            let x = rect.minX + CGFloat(index) * (barWidth + spacing)

            for segment in 0..<litSegments {
                let y = rect.maxY - CGFloat(segment + 1) * (segmentHeight + segmentGap) + segmentGap
                let segmentRect = CGRect(x: x, y: y, width: barWidth, height: segmentHeight)
                path.addRoundedRect(in: segmentRect, cornerSize: CGSize(width: 1, height: 1))
            }
        }
        return path
    }
}

/// Bars with a small peak-hold cap that jumps up with the signal and falls
/// slowly, like cliamp's `ClassicPeak` -- `peaks` is decayed by the caller
/// (`RealTimeAudioVisualizerView`) once per tick since a peak must persist
/// (and keep falling) across frames where the underlying magnitude has
/// already dropped, which a stateless `Shape` can't track on its own.
struct PeakVisualizerShape: Shape {
    var magnitudes: [Float]
    var peaks: [Float]

    var animatableData: AnimatableVector {
        get { AnimatableVector(values: magnitudes + peaks) }
        set {
            let half = newValue.values.count / 2
            magnitudes = Array(newValue.values[..<half])
            peaks = Array(newValue.values[half...])
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = magnitudes.count
        guard count > 0, peaks.count == count else { return path }

        let spacing: CGFloat = 2
        let barWidth = max(1, (rect.width - CGFloat(count - 1) * spacing) / CGFloat(count))
        let capHeight: CGFloat = 2

        for index in 0..<count {
            let scale = max(0.2, min(1.0, CGFloat(magnitudes[index]) * 1.5 + 0.2))
            let barHeight = rect.height * scale
            let x = rect.minX + CGFloat(index) * (barWidth + spacing)
            let barRect = CGRect(x: x, y: rect.maxY - barHeight, width: barWidth, height: barHeight)
            path.addRoundedRect(in: barRect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))

            let peakScale = max(0.2, min(1.0, CGFloat(peaks[index]) * 1.5 + 0.2))
            let peakY = rect.maxY - rect.height * peakScale
            let capRect = CGRect(x: x, y: peakY - capHeight, width: barWidth, height: capHeight)
            path.addRoundedRect(in: capRect, cornerSize: CGSize(width: 1, height: 1))
        }
        return path
    }
}

/// A continuous dotted line tracing a rolling history of overall level,
/// centered on the view's vertical middle and swinging up for louder
/// moments, down for quieter ones -- unlike the other styles (a snapshot
/// of the current magnitude bands, anchored to the bottom), this plots
/// one aggregate sample per tick over time around a center axis, closest
/// to cliamp's own scrolling, center-anchored `Wave` visualizer.
struct LineHistoryVisualizerShape: Shape {
    var history: [Float]

    var animatableData: AnimatableVector {
        get { AnimatableVector(values: history) }
        set { history = newValue.values }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = history.count
        guard count > 1 else { return path }

        let dotSize: CGFloat = 1.5
        let stepX = rect.width / CGFloat(count - 1)

        for (index, value) in history.enumerated() {
            let normalized = max(0.0, min(1.0, CGFloat(value) * 1.5))
            let offset = (normalized - 0.5) * rect.height
            let x = rect.minX + CGFloat(index) * stepX
            let y = rect.midY - offset
            let dotRect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
            path.addRoundedRect(in: dotRect, cornerSize: CGSize(width: dotSize / 2, height: dotSize / 2))
        }
        return path
    }
}

/// A scrolling ECG/pulse-monitor trace over the same rolling level history
/// as `LineHistoryVisualizerShape` -- cliamp's `Heartbeat`. Squaring the
/// (already non-negative) level sharpens loud beats into spikes while
/// flattening quiet passages toward a dashed baseline, instead of swinging
/// smoothly around a center axis.
struct HeartbeatVisualizerShape: Shape {
    var history: [Float]

    var animatableData: AnimatableVector {
        get { AnimatableVector(values: history) }
        set { history = newValue.values }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = history.count
        guard count > 1 else { return path }

        let stepX = rect.width / CGFloat(count - 1)
        let baseline = rect.maxY - 1
        let amplitude = max(0, rect.height - 2)

        // Dashed baseline the trace departs from and returns to between beats.
        var dashX = rect.minX
        while dashX < rect.maxX {
            let dashEnd = min(dashX + 4, rect.maxX)
            path.move(to: CGPoint(x: dashX, y: baseline))
            path.addLine(to: CGPoint(x: dashEnd, y: baseline))
            dashX = dashEnd + 3
        }

        for (index, value) in history.enumerated() {
            let normalized = max(0.0, min(1.0, CGFloat(value) * 1.5))
            let shaped = normalized * normalized
            let x = rect.minX + CGFloat(index) * stepX
            let y = baseline - shaped * amplitude
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        return path.strokedPath(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
    }
}

/// Renders `Defaults[.visualizerStyle]` from live `AudioTap` magnitudes,
/// replacing the retired NSView/CAShapeLayer-based `RealTimeAudioSpectrum`.
/// Used exclusively as `.mask {}` content by every caller, so styles only
/// need to fill their silhouette -- the mask's opacity is all that matters,
/// not color.
struct RealTimeAudioVisualizerView: View {
    @Binding var isPlaying: Bool
    @Default(.visualizerStyle) private var visualizerStyle

    private static let historyLength = 24

    @State private var timer: Timer?
    @State private var magnitudes: [Float] = Array(repeating: 0, count: Defaults[.visualizerBarCount])
    @State private var peakLevels: [Float] = Array(repeating: 0, count: Defaults[.visualizerBarCount])
    @State private var history: [Float] = Array(repeating: 0, count: RealTimeAudioVisualizerView.historyLength)

    var body: some View {
        visualizerShape
            .onAppear {
                if isPlaying { startTimer() }
            }
            .onDisappear {
                stopTimer()
            }
            .onChange(of: isPlaying) { _, playing in
                if playing {
                    startTimer()
                } else {
                    stopTimer()
                    resetMagnitudes()
                }
            }
    }

    @ViewBuilder
    private var visualizerShape: some View {
        switch visualizerStyle {
        case .bars:
            BarsVisualizerShape(magnitudes: magnitudes).fill(.white)
        case .wave:
            WaveformShape(magnitudes: magnitudes, minHeight: 1).fill(.white)
        case .dots:
            DotsVisualizerShape(magnitudes: magnitudes).fill(.white)
        case .mirror:
            MirrorVisualizerShape(magnitudes: magnitudes).fill(.white)
        case .line:
            LineHistoryVisualizerShape(history: history).fill(.white)
        case .outline:
            OutlineVisualizerShape(magnitudes: magnitudes).fill(.white)
        case .blocks:
            BlocksVisualizerShape(magnitudes: magnitudes).fill(.white)
        case .peak:
            PeakVisualizerShape(magnitudes: magnitudes, peaks: peakLevels).fill(.white)
        case .heartbeat:
            HeartbeatVisualizerShape(history: history).fill(.white)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            let tapMagnitudes = AudioTap.shared.getSmoothedMagnitudes()
            let barCount = Defaults[.visualizerBarCount]
            let sliced = tapMagnitudes.count >= barCount ? Array(tapMagnitudes.prefix(barCount)) : tapMagnitudes
            let level = tapMagnitudes.isEmpty ? 0 : tapMagnitudes.reduce(0, +) / Float(tapMagnitudes.count)
            // Peak caps jump up instantly with the signal but fall slowly --
            // reseed the array whenever the band count changes so a stale,
            // differently-sized array from a prior candle count never lingers.
            var decayedPeaks = peakLevels.count == sliced.count ? peakLevels : Array(repeating: 0, count: sliced.count)
            for i in sliced.indices {
                decayedPeaks[i] = max(sliced[i], decayedPeaks[i] - 0.02)
            }
            withAnimation(.linear(duration: 1.0 / 30.0)) {
                magnitudes = sliced
                peakLevels = decayedPeaks
                history.append(level)
                if history.count > Self.historyLength {
                    history.removeFirst(history.count - Self.historyLength)
                }
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func resetMagnitudes() {
        withAnimation(.easeOut(duration: 0.3)) {
            magnitudes = Array(repeating: 0, count: magnitudes.count)
            peakLevels = Array(repeating: 0, count: peakLevels.count)
            history = Array(repeating: 0, count: Self.historyLength)
        }
    }
}

#Preview {
    RealTimeAudioVisualizerView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
