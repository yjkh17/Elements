#include <metal_stdlib>
using namespace metal;

struct Particle {
    float2 position;
    float2 velocity;
    uint color;
    int next;
    float padding; 
};

// Color Packing Helpers
float4 unpackColor(uint c) {
    return float4(float(c & 0xFF) / 255.0,
                  float((c >> 8) & 0xFF) / 255.0,
                  float((c >> 16) & 0xFF) / 255.0,
                  float((c >> 24) & 0xFF) / 255.0);
}

uint packColor(float4 c) {
    uint r = uint(clamp(c.r * 255.0, 0.0, 255.0));
    uint g = uint(clamp(c.g * 255.0, 0.0, 255.0));
    uint b = uint(clamp(c.b * 255.0, 0.0, 255.0));
    uint a = uint(clamp(c.a * 255.0, 0.0, 255.0));
    return (a << 24) | (b << 16) | (g << 8) | r;
}

struct GridCell {
    float u;
    float v;
    float weightU;
    float weightV;
    float prevU;
    float prevV;
    float density;
    int type; // 0: fluid, 1: air, 2: solid
    float s;   // solid factor
    int firstParticle;
};

struct Uniforms {
    float dt;
    float2 gravity; // Vector gravity for tilt controls
    float flipRatio;
    uint numParticles;
    float2 domainSize;
    float spacing;
    float particleRadius;
    uint2 gridRes;
    float2 obstaclePos;
    float2 obstacleVel;
    float obstacleRadius;
    float particleRestDensity;
    float colorDiffusionCoeff;
    float2 viewportSize;
    int showParticles;
    int showGrid;
    int compensateDrift;
    int separateParticles;
    int solverPass;
    int showLiquid;
    int interactionMode;
    float interactionStrength;
    int useGravity;
    int useGyro; // Added to match Swift
    int useHydrogenMod;
    float hydrogenStrength;
    float refractStrength;
    float sssIntensity;
    int showObstacle;
    float expansionFactor;
    int renderMode;
    float pixelSize; // NEW: Dynamic pixel size
    float surfaceTension; // NEW: Physical Cohesion
    float zoomLevel;      // NEW: Pinch to zoom
    float2 zoomOffset;    // NEW: Pan/Zoom offset
    float time;
};

struct EmitUniforms {
    float2 position;
    uint startIndex;
    uint count;
    float time;
};

// Simple hash-based random function for GPU jitter
float random(float2 st, float seed) {
    return fract(sin(dot(st.xy, float2(12.9898, 78.233))) * (43758.5453123 + seed));
}

kernel void emitParticles(
    device Particle* particles [[buffer(0)]],
    constant EmitUniforms& params [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= params.count) return;
    
    uint index = params.startIndex + id;
    float seed = params.time + float(id);
    
    // Spread: -0.05 to 0.05
    float2 jitter = float2(
        random(float2(params.position.x, seed), 1.0) * 0.1 - 0.05,
        random(float2(seed, params.position.y), 2.0) * 0.1 - 0.05
    );
    
    // Velocity: x: -1 to 1, y: -2 to 0
    float2 vel = float2(
        random(float2(seed, 1.23), 3.0) * 2.0 - 1.0,
        random(float2(4.56, seed), 4.0) * -2.0
    );
    
    particles[index].position = params.position + jitter;
    particles[index].velocity = vel;
    particles[index].color = packColor(float4(0.2, 0.6, 1.0, 1.0));
}

// Atomic helper for float addition
void atomicAddFloat(device float* addr, float val) {
    if (!isfinite(val) || val == 0.0f) return;
    device atomic_uint* uintAddr = (device atomic_uint*)addr;
    uint oldVal, newVal;
    do {
        oldVal = atomic_load_explicit(uintAddr, memory_order_relaxed);
        newVal = as_type<uint>(as_type<float>(oldVal) + val);
    } while (!atomic_compare_exchange_weak_explicit(uintAddr, &oldVal, newVal, memory_order_relaxed, memory_order_relaxed));
}

