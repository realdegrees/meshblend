"""Builds the demo's rocks: displaced, flattened icospheres with smart-projected UVs, one FBX each.

    blender --background --factory-startup --python tools/blender/rocks.py -- Packages/com.realdegrees.meshblend/Samples~/Demo/Models
"""
import math
import os
import random
import sys

import bpy

out = sys.argv[sys.argv.index("--") + 1]
os.makedirs(out, exist_ok=True)

# name, seed, scale (x, y, z) in metres, noise size, displacement strength
ROCKS = [
    ("Boulder", 11, (1.6, 1.2, 1.3), 0.9, 0.45),
    ("Slab", 23, (2.2, 0.55, 1.6), 0.7, 0.25),
    ("Stone", 37, (0.6, 0.45, 0.5), 0.5, 0.18),
    ("Pillar", 41, (0.8, 2.2, 0.75), 0.8, 0.35),
]

for name, seed, scale, noise_size, strength in ROCKS:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    random.seed(seed)
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=5, radius=1.0)
    rock = bpy.context.active_object
    rock.name = name

    texture = bpy.data.textures.new(f"{name}Noise", type="VORONOI")
    texture.noise_scale = noise_size
    texture.distance_metric = "DISTANCE"
    texture.noise_intensity = 1.0
    displace = rock.modifiers.new("Displace", "DISPLACE")
    displace.texture = texture
    displace.strength = strength
    displace.mid_level = 0.6
    displace.texture_coords = "LOCAL"
    rock.location = (random.uniform(-5, 5), random.uniform(-5, 5), random.uniform(-5, 5))
    bpy.ops.object.modifier_apply(modifier="Displace")
    rock.location = (0, 0, 0)

    detail = bpy.data.textures.new(f"{name}Detail", type="CLOUDS")
    detail.noise_scale = noise_size * 0.25
    fine = rock.modifiers.new("Detail", "DISPLACE")
    fine.texture = detail
    fine.strength = strength * 0.25
    bpy.ops.object.modifier_apply(modifier="Detail")

    rock.scale = scale
    rock.rotation_euler = (0.0, 0.0, random.uniform(0, math.tau))
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

    decimate = rock.modifiers.new("Decimate", "DECIMATE")
    decimate.ratio = 0.35
    bpy.ops.object.modifier_apply(modifier="Decimate")
    bpy.ops.object.shade_smooth()

    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.02, scale_to_bounds=True)
    bpy.ops.object.mode_set(mode="OBJECT")

    # Blender is Z-up; Unity is Y-up. The scale above is authored as (x, height, depth).
    rock.rotation_euler = (math.radians(90), 0, 0)
    bpy.ops.object.transform_apply(rotation=True)

    path = os.path.join(out, f"{name}.fbx")
    bpy.ops.export_scene.fbx(
        filepath=path,
        use_selection=False,
        apply_scale_options="FBX_SCALE_UNITS",
        axis_forward="-Z",
        axis_up="Y",
        bake_space_transform=True,
        mesh_smooth_type="FACE",
        add_leaf_bones=False,
    )
    print("wrote", path, len(rock.data.polygons), "faces")
