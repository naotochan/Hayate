import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
@preconcurrency import Metal
import os.signpost

/// Sendable wrapper for MTLTexture. MTLTexture is thread-safe in practice
/// but the protocol lacks Sendable conformance in Swift 6.
struct SendableTexture: @unchecked Sendable {
    let texture: MTLTexture
}

/// 256-bin RGB histogram, normalized so the tallest bin across all channels
/// is 1.0. Computed from the displayed texture (H key overlay).
struct HistogramData: Sendable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
}

/// Pre-formatted shooting metadata for the info overlay (I key).
struct EXIFInfo: Sendable {
    var camera: String?
    var lens: String?
    var shutter: String?
    var aperture: String?
    var iso: String?
    var focalLength: String?
    var dateTaken: String?

    var exposureLine: [String] {
        [shutter, aperture, iso, focalLength].compactMap { $0 }
    }
}

/// Handles RAW and JPEG decoding.
///
/// Unlike an actor, this class lets multiple decodes run in parallel: each public
/// async method dispatches to `Task.detached`, so the work executes on the global
/// concurrent pool rather than on a single serial executor. That matters during
/// rapid culling — without parallelism, prefetching N±5 would serialize into one
/// long queue and stall the user.
///
/// Thread safety:
/// - `CIContext` is documented thread-safe and is shared.
/// - `CIRAWFilter` is NOT thread-safe, so each decode creates a new instance.
/// - `MTLDevice` is thread-safe.
final class ImageDecoder: @unchecked Sendable {
    private let ciContext: CIContext
    private let device: MTLDevice
    private let signpostLog = OSLog(subsystem: "com.hayate", category: "Decode")

    init(ciContext: CIContext, device: MTLDevice) {
        self.ciContext = ciContext
        self.device = device
    }

    // MARK: - Public async API (dispatches to background)

    /// Extract embedded JPEG thumbnail from a RAW file. Typically ~5-16ms.
    func extractJPEG(url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { [self] in
            extractJPEGSync(url: url)
        }.value
    }

    /// Decode a RAW file to MTLTexture at the specified display size.
    /// Typically ~200-500ms depending on format and resolution.
    func decodeRAW(url: URL, displaySize: CGSize, focusPeaking: Bool = false) async -> SendableTexture? {
        await Task.detached(priority: .userInitiated) { [self] in
            decodeRAWSync(url: url, displaySize: displaySize, focusPeaking: focusPeaking)
        }.value
    }

    /// Decode a RAW file to CGImage at the specified display size.
    /// Used by the disk cache path: produces a CGImage that can be both
    /// converted to MTLTexture (for memory cache) and written as HEIF (for disk cache)
    /// with only a single RAW decode pass.
    func decodeRAWToCGImage(url: URL, displaySize: CGSize, priority: TaskPriority = .userInitiated) async -> CGImage? {
        await Task.detached(priority: priority) { [self] in
            decodeRAWToCGImageSync(url: url, displaySize: displaySize)
        }.value
    }

    /// Decode a RAW file at full resolution (for zoom).
    func decodeRAWFullResolution(url: URL) async -> SendableTexture? {
        await Task.detached(priority: .userInitiated) { [self] in
            decodeRAWFullResolutionSync(url: url)
        }.value
    }

    /// Convert a CGImage (e.g. extracted JPEG) to MTLTexture.
    func cgImageToTexture(_ cgImage: CGImage) async -> SendableTexture? {
        await Task.detached(priority: .userInitiated) { [self] in
            cgImageToTextureSync(cgImage)
        }.value
    }

    /// Extract a small thumbnail CGImage for the filmstrip.
    func extractThumbnail(url: URL, maxSize: Int = 400) async -> CGImage? {
        await Task.detached(priority: .utility) { [self] in
            extractThumbnailSync(url: url, maxSize: maxSize)
        }.value
    }

    /// Read shooting metadata (shutter, aperture, ISO, …) for the info overlay.
    func extractEXIF(url: URL) async -> EXIFInfo? {
        await Task.detached(priority: .utility) { [self] in
            extractEXIFSync(url: url)
        }.value
    }

    /// Compute an RGB histogram from a displayed texture (H key overlay).
    func computeHistogram(texture: SendableTexture) async -> HistogramData? {
        await Task.detached(priority: .utility) { [self] in
            computeHistogramSync(texture: texture.texture)
        }.value
    }

    // MARK: - Sync implementations

    private func extractJPEGSync(url: URL) -> CGImage? {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "extractJPEG", signpostID: signpostID, "file: %{public}s", url.lastPathComponent)
        defer { os_signpost(.end, log: signpostLog, name: "extractJPEG", signpostID: signpostID) }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840,
            kCGImageSourceShouldCache: false
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func decodeRAWToCGImageSync(url: URL, displaySize: CGSize) -> CGImage? {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "decodeRAWCGImage", signpostID: signpostID, "file: %{public}s", url.lastPathComponent)
        defer { os_signpost(.end, log: signpostLog, name: "decodeRAWCGImage", signpostID: signpostID) }

        guard let rawFilter = CIRAWFilter(imageURL: url) else { return nil }
        guard let outputImage = rawFilter.outputImage else { return nil }

