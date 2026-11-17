using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.RenderGraphModule;
using UnityEngine.Rendering.RenderGraphModule.Util;
using UnityEngine.Rendering.Universal;

namespace MeshBlending
{
    /// <summary>What <see cref="MeshBlendRendererFeature"/> draws instead of the blend, to check its setup.</summary>
    public enum MeshBlendDebugView
    {
        None,
        /// <summary>Every taking-part surface in a colour of its own, the ground in one dark brown.</summary>
        Ids,
        /// <summary>How much of the other side each pixel takes, in red over a grey frame.</summary>
        Weight,
    }

    /// <summary>
    /// A set of renderers, picked by rendering layer, that take part in the blend with one band and priority.
    /// </summary>
    [Serializable]
    public sealed class MeshBlendSurfaceGroup
    {
        [Tooltip("Shown in the blend matrix.")]
        public string name = "Group";

        [Tooltip("Renderers on any of these rendering layers belong to this group (the first group that matches).")]
        public RenderingLayerMask layers;

        [Range(0.05f, 1f)]
        [Tooltip("This group's share of the volume's band. Where two groups meet, the smaller share applies.")]
        public float bandShare = 1f;

        [Range(0, 3)]
        [Tooltip("Where two groups meet, the lower one fades into the higher one, which keeps its own colour (sand " +
                 "rising onto a rock while the rock's grey never spreads over the sand). Equal priorities meet in an " +
                 "even mix.")]
        public int priority;

        [Tooltip("Ground: drawn with the renderers' own DepthOnly pass instead of the id shader, and all of the group " +
                 "counts as one surface, so any ground shader works, Unity terrain included.")]
        public bool ground;

        [HideInInspector, Tooltip("The groups this one blends with, one bit per group index. Edited in the blend matrix.")]
        public int blendsWith = ~0;
    }

    /// <summary>
    /// Draws <see cref="MeshBlend"/>.
    ///
    /// Before the opaques it works out which surface each pixel belongs to: the taking-part renderers are drawn once
    /// more with an id shader (a hash of each object's position), and the ground renderers are drawn with their own
    /// depth pass so any ground shader, Unity terrain included, counts as one surface. Pixels next to a different surface
    /// they actually touch seed a seam map, a jump flood hands every taking-part pixel the nearest seam pixel on the
    /// other side, and the band holds URP's SSAO at the level of its outer edge. After the opaques the pixels beside
    /// a seam fade into the other surface's own pixels, mirrored across the seam; further out a surface keeps its own
    /// detail and lighting and takes on the other side's colour, over a band measured on the surfaces in the world.
    /// </summary>
    [DisallowMultipleRendererFeature("Mesh Blend")]
    public sealed class MeshBlendRendererFeature : ScriptableRendererFeature
    {
        const string ShaderName = "Hidden/MeshBlend";

        /// <summary>Overrides the feature's own <see cref="debugView"/> while it is not <c>None</c>, for a debug menu
        /// that should not edit the renderer asset.</summary>
        public static MeshBlendDebugView ForcedDebugView;

        [SerializeField, Tooltip("Hidden/MeshBlend. Kept as a reference so builds include it.")]
        Shader shader;

        /// <summary>The most surface groups the feature can tell apart.</summary>
        public const int MaxGroups = 7;

        [SerializeField, Tooltip("Which renderers take part and how, at most seven groups.")]
        List<MeshBlendSurfaceGroup> groups = new List<MeshBlendSurfaceGroup>
        {
            new MeshBlendSurfaceGroup { name = "Rocks", layers = 1u << 1, bandShare = 1f },
            new MeshBlendSurfaceGroup { name = "Buildings & Props", layers = 1u << 2, bandShare = 0.5f },
            new MeshBlendSurfaceGroup { name = "Ground", layers = 1u << 3, priority = 1, ground = true },
        };

        [SerializeField, Range(0.05f, 0.5f)]
        [Tooltip("How far the seam search reaches, as a share of the screen's height. A band wider than this on screen " +
                 "(very close up) fades out toward it. Every doubling costs one more short pass.")]
        float searchReach = 0.25f;

