import Accelerate
import Combine
import CoreGraphics
import Foundation
import ImageIO
import Vision

// MARK: - Result

struct PhotoAnalysisResult: Sendable, Equatable {
    let sharpness: Double
    let faceCount: Int
    /// Highest `VNFaceObservation.faceCaptureQuality` when faces are present.
    let faceQuality: Double?
}

// MARK: - Review heuristics (folder-relative)

enum PhotoAnalysisReview {
    private static let bottomPercentile = 0.10
    /// Sharpness must also fall below this fraction of the folder median.
    private static let medianFactor = 0.55
    private static let lowFaceQualityThreshold = 0.35
    private static let minimumSampleCount = 5

    static func needsReviewURLs(from results: [URL: PhotoAnalysisResult]) -> Set<URL> {
        guard results.count >= minimumSampleCount else { return [] }

        let sortedSharpness = results.values.map(\.sharpness).sorted()
        let count = sortedSharpness.count
        let p10Index = max(0, Int(Double(count - 1) * bottomPercentile))
        let p10Threshold = sortedSharpness[p10Index]

        let median: Double
        if count.isMultiple(of: 2) {
            median = (sortedSharpness[count / 2 - 1] + sortedSharpness[count / 2]) / 2
        } else {
            median = sortedSharpness[count / 2]
        }

        var flagged = Set<URL>()
        for (url, result) in results {
            let blurry = result.sharpness <= p10Threshold && result.sharpness < median * medianFactor
            let weakFace = result.faceCount > 0 && (result.faceQuality ?? 1) < lowFaceQualityThreshold
            if blurry || weakFace {
                flagged.insert(url)
            }
        }
        return flagged
    }
}

// MARK: - Engine

enum PhotoAnalysisEngine {
    static let analysisMaxPixelSize = 512

    nonisolated static func analyze(cgImage: CGImage) -> PhotoAnalysisResult? {
        guard let scaled = downscaled(cgImage, maxPixelSize: analysisMaxPixelSize) else { return nil }
        guard let sharpness = laplacianVariance(of: scaled) else { return nil }
        let (faceCount, faceQuality) = detectFaces(in: scaled)
        return PhotoAnalysisResult(sharpness: sharpness, faceCount: faceCount, faceQuality: faceQuality)
    }

    private nonisolated static func downscaled(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let w = image.width
        let h = image.height
        let longest = max(w, h)
        guard longest > maxPixelSize, maxPixelSize > 0 else { return image }

        let scale = CGFloat(maxPixelSize) / CGFloat(longest)
        let newW = max(1, Int((CGFloat(w) * scale).rounded()))
        let newH = max(1, Int((CGFloat(h) * scale).rounded()))

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return context.makeImage()
    }

    /// Laplacian variance on an 8-bit luminance plane (higher → sharper).
    private nonisolated static func laplacianVariance(of image: CGImage) -> Double? {
        let width = image.width
        let height = image.height
        guard width >= 3, height >= 3 else { return nil }

        var gray = [UInt8](repeating: 0, count: width * height)
        guard let graySpace = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        guard let context = CGContext(
            data: &gray,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: graySpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return gray.withUnsafeMutableBytes { rawBuffer -> Double? in
            guard let base = rawBuffer.baseAddress else { return nil }
            var srcBuffer = vImage_Buffer(
                data: base,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width
            )

            let destBytes = width * height
            guard let destData = malloc(destBytes) else { return nil }
            defer { free(destData) }

            var destBuffer = vImage_Buffer(
                data: destData,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width
            )

            let kernel: [Int16] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
            let convError = kernel.withUnsafeBufferPointer { kernelPtr in
                vImageConvolve_Planar8(
                    &srcBuffer,
                    &destBuffer,
                    nil,
                    0, 0,
                    kernelPtr.baseAddress!,
                    3, 3,
                    1,
                    0,
                    vImage_Flags(kvImageEdgeExtend)
                )
            }
            guard convError == kvImageNoError else { return nil }

            let pixelCount = width * height
            var floatPixels = [Float](repeating: 0, count: pixelCount)
            let variance: Double? = floatPixels.withUnsafeMutableBufferPointer { floatPtr -> Double? in
                guard let floatBase = floatPtr.baseAddress else { return nil }
                var floatBuffer = vImage_Buffer(
                    data: floatBase,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.size
                )
                let convertError = vImageConvert_Planar8toPlanarF(
                    &destBuffer,
                    &floatBuffer,
                    255,
                    0,
                    vImage_Flags(kvImageNoFlags)
                )
                guard convertError == kvImageNoError else { return nil }

                var mean: Float = 0
                vDSP_meanv(floatBase, 1, &mean, vDSP_Length(pixelCount))
                var meanSquare: Float = 0
                vDSP_measqv(floatBase, 1, &meanSquare, vDSP_Length(pixelCount))
                return Double(meanSquare - mean * mean)
            }
            guard let variance else { return nil }
            return max(0, variance)
        }
    }

    /// `VNDetectFaceCaptureQualityRequest` detects faces and populates
    /// `faceCaptureQuality` on its own observations (not on rectangle-request results).
    private nonisolated static func detectFaces(in image: CGImage) -> (count: Int, maxQuality: Double?) {
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([qualityRequest])
        } catch {
            return (0, nil)
        }
        guard let faces = qualityRequest.results, !faces.isEmpty else {
            return (0, nil)
        }
        let qualities = faces.compactMap(\.faceCaptureQuality).map(Double.init)
        return (faces.count, qualities.max())
    }
}

