import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Drop images on the notch to convert them: HEIC from the iPhone to JPG, and between JPG, PNG,
// HEIC, WebP and TIFF where the system can write them. Copies land next to the originals
// ("IMG_0042.jpg", "IMG_0042 2.jpg" if that exists); metadata and orientation are kept.

enum ImageFormat: String, CaseIterable, Identifiable {
    case jpeg, png, heic, webp, tiff

    var id: String { rawValue }
    var type: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .webp: return .webP
        case .tiff: return .tiff
        }
    }
    var label: String { self == .jpeg ? "JPG" : (self == .webp ? "WebP" : rawValue.uppercased()) }
    var ext: String { self == .jpeg ? "jpg" : rawValue }
    var lossy: Bool { self == .jpeg || self == .heic || self == .webp }

    /// The formats this Mac's ImageIO can write (WebP depends on the macOS version).
    static let writable: [ImageFormat] = {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return allCases.filter { ids.contains($0.type.identifier) }
    }()

    static func of(_ url: URL) -> ImageFormat? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let id = CGImageSourceGetType(src) as String? else { return nil }
        return allCases.first { $0.type.identifier == id }
    }
}

enum ImageConverter {
    /// Files ImageIO can read as a still image (PDFs and movies left out).
    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return false }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 0
    }

    static func thumbnail(_ url: URL, size: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: size * 2]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }

    enum Failure: LocalizedError {
        case unreadable, unwritable
        var errorDescription: String? {
            switch self {
            case .unreadable: return L.t("can't read the image", "не читается")
            case .unwritable: return L.t("can't write the file", "не записывается")
            }
        }
    }

    /// Writes a copy in `format` next to `url` and returns its location.
    static func convert(_ url: URL, to format: ImageFormat) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else { throw Failure.unreadable }
        let out = freeURL(url.deletingPathExtension().appendingPathExtension(format.ext))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw Failure.unwritable
        }
        var props: [CFString: Any] = [:]
        if format.lossy { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        if format == .jpeg, let image = CGImageSourceCreateImageAtIndex(src, 0, nil), hasAlpha(image),
           let flat = flatten(image) {
            // JPEG has no transparency: white behind it, not black.
            var meta = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
            meta.merge(props) { _, new in new }
            CGImageDestinationAddImage(dest, flat, meta as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw Failure.unwritable }
        return out
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    private static func flatten(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// "photo.jpg", or "photo 2.jpg", "photo 3.jpg"… when taken.
    private static func freeURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        for n in 2...999 {
            let candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(base) \(UUID().uuidString.prefix(6))").appendingPathExtension(ext)
    }
}

/// Images dropped on the notch and what became of them.
struct ConvertJob: Equatable {
    enum State: Equatable {
        case ready
        case working(ImageFormat)
        case done(ImageFormat, [URL], failed: Int)
    }
    var files: [URL]
    var state: State = .ready

    /// The common format of the dropped files, if they share one (that button is pointless).
    var sourceFormat: ImageFormat? {
        let formats = Set(files.compactMap { ImageFormat.of($0) })
        return formats.count == 1 ? formats.first : nil
    }
}

// MARK: - Views

/// While a drag hovers over the notch.
struct DropHint: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            NotchRow(notchWidth: notchWidth, height: notchHeight) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
            } right: {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.horizontal, 18)
            Text(L.t("Drop images to convert", "Отпустите, чтобы конвертировать"))
                .font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.85))
                .frame(height: 30).padding(.bottom, 4)
        }
    }
}

struct ConvertView: View {
    @ObservedObject var model: NotchModel
    let job: ConvertJob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchRow(notchWidth: model.notchWidth, height: model.notchHeight) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
            } right: {
                IconButton(symbol: "xmark", help: L.t("Close", "Закрыть")) { model.onConvertClose() }
                    .scaleEffect(0.8)
            }
            .padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(job.files.prefix(5), id: \.self) { url in
                        Thumb(url: url)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.files.count == 1 ? job.files[0].lastPathComponent
                                                  : L.t("\(job.files.count) images", "Картинок: \(job.files.count)"))
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                        Text(job.files.first?.deletingLastPathComponent().lastPathComponent ?? "")
                            .font(.system(size: 11)).foregroundColor(.white.opacity(0.45)).lineLimit(1)
                    }
                    .padding(.leading, 4)
                    Spacer(minLength: 0)
                }
                status
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 18)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .ready:
            HStack(spacing: 8) {
                Text(L.t("Convert to", "Конвертировать в")).font(.system(size: 12)).foregroundColor(.white.opacity(0.55))
                ForEach(ImageFormat.writable) { f in
                    Button(f.label) { model.onConvert(f) }
                        .buttonStyle(NotchButtonStyle(role: f == .jpeg ? .primary : .secondary))
                        .disabled(f == job.sourceFormat)
                        .opacity(f == job.sourceFormat ? 0.35 : 1)
                }
                Spacer(minLength: 0)
            }
        case .working(let f):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L.t("Converting to \(f.label)…", "Конвертирую в \(f.label)…"))
                    .font(.system(size: 12.5)).foregroundColor(.white.opacity(0.75))
            }
            .frame(height: 30)
        case .done(let f, let urls, let failed):
            HStack(spacing: 10) {
                Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(failed == 0 ? .green : usageColor(70))
                Text(doneText(f, urls.count, failed)).font(.system(size: 12.5)).foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !urls.isEmpty {
                    Button(L.t("Show in Finder", "Показать в Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting(urls)
                        model.onConvertClose()
                    }
                    .buttonStyle(NotchButtonStyle(role: .secondary))
                }
            }
            .frame(height: 30)
        }
    }

    private func doneText(_ f: ImageFormat, _ ok: Int, _ failed: Int) -> String {
        let base = ok == 1 ? L.t("Saved as \(f.label)", "Сохранено в \(f.label)") : L.t("\(ok) saved as \(f.label)", "\(ok) сохранено в \(f.label)")
        return failed == 0 ? base : base + L.t(", \(failed) failed", ", не вышло: \(failed)")
    }
}

struct Thumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let thumb = ImageConverter.thumbnail(url, size: 40)
                DispatchQueue.main.async { image = thumb }
            }
        }
    }
}
