#include <metal_stdlib>
using namespace metal;

struct ClothParticle {
    float3 position;
    float3 prevPosition;
    float3 velocity;
    float normalX;
    float normalY;
    float normalZ;
    float invMass; // 0.0 if pinned
};

struct DistanceConstraint {
    uint indexA;
    uint indexB;
    float restLength;
};

struct ClothUniforms {
    float dt;
    int substepIndex;
    uint numParticles;
    uint numSubsteps;
    
    float compliance;
    int showWireframe;
    float _pad1;
    float _pad2;

    float4 gravity;
    float4 ambientColor;
    float4 light1Pos;    // Spotlight position
    float4 light1Color;
    float4 light1Target; // Spotlight target (to derive direction)
    float4 light1Params; // x: cos(outerAngle), y: cos(innerAngle)
    float4 light2Dir;    // Directional light dir
    float4 light2Color;
    
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4x4 shadowMatrix;
    float4 clothColor;
};

// ------------------------------------------------------------------
// ATOMIC HELPERS
// ------------------------------------------------------------------

inline void atomic_add_float(device float* addr, float value) {
    device atomic_uint* atomic_addr = (device atomic_uint*)addr;
    uint expected = atomic_load_explicit(atomic_addr, memory_order_relaxed);
    uint desired;
    do {
        desired = as_type<uint>(as_type<float>(expected) + value);
    } while (!atomic_compare_exchange_weak_explicit(atomic_addr, &expected, desired, memory_order_relaxed, memory_order_relaxed));
}

inline void atomic_add_float3(device float3* vec, float3 value) {
    device float* addr = (device float*)vec;
    atomic_add_float(addr + 0, value.x);
    atomic_add_float(addr + 1, value.y);
    atomic_add_float(addr + 2, value.z);
}

// ------------------------------------------------------------------
// COMPUTE KERNELS
// ------------------------------------------------------------------

kernel void integrateCloth(
    device ClothParticle* particles [[buffer(0)]],
    constant ClothUniforms& uniforms [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.numParticles) return;
    
    if (particles[id].invMass == 0.0) {
        return;
    }
    
    float dt = uniforms.dt / float(uniforms.numSubsteps); 
    
    particles[id].velocity *= 0.99;
    
    if (uniforms.substepIndex == 0) {
        particles[id].prevPosition = particles[id].position;
    }
    
    particles[id].velocity += uniforms.gravity.xyz * dt;
    particles[id].position += particles[id].velocity * dt;
    
    if (particles[id].position.y < 0.0) {
        particles[id].position.y = 0.0;
    }
}

kernel void solveDistanceConstraint(
    device ClothParticle* particles [[buffer(0)]],
    device DistanceConstraint* constraints [[buffer(1)]],
    constant ClothUniforms& uniforms [[buffer(2)]],
    constant uint& numConstraints [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= numConstraints) return;
    
    uint idxA = constraints[id].indexA;
    uint idxB = constraints[id].indexB;
    
    float3 p0 = particles[idxA].position;
    float3 p1 = particles[idxB].position;
    
    float w0 = particles[idxA].invMass;
    float w1 = particles[idxB].invMass;
    float w = w0 + w1;
    
    if (w == 0.0) return;
    
    float3 dir = p0 - p1;
    float len = length(dir);
    if (len == 0.0) return;
    
    dir /= len;
    float restLen = constraints[id].restLength;
    float C = len - restLen;
    
    float dt = uniforms.dt / float(uniforms.numSubsteps);
    float alpha = uniforms.compliance / (dt * dt);
    
    float lambda = -C / (w + alpha);
    // Relaxation factor to prevent overcorrection in parallel solver
    float3 corr = dir * lambda * 0.5;
    
    if (w0 > 0) {
        atomic_add_float3(&(particles[idxA].position), corr * w0);
    }
    if (w1 > 0) {
        atomic_add_float3(&(particles[idxB].position), -corr * w1);
    }
}

kernel void updateClothVelocities(
    device ClothParticle* particles [[buffer(0)]],
    constant ClothUniforms& uniforms [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.numParticles) return;
    
    if (particles[id].invMass == 0.0) {
        particles[id].velocity = float3(0,0,0);
        return;
    }
    
    float dt = uniforms.dt;
    if (dt <= 0.0) return;
    
    float3 newVel = (particles[id].position - particles[id].prevPosition) / dt;
    float maxVel = 20.0;
    float velLen = length(newVel);
    if (velLen > maxVel) {
        newVel = (newVel / velLen) * maxVel;
    }
    particles[id].velocity = newVel; 
    particles[id].velocity *= 0.99; 
}

