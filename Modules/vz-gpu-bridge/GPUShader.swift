// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC

let gpuShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct DrawUniform { uint drawIndex; uint colorSeed; float offsetX; float offsetY; };
struct VertexOut { float4 position [[position]]; float4 color; };
vertex VertexOut vs_main(uint vid [[vertex_id]], uint iid [[instance_id]],
                         constant DrawUniform *uniforms [[buffer(0)]]) {
    DrawUniform u = uniforms[iid];
    float2 vertices[3] = { float2(-0.03, -0.03), float2(0.03, -0.03), float2(0.00, 0.03) };
    VertexOut output;
    output.position = float4(vertices[vid] + float2(u.offsetX, u.offsetY), 0.0, 1.0);
    float3 color = fract(float3(u.drawIndex * 37u, u.drawIndex * 73u, u.drawIndex * 113u)
                         * 0.00390625 + float(u.colorSeed % 256u) * 0.00390625);
    output.color = float4(color, 1.0);
    return output;
}
fragment float4 fs_main(VertexOut input [[stage_in]]) { return input.color; }
struct PresentOut { float4 position [[position]]; float2 uv; };
vertex PresentOut present_vertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    PresentOut output;
    output.position = float4(positions[vid], 0.0, 1.0);
    output.uv = float2((positions[vid].x + 1.0) * 0.5, (1.0 - positions[vid].y) * 0.5);
    return output;
}
fragment float4 present_fragment(PresentOut input [[stage_in]], texture2d<float> image [[texture(0)]]) {
    constexpr sampler nearestSampler(coord::normalized, filter::nearest, address::clamp_to_edge);
    return image.sample(nearestSampler, input.uv);
}
"""
