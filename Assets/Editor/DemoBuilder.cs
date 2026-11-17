using System.IO;
using System.Linq;
using MeshBlending;
using UnityEditor;
using UnityEditor.Rendering;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

/// <summary>
/// Builds this repository's demo, the project's URP setup and the raw README captures. Not part of the package. The
/// demo's one committed copy is the package's <c>Samples~/Demo</c>, which Unity does not import; it is edited as a copy
/// under <see cref="Demo"/> and written back by <see cref="SaveDemoIntoPackage"/>. Run from the menu (Mesh Blend ▸ ...)
/// or headless: <c>Unity -batchmode -projectPath . -executeMethod DemoBuilder.BuildAll -quit</c>, then
/// <c>python tools/readme_images.py</c> composes the README's animation from the captures.
/// </summary>
public static class DemoBuilder
{
    const string Demo = "Assets/Samples/Mesh Blend/Demo";
    const string PackageDemo = "Packages/com.realdegrees.meshblend/Samples~/Demo";
    const string ScenePath = Demo + "/MeshBlendDemo.unity";
    const string RawFolder = "docs/images/raw";

    // The feature's default surface groups: rocks, buildings and props, ground.
    const int RockLayer = 1;
    const int GroundLayer = 3;

    // The ground each patch is painted with, in order along the terrain.
    static readonly string[] Grounds = { "Grass", "Dirt", "Sand" };
    const float PatchSpacing = 30f;
    // A patch's width of the outer grounds runs on past either end, so no view of a patch sees the terrain end.
    const float TerrainWidth = PatchSpacing * 5f;
    const float TerrainDepth = 96f;

    // The cluster every patch gets: model, offset from the patch's centre (x, z), yaw, lean, share of the height sunk
    // into the ground, scale. The stones clip into the boulder and into each other, the pillar leans into the boulder's
    // back, and the slab lies almost flat, so the cluster shows rock against rock and contacts at every angle.
    static readonly (string model, Vector2 at, float yaw, float lean, float sink, float scale)[] Cluster =
    {
        ("Boulder", new Vector2(0f, 0f), 20f, 0f, 0.3f, 0.7f),
        ("Stone", new Vector2(1.05f, -0.55f), 0f, 0f, 0.3f, 1f),
        ("Stone", new Vector2(1.75f, -1.05f), 120f, 8f, 0.3f, 0.75f),
        ("Slab", new Vector2(-2.3f, 0.5f), 65f, 4f, 0.6f, 0.8f),
        ("Pillar", new Vector2(0.55f, 1.25f), 10f, 14f, 0.2f, 0.55f),
    };

    [MenuItem("Mesh Blend/Build Everything")]
    public static void BuildAll()
    {
        OpenDemoForEditing();
        SetupProject();
        BuildScene();
        CaptureImages();
        SaveDemoIntoPackage();
    }

    /// <summary>Copies the package's demo into the project, where it can be edited, unless a copy is already there.
    /// </summary>
    [MenuItem("Mesh Blend/Open Demo For Editing")]
    public static void OpenDemoForEditing()
    {
        if (Directory.Exists(Demo)) return;
        CopyFolder(PackageDemo, Demo);
        AssetDatabase.Refresh(ImportAssetOptions.ForceSynchronousImport);
    }

    /// <summary>Replaces the package's demo with the edited copy, .meta files included so every reference holds.
    /// </summary>
    [MenuItem("Mesh Blend/Save Demo Into Package")]
    public static void SaveDemoIntoPackage()
    {
        AssetDatabase.SaveAssets();
        if (Directory.Exists(PackageDemo)) Directory.Delete(PackageDemo, true);
        CopyFolder(Demo, PackageDemo);
    }

    static void CopyFolder(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (string file in Directory.GetFiles(from))
            File.Copy(file, Path.Combine(to, Path.GetFileName(file)), true);
        foreach (string folder in Directory.GetDirectories(from))
            CopyFolder(folder, Path.Combine(to, Path.GetFileName(folder)));
    }

