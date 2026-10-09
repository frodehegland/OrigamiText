import SwiftUI
import CoreMotion

/// What the reader shows while a book is still arriving: its title, author
/// and date as words floating in space. They fly in from the distance and
/// settle into the title; a touch pushes the nearby words aside and a shake
/// scatters them all, and either way they drift home again. Over a slow
/// network that can be several seconds, so it is something to play with
/// rather than a spinner to wait on.
struct LoadingTitleView: View {
    let title: String
    let author: String
    let date: String?
    /// Starts with the title already composed — for previews, which show
    /// only a first frame.
    var assembled = false

    @State private var field = TypeField()
    @State private var motion = ShakeDetector()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            stillTitle
        } else {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    field.startsAssembled = assembled
                    field.advance(to: timeline.date, in: size,
                                  pieces: pieces, shake: motion.takeShake())
                    field.draw(in: &context)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { field.touch = $0.location }
                    .onEnded { _ in field.touch = nil }
            )
            .onAppear { motion.start() }
            .onDisappear { motion.stop() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    /// The same words, standing still, for Reduce Motion.
    private var stillTitle: some View {
        VStack(spacing: 12) {
            Text(title).font(.system(.title, design: .serif, weight: .semibold))
            Text(author).font(.system(.body, design: .serif))
            if let date { Text(date).font(.system(.callout, design: .serif)).foregroundStyle(.secondary) }
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        "Opening \(title) by \(author)"
    }

    /// Each line of the title page as words in their own style.
    private var pieces: [TypeField.Line] {
        var lines = [TypeField.Line(text: title, size: 30, weight: .semibold, ink: 1)]
        if !author.isEmpty { lines.append(.init(text: author, size: 19, weight: .regular, ink: 0.85)) }
        if let date, !date.isEmpty { lines.append(.init(text: date, size: 15, weight: .regular, ink: 0.6)) }
        return lines
    }
}

/// The words and their physics: each has a home in the composed title, a
/// place, a velocity and a depth. Springs pull them home; touch and shake
/// push them away. A class, so the canvas can step it every frame without
/// asking SwiftUI to re-render anything else.
@MainActor
final class TypeField {
    struct Line {
        let text: String
        let size: CGFloat
        let weight: UIFont.Weight
        let ink: Double
    }

    private struct Word {
        let text: String
        let size: CGFloat
        let weight: UIFont.Weight
        let ink: Double
        var home: CGPoint
        var position: CGPoint
        var velocity: CGVector
        /// 1 is the page; larger is nearer the reader, smaller farther away.
        var depth: CGFloat
        var depthVelocity: CGFloat
        /// Each word breathes on its own phase, so the title is never still.
        let phase: Double
    }

    var touch: CGPoint?
    var startsAssembled = false
    private var words: [Word] = []
    private var layoutKey = ""
    private var lastTime: Date?
    private var start = Date()

    func advance(to now: Date, in size: CGSize, pieces: [Line], shake: Double) {
        let key = "\(Int(size.width))x\(Int(size.height))|" + pieces.map(\.text).joined(separator: "|")
        if key != layoutKey {
            compose(pieces, in: size, keepingPlaces: !words.isEmpty)
            layoutKey = key
        }
        let dt = min(now.timeIntervalSince(lastTime ?? now), 1.0 / 30)
        lastTime = now
        guard dt > 0 else { return }
        let elapsed = now.timeIntervalSince(start)

        if shake > 0 {
            for index in words.indices {
                let angle = Double.random(in: 0..<(2 * .pi))
                let speed = CGFloat(380 + 900 * min(shake, 3)) * CGFloat.random(in: 0.5...1)
                words[index].velocity.dx += cos(angle) * speed
                words[index].velocity.dy += sin(angle) * speed
                words[index].depthVelocity += CGFloat.random(in: -2.2...2.2) * CGFloat(min(shake, 3))
            }
        }

        let stiffness: CGFloat = 9, damping: CGFloat = 4.2
        for index in words.indices {
            var word = words[index]
            // Home, breathing a little around it.
            let breath = CGPoint(x: word.home.x + 3 * CGFloat(sin(elapsed * 0.9 + word.phase)),
                                 y: word.home.y + 4 * CGFloat(cos(elapsed * 0.7 + word.phase * 1.3)))
            var ax = (breath.x - word.position.x) * stiffness - word.velocity.dx * damping
            var ay = (breath.y - word.position.y) * stiffness - word.velocity.dy * damping
            // A finger pushes the words near it out of the way.
            if let touch {
                let dx = word.position.x - touch.x, dy = word.position.y - touch.y
                let distance = max(sqrt(dx * dx + dy * dy), 8)
                let reach: CGFloat = 140
                if distance < reach {
                    let push = (1 - distance / reach) * 5200
                    ax += dx / distance * push
                    ay += dy / distance * push
                }
            }
            word.velocity.dx += ax * dt
            word.velocity.dy += ay * dt
            word.position.x += word.velocity.dx * dt
            word.position.y += word.velocity.dy * dt
            let homeDepth = 1 + 0.04 * CGFloat(sin(elapsed * 0.8 + word.phase))
            word.depthVelocity += ((homeDepth - word.depth) * 6 - word.depthVelocity * 3.2) * dt
            word.depth = min(max(word.depth + word.depthVelocity * dt, 0.15), 2.6)
            words[index] = word
        }
    }

    func draw(in context: inout GraphicsContext) {
        // Far words first, so near ones pass in front of them.
        for word in words.sorted(by: { $0.depth < $1.depth }) {
            let font = Font.system(size: word.size, weight: Font.Weight(word.weight), design: .serif)
            let opacity = word.ink * Double(min(max(0.25 + 0.75 * word.depth, 0.15), 1))
            let text = context.resolve(Text(word.text).font(font).foregroundStyle(.primary.opacity(opacity)))
            var layer = context
            layer.translateBy(x: word.position.x, y: word.position.y)
            layer.scaleBy(x: word.depth, y: word.depth)
            layer.draw(text, at: .zero, anchor: .center)
        }
    }

    /// The face the canvas draws a line in, for measuring it.
    private static func serif(_ line: Line) -> UIFont {
        let font = UIFont.systemFont(ofSize: line.size, weight: line.weight)
        return font.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: line.size) } ?? font
    }

    /// Lays the lines out as a centred title page and gives every word its
    /// home. On first composition the words start scattered far away, so
    /// the title assembles itself out of the distance.
    private func compose(_ lines: [Line], in size: CGSize, keepingPlaces: Bool) {
        let maxWidth = max(size.width - 56, 120)
        var rows: [[(text: String, width: CGFloat, line: Line)]] = []
        var rowHeights: [CGFloat] = []
        for line in lines {
            let serif = Self.serif(line)
            let space = (" " as NSString).size(withAttributes: [.font: serif]).width
            var row: [(String, CGFloat, Line)] = []
            var rowWidth: CGFloat = 0
            for token in line.text.split(separator: " ").map(String.init) {
                let width = (token as NSString).size(withAttributes: [.font: serif]).width
                if !row.isEmpty, rowWidth + space + width > maxWidth {
                    rows.append(row.map { (text: $0.0, width: $0.1, line: $0.2) })
                    rowHeights.append(line.size * 1.3)
                    row = []; rowWidth = 0
                }
                rowWidth += (row.isEmpty ? 0 : space) + width
                row.append((token, width, line))
            }
            if !row.isEmpty {
                rows.append(row.map { (text: $0.0, width: $0.1, line: $0.2) })
                rowHeights.append(line.size * 1.3)
            }
            // A little air between title, author and date.
            rowHeights[rowHeights.count - 1] += line.size * 0.5
        }
        let totalHeight = rowHeights.reduce(0, +)
        var y = (size.height - totalHeight) / 2
        var homes: [(String, CGPoint, Line)] = []
        for (row, height) in zip(rows, rowHeights) {
            let space = (" " as NSString).size(withAttributes: [.font: Self.serif(row[0].line)]).width
            let width = row.map(\.width).reduce(0, +) + space * CGFloat(row.count - 1)
            var x = (size.width - width) / 2
            for item in row {
                homes.append((item.text, CGPoint(x: x + item.width / 2, y: y + item.line.size * 0.65), item.line))
                x += item.width + space
            }
            y += height
        }
        let previous = words
        words = homes.enumerated().map { index, entry in
            let (text, home, line) = entry
            if keepingPlaces, index < previous.count {
                var word = previous[index]
                word = Word(text: text, size: line.size, weight: line.weight, ink: line.ink, home: home,
                            position: word.position, velocity: word.velocity,
                            depth: word.depth, depthVelocity: word.depthVelocity, phase: word.phase)
                return word
            }
            let angle = Double.random(in: 0..<(2 * .pi))
            let reach = max(size.width, size.height) * CGFloat.random(in: 0.4...0.8)
            return Word(text: text, size: line.size, weight: line.weight, ink: line.ink, home: home,
                        position: startsAssembled ? home
                            : CGPoint(x: size.width / 2 + cos(angle) * reach,
                                      y: size.height / 2 + sin(angle) * reach),
                        velocity: .zero,
                        depth: startsAssembled ? 1 : CGFloat.random(in: 0.15...0.4), depthVelocity: 0,
                        phase: Double.random(in: 0..<(2 * .pi)))
        }
        start = Date()
    }
}

