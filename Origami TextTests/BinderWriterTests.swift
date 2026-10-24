import Testing
import Foundation
@testable import Origami_Text

/// The binder (Origami Binding Profile §5): works lifted out of shelved
/// books by their collection declarations, written as one new EPUB.
struct BinderWriterTests {

    /// A small unpacked book of two works, as Author writes one.
    private func makeBook(at root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("content/images"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="package.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: root.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="en" prefix="origami: https://example/#">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="pub-id">urn:isbn:9798241902979</dc:identifier>
        <dc:title>The Future of Text Vol VI</dc:title>
        <dc:language>en</dc:language>
        <dc:creator id="compiler1">Frode Alexander Hegland</dc:creator>
        <dc:date>2025-12-01</dc:date>
        <meta property="origami:binding">book</meta>
        <meta property="dcterms:isVersionOf">urn:uuid:book-work</meta>
        <link rel="record" href="visual-meta.json" media-type="application/json" properties="origami:visual-meta"/>
        </metadata>
        <manifest>
        <item id="cover" href="content/cover.html" media-type="application/xhtml+xml"/>
        <item id="paper" href="content/paper.html" media-type="application/xhtml+xml"/>
        <item id="section1" href="content/work-1-authoring-for-ai.html" media-type="application/xhtml+xml"/>
        <item id="section2" href="content/work-2-after-documents.html" media-type="application/xhtml+xml"/>
        <item id="back" href="content/back.html" media-type="application/xhtml+xml"/>
        <item id="nav" href="content/nav.html" media-type="application/xhtml+xml" properties="nav"/>
        <item id="img0" href="content/images/millard-1.png" media-type="image/png"/>
        </manifest>
        <spine>
        <itemref idref="cover"/><itemref idref="paper"/><itemref idref="section1"/><itemref idref="section2"/><itemref idref="back"/>
        </spine>
        <collection role="distributable-object" id="work1">
        <metadata>
        <dc:identifier>urn:uuid:work-antonini</dc:identifier>
        <dc:title>Authoring for AI</dc:title>
        <dc:creator id="work1-author1">Alessio Antonini</dc:creator>
        <dc:date>2025</dc:date>
        <meta property="dcterms:isPartOf">urn:uuid:book-work</meta>
        <meta property="dcterms:source">urn:isbn:9798241902979</meta>
        </metadata>
        <link href="content/work-1-authoring-for-ai.html"/>
        </collection>
        <collection role="distributable-object" id="work2">
        <metadata>
        <dc:identifier>urn:uuid:work-millard</dc:identifier>
        <dc:title>After Documents</dc:title>
        <dc:creator id="work2-author1">David E. Millard</dc:creator>
        <dc:date>2025</dc:date>
        <meta property="dcterms:isPartOf">urn:uuid:book-work</meta>
        <meta property="dcterms:source">urn:isbn:9798241902979</meta>
        </metadata>
        <link href="content/work-2-after-documents.html"/>
        <link href="content/images/millard-1.png"/>
        </collection>
        </package>
        """.write(to: root.appendingPathComponent("package.opf"), atomically: true, encoding: .utf8)
        func page(_ body: String) -> String {
            """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>x</title></head><body>
            \(body)
            </body></html>
            """
        }
        try page("<section epub:type=\"cover\" id=\"cover\"><h1>Cover</h1></section>")
            .write(to: root.appendingPathComponent("content/cover.html"), atomically: true, encoding: .utf8)
        try page("<header><h1>The Future of Text Vol VI</h1></header><main><section><p id=\"p-front\">Front.</p></section></main>")
            .write(to: root.appendingPathComponent("content/paper.html"), atomically: true, encoding: .utf8)
        try page("""
            <main><section epub:type="chapter" role="doc-chapter" data-origami-work="urn:uuid:work-antonini">
            <h1 id="H-h-antonini">Authoring for AI</h1><p class="byline work-authors">Alessio Antonini</p>
            <p id="p-a1">Machines read <a epub:type="glossref" href="back.html#gloss-g1">reading</a> and <a epub:type="biblioref" href="#bib-c1">[1]</a>, see <a href="work-2-after-documents.html#H-h-millard">Millard</a> and <a href="paper.html#p-front">the front</a>.</p>
            <section epub:type="bibliography" role="doc-bibliography" id="references"><h2>References</h2><ol><li id="bib-c1">Ong (1982). On Reading Machines.</li></ol></section>
            </section></main>
            """).write(to: root.appendingPathComponent("content/work-1-authoring-for-ai.html"), atomically: true, encoding: .utf8)
        try page("""
            <main><section epub:type="chapter" role="doc-chapter" data-origami-work="urn:uuid:work-millard">
            <h1 id="H-h-millard">After Documents</h1>
            <p id="p-m1">Welcome.</p><figure id="f-m1"><img src="images/millard-1.png" alt="A diagram"/></figure>
            </section></main>
            """).write(to: root.appendingPathComponent("content/work-2-after-documents.html"), atomically: true, encoding: .utf8)
        try page("""
            <section epub:type="glossary" role="doc-glossary" id="glossary"><h2>Glossary</h2><dl><dt id="gloss-g1">Reading</dt><dd>What a machine does to text.</dd></dl></section>
            <section epub:type="colophon" id="origami-publication-info"><h2>Colophon</h2></section>
            <section id="visual-meta"><h2>Visual-Meta</h2></section>
            """).write(to: root.appendingPathComponent("content/back.html"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("content/images/millard-1.png"))
        try """
        @book{c1,
        title = {On Reading Machines},
        author = {Ong, Walter},
        year = {1982}
        }
        """.write(to: root.appendingPathComponent("references.bib"), atomically: true, encoding: .utf8)
        let record: [String: Any] = ["document": ["binding": ["kind": "book", "works": [
            ["id": "urn:uuid:work-antonini", "section": "H-h-antonini", "note": "Read first."],
            ["id": "urn:uuid:work-millard", "section": "H-h-millard"]]]]]
        try JSONSerialization.data(withJSONObject: record).write(to: root.appendingPathComponent("visual-meta.json"))
    }

    /// A plain one-document publication with no works.
    private func makePaper(at root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("content"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="package.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: root.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="en">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="pub-id">urn:uuid:plain-edition</dc:identifier>
        <dc:title>A Plain Paper</dc:title>
        <dc:language>en</dc:language>
        <dc:creator>Someone Else</dc:creator>
        <dc:date>2026-01-01</dc:date>
        <meta property="dcterms:isVersionOf">urn:uuid:plain-work</meta>
        </metadata>
        <manifest>
        <item id="paper" href="content/paper.html" media-type="application/xhtml+xml"/>
        <item id="nav" href="content/nav.html" media-type="application/xhtml+xml" properties="nav"/>
        </manifest>
        <spine><itemref idref="paper"/></spine>
        </package>
        """.write(to: root.appendingPathComponent("package.opf"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>x</title></head><body>
        <header><h1>A Plain Paper</h1></header>
        <main><section><h2 id="H-h-intro">Introduction</h2><p id="p-1">Plain text <a href="#bib-c9">[1]</a>.</p></section></main>
        <section epub:type="bibliography" id="references"><ol><li id="bib-c9">Doe (2020). Something.</li></ol></section>
        <section epub:type="colophon" id="origami-publication-info"><h2>Colophon</h2></section>
        <section id="visual-meta"><h2>Visual-Meta</h2></section>
        </body></html>
        """.write(to: root.appendingPathComponent("content/paper.html"), atomically: true, encoding: .utf8)
        try "@misc{c9,\ntitle = {Something},\nyear = {2020}\n}\n".write(to: root.appendingPathComponent("references.bib"), atomically: true, encoding: .utf8)
    }

    private func record(_ id: String, title: String, folder: String) -> EPUBRecord {
        EPUBRecord(id: id, title: title, author: "", dateISO: nil, folder: folder,
                   contentSubpath: "content/paper.html", openedAt: Date())
    }

    @Test func readsWorksFromCollections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("binder-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBook(at: root)
        let info = try #require(EPUBWorks.read(unpackedFolder: root))
        #expect(info.title == "The Future of Text Vol VI")
        #expect(info.bindingKind == "book")
        #expect(info.works.count == 2)
        #expect(info.works[0].title == "Authoring for AI")
        #expect(info.works[0].authors == ["Alessio Antonini"])
        #expect(info.works[0].files == ["content/work-1-authoring-for-ai.html"])
        #expect(info.works[0].section == "H-h-antonini")
        #expect(info.works[0].note == "Read first.")
        #expect(info.works[1].files.contains("content/images/millard-1.png"))
        #expect(info.spine.count == 5)
    }

    @Test func bindsWorksFromTwoBooks() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("binder-write-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let bookFolder = base.appendingPathComponent("book")
        let paperFolder = base.appendingPathComponent("paper")
        try makeBook(at: bookFolder)
        try makePaper(at: paperFolder)
        let book = try #require(EPUBWorks.read(unpackedFolder: bookFolder))
        let paper = try #require(EPUBWorks.read(unpackedFolder: paperFolder))
        #expect(!paper.hasWorks)

        let destination = base.appendingPathComponent("Reading.epub")
        try EPUBBinderWriter.write(.init(
            title: "Reading for Week 3", coverText: "Two positions.\n\nRead both.", compiler: "Dene Grigar",
            parts: [(BinderPart(record: record("r1", title: book.title, folder: "book"), workIDs: ["urn:uuid:work-antonini"]), bookFolder, book),
                    (BinderPart(record: record("r2", title: paper.title, folder: "paper"), workIDs: nil), paperFolder, paper)]),
            to: destination)

        // Unpack what was written and look.
        let out = base.appendingPathComponent("out")
        _ = try OrigamiEPUBImporter.unpack(at: destination, into: out)
        func text(_ path: String) throws -> String {
            try String(contentsOf: out.appendingPathComponent(path), encoding: .utf8)
        }
        let opf = try text("package.opf")
        #expect(opf.contains("<dc:title>Reading for Week 3</dc:title>"))
        #expect(opf.contains("<meta property=\"origami:binding\">reading-list</meta>"))
        #expect(opf.contains("<dc:creator id=\"compiler1\">Dene Grigar</dc:creator>"))
        #expect(opf.contains("scheme=\"marc:relators\">com</meta>"))
        #expect(opf.components(separatedBy: "<collection role=\"distributable-object\"").count - 1 == 2)
        #expect(opf.contains("<dc:identifier>urn:uuid:work-antonini</dc:identifier>"))
        #expect(opf.contains("<dc:identifier>urn:uuid:plain-work</dc:identifier>"))
        #expect(opf.contains("<meta property=\"dcterms:isPartOf\">urn:uuid:book-work</meta>"))
        #expect(opf.contains("href=\"content/s1-work-1-authoring-for-ai.html\""))
        #expect(opf.contains("href=\"content/s2-paper.html\""))
        // Well-formed XML throughout.
        for path in ["package.opf", "content/cover.html", "content/back.html", "content/nav.html",
                     "content/s1-work-1-authoring-for-ai.html", "content/s2-paper.html"] {
            let data = try Data(contentsOf: out.appendingPathComponent(path))
            #expect((try? XMLDocument(data: data, options: [])) != nil, "well-formed \(path)")
        }

        let work = try text("content/s1-work-1-authoring-for-ai.html")
        // The glossary link now reaches the binder's glossary; the link to a
        // work not in the binder and to the book's front are let go.
        #expect(work.contains("href=\"back.html#gloss-s1-g1\""))
        #expect(!work.contains("work-2-after-documents.html"))
        #expect(!work.contains("paper.html#p-front"))
        #expect(work.contains(">Millard</a>") == false && work.contains("Millard"))
        #expect(work.contains("href=\"#bib-c1\""))
        let back = try text("content/back.html")
        #expect(back.contains("<dt id=\"gloss-s1-g1\">Reading</dt>"))
        #expect(back.contains("@misc{grigar"))
        #expect(back.contains("@incollection{antonini2025authoring"))
        #expect(back.contains("booktitle = {The Future of Text Vol VI}"))
        let plain = try text("content/s2-paper.html")
        #expect(!plain.contains("epub:type=\"colophon\""))
        #expect(!plain.contains("id=\"visual-meta\""))
        #expect(plain.contains("<header><h1>A Plain Paper</h1></header>"))
        let cover = try text("content/cover.html")
        #expect(cover.contains("Compiled by Dene Grigar"))
        #expect(cover.contains("<p>Two positions.</p>"))
        #expect(cover.contains("From <cite>The Future of Text Vol VI</cite>, 2025."))
        #expect(cover.contains("Read first."))
        let bib = try text("references.bib")
        #expect(bib.contains("@book{c1,"))
        #expect(bib.contains("@misc{c9,"))
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("visual-meta.json"))) as? [String: Any]
        let binding = (record?["document"] as? [String: Any])?["binding"] as? [String: Any]
        #expect(binding?["kind"] as? String == "reading-list")
        #expect((binding?["works"] as? [[String: Any]])?.count == 2)
    }
}
