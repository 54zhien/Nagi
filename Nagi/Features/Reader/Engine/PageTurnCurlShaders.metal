#include <metal_stdlib>

using namespace metal;

struct PageTurnVertex {
    float2 position;
    float2 uv;
};

struct PageTurnUniforms {
    float progress;
    float direction;
    float isDark;
    float side;
    float cornerRadius;
    float aspect;
    float pageDirection;
    float padding1;
};

struct PageTurnRasterizerData {
    float4 position [[position]];
    float2 uv;
    float edge;
    float fold;
    float shade;
};

inline bool insideRoundedPage(float2 uv, constant PageTurnUniforms &uniforms) {
    // Work in a coordinate system whose unit is the page height. This keeps
    // the radius proportional to the actual host geometry on every device.
    float2 point = (uv - 0.5) * float2(max(uniforms.aspect, 0.001), 1.0);
    float2 halfSize = float2(max(uniforms.aspect, 0.001) * 0.5, 0.5);
    float radius = clamp(uniforms.cornerRadius, 0.0, 0.5);
    float2 q = abs(point) - (halfSize - radius);
    float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    return distance <= 0.001;
}

vertex PageTurnRasterizerData page_turn_fullscreen_vertex(
    const device PageTurnVertex *vertices [[buffer(0)]],
    uint vertexID [[vertex_id]]) {
    PageTurnRasterizerData output;
    output.position = float4(vertices[vertexID].position, 0.0, 1.0);
    output.uv = vertices[vertexID].uv;
    output.edge = 0.0;
    output.fold = 0.0;
    output.shade = 1.0;
    return output;
}

fragment float4 page_turn_target_fragment(
    PageTurnRasterizerData input [[stage_in]],
    constant PageTurnUniforms &uniforms [[buffer(1)]],
    texture2d<float> targetTexture [[texture(0)]]) {
    constexpr sampler pageSampler(filter::linear, address::clamp_to_edge);
    if (!insideRoundedPage(input.uv, uniforms)) { discard_fragment(); }
    return targetTexture.sample(pageSampler, float2(input.uv.x, 1.0 - input.uv.y));
}

vertex PageTurnRasterizerData page_turn_curl_vertex(
    const device PageTurnVertex *vertices [[buffer(0)]],
    constant PageTurnUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]) {
    PageTurnRasterizerData output;
    PageTurnVertex inputVertex = vertices[vertexID];
    float rawProgress = clamp(uniforms.progress, 0.0, 1.0);
    float progress = uniforms.pageDirection < 0.5 ? rawProgress : 1.0 - rawProgress;
    float direction = uniforms.direction < 0.0 ? -1.0 : 1.0;

    // The leading edge travels off-screen while the sheet bows around a
    // vertical fold. The mesh is dense enough that the fold remains smooth at
    // 120Hz, but the per-frame work is only a vertex transform.
    float edge = direction < 0.0 ? inputVertex.uv.x : 1.0 - inputVertex.uv.x;
    float fold = sin(progress * 3.14159265);
    float curl = sin(edge * 3.14159265) * fold * 0.22;
    float crease = exp(-pow((edge - 0.52) / 0.12, 2.0)) * fold;
    float2 position = inputVertex.position;
    position.x += direction * progress * 2.0;
    position.x += direction * curl;
    position.y *= 1.0 - curl * 0.045;
    // Slight perspective compression at the turning edge makes the fold read
    // as a sheet rather than a uniformly translated rectangle.
    float logicalTurnSign = uniforms.pageDirection < 0.5 ? 1.0 : -1.0;
    position.y += (inputVertex.uv.y - 0.5) * crease * 0.035 * logicalTurnSign;

    output.position = float4(position, 0.0, 1.0);
    output.uv = inputVertex.uv;
    output.edge = edge;
    output.fold = fold;
    output.shade = 1.0 - curl * (uniforms.isDark > 0.5 ? 0.18 : 0.12);
    return output;
}

fragment float4 page_turn_curl_fragment(
    PageTurnRasterizerData input [[stage_in]],
    constant PageTurnUniforms &uniforms [[buffer(1)]],
    texture2d<float> currentTexture [[texture(0)]]) {
    constexpr sampler pageSampler(filter::linear, address::clamp_to_edge);
    if (!insideRoundedPage(input.uv, uniforms)) { discard_fragment(); }
    float4 color = currentTexture.sample(pageSampler, float2(input.uv.x, 1.0 - input.uv.y));
    float highlight = exp(-pow((input.edge - 0.52) / 0.12, 2.0)) * input.fold;
    float shadow = smoothstep(0.0, 0.30, input.edge) * input.fold * 0.08;
    color.rgb = color.rgb * max(0.0, input.shade - shadow);
    color.rgb += float3(0.16, 0.15, 0.13) * highlight;
    color.a = 1.0;
    return color;
}

fragment float4 page_turn_curl_back_fragment(
    PageTurnRasterizerData input [[stage_in]],
    constant PageTurnUniforms &uniforms [[buffer(1)]],
    texture2d<float> currentTexture [[texture(0)]]) {
    constexpr sampler pageSampler(filter::linear, address::clamp_to_edge);
    if (!insideRoundedPage(input.uv, uniforms)) { discard_fragment(); }

    // Only the part that has rolled over is the back of the sheet. Mirroring
    // the source gives the expected reversed text, while a small alpha and
    // paper tint keep the content readable in both themes.
    float turnProgress = uniforms.pageDirection < 0.5
        ? clamp(uniforms.progress, 0.0, 1.0)
        : 1.0 - clamp(uniforms.progress, 0.0, 1.0);
    float foldWidth = mix(0.045, 0.78, turnProgress);
    if (input.edge > foldWidth || turnProgress < 0.012) { discard_fragment(); }
    float2 mirroredUV = float2(1.0 - input.uv.x, input.uv.y);
    float4 color = currentTexture.sample(pageSampler, float2(mirroredUV.x, 1.0 - mirroredUV.y));
    float3 paperTint = uniforms.isDark > 0.5
        ? float3(0.10, 0.10, 0.11)
        : float3(0.96, 0.95, 0.92);
    color.rgb = mix(color.rgb, paperTint, 0.16);
    float creaseShadow = 0.18 * exp(-pow((input.edge - foldWidth) / 0.08, 2.0));
    color.rgb *= 1.0 - creaseShadow;
    color.a = 0.94;
    return color;
}
