//
//  PageCurlShaders.metal
//
//  Vertex-side paper deformation for the reader's interactive page curl.
//
//  The mesh is static: every frame only changes the uniforms below, and the
//  curvature is evaluated per vertex on the GPU. Nothing here samples the
//  page images except the fragment stage, which reads the two textures the
//  host already uploaded before the gesture started.
//

#include <metal_stdlib>
using namespace metal;

/// Must stay layout-compatible with `PageCurlUniforms` in PageCurlRenderer.swift.
/// Field order and types are shared by both sides; do not reorder one alone.
struct PageCurlUniforms {
    /// Gesture progress, 0 (page flat) to 1 (page fully turned).
    float progress;
    /// +1 when the moving edge is the right one, -1 when it is the left one.
    /// The reader folds in reading-direction order, so RTL publications simply
    /// arrive with the opposite sign instead of a mirrored image pair.
    float foldSign;
    /// Page width / height, so the bend keeps a circular cross-section instead
    /// of stretching with the page shape.
    float aspect;
    /// Bend radius in page-width units.
    float curlRadius;
    /// Strength of the shadow the turning sheet casts on the page beneath.
    float shadowStrength;
    /// Strength of the specular sheen along the bend.
    float highlightStrength;
    /// How far the back face is tinted toward the paper colour.
    float paperTint;
    /// 1 for dark appearance. Dark pages get less sheen and a tighter edge.
    float isDark;
};

struct PageCurlVertex {
    /// Normalized page space, always left to right: x runs 0 at the left edge
    /// to 1 at the right, y runs 0 at the top to 1 at the bottom. The vertex
    /// stage converts this to the moving-edge-relative space `curlDeform`
    /// works in; see the comment there.
    float2 position;
    float2 uv;
};

struct PageCurlVertexOut {
    float4 position [[position]];
    float2 uv;
    float3 normal;
    /// Height above the page plane, used for the projected shadow falloff.
    float height;
};

/// Operates in **moving-edge space**, not page space: x is the distance from
/// the edge that lifts, 0 at that edge and 1 at the spine. Callers must convert
/// into this space with `foldSign` before calling and back out afterwards.
/// Naming the parameter for the space it is actually in is deliberate — the
/// earlier name `pagePos` is what made the missing entry conversion easy to
/// overlook.
///
/// Fine to replace wholesale when the conical model lands. Everything else in
/// this file is written against this signature, not against its internals.
static inline void curlDeform(
    float2 canonicalPos,
    constant PageCurlUniforms &u,
    thread float2 &outPagePos,
    thread float &outHeight,
    thread float3 &outNormal
) {
    // Taper the bend to zero at both ends of the gesture. Without it the sheet
    // would still be a tube at progress 1 instead of settling flat.
    float phase = clamp(u.progress, 0.0, 1.0);
    float radius = max(u.curlRadius * sin(M_PI_F * phase), 1e-4);
    float bendArc = M_PI_F * radius;

    // How far the bend has travelled from the moving edge toward the spine.
    // The taper already collapses the bend at both ends of the gesture, so the
    // fold position is just the progress: at 1 every vertex has passed the bend
    // and the sheet has flipped.
    float travelled = phase;

    // Positive once this material has reached the bend.
    float entered = travelled - canonicalPos.x;

    if (entered <= 0.0) {
        // Untouched: still lying flat.
        outPagePos = canonicalPos;
        outHeight = 0.0;
        outNormal = float3(0.0, 0.0, 1.0);
        return;
    }

    if (entered <= bendArc) {
        // Wrapped over the cylinder. `a` sweeps 0 -> PI across the bend, so the
        // strip enters and leaves the bend at the same lateral position after
        // folding back on itself.
        float a = entered / radius;
        outPagePos.x = travelled - radius * sin(a);
        outHeight = radius * (1.0 - cos(a));
        // Perpendicular to the tangent (-cos a, sin a) and continuous with both
        // neighbours: (0, 0, 1) as a -> 0 where the bend meets the flat sheet,
        // and (0, 0, -1) at a -> PI where it meets the turned part.
        outNormal = float3(sin(a), 0.0, cos(a));
        return;
    }

    // Past the bend: the sheet has turned over and now lies on the far side,
    // displaced by however much material ran through the bend.
    float excess = entered - bendArc;
    outPagePos.x = travelled + excess;
    outHeight = 2.0 * radius;
    outNormal = float3(0.0, 0.0, -1.0);
}

