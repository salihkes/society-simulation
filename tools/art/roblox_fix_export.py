"""
Roblox .blend -> clean GLB. Fixes materials, deduplicates them, exports.
Works on Blender 4.x AND 5.x (no deprecated API: no MixRGB, no blend_method
assumptions, no reliance on importer node layouts).

Per unique material:
  * tint = mat.diffuse_color (the Kd part color the OBJ importer stored)
  * Base Color = diffuse texture * tint  (glTF exporter turns this into
    baseColorTexture + baseColorFactor -- no texture baking needed)
  * Alpha forced to 1 / opaque -> no see-through holes from map_d
  * normal map rewired, spec map inverted into Roughness
  * color spaces set, images packed

Dedup (lossless -- pixels and geometry untouched):
  * images by CONTENT hash: Roblox writes the same texture once per part
    (Part76_diff.png == Part4817_diff.png ...); identical bytes -> one image
  * materials: same (tint, diff, nmap, spec) fingerprint -> one material,
    all mesh slots remapped, orphans deleted. Distinct colors stay distinct.
  * textures whose source file is missing on disk are dropped from the
    material instead of exporting broken references

The .blend is NOT saved -- only the GLB is written next to it.

Run headless (macOS):
    /Applications/Blender.app/Contents/MacOS/Blender -b ~/Desktop/placeholder.blend \
        -P tools/art/roblox_fix_export.py
or open the .blend, Scripting tab, run this.
"""

import hashlib
import os

import bpy

# ---------- settings ----------
EXPORT_PATH = ""   # "" -> <blendname>.glb next to the .blend
DRACO = False      # mesh compression; smaller GLB but Godot can't read it
WEBP = False       # textures as WebP; smaller, check your engine imports it
MAX_TEX = 0        # 0 = keep textures intact; else downscale to max N px
# ------------------------------

IMAGE_MAP = {}     # canon filename key -> canonical (content-deduped) image
MISSING = set()    # keys whose source file doesn't exist


def canon_key(img):
    """Same source file -> same key, regardless of Blender's .001 suffixes."""
    base = os.path.basename(img.filepath) if img.filepath else img.name
    base = base.lower()
    stem, ext = os.path.splitext(base)
    if ext.lstrip(".").isdigit():          # "part_diff.png.001" -> strip ".001"
        base = stem.lower()
    return base


def file_bytes(img):
    if img.packed_file:
        return img.packed_file.data
    path = bpy.path.abspath(img.filepath)
    if os.path.isfile(path):
        with open(path, "rb") as fh:
            return fh.read()
    return None


def build_image_map():
    by_name = {}
    for img in bpy.data.images:
        if img.source == "FILE":
            by_name.setdefault(canon_key(img), img)
    by_content = {}
    for key, img in sorted(by_name.items()):
        data = file_bytes(img)
        if data is None:
            MISSING.add(key)
            continue
        digest = hashlib.md5(data).hexdigest()
        IMAGE_MAP[key] = by_content.setdefault(digest, img)
    print("unique texture files: %d -> %d by content (%d missing on disk)"
          % (len(by_name), len(by_content), len(MISSING)))


def prep_image(img, non_color):
    img.colorspace_settings.name = "Non-Color" if non_color else "sRGB"
    img.alpha_mode = "NONE"
    if MAX_TEX and img.size[0] > MAX_TEX:
        s = MAX_TEX / img.size[0]
        img.scale(MAX_TEX, max(1, round(img.size[1] * s)))
    try:
        img.pack()
    except RuntimeError:
        pass


def pick(nt, suffix):
    """This material's texture by Roblox suffix -> canonical image or None."""
    for node in nt.nodes:
        if node.type == "TEX_IMAGE" and node.image and suffix in node.image.name:
            key = canon_key(node.image)
            if key in MISSING:
                return None
            if key not in IMAGE_MAP:
                data = file_bytes(node.image)
                if data is None:
                    MISSING.add(key)
                    return None
                IMAGE_MAP[key] = node.image
            return IMAGE_MAP[key]
    return None


def mix_multiply(nt):
    """Version-proof multiply node. Returns (input_a, input_b, output)."""
    node = nt.nodes.new("ShaderNodeMix")
    node.data_type = "RGBA"
    node.blend_type = "MULTIPLY"
    node.inputs["Factor"].default_value = 1.0
    a = [s for s in node.inputs if s.name == "A" and s.type == "RGBA"][0]
    b = [s for s in node.inputs if s.name == "B" and s.type == "RGBA"][0]
    out = [s for s in node.outputs if s.type == "RGBA"][0]
    return a, b, out


