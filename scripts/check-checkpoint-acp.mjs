// One real disposable turn through the production bridge and public ACP wire.
import assert from 'node:assert/strict';
import { mkdtemp, realpath, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { Readable, Writable } from 'node:stream';
import { client, ndJsonStream } from '../.build/agent/node_modules/@agentclientprotocol/sdk/dist/acp.js';

if (process.env.CCODE_REAL_CHECKPOINT !== '1') {
  console.log('Skipped: set CCODE_REAL_CHECKPOINT=1 for one authenticated disposable ACP checkpoint turn.');
  process.exit(0);
}
const root = await realpath(await mkdtemp(path.join(tmpdir(), 'ccode-real-acp-checkpoint-')));
const recovery = await realpath(await mkdtemp(path.join(tmpdir(), 'ccode-real-acp-recovery-')));
const file = path.join(root, 'checkpoint.txt'), sentinel = path.join(root, 'unrelated.txt');
await writeFile(file, 'original\n'); await writeFile(sentinel, 'keep unrelated\n');
const entry = path.resolve('.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js');
const child = spawn(process.execPath, [path.resolve('scripts/claude-acp-native-subagents.mjs'), entry], { cwd: root, stdio: ['pipe', 'pipe', 'pipe'] });
let stderr = '', permittedWrites = 0, timer;
child.stderr.on('data', chunk => { stderr = (stderr + chunk.toString()).slice(-8192); });
const exited = new Promise(resolve => child.once('exit', (code, signal) => resolve({ code, signal })));
const receipts = [], raw = [];
const app = client()
  .onNotification('_ccode/checkpoint', { parse: value => value }, ctx => receipts.push(ctx.params))
  .onNotification('_claude/sdkMessage', { parse: value => value }, ctx => raw.push(ctx.params))
  .onNotification('session/update', () => {})
  .onRequest('session/request_permission', ctx => {
    const tool = ctx.params.toolCall, input = tool?.rawInput;
    const target = typeof input?.file_path === 'string' ? path.resolve(root, input.file_path) : '';
    const allowed = target === file && (input.content === undefined || input.content === 'after-checkpoint\n');
    const option = allowed && ctx.params.options.find(value => value.kind === 'allow_once');
    if (!option) return { outcome: { outcome: 'cancelled' } };
    if (input.content === 'after-checkpoint\n') permittedWrites++;
    return { outcome: { outcome: 'selected', optionId: option.optionId } };
  });
try {
  const work = app.connectWith(ndJsonStream(Writable.toWeb(child.stdin), Readable.toWeb(child.stdout)), async peer => {
    const handshake = await peer.request('initialize', { protocolVersion: 1, clientInfo: { name: 'ccode', version: '0.1' }, clientCapabilities: { _meta: { ccode: { fileCheckpoints: true, fileCheckpointRecoveryDirectory: recovery } } } });
    const cap = handshake._meta?.ccode?.fileCheckpoints;
    assert.equal(cap?.version, 1, 'Production entry must register and negotiate the new route');
    const session = await peer.request('session/new', { cwd: root, mcpServers: [], _meta: { claudeCode: { options: { tools: ['Read', 'Write'], settingSources: [] } } } });
    for (const [category, selected] of [['model', 'sonnet'], ['mode', 'default']]) {
      const config = session.configOptions.find(value => value.category === category);
      const options = config.options.flatMap(value => value.options ?? [value]);
      const option = options.find(value => category === 'model' ? value.name.toLowerCase().includes(selected) : value.value === selected);
      assert.ok(option, `Required ${category} option`);
      await peer.request('session/set_config_option', { sessionId: session.sessionId, configId: config.id, value: option.value });
    }
    const promptId = randomUUID();
    const result = await peer.request('session/prompt', { sessionId: session.sessionId,
      prompt: [{ type: 'text', text: 'Use Read on checkpoint.txt, then Write exactly once to replace its entire content with after-checkpoint followed by a newline. No commands, agents, skills, network or other files. Reply done and finish.' }],
      _meta: { ccode: { promptId } } });
    assert.equal(result.stopReason, 'end_turn'); assert.ok(permittedWrites > 0);
    assert.equal(await readFile(file, 'utf8'), 'after-checkpoint\n');
    assert.equal(receipts.length, 1); assert.equal(receipts[0].promptId, promptId);
    assert.equal(receipts[0].sessionId, session.sessionId); assert.equal(raw.length, 0);
    const preview = await peer.request(cap.previewMethod, receipts[0]);
    assert.equal(preview.canRewind, true);
    assert.ok(preview.filesChanged.some(value => path.resolve(root, value) === file));
    assert.equal(preview.declaredComplete, false);
    assert.equal(await readFile(file, 'utf8'), 'after-checkpoint\n', 'Production preview never writes');
    assert.equal(await readFile(sentinel, 'utf8'), 'keep unrelated\n');
    assert.equal(cap.restoreMethod, '_ccode/checkpoint/restore'); assert.ok(preview.previewToken);
    await writeFile(file, 'external edit after preview\n');
    await assert.rejects(peer.request(cap.restoreMethod, { ...receipts[0], previewToken: preview.previewToken }), /changed|conflict/i);
    assert.equal(await readFile(file, 'utf8'), 'external edit after preview\n', 'A stale preview must not overwrite external work');
    const refreshed = await peer.request(cap.previewMethod, receipts[0]);
    const restored = await peer.request(cap.restoreMethod, { ...receipts[0], previewToken: refreshed.previewToken });
    assert.equal(restored.status, 'completed'); assert.equal(restored.declaredComplete, false);
    assert.equal(await readFile(file, 'utf8'), 'original\n'); assert.equal(await readFile(sentinel, 'utf8'), 'keep unrelated\n');
    assert.equal(path.dirname(restored.recoveryDirectory), recovery);
    const manifest = JSON.parse(await readFile(path.join(restored.recoveryDirectory, 'manifest.json'), 'utf8'));
    assert.equal(manifest.status, 'completed');
    assert.equal(await readFile(path.join(restored.recoveryDirectory, manifest.files[0].backup), 'utf8'), 'external edit after preview\n');
    await assert.rejects(peer.request(cap.restoreMethod, { ...receipts[0], previewToken: refreshed.previewToken }));
    console.log(JSON.stringify({ productionACPRoute: true, exactPromptEcho: true, actualApprovedWrite: true,
      previewReadOnly: true, unrelatedPreserved: true, noRawSDKPayloads: true, externalConflictRejected: true,
      actualRestoration: true, diskRecoveryVerified: true, tokenNotReplayable: true }));
    await peer.request('session/close', { sessionId: session.sessionId });
  });
  await Promise.race([work, new Promise((_, reject) => { timer = setTimeout(() => reject(Error('Real ACP checkpoint proof timed out')), 120000); })]);
} catch (error) {
  // Retain bounded provider diagnostic only in the local failure log.
  console.error(stderr); throw error;
} finally {
  clearTimeout(timer); child.stdin.end();
  const graceful = await Promise.race([exited, new Promise(resolve => setTimeout(() => resolve(null), 5000))]);
  if (!graceful) { child.kill('SIGTERM'); await exited; }
  await rm(root, { recursive: true, force: true });
  await rm(recovery, { recursive: true, force: true });
}
