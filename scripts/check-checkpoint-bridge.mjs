// Deterministic checkpoint routing tests through the pinned public ACP builder.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, mkdir, symlink, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { AgentApp, client, RequestError } from '../.build/agent/node_modules/@agentclientprotocol/sdk/dist/acp.js';
import * as bridge from './claude-acp-native-subagents.mjs';

assert.equal(typeof bridge.installFileCheckpointBridge, 'function', 'Checkpoint preview needs an explicitly negotiated bridge');
const directory = await mkdtemp(path.join(tmpdir(), 'ccode-checkpoint-wire-'));
const physical = path.join(directory, 'project'), selected = path.join(directory, 'project-alias');
await mkdir(physical); await symlink(physical, selected);
await mkdir(path.join(directory, 'foreign')); await symlink(path.join(directory, 'foreign'), path.join(physical, 'escape'));
const records = [], raw = [], calls = [];
let delayed, release, failing = false;
let returnedPaths = ['answer.py'];
class Provider {
  sessions = {};
  client = { extNotification: async (method, params) => raw.push({ method, params }) };
  async initialize() { return { protocolVersion: 1, agentCapabilities: {}, _meta: { existing: true } }; }
  async newSession(params) {
    const sessionId = randomUUID();
    const session = this.sessions[sessionId] = { cwd: selected, creationParams: params, turnQueue: [], query: {
      rewindFiles: async (id, options) => { calls.push({ id, options }); if (failing) throw Error('provider rejected'); if (delayed) await delayed; return { canRewind: true, filesChanged: returnedPaths, insertions: 2, deletions: 1 }; },
    }, input: { push() {} } };
    records.push(session); return { sessionId };
  }
  async loadSession(params) { return this.newSession(params); }
  async unstable_resumeSession(params) { return this.newSession(params); }
  async prompt(params) {
    await Promise.resolve(); // Association must survive the adapter's awaits.
    const session = this.sessions[params.sessionId];
    const turn = { promptUuid: randomUUID(), settled: false };
    session.turnQueue.push(turn);
    this.ensureConsumer(session, params.sessionId);
    await this.client.extNotification('_claude/sdkMessage', { sessionId: params.sessionId,
      message: { type: 'user', uuid: turn.promptUuid, parent_tool_use_id: null, message: { content: 'private prompt' } } });
    turn.settled = true; return { stopReason: 'end_turn' };
  }
  ensureConsumer(session, id) { return this.runConsumer(session, { sessionId: id }); }
  runConsumer() {}
  async dispose() {}
}
bridge.installFileCheckpointBridge(Provider, AgentApp, RequestError);
const request = { protocolVersion: 1, clientInfo: { name: 'ccode', version: '0.1' }, clientCapabilities: { _meta: { ccode: { fileCheckpoints: true } } } };
const provider = new Provider(), other = new Provider();
function app(agent) {
  return new AgentApp().onRequest('initialize', ctx => {
    agent.client.extNotification = async (method, params) => {
      if (method === '_claude/sdkMessage') raw.push({ method, params });
      else await ctx.client.notify(method, params);
    };
    return agent.initialize(ctx.params);
  })
    .onRequest('session/new', ctx => agent.newSession(ctx.params))
    .onRequest('session/prompt', ctx => agent.prompt(ctx.params));
}
const notifications = [];
await client().onNotification('_ccode/checkpoint', { parse: value => value }, ctx => notifications.push(ctx.params)).connectWith(app(provider), async peer => {
  const handshake = await peer.request('initialize', request);
  assert.equal(handshake._meta.existing, true);
  const cap = handshake._meta.ccode.fileCheckpoints;
  assert.equal(cap.version, 1); assert.equal(cap.previewMethod, '_ccode/checkpoint/preview');
  assert.equal(cap.restoreMethod, undefined, 'Preview capability never implies file restore');
  const created = await peer.request('session/new', { cwd: selected, mcpServers: [] });
  assert.equal(records.at(-1).creationParams._meta.claudeCode.options.enableFileCheckpointing, true);
  const localID = randomUUID();
  await peer.request('session/prompt', { sessionId: created.sessionId, prompt: [{ type: 'text', text: 'fixture' }], _meta: { ccode: { promptId: localID } } });
  assert.equal(notifications.length, 1, 'One compact receipt, no duplicate user transcript');
  const receipt = notifications[0];
  assert.equal(receipt.promptId, localID); assert.equal(receipt.sessionId, created.sessionId);
  assert.ok(receipt.checkpointId); assert.equal(receipt.connectionId, cap.connectionId);
  assert.equal(JSON.stringify(receipt).includes('private prompt'), false);
  assert.equal(raw.length, 0, 'Tracking never exposes raw SDK prompt/tool payloads');
  const params = { ...receipt }; delete params.version;
  const preview = await peer.request(cap.previewMethod, params);
  assert.equal(preview.canRewind, true); assert.deepEqual(preview.filesChanged, ['answer.py']);
  assert.equal(preview.declaredComplete, false); assert.equal(preview.checkpointId, receipt.checkpointId);
  assert.deepEqual(calls.at(-1), { id: receipt.checkpointId, options: { dryRun: true } });
  returnedPaths = [path.join(await realpath(physical), 'answer.py')];
  assert.deepEqual((await peer.request(cap.previewMethod, params)).filesChanged, returnedPaths,
    'A canonical SDK path inside a selected alias is the same workspace');
  for (const bad of [['../foreign/source'], ['escape/source'], [''], [path.join(directory, 'foreign/source')]]) {
    returnedPaths = bad;
    await assert.rejects(peer.request(cap.previewMethod, params));
  }
  returnedPaths = ['answer.py'];
  for (const bad of [{ ...params, sessionId: 'foreign' }, { ...params, checkpointId: randomUUID() }, { ...params, promptId: randomUUID() }, { ...params, connectionId: randomUUID() }, { ...params, checkpointId: '' }]) {
    const before = calls.length;
    await assert.rejects(peer.request(cap.previewMethod, bad)); assert.equal(calls.length, before);
  }
  const session = records.at(-1);
  await provider.client.extNotification('_claude/sdkMessage', { sessionId: created.sessionId, message: { type: 'user', uuid: receipt.checkpointId, parent_tool_use_id: 'child' } });
  await provider.client.extNotification('_claude/sdkMessage', { sessionId: created.sessionId, message: { type: 'user', uuid: randomUUID(), parent_tool_use_id: null } });
  assert.equal(notifications.length, 1, 'Child/foreign/duplicate echo cannot create checkpoint authority');
  session.turnQueue.push({ settled: false });
  await assert.rejects(peer.request(cap.previewMethod, params)); session.turnQueue.pop();
  session.nativeSubagentsByTaskId = new Map([['child', { terminalState: undefined }]]);
  await assert.rejects(peer.request(cap.previewMethod, params)); session.nativeSubagentsByTaskId.clear();
  session.asyncTaskRuntime = { tasks: new Map([['bash', { ignored: false, state: 'running' }]]) };
  await assert.rejects(peer.request(cap.previewMethod, params)); session.asyncTaskRuntime.tasks.clear();
  failing = true;
  await assert.rejects(peer.request(cap.previewMethod, params), error => error.code === -32603 && error.data?.details === 'provider rejected'); failing = false;
  delayed = new Promise(resolve => { release = resolve; });
  const priorCalls = calls.length;
  const pending = peer.request(cap.previewMethod, params);
  while (calls.length === priorCalls) await new Promise(resolve => setImmediate(resolve));
  const oldQuery = session.query;
  session.query = { rewindFiles: oldQuery.rewindFiles }; release();
  await assert.rejects(pending, /changed|unavailable/i); delayed = undefined;
  await assert.rejects(peer.request(cap.previewMethod, params), /changed|unavailable/i);
  await client().connectWith(app(other), async foreignPeer => {
    await foreignPeer.request('initialize', request);
    await assert.rejects(foreignPeer.request(cap.previewMethod, params));
  });
});
for (const foreignRequest of [{ ...request, clientInfo: { name: 'other-client' } }, { ...request, clientCapabilities: {} }]) {
  const foreign = new Provider();
  await client().connectWith(app(foreign), async peer => {
    assert.equal((await peer.request('initialize', foreignRequest))._meta?.ccode?.fileCheckpoints, undefined);
    await peer.request('session/new', { cwd: selected, mcpServers: [] });
    assert.equal(records.at(-1).creationParams._meta?.claudeCode?.options?.enableFileCheckpointing, undefined);
    await assert.rejects(peer.request('_ccode/checkpoint/preview', { sessionId: 'root', checkpointId: 'id', promptId: 'local', connectionId: 'connection' }));
  });
}
await rm(directory, { recursive: true, force: true });
console.log('Checkpoint bridge: public ACP routing, exact echoed root identity, no raw content, read-only preview, foreign/child/duplicate rejection, live-work and stale-query guards verified.');
