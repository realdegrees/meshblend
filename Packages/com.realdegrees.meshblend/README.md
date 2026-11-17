# Mesh Blend

Soft contacts for URP. Softens the hard line where one surface meets another (a rock entering the terrain, a wall
standing on the ground, two boulders pushed together) with a screen-space pass. Materials, meshes and URP stay as they
are.

Full documentation, images and the demo: <https://github.com/realdegrees/meshblend>

## Requirements

- Unity 6000.3 or newer, URP 17.3 or newer, Render Graph (not Compatibility Mode).
- Perspective cameras. Orthographic cameras, overlay cameras and XR are skipped.

## Setup

1. **Rendering layers.** In *Project Settings ▸ Tags and Layers ▸ Rendering Layers*, name three layers, for example
   `Mesh Blend`, `Mesh Blend Narrow` and `Mesh Blend Ground`. The feature's default groups use layers 1, 2 and 3.
2. **Renderer feature.** On your URP Renderer asset, *Add Renderer Feature ▸ Mesh Blend*. Its default surface groups
   are *Rocks* (layer 1), *Buildings & Props* (layer 2, half the band) and *Ground* (layer 3, priority 1); adjust them
   and the blend matrix as you need.
3. **Tag renderers.** Add each group's layer to the *Rendering Layer Mask* of its renderers, the ground layer to your
   Terrain (*Terrain ▸ Settings ▸ Rendering Layer Mask*) or ground meshes.
4. **Volume.** On a Volume, *Add Override ▸ Mesh Blend* and raise *Intensity* above 0.

## Demo

*Package Manager ▸ Mesh Blend ▸ Samples ▸ Demo ▸ Import* copies a demo scene to
`Assets/Samples/Mesh Blend/<version>/Demo`. It uses layers 1, 2 and 3, so do steps 1 and 2 first; delete the folder to
remove it.

## Settings

| On the Volume | |
|---|---|
| Intensity | How much of the other side is mixed in. 0 switches the effect off and records no passes. |
| Right Angle Radius | Metres from the seam to the band's end where the surfaces meet at 90° or steeper. |
| Flat Radius | The same where the surfaces meet nearly flat. |
| Flat Falloff | How quickly the band narrows from the flat radius toward the right-angle one as the contact steepens. |
| Sharp Seams | How much of the seam line shows through where the surfaces meet at a sharp angle (0 blends it away). |
| Noise, Noise Size | How ragged the band's outer edge is, and the size of its world-anchored pattern. |
| Occlusion, Occlusion Reach | How much URP SSAO stays near a contact, and how far from it (about your SSAO radius). |
| Max Distance | Metres from the camera beyond which the blend has faded out. |

| On the Renderer Feature | |
|---|---|
| Surface Groups | Which renderers take part, by rendering layer, each with its share of the band, a priority (the lower side of a seam fades into the higher one, which keeps its own colour) and whether it is ground (one surface, own depth pass). |
| Blend Matrix | Which groups blend with each other. |
| Search Reach | How far the seam search reaches, as a share of the screen height. Every doubling costs one more short pass. |
| Debug View | *Ids* colours every taking-part surface; *Weight* shows the blend in red. |

`MeshBlendRendererFeature.ForcedDebugView` switches the debug view from code, for a debug menu.

## Limits

- Opaque surfaces only. Transparent surfaces are left as they are.
- Taking-part renderers are drawn once more with a plain id shader, so alpha clipping and vertex animation are ignored
  for finding the seam (fine for rocks and buildings, not for foliage).
- Statically batched objects share one id and so do not blend into each other.
- Screen space: a seam hidden behind something else is not blended.

## License

MIT. See `LICENSE.md` and `THIRD-PARTY-NOTICES.md`.
