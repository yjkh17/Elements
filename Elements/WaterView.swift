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
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9)),
                        removal: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9))
                    ))
                    .padding(.top, 20) // Floating offset
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
                    VStack(alignment: .leading, spacing: 25) {
                        // Header
                        HStack {
                            Text("SIMULATION CONTROL")
                                .font(.system(size: 14, weight: .black))
                                .tracking(2)
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        
                        // 1. RENDER SECTION
                        ControlSection(title: "DISPLAY", icon: "eye.fill") {
                            VStack(spacing: 16) {
                                RenderModeSwitcher(selectedMode: $engine.settings.renderMode)
                                
                                VStack(spacing: 12) {
                                    SliderItem(label: "Refraction", icon: "aqi.medium", value: $engine.settings.refractStrength, range: 0...0.1)
                                        .disabled(engine.settings.renderMode != .liquid)
                                        .opacity(engine.settings.renderMode == .liquid ? 1.0 : 0.5)
                                    
                                    SliderItem(label: "Glow", icon: "sun.max.fill", value: $engine.settings.sssIntensity, range: 0...2.0)
                                        .disabled(engine.settings.renderMode != .liquid)
                                        .opacity(engine.settings.renderMode == .liquid ? 1.0 : 0.5)

                                    if engine.settings.renderMode == .pixels {
                                        SliderItem(label: "Pixel Size", icon: "square.grid.2x2", value: $engine.settings.pixelSize, range: 1.0...10.0)
                                    }
                                }
                            }
                        }
                        
                        // 2. PHYSICS SECTION
                        ControlSection(title: "PHYSICS", icon: "atom") {
                            VStack(spacing: 16) {
                                HStack(spacing: 10) {
                                    IconToggle(isOn: $engine.settings.useGravity, icon: "arrow.down", label: "GRAVITY")
                                    #if os(iOS)
                                    IconToggle(isOn: $engine.settings.useGyro, icon: "iphone.gen3", label: "TILT")
                                    #endif
                                    IconToggle(isOn: $engine.settings.useHydrogenMod, icon: "hexagon.fill", label: "H-BOND")
                                }
                                
                                SliderItem(label: "Growth", icon: "arrow.up.left.and.arrow.down.right", value: $engine.settings.volumeExpansion, range: 1.0...4.0)
                                SliderItem(label: "Surface", icon: "app.dashed", value: $engine.settings.surfaceTension, range: 0.0...2.0)
                                SliderItem(label: "Time", icon: "clock.fill", value: $engine.settings.timeScale, range: 0.0...2.0)
                            }
                        }
                        
                        // 3. INTERACTION & PRESETS
                        ControlSection(title: "INTERACT", icon: "hand.tap.fill") {
                            VStack(spacing: 16) {
                                Picker("Mode", selection: $engine.settings.interactionMode) {
                                    Text("SOLID").tag(0)
                                    Text("VORTEX").tag(1)
                                    Text("FORCE").tag(2)
                                    Text("EMIT").tag(3)
                                }
                                .pickerStyle(.segmented)
                                
                                if engine.settings.interactionMode == 2 {
                                    SliderItem(label: "Strength", icon: "burst.fill", value: $engine.settings.interactionStrength, range: 0.1...3.0)
                                }
                                
                                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                                    GridRow {
                                        PresetButton(title: "POOL", icon: "water.waves", action: { engine.resetToHexagonalPool() })
                                        PresetButton(title: "DAM", icon: "square.split.2x1.fill", action: { engine.resetToDamBreak() })
                                    }
                                    GridRow {
                                        PresetButton(title: "SPLASH", icon: "drop.fill", action: { engine.resetToCenterSplash() })
                                        PresetButton(title: "RANDOM", icon: "dice.fill", action: { engine.resetToRandom() })
                                    }
                                }
                                
                                HStack(spacing: 10) {
                                    Button(action: { engine.resetSimulation() }) {
                                        Label("RESET EVERYTHING", systemImage: "arrow.counterclockwise")
                                            .font(.system(size: 10, weight: .bold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                            .background(.red.opacity(0.15))
                                            .foregroundColor(.red)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Button(action: { engine.isPaused.toggle() }) {
                                        Image(systemName: engine.isPaused ? "play.fill" : "pause.fill")
                                            .font(.system(size: 14, weight: .bold))
                                            .frame(width: 50, height: 40)
                                            .background(engine.isPaused ? Color.green.opacity(0.2) : Color.white.opacity(0.1))
                                            .foregroundColor(engine.isPaused ? .green : .white)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(25)
                }
                .frame(maxWidth: 400) // Floating Island Width
                .background {
                    RoundedRectangle(cornerRadius: 35)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 15)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 35)
                        .stroke(.white.opacity(0.2), lineWidth: 0.5)
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.8)),
                    removal: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.8))
                ))
                .padding(.bottom, 20)
            }
            
            // Phase 58: Unified Top Bar (Exit Left, Menu Right)
            HStack(spacing: 12) {
                // Exit Button (Left) - Standardized Back Position
                Button(action: { onExit?() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                        Text("LAB")
                            .font(.system(size: 10, weight: .black))
                            .tracking(1)
                    }
                    .foregroundColor(.white)
                    .frame(height: 38)
                    .padding(.horizontal, 16)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                }
                .buttonStyle(SpringScaleButtonStyle())
                
                Spacer()
                
                // Menu Button (Right) - Glass Capsule
                Button(action: {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        isCollapsed.toggle()
                    }
                }) {
                    HStack(spacing: 8) {
                        Text(isCollapsed ? "COMMAND" : "CLOSE")
                            .font(.system(size: 10, weight: .black))
                            .tracking(1.5)
                        
                        Image(systemName: isCollapsed ? "slider.horizontal.3" : "chevron.up")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(height: 38)
                    .padding(.horizontal, 20)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                }
                .buttonStyle(SpringScaleButtonStyle())
            }
            .frame(maxWidth: 400) // Match Island Width
            .padding(.top, 10)
            .padding(.horizontal, 20)
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
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(title)
                    .font(.system(size: 10, weight: .black))
                    .tracking(1.5)
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(.white.opacity(0.4))
            
            VStack(alignment: .leading, spacing: 15) {
                content
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(0.05), lineWidth: 0.5)
            )
        }
    }
}

