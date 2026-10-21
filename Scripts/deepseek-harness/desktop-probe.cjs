// Temporarily loads the observer in the running Desktop profile, then restores it.
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { createHash, randomUUID } = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');

const patchPath = path.join(os.homedir(), '.dsh/profiles/desktop/cordis.patch.yml');
const pluginPath = path.resolve(__dirname, '../../Sources/CodexBar/Resources/HarnessBridge.cjs');
const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-desktop-')));
const socketPath = path.join(root, 'p.sock');
const statePath = path.join(root, 'harness-state.json');
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const original = fs.readFileSync(patchPath);
const mode = fs.statSync(patchPath).mode & 0o777;
const marker = `vibe-island-feasibility-${randomUUID()}`;
const overlay = `\n- insert:\n    - id: ${marker}\n      name: ${JSON.stringify(pluginPath)}\n      config:\n        socketPath: ${JSON.stringify(socketPath)}\n        statePath: ${JSON.stringify(statePath)}\n`;
const installed = Buffer.concat([original, Buffer.from(overlay)]);
const records = [];
let interrupted = false;
let modified = false;
let stage = 'initializing';
const interrupt = () => { interrupted = true; };
process.on('SIGINT', interrupt);
process.on('SIGTERM', interrupt);

function atomicWrite(bytes) {
  const temporary = `${patchPath}.${marker}.tmp`;
  try {
    fs.writeFileSync(temporary, bytes, { mode, flag: 'wx' });
    fs.renameSync(temporary, patchPath);
  } finally { fs.rmSync(temporary, { force: true }); }
}

async function waitFor(predicate, attempts = 200) {
  for (let i = 0; i < attempts; i += 1) {
    const value = predicate();
    if (value) return value;
    if (interrupted) throw new Error('Desktop probe interrupted');
    await delay(50);
  }
  throw new Error(`Desktop did not acknowledge the profile plugin change (${stage})`);
}

function restore() {
  if (!modified) return;
  const current = fs.readFileSync(patchPath);
  if (current.equals(installed)) atomicWrite(original);
  else {
    const text = current.toString();
    assert.equal(text.split(overlay).length, 2, `Concurrent profile edit: retained backup at ${root}`);
    atomicWrite(Buffer.from(text.replace(overlay, '')));
  }
  modified = false;
}

const server = net.createServer((socket) => {
  let wire = Buffer.alloc(0);
  socket.setTimeout(1000, () => socket.destroy());
  socket.on('data', (chunk) => {
    wire = Buffer.concat([wire, chunk]);
    if (wire.length > 128 * 1024) socket.destroy();
  });
  socket.on('end', () => { try { records.push(JSON.parse(wire)); } catch {} });
  socket.on('error', () => {});
});

(async () => {
  try {
    fs.writeFileSync(path.join(root, 'profile-original'), original, { mode: 0o600 });
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
    fs.chmodSync(socketPath, 0o600);
    assert.ok(fs.readFileSync(patchPath).equals(original), 'Profile changed before probe installation');
    atomicWrite(installed);
    modified = true;
    stage = 'plugin ready';
    const ready = await waitFor(() => records.find((record) => record.type === 'bridge/ready'));
    assert.ok(Number.isSafeInteger(ready.pid) && ready.pid > 1);
    const executable = execFileSync('/bin/ps', ['-p', String(ready.pid), '-o', 'comm='], { encoding: 'utf8' }).trim();
    assert.equal(executable, '/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness');
    stage = 'snapshot heartbeat';
    await waitFor(() => fs.existsSync(statePath));
    const snapshot = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    assert.equal(snapshot.pid, ready.pid);
    assert.ok(Date.now() - snapshot.generatedAt < 10000);
    assert.equal(fs.statSync(statePath).mode & 0o777, 0o600);
    restore();
    stage = 'plugin stopped';
    await waitFor(() => records.find((record) => record.type === 'bridge/stopped' && record.pid === ready.pid));
    const restoredHash = hash(fs.readFileSync(patchPath));
    assert.equal(restoredHash, hash(original));
    console.log(JSON.stringify({ desktopPluginLoaded: true, desktopHostPID: ready.pid,
      executable, hotReload: true, snapshotHeartbeat: true, pluginUnloaded: true, profileRestored: true,
      originalProfileSHA256: hash(original), restoredProfileSHA256: restoredHash,
      taskEventsObserved: records.filter((record) => record.payload).length,
      productionIslandEventsSent: 0, externalModelCalls: 0 }, null, 2));
  } finally {
    try { restore(); } finally {
      await new Promise((resolve) => server.close(resolve));
      if (!modified) fs.rmSync(root, { recursive: true, force: true });
      process.off('SIGINT', interrupt);
      process.off('SIGTERM', interrupt);
    }
  }
})().catch((error) => { console.error(error.message); process.exitCode = 1; });
