#include <metal_stdlib>
using namespace metal;

// ----------------------------------------------------------------------------
// DATA STRUCTURES
// ----------------------------------------------------------------------------

struct RenderUniforms {
    uint flags;               // 4 bytes
    float _pad0;              // 4 bytes padding
    float _pad1;              // 4 bytes padding
    float _pad2;              // 4 bytes padding (total 16 for float4 alignment)
    float4 smokeColor;        // 16 bytes (offset 16)
    float2 obstaclePos;       // 8 bytes (offset 32)
    float obstacleRadius;     // 4 bytes (offset 40)
    float _pad3;              // 4 bytes padding (offset 44)
    float2 gridRes;           // 8 bytes (offset 48)
    float _pad4;              // 4 bytes (offset 56)
    float _pad5;              // 4 bytes (offset 60) - Total: 64 bytes
};

// Rendering Flags (Bitmask)
#define FLAG_SMOKE       (1 << 0)
#define FLAG_PRESSURE    (1 << 1)
#define FLAG_VELOCITY    (1 << 2)
#define FLAG_VORTICITY   (1 << 3)
#define FLAG_VECTORS     (1 << 4)
#define FLAG_SCIENTIFIC  (1 << 5)
#define FLAG_STREAMLINES (1 << 6)
#define FLAG_VERTICAL    (1 << 7) // Phase 55: iOS Portrait Orientation

struct GasVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct SimulationUniforms {
    float dt;
    float dissipation;
    float buoyancy;
    float vorticityStrength;
    float omega;
    int parity;
    float cp; // Pressure scaling density * h / dt
    float h;  // Phase 38: Grid spacing (meters)
    int isDensity; // 1 = Density (White Default), 0 = Velocity (Zero Default)
    float2 obstaclePos;   // Phase 52
    float obstacleRadius; // Phase 52
    float2 obstacleVel;   // Phase 52
    float windSpeed;
    float _pad;
};

// ----------------------------------------------------------------------------
// RENDER SHADERS (Quad Visualization)
// ----------------------------------------------------------------------------

vertex GasVertexOut gasVertex(uint vertexID [[vertex_id]], constant RenderUniforms &render [[buffer(0)]]) {
    // Full screen triangle strip quad
    // 0: (-1, -1), 1: (1, -1), 2: (-1, 1), 3: (1, 1)
    float2 pos[4] = {
        float2(-1, -1), float2(1, -1),
        float2(-1, 1),  float2(1, 1)
    };
    float2 uvs[4] = {
        float2(0, 1), float2(1, 1), // Screen Bottom (y=-1) -> Texture Bottom (y=1)
        float2(0, 0), float2(1, 0)  // Screen Top (y=1) -> Texture Top (y=0)
    };
    
    GasVertexOut out;
    out.position = float4(pos[vertexID], 0, 1);
    float2 baseUV = uvs[vertexID];
    
    // Phase 55: iOS Vertical Rotation (90 Degrees Counter-Clockwise)
    // To make horizontal flow look Vertical (Bottom -> Top)
    if (render.flags & FLAG_VERTICAL) {
        // Phase 57: Correct CCW 90 rotation: (u,v) -> (1-v, u)
        out.uv = float2(1.0 - baseUV.y, baseUV.x);
    } else {
        out.uv = baseUV;
    }
    
    return out;
}

// Custom mapping matching Ten Minute Physics reference:
// Red (High) -> Yellow -> Green (Mid) -> Cyan -> Blue (Low)
float3 getCustomSciColor(float val, float minVal, float maxVal) {
    val = clamp(val, minVal, maxVal - 0.0001);
    float d = maxVal - minVal;
    float s = (d == 0.0) ? 0.5 : (val - minVal) / d;
    
    // 4-segment mapping
    float m = 0.25;
    float num = floor(s / m);
    float t = (s - num * m) / m;
    
    if (num == 0) return mix(float3(0.1, 0.2, 0.9), float3(0.1, 0.9, 0.9), t); // Blue -> Cyan
    if (num == 1) return mix(float3(0.1, 0.9, 0.9), float3(0.1, 0.9, 0.1), t); // Cyan -> Green
    if (num == 2) return mix(float3(0.1, 0.9, 0.1), float3(0.9, 0.9, 0.1), t); // Green -> Yellow
    return mix(float3(0.9, 0.9, 0.1), float3(0.9, 0.1, 0.1), t);              // Yellow -> Red
}

