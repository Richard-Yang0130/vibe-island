const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const pluginPath = path.join(__dirname, 'bridge.cjs');
const session = { id: 'session-test', header: { cwd: '/example/project', origin: 'user' } };
const event = (type, data = {}, seq = 0) => ({ type, data, seq, time: 1792540800000 });
const load = () => {
  assert.ok(fs.existsSync(pluginPath), 'Harness bridge has not been implemented');
  return require(pluginPath);
};
const payload = (envelope) => JSON.parse(Buffer.from(envelope.payload, 'base64'));

test('uses a distinct provider and stable event identity', () => {
  const { normalizeEvent } = load();
  const first = normalizeEvent(session, event('turn/start', { turn: 1 }));
  assert.equal(first.provider, 'deepseekHarness');
  assert.equal(first.schemaVersion, 1);
  assert.match(first.eventID, /^[\da-f]{8}(-[\da-f]{4}){3}-[\da-f]{12}$/i);
  assert.deepEqual(first, normalizeEvent(session, event('turn/start', { turn: 1 })));
  assert.equal(payload(first).hook_event_name, 'UserPromptSubmit');
  assert.equal(payload(first).turn_id, '1');
});

test('distinguishes completed, failed, interrupted and blocked turns', () => {
  const { normalizeEvent } = load();
  for (const [kind, expected] of Object.entries({
    completed: 'Stop', error: 'StopFailure', aborted: 'Interrupt', blocked: 'StopFailure',
    'max-tokens': 'StopFailure',
  })) {
    assert.equal(payload(normalizeEvent(session,
      event('turn/end', { turn: 2, reason: { kind } }))).hook_event_name, expected);
  }
  assert.equal(normalizeEvent(session, event('turn/end', { turn: 2, reason: { kind: 'future' } })), null);
  assert.equal(normalizeEvent(session, event('turn/end', { turn: 2, reason: { kind: 'toString' } })), null);
});

test('never exports prompt text, tool arguments, errors or approval details', () => {
  const { normalizeEvent } = load();
  const value = normalizeEvent(session, event('approval/asked', {
    id: 'approval-test', toolName: 'bash', reason: 'PRIVATE', args: { password: 'PRIVATE' },
  }), '3');
  assert.deepEqual(Object.keys(payload(value)).sort(),
    ['cwd', 'harness_event_seq', 'harness_event_type', 'hook_event_name', 'session_id', 'timestamp', 'turn_id']);
  assert.equal(JSON.stringify(value).includes('PRIVATE'), false);
  assert.equal(Buffer.from(value.payload, 'base64').toString().includes('PRIVATE'), false);
  assert.equal(normalizeEvent(session, event('assistant/message', { content: 'PRIVATE' })), null);
});

test('excludes subagent sessions and rejects invalid identities and event envelopes', () => {
  const { normalizeEvent } = load();
  const start = event('turn/start', { turn: 1 });
  assert.equal(normalizeEvent({ ...session, header: { origin: 'subagent' } }, start), null);
  assert.equal(normalizeEvent({ ...session, id: '' }, start), null);
  assert.equal(normalizeEvent(session, { ...start, seq: -1 }), null);
  assert.equal(normalizeEvent(session, { ...start, time: NaN }), null);
  assert.equal(normalizeEvent(session, event('turn/start', { turn: 'wrong' })), null);
});

