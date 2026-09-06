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
    float padding;
};

struct PageTurnRasterizerData {
    float4 position [[position]];
    float2 uv;
    float shade;
};

vertex PageTurnRasterizerData page_turn_fullscreen_vertex(
    const device PageTurnVertex *vertices [[buffer(0)]],
    uint vertexID [[vertex_id]]
) {
    PageTurnRasterizerData output;
    output.position = float4(vertices[vertexID].position, 0.0, 1.0);
    output.uv = vertices[vertexID].uv;
    output.shade = 1.0;
    return output;
}

fragment float4 page_turn_target_fragment(
    PageTurnRasterizerData input [[stage_in]],
    texture2d<float> targetTexture [[texture(0)]]
) {
    constexpr sampler pageSampler(filter::linear, address::clamp_to_edge);
    return targetTexture.sample(pageSampler, float2(input.uv.x, 1.0 - input.uv.y));
}

vertex PageTurnRasterizerData page_turn_curl_vertex(
    const device PageTurnVertex *vertices [[buffer(0)]],
    constant PageTurnUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    PageTurnRasterizerData output;
    PageTurnVertex vertex = vertices[vertexID];
    float progress = clamp(uniforms.progress, 0.0, 1.0);
    float direction = uniforms.direction < 0.0 ? -1.0 : 1.0;

    // Move the outgoing sheet while adding a curved fold whose strength is
    // highest around the middle of the turn. This keeps the mesh stable and
    // makes the cost independent of the page's DOM complexity.
    float fold = sin(progress * 3.14159265);
    float edgeDistance = direction < 0.0
        ? (1.0 - vertex.uv.x)
        : vertex.uv.x;
    float curl = sin(edgeDistance * 3.14159265) * fold * 0.18;
    float2 position = vertex.position;
    position.x += direction * progress * 2.0;
    position.x += direction * curl;
    position.y *= 1.0 - curl * 0.035;

    output.position = float4(position, 0.0, 1.0);
    output.uv = vertex.uv;
    output.shade = 1.0 - curl * (uniforms.isDark > 0.5 ? 0.28 : 0.16);
    return output;
}

fragment float4 page_turn_curl_fragment(
    PageTurnRasterizerData input [[stage_in]],
    texture2d<float> currentTexture [[texture(0)]]
) {
    constexpr sampler pageSampler(filter::linear, address::clamp_to_edge);
    float4 color = currentTexture.sample(pageSampler, float2(input.uv.x, 1.0 - input.uv.y));
    color.rgb *= input.shade;
    return color;
}