kernel void clearGrid(
    device GridCell* grid [[buffer(0)]],
    device uint* densityBuffer [[buffer(1)]],
    constant Uniforms& uniforms [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    uint numCells = uniforms.gridRes.x * uniforms.gridRes.y;
    if (id >= numCells) return;
    
    grid[id].u = 0;
    grid[id].v = 0;
    grid[id].weightU = 0;
    grid[id].weightV = 0;
    grid[id].density = 0;
    grid[id].type = 1; // AIR
    grid[id].firstParticle = -1;
    densityBuffer[id] = 0;
    
    uint x = id / uniforms.gridRes.y;
    uint y = id % uniforms.gridRes.y;
    
    // Boundary and Obstacle
    if (x == 0 || x == uniforms.gridRes.x - 1 || y == 0 || y == uniforms.gridRes.y - 1) {
        grid[id].s = 0;
        grid[id].type = 2; // SOLID
    } else {
        grid[id].s = 1;
        float2 cellCenter = (float2(x, y) + 0.5) * uniforms.spacing;
        float d = distance(cellCenter, uniforms.obstaclePos);
        if (d < uniforms.obstacleRadius) {
            // Only mark as SOLID if in Solid mode (0)
            if (uniforms.interactionMode == 0) {
                grid[id].s = 0;
                grid[id].type = 2; // SOLID
                grid[id].u = uniforms.obstacleVel.x;
                grid[id].v = uniforms.obstacleVel.y;
            }
        }
    }
}
kernel void integrateParticles(
    device Particle* particles [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.numParticles) return;
    
    if (uniforms.useGravity != 0) {
        particles[id].velocity += uniforms.gravity * uniforms.dt;
    }
    
    float2 vel = particles[id].velocity;
    if (!isfinite(vel.x) || !isfinite(vel.y)) vel = 0;
    float maxVel = 3.0f; 
    if (length(vel) > maxVel) vel = normalize(vel) * maxVel;
    particles[id].velocity = vel;
    
    float2 pos = particles[id].position + vel * uniforms.dt;
    
    // Boundary Padding
    float h = uniforms.spacing;
    float pR = uniforms.particleRadius;
    float2 minP = float2(h + pR, h + pR);
    float2 maxP = float2(float(uniforms.gridRes.x - 1) * h - pR, float(uniforms.gridRes.y - 1) * h - pR);
    pos = clamp(pos, minP, maxP);
    
    // Obstacle Interaction
    float2 dPos = pos - uniforms.obstaclePos;
    float distSq = dot(dPos, dPos);
    float obstacleR = uniforms.obstacleRadius + h * 0.5f;
    float rSq = obstacleR * obstacleR;
    
    if (distSq < rSq) {
        float dist = sqrt(distSq);
        float2 normal = (dist > 0.0001f) ? (dPos / dist) : float2(1, 0);
        
        // --- Shared Dynamics ---
        float velMag = length(uniforms.obstacleVel);
        // Velocity-aware boost: Moving fast increases force significantly
        float speedBoost = 1.0f + velMag * 5.0f; 
        // Smooth Step/Gaussian-like Falloff for "soft" edges
        float falloff = saturate(1.0f - (distSq / rSq));
        falloff = falloff * falloff; // Quadratic falloff for smoother feel
        
        if (uniforms.interactionMode == 0) {
            // MODE 0: PUSH (Collider)
            // Still solid, but inherits some velocity for a "scooping" feel
            pos = uniforms.obstaclePos + normal * obstacleR;
            particles[id].velocity = mix(particles[id].velocity, uniforms.obstacleVel, 0.4f);
        } else if (uniforms.interactionMode == 1 && dist > 0.0001f) {
            // MODE 1: SWIRL/VORTEX
            float strength = uniforms.interactionStrength * 15.0f * speedBoost;
            float2 tangent = float2(-dPos.y, dPos.x) / dist;
            particles[id].velocity += tangent * strength * falloff * uniforms.dt;
            // Add a little inward/outward motion based on rotation to keep it stable
            particles[id].velocity += normal * strength * 0.1f * falloff * uniforms.dt;
        } else if (uniforms.interactionMode == 2 && dist > 0.0001f) {
            // MODE 2: FORCE (Radial Pushing)
            float strength = uniforms.interactionStrength * 60.0f * speedBoost;
            
            // 1. Radial component
            particles[id].velocity += normal * strength * falloff * uniforms.dt;
            
            // 2. Directional component (allows "throwing" water)
            particles[id].velocity += uniforms.obstacleVel * 5.0f * falloff * uniforms.dt;
            
            // 3. Subtle Vortex component during movement (creates eddies)
            if (velMag > 0.1f) {
                float2 tangent = float2(-dPos.y, dPos.x) / dist;
                float vortexStrength = strength * 0.2f * saturate(velMag * 2.0f);
                particles[id].velocity += tangent * vortexStrength * falloff * uniforms.dt;
            }
        }
    }
    
    particles[id].position = pos;
    particles[id].next = -1; // Reset linked list pointer
}

kernel void buildNeighborGrid(
    device Particle* particles [[buffer(0)]],
    device GridCell* grid [[buffer(1)]],
    constant Uniforms& uniforms [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.numParticles) return;
    
    float2 pos = particles[id].position;
    int2 coord = int2(floor(pos / uniforms.spacing));
    
    if (coord.x >= 0 && coord.x < (int)uniforms.gridRes.x && 
        coord.y >= 0 && coord.y < (int)uniforms.gridRes.y) {
        uint gridIdx = (uint)coord.x * uniforms.gridRes.y + (uint)coord.y;
        
        // Atomically set firstParticle and update next pointer
        device atomic_int* firstPtr = (device atomic_int*)&grid[gridIdx].firstParticle;
        particles[id].next = atomic_exchange_explicit(firstPtr, (int)id, memory_order_relaxed);
    }
}

kernel void particlesToGrid(
    device Particle* particles [[buffer(0)]],
    device GridCell* grid [[buffer(1)]],
    constant Uniforms& uniforms [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.numParticles) return;
    
    float2 pos = particles[id].position;
    float2 vel = particles[id].velocity;
    float h = uniforms.spacing;
    float h2 = h * 0.5;
    
    uint n = uniforms.gridRes.y;
    uint m = uniforms.gridRes.x;
    
    int2 cell = int2(floor(pos / h));
    if (cell.x >= 0 && (uint)cell.x < m && cell.y >= 0 && (uint)cell.y < n) {
        uint idx = cell.x * n + cell.y;
        if (grid[idx].type != 2) grid[idx].type = 0; 
    }

    // Splat U
    float2 posU = (pos - float2(0, h2)) / h;
    int2 i0 = int2(floor(posU));
    float2 f = posU - float2(i0);
    float weights[4] = { (1-f.x)*(1-f.y), f.x*(1-f.y), (1-f.x)*f.y, f.x*f.y };
    int2 offsets[4] = { {0,0}, {1,0}, {0,1}, {1,1} };
    
    for (int i=0; i<4; i++) {
        int2 c = i0 + offsets[i];
        if (c.x >= 0 && (uint)c.x < m && c.y >= 0 && (uint)c.y < n) {
            uint idx = (uint)c.x * n + (uint)c.y;
            atomicAddFloat(&grid[idx].u, vel.x * weights[i]);
            atomicAddFloat(&grid[idx].weightU, weights[i]);
        }
    }

    // Splat V
    float2 posV = (pos - float2(h2, 0)) / h;
    i0 = int2(floor(posV));
    f = posV - float2(i0);
    weights[0] = (1-f.x)*(1-f.y); weights[1] = f.x*(1-f.y); weights[2] = (1-f.x)*f.y; weights[3] = f.x*f.y;
    
    for (int i=0; i<4; i++) {
        int2 c = i0 + offsets[i];
        if (c.x >= 0 && (uint)c.x < m && c.y >= 0 && (uint)c.y < n) {
            uint idx = (uint)c.x * n + (uint)c.y;
            atomicAddFloat(&grid[idx].v, vel.y * weights[i]);
            atomicAddFloat(&grid[idx].weightV, weights[i]);
        }
    }
}

kernel void updateParticleDensity(
    device Particle* particles [[buffer(0)]],
    device GridCell* grid [[buffer(1)]],
    device float* densityBuffer [[buffer(2)]],
    constant Uniforms& uniforms [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.numParticles) return;
    
    float2 pos = particles[id].position;
    int2 coord = int2(floor(pos / uniforms.spacing));
    float h = uniforms.spacing;
    float h2 = h * h;
    
    float density = 0;
    float weight = 0;
    
    for (int i = -1; i <= 1; i++) {
        for (int j = -1; j <= 1; j++) {
            int2 neighborCoord = coord + int2(i, j);
            if (neighborCoord.x >= 0 && neighborCoord.x < (int)uniforms.gridRes.x &&
                neighborCoord.y >= 0 && neighborCoord.y < (int)uniforms.gridRes.y) {
                uint gridIdx = (uint)neighborCoord.x * uniforms.gridRes.y + (uint)neighborCoord.y;
                
                int pIdx = grid[gridIdx].firstParticle;
                while (pIdx != -1) {
                    if (pIdx != (int)id) {
                        float2 r = particles[pIdx].position - pos;
                        float distSq = dot(r, r);
                        if (distSq < h2) {
                            float dist = sqrt(distSq);
                            float w = 1.0f - dist / h;
                            density += w * w * w;
                            weight += w;
                        }
                    }
                    pIdx = particles[pIdx].next;
                }
            }
        }
    }
    
    // We don't store density on particle in Phase 7 legacy
    device atomic_float* densPtr = (device atomic_float*)&densityBuffer[coord.x * uniforms.gridRes.y + coord.y];
    atomicAddFloat((device float*)densPtr, weight);
}

kernel void finalizeDensity(
    device GridCell* grid [[buffer(0)]],
    device float* densityBuffer [[buffer(1)]],
    constant Uniforms& uniforms [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    uint m = uniforms.gridRes.x;
    uint n = uniforms.gridRes.y;
    if (id >= m * n) return;
    grid[id].density = densityBuffer[id];
    
    float eps = 1e-8f;
    if (grid[id].weightU > eps) grid[id].u /= grid[id].weightU; else grid[id].u = 0;
    if (grid[id].weightV > eps) grid[id].v /= grid[id].weightV; else grid[id].v = 0;
    
    grid[id].prevU = grid[id].u;
    grid[id].prevV = grid[id].v;
    
    uint x = id / n;
    uint y = id % n;
    bool isBoundary = (x == 0 || x == m-1 || y == 0 || y == n-1);
    
    if (x == 0 || x == m-1 || grid[id].type == 2 || (x > 0 && grid[id-n].type == 2)) {
        grid[id].u = 0;
        if (grid[id].type == 2 && !isBoundary) grid[id].u = uniforms.obstacleVel.x;
    }
    
    if (y == 0 || y == n-1 || grid[id].type == 2 || (y > 0 && grid[id-1].type == 2)) {
        grid[id].v = 0;
        if (grid[id].type == 2 && !isBoundary) grid[id].v = uniforms.obstacleVel.y;
    }
}

kernel void pushParticlesApart(
    device Particle* particles [[buffer(0)]],
    device const GridCell* grid [[buffer(1)]],
    constant Uniforms& uniforms [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.numParticles || uniforms.separateParticles == 0) return;
    
    float2 pos = particles[id].position;
    float h = uniforms.spacing;
    int2 cell = int2(floor(pos / h));
    float minDist = 2.0f * uniforms.particleRadius;
    float2 correction = 0;
    
    for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
            int2 c = cell + int2(dx, dy);
            if (c.x < 0 || (uint)c.x >= uniforms.gridRes.x || c.y < 0 || (uint)c.y >= uniforms.gridRes.y) continue;
            
            uint gridIdx = (uint)c.x * uniforms.gridRes.y + (uint)c.y;
            int pIdx = grid[gridIdx].firstParticle;
            
            while (pIdx != -1) {
                if (pIdx != (int)id) {
                    float2 diff = pos - particles[pIdx].position;
                    float d2 = dot(diff, diff);
                    if (d2 > 0) {
                        float d = sqrt(d2);
                        float timeWeight = uniforms.dt * 60.0f;
                        if (d < minDist) {
                            float force = (minDist - d) / (d + 1e-6f);
                            correction += diff * force * 0.2f * timeWeight; // Scale with time
                            
                            float4 color_id = unpackColor(particles[id].color);
                            float4 color_pIdx = unpackColor(particles[pIdx].color);
                            float4 avgColor = (color_id + color_pIdx) * 0.5f;
                            particles[id].color = packColor(color_id + (avgColor - color_id) * uniforms.colorDiffusionCoeff);
                        } else {
                            // High-Fidelity Dual Interaction System
                            
                            // 1. Surface Tension (Physical Cohesion - Macro Scale)
                            if (uniforms.surfaceTension > 0.0f && d < minDist * 2.5f) {
                                float cohesionStrength = uniforms.surfaceTension * 0.15f;
                                float falloff = 1.0f - (d / (minDist * 2.5f));
                                correction -= diff * cohesionStrength * (falloff * falloff) * timeWeight;
                            }
                            
                            // 2. Hydrogen Bonding (Structural Crystallization - Micro Scale)
                            if (uniforms.useHydrogenMod != 0 && d < minDist * 1.6f) {
                                // Bipolar Snapping Force: Aggressively organized hexagonal lattice
                                float targetDist = minDist * 0.96f; // Tight pack
                                float stiffness = uniforms.hydrogenStrength * 0.25f; 
                                
                                // Calculate displacement from target
                                float delta = d - targetDist;
                                
                                // Non-linear "snap" effect: Stronger near targetDist to lock it in
                                float snap = delta * stiffness;
                                if (abs(delta) < uniforms.particleRadius * 0.2f) {
                                    snap *= 1.5f; // "Lock-in" zone
                                }
                                
                                // Damping term (Velocity-based friction)
                                float2 relVel = particles[id].velocity - particles[pIdx].velocity;
                                float damping = dot(relVel, diff / (d + 1e-4f)) * 0.12f * uniforms.hydrogenStrength;
                                
                                // Total structural correction
                                float structuralForce = (snap + damping) * timeWeight;
                                
                                // SAFETY: Clamp to prevent particle jumping too far in one frame
                                float maxShift = uniforms.particleRadius * 0.6f;
                                structuralForce = clamp(structuralForce, -maxShift, maxShift);
                                
                                correction -= (diff / (d + 1e-4f)) * structuralForce;
                                
                                // Bonus: Color particles by their "bond stability" (structural convergence)
                                if (abs(delta) < uniforms.particleRadius * 0.1f) {
                                    float4 color_id = unpackColor(particles[id].color);
                                    particles[id].color = packColor(float4(color_id.rgb + 0.05f * uniforms.hydrogenStrength * timeWeight, color_id.a));
                                }
                            }
                        }
                    }
                }
                pIdx = particles[pIdx].next;
            }
        }
    }
    
    if (isfinite(correction.x) && isfinite(correction.y)) {
        float maxShift = 0.5f * h;
        if (length(correction) > maxShift) {
            correction = normalize(correction) * maxShift;
        }
        particles[id].position += correction;
    }
    
    float pR = uniforms.particleRadius;
    float2 minP = float2(h + pR, h + pR);
    float2 maxP = float2(float(uniforms.gridRes.x - 1) * h - pR, float(uniforms.gridRes.y - 1) * h - pR);
    particles[id].position = clamp(particles[id].position, minP, maxP);
}

