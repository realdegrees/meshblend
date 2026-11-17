Shader "Hidden/MeshBlend"
{
    // Softens the seam where one surface meets another by fading both sides into the same mix of the two.
    //
    // Pass 4 (Ground Ids) marks, for one ground group, every pixel where that group is what the camera sees. Pass 6
    //   (Id) is the override every other taking-part renderer is drawn with: a hash of its object's position in the
    //   high half, its size and surface group below, kept only where it is the visible surface.
    // Pass 0 seeds: a taking-part pixel next to a pixel of another id whose group it blends with stores that neighbour,
    //   the angle
    //   between the two surfaces there and how well the two touch, when they touch in the world (a contact running
    //   along the boundary, not an edge seen over something behind it).
    // Pass 1 floods, once per halving step: every taking-part pixel keeps the stored neighbour nearest along its own
    //   surface whose id is not its own, so it ends up holding the nearest pixel across its nearest seam.
    // Pass 5 copies the frame at half size, twice, with every surface that does not take part weighted out: once
    //   with the higher priorities outweighing the lower, once the other way round, so a blur of either near a seam
    //   is one side's colour.
    // Pass 2 blends. In its first pixels beside a seam a surface fades into the other one's own pixels, mirrored
    //   across the seam on screen, so the two show the same pixels where they meet. Further out it keeps its own
    //   detail and lighting and only shifts toward the other side's colour. Between equals each side goes halfway;
    //   where one group outranks the other, the lower side goes all the way and the higher side keeps its colour.
    // Pass 3 runs before the opaques and holds the SSAO texture inside the band at the level of the band's outer edge.
    //
    // Everything that decides the band's shape is measured in the world: the angle, the distance to the contact and the
    // raggedness. Only finding the seam happens on screen, so the band stays put on the surfaces as the camera moves.
    //
    // Uniforms are shader globals set by MeshBlendRendererFeature through the command buffer.

    SubShader
    {
        Tags { "RenderPipeline" = "UniversalPipeline" }

        Cull Off
        ZTest Always
        ZWrite Off

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

        Texture2D<uint> _MeshBlendIds;
        Texture2D<float> _MeshBlendDepth;
        Texture2D<float> _MeshBlendGroundDepth;
        Texture2D<float4> _MeshBlendNormals;
        Texture2D<uint4> _MeshBlendSeams;
        Texture2D<float4> _MeshBlendColor;
        // The colours of the surfaces taking part at half size, with levels of detail: each pixel's colour times a
        // weight and the weight in alpha, nothing for everything else. In the first every step of priority weighs 256
        // times the one below, so about a seam it is the higher side's colour; the second is the other way round, the
        // lower side's. Between surfaces of one priority both are the even mix.
        Texture2D<float4> _MeshBlendMasked;
        Texture2D<float4> _MeshBlendMaskedLow;
        Texture2D<float4> _MeshBlendOcclusionSource;

        // x, y: target size in pixels; z, w: their reciprocals.
        float4 _MeshBlendSize;
        float4x4 _MeshBlendInvViewProj;
        float4x4 _MeshBlendViewProj;
        // x: radius where the surfaces meet at a right angle; y: where they meet flat (metres); z: pixels per metre at
        // one metre's depth; w: widest band in pixels.
        float4 _MeshBlendBand;
        // x: intensity; y: noise; z: one over the noise size (per metre); w: distance at which the blend has faded out.
        float4 _MeshBlendShape;
        // x: how fast the flat radius falls off toward a right angle; y: how much occlusion stays near a contact; z:
        // how far from a contact the occlusion is flattened (metres); w: how much of a sharp seam's line shows through.
        float4 _MeshBlendExtra;
        float4 _MeshBlendOcclusionSize;
        // Per surface group, by index (a surface's group is its index plus one; 0 is none). x and y: the low and high
        // halves of its rendering layer mask; z: its share of the band; w: its priority.
        float4 _MeshBlendGroups[8];
        // x: the groups it blends with, one bit per index; y: 1 for a ground group; z and w: its weight in the first
        // and the second masked copy.
        float4 _MeshBlendGroupLinks[8];
        int _MeshBlendGroupCount;
        // The ground group a Ground Ids pass marks, plus one.
        int _MeshBlendGroundGroup;
        int _MeshBlendStep;
        // 1: ids; 2: blend weight.
        int _MeshBlendDebug;

        #define NO_GROUP 0u
        #define NO_SEAM 0xFFFFu
        // The narrowest a band gets on screen, in pixels.
        #define MIN_BAND_PIXELS 5.0
        // A seam's w packs the angle between the surfaces (bits 2 to 9) and how well the two pixels touch (bits 10 to
        // 15). Bit 0 is the pixel's own, whatever seam it holds: set where it is its surface's last pixel before
        // another taking-part surface.
        #define EDGE_PIXEL 1u
        #define ANGLE_STEPS 255.0
        #define TOUCH_STEPS 63.0
        float SeamAngle(uint w) { return ((w >> 2) & 0xFFu) / ANGLE_STEPS; }
        float SeamTouch(uint w) { return ((w >> 10) & 0x3Fu) / TOUCH_STEPS; }
        // Whether a pixel is its surface's last before another one. With multisampling such a pixel's colour is part
        // the other surface's.
        bool IsEdgePixel(uint4 seam) { return (seam.w & EDGE_PIXEL) != 0u; }
        #define SIZE_STEPS 0x1FFFu
        #define SIZE_LOG_MIN -8.0
        #define SIZE_LOG_RANGE 18.0

        // Straight neighbours first: a seam pixel prefers the nearer of its candidates.
        static const int2 Neighbours[8] =
        {
            int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1),
            int2(-1, -1), int2(-1, 1), int2(1, -1), int2(1, 1),
        };

        struct Attributes
        {
            uint vertexID : SV_VertexID;
        };

        struct Varyings
        {
            float4 positionCS : SV_POSITION;
        };

        Varyings Vert(Attributes input)
        {
            Varyings output;
            output.positionCS = GetFullScreenTriangleVertexPosition(input.vertexID);
            return output;
        }

        bool Inside(int2 p)
        {
            return all(p >= 0) && all(p < int2(_MeshBlendSize.xy));
        }

        int2 ClampPixel(int2 p)
        {
            return clamp(p, 0, int2(_MeshBlendSize.xy) - 1);
        }

        // A pixel's surface: the object id in the high half, its class in the low two bits, 0 for nothing.
        uint SurfaceAt(int2 p)
        {
            return _MeshBlendIds.Load(int3(p, 0));
        }

        uint IdOf(uint surface)
        {
            return surface >> 16;
        }

        // A surface packs its object's id (bits 16 to 31), its size (bits 3 to 15, see EncodeSize) and its group plus one
        // (bits 0 to 2). Each ground group is one surface with an id of its own counted down from 0xFFFF.
        uint GroupOf(uint surface)
        {
            return surface & 7u;
        }

        float4 GroupData(uint group)
        {
            return _MeshBlendGroups[max(group, 1u) - 1u];
        }

        bool IsGround(uint group)
        {
            return group != NO_GROUP && _MeshBlendGroupLinks[group - 1u].y > 0.5;
        }

        // Whether two groups blend where they meet.
        bool Blends(uint a, uint b)
        {
            if (a == NO_GROUP || b == NO_GROUP) return false;
            return ((uint(_MeshBlendGroupLinks[a - 1u].x) >> (b - 1u)) & 1u) != 0u;
        }

        // An object's size in metres, from bits 3 to 15 of its surface (see EncodeSize). The ground has no size.
        float SizeOf(uint surface)
        {
            if (IsGround(GroupOf(surface))) return 1e6;
            return exp2(((surface >> 3) & SIZE_STEPS) / (float)SIZE_STEPS * SIZE_LOG_RANGE + SIZE_LOG_MIN);
        }

        // The band in metres where two surfaces touch, at the angle between them, 0 meeting flat and 1 at a right angle
        // or steeper: the smaller of the two groups' shares of it, and never so wide that the whole band, both sides at
        // their raggedest, spans more than a fifth of the smaller object, so a stone not much taller than the band does
        // not melt into the ground whole.
        float BandRadius(uint a, uint b, float angle)
        {
            // The flat radius holds only near flat: its share falls off as a power of how flat the contact is, so a
            // contact at 45 degrees is already close to the right-angle radius.
            float radius = lerp(_MeshBlendBand.x, _MeshBlendBand.y, pow(saturate(1.0 - angle), _MeshBlendExtra.x));
            radius *= min(GroupData(GroupOf(a)).z, GroupData(GroupOf(b)).z);
            return min(radius, 0.1 * min(SizeOf(a), SizeOf(b)) / (1.0 + _MeshBlendShape.y));
        }

        float RawDepthAt(int2 p)
        {
            return _MeshBlendDepth.Load(int3(p, 0));
        }

        float3 WorldAt(int2 p, float rawDepth)
        {
            float2 uv = (float2(p) + 0.5) * _MeshBlendSize.zw;
            return ComputeWorldSpacePosition(uv, rawDepth, _MeshBlendInvViewProj);
        }

        float3 WorldAt(int2 p)
        {
            return WorldAt(p, RawDepthAt(p));
        }

        // The pixel a world point lands on, the inverse of WorldAt.
        float2 PixelOf(float3 positionWS)
        {
            float4 clip = mul(_MeshBlendViewProj, float4(positionWS, 1.0));
            float2 ndc = clip.xy / clip.w;
            #if UNITY_UV_STARTS_AT_TOP
                ndc.y = -ndc.y;
            #endif
            return (ndc * 0.5 + 0.5) * _MeshBlendSize.xy - 0.5;
        }

        float3 NormalAt(int2 p)
        {
            return normalize(_MeshBlendNormals.Load(int3(p, 0)).xyz);
        }

        float EyeDepth(float rawDepth)
        {
            return LinearEyeDepth(rawDepth, _ZBufferParams);
        }

        // Pixels between samples for a patch spanning about half the widest band two classes can have, so what is measured
        // around a seam is the shape at the band's own scale: a groove or a bevel much smaller than the band does not
        // turn it, however close the camera comes.
        float PatchStride(int2 p, uint a, uint b)
        {
            float widest = max(BandRadius(a, b, 0.0), BandRadius(a, b, 1.0));
            return clamp(0.25 * widest * _MeshBlendBand.z / EyeDepth(RawDepthAt(p)), 1.0, 32.0);
        }

        // Both surfaces' normals around a seam pixel, each averaged over its own pixels in a 5x5 patch, so the angle at a
        // seam depends on the seam pixel alone and not on which neighbour found it.
        void SeamNormals(int2 centre, int stride, uint ownId, uint otherId, out float3 own, out float3 other)
        {
            float3 ownSum = 0.0;
            float3 otherSum = 0.0;
            [unroll]
            for (int y = -2; y <= 2; y++)
            [unroll]
            for (int x = -2; x <= 2; x++)
            {
                int2 q = ClampPixel(centre + int2(x, y) * stride);
                uint id = IdOf(SurfaceAt(q));
                float3 n = NormalAt(q);
                if (id == ownId) ownSum += n;
                else if (id == otherId) otherSum += n;
            }
            other = dot(otherSum, otherSum) > 1e-8 ? normalize(otherSum) : NormalAt(centre);
            own = dot(ownSum, ownSum) > 1e-8 ? normalize(ownSum) : other;
        }

        // SeamNormals at a stride between whole pixels: the two whole strides around it, blended by where it lies
        // between them. The stride follows the distance, and a whole-pixel stride that snapped from two to three as the
        // camera moved would change the measured angle, and with it the band's width, in a visible pop; far away, where
        // strides are a pixel or two, every snap is a third or a half of the patch.
        void SeamNormalsAt(int2 centre, float stride, uint ownId, uint otherId, out float3 own, out float3 other)
        {
            int lower = (int)floor(stride);
            float3 ownLow, otherLow, ownHigh, otherHigh;
            SeamNormals(centre, lower, ownId, otherId, ownLow, otherLow);
            SeamNormals(centre, min(lower + 1, 32), ownId, otherId, ownHigh, otherHigh);
            float f = stride - lower;
            own = normalize(lerp(ownLow, ownHigh, f) + 1e-6);
            other = normalize(lerp(otherLow, otherHigh, f) + 1e-6);
        }

        // 0 where two surfaces meet flat, 1 at a right angle or steeper.
        float AngleBetween(float3 a, float3 b)
        {
            return saturate(acos(clamp(dot(a, b), -1.0, 1.0)) / HALF_PI);
        }

        float Hash13(float3 p)
        {
            p = frac(p * 0.1031);
            p += dot(p, p.zyx + 31.32);
            return frac((p.x + p.y) * p.z);
        }

        float ValueNoise(float3 x)
        {
            float3 i = floor(x);
            float3 f = frac(x);
            f = f * f * (3.0 - 2.0 * f);
            float a = lerp(Hash13(i), Hash13(i + float3(1, 0, 0)), f.x);
            float b = lerp(Hash13(i + float3(0, 1, 0)), Hash13(i + float3(1, 1, 0)), f.x);
            float c = lerp(Hash13(i + float3(0, 0, 1)), Hash13(i + float3(1, 0, 1)), f.x);
            float d = lerp(Hash13(i + float3(0, 1, 1)), Hash13(i + float3(1, 1, 1)), f.x);
            return lerp(lerp(a, b, f.y), lerp(c, d, f.y), f.z);
        }

        float Raggedness(float3 positionWS)
        {
            float3 x = positionWS * _MeshBlendShape.z;
            return ValueNoise(x) * 0.65 + ValueNoise(x * 2.7 + 17.0) * 0.35;
        }

        float3 Hue(float h)
        {
            return saturate(abs(frac(h + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0);
        }

        // How many of the twenty-five pixels around one carry this id.
        int IdCount(int2 centre, uint id)
        {
            int count = 0;
            [unroll]
            for (int y = -2; y <= 2; y++)
            [unroll]
            for (int x = -2; x <= 2; x++)
                count += IdOf(SurfaceAt(ClampPixel(centre + int2(x, y)))) == id ? 1 : 0;
            return count;
        }

        // Whether two pixels either side of a boundary are where their surfaces meet. At a real contact each lies on the
        // other surface's plane, off it by no more than its own pixel's footprint (one pixel's step along its surface
        // from where they meet), and the two lie next to each other, no further apart than their footprints. An edge
        // seen over something behind it is off the other's plane by the gap between them (a stone's top edge seen from
        // above stands its height over the ground), and a stone seen over another one further back can happen to lie in
        // that one's plane, with a gap between them. Footprints come from the surfaces' normals at the band's scale, so
        // an edge pixel seen side on does not stretch its own to the whole of the stone's side.
        // How well two pixels either side of a boundary touch: 1 up to one and a half times the tolerance (a real
        // contact seen at a slant, or along a staircase, lands a little past it) and 0 at two and a half times it. A gap that changes smoothly along an edge then fades the band smoothly along it: a pass or
        // fail at one tolerance would cut an edge whose gap hovers about it into teeth, shifting as the view moves.
        float Touch(float3 ownWS, float3 otherWS, float3 ownNormal, float3 otherNormal, float ownFootprint,
            float otherFootprint, float metresPerPixel)
        {
            float offOther = abs(dot(ownWS - otherWS, otherNormal)) / (1.5 * ownFootprint + metresPerPixel);
            float offOwn = abs(dot(otherWS - ownWS, ownNormal)) / (1.5 * otherFootprint + metresPerPixel);
            float apart = distance(ownWS, otherWS) / (1.5 * (ownFootprint + otherFootprint) + metresPerPixel);
            return saturate(2.5 - max(max(offOther, offOwn), apart));
        }

        uint4 FragSeed(Varyings input) : SV_Target
        {
            int2 p = int2(input.positionCS.xy);
            uint layers = SurfaceAt(p);
            uint own = GroupOf(layers);
            if (own == NO_GROUP) return uint4(NO_SEAM, NO_SEAM, 0u, 0u);

            uint id = IdOf(layers);
            float raw = RawDepthAt(p);
            float3 positionWS = WorldAt(p, raw);
            float3 normal = NormalAt(p);
            float metresPerPixel = EyeDepth(raw) / _MeshBlendBand.z;

            // Of the neighbours on another surface, the one that touches best is the seam: along a staircase boundary the
            // first one found is a straight neighbour on one pixel and a diagonal one, further away and touching less, on
            // the next, and a touch that alternates like that stripes the band column by column.
            uint4 seam = uint4(NO_SEAM, NO_SEAM, 0u, 0u);
            uint edge = 0u;
            float bestTouch = 0.0;
            for (int i = 0; i < 8; i++)
            {
                int2 q = ClampPixel(p + Neighbours[i]);
                uint other = SurfaceAt(q);
                uint otherId = IdOf(other);
                if (otherId != id && GroupOf(other) != NO_GROUP) edge = EDGE_PIXEL;
                if (otherId == id || !Blends(own, GroupOf(other))) continue;

                // Two surfaces meeting each fill a region beside the seam. A speck of one inside the other (a buried
                // rock's tip peeking through the ground for a pixel or three, coming and going as the view moves) is no
                // contact, and would grow a band of its own. The window is wide enough that a surface seen as a line
                // only a pixel tall (a far lip, drawn as a staircase of one and two pixel steps) still counts five.
                if (IdCount(q, otherId) < 4 || IdCount(p, id) < 4) continue;

                float3 ownNormal;
                float3 otherNormal;
                SeamNormalsAt(q, PatchStride(q, layers, other), id, otherId, ownNormal, otherNormal);
                float angle = AngleBetween(ownNormal, otherNormal);
                float3 view = normalize(_WorldSpaceCameraPos - positionWS);
                float ownFootprint = metresPerPixel / max(abs(dot(ownNormal, view)), 0.05);
                float otherFootprint = metresPerPixel / max(abs(dot(otherNormal, view)), 0.05);
                float touch = Touch(positionWS, WorldAt(q), ownNormal, otherNormal, ownFootprint, otherFootprint, metresPerPixel);
                if (touch <= 0.0) continue;

                // A contact runs along the boundary between the two surfaces, so the pairs beside this one along it touch
                // too. Where the boundary is an edge seen over the other surface, it is drawn as a staircase, and at each
                // step two pixels side by side on one row stand at all but the same depth and touch by chance: a lone
                // pair like that is no contact, and would grow a blob of band at every step.
                int2 along = int2(-Neighbours[i].y, Neighbours[i].x);
                float touching = 0.0;
                float onBoundary = 0.0;
                [unroll]
                for (int k = -2; k <= 2; k++)
                {
                    if (k == 0) continue;
                    int2 pk = ClampPixel(p + along * k);
                    int2 qk = ClampPixel(q + along * k);
                    if (IdOf(SurfaceAt(pk)) != id || IdOf(SurfaceAt(qk)) != otherId) continue;
                    onBoundary += 1.0;
                    touching += Touch(WorldAt(pk), WorldAt(qk), ownNormal, otherNormal, ownFootprint, otherFootprint,
                        metresPerPixel);
                }
                // The pairs beside it that lie on the boundary too must touch about as well. A slanted boundary runs
                // off the row within a pixel or two, so only the pairs that are on it count.
                if (onBoundary > 0.0) touch = min(touch, saturate(1.25 * touching / onBoundary));
                if (touch <= bestTouch) continue;
                bestTouch = touch;

                seam = uint4(uint2(q), otherId, (uint(round(angle * ANGLE_STEPS)) << 2)
                    | (uint(round(touch * TOUCH_STEPS)) << 10));
            }
            seam.w |= edge;
            return seam;
        }

        // What a step of one pixel along a screen axis covers on the surface a pixel shows, from its neighbours on
        // the same surface; as if facing the camera where it has none.
        float3 SurfaceStep(int2 p, int2 axis, uint id, float raw, float3 here)
        {
            int2 ahead = p + axis;
            int2 behind = p - axis;
            bool hasAhead = Inside(ahead) && IdOf(SurfaceAt(ahead)) == id;
            bool hasBehind = Inside(behind) && IdOf(SurfaceAt(behind)) == id;
            float3 from = hasBehind ? WorldAt(behind) : here;
            float3 to = hasAhead ? WorldAt(ahead) : (hasBehind ? here : WorldAt(ahead, raw));
            return (to - from) * (hasAhead && hasBehind ? 0.5 : 1.0);
        }

        uint4 FragFlood(Varyings input) : SV_Target
        {
            int2 p = int2(input.positionCS.xy);
            uint4 best = _MeshBlendSeams.Load(int3(p, 0));
            uint layers = SurfaceAt(p);
            if (GroupOf(layers) == NO_GROUP) return best;
            uint edge = best.w & EDGE_PIXEL;

            // Nearest is nearest in the world, not on screen: the band is measured in the world, and on a surface seen
            // at a slant one pixel row spans far more of it than one column, so the seam pixel nearest on screen can
            // switch to one much further away in the world from one pixel to the next, and the band steps there.
            //
            // The distance is along this pixel's own surface: the way to the seam pixel on screen, at what a pixel's
            // step covers of this surface here. It is never to the seam pixel's own place in the world: that one lies
            // on the other surface, and where the other surface is seen low (ground under a cliff) its pixels stand a
            // quarter metre apart in depth, so which of them came out nearest to a cliff pixel was down to chance,
            // several columns to the side as often as straight below, and everything worked out per seam pixel changed
            // in steps along the seam. The steps come from the depths of the neighbours on the same surface, not from
            // its normal: a normal map tilts a plane seen low far enough to put the seam beyond its horizon.
            uint id = IdOf(layers);
            float raw = RawDepthAt(p);
            float3 here = WorldAt(p, raw);
            float3 stepX = SurfaceStep(p, int2(1, 0), id, raw, here);
            float3 stepY = SurfaceStep(p, int2(0, 1), id, raw, here);
            float2 toBest = float2(best.xy) - float2(p);
            float3 bestOffset = stepX * toBest.x + stepY * toBest.y;
            float bestDistance = best.x == NO_SEAM ? 1e20 : dot(bestOffset, bestOffset);
            float reach = _MeshBlendBand.w * _MeshBlendBand.w;

            [unroll]
            for (int i = 0; i < 8; i++)
            {
                int2 q = p + Neighbours[i] * _MeshBlendStep;
                if (!Inside(q)) continue;
                uint4 candidate = _MeshBlendSeams.Load(int3(q, 0));
                if (candidate.x == NO_SEAM || candidate.z == id) continue;
                float2 onScreen = float2(candidate.xy) - float2(p);
                if (dot(onScreen, onScreen) > reach) continue;
                float3 candidateOffset = stepX * onScreen.x + stepY * onScreen.y;
                float candidateDistance = dot(candidateOffset, candidateOffset);
                if (candidateDistance < bestDistance)
                {
                    bestDistance = candidateDistance;
                    best = candidate;
                }
            }
            best.w = (best.w & ~EDGE_PIXEL) | edge;
            return best;
        }

        // A pixel near a seam, with the seam measured in the world.
        struct SeamPoint
        {
            // 1 at the seam, 0 at the band's edge.
            float closeness;
            // Intensity, faded out with distance from the camera and toward the reach of the seam search.
            float occlusionStrength;
            // The same, scaled by how well the seam's two sides touch.
            float strength;
            // How well this side and the other can show a band, see BandRoom.
            float ownRoom;
            float otherRoom;
            // How many of the other surface's pixels one of this surface's covers, going away from the seam: 1 where
            // the other surface is seen no flatter than this one, less where it is foreshortened more.
            float fold;
            // The band in metres.
            float radius;
            // Metres from the seam line, across this surface.
            float across;
            // The same measured in the world alone, never along the seam's line on screen: it changes smoothly from
            // pixel to pixel at any band width, where the line, used for bands a few pixels wide, switches on and off
            // from one stair step of the seam to the next on ground seen low.
            float acrossWorld;
            // 1 while both surfaces face the camera at the contact, falling to 0 as either turns edge on, see SeamAt.
            float inView;
            // 0 where the surfaces meet flat, 1 at a right angle or steeper.
            float angle;
            float eyeDepth;
            // The seam on screen: the way from it to this pixel, and this pixel's distance in pixels from the line
            // through the other surface's pixels along it.
            float2 away;
            float pixels;
            // 1 where this pixel lies within a pixel or two of the contact in the world, 0 from three: an edge pixel
            // that is not, is the last of a surface seen over the other one and not where they meet.
            float atContact;
        };

        // World size of one screen pixel on a surface at this point, stretched where the surface is seen edge on.
        float PixelFootprint(float3 positionWS, float3 normal)
        {
            float3 toCamera = _WorldSpaceCameraPos - positionWS;
            float distance = length(toCamera);
            float facing = max(abs(dot(normal, toCamera / max(distance, 1e-5))), 0.05);
            return distance / _MeshBlendBand.z / facing;
        }

        // World size, along a direction on a surface, of one screen pixel there.
        float FootprintAlong(float3 positionWS, float3 direction)
        {
            const float probe = 0.01;
            float pixels = length(PixelOf(positionWS + direction * probe) - PixelOf(positionWS));
            return probe / max(pixels, 1e-4);
        }

        // Where the view ray through a pixel meets a plane.
        bool OnPlane(float2 pixel, float3 onPlane, float3 normal, out float3 positionWS)
        {
            float3 through = ComputeWorldSpacePosition((pixel + 0.5) * _MeshBlendSize.zw, 0.5, _MeshBlendInvViewProj);
            float3 ray = through - _WorldSpaceCameraPos;
            float toward = dot(ray, normal);
            float along = dot(onPlane - _WorldSpaceCameraPos, normal) / (abs(toward) > 1e-6 ? toward : 1e-6);
            positionWS = _WorldSpaceCameraPos + ray * along;
            return along > 0.0;
        }

        // Metres of a plane that one pixel covers along a direction on screen, about a pixel. Huge where the plane is
        // seen edge on or lies behind the camera.
        float PlaneFootprint(float2 pixel, float2 direction, float3 onPlane, float3 normal)
        {
            float3 before;
            float3 after;
            if (!OnPlane(pixel - direction, onPlane, normal, before) || !OnPlane(pixel + direction, onPlane, normal, after))
                return 1e6;
            return max(0.5 * distance(before, after), 1e-6);
        }

        // How well a band shows on a surface whose pixels cover this much of it across the seam: 0 where the band spans
        // two pixels or fewer on screen, 1 from five. A band a pixel or two wide shows no blend, only the odd pixel
        // along the seam's staircase, crawling as the view moves.
        float BandRoom(float radius, float footprint)
        {
            return saturate((radius / footprint - 2.0) / 3.0);
        }

        // How far a set of screen offsets reaches along a direction, from its reach along eight directions an eighth of a
        // turn apart (x, x + y, y, y - x and their opposites), read between the two nearest.
        float SupportAlong(float4 ahead, float4 back, float2 way)
        {
            float turn = atan2(way.y, way.x) / (0.25 * PI);
            turn = turn < 0.0 ? turn + 8.0 : turn;
            float reaches[8] = { ahead.x, ahead.y, ahead.z, ahead.w, back.x, back.y, back.z, back.w };
            float sum = 0.0;
            [unroll]
            for (int i = 0; i < 8; i++)
            {
                float apart = abs(turn - i);
                apart = min(apart, 8.0 - apart);
                sum += saturate(1.0 - apart) * reaches[i];
            }
            return sum;
        }

        // How far a seam pixel's piece of the contact line reaches one way: the seam pixels seen that way, and half a
        // pixel more, while they end inside the window; the full piece once they run to its edge.
        float PieceReach(float seenPixels, float footprint, float fullPiece)
        {
            float seen = min(footprint * (seenPixels + 0.5), fullPiece);
            return lerp(seen, fullPiece, saturate(seenPixels - 2.0));
        }

        // Whether this surface, on the way across the screen from a pixel to its pixel beside the seam, drops away
        // behind the line between the two by more than the band: then the pixel is a part of the surface standing in
        // front of the seam (an overhang's lip seen just above the contact below it), near the contact in the world
        // but not joined to it on screen, and it takes no band. Depth is read in its reciprocal, which runs evenly
        // across the screen along a plane, so a flat or bulging surface never counts as dropping away.
        bool InFrontOfSeam(int2 p, float rawP, int2 beside, uint id, float radius)
        {
            float near0 = 1.0 / EyeDepth(rawP);
            float near1 = 1.0 / EyeDepth(RawDepthAt(beside));
            float2 way = float2(beside - p);
            [unroll]
            for (int i = 1; i < 8; i++)
            {
                float t = i / 8.0;
                int2 s = ClampPixel(int2(round(float2(p) + way * t)));
                if (IdOf(SurfaceAt(s)) != id) continue;
                float depth = EyeDepth(RawDepthAt(s));
                float expected = 1.0 / lerp(near0, near1, t);
                if (depth - expected > max(radius, 4.0 * depth / _MeshBlendBand.z)) return true;
            }
            return false;
        }

        bool SeamAt(int2 p, uint own, uint4 seam, out SeamPoint near)
        {
            near = (SeamPoint)0;
            if (own == NO_GROUP || seam.x == NO_SEAM) return false;

            float raw = RawDepthAt(p);
            float eyeDepth = EyeDepth(raw);
            uint ownSurface = SurfaceAt(p);
            uint ownId = IdOf(ownSurface);
            float3 ownAtSeam;
            float3 otherNormal;
            uint otherSurface = SurfaceAt(int2(seam.xy));
            float stride = PatchStride(int2(seam.xy), ownSurface, otherSurface);
            SeamNormalsAt(int2(seam.xy), stride, ownId, seam.z, ownAtSeam, otherNormal);

            // Each seam pixel carries the angle measured around it, and neighbouring pixels can be handed neighbouring
            // seam pixels with different angles. Averaging what the pixels around this one were handed lets the band's
            // width change smoothly along the contact instead of in a step at every change of seam pixel. The samples
            // stand at least three pixels apart: far away a short step in the surface (a lip a few centimetres tall
            // before a flat top) is a pixel or two on screen, and an average over fewer pixels catches it in one
            // column and misses it in the next, so the band flips between the narrow and the wide one column by
            // column, in teeth that shift as the view moves.
            float angleSpacing = max(2.0 * stride, 3.0);
            float angleSum = 0.0;
            float angleCount = 0.0;
            [unroll]
            for (int ay = -2; ay <= 2; ay++)
            [unroll]
            for (int ax = -2; ax <= 2; ax++)
            {
                int2 q = ClampPixel(p + int2(round(float2(ax, ay) * angleSpacing)));
                uint4 nearby = _MeshBlendSeams.Load(int3(q, 0));
                if (nearby.x == NO_SEAM || nearby.z != seam.z || IdOf(SurfaceAt(q)) != ownId) continue;
                angleSum += SeamAngle(nearby.w);
                angleCount += 1.0;
            }
            float angle = angleCount > 0.0 ? angleSum / angleCount : SeamAngle(seam.w);
            // How well the surfaces touch, averaged densely around the seam pixel: it changes from step to step of the
            // boundary's staircase, and a sparse average about this pixel catches a different set of steps one column
            // to the next, which stripes the band. Around the seam pixel it is the same for every pixel that seam pixel
            // serves, and neighbouring seam pixels share all but one row of the window.
            float touchNear = 0.0;
            float touchCount = 0.0;
            // The same pixels say where the seam runs on screen: each names the other surface's pixel across the seam
            // from it.
            float2 namedSum = 0.0;
            float3 namedSquares = 0.0;
            float2 ownSum = 0.0;
            // And how far they run from the seam pixel each way, along eight directions an eighth of a turn apart.
            float4 reachAhead = 0.0;
            float4 reachBack = 0.0;
            [unroll]
            for (int ty = -3; ty <= 3; ty++)
            [unroll]
            for (int tx = -3; tx <= 3; tx++)
            {
                int2 q = ClampPixel(int2(seam.xy) + int2(tx, ty));
                uint4 nearby = _MeshBlendSeams.Load(int3(q, 0));
                if (nearby.x == NO_SEAM || nearby.z != seam.z || IdOf(SurfaceAt(q)) != ownId) continue;
                touchNear += SeamTouch(nearby.w);
                touchCount += 1.0;
                float2 named = float2(nearby.xy) - float2(seam.xy);
                namedSum += named;
                namedSquares += float3(named.x * named.x, named.x * named.y, named.y * named.y);
                float4 onAxes = float4(named.x, (named.x + named.y) * 0.70710678, named.y, (named.y - named.x) * 0.70710678);
                reachAhead = max(reachAhead, onAxes);
                reachBack = max(reachBack, -onAxes);
                ownSum += float2(tx, ty);
            }
            float touch = touchCount > 0.0 ? touchNear / touchCount : SeamTouch(seam.w);
            // Never narrower than a few pixels on screen: a right-angle band of a few centimetres is under two pixels
            // a little way off, too narrow to show a blend, and the seam would be left hard there.
            near.radius = max(BandRadius(ownSurface, otherSurface, angle), MIN_BAND_PIXELS * eyeDepth / _MeshBlendBand.z);
            near.angle = angle;
            near.eyeDepth = eyeDepth;

            float3 positionWS = WorldAt(p, raw);

            float3 seamWS = WorldAt(int2(seam.xy));
            float3 crossed = cross(ownAtSeam, otherNormal);
            float sine = sin(angle * HALF_PI);
            float lineStrength = saturate((sine - 0.05) / 0.15);
            float3 seamLine = length(crossed) > 1e-4 ? normalize(crossed) : float3(0.0, 0.0, 0.0);

            // Where the surfaces meet. The seam pixel and the pixel on this side it names sit either side of the contact,
            // each up to a pixel's footprint off it, and a surface seen at a slant has a long footprint: one ground pixel
            // seen low spans a long stretch of ground in depth. So the contact is taken as the point where the two
            // surfaces' planes there meet, nearest the pair, which lies on the contact whichever surface is seen at a
            // slant. It never moves further from the pair than the pair's own spread: the pixel named can be far along
            // an outline, and a plane taken far from where it was measured goes astray.
            uint4 back = _MeshBlendSeams.Load(int3(seam.xy, 0));
            float3 hereWS = back.x == NO_SEAM ? seamWS : WorldAt(int2(back.xy));
            float3 middle = 0.5 * (hereWS + seamWS);
            float3 contact = middle;
            float cosine = dot(ownAtSeam, otherNormal);
            float determinant = 1.0 - cosine * cosine;
            if (determinant > 1e-3)
            {
                float toHerePlane = dot(ownAtSeam, hereWS - middle);
                float toSeamPlane = dot(otherNormal, seamWS - middle);
                float alongOwn = (toHerePlane - cosine * toSeamPlane) / determinant;
                float alongOther = (toSeamPlane - cosine * toHerePlane) / determinant;
                float3 onBoth = middle + alongOwn * ownAtSeam + alongOther * otherNormal;
                float spread = distance(hereWS, seamWS) + PixelFootprint(seamWS, otherNormal);
                contact = distance(onBoth, middle) <= spread ? onBoth : middle;
            }

            // The seam is seen only while both surfaces face the camera where they meet: as either turns edge on, the
            // contact goes behind it and the seam is gone, and a band still wide then would vanish all at once. So the
            // band shrinks as the surface seen flatter of the two drops from 30 degrees to the line of sight, and is
            // gone at 5, a little before it is edge on and the seam's last pixels flicker in and out. Seen from above, the ground keeps its band and the
            // other surface's colour comes onto the rock; seen low over the ground, the band draws back to the seam.
            float3 toCamera = normalize(_WorldSpaceCameraPos - contact);
            float facing = min(dot(ownAtSeam, toCamera), dot(otherNormal, toCamera));
            near.inView = saturate((asin(clamp(facing, -1.0, 1.0)) - radians(5.0)) / radians(25.0));
            near.radius *= near.inView;


            // The seam on screen about its seam pixel. Where it runs straight there, it is the line through the middle
            // of the pixels named above, along the way they spread, with this surface on the side the pixels naming
            // them lie on: that gives the way across the seam, and this pixel's distance from it, without the whole
            // pixel steps one seam pixel's own place has. Where they do not line up (a tip, a speck, a seam pixel with
            // next to nothing around it) the seam pixel itself stands for the seam.
            float2 toHere = float2(p) - float2(seam.xy);
            float pointDistance = max(length(toHere), 1.0);
            float2 pointAway = toHere / pointDistance;
            float2 straightAway = pointAway;
            float straightDistance = pointDistance;
            float straight = 0.0;
            float2 alongScreen = 0.0;
            if (touchCount > 2.5)
            {
                float2 centre = namedSum / touchCount;
                float3 spread = namedSquares / touchCount
                    - float3(centre.x * centre.x, centre.x * centre.y, centre.y * centre.y);
                float halfTrace = 0.5 * (spread.x + spread.z);
                float halfGap = 0.5 * (spread.x - spread.z);
                float root = sqrt(halfGap * halfGap + spread.y * spread.y);
                float major = halfTrace + root;
                float minor = halfTrace - root;
                float2 first = float2(major - spread.z, spread.y);
                float2 second = float2(spread.y, major - spread.x);
                float2 along = dot(first, first) > dot(second, second) ? first : second;
                float alongLength = length(along);
                if (alongLength > 1e-4)
                {
                    alongScreen = along / alongLength;
                    float2 acrossSeam = float2(-along.y, along.x) / alongLength;
                    if (dot(acrossSeam, ownSum / touchCount - centre) < 0.0) acrossSeam = -acrossSeam;
                    straightAway = acrossSeam;
                    // The line stands for the seam only as far as its pixels run: a pixel served from a seam's last pixel
                    // (a corner, where a third surface takes over) can lie far out along the line's extension, at no
                    // distance from the line, and the band would run on along it as a long thin shard. Past the seam's
                    // end, and a pixel and a half of the staircase's steps more, the distance is to that end. Where the
                    // seam pixels run on toward the window's edge they go on beyond it, and the line holds.
                    float alongHere = dot(toHere, alongScreen);
                    float seamRuns = SupportAlong(reachAhead, reachBack, alongHere >= 0.0 ? alongScreen : -alongScreen);
                    float beyond = max(abs(alongHere) - seamRuns - 1.5, 0.0) * (1.0 - saturate(seamRuns - 1.5));
                    float acrossLine = dot(toHere - centre, acrossSeam);
                    straightDistance = acrossLine >= 0.0 ? length(float2(acrossLine, beyond)) : acrossLine + beyond;
                    straight = saturate((major - 0.5) / 1.5)
                        * saturate(((major - minor) / max(major + minor, 1e-4) - 0.6) / 0.3);
                }
            }
            near.away = normalize(lerp(pointAway, straightAway, straight) + 1e-6);
            near.pixels = lerp(pointDistance, straightDistance, straight);

            // The seam line in the world. Where the seam runs straight on screen it is that line laid on this surface's
            // plane: where the surfaces meet nearly flat their normals are nearly the same, and the line they cross in
            // turns with every bump of the normal maps from one seam pixel to the next, and each pixel's distance to
            // its own seam pixel's piece with it, in streaks fanning out across the band.
            if (straight > 0.0)
            {
                float3 lineStart;
                float3 lineEnd;
                if (OnPlane(float2(seam.xy) - 2.0 * alongScreen, contact, ownAtSeam, lineStart)
                    && OnPlane(float2(seam.xy) + 2.0 * alongScreen, contact, ownAtSeam, lineEnd)
                    && distance(lineStart, lineEnd) > 1e-6)
                {
                    float3 onScreen = normalize(lineEnd - lineStart);
                    if (dot(seamLine, onScreen) < 0.0) seamLine = -seamLine;
                    seamLine = normalize(lerp(seamLine, onScreen, straight) + 1e-6);
                    lineStrength = max(lineStrength, straight);
                }
            }

            // The distance across is to that contact, standing for a piece of the seam line a pixel long: a distance to
            // the nearest of a set of points changes smoothly from pixel to pixel, so the band follows the contact's own
            // outline, facets and corners included, and neighbouring seam pixels' pieces overlap, so its edge runs
            // smooth along the contact without reaching far past the end of one.
            float3 toSeam = positionWS - contact;
            // The piece reaches up to twice the band either way along the line: seen at a grazing angle, the seam
            // pixel nearest in the world is often several pixels along the contact from this one (the ground pixel
            // straight below spans a long stretch of ground in depth), and a piece only a pixel long would leave this
            // pixel two bands from it, a gap in the band with the seam showing through.
            // Each end reaches no further on screen than the seam pixels around this one run that way, unless they run
            // on past the window. At a corner the seam turns away, and a piece running on along the line past the tip
            // reaches into the open wedge beyond it, while the pixels served from the other side of the corner measure
            // to their own line: the band there changes in a hard edge running out of the corner.
            float footprintAlong = FootprintAlong(contact, seamLine);
            float fullPiece = max(footprintAlong, 2.0 * near.radius);
            float2 lineOnScreen = PixelOf(contact + seamLine * 0.01) - PixelOf(contact);
            float lineShown = length(lineOnScreen);
            float2 lineWay = lineShown > 1e-5 ? lineOnScreen / lineShown : float2(1.0, 0.0);
            float pieceAhead = lineStrength * PieceReach(SupportAlong(reachAhead, reachBack, lineWay), footprintAlong, fullPiece);
            float pieceBack = lineStrength * PieceReach(SupportAlong(reachAhead, reachBack, -lineWay), footprintAlong, fullPiece);
            float3 offPiece = toSeam - clamp(dot(toSeam, seamLine), -pieceBack, pieceAhead) * seamLine;
            float acrossWorld = length(offPiece);

            // Each surface as its plane at the seam, and the way across as the seam's own on screen: every pixel a
            // seam serves gets one answer, both sides get the same two, and they change smoothly along the seam.
            // Counted from each pixel's own offset to the seam there is no direction to go by right at the seam, and
            // single seam pixels came out unblended, in a dashed line.
            float ownFootprint = PlaneFootprint(float2(seam.xy), near.away, contact, ownAtSeam);
            float otherFootprint = PlaneFootprint(float2(seam.xy), near.away, contact, otherNormal);
            near.ownRoom = BandRoom(near.radius, ownFootprint);
            near.otherRoom = BandRoom(near.radius, otherFootprint);
            near.fold = saturate(ownFootprint / otherFootprint);

            // The contact above is worked out per seam pixel, and from one seam pixel to the next it sits up to half a
            // pixel higher or lower. A band many pixels wide does not show that; one a few pixels wide shows its edge
            // step up and down in teeth. So the narrower the band on screen, the more the distance is counted from the
            // straight line instead, which has no steps: the seam lies half a pixel before the other surface's pixels.
            near.atContact = 1.0 - smoothstep(1.5, 3.0, acrossWorld / ownFootprint);
            float acrossStraight = max(near.pixels - 0.5, 0.0) * ownFootprint;
            float narrow = straight * saturate((24.0 - near.radius / ownFootprint) / 16.0);
            near.across = lerp(acrossWorld, acrossStraight, narrow);
            near.acrossWorld = acrossWorld;

            // Raggedness moves the band's outer edge between (1 - noise) and (1 + noise) of the radius; the seam itself
            // stays put. A noise patch only a pixel or two wide on screen is sampled too coarsely and crawls as the view
            // moves, so the raggedness fades out as its patches shrink from six pixels to two.
            float patchPixels = _MeshBlendBand.z / (_MeshBlendShape.z * eyeDepth);
            float noise = _MeshBlendShape.y * saturate((patchPixels - 2.0) / 4.0);
            float edge = near.radius * (1.0 + noise * (2.0 * Raggedness(positionWS) - 1.0));
            // The full mix holds over the first part of the band, so the pixels right at the seam take all of it: a mix
            // that only peaks at the seam itself leaves the pixel beside it a little of its own colour, and that little
            // runs the whole length of the seam as a straight edge. Toward the band's outer edge it eases out to nothing,
            // so the edge leaves no line: a falloff that reaches zero at a slant draws a crease where it stops.
            near.closeness = smoothstep(0.0, 1.0, saturate((1.0 - near.across / max(edge, 1e-4)) / 0.8));
            // Close up a band can outgrow the seam search's reach on screen; it fades out before the reach rather than
            // ending in a cut.
            float searched = length(toHere);
            near.occlusionStrength = _MeshBlendShape.x
                * saturate((_MeshBlendShape.w - eyeDepth) / (0.25 * _MeshBlendShape.w))
                * saturate((_MeshBlendBand.w - searched) / (0.35 * _MeshBlendBand.w));
            near.strength = near.occlusionStrength * touch;
            // A surface's last pixels before another take part whatever their band, see the blend; so does a pixel
            // within the occlusion reach, in the occlusion pass.
            if (back.x != NO_SEAM && IdOf(SurfaceAt(int2(back.xy))) == ownId
                && InFrontOfSeam(p, raw, int2(back.xy), ownId, near.radius))
                return false;
            bool blends = near.strength > 0.0 && (near.closeness > 0.0 || IsEdgePixel(seam));
            return blends || (near.occlusionStrength > 0.0 && acrossWorld < max(_MeshBlendExtra.z, near.radius));
        }

        // The colour of a masked copy around a point on screen, blurred over about a given radius in pixels: eight taps
        // on a ring and one in the middle, each reading a detail level a step finer than the radius, so the levels'
        // own grid does not show, and divided by the weight gathered, so grass, water, a character or the sky near
        // the seam add nothing. It changes smoothly as the point moves. Alpha is 0 where nothing was gathered.
        float4 BlurredColorAt(Texture2D<float4> source, float2 pixel, float radius)
        {
            // The copies are half size, so their finest level is already one step down. Read between levels: the radius
            // grows with the distance from the seam, and snapped to whole levels the band steps from one to the next in
            // squares of the coarser level's texels, which crawl as the view moves.
            float level = max(log2(max(radius, 1.0)) - 2.0, 0.0);
            float4 sum = source.SampleLevel(sampler_TrilinearClamp, (pixel + 0.5) * _MeshBlendSize.zw, level);
            [unroll]
            for (int i = 0; i < 8; i++)
            {
                float angle = i * (TWO_PI / 8.0);
                float2 tap = pixel + 0.6 * radius * float2(cos(angle), sin(angle));
                sum += source.SampleLevel(sampler_TrilinearClamp, (tap + 0.5) * _MeshBlendSize.zw, level);
            }
            return sum.a > 1e-6 ? float4(sum.rgb / sum.a, 1.0) : float4(0.0, 0.0, 0.0, 0.0);
        }

        // The colour of one surface about a point on screen: the four pixels around the point, weighed as a filtered
        // sample weighs them, counting only those that show the surface at about the given depth and are not edge
        // pixels. An edge pixel is part the other surface, and a filtered sample next to a seam takes in the other
        // surface outright; either one carries the dark foot of a rock into the sand it is meant to fade into. rgb is
        // the weighted sum and a the weight that counted, 1 where all four did.
        float4 SurfaceColorAt(float2 pixel, uint id, float eyeDepth)
        {
            float2 corner = floor(pixel);
            float2 f = pixel - corner;
            float4 sum = 0.0;
            [unroll]
            for (int i = 0; i < 4; i++)
            {
                int2 cell = int2(i & 1, i >> 1);
                int2 q = int2(corner) + cell;
                if (!Inside(q) || IdOf(SurfaceAt(q)) != id) continue;
                if (IsEdgePixel(_MeshBlendSeams.Load(int3(q, 0)))) continue;
                if (abs(EyeDepth(RawDepthAt(q)) - eyeDepth) > 0.5 * eyeDepth) continue;
                float2 share = lerp(1.0 - f, f, float2(cell));
                sum += float4(_MeshBlendColor.Load(int3(q, 0)).rgb, 1.0) * (share.x * share.y);
            }
            return sum;
        }

        struct MaskedColors
        {
            float4 higher : SV_Target0;
            float4 lower : SV_Target1;
        };

        // Pass 5: the masked copies, each pixel the four frame pixels it covers. Edge pixels are left out: part
        // another surface's colour, they would carry it into every blur that reaches them.
        MaskedColors FragMasked(Varyings input)
        {
            int2 corner = int2(input.positionCS.xy) * 2;
            MaskedColors output;
            output.higher = 0.0;
            output.lower = 0.0;
            [unroll]
            for (int i = 0; i < 4; i++)
            {
                int2 q = ClampPixel(corner + int2(i & 1, i >> 1));
                uint group = GroupOf(SurfaceAt(q));
                if (group == NO_GROUP || IsEdgePixel(_MeshBlendSeams.Load(int3(q, 0)))) continue;
                float4 weighed = float4(min(_MeshBlendColor.Load(int3(q, 0)).rgb, 64.0), 1.0);
                float2 weights = _MeshBlendGroupLinks[group - 1u].zw;
                output.higher += weighed * weights.x;
                output.lower += weighed * weights.y;
            }
            return output;
        }

        float4 FragBlend(Varyings input) : SV_Target
        {
            int2 p = int2(input.positionCS.xy);
            uint layers = SurfaceAt(p);
            uint own = GroupOf(layers);
            float4 color = _MeshBlendColor.Load(int3(p, 0));
            uint4 seam = _MeshBlendSeams.Load(int3(p, 0));

            SeamPoint near;
            bool hasSeam = SeamAt(p, own, seam, near);
            // How much of the other surface this pixel shows, for the weight view.
            float taken = 0.0;
            float3 result = color.rgb;
            bool changed = false;
            if (hasSeam)
            {
                // Sharp Seams lets the line itself show through in the last few pixels next to the seam, as much as
                // the surfaces meet at a sharp angle.
                float acrossPixels = near.across * _MeshBlendBand.z / near.eyeDepth;
                float showLine = _MeshBlendExtra.w * near.angle * saturate(1.0 - acrossPixels / 3.0);
                float strength = near.strength * (1.0 - showLine);
                float ownRank = GroupData(own).w;
                float otherRank = GroupData(GroupOf(SurfaceAt(int2(seam.xy)))).w;

                if (IsEdgePixel(seam))
                {
                    // An edge pixel does not keep its own colour where the seam blends. With multisampling it is part
                    // the other surface, and what there is of its own is shaded from outside its triangle, often near
                    // black. Next to a surface that fades away, or between two that each keep half of themselves, it
                    // would stay behind as a dark, stair-stepped line through the blend. It shows its surface from a
                    // pixel or two further in instead, by as much as the seam blends (for the side that keeps its
                    // colour, as much as the other side fades at all). Where the two do not meet at this pixel (one
                    // is seen over the other, touching it further along) it is left alone: there it is the outline's
                    // anti-aliasing, and replacing it leaves the outline in stair steps.
                    //
                    // The way in is read off the pixels around: the seam this pixel holds is its nearest in the world,
                    // and on ground seen low that is as often a step of the seam's staircase some pixels to the side
                    // as the rock right above.
                    float cleaned = strength * near.atContact * (ownRank > otherRank ? near.otherRoom : 1.0);
                    if (cleaned > 0.0)
                    {
                        float2 toOthers = 0.0;
                        [unroll]
                        for (int i = 0; i < 8; i++)
                        {
                            uint beside = SurfaceAt(ClampPixel(p + Neighbours[i]));
                            if (GroupOf(beside) != NO_GROUP && IdOf(beside) != IdOf(layers))
                                toOthers += float2(Neighbours[i]);
                        }
                        float2 inward = dot(toOthers, toOthers) > 0.0 ? -normalize(toOthers) : near.away;
                        float4 clean = SurfaceColorAt(float2(p) + inward * 1.5, IdOf(layers), near.eyeDepth);
                        if (clean.a < 0.5) clean = SurfaceColorAt(float2(p) + inward * 2.5, IdOf(layers), near.eyeDepth);
                        if (clean.a > 0.25)
                        {
                            result = lerp(result, clean.rgb / clean.a, saturate(cleaned));
                            changed = true;
                        }
                    }
                }

                if (ownRank <= otherRank)
                {
                    // The lower side goes all the way at the seam. Equals each go halfway, unless one side has no room
                    // to show a band (ground seen low is a fraction of a pixel per band): then the side that has room
                    // carries the whole fade, and the two shares still add up to one at the seam.
                    float share = ownRank < otherRank ? near.ownRoom : near.ownRoom * (1.0 - 0.5 * near.otherRoom);
                    float weight = near.closeness * strength * share;
                    taken = weight;
                    if (weight > 0.0)
                    {
                        // The two sides' colours right at the seam, each over the few pixels beside it. Taken that
                        // close, both stand in the same light, so how they compare is how the surfaces differ and not
                        // how they are lit: over the whole band one side can lie in a leaf's shadow and the other in
                        // the sun. Neighbouring seam pixels read all but the same pixels, so it changes smoothly
                        // along the seam. Further out they are read over as much again as the pixel is from the seam: deep
                        // in a wide band a whole row of pixels is served by one seam pixel, and a leaf's shadow crossing
                        // the seam, read over a few pixels, would be carried straight across the band as a hard edge.
                        // They are read about the point of the seam straight across from this pixel, not about its seam
                        // pixel: where the seam runs nearly level its stair steps lie many pixels apart, each serves a
                        // column that wide, and colours read about the steps change in a step from column to column, in
                        // stripes running up the band.
                        float lines = _MeshBlendSize.y / 1080.0;
                        float2 about = float2(p) - near.away * (near.pixels - 0.5);
                        float spread = max(8.0 * lines, near.pixels);
                        float4 higher = BlurredColorAt(_MeshBlendMasked, about, spread);

                        // Away from the seam a pixel keeps its own detail and its own lighting and only shifts in
                        // colour: it becomes the other side's colour there, as much brighter or darker as the pixel
                        // itself is than its own side there. A rock's foot turns the sand's colour and stays lit and
                        // shadowed as the rock is. Fading into the other side's pixels over a wide band copies its
                        // lighting along with them, a patch of leaf shadow or a run of ripples laid on the rock a
                        // second time, mirrored. The colour is the other side's outright, not this pixel's scaled
                        // channel by channel: on a rock that is all but black a channel near zero turned the scale,
                        // and the foot, blue or orange. Between equals there is no shift, since no blur tells the two
                        // apart.
                        float3 target = result;
                        if (ownRank < otherRank)
                        {
                            float4 lower = BlurredColorAt(_MeshBlendMaskedLow, about, spread);
                            if (higher.a > 0.0 && lower.a > 0.0)
                            {
                                const float3 luma = float3(0.2126, 0.7152, 0.0722);
                                float relative = dot(result, luma) / max(dot(lower.rgb, luma), 1e-3);
                                target = higher.rgb * clamp(relative, 0.25, 2.5);

                            }
                        }

                        // Beside the seam it fades into the other surface's own pixels instead, mirrored across the
                        // seam on screen: the pixel as far past the seam as this one is before it, so both sides show
                        // the same pixels where they meet and no line is left between two textures. That holds for
                        // the first three pixels and is gone by twelve (at 1080 lines): a narrow band is mirrored
                        // nearly through, a wide one only along the seam, where a texture with a direction to it
                        // (ripples) has little room to turn back on itself in hooks. Where the other surface is
                        // foreshortened more than this one (ground seen low under a wall), a pixel of it is a long way
                        // in the world, so the mirror takes shorter steps there and stays as near the seam in the
                        // world as this pixel is.
                        float mirrorShare = 1.0 - smoothstep(3.0, 12.0, near.pixels / lines);
                        if (mirrorShare > 0.0)
                        {
                            // A pixel and a half past the line at the least, clear of the other surface's edge pixel.
                            float past = 1.5 + max(near.pixels - 1.0, 0.0) * near.fold;
                            float2 mirrored = float2(p) - near.away * (near.pixels + past);
                            float4 other = SurfaceColorAt(mirrored, seam.z, near.eyeDepth);
                            float3 otherColor = other.rgb / max(other.a, 1e-4);
                            // Where the mirrored pixels are not the other surface (hidden behind grass or a body, off
                            // screen, too thin a strip of it), the blur of the higher side about the seam stands in.
                            if (other.a < 0.999) otherColor = lerp(higher.a > 0.0 ? higher.rgb : result, otherColor, other.a);
                            target = lerp(target, otherColor, mirrorShare);
                        }

                        result = lerp(result, target, weight);
                        changed = true;
                    }
                }
            }

            if (_MeshBlendDebug == 1)
            {
                if (own == NO_GROUP) return float4(color.rgb * 0.15, 1.0);
                if (IsGround(own)) return float4(Hue(own * 0.13 + 0.06) * 0.35, 1.0);
                return float4(Hue(frac(IdOf(layers) * 0.6180339)) * lerp(0.5, 1.0, GroupData(own).z), 1.0);
            }
            if (_MeshBlendDebug == 2)
            {
                float grey = dot(color.rgb, float3(0.2126, 0.7152, 0.0722)) * 0.6;
                return float4(lerp(grey.xxx, float3(1.0, 0.1, 0.05), saturate(taken)), 1.0);
            }

            if (!changed) discard;
            return float4(result, color.a);
        }

        float OcclusionAt(float2 pixel)
        {
            return _MeshBlendOcclusionSource.SampleLevel(sampler_LinearClamp, (pixel + 0.5) * _MeshBlendSize.zw, 0).r;
        }

        // Before any surface is lit, holds the occlusion inside the band at the level the band's outer edge has on the
        // same surface, so the crease's own darkening goes while the grounding around the contact stays and nothing in
        // the band ends lighter than its surroundings.
        float4 FragOcclusion(Varyings input) : SV_Target
        {
            float2 scale = _MeshBlendSize.xy / _MeshBlendOcclusionSize.xy;
            int2 p = ClampPixel(int2(input.positionCS.xy * scale));
            uint layers = SurfaceAt(p);
            SeamPoint near;
            if (!SeamAt(p, GroupOf(layers), _MeshBlendSeams.Load(int3(p, 0)), near)) discard;

            // SSAO darkens a contact over its own radius, often far wider than the band, so the occlusion is held over
            // its own reach, at the level of the occlusion around this pixel out at that reach: a ring of samples about
            // the pixel itself, so the level changes smoothly from pixel to pixel. A level taken at one point per seam
            // pixel splits the ground into flat shards, one per seam pixel's region.
            float reach = max(_MeshBlendExtra.z, near.radius);
            float ringPixels = clamp(reach * _MeshBlendBand.z / near.eyeDepth, 2.0, 96.0);
            float edgeLevel = 0.0;
            [unroll]
            for (int i = 0; i < 12; i++)
            {
                float angle = i * (TWO_PI / 12.0);
                edgeLevel += OcclusionAt(float2(p) + ringPixels * float2(cos(angle), sin(angle)));
            }
            edgeLevel /= 12.0;
            float here = OcclusionAt(float2(p));
            float held = max(here, edgeLevel);
            // The occlusion is soft whatever the band, so it goes by the distance in the world: by the line on screen,
            // ground seen low switched between the two at each stair step of the seam, and kept the full occlusion in a
            // triangle under each step, which the blend then mirrored up the rock in a row of dark teeth.
            float closeness = smoothstep(0.0, 1.0, saturate((1.0 - near.acrossWorld / reach) / 0.8));
            // Not scaled by how well the seam's sides touch: that varies from seam pixel to seam pixel, and each one's
            // region of ground would keep a different amount of occlusion, in shards.
            float flatten = closeness * near.occlusionStrength * near.inView * (1.0 - _MeshBlendExtra.y);
            return lerp(here, held, flatten).xxxx;
        }
        bool IsSky(float rawDepth)
        {
            #if UNITY_REVERSED_Z
                return rawDepth <= 1e-7;
            #else
                return rawDepth >= 1.0 - 1e-7;
            #endif
        }

        // Whether two depths are the same surface. The id and ground passes draw the very geometry the depth prepass drew,
        // but not at the very spot: with MSAA the depth texture holds one sample's depth, off the pixel's centre by up to
        // half a pixel each way, so on a surface whose depth changes steeply across the screen the two differ by up to
        // half the change across a pixel (the slope passed in is the sum of the changes along x and y). That is the
        // tolerance, and no more: any looser and a surface just behind the visible one counts too, and a buried rock
        // marks the ground above it in specks, each a seam of its own. The mismatch is the difference in tolerances:
        // 1 at the edge of it.
        float DepthMismatch(float rawA, float rawB, float slope)
        {
            float a = EyeDepth(rawA);
            float b = EyeDepth(rawB);
            return abs(a - b) / (0.5 * slope + b * 2e-4 + 2e-4);
        }

        bool SameDepth(float rawA, float rawB, float slope)
        {
            return DepthMismatch(rawA, rawB, slope) <= 1.0;
        }

        // Two surfaces that meet nearly flat, seen close and low (ground and a rock buried flush in it), can both lie
        // within the tolerance of what the camera sees, and over many pixels: the one further back is under a
        // millimetre behind. Each id pass writes how well it matches as depth into a buffer of their own, so the
        // surface that matches best keeps the pixel, whichever draws last. Otherwise the ids put the seam pixels away
        // from where the colour changes, and the band leaves the edge the eye sees untouched.
        float MatchDepth(float mismatch)
        {
            #if UNITY_REVERSED_Z
                return 1.0 - saturate(mismatch);
            #else
                return saturate(mismatch);
            #endif
        }

        // Whether a surface at this depth is the one the camera sees there: the same depth the prepass kept, and nothing
        // in front of it. The id pass draws without the renderers' materials, so an alpha-clipped surface (an impostor's
        // quad, a leaf card) draws its see-through parts too; those lie in front of what the camera sees and must not
        // claim the object's id there.
        bool IsVisibleAt(int2 p, float rawDepth, float slope)
        {
            return SameDepth(rawDepth, RawDepthAt(p), slope);
        }

        uint FragGround(Varyings input, out float match : SV_Depth) : SV_Target
        {
            int2 p = int2(input.positionCS.xy);
            float scene = RawDepthAt(p);
            if (IsSky(scene)) discard;
            float ground = _MeshBlendGroundDepth.Load(int3(p, 0));
            if (IsSky(ground)) discard;
            float right = _MeshBlendGroundDepth.Load(int3(ClampPixel(p + int2(1, 0)), 0));
            float up = _MeshBlendGroundDepth.Load(int3(ClampPixel(p + int2(0, 1)), 0));
            float eye = EyeDepth(ground);
            float slope = (IsSky(right) ? 0.0 : abs(EyeDepth(right) - eye)) + (IsSky(up) ? 0.0 : abs(EyeDepth(up) - eye));
            float mismatch = DepthMismatch(ground, scene, slope);
            if (mismatch > 1.0) discard;
            match = MatchDepth(mismatch);
            uint group = (uint)_MeshBlendGroundGroup;
            return ((0xFFFFu - group) << 16) | group;
        }
        ENDHLSL

        Pass
        {
            Name "Seed"
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment FragSeed
            ENDHLSL
        }

        Pass
        {
            Name "Flood"
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment FragFlood
            ENDHLSL
        }

        Pass
        {
            Name "Blend"
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment FragBlend
            ENDHLSL
        }

        Pass
        {
            Name "Occlusion"
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment FragOcclusion
            ENDHLSL
        }

        Pass
        {
            Name "Ground Ids"
            ZTest LEqual
            ZWrite On
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment FragGround
            ENDHLSL
        }

        Pass
        {
            Name "Masked Copy"
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment FragMasked
            ENDHLSL
        }

        Pass
        {
            // Drawn in place of each taking-part renderer's own material. Renderers drawn by the GPU Resident Drawer need
            // a DOTS-instanced variant of every pass they are drawn with, an override's included.
            Name "Id"
            Cull Back
            ZTest LEqual
            ZWrite On
            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex VertId
            #pragma fragment FragId
            #pragma multi_compile_instancing
            #include_with_pragmas "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DOTS.hlsl"

            struct IdAttributes
            {
                float4 positionOS : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct IdVaryings
            {
                float4 positionCS : SV_POSITION;
                nointerpolation uint surface : TEXCOORD0;
            };

            // A hash of the object's world position: every pixel of an object agrees on it, and the LODs of one object
            // share it. 0 is nothing and the top few ids are the ground groups', so an object takes 1 to 0xFFF0.
            uint ObjectId()
            {
                uint3 position = asuint(UNITY_MATRIX_M._m03_m13_m23);
                uint h = position.x * 0x8da6b343u ^ position.y * 0xd8163841u ^ position.z * 0xcb1ab31fu;
                h ^= h >> 16;
                h *= 0x7feb352du;
                h ^= h >> 15;
                h *= 0x846ca68bu;
                h ^= h >> 16;
                return 1u + h % 0xFFF0u;
            }

            // The object's size: the middle of its world bounds' three extents, so a slab lying flat counts by its
            // breadth and not its thickness, and a pillar by its girth. Log-scaled into 13 bits.
            uint EncodeSize()
            {
                float3 extent = unity_RendererBounds_Max.xyz - unity_RendererBounds_Min.xyz;
                float middle = max(min(extent.x, extent.y), min(max(extent.x, extent.y), extent.z));
                float scaled = saturate((log2(max(middle, 1e-6)) - SIZE_LOG_MIN) / SIZE_LOG_RANGE);
                return (uint)round(scaled * SIZE_STEPS);
            }

            IdVaryings VertId(IdAttributes input)
            {
                UNITY_SETUP_INSTANCE_ID(input);
                IdVaryings output;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                uint layers = asuint(unity_RenderingLayer.x);
                uint group = NO_GROUP;
                for (int g = _MeshBlendGroupCount - 1; g >= 0; g--)
                {
                    uint mask = uint(_MeshBlendGroups[g].x) | (uint(_MeshBlendGroups[g].y) << 16);
                    if (_MeshBlendGroupLinks[g].y < 0.5 && (layers & mask) != 0u) group = uint(g) + 1u;
                }
                output.surface = (ObjectId() << 16) | (EncodeSize() << 3) | group;
                return output;
            }

            uint FragId(IdVaryings input, out float match : SV_Depth) : SV_Target
            {
                float slope = fwidth(EyeDepth(input.positionCS.z));
                float mismatch = DepthMismatch(input.positionCS.z, RawDepthAt(int2(input.positionCS.xy)), slope);
                if (mismatch > 1.0) discard;
                match = MatchDepth(mismatch);
                return input.surface;
            }
            ENDHLSL
        }
    }
}