        [SerializeField, Tooltip("Draws a view of the setup instead of the blend.")]
        MeshBlendDebugView debugView = MeshBlendDebugView.None;

        Material _material;
        SeamPass _seamPass;
        BlendPass _blendPass;

        public override void Create()
        {
            ReleaseResources();
            if (shader == null) shader = Shader.Find(ShaderName);
            if (shader == null) return;
            _material = CoreUtils.CreateEngineMaterial(shader);
            _seamPass = new SeamPass(_material) { renderPassEvent = RenderPassEvent.BeforeRenderingOpaques };
            _blendPass = new BlendPass(_material) { renderPassEvent = RenderPassEvent.AfterRenderingOpaques };
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (_seamPass == null || _blendPass == null) return;
            ref CameraData cameraData = ref renderingData.cameraData;
            if (cameraData.cameraType != CameraType.Game && cameraData.cameraType != CameraType.SceneView) return;
            if (cameraData.renderType != CameraRenderType.Base) return;
            if (cameraData.camera.orthographic) return;
            if (groups == null || groups.Count == 0) return;

            MeshBlend settings = VolumeManager.instance.stack.GetComponent<MeshBlend>();
            if (settings == null || !settings.IsActive()) return;

            _seamPass.Setup(groups, searchReach,
                ForcedDebugView != MeshBlendDebugView.None ? ForcedDebugView : debugView);
            renderer.EnqueuePass(_seamPass);
            renderer.EnqueuePass(_blendPass);
        }

        protected override void Dispose(bool disposing)
        {
            ReleaseResources();
        }

        void ReleaseResources()
        {
            _seamPass = null;
            _blendPass = null;
            if (_material != null) CoreUtils.Destroy(_material);
            _material = null;
        }

#if UNITY_EDITOR
        void Reset()
        {
            shader = Shader.Find(ShaderName);
        }

        void OnValidate()
        {
            if (shader == null) shader = Shader.Find(ShaderName);
        }
#endif

        static readonly int IdsId = Shader.PropertyToID("_MeshBlendIds");
        static readonly int DepthId = Shader.PropertyToID("_MeshBlendDepth");
        static readonly int GroundDepthId = Shader.PropertyToID("_MeshBlendGroundDepth");
        static readonly int NormalsId = Shader.PropertyToID("_MeshBlendNormals");
        static readonly int SeamsId = Shader.PropertyToID("_MeshBlendSeams");
        static readonly int ColorId = Shader.PropertyToID("_MeshBlendColor");
        static readonly int MaskedId = Shader.PropertyToID("_MeshBlendMasked");
        static readonly int MaskedLowId = Shader.PropertyToID("_MeshBlendMaskedLow");
        static readonly int OcclusionSourceId = Shader.PropertyToID("_MeshBlendOcclusionSource");
        static readonly int SizeId = Shader.PropertyToID("_MeshBlendSize");
        static readonly int OcclusionSizeId = Shader.PropertyToID("_MeshBlendOcclusionSize");
        static readonly int ViewProjId = Shader.PropertyToID("_MeshBlendViewProj");
        static readonly int InvViewProjId = Shader.PropertyToID("_MeshBlendInvViewProj");
        static readonly int BandId = Shader.PropertyToID("_MeshBlendBand");
        static readonly int ShapeId = Shader.PropertyToID("_MeshBlendShape");
        static readonly int ExtraId = Shader.PropertyToID("_MeshBlendExtra");
        static readonly int GroupsId = Shader.PropertyToID("_MeshBlendGroups");
        static readonly int GroupLinksId = Shader.PropertyToID("_MeshBlendGroupLinks");
        static readonly int GroupCountId = Shader.PropertyToID("_MeshBlendGroupCount");
        static readonly int GroundGroupId = Shader.PropertyToID("_MeshBlendGroundGroup");
        static readonly int StepId = Shader.PropertyToID("_MeshBlendStep");
        static readonly int DebugId = Shader.PropertyToID("_MeshBlendDebug");

