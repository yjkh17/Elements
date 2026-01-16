import SwiftUI
import MetalKit
import Combine

struct GasRenderUniforms {
    var flags: UInt32               // 4 bytes
    var _pad0: Float = 0            // 4 bytes
    var _pad1: Float = 0            // 4 bytes
    var _pad2: Float = 0            // 4 bytes (total 16 for SIMD4 alignment)
    var smokeColor: SIMD4<Float>    // 16 bytes (offset 16)
    var obstaclePos: SIMD2<Float>   // 8 bytes (offset 32)
    var obstacleRadius: Float       // 4 bytes (offset 40)
    var _pad3: Float = 0            // 4 bytes (offset 44)
    var gridRes: SIMD2<Float>       // 8 bytes (offset 48)
    var _pad4: Float = 0            // 4 bytes (offset 56)
    var _pad5: Float = 0            // 4 bytes (offset 60) - Total: 64 bytes
}

struct GasSimulationUniforms {
    var dt: Float
    var dissipation: Float
    var buoyancy: Float
    var vorticityStrength: Float
    var omega: Float
    var parity: Int32
    var cp: Float
    var h: Float      // Phase 38: Grid spacing
    var isDensity: Int32
    var obstaclePos: SIMD2<Float> // Phase 52
    var obstacleRadius: Float     // Phase 52
    var obstacleVel: SIMD2<Float> // Phase 52
    var windSpeed: Float          // Phase 78: Sync for Dirichlet
    var _pad: Float = 0           // 4 bytes padding
}

struct RenderingFlags: OptionSet {
    let rawValue: UInt32
    
    static let smoke      = RenderingFlags(rawValue: 1 << 0)
    static let pressure   = RenderingFlags(rawValue: 1 << 1)
    static let velocity   = RenderingFlags(rawValue: 1 << 2)
    static let vorticity  = RenderingFlags(rawValue: 1 << 3)
    static let vectors    = RenderingFlags(rawValue: 1 << 4)
    static let scientific = RenderingFlags(rawValue: 1 << 5)
    static let streamlines = RenderingFlags(rawValue: 1 << 6)
    static let vertical    = RenderingFlags(rawValue: 1 << 7) // Phase 55
}

enum GasScenario: String, CaseIterable {
    case windTunnel = "Wind Tunnel"
    case hiresTunnel = "Hires Tunnel"
    case tank = "Tank"
    case paint = "Paint"
}