fragment float4 gasFragment(GasVertexOut in [[stage_in]],
                            texture2d<float> densityTex [[texture(0)]],
                            texture2d<float> velocityTex [[texture(1)]],
                            texture2d<float> pressureTex [[texture(2)]],
                            texture2d<float> vorticityTex [[texture(3)]],
                            texture2d<float> obstacleTex [[texture(4)]],
                            texture2d<float> streamTex [[texture(5)]],
                            constant RenderUniforms &uniforms [[buffer(0)]])
{
    float2 uv = in.uv;
    // Phase 45: Linear Sampler to eliminate "Vertical Grid Lines" (aliasing)
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    
    // Theme Switching
    bool showPressure = (uniforms.flags & FLAG_PRESSURE) || (uniforms.flags & FLAG_SCIENTIFIC);
    float den = densityTex.sample(s, uv).r;
    
    // Default Backgrounds
    float4 backgroundColor = showPressure ? float4(0, 0, 0, 1.0) : float4(1.0, 1.0, 1.0, 1.0);
    float4 color = backgroundColor;
    
    // 1. Layer: Pressure / Gas Coloring
    if (showPressure) {
        float p = pressureTex.sample(s, uv).r;
        // Phase 66: Calibration to physical units (~ -4000 to 4000)
        // Match simulation clamp limits (-1000 to 1000) for varying pressure visibility
        float3 pCol = getCustomSciColor(p, -1000.0, 1000.0);
        
        if (uniforms.flags & FLAG_SMOKE) {
            // Phase 66: Combo View (Vibrant Tinted Smoke on Black)
            // Smoke is 0.0 (Black), Air is 1.0 (White). 
            // Phase 71: Visual Density Enhancement
            // Convert 'den' (1=Air, 0=Smoke) to 'smoke' (0=Air, 1=Smoke)
            float smoke = clamp(1.0 - den, 0.0, 1.0);
            
            // Apply Power Curve to "thicken" the look
            // larger power makes it thinner (pushes midtones to 0)
            // smaller power (0.5) makes it thicker (pushes midtones to 1)
            // Let's use 0.5 for a "Thick Gas" look.
            smoke = pow(smoke, 0.5);
            
            float smokeAlpha = smoke;
            color.rgb = pCol * smokeAlpha;
        } else {
            // Phase 66: Pressure Only (Full Heatmap)
            color.rgb = pCol;
        }
    } else if (uniforms.flags & FLAG_SMOKE) {
        // Pure Smoke Mode: White Background, Black Smoke
        // Phase 71: Visual Density Enhancement
        // densityTex: 1.0 = Clean Air (White), 0.0 = Dense Smoke (Black)
        float smoke = clamp(1.0 - den, 0.0, 1.0);
        
        // Boost Thicknes: pow(s, 0.4) makes 0.5 -> 0.75 opacity (darker)
        smoke = pow(smoke, 0.4); 
        
        // Invert back to display color (0 = Black/Smoke, 1 = White/Air)
        float displayVal = 1.0 - smoke;
        
        color = float4(displayVal, displayVal, displayVal, 1.0);
    }
    
    // 2. Layer: Vorticity (Overlay)
    if (uniforms.flags & FLAG_VORTICITY) {
        float vort = abs(vorticityTex.sample(s, uv).r);
        float3 vCol = showPressure ? float3(1, 1, 0) : float3(1, 0, 0); // Yellow on black, Red on white
        color.rgb = mix(color.rgb, vCol, clamp(vort * 0.2, 0.0, 0.5));
    }
    
    // 3. Layer: Obstacle Clipping (Analytic SDF)
    float2 currentPos = in.uv * uniforms.gridRes;
    float d = distance(currentPos, uniforms.obstaclePos);
    float r = uniforms.obstacleRadius;
    
    // Phase 44: Absolute Clipping & Grey Obstacle
    if (d < r) {
        return float4(0.5, 0.5, 0.5, 1.0); // Classic Grey
    }
    
    // Anti-Aliased Border
    if (d < r + 2.0) {
        float AA = fwidth(d);
        float alpha = 1.0 - smoothstep(r - AA, r + AA, d);
        float3 obstacleColor = showPressure ? float3(0,0,0) : float3(0.5, 0.5, 0.5);
        color.rgb = mix(color.rgb, obstacleColor, alpha);
    }
    
    return color;
}

// ----------------------------------------------------------------------------
// COMPUTE KERNELS (Eulerian Fluid)
// ----------------------------------------------------------------------------

// 0. Init / Clear
kernel void gas_clear(texture2d<float, access::write> tex [[texture(0)]],
                      constant float4 &color [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= tex.get_width() || gid.y >= tex.get_height()) return;
    tex.write(color, gid);
}

kernel void gas_init_wind_tunnel_velocity_u(texture2d<float, access::write> uTex [[texture(0)]],
                                             constant float &inVel [[buffer(0)]],
                                             uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uTex.get_width() || gid.y >= uTex.get_height()) return;
    uTex.write(float4(gid.x == 1 ? inVel : 0.0, 0, 0, 0), gid);
}