// Normal Calculation
struct TriangleIndices {
    uint i0, i1, i2;
};

kernel void clearNormals(
    device ClothParticle* particles [[buffer(0)]],
    constant ClothUniforms& uniforms [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.numParticles) return;
    particles[id].normalX = 0.0;
    particles[id].normalY = 0.0;
    particles[id].normalZ = 0.0;
}

kernel void computeFaceNormals(
    device ClothParticle* particles [[buffer(0)]],
    device TriangleIndices* indices [[buffer(1)]],
    constant uint& numTriangles [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= numTriangles) return;
    
    TriangleIndices tri = indices[id];
    float3 p0 = particles[tri.i0].position;
    float3 p1 = particles[tri.i1].position;
    float3 p2 = particles[tri.i2].position;
    
    float3 v0 = p1 - p0;
    float3 v1 = p2 - p0;
    float3 faceNormal = cross(v0, v1);
    
    atomic_add_float(&(particles[tri.i0].normalX), faceNormal.x);
    atomic_add_float(&(particles[tri.i0].normalY), faceNormal.y);
    atomic_add_float(&(particles[tri.i0].normalZ), faceNormal.z);
    
    atomic_add_float(&(particles[tri.i1].normalX), faceNormal.x);
    atomic_add_float(&(particles[tri.i1].normalY), faceNormal.y);
    atomic_add_float(&(particles[tri.i1].normalZ), faceNormal.z);
    
    atomic_add_float(&(particles[tri.i2].normalX), faceNormal.x);
    atomic_add_float(&(particles[tri.i2].normalY), faceNormal.y);
    atomic_add_float(&(particles[tri.i2].normalZ), faceNormal.z);
}

kernel void normalizeNormals(
    device ClothParticle* particles [[buffer(0)]],
    constant ClothUniforms& uniforms [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.numParticles) return;
    float3 n = float3(particles[id].normalX, particles[id].normalY, particles[id].normalZ);
    if (length_squared(n) > 0.0) {
        n = normalize(n);
    } else {
        n = float3(0, 1, 0);
    }
    particles[id].normalX = n.x;
    particles[id].normalY = n.y;
    particles[id].normalZ = n.z;
}

kernel void computeGridNormals(
    device ClothParticle* particles [[buffer(0)]],
    constant uint2& gridSize [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    // Deprecated
}

// ------------------------------------------------------------------
// RENDER SHADERS
// ------------------------------------------------------------------

struct VertexOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
    float2 uv;
    float4 shadowPos;
};

