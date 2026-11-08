import Testing
import Foundation
@testable import Origami_Text

/// The XR colour guard (CONCEPT-COLOURS-IN-XR-PLAN.md, section 4): no XR
/// colour may sit near a concept colour unless a plan step already owns it.
struct XRColourRolesTests {

    @Test func noUnplannedClashWithTheDefaults() {
        let unplanned = XRColourRoles.unplannedClashes()
        #expect(unplanned.isEmpty, "\(unplanned.map(\.description).joined(separator: "\n"))")
    }

    @Test func distancesMatchThePlan() {
        func d(_ a: UInt32, _ kind: ConceptKind) -> Double {
            XRColour(hex: a).distance(to: kind.defaultColour)
        }
        #expect(abs(d(0xFFCC00, .event) - 1.7) < 0.1)       // Find yellow
        #expect(abs(d(0x17938B, .location) - 18.5) < 0.1)   // teal
        #expect(abs(d(0xFF47AE, .artifact) - 18.8) < 0.2)   // rose's nearest
        #expect(abs(XRColour(hex: 0xFF47AE).distance(to: XRColour(hex: 0xD12929)) - 19.3) < 0.1)
    }

    @Test func aWritersCollidingColourIsWarnedNotSwapped() {
        let tealLocation = ConceptKind.defaults.merging([.location: XRColour(hex: 0x2E9090)]) { $1 }
        #expect(XRColourRoles.note(forAnnotation: "Quotable", hex: "2E8B8B", concepts: tealLocation)
                == "Quotable is close to your Location colour.")
        #expect(XRColourRoles.note(forAnnotation: "Quotable", hex: "2E8B8B") == nil)
    }

    @Test func productReadsAsArtifact() {
        #expect(ConceptKind(fileKey: "product") == .artifact)
        #expect(ConceptKind(fileKey: "Person") == .person)
    }
}