struct PresetButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.system(size: 9, weight: .black))
                    .tracking(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(.white.opacity(0.05))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .stroke(.white.opacity(0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(SpringScaleButtonStyle())
    }
}

struct SpringScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct IconToggle: View {
    @Binding var isOn: Bool
    let icon: String
    let label: String
    
    var body: some View {
        Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isOn.toggle() } }) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                Text(label)
                    .font(.system(size: 8, weight: .black))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(isOn ? Color.blue.opacity(0.3) : Color.white.opacity(0.05))
            .foregroundColor(isOn ? .blue : .white.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isOn ? Color.blue.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(SpringScaleButtonStyle())
    }
}

struct RenderModeSwitcher: View {
    @Binding var selectedMode: RenderMode
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(RenderMode.allCases) { mode in
                Button(action: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        selectedMode = mode
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 12, weight: .bold))
                        if selectedMode == mode {
                            Text(mode.name.uppercased())
                                .font(.system(size: 9, weight: .black))
                                .tracking(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(selectedMode == mode ? Color.blue.opacity(0.3) : Color.white.opacity(0.05))
                    .foregroundColor(selectedMode == mode ? .white : .white.opacity(0.4))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(selectedMode == mode ? Color.blue.opacity(0.5) : Color.white.opacity(0.05), lineWidth: 0.5)
                    )
                }
                .buttonStyle(SpringScaleButtonStyle())
            }
        }
    }
}

struct SliderItem: View {
    let label: String
    let icon: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    Text(label.uppercased())
                        .font(.system(size: 8, weight: .black))
                        .tracking(1)
                } icon: {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                .foregroundColor(.white.opacity(0.5))
                
                Spacer()
                
                Text(String(format: "%.2f", value))
                    .font(.system(size: 8, weight: .bold).monospacedDigit())
                    .foregroundColor(.white.opacity(0.3))
            }
            
            Slider(value: $value, in: range)
                .accentColor(.blue)
        }
        .padding(.vertical, 4)
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
