import SwiftUI

@MainActor
struct ScrollingDanmuView: View {
    @ObservedObject var danmu: ClassroomDanmu
    let topInset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flights: [Flight] = []

    private struct Flight {
        let text: String
        let start: Date
        let lane: Int
    }

    private let duration: TimeInterval = 7
    private let lineHeight: CGFloat = 24
    private let maximumLanes = 4

    var body: some View {
        GeometryReader { bounds in
            let lanes = min(maximumLanes, max(0, Int((bounds.size.height / 3 - topInset) / lineHeight)))
            let latest = danmu.messages.last
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || flights.isEmpty)) { timeline in
                Canvas { context, size in
                    for flight in flights where flight.lane < lanes {
                        let progress = timeline.date.timeIntervalSince(flight.start) / duration
                        guard (0..<1).contains(progress) else { continue }
                        let text = Text(flight.text).font(.system(size: 16, weight: .semibold))
                        let foreground = context.resolve(text.foregroundColor(.white))
                        let outline = context.resolve(text.foregroundColor(.black.opacity(0.85)))
                        let width = foreground.measure(in: CGSize(width: 10_000, height: lineHeight)).width
                        let x = size.width - (size.width + width) * CGFloat(progress)
                        let y = topInset + (CGFloat(flight.lane) + 0.5) * lineHeight
                        for offset in [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1)] {
                            context.draw(outline, at: CGPoint(x: x + offset.x, y: y + offset.y), anchor: .leading)
                        }
                        context.draw(foreground, at: CGPoint(x: x, y: y), anchor: .leading)
                    }
                }
            }
            .clipped()
            .onChange(of: latest?.id) { _, _ in
                guard let latest else { flights.removeAll(); return }
                guard !reduceMotion else { return }
                let now = Date()
                flights.removeAll { now.timeIntervalSince($0.start) >= duration }
                guard let lane = (0..<lanes).first(where: { lane in
                    !flights.contains { $0.lane == lane }
                }) else { return }
                let text = latest.text.split(whereSeparator: \.isNewline).joined(separator: " ")
                flights.append(Flight(text: String(text.prefix(80)), start: now, lane: lane))
            }
            .onChange(of: reduceMotion) { _, _ in flights.removeAll() }
            .task(id: flights.last?.start) {
                guard !flights.isEmpty else { return }
                do {
                    try await Task.sleep(for: .seconds(duration))
                    flights.removeAll()
                } catch {}
            }
        }
    }
}