vertex PageCurlVertexOut pageCurlVertex(
    uint vertexID [[vertex_id]],
    const device PageCurlVertex *mesh [[buffer(0)]],
    constant PageCurlUniforms &uniforms [[buffer(1)]]
) {
    PageCurlVertex in = mesh[vertexID];

    // `curlDeform` measures x as the distance from the moving edge, but the
    // mesh always runs left to right. Convert into that space before deforming
    // and back out afterwards. Doing only the exit conversion — as an earlier
    // version did — leaves the page mirrored even at progress 0.
    float canonicalX = uniforms.foldSign > 0.0 ? 1.0 - in.position.x : in.position.x;

    float2 curled;
    float height;
    float3 normal;
    curlDeform(float2(canonicalX, in.position.y), uniforms, curled, height, normal);

    // Back to page space. Fold direction picks which physical edge is the
    // moving one; this is what replaces the old image-mirroring step.
    float pageX = uniforms.foldSign > 0.0 ? 1.0 - curled.x : curled.x;
    float2 page = float2(pageX, in.position.y);

    // Page space (0..1) -> centred clip space (-1..1). Y is flipped because
    // page space grows downward and clip space grows upward.
    float2 clip = float2(page.x * 2.0 - 1.0, 1.0 - page.y * 2.0);

    // Lift the curled material toward the viewer: the page plane sits at the
    // far depth, so the bend occludes the flat part of the same sheet where
    // they overlap. The band is deliberately narrow to stay well inside the
    // depth buffer's precision.
    float depth = 1.0 - clamp(height / max(uniforms.aspect, 1e-3), 0.0, 0.35);

    PageCurlVertexOut out;
    out.position = float4(clip.x, clip.y, depth, 1.0);
    out.uv = in.uv;
    out.normal = normal;
    out.height = height;
    return out;
}

fragment float4 pageCurlFragment(
    PageCurlVertexOut in [[stage_in]],
    constant PageCurlUniforms &uniforms [[buffer(1)]],
    texture2d<float> currentTexture [[texture(0)]],
    sampler pageSampler [[sampler(0)]],
    bool frontFacing [[front_facing]]
) {
    float4 paper = currentTexture.sample(pageSampler, in.uv);

    // The back of the turning sheet shows the same page mirrored, dimmed and
    // pulled toward the paper colour, which is how a real sheet reads when it
    // catches the light at a shallow angle.
    //
    // `front_facing` is the sole discriminator. The mesh winds counter-clockwise
    // and the renderer declares that winding, so the rasteriser's answer is
    // authoritative — including across the bend, where the surface turns away
    // from the viewer and the winding flips on its own.
    if (!frontFacing) {
        float2 mirrored = float2(1.0 - in.uv.x, in.uv.y);
        float4 back = currentTexture.sample(pageSampler, mirrored);
        float luma = dot(back.rgb, float3(0.299, 0.587, 0.114));
        float3 flattened = mix(back.rgb, float3(luma), 0.45);
        float3 tinted = mix(flattened, paper.rgb * 0.35 + 0.5, uniforms.paperTint);
        back.rgb = tinted * (uniforms.isDark > 0.5 ? 0.62 : 0.82);
        return back;
    }

    // Sheen only along the steepest part of the bend, and kept low on purpose.
    float bendAmount = 1.0 - abs(in.normal.z);
    float sheen = pow(saturate(bendAmount), 3.0) * uniforms.highlightStrength;
    float3 lit = paper.rgb + sheen * (uniforms.isDark > 0.5 ? 0.35 : 0.60);

    // Darken where the sheet leans away, so the curl reads as a solid form.
    float facing = saturate(in.normal.z);
    lit *= mix(0.82, 1.0, facing);

    return float4(saturate(lit), paper.a);
}

// MARK: - Full-screen passes

struct PageCurlQuadOut {
    float4 position [[position]];
    float2 uv;
};

/// One oversized triangle covering the viewport, used for the page beneath and
/// for its shadow. Cheaper than a two-triangle quad and needs no vertex buffer.
vertex PageCurlQuadOut pageCurlFullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 corner = float2((vertexID << 1) & 2, vertexID & 2);
    float2 uv = corner * 0.5;

    PageCurlQuadOut out;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 1.0, 1.0);
    out.uv = uv;
    return out;
}

fragment float4 pageCurlTargetFragment(
    PageCurlQuadOut in [[stage_in]],
    texture2d<float> targetTexture [[texture(0)]],
    sampler pageSampler [[sampler(0)]]
) {
    return targetTexture.sample(pageSampler, in.uv);
}

/// The turning sheet's shadow, drawn over the page beneath but under the mesh.
/// Analytic rather than blurred: no extra pass, which matters at 120 Hz.
fragment float4 pageCurlShadowFragment(
    PageCurlQuadOut in [[stage_in]],
    constant PageCurlUniforms &uniforms [[buffer(1)]]
) {
    float phase = clamp(uniforms.progress, 0.0, 1.0);
    if (phase <= 0.0 || phase >= 1.0 || uniforms.shadowStrength <= 0.0) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    // The shadow creeps in from the moving edge and widens with the lift. It
    // has to follow the same edge the sheet folds on, so mirror its coordinate
    // exactly the way the vertex stage mirrors the page.
    float edgeU = uniforms.foldSign > 0.0 ? 1.0 - in.uv.x : in.uv.x;
    float reach = phase * 0.55;
    float edge = 1.0 - (edgeU / max(reach, 1e-3));
    float falloff = smoothstep(0.0, 1.0, saturate(edge));

    // Fade out as the sheet settles, so the shadow never outlives the curl.
    float life = sin(M_PI_F * phase);
    float alpha = falloff * life * uniforms.shadowStrength;

    return float4(0.0, 0.0, 0.0, alpha);
}