kernel void solvePressure(
    device GridCell* grid [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]],
    uint id [[thread_position_in_grid]],
    constant int& solverPass [[buffer(4)]]
) {
    uint n = uniforms.gridRes.y;
    uint x = id / n;
    uint y = id % n;
    
    if (x <= 0 || x >= uniforms.gridRes.x - 1 || y <= 0 || y >= uniforms.gridRes.y - 1) return;
    if (grid[id].type != 0) return; 

    if ((int(x) + int(y)) % 2 != solverPass) return;

    float s = grid[id-n].s + grid[id+n].s + grid[id-1].s + grid[id+1].s;
    if (s == 0) return;
    
    float div = grid[id+n].u - grid[id].u + grid[id+1].v - grid[id].v;
    if (uniforms.particleRestDensity > 0.0 && uniforms.compensateDrift != 0) {
        float k = 1.9 / 60.0; 
        float compression = grid[id].density - uniforms.particleRestDensity;
        if (compression > 0.0) div -= k * compression;
    }
    
    float p = -div / s * 1.1; 
    
    atomicAddFloat(&grid[id].u, -grid[id-n].s * p);
    atomicAddFloat(&grid[id+n].u, grid[id+n].s * p);
    atomicAddFloat(&grid[id].v, -grid[id-1].s * p);
    atomicAddFloat(&grid[id+1].v, grid[id+1].s * p);
}

