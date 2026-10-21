const { createHash, randomUUID } = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');

const PROVIDER = 'deepseekHarness';
const END_HOOKS = {
  completed: 'Stop', error: 'StopFailure', aborted: 'Interrupt',
  blocked: 'StopFailure', 'max-tokens': 'StopFailure',
};

function normalizeEvent(session, event, currentTurn, title) {
  if (typeof session?.id !== 'string' || !session.id.trim() || session.id.length > 512
    || session.header?.origin === 'subagent' || !Number.isSafeInteger(event?.seq) || event.seq < 0
    || !Number.isFinite(event.time) || !Number.isFinite(new Date(event.time).getTime())) return null;
  let hook;
  if (event.type === 'turn/start') hook = 'UserPromptSubmit';
  if (event.type === 'turn/end' && Object.hasOwn(END_HOOKS, event.data?.reason?.kind)) {
    hook = END_HOOKS[event.data.reason.kind];
  }
  if (event.type === 'tool/result' || event.type === 'approval/decided') hook = 'PostToolUse';
  if (event.type === 'approval/asked') hook = 'PermissionRequest';
  if (!hook) return null;
  const turn = Number.isSafeInteger(event.data?.turn) && event.data.turn >= 0
    ? String(event.data.turn) : currentTurn;
  if (typeof turn !== 'string' || !/^\d+$/.test(turn)) return null;
  const payload = {
    session_id: session.id,
    turn_id: turn,
    hook_event_name: hook,
    timestamp: new Date(event.time).toISOString(),
    harness_event_type: event.type,
    harness_event_seq: event.seq,
  };
  if (typeof session.header?.cwd === 'string' && session.header.cwd.length <= 4096
    && path.isAbsolute(session.header.cwd)) {
    payload.cwd = session.header.cwd;
  }
  if (typeof title === 'string') {
    const clean = [...title.replace(/[\u0000-\u001f\u007f-\u009f\u200b\u200e\u200f\u202a-\u202e\u2060-\u206f\ufeff]/g, '')
      .replace(/\s+/gu, ' ').trim()].slice(0, 160).join('');
    if (clean) payload.task_title = clean;
  }
  const bytes = createHash('sha256').update(`${session.id}:${event.seq}`).digest().subarray(0, 16);
  const hex = bytes.toString('hex');
  return {
    schemaVersion: 1,
    provider: PROVIDER,
    eventID: `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`,
    payload: Buffer.from(JSON.stringify(payload)).toString('base64'),
  };
}

async function sendEnvelope(socketPath, envelope) {
  assertPrivateParent(socketPath);
  const socket = fs.lstatSync(socketPath);
  if (socket.isSymbolicLink() || !socket.isSocket() || socket.uid !== process.getuid()
    || (socket.mode & 0o7777) !== 0o600) throw new Error('unsafe socket endpoint');
  const wire = JSON.stringify(envelope);
  if (Buffer.byteLength(wire) > 128 * 1024) throw new Error('oversized bridge envelope');
  await new Promise((resolve, reject) => {
    const client = net.createConnection(socketPath);
    client.setTimeout(500, () => client.destroy(new Error('bridge socket timeout')));
    client.once('error', reject);
    client.once('connect', () => client.end(wire));
    client.once('finish', () => { client.destroy(); resolve(); });
  });
}

// Snapshot and socket must live in the same canonical private directory, created by Vibe Island.
function assertPrivateParent(filePath) {
  if (!path.isAbsolute(filePath)) throw new Error('unsafe bridge path');
  const parentPath = path.dirname(filePath);
  const parent = fs.lstatSync(parentPath);
  if (parent.isSymbolicLink() || !parent.isDirectory() || parent.uid !== process.getuid()
    || (parent.mode & 0o7777) !== 0o700 || fs.realpathSync(parentPath) !== parentPath) {
    throw new Error('unsafe bridge directory');
  }
}