        let scale = min(
            displaySize.width / outputImage.extent.width,
            displaySize.height / outputImage.extent.height
        )
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(scaledImage, from: scaledImage.extent)
    }

    private func decodeRAWSync(url: URL, displaySize: CGSize, focusPeaking: Bool) -> SendableTexture? {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "decodeRAW", signpostID: signpostID, "file: %{public}s", url.lastPathComponent)
        defer { os_signpost(.end, log: signpostLog, name: "decodeRAW", signpostID: signpostID) }

        guard let rawFilter = CIRAWFilter(imageURL: url) else {
            return nil
        }

        guard let outputImage = rawFilter.outputImage else {
            return nil
        }

        let scale = min(
            displaySize.width / outputImage.extent.width,
            displaySize.height / outputImage.extent.height
        )
        var scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        if focusPeaking {
            scaledImage = applyFocusPeaking(to: scaledImage)
        }

        guard let tex = renderToTexture(image: scaledImage) else { return nil }
        return SendableTexture(texture: tex)
    }

    private func decodeRAWFullResolutionSync(url: URL) -> SendableTexture? {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "decodeRAWFull", signpostID: signpostID, "file: %{public}s", url.lastPathComponent)
        defer { os_signpost(.end, log: signpostLog, name: "decodeRAWFull", signpostID: signpostID) }

        guard let rawFilter = CIRAWFilter(imageURL: url) else {
            return nil
        }

        guard let outputImage = rawFilter.outputImage else {
            return nil
        }

        guard let tex = renderToTexture(image: outputImage) else { return nil }
        return SendableTexture(texture: tex)
    }

    private func cgImageToTextureSync(_ cgImage: CGImage) -> SendableTexture? {
        let ciImage = CIImage(cgImage: cgImage)
        guard let tex = renderToTexture(image: ciImage) else { return nil }
        return SendableTexture(texture: tex)
    }

    private func extractThumbnailSync(url: URL, maxSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func extractEXIFSync(url: URL) -> EXIFInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any] else {
            return nil
        }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        var info = EXIFInfo()
        info.camera = tiff[kCGImagePropertyTIFFModel] as? String
        info.lens = exif[kCGImagePropertyExifLensModel] as? String
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            // Near-1s speeds (0.5, 0.6, 0.8 …) read better as decimals; the
            // reciprocal form would misreport 0.6s as 1/2s.
            info.shutter = t >= 0.4
                ? String(format: "%gs", t)
                : "1/\(Int((1 / t).rounded()))s"
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double {
            info.aperture = String(format: "f/%.1f", f)
        }
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any],
           let iso = isos.first as? Int {
            info.iso = "ISO \(iso)"
        }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double {
            info.focalLength = "\(Int(fl.rounded()))mm"
        }
        if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            info.dateTaken = Self.formatEXIFDate(raw)
        }
        return info
    }

    private func computeHistogramSync(texture: MTLTexture) -> HistogramData? {
        guard let image = CIImage(mtlTexture: texture, options: nil) else { return nil }

        guard let filter = CIFilter(name: "CIAreaHistogram", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: image.extent),
            "inputCount": 256,
            "inputScale": 1.0,
        ]), let output = filter.outputImage else { return nil }

        // Render the 256×1 histogram image into a float bitmap.
        var bitmap = [Float](repeating: 0, count: 256 * 4)
        ciContext.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 256 * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: 256, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )

        var red = [Float](repeating: 0, count: 256)
        var green = [Float](repeating: 0, count: 256)
        var blue = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            red[i] = bitmap[i * 4]
            green[i] = bitmap[i * 4 + 1]
            blue[i] = bitmap[i * 4 + 2]
        }

        let maxValue = max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0)
        guard maxValue > 0 else { return nil }
        for i in 0..<256 {
            red[i] /= maxValue
            green[i] /= maxValue
            blue[i] /= maxValue
        }
        return HistogramData(red: red, green: green, blue: blue)
    }

    /// EXIF dates arrive as "2026:07:12 14:23:45" — reformat for display.
    /// (DateFormatter is thread-safe for formatting on modern macOS.)
    private static let exifDateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let exifDateDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    private static func formatEXIFDate(_ raw: String) -> String {
        guard let date = exifDateParser.date(from: raw) else { return raw }
        return exifDateDisplay.string(from: date)
    }

    /// Apply Leica-style focus peaking: thin green lines on in-focus edges.
    private func applyFocusPeaking(to image: CIImage) -> CIImage {
        let grayscaleKernel = CIColorKernel(source: """
            kernel vec4 grayscale(sampler src) {
                vec4 c = sample(src, samplerCoord(src));
                float lum = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
                return vec4(lum, lum, lum, 1.0);
            }
        """)
        let gray = grayscaleKernel?.apply(extent: image.extent, arguments: [image]) ?? image

        let laplacianWeights: [CGFloat] = [
             0, -1,  0,
            -1,  4, -1,
             0, -1,  0
        ]
        guard let laplacian = CIFilter(name: "CIConvolution3X3", parameters: [
            kCIInputImageKey: gray,
            "inputWeights": CIVector(values: laplacianWeights, count: 9),
            "inputBias": 0.0
        ])?.outputImage else {
            return image
        }

        let peakingKernel = CIColorKernel(source: """
            kernel vec4 peaking(sampler edges) {
                vec4 e = sample(edges, samplerCoord(edges));
                float strength = abs(e.r);
                if (strength > 0.08) {
                    return vec4(0.0, 1.0, 0.0, min(strength * 4.0, 0.9));
                }
                return vec4(0.0, 0.0, 0.0, 0.0);
            }
        """)

        guard let greenEdges = peakingKernel?.apply(
            extent: image.extent,
            arguments: [laplacian.cropped(to: image.extent)]
        ) else {
            return image
        }

        guard let composite = CIFilter(name: "CISourceOverCompositing", parameters: [
            kCIInputImageKey: greenEdges,
            kCIInputBackgroundImageKey: image
        ])?.outputImage else {
            return image
        }

        return composite
    }

    // MARK: - Private

    private func renderToTexture(image: CIImage) -> MTLTexture? {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)

        guard width > 0, height > 0 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        ciContext.render(
            image,
            to: texture,
            commandBuffer: nil,
            bounds: image.extent,
            colorSpace: colorSpace
        )

        return texture
    }
}