kernel void gas_init_wind_tunnel_velocity_v(texture2d<float, access::write> vTex [[texture(0)]],
                                             uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= vTex.get_width() || gid.y >= vTex.get_height()) return;
    vTex.write(float4(0, 0, 0, 0), gid);
}

kernel void gas_init_wind_tunnel_smoke(texture2d<float, access::write> densityTex [[texture(0)]],
                                       constant float &pipeMin [[buffer(0)]],
                                       constant float &pipeMax [[buffer(1)]],
                                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= densityTex.get_width() || gid.y >= densityTex.get_height()) return;
    
    // m=1 (white/clear) by default, m=0 (black/smoke) in pipe region
    if (gid.x == 0 && float(gid.y) >= pipeMin && float(gid.y) <= pipeMax) {
        densityTex.write(float4(0, 0, 0, 0), gid);  // Smoke
    } else {
        densityTex.write(float4(1, 1, 1, 1), gid);  // Clear
    }
}


// 1. Advect Scalar (Density/Smoke)
kernel void gas_advect_smoke(texture2d<float, access::sample> uTex [[texture(0)]],
                             texture2d<float, access::sample> vTex [[texture(1)]],
                             texture2d<float, access::sample> sourceTex [[texture(2)]],
                             texture2d<float, access::write> destTex [[texture(3)]],
                             texture2d<float, access::sample> obstacleTex [[texture(4)]],
                             constant SimulationUniforms &sim [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]])
{
    uint w = destTex.get_width();
    uint h = destTex.get_height();
    // Boundary Check: Phase 90 Seamless Reservoir Protection.
    // Skip advection inside the reservoir depth to prevent conflicts with forcing.
    float travelDist = (sim.windSpeed * sim.dt) / sim.h;
    float sourceWidth = max(2.5, travelDist + 1.0);
    
    if (float(gid.x) <= sourceWidth) {
        destTex.write(sourceTex.read(gid), gid);
        return;
    }

    // Clear density inside obstacles to prevent "ghosting" or "carry-over"
    if (obstacleTex.read(gid).r < 0.1) {
        destTex.write(float4(1.0, 1.0, 1.0, 1.0), gid);
        return;
    }
    
    float2 size = float2(w, h);
    float2 coords = float2(gid);
    
    constexpr sampler s_linear(address::clamp_to_edge, filter::linear);
    float2 uv_sample = (coords + 0.5) / size;
    
    // Average velocity at cell center
    float2 vel = float2(uTex.sample(s_linear, uv_sample).r, vTex.sample(s_linear, uv_sample).r);
    
    float2 backPos = (coords + 0.5) - vel * sim.dt / sim.h;
    
    // Solid Source Blocking: If sampling from a solid, pull from current cell center instead
    // to prevent "erasing" gas by sampling Air (1.0) from inside a wall.
    // EXEMPTION: Allow sampling from the x=0 world inlet border (Dirichlet source).
    float2 backUV = backPos / size;
    uint2 backID = uint2(clamp(backPos.x, 0.5, size.x - 0.5), clamp(backPos.y, 0.5, size.y - 0.5));
    if (obstacleTex.read(backID).r < 0.5 && backID.x > 0) {
        backUV = uv_sample; 
    }
    
    // Soften sampling slightly to hide numerical staircase artifacts
    float4 result = sourceTex.sample(s_linear, backUV);
    float d = sim.dissipation; 
    float4 finalResult = 1.0 - (1.0 - result) * d;
    
    if (!isfinite(finalResult.r)) finalResult = float4(1, 1, 1, 1);
    destTex.write(finalResult, gid);
}