class GasSimulationEngine: NSObject, ObservableObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    // Simulation Parameters
    @Published var gridRes = SIMD2<Int32>(256, 128) // Texture Resolution
    private var lastViewSize: CGSize = .zero
    @Published var isVertical = false // Phase 55
    @Published var dt: Float = 1.0 / 60.0
    var h_spacing: Float = 1.0 / 128.0 // Phase 38
    @Published var isPaused = false
    
    @Published var currentScenario: GasScenario = .windTunnel
    
    // Visualization Toggles (Bitmask)
    @Published var showSmoke = true
    @Published var showPressure = false
    @Published var showVorticity = false
    @Published var showStreamlines = false
    @Published var overrelax: Bool = true { didSet { reset() } }
    @Published var vorticityStrength: Float = 0.02 { didSet { reset() } }
    @Published var buoyancyStrength: Float = 0.0 { didSet { reset() } }
    @Published var windSpeed: Float = 5.0 // Phase 49
    
    // Metal Textures (Double Buffered where needed)
    var uTextureRead: MTLTexture!
    var uTextureWrite: MTLTexture!
    var vTextureRead: MTLTexture!
    var vTextureWrite: MTLTexture!
    
    var densityTextureRead: MTLTexture!
    var densityTextureWrite: MTLTexture!
    
    var pressureTextureRead: MTLTexture!
    var pressureTextureWrite: MTLTexture!
    
    var divergenceTexture: MTLTexture!
    var vorticityTexture: MTLTexture!
    var obstacleTexture: MTLTexture! // 0 = Fluid, 1 = Wall
    
    // Manipulatable Obstacle (like the circle in reference)
    @Published var mainObstaclePos = SIMD2<Float>(100, 100)
    private var pendingObstaclePos = SIMD2<Float>(100, 100) // Phase 50
    private var obstacleVel = SIMD2<Float>(0, 0) // Phase 50
    var mainObstacleRadius: Float = 30.0
    var isDraggingObstacle = false
    
    // Compute Pipelines
    var gsSolvePipeline: MTLComputePipelineState!
    var pressureClearPipeline: MTLComputePipelineState!
    var advectDenPipeline: MTLComputePipelineState!
    var advectVelPipeline: MTLComputePipelineState!
    var splatPipeline: MTLComputePipelineState!
    var leftInflowPipeline: MTLComputePipelineState!
    var drawObstaclePipeline: MTLComputePipelineState!
    var drawBorderPipeline: MTLComputePipelineState!
    var calcVorticityPipeline: MTLComputePipelineState!
    var applyVorticityPipeline: MTLComputePipelineState!
    var buoyancyPipeline: MTLComputePipelineState!
    var diffuseDensityPipeline: MTLComputePipelineState!
    var extrapolatePipeline: MTLComputePipelineState! // Phase 72: Extrapolate
    var clearPipeline: MTLComputePipelineState!
    
    // Render Pipelines
    var renderPipeline: MTLRenderPipelineState!
    var streamlineRenderPipeline: MTLRenderPipelineState!
    
    var initVelocityPipeline: MTLComputePipelineState!
    var initSmokePipeline: MTLComputePipelineState!
    
    override init() {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal not supported") }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        super.init()
        
        setupTextures()
        setupPipelines()
        reset()
    }
    
    func setupTextures() {
        let width = Int(gridRes.x)
        let height = Int(gridRes.y)
        
        // Phase 12/46: High Precision Upgrade (32-bit)
        // Switch from .rg16Float / .r16Float to .rg32Float / .r32Float to eliminate solver noise
        // and "Vertical Grid Lines" artifacts seen with 16-bit floats.
        // Note: Reverted to .r16Float because iOS Simulator does not support .r32Float read-write textures.
        let scalarDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: width, height: height, mipmapped: false)
        scalarDesc.usage = [.shaderRead, .shaderWrite]
        
        uTextureRead = device.makeTexture(descriptor: scalarDesc)
        uTextureWrite = device.makeTexture(descriptor: scalarDesc)
        vTextureRead = device.makeTexture(descriptor: scalarDesc)
        vTextureWrite = device.makeTexture(descriptor: scalarDesc)
        
        densityTextureRead = device.makeTexture(descriptor: scalarDesc)
        densityTextureWrite = device.makeTexture(descriptor: scalarDesc)
        
        pressureTextureRead = device.makeTexture(descriptor: scalarDesc)
        pressureTextureWrite = device.makeTexture(descriptor: scalarDesc)
        
        divergenceTexture = device.makeTexture(descriptor: scalarDesc)
        vorticityTexture = device.makeTexture(descriptor: scalarDesc)
        obstacleTexture = device.makeTexture(descriptor: scalarDesc)
    }
    
    func updateResolution(to size: CGSize) {
        if abs(size.width - lastViewSize.width) < 1 && abs(size.height - lastViewSize.height) < 1 { return }
        lastViewSize = size
        
        let aspect = Float(size.width / size.height)
        var baseRes: Float = 120.0 // Default res
        
        if currentScenario == .hiresTunnel {
            baseRes = 240.0 // Higher resolution for Hires Tunnel
        }
        
        // Phase 55: iOS Portrait-to-Landscape Mapping
        // On iOS Portrait, size.width < size.height. 
        // We force internal resolution to stay landscape (W > H) for kernel efficiency,
        // then rotate the vertex shader by 90 deg.
        isVertical = (size.height > size.width)
        
        let landscapeAspect = isVertical ? Float(size.height / size.width) : aspect
        
        if landscapeAspect > 1.0 {
            gridRes = SIMD2<Int32>(Int32(baseRes * landscapeAspect), Int32(baseRes))
        } else {
            gridRes = SIMD2<Int32>(Int32(baseRes), Int32(baseRes / landscapeAspect))
        }
        
        setupTextures()
        reset()
    }
    
    func setupPipelines() {
        guard let library = device.makeDefaultLibrary() else { return }
        
        func makeCompute(_ name: String) -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else { fatalError("Kernel \(name) not found") }
            return try! device.makeComputePipelineState(function: fn)
        }
        
        gsSolvePipeline = makeCompute("gas_solve_gauss_seidel")
        pressureClearPipeline = makeCompute("gas_pressure_clear")
        advectDenPipeline = makeCompute("gas_advect_smoke")
        advectVelPipeline = makeCompute("gas_advect_velocity_staggered")
        splatPipeline = makeCompute("gas_splat")
        leftInflowPipeline = makeCompute("gas_set_left_inflow")
        drawObstaclePipeline = makeCompute("gas_draw_obstacle")
        drawBorderPipeline = makeCompute("gas_draw_border")
        calcVorticityPipeline = makeCompute("gas_calc_vorticity")
        applyVorticityPipeline = makeCompute("gas_apply_vorticity_confinement")
        buoyancyPipeline = makeCompute("gas_buoyancy")
        diffuseDensityPipeline = makeCompute("gas_diffuse_density")
        extrapolatePipeline = makeCompute("gas_extrapolate") // Phase 72
        clearPipeline = makeCompute("gas_clear")
        
        initVelocityPipeline = makeCompute("gas_init_wind_tunnel_velocity_u")
        initSmokePipeline = makeCompute("gas_init_wind_tunnel_smoke")
        
        // Render Pipeline (Draw Texture to Screen)
        let renderDesc = MTLRenderPipelineDescriptor()
        renderDesc.vertexFunction = library.makeFunction(name: "gasVertex")
        renderDesc.fragmentFunction = library.makeFunction(name: "gasFragment")
        renderDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        renderDesc.colorAttachments[0].isBlendingEnabled = true
        renderDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        renderDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        
        do {
            renderPipeline = try device.makeRenderPipelineState(descriptor: renderDesc)
            
            // Streamline Render Pipeline (Lines)
            let streamDesc = MTLRenderPipelineDescriptor()
            streamDesc.vertexFunction = library.makeFunction(name: "gas_streamline_vertex")
            streamDesc.fragmentFunction = library.makeFunction(name: "gas_streamline_fragment")
            streamDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            streamDesc.colorAttachments[0].isBlendingEnabled = true
            streamDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            streamDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            
            streamlineRenderPipeline = try device.makeRenderPipelineState(descriptor: streamDesc)
        } catch {
            print("Render Pipeline Error: \(error)")
        }
        
        reset()
    }
    
    
    func reset() {
        guard let library = device.makeDefaultLibrary() else { return }
        clearPipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "gas_clear")!)
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        
        let textures: [MTLTexture?] = [uTextureRead, uTextureWrite, vTextureRead, vTextureWrite, densityTextureRead, densityTextureWrite, pressureTextureRead, pressureTextureWrite, divergenceTexture, vorticityTexture, obstacleTexture]
        
        var clearColor = SIMD4<Float>(0, 0, 0, 0)
        encoder.setComputePipelineState(clearPipeline)
        encoder.setBytes(&clearColor, length: 16, index: 0)

        let w = clearPipeline.threadExecutionWidth
        let h = clearPipeline.maxTotalThreadsPerThreadgroup / w
        let threadsParams = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(width: (Int(gridRes.x) + w - 1) / w, height: (Int(gridRes.y) + h - 1) / h, depth: 1)
        
        for tex in textures {
            if let t = tex {
                encoder.setTexture(t, index: 0)
                // Default: Clear to Transparent Black, but for Density we want White (m=1) for Reference Parity
                var clearVal = SIMD4<Float>(0,0,0,0)
                if (t === densityTextureRead || t === densityTextureWrite) {
                    clearVal = SIMD4<Float>(1,1,1,1) // White/Clear
                }
                encoder.setBytes(&clearVal, length: 16, index: 0)
                
                encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsParams)
            }
        }
        encoder.endEncoding()
        commandBuffer.commit()
        
        // Initialize Obstacle Map to 1.0 (Fluid)
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        dispatch(drawObstaclePipeline, [obstacleTexture], [SIMD2<Float>(Float(gridRes.x)/2, Float(gridRes.y)/2), Float(gridRes.x + gridRes.y), Float(1.0)], in: cb)
        
        // Scenario Initial Geometry
        switch currentScenario {
        case .windTunnel, .hiresTunnel:
            mainObstaclePos = SIMD2<Float>(Float(gridRes.x) * 0.4, Float(gridRes.y) * 0.5) // 0.4, 0.5 reference
            mainObstacleRadius = Float(gridRes.y) * 0.15 
            dispatch(drawObstaclePipeline, [obstacleTexture], [mainObstaclePos, mainObstacleRadius, Float(0.0)], in: cb)
            
            // Add top/bottom/left walls via specialized border kernel (Parity with HTML)
            dispatch(drawBorderPipeline, [obstacleTexture], in: cb)
            
            // --- WIND TUNNEL INIT ---
            // 1. Set Initial Velocity (u=2 at x=1)
            let inVel: Float = 2.0
            dispatch(initVelocityPipeline, [uTextureRead], [inVel], in: cb)
            // Implicit v=0 init from clearing is enough
            
            // 2. Set Initial Smoke (m=0 at x=0 for 10% height)
            let pipeH = Float(gridRes.y) * 0.1
            let minJ = Float(gridRes.y) * 0.5 - pipeH * 0.5
            let maxJ = Float(gridRes.y) * 0.5 + pipeH * 0.5
            dispatch(initSmokePipeline, [densityTextureRead], [minJ, maxJ], in: cb)
            
        case .tank:
            // Closed reach box
            let w = Float(gridRes.x)
            let h = Float(gridRes.y)
            dispatch(drawObstaclePipeline, [obstacleTexture], [SIMD2<Float>(w/2, 0), w, Float(0.0)], in: cb) // Bottom
            dispatch(drawObstaclePipeline, [obstacleTexture], [SIMD2<Float>(w/2, h), w, Float(0.0)], in: cb) // Top
            dispatch(drawObstaclePipeline, [obstacleTexture], [SIMD2<Float>(0, h/2), h, Float(0.0)], in: cb) // Left
            dispatch(drawObstaclePipeline, [obstacleTexture], [SIMD2<Float>(w, h/2), h, Float(0.0)], in: cb) // Right
            
        case .paint:
            break
        }
        cb.commit()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Adapt grid to aspect ratio if needed, but for now fixed 256x256
    }
    
    
    func draw(in view: MTKView) {
        // Simulation Step
        if !isPaused {
            step()
        }
        
        // Render Step
        guard let drawable = view.currentDrawable,
              let renderDesc = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderDesc) else { return }
        
        encoder.setRenderPipelineState(renderPipeline)
        // Pass Textures to Fragment Shader
        encoder.setFragmentTexture(densityTextureRead, index: 0)
        encoder.setFragmentTexture(uTextureRead, index: 1) // Just show U for magnitude/visual? 
        encoder.setFragmentTexture(pressureTextureRead, index: 2)
        encoder.setFragmentTexture(vorticityTexture, index: 3)
        encoder.setFragmentTexture(obstacleTexture, index: 4)
        
        // Pass Render Uniforms
        var flags = RenderingFlags()
        if showSmoke { flags.insert(.smoke) }
        if showPressure { flags.insert(.pressure) }
        if showVorticity { flags.insert(.vorticity) }
        if showStreamlines { flags.insert(.streamlines) }
        if isVertical { flags.insert(.vertical) } // Phase 55
        
        var renderUniforms = GasRenderUniforms(
            flags: flags.rawValue,
            _pad0: 0, _pad1: 0, _pad2: 0,
            smokeColor: SIMD4<Float>(1, 1, 1, 1),
            obstaclePos: mainObstaclePos,
            obstacleRadius: mainObstacleRadius,
            _pad3: 0,
            gridRes: SIMD2<Float>(Float(gridRes.x), Float(gridRes.y)),
            _pad4: 0, _pad5: 0
        )
        encoder.setVertexBytes(&renderUniforms, length: MemoryLayout<GasRenderUniforms>.size, index: 0)
        encoder.setFragmentBytes(&renderUniforms, length: MemoryLayout<GasRenderUniforms>.size, index: 0)
        
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        // --- DRAW STREAMLINES (Vertex-Based) ---
        if showStreamlines {
            encoder.setRenderPipelineState(streamlineRenderPipeline)
            encoder.setVertexTexture(uTextureRead, index: 0)
            encoder.setVertexTexture(vTextureRead, index: 1)
            encoder.setVertexTexture(obstacleTexture, index: 2)
            
            var res = gridRes
            encoder.setVertexBytes(&res, length: 8, index: 0)
            
            // Phase 57: Pass Uniforms for Rotation Flag
            var flags = RenderingFlags()
            if showSmoke { flags.insert(.smoke) }
            if showPressure { flags.insert(.pressure) }
            if showVorticity { flags.insert(.vorticity) }
            if showStreamlines { flags.insert(.streamlines) }
            if isVertical { flags.insert(.vertical) }
            
            var renderUniforms = GasRenderUniforms(
                flags: flags.rawValue,
                _pad0: 0, _pad1: 0, _pad2: 0,
                smokeColor: SIMD4<Float>(1, 1, 1, 1),
                obstaclePos: mainObstaclePos,
                obstacleRadius: mainObstacleRadius,
                _pad3: 0,
                gridRes: SIMD2<Float>(Float(gridRes.x), Float(gridRes.y)),
                _pad4: 0, _pad5: 0
            )
            encoder.setVertexBytes(&renderUniforms, length: MemoryLayout<GasRenderUniforms>.size, index: 1)
            
            let numSeedsX = gridRes.x / 4
            let numSeedsY = gridRes.y / 4
            let totalVertices = Int(numSeedsX * numSeedsY * 128) // 64 segments (Sync with shader)
            
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: totalVertices)
        }
        
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    func dispatch(_ pipeline: MTLComputePipelineState, _ textures: [MTLTexture], _ args: [Any] = [], in commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        
        encoder.setComputePipelineState(pipeline)
        for (i, tex) in textures.enumerated() {
            encoder.setTexture(tex, index: i)
        }
        
        // Set Bytes (Arguments)
        for (i, arg) in args.enumerated() {
            let val = arg
            // Check type and size carefully (Metal expects exact match)
            if var floatVal = val as? Float {
                 encoder.setBytes(&floatVal, length: 4, index: i)
            } else if var simUniforms = val as? GasSimulationUniforms {
                 encoder.setBytes(&simUniforms, length: MemoryLayout<GasSimulationUniforms>.size, index: i)
            } else if var vectorVal = val as? SIMD2<Float> {
                 encoder.setBytes(&vectorVal, length: 8, index: i)
            } else if var vector4Val = val as? SIMD4<Float> {
                 encoder.setBytes(&vector4Val, length: 16, index: i)
            } else if var intVal = val as? Int32 {
                 encoder.setBytes(&intVal, length: 4, index: i)
            }
        }
        
        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        
        // Phase 54: Universal Compatibility Fix
        // Switching to dispatchThreadgroups to support devices/simulators 
        // that don't support non-uniform threadgroup sizes.
        let groups = MTLSize(
            width: (Int(gridRes.x) + w - 1) / w,
            height: (Int(gridRes.y) + h - 1) / h,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }
    
    func step() {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        let stepDt = (currentScenario == .hiresTunnel) ? (1.0 / 120.0) : dt
        
        // Phase 38: Use stored h_spacing
        h_spacing = 1.1 / Float(gridRes.y)
        let density: Float = 1000.0
        let cp = density * h_spacing / stepDt
        
        var simUniforms = GasSimulationUniforms(
            dt: stepDt,
            dissipation: currentScenario == .paint ? 0.9999 : 1.0, // 1.0 matches HTML (frictionless wind tunnel)
            buoyancy: buoyancyStrength,
            vorticityStrength: vorticityStrength,
            omega: (currentScenario == .windTunnel || currentScenario == .hiresTunnel) ? 1.9 : 1.0, 
            parity: 0,
            cp: cp,
            h: h_spacing,
            isDensity: 0,
            obstaclePos: mainObstaclePos,
            obstacleRadius: mainObstacleRadius,
            obstacleVel: obstacleVel,
            windSpeed: windSpeed,
            _pad: 0
        )
        
        // Phase 57: Global Obstacle Mask Management
        // 1. Clear everything to Fluid (1.0)
        let airColor = SIMD4<Float>(1, 1, 1, 1)
        dispatch(clearPipeline, [obstacleTexture], [airColor], in: commandBuffer)
        
        // 2. Draw Solid Borders (Top/Bottom)
        dispatch(drawBorderPipeline, [obstacleTexture], in: commandBuffer)
        
        // 3. Update main obstacle position and velocity
        let oldPos = mainObstaclePos
        if pendingObstaclePos.x > 0 {
            mainObstaclePos = pendingObstaclePos
            pendingObstaclePos = SIMD2<Float>(-1, -1)
        }
        
        let rawVel = (mainObstaclePos - oldPos) * h_spacing / stepDt
        // Safety: Prevent "speed of light" explosions by limiting synthetic velocity
        obstacleVel = SIMD2<Float>(
            min(max(rawVel.x, -20.0), 20.0),
            min(max(rawVel.y, -20.0), 20.0)
        )
        
        // 4. Draw Main Obstacle (Solid 0.0)
        let solidVal: Float = 0.0
        dispatch(drawObstaclePipeline, [obstacleTexture], [mainObstaclePos, mainObstacleRadius, solidVal], in: commandBuffer)
        
        // --- PHASE 1: INTEGRATE (Forces & Sources) ---
        // Gravity/Buoyancy
        if currentScenario == .tank && abs(buoyancyStrength) > 0.001 {
            dispatch(buoyancyPipeline, [uTextureRead, vTextureRead, densityTextureRead, uTextureWrite, vTextureWrite], [simUniforms], in: commandBuffer)
            swap(&uTextureRead, &uTextureWrite)
            swap(&vTextureRead, &vTextureWrite)
        }
        
        // Interaction (Splat)
        // Note: Splat currently written for float4, need to update if still used. 
        // For now, focusing on Wind Tunnel Stability.
        
        // --- PHASE 2: CLEAR PRESSURE ---
        // Restore Phase 79 logic for tunnels: Disable clear to allow pressure persistence.
        // This eliminates the high-frequency "jitter" or "sawtooth" streamlines.
        if currentScenario != .windTunnel && currentScenario != .hiresTunnel {
            dispatch(pressureClearPipeline, [pressureTextureRead], in: commandBuffer)
        }
        
        
        // --- PHASE 3: PROJECT (Solve Incompressibility) ---
        // Phase 74: Direct Velocity/Pressure Update (Gauss-Seidel SOR)
        // Matches Ten Minute Physics Page 18-20
        // No longer clearing pressure every frame to improve temporal stability
        
        // 1.9 is the "magic" over-relaxation factor from Page 20
        simUniforms.omega = 1.9 
        for i in 0..<80 {
            simUniforms.parity = Int32(i % 2)
            dispatch(gsSolvePipeline, [uTextureRead, vTextureRead, pressureTextureRead, obstacleTexture], [simUniforms], in: commandBuffer)
        }
        
        
        // --- PHASE 4: EXTRAPOLATE (Boundary Safety) ---
        dispatch(extrapolatePipeline, [uTextureRead, uTextureWrite], in: commandBuffer)
        swap(&uTextureRead, &uTextureWrite)
        dispatch(extrapolatePipeline, [vTextureRead, vTextureWrite], in: commandBuffer)
        swap(&vTextureRead, &vTextureWrite)
        
        
        // --- PHASE 5: ADVECT VELOCITY ---
        dispatch(advectVelPipeline, [uTextureRead, vTextureRead, uTextureWrite, vTextureWrite, obstacleTexture], [simUniforms], in: commandBuffer)
        swap(&uTextureRead, &uTextureWrite)
        swap(&vTextureRead, &vTextureWrite)
        
        
        // --- PHASE 6: ADVECT DENSITY ---
        dispatch(advectDenPipeline, [uTextureRead, vTextureRead, densityTextureRead, densityTextureWrite, obstacleTexture], [simUniforms], in: commandBuffer)
        swap(&densityTextureRead, &densityTextureWrite)
        
        
        // --- PHASE 7: EXTRAS (Post-Processing) ---
        // Vorticity Confinement (Optional Energy Injection)
        if abs(vorticityStrength) > 0.01 {
            dispatch(calcVorticityPipeline, [uTextureRead, vTextureRead, vorticityTexture], in: commandBuffer)
            dispatch(applyVorticityPipeline, [uTextureRead, vTextureRead, vorticityTexture, uTextureWrite, vTextureWrite], [simUniforms], in: commandBuffer)
            swap(&uTextureRead, &uTextureWrite)
            swap(&vTextureRead, &vTextureWrite)
        }
        
        // Density Smoothing (Diffusion)
        // Phase 87: Razor-Sharp Parity.
        // Disable for tunnels as the reference does not use smoke diffusion.
        if currentScenario != .windTunnel && currentScenario != .hiresTunnel {
            dispatch(diffuseDensityPipeline, [densityTextureRead, densityTextureWrite, obstacleTexture], in: commandBuffer)
            swap(&densityTextureRead, &densityTextureWrite)
        }

        // --- PHASE 8: REPLENISH (Inflow Source) ---
        // Move to end of frame so it persists as the source for next frame's advection
        if currentScenario == .windTunnel || currentScenario == .hiresTunnel {
            let inflowVel = SIMD2<Float>(windSpeed, 0)
            dispatch(leftInflowPipeline, [densityTextureRead, densityTextureWrite, uTextureRead, uTextureWrite, vTextureRead, vTextureWrite], [inflowVel, simUniforms], in: commandBuffer)
            swap(&uTextureRead, &uTextureWrite)
            swap(&vTextureRead, &vTextureWrite)
            swap(&densityTextureRead, &densityTextureWrite)
        }
        
        commandBuffer.commit()
    }
    
    func moveMainObstacle(x: Float, y: Float) {
        // Phase 50: Deferred Update
        // Just store the position; the next step() will calculate velocity and update textures.
        pendingObstaclePos = SIMD2<Float>(x, y)
    }
}
