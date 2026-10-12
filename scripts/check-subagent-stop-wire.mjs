import assert from 'node:assert/strict';
import { NativeSubagentRuntime } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/native-subagents.js';
import { ClaudeAcpAgent } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/acp-agent.js';
import { asSdkSessionNotification } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/acp-subagents.js';
import * as bridge from './claude-acp-native-subagents.mjs';

assert.equal(typeof bridge.installNativeSubagentStopBridge, 'function', 'Individual native-child Stop requires an explicit bridge');
const updates = [], calls = [];
let fail = false, hold, release;
class Provider {
  sessions = {};
  client = { sessionUpdate: async value => updates.push(value) };
  initialize() { return { protocolVersion: 1 }; }
  stopAsyncTask(params) { return ClaudeAcpAgent.prototype.stopAsyncTask.call(this, params); }
}
bridge.installNativeSubagentStopBridge(Provider, asSdkSessionNotification);
const provider = new Provider();
const request = { clientInfo: { name: 'ccode' }, clientCapabilities: { _meta: { ccode: { nativeSubagents: true, nativeSubagentStop: true } } } };
const response = await provider.initialize(request);
assert.equal(response._meta.ccode.nativeSubagentStop.version, 1);
const session = { query: { stopTask: async id => { calls.push(id); if (fail) throw Error('Stop rejected'); if (hold) await hold; } } };
provider.sessions.root = session;
const publish = value => provider.client.sessionUpdate(asSdkSessionNotification(value));
const runtime = session.nativeSubagentRuntime = new NativeSubagentRuntime(true, 'root', session, publish, { log() {}, error() {} });
const deliver = async value => { const routed = await runtime.route(value, deliver); if (routed) await publish(routed); };
await runtime.taskStarted({ taskId: 'sdk-left', subagentType: 'general-purpose', description: 'Left' }, deliver);
await runtime.taskStarted({ taskId: 'sdk-right', subagentType: 'general-purpose', description: 'Right' }, deliver);
const control = updates.find(value => value.update.subagentSessionId === 'sdk-left').update.capabilities._meta.ccode.stopTask;
assert.equal(control.version, 1);
assert.equal(control.method, '_session/async_task/stop');
assert.ok(control.taskId.startsWith('ccode-subagent:'), 'The bridge uses a generation-specific control handle, not a reusable SDK task ID');
assert.deepEqual(await provider.stopAsyncTask({ sessionId: 'foreign', asyncTaskId: control.taskId }), { stopped: false });
assert.equal(calls.length, 0);
fail = true;
await assert.rejects(provider.stopAsyncTask({ sessionId: 'root', asyncTaskId: control.taskId }), /Stop rejected/);
assert.equal(runtime.isLiveSession('sdk-left'), true, 'A rejected Stop must not fabricate completion');
fail = false;
hold = new Promise(resolve => { release = resolve; });
const pending = provider.stopAsyncTask({ sessionId: 'root', asyncTaskId: control.taskId });
assert.deepEqual(await provider.stopAsyncTask({ sessionId: 'root', asyncTaskId: control.taskId }), { stopped: false }, 'Concurrent Stop is single-flight');
release();
assert.deepEqual(await pending, { stopped: true });
assert.equal(runtime.isLiveSession('sdk-left'), false);
assert.equal(runtime.isLiveSession('sdk-right'), true, 'Sibling remains running');
assert.equal(provider.sessions.root, session, 'Parent query remains the same');
assert.ok(updates.some(value => value.update.subagentSessionId === 'sdk-left' && value.update.state === 'cancelled'));
assert.deepEqual(await provider.stopAsyncTask({ sessionId: 'root', asyncTaskId: control.taskId }), { stopped: false });
hold = undefined;
await runtime.taskResumed('sdk-left', deliver, 'Continue');
const resumed = updates.find(value => value.update.subagentSessionId === 'sdk-left:generation:2').update.capabilities._meta.ccode.stopTask;
assert.notEqual(resumed.taskId, control.taskId);
assert.deepEqual(await provider.stopAsyncTask({ sessionId: 'root', asyncTaskId: control.taskId }), { stopped: false }, 'Old generation cannot stop a resumed child');
assert.equal(runtime.isLiveSession('sdk-left:generation:2'), true);
hold = new Promise(resolve => { release = resolve; });
const oldGenerationStop = provider.stopAsyncTask({ sessionId: 'root', asyncTaskId: resumed.taskId });
await runtime.finishTask('sdk-left', 'completed', deliver);
await runtime.taskResumed('sdk-left', deliver, 'New generation');
release();
await oldGenerationStop;
assert.equal(runtime.isLiveSession('sdk-left:generation:3'), true, 'Late acknowledgement never completes a newer generation');
session.asyncTaskRuntime = { claimStop: id => id === 'shell', taskStopped: async () => {}, releaseStop() {} };
hold = undefined;
assert.deepEqual(await provider.stopAsyncTask({ sessionId: 'root', asyncTaskId: 'shell' }), { stopped: true }, 'Ordinary async Stop still uses the official handler');
assert.equal(calls.at(-1), 'shell');
for (const other of [{ ...request, clientInfo: { name: 'foreign' } }, { ...request, clientCapabilities: {} }]) {
  const foreign = new Provider();
  assert.equal((await foreign.initialize(other))._meta?.ccode?.nativeSubagentStop, undefined);
  assert.deepEqual(await foreign.stopAsyncTask({ sessionId: 'root', asyncTaskId: control.taskId }), { stopped: false });
}
console.log('Native-child Stop: actual runtime generations, scoped handles, rejected/concurrent/duplicate controls, parent/sibling preservation, late acknowledgement and official async fallback verified.');