function writeSnapshot(statePath, snapshot) {
  assertPrivateParent(statePath);
  try {
    const existing = fs.lstatSync(statePath);
    if (!existing.isFile() || existing.isSymbolicLink() || existing.uid !== process.getuid()
      || (existing.mode & 0o7777) !== 0o600) throw new Error('unsafe bridge snapshot');
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const temporary = `${statePath}.${process.pid}.${randomUUID()}.tmp`;
  let descriptor;
  try {
    descriptor = fs.openSync(temporary,
      fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    fs.writeFileSync(descriptor, JSON.stringify(snapshot));
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(temporary, statePath);
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    try { fs.unlinkSync(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}

function recordEvents(record) {
  return record.start && record.start.eventID !== record.latest.eventID
    ? [record.start, record.latest] : [record.latest];
}

function apply(ctx, config = {}) {
  if (typeof config.socketPath !== 'string' || !path.isAbsolute(config.socketPath)) {
    throw new Error('Harness bridge requires an absolute socketPath');
  }
  if (config.statePath !== undefined && (typeof config.statePath !== 'string'
    || !path.isAbsolute(config.statePath) || config.statePath === config.socketPath
    || path.dirname(config.statePath) !== path.dirname(config.socketPath))) {
    throw new Error('Harness bridge statePath must share the socket directory');
  }
  let active = true;
  let recovering = true;
  let pumping = false;
  let pending = Promise.resolve();
  let endpointFailed = false;
  let snapshotFailed = false;
  const records = new Map();
  const titles = new Map();
  const queued = new Map();
  const controls = [{ type: 'bridge/ready', provider: PROVIDER, pid: process.pid }];
  const warn = (message) => { try { ctx.logger.warn(message); } catch {} };
  const titleOf = (session) => {
    try {
      return titles.get(session.id)?.title ?? ctx.get?.('sessionTitle')?.get(session)?.title;
    } catch { return titles.get(session.id)?.title; }
  };
  const publish = (generatedAt = Date.now()) => {
    const now = Date.now();
    for (const [id, record] of records) {
      if (record.endedAt !== undefined && now - record.endedAt >= 120000) {
        records.delete(id);
        queued.delete(id);
      }
    }
    if (!config.statePath) return;
    const events = [];
    let bytes = 128;
    // shortcut: 512 KiB prioritizes active, then newest terminal records; extreme concurrency can omit old active records.
    const ordered = [...records.values()].sort((a, b) =>
      Number(a.endedAt !== undefined) - Number(b.endedAt !== undefined)
      || (b.endedAt ?? b.updatedAt) - (a.endedAt ?? a.updatedAt));
    for (const record of ordered) {
      const values = recordEvents(record);
      const size = Buffer.byteLength(JSON.stringify(values)) + 1;
      if (bytes + size > 512 * 1024) continue;
      events.push(...values);
      bytes += size;
    }
    try {
      writeSnapshot(config.statePath, { schemaVersion: 1, pid: process.pid, generatedAt, events });
      snapshotFailed = false;
    } catch {
      if (!snapshotFailed) warn('Vibe Island bridge: private snapshot unavailable');
      snapshotFailed = true;
    }
  };
  const send = async (envelope) => {
    try {
      await sendEnvelope(config.socketPath, envelope);
      endpointFailed = false;
      return true;
    } catch {
      if (!endpointFailed) warn('Vibe Island bridge: receiver unavailable');
      endpointFailed = true;
      return false;
    }
  };
  const pump = () => {
    if (pumping || !active) return;
    pumping = true;
    pending = Promise.resolve().then(async () => {
      while (active && (controls.length || queued.size)) {
        if (controls.length) { await send(controls.shift()); continue; }
        const [id, record] = queued.entries().next().value;
        queued.delete(id);
        for (const envelope of recordEvents(record)) {
          if (!active) break;
          if (record.sentStart === envelope.eventID || record.sentLatest === envelope.eventID) continue;
          if (await send(envelope)) {
            if (envelope.eventID === record.start?.eventID) record.sentStart = envelope.eventID;
            else record.sentLatest = envelope.eventID;
          }
        }
      }
    }).catch(() => warn('Vibe Island bridge: transport unavailable')).finally(() => { pumping = false; });
  };
  const accept = (session, event) => {
    if (!active || session?.header?.origin === 'subagent') return;
    if (event?.type === 'session/title' && typeof event.data?.title === 'string'
      && Number.isSafeInteger(event.seq) && event.seq > (titles.get(session.id)?.seq ?? -1)) {
      titles.set(session.id, { title: event.data.title, seq: event.seq });
      return;
    }
    const previous = records.get(session?.id);
    if (previous && (event?.seq <= previous.seq
      || (previous.endedAt !== undefined && event?.type !== 'turn/start'))) return;
    const envelope = normalizeEvent(session, event, previous?.turn, titleOf(session));
    if (!envelope) return;
    const turn = JSON.parse(Buffer.from(envelope.payload, 'base64')).turn_id;
    const record = event.type === 'turn/start' || !previous || previous.turn !== turn
      ? { turn, start: event.type === 'turn/start' ? envelope : undefined } : previous;
    record.latest = envelope;
    record.seq = event.seq;
    record.updatedAt = Date.now();
    if (event.type === 'turn/end') record.endedAt = Date.now();
    records.set(session.id, record);
    queued.set(session.id, record);
    if (!recovering) { publish(); pump(); }
  };
  ctx.on('session/event', (session, event) => {
    try { accept(session, event); } catch { warn('Vibe Island bridge: unsupported session event'); }
  }, { global: true });
  ctx.on('session/disposed', (session) => {
    titles.delete(session.id);
    const record = records.get(session.id);
    // Disposal without a committed turn/end is not evidence of completion.
    if (record && record.endedAt === undefined) {
      records.delete(session.id);
      queued.delete(session.id);
      publish();
    }
  }, { global: true });
  for (const agent of ctx.agents.list()) {
    const session = agent.session;
    if (agent.status !== 'running' || session?.header?.origin === 'subagent'
      || typeof session?.eventAt !== 'function' || !Number.isSafeInteger(session.seq)) continue;
    let latest;
    // Recover from the actual open turn only, never an idle agent's historical completion.
    for (let seq = session.seq - 1; seq >= 0; seq -= 1) {
      const event = session.eventAt(seq);
      if (event?.type === 'turn/end') break;
      if (event?.type === 'turn/start') {
        accept(session, event);
        if (latest) accept(session, latest);
        break;
      }
      if (!latest && normalizeEvent(session, event, '0', titleOf(session))) latest = event;
    }
  }
  recovering = false;
  publish();
  pump();
  const heartbeat = setInterval(() => {
    if (!active) return;
    publish();
    for (const [id, record] of records) queued.set(id, record);
    pump();
  }, 2000);
  heartbeat.unref?.();
  ctx.effect(() => () => {
    if (!active) return pending;
    active = false;
    clearInterval(heartbeat);
    queued.clear();
    publish(0);
    return pending.then(() => sendEnvelope(config.socketPath,
      { type: 'bridge/stopped', provider: PROVIDER, pid: process.pid })).catch(() => {});
  });
}

module.exports = { name: 'vibe-island-harness-bridge', inject: ['sessions', 'agents'],
  apply, normalizeEvent, sendEnvelope };