kernel void gridToParticles(
    device Particle* particles [[buffer(0)]],
    device GridCell* grid [[buffer(1)]],
    constant Uniforms& uniforms [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.numParticles) return;
    float2 pos = particles[id].position;
    float h = uniforms.spacing;
    float h2 = h * 0.5;
    uint n = uniforms.gridRes.y;
    
    float2 posU = (pos - float2(0, h2)) / h;
    int2 i0 = int2(floor(posU));
    float2 f = posU - float2(i0);
    float w[4] = { (1-f.x)*(1-f.y), f.x*(1-f.y), (1-f.x)*f.y, f.x*f.y };
    int2 o[4] = { {0,0}, {1,0}, {0,1}, {1,1} };
    float u = 0, prevU = 0;
    for(int i=0; i<4; i++) {
        int2 c = clamp(i0 + o[i], int2(0), int2(uniforms.gridRes)-1);
        u += grid[c.x*n+c.y].u * w[i];
        prevU += grid[c.x*n+c.y].prevU * w[i];
    }
    
    float2 posV = (pos - float2(h2, 0)) / h;
    i0 = int2(floor(posV));
    f = posV - float2(i0);
    w[0]=(1-f.x)*(1-f.y); w[1]=f.x*(1-f.y); w[2]=(1-f.x)*f.y; w[3]=f.x*f.y;
    float v = 0, prevV = 0;
    for(int i=0; i<4; i++) {
        int2 c = clamp(i0 + o[i], int2(0), int2(uniforms.gridRes)-1);
        v += grid[c.x*n+c.y].v * w[i];
        prevV += grid[c.x*n+c.y].prevV * w[i];
    }
    
    float2 gridVel = float2(u, v);
    float2 flipVel = particles[id].velocity + (gridVel - float2(prevU, prevV));
    if (!isfinite(flipVel.x) || !isfinite(flipVel.y)) flipVel = gridVel;
    particles[id].velocity = mix(gridVel, flipVel, uniforms.flipRatio);
}