// 2. Advect Velocity (Staggered Vector)
kernel void gas_advect_velocity_staggered(texture2d<float, access::sample> uInTex [[texture(0)]],
                                          texture2d<float, access::sample> vInTex [[texture(1)]],
                                          texture2d<float, access::write> uOutTex [[texture(2)]],
                                          texture2d<float, access::write> vOutTex [[texture(3)]],
                                          texture2d<float, access::read> obstacleTex [[texture(4)]],
                                          constant SimulationUniforms &sim [[buffer(0)]],
                                          uint2 gid [[thread_position_in_grid]])
{
    uint w = uOutTex.get_width();
    uint h = uOutTex.get_height();
    if (gid.x >= w || gid.y >= h) return;
    
    float2 size = float2(w, h);
    float2 coords = float2(gid);
    constexpr sampler s_linear(address::clamp_to_edge, filter::linear);
    
    // 1. Advect U (Left Face: x=i, y=j+0.5)
    float uNew = uInTex.read(gid, 0).r; // Preserve current if solid/boundary
    if (obstacleTex.read(gid).r > 0.1 && obstacleTex.read(uint2(max((int)gid.x-1,0), (int)gid.y)).r > 0.1) {
        float avgV = vInTex.sample(s_linear, (coords + float2(0.0, 0.5)) / size).r;
        float2 velU = float2(uNew, avgV);
        float2 backPosU = (coords + float2(0.0, 0.5)) - velU * sim.dt / sim.h;
        uNew = uInTex.sample(s_linear, backPosU / size).r;
    }
    
    // 2. Advect V (Bottom Face: x=i+0.5, y=j)
    float vNew = vInTex.read(gid, 0).r; // Preserve current if solid/boundary
    if (obstacleTex.read(gid).r > 0.1 && obstacleTex.read(uint2((int)gid.x, max((int)gid.y-1,0))).r > 0.1) {
        float avgU = uInTex.sample(s_linear, (coords + float2(0.5, 0.0)) / size).r;
        float2 velV = float2(avgU, vNew);
        float2 backPosV = (coords + float2(0.5, 0.0)) - velV * sim.dt / sim.h;
        vNew = vInTex.sample(s_linear, backPosV / size).r;
    }
    
    uOutTex.write(float4(uNew, 0, 0, 1), gid);
    vOutTex.write(float4(vNew, 0, 0, 1), gid);
}

// Phase 72: Extrapolate (Boundary Copy)
// Matches HTML extrapolate(): Copies inner neighbor velocity to boundary edge.
kernel void gas_extrapolate(texture2d<float, access::read> sourceTex [[texture(0)]],
                            texture2d<float, access::write> destTex [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]])
{
    uint w = destTex.get_width();
    uint h = destTex.get_height();
    
    if (gid.x >= w || gid.y >= h) return;
    
    float4 val = sourceTex.read(gid);
    
    // Extrapolate X boundaries
    if (gid.x == 0) {
        val = sourceTex.read(uint2(1, gid.y));
    } else if (gid.x == w - 1) {
        val = sourceTex.read(uint2(w - 2, gid.y));
    }
    
    // Extrapolate Y boundaries
    if (gid.y == 0) {
        val = sourceTex.read(uint2(gid.x, 1));
    } else if (gid.y == h - 1) {
        val = sourceTex.read(uint2(gid.x, h - 2));
    }
    
    destTex.write(val, gid);
}

// 1b. Diffuse Density (Phase 65: Removes zigzag artifacts)
// Phase 68: Boundary Blocking (Prevent White Halo)
kernel void gas_diffuse_density(texture2d<float, access::read> sourceTex [[texture(0)]],
                                texture2d<float, access::write> destTex [[texture(1)]],
                                texture2d<float, access::read> obstacleTex [[texture(2)]],
                                uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= destTex.get_width() || gid.y >= destTex.get_height()) return;
    
    // Boundary Check: If we are inside solid, just write pure White and exit
    // This keeps the "Inside" clean.
    if (obstacleTex.read(gid).r < 0.1) {
        destTex.write(float4(1, 1, 1, 1), gid);
        return;
    }

    uint w = sourceTex.get_width();
    uint h = sourceTex.get_height();
    
    float4 c = sourceTex.read(gid);
    
    // Neumann Neighbor Fetch:
    // If neighbor is solid, use Center value 'c' instead.
    // This effectively means "Zero Flux" across the boundary for diffusion.
    
    uint2 lID = uint2(max((int)gid.x - 1, 0), gid.y);
    float4 l = (obstacleTex.read(lID).r < 0.5) ? c : sourceTex.read(lID);
    
    uint2 rID = uint2(min((int)gid.x + 1, (int)w - 1), gid.y);
    float4 r = (obstacleTex.read(rID).r < 0.5) ? c : sourceTex.read(rID);
    
    uint2 bID = uint2(gid.x, max((int)gid.y - 1, 0));
    float4 b = (obstacleTex.read(bID).r < 0.5) ? c : sourceTex.read(bID);
    
    uint2 tID = uint2(gid.x, min((int)gid.y + 1, (int)h - 1));
    float4 t = (obstacleTex.read(tID).r < 0.5) ? c : sourceTex.read(tID);
    
    // Simple Box Blur
    float diffused = (c.r + l.r + r.r + b.r + t.r) / 5.0;
    destTex.write(float4(diffused, 0, 0, 1), gid);
}