    [MenuItem("Mesh Blend/Set Up Project")]
    public static void SetupProject()
    {
        string[] names = { "Mesh Blend", "Mesh Blend Narrow", "Mesh Blend Ground" };
        for (int i = 0; i < names.Length; i++)
            if (RenderingLayerMask.GetMask(names[i]) == 0 && !RenderPipelineEditorUtility.TrySetRenderingLayerName(i + 1, names[i]))
                RenderPipelineEditorUtility.TryAddRenderingLayerName(names[i]);

        PlayerSettings.colorSpace = ColorSpace.Linear;

        EnsureFolder("Assets/Settings");
        const string rendererPath = "Assets/Settings/URP_Renderer.asset";
        const string pipelinePath = "Assets/Settings/URP.asset";
        var renderer = AssetDatabase.LoadAssetAtPath<UniversalRendererData>(rendererPath);
        if (renderer == null)
        {
            renderer = ScriptableObject.CreateInstance<UniversalRendererData>();
            AssetDatabase.CreateAsset(renderer, rendererPath);
        }

        AddFeature<ScreenSpaceAmbientOcclusion>(renderer, "SSAO");
        MeshBlendRendererFeature blend = AddFeature<MeshBlendRendererFeature>(renderer, "Mesh Blend");
        var so = new SerializedObject(blend);
        so.FindProperty("shader").objectReferenceValue = Shader.Find("Hidden/MeshBlend");
        so.ApplyModifiedPropertiesWithoutUndo();
        EditorUtility.SetDirty(renderer);

        var pipeline = AssetDatabase.LoadAssetAtPath<UniversalRenderPipelineAsset>(pipelinePath);
        if (pipeline == null)
        {
            pipeline = UniversalRenderPipelineAsset.Create(renderer);
            AssetDatabase.CreateAsset(pipeline, pipelinePath);
        }
        pipeline.msaaSampleCount = 4;
        pipeline.shadowDistance = 60f;
        EditorUtility.SetDirty(pipeline);

        GraphicsSettings.defaultRenderPipeline = pipeline;
        for (int i = 0; i < QualitySettings.names.Length; i++)
        {
            QualitySettings.SetQualityLevel(i, false);
            QualitySettings.renderPipeline = pipeline;
        }
        AssetDatabase.SaveAssets();
    }

    static T AddFeature<T>(UniversalRendererData renderer, string name) where T : ScriptableRendererFeature
    {
        T existing = renderer.rendererFeatures.OfType<T>().FirstOrDefault();
        if (existing != null) return existing;

        T feature = ScriptableObject.CreateInstance<T>();
        feature.name = name;
        AssetDatabase.AddObjectToAsset(feature, renderer);
        AssetDatabase.TryGetGUIDAndLocalFileIdentifier(feature, out _, out long localId);
        var so = new SerializedObject(renderer);
        SerializedProperty list = so.FindProperty("m_RendererFeatures");
        SerializedProperty map = so.FindProperty("m_RendererFeatureMap");
        list.arraySize++;
        list.GetArrayElementAtIndex(list.arraySize - 1).objectReferenceValue = feature;
        map.arraySize++;
        map.GetArrayElementAtIndex(map.arraySize - 1).longValue = localId;
        so.ApplyModifiedPropertiesWithoutUndo();
        return feature;
    }