kernel void updateParticleColors(
    device Particle* particles [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]],
    device const GridCell* grid [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.numParticles) return;
    
    float2 pos = particles[id].position;
    float2 vel = particles[id].velocity;
    float speed = length(vel);
    
    // Check for neighbor air
    int2 coord = int2(floor(pos / uniforms.spacing));
    bool nearAir = false;
    for (int i = -1; i <= 1; i++) {
        for (int j = -1; j <= 1; j++) {
            int2 nCoord = coord + int2(i, j);
            if (nCoord.x >= 0 && nCoord.x < (int)uniforms.gridRes.x &&
                nCoord.y >= 0 && nCoord.y < (int)uniforms.gridRes.y) {
                if (grid[nCoord.x * uniforms.gridRes.y + nCoord.y].type == 1) {
                    nearAir = true; break;
                }
            }
        }
        if (nearAir) break;
    }
    
    float decay = 0.01f;
    float4 color = unpackColor(particles[id].color);
    float3 c = color.rgb;
    
    // Base color shift
    c.x = clamp(c.x - decay, 0.2f, 1.0f); 
    c.y = clamp(c.y - decay, 0.2f, 1.0f);
    c.z = clamp(c.z + decay, 0.0f, 1.0f);
    
    // Speed-based foam/highlight (ONLY if near air)
    // LOWERED THRESHOLD FOR HYPER-SENSITIVITY
    if (nearAir) {
        float foam = saturate(speed * 0.8f - 0.05f); // Easier trigger, higher intensity
        c = mix(c, float3(1.0, 1.0, 1.0), foam * 0.9f);
    }
    
    particles[id].color = packColor(float4(c, 1.0));
}

// DIAGNOSTIC KERNEL
kernel void countActiveParticles(
    device Particle* particles [[buffer(0)]],
    device atomic_uint* countBuffer [[buffer(1)]],
    constant Uniforms& uniforms [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.numParticles) return;
    float2 p = particles[id].position;
    // Check if particle is within reasonable bounds (not escaped/vanished)
    if (p.x >= 0 && p.x <= uniforms.domainSize.x && p.y >= 0 && p.y <= uniforms.domainSize.y) {
        atomic_fetch_add_explicit(countBuffer, 1, memory_order_relaxed);
    }
}

kernel void shakeParticles(
    device Particle* particles [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.numParticles) return;
    
    // Generate random impulse direction based on particle ID and time
    float seed = uniforms.time + float(id) * 0.123;
    float2 impulse = float2(
        random(float2(seed, id), 1.0) * 2.0 - 1.0,
        random(float2(id, seed), 2.0) * 2.0 - 1.0
    );
    
    // Apply strong impulse (Shockwave)
    float strength = 50.0; // Adjustable strength
    particles[id].velocity += impulse * strength;
}

