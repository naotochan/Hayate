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

/// Actor that handles RAW and JPEG decoding.
/// CIRAWFilter is NOT thread-safe, so each decode creates a new instance.
/// CIContext IS thread-safe and shared across all decodes.
actor ImageDecoder {
    private let ciContext: CIContext
    private let device: MTLDevice
    private let signpostLog = OSLog(subsystem: "com.hayate", category: "Decode")

    init(ciContext: CIContext, device: MTLDevice) {
        self.ciContext = ciContext
        self.device = device
    }

    /// Extract embedded JPEG thumbnail from a RAW file.
    /// Typically ~5-16ms. Returns nil if no embedded JPEG exists.
    func extractJPEG(url: URL) -> CGImage? {
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

    /// Decode a RAW file to MTLTexture at the specified display size.
    /// Uses CIRAWFilter for GPU-accelerated decoding.
    /// Typically ~200-500ms depending on format and resolution.
    func decodeRAW(url: URL, displaySize: CGSize, focusPeaking: Bool = false) -> SendableTexture? {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "decodeRAW", signpostID: signpostID, "file: %{public}s", url.lastPathComponent)
        defer { os_signpost(.end, log: signpostLog, name: "decodeRAW", signpostID: signpostID) }

        guard let rawFilter = CIRAWFilter(imageURL: url) else {
            return nil
        }

        guard let outputImage = rawFilter.outputImage else {
            return nil
        }

        // Scale to display size to save GPU memory
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

    /// Decode a RAW file at full resolution (for zoom).
    func decodeRAWFullResolution(url: URL) -> SendableTexture? {
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

    /// Convert a CGImage (e.g. extracted JPEG) to MTLTexture.
    func cgImageToTexture(_ cgImage: CGImage) -> SendableTexture? {
        let ciImage = CIImage(cgImage: cgImage)
        guard let tex = renderToTexture(image: ciImage) else { return nil }
        return SendableTexture(texture: tex)
    }

    /// Extract a small thumbnail CGImage for the filmstrip.
    func extractThumbnail(url: URL, maxSize: Int = 120) -> CGImage? {
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
    func applyFocusPeaking(to image: CIImage) -> CIImage {
        // 1. Convert to grayscale for edge detection
        let grayscaleKernel = CIColorKernel(source: """
            kernel vec4 grayscale(sampler src) {
                vec4 c = sample(src, samplerCoord(src));
                float lum = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
                return vec4(lum, lum, lum, 1.0);
            }
        """)
        let gray = grayscaleKernel?.apply(extent: image.extent, arguments: [image]) ?? image

        // 2. Laplacian edge detection (3x3 convolution)
        // Highlights sharp transitions = in-focus areas
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

        // 3. Threshold + colorize: strong edges become green lines, rest transparent
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

        // 4. Composite green lines over original image
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
