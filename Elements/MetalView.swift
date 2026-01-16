import SwiftUI
import MetalKit

struct MetalView: ViewRepresentable {
    @ObservedObject var engine: WaterSimulationEngine
    
    #if os(macOS)
    func makeNSView(context: Context) -> MTKView {
        setupView()
    }
    func updateNSView(_ nsView: MTKView, context: Context) {}
    #elseif os(iOS)
    func makeUIView(context: Context) -> MTKView {
        setupView()
    }
    func updateUIView(_ uiView: MTKView, context: Context) {}
    #endif
    
    private func setupView() -> MTKView {
        let mtkView = MTKView()
        mtkView.device = engine.device
        mtkView.delegate = engine
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1.0)
        return mtkView
    }
}
