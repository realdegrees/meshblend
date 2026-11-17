using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace MeshBlending
{
    /// <summary>
    /// Softens the hard line where one surface meets another: a rock where it enters the terrain, a wall where it stands
    /// on the ground, two boulders pushed into each other. Each side of the seam fades into the other's own texture,
    /// so they meet in a blend instead of a cut.
    ///
    /// Which surfaces take part is set on <see cref="MeshBlendRendererFeature"/> by rendering layer. This override holds
    /// the look; nothing is drawn while <see cref="intensity"/> is zero.
    /// </summary>
    [Serializable]
    [VolumeComponentMenu("Mesh Blend")]
    [SupportedOnRenderPipeline(typeof(UniversalRenderPipelineAsset))]
    public sealed class MeshBlend : VolumeComponent, IPostProcessComponent
    {
        [Tooltip("How much of the other side is mixed in. Zero switches the effect off and records no passes.")]
        public ClampedFloatParameter intensity = new ClampedFloatParameter(0f, 0f, 1f);

        [Tooltip("Metres from the seam to where the band ends, on each side, where the two surfaces meet at a right " +
                 "angle or steeper (a wall on the ground, a boulder's side going into the terrain).")]
        public ClampedFloatParameter rightAngleRadius = new ClampedFloatParameter(0.06f, 0.01f, 2f);

        [Tooltip("Metres from the seam to where the band ends, on each side, where the two surfaces meet nearly flat " +
                 "(a slab lying in the ground, a ledge running out into a slope). Toward a right angle the band narrows " +
                 "as Flat Falloff sets.")]
        public ClampedFloatParameter flatRadius = new ClampedFloatParameter(0.5f, 0.01f, 2f);

        [Tooltip("How quickly the band narrows from the flat radius toward the right-angle radius as the surfaces meet " +
                 "steeper. 1 narrows it evenly with the angle; at the default 4 the flat radius holds only within a few " +
                 "degrees of flat (about 60% of it at 10 degrees) and a 45 degree contact is close to the right-angle " +
                 "radius.")]
        public ClampedFloatParameter flatFalloff = new ClampedFloatParameter(4f, 1f, 12f);

        [Tooltip("How much of the seam line shows through where the surfaces meet at a sharp angle: 0 blends it away " +
                 "completely, 1 keeps a right-angle seam's line in the last few pixels next to it, with the blend around it. " +
                 "Seams that meet flatter show less of it.")]
        public ClampedFloatParameter sharpSeams = new ClampedFloatParameter(0f, 0f, 1f);

        [Tooltip("How ragged the band's outer edge is: it wanders between (1 - noise) and (1 + noise) times the radius. " +
                 "Zero is an even band; the seam itself never moves.")]
        public ClampedFloatParameter noise = new ClampedFloatParameter(0.4f, 0f, 0.9f);

        [Tooltip("Metres across one patch of the raggedness. The pattern is fixed to the world, so it holds still as " +
                 "the camera moves.")]
        public ClampedFloatParameter noiseSize = new ClampedFloatParameter(0.1f, 0.02f, 4f);

        [Tooltip("How much of the screen-space ambient occlusion stays inside the band. The occlusion in the crease is " +
                 "the hard line itself; mixed across the seam it smears dark over both sides. Needs URP's SSAO.")]
        public ClampedFloatParameter occlusion = new ClampedFloatParameter(0.1f, 0f, 1f);

        [Tooltip("Metres from a contact over which the screen-space ambient occlusion is flattened, independent of the " +
                 "band. Set it to about your SSAO radius: the occlusion's dark halo around a contact is as wide as that, " +
                 "and past a narrow band it would be left as an edge of its own.")]
        public MinFloatParameter occlusionReach = new MinFloatParameter(0.5f, 0f);

        [Tooltip("Metres from the camera beyond which the blend has faded out.")]
        public MinFloatParameter maxDistance = new MinFloatParameter(100f, 1f);

        public bool IsActive() => intensity.value > 0f;
    }
}
