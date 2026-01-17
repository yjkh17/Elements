import SwiftUI
import UIKit

#if os(iOS)
struct MultiTouchControlView: UIViewRepresentable {
    var engine: ClothSimulationEngine
    var onInteraction: () -> Void
    
    func makeUIView(context: Context) -> TouchHandlerView {
        let view = TouchHandlerView()
        view.engine = engine
        view.onInteraction = onInteraction
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        return view
    }
    
    func updateUIView(_ uiView: TouchHandlerView, context: Context) {}
}

class TouchHandlerView: UIView {
    weak var engine: ClothSimulationEngine?
    var onInteraction: (() -> Void)?
    var cameraTouches: Set<UITouch> = []
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let engine = engine else { return }
        onInteraction?()
        
        for touch in touches {
            let loc = touch.location(in: self)
            if engine.isNearCloth(screenPoint: loc, viewSize: bounds.size) {
                engine.startGrab(at: loc, viewSize: bounds.size, touchID: touch.hash)
            } else {
                cameraTouches.insert(touch)
            }
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let engine = engine else { return }
        
        // Handle Camera Touches (Zoom or Rotate)
        let backgroundTouches = Array(cameraTouches)
        if backgroundTouches.count == 2 {
            // Pinch to Zoom
            let t1 = backgroundTouches[0]
            let t2 = backgroundTouches[1]
            
            let p1 = t1.location(in: self)
            let p2 = t2.location(in: self)
            let prev1 = t1.previousLocation(in: self)
            let prev2 = t2.previousLocation(in: self)
            
            let currentDist = hypot(Float(p1.x - p2.x), Float(p1.y - p2.y))
            let prevDist = hypot(Float(prev1.x - prev2.x), Float(prev1.y - prev2.y))
            
            if prevDist > 0 {
                let scale = currentDist / prevDist
                let newDistance = engine.cameraDistance / scale
                engine.cameraDistance = max(0.5, min(5.0, newDistance))
            }
        } else if backgroundTouches.count == 1 {
            // Rotate
            if let touch = touches.first(where: { cameraTouches.contains($0) }) {
                let loc = touch.location(in: self)
                let prev = touch.previousLocation(in: self)
                let deltaX = Float(loc.x - prev.x)
                let deltaY = Float(loc.y - prev.y)
                engine.rotateCamera(deltaX: deltaX, deltaY: -deltaY)
            }
        }
        
        // Handle Grabs (Independent of camera)
        for touch in touches {
            if !cameraTouches.contains(touch) {
                let loc = touch.location(in: self)
                engine.moveGrab(to: loc, touchID: touch.hash)
            }
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let engine = engine else { return }
        for touch in touches {
            if cameraTouches.contains(touch) {
                cameraTouches.remove(touch)
            } else {
                engine.endGrab(touchID: touch.hash)
            }
        }
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}
#endif