// 2. Divergence
// Calculates local expansion/contraction of fluid
kernel void gas_solve_gauss_seidel(texture2d<half, access::read_write> uTex [[texture(0)]],
                                   texture2d<half, access::read_write> vTex [[texture(1)]],
                                   texture2d<half, access::read_write> pressureTex [[texture(2)]],
                                   texture2d<float, access::read> obstacleTex [[texture(3)]],
                                   constant SimulationUniforms &sim [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]])
{
    uint w = uTex.get_width();
    uint h = uTex.get_height();
    
    // Phase 90: Dirichlet Reservoir Protection.
    // Protect the entire reservoir zone from solver adjustments.
    float travelDist = (sim.windSpeed * sim.dt) / sim.h;
    float sourceWidth = max(2.5, travelDist + 1.0);
    
    if (float(gid.x) <= sourceWidth || gid.x >= w - 1 || gid.y <= 0 || gid.y >= h - 1) return;
    
    // Red-Black Checkerboard: (i+j) % 2
    if ((int(gid.x) + int(gid.y)) % 2 != sim.parity) return;

    // Obstacle Check (Fluidity)
    if (obstacleTex.read(gid).r < 0.1) return;
    
    float uL = uTex.read(gid).r;
    float uR = uTex.read(uint2(gid.x + 1, gid.y)).r;
    float vB = vTex.read(gid).r;
    float vT = vTex.read(uint2(gid.x, gid.y + 1)).r;
    
    // Boundary Solid check for Divergence Calculation
    float sL = obstacleTex.read(uint2(gid.x - 1, gid.y)).r > 0.1 ? 1.0 : 0.0;
    float sR = obstacleTex.read(uint2(gid.x + 1, gid.y)).r > 0.1 ? 1.0 : 0.0;
    float sB = obstacleTex.read(uint2(gid.x, gid.y - 1)).r > 0.1 ? 1.0 : 0.0;
    float sT = obstacleTex.read(uint2(gid.x, gid.y + 1)).r > 0.1 ? 1.0 : 0.0;
    
    float s = sL + sR + sB + sT;
    if (s == 0.0) return;
    
    // Enforce obstacle / boundary velocities in divergence calculation
    float2 obstacleVel = sim.obstacleVel;
    float windSpeed = sim.windSpeed; 
    
    // Phase 83: Isolate obstacle velocity from stationary grid walls (gid.y=1 or gid.y=h-2)
    if (sL < 0.1) uL = (gid.x == 1) ? windSpeed : obstacleVel.x;
    if (sR < 0.1) uR = (gid.x == w - 2) ? 0.0 : obstacleVel.x; 
    if (sB < 0.1) vB = (gid.y == 1) ? 0.0 : obstacleVel.y;
    if (sT < 0.1) vT = (gid.y == h - 2) ? 0.0 : obstacleVel.y;
    
    float div = (uR - uL) + (vT - vB);
    float d = sim.omega * div; 
    
    // 2. Update Velocity Components (Directly in Place)
    d = clamp(d, -100.0, 100.0);

    // Current Cell Faces: Left (uL) and Bottom (vB)
    float newUL = uL;
    float newVB = vB;
    if (sL > 0.1) newUL += d * (sL / s);
    if (sB > 0.1) newVB += d * (sB / s);
    
    // Speed Limit Clamp
    newUL = clamp(newUL, -50.0, 50.0);
    newVB = clamp(newVB, -50.0, 50.0);
    uTex.write(half4(newUL, 0, 0, 1), gid);
    vTex.write(half4(newVB, 0, 0, 1), gid);
    
    // Neighbor Faces: Right (uR) and Top (vT)
    // Red-Black safely allows these neighbor updates
    if (sR > 0.1) {
        float nR_u = uTex.read(uint2(gid.x + 1, gid.y)).r;
        nR_u -= d * (sR / s);
        uTex.write(half4(clamp(nR_u, -50.0, 50.0), 0, 0, 1), uint2(gid.x + 1, gid.y));
    }
    if (sT > 0.1) {
        float nT_v = vTex.read(uint2(gid.x, gid.y + 1)).r;
        nT_v -= d * (sT / s);
        vTex.write(half4(clamp(nT_v, -50.0, 50.0), 0, 0, 1), uint2(gid.x, gid.y + 1));
    }
    
    // 3. Accumulate Pressure (Matches HTML p += cp * (-div / s * omega))
    float p = pressureTex.read(gid).r;
    float p_new = p - (d / s) * sim.cp; 
    pressureTex.write(half4(clamp(p_new, -1000.0, 1000.0), 0, 0, 1), gid);
}

kernel void gas_pressure_clear(texture2d<float, access::write> pressureTex [[texture(0)]],
                               uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= pressureTex.get_width() || gid.y >= pressureTex.get_height()) return;
    pressureTex.write(float4(0, 0, 0, 1), gid);
}

// Jacobi removed for GS parity

// Subtract Gradient removed for GS parity

