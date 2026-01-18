import SwiftUI
import Combine
import MetalKit
#if os(iOS)
import CoreMotion
#endif

struct Particle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var color: UInt32  // RGBA8 packed
    var next: Int32 = -1
    var padding: Float = 0
}

struct Uniforms {
    var dt: Float
    var _pad0: Float = 0 // Padding
    var gravity: SIMD2<Float>
    var flipRatio: Float
    var numParticles: UInt32
    var domainSize: SIMD2<Float>
    var spacing: Float
    var particleRadius: Float
    var gridRes: SIMD2<UInt32>
    var obstaclePos: SIMD2<Float>
    var obstacleVel: SIMD2<Float>
    var obstacleRadius: Float
    var particleRestDensity: Float
    var colorDiffusionCoeff: Float
    var viewportSize: SIMD2<Float>
    var showParticles: Int32
    var showGrid: Int32
    var compensateDrift: Int32
    var separateParticles: Int32
    var solverPass: Int32 // 0 for Red, 1 for Black (for RBGS solver)
    var showLiquid: Int32 = 0
    var interactionMode: Int32 = 0
    var interactionStrength: Float = 1.0
    var useGravity: Int32 = 1
    var useGyro: Int32 = 0 // METAL-SIDE FIELD
    var useHydrogenMod: Int32 = 0
    var hydrogenStrength: Float = 1.0
    var refractStrength: Float = 0.05
    var sssIntensity: Float = 0.8
    var showObstacle: Int32 = 1 // New flag to hide red ball
    var expansionFactor: Float = 1.0 // 1.0 to 4.0
    var renderMode: Int32 = 0 // 0: particles, 1: liquid, 2: pixels
    var pixelSize: Float = 2.0 // NEW: Pixel size control
    var surfaceTension: Float = 0.0 // NEW: Physical Cohesion
    var zoomLevel: Float = 1.0 // NEW: Pinch to zoom
    var zoomOffset: SIMD2<Float> = SIMD2<Float>(0, 0) // NEW: Pan/Zoom offset
    var timeScale: Float = 1.0 // NEW: Time speed control
    var time: Float = 0
}

enum RenderMode: Int, CaseIterable, Identifiable {
    case defaultView = 0
    case liquid = 1
    case pixels = 2
    
    var id: Int { self.rawValue }
    var name: String {
        switch self {
        case .defaultView: return "DEFAULT"
        case .liquid: return "LIQUID"
        case .pixels: return "PIXELS"
        }
    }
    
    var icon: String {
        switch self {
        case .defaultView: return "circle.grid.3x3.fill"
        case .liquid: return "drop.fill"
        case .pixels: return "square.grid.2x2.fill"
        }
    }
}

// Phase 4: UI-Specific state that needs @Published behavior
struct SettingsState: Equatable {
    var renderMode: RenderMode = .liquid
    var pixelSize: Float = 2.0 // NEW: Pixel size control
    var surfaceTension: Float = 0.0 // NEW: Physical Cohesion
    var showGrid: Bool = false
    var useGravity: Bool = true
    var useGyro: Bool = false // Tilt-to-Steer
    var useHydrogenMod: Bool = false
    var hydrogenStrength: Float = 1.0
    var refractStrength: Float = 0.05
    var sssIntensity: Float = 0.8
    var interactionMode: Int = 0
    var compensateDrift: Bool = true
    var separateParticles: Bool = true
    var volumeExpansion: Float = 1.0 // 1.0 is default, up to 4.0
    var interactionStrength: Float = 1.0 // Force/Vortex Multiplier
    var timeScale: Float = 1.0 // NEW: Time speed control
    var zoomLevel: Float = 1.0 // NEW: Pinch to zoom
    var zoomOffset: SIMD2<Float> = SIMD2<Float>(0, 0)
}

struct EmitUniforms {
    var position: SIMD2<Float>
    var startIndex: UInt32
    var count: UInt32
    var time: Float
}

struct GridCell {
    var u: Float = 0
    var v: Float = 0
    var weightU: Float = 0
    var weightV: Float = 0
    var prevU: Float = 0
    var prevV: Float = 0
    var density: Float = 0
    var type: Int32 = 1 // 0: fluid, 1: air, 2: solid
    var s: Float = 1
    var firstParticle: Int32 = -1
}

