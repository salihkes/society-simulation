"""Read the road bake and render its actual game-space route and height profile."""
import json
import numpy as np
from PIL import Image, ImageDraw
from build_region import DEFAULT_OUT, ROOT
from render_overview import View, assemble, resample, relief, text, BG, INK, MUTED, ACCENT


def main():
    root = DEFAULT_OUT/'roads'
    manifest = json.loads((root/'manifest.json').read_text())
    folder = root/manifest['version']
    rows = np.fromfile(folder/'alignment.bin', '<f4').reshape(-1, 10)
    terrain_root = root/manifest['terrain_dir']
    meta = json.loads((terrain_root/'meta.json').read_text())
    meta['tiles_dir'] = str((terrain_root/meta['tiles_dir']).resolve())
    meta['tile_overrides'] = {k: str((terrain_root/v).resolve()) for k, v in meta['tile_overrides'].items()}
    _, heights = assemble(meta)
    angle = np.radians(meta['projection']['bearing_x_deg'])
    east = rows[:, 0]*np.sin(angle)+rows[:, 2]*np.cos(angle)
    north = rows[:, 0]*np.cos(angle)-rows[:, 2]*np.sin(angle)
    view = View(meta, [east.min()-7000, north.min()-6000, east.max()+7000, north.max()+6000], 1700, 640)
    x, z = view.world()
    h, _ = resample(heights, x, z, meta)
    image = Image.fromarray(relief(h, meta['sea_y'], view.upp))
    draw = ImageDraw.Draw(image)
    points = [view.point(row[0], row[2]) for row in rows]
    draw.line(points, fill='#142932', width=7)
    draw.line(points, fill=ACCENT, width=3)
    for i in range(len(rows)-1):
        if rows[i, 7] == 1:
            draw.line(points[i:i+2], fill='#71e4ef', width=5)
        elif rows[i, 7] == 2:
            draw.line(points[i:i+2], fill='#e7a4ed', width=6)
    for i, name in [(0, 'Home city'), (-1, 'Destination')]:
        px, py = points[i]
        draw.ellipse([px-7, py-7, px+7, py+7], fill=INK)
        text(draw, (px+12 if i == 0 else px-125, py+18), name, 25)
    canvas = Image.new('RGB', (1800, 1140), BG)
    canvas.paste(image, (50, 145))
    draw = ImageDraw.Draw(canvas)
    text(draw, (50, 26), 'Home city to destination', 42)
    text(draw, (50, 83), 'First road corridor · actual deformed game geography · provisional city exits', 24, MUTED)
    text(draw, (50, 805), 'Road', 21, ACCENT)
    text(draw, (155, 805), 'Bridge / water crossing', 21, '#71e4ef')
    text(draw, (485, 805), 'Source tunnel: open cutting in this prototype', 21, '#e7a4ed')
    text(draw, (1180, 805), 'Route width exaggerated for visibility', 20, MUTED)
    lo, hi = min(rows[:, 1].min(), rows[:, 8].min()), max(rows[:, 1].max(), rows[:, 8].max())
    chart_x = 50+rows[:, 6]/rows[-1, 6]*1700
    for column, color in [(8, '#627c72'), (1, ACCENT)]:
        chart_y = 1040-(rows[:, column]-lo)/max(hi-lo, 1)*150
        draw.line(list(zip(chart_x, chart_y)), fill=color, width=2)
    text(draw, (50, 850), 'Height profile: original ground / generated road', 23)
    text(draw, (50, 1068), f'{rows[-1,6]:,.0f} city units · {len(manifest["chunks"])} chunks · maximum grade 12%', 23)
    text(draw, (1140, 1068), 'OSM contributors · elevation: AWS Terrarium', 20, MUTED)
    output = ROOT/'output/road-prototype/route-overview.png'
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output)
    print(output)


if __name__ == '__main__':
    main()
