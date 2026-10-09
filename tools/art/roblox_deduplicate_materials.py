"""Deduplicate Roblox OBJ materials without rebuilding or tinting shaders.

Open the imported scene in Blender, then run this in the Scripting workspace.
Identical texture files can have different names. Different colors, shader
values and texture settings stay separate. No automatic save or export.
Custom/animated shaders are skipped; this targets ordinary OBJ imports.
"""

import hashlib
import os

import bpy


NODE_SETTINGS = {
    "ShaderNodeBsdfPrincipled": ("distribution", "subsurface_method"),
    "ShaderNodeOutputMaterial": ("target", "is_active_output"),
    "ShaderNodeTexImage": ("interpolation", "projection", "projection_blend", "extension"),
    "ShaderNodeNormalMap": ("space", "uv_map"),
    "ShaderNodeBump": ("invert",),
}


def value_key(value):
    try:
        return tuple(value)
    except TypeError:
        return value


def settings_key(data):
    """Compare scalar RNA settings, including arrays, without rounding colors."""
    return tuple(
        (prop.identifier, value_key(getattr(data, prop.identifier)))
        for prop in data.bl_rna.properties
        if prop.type in {"BOOLEAN", "INT", "FLOAT", "STRING", "ENUM"}
        and not prop.is_readonly
        and prop.identifier not in {"name", "use_fake_user", "use_extra_user", "tag"}
    )


def image_key(image, cache):
    if image is None:
        return None
    if image not in cache:
        # Missing, edited, generated and animated images retain their identity.
        identity = image.as_pointer()
        if image.source == "FILE" and not image.is_dirty:
            try:
                if image.packed_file:
                    data = image.packed_file.data
                else:
                    path = bpy.path.abspath(image.filepath, library=image.library)
                    with open(os.path.realpath(path), "rb") as source:
                        data = source.read()
                identity = hashlib.sha256(data).digest()
            except OSError:
                pass
        cache[image] = (identity, image.colorspace_settings.name, image.alpha_mode)
    return cache[image]


def fingerprint(material, images):
    tree = material.node_tree
    if material.animation_data or material.library or material.override_library:
        return None
    if material.keys() or material.is_grease_pencil:
        return None
    if tree and (tree.animation_data or tree.keys()):
        return None

    nodes = []
    if tree:
        for node in sorted(tree.nodes, key=lambda item: item.name):
            if node.bl_idname not in NODE_SETTINGS or node.keys():
                return None
            inputs = tuple(
                (socket.identifier, value_key(socket.default_value))
                for socket in node.inputs if hasattr(socket, "default_value")
            )
            settings = tuple(
                (attr, getattr(node, attr)) for attr in NODE_SETTINGS[node.bl_idname]
                if hasattr(node, attr)
            )
            texture = None
            if node.bl_idname == "ShaderNodeTexImage":
                texture = (
                    image_key(node.image, images),
                    settings_key(node.image_user),
                    settings_key(node.texture_mapping),
                    settings_key(node.color_mapping),
                )
                # A custom color ramp needs a more detailed comparison.
                if node.color_mapping.use_color_ramp:
                    return None
            nodes.append((node.name, node.bl_idname, node.mute, inputs, settings, texture))

    links = tuple(sorted(
        (link.from_node.name, link.from_socket.identifier,
         link.to_node.name, link.to_socket.identifier, link.is_muted)
        for link in tree.links
    )) if tree else ()
    extras = tuple(
        (attr, settings_key(getattr(material, attr)))
        for attr in ("cycles", "lineart") if hasattr(material, attr)
    )
    return settings_key(material), extras, tuple(nodes), links


def main():
    canonical, images = {}, {}
    merged = skipped = 0
    for material in list(bpy.data.materials):
        if material.users == 0:
            continue
        key = fingerprint(material, images)
        if key is None:
            skipped += 1
            continue
        if key not in canonical:
            canonical[key] = material
            continue
        material.user_remap(canonical[key])
        if material.users == 0:
            bpy.data.materials.remove(material)
        merged += 1
    print("Roblox materials: merged %d duplicates; skipped %d custom/linked materials."
          % (merged, skipped))


if __name__ == "__main__":
    main()