// 5. Splat / Interaction Kernels
kernel void gas_splat(texture2d<float, access::read> readTex [[texture(0)]],
                      texture2d<float, access::write> writeTex [[texture(1)]],
                      constant float2 &point [[buffer(0)]],
                      constant float &radius [[buffer(1)]],
                      constant float4 &color [[buffer(2)]],
                      constant int &isSet [[buffer(3)]],
                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= writeTex.get_width() || gid.y >= writeTex.get_height()) return;
    
    float2 coords = float2(gid);
    float d = distance(coords, point);
    float4 base = readTex.read(gid);
    
    if (d < radius) {
        float strength = exp(-d * d / (radius * 0.5));
        if (isSet) base = mix(base, color, strength);
        else base += color * strength;
    }
    writeTex.write(base, gid);
}

// 5b. Left Inflow (Robust Post-Advection Forcing)
// 5b. Boundary Condition Forcing (One-Way Wind Tunnel)
kernel void gas_set_left_inflow(texture2d<float, access::read> denRead [[texture(0)]],
                                 texture2d<float, access::write> denWrite [[texture(1)]],
                                 texture2d<float, access::read> uRead [[texture(2)]],
                                 texture2d<float, access::write> uWrite [[texture(3)]],
                                 texture2d<float, access::read> vRead [[texture(4)]],
                                 texture2d<float, access::write> vWrite [[texture(5)]],
                                 constant float2 &velocity [[buffer(0)]],
                                 constant SimulationUniforms &sim [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]])
{
    uint w = denWrite.get_width();
    uint h = denWrite.get_height();
    if (gid.x >= w || gid.y >= h) return;
    
    float den = denRead.read(gid).r;
    float u = uRead.read(gid).r;
    float v = vRead.read(gid).r;
    
    // --- LEFT INFLOW (Forcing) ---
    // Phase 89: High-Parity Deep Reservoir.
    // Dynamically broaden the reservoir based on wind travel distance per frame.
    // This ensures advection at x=i (where i > 0) always pulls from a continuous smoke pool.
    float travelDist = (sim.windSpeed * sim.dt) / sim.h;
    float sourceWidth = max(2.5, travelDist + 1.0);
    
    if (float(gid.x) <= sourceWidth) {
        float pipeH = float(h) * 0.1;
        float centerY = float(h) * 0.5;
        float distToCenter = abs(float(gid.y) - centerY);
        
        // Anti-Aliased Rectangular Profile (1-pixel soft edge)
        float halfPipe = pipeH * 0.5;
        float edge = 1.0; 
        den = smoothstep(halfPipe - edge, halfPipe + edge, distToCenter);
        
        // Phase 90: Pure Dirichlet Reservoir.
        // Force both horizontal and vertical velocity across the depth
        // to ensure a perfectly laminar "pipe" injection without internal divergence.
        u = velocity.x;
        v = 0.0;
        
        // Anti-NaN Safety
        if (!isfinite(u)) u = velocity.x;
        if (!isfinite(v)) v = 0.0;
        if (!isfinite(den)) den = 1.0;
    }
    
    // --- RIGHT OUTFLOW (Cleansing) ---
    if (gid.x >= w - 2) {
        float fade = clamp((float(gid.x - (w - 2)) / 2.0), 0.0, 1.0);
        den = mix(den, 1.0, fade);
        u = mix(u, max(u, velocity.x), fade);
        v = mix(v, 0.0, fade);
    }
    
    // Grid-Wide Mandatory Write Coverage (Prevents Garbage Injection)
    denWrite.write(float4(den, 0, 0, 1), gid);
    uWrite.write(float4(u, 0, 0, 1), gid);
    vWrite.write(float4(v, 0, 0, 1), gid);
}