// MARK: - Background runner

/// Holds in-memory analysis results and review flags for the current folder.
@MainActor
final class PhotoAnalysisStore: ObservableObject {
    @Published private(set) var results: [URL: PhotoAnalysisResult] = [:]
    @Published private(set) var needsReview: Set<URL> = []

    private let runner = PhotoAnalysisRunner()
    private var sessionTask: Task<Void, Never>?
    private var activeGeneration = 0

    func stop() {
        activeGeneration += 1
        sessionTask?.cancel()
        results = [:]
        needsReview = []
        let token = activeGeneration
        sessionTask = Task { await runner.beginSession(token: token) }
    }

    func start(
        generation: Int,
        enabled: Bool,
        files: [URL],
        focusIndex: Int,
        decoder: ImageDecoder
    ) {
        sessionTask?.cancel()
        activeGeneration = generation
        results = [:]
        needsReview = []

        let gen = generation
        guard enabled, !files.isEmpty else {
            sessionTask = Task { await runner.beginSession(token: gen) }
            return
        }

        let ordered = PrefetchManager.radialOrder(files: files, focusIndex: focusIndex)
        sessionTask = Task {
            await runner.beginSession(token: gen)
            guard !Task.isCancelled else { return }
            await runner.analyze(
                token: gen,
                files: ordered,
                decoder: decoder
            ) { [weak self] batch in
                guard let self, gen == self.activeGeneration else { return }
                for (url, result) in batch {
                    self.results[url] = result
                }
                self.needsReview = PhotoAnalysisReview.needsReviewURLs(from: self.results)
            }
        }
    }
}

/// Low-priority folder scan. Cancelled on folder change via session token.
actor PhotoAnalysisRunner {
    private var workTask: Task<Void, Never>?
    private var sessionToken = 0

    func beginSession(token: Int) {
        workTask?.cancel()
        workTask = nil
        sessionToken = token
    }

    func analyze(
        token: Int,
        files: [URL],
        decoder: ImageDecoder,
        maxConcurrent: Int = 2,
        onBatch: @escaping @MainActor @Sendable ([(URL, PhotoAnalysisResult)]) -> Void
    ) {
        guard token == sessionToken else { return }
        workTask?.cancel()
        let parallelism = max(1, min(maxConcurrent, 4))
        workTask = Task.detached(priority: .utility) {
            var index = 0
            while index < files.count {
                guard !Task.isCancelled else { return }
                let currentToken = await self.sessionToken
                guard token == currentToken else { return }

                let end = min(index + parallelism, files.count)
                let batchURLs = Array(files[index..<end])
                index = end

                var batchResults: [(URL, PhotoAnalysisResult)] = []
                batchResults.reserveCapacity(batchURLs.count)

                await withTaskGroup(of: (URL, PhotoAnalysisResult?).self) { group in
                    for url in batchURLs {
                        group.addTask {
                            guard !Task.isCancelled else { return (url, nil) }
                            guard let image = await Self.loadAnalysisImage(url: url, decoder: decoder) else {
                                return (url, nil)
                            }
                            guard !Task.isCancelled else { return (url, nil) }
                            let result = PhotoAnalysisEngine.analyze(cgImage: image)
                            return (url, result)
                        }
                    }
                    for await (url, result) in group {
                        guard !Task.isCancelled else { return }
                        if let result {
                            batchResults.append((url, result))
                        }
                    }
                }

                guard !Task.isCancelled else { return }
                let batchToken = await self.sessionToken
                guard token == batchToken else { return }
                guard !batchResults.isEmpty else { continue }
                await onBatch(batchResults)
            }
        }
    }

    /// Avoid `DiskCacheManager.loadPreview` — decode small sources only.
    private static func loadAnalysisImage(url: URL, decoder: ImageDecoder) async -> CGImage? {
        if let embedded = await decoder.extractJPEG(url: url) {
            return embedded
        }
        if let thumb = await decoder.extractThumbnail(
            url: url,
            maxSize: PhotoAnalysisEngine.analysisMaxPixelSize
        ) {
            return thumb
        }
        return thumbnailFromSourceFile(url: url, maxPixelSize: PhotoAnalysisEngine.analysisMaxPixelSize)
    }

    /// Bounded decode from the original file without touching the preview-cache actor.
    private nonisolated static func thumbnailFromSourceFile(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
