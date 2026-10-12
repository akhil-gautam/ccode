// Actual-provider, opt-in checkpoint proof. Only mutates a fresh disposable root.
// Uses the supported SDK contract before any restoration UI/ACP bridge is enabled.
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { query } from '../.build/agent/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs';

if (process.env.CCODE_REAL_CHECKPOINT !== '1') {
  console.log('Skipped: set CCODE_REAL_CHECKPOINT=1 to run one authenticated disposable SDK turn.');
  process.exit(0);
}
const directory = await realpath(await mkdtemp(path.join(tmpdir(), 'ccode-real-checkpoint-')));
const file = path.join(directory, 'checkpoint.txt');
await writeFile(file, 'original\n');
const sentinel = path.join(directory, 'unrelated.txt');
await writeFile(sentinel, 'keep unrelated\n');
const promptID = randomUUID();
const prompt = 'Use Read on checkpoint.txt, then Write exactly once to replace its entire content with after-checkpoint followed by a newline. No commands, agents, skills, network or other files. Reply done and finish.';
let releaseInput, resolveTurn, rejectTurn, checkpoint, sessionID, permittedWrites = 0;
const heldInput = new Promise(resolve => { releaseInput = resolve; });
const turn = new Promise((resolve, reject) => { resolveTurn = resolve; rejectTurn = reject; });
async function* input() {
  yield { type: 'user', uuid: promptID, session_id: '', parent_tool_use_id: null, message: { role: 'user', content: prompt } };
  await heldInput;
}
const stream = query({ prompt: input(), options: {
  cwd: directory, model: 'sonnet', tools: ['Read', 'Write'], permissionMode: 'default',
  settingSources: [], enableFileCheckpointing: true, extraArgs: { 'replay-user-messages': null },
  canUseTool: async (name, args) => {
    const target = typeof args.file_path === 'string' ? path.resolve(directory, args.file_path) : '';
    if (!['Read', 'Write'].includes(name) || target !== file) return { behavior: 'deny', message: 'Disposable checkpoint proof permits only its one file.' };
    if (name === 'Write') { assert.equal(args.content, 'after-checkpoint\n'); permittedWrites++; }
    return { behavior: 'allow', updatedInput: args };
  },
} });
const consume = (async () => {
  for await (const message of stream) {
    if (message.type === 'user' && message.uuid === promptID) checkpoint = message.uuid;
    if (typeof message.session_id === 'string') sessionID = message.session_id;
    if (message.type === 'result') resolveTurn(message);
  }
})().catch(error => { rejectTurn(error); });
let timer;
try {
  const result = await Promise.race([turn, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Checkpoint turn timed out')), 120000); })]);
  clearTimeout(timer);
  assert.equal(result.subtype, 'success', 'The actual tool turn must complete successfully');
  assert.equal(checkpoint, promptID, 'Captured checkpoint must be the submitted user message');
  assert.ok(sessionID);
  assert.ok(permittedWrites > 0, 'Actual approved Write must have occurred');
  assert.equal(await readFile(file, 'utf8'), 'after-checkpoint\n');
  const preview = await stream.rewindFiles(checkpoint, { dryRun: true });
  assert.equal(preview.canRewind, true);
  assert.ok(preview.filesChanged?.some(value => path.resolve(directory, value) === file));
  assert.equal(await readFile(file, 'utf8'), 'after-checkpoint\n', 'Preview must not modify files');
  assert.equal(await readFile(sentinel, 'utf8'), 'keep unrelated\n');
  // Establish whether SDK restore itself protects an intervening external edit.
  // The future app must preview and independently guard against this conflict.
  await writeFile(file, 'external edit after preview\n');
  const restored = await stream.rewindFiles(checkpoint);
  assert.equal(restored.canRewind, true);
  assert.equal(restored.skippedLinks ?? 0, 0);
  assert.equal(await readFile(file, 'utf8'), 'original\n');
  assert.equal(await readFile(sentinel, 'utf8'), 'keep unrelated\n');
  console.log(JSON.stringify({ sdkCheckpoint: true, userCheckpointEcho: true, approvedWrite: true, previewReadOnly: true, actualRestore: true, unrelatedPreserved: true, externalEditOverwrittenBySDK: true, appConflictGuardRequired: true }));
} finally {
  clearTimeout(timer); releaseInput(); stream.close();
  await consume;
  await rm(directory, { recursive: true, force: true });
}
