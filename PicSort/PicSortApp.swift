import SwiftUI
import Metal
import CoreImage

@main
struct PicSortApp: App {
    @StateObject private var session = CullingSession()

    private let device: MTLDevice
    /// Single shared CIContext bound to the default Metal device.
    /// CIContext is thread-safe and expensive to create (GPU shader compilation on first use).
    private let ciContext: CIContext

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device
        self.ciContext = CIContext(mtlDevice: device)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .environment(\.ciContext, ciContext)
                .environment(\.metalDevice, device)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
    }
}

// MARK: - Environment Keys

private struct CIContextKey: EnvironmentKey {
    static let defaultValue: CIContext? = nil
}

private struct MetalDeviceKey: EnvironmentKey {
    static let defaultValue: MTLDevice? = nil
}

extension EnvironmentValues {
    var ciContext: CIContext? {
        get { self[CIContextKey.self] }
        set { self[CIContextKey.self] = newValue }
    }

    var metalDevice: MTLDevice? {
        get { self[MetalDeviceKey.self] }
        set { self[MetalDeviceKey.self] = newValue }
    }
}