def rebuild(mat):
    if not mat.node_tree:
        return
    nt = mat.node_tree

    tint = tuple(mat.diffuse_color)
    diff = pick(nt, "_diff")
    nmap = pick(nt, "_nmap")
    spec = pick(nt, "_spec")

    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

    if diff:
        prep_image(diff, non_color=False)
        d = nt.nodes.new("ShaderNodeTexImage")
        d.image = diff
        in_a, in_b, mix_out = mix_multiply(nt)
        in_b.default_value = tint
        nt.links.new(d.outputs["Color"], in_a)
        nt.links.new(mix_out, bsdf.inputs["Base Color"])
    else:
        bsdf.inputs["Base Color"].default_value = tint
    bsdf.inputs["Alpha"].default_value = 1.0

    if nmap:
        prep_image(nmap, non_color=True)
        n = nt.nodes.new("ShaderNodeTexImage")
        n.image = nmap
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nt.links.new(n.outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])

    if spec:
        prep_image(spec, non_color=True)
        s = nt.nodes.new("ShaderNodeTexImage")
        s.image = spec
        inv = nt.nodes.new("ShaderNodeInvert")
        nt.links.new(s.outputs["Color"], inv.inputs["Color"])
        nt.links.new(inv.outputs["Color"], bsdf.inputs["Roughness"])

    mat.use_backface_culling = False
    for attr, value in (("surface_render_method", "DITHERED"),
                        ("blend_method", "OPAQUE"),
                        ("shadow_method", "OPAQUE")):
        if hasattr(mat, attr):
            try:
                setattr(mat, attr, value)
            except (AttributeError, TypeError):
                pass


def fingerprint(mat):
    tint = tuple(round(c, 4) for c in mat.diffuse_color)
    if not mat.node_tree:
        return (tint, None, None, None)
    nt = mat.node_tree
    names = []
    for suffix in ("_diff", "_nmap", "_spec"):
        img = pick(nt, suffix)
        names.append(img.name if img else None)
    return (tint,) + tuple(names)


def main():
    build_image_map()
    mats_before = len(bpy.data.materials)
    imgs_before = len(bpy.data.images)

    # dedup + remap slots; rebuild each surviving material once
    canonical = {}
    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue
        for slot in obj.material_slots:
            mat = slot.material
            if not mat:
                continue
            fp = fingerprint(mat)
            if fp not in canonical:
                canonical[fp] = mat
                rebuild(mat)
            slot.material = canonical[fp]

    # drop orphaned duplicate materials and images
    for mat in list(bpy.data.materials):
        if mat.users == 0:
            bpy.data.materials.remove(mat)
    for img in list(bpy.data.images):
        if img.users == 0 and img.source == "FILE":
            bpy.data.images.remove(img)

    print("materials: %d -> %d   images: %d -> %d" % (
        mats_before, len(bpy.data.materials), imgs_before, len(bpy.data.images)))

    # bpy.data.filepath is EMPTY when the script runs from the Scripting tab on
    # an unsaved file, and "" + '.glb' is the RELATIVE name '.glb', which lands
    # in Blender's working directory — '/' on macOS. That is a read-only
    # filesystem, so the export dies with Errno 30 pointing at a path that
    # looks like nothing. Always finish with an absolute path.
    out_path = EXPORT_PATH
    if not out_path:
        if bpy.data.filepath:
            out_path = os.path.splitext(bpy.data.filepath)[0] + ".glb"
        else:
            out_path = os.path.join(os.path.expanduser("~"), "Desktop", "export.glb")
            print("unsaved .blend -> writing to %s" % out_path)
    out_path = os.path.abspath(bpy.path.abspath(out_path))
    kwargs = dict(
        filepath=out_path,
        export_format="GLB",
        export_image_format="WEBP" if WEBP else "AUTO",
    )
    if DRACO:
        kwargs["export_draco_mesh_compression_enable"] = True
    bpy.ops.export_scene.gltf(**kwargs)

    size_mb = os.path.getsize(out_path) / 1e6
    print("exported: %s (%.1f MB)" % (out_path, size_mb))


main()
