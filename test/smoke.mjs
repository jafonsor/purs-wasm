// Smoke test for purs-core.wasm: run it under Node's WASI and compile a tiny
// PureScript module. Needs only Node >= 20 and the wasm; nothing from the
// network and nothing from any other repo.
//
//   node test/smoke.mjs path/to/purs-core.wasm
//
// purs-core takes: <output dir> <file.purs>...   (see nix/purescript/purs-core-Main.hs)
import { WASI } from 'node:wasi';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, openSync, closeSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';

const wasmPath = process.argv[2];
if (!wasmPath) { console.error('usage: node test/smoke.mjs purs-core.wasm'); process.exit(2); }

const mod = await WebAssembly.compile(readFileSync(wasmPath));

// Compile `files` ({ name: source }) in a fresh directory; returns exit code,
// the compiler's stdout and the directory.
async function compile(files) {
  const root = mkdtempSync(join(tmpdir(), 'purs-smoke-'));
  mkdirSync(join(root, 'src'));
  for (const [name, text] of Object.entries(files)) writeFileSync(join(root, 'src', name), text);
  const outFile = join(root, 'stdout.txt');
  const out = openSync(outFile, 'w');
  const wasi = new WASI({
    version: 'preview1',
    args: ['purs-core', '/w/out', ...Object.keys(files).map(n => `/w/src/${n}`)],
    env: {},
    preopens: { '/w': root },
    stdout: out,
    stderr: out,
    returnOnExit: true,
  });
  const inst = await WebAssembly.instantiate(mod, { wasi_snapshot_preview1: wasi.wasiImport });
  const code = wasi.start(inst);
  closeSync(out);
  return { code, stdout: readFileSync(outFile, 'utf8'), root };
}

const good = await compile({
  'Main.purs': 'module Main where\n\nanswer :: Int\nanswer = 42\n',
});
console.log(good.stdout.trim());
assert.equal(good.code, 0, 'a valid module compiles');
assert.match(good.stdout, /RESULT: ok/);
const js = join(good.root, 'out', 'Main', 'index.js');
assert.ok(existsSync(js), 'Main/index.js was written');
const text = readFileSync(js, 'utf8');
assert.match(text, /answer/, 'the JavaScript defines answer');
assert.match(text, /42/, 'the JavaScript contains the value');
console.log(`ok: ${js.slice(good.root.length + 1)} (${text.length} bytes of JavaScript)`);

const bad = await compile({
  'Main.purs': 'module Main where\n\nanswer :: Int\nanswer = "not an Int"\n',
});
assert.notEqual(bad.code, 0, 'a type error fails');
assert.match(bad.stdout, /RESULT: errors/);
assert.match(bad.stdout, /Int/, 'the error mentions the types');
console.log('ok: a type error is reported');

rmSync(good.root, { recursive: true, force: true });
rmSync(bad.root, { recursive: true, force: true });