    [MenuItem("Mesh Blend/Build Demo Scene")]
    public static void BuildScene()
    {
        OpenDemoForEditing();
        foreach (string texture in new[] { "Rock" }.Concat(Grounds))
        {
            var importer = (TextureImporter)AssetImporter.GetAtPath($"{Demo}/Textures/{texture}_Normal.jpg");
            if (importer.textureType == TextureImporterType.NormalMap) continue;
            importer.textureType = TextureImporterType.NormalMap;
            importer.SaveAndReimport();
        }

        EnsureFolder(Demo + "/Materials");
        Material rock = RockMaterial();
        TerrainLayer[] layers = Grounds.Select(Layer).ToArray();

        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

        var sun = new GameObject("Sun").AddComponent<Light>();
        sun.type = LightType.Directional;
        sun.intensity = 1.6f;
        sun.color = new Color(1f, 0.96f, 0.9f);
        sun.shadows = LightShadows.Soft;
        sun.transform.rotation = Quaternion.Euler(38f, -35f, 0f);
        RenderSettings.sun = sun;
        RenderSettings.ambientMode = AmbientMode.Trilight;
        RenderSettings.ambientSkyColor = new Color(0.62f, 0.7f, 0.82f);
        RenderSettings.ambientEquatorColor = new Color(0.45f, 0.46f, 0.42f);
        RenderSettings.ambientGroundColor = new Color(0.25f, 0.22f, 0.18f);
        RenderSettings.fog = true;
        RenderSettings.fogMode = FogMode.ExponentialSquared;
        RenderSettings.fogDensity = 0.018f;
        RenderSettings.fogColor = new Color(0.74f, 0.79f, 0.85f);

        Terrain terrain = BuildTerrain(layers);

        var rocks = new GameObject("Rocks").transform;
        for (int patch = 0; patch < Grounds.Length; patch++)
        {
            var group = new GameObject(Grounds[patch]).transform;
            group.SetParent(rocks, false);
            foreach (var (model, at, yaw, lean, sink, scale) in Cluster)
                PlaceRock(model, rock, terrain, group, PatchCentre(patch) + at, yaw, lean, sink, scale);
        }

        var volume = new GameObject("Global Volume").AddComponent<Volume>();
        volume.isGlobal = true;
        volume.sharedProfile = Profile();

        var camera = new GameObject("Main Camera").AddComponent<Camera>();
        camera.tag = "MainCamera";
        camera.fieldOfView = 45f;
        camera.nearClipPlane = 0.05f;
        camera.gameObject.AddComponent<UniversalAdditionalCameraData>().renderPostProcessing = true;
        (Vector3 position, Vector3 target) = PatchView(terrain, 0);
        camera.transform.position = position;
        camera.transform.LookAt(target);

        EditorSceneManager.SaveScene(UnityEngine.SceneManagement.SceneManager.GetActiveScene(), ScenePath);
        EditorBuildSettings.scenes = new EditorBuildSettingsScene[0];
    }

    static Vector2 PatchCentre(int patch) => new Vector2(PatchSpacing * (patch + 1.5f), 24f);

    static Vector3 OnTerrain(Terrain terrain, Vector2 at, float above)
    {
        Vector3 world = terrain.transform.position + new Vector3(at.x, 0f, at.y);
        world.y = terrain.SampleHeight(world) + terrain.transform.position.y + above;
        return world;
    }

    // The camera for one patch's cluster: in front of it and looking down on it, with the whole cluster in a 4:3 frame
    // and no sky.
    static (Vector3 position, Vector3 target) PatchView(Terrain terrain, int patch)
    {
        Vector2 centre = PatchCentre(patch);
        return (OnTerrain(terrain, centre + new Vector2(0.2f, -5.2f), 3.9f), OnTerrain(terrain, centre + new Vector2(-0.25f, 0.2f), 0.2f));
    }

    static Material RockMaterial()
    {
        string path = $"{Demo}/Materials/Rock.mat";
        var material = AssetDatabase.LoadAssetAtPath<Material>(path);
        if (material == null)
        {
            material = new Material(Shader.Find("Universal Render Pipeline/Lit"));
            AssetDatabase.CreateAsset(material, path);
        }
        material.SetTexture("_BaseMap", AssetDatabase.LoadAssetAtPath<Texture2D>($"{Demo}/Textures/Rock_Color.jpg"));
        material.SetTexture("_BumpMap", AssetDatabase.LoadAssetAtPath<Texture2D>($"{Demo}/Textures/Rock_Normal.jpg"));
        material.EnableKeyword("_NORMALMAP");
        material.SetFloat("_Smoothness", 0.25f);
        EditorUtility.SetDirty(material);
        return material;
    }

    static TerrainLayer Layer(string name)
    {
        string path = $"{Demo}/Materials/{name}.terrainlayer";
        var layer = AssetDatabase.LoadAssetAtPath<TerrainLayer>(path);
        if (layer == null)
        {
            layer = new TerrainLayer();
            AssetDatabase.CreateAsset(layer, path);
        }
        layer.diffuseTexture = AssetDatabase.LoadAssetAtPath<Texture2D>($"{Demo}/Textures/{name}_Color.jpg");
        layer.normalMapTexture = AssetDatabase.LoadAssetAtPath<Texture2D>($"{Demo}/Textures/{name}_Normal.jpg");
        layer.tileSize = new Vector2(3.5f, 3.5f);
        layer.smoothness = 0.05f;
        EditorUtility.SetDirty(layer);
        return layer;
    }

