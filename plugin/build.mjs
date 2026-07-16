// Bundle src/plugin.ts into the .sdPlugin and ship the compiled daemon next to
// it. All paths resolve relative to this script, so it works from any cwd.
import { build } from 'esbuild';
import { chmodSync, copyFileSync, existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, 'gg.pim.loudini.sdPlugin', 'bin');
mkdirSync(outDir, { recursive: true });

await build({
  entryPoints: [join(here, 'src', 'plugin.ts')],
  outfile: join(outDir, 'plugin.js'),
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node20',
  // All paths here are absolute, so the working dir is irrelevant — except that
  // esbuild switches to Yarn PnP resolution if any ancestor dir has a .pnp.cjs.
  // Anchoring in the temp dir keeps resolution on node_modules everywhere.
  absWorkingDir: tmpdir(),
  // Bundled CJS deps (ws) still call require() inside our ESM output.
  banner: {
    js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);",
  },
  logLevel: 'info',
});

// plugin.js is ESM; Node resolves module type from the nearest package.json.
// The installed .sdPlugin has none above bin/, so ship the marker ourselves.
writeFileSync(join(outDir, 'package.json'), JSON.stringify({ type: 'module' }));

const helperSrc = join(here, '..', 'helper', 'loudini-helper');
const helperDst = join(outDir, 'loudini-helper');
// Never let a stale copy from an earlier build masquerade as current.
rmSync(helperDst, { force: true });
if (existsSync(helperSrc)) {
  copyFileSync(helperSrc, helperDst);
  chmodSync(helperDst, 0o755);
  console.log(`bundled daemon -> ${helperDst}`);
} else {
  console.warn(`WARNING: daemon binary missing at ${helperSrc}`);
  console.warn('The plugin will load but cannot control audio. Build the daemon with:');
  console.warn('  cd helper && swiftc -O -parse-as-library -o loudini-helper \\');
  console.warn('    loudini-helper.swift ControlFile.swift DDC.swift \\');
  console.warn('    -framework CoreAudio -framework AudioToolbox -framework Foundation -framework IOKit');
}