        const int SeedShaderPass = 0;
        const int FloodShaderPass = 1;
        const int BlendShaderPass = 2;
        const int OcclusionShaderPass = 3;
        const int GroundShaderPass = 4;
        const int IdShaderPass = 6;
        const int MaskedShaderPass = 5;

        struct Constants
        {
            public Vector4 size;
            public Matrix4x4 viewProjection;
            public Matrix4x4 invViewProjection;
            public Vector4 band;
            public Vector4 shape;
            public Vector4 extra;
            public Vector4[] groups;
            public Vector4[] groupLinks;
            public int groupCount;
            public int debug;
        }

        /// <summary>The seam map, from the pass before the opaques to the blend after them.</summary>
        sealed class SeamFrame : ContextItem
        {
            public TextureHandle ids;
            public TextureHandle seams;
            public Constants constants;

            public override void Reset()
            {
                ids = TextureHandle.nullHandle;
                seams = TextureHandle.nullHandle;
            }
        }

        sealed class MipData
        {
            public TextureHandle color;
        }

        sealed class PassData
        {
            public Material material;
            public Constants constants;
            public TextureHandle ids;
            public TextureHandle depth;
            public TextureHandle groundDepth;
            public TextureHandle normals;
            public TextureHandle seams;
            public TextureHandle color;
            public TextureHandle masked;
            public TextureHandle maskedLow;
            public RendererListHandle renderers;
            public Vector4 occlusionSize;
            public int step;
            public int groundGroup;
        }

        static void Bind(RasterCommandBuffer cmd, PassData d)
        {
            cmd.SetGlobalTexture(DepthId, d.depth);
            cmd.SetGlobalTexture(NormalsId, d.normals);
            cmd.SetGlobalVector(SizeId, d.constants.size);
            cmd.SetGlobalMatrix(ViewProjId, d.constants.viewProjection);
            cmd.SetGlobalMatrix(InvViewProjId, d.constants.invViewProjection);
            cmd.SetGlobalVector(BandId, d.constants.band);
            cmd.SetGlobalVector(ShapeId, d.constants.shape);
            cmd.SetGlobalVector(ExtraId, d.constants.extra);
            cmd.SetGlobalVectorArray(GroupsId, d.constants.groups);
            cmd.SetGlobalVectorArray(GroupLinksId, d.constants.groupLinks);
            cmd.SetGlobalInteger(GroupCountId, d.constants.groupCount);
            cmd.SetGlobalInteger(DebugId, d.constants.debug);
        }

        static void Draw(RasterCommandBuffer cmd, Material material, int pass)
        {
            cmd.DrawProcedural(Matrix4x4.identity, material, pass, MeshTopology.Triangles, 3, 1);
        }

        sealed class SeamPass : ScriptableRenderPass
        {
            // Here rather than on the feature: a ScriptableObject's static initializer may not create shader tags.
            static readonly List<ShaderTagId> SurfaceTags = new List<ShaderTagId>
            {
                new ShaderTagId("UniversalForward"), new ShaderTagId("UniversalForwardOnly"),
                new ShaderTagId("SRPDefaultUnlit"),
            };

            static readonly List<ShaderTagId> DepthOnlyTags = new List<ShaderTagId> { new ShaderTagId("DepthOnly") };

            readonly Material _material;
            readonly Vector4[] _groups = new Vector4[8];
            readonly Vector4[] _groupLinks = new Vector4[8];
            readonly List<(int index, uint layers)> _grounds = new List<(int, uint)>();
            int _groupCount;
            uint _surfaceLayers;
            float _reach;
            MeshBlendDebugView _debug;

            public SeamPass(Material material)
            {
                _material = material;
                profilingSampler = new ProfilingSampler("Mesh Blend Seams");
                ConfigureInput(ScriptableRenderPassInput.Depth | ScriptableRenderPassInput.Normal);
            }