    // Gentle rolling ground, one patch of each layer along it with a soft border between them.
    static Terrain BuildTerrain(TerrainLayer[] layers)
    {
        string path = $"{Demo}/Terrain.asset";
        AssetDatabase.DeleteAsset(path);
        var data = new TerrainData { heightmapResolution = 257, alphamapResolution = 512 };
        data.size = new Vector3(TerrainWidth, 8f, TerrainDepth);
        AssetDatabase.CreateAsset(data, path);
        data.terrainLayers = layers;

        // The ground's shape repeats every patch, so every patch's cluster stands on the same ground and is seen the
        // same way: only the texture differs between them.
        int res = data.heightmapResolution;
        var heights = new float[res, res];
        for (int z = 0; z < res; z++)
        for (int x = 0; x < res; x++)
        {
            float u = x / (float)(res - 1) * TerrainWidth / PatchSpacing * 2f * Mathf.PI;
            float v = z / (float)(res - 1) * TerrainDepth;
            float h = 1f + 0.35f * Mathf.Sin(u + 0.6f) * Mathf.Cos(v * 0.11f)
                + 0.12f * Mathf.Sin(2f * u + 1.7f) * Mathf.Sin(v * 0.31f + 0.4f)
                + 0.04f * Mathf.Sin(5f * u + 0.3f) * Mathf.Cos(v * 0.9f);
            heights[z, x] = h / data.size.y;
        }
        data.SetHeights(0, 0, heights);

        int ares = data.alphamapResolution;
        var splat = new float[ares, ares, layers.Length];
        for (int z = 0; z < ares; z++)
        for (int x = 0; x < ares; x++)
        {
            float u = x / (float)ares * TerrainWidth;
            float total = 0f;
            var weights = new float[layers.Length];
            for (int i = 0; i < layers.Length; i++)
            {
                float offset = u - PatchCentre(i).x;
                if ((i == 0 && offset < 0f) || (i == layers.Length - 1 && offset > 0f)) offset = 0f;
                float d = Mathf.Abs(offset) / (PatchSpacing * 0.5f);
                weights[i] = Mathf.Clamp01((1.2f - d) / 0.4f);
                total += weights[i];
            }
            for (int i = 0; i < layers.Length; i++) splat[z, x, i] = weights[i] / Mathf.Max(total, 1e-4f);
        }
        data.SetAlphamaps(0, 0, splat);
        EditorUtility.SetDirty(data);

        GameObject go = Terrain.CreateTerrainGameObject(data);
        go.name = "Terrain";
        var terrain = go.GetComponent<Terrain>();
        terrain.renderingLayerMask = 1u | (1u << GroundLayer);
        return terrain;
    }

    static void PlaceRock(string model, Material material, Terrain terrain, Transform parent, Vector2 at, float yaw,
        float lean, float sink, float scale)
    {
        var prefab = AssetDatabase.LoadAssetAtPath<GameObject>($"{Demo}/Models/{model}.fbx");
        var rock = (GameObject)PrefabUtility.InstantiatePrefab(prefab, parent);
        rock.transform.rotation = Quaternion.Euler(lean, yaw, 0f);
        rock.transform.localScale = Vector3.one * scale;
        foreach (var renderer in rock.GetComponentsInChildren<MeshRenderer>())
        {
            renderer.sharedMaterial = material;
            renderer.renderingLayerMask = 1u | (1u << RockLayer);
        }

        Bounds bounds = rock.GetComponentInChildren<Renderer>().bounds;
        Vector3 world = terrain.transform.position + new Vector3(at.x, 0f, at.y);
        float ground = float.MaxValue;
        for (int x = -1; x <= 1; x++)
        for (int z = -1; z <= 1; z++)
            ground = Mathf.Min(ground, terrain.SampleHeight(world + new Vector3(x * bounds.extents.x, 0f, z * bounds.extents.z)));
        ground += terrain.transform.position.y;
        Vector3 target = new Vector3(world.x, ground - bounds.size.y * sink + bounds.extents.y, world.z);
        rock.transform.position += target - bounds.center;
    }

