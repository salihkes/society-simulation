class_name RuntimeImage
extends RefCounted
## Makes an image written at runtime loadable by path, e.g. by RichTextLabel's [img].


## The cache holds the returned texture weakly, so the caller must keep it alive.
static func adopt(path: String) -> Texture2D:
	var image := Image.new()
	if image.load(path) != OK:
		return null
	var texture := ImageTexture.create_from_image(image)
	texture.take_over_path(path)
	return texture
