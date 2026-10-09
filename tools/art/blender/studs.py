"""
Blender that builds in studs, the way Studio + F3X did.

Opened by tools/art/blender.sh. Adds a "Studs" tab to the 3D view's sidebar (N):

  Grid      Move step (0.2) and Rotate step (5 deg). Every drag moves in
            steps and lands on the stud grid; typed values (G X 1.4) still
            work. 1 Blender unit = 1 stud = 1 Godot unit.
  New Part  a 4 x 1.2 x 2 part resting on the 3D cursor (Shift+Right-click
            a surface to put the cursor there first).
  Part      Size in studs (changes the mesh, never the object scale, so
            moving a face in Edit Mode still steps in real studs),
            CanCollide.
  Paint     Material (Brick, Concrete, ...) and Color, applied to the
            selected parts; Pick copies them from the active part.
  Export    <blend name>.glb next to the saved .blend, for Godot. Parts
            with CanCollide get Godot's "-col" name suffix only inside
            the file, so Godot gives them a static collider.

A part's material is named "<Material> #<RRGGBB>" (sRGB hex, like a
Roblox Color3), so Godot can tell the material kind from the name and the
color from the glTF base color.
"""

import math

import bmesh
import bpy
from bpy.app.handlers import persistent
from mathutils import Matrix

# ---------- settings ----------
DEFAULT_STEP = 0.2
DEFAULT_ROTATE = 5.0             # degrees
GRID_LEVELS = 5                  # side views zoom 0.2 -> 1 -> 5 -> 25 studs
PART_SIZE = (4.0, 2.0, 1.2)      # X, Y, Z (Z is up; Roblox's 4 x 1.2 x 2)
DEFAULT_COLOR = "A3A2A5"         # Medium stone grey
CLIP = (0.1, 10000.0)            # a whole city in view, studs
# ------------------------------

# kind -> (roughness, metallic)
KINDS = {
    "SmoothPlastic": (0.35, 0.0),
    "Plastic": (0.6, 0.0),
    "Brick": (0.9, 0.0),
    "Concrete": (0.9, 0.0),
    "Wood": (0.8, 0.0),
    "WoodPlanks": (0.8, 0.0),
    "Slate": (0.85, 0.0),
    "Marble": (0.3, 0.0),
    "Granite": (0.6, 0.0),
    "Cobblestone": (0.9, 0.0),
    "Asphalt": (0.95, 0.0),
    "Pavement": (0.9, 0.0),
    "Pebble": (0.9, 0.0),
    "Rock": (0.9, 0.0),
    "ClayRoofTiles": (0.8, 0.0),
    "Fabric": (0.95, 0.0),
    "Grass": (0.95, 0.0),
    "Metal": (0.35, 1.0),
    "CorrodedMetal": (0.8, 0.6),
    "Glass": (0.05, 0.0),
    "Neon": (0.5, 0.0),
}
DEFAULT_KIND = "SmoothPlastic"
COLLIDE_SUFFIXES = ("-col", "-colonly", "-convcol", "-convcolonly")


# ---------- color ----------

def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def linear_to_srgb(c):
    c = max(0.0, min(1.0, c))
    return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def hex_to_linear(h):
    return tuple(srgb_to_linear(int(h[i:i + 2], 16) / 255) for i in (0, 2, 4))


def linear_to_hex(rgb):
    return "".join("%02X" % round(linear_to_srgb(c) * 255) for c in rgb[:3])


# ---------- materials ----------

def principled(mat):
    if mat is None or mat.node_tree is None:
        return None
    return next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)


def kind_of(mat):
    head = mat.name.split(" #")[0] if mat else ""
    return head if head in KINDS else DEFAULT_KIND


def color_of(mat):
    bsdf = principled(mat)
    if bsdf is not None:
        return tuple(bsdf.inputs["Base Color"].default_value[:3])
    if mat is not None:
        return tuple(mat.diffuse_color[:3])
    return hex_to_linear(DEFAULT_COLOR)


def part_material(kind, rgb):
    """The one shared material for this kind + color, made on first use."""
    rgb = tuple(max(0.0, min(1.0, c)) for c in rgb[:3])
    name = "%s #%s" % (kind, linear_to_hex(rgb))
    mat = bpy.data.materials.get(name)
    if mat is not None:
        return mat
    rough, metal = KINDS[kind]
    alpha = 0.35 if kind == "Glass" else 1.0
    mat = bpy.data.materials.new(name)
    if not mat.use_nodes:
        mat.use_nodes = True
    mat.diffuse_color = (*rgb, alpha)   # what Solid view shows
    mat.roughness = rough
    mat.metallic = metal
    bsdf = principled(mat)
    if bsdf is not None:
        bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
        bsdf.inputs["Roughness"].default_value = rough
        bsdf.inputs["Metallic"].default_value = metal
        bsdf.inputs["Alpha"].default_value = alpha
        if kind == "Neon":
            bsdf.inputs["Emission Color"].default_value = (*rgb, 1.0)
            bsdf.inputs["Emission Strength"].default_value = 2.0
    if alpha < 1.0 and hasattr(mat, "surface_render_method"):
        mat.surface_render_method = "BLENDED"
    return mat


