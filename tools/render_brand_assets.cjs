// Render the shared vector mark with SVG filter support before generating native assets.
// Requires Node.js and sharp. Run from any directory; see website/README.md.
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('sharp');
const assets = path.resolve(__dirname, '../website/assets');

async function main() {
  const symbol = await fs.readFile(path.join(assets, 'mark.svg'), 'utf8');
  const icon = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" fill="none">
  <defs>
    <linearGradient id="tile" x1="260" y1="100" x2="710" y2="940" gradientUnits="userSpaceOnUse">
      <stop stop-color="#FFFFFF"/>
      <stop offset=".55" stop-color="#FAF9FE"/>
      <stop offset="1" stop-color="#EDEAF5"/>
    </linearGradient>
    <linearGradient id="tile-edge" x1="512" y1="100" x2="512" y2="920" gradientUnits="userSpaceOnUse">
      <stop stop-color="white"/>
      <stop offset="1" stop-color="#DCD8E7"/>
    </linearGradient>
  </defs>
  <rect x="100" y="113" width="824" height="824" rx="186" fill="#1A1039" fill-opacity=".04"/>
  <rect x="100" y="108" width="824" height="824" rx="186" fill="#1A1039" fill-opacity=".06"/>
  <rect x="100" y="100" width="824" height="824" rx="186" fill="url(#tile)"/>
  <rect x="101" y="101" width="822" height="822" rx="185" stroke="url(#tile-edge)" stroke-width="2"/>
  <g transform="translate(152 142) scale(5.625)">
    ${symbol.trim()}

  </g>
</svg>`;
  await fs.writeFile(path.join(assets, 'app-icon.svg'), icon);
  // A 2x render preserves the soft shadows when reduced to the 1024px masters.
  await sharp(Buffer.from(symbol), { density: 1152 }).resize(1024, 1024)
    .png().toFile(path.join(assets, 'mark.png'));
  await sharp(Buffer.from(icon), { density: 144 }).resize(1024, 1024)
    .png().toFile(path.join(assets, 'app-icon.png'));
  console.log('Rendered mark.png, app-icon.svg, and app-icon.png from mark.svg.');
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
