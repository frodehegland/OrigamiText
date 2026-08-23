import SwiftUI
#if os(macOS)
import SceneKit
#endif

// The Sphere Weave: an experiment in seeing the library in the round.
// One element stands in the center — a keyword, a note, a person, a
// place — and around it three concentric spheres: every document on
// the inner sphere, every author on the middle, every place on the
// outer, each shell's nodes evenly spaced by a Fibonacci lattice.
// Lines run from the center to whatever it touches. Click any node to
// make it the center; drag to orbit, pinch or scroll to approach.
// Deliberately raw: the point is to experience the interactions.

/// What stands in the middle.
enum WeaveCenter: Equatable {
    case none
    case keyword(String)
    case document(String)   // document id
    case person(String)     // display name
    case place(String)      // place name
}

struct SphereWeaveView: View {
    @Environment(AppModel.self) private var state

    @State private var center: WeaveCenter = .none
    @State private var keyword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Sphere Weave")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                TextField("Center on a keyword…", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit {
                        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { center = .keyword(trimmed) }
                    }
                Text(centerCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("Click a node to center it · drag to orbit · scroll to approach")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            Divider()
            #if os(macOS)
            SphereWeaveSceneView(data: sphereData) { clickedID in
                recenter(on: clickedID)
            }
            #else
            Text("On Vision Pro the Sphere Weave is its own volume — open it from the Map's windows.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
        }
        .background(AppGreys.page)
        .onAppear {
            // Arrive centered on something: a Show-in term, the open
            // document — or, given nothing, the word the whole field
            // began with: "hypertext".
            if let payload = state.takeShowInPayload(for: "sphere-weave") {
                if let text = payload.text, !text.isEmpty {
                    keyword = text
                    center = .keyword(text)
                } else {
                    center = .document(payload.docID)
                }
            } else if case .none = center {
                if let selected = state.selectedDocID {
                    center = .document(selected)
                } else {
                    keyword = "hypertext"
                    center = .keyword("hypertext")
                }
            }
        }
    }

    private var centerCaption: String {
        switch center {
        case .none: return "Nothing centered yet."
        case .keyword(let word): return "Centered on “\(word)”"
        case .document(let id):
            return "Centered on “\(state.index.allByID[id]?.doc.title ?? id)”"
        case .person(let name): return "Centered on \(name)"
        case .place(let name): return "Centered on \(name)"
        }
    }

    private func recenter(on nodeID: String) {
        if nodeID.hasPrefix("doc:") {
            center = .document(String(nodeID.dropFirst(4)))
        } else if nodeID.hasPrefix("person:") {
            center = .person(String(nodeID.dropFirst(7)))
        } else if nodeID.hasPrefix("place:") {
            center = .place(String(nodeID.dropFirst(6)))
        }
    }

    // MARK: The shells and the threads

    /// Everything the scene needs, computed fresh from the library.
    struct SphereData: Equatable {
        struct Item: Equatable {
            let id: String      // "doc:<id>" / "person:<name>" / "place:<name>"
            let label: String
        }
        var documents: [Item] = []
        var people: [Item] = []
        var places: [Item] = []
        var centerID: String = ""
        var centerLabel: String = ""
        var connected: Set<String> = []
    }

    private var sphereData: SphereData {
        SphereData.woven(
            center: center,
            // Digests keep to their own section — the weave too.
            docs: state.index.timeline.filter { $0.doc.documentType != "digest" }
                .suffix(500).map(\.doc),
            people: state.libraryAuthorNames,
            backlinksTo: { state.index.backlinks[$0]?.map(\.fromID) ?? [] })
    }
}

