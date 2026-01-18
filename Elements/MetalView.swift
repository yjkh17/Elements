import SwiftUI
import MetalKit

struct MetalView: ViewRepresentable {
    @ObservedObject var engine: WaterSimulationEngine
    
    var onInteractionStart: (() -> Void)? = nil
    var onInteractionEnd: (() -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    var showZoomHUD: ((Bool) -> Void)? = nil

    #if os(macOS)
    func makeNSView(context: Context) -> InteractiveMTKView {
        setupView()
    }
    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {
        nsView.engine = engine
    }
    #elseif os(iOS)
    func makeUIView(context: Context) -> InteractiveMTKView {
        let view = setupView()
        
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        
        return view
    }
    func updateUIView(_ uiView: InteractiveMTKView, context: Context) {
        uiView.engine = engine
        context.coordinator.engine = engine
        context.coordinator.parent = self
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine, parent: self)
    }
    
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var engine: WaterSimulationEngine
        var parent: MetalView
        var baseZoom: Float = 1.0
        
        init(engine: WaterSimulationEngine, parent: MetalView) {
            self.engine = engine
            self.parent = parent
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
        
        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            parent.onDoubleTap?()
        }
        
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began {
                baseZoom = engine.settings.zoomLevel
                parent.onInteractionStart?()
                parent.showZoomHUD?(true)
            }
            
            let newZoom = max(1.0, min(10.0, baseZoom * Float(gesture.scale)))
            
            // Anchored Zooming logic (similar to WaterView)
            if let view = gesture.view {
                let location = gesture.location(in: view)
                let width = Float(view.bounds.width)
                let height = Float(view.bounds.height)
                let ndcX = (Float(location.x) / width) * 2.0 - 1.0
                let ndcY = (1.0 - Float(location.y) / height) * 2.0 - 1.0
                
                let oldZoom = engine.settings.zoomLevel
                let center = engine.uniforms.domainSize * 0.5
                
                let oldWorldX = (ndcX * center.x) / oldZoom + (center.x + engine.settings.zoomOffset.x)
                let oldWorldY = (ndcY * center.y) / oldZoom + (center.y + engine.settings.zoomOffset.y)
                
                engine.settings.zoomLevel = newZoom
                
                let newWorldX = (ndcX * center.x) / newZoom + (center.x + engine.settings.zoomOffset.x)
                let newWorldY = (ndcY * center.y) / newZoom + (center.y + engine.settings.zoomOffset.y)
                
                engine.settings.zoomOffset.x += (oldWorldX - newWorldX)
                engine.settings.zoomOffset.y += (oldWorldY - newWorldY)
                
                // Boundary clamping
                let maxOffX = center.x * (1.0 - 1.0 / newZoom)
                let maxOffY = center.y * (1.0 - 1.0 / newZoom)
                engine.settings.zoomOffset.x = max(-maxOffX, min(maxOffX, engine.settings.zoomOffset.x))
                engine.settings.zoomOffset.y = max(-maxOffY, min(maxOffY, engine.settings.zoomOffset.y))
            }
            
            if gesture.state == .ended || gesture.state == .cancelled {
                parent.onInteractionEnd?()
                parent.showZoomHUD?(false)
            }
        }
        
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let translation = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            
            if gesture.state == .ended || gesture.state == .cancelled {
                engine.hideObstacle()
                parent.onInteractionEnd?()
                return
            }
            
            if gesture.numberOfTouches == 2 {
                // Panning
                let zoom = engine.settings.zoomLevel
                if zoom <= 1.01 { return }
                
                let center = engine.uniforms.domainSize * 0.5
                let dx = -Float(translation.x / view.bounds.width) * center.x * 2.0 / zoom
                let dy = Float(translation.y / view.bounds.height) * center.y * 2.0 / zoom
                
                engine.settings.zoomOffset.x += dx
                engine.settings.zoomOffset.y += dy
                
                // Boundary clamping
                let maxOffX = center.x * (1.0 - 1.0 / zoom)
                let maxOffY = center.y * (1.0 - 1.0 / zoom)
                engine.settings.zoomOffset.x = max(-maxOffX, min(maxOffX, engine.settings.zoomOffset.x))
                engine.settings.zoomOffset.y = max(-maxOffY, min(maxOffY, engine.settings.zoomOffset.y))
                
                engine.hideObstacle() // Hide obstacle while panning
            } else if gesture.numberOfTouches == 1 {
                // Obstacle Interaction
                if gesture.state == .began {
                    parent.onInteractionStart?()
                }
                
                let width = Float(view.bounds.width)
                let height = Float(view.bounds.height)
                let ndcX = (Float(location.x) / width) * 2.0 - 1.0
                let ndcY = (1.0 - Float(location.y) / height) * 2.0 - 1.0
                
                let center = engine.uniforms.domainSize * 0.5
                let x = (ndcX * center.x) / engine.settings.zoomLevel + (center.x + engine.settings.zoomOffset.x)
                let y = (ndcY * center.y) / engine.settings.zoomLevel + (center.y + engine.settings.zoomOffset.y)
                
                engine.setObstacle(x: x, y: y, reset: false)
            }
        }
    }
    #endif
    
    private func setupView() -> InteractiveMTKView {
        let mtkView = InteractiveMTKView()
        mtkView.engine = engine
        mtkView.device = engine.device
        mtkView.delegate = engine
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.clearColor = MTLClearColor(red: 0.76, green: 0.70, blue: 0.50, alpha: 1.0)
        return mtkView
    }
}

class InteractiveMTKView: MTKView {
    var engine: WaterSimulationEngine?
    
    #if os(macOS)
    override func scrollWheel(with event: NSEvent) {
        guard let engine = engine, engine.settings.zoomLevel > 1.01 else {
            super.scrollWheel(with: event)
            return
        }
        
        let zoom = engine.settings.zoomLevel
        let center = engine.uniforms.domainSize * 0.5
        
        // Mouse wheel or trackpad scroll
        let dx = -Float(event.scrollingDeltaX / self.bounds.width) * center.x * 2.0 / zoom
        let dy = Float(event.scrollingDeltaY / self.bounds.height) * center.y * 2.0 / zoom
        
        engine.settings.zoomOffset.x += dx
        engine.settings.zoomOffset.y += dy
        
        // Boundary clamping
        let maxOffX = center.x * (1.0 - 1.0 / zoom)
        let maxOffY = center.y * (1.0 - 1.0 / zoom)
        engine.settings.zoomOffset.x = max(-maxOffX, min(maxOffX, engine.settings.zoomOffset.x))
        engine.settings.zoomOffset.y = max(-maxOffY, min(maxOffY, engine.settings.zoomOffset.y))
    }
    #endif
}
