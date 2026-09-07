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
    // Keep the stable background behind both sides of the folded sheet when
    // using the greater-than depth state.
    output.position = float4(vertices[vertexID].position, 0.05, 1.0);
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
    float progress = clamp(uniforms.progress, 0.0, 1.0);
    float direction = uniforms.direction < 0.0 ? -1.0 : 1.0;

    // The fixed edge stays in place while the opposite edge folds over it.
    // `edge` is zero at the fixed edge and one at the edge being turned. The
    // old implementation translated the entire sheet, which made this mode
    // indistinguishable from cover. This is a cylindrical page turn: only
    // the band already crossed by the moving crease is bent.
    float edge = direction < 0.0 ? inputVertex.uv.x : 1.0 - inputVertex.uv.x;
    float foldStart = 1.0 - progress;
    float folded = progress > 0.0001
        ? clamp((edge - foldStart) / max(progress, 0.0001), 0.0, 1.0)
        : 0.0;
    float foldAngle = folded * 3.14159265;
    float fold = sin(foldAngle) * step(0.0001, progress);
    // cos(theta) is the signed depth of the cylindrical sheet. Keep the
    // visible front/back z ranges ordered while preserving the end points.
    float cylinderDepth = 0.5 + 0.5 * cos(foldAngle);
    float crease = exp(-pow((folded - 0.5) / 0.11, 2.0)) * fold;
    float2 position = inputVertex.position;
    if (folded > 0.0) {
        // A radius proportional to the crossed band gives a stable silhouette
        // at both the first and last frames without moving the live reader.
        float radius = max(0.62, 1.15 * progress);
        float creaseX = direction < 0.0
            ? 1.0 - 2.0 * progress
            : -1.0 + 2.0 * progress;
        position.x = creaseX + direction * radius * sin(foldAngle);
        position.y *= 1.0 - 0.075 * fold;
        position.y += (inputVertex.uv.y - 0.5) * crease * 0.055;
    }

    // Fixed/front paper sits above the target; the folded back receives a
    // larger z so projected overlap self-orders deterministically.
    output.position = float4(
        position,
        uniforms.side > 0.5 ? 0.55 + cylinderDepth * 0.35 : 0.15,
        1.0
    );
    output.uv = inputVertex.uv;
    output.edge = edge;
    output.fold = fold;
    output.shade = 1.0 - fold * (uniforms.isDark > 0.5 ? 0.22 : 0.16);
    return output;
}

fragment float4 page_turn_curl_fragment(
    PageTurnRasterizerData input [[stage_in]],
    constant PageTurnUniforms &uniforms [[buffer(1)]],
    texture2d<float> currentTexture [[texture(0)]]) {
    constexpr sampler pageSampler(filter::linear, address::clamp_to_edge);
    float progress = clamp(uniforms.progress, 0.0, 1.0);
    // The front face ends exactly at the moving crease. The target page is
    // already underneath, so leaving this band transparent exposes it while
    // the back-face pass paints the turned paper.
    if (!insideRoundedPage(input.uv, uniforms) || input.edge > 1.0 - progress) {
        discard_fragment();
    }
    float4 color = currentTexture.sample(pageSampler, float2(input.uv.x, 1.0 - input.uv.y));
    float highlight = exp(-pow((input.edge - (1.0 - progress * 0.5)) / 0.10, 2.0)) * input.fold;
    float shadow = smoothstep(0.0, 0.30, input.edge) * input.fold * 0.11;
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
    float turnProgress = clamp(uniforms.progress, 0.0, 1.0);
    float foldStart = 1.0 - turnProgress;
    if (input.edge <= foldStart || turnProgress < 0.012) { discard_fragment(); }

    float folded = clamp((input.edge - foldStart) / max(turnProgress, 0.0001), 0.0, 1.0);
    float2 mirroredUV = float2(1.0 - input.uv.x, input.uv.y);
    float4 source = currentTexture.sample(pageSampler, float2(mirroredUV.x, 1.0 - mirroredUV.y));
    float3 paperTint = uniforms.isDark > 0.5
        ? float3(0.17, 0.18, 0.19)
        : float3(0.96, 0.95, 0.91);
    // Keep the reverse side paper-like in both themes. A small amount of the
    // immutable source texture preserves the page's tone without exposing a
    // dark/bright opaque rectangle during the turn.
    float paperGradient = mix(0.74, 0.94, folded);
    float3 color = mix(paperTint, source.rgb, 0.10) * paperGradient;
    float creaseShadow = 0.24 * exp(-pow((folded - 0.5) / 0.10, 2.0));
    color *= 1.0 - creaseShadow;
    return float4(color, 1.0);
}
