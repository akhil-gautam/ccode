// Explicit ccode-only contract over the pinned adapter's public SDK query.
// Configurations and provider errors are never returned to the client.
import { randomUUID } from 'node:crypto';
const method = '_ccode/configuration';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const operations = new Set(['status', 'toggle', 'reconnect', 'reloadSkills', 'reloadPlugins', 'beginAuthentication', 'authenticationStatus', 'cancelAuthentication']);
const statuses = new Set(['connected', 'failed', 'needs-auth', 'pending', 'disabled']);
export function installConfigurationBridge(Agent, AgentApp, RequestError) {
  const states = new WeakMap(), initializing = new Map();
  const initialize = Agent.prototype.initialize, onRequest = AgentApp.prototype.onRequest;
  Agent.prototype.initialize = async function(request) {
    const response = await initialize.call(this, request);
    if (request.clientInfo?.name !== 'ccode' || request.clientCapabilities?._meta?.ccode?.configurationManagement !== true) {
      states.delete(this); return response;
    }
    const state = { id: randomUUID(), busy: new WeakSet(), authentication: new WeakMap() };
    states.set(this, state); initializing.set(state.id, this);
    while (initializing.size > 512) initializing.delete(initializing.keys().next().value);
    return { ...response, _meta: { ...response._meta, ccode: { ...response._meta?.ccode,
      configurationManagement: { version: 1, connectionId: state.id, method, authenticationVersion: 1 } } } };
  };
  AgentApp.prototype.onRequest = function(name, parser, handler) {
    if (name !== 'initialize' || handler) return onRequest.call(this, name, parser, handler);
    let owner, connection;
    onRequest.call(this, method, { parse: params => {
      if (!params || Array.isArray(params) || typeof params.sessionId !== 'string' || typeof params.connectionId !== 'string' || !uuid.test(params.sessionId) || !uuid.test(params.connectionId) || !operations.has(params.operation)
          || Object.keys(params).some(key => !['sessionId', 'connectionId', 'operation', 'name', 'enabled', 'flowId'].includes(key))) throw RequestError.invalidParams(undefined, 'Invalid configuration request.');
      if (['toggle', 'reconnect', 'beginAuthentication', 'authenticationStatus', 'cancelAuthentication'].includes(params.operation) && !text(params.name, 256)) throw RequestError.invalidParams(undefined, 'Invalid server name.');
      if (params.operation === 'toggle' && typeof params.enabled !== 'boolean') throw RequestError.invalidParams(undefined, 'Invalid toggle value.');
      if (['authenticationStatus', 'cancelAuthentication'].includes(params.operation) && (typeof params.flowId !== 'string' || !uuid.test(params.flowId))) throw RequestError.invalidParams(undefined, 'Invalid authentication flow.');
      return params;
    } }, async ctx => {
      if (!owner || ctx.params.connectionId !== connection || states.get(owner)?.id !== connection) throw RequestError.methodNotFound(method);
      return invoke(owner, states.get(owner), ctx.params, ctx.signal);
    });
    return onRequest.call(this, name, async ctx => {
      const response = await parser(ctx);
      connection = response._meta?.ccode?.configurationManagement?.connectionId;
      owner = initializing.get(connection); initializing.delete(connection);
      return response;
    });
  };
  async function invoke(agent, state, params, signal) {
    const session = Object.hasOwn(agent.sessions ?? {}, params.sessionId) ? agent.sessions[params.sessionId] : undefined;
    const query = session?.query;
    const current = () => {
      signal.throwIfAborted();
      if (!session || session.queryClosed || session.abortController?.signal.aborted || agent.sessions[params.sessionId] !== session || session.query !== query || states.get(agent) !== state)
        throw RequestError.invalidParams(undefined, 'The agent connection changed. Refresh its configuration.');
    };
    current();
    const mutating = !['status', 'authenticationStatus', 'cancelAuthentication'].includes(params.operation);
    if (state.busy.has(session) || mutating && liveWork(session)) throw RequestError.invalidParams(undefined, 'Wait for this session’s current work to finish.');
    state.busy.add(session);
    try {
      if (typeof query.mcpServerStatus !== 'function') throw RequestError.methodNotFound(method);
      let extra = {};
      if (['beginAuthentication', 'authenticationStatus', 'cancelAuthentication'].includes(params.operation)) {
        const statuses = await query.mcpServerStatus(); current();
        const server = statuses.find(item => item.name === params.name);
        if (!server) throw RequestError.invalidParams(undefined, 'Refresh the server list before signing in.');
        let flow = state.authentication.get(session);
        if (flow && (flow.query !== query || Date.now() >= flow.deadline)) { state.authentication.delete(session); flow = undefined; }
        if (params.operation === 'beginAuthentication') {
          if (flow && flow.name !== params.name) throw RequestError.invalidParams(undefined, 'Finish or cancel the current sign-in first.');
          if (!flow) {
            if (typeof query.mcpAuthenticate !== 'function') throw RequestError.methodNotFound(method);
            if (server.status !== 'needs-auth' && server.status !== 'connected') throw RequestError.invalidParams(undefined, 'Reconnect this server before signing in.');
            const login = server.status === 'connected' ? { requiresUserAction: false } : await query.mcpAuthenticate(params.name); current();
            const url = login.requiresUserAction ? authenticationURL(login.authUrl) : undefined;
            flow = { id: randomUUID(), name: params.name, query, url, deadline: Date.now() + 10 * 60 * 1000 };
            state.authentication.set(session, flow);
          }
        } else if (!flow || flow.id !== params.flowId || flow.name !== params.name) {
          throw RequestError.invalidParams(undefined, 'This sign-in flow is no longer active. Refresh the server list.');
        }
        if (params.operation === 'cancelAuthentication') {
          // Cancels only ccode's tracking. The SDK owns callback/listener lifetime;
          // no credential revocation or rollback is implied.
          state.authentication.delete(session);
          extra.authentication = { id: flow.id, name: flow.name, state: 'cancelled' };
        } else {
          const statuses = await query.mcpServerStatus(); current();
          const status = statuses.find(item => item.name === params.name)?.status;
          const result = status === 'connected' ? 'connected' : ['failed', 'disabled'].includes(status) || !status ? 'failed' : 'pending';
          if (result !== 'pending') flow.url = undefined;
          extra.authentication = { id: flow.id, name: flow.name, state: result, ...(result === 'pending' && flow.url ? { url: flow.url } : {}) };
        }
      } else if (['toggle', 'reconnect'].includes(params.operation)) {
        const known = await query.mcpServerStatus(); current();
        if (!Array.isArray(known) || !known.some(item => item.name === params.name)) throw RequestError.invalidParams(undefined, 'Refresh the server list before changing this server.');
        const action = params.operation === 'toggle' ? query.toggleMcpServer : query.reconnectMcpServer;
        if (typeof action !== 'function') throw RequestError.methodNotFound(method);
        current();
        if (params.operation === 'toggle') await action.call(query, params.name, params.enabled);
        else await action.call(query, params.name);
      } else if (params.operation === 'reloadSkills') {
        if (typeof query.reloadSkills !== 'function') throw RequestError.methodNotFound(method);
        extra.commands = commands((await query.reloadSkills()).skills);
      } else if (params.operation === 'reloadPlugins') {
        if (typeof query.reloadPlugins !== 'function') throw RequestError.methodNotFound(method);
        const result = await query.reloadPlugins(); current();
        extra.commands = commands(result.commands);
        extra.plugins = (result.plugins ?? []).slice(0, 512).map(item => text(item.name, 256) ? item.name : '').filter(Boolean);
        extra.errorCount = Number.isSafeInteger(result.error_count) && result.error_count >= 0 ? result.error_count : 0;
      }
      current();
      if (['reloadSkills', 'reloadPlugins'].includes(params.operation) && typeof agent.sendAvailableCommandsUpdate === 'function') {
        await agent.sendAvailableCommandsUpdate(params.sessionId); current();
      }
      const servers = sanitizeServers(await query.mcpServerStatus()); current();
      const result = { version: 1, sessionId: params.sessionId, connectionId: state.id, operation: params.operation, servers, ...extra };
      if (Buffer.byteLength(JSON.stringify(result)) > 512 * 1024) throw Error('Result limit');
      return result;
    } catch (error) {
      signal.throwIfAborted();
      if (error instanceof RequestError) throw error;
      throw RequestError.invalidParams(undefined, mutating ? 'Claude could not confirm this configuration change. Refresh before repeating it.' : 'Claude could not read live configuration.');
    } finally { state.busy.delete(session); }
  }
}
function text(value, limit) { return typeof value === 'string' && value.length > 0 && Buffer.byteLength(value) <= limit && !/[\u0000-\u001f]/.test(value); }
function sanitizeServers(items) {
  if (!Array.isArray(items) || items.length > 256) throw Error('Server limit');
  const names = new Set();
  return items.map(item => {
    if (!text(item.name, 256) || !statuses.has(item.status) || names.has(item.name)) throw Error('Invalid status');
    names.add(item.name);
    const result = { name: item.name, status: item.status };
    for (const key of ['source', 'scope']) if (text(item[key], 256)) result[key] = item[key];
    if (item.tools !== undefined) {
      if (!Array.isArray(item.tools) || item.tools.length > 512) throw Error('Tool limit');
      result.tools = item.tools.map(tool => { if (!text(tool.name, 256)) throw Error('Invalid tool'); return tool.name; });
    }
    return result;
  });
}
function commands(items) {
  if (!Array.isArray(items) || items.length > 512) throw Error('Command limit');
  return items.map(item => {
    if (!text(item.name, 256)) throw Error('Invalid command');
    return { name: item.name, description: typeof item.description === 'string' ? item.description.slice(0, 4096) : '', argumentHint: typeof item.argumentHint === 'string' ? item.argumentHint.slice(0, 1024) : '' };
  });
}
function liveWork(session) {
  return (session.turnQueue ?? []).some(turn => !turn.settled)
    || [...(session.nativeSubagentsByTaskId?.values() ?? [])].some(child => child.terminalState === undefined)
    || [...(session.asyncTaskRuntime?.tasks?.values() ?? [])].some(task => !task.ignored && !['completed', 'failed', 'stopped'].includes(task.state));
}

function authenticationURL(value) {
  if (typeof value !== 'string' || Buffer.byteLength(value) > 16384 || /[\u0000-\u001f]/.test(value)) throw Error('Invalid authorization URL');
  const url = new URL(value);
  if (url.username || url.password || !(url.protocol === 'https:' || url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname))) throw Error('Unsafe authorization URL');
  return url.href;
}