class WaterSimulationEngine: NSObject, ObservableObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    var particleBuffer: MTLBuffer?
    var gridBuffer: MTLBuffer?
    var densityBuffer: MTLBuffer?
    var uniformBuffer: MTLBuffer?
    
    let clearGridPipeline: MTLComputePipelineState
    let buildNeighborGridPipeline: MTLComputePipelineState
    let updateParticleDensityPipeline: MTLComputePipelineState
    let finalizeDensityPipeline: MTLComputePipelineState
    let pushParticlesApartPipeline: MTLComputePipelineState
    let solvePressurePipeline: MTLComputePipelineState
    
    // CoreMotion Manager
    #if os(iOS)
    let motionManager = CMMotionManager()
    #endif
    
    // Phase 8: Fused Kernels (DEPRECATED - Reverting)
    let integrateParticlesPipeline: MTLComputePipelineState
    let particlesToGridPipeline: MTLComputePipelineState
    let gridToParticlesPipeline: MTLComputePipelineState
    let updateParticleColorsPipeline: MTLComputePipelineState
    
    let particleRenderPipeline: MTLRenderPipelineState
    let countActiveParticlesPipeline: MTLComputePipelineState
    let sumFluidDensityPipeline: MTLComputePipelineState
    let renderPipelineState: MTLRenderPipelineState
    let obstacleRenderPipelineState: MTLRenderPipelineState
    let gridRenderPipelineState: MTLRenderPipelineState
    let liquidRenderPipelineState: MTLRenderPipelineState
    let pixelRenderPipelineState: MTLRenderPipelineState
    let emitParticlesPipeline: MTLComputePipelineState
    let shakeParticlesPipeline: MTLComputePipelineState
    
    var diagnosticCountBuffer: MTLBuffer?
    var calibrationBuffer: MTLBuffer?
    private var obstacleVertexBuffer: MTLBuffer?
    private var lastObsPos: SIMD2<Float> = .zero
    var frameCount: Int = 0
    
    // Phase 28: Refraction Background
    private var backgroundTexture: MTLTexture?
    
    // Phase 4: Separate UI and high-frequency state
    var uniforms: Uniforms
    @Published var settings = SettingsState()
    
    @Published var subSteps: Int = 1
    @Published var isPaused: Bool = false
    let maxParticles: Int = 100000 // 100k (Phase 7 stable)
    private var isTouching: Bool = false
    private var lastTouchPos: SIMD2<Float> = .zero
    
    override init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported")
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Metal Shaders not found. Ensure Shaders.metal is in the app target.")
        }
        
        func makePipe(_ name: String) -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else { fatalError("Kernel not found: \(name)") }
            return try! device.makeComputePipelineState(function: fn)
        }
        
        self.clearGridPipeline = makePipe("clearGrid")
        self.buildNeighborGridPipeline = makePipe("buildNeighborGrid")
        self.updateParticleDensityPipeline = makePipe("updateParticleDensity")
        self.finalizeDensityPipeline = makePipe("finalizeDensity")
        self.pushParticlesApartPipeline = makePipe("pushParticlesApart")
        self.solvePressurePipeline = makePipe("solvePressure")
        
        // Restoration
        self.integrateParticlesPipeline = makePipe("integrateParticles")
        self.particlesToGridPipeline = makePipe("particlesToGrid")
        self.gridToParticlesPipeline = makePipe("gridToParticles")
        self.updateParticleColorsPipeline = makePipe("updateParticleColors")
        
        self.countActiveParticlesPipeline = makePipe("countActiveParticles")
        self.sumFluidDensityPipeline = makePipe("sumFluidDensity")
        self.shakeParticlesPipeline = makePipe("shakeParticles")
        
        let vertexFunc = library.makeFunction(name: "particleVertex")!
        let fragmentFunc = library.makeFunction(name: "particleFragment")!
        
        let renderDesc = MTLRenderPipelineDescriptor()
        renderDesc.vertexFunction = vertexFunc
        renderDesc.fragmentFunction = fragmentFunc
        renderDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        renderDesc.colorAttachments[0].isBlendingEnabled = true
        renderDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        renderDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        self.particleRenderPipeline = try! device.makeRenderPipelineState(descriptor: renderDesc) // Renamed from renderPipelineState
        self.renderPipelineState = self.particleRenderPipeline // Assign to original renderPipelineState for compatibility
        
        let obstacleVertexFunc = library.makeFunction(name: "obstacleVertex")!
        let obstacleFragmentFunc = library.makeFunction(name: "obstacleFragment")!
        let obstacleDesc = MTLRenderPipelineDescriptor()
        obstacleDesc.vertexFunction = obstacleVertexFunc
        obstacleDesc.fragmentFunction = obstacleFragmentFunc
        obstacleDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        obstacleDesc.colorAttachments[0].isBlendingEnabled = true
        obstacleDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        obstacleDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        obstacleDesc.vertexDescriptor = vertexDescriptor
        
        self.obstacleRenderPipelineState = try! device.makeRenderPipelineState(descriptor: obstacleDesc)
        
        // Grid Render Pipeline
        let gridDesc = MTLRenderPipelineDescriptor()
        gridDesc.vertexFunction = library.makeFunction(name: "gridVertex")
        gridDesc.fragmentFunction = library.makeFunction(name: "gridFragment")
        gridDesc.colorAttachments[0].pixelFormat = MTLPixelFormat.bgra8Unorm
        self.gridRenderPipelineState = try! device.makeRenderPipelineState(descriptor: gridDesc)
        
        let liquidDesc = MTLRenderPipelineDescriptor()
        liquidDesc.vertexFunction = library.makeFunction(name: "liquidVertex")
        liquidDesc.fragmentFunction = library.makeFunction(name: "liquidFragment")
        liquidDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        liquidDesc.colorAttachments[0].isBlendingEnabled = true
        liquidDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        liquidDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        do {
            liquidRenderPipelineState = try device.makeRenderPipelineState(descriptor: liquidDesc)
            
            let pixelDesc = MTLRenderPipelineDescriptor()
            pixelDesc.vertexFunction = library.makeFunction(name: "liquidVertex")
            pixelDesc.fragmentFunction = library.makeFunction(name: "pixelFragment")
            pixelDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pixelDesc.colorAttachments[0].isBlendingEnabled = true
            pixelDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pixelDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pixelRenderPipelineState = try device.makeRenderPipelineState(descriptor: pixelDesc)
            
            let emitFunction = library.makeFunction(name: "emitParticles")!
            emitParticlesPipeline = try device.makeComputePipelineState(function: emitFunction)
        } catch {
            fatalError("Failed to create visual pipelines: \(error)")
        }
        
        #if os(iOS)
        let defaultObstacleRadius: Float = 0.25 // Larger for finger
        let defaultShowObstacle: Int32 = 0 // Hide red ball
        #else
        let defaultObstacleRadius: Float = 0.15 // Original for mouse
        let defaultShowObstacle: Int32 = 1 // Show red ball
        #endif

        self.uniforms = Uniforms(
            dt: 1.0 / 60.0,
            _pad0: 0,
            gravity: SIMD2<Float>(0, -9.81), // Default Gravity Vector
            flipRatio: 0.9, // Restored Phase 7 energetic behavior
            numParticles: 40000,
            domainSize: SIMD2<Float>(4.5, 3.0),
            spacing: 0.02,
            particleRadius: 0.006, // Phase 7 baseline
            gridRes: SIMD2<UInt32>(225, 150),
            obstaclePos: SIMD2<Float>(-100, -100), // Hidden at start
            obstacleVel: SIMD2<Float>(0, 0),
            obstacleRadius: defaultObstacleRadius,
            particleRestDensity: 16.0, // Solid volume packing
            colorDiffusionCoeff: 0.002,
            viewportSize: SIMD2<Float>(1200, 800),
            showParticles: 1,
            showGrid: 0,
            compensateDrift: 1,
            separateParticles: 1,
            solverPass: 0,
            showLiquid: 0,
            interactionMode: 0,
            interactionStrength: 1.0,
            useGravity: 1,
            useGyro: 0,
            useHydrogenMod: 0,
            hydrogenStrength: 1.0,
            refractStrength: 0.05,
            sssIntensity: 0.8,
            showObstacle: defaultShowObstacle,
            expansionFactor: 1.0,
            renderMode: 1, // Liquid default
            pixelSize: 2.0,
            surfaceTension: 0.0,
            zoomLevel: 1.0,
            zoomOffset: SIMD2<Float>(0, 0),
            timeScale: 1.0,
            time: 0
        )
        
        super.init()
        syncSettings() // Initial sync
        setupBuffers()
        diagnosticCountBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
        calibrationBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 2, options: .storageModeShared)
        uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)

        // Start Motion Updates
        #if os(iOS)
        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 1.0 / 60.0
            motionManager.startAccelerometerUpdates()
        }
        #endif
    }
    
    
    func setupBuffers() {
        // Hexagonal Pool for perfectly organized crystalline behavior
        resetToHexagonalPool()
        
        let numCells = Int(uniforms.gridRes.x * uniforms.gridRes.y)
        gridBuffer = device.makeBuffer(length: MemoryLayout<GridCell>.stride * numCells, options: .storageModePrivate)
        densityBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride * numCells, options: .storageModePrivate)
        
        // Setup Obstacle Disk (Circle using Triangles)
        var circleVertices = [SIMD2<Float>]()
        let segments = 32
        for i in 0..<segments {
            let a1 = Float(i) * 2.0 * .pi / Float(segments)
            let a2 = Float(i + 1) * 2.0 * .pi / Float(segments)
            
            circleVertices.append(SIMD2<Float>(0, 0)) // Center
            circleVertices.append(SIMD2<Float>(cos(a1), sin(a1)))
            circleVertices.append(SIMD2<Float>(cos(a2), sin(a2)))
        }
        obstacleVertexBuffer = device.makeBuffer(bytes: circleVertices, length: MemoryLayout<SIMD2<Float>>.stride * circleVertices.count, options: .storageModeShared)
    }

    func update(with commandBuffer: MTLCommandBuffer, currentUniforms: Uniforms) {
        // Phase 4: Sync settings once per frame start if needed
        syncSettings()
        
        // 1. Update Uniform Buffer (Once per sub-step)
        if let uBuf = uniformBuffer {
            var mutableUniforms = currentUniforms
            uBuf.contents().copyMemory(from: &mutableUniforms, byteCount: MemoryLayout<Uniforms>.stride)
        }
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        
        // 2. Clear Grid
        encoder.pushDebugGroup("Physics Pass")
        encoder.setComputePipelineState(clearGridPipeline)
        encoder.setBuffer(gridBuffer, offset: 0, index: 0)
        encoder.setBuffer(densityBuffer, offset: 0, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 2)
        
        let numCells = Int(currentUniforms.gridRes.x * currentUniforms.gridRes.y)
        var threadsPerGroup = clearGridPipeline.maxTotalThreadsPerThreadgroup
        var groups = (numCells + threadsPerGroup - 1) / threadsPerGroup
        encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), 
                                    threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
        
        // 3. Integrate Particles
        encoder.setComputePipelineState(integrateParticlesPipeline)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 1)
        let numP = Int(currentUniforms.numParticles)
        threadsPerGroup = integrateParticlesPipeline.maxTotalThreadsPerThreadgroup
        groups = (numP + threadsPerGroup - 1) / threadsPerGroup
        encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), 
                                    threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
        
        // 4. Build Neighbor Grid (Linked List)
        encoder.setComputePipelineState(buildNeighborGridPipeline)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(gridBuffer, offset: 0, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 2)
        threadsPerGroup = buildNeighborGridPipeline.maxTotalThreadsPerThreadgroup
        groups = (numP + threadsPerGroup - 1) / threadsPerGroup
        encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), 
                                    threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
        
        // 5. Particles to Grid
        encoder.setComputePipelineState(particlesToGridPipeline)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(gridBuffer, offset: 0, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 2)
        threadsPerGroup = particlesToGridPipeline.maxTotalThreadsPerThreadgroup
        groups = (numP + threadsPerGroup - 1) / threadsPerGroup
        encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), 
                                    threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
        
        // 6. Update Particle Density
        encoder.setComputePipelineState(updateParticleDensityPipeline)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(gridBuffer, offset: 0, index: 1)
        encoder.setBuffer(densityBuffer, offset: 0, index: 2)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 3)
        threadsPerGroup = updateParticleDensityPipeline.maxTotalThreadsPerThreadgroup
        groups = (numP + threadsPerGroup - 1) / threadsPerGroup
        encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), 
                                    threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
        
        // 7. Finalize Density
        encoder.setComputePipelineState(finalizeDensityPipeline)
        encoder.setBuffer(gridBuffer, offset: 0, index: 0)
        encoder.setBuffer(densityBuffer, offset: 0, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 2)
        threadsPerGroup = finalizeDensityPipeline.maxTotalThreadsPerThreadgroup
        groups = (numCells + threadsPerGroup - 1) / threadsPerGroup
        encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), 
                                    threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
        
        // 8. Push Particles Apart
        if currentUniforms.separateParticles != 0 {
            encoder.setComputePipelineState(pushParticlesApartPipeline)
            encoder.setBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setBuffer(gridBuffer, offset: 0, index: 1)
            encoder.setBuffer(uniformBuffer, offset: 0, index: 2)
            threadsPerGroup = pushParticlesApartPipeline.maxTotalThreadsPerThreadgroup
            groups = (numP + threadsPerGroup - 1) / threadsPerGroup
            for _ in 0..<3 { 
                encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), 
                                            threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
            }
        }
        
        // 9. Solve Pressure (Iterative)
        encoder.setComputePipelineState(solvePressurePipeline)
        encoder.setBuffer(gridBuffer, offset: 0, index: 0)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 1)
        
        let threadGroupSize = MTLSize(width: min(numCells, solvePressurePipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        let solverGroups = MTLSize(width: (numCells + threadGroupSize.width - 1) / threadGroupSize.width, height: 1, depth: 1)
        
        for _ in 0..<40 { 
            var pass: Int32 = 0
            encoder.setBytes(&pass, length: 4, index: 4) 
            encoder.dispatchThreadgroups(solverGroups, threadsPerThreadgroup: threadGroupSize)
            
            pass = 1
            encoder.setBytes(&pass, length: 4, index: 4)
            encoder.dispatchThreadgroups(solverGroups, threadsPerThreadgroup: threadGroupSize)
        }
        
        // 10. Finalize Velocity & Update Colors
        encoder.setComputePipelineState(gridToParticlesPipeline)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(gridBuffer, offset: 0, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 2)
        threadsPerGroup = gridToParticlesPipeline.maxTotalThreadsPerThreadgroup
        groups = (numP + threadsPerGroup - 1) / threadsPerGroup
        encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), 
                                    threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
        
        encoder.setComputePipelineState(updateParticleColorsPipeline)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setBuffer(gridBuffer, offset: 0, index: 2)
        encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), 
                                    threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
        
        encoder.popDebugGroup()
        encoder.endEncoding()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let aspect = Float(size.width / size.height)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let newViewportSize = SIMD2<Float>(Float(size.width), Float(size.height))
            
            #if os(iOS)
            // On iOS (usually portrait), we use a taller domain
            let targetDomainY: Float = 5.0
            let newDomainX = aspect * targetDomainY
            let newDomainY = targetDomainY
            #else
            let newDomainX = aspect * 3.0
            let newDomainY: Float = 3.0
            #endif
            
            // Only update if something actually changed to avoid redundant UI re-renders
            if self.uniforms.viewportSize != newViewportSize || self.uniforms.domainSize.x != newDomainX {
                self.uniforms.viewportSize = newViewportSize
                self.uniforms.domainSize.y = newDomainY
                self.uniforms.domainSize.x = newDomainX
                
                // Update grid resolution to maintain constant spacing
                let nx = UInt32(ceil(self.uniforms.domainSize.x / self.uniforms.spacing)) + 1
                let ny = UInt32(ceil(self.uniforms.domainSize.y / self.uniforms.spacing)) + 1
                
                if nx != self.uniforms.gridRes.x || ny != self.uniforms.gridRes.y {
                    self.uniforms.gridRes = SIMD2<UInt32>(nx, ny)
                    let numCells = Int(nx * ny)
                    self.gridBuffer = self.device.makeBuffer(length: MemoryLayout<GridCell>.stride * numCells, options: .storageModePrivate)
                    self.densityBuffer = self.device.makeBuffer(length: MemoryLayout<Float>.stride * numCells, options: .storageModePrivate)
                }
                
                // Phase 28: Allocate/Resize background texture
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
                desc.usage = [.renderTarget, .shaderRead]
                desc.storageMode = .private
                self.backgroundTexture = self.device.makeTexture(descriptor: desc)
            }
        }
    }
    
    func draw(in view: MTKView) {
        if isPaused { return }
        
        let originalDt = uniforms.dt
        var subStepUniforms = uniforms
        subStepUniforms.dt = originalDt / Float(subSteps)
        
        for _ in 0..<subSteps {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { break }
            autoreleasepool {
                // Modified: Now passes the commandBuffer to emitWater for GPU dispatch
                if isTouching && uniforms.interactionMode == 3 {
                    emitWater(at: lastTouchPos, within: commandBuffer)
                }
                
                update(with: commandBuffer, currentUniforms: subStepUniforms)
                commandBuffer.commit()
            }
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        var renderUniforms = uniforms
        
        // --- PHASE 28: Offscreen Background Pass ---
        if uniforms.showLiquid != 0, let bgTex = backgroundTexture {
            let bgDesc = MTLRenderPassDescriptor()
            bgDesc.colorAttachments[0].texture = bgTex
            bgDesc.colorAttachments[0].loadAction = .clear
            bgDesc.colorAttachments[0].storeAction = .store
            bgDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            
            if let bgEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: bgDesc) {
                bgEncoder.pushDebugGroup("Offscreen Background")
                
                // 1. Render Grid into background texture
                if uniforms.showGrid != 0 {
                    bgEncoder.setRenderPipelineState(gridRenderPipelineState)
                    bgEncoder.setVertexBytes(&renderUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    let nx = uniforms.gridRes.x
                    let ny = uniforms.gridRes.y
                    let numVertices = Int(2 * (nx + 1 + ny + 1))
                    bgEncoder.drawPrimitives(type: MTLPrimitiveType.line, vertexStart: 0, vertexCount: numVertices)
                }
                
                // 2. Render Particles into background texture (so they can be refracted!)
                if uniforms.showParticles != 0 {
                    bgEncoder.setRenderPipelineState(renderPipelineState)
                    bgEncoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
                    bgEncoder.setVertexBytes(&renderUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    bgEncoder.drawPrimitives(type: MTLPrimitiveType.point, vertexStart: 0, vertexCount: Int(renderUniforms.numParticles))
                }
                
                bgEncoder.popDebugGroup()
                bgEncoder.endEncoding()
            }
        }

        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { 
            return 
        }
        
        // 9. Render Grid to main view (so we can see it normally too)
        if uniforms.showGrid != 0 {
            renderEncoder.pushDebugGroup("Render Grid")
            renderEncoder.setRenderPipelineState(gridRenderPipelineState)
            renderEncoder.setVertexBytes(&renderUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            let nx = uniforms.gridRes.x
            let ny = uniforms.gridRes.y
            let numVertices = Int(2 * (nx + 1 + ny + 1))
            renderEncoder.drawPrimitives(type: MTLPrimitiveType.line, vertexStart: 0, vertexCount: numVertices)
            renderEncoder.popDebugGroup()
        }
        
        // 10. Render Particles
        if uniforms.showParticles != 0 {
            renderEncoder.pushDebugGroup("Render Particles")
            renderEncoder.setRenderPipelineState(renderPipelineState)
            renderEncoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&renderUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            renderEncoder.drawPrimitives(type: MTLPrimitiveType.point, vertexStart: 0, vertexCount: Int(renderUniforms.numParticles))
            renderEncoder.popDebugGroup()
        }
        
        // 11. Render Liquid Surface / Pixels
        if uniforms.showLiquid != 0 {
            let pipeline = (uniforms.renderMode == 2) ? pixelRenderPipelineState : liquidRenderPipelineState
            
            // Refraction fallback: if liquid mode but no texture, skip or fallback to pixels
            if uniforms.renderMode == 1 && backgroundTexture == nil {
                // Skip or could fallback to pixels if desired
            } else {
                renderEncoder.pushDebugGroup(uniforms.renderMode == 2 ? "Render Pixels" : "Render Liquid")
                renderEncoder.setRenderPipelineState(pipeline)
                renderEncoder.setVertexBytes(&renderUniforms, length: MemoryLayout<Uniforms>.stride, index: 1) // FIXED: Added vertex uniforms
                renderEncoder.setFragmentBuffer(gridBuffer, offset: 0, index: 0)
                renderEncoder.setFragmentBytes(&renderUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                
                // Pass background texture for refraction (only for liquid)
                if uniforms.renderMode == 1 {
                    renderEncoder.setFragmentTexture(backgroundTexture, index: 0)
                }
                renderEncoder.drawPrimitives(type: MTLPrimitiveType.triangleStrip, vertexStart: 0, vertexCount: 4)
                renderEncoder.popDebugGroup()
            }
        }
        
        // 12. Render Obstacle (Red Ball) - On top
        if let obsBuf = obstacleVertexBuffer {
            renderEncoder.pushDebugGroup("Render Obstacle")
            renderEncoder.setRenderPipelineState(obstacleRenderPipelineState)
            renderEncoder.setVertexBuffer(obsBuf, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&renderUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            renderEncoder.setFragmentBytes(&renderUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            renderEncoder.drawPrimitives(type: MTLPrimitiveType.triangle, vertexStart: 0, vertexCount: 32 * 3) 
            renderEncoder.popDebugGroup()
        }
        
        renderEncoder.endEncoding()
        
        // Final Diagnostic Pass (Every 60 frames)
        frameCount += 1
        if frameCount % 60 == 0 {
            if let countEncoder = commandBuffer.makeComputeCommandEncoder(),
               let countBuf = diagnosticCountBuffer {
                // Clear count
                let ptr = countBuf.contents().assumingMemoryBound(to: UInt32.self)
                ptr.pointee = 0
                
                countEncoder.pushDebugGroup("Count Active Particles")
                countEncoder.setComputePipelineState(countActiveParticlesPipeline)
                countEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
                countEncoder.setBuffer(countBuf, offset: 0, index: 1)
                countEncoder.setBytes(&renderUniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
                let numP = Int(renderUniforms.numParticles)
                let threadsPerGroup = countActiveParticlesPipeline.maxTotalThreadsPerThreadgroup
                let groups = (numP + threadsPerGroup - 1) / threadsPerGroup
                countEncoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), 
                                                  threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
                countEncoder.popDebugGroup()
                countEncoder.endEncoding()
                
                commandBuffer.addCompletedHandler { (cb: MTLCommandBuffer) in
                    let result = countBuf.contents().assumingMemoryBound(to: UInt32.self).pointee
                    // print("DIAGNOSTIC: Active Particles: \(result) / \(renderUniforms.numParticles)")
                    if result < renderUniforms.numParticles / 2 && !self.isPaused {
                        print("WARNING: More than 50% particles escaped/vanished. Resetting...")
                    }
                }
            }
        }

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }
        // Auto-Calibration (Frame 20) using GPU Buffer
        // Only run if density is 0.0 (signaling Dam Break / Need Calibration)
        if frameCount == 20 && uniforms.particleRestDensity == 0.0 {
             if let densityBuf = densityBuffer,
                let gridBuf = gridBuffer,
                let calibBuf = calibrationBuffer {
                 
                 // Clear calibration buffer
                 let ptr = calibBuf.contents().assumingMemoryBound(to: UInt32.self)
                 ptr[0] = 0
                 ptr[1] = 0
                 
                 if let calibEncoder = commandBuffer.makeComputeCommandEncoder() {
                     calibEncoder.setComputePipelineState(sumFluidDensityPipeline)
                     calibEncoder.setBuffer(gridBuf, offset: 0, index: 0)
                     calibEncoder.setBuffer(densityBuf, offset: 0, index: 1)
                     calibEncoder.setBuffer(calibBuf, offset: 0, index: 2)
                     calibEncoder.setBytes(&renderUniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
                     let numCells = Int(renderUniforms.gridRes.x * renderUniforms.gridRes.y)
                     let threadsPerGroup = sumFluidDensityPipeline.maxTotalThreadsPerThreadgroup
                     let groups = (numCells + threadsPerGroup - 1) / threadsPerGroup
                     calibEncoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), 
                                                       threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
                     calibEncoder.endEncoding()
                 }
                 
                 commandBuffer.addCompletedHandler { [weak self] (cb: MTLCommandBuffer) in
                     guard let self = self else { return }
                     let ptr = calibBuf.contents().assumingMemoryBound(to: UInt32.self)
                     let sumBits = ptr[0]
                     let count = ptr[1]
                     let sum = Float(bitPattern: sumBits)
                     
                     if count > 0 {
                         let avgParams = sum / Float(count)
                         let safeParams = max(avgParams, 4.0) // Safety clamp: prevent < 4.0 explosions
                         DispatchQueue.main.async {
                             self.uniforms.particleRestDensity = safeParams
                             print("CALIBRATION: Rest Density set to \(safeParams) (raw: \(avgParams), based on \(count) cells)")
                         }
                     }
                 }
             }
        }
        
        commandBuffer.commit()
    }

    func applyShakeImpulse() {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        
        encoder.setComputePipelineState(shakeParticlesPipeline)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        
        let threadsPerGroup = shakeParticlesPipeline.maxTotalThreadsPerThreadgroup
        let threadgroups = MTLSize(width: (Int(uniforms.numParticles) + threadsPerGroup - 1) / threadsPerGroup, height: 1, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: threadsPerGroup, height: 1, depth: 1)
        
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
    }

    func setObstacle(x: Float, y: Float, reset: Bool) {
        lastTouchPos = SIMD2<Float>(x, y)
        isTouching = true
        
        if uniforms.interactionMode == 3 {
            // Emit Mode: Continuous emission handled in draw() loop
            // We just update the position here
        } else {
            let newPos = SIMD2<Float>(x, y)
            if !reset && uniforms.obstaclePos.x > -50 {
                // Low-Pass Filter (EMA) for smoother movement
                let alpha: Float = 0.5
                let smoothedPos = uniforms.obstaclePos * (1.0 - alpha) + newPos * alpha
                
                // Calculate velocity based on smoothed movement
                var vel = (smoothedPos - uniforms.obstaclePos) / uniforms.dt
                
                // Speed Cap: Prevent simulation explosions from extreme mouse flicks
                let maxSpeed: Float = 20.0
                let speed = length(vel)
                if speed > maxSpeed {
                    vel = (vel / speed) * maxSpeed
                }
                
                uniforms.obstacleVel = vel
                uniforms.obstaclePos = smoothedPos
            } else {
                uniforms.obstacleVel = SIMD2<Float>(0, 0)
                uniforms.obstaclePos = newPos
            }
            
            // Ensure obstacle and particles stay within current dynamic domain
            let h = uniforms.spacing
            let r = uniforms.obstacleRadius
            uniforms.obstaclePos.x = max(h + r, min(uniforms.domainSize.x - h - r, uniforms.obstaclePos.x))
            uniforms.obstaclePos.y = max(h + r, min(uniforms.domainSize.y - h - r, uniforms.obstaclePos.y))
        }
    }
    
    // Phase 4 Helpers
    func syncSettings() {
        // 1. Core Simulation Parameters
        let expansion = settings.volumeExpansion
        
        // Time Scaling logic: Scale subSteps with speed to maintain stability
        let scale = settings.timeScale
        let targetSubSteps = max(1, Int(ceil(scale * 3.0))) // 3 steps per 1.0x speed for safety
        if self.subSteps != targetSubSteps {
            self.subSteps = targetSubSteps
        }
        
        let baseDt: Float = 1.0 / 60.0
        uniforms.dt = baseDt * scale
        
        uniforms.showParticles = (settings.renderMode == .defaultView) ? 1 : 0
        uniforms.showLiquid = (settings.renderMode == .liquid || settings.renderMode == .pixels) ? 1 : 0
        uniforms.showGrid = settings.showGrid ? 1 : 0
        uniforms.renderMode = Int32(settings.renderMode.rawValue)
        uniforms.pixelSize = settings.pixelSize
        uniforms.surfaceTension = settings.surfaceTension
        
        // Zoom and Pan
        uniforms.zoomLevel = settings.zoomLevel
        uniforms.zoomOffset = settings.zoomOffset
        
        // Gravity Control
        #if os(iOS)
        if settings.useGyro, let data = motionManager.accelerometerData {
            // Map accelerometer to gravity vector (scaling for effect)
            // Reduced from 3.0 to 1.5 to prevent corner explosions
            let gx = Float(data.acceleration.x) * 9.8 * 1.5 
            let gy = Float(data.acceleration.y) * 9.8 * 1.5
            uniforms.gravity = SIMD2<Float>(gx, gy)
            uniforms.useGravity = 1 // Force gravity ON if Gyro is ON
            
            // Shake Detection (Splash)
            let ax = data.acceleration.x
            let ay = data.acceleration.y
            let az = data.acceleration.z
            let magnitude = sqrt(ax*ax + ay*ay + az*az)
            
            if magnitude > 2.5 {
                 // Trigger Splash on Shake
                 DispatchQueue.main.async {
                     self.applyShakeImpulse()
                 }
            }
        } else {
            uniforms.gravity = SIMD2<Float>(0, -9.8)
            uniforms.useGravity = settings.useGravity ? 1 : 0
        }
        #else
        uniforms.gravity = SIMD2<Float>(0, -9.8)
        uniforms.useGravity = settings.useGravity ? 1 : 0
        #endif

        uniforms.useHydrogenMod = settings.useHydrogenMod ? 1 : 0
        uniforms.hydrogenStrength = settings.hydrogenStrength
        uniforms.refractStrength = settings.refractStrength
        uniforms.sssIntensity = settings.sssIntensity
        uniforms.interactionMode = Int32(settings.interactionMode)
        uniforms.interactionStrength = settings.interactionStrength
        uniforms.compensateDrift = settings.compensateDrift ? 1 : 0
        uniforms.separateParticles = settings.separateParticles ? 1 : 0
        uniforms.expansionFactor = expansion
        uniforms.time = Float(frameCount) / 60.0
        
        // 1. Maintain Hexagonal Spacing Baseline
        uniforms.spacing = 0.02
        uniforms.particleRadius = 0.006 * sqrt(expansion)
        
        // 2. Adjust Rest Density (High Cohesion Baseline: 16.0)
        if uniforms.particleRestDensity > 0 {
            uniforms.particleRestDensity = 16.0 / expansion
        }
    }
    
    func emitWater(at position: SIMD2<Float>, within commandBuffer: MTLCommandBuffer) {
        let emitRate: UInt32 = 100 // Massively increased for GPU
        let poolStart = uniforms.numParticles
        
        if poolStart + emitRate > UInt32(maxParticles) { return }
        
        // 1. Update CPU-side counter
        uniforms.numParticles += emitRate
        
        // 2. Dispatch GPU Emitter
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(emitParticlesPipeline)
            encoder.setBuffer(particleBuffer, offset: 0, index: 0)
            
            var emitParams = EmitUniforms(
                position: position,
                startIndex: poolStart,
                count: emitRate,
                time: Float(frameCount) * 0.01 + Float.random(in: 0...100)
            )
            encoder.setBytes(&emitParams, length: MemoryLayout<EmitUniforms>.stride, index: 1)
            
            let threadsPerGroup = emitParticlesPipeline.maxTotalThreadsPerThreadgroup
            let groups = (Int(emitRate) + threadsPerGroup - 1) / threadsPerGroup
            encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), 
                                        threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
            encoder.endEncoding()
        }
    }
    func hideObstacle() {
        isTouching = false
        // Move obstacle far off-screen to stop interaction
        uniforms.obstaclePos = SIMD2<Float>(-100, -100)
        uniforms.obstacleVel = SIMD2<Float>(0, 0)
    }
    
    func resetSimulation() {
        resetToHexagonalPool()
    }
    
    func resetToRandom() {
        frameCount = 0 // Reset frame tracking
        uniforms.particleRestDensity = 0.0 // Force auto-calibration
        
        var particles = [Particle]()
        for _ in 0..<maxParticles {
            let x = Float.random(in: 0.1...0.9) * uniforms.domainSize.x
            let y = Float.random(in: 0.1...0.9) * uniforms.domainSize.y
            let color = packColor(r: 0.1, g: 0.4, b: 0.9, a: 1.0)
            particles.append(Particle(position: SIMD2<Float>(x, y), velocity: SIMD2<Float>(0, 0), color: color))
        }
        uniforms.numParticles = UInt32(particles.count)
        
        // RE-FILL RESERVE
        let reserveCount = maxParticles - particles.count
        if reserveCount > 0 {
            for _ in 0..<reserveCount {
                particles.append(Particle(
                    position: SIMD2<Float>(-100, -100),
                    velocity: SIMD2<Float>(0, 0),
                    color: packColor(r: 0.2, g: 0.6, b: 1.0, a: 1.0)
                ))
            }
        }
        
        updateParticleBuffer(with: particles)
    }

    func resetToHexagonalPool() {
        frameCount = 0 
        uniforms.particleRestDensity = 0.0 // Force auto-calibration
        
        var particles = [Particle]()
        let h = uniforms.spacing
        let dx = h // Distribute exactly at spacing distance
        let dy = dx * (sqrt(3.0) / 2.0)
        
        let tankWidth = uniforms.domainSize.x
        let tankHeight = uniforms.domainSize.y
        
        let poolHeight: Float = tankHeight * 0.6 // Fill 60% of vertical space
        let wallMargin: Float = h * 1.5
        
        let numX = Int(floor((tankWidth - 2.0 * wallMargin) / dx))
        let numY = Int(floor((poolHeight - 2.0 * wallMargin) / dy))
        
        for i in 0..<numX {
            for j in 0..<numY {
                if particles.count >= maxParticles { break }
                let px = wallMargin + dx * Float(i) + (j % 2 == 0 ? 0.0 : dx * 0.5)
                let py = wallMargin + dy * Float(j)
                
                particles.append(Particle(
                    position: SIMD2<Float>(px, py),
                    velocity: SIMD2<Float>(0, 0),
                    color: packColor(r: 0.15, g: 0.45, b: 0.95, a: 1.0)
                ))
            }
        }
        uniforms.numParticles = UInt32(particles.count)
        
        let reserveCount = maxParticles - particles.count
        if reserveCount > 0 {
            for _ in 0..<reserveCount {
                particles.append(Particle(
                    position: SIMD2<Float>(-100, -100),
                    velocity: SIMD2<Float>(0, 0),
                    color: packColor(r: 0.2, g: 0.6, b: 1.0, a: 1.0)
                ))
            }
        }
        
        updateParticleBuffer(with: particles)
    }

    func resetToDamBreak() {
        frameCount = 0 
        uniforms.particleRestDensity = 0.0
        
        var particles = [Particle]()
        let h = uniforms.spacing
        let dx = h // Hexagonal spacing
        let dy = dx * (sqrt(3.0) / 2.0)
        
        let relWaterWidth: Float = 0.6
        let relWaterHeight: Float = 0.8
        let tankWidth = uniforms.domainSize.x
        let tankHeight = uniforms.domainSize.y
        
        let numX = Int(floor((relWaterWidth * tankWidth - 2.0 * dx) / dx))
        let numY = Int(floor((relWaterHeight * tankHeight - 2.0 * dx) / dy))
        
        for i in 0..<numX {
            for j in 0..<numY {
                if particles.count >= maxParticles { break }
                let px = dx + dx * Float(i) + (j % 2 == 0 ? 0.0 : dx * 0.5)
                let py = dx + dy * Float(j)
                
                particles.append(Particle(
                    position: SIMD2<Float>(px, py),
                    velocity: SIMD2<Float>(0, 0),
                    color: packColor(r: 0.15, g: 0.45, b: 0.95, a: 1.0)
                ))
            }
        }
        uniforms.numParticles = UInt32(particles.count)
        
        let reserveCount = maxParticles - particles.count
        if reserveCount > 0 {
            for _ in 0..<reserveCount {
                particles.append(Particle(
                    position: SIMD2<Float>(-100, -100),
                    velocity: SIMD2<Float>(0, 0),
                    color: packColor(r: 0.2, g: 0.6, b: 1.0, a: 1.0)
                ))
            }
        }
        
        updateParticleBuffer(with: particles)
    }
    
    func resetToCenterSplash() {
        frameCount = 0 // Reset frame tracking for fade-in logic
        uniforms.particleRestDensity = 0.0 // Force auto-calibration
        
        var particles = [Particle]()
        let h = uniforms.spacing
        let dx = h // Hexagonal spacing
        let dy = dx * (sqrt(3.0) / 2.0)
        
        let tankWidth = uniforms.domainSize.x
        let tankHeight = uniforms.domainSize.y
        
        // Match a tall column in the middle
        let colWidth: Float = 1.0
        let colHeight: Float = 2.0
        let startX = (tankWidth - colWidth) * 0.5
        
        let numX = Int(floor(colWidth / dx))
        let numY = Int(floor(colHeight / dy))
        
        for i in 0..<numX {
            for j in 0..<numY {
                if particles.count >= maxParticles { break }
                let px = startX + dx * Float(i) + (j % 2 == 0 ? 0.0 : dx * 0.5)
                let py = (tankHeight - colHeight) + dy * Float(j) // Drop from top
                
                particles.append(Particle(
                    position: SIMD2<Float>(px, py),
                    velocity: SIMD2<Float>(0, 0),
                    color: packColor(r: 0.15, g: 0.45, b: 0.95, a: 1.0)
                ))
            }
        }
        uniforms.numParticles = UInt32(particles.count)
        
        // RE-FILL RESERVE
        let reserveCount = maxParticles - particles.count
        if reserveCount > 0 {
            for _ in 0..<reserveCount {
                particles.append(Particle(
                    position: SIMD2<Float>(-100, -100),
                    velocity: SIMD2<Float>(0, 0),
                    color: packColor(r: 0.2, g: 0.6, b: 1.0, a: 1.0)
                ))
            }
        }
        
        updateParticleBuffer(with: particles)
    }
    
    private func updateParticleBuffer(with particles: [Particle]) {
        if particleBuffer == nil {
            particleBuffer = device.makeBuffer(length: MemoryLayout<Particle>.stride * maxParticles, options: .storageModeShared)
        }
        guard let buffer = particleBuffer else { return }
        let ptr = buffer.contents().assumingMemoryBound(to: Particle.self)
        for (i, p) in particles.enumerated() {
            ptr[i] = p
        }
        // Fill remaining with out-of-bounds particles if needed
        if particles.count < maxParticles {
            for i in particles.count..<maxParticles {
                ptr[i].position = SIMD2<Float>(-100, -100) // Unified hidden marker
            }
        }
    }
    
    private func packColor(r: Float, g: Float, b: Float, a: Float) -> UInt32 {
        let ri = UInt32(max(0, min(255, r * 255)))
        let gi = UInt32(max(0, min(255, g * 255)))
        let bi = UInt32(max(0, min(255, b * 255)))
        let ai = UInt32(max(0, min(255, a * 255)))
        return (ai << 24) | (bi << 16) | (gi << 8) | ri
    }
}
