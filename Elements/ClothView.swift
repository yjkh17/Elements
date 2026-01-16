import SwiftUI
import MetalKit

struct ClothView: View {
    @StateObject var engine = ClothSimulationEngine()
    var onExit: (() -> Void)?
    @State private var isDragging = false
    @State private var showUI = true
    @State private var hideTimer: Timer?
    @State private var lastDragLocation: CGPoint = .zero
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Metal view for simulation
                ClothMetalView(engine: engine)
                    .ignoresSafeArea()
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                resetHideTimer()
                                if showUI {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        showUI = false
                                    }
                                }
                                
                                if !isDragging {
                                    isDragging = true
                                    lastDragLocation = value.startLocation
                                    // Decide mode: grab cloth or rotate camera
                                    if engine.isNearCloth(screenPoint: value.startLocation, viewSize: geometry.size) {
                                        engine.interactionMode = .grabbing
                                        engine.startGrab(at: value.startLocation, viewSize: geometry.size)
                                    } else {
                                        engine.interactionMode = .rotating
                                    }
                                }
                                
                                // Continue based on mode
                                switch engine.interactionMode {
                                case .grabbing:
                                    engine.moveGrab(to: value.location)
                                case .rotating:
                                    let deltaX = Float(value.location.x - lastDragLocation.x)
                                    let deltaY = Float(value.location.y - lastDragLocation.y)
                                    engine.rotateCamera(deltaX: deltaX, deltaY: -deltaY)
                                case .none:
                                    break
                                }
                                lastDragLocation = value.location
                            }
                            .onEnded { _ in
                                if engine.interactionMode == .grabbing {
                                    engine.endGrab()
                                }
                                engine.interactionMode = .none
                                isDragging = false
                                startHideTimer()
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    showUI = true
                                }
                            }
                    )
                
                // HUD - Top Bar
                if showUI {
                    VStack {
                        HStack {
                            Button(action: { onExit?() }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 16, weight: .bold))
                                    Text("LAB")
                                        .font(.system(size: 13, weight: .black))
                                        .kerning(1)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 1))
                            }
                            .allowsHitTesting(true) // Explicitly allow button tap
                            .padding(.leading, 20)
                            .padding(.top, geometry.safeAreaInsets.top > 0 ? geometry.safeAreaInsets.top : 20)
                            
                            Spacer()
                        }
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // HUD - Bottom Panel
                if showUI {
                    VStack {
                        Spacer()
                        VStack(spacing: 20) {
                            // Bending Compliance Header
                            VStack(spacing: 8) {
                                HStack {
                                    Text("BENDING STIFFNESS")
                                        .font(.system(size: 10, weight: .black))
                                        .kerning(1.5)
                                        .foregroundStyle(.white.opacity(0.6))
                                    Spacer()
                                    Text("\(engine.compliance, specifier: "%.1f")")
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white)
                                }
                                Slider(value: $engine.compliance, in: 0...10.0).tint(.red)
                            }
                            .padding(.horizontal)
                            
                            // Main controls
                            HStack(spacing: 15) {
                                // Pause/Run button
                                Button(action: { 
                                    engine.isPaused.toggle()
                                    resetHideTimer(); startHideTimer()
                                }) {
                                    HStack {
                                        Image(systemName: engine.isPaused ? "play.fill" : "pause.fill")
                                        Text(engine.isPaused ? "RESUME" : "PAUSE")
                                            .font(.system(size: 12, weight: .bold))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(engine.isPaused ? Color.green.opacity(0.8) : Color.orange.opacity(0.8))
                                    .cornerRadius(12)
                                }
                                
                                // Reset button
                                Button(action: {
                                    engine.resetSimulation(); engine.isPaused = true
                                    resetHideTimer(); startHideTimer()
                                }) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 18, weight: .bold))
                                        .frame(width: 50, height: 44)
                                        .background(Color.white.opacity(0.1))
                                        .cornerRadius(12)
                                }
                                
                                // Edges Toggle
                                Button(action: {
                                    engine.showWireframe.toggle()
                                    resetHideTimer(); startHideTimer()
                                }) {
                                    VStack(spacing: 2) {
                                        Image(systemName: engine.showWireframe ? "square.grid.2x2.fill" : "square.grid.2x2")
                                        Text("EDGES").font(.system(size: 8, weight: .bold))
                                    }
                                    .frame(width: 60, height: 44)
                                    .background(engine.showWireframe ? Color.blue.opacity(0.6) : Color.white.opacity(0.1))
                                    .cornerRadius(12)
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal)
                        }
                        .padding(.top, 25)
                        .padding(.bottom, geometry.safeAreaInsets.bottom + 15)
                        .background(
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
                        )
                        .allowsHitTesting(true) // Explicitly allow panel interactions
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea()
        }
    }
    
    private func startHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                showUI = true
            }
        }
    }
    
    private func resetHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }
}

#if os(macOS)
typealias ClothViewRepresentable = NSViewRepresentable
#else
typealias ClothViewRepresentable = UIViewRepresentable
#endif

struct ClothMetalView: ClothViewRepresentable {
    @ObservedObject var engine: ClothSimulationEngine
    
    #if os(macOS)
    func makeNSView(context: Context) -> MTKView {
        setupView()
    }
    func updateNSView(_ view: MTKView, context: Context) {}
    #else
    func makeUIView(context: Context) -> MTKView {
        setupView()
    }
    func updateUIView(_ view: MTKView, context: Context) {}
    #endif
    
    private func setupView() -> MTKView {
        let mtkView = MTKView()
        mtkView.device = engine.device
        mtkView.delegate = engine
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0)
        mtkView.clearDepth = 1.0
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        return mtkView
    }
}

#Preview {
    ClothView()
}
