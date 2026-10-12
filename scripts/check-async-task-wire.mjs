import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { AsyncTaskRuntime, clientSupportsAsyncTasks } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/async-tasks.js';
import { ClaudeAcpAgent } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/acp-agent.js';
import { asSdkSessionNotification } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/acp-subagents.js';
import { AcpToolCallRenderer } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/tool-calls/renderer.js';
import { zInitializeRequest } from '../.build/agent/node_modules/@agentclientprotocol/sdk/dist/schema/zod.gen.js';
import { installAsyncTaskBridge } from './claude-acp-native-subagents.mjs';

const pkg = JSON.parse(await readFile(new URL('../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/package.json', import.meta.url), 'utf8'));
assert.equal(pkg.version, '0.84.0');
const updates = [], stopped = [];
class ConsumerAgent {
  client = { sessionUpdate: async value => updates.push(value) };
  sessions = {};
  async initialize(request) {
    this.clientCapabilities = request.clientCapabilities;
    return { protocolVersion: 1, _meta: { steering: { supported: true } } };
  }
  async runConsumer(session, params) {
    session.asyncTaskRuntime ??= new AsyncTaskRuntime(clientSupportsAsyncTasks(this.clientCapabilities), params.sessionId, value => this.client.sessionUpdate(value));
  }
}
installAsyncTaskBridge(ConsumerAgent, AsyncTaskRuntime, asSdkSessionNotification);
const request = zInitializeRequest.parse({ protocolVersion: 1, clientInfo: { name: 'ccode', version: '0.1' }, clientCapabilities: { _meta: { ccode: { asyncTasks: true } } } });
const agent = new ConsumerAgent(), response = await agent.initialize(request);
assert.equal(response._meta.ccode.asyncTasks.version, 1);
assert.equal(response._meta.ccode.asyncTasks.stopMethod, '_session/async_task/stop');
assert.equal(response._meta.steering.supported, true);
assert.equal(agent.clientCapabilities._meta.jetbrains, undefined, 'Do not select AIR presentation to obtain a task runtime');
const session = { query: { stopTask: async id => stopped.push(id) }, nativeSubagentRuntime: { routeOfToolCall: id => id === 'child-tool' ? value => ({ ...value, sessionId: 'child' }) : undefined } };
agent.sessions.root = session;
await agent.runConsumer(session, { sessionId: 'root' });
const runtime = session.asyncTaskRuntime;
await runtime.taskBackgrounded({ taskId: 'job', taskType: 'local_bash', description: 'Fixture command', toolCallId: 'child-tool', outputFilePath: '/tmp/job.output' });
assert.equal(updates[0].sessionId, 'child');
assert.equal(updates[0].update.sessionUpdate, 'async_task_spawned');
assert.equal(updates[0].update.canStop, true);
await runtime.taskProgress({ taskId: 'job', description: 'Still checking', summary: 'One step done' });
assert.equal(updates.at(-1).update.sessionUpdate, 'async_task_progress');
await runtime.taskBackgrounded({ taskId: 'sibling', taskType: 'local_bash', toolCallId: 'sibling-tool' });
assert.equal(updates.at(-1).sessionId, 'root');
const result = await ClaudeAcpAgent.prototype.stopAsyncTask.call(agent, { sessionId: 'root', asyncTaskId: 'job' });
assert.deepEqual(result, { stopped: true });
assert.deepEqual(stopped, ['job']);
assert.equal(runtime.canStop('sibling'), true, 'Stopping a task does not cancel its parent or siblings');
assert.ok(updates.some(value => value.sessionId === 'child' && value.update.state === 'stopped'));
assert.deepEqual(await ClaudeAcpAgent.prototype.stopAsyncTask.call(agent, { sessionId: 'root', asyncTaskId: 'job' }), { stopped: false });
assert.deepEqual(await ClaudeAcpAgent.prototype.stopAsyncTask.call(agent, { sessionId: 'foreign', asyncTaskId: 'sibling' }), { stopped: false });
const renderer = AcpToolCallRenderer.for(agent.clientCapabilities);
const read = renderer.result({ id: 'read', name: 'Read', input: { file_path: '/tmp/source', offset: 3 } }, { content: 'raw model copy' }, { structured: { type: 'text', file: { content: 'literal file text', startLine: 3 } } }).at(-1);
assert.equal(read.content[0].content.text, '```\n3\tliteral file text\n```');
for (const other of [{ ...request, clientInfo: { name: 'other-client' } }, { ...request, clientCapabilities: {} }]) {
  const foreign = new ConsumerAgent(), handshake = await foreign.initialize(other), foreignSession = {};
  assert.equal(handshake._meta.ccode, undefined);
  await foreign.runConsumer(foreignSession, { sessionId: 'foreign' });
  assert.equal(foreignSession.asyncTaskRuntime.enabled, false);
}
console.log('Pinned async runtime: explicit negotiation, standard Read presentation, child routing, actual per-task stop/ack, duplicate stop and sibling preservation verified.');
