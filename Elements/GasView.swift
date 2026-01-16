
import SwiftUI
import MetalKit

struct GasMetalView: ViewRepresentable {
    @ObservedObject var engine: GasSimulationEngine
    
    #if os(macOS)
    func makeNSView(context: Context) -> MTKView { setupView() }
    func updateNSView(_ nsView: MTKView, context: Context) {}
    #elseif os(iOS)
    func makeUIView(context: Context) -> MTKView { setupView() }
    func updateUIView(_ uiView: MTKView, context: Context) {}
    #endif
    
    private func setupView() -> MTKView {
        let mtkView = MTKView()
        mtkView.device = engine.device
        mtkView.delegate = engine
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        return mtkView
    }
}

struct GasView: View {
    @StateObject private var engine = GasSimulationEngine()
    var onExit: (() -> Void)? = nil
    @State private var canvasSize: CGSize = .zero
    @State private var showSettings = false
    @State private var isCollapsed = true 
    @State private var showUI = true
    @State private var hideTimer: Timer?
    
    // Simplified interaction: Drag to move the circular obstacle
    @State private var isDraggingObstacle = false
    
    var body: some View {
        ZStack(alignment: .top) { 
            GasMetalView(engine: engine)
                .ignoresSafeArea()
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            resetHideTimer()
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showUI = false
                            }
                            
                            let width = Float(canvasSize.width)
                            let height = Float(canvasSize.height)
                            let x: Float
                            let y: Float
                            
                            if engine.isVertical {
                                x = (1.0 - Float(value.location.y) / height) * Float(engine.gridRes.x)
                                y = (Float(value.location.x) / width) * Float(engine.gridRes.y)
                            } else {
                                x = Float(value.location.x) / width * Float(engine.gridRes.x)
                                y = (Float(value.location.y) / height) * Float(engine.gridRes.y)
                            }
                        
                            engine.moveMainObstacle(x: x, y: y)
                        }
                        .onEnded { _ in
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
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { 
                                canvasSize = geo.size
                                engine.updateResolution(to: geo.size)
                            }
                            .onChange(of: geo.size) { _, newValue in
                                canvasSize = newValue
                                engine.updateResolution(to: newValue)
                            }
                    }
                )
            
            if showUI {
                GasTopGlassDock(engine: engine, isCollapsed: $isCollapsed, onExit: onExit)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
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

struct GasTopGlassDock: View {
    @ObservedObject var engine: GasSimulationEngine
    @Binding var isCollapsed: Bool
    var onExit: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            if !isCollapsed {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        // 1. SCENARIOS Section
                        ControlSection(title: "SCENARIOS", icon: "map.fill") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ScenarioButton(title: "Wind Tunnel", isSelected: engine.currentScenario == .windTunnel) {
                                        engine.currentScenario = .windTunnel; engine.reset()
                                    }
                                    ScenarioButton(title: "Hires Tunnel", isSelected: engine.currentScenario == .hiresTunnel) {
                                        engine.currentScenario = .hiresTunnel; engine.reset()
                                    }
                                    ScenarioButton(title: "Tank", isSelected: engine.currentScenario == .tank) {
                                        engine.currentScenario = .tank; engine.reset()
                                    }
                                    ScenarioButton(title: "Paint", isSelected: engine.currentScenario == .paint) {
                                        engine.currentScenario = .paint; engine.reset()
                                    }
                                }
                            }
                        }
                        
                        // 2. PHYSICS Section
                        ControlSection(title: "PHYSICS", icon: "wind") {
                            VStack(alignment: .leading, spacing: 14) {
                                SliderItem(label: "Wind Speed", icon: "gauge.with.dots.needle.bottom.50percent", value: $engine.windSpeed, range: 0...10.0)
                                SliderItem(label: "Buoyancy", icon: "arrow.up.circle", value: $engine.buoyancyStrength, range: -1.0...1.0)
                                SliderItem(label: "Swirl", icon: "vortex", value: $engine.vorticityStrength, range: 0...2.0)
                            }
                        }
                        
                        // 3. RENDER Section
                        ControlSection(title: "VISUALS", icon: "eye.fill") {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                IconToggle(isOn: $engine.showSmoke, icon: "smoke.fill", label: "Smoke")
                                IconToggle(isOn: $engine.showPressure, icon: "p.circle.fill", label: "Pressure")
                                IconToggle(isOn: $engine.showStreamlines, icon: "wave.3.forward", label: "Stream")
                                IconToggle(isOn: $engine.overrelax, icon: "bolt.fill", label: "Overrelax")
                            }
                        }
                        
                        Button(action: { engine.reset() }) {
                            Label("Reset Simulation", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    .padding(20)
                }
                .background {
                    VisualEffectView(material: .glassMaterial)
                        .ignoresSafeArea()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .frame(maxHeight: 500)
            }
            
            // Phase 58: Unified Top Bar (Exit Left, Menu Right)
            HStack(spacing: 0) {
                // Exit Button (Left) - Standardized Back Position
                Button(action: { onExit?() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                        Text("LAB")
                            .font(.system(size: 11, weight: .black))
                            .tracking(1)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                }
                .buttonStyle(ConditionalButtonStyle())
                .padding(.leading, 20)
                
                Spacer()
                
                // Menu Button (Right) - Glass Capsule
                Button(action: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        isCollapsed.toggle()
                    }
                }) {
                    HStack(spacing: 8) {
                        Text(isCollapsed ? "MENU" : "CLOSE")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1)
                        
                        Image(systemName: isCollapsed ? "slider.horizontal.3" : "chevron.up")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background {
                        VisualEffectView(material: .glassMaterial)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                    }
                }
                .buttonStyle(ConditionalButtonStyle())
                .padding(.trailing, 20)
            }
            .padding(.top, 55) // Phase 60: Fine-tuned lower position
            .zIndex(100)
        }

    }
}
// Helper Components
struct ScenarioButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.blue.opacity(0.8) : Color.clear)
                .foregroundColor(.white)
                .clipShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// Custom Checkbox-style Toggle
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(configuration.isOn ? .blue : .white.opacity(0.3))
                
                configuration.label
                    .foregroundColor(configuration.isOn ? .white : .white.opacity(0.6))
                    .font(.system(size: 11, weight: .bold))
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}