vertex VertexOut clothVertex(
    uint vertexID [[vertex_id]],
    const device ClothParticle* particles [[buffer(0)]],
    constant ClothUniforms& uniforms [[buffer(1)]],
    constant uint2& gridSize [[buffer(2)]]
) {
    VertexOut out;
    ClothParticle p = particles[vertexID];
    
    float4 pos = float4(p.position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * pos;
    out.worldPos = p.position;
    out.normal = float3(p.normalX, p.normalY, p.normalZ);
    out.shadowPos = uniforms.shadowMatrix * pos;
    
    uint w = gridSize.x;
    uint h = gridSize.y;
    float u = float(vertexID % w) / float(w - 1);
    float v = float(vertexID / w) / float(h - 1);
    out.uv = float2(u, v);
    
    return out;
}

fragment float4 clothFragment(
    VertexOut in [[stage_in]],
    constant ClothUniforms& uniforms [[buffer(0)]],
    depth2d<float> shadowMap [[texture(0)]])
{
    if (uniforms.showWireframe == 1) {
        return uniforms.clothColor;
    }

    float3 shadowCoord = in.shadowPos.xyz / in.shadowPos.w;
    float2 shadowTexCoord = shadowCoord.xy * 0.5 + 0.5;
    shadowTexCoord.y = 1.0 - shadowTexCoord.y;
    
    constexpr sampler shadowSampler(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less);
    float shadow = shadowMap.sample_compare(shadowSampler, shadowTexCoord, shadowCoord.z - 0.005);

    float3 N = normalize(in.normal);
    float3 V = normalize(float3(0, 1, 1) - in.worldPos);
    if (dot(N, V) < 0.0) N = -N;

    float3 ambient = uniforms.ambientColor.rgb;
    
    // Light 1 (Spotlight-Key) 
    float3 L1 = normalize(uniforms.light1Pos.xyz - in.worldPos);
    float3 D1 = normalize(uniforms.light1Target.xyz - uniforms.light1Pos.xyz);
    float theta = dot(L1, -D1);
    float cosOuter = uniforms.light1Params.x;
    float cosInner = uniforms.light1Params.y;
    float intensity = clamp((theta - cosOuter) / (cosInner - cosOuter), 0.0, 1.0);
    
    float3 R1 = reflect(-L1, N);
    float diffuse1 = shadow * max(dot(N, L1), 0.0) * intensity;
    float specular1 = shadow * pow(max(dot(V, R1), 0.0), 30.0) * 0.4 * intensity;
    float3 light1Result = (diffuse1 * uniforms.clothColor.rgb + specular1) * uniforms.light1Color.rgb;

    // Light 2 (Directional-Fill)
    float3 L2 = normalize(uniforms.light2Dir.xyz);
    float3 R2 = reflect(-L2, N);
    float diffuse2 = max(dot(N, L2), 0.0);
    float specular2 = pow(max(dot(V, R2), 0.0), 30.0) * 0.2;
    float3 light2Result = (diffuse2 * uniforms.clothColor.rgb + specular2) * uniforms.light2Color.rgb;

    float3 finalColor = ambient * uniforms.clothColor.rgb + light1Result + light2Result;
    
    return float4(finalColor, 1.0);
}

struct FloorVertexIn {
    float3 position;
};

vertex float4 shadowVertex(
    uint vertexID [[vertex_id]],
    const device FloorVertexIn* vertices [[buffer(0)]],
    constant ClothUniforms& uniforms [[buffer(1)]])
{
    float4 worldPos = float4(vertices[vertexID].position, 1.0);
    return uniforms.shadowMatrix * worldPos;
}

vertex float4 shadowVertexParticle(
    uint vertexID [[vertex_id]],
    const device ClothParticle* particles [[buffer(0)]],
    constant ClothUniforms& uniforms [[buffer(1)]])
{
    float4 worldPos = float4(particles[vertexID].position, 1.0);
    return uniforms.shadowMatrix * worldPos;
}

struct FloorVertexOut {
    float4 position [[position]];
    float3 worldPos;
    float4 shadowPos;
};

vertex FloorVertexOut floorVertex(
    uint vertexID [[vertex_id]],
    const device FloorVertexIn* vertices [[buffer(0)]],
    constant ClothUniforms& uniforms [[buffer(1)]]
) {
    FloorVertexOut out;
    float3 pos = vertices[vertexID].position;
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * float4(pos, 1.0);
    out.worldPos = pos;
    out.shadowPos = uniforms.shadowMatrix * float4(pos, 1.0);
    return out;
}

fragment float4 floorFragment(
    FloorVertexOut in [[stage_in]],
    constant ClothUniforms& uniforms [[buffer(0)]],
    depth2d<float> shadowMap [[texture(0)]])
{
    float3 shadowCoord = in.shadowPos.xyz / in.shadowPos.w;
    float2 shadowTexCoord = shadowCoord.xy * 0.5 + 0.5;
    shadowTexCoord.y = 1.0 - shadowTexCoord.y;
    
    constexpr sampler shadowSampler(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less);
    float shadow = shadowMap.sample_compare(shadowSampler, shadowTexCoord, shadowCoord.z - 0.005);

    float3 baseColor = float3(0.627, 0.678, 0.686); 
    
    float gridSize = 1.0;
    float2 gridCoord = fract(in.worldPos.xz / gridSize);
    float lineWidth = 0.02;
    float grid = (gridCoord.x < lineWidth || gridCoord.x > 1.0 - lineWidth ||
                  gridCoord.y < lineWidth || gridCoord.y > 1.0 - lineWidth) ? 0.7 : 1.0;
    
    float3 ambient = uniforms.ambientColor.rgb;
    float lighting = ambient.r + 0.7 * shadow;
    
    return float4(baseColor * grid * lighting, 1.0);
}
