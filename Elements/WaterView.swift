//
//  ContentView.swift
//  Water
//
//  Created by Yousef Jawdat on 12/01/2026.
//

import SwiftUI

#if os(macOS)
import AppKit
typealias ViewRepresentable = NSViewRepresentable
#elseif os(iOS)
import UIKit
typealias ViewRepresentable = UIViewRepresentable
#endif

// MARK: - Main Content View
struct WaterView: View {
    @StateObject var engine = WaterSimulationEngine()
    var onExit: (() -> Void)? = nil
    @State private var showUI = true
    @State private var hideTimer: Timer?
    
    var body: some View {
        ZStack(alignment: .top) {
            simulationView
            if showUI {
                TopGlassDock(engine: engine, onExit: onExit)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color(red: 0.76, green: 0.70, blue: 0.50))
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
    
    // Sub-View: Simulation & Interaction
    var simulationView: some View {
        SimulationContainer(engine: engine, onInteractionStart: {
            resetHideTimer()
            withAnimation(.easeInOut(duration: 0.3)) {
                showUI = false
            }
        }, onInteractionEnd: {
            startHideTimer()
        }, onDoubleTap: {
            withAnimation(.easeInOut(duration: 0.3)) {
                showUI = true
            }
        })
    }
}

// MARK: - Unified Integrated Toolbar
struct TopGlassDock: View {
    @ObservedObject var engine: WaterSimulationEngine
    var onExit: (() -> Void)? = nil
    @State private var isCollapsed = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Expanded Controls (Glass Panel)
            if !isCollapsed {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        // 1. RENDER SECTION
                        ControlSection(title: "RENDER", icon: "eye.fill") {
                            VStack(alignment: .leading, spacing: 14) {
                                // Mode Switcher
                                RenderModeSwitcher(selectedMode: $engine.settings.renderMode)
                                
                                Divider().background(.white.opacity(0.1))
                                
                                // Sliders
                                VStack(alignment: .leading, spacing: 12) {
                                    SliderItem(label: "Refraction", icon: "aqi.medium", value: $engine.settings.refractStrength, range: 0...0.1)
                                        .opacity(engine.settings.renderMode == .liquid ? 1 : 0.5)
                                        .disabled(engine.settings.renderMode != .liquid)
                                    
                                    SliderItem(label: "Glow Intensity", icon: "sun.max.fill", value: $engine.settings.sssIntensity, range: 0...2.0)
                                        .opacity(engine.settings.renderMode == .liquid ? 1 : 0.5)
                                        .disabled(engine.settings.renderMode != .liquid)
                                    
                                    SliderItem(label: "Pixel Size", icon: "square.grid.2x2", value: $engine.settings.pixelSize, range: 1.0...10.0)
                                        .opacity(engine.settings.renderMode == .pixels ? 1 : 0.5)
                                        .disabled(engine.settings.renderMode != .pixels)
                                }
                            }
                        }
                        
                        // 2. PHYSICS SECTION
                        ControlSection(title: "PHYSICS", icon: "atom") {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 12) {
                                    IconToggle(isOn: $engine.settings.useGravity, icon: "arrow.down", label: "Gravity")
                                    // Gyro Toggle (iOS Only)
                                    #if os(iOS)
                                    IconToggle(isOn: $engine.settings.useGyro, icon: "iphone.gen3", label: "Tilt Control")
                                    #endif
                                }
                                
                                SliderItem(label: "Expansion", icon: "arrow.up.left.and.arrow.down.right", value: $engine.settings.volumeExpansion, range: 1.0...4.0)
                                
                                SliderItem(label: "Surface Tension", icon: "app.dashed", value: $engine.settings.surfaceTension, range: 0.0...2.0)
                                
                                SliderItem(label: "Hydrogen Strength", icon: "atom", value: $engine.settings.hydrogenStrength, range: 0.1...5.0)
                                    .disabled(!engine.settings.useHydrogenMod)
                                    .opacity(engine.settings.useHydrogenMod ? 1.0 : 0.5)
                                
                                HStack(spacing: 12) {
                                    IconToggle(isOn: $engine.settings.useHydrogenMod, icon: "hexagon.fill", label: "Hydrogen Bonding")
                                    IconToggle(isOn: $engine.settings.compensateDrift, icon: "arrow.left.and.right", label: "Drift Fix")
                                }
                                
                                HStack(spacing: 12) {
                                    IconToggle(isOn: $engine.settings.separateParticles, icon: "arrow.up.and.down.and.arrow.left.and.right", label: "Separate")
                                }
                                
                                Button(action: { engine.resetToCenterSplash() }) {
                                    Label("Center Splash", systemImage: "drop.triangle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.blue)
                            }
                        }
                        
                                // 3. TIME SECTION
                                ControlSection(title: "TIME CONTROL", icon: "clock.fill") {
                                    VStack(alignment: .leading, spacing: 14) {
                                        HStack {
                                            Label("Time Speed", systemImage: "speedometer")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Text(String(format: "%.2fx", engine.settings.timeScale))
                                                .font(.system(size: 10).monospacedDigit())
                                                .foregroundColor(.secondary.opacity(0.7))
                                        }
                                        
                                        HStack(spacing: 12) {
                                            Button(action: { engine.settings.timeScale = max(0.0, engine.settings.timeScale - 0.1) }) {
                                                Image(systemName: "minus.circle.fill")
                                                    .font(.system(size: 16))
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundColor(.blue)
                                            
                                            Slider(value: $engine.settings.timeScale, in: 0.0...2.0)
                                            
                                            Button(action: { engine.settings.timeScale = min(2.0, engine.settings.timeScale + 0.1) }) {
                                                Image(systemName: "plus.circle.fill")
                                                    .font(.system(size: 16))
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundColor(.blue)
                                        }
                                    }
                                }
                                
                                // 4. SIMULATION SECTION
                        ControlSection(title: "SIMULATION", icon: "gamecontroller.fill") {
                            VStack(alignment: .leading, spacing: 14) {
                                Picker("Mode", selection: $engine.settings.interactionMode) {
                                    Text("Solid").tag(0)
                                    Text("Vortex").tag(1)
                                    Text("Force").tag(2)
                                    Text("Emit").tag(3)
                                }
                                .pickerStyle(.segmented)
                                
                                // Force Strength Slider (Conditional)
                                if engine.settings.interactionMode == 2 {
                                    SliderItem(label: "Force Strength", icon: "burst.fill", value: $engine.settings.interactionStrength, range: 0.1...3.0)
                                }
                                                                VStack(spacing: 8) {
                                    HStack(spacing: 8) {
                                        Button(action: { engine.resetToHexagonalPool() }) {
                                            Label("Pool", systemImage: "water.waves")
                                        }
                                        .frame(maxWidth: .infinity)
                                        
                                        Button(action: { engine.resetToDamBreak() }) {
                                            Label("Dam", systemImage: "square.split.2x1.fill")
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                    
                                    HStack(spacing: 8) {
                                        Button(action: { engine.resetToCenterSplash() }) {
                                            Label("Splash", systemImage: "drop.fill")
                                        }
                                        .frame(maxWidth: .infinity)
                                        
                                        Button(action: { engine.resetToRandom() }) {
                                            Label("Random", systemImage: "dice.fill")
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                    
                                    Divider()
                                        .padding(.vertical, 4)
                                    
                                    HStack {
                                        Button(action: { engine.resetSimulation() }) {
                                            Label("Reset All", systemImage: "arrow.counterclockwise")
                                        }
                                        .tint(.red)
                                        
                                        Spacer()
                                        
                                        Button(action: { engine.isPaused.toggle() }) {
                                            Label(engine.isPaused ? "Play" : "Pause", systemImage: engine.isPaused ? "play.fill" : "pause.fill")
                                        }
                                        .tint(engine.isPaused ? .green : .orange)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 20)
                }
                .background {
                    VisualEffectView(material: .glassMaterial)
                        .ignoresSafeArea()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .frame(maxHeight: 500) // Limit height
                .mask(
                    LinearGradient(gradient: Gradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.9),
                        .init(color: .clear, location: 1)
                    ]), startPoint: .top, endPoint: .bottom)
                )
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
                .allowsHitTesting(true)
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

// MARK: - UI Helpers

struct ControlSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content
    
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(.secondary)
                .tracking(1)
            
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(12)
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)
        }
    }
}

struct IconToggle: View {
    @Binding var isOn: Bool
    let icon: String
    let label: String
    
    var body: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isOn.toggle() } }) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isOn ? Color.blue.opacity(0.8) : Color.white.opacity(0.1))
            .foregroundColor(isOn ? .white : .secondary)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

struct RenderModeSwitcher: View {
    @Binding var selectedMode: RenderMode
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(RenderMode.allCases) { mode in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedMode = mode
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 16, weight: .semibold))
                        Text(mode.name)
                            .font(.system(size: 8, weight: .black))
                            .tracking(0.5)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(selectedMode == mode ? Color.blue.opacity(0.6) : Color.white.opacity(0.05))
                    .foregroundColor(selectedMode == mode ? .white : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
    }
}

struct SliderItem: View {
    let label: String
    let icon: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(label, systemImage: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary.opacity(0.7))
            }
            
            Slider(value: $value, in: range)
        }
    }
}