            public void Setup(List<MeshBlendSurfaceGroup> groups, float reach, MeshBlendDebugView debug)
            {
                _groupCount = Mathf.Min(groups.Count, MaxGroups);
                _surfaceLayers = 0u;
                _grounds.Clear();
                int lowest = int.MaxValue;
                int highest = int.MinValue;
                for (int i = 0; i < _groupCount; i++)
                {
                    lowest = Mathf.Min(lowest, groups[i].priority);
                    highest = Mathf.Max(highest, groups[i].priority);
                }
                for (int i = 0; i < _groupCount; i++)
                {
                    MeshBlendSurfaceGroup group = groups[i];
                    uint layers = group.layers.value;
                    _groups[i] = new Vector4(layers & 0xFFFFu, layers >> 16, group.bandShare, group.priority);
                    // A group blends with another only when both say so, so the matrix reads the same either way.
                    int mask = 0;
                    for (int j = 0; j < _groupCount; j++)
                        if ((group.blendsWith & (1 << j)) != 0 && (groups[j].blendsWith & (1 << i)) != 0)
                            mask |= 1 << j;
                    // Its weight in the two masked copies: 256 times per step of priority, counted down from the
                    // highest in one and up from the lowest in the other, so neither outgrows a half float.
                    _groupLinks[i] = new Vector4(mask, group.ground ? 1f : 0f,
                        Mathf.Pow(2f, 8f * (group.priority - highest)), Mathf.Pow(2f, 8f * (lowest - group.priority)));
                    if (group.ground) _grounds.Add((i, layers));
                    else _surfaceLayers |= layers;
                }
                _reach = reach;
                _debug = debug;
            }

