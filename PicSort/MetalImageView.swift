import SwiftUI
import MetalKit

/// NSViewRepresentable wrapper around MTKView for displaying MTLTextures.
/// Supports zoom and pan via scale/offset parameters.
struct MetalImageView: NSViewRepresentable {
    let texture: MTLTexture?
    let device: MTLDevice
    var zoomScale: CGFloat = 1.0
    var panOffset: CGPoint = .zero

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        mtkView.layer?.isOpaque = true
        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.texture = texture
        context.coordinator.zoomScale = Float(zoomScale)
        context.coordinator.panOffset = panOffset
        mtkView.setNeedsDisplay(mtkView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(device: device)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var texture: MTLTexture?
        var zoomScale: Float = 1.0
        var panOffset: CGPoint = .zero
        private let commandQueue: MTLCommandQueue?
        private let pipelineState: MTLRenderPipelineState?

        init(device: MTLDevice) {
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

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let texture = texture,
                  let pipelineState = pipelineState,
                  let commandQueue = commandQueue,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else {
                guard let commandQueue = commandQueue,
                      let drawable = view.currentDrawable,
                      let descriptor = view.currentRenderPassDescriptor else { return }
                let commandBuffer = commandQueue.makeCommandBuffer()!
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)!
                encoder.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

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

            let commandBuffer = commandQueue.makeCommandBuffer()!
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)!
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBytes(vertices, length: vertices.count * MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
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
