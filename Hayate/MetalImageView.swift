import SwiftUI
import MetalKit

/// NSViewRepresentable wrapper around MTKView for displaying MTLTextures.
/// Supports zoom and pan via scale/offset parameters.
struct MetalImageView: NSViewRepresentable {
    let texture: MTLTexture?
    let device: MTLDevice
    var zoomScale: CGFloat = 1.0
    var panOffset: CGPoint = .zero
    /// Updated from `MTKView.drawableSize` (physical pixels, Retina-aware).
    @Binding var reportedDrawableSize: CGSize
    @Environment(\.colorScheme) private var colorScheme

    init(
        texture: MTLTexture?,
        device: MTLDevice,
        zoomScale: CGFloat = 1.0,
        panOffset: CGPoint = .zero,
        reportedDrawableSize: Binding<CGSize> = .constant(.zero)
    ) {
        self.texture = texture
        self.device = device
        self.zoomScale = zoomScale
        self.panOffset = panOffset
        _reportedDrawableSize = reportedDrawableSize
    }

    /// `zoomScale` where one image texel maps to one drawable pixel (100% / 1:1).
    /// `drawableSize` must be physical pixels (`MTKView.drawableSize`), not points.
    static func oneToOneZoomScale(textureSize: CGSize, drawableSize: CGSize) -> CGFloat {
        guard textureSize.width > 0, textureSize.height > 0,
              drawableSize.width > 0, drawableSize.height > 0 else {
            return 1.0
        }
        let viewAspect = drawableSize.width / drawableSize.height
        let texAspect = textureSize.width / textureSize.height

        var baseX = 1.0 as CGFloat
        var baseY = 1.0 as CGFloat
        if texAspect > viewAspect {
            baseY = viewAspect / texAspect
        } else {
            baseX = texAspect / viewAspect
        }

        // Fit (`zoomScale` 1) maps the texture into `baseX`/`baseY` NDC half-extents;
        // displayed texel width = baseX * zoomScale * drawableWidth.
        let scaleX = textureSize.width / (baseX * drawableSize.width)
        let scaleY = textureSize.height / (baseY * drawableSize.height)
        return max(scaleX, scaleY)
    }

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = HayateTheme.metalClear(for: colorScheme)
        mtkView.layer?.isOpaque = true
        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.reportedDrawableSize = $reportedDrawableSize
        context.coordinator.texture = texture
        context.coordinator.zoomScale = Float(zoomScale)
        context.coordinator.panOffset = panOffset
        mtkView.clearColor = HayateTheme.metalClear(for: colorScheme)
        publishDrawableSize(from: mtkView)
        mtkView.setNeedsDisplay(mtkView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(device: device, reportedDrawableSize: $reportedDrawableSize)
    }

    private func publishDrawableSize(from view: MTKView) {
        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        if reportedDrawableSize != size {
            reportedDrawableSize = size
        }
    }

    @MainActor
    class Coordinator: NSObject, @preconcurrency MTKViewDelegate {
        var texture: MTLTexture?
        var zoomScale: Float = 1.0
        var panOffset: CGPoint = .zero
        private let commandQueue: MTLCommandQueue?
        private let pipelineState: MTLRenderPipelineState?
        /// Bounds in-flight display command buffers so a backed-up GPU drops
        /// frames instead of blocking the main thread on `currentDrawable`.
        nonisolated let frameSemaphore = DispatchSemaphore(value: 2)
        /// Frame-drop bookkeeping. Main thread only (draw and the completion
        /// handler's main-hop both run there).
        private var redrawPending = false
        private weak var lastView: MTKView?

        var reportedDrawableSize: Binding<CGSize>

        init(device: MTLDevice, reportedDrawableSize: Binding<CGSize>) {
            self.reportedDrawableSize = reportedDrawableSize
            self.commandQueue = device.makeCommandQueue()

            let library: MTLLibrary?
            do {
                library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            } catch {
                library = nil
            }

            if let library = library,
               let vertexFunc = library.makeFunction(name: "vertexShader"),
               let fragmentFunc = library.makeFunction(name: "fragmentShader") {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunc
                descriptor.fragmentFunction = fragmentFunc
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                self.pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
            } else {
                self.pipelineState = nil
            }

            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            if reportedDrawableSize.wrappedValue != size {
                reportedDrawableSize.wrappedValue = size
            }
        }

        func draw(in view: MTKView) {
            let drawableSize = view.drawableSize
            if drawableSize.width > 0, drawableSize.height > 0,
               reportedDrawableSize.wrappedValue != drawableSize {
                reportedDrawableSize.wrappedValue = drawableSize
            }

            // Bound in-flight display work: when the GPU is backed up (heavy
            // RAW renders during rapid navigation), drop the frame instead of
            // blocking the main thread inside `view.currentDrawable` (drawable
            // pool exhaustion). A blocked main thread froze the whole UI —
            // and delayed folder switching — until the GPU drained.
            guard frameSemaphore.wait(timeout: .now()) == .success else {
                redrawPending = true
                lastView = view
                return
            }

            guard let commandQueue = commandQueue,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                frameSemaphore.signal()
                return
            }

            if let texture = texture, let pipelineState = pipelineState {
                // Aspect-fit base scale
                let viewAspect = view.drawableSize.width / view.drawableSize.height
                let texAspect = Double(texture.width) / Double(texture.height)

                var baseX: Float = 1.0
                var baseY: Float = 1.0

                if texAspect > viewAspect {
                    baseY = Float(viewAspect / texAspect)
                } else {
                    baseX = Float(texAspect / viewAspect)
                }

                // Apply zoom
                let sx = baseX * zoomScale
                let sy = baseY * zoomScale

                // Apply pan (in NDC, clamped so image edge stays visible)
                let maxPanX = max(0, sx - 1.0)
                let maxPanY = max(0, sy - 1.0)
                let px = min(max(Float(panOffset.x), -maxPanX), maxPanX)
                let py = min(max(Float(panOffset.y), -maxPanY), maxPanY)

                let vertices: [Float] = [
                    -sx + px, -sy + py, 0.0, 0.0,
                     sx + px, -sy + py, 1.0, 0.0,
                    -sx + px,  sy + py, 0.0, 1.0,
                     sx + px,  sy + py, 1.0, 1.0,
                ]

                encoder.setRenderPipelineState(pipelineState)
                encoder.setVertexBytes(vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            // No texture yet: the render pass' clear color shows the background.

            encoder.endEncoding()
            commandBuffer.addCompletedHandler { [weak self] _ in
                guard let self else { return }
                self.frameSemaphore.signal()
                Task { @MainActor in
                    // A frame was dropped while the GPU was busy — draw the
                    // latest state now that a slot freed up.
                    if self.redrawPending, let view = self.lastView {
                        self.redrawPending = false
                        view.setNeedsDisplay(view.bounds)
                    }
                }
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                                      constant float4 *vertices [[buffer(0)]]) {
            VertexOut out;
            float4 v = vertices[vertexID];
            out.position = float4(v.x, v.y, 0.0, 1.0);
            out.texCoord = float2(v.z, v.w);
            return out;
        }

        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(mag_filter::linear, min_filter::linear);
            return tex.sample(s, in.texCoord);
        }
        """
    }
}