// 5a. Splat Rect (Used for initial setup or custom drawing)
kernel void gas_splat_rect(texture2d<float, access::read> readTex [[texture(0)]],
                           texture2d<float, access::write> writeTex [[texture(1)]],
                           constant float2 &center [[buffer(0)]],
                           constant float2 &halfSize [[buffer(1)]],
                           constant float4 &color [[buffer(2)]],
                           constant int &isSet [[buffer(3)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= writeTex.get_width() || gid.y >= writeTex.get_height()) return;
    
    float2 coords = float2(gid);
    float2 delta = abs(coords - center);
    
    float4 base = readTex.read(gid);
    
    if (delta.x <= halfSize.x && delta.y <= halfSize.y) {
        if (isSet) base = color;
        else base += color;
    }
    writeTex.write(base, gid);
}

// 6b. Boundary Enforcement (Legacy/Fallback)
kernel void gas_boundary_circle(texture2d<float, access::write> velocityTex [[texture(0)]],
                               texture2d<float, access::write> densityTex [[texture(1)]],
                               constant float2 &center [[buffer(0)]],
                               constant float &radius [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= velocityTex.get_width() || gid.y >= velocityTex.get_height()) return;
    float2 coords = float2(gid);
    if (distance(coords, center) < radius) {
        velocityTex.write(float4(0, 0, 0, 0), gid);
    }
}

// 11. Streamline Advection (Lagrangian Step for Legacy Streamlines)
kernel void gas_advect_streamlines(texture2d<float, access::sample> velocityTex [[texture(0)]],
                                   texture2d<float, access::sample> sourceTex [[texture(1)]],
                                   texture2d<float, access::write> destTex [[texture(2)]],
                                   texture2d<float, access::read> obstacleTex [[texture(3)]],
                                   constant SimulationUniforms &sim [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= destTex.get_width() || gid.y >= destTex.get_height()) return;
    
    // Boundary Check: If inside solid, preserve
    if (obstacleTex.read(gid).r < 0.1) {
        destTex.write(sourceTex.read(gid), gid);
        return;
    }
    
    float2 coords = float2(gid);
    float2 size = float2(destTex.get_width(), destTex.get_height());
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    
    float2 uv = (coords + 0.5) / size;
    float2 vel = velocityTex.sample(s, uv).xy;
    
    // Phase 38 Sync: Trace back using (vel / h)
    float2 backPos = coords - (vel / sim.h) * sim.dt;
    float2 backUV = (backPos + 0.5) / size;
    
    float4 result = sourceTex.sample(s, backUV);
    destTex.write(result, gid);
}

// 6. Obstacle Management
kernel void gas_draw_obstacle(texture2d<float, access::write> obstacleTex [[texture(0)]],
                              constant float2 &point [[buffer(0)]],
                              constant float &radius [[buffer(1)]],
                              constant float &value [[buffer(2)]], // 1.0 = Fluid, 0.0 = Solid
                              uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= obstacleTex.get_width() || gid.y >= obstacleTex.get_height()) return;
    if (distance(float2(gid), point) < radius) {
        obstacleTex.write(float4(value, 0, 0, 1), gid);
    }
}

kernel void gas_draw_border(texture2d<float, access::write> obstacleTex [[texture(0)]],
                            uint2 gid [[thread_position_in_grid]])
{
    uint w = obstacleTex.get_width();
    uint h = obstacleTex.get_height();
    if (gid.x >= w || gid.y >= h) return;
    
    // Solid Boundaries: Bottom (y=0), Top (y=h-1)
    // AND Left (x=0) for Wind Tunnel Dirichlet logic
    if (gid.y == 0 || gid.y == h - 1 || gid.x == 0) {
        obstacleTex.write(float4(0.0, 0, 0, 1), gid);
    }
}

// 7. Vorticity
kernel void gas_calc_vorticity(texture2d<float, access::read> uTex [[texture(0)]],
                               texture2d<float, access::read> vTex [[texture(1)]],
                               texture2d<float, access::write> vorticityTex [[texture(2)]],
                               uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= vorticityTex.get_width() || gid.y >= vorticityTex.get_height()) return;
    uint w = uTex.get_width();
    uint h = uTex.get_height();
    
    float vL = vTex.read(uint2(max((int)gid.x - 1, 0), gid.y)).r;
    float vR = vTex.read(uint2(min((int)gid.x + 1, (int)w - 1), gid.y)).r;
    float uB = uTex.read(uint2(gid.x, max((int)gid.y - 1, 0))).r;
    float uT = uTex.read(uint2(gid.x, min((int)gid.y + 1, (int)h - 1))).r;
    
    float curl = (vR - vL) - (uT - uB);
    vorticityTex.write(float4(curl, 0, 0, 1), gid);
}

kernel void gas_apply_vorticity_confinement(texture2d<float, access::read> uInTex [[texture(0)]],
                                            texture2d<float, access::read> vInTex [[texture(1)]],
                                            texture2d<float, access::read> vorticityTex [[texture(2)]],
                                            texture2d<float, access::write> uOutTex [[texture(3)]],
                                            texture2d<float, access::write> vOutTex [[texture(4)]],
                                            constant SimulationUniforms &sim [[buffer(0)]],
                                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uOutTex.get_width() || gid.y >= uOutTex.get_height()) return;
    uint w = vorticityTex.get_width();
    uint h = vorticityTex.get_height();
    
    float vL = abs(vorticityTex.read(uint2(max((int)gid.x - 1, 0), gid.y)).r);
    float vR = abs(vorticityTex.read(uint2(min((int)gid.x + 1, (int)w - 1), gid.y)).r);
    float vB = abs(vorticityTex.read(uint2(gid.x, max((int)gid.y - 1, 0))).r);
    float vT = abs(vorticityTex.read(uint2(gid.x, min((int)gid.y + 1, (int)h - 1))).r);
    
    float2 eta = 0.5 * float2(vR - vL, vT - vB);
    float magnitude = length(eta) + 1e-4;
    eta /= magnitude;
    
    float curl = vorticityTex.read(gid).r;
    float2 force = sim.vorticityStrength * float2(eta.y * curl, -eta.x * curl);
    
    float newU = uInTex.read(gid).r + force.x * sim.dt;
    float newV = vInTex.read(gid).r + force.y * sim.dt;
    uOutTex.write(float4(newU, 0, 0, 1), gid);
    vOutTex.write(float4(newV, 0, 0, 1), gid);
}

