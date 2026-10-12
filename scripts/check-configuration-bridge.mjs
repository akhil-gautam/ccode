import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { AgentApp, client, RequestError } from '../.build/agent/node_modules/@agentclientprotocol/sdk/dist/acp.js';
import * as bridge from './claude-acp-native-subagents.mjs';
assert.equal(typeof bridge.installConfigurationBridge, 'function', 'Live configuration needs an explicitly negotiated transport');
let held, release, authenticationCalls = 0;
class Provider {
  sessions = {};
  async initialize() { return { protocolVersion: 1, agentCapabilities: {}, _meta: { existing: true } }; }
  async newSession() {
    const sessionId = randomUUID();
    const statuses = [{ name: 'fixture', status: 'connected', source: 'project', scope: 'project', config: { env: { SECRET: 'never-output' }, headers: { Authorization: 'never-output' } }, error: 'secret error never-output', tools: [{ name: 'read_fixture', description: 'never-output' }] }];
    this.sessions[sessionId] = { queryClosed: false, turnQueue: [], query: {
      mcpServerStatus: async () => structuredClone(statuses),
      mcpAuthenticate: async name => { authenticationCalls++; return { requiresUserAction: true, authUrl: 'https://issuer.example/authorize?state=private-fixture' }; },
      toggleMcpServer: async (name, enabled) => { if (held) await held; statuses.find(item => item.name === name).status = enabled ? 'connected' : 'disabled'; },
      reconnectMcpServer: async name => { statuses.find(item => item.name === name).status = 'connected'; },
      reloadSkills: async () => ({ skills: [{ name: 'fixture-skill', description: 'Fixture description', argumentHint: 'file' }] }),
      reloadPlugins: async () => ({ commands: [{ name: 'plugin-command', description: 'Fixture plugin', argumentHint: '' }], plugins: [{ name: 'fixture-plugin', path: '/private/plugin' }], error_count: 0 }),
    } }; return { sessionId };
  }
}
bridge.installConfigurationBridge(Provider, AgentApp, RequestError);
const provider = new Provider();
function app(agent) { return new AgentApp().onRequest('initialize', ctx => agent.initialize(ctx.params)).onRequest('session/new', ctx => agent.newSession(ctx.params)); }
const request = { protocolVersion: 1, clientInfo: { name: 'ccode', version: '0.1' }, clientCapabilities: { _meta: { ccode: { configurationManagement: true } } } };
await client().connectWith(app(provider), async peer => {
  const response = await peer.request('initialize', request);
  assert.equal(response._meta.existing, true);
  const cap = response._meta.ccode.configurationManagement;
  assert.equal(cap.authenticationVersion, 1); assert.equal(cap.version, 1); assert.equal(cap.method, '_ccode/configuration');
  const sessionId = (await peer.request('session/new', { cwd: '/tmp', mcpServers: [] })).sessionId;
  const params = operation => ({ connectionId: cap.connectionId, sessionId, operation });
  const status = await peer.request(cap.method, params('status'));
  assert.deepEqual(status.servers, [{ name: 'fixture', status: 'connected', source: 'project', scope: 'project', tools: ['read_fixture'] }]);
  assert.equal(JSON.stringify(status).includes('never-output'), false);
  assert.equal(status.connectionId, cap.connectionId); assert.equal(status.sessionId, sessionId);
  const disabled = await peer.request(cap.method, { ...params('toggle'), name: 'fixture', enabled: false });
  assert.equal(disabled.servers[0].status, 'disabled');
  assert.equal((await peer.request(cap.method, { ...params('reconnect'), name: 'fixture' })).servers[0].status, 'connected');
  const skills = await peer.request(cap.method, params('reloadSkills'));
  assert.deepEqual(skills.commands, [{ name: 'fixture-skill', description: 'Fixture description', argumentHint: 'file' }]);
  const plugins = await peer.request(cap.method, params('reloadPlugins'));
  assert.deepEqual(plugins.plugins, ['fixture-plugin']); assert.equal(JSON.stringify(plugins).includes('/private/plugin'), false);
  for (const invalid of [{ ...params('status'), sessionId: [sessionId] }, { ...params('status'), connectionId: randomUUID() }, { ...params('status'), sessionId: randomUUID() }, { ...params('status'), operation: 'authenticate' }, { ...params('toggle'), name: 'fixture', enabled: 'false' }, { ...params('toggle'), name: 'unknown', enabled: false }]) await assert.rejects(peer.request(cap.method, invalid));
  const session = provider.sessions[sessionId];
  session.query.toggleMcpServer = async (name, enabled) => { if (held) await held; session.authenticationStatus = enabled ? 'needs-auth' : 'disabled'; };
  const originalStatus = session.query.mcpServerStatus;
  session.query.mcpServerStatus = async () => (await originalStatus()).map(item => ({ ...item, status: session.authenticationStatus ?? item.status }));
  session.authenticationStatus = 'needs-auth';
  const start = await peer.request(cap.method, { ...params('beginAuthentication'), name: 'fixture' });
  assert.equal(start.authentication.state, 'pending'); assert.equal(start.authentication.name, 'fixture');
  assert.equal(start.authentication.url, 'https://issuer.example/authorize?state=private-fixture');
  const flowId = start.authentication.id;
  assert.equal((await peer.request(cap.method, { ...params('beginAuthentication'), name: 'fixture' })).authentication.id, flowId);
  assert.equal(authenticationCalls, 1, 'Explicit repeat must not create duplicate callback listeners');
  await assert.rejects(peer.request(cap.method, { ...params('authenticationStatus'), name: 'fixture', flowId: randomUUID() }));
  session.authenticationStatus = 'connected';
  const completed = await peer.request(cap.method, { ...params('authenticationStatus'), name: 'fixture', flowId });
  assert.equal(completed.authentication.state, 'connected'); assert.equal(completed.authentication.url, undefined);
  assert.equal(JSON.stringify(await peer.request(cap.method, params('status'))).includes('private-fixture'), false);
  await peer.request(cap.method, { ...params('cancelAuthentication'), name: 'fixture', flowId });
  await assert.rejects(peer.request(cap.method, { ...params('authenticationStatus'), name: 'fixture', flowId }));
  session.authenticationStatus = 'needs-auth';
  session.query.mcpAuthenticate = async () => ({ requiresUserAction: true, authUrl: 'javascript:alert(1)' });
  await assert.rejects(peer.request(cap.method, { ...params('beginAuthentication'), name: 'fixture' }));
  delete session.query.mcpAuthenticate;
  await assert.rejects(peer.request(cap.method, { ...params('beginAuthentication'), name: 'fixture' }));
  session.authenticationStatus = 'connected';

  session.turnQueue.push({ settled: false });
  assert.equal((await peer.request(cap.method, params('status'))).servers[0].status, 'connected');
  await assert.rejects(peer.request(cap.method, { ...params('toggle'), name: 'fixture', enabled: false }));
  session.turnQueue = [];
  held = new Promise(resolve => { release = resolve; });
  const pending = peer.request(cap.method, { ...params('toggle'), name: 'fixture', enabled: false });
  await new Promise(resolve => setImmediate(resolve));
  await assert.rejects(peer.request(cap.method, { ...params('reconnect'), name: 'fixture' }));
  session.query = { ...session.query }; release();
  await assert.rejects(pending, 'Late results from a replaced query cannot publish'); held = undefined;
  session.queryClosed = true;
  await assert.rejects(peer.request(cap.method, params('status')));
});
await client().connectWith(app(new Provider()), async peer => {
  const response = await peer.request('initialize', { ...request, clientInfo: { name: 'other-client', version: '1' } });
  assert.equal(response._meta?.ccode?.configurationManagement, undefined);
  await assert.rejects(peer.request('_ccode/configuration', { connectionId: randomUUID(), sessionId: randomUUID(), operation: 'status' }));
});
console.log('Configuration bridge: actual ACP negotiation, redacted status, toggle/reconnect/reload, ownership and late-query refusal passed.');
