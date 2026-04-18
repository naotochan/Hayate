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
    func extractThumbnail(url: URL, maxSize: Int = 120) async -> CGImage? {
        await Task.detached(priority: .utility) { [self] in
            extractThumbnailSync(url: url, maxSize: maxSize)
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