            public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
            {
                UniversalResourceData resources = frameData.Get<UniversalResourceData>();
                if (!resources.cameraDepthTexture.IsValid() || !resources.cameraNormalsTexture.IsValid()) return;

                MeshBlend settings = VolumeManager.instance.stack.GetComponent<MeshBlend>();
                if (settings == null) return;

                UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
                UniversalRenderingData renderingData = frameData.Get<UniversalRenderingData>();
                UniversalLightData lightData = frameData.Get<UniversalLightData>();
                RenderTextureDescriptor target = cameraData.cameraTargetDescriptor;
                int width = target.width;
                int height = target.height;

                // The camera textures these passes read were drawn into intermediate textures, with the projection
                // flipped as for any render target, so the inverse has to be of that flipped projection or every
                // rebuilt position mirrors vertically.
                Matrix4x4 projection = cameraData.GetProjectionMatrix();
                Matrix4x4 viewProjection = GL.GetGPUProjectionMatrix(projection, true) * cameraData.GetViewMatrix();
                float pixelsPerMetre = 0.5f * height * projection.m11;
                float maxPixels = Mathf.Max(2f, _reach * height);

                var constants = new Constants
                {
                    size = new Vector4(width, height, 1f / width, 1f / height),
                    viewProjection = viewProjection,
                    invViewProjection = viewProjection.inverse,
                    band = new Vector4(settings.rightAngleRadius.value, settings.flatRadius.value, pixelsPerMetre,
                        maxPixels),
                    shape = new Vector4(settings.intensity.value, settings.noise.value, 1f / settings.noiseSize.value,
                        settings.maxDistance.value),
                    extra = new Vector4(settings.flatFalloff.value, settings.occlusion.value, settings.occlusionReach.value, settings.sharpSeams.value),
                    groups = _groups,
                    groupLinks = _groupLinks,
                    groupCount = _groupCount,
                    debug = (int)_debug,
                };

                var idDesc = new TextureDesc(width, height)
                {
                    format = GraphicsFormat.R32_UInt,
                    filterMode = FilterMode.Point,
                    wrapMode = TextureWrapMode.Clamp,
                    clearBuffer = true,
                    clearColor = Color.clear,
                    msaaSamples = MSAASamples.None,
                    name = "Mesh Blend Ids",
                };
                TextureHandle ids = renderGraph.CreateTexture(idDesc);
                // How well the surface each id came from matches the camera's depth there, so the best match keeps the
                // pixel when two lie within the tolerance of it.
                TextureHandle idMatch = renderGraph.CreateTexture(new TextureDesc(width, height)
                {
                    format = GraphicsFormat.D32_SFloat,
                    clearBuffer = true,
                    msaaSamples = MSAASamples.None,
                    name = "Mesh Blend Id Match",
                });

                // Each ground group is drawn with its own depth pass and marked where it is what the camera sees; the
                // other taking-part surfaces are drawn over them.
                foreach ((int index, uint layers) in _grounds)
                {
                    var groundDesc = new TextureDesc(width, height)
                    {
                        format = GraphicsFormat.D32_SFloat,
                        clearBuffer = true,
                        msaaSamples = MSAASamples.None,
                        name = "Mesh Blend Ground Depth",
                    };
                    TextureHandle groundDepth = renderGraph.CreateTexture(groundDesc);

                    using (IRasterRenderGraphBuilder builder =
                           renderGraph.AddRasterRenderPass("Mesh Blend Ground", out PassData data, profilingSampler))
                    {
                        DrawingSettings drawing = RenderingUtils.CreateDrawingSettings(DepthOnlyTags, renderingData,
                            cameraData, lightData, SortingCriteria.CommonOpaque);
                        var filtering = new FilteringSettings(RenderQueueRange.opaque, renderingLayerMask: layers);
                        RendererListHandle list = renderGraph.CreateRendererList(
                            new RendererListParams(renderingData.cullResults, drawing, filtering));
                        data.renderers = list;
                        builder.UseRendererList(list);
                        builder.SetRenderAttachmentDepth(groundDepth, AccessFlags.Write);
                        builder.SetRenderFunc(static (PassData d, RasterGraphContext context) =>
                            context.cmd.DrawRendererList(d.renderers));
                    }

                    using (IRasterRenderGraphBuilder builder =
                           renderGraph.AddRasterRenderPass("Mesh Blend Ground Ids", out PassData data, profilingSampler))
                    {
                        Fill(data, constants, resources);
                        data.groundDepth = groundDepth;
                        data.groundGroup = index + 1;
                        builder.UseTexture(data.depth);
                        builder.UseTexture(data.normals);
                        builder.UseTexture(groundDepth);
                        builder.SetRenderAttachment(ids, 0, AccessFlags.ReadWrite);
                        builder.SetRenderAttachmentDepth(idMatch, AccessFlags.ReadWrite);
                        builder.AllowGlobalStateModification(true);
                        builder.SetRenderFunc(static (PassData d, RasterGraphContext context) =>
                        {
                            Bind(context.cmd, d);
                            context.cmd.SetGlobalTexture(GroundDepthId, d.groundDepth);
                            context.cmd.SetGlobalInteger(GroundGroupId, d.groundGroup);
                            Draw(context.cmd, d.material, GroundShaderPass);
                        });
                    }
                }

                using (IRasterRenderGraphBuilder builder =
                       renderGraph.AddRasterRenderPass("Mesh Blend Surface Ids", out PassData data, profilingSampler))
                {
                    DrawingSettings drawing = RenderingUtils.CreateDrawingSettings(SurfaceTags, renderingData,
                        cameraData, lightData, SortingCriteria.CommonOpaque);
                    drawing.overrideMaterial = _material;
                    drawing.overrideMaterialPassIndex = IdShaderPass;
                    var filtering = new FilteringSettings(RenderQueueRange.opaque, renderingLayerMask: _surfaceLayers);
                    RendererListHandle list = renderGraph.CreateRendererList(
                        new RendererListParams(renderingData.cullResults, drawing, filtering));

                    Fill(data, constants, resources);
                    data.renderers = list;
                    builder.UseRendererList(list);
                    builder.UseTexture(data.depth);
                    builder.UseTexture(data.normals);
                    builder.SetRenderAttachment(ids, 0, AccessFlags.ReadWrite);
                    builder.SetRenderAttachmentDepth(idMatch, AccessFlags.ReadWrite);
                    builder.AllowGlobalStateModification(true);
                    builder.SetRenderFunc(static (PassData d, RasterGraphContext context) =>
                    {
                        Bind(context.cmd, d);
                        context.cmd.DrawRendererList(d.renderers);
                    });
                }

                var seamDesc = new TextureDesc(width, height)
                {
                    format = GraphicsFormat.R16G16B16A16_UInt,
                    filterMode = FilterMode.Point,
                    wrapMode = TextureWrapMode.Clamp,
                    clearBuffer = false,
                    msaaSamples = MSAASamples.None,
                    name = "Mesh Blend Seams A",
                };
                TextureHandle seamsA = renderGraph.CreateTexture(seamDesc);
                seamDesc.name = "Mesh Blend Seams B";
                TextureHandle seamsB = renderGraph.CreateTexture(seamDesc);

                using (IRasterRenderGraphBuilder builder =
                       renderGraph.AddRasterRenderPass("Mesh Blend Seed", out PassData data, profilingSampler))
                {
                    Fill(data, constants, resources);
                    data.ids = ids;
                    builder.UseTexture(ids);
                    builder.UseTexture(data.depth);
                    builder.UseTexture(data.normals);
                    builder.SetRenderAttachment(seamsA, 0, AccessFlags.Write);
                    builder.AllowGlobalStateModification(true);
                    builder.SetRenderFunc(static (PassData d, RasterGraphContext context) =>
                    {
                        Bind(context.cmd, d);
                        context.cmd.SetGlobalTexture(IdsId, d.ids);
                        Draw(context.cmd, d.material, SeedShaderPass);
                    });
                }

                // Halving steps down to one, then two more at 2 and 1: the plain jump flood now and then hands a pixel a
                // seam pixel further than the nearest, which shows as a step in the band, and the two extra passes catch
                // nearly all of those.
                int firstStep = Mathf.Max(1, Mathf.NextPowerOfTwo(Mathf.CeilToInt(maxPixels)) / 2);
                int halvings = (int)Mathf.Log(firstStep, 2f) + 1;

                TextureHandle source = seamsA;
                TextureHandle destination = seamsB;
                for (int pass = 0; pass < halvings + 2; pass++)
                {
                    int step = pass < halvings ? firstStep >> pass : (pass == halvings ? 2 : 1);
                    using IRasterRenderGraphBuilder builder =
                        renderGraph.AddRasterRenderPass("Mesh Blend Flood", out PassData data, profilingSampler);
                    Fill(data, constants, resources);
                    data.ids = ids;
                    data.seams = source;
                    data.step = step;
                    builder.UseTexture(ids);
                    builder.UseTexture(data.depth);
                    builder.UseTexture(data.normals);
                    builder.UseTexture(source);
                    builder.SetRenderAttachment(destination, 0, AccessFlags.Write);
                    builder.AllowGlobalStateModification(true);
                    builder.SetRenderFunc(static (PassData d, RasterGraphContext context) =>
                    {
                        Bind(context.cmd, d);
                        context.cmd.SetGlobalTexture(IdsId, d.ids);
                        context.cmd.SetGlobalTexture(SeamsId, d.seams);
                        context.cmd.SetGlobalInteger(StepId, d.step);
                        Draw(context.cmd, d.material, FloodShaderPass);
                    });
                    (source, destination) = (destination, source);
                }

                if (resources.ssaoTexture.IsValid() && constants.extra.y < 1f)
                {
                    TextureDesc occlusionDesc = renderGraph.GetTextureDesc(resources.ssaoTexture);
                    occlusionDesc.name = "Mesh Blend Occlusion Source";
                    occlusionDesc.clearBuffer = false;
                    occlusionDesc.filterMode = FilterMode.Bilinear;
                    TextureHandle occlusionCopy = renderGraph.CreateTexture(occlusionDesc);
                    renderGraph.AddBlitPass(resources.ssaoTexture, occlusionCopy, Vector2.one, Vector2.zero,
                        passName: "Mesh Blend Occlusion Copy");

                    using IRasterRenderGraphBuilder builder =
                        renderGraph.AddRasterRenderPass("Mesh Blend Occlusion", out PassData data, profilingSampler);
                    Fill(data, constants, resources);
                    data.ids = ids;
                    data.seams = source;
                    data.color = occlusionCopy;
                    data.occlusionSize = new Vector4(occlusionDesc.width, occlusionDesc.height, 0f, 0f);
                    builder.UseTexture(ids);
                    builder.UseTexture(data.depth);
                    builder.UseTexture(data.normals);
                    builder.UseTexture(source);
                    builder.UseTexture(occlusionCopy);
                    builder.SetRenderAttachment(resources.ssaoTexture, 0, AccessFlags.ReadWrite);
                    builder.AllowGlobalStateModification(true);
                    builder.SetRenderFunc(static (PassData d, RasterGraphContext context) =>
                    {
                        Bind(context.cmd, d);
                        context.cmd.SetGlobalTexture(IdsId, d.ids);
                        context.cmd.SetGlobalTexture(SeamsId, d.seams);
                        context.cmd.SetGlobalVector(OcclusionSizeId, d.occlusionSize);
                        context.cmd.SetGlobalTexture(OcclusionSourceId, d.color);
                        Draw(context.cmd, d.material, OcclusionShaderPass);
                    });
                }

                SeamFrame frame = frameData.Create<SeamFrame>();
                frame.ids = ids;
                frame.seams = source;
                frame.constants = constants;
            }

