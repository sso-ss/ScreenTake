"""Prepare native product assets without changing the open ScreenTake session."""
from pathlib import Path
from PIL import Image
import shutil
root=Path(__file__).resolve().parents[1]
repo=root.parent
assets=root/'public/assets'
assets.mkdir(parents=True,exist_ok=True)
for name in ['editor.png','recording.png','toolbar.png','mark.svg','prism.png','lagoon.png','ember.png','midnight.png']:
    shutil.copy2(repo/'website/assets'/name,assets/name)
Image.open(assets/'editor.png').crop((129,118,902,601)).resize((480,300)).convert('RGB').save(assets/'demo-thumb.jpg',quality=90)
fonts=root/'public/fonts'
fonts.mkdir(exist_ok=True)
for name in ['SFNS.ttf','SFNSMono.ttf']:
    source=Path('/System/Library/Fonts')/name
    if source.exists(): shutil.copyfile(source,fonts/name)
print('Native assets and local production fonts prepared.')
