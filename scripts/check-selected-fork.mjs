// Verify the installed adapter and SDK's persisted boundary semantics, without a model request.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

const root = await realpath(await mkdtemp(join(tmpdir(), 'ccode-selected-fork-')));
process.env.CLAUDE_CONFIG_DIR = join(root, 'claude');
try {
  const sdk = await import('../.build/agent/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs');
  const { forkSession } = await import('../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/fork-session.js');
  const { messageIdForGrouping } = await import('../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/acp-agent.js');
  const project = join(root, 'workspace'), sessionId = randomUUID();
  const directory = join(process.env.CLAUDE_CONFIG_DIR, 'projects', project.replace(/[^a-zA-Z0-9]/g, '-'));
  await mkdir(project); await mkdir(directory, { recursive: true });
  const ids = Array.from({ length: 4 }, () => randomUUID());
  const entries = ids.map((uuid, index) => ({
    uuid, parentUuid: index ? ids[index - 1] : null, sessionId, cwd: project,
    type: index % 2 ? 'assistant' : 'user', isSidechain: false,
    timestamp: new Date().toISOString(), version: '2.1.284', userType: 'external',
    message: index % 2 ? { id: `msg-${index}`, role: 'assistant', content: [{ type: 'text', text: `Answer ${index}` }] }
      : { role: 'user', content: `Question ${index}` },
  }));
  const sourcePath = join(directory, sessionId + '.jsonl');
  await writeFile(sourcePath, entries.map(entry => JSON.stringify(entry)).join('\n') + '\n');
  const original = await readFile(sourcePath);
  assert.equal((await sdk.getSessionMessages(sessionId, { dir: project })).length, 4);
  const branch = await forkSession({ sessionId, cwd: project,
    _meta: { jetbrains: { air: { fork: { version: 1, messageId: 'msg-1' } } } },
  }, { messageIdForGrouping });
  assert.notEqual(branch.sessionId, sessionId);
  const messages = await sdk.getSessionMessages(branch.sessionId, { dir: project });
  assert.equal(messages.length, 2);
  assert.equal(messages.at(-1).message.id, 'msg-1');
  assert.deepEqual(messages.map(message => message.message), entries.slice(0, 2).map(entry => entry.message));
  assert.deepEqual(await readFile(sourcePath), original);
  await assert.rejects(forkSession({ sessionId, cwd: project,
    _meta: { jetbrains: { air: { fork: { version: 1, messageId: 'missing' } } } },
  }, { messageIdForGrouping }));
  console.log(JSON.stringify({ sourceMessages: 4, forkMessages: messages.length, sourceUnchanged: true, missingBoundaryRejected: true, modelRequests: 0 }));
} finally {
  await rm(root, { recursive: true, force: true });
}
