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
    float face;
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
    output.face = 1.0;
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

    // Rotate the sheet around its bound edge while varying the angle across
    // the page. The global turn keeps the dragged edge under the finger; the
    // local bend prevents the page from collapsing into a rigid rectangle.
    float edge = direction < 0.0 ? inputVertex.uv.x : 1.0 - inputVertex.uv.x;
    float turnAngle = 3.14159265 * progress;
    float localBend = 0.42
        * sin(3.14159265 * progress)
        * sin(3.14159265 * edge);
    float pageAngle = turnAngle + localBend;
    float face = cos(pageAngle);
    float fold = abs(sin(pageAngle));
    float fixedX = direction < 0.0 ? -1.0 : 1.0;
    float outward = -direction;
    float2 position = inputVertex.position;
    position.x = fixedX + outward * (2.0 * edge) * face;

    // The target remains at z=0.05. Curved paper rises above it, with a tiny
    // side bias to make the front/back boundary deterministic.
    output.position = float4(
        position,
        0.12 + fold * 0.68 + uniforms.side * 0.001,
        1.0
    );
    output.uv = inputVertex.uv;
    output.edge = edge;
    output.fold = fold;
    output.shade = 1.0 - fold * (uniforms.isDark > 0.5 ? 0.20 : 0.14);
    output.face = face;
    return output;
}

fragment float4 page_turn_curl_fragment(
    PageTurnRasterizerData input [[stage_in]],
    constant PageTurnUniforms &uniforms [[buffer(1)]],
    texture2d<float> currentTexture [[texture(0)]]) {
    constexpr sampler pageSampler(filter::linear, address::clamp_to_edge);
    if (!insideRoundedPage(input.uv, uniforms) || input.face < 0.0) {
        discard_fragment();
    }
    float4 color = currentTexture.sample(pageSampler, float2(input.uv.x, 1.0 - input.uv.y));
    float highlight = pow(input.fold, 7.0) * 0.15;
    float shadow = smoothstep(0.0, 1.0, input.edge) * input.fold * 0.12;
    color.rgb = color.rgb * max(0.0, input.shade - shadow);
    color.rgb += float3(highlight);
    color.a = 1.0;
    return color;
}

fragment float4 page_turn_curl_back_fragment(
    PageTurnRasterizerData input [[stage_in]],
    constant PageTurnUniforms &uniforms [[buffer(1)]],
    texture2d<float> currentTexture [[texture(0)]]) {
    constexpr sampler pageSampler(filter::linear, address::clamp_to_edge);
    if (!insideRoundedPage(input.uv, uniforms) || input.face >= 0.0) { discard_fragment(); }

    // The geometry itself reverses the page in screen space after it crosses
    // ninety degrees. Sampling the original UV avoids a second, incorrect
    // mirror and leaves just a restrained hint of ink on the paper back.
    float4 source = currentTexture.sample(pageSampler, float2(input.uv.x, 1.0 - input.uv.y));
    float3 paperTint = uniforms.isDark > 0.5
        ? float3(0.17, 0.18, 0.19)
        : float3(0.96, 0.95, 0.91);
    float paperGradient = mix(0.78, 0.96, input.edge);
    float3 color = mix(paperTint, source.rgb, 0.08) * paperGradient;
    float creaseShadow = 0.22 * pow(input.fold, 6.0);
    color *= 1.0 - creaseShadow;
    return float4(color, 1.0);
}