// 8. Buoyancy
kernel void gas_buoyancy(texture2d<float, access::read> uInTex [[texture(0)]],
                         texture2d<float, access::read> vInTex [[texture(1)]],
                         texture2d<float, access::read> densityTex [[texture(2)]],
                         texture2d<float, access::write> uOutTex [[texture(3)]],
                         texture2d<float, access::write> vOutTex [[texture(4)]],
                         constant SimulationUniforms &sim [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uOutTex.get_width() || gid.y >= uOutTex.get_height()) return;
    
    float u = uInTex.read(gid).r;
    float v = vInTex.read(gid).r;
    float den = densityTex.read(gid).r;
    v += -sim.buoyancy * den * sim.dt * 50.0;
    
    uOutTex.write(float4(u, 0, 0, 1), gid);
    vOutTex.write(float4(v, 0, 0, 1), gid);
}

// 9. Vertex-Based Streamlines
struct StreamlineOut {
    float4 position [[position]];
    float4 color;
};

// Phase 74: Refined Streamline Graphics (High Parity)
vertex StreamlineOut gas_streamline_vertex(uint vid [[vertex_id]],
                                           texture2d<float, access::sample> uTex [[texture(0)]],
                                           texture2d<float, access::sample> vTex [[texture(1)]],
                                           texture2d<float, access::read> obstacleTex [[texture(2)]],
                                           constant uint2 &gridRes [[buffer(0)]],
                                           constant RenderUniforms &uniforms [[buffer(1)]])
{
    uint verticesPerStream = 128;
    uint streamlineID = vid / verticesPerStream;
    uint vertexInStreamline = vid % verticesPerStream;
    uint segmentIndex = (vertexInStreamline + 1) / 2;
    
    uint numSeedsX = gridRes.x / 4;
    uint seedX = (streamlineID % numSeedsX) * 4 + 1;
    uint seedY = (streamlineID / numSeedsX) * 4 + 1;
    
    float2 pos = float2(seedX, seedY);
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 size = float2(gridRes);
    
    float step = 1.0; 
    bool isDead = false;
    
    if (obstacleTex.read(uint2(pos)).r < 0.1) isDead = true;

    for (uint i = 0; i < segmentIndex; i++) {
        if (isDead) break;
        if (obstacleTex.read(uint2(pos), 0).r < 0.1) {
            isDead = true;
            break;
        }
        
        float2 uv = (pos + 0.5) / size;
        float2 vel = float2(uTex.sample(s, uv).r, vTex.sample(s, uv).r);
        float mag = length(vel);
        
        if (mag > 0.001) {
            float2 dir = vel / mag;
            float2 posMid = pos + dir * (step * 0.5);
            float2 uvMid = (posMid + 0.5) / size;
            float2 velMid = float2(uTex.sample(s, uvMid).r, vTex.sample(s, uvMid).r);
            float magMid = length(velMid);
            
            if (magMid > 0.001) {
                pos += (velMid / magMid) * step;
            } else {
                pos += dir * step;
            }
        } else {
             pos.x += step; 
        }
    }

    StreamlineOut out;
    float2 ndc = (pos / size) * 2.0 - 1.0;
    
    if (uniforms.flags & FLAG_VERTICAL) {
        float2 finalNDC;
        finalNDC.x = (pos.y / size.y) * 2.0 - 1.0;
        finalNDC.y = (pos.x / size.x) * 2.0 - 1.0; 
        out.position = float4(finalNDC.x, finalNDC.y, 0, 1);
    } else {
        out.position = float4(ndc.x, -ndc.y, 0, 1);
    }
    
    float fade = 1.0 - (float(vertexInStreamline) / float(verticesPerStream));
    out.color = float4(0.1, 0.1, 0.1, isDead ? 0.0 : fade * 0.6); 
    
    return out;
}

fragment float4 gas_streamline_fragment(StreamlineOut in [[stage_in]]) {
    return in.color;
}