// DENSITY CALIBRATION KERNEL
kernel void sumFluidDensity(
    device GridCell* grid [[buffer(0)]],
    device float* densityBuffer [[buffer(1)]],
    device atomic_uint* resultBuffer [[buffer(2)]], // [0]: sum (float bits), [1]: count
    constant Uniforms& uniforms [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    uint numCells = uniforms.gridRes.x * uniforms.gridRes.y;
    if (id >= numCells) return;
    
    // Check if Fluid
    if (grid[id].type == 0) {
        // Atomic Add Float Sum
        atomicAddFloat((device float*)&resultBuffer[0], densityBuffer[id]);
        // Atomic Add Count
        atomic_fetch_add_explicit(&resultBuffer[1], 1, memory_order_relaxed);
    }
}

struct VertexOut {
    float4 position [[position]];
    float3 color;
    float pointSize [[point_size]];
    float2 localPos;
};

// DELETED calculateGridKeys (Fused into integrateAndHash)


vertex VertexOut particleVertex(const device Particle* particles [[buffer(0)]], constant Uniforms& uniforms [[buffer(1)]], uint id [[vertex_id]]) {
    VertexOut out;
    if (uniforms.showParticles == 0) {
        out.position = float4(-10, -10, 0, 1);
        return out;
    }
    float2 pos = particles[id].position;
    
    // Zoom-Aware Mapping
    float2 center = uniforms.domainSize * 0.5;
    float2 normPos = (pos - (center + uniforms.zoomOffset)) * uniforms.zoomLevel / center;
    out.position = float4(normPos, 0, 1);
    
    out.color = unpackColor(particles[id].color).rgb;
    
    // Dynamic Point Size with Zoom Scaling
    float worldToPixel = uniforms.viewportSize.y / uniforms.domainSize.y;
    out.pointSize = uniforms.particleRadius * 2.2 * worldToPixel * sqrt(uniforms.expansionFactor) * uniforms.zoomLevel;
    
    return out;
}

fragment float4 particleFragment(VertexOut in [[stage_in]], float2 pointCoord [[point_coord]]) {
    float dist = length(pointCoord - 0.5);
    if (dist > 0.5) discard_fragment();
    // Hard edge to match HTML reference
    return float4(in.color, 1.0);
}

// OBSTACLE SHADERS (Red Ball)
struct ObstacleVertexIn {
    float2 position [[attribute(0)]];
};

vertex VertexOut obstacleVertex(
    ObstacleVertexIn in [[stage_in]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    VertexOut out;
    if (uniforms.showObstacle == 0) {
        out.position = float4(-10, -10, 0, 1);
        return out;
    }
    
    // VISUAL EXPANSION: Render 1.5x larger than physical radius for the halo/glow
    float visualScale = 1.5f;
    float2 worldPos = uniforms.obstaclePos + in.position * uniforms.obstacleRadius * visualScale;
    
    // Zoom-Aware Mapping
    float2 center = uniforms.domainSize * 0.5;
    float2 normPos = (worldPos - (center + uniforms.zoomOffset)) * uniforms.zoomLevel / center;
    out.position = float4(normPos, 0, 1);
    
    out.color = float3(1.0, 0.0, 0.0); // Bright Red
    out.pointSize = 1.0; 
    out.localPos = in.position; // Still 0->1 range
    return out;
}

fragment float4 obstacleFragment(
    VertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(0)]]
) {
    float dist = length(in.localPos);
    float physicalRadiusEdge = 1.0f / 1.5f; // Threshold where solid obstacle ends
    
    // 1. Solid Core
    if (dist < physicalRadiusEdge) {
        if (uniforms.interactionMode == 1) return float4(0.8, 0.2, 1.0, 0.8);
        return float4(in.color, 1.0);
    }
    
    // 2. Reactive Force Halo (outside the solid core)
    float velMag = length(uniforms.obstacleVel);
    float glow = saturate(velMag * 2.0f);
    
    // Smooth fade out from the physical edge to the visual edge
    float normalizedHaloDist = (dist - physicalRadiusEdge) / (1.0f - physicalRadiusEdge);
    float alpha = saturate(1.0f - normalizedHaloDist);
    alpha = alpha * alpha; // Nicer falloff
    
    float3 haloColor = (uniforms.interactionMode == 1) ? float3(0.9, 0.5, 1.0) : float3(1.0, 0.4, 0.4);
    
    // Pulsing effect
    float pulse = 0.5f + 0.5f * sin(uniforms.dt * 60.0f); 
    
    return float4(haloColor, alpha * (0.2f + glow * 0.8f * pulse));
}

// GRID SHADERS
vertex VertexOut gridVertex(uint id [[vertex_id]], constant Uniforms& uniforms [[buffer(1)]]) {
    VertexOut out;
    if (uniforms.showGrid == 0) {
        out.position = float4(-10, -10, 0, 1);
        return out;
    }
    
    uint nx = uniforms.gridRes.x;
    uint numVertical = nx + 1;
    uint lineIdx = id / 2;
    uint vertIdx = id % 2;
    
    float2 pos;
    float h = uniforms.spacing;
    
    if (lineIdx < numVertical) { // Vertical lines
        pos.x = lineIdx * h;
        pos.y = (vertIdx == 0) ? 0 : uniforms.domainSize.y;
    } else { // Horizontal lines
        uint hIdx = lineIdx - numVertical;
        pos.y = hIdx * h;
        pos.x = (vertIdx == 0) ? 0 : uniforms.domainSize.x;
    }
    
    float2 normPos = (pos - (uniforms.domainSize * 0.5 + uniforms.zoomOffset)) * uniforms.zoomLevel / (uniforms.domainSize * 0.5);
    
    // ADJUSTMENT: Shift 1 pixel left and 1 pixel down
    float2 pixelShift = 2.0 / uniforms.viewportSize;
    normPos -= pixelShift;
    
    out.position = float4(normPos, 0, 1);
    out.color = float3(0.1, 0.1, 0.1); // Subtle grid lines
    return out;
}

fragment float4 gridFragment(VertexOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}

// --- Liquid Surface Rendering (Metaball Effect) ---

struct LiquidVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex LiquidVertexOut liquidVertex(uint vid [[vertex_id]], constant Uniforms& uniforms [[buffer(1)]]) {
    float4 vertices[4] = {
        float4(-1, -1, 0, 1),
        float4( 1, -1, 0, 1),
        float4(-1,  1, 0, 1),
        float4( 1,  1, 0, 1)
    };
    float2 uvs[4] = {
        float2(0, 1),
        float2(1, 1),
        float2(0, 0),
        float2(1, 0)
    };
    
    // ADJUSTMENT: Shift 1 pixel left and 1 pixel down
    float2 pixelSize = 2.0 / uniforms.viewportSize;
    float4 pos = vertices[vid];
    pos.x -= pixelSize.x;
    pos.y -= pixelSize.y;
    
    LiquidVertexOut out;
    out.position = pos;
    
    // Transform UVs for Zoom & Pan
    // Simulation is Y-up, Texture is Y-down.
    float2 centeredUV = uvs[vid] - 0.5;
    out.uv.x = centeredUV.x / uniforms.zoomLevel + 0.5 + (uniforms.zoomOffset.x / uniforms.domainSize.x);
    out.uv.y = centeredUV.y / uniforms.zoomLevel + 0.5 - (uniforms.zoomOffset.y / uniforms.domainSize.y);
    
    return out;
}

