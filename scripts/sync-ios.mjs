import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const rootDir = path.resolve(__dirname, '..');
const distDir = path.join(rootDir, 'dist');
const iosAssetsDir = path.join(rootDir, 'ios', 'AlgerMusicPlayer', 'AppAssets');

console.log('🔄 Syncing web build to iOS project bundle...');
console.log(`Source: ${distDir}`);
console.log(`Destination: ${iosAssetsDir}`);

if (!fs.existsSync(distDir)) {
  console.error('❌ Error: dist folder does not exist! Please run "npm run build:web" or "vite build" first.');
  process.exit(1);
}

// Ensure destination directory exists
if (fs.existsSync(iosAssetsDir)) {
  fs.rmSync(iosAssetsDir, { recursive: true, force: true });
}
fs.mkdirSync(iosAssetsDir, { recursive: true });

function copyRecursive(src, dest) {
  const stats = fs.statSync(src);
  if (stats.isDirectory()) {
    if (!fs.existsSync(dest)) {
      fs.mkdirSync(dest, { recursive: true });
    }
    const entries = fs.readdirSync(src);
    for (const entry of entries) {
      copyRecursive(path.join(src, entry), path.join(dest, entry));
    }
  } else {
    fs.copyFileSync(src, dest);
  }
}

copyRecursive(distDir, iosAssetsDir);
console.log('✅ Web build successfully synced to iOS AppAssets folder!');
