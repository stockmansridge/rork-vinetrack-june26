#!/usr/bin/env python3
"""Compose labelled comparisons from the supplied references and actual emulator HUD captures."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageOps

folder = Path(__file__).resolve().parents[1] / 'docs/reviews/live-trip-ui-evidence'
font_path = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
font = ImageFont.truetype(font_path, 17)
small = ImageFont.truetype(font_path, 13)

def comparison(filename, entries):
    width, height, gap = 360, 940, 18
    canvas = Image.new('RGB', (gap + len(entries) * (width + gap), height + 120), '#edf1ed')
    draw = ImageDraw.Draw(canvas)
    for index, (path, title, subtitle) in enumerate(entries):
        x = gap + index * (width + gap)
        draw.text((x, 12), title, font=font, fill='#183729')
        draw.text((x, 38), subtitle, font=small, fill='#3b4841')
        image = Image.open(folder / path).convert('RGB')
        image = ImageOps.contain(image, (width, height - 10))
        canvas.paste(image, (x + (width - image.width) // 2, 68))
    draw.text((gap, height + 76), 'After: production Compose HUD; synthetic state; map renderer excluded.', font=small, fill='#293b32')
    draw.text((gap, height + 97), 'Not physical Samsung, live GPS, OS-process or backend acceptance.', font=small, fill='#293b32')
    canvas.save(folder / filename, quality=90)
    print(folder / filename)

comparison('before-after.webp', [
    ('reference-android.png', 'BEFORE · supplied Samsung', 'Original trip/path state not independently inspected'),
    ('planned-active-tank.webp', 'AFTER · Android planned fixture', '360 dp · confirmed Tank 1 of 2 · offline'),
])
comparison('ios-android.webp', [
    ('reference-ios.png', 'REFERENCE · supplied iOS', 'Intended operational information hierarchy'),
    ('planned-active-tank.webp', 'AFTER · Android planned fixture', 'Same hierarchy, Android-native controls'),
])
