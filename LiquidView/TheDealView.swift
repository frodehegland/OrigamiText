import SwiftUI

/// The Deal: structured serendipity. Every other view favors the recent
/// and the cited; the Deal shuffles the whole library and deals a hand of
/// cards face-up, so a forgotten document gets the same chance as
/// yesterday's. Click a card to flip it — the back is its metadata, as a
/// card back should be. Double-click to read. Drag one card onto another
/// to play a pair: the two open in parallel reading.
struct TheDealView: View {
    @Environment(AppModel.self) private var model

    private struct Dealt: Identifiable {
        let doc: LiquidDoc
        var flipped = false
        var id: String { doc.id }
    }

    @State private var hand: [Dealt] = []
    @State private var dragOffset: CGSize = .zero
    @State private var draggingID: String?

    private static let cardSize = CGSize(width: 190, height: 264)
    private static let handSize = 5

    /// The deck: the library, minus superseded and retracted versions —
    /// the Deal re-surfaces living documents, not their retired forms.
    private var deck: [LiquidDoc] {
        model.index.byID.values.map(\.doc).filter {
            !model.index.supersededIDs.contains($0.id)
                && !model.index.retractedIDs.contains($0.id)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                felt
                if deck.isEmpty {
                    ContentUnavailableView("Nothing to Deal",
                                           systemImage: "suit.club",
                                           description: Text("The Deal shuffles the community library. Choose a folder with documents and deal a hand."))
                } else {
                    ForEach(Array(hand.enumerated()), id: \.element.id) { index, dealt in
                        card(dealt, at: index, in: geometry.size)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { table }
        .navigationTitle("The Deal")
        .onAppear { if hand.isEmpty { deal() } }
    }

    // MARK: The table

    private var felt: some View {
        RadialGradient(colors: [Color(red: 0.09, green: 0.32, blue: 0.17),
                                Color(red: 0.03, green: 0.15, blue: 0.08)],
                       center: .center, startRadius: 60, endRadius: 700)
            .ignoresSafeArea()
    }

    private var table: some View {
        HStack(spacing: 14) {
            Text("\(deck.count) in the deck")
                .foregroundStyle(.white.opacity(0.55))
            Button("Deal") { deal() }
                .buttonStyle(.borderedProminent)
                .disabled(deck.isEmpty)
                .help("Shuffle the library and deal a fresh hand — every document gets an equal chance")
            Text("Click to flip · double-click to read · drag a card onto another to read the pair side by side")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.25), in: Capsule())
        .padding(.bottom, 18)
    }

    private func deal() {
        withAnimation(.spring(duration: 0.55, bounce: 0.25)) {
            hand = deck.shuffled().prefix(Self.handSize).map { Dealt(doc: $0) }
            dragOffset = .zero
            draggingID = nil
        }
    }

    // MARK: The cards

    /// The hand fans across the table: each card offset from center,
    /// tilted a little, the outer ones sitting slightly lower.
    private func position(at index: Int, in size: CGSize) -> CGPoint {
        let offset = Double(index) - Double(hand.count - 1) / 2
        return CGPoint(x: size.width / 2 + offset * Self.cardSize.width * 0.82,
                       y: size.height / 2 + abs(offset) * abs(offset) * 9)
    }

    private func tilt(at index: Int) -> Angle {
        let offset = Double(index) - Double(hand.count - 1) / 2
        return .degrees(offset * 4)
    }

    @ViewBuilder
    private func card(_ dealt: Dealt, at index: Int, in size: CGSize) -> some View {
        let isDragging = draggingID == dealt.id
        ZStack {
            face(for: dealt.doc)
                .opacity(dealt.flipped ? 0 : 1)
            back(for: dealt.doc)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(dealt.flipped ? 1 : 0)
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .rotation3DEffect(.degrees(dealt.flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .rotationEffect(isDragging ? .zero : tilt(at: index))
        .shadow(color: .black.opacity(0.45), radius: isDragging ? 16 : 7, y: 5)
        .position(position(at: index, in: size))
        .offset(isDragging ? dragOffset : .zero)
        .zIndex(isDragging ? 1 : 0)
        .onTapGesture(count: 2) { model.openInLibrary(dealt.doc) }
        .onTapGesture {
            withAnimation(.spring(duration: 0.5)) {
                if let i = hand.firstIndex(where: { $0.id == dealt.id }) {
                    hand[i].flipped.toggle()
                }
            }
        }
        .gesture(pairDrag(for: dealt, at: index, in: size))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Playing a pair: drop one card onto another and the two open side by
    /// side in parallel reading, connections visible.
    private func pairDrag(for dealt: Dealt, at index: Int, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                draggingID = dealt.id
                dragOffset = value.translation
            }
            .onEnded { value in
                defer {
                    draggingID = nil
                    dragOffset = .zero
                }
                let dropped = CGPoint(x: position(at: index, in: size).x + value.translation.width,
                                      y: position(at: index, in: size).y + value.translation.height)
                for (otherIndex, other) in hand.enumerated() where other.id != dealt.id {
                    let target = position(at: otherIndex, in: size)
                    if hypot(dropped.x - target.x, dropped.y - target.y) < Self.cardSize.width * 0.55 {
                        model.openTranspointing(from: dealt.doc, to: other.doc)
                        return
                    }
                }
            }
    }

    // MARK: Faces

    /// The suit: the document's type, in card terms. Letters are hearts
    /// (correspondence), transcripts clubs (people gathered), extracts
    /// diamonds (lifted gems), RFCs spades (digging into questions).
    private func suit(for doc: LiquidDoc) -> (symbol: String, isRed: Bool, name: String) {
        let type = doc.documentType
            ?? (TranscriptsView.isTranscript(doc)
                ? LiquidDoc.DocumentType.transcript.rawValue
                : LiquidDoc.DocumentType.letter.rawValue)
        switch LiquidDoc.DocumentType(rawValue: type) {
        case .letter: return ("suit.heart.fill", true, "Letter")
        case .transcript: return ("suit.club.fill", false, "Transcript")
        case .extract: return ("suit.diamond.fill", true, "Extract")
        case .rfc: return ("suit.spade.fill", false, "RFC")
        case .some(let known): return ("rectangle.portrait.fill", false, known.displayName)
        case nil: return ("rectangle.portrait.fill", false, type)
        }
    }

    private func face(for doc: LiquidDoc) -> some View {
        let suit = suit(for: doc)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(spacing: 1) {
                    Image(systemName: suit.symbol)
                    Text(suit.name)
                        .font(.system(size: 7, weight: .semibold))
                        .textCase(.uppercase)
                }
                Spacer()
                Text(doc.date?.yearText ?? doc.created.formatted(.dateTime.year()))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 15))
            .foregroundStyle(suit.isRed ? Color(red: 0.78, green: 0.1, blue: 0.14) : .black)
            Spacer(minLength: 8)
            Text(doc.title)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Text(doc.displayAuthor)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 3)
            Spacer(minLength: 8)
            Text(openingWords(of: doc))
                .font(.system(size: 10, design: .serif).italic())
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Spacer(minLength: 6)
            HStack {
                Spacer()
                Image(systemName: suit.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(suit.isRed ? Color(red: 0.78, green: 0.1, blue: 0.14) : .black)
                    .rotationEffect(.degrees(180))
            }
        }
        .padding(12)
        .background(cardStock)
    }

    /// The back: the card's metadata, as a card back should be — the same
    /// facts the Visual-Meta appendix carries, made the pattern itself.
    private func back(for doc: LiquidDoc) -> some View {
        let suit = suit(for: doc)
        return VStack(spacing: 5) {
            Image(systemName: suit.symbol)
                .font(.system(size: 22))
                .padding(.bottom, 4)
            metaLine("type", suit.name.lowercased())
            metaLine("author", doc.author)
            if let onBehalfOf = doc.onBehalfOf {
                metaLine("on behalf of", onBehalfOf)
            }
            metaLine("date", doc.listedDateText)
            if !doc.attention.isEmpty {
                metaLine("attention", doc.attention.joined(separator: ", "))
            }
            metaLine("links", "\(doc.links.count) out · \(model.index.backlinks[doc.id]?.count ?? 0) in")
            metaLine("address", doc.id)
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.white.opacity(0.92))
        .multilineTextAlignment(.center)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.16, green: 0.2, blue: 0.38))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                    .padding(5)
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    .padding(9)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metaLine(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .lineLimit(2)
        }
    }

    private var cardStock: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(red: 0.985, green: 0.975, blue: 0.95))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
    }

    private func openingWords(of doc: LiquidDoc) -> String {
        doc.body?
            .first { $0.effectiveHeading == nil && !$0.displayText.isEmpty }
            .map { "“\($0.displayText.prefix(140))…”" } ?? ""
    }
}

extension TheDealView {
    /// The Deal as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "the-deal",
        name: "The Deal",
        systemImage: "suit.club",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(TheDealView()) },
        hidesDocumentList: true
    )
}