extension SphereWeaveView.SphereData {
    /// Weaves the shells and threads from documents alone, so any
    /// platform holding the folder's documents can build the sphere —
    /// the Mac feeds it the library index, the Vision Pro volume the
    /// Map's folder scan.
    static func woven(center: WeaveCenter,
                      docs: [LiquidDoc],
                      people: [String],
                      backlinksTo: (String) -> [String]) -> Self {
        var data = Self()
        // The inner sphere: every document in the system now — to be
        // ordered later, as the experiment teaches us what order means.
        data.documents = docs.map {
            .init(id: "doc:\($0.id)", label: String($0.title.prefix(40)))
        }
        // The middle sphere: everyone credited as an author.
        data.people = people.map {
            .init(id: "person:\($0)", label: $0)
        }
        // The outer sphere: every place the documents carry.
        var seenPlaces = Set<String>()
        for doc in docs {
            guard let place = doc.location,
                  seenPlaces.insert(place.lowercased()).inserted else { continue }
            data.places.append(.init(id: "place:\(place)", label: place))
        }

        switch center {
        case .none:
            break
        case .keyword(let word):
            data.centerID = "kw:\(word.lowercased())"
            data.centerLabel = "“\(word)”"
            let needle = word.lowercased()
            for doc in docs
            where (doc.title + " " + doc.bodyEditingText)
                .lowercased().contains(needle) {
                data.connected.insert("doc:\(doc.id)")
            }
        case .document(let id):
            data.centerID = "doc:\(id)"
            if let doc = docs.first(where: { $0.id == id }) {
                data.centerLabel = String(doc.title.prefix(40))
                for link in doc.links { data.connected.insert("doc:\(link.to)") }
                for fromID in backlinksTo(id) {
                    data.connected.insert("doc:\(fromID)")
                }
                data.connected.insert("person:\(doc.creditedAuthor)")
                if let place = doc.location {
                    data.connected.insert("place:\(place)")
                }
            }
        case .person(let name):
            data.centerID = "person:\(name)"
            data.centerLabel = name
            for doc in docs
            where doc.creditedAuthor.caseInsensitiveCompare(name) == .orderedSame {
                data.connected.insert("doc:\(doc.id)")
                if let place = doc.location {
                    data.connected.insert("place:\(place)")
                }
            }
        case .place(let name):
            data.centerID = "place:\(name)"
            data.centerLabel = name
            for doc in docs
            where doc.location?.caseInsensitiveCompare(name) == .orderedSame {
                data.connected.insert("doc:\(doc.id)")
            }
        }
        return data
    }
}

/// Evenly spaced points on a sphere: the Fibonacci lattice. Shared by
/// the Mac scene and the visionOS volume.
enum WeaveLattice {
    static func points(count: Int, radius: Float) -> [SIMD3<Float>] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [SIMD3(0, 0, radius)] }
        let golden = Float.pi * (3 - sqrt(5))
        return (0..<count).map { index in
            let y = 1 - (Float(index) + 0.5) * 2 / Float(count)
            let ring = sqrt(max(0, 1 - y * y))
            let theta = golden * Float(index)
            return SIMD3(cos(theta) * ring, y, sin(theta) * ring) * radius
        }
    }
}

extension SphereWeaveView {
    /// The Sphere Weave as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "sphere-weave",
        name: "Sphere Weave",
        systemImage: "globe",
        makeContent: { AnyView(SphereWeaveView()) },
        makeDetail: { _ in AnyView(SphereWeaveView()) },
        hidesDocumentList: true,
        showInAppetite: .text
    )
}

#if os(macOS)

// MARK: - The scene

