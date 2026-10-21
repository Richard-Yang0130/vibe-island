// Run with the installed Electron executable in ELECTRON_RUN_AS_NODE mode.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { createRequire } = require('node:module');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');
const { setTimeout: delay } = require('node:timers/promises');

const anchor = '/Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/package.json';
const packaged = createRequire(anchor);
const { Context } = packaged('@deepseek-ai/cordis');
const { LlmAdapter, createUserMessage } = packaged('@deepseek-ai/dsh-llm');
const bridge = require('./bridge.cjs');

async function waitFor(predicate) {
  for (let i = 0; i < 300; i += 1) {
    if (predicate()) return;
    await delay(10);
  }
  throw new Error('Timed out waiting for Harness bridge evidence');
}

for (const [scenario, expectedReason, expectedHook] of [
  ['completed', 'completed', 'Stop'],
  ['failed', 'error', 'StopFailure'],
  ['interrupted', 'aborted', 'Interrupt'],
  ['receiver-offline', 'completed', null],
  ['startup-running', 'completed', 'Stop'],
]) {
  test(`packaged AgentLoop -> session/event -> socket: ${scenario}`, { timeout: 10000 }, async () => {
    const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-runtime-')));
    const socketPath = path.join(root, 'p.sock');
    const envelopes = [];
    const events = [];
    const server = net.createServer((socket) => {
      const chunks = [];
      socket.on('data', (chunk) => chunks.push(chunk));
      socket.on('end', () => envelopes.push(JSON.parse(Buffer.concat(chunks))));
    });
    const ctx = new Context();
    try {
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
      fs.chmodSync(socketPath, 0o600);
      ctx.on('session/event', (_session, event) => events.push(event), { global: true });
      ctx.on('agent/error', () => {}, { global: true });
      const fibers = [];
      for (const name of ['dsh-llm', 'dsh-session', 'dsh-agent', 'dsh-system-prompt',
        'dsh-tools', 'dsh-session-projection', 'dsh-agent-loop']) {
        fibers.push(ctx.plugin(packaged(`@deepseek-ai/${name}`).default, {}));
      }
      await Promise.all(fibers);
      const statePath = path.join(root, 'harness-state.json');
      const bridgeConfig = { socketPath: scenario === 'receiver-offline'
        ? path.join(root, 'missing.sock') : socketPath, statePath };
      if (scenario !== 'startup-running') await ctx.plugin(bridge, bridgeConfig);
      let generating = false;
      const gate = Promise.withResolvers();
      class LocalAdapter extends LlmAdapter {
        async resolveModel(provider, id) { return { provider, id, name: 'Local feasibility fixture' }; }
        async *stream(options) {
          generating = true;
          if (scenario === 'startup-running') await gate.promise;
          if (scenario === 'failed') throw new Error('Expected local feasibility failure');
          if (scenario === 'interrupted') {
            await new Promise((resolve, reject) => {
              if (options.signal.aborted) { reject(options.signal.reason); return; }
              options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true });
            });
          }
          yield { type: 'text-delta', index: 0, text: 'local feasibility result' };
          yield { type: 'finish', reason: { kind: 'stop' } };
        }
      }
      ctx.llm.registerAdapter(['feasibility-fixture'], new LocalAdapter());
      const agent = await ctx.agentLoop.create(`feasibility-${scenario}`,
        { provider: 'feasibility-fixture', model: 'fixture-model' }, { cwd: root });
      agent.send(createUserMessage({ content: [{ type: 'text', text: 'local probe' }],
        source: { kind: 'user' } }), 'next-turn', true);
      if (scenario === 'startup-running') {
        await waitFor(() => generating);
        assert.equal(agent.status, 'running');
        const start = events.findLast((value) => value.type === 'turn/start');
        await ctx.plugin(bridge, bridgeConfig);
        const recovery = JSON.parse(fs.readFileSync(statePath, 'utf8'));
        assert.deepEqual(recovery.events.map((value) => value.eventID),
          [bridge.normalizeEvent(agent.session, start).eventID]);
        gate.resolve();
      }
      if (scenario === 'interrupted') {
        await waitFor(() => generating);
        agent.cancel({ kind: 'user' });
      }
      await agent.whenIdle();
      const snapshot = JSON.parse(fs.readFileSync(statePath, 'utf8'));
      assert.equal(snapshot.generatedAt > 0, true);
      const persisted = snapshot.events.map((value) => JSON.parse(Buffer.from(value.payload, 'base64')));
      assert.deepEqual(persisted.map((value) => value.hook_event_name), ['UserPromptSubmit',
        { completed: 'Stop', error: 'StopFailure', aborted: 'Interrupt' }[expectedReason]]);
      assert.deepEqual(JSON.parse(fs.readFileSync(statePath, 'utf8')).events, snapshot.events);
      const terminal = events.findLast((event) => event.type === 'turn/end');
      assert.ok(terminal, 'Actual AgentLoop must publish a turn/end');
      assert.equal(terminal.data.reason.kind, expectedReason);
      if (expectedHook) {
        await waitFor(() => envelopes.some((envelope) => envelope.payload
          && JSON.parse(Buffer.from(envelope.payload, 'base64')).hook_event_name === expectedHook));
      }
      const payloads = envelopes.filter((envelope) => envelope.payload)
        .map((envelope) => JSON.parse(Buffer.from(envelope.payload, 'base64')));
      if (expectedHook) {
        assert.equal(payloads[0].hook_event_name, 'UserPromptSubmit');
        assert.equal(payloads.at(-1).hook_event_name, expectedHook);
      } else assert.equal(payloads.length, 0, 'Missing receiver must not prevent actual task completion');
      assert.ok(envelopes.every((envelope) => envelope.provider === 'deepseekHarness'));
      assert.ok(!JSON.stringify(payloads).includes('local probe'));
      assert.ok(!JSON.stringify(payloads).includes('local feasibility result'));
      console.log(JSON.stringify({ scenario, runtimeVersion: packaged('./package.json').version,
        reason: expectedReason, hooks: payloads.map((payload) => payload.hook_event_name),
        liveAgentLoop: true, externalModelCalls: 0 }));
    } finally {
      await ctx.fiber.dispose();
      await new Promise((resolve) => server.close(resolve));
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
}
