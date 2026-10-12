// Disposable filesystem and actual public ACP routing. No model calls.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, readFile, rm, rename, symlink, link, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { AgentApp, client, RequestError } from '../.build/agent/node_modules/@agentclientprotocol/sdk/dist/acp.js';
import { installFileCheckpointBridge } from './claude-acp-checkpoints.mjs';

const root = await mkdtemp(path.join(tmpdir(), 'ccode-restore-wire-'));
const project = path.join(root, 'project'), recovery = path.join(root, 'recovery');
await mkdir(project); await mkdir(recovery, { mode: 0o700 });
const file = path.join(project, 'answer.py'), sentinel = path.join(project, 'unrelated.txt');
await writeFile(sentinel, 'keep unrelated\n');
let paths = ['answer.py'], restoreCalls = 0, rejectRestore = false, skippedLinks = 0, delayed, release;
class Provider {
  sessions = {};
  client = { extNotification: async () => {} };
  async initialize() { return { protocolVersion: 1, agentCapabilities: {} }; }
  async newSession(params) {
    const sessionId = randomUUID();
    this.sessions[sessionId] = { cwd: project, creationParams: params, turnQueue: [], query: {
      rewindFiles: async (_, options) => {
        if (!options?.dryRun) {
          restoreCalls++;
          if (delayed) await delayed;
          await writeFile(file, 'original\n');
          if (rejectRestore) throw Error('Simulated failure after one file changed');
        }
        return { canRewind: true, filesChanged: paths, insertions: 1, deletions: 1, ...(!options?.dryRun ? { skippedLinks } : {}) };
      },
    } }; return { sessionId };
  }
  async prompt(params) {
    const session = this.sessions[params.sessionId], turn = { promptUuid: randomUUID(), settled: false };
    session.turnQueue.push(turn); this.ensureConsumer(session, params.sessionId);
    await this.client.extNotification('_claude/sdkMessage', { sessionId: params.sessionId,
      message: { type: 'user', uuid: turn.promptUuid, parent_tool_use_id: null } });
    turn.settled = true; return { stopReason: 'end_turn' };
  }
  ensureConsumer() {}
  async closeSession(params) { delete this.sessions[params.sessionId]; return {}; }
}
installFileCheckpointBridge(Provider, AgentApp, RequestError);
const receipts = [], provider = new Provider();
const app = new AgentApp().onRequest('initialize', ctx => {
  provider.client.extNotification = (method, params) => ctx.client.notify(method, params);
  return provider.initialize(ctx.params);
}).onRequest('session/new', ctx => provider.newSession(ctx.params))
  .onRequest('session/prompt', ctx => provider.prompt(ctx.params))
  .onRequest('session/close', ctx => provider.closeSession(ctx.params));
