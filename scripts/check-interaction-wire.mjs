// Exercise the pinned official adapter's actual steering implementation without
// starting a model query. Real-agent behavior is checked independently in Swift.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { ClaudeAcpAgent } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/acp-agent.js';
import { buildClaudePermissionPresentation } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/permissions/presentation.js';
import { buildExitPlanModePermissionOptions } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/permissions/options/tools.js';
import { providerFailureCategory } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/session-failure-extension.js';
import { RequestError } from '../.build/agent/node_modules/@agentclientprotocol/sdk/dist/acp.js';

const pkg = JSON.parse(await readFile(new URL('../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/package.json', import.meta.url), 'utf8'));
assert.equal(pkg.version, '0.84.0', 'Reverify contracts before accepting a different adapter version');
const notifications = [], inputs = [];
const agent = new ClaudeAcpAgent({ sessionUpdate: async value => notifications.push(value) });
const turn = { settled: false };
const session = { turnQueue: [turn], input: { push: value => inputs.push(value) }, pendingUserInputCount: 0 };
agent.sessions['wire-session'] = session;
const request = { sessionId: 'wire-session', prompt: [{ type: 'text', text: 'Use the requested correction' }], _meta: { steering: { idleBehavior: 'promptRequired' } } };

assert.deepEqual(await agent.steer(request), { outcome: 'injected' });
assert.equal(session.turnQueue.length, 1, 'Injection cannot create a second prompt turn');
assert.equal(session.turnQueue[0], turn);
assert.equal(inputs[0].priority, 'now');
assert.ok(turn.steeredEchoes.has(inputs[0].uuid));
assert.ok(turn.steeredUuids.has(inputs[0].uuid));
assert.equal(inputs[0].message.content[0].text, 'Use the requested correction');

session.pendingUserInputCount = 1;
assert.deepEqual(await agent.steer(request), { outcome: 'injected' });
assert.equal(inputs[1].priority, 'later', 'An awaiting question/approval cannot be pre-empted');
assert.notEqual(inputs[0].uuid, inputs[1].uuid);

session.turnQueue = [];
const before = inputs.length;
assert.deepEqual(await agent.steer(request), { outcome: 'promptRequired', reason: 'noRunningTurn' });
assert.equal(inputs.length, before, 'Idle fallback must leave the message host-owned');
assert.equal(session.turnQueue.length, 0);
console.log('Pinned adapter 0.84.0: active injection, question-safe priority, distinct UUIDs and mutation-free idle fallback verified.');

const plan = '# Plan\n\nUse SQLite, then test.';
const planPresentation = buildClaudePermissionPresentation({ toolName: 'ExitPlanMode', toolUseID: 'plan-1', input: { plan }, cwd: '/tmp' });
assert.equal(planPresentation.toolCall.name, 'ExitPlanMode', 'Top-level permissions identify the tool by name');
assert.equal(planPresentation.toolCall.rawInput.plan, plan);
assert.equal(planPresentation.toolCall.content[0].content.text, plan);
const command = "printf 'hello\\n'\ncat <<'EOF'\n$(literal) `literal`\nEOF";
const commandPresentation = buildClaudePermissionPresentation({ toolName: 'Bash', toolUseID: 'command-1', input: { command }, cwd: '/tmp' });
assert.equal(commandPresentation.toolCall.rawInput.command, command, 'Shell previews must preserve executable bytes');
const options = buildExitPlanModePermissionOptions({ availableModes: ['default', 'acceptEdits', 'auto', 'bypassPermissions'], input: { plan }, prePlanMode: 'default' });
assert.equal(options.filter(option => option.kind === 'reject_once').length, 1);
assert.ok(options.some(option => option.kind === 'allow_once'));
assert.ok(options.some(option => option.name.includes('clear context')));
console.log('Pinned plan permission shape, verbatim command preview and advertised revision/manual/context choices verified.');

for (const [kind, category] of [['billing_error', 'quota_exhausted'], ['rate_limit', 'rate_limited'], ['overloaded', 'overloaded'], ['max_output_tokens', 'context_exhausted'], ['verification_required', 'access_denied']]) {
  assert.equal(providerFailureCategory(kind), category);
  const wire = RequestError.internalError({ errorKind: kind }, 'Exact provider explanation').toErrorResponse();
  assert.equal(wire.code, -32603);
  assert.equal(wire.data.errorKind, kind);
  assert.ok(wire.message.includes('Exact provider explanation'));
}
assert.equal(RequestError.authRequired().code, -32000);
assert.equal(RequestError.authRequired().message, 'Authentication required');
console.log('Pinned provider failure categories, JSON-RPC error data and authentication signal verified.');