private extension Font.Weight {
    init(_ weight: UIFont.Weight) {
        switch weight {
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .medium: self = .medium
        default: self = .regular
        }
    }
}

/// Reads the accelerometer and reports a shake as a strength, once. The
/// raw accelerometer needs no permission prompt.
@MainActor
final class ShakeDetector {
    private let manager = CMMotionManager()
    private var pending: Double = 0
    private var lastShake = Date.distantPast

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let acceleration = motion?.userAcceleration else { return }
            let strength = sqrt(acceleration.x * acceleration.x
                                + acceleration.y * acceleration.y
                                + acceleration.z * acceleration.z)
            // A deliberate shake, not a hand settling the phone; and not
            // every sample of one shake.
            if strength > 1.3, Date().timeIntervalSince(self.lastShake) > 0.35 {
                self.lastShake = Date()
                self.pending = max(self.pending, strength)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// The shake since the last frame, if any — consumed on reading.
    func takeShake() -> Double {
        defer { pending = 0 }
        return pending
    }
}

#Preview("Loading a book") {
    LoadingTitleView(title: "Linked Locative Ludonarrative and Heritage Hypertext Harmonies",
                     author: "Bob Rimington, Jack Brett, Charlie Hargood",
                     date: "14 September 2026", assembled: true)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
}