test('sends one EOF-framed envelope to a private Unix socket', async () => {
  const { normalizeEvent, sendEnvelope } = load();
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-bridge-')));
  const socketPath = path.join(root, 'p.sock');
  const envelope = normalizeEvent(session, event('turn/start', { turn: 1 }));
  const received = Promise.withResolvers();
  const server = net.createServer((socket) => {
    const chunks = [];
    socket.on('data', (chunk) => chunks.push(chunk));
    socket.on('end', () => received.resolve(JSON.parse(Buffer.concat(chunks))));
  });
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
    fs.chmodSync(socketPath, 0o600);
    await sendEnvelope(socketPath, envelope);
    assert.deepEqual(await received.promise, envelope);
    fs.chmodSync(socketPath, 0o666);
    await assert.rejects(sendEnvelope(socketPath, envelope), /unsafe socket/);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('missing or unsafe endpoints fail without unhandled rejection', async () => {
  const { sendEnvelope } = load();
  await assert.rejects(sendEnvelope('/nonexistent/dsh-probe.sock', {}));
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-unsafe-')));
  try {
    fs.writeFileSync(path.join(root, 'regular'), 'not a socket', { mode: 0o600 });
    fs.symlinkSync(path.join(root, 'regular'), path.join(root, 'link'));
    await assert.rejects(sendEnvelope(path.join(root, 'link'), {}), /unsafe socket/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

const { setTimeout: delay } = require('node:timers/promises');
function fixture(agentSpecs = []) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-state-')));
  const socketPath = path.join(root, 'p.sock');
  const statePath = path.join(root, 'harness-state.json');
  const listeners = new Map();
  const cleanups = [];
  const warnings = [];
  const agents = agentSpecs.map(({ id, status = 'running', origin = 'user', events = [] }) => {
    const live = { id, header: { cwd: root, origin }, seq: events.length,
      eventAt: (seq) => events[seq] };
    return { session: live, status };
  });
  const ctx = {
    agents: { list: () => agents }, sessions: { list: () => agents.map((agent) => agent.session) },
    get: (key) => key === 'sessionTitle' ? { get: () => ({ title: 'Actual session title' }) } : undefined,
    logger: { warn: (warning) => warnings.push(warning) },
    on: (name, callback) => {
      if (!listeners.has(name)) listeners.set(name, []);
      listeners.get(name).push(callback);
    },
    effect: (factory) => cleanups.push(factory()),
  };
  return { root, socketPath, statePath, ctx, warnings, agents,
    emit: (live, value) => { for (const callback of listeners.get('session/event') || []) callback(live, value); },
    snapshot: () => JSON.parse(fs.readFileSync(statePath, 'utf8')),
    dispose: async () => { for (const cleanup of cleanups.reverse()) await cleanup(); },
    remove: () => fs.rmSync(root, { recursive: true, force: true }),
  };
}

test('production plugin requires actual sessions and agents services', () => {
  assert.deepEqual(load().inject, ['sessions', 'agents']);
});

test('recovers only the current turn of an actually running root agent', async () => {
  const start = event('turn/start', { turn: 2 }, 1);
  const approval = event('approval/asked', { args: { private: 'SECRET' } }, 2);
  const f = fixture([
    { id: 'running', events: [event('session/title', { title: 'Older title' }), start, approval] },
    { id: 'idle', status: 'idle', events: [start] },
    { id: 'child', origin: 'subagent', events: [start] },
    { id: 'ended', events: [start, event('turn/end', { turn: 2, reason: { kind: 'completed' } }, 2)] },
  ]);
  try {
    load().apply(f.ctx, f);
    const snapshot = f.snapshot();
    assert.equal(snapshot.schemaVersion, 1);
    assert.equal(snapshot.pid, process.pid);
    assert.ok(snapshot.generatedAt > 0);
    assert.deepEqual(snapshot.events.map((value) => payload(value).session_id), ['running', 'running']);
    assert.deepEqual(snapshot.events.map((value) => payload(value).hook_event_name),
      ['UserPromptSubmit', 'PermissionRequest']);
    assert.equal(payload(snapshot.events[0]).task_title, 'Actual session title');
    assert.equal(JSON.stringify(snapshot).includes('SECRET'), false);
    assert.deepEqual(snapshot.events[0], load().normalizeEvent(f.agents[0].session, start, undefined,
      'Actual session title'));
    assert.equal(fs.statSync(f.statePath).mode & 0o7777, 0o600);
  } finally { await f.dispose(); f.remove(); }
});

test('disconnected receiver snapshot preserves start and latest terminal with stable IDs', async () => {
  const f = fixture();
  try {
    load().apply(f.ctx, f);
    const start = event('turn/start', { turn: 1 }, 1);
    f.emit(session, start);
    f.emit(session, event('approval/asked', {}, 2));
    f.emit(session, event('turn/end', { turn: 1, reason: { kind: 'completed' } }, 4));
    const first = f.snapshot();
    assert.deepEqual(first.events.map((value) => payload(value).hook_event_name), ['UserPromptSubmit', 'Stop']);
    // Duplicate/out-of-order callbacks must never replace terminal state with progress.
    f.emit(session, event('tool/result', {}, 3));
    f.emit(session, start);
    assert.deepEqual(f.snapshot().events, first.events);
    await delay(20);
    assert.deepEqual(f.snapshot().events, first.events);
    await f.dispose();
    const stopped = f.snapshot();
    assert.equal(stopped.generatedAt, 0);
    assert.deepEqual(stopped.events, first.events);
  } finally { await f.dispose(); f.remove(); }
});

test('titles come only from title metadata and are bounded to 160 characters', async () => {
  const f = fixture();
  delete f.ctx.get;
  try {
    load().apply(f.ctx, f);
    f.emit(session, event('session/title', { title: '😀'.repeat(200) + '\nPRIVATE' }, 0));
    f.emit(session, event('turn/start', { turn: 1, prompt: 'SECRET' }, 1));
    const title = payload(f.snapshot().events[0]).task_title;
    assert.equal([...title].length, 160);
    assert.equal(title, '😀'.repeat(160));
  } finally { await f.dispose(); f.remove(); }
});

test('heartbeat retains active turns and expires terminal turns after 120 seconds', async (t) => {
  const f = fixture();
  t.mock.timers.enable({ apis: ['Date', 'setInterval'], now: 1792540800000 });
  try {
    load().apply(f.ctx, f);
    f.emit(session, event('turn/start', { turn: 1 }, 1));
    const active = f.snapshot().events;
    t.mock.timers.tick(122000);
    assert.deepEqual(f.snapshot().events, active);
    assert.equal(f.snapshot().generatedAt, Date.now());
    f.emit(session, event('turn/end', { turn: 1, reason: { kind: 'completed' } }, 2));
    t.mock.timers.tick(118000);
    assert.equal(f.snapshot().events.length, 2);
    t.mock.timers.tick(4000);
    assert.deepEqual(f.snapshot().events, []);
  } finally { await f.dispose(); t.mock.timers.reset(); f.remove(); }
});

test('refuses unsafe snapshot directories and symlink files without affecting tasks', async () => {
  for (const unsafe of ['directory', 'symlink', 'parent-link']) {
    const f = fixture();
    const target = path.join(f.root, 'target');
    fs.writeFileSync(target, 'KEEP', { mode: 0o600 });
    try {
      if (unsafe === 'directory') fs.chmodSync(f.root, 0o755);
      if (unsafe === 'symlink') fs.symlinkSync(target, f.statePath);
      let config = f;
      if (unsafe === 'parent-link') {
        const alias = `${f.root}-alias`;
        fs.symlinkSync(f.root, alias);
        config = { socketPath: path.join(alias, 'p.sock'), statePath: path.join(alias, 'harness-state.json') };
      }
      load().apply(f.ctx, config);
      f.emit(session, event('turn/start', { turn: 1 }, 1));
      assert.equal(fs.readFileSync(target, 'utf8'), 'KEEP');
      if (unsafe !== 'symlink') assert.equal(fs.existsSync(f.statePath), false);
      assert.ok(f.warnings.length > 0);
    } finally {
      await f.dispose();
      fs.rmSync(`${f.root}-alias`, { force: true });
      f.remove();
    }
  }
});

test('coalesces saturated transport queue and eventually delivers the latest terminal', async () => {
  const f = fixture();
  const envelopes = [];
  const server = net.createServer((socket) => {
    const chunks = [];
    socket.on('data', (chunk) => chunks.push(chunk));
    socket.on('end', () => envelopes.push(JSON.parse(Buffer.concat(chunks))));
  });
  try {
    await new Promise((resolve) => server.listen(f.socketPath, resolve));
    fs.chmodSync(f.socketPath, 0o600);
    load().apply(f.ctx, f);
    f.emit(session, event('turn/start', { turn: 1 }, 1));
    for (let seq = 2; seq <= 200; seq += 1) f.emit(session, event('tool/result', {}, seq));
    f.emit(session, event('turn/end', { turn: 1, reason: { kind: 'completed' } }, 201));
    for (let attempt = 0; attempt < 200; attempt += 1) {
      if (envelopes.some((value) => value.payload && payload(value).hook_event_name === 'Stop')) break;
      await delay(10);
    }
    const values = envelopes.filter((value) => value.payload);
    assert.equal(payload(values[0]).hook_event_name, 'UserPromptSubmit');
    assert.equal(payload(values.at(-1)).hook_event_name, 'Stop');
    assert.ok(values.length <= 4, 'Progress queue is coalesced, not one entry per callback');
    assert.deepEqual(f.snapshot().events, values.slice(-2));
  } finally {
    await f.dispose();
    await new Promise((resolve) => server.close(resolve));
    f.remove();
  }
});

test('ignores progress appended after a terminal until the next real turn/start', async () => {
  const f = fixture();
  try {
    load().apply(f.ctx, f);
    f.emit(session, event('turn/start', { turn: 1 }, 1));
    f.emit(session, event('turn/end', { turn: 1, reason: { kind: 'aborted' } }, 2));
    const terminal = f.snapshot().events;
    f.emit(session, event('tool/result', {}, 3));
    assert.deepEqual(f.snapshot().events, terminal);
    f.emit(session, event('turn/start', { turn: 2 }, 4));
    assert.deepEqual(f.snapshot().events.map((value) => payload(value).hook_event_name), ['UserPromptSubmit']);
    assert.equal(payload(f.snapshot().events[0]).turn_id, '2');
  } finally { await f.dispose(); f.remove(); }
});

test('snapshot has a 512 KiB ceiling and prioritizes active turns over terminal history', async () => {
  const f = fixture(Array.from({ length: 600 }, (_, index) => ({
    id: `active-${index}-${'x'.repeat(400)}`,
    events: [event('turn/start', { turn: 1 }, 0), event('approval/asked', {}, 1)],
  })));
  try {
    load().apply(f.ctx, f);
    f.emit(session, event('turn/start', { turn: 1 }, 1));
    f.emit(session, event('turn/end', { turn: 1, reason: { kind: 'completed' } }, 2));
    const snapshot = f.snapshot();
    assert.ok(fs.statSync(f.statePath).size <= 512 * 1024);
    assert.ok(snapshot.events.length > 0);
    const values = snapshot.events.map(payload);
    const firstTerminal = values.findIndex((value) => value.hook_event_name === 'Stop');
    if (firstTerminal >= 0) assert.equal(firstTerminal, values.length - 1);
    assert.equal(values[0].session_id.startsWith('active-'), true);
    assert.deepEqual(fs.readdirSync(f.root), ['harness-state.json']);
  } finally { await f.dispose(); f.remove(); }
});

test('missing snapshot directory is never created by the plugin', async () => {
  const f = fixture();
  const missing = path.join(f.root, 'missing');
  try {
    load().apply(f.ctx, { socketPath: path.join(missing, 'p.sock'), statePath: path.join(missing, 'state.json') });
    f.emit(session, event('turn/start', { turn: 1 }, 1));
    assert.equal(fs.existsSync(missing), false);
    assert.ok(f.warnings.length);
  } finally { await f.dispose(); f.remove(); }
});

test('oversized optional working directory cannot exceed the payload limit', () => {
  const envelope = load().normalizeEvent({ ...session, header: { cwd: `/${'x'.repeat(70000)}` } },
    event('turn/start', { turn: 1 }));
  assert.ok(Buffer.from(envelope.payload, 'base64').length <= 64 * 1024);
  assert.equal(payload(envelope).cwd, undefined);
});

test('heartbeat replays undelivered start and terminal after the receiver reconnects', async (t) => {
  const f = fixture();
  const envelopes = [];
  const server = net.createServer((socket) => {
    const chunks = [];
    socket.on('data', (chunk) => chunks.push(chunk));
    socket.on('end', () => envelopes.push(JSON.parse(Buffer.concat(chunks))));
  });
  t.mock.timers.enable({ apis: ['Date', 'setInterval'], now: 1792540800000 });
  try {
    load().apply(f.ctx, f);
    f.emit(session, event('turn/start', { turn: 1 }, 1));
    f.emit(session, event('turn/end', { turn: 1, reason: { kind: 'completed' } }, 2));
    const durable = f.snapshot().events;
    await delay(10);
    await new Promise((resolve) => server.listen(f.socketPath, resolve));
    fs.chmodSync(f.socketPath, 0o600);
    t.mock.timers.tick(2000);
    for (let attempt = 0; attempt < 100 && envelopes.length < 2; attempt += 1) await delay(10);
    assert.deepEqual(envelopes, durable);
    assert.deepEqual(f.snapshot().events, durable);
  } finally {
    await f.dispose();
    t.mock.timers.reset();
    await new Promise((resolve) => server.close(resolve));
    f.remove();
  }
});
