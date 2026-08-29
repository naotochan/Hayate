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

/// Caps concurrent CIRAWFilter / full-res work. Cancelled waiters are dropped
/// instead of becoming zombie decodes; interactive (visible photo) work is
/// always scheduled ahead of prefetch.
actor DecodeLimiter {
    /// Interactive (visible photo) decodes jump ahead of prefetch work.
    enum Tier { case high, low }

    private let maxConcurrent: Int
    private var inFlight = 0
    private var highWaiters: [(id: UUID, cont: CheckedContinuation<Bool, Never>)] = []
    private var lowWaiters: [(id: UUID, cont: CheckedContinuation<Bool, Never>)] = []
    /// Remembers cancel races so a late onCancel flag can be cleared after
    /// acquire's handler returns. The enqueue-path check is cheap defense only.
    private var cancelledWaiterIDs: Set<UUID> = []

    init(maxConcurrent: Int) { self.maxConcurrent = max(1, maxConcurrent) }

    /// Returns nil when the caller was cancelled before a permit was granted.
    /// Cancellation mid-operation cannot preempt CIRAWFilter; the decode runs
    /// to completion and the permit is released normally.
    func withPermit<T: Sendable>(tier: Tier = .high, _ operation: @Sendable () async -> T) async -> T? {
        guard await acquire(tier: tier) else { return nil }
        let result = await operation()
        release()
        return result
    }

    private func acquire(tier: Tier) async -> Bool {
        guard !Task.isCancelled else { return false }
        if inFlight < maxConcurrent {
            inFlight += 1
            return true
        }
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                // Cheap defense; enqueue is synchronous on the actor so this
                // should not fire in practice.
                if cancelledWaiterIDs.contains(id) {
                    cancelledWaiterIDs.remove(id)
                    cont.resume(returning: false)
                } else if tier == .high {
                    highWaiters.append((id, cont))
                } else {
                    lowWaiters.append((id, cont))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
        cancelledWaiterIDs.remove(id)  // clear stale cancel flag after handler returns
        guard granted else { return false }
        if Task.isCancelled {
            // Cancelled just as the slot was handed over — pass it on.
            release()
            return false
        }
        return true
    }

    private func cancelWaiter(id: UUID) {
        if let i = highWaiters.firstIndex(where: { $0.id == id }) {
            highWaiters.remove(at: i).cont.resume(returning: false)
        } else if let i = lowWaiters.firstIndex(where: { $0.id == id }) {
            lowWaiters.remove(at: i).cont.resume(returning: false)
        } else {
            cancelledWaiterIDs.insert(id)
        }
    }

    private func release() {
        // Hand the slot directly to the oldest waiter (inFlight unchanged);
        // interactive work is always drained before prefetch work.
        if !highWaiters.isEmpty {
            highWaiters.removeFirst().cont.resume(returning: true)
        } else if !lowWaiters.isEmpty {
            lowWaiters.removeFirst().cont.resume(returning: true)
        } else {
            inFlight -= 1
        }
    }
}

/// Handles RAW and JPEG decoding.
///
/// Lightweight paths (embedded JPEG / filmstrip thumbs) run freely on the
/// concurrent pool. Heavy CIRAWFilter work is gated by `DecodeLimiter` so
/// opening a 200+ file folder cannot launch dozens of full RAW decodes at once.
///
/// Thread safety:
/// - Two `CIContext`s are kept (each is thread-safe with its own lock):
///   `ciContext` for plain CGImage/texture renders, and a lazily created RAW
///   context for CIRAWFilter-backed renders — a RawCamera hang holds the
///   context lock for the whole render, and must not freeze display renders.
/// - `CIRAWFilter` is NOT thread-safe, so each decode creates a new instance,
///   and decodes run serially (see `rawLimiter`).
/// - `MTLDevice` is thread-safe.
final class ImageDecoder: @unchecked Sendable {
    private let ciContext: CIContext
    private let device: MTLDevice
    private let signpostLog = OSLog(subsystem: "com.hayate", category: "Decode")
    /// Serial full RAW decodes. RawCamera (CIRAWFilter's engine) has shared
    /// internal queues that can deadlock under concurrent decodes — observed
    /// in the field as a permanent stall holding the CIContext lock.
    private let rawLimiter = DecodeLimiter(maxConcurrent: 1)

    /// Lazily created on first RAW decode (off the main thread — CIContext
    /// creation compiles GPU shaders). See the class doc for why RAW renders
    /// get their own context.
    private var rawContextStorage: CIContext?
    private let rawContextLock = NSLock()

    init(ciContext: CIContext, device: MTLDevice) {
        self.ciContext = ciContext
        self.device = device
    }

    private func rawContext() -> CIContext {
        rawContextLock.lock()
        defer { rawContextLock.unlock() }
        if let rawContextStorage { return rawContextStorage }
        let context = CIContext(mtlDevice: device)
        rawContextStorage = context
        return context
    }

    /// Returns a task that logs an error if it isn't cancelled within
    /// `seconds`. A decode can't be cancelled mid-CIRAWFilter-render — the
    /// log exists to identify files that hang RawCamera.
    private func startStallWatchdog(seconds: UInt64, label: String, url: URL) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            os_log(.error, log: signpostLog, "%{public}@ stuck >%llus: %{public}@ — this file may hang RawCamera; draft previews remain usable", label, seconds, url.lastPathComponent)
        }
    }

    // MARK: - Public async API (dispatches to background)

    /// Extract embedded JPEG preview from a RAW file. Typically ~5-16ms.
    /// Uses ImageIO's embedded thumbnail only — never forces a full-image decode.
    func extractJPEG(url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { [self] in
            extractJPEGSync(url: url)
        }.value
    }

    /// Decode a RAW file to MTLTexture at the specified display size.
    /// Typically ~200-500ms depending on format and resolution.
    func decodeRAW(url: URL, displaySize: CGSize, focusPeaking: Bool = false) async -> SendableTexture? {
        await rawLimiter.withPermit(tier: .high) {
            let watchdog = startStallWatchdog(seconds: 10, label: "decodeRAW", url: url)
            let result = await Task.detached(priority: .userInitiated) { [self] in
                decodeRAWSync(url: url, displaySize: displaySize, focusPeaking: focusPeaking)
            }.value
            watchdog.cancel()
            return result
        } ?? nil
    }

    /// Decode a RAW file to CGImage at the specified display size.
    /// Used by the disk cache path: produces a CGImage that can be both
    /// converted to MTLTexture (for memory cache) and written as HEIF (for disk cache)
    /// with only a single RAW decode pass.
    func decodeRAWToCGImage(url: URL, displaySize: CGSize, priority: TaskPriority = .userInitiated) async -> CGImage? {
        let tier: DecodeLimiter.Tier = priority >= .userInitiated ? .high : .low
        return await rawLimiter.withPermit(tier: tier) {
            let watchdog = startStallWatchdog(seconds: 10, label: "decodeRAWToCGImage", url: url)
            let result = await Task.detached(priority: priority) { [self] in
                decodeRAWToCGImageSync(url: url, displaySize: displaySize)
            }.value
            watchdog.cancel()
            return result
        } ?? nil
    }

    /// Decode a RAW file at full resolution (for zoom).
    func decodeRAWFullResolution(url: URL) async -> SendableTexture? {
        await rawLimiter.withPermit(tier: .high) {
            let watchdog = startStallWatchdog(seconds: 10, label: "decodeRAWFullResolution", url: url)
            let result = await Task.detached(priority: .userInitiated) { [self] in
                decodeRAWFullResolutionSync(url: url)
            }.value
            watchdog.cancel()
            return result
        } ?? nil
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

    /// Downscale an already-decoded image for filmstrip/cache use without
    /// touching the source file again.
    func downscaledCGImage(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let w = image.width
        let h = image.height
        let longest = max(w, h)
        guard longest > maxPixelSize, maxPixelSize > 0 else { return image }
        let scale = CGFloat(maxPixelSize) / CGFloat(longest)
        let ciImage = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    /// Read shooting metadata (shutter, aperture, ISO, …) for the info overlay.
    func extractEXIF(url: URL) async -> EXIFInfo? {
        await Task.detached(priority: .utility) { [self] in
            extractEXIFSync(url: url)
        }.value
    }

    /// Display-oriented full-resolution pixel size from file metadata (no decode).
    /// Swaps width/height when EXIF/TIFF orientation implies 90° rotation.
    nonisolated static func orientedPixelSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any] else {
            return nil
        }
        guard let pixelWidth = props[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = props[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0 else {
            return nil
        }
        var width = CGFloat(pixelWidth)
        var height = CGFloat(pixelHeight)

        let orientation: Int = {
            if let o = props[kCGImagePropertyOrientation] as? Int { return o }
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
               let o = tiff[kCGImagePropertyTIFFOrientation] as? Int { return o }
            return 1
        }()

        switch orientation {
        case 5, 6, 7, 8:
            swap(&width, &height)
        default:
            break
        }
        return CGSize(width: width, height: height)
    }

    /// Capture date from EXIF DateTimeOriginal only. Missing / unreadable → nil.
    nonisolated static func captureDate(url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any] else {
            return nil
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        guard let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return nil
        }
        return exifDateParser.date(from: raw)
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

        // No Always/IfAbsent flags: return the embedded preview only. Forcing
        // ImageIO to synthesize a thumb from the full RAW starves the UI when
        // many files load at once; L3b CIRAWFilter handles the full decode.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840,
            kCGImageSourceShouldCache: false
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Full-quality CIImage for a file: CIRAWFilter for RAWs, plain CIImage
    /// for JPEG-only shots (which go through the same display pipeline).
    /// Explicit type branch — a RAW that CIRAWFilter can't open must fail,
    /// not silently degrade to an ImageIO preview decode.
    private func fullQualityImage(url: URL) -> CIImage? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if let type = type,
           CullingSession.rawUTTypes.contains(where: { type.conforms(to: $0) }) {
            guard let rawFilter = CIRAWFilter(imageURL: url) else { return nil }
            return rawFilter.outputImage
        }
        // applyOrientationProperty: CIRAWFilter output is rotation-applied;
        // plain CIImage is not by default, and a sideways decode would stick
        // in the HEIF disk cache.
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    private func decodeRAWToCGImageSync(url: URL, displaySize: CGSize) -> CGImage? {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "decodeRAWCGImage", signpostID: signpostID, "file: %{public}s", url.lastPathComponent)
        defer { os_signpost(.end, log: signpostLog, name: "decodeRAWCGImage", signpostID: signpostID) }

        guard let outputImage = fullQualityImage(url: url) else { return nil }

        // Never upscale (a small JPEG would otherwise be blown up and cached).
        let scale = min(1,
            min(displaySize.width / outputImage.extent.width,
                displaySize.height / outputImage.extent.height)
        )
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return rawContext().createCGImage(scaledImage, from: scaledImage.extent)
    }

    private func decodeRAWSync(url: URL, displaySize: CGSize, focusPeaking: Bool) -> SendableTexture? {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "decodeRAW", signpostID: signpostID, "file: %{public}s", url.lastPathComponent)
        defer { os_signpost(.end, log: signpostLog, name: "decodeRAW", signpostID: signpostID) }

        guard let outputImage = fullQualityImage(url: url) else {
            return nil
        }

        let scale = min(1,
            min(displaySize.width / outputImage.extent.width,
                displaySize.height / outputImage.extent.height)
        )
        var scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        if focusPeaking {
            scaledImage = applyFocusPeaking(to: scaledImage)
        }

        guard let tex = renderToTexture(image: scaledImage, context: rawContext()) else { return nil }
        return SendableTexture(texture: tex)
    }

    private func decodeRAWFullResolutionSync(url: URL) -> SendableTexture? {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "decodeRAWFull", signpostID: signpostID, "file: %{public}s", url.lastPathComponent)
        defer { os_signpost(.end, log: signpostLog, name: "decodeRAWFull", signpostID: signpostID) }

        guard let outputImage = fullQualityImage(url: url) else {
            return nil
        }

        guard let tex = renderToTexture(image: outputImage, context: rawContext()) else { return nil }
        return SendableTexture(texture: tex)
    }

    private func cgImageToTextureSync(_ cgImage: CGImage) -> SendableTexture? {
        let ciImage = CIImage(cgImage: cgImage)
        // Plain CGImage renders stay on the display context — only
        // CIRAWFilter-backed renders use the RAW context.
        guard let tex = renderToTexture(image: ciImage, context: ciContext) else { return nil }
        return SendableTexture(texture: tex)
    }

    private func extractThumbnailSync(url: URL, maxSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        // Embedded thumb only — never synthesize from the full RAW.
        let options: [CFString: Any] = [
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

    private func renderToTexture(image: CIImage, context: CIContext) -> MTLTexture? {
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
        context.render(
            image,
            to: texture,
            commandBuffer: nil,
            bounds: image.extent,
            colorSpace: colorSpace
        )

        return texture
    }
}

/// Scene breaks for the grid: indices that start a new shooting segment.
enum SceneBoundary {
    /// Returns indices (never 0) where the gap between consecutive capture
    /// times exceeds `gapMinutes`. Missing dates never create a break.
    /// `gapMinutes <= 0` disables detection.
    static func startIndices(dates: [Date?], gapMinutes: Int) -> Set<Int> {
        guard gapMinutes > 0, dates.count > 1 else { return [] }
        let gap = TimeInterval(gapMinutes * 60)
        var starts = Set<Int>()
        for i in 1..<dates.count {
            guard let prev = dates[i - 1], let cur = dates[i] else { continue }
            if abs(cur.timeIntervalSince(prev)) > gap {
                starts.insert(i)
            }
        }
        return starts
    }
}