def repaint(ob, kind=None, rgb=None):
    """Swap every slot to the same kind/color, keeping whichever is None."""
    if ob.type != "MESH":
        return False
    if not ob.material_slots:
        ob.data.materials.append(None)
    for slot in ob.material_slots:
        old = slot.material
        slot.material = part_material(kind or kind_of(old),
                                      rgb if rgb is not None else color_of(old))
    return True


# ---------- the view: studs, steps, snapping ----------

def apply_view_settings(scene):
    tool = scene.studs
    scene.unit_settings.system = "NONE"
    ts = scene.tool_settings
    ts.use_snap = True
    ts.snap_elements = {"INCREMENT"}
    ts.use_snap_grid_absolute = True
    ts.use_snap_translate = True
    ts.use_snap_rotate = True
    ts.snap_angle_increment_3d = math.radians(tool.rotate_step)
    for screen in bpy.data.screens:
        for area in screen.areas:
            for space in area.spaces:
                if space.type != "VIEW_3D":
                    continue
                space.overlay.grid_scale = tool.step
                space.overlay.grid_subdivisions = GRID_LEVELS
                space.clip_start, space.clip_end = CLIP


def _step_changed(self, context):
    apply_view_settings(context.scene)


def _rotate_changed(self, context):
    context.scene.tool_settings.snap_angle_increment_3d = math.radians(self.rotate_step)


def _size_get(self):
    ob = bpy.context.active_object
    if ob is None or ob.type != "MESH":
        return (0.0, 0.0, 0.0)
    return tuple(ob.dimensions)


def _size_set(self, value):
    ob = bpy.context.active_object
    if ob is None or ob.type != "MESH" or ob.mode != "OBJECT":
        return
    f = [v / d if d > 1e-6 and v > 1e-6 else 1.0 for v, d in zip(value, ob.dimensions)]
    ob.data.transform(Matrix.Diagonal((*f, 1.0)))
    ob.data.update()


class StudsTool(bpy.types.PropertyGroup):
    step: bpy.props.FloatProperty(
        name="Move", description="Studs per step when moving or extruding",
        default=DEFAULT_STEP, min=0.001, soft_max=16.0, step=10, precision=3,
        update=_step_changed)
    rotate_step: bpy.props.FloatProperty(
        name="Rotate", description="Degrees per step when rotating",
        default=DEFAULT_ROTATE, min=0.1, max=180.0, precision=1,
        update=_rotate_changed)
    kind: bpy.props.EnumProperty(
        name="Material", default=DEFAULT_KIND,
        items=[(k, k, "") for k in KINDS])
    color: bpy.props.FloatVectorProperty(
        name="Color", subtype="COLOR", size=3, min=0.0, max=1.0,
        default=hex_to_linear(DEFAULT_COLOR))
    size: bpy.props.FloatVectorProperty(
        name="Size", description="Active part's size in studs",
        size=3, subtype="XYZ", min=0.0, step=20, precision=2,
        get=_size_get, set=_size_set)


# ---------- operators ----------

class STUDS_OT_new_part(bpy.types.Operator):
    """Insert a part resting on the 3D cursor"""
    bl_idname = "studs.new_part"
    bl_label = "New Part"
    bl_options = {"REGISTER", "UNDO"}

    @classmethod
    def poll(cls, context):
        return context.mode == "OBJECT"

    def execute(self, context):
        tool = context.scene.studs
        bm = bmesh.new()
        bm.loops.layers.uv.new()
        bmesh.ops.create_cube(bm, size=1.0, calc_uvs=True)
        bmesh.ops.scale(bm, vec=PART_SIZE, verts=bm.verts)
        me = bpy.data.meshes.new("Part")
        bm.to_mesh(me)
        bm.free()
        ob = bpy.data.objects.new("Part", me)
        context.collection.objects.link(ob)

        s = tool.step
        cur = context.scene.cursor.location
        ob.location = (round(cur.x / s) * s,
                       round(cur.y / s) * s,
                       round(cur.z / s) * s + PART_SIZE[2] / 2)
        repaint(ob, tool.kind, tuple(tool.color))

        for other in context.selected_objects:
            other.select_set(False)
        ob.select_set(True)
        context.view_layer.objects.active = ob
        return {"FINISHED"}


class STUDS_OT_set_material(bpy.types.Operator):
    """Give the selected parts this material, keeping their colors"""
    bl_idname = "studs.set_material"
    bl_label = "Material"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        n = sum(repaint(ob, kind=context.scene.studs.kind) for ob in context.selected_objects)
        self.report({"INFO"}, "%s on %d part(s)" % (context.scene.studs.kind, n))
        return {"FINISHED"}