    static VolumeProfile Profile()
    {
        string path = $"{Demo}/DemoVolume.asset";
        var profile = AssetDatabase.LoadAssetAtPath<VolumeProfile>(path);
        if (profile != null)
        {
            // The demo shows the package's defaults: only intensity is overridden.
            if (profile.TryGet(out MeshBlend existing))
            {
                foreach (VolumeParameter parameter in existing.parameters) parameter.overrideState = false;
                existing.intensity.Override(1f);
                EditorUtility.SetDirty(existing);
                AssetDatabase.SaveAssetIfDirty(profile);
            }
            return profile;
        }

        profile = ScriptableObject.CreateInstance<VolumeProfile>();
        AssetDatabase.CreateAsset(profile, path);
        MeshBlend blend = profile.Add<MeshBlend>(true);
        blend.intensity.value = 1f;
        Tonemapping tonemapping = profile.Add<Tonemapping>(true);
        tonemapping.mode.value = TonemappingMode.Neutral;
        foreach (VolumeComponent component in profile.components)
        {
            component.name = component.GetType().Name;
            AssetDatabase.AddObjectToAsset(component, profile);
        }
        EditorUtility.SetDirty(profile);
        AssetDatabase.SaveAssets();
        return profile;
    }

    /// <summary>Renders the raw README captures into <see cref="RawFolder"/>: every patch with the blend off and on, the
    /// sand patch's ids and blend weight, and for each patch where on screen the close-up is centred (the boulder's and
    /// the first stone's foot, where they meet each other and the ground).</summary>
    [MenuItem("Mesh Blend/Capture README Images")]
    public static void CaptureImages()
    {
        OpenDemoForEditing();
        Directory.CreateDirectory(RawFolder);
        EditorSceneManager.OpenScene(ScenePath);
        Terrain terrain = Object.FindFirstObjectByType<Terrain>();
        Volume volume = Object.FindFirstObjectByType<Volume>();
        var go = new GameObject("Capture") { hideFlags = HideFlags.HideAndDontSave };
        var rt = new RenderTexture(2400, 1800, 24, RenderTextureFormat.ARGB32) { antiAliasing = 4 };
        try
        {
            var camera = go.AddComponent<Camera>();
            camera.CopyFrom(Camera.main);
            camera.targetTexture = rt;
            go.AddComponent<UniversalAdditionalCameraData>().renderPostProcessing = true;

            for (int patch = 0; patch < Grounds.Length; patch++)
            {
                (Vector3 position, Vector3 target) = PatchView(terrain, patch);
                go.transform.position = position;
                go.transform.LookAt(target);
                string shot = Grounds[patch].ToLowerInvariant();
                Shot(camera, rt, volume, 0f, MeshBlendDebugView.None, $"{shot}-off");
                Shot(camera, rt, volume, 1f, MeshBlendDebugView.None, $"{shot}-on");
                if (Grounds[patch] == "Sand")
                {
                    Shot(camera, rt, volume, 1f, MeshBlendDebugView.Ids, $"{shot}-ids");
                    Shot(camera, rt, volume, 1f, MeshBlendDebugView.Weight, $"{shot}-weight");
                }

                Vector3 focus = OnTerrain(terrain, PatchCentre(patch) + new Vector2(0.75f, -0.95f), 0.02f);
                Vector3 viewport = camera.WorldToViewportPoint(focus);
                File.WriteAllText($"{RawFolder}/{shot}-focus.txt", $"{viewport.x:0.0000} {1f - viewport.y:0.0000}");
            }
        }
        finally
        {
            MeshBlendRendererFeature.ForcedDebugView = MeshBlendDebugView.None;
            volume.weight = 1f;
            Object.DestroyImmediate(go);
            rt.Release();
            Object.DestroyImmediate(rt);
        }
    }

    static void Shot(Camera camera, RenderTexture rt, Volume volume, float weight, MeshBlendDebugView view, string name)
    {
        volume.weight = weight;
        MeshBlendRendererFeature.ForcedDebugView = view;
        camera.Render();
        RenderTexture previous = RenderTexture.active;
        RenderTexture.active = rt;
        var texture = new Texture2D(rt.width, rt.height, TextureFormat.RGB24, false);
        texture.ReadPixels(new Rect(0, 0, rt.width, rt.height), 0, 0);
        texture.Apply();
        RenderTexture.active = previous;
        string path = $"{RawFolder}/{name}.png";
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        File.WriteAllBytes(path, texture.EncodeToPNG());
        Object.DestroyImmediate(texture);
    }

    static void EnsureFolder(string path)
    {
        if (AssetDatabase.IsValidFolder(path)) return;
        string parent = Path.GetDirectoryName(path).Replace('\\', '/');
        EnsureFolder(parent);
        AssetDatabase.CreateFolder(parent, Path.GetFileName(path));
    }
}
