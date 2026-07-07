# Bake the cartoon-hand asset pack into the avatar's hands.glb.
#
#   blender --background --python vendor/bake-hands.py
#
# Source : vendor/hands-src/Hands_Cartoon_Collection.fbx  (15 modelled hands)
# Output : priv/static/vendor/hands.glb                   (13 named gesture meshes)
# Loaded by priv/static/vendor/avatar3d.mjs (const HANDS_URL), wrapped in the
# cube's own matcap + inverted-hull toon shaders.
#
# What it does, per gesture: bake world transform -> weld coincident verts ->
# per-pose corrective rotation -> ONE uniform scale for the whole set (so a fist
# stays smaller than an open hand) -> center on bbox (anchors like the old capsule
# poses) -> smooth-shade -> export GLB (Y-up, no materials — the runtime skins).
import bpy, bmesh, math, os
from mathutils import Vector, Matrix, Euler

HERE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(HERE, "hands-src", "Hands_Cartoon_Collection.fbx")
GLB  = os.path.normpath(os.path.join(HERE, "..", "priv", "static", "vendor", "hands.glb"))

# gesture names (identified from renders). "point","open","thumb" kept verbatim so
# the existing gesture engine stays backward-compatible. DROPPED: Hand 10 (a
# two-hand handshake, not a single gesture) and Hand 2 (a flat hand modeled in a
# tilted 3-o'clock orientation — "palm" already covers the flat-hand look upright).
NAMES = {
  "Hand 1":"point", "Hand 3":"thumb", "Hand 4":"fist", "Hand 5":"peace",
  "Hand 6":"two",   "Hand 7":"spread","Hand 8":"rock", "Hand 9":"ily",
  "Hand 11":"open", "Hand 12":"palm", "Hand 13":"three","Hand 14":"five",
  "Hand 15":"relaxed",
}
# per-gesture corrective reorientation (post-weld), as in-plane rolls about the
# depth axis (Blender Y == glTF Z, the camera axis). thumb was modeled lying on
# its side -> -90° stands the thumbs-up upright (fist vertical, thumb up). spread
# raked slightly right -> +12° makes the fingers straight up-and-down.
CORRECT = {
    "thumb":  Euler((0, math.radians(-90), 0), "XYZ").to_matrix().to_4x4(),
    "spread": Euler((0, math.radians( 12), 0), "XYZ").to_matrix().to_4x4(),
}
TARGET = 42.0   # height of the TALLEST pose after scale (bumped from the 34u capsule
                # size — the hands read a bit larger); other poses share this factor.

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=SRC)

# ── pass 1: clean each mesh + measure its bounds (in a common space) ──
proc = []   # (obj, mesh, mn, mx)
for o in list(bpy.data.objects):
    if o.type != "MESH" or o.name not in NAMES:
        bpy.data.objects.remove(o, do_unlink=True); continue
    gname = NAMES[o.name]

    bpy.ops.object.select_all(action="DESELECT")
    o.select_set(True); bpy.context.view_layer.objects.active = o
    o.rotation_mode = "XYZ"
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)  # bake world xform

    me = o.data
    bm = bmesh.new(); bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-4)                    # weld coincident verts
    bm.to_mesh(me); bm.free()

    # smooth the low-poly silhouette so the toon outline reads clean (the raw
    # ~400-poly mesh gives an angular inverted-hull line). Subdivide once, then
    # decimate back down so the GLB stays light (~400-poly -> subdiv -> ~690 verts).
    sub = o.modifiers.new("subsurf", "SUBSURF")
    sub.levels = 1; sub.render_levels = 1
    bpy.ops.object.modifier_apply(modifier="subsurf")
    dec = o.modifiers.new("dec", "DECIMATE"); dec.decimate_type = "COLLAPSE"; dec.ratio = 0.42
    bpy.ops.object.modifier_apply(modifier="dec")

    if gname in CORRECT:                                                       # per-pose reorientation
        me.transform(CORRECT[gname])

    co = [v.co for v in me.vertices]                                           # bounds post-rotation
    mn = Vector((min(c.x for c in co), min(c.y for c in co), min(c.z for c in co)))
    mx = Vector((max(c.x for c in co), max(c.y for c in co), max(c.z for c in co)))

    o.name = gname; me.name = gname; me.materials.clear()
    proc.append((o, me, mn, mx))

# ── pass 2: ONE uniform scale for the whole set (a fist stays smaller than an
#    open hand — per-pose normalization would wrongly blow the fist up to full
#    height). Reference = the tallest pose (a fully extended hand ≈ real length).
#    Then center each pose on its bbox so it anchors like the capsule poses do. ──
S = TARGET / max((mx.z - mn.z) for (_, _, mn, mx) in proc)
kept = []
for (o, me, mn, mx) in proc:
    ctr = (mn + mx) * 0.5
    me.transform(Matrix.Translation(-ctr))               # bbox center -> origin
    me.transform(Matrix.Diagonal((S, S, S, 1.0)))         # shared scale -> relative sizes preserved
    me.transform(Matrix.Rotation(math.radians(180), 4, "Z"))  # 180° about up -> PALM faces the
    #   viewer (the cube's face is toward us, so we see the front of the hand, not the back)
    for p in me.polygons: p.use_smooth = True             # matcap reads off smooth normals
    me.update()
    kept.append(o)

bpy.ops.object.select_all(action="DESELECT")
for o in kept: o.select_set(True)
bpy.context.view_layer.objects.active = kept[0]

bpy.ops.export_scene.gltf(
    filepath=GLB, export_format="GLB", use_selection=True,
    export_yup=True, export_apply=True, export_materials="NONE",
    export_normals=True, export_texcoords=False, export_tangents=False,
    export_extras=False, export_cameras=False, export_lights=False,
)
print("BAKED %d meshes -> %s" % (len(kept), GLB))
for o in kept: print("  %-8s verts=%d" % (o.name, len(o.data.vertices)))