class STUDS_OT_paint(bpy.types.Operator):
    """Give the selected parts this color, keeping their materials"""
    bl_idname = "studs.paint"
    bl_label = "Paint"
    bl_options = {"REGISTER", "UNDO"}

    def execute(self, context):
        rgb = tuple(context.scene.studs.color)
        n = sum(repaint(ob, rgb=rgb) for ob in context.selected_objects)
        self.report({"INFO"}, "#%s on %d part(s)" % (linear_to_hex(rgb), n))
        return {"FINISHED"}


class STUDS_OT_pick(bpy.types.Operator):
    """Copy material and color from the active part"""
    bl_idname = "studs.pick"
    bl_label = "Pick"

    @classmethod
    def poll(cls, context):
        ob = context.active_object
        return ob is not None and ob.type == "MESH"

    def execute(self, context):
        mat = context.active_object.active_material
        tool = context.scene.studs
        tool.kind = kind_of(mat)
        tool.color = color_of(mat)
        return {"FINISHED"}


class STUDS_OT_fix_scale(bpy.types.Operator):
    """Bake the object scale into the mesh so steps are real studs again"""
    bl_idname = "studs.fix_scale"
    bl_label = "Fix scale"
    bl_options = {"REGISTER", "UNDO"}

    @classmethod
    def poll(cls, context):
        return context.mode == "OBJECT"

    def execute(self, context):
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        return {"FINISHED"}


class STUDS_OT_export(bpy.types.Operator):
    """Write <blend name>.glb next to the .blend, for Godot"""
    bl_idname = "studs.export"
    bl_label = "Export for Godot"

    @classmethod
    def poll(cls, context):
        return context.mode == "OBJECT"

    def execute(self, context):
        if not bpy.data.filepath:
            self.report({"ERROR"}, "Save the .blend first; the .glb goes next to it")
            return {"CANCELLED"}
        path = bpy.path.ensure_ext(bpy.data.filepath[:-len(".blend")], ".glb")

        renamed = []
        for ob in context.scene.objects:
            if (ob.type == "MESH" and ob.studs_can_collide
                    and not ob.name.endswith(COLLIDE_SUFFIXES)):
                renamed.append((ob, ob.name))
                ob.name = ob.name + "-col"
        try:
            bpy.ops.export_scene.gltf(filepath=path, export_format="GLB",
                                      export_apply=True, export_yup=True)
        finally:
            for ob, name in reversed(renamed):
                ob.name = name

        self.report({"INFO"}, "Exported %s (%d colliding)" % (path, len(renamed)))
        return {"FINISHED"}


# ---------- panel ----------

class STUDS_PT_panel(bpy.types.Panel):
    bl_label = "Studs"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Studs"

    def draw(self, context):
        tool = context.scene.studs
        ob = context.active_object
        col = self.layout.column()

        box = col.box()
        box.label(text="Grid")
        row = box.row(align=True)
        row.prop(tool, "step")
        row.prop(tool, "rotate_step")

        col.operator("studs.new_part", icon="MESH_CUBE")

        if ob is not None and ob.type == "MESH":
            box = col.box()
            box.label(text=ob.name)
            sub = box.column(align=True)
            sub.enabled = ob.mode == "OBJECT"
            sub.prop(tool, "size")
            if any(abs(s - 1.0) > 1e-4 for s in ob.scale):
                warn = box.row()
                warn.alert = True
                warn.label(text="Scaled: steps aren't studs", icon="ERROR")
                warn.operator("studs.fix_scale")
            box.prop(ob, "studs_can_collide")

        box = col.box()
        box.label(text="Paint")
        box.prop(tool, "kind", text="")
        box.prop(tool, "color", text="")
        row = box.row(align=True)
        row.operator("studs.set_material")
        row.operator("studs.paint")
        row.operator("studs.pick", icon="EYEDROPPER")

        col.operator("studs.export", icon="EXPORT")


# ---------- register ----------

CLASSES = (StudsTool, STUDS_OT_new_part, STUDS_OT_set_material, STUDS_OT_paint,
           STUDS_OT_pick, STUDS_OT_fix_scale, STUDS_OT_export, STUDS_PT_panel)


@persistent
def _on_load(_):
    for scene in bpy.data.scenes:
        apply_view_settings(scene)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)
    bpy.types.Scene.studs = bpy.props.PointerProperty(type=StudsTool)
    bpy.types.Object.studs_can_collide = bpy.props.BoolProperty(
        name="CanCollide", default=True,
        description="Players can't walk through it (exported with Godot's -col suffix)")
    bpy.app.handlers.load_post.append(_on_load)
    _on_load(None)


if __name__ == "__main__":
    register()
