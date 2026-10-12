import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { NativeSubagentRuntime } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/native-subagents.js';
import { clientSupportsSubagents } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/acp-subagents.js';
import { zInitializeRequest } from '../.build/agent/node_modules/@agentclientprotocol/sdk/dist/schema/zod.gen.js';
import { installNativeSubagentCapabilityBridge } from './claude-acp-native-subagents.mjs';

const pkg = JSON.parse(await readFile(new URL('../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/package.json', import.meta.url), 'utf8'));
assert.equal(pkg.version, '0.84.0');
assert.equal(clientSupportsSubagents({ subagents: {} }), true);
assert.equal(clientSupportsSubagents({ subagents: true }), false);
const request = { protocolVersion: 1, clientInfo: { name: 'ccode', version: '0.1' }, clientCapabilities: { subagents: {}, _meta: { ccode: { nativeSubagents: true } } } };
const parsed = zInitializeRequest.parse(request);
assert.equal(clientSupportsSubagents(parsed.clientCapabilities), false, 'The pinned SDK drops the new standard capability');
class CaptureAgent { initialize(value) { return value; } }
installNativeSubagentCapabilityBridge(CaptureAgent);
assert.equal(clientSupportsSubagents(new CaptureAgent().initialize(parsed).clientCapabilities), true);
assert.equal(clientSupportsSubagents(new CaptureAgent().initialize({ ...parsed, clientInfo: { name: 'other-client' } }).clientCapabilities), false);
assert.equal(clientSupportsSubagents(new CaptureAgent().initialize({ ...parsed, clientCapabilities: {} }).clientCapabilities), false);
assert.equal(new CaptureAgent().initialize(parsed).clientCapabilities._meta.jetbrains, undefined, 'Do not select AIR presentation as a side effect');
const output = [], session = {}, logger = { log() {}, error() {} };
const runtime = new NativeSubagentRuntime(true, 'root', session, async value => output.push(value), logger);
const deliver = async value => { const routed = await runtime.route(value, deliver); if (routed) output.push(routed); };
const tool = (id, parent, name = 'Agent') => ({ sessionId: 'root', update: {
  sessionUpdate: 'tool_call', toolCallId: id, rawInput: { description: id, prompt: 'Read the fixture' },
  _meta: { claudeCode: { toolName: name, ...(parent ? { parentToolUseId: parent } : {}) } }
} });
await deliver(tool('parent-launch'));
assert.equal(output.length, 0, 'Native delegation is represented by its announced child');
await runtime.taskStarted({ taskId: 'child', toolUseId: 'parent-launch', subagentType: 'Explore', description: 'Explore fixture' }, deliver);
assert.equal(output[0].sessionId, 'root');
assert.equal(output[0].update.sessionUpdate, 'subagent_spawned');
assert.equal(output[0].update.subagentSessionId, 'child');
assert.deepEqual(output[0].update.capabilities, {}, 'Do not invent direct child operations');
await deliver(tool('nested-launch', 'parent-launch'));
await runtime.taskStarted({ taskId: 'nested', toolUseId: 'nested-launch', subagentType: 'Explore' }, deliver);
assert.equal(output[1].sessionId, 'child', 'Nested announcements belong to the immediate parent');
assert.equal(output[1].update.subagentSessionId, 'nested');
await deliver(tool('read-tool', 'nested-launch', 'Read'));
assert.equal(output[2].sessionId, 'nested');
assert.equal(output[2].update.toolCallId, 'read-tool');
await runtime.finishTask('nested', 'completed', deliver, 'nested-launch');
assert.deepEqual(output[3], { sessionId: 'child', update: { sessionUpdate: 'subagent_state_update', subagentSessionId: 'nested', state: 'completed' } });
await runtime.finishTask('nested', 'failed', deliver, 'nested-launch');
assert.equal(output.length, 4, 'A terminal generation cannot complete twice');
await runtime.taskResumed('nested', deliver, 'Continue inspection');
assert.equal(output[4].update.subagentSessionId, 'nested:generation:2');
assert.equal(output[4].sessionId, 'child');
console.log('Pinned standard subagents: negotiation, parent-before-child ordering, nested ownership, empty operation capabilities, exactly-once completion and distinct resumed generations verified.');
