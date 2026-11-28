import UIKit
import ZIPFoundation

enum DeckExport {
    static func fileStem(_ name: String, fallback: String) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasSuffix(".pptx") { base.removeLast(5) }
        let prohibited = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        base = base.components(separatedBy: prohibited).joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        var stem = ""
        var count = 0
        for character in base {
            let bytes = String(character).utf8.count
            guard count + bytes <= 180 else { break }
            stem.append(character)
            count += bytes
        }
        return stem.isEmpty ? fallback : stem
    }

    static func exportStem(title: String, pptx: Bool, filename: String?) -> String {
        guard pptx else { return "Slides" }
        let defaultName = fileStem(title, fallback: "Slides")
        return fileStem(filename ?? defaultName, fallback: defaultName)
    }

    static func create(_ deck: Deck, api: RainAPI, pptx: Bool, filename: String?,
                       progress: @escaping @MainActor (Int?) -> Void) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = exportStem(title: deck.title, pptx: pptx, filename: filename)
        let output = directory.appendingPathComponent(name).appendingPathExtension(pptx ? "pptx" : "zip")
        do {
            let archive = try Archive(url: output, accessMode: .create)
            var ratio = 1.0
            for offset in deck.slides.indices {
                try Task.checkCancellation()
                let page = offset + 1
                await progress(page)
                let input = try await deck.pageData(offset, api: api)
                guard let image = UIImage(data: input), let data = image.jpegData(compressionQuality: 0.94),
                      image.size.height > 0 else { throw RainError.invalid("课件图片") }
                if offset == 0 { ratio = Double(image.size.width / image.size.height) }
                try add(archive, pptx ? "ppt/media/image\(page).jpg" : String(format: "%04d.jpg", page), data)
            }
            await progress(nil)
            if pptx { try writeParts(archive, count: deck.slides.count, title: name, ratio: ratio) }
            try Task.checkCancellation()
            return output
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func pdf(_ deck: Deck, api: RainAPI, progress: @escaping @MainActor (Int?) -> Void) async throws -> URL {
        guard !deck.slides.isEmpty else { throw RainError.invalid("课件没有页面") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(fileStem(deck.title, fallback: "Slides")).appendingPathExtension("pdf")
        do {
            for index in deck.slides.indices {
                try Task.checkCancellation()
                await progress(index + 1)
                let bytes = try await deck.pageData(index, api: api)
                try bytes.write(to: directory.appendingPathComponent("\(index).image"))
            }
            await progress(nil)
            try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 1, height: 1)).writePDF(to: output) { context in
                for index in deck.slides.indices where !Task.isCancelled {
                    autoreleasepool {
                        let page = directory.appendingPathComponent("\(index).image")
                        guard let image = UIImage(contentsOfFile: page.path) else { return }
                        let bounds = CGRect(origin: .zero, size: image.size)
                        context.beginPage(withBounds: bounds, pageInfo: [:])
                        image.draw(in: bounds)
                        try? FileManager.default.removeItem(at: page)
                    }
                }
            }
            try Task.checkCancellation()
            guard (try FileManager.default.contentsOfDirectory(atPath: directory.path)).count == 1 else {
                throw RainError.invalid("PDF 中有无法读取的课件图片")
            }
            return output
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func add(_ archive: Archive, _ name: String, _ data: Data) throws {
        try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { offset, size in
            data.subdata(in: Int(offset)..<(Int(offset) + size))
        }
    }

    private static func writeParts(_ archive: Archive, count: Int, title: String, ratio: Double) throws {
        guard let url = Bundle.main.url(forResource: "DeckParts", withExtension: "json"), count > 0 else {
            throw RainError.invalid("PPTX 结构")
        }
        let parts = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let width = Int((6_858_000 * min(4, max(0.25, ratio))).rounded())
        let escaped = title.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let presentation = "ppt/presentation.xml"
        let links = "ppt/_rels/presentation.xml.rels"
        let slide = "ppt/slides/slide1.xml"
        let slideLinks = "ppt/slides/_rels/slide1.xml.rels"
        let slideID = "<p:sldId id=\"256\" r:id=\"rId1\"/>"
        let relationship = "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide1.xml\"/>"
        let override = "<Override PartName=\"/ppt/slides/slide1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        func repeatPart(_ block: (Int) -> String) -> String { (1...count).map(block).joined() }
        for (path, source) in parts {
            switch path {
            case slide, slideLinks:
                for page in 1...count {
                    try Task.checkCancellation()
                    let content = source.replacingOccurrences(of: "image1.jpg", with: "image\(page).jpg")
                        .replacingOccurrences(of: "Page 1", with: "Page \(page)")
                        .replacingOccurrences(of: "cx=\"6858000\"", with: "cx=\"\(width)\"")
                    try add(archive, path.replacingOccurrences(of: "slide1.xml", with: "slide\(page).xml"), Data(content.utf8))
                }
            default:
                var content = source
                switch path {
                case presentation:
                    content = content.replacingOccurrences(of: slideID, with: repeatPart { "<p:sldId id=\"\(255 + $0)\" r:id=\"rId\($0)\"/>" })
                        .replacingOccurrences(of: "<p:sldSz cx=\"6858000\"", with: "<p:sldSz cx=\"\(width)\"")
                case links:
                    content = content.replacingOccurrences(of: relationship, with: repeatPart {
                        relationship.replacingOccurrences(of: "rId1", with: "rId\($0)")
                            .replacingOccurrences(of: "slide1.xml", with: "slide\($0).xml")
                    })
                case "[Content_Types].xml":
                    content = content.replacingOccurrences(of: override, with: repeatPart { override.replacingOccurrences(of: "slide1.xml", with: "slide\($0).xml") })
                case "docProps/core.xml":
                    content = content.replacingOccurrences(of: "TITLE_TOKEN", with: escaped)
                default: break
                }
                try add(archive, path, Data(content.utf8))
            }
        }
    }
}