// Platform-Agnostic Visual Effect View
struct VisualEffectView: ViewRepresentable {
    #if os(macOS)
    let material: NSVisualEffectView.Material
    #else
    let material: UIBlurEffect.Style
    #endif
    
    #if os(macOS)
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
    #else
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: material))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
    #endif
}

// Button Style Fix for Platform Parity
struct ConditionalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

#if os(macOS)
extension NSVisualEffectView.Material {
    static var glassMaterial: NSVisualEffectView.Material { .headerView }
}
#else
extension UIBlurEffect.Style {
    static var glassMaterial: UIBlurEffect.Style { .systemUltraThinMaterial }
}
#endif

extension WaterSimulationEngine {
}

struct SimulationContainer: View {
    @ObservedObject var engine: WaterSimulationEngine
    @State private var canvasSize: CGSize = .zero
    @State private var lastInteractionPos: CGPoint = .zero
    @State private var baseZoom: Float = 1.0
    @State private var showZoomHUD: Bool = false
    @State private var hudTimer: Timer?
    
    var onInteractionStart: () -> Void
    var onInteractionEnd: () -> Void
    var onDoubleTap: () -> Void
    
    var body: some View {
        MetalView(
            engine: engine,
            onInteractionStart: onInteractionStart,
            onInteractionEnd: onInteractionEnd,
            onDoubleTap: onDoubleTap,
            showZoomHUD: { isShowing in
                if isShowing {
                    hudTimer?.invalidate()
                    withAnimation { showZoomHUD = true }
                } else {
                    hudTimer?.invalidate()
                    hudTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                        withAnimation { showZoomHUD = false }
                    }
                }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        #if os(macOS)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onInteractionStart()
                        lastInteractionPos = value.location
                        let width = Float(canvasSize.width)
                        let height = Float(canvasSize.height)
                        
                        // Interaction Mapping must account for Zoom & Offset
                        let ndcX = (Float(value.location.x) / width) * 2.0 - 1.0
                        let ndcY = (1.0 - Float(value.location.y) / height) * 2.0 - 1.0
                        
                        let center = engine.uniforms.domainSize * 0.5
                        let x = (ndcX * center.x) / engine.settings.zoomLevel + (center.x + engine.settings.zoomOffset.x)
                        let y = (ndcY * center.y) / engine.settings.zoomLevel + (center.y + engine.settings.zoomOffset.y)
                        
                        // Only set obstacle if not panning (heuristic: if zoomed in, we might want to pan?)
                        // For now, allow both, but refine mapping
                        engine.setObstacle(x: x, y: y, reset: false)
                    }
                    .onEnded { _ in
                        engine.hideObstacle()
                        onInteractionEnd()
                        baseZoom = engine.settings.zoomLevel
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        let oldZoom = engine.settings.zoomLevel
                        let newZoom = max(1.0, min(10.0, baseZoom * Float(value.magnitude)))
                        
                        // FOCAL POINT ZOOMING & PANNING
                        let width = Float(canvasSize.width)
                        let height = Float(canvasSize.height)
                        let ndcX = (Float(lastInteractionPos.x) / width) * 2.0 - 1.0
                        let ndcY = (1.0 - Float(lastInteractionPos.y) / height) * 2.0 - 1.0
                        
                        let center = engine.uniforms.domainSize * 0.5
                        
                        // Calculate where the cursor is in world space before any changes
                        let worldX = (ndcX * center.x) / oldZoom + engine.uniforms.zoomOffset.x
                        let worldY = (ndcY * center.y) / oldZoom + engine.uniforms.zoomOffset.y
                        
                        // Update Zoom
                        engine.settings.zoomLevel = newZoom
                        
                        // Update Offset based on current interaction position (enables panning during pinch)
                        let targetOffX = worldX - (ndcX * center.x) / newZoom
                        let targetOffY = worldY - (ndcY * center.y) / newZoom
                        
                        // CLAMPING: Prevent empty space at edges
                        let maxOffX = center.x * (1.0 - 1.0 / newZoom)
                        let maxOffY = center.y * (1.0 - 1.0 / newZoom)
                        
                        engine.settings.zoomOffset.x = max(-maxOffX, min(maxOffX, targetOffX))
                        engine.settings.zoomOffset.y = max(-maxOffY, min(maxOffY, targetOffY))
                        
                        // Show HUD
                        showZoomHUD = true
                        hudTimer?.invalidate()
                        hudTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                            withAnimation { showZoomHUD = false }
                        }
                    }
                    .onEnded { _ in
                        baseZoom = engine.settings.zoomLevel
                    }
            )
            #endif
            #if os(macOS)
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        engine.settings.zoomLevel = 1.0
                        engine.settings.zoomOffset = .zero
                        baseZoom = 1.0
                        onDoubleTap()
                    }
            )
            #endif
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { canvasSize = geo.size }
                        .onChange(of: geo.size) { _, newValue in canvasSize = newValue }
                }
            )
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    lastInteractionPos = location
                case .ended:
                    break
                }
            }
            #endif
            .overlay(alignment: .top) {
                if showZoomHUD || engine.settings.zoomLevel > 1.01 {
                    Text(String(format: "x%.2f", engine.settings.zoomLevel))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .foregroundColor(.white)
                        .padding(.top, 60)
                        .opacity(showZoomHUD ? 1 : 0.6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
    }
}

#Preview {
    WaterView()
}
