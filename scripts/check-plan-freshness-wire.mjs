// Actual pinned permission pipeline, without a model query. Reproduce the SDK's
// cached ExitPlanMode input after its plan file has been rewritten.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { ClaudeAcpAgent } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/acp-agent.js';
import { ClientCapabilities } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/tool-calls/client-capabilities.js';
import * as bridge from './claude-acp-native-subagents.mjs';

assert.equal(JSON.parse(await readFile(new URL('../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/package.json', import.meta.url))).version, '0.84.0');
const root = await mkdtemp(path.join(tmpdir(), 'ccode-plan-freshness-'));
const directory = path.join(root, 'plans'), file = path.join(directory, 'fixture.md');
await mkdir(directory); await writeFile(file, '# Plan\nReturn amber17.\n');
class TestAgent extends ClaudeAcpAgent {
  // Only suppress the background authentication probe. canUseTool, rendering,
  // permission-option decoding and cancellation are the actual pinned code.
  async initialize(request) { this.clientCapabilities = request.clientCapabilities; this.toolCallCapabilities = ClientCapabilities.from(request.clientCapabilities); return {}; }
}
if (bridge.installPlanFreshnessBridge) bridge.installPlanFreshnessBridge(TestAgent, directory);
const requests = [], notifications = [];
let duringApproval, selection = 'manual';
const agent = new TestAgent({ sessionUpdate: async n => notifications.push(n), requestPermission: async request => {
  requests.push(request); if (duringApproval) await duringApproval();
  const option = request.options.find(value => selection === 'clear' ? value.name.includes('clear context') : value.kind === 'allow_once');
  assert.ok(option, 'The pinned provider must offer an approval choice');
  return { outcome: { outcome: 'selected', optionId: option.optionId } };
} });
await agent.initialize({ clientInfo: { name: 'ccode' }, clientCapabilities: { _meta: { ccode: { nativeSubagents: true } } } });
agent.sessions.root = { cwd: root, emittedToolCalls: new Set(), configOptions: [], modelInfos: [], models: { currentModelId: 'sonnet' }, modes: { currentModeId: 'plan', availableModes: [{ id: 'default' }, { id: 'plan' }] } };
const stale = { planFilePath: file, plan: '# Plan\nReturn cobalt42.\n' };
let seq = 0;
const ask = (input = stale, signal = new AbortController().signal) => agent.canUseTool('root')('ExitPlanMode', input, { toolUseID: `plan-${++seq}`, signal });
try {
  const result = await ask();
  assert.equal(requests.at(-1).toolCall.rawInput.plan, '# Plan\nReturn amber17.\n', 'Approval must show the rewritten plan, not cached input');
  assert.equal(result.updatedInput.plan, '# Plan\nReturn amber17.\n', 'The actual SDK must receive exactly the plan that was approved');
  assert.equal(stale.plan, '# Plan\nReturn cobalt42.\n', 'Do not mutate SDK-owned input objects');
  selection = 'clear';
  const clear = await ask();
  assert.equal(clear.behavior, 'deny'); assert.equal(clear.interrupt, true);
  assert.equal(agent.sessions.root.pendingExitPlanContextReset.plan, '# Plan\nReturn amber17.', 'The actual clear-context handoff must also receive the current plan');
  selection = 'manual';
  duringApproval = async () => writeFile(file, '# Plan\nExternal change.\n');
  await assert.rejects(ask(), /plan.*changed/i, 'A file change while the approval is open cannot execute');
  duringApproval = undefined;
  const count = requests.length;
  await assert.rejects(ask({ ...stale, planFilePath: path.join(root, 'outside.md') }), /plan/i);
  await symlink(file, path.join(directory, 'linked.md'));
  await assert.rejects(ask({ ...stale, planFilePath: path.join(directory, 'linked.md') }), /plan/i);
  await writeFile(file, Buffer.alloc(1024 * 1024 + 1, 65));
  await assert.rejects(ask(), /plan/i);
  await assert.rejects(ask({ ...stale, planFilePath: 'relative.md' }), /plan/i);
  await assert.rejects(ask({ ...stale, planFilePath: path.join(directory, 'missing.md') }), /plan/i);
  await writeFile(file, Buffer.from([0xff, 0xfe]));
  await assert.rejects(ask(), /plan/i);
  await writeFile(file, ' \n');
  await assert.rejects(ask(), /plan/i, 'An empty plan is not a replacement for its cached proposal');
  assert.equal(requests.length, count, 'Unverifiable sources must not present cached approvals');
  const cancelled = new AbortController(); cancelled.abort();
  await assert.rejects(ask(stale, cancelled.signal));
  assert.equal(requests.length, count);
  await writeFile(file, 'Current plan.\n');
  await ask({ plan: 'An inline-only plan.' });
  assert.equal(requests.at(-1).toolCall.rawInput.plan, 'An inline-only plan.', 'No path means no guessed file read');
  await agent.initialize({ clientInfo: { name: 'another-client' }, clientCapabilities: {} });
  await ask();
  assert.equal(requests.at(-1).toolCall.rawInput.plan, stale.plan, 'Other clients retain their original behavior');
  assert.equal(await readFile(file, 'utf8'), 'Current plan.\n');
  console.log('Pinned actual permission pipeline: fresh displayed/approved input, stale-open rejection, invalid source/cancel refusal, inline/other-client preservation.');
} finally { await rm(root, { recursive: true, force: true }); }