try {
  await client().onNotification('_ccode/checkpoint', { parse: value => value }, ctx => receipts.push(ctx.params)).connectWith(app, async peer => {
    const cap = (await peer.request('initialize', { protocolVersion: 1, clientInfo: { name: 'ccode', version: '0.1' },
      clientCapabilities: { _meta: { ccode: { fileCheckpoints: true, fileCheckpointRecoveryDirectory: recovery } } } }))._meta.ccode.fileCheckpoints;
    assert.equal(cap.restoreMethod, '_ccode/checkpoint/restore', 'Restoration must be negotiated separately from preview');
    const session = await peer.request('session/new', { cwd: project, mcpServers: [] });
    const prompt = { sessionId: session.sessionId, prompt: [{ type: 'text', text: 'fixture' }], _meta: { ccode: { promptId: randomUUID() } } };
    await peer.request('session/prompt', prompt);
    const params = receipts.at(-1);
    const preview = () => peer.request(cap.previewMethod, params);
    const restore = result => peer.request(cap.restoreMethod, { ...params, previewToken: result.previewToken });
    await writeFile(file, 'edited\n');
    let inspected = await preview();
    assert.ok(inspected.previewToken); assert.equal(await readFile(file, 'utf8'), 'edited\n');
    await writeFile(file, 'external work\n');
    await assert.rejects(restore(inspected), /changed|conflict/i);
    assert.equal(restoreCalls, 0); assert.equal(await readFile(file, 'utf8'), 'external work\n');
    inspected = await preview();
    await writeFile(file + '.replacement', 'external work\n'); await rename(file + '.replacement', file);
    await assert.rejects(restore(inspected), /changed|conflict/i, 'Same bytes in a replaced inode are stale');
    assert.equal(restoreCalls, 0);
    inspected = await preview(); paths = ['answer.py', 'new.py'];
    await assert.rejects(restore(inspected), /changed|conflict/i); paths = ['answer.py'];
    assert.equal(restoreCalls, 0);
    const nested = path.join(project, 'nested'); await mkdir(nested); await writeFile(path.join(nested, 'answer.txt'), 'nested edit\n');
    paths = ['nested/answer.txt']; inspected = await preview();
    await rename(nested, nested + '-before'); await mkdir(nested); await writeFile(path.join(nested, 'answer.txt'), 'nested edit\n');
    await assert.rejects(restore(inspected), /changed|conflict/i, 'Replacing the parent directory invalidates the preview');
    assert.equal(restoreCalls, 0); paths = ['answer.py'];
    const conflicting = await peer.request('session/new', { cwd: project, mcpServers: [] });
    provider.sessions[conflicting.sessionId].turnQueue.push({ settled: false });
    await assert.rejects(preview(), /work|finish/i, 'Overlapping agent work must finish first');
    delete provider.sessions[conflicting.sessionId];
    inspected = await preview();
    const foreign = { ...params, previewToken: inspected.previewToken, connectionId: randomUUID() };
    await assert.rejects(peer.request(cap.restoreMethod, foreign));
    const result = await restore(inspected);
    assert.equal(result.status, 'completed'); assert.equal(result.declaredComplete, false);
    assert.equal(await readFile(file, 'utf8'), 'original\n'); assert.equal(await readFile(sentinel, 'utf8'), 'keep unrelated\n');
    const manifest = JSON.parse(await readFile(path.join(result.recoveryDirectory, 'manifest.json'), 'utf8'));
    assert.equal(manifest.status, 'completed'); assert.equal(manifest.files.length, 1);
    assert.equal(await readFile(path.join(result.recoveryDirectory, manifest.files[0].backup), 'utf8'), 'external work\n');
    await assert.rejects(restore(inspected)); assert.equal(restoreCalls, 1, 'A token is single-use');
    await writeFile(file, 'new edit\n'); inspected = await preview();
    rejectRestore = true;
    const uncertain = await restore(inspected); rejectRestore = false;
    assert.equal(uncertain.status, 'uncertain'); assert.equal(uncertain.declaredComplete, false);
    assert.equal(await readFile(path.join(uncertain.recoveryDirectory, '0.before'), 'utf8'), 'new edit\n');
    await writeFile(file, 'third edit\n'); inspected = await preview();
    skippedLinks = 1; assert.equal((await restore(inspected)).status, 'partial'); skippedLinks = 0;
    await writeFile(file, 'fourth edit\n'); inspected = await preview();
    delayed = new Promise(resolve => { release = resolve; });
    const prior = restoreCalls, pending = restore(inspected);
    while (restoreCalls === prior) await new Promise(resolve => setImmediate(resolve));
    await assert.rejects(peer.request('session/prompt', { ...prompt, _meta: { ccode: { promptId: randomUUID() } } }), /restor/i);
    await assert.rejects(peer.request('session/close', { sessionId: session.sessionId }), /restor/i);
    await assert.rejects(peer.request('session/new', { cwd: project, mcpServers: [] }), /restor/i);
    await assert.rejects(restore(inspected), /restor|unavailable|expired/i);
    release(); assert.equal((await pending).status, 'completed'); delayed = undefined;
    await rm(file); await symlink(sentinel, file);
    const unsafe = await preview(); assert.equal(unsafe.previewToken, undefined); assert.match(unsafe.restoreUnavailable, /link|regular/i);
    await rm(file); await writeFile(file, 'hardlink\n'); await link(file, file + '.link');
    assert.equal((await preview()).previewToken, undefined); await rm(file + '.link');
    // Missing files can be restored, but a later external creation invalidates the preview.
    await rm(file); inspected = await preview(); assert.ok(inspected.previewToken);
    await writeFile(file, 'external creation\n'); await assert.rejects(restore(inspected), /changed|conflict/i);
    await rm(file); inspected = await preview(); const missing = await restore(inspected);
    const missingManifest = JSON.parse(await readFile(path.join(missing.recoveryDirectory, 'manifest.json'), 'utf8'));
    assert.equal(missingManifest.files[0].backup, null); assert.equal(await readFile(file, 'utf8'), 'original\n');
    assert.ok((await readdir(recovery)).length >= 4, 'Recovery copies survive successful and uncertain writes');
    console.log('Restore: exact preview/query binding, external edit/inode/file-list conflicts, one-shot tokens, streamed disk recovery, partial/uncertain outcomes, operation ownership and unsafe-link refusal verified.');
  });
} finally { release?.(); await rm(root, { recursive: true, force: true }); }