// --- Visual Utility: Pseudo-Noise for Cohesion Texture ---
float pseudo_noise(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

float smooth_noise(float2 p) {
    // ROTATION to break square grid alignment
    float c = cos(1.0); float s = sin(1.0);
    float2x2 m = float2x2(c, -s, s, c);
    p = m * p;
    
    float2 i = floor(p);
    float2 f = fract(p);
    
    // Quintic interpolation (smoother than cubic)
    f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    
    float a = pseudo_noise(i);
    float b = pseudo_noise(i + float2(1.0, 0.0));
    float c_noise = pseudo_noise(i + float2(0.0, 1.0)); // Renamed variable to avoid conflict
    float d = pseudo_noise(i + float2(1.0, 1.0));
    
    return mix(mix(a, b, f.x), mix(c_noise, d, f.x), f.y);
}

fragment float4 liquidFragment(
    LiquidVertexOut in [[stage_in]],
    device GridCell* grid [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]],
    texture2d<float, access::sample> background [[texture(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    int2 offsets[4] = { {0,0}, {1,0}, {0,1}, {1,1} };

    auto getDensityAt = [](float2 uv, constant Uniforms& u, device GridCell* g, int2 off[4]) {
        float h_val = u.spacing;
        float2 sPos = float2(uv.x * u.domainSize.x, (1.0 - uv.y) * u.domainSize.y);
        float2 pD = (sPos - float2(h_val * 0.5, h_val * 0.5)) / h_val;
        int2 i0 = int2(floor(pD));
        float2 f = pD - float2(i0);
        float d[4] = {0,0,0,0};
        for (int i=0; i<4; i++) {
            int2 c = i0 + off[i];
            if (c.x >= 0 && (uint)c.x < u.gridRes.x && c.y >= 0 && (uint)c.y < u.gridRes.y) {
                d[i] = g[c.x * u.gridRes.y + c.y].density;
            }
        }
        return mix(mix(d[0], d[1], f.x), mix(d[2], d[3], f.x), f.y);
    };

    auto getVelAt = [](float2 uv, constant Uniforms& u, device GridCell* g, int2 off[4]) {
        float h_val = u.spacing;
        float2 sPos = float2(uv.x * u.domainSize.x, (1.0 - uv.y) * u.domainSize.y);
        float2 pD = (sPos - float2(h_val * 0.5, h_val * 0.5)) / h_val;
        int2 i0 = int2(floor(pD));
        float2 f = pD - float2(i0);
        float2 v[4] = {0,0,0,0};
        for (int i=0; i<4; i++) {
            int2 c = i0 + off[i];
            if (c.x >= 0 && (uint)c.x < u.gridRes.x && c.y >= 0 && (uint)c.y < u.gridRes.y) {
                v[i] = float2(g[c.x * u.gridRes.y + c.y].u, g[c.x * u.gridRes.y + c.y].v);
            }
        }
        return mix(mix(v[0], v[1], f.x), mix(v[2], v[3], f.x), f.y);
    };

    auto getAirFactorAt = [](float2 uv, constant Uniforms& u, device GridCell* g, int2 off[4]) {
        float h_val = u.spacing;
        float2 sPos = float2(uv.x * u.domainSize.x, (1.0 - uv.y) * u.domainSize.y);
        float2 pD = (sPos - float2(h_val * 0.5, h_val * 0.5)) / h_val;
        int2 i0 = int2(floor(pD));
        bool air = false;
        for (int i=0; i<4; i++) {
            int2 c = i0 + off[i];
            if (c.x >= 0 && (uint)c.x < u.gridRes.x && c.y >= 0 && (uint)c.y < u.gridRes.y) {
                if (g[c.x * u.gridRes.y + c.y].type == 1) air = true;
            }
        }
        return air ? 1.0f : 0.0f;
    };

    float density = getDensityAt(in.uv, uniforms, grid, offsets);
    // float airFactor = getAirFactorAt(in.uv, uniforms, grid, offsets); // Unused here, calculated later in Foam Logic

    float baseThreshold = 0.2f / uniforms.expansionFactor; // Lowered from 0.35 to 0.2 for solid volume
    
    // 1. Procedural Surface Waves & Cohesion Noise
    float ripple = sin(in.uv.x * 40.0 + uniforms.time * 2.5) * cos(in.uv.y * 30.0 - uniforms.time * 1.5) * 0.02;
    
    // Transparent Cohesion Texture: Fills micro-gaps with base liquid color
    // REMOVED JITTER: It was causing "disconnected pixel islands" and blockiness.
    // float densityJitter = (cohesionSeed - 0.5) * 0.04; 
    
    float threshold = baseThreshold + ripple;
    
    // ANTI-ALIASING: Smooth alpha at edge
    // Use raw density for perfectly smooth curve
    float surfaceAlpha = smoothstep(threshold - 0.05, threshold + 0.05, density);
    if (surfaceAlpha < 0.01) discard_fragment(); 
    
    // 2. Calculate Precise Surface Normal
    
    // 2. Calculate Precise Surface Normal
    float eps = 0.015f / uniforms.expansionFactor;
    float dX = getDensityAt(in.uv + float2(eps,0), uniforms, grid, offsets) - getDensityAt(in.uv - float2(eps,0), uniforms, grid, offsets);
    float dY = getDensityAt(in.uv + float2(0,eps), uniforms, grid, offsets) - getDensityAt(in.uv - float2(0,eps), uniforms, grid, offsets);
    float2 normal = -normalize(float2(dX, dY) + float2(1e-6));
    
    // 3. Chromatic Aberration Refraction
    float shift = uniforms.refractStrength;
    float2 uvR = in.uv + normal * shift * 1.1;
    float2 uvG = in.uv + normal * shift;
    float2 uvB = in.uv + normal * shift * 0.9;
    
    float4 bgColor;
    bgColor.r = background.sample(textureSampler, uvR).r;
    bgColor.g = background.sample(textureSampler, uvG).g;
    bgColor.b = background.sample(textureSampler, uvB).b;
    bgColor.a = 1.0;
    
    // 4. Premium Water Coloring
    // Redefine Depth: Scaled down to spread the gradient out. 
    // Was * 2.0f, now * 0.8f so it takes longer to get "Deep"
    float depth = saturate((density - threshold) * 0.8f * uniforms.expansionFactor);
    
    // COLOR RAMP:
    // 1. Edge/Surface: Very bright, almost white (simulating thin water / light scattering)
    // 2. Body: Rich Blue
    // 3. Deep: Dark Navy
    
    float3 edgeColor = float3(0.7, 0.9, 1.0);    // Bright Cyan (slightly more saturated)
    float3 bodyColor = float3(0.0, 0.5, 0.9);    // Vibrant Water Blue
    float3 deepColor = float3(0.0, 0.05, 0.2);   // Dark Depth
    
    float3 waterColor;
    if (depth < 0.4) { // Widen the "shallow" zone (was 0.3)
        waterColor = mix(edgeColor, bodyColor, depth / 0.4);
    } else {
        waterColor = mix(bodyColor, deepColor, (depth - 0.4) / 0.6);
    }

    // [Skipping Foam Logic - Same as before]
    // 5. Foam & Specular
    float2 vel = getVelAt(in.uv, uniforms, grid, offsets);
    float speed = length(vel);
    
    // FOAM LOGIC (Moved up to prevent scope issues)
    float foamIntensity = saturate(speed * 1.0f - 0.05f);
    float surfaceMask = getAirFactorAt(in.uv, uniforms, grid, offsets);
    float bubbleNoise = smooth_noise(in.uv * 80.0 + uniforms.time * 0.5); 
    float foamTexture = smoothstep(0.3, 0.7, bubbleNoise);
    
    float finalFoam = 0.0;
    if (surfaceMask > 0.0) {
        finalFoam = foamIntensity * (0.3 + 0.7 * foamTexture);
        float foamGrad = smoothstep(0.4, 0.6, bubbleNoise) - smoothstep(0.4, 0.6, smooth_noise((in.uv + float2(0.001, 0.0)) * 150.0 + uniforms.time * 0.5));
        normal += foamGrad * finalFoam * 0.5; 
        normal = normalize(normal);
    }

    waterColor = mix(waterColor, float3(0.95, 0.98, 1.0), finalFoam * 0.95);

    // Specular
    float3 lightDir = normalize(float3(0.5, 0.8, -1.0));
    float3 viewDir = float3(0, 0, -1);
    float3 halfDir = normalize(lightDir + viewDir);
    float roughness = mix(32.0, 4.0, finalFoam);
    float spec = pow(saturate(dot(float3(normal, 0.5), halfDir)), roughness);
    
    // 6. Rim Lighting
    float edge = 1.0 - saturate((density - threshold) * 8.0);
    float rim = pow(edge, 3.0) * 0.5;
    
    // Final Fluid Color
    float3 finalFluidColor = waterColor + float3(1.0, 1.0, 1.0) * spec * (0.8 - finalFoam * 0.4) + float3(0.8, 0.9, 1.0) * rim;
    
    // 7. COMPOSITING
    float3 tintedBackground = bgColor.rgb * waterColor; 
    float alpha = saturate(depth * 1.5); 
    float3 edgeGlow = edgeColor * (1.0 - alpha) * 0.6;
    
    float3 finalColor = mix(tintedBackground, finalFluidColor, alpha) + edgeGlow;
    
    return float4(finalColor, surfaceAlpha);
}

// --- PIXELS VIEW SHADER ---
fragment float4 pixelFragment(
    LiquidVertexOut in [[stage_in]],
    device GridCell* grid [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    // 1. Quantize UV into Simulation Grid Pixels (Dynamic Size)
    float2 gridRes = float2(uniforms.gridRes) * (1.0 / uniforms.pixelSize); 
    float2 pixelUV = floor(in.uv * gridRes) / gridRes;
    float2 centerUV = (floor(in.uv * gridRes) + 0.5) / gridRes;
    
    // 2. Fetch Density at block center
    float h_val = uniforms.spacing;
    float2 sPos = float2(centerUV.x * uniforms.domainSize.x, (1.0 - centerUV.y) * uniforms.domainSize.y);
    int2 coord = int2(floor(sPos / h_val));
    
    float density = 0;
    if (coord.x >= 0 && (uint)coord.x < uniforms.gridRes.x && coord.y >= 0 && (uint)coord.y < uniforms.gridRes.y) {
        density = grid[coord.x * uniforms.gridRes.y + coord.y].density;
    }
    
    float threshold = 0.25f / uniforms.expansionFactor;
    if (density < threshold) discard_fragment();
    
    // 3. Stylized Retro Color
    // Map density to a vibrant blue/cyan range
    float d = saturate((density - threshold) * 0.5);
    float3 baseColor = mix(float3(0.0, 0.4, 1.0), float3(0.0, 1.0, 0.8), d);
    
    // 4. Pixel Border Effect (Grid look)
    float2 localCoord = fract(in.uv * gridRes);
    float border = 0.1;
    float mask = step(border, localCoord.x) * step(border, localCoord.y) * 
                 step(localCoord.x, 1.0 - border) * step(localCoord.y, 1.0 - border);
    
    // Darken the border for a nice LCD/CRT grid look
    float3 finalColor = mix(baseColor * 0.2, baseColor, mask);
    
    // Add a subtle "glow" based on time
    float pulse = sin(uniforms.time * 2.0 + (pixelUV.x + pixelUV.y) * 10.0) * 0.1 + 0.9;
    finalColor *= pulse;
    
    return float4(finalColor, 1.0);
}