            void Fill(PassData data, in Constants constants, UniversalResourceData resources)
            {
                data.material = _material;
                data.constants = constants;
                data.depth = resources.cameraDepthTexture;
                data.normals = resources.cameraNormalsTexture;
            }
        }

        sealed class BlendPass : ScriptableRenderPass
        {
            readonly Material _material;

            public BlendPass(Material material)
            {
                _material = material;
                profilingSampler = new ProfilingSampler("Mesh Blend");
                ConfigureInput(ScriptableRenderPassInput.Depth | ScriptableRenderPassInput.Normal);
            }

            public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
            {
                if (!frameData.Contains<SeamFrame>()) return;
                SeamFrame frame = frameData.Get<SeamFrame>();
                if (!frame.seams.IsValid()) return;

                UniversalResourceData resources = frameData.Get<UniversalResourceData>();
                if (resources.isActiveTargetBackBuffer || !resources.activeColorTexture.IsValid()) return;
                RenderTextureDescriptor target = frameData.Get<UniversalCameraData>().cameraTargetDescriptor;

                TextureDesc colorDesc = renderGraph.GetTextureDesc(resources.activeColorTexture);
                colorDesc.name = "Mesh Blend Color";
                colorDesc.msaaSamples = MSAASamples.None;
                colorDesc.bindTextureMS = false;
                colorDesc.clearBuffer = false;
                colorDesc.filterMode = FilterMode.Point;
                colorDesc.useMipMap = false;
                colorDesc.autoGenerateMips = false;
                TextureHandle colorCopy = renderGraph.CreateTexture(colorDesc);
                renderGraph.AddBlitPass(resources.activeColorTexture, colorCopy, Vector2.one, Vector2.zero,
                    passName: "Mesh Blend Copy");

                // Two copies of the frame at half size with everything that does not take part weighted out (grass,
                // water, characters, the sky), one where the higher priorities outweigh the lower and one the other
                // way round. A blur of either divides by the weight it gathered, and their levels of detail let a blur
                // of any width read a handful of samples.
                TextureDesc maskedDesc = colorDesc;
                maskedDesc.name = "Mesh Blend Masked Color";
                maskedDesc.sizeMode = TextureSizeMode.Explicit;
                maskedDesc.width = Mathf.Max(1, (target.width + 1) / 2);
                maskedDesc.height = Mathf.Max(1, (target.height + 1) / 2);
                maskedDesc.format = GraphicsFormat.R16G16B16A16_SFloat;
                maskedDesc.filterMode = FilterMode.Trilinear;
                maskedDesc.useMipMap = true;
                maskedDesc.autoGenerateMips = false;
                TextureHandle masked = renderGraph.CreateTexture(maskedDesc);
                maskedDesc.name = "Mesh Blend Masked Color Low";
                TextureHandle maskedLow = renderGraph.CreateTexture(maskedDesc);
                using (IRasterRenderGraphBuilder maskBuilder =
                    renderGraph.AddRasterRenderPass("Mesh Blend Masked Copy", out PassData maskData, profilingSampler))
                {
                    maskData.material = _material;
                    maskData.constants = frame.constants;
                    maskData.ids = frame.ids;
                    maskData.depth = resources.cameraDepthTexture;
                    maskData.normals = resources.cameraNormalsTexture;
                    maskData.seams = frame.seams;
                    maskData.color = colorCopy;
                    maskBuilder.UseTexture(maskData.ids);
                    maskBuilder.UseTexture(maskData.depth);
                    maskBuilder.UseTexture(maskData.normals);
                    maskBuilder.UseTexture(maskData.seams);
                    maskBuilder.UseTexture(colorCopy);
                    maskBuilder.SetRenderAttachment(masked, 0, AccessFlags.Write);
                    maskBuilder.SetRenderAttachment(maskedLow, 1, AccessFlags.Write);
                    maskBuilder.AllowGlobalStateModification(true);
                    maskBuilder.SetRenderFunc(static (PassData d, RasterGraphContext context) =>
                    {
                        Bind(context.cmd, d);
                        context.cmd.SetGlobalTexture(IdsId, d.ids);
                        context.cmd.SetGlobalTexture(SeamsId, d.seams);
                        context.cmd.SetGlobalTexture(ColorId, d.color);
                        Draw(context.cmd, d.material, MaskedShaderPass);
                    });
                }
                foreach (TextureHandle copy in new[] { masked, maskedLow })
                {
                    using IUnsafeRenderGraphBuilder mips =
                        renderGraph.AddUnsafePass("Mesh Blend Masked Mips", out MipData mipData, profilingSampler);
                    mipData.color = copy;
                    mips.UseTexture(copy, AccessFlags.ReadWrite);
                    mips.SetRenderFunc(static (MipData d, UnsafeGraphContext context) =>
                        CommandBufferHelpers.GetNativeCommandBuffer(context.cmd).GenerateMips(d.color));
                }

                using IRasterRenderGraphBuilder builder =
                    renderGraph.AddRasterRenderPass("Mesh Blend", out PassData data, profilingSampler);
                data.material = _material;
                data.constants = frame.constants;
                data.ids = frame.ids;
                data.depth = resources.cameraDepthTexture;
                data.normals = resources.cameraNormalsTexture;
                data.seams = frame.seams;
                data.color = colorCopy;
                data.masked = masked;
                data.maskedLow = maskedLow;
                builder.UseTexture(data.ids);
                builder.UseTexture(data.depth);
                builder.UseTexture(data.normals);
                builder.UseTexture(data.seams);
                builder.UseTexture(colorCopy);
                builder.UseTexture(masked);
                builder.UseTexture(maskedLow);
                builder.SetRenderAttachment(resources.activeColorTexture, 0, AccessFlags.ReadWrite);
                builder.AllowGlobalStateModification(true);
                builder.SetRenderFunc(static (PassData d, RasterGraphContext context) =>
                {
                    Bind(context.cmd, d);
                    context.cmd.SetGlobalTexture(IdsId, d.ids);
                    context.cmd.SetGlobalTexture(SeamsId, d.seams);
                    context.cmd.SetGlobalTexture(ColorId, d.color);
                    context.cmd.SetGlobalTexture(MaskedId, d.masked);
                    context.cmd.SetGlobalTexture(MaskedLowId, d.maskedLow);
                    Draw(context.cmd, d.material, BlendShaderPass);
                });
            }
        }
    }
}