private struct SphereWeaveSceneView: NSViewRepresentable {
    let data: SphereWeaveView.SphereData
    let onClick: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClick: onClick) }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = NSColor(red: 235 / 255, green: 235 / 255,
                                       blue: 235 / 255, alpha: 1)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = 300
        camera.position = SCNVector3(0, 0, 34)
        view.scene?.rootNode.addChildNode(camera)
        let click = NSClickGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.clicked(_:)))
        view.addGestureRecognizer(click)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.onClick = onClick
        context.coordinator.apply(data)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onClick: (String) -> Void
        weak var view: SCNView?

        private var shellsKey = ""
        private var centerKey = ""
        private let shellsNode = SCNNode()
        private let threadsNode = SCNNode()
        private var nodesByID: [String: SCNNode] = [:]

        init(onClick: @escaping (String) -> Void) {
            self.onClick = onClick
        }

        // Shell colors: documents ink-blue within, people green between,
        // places warm at the horizon.
        private static let documentColor = NSColor(calibratedRed: 0.32, green: 0.42, blue: 0.62, alpha: 1)
        private static let personColor = NSColor(calibratedRed: 0.29, green: 0.58, blue: 0.42, alpha: 1)
        private static let placeColor = NSColor(calibratedRed: 0.74, green: 0.49, blue: 0.24, alpha: 1)

        func apply(_ data: SphereWeaveView.SphereData) {
            guard let root = view?.scene?.rootNode else { return }
            let newShellsKey = "\(data.documents.count)/\(data.people.count)/\(data.places.count)"
                + data.documents.map(\.id).joined()
            if shellsKey != newShellsKey {
                shellsKey = newShellsKey
                rebuildShells(data, under: root)
                centerKey = ""
            }
            let newCenterKey = data.centerID + data.connected.sorted().joined()
            if centerKey != newCenterKey {
                centerKey = newCenterKey
                rebuildThreads(data, under: root)
            }
        }

        /// The three shells, each node evenly spaced on its sphere by
        /// the Fibonacci lattice.
        private func rebuildShells(_ data: SphereWeaveView.SphereData, under root: SCNNode) {
            shellsNode.removeFromParentNode()
            shellsNode.childNodes.forEach { $0.removeFromParentNode() }
            nodesByID.removeAll()
            addShell(data.documents, radius: 7, dot: 0.14,
                     color: Self.documentColor, labelAll: false)
            addShell(data.people, radius: 11, dot: 0.22,
                     color: Self.personColor, labelAll: true)
            addShell(data.places, radius: 15, dot: 0.22,
                     color: Self.placeColor, labelAll: true)
            root.addChildNode(shellsNode)
        }

        private func addShell(_ items: [SphereWeaveView.SphereData.Item],
                              radius: Float, dot: CGFloat,
                              color: NSColor, labelAll: Bool) {
            let positions = WeaveLattice.points(count: items.count, radius: radius)
            for (item, position) in zip(items, positions) {
                let sphere = SCNSphere(radius: dot)
                sphere.firstMaterial?.diffuse.contents = color
                let node = SCNNode(geometry: sphere)
                node.name = item.id
                node.position = SCNVector3(position.x, position.y, position.z)
                let label = Self.labelNode(item.label, color: color)
                label.isHidden = !labelAll
                node.addChildNode(label)
                shellsNode.addChildNode(node)
                nodesByID[item.id] = node
            }
        }

        /// The center element and its threads, redrawn per centering.
        private func rebuildThreads(_ data: SphereWeaveView.SphereData, under root: SCNNode) {
            threadsNode.removeFromParentNode()
            threadsNode.childNodes.forEach { $0.removeFromParentNode() }
            // Document labels show only for what the center touches.
            for (id, node) in nodesByID where id.hasPrefix("doc:") {
                node.childNodes.first?.isHidden = !data.connected.contains(id)
            }
            guard !data.centerID.isEmpty else {
                root.addChildNode(threadsNode)
                return
            }
            // The center: a distinct dot at the origin, wearing its name.
            let sphere = SCNSphere(radius: 0.4)
            sphere.firstMaterial?.diffuse.contents = NSColor.black
            let centerNode = SCNNode(geometry: sphere)
            centerNode.name = data.centerID
            let label = Self.labelNode(data.centerLabel, color: .black, size: 1.6)
            label.isHidden = false
            centerNode.addChildNode(label)
            threadsNode.addChildNode(centerNode)
            // Threads from the center to everything it touches.
            for id in data.connected {
                guard let target = nodesByID[id] else { continue }
                threadsNode.addChildNode(
                    Self.lineNode(to: target.position,
                                  color: NSColor.black.withAlphaComponent(0.35)))
            }
            root.addChildNode(threadsNode)
        }

        @objc func clicked(_ recognizer: NSClickGestureRecognizer) {
            guard let view else { return }
            let point = recognizer.location(in: view)
            let hits = view.hitTest(point, options: [.boundingBoxOnly: true])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let candidate = node {
                    if let name = candidate.name, name.contains(":") {
                        onClick(name)
                        return
                    }
                    node = candidate.parent
                }
            }
        }

        // MARK: Geometry helpers

        /// A billboarded name beside a dot.
        static func labelNode(_ text: String, color: NSColor,
                              size: CGFloat = 1.0) -> SCNNode {
            let scnText = SCNText(string: text, extrusionDepth: 0)
            scnText.font = NSFont.systemFont(ofSize: size, weight: .medium)
            scnText.flatness = 0.2
            scnText.firstMaterial?.diffuse.contents = color
            scnText.firstMaterial?.isDoubleSided = true
            let node = SCNNode(geometry: scnText)
            node.scale = SCNVector3(0.5, 0.5, 0.5)
            node.position = SCNVector3(0.3, 0.15, 0)
            node.constraints = [SCNBillboardConstraint()]
            return node
        }

        /// A thin thread from the origin to a point.
        static func lineNode(to end: SCNVector3, color: NSColor) -> SCNNode {
            let vertices = [SCNVector3(0, 0, 0), end]
            let source = SCNGeometrySource(vertices: vertices)
            let indices: [Int32] = [0, 1]
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            geometry.firstMaterial?.diffuse.contents = color
            geometry.firstMaterial?.lightingModel = .constant
            return SCNNode(geometry: geometry)
        }
    }
}
#endif
