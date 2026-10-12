// Compatibility bridge for the official adapter 0.84.0: its runtime supports
// standard subagents, but its bundled SDK schema drops that capability. Carry
// the client's choice through a private metadata key, then restore exactly the
// supported standard field. No AIR presentation or new process is enabled.
import { pathToFileURL } from 'node:url';
import { readFile, open, realpath, lstat } from 'node:fs/promises';
import { constants } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { installFileCheckpointBridge } from './claude-acp-checkpoints.mjs';
import { installConfigurationBridge } from './claude-acp-configuration.mjs';
import { installSideQuestionBridge } from './claude-acp-side-question.mjs';
export { installConfigurationBridge };
export { installFileCheckpointBridge };

// The pinned CLI can supply a cached plan after a rejected approval, even when
// its own Write just replaced the plan file. Normalize at the provider boundary
// so presentation, SDK updatedInput and clear-context handoff share one receipt.
export function installPlanFreshnessBridge(Agent, directory = path.join(process.env.CLAUDE_CONFIG_DIR || path.join(homedir(), '.claude'), 'plans')) {
  const enabled = new WeakSet(), receipts = new WeakMap();
  const initialize = Agent.prototype.initialize, canUseTool = Agent.prototype.canUseTool;
  const requestPermission = Agent.prototype.requestPermissionFromClient;
  Agent.prototype.initialize = function(request) {
    enabled.delete(this);
    if (request.clientInfo?.name === 'ccode' && request.clientCapabilities?._meta?.ccode?.nativeSubagents === true) enabled.add(this);
    return initialize.call(this, request);
  };
  Agent.prototype.canUseTool = function(sessionId) {
    const original = canUseTool.call(this, sessionId), agent = this;
    return async function(name, input, options) {
      if (!enabled.has(agent) || name !== 'ExitPlanMode' || input?.planFilePath === undefined) return original(name, input, options);
      options.signal.throwIfAborted();
      const receipt = await readPlanReceipt(input.planFilePath, directory);
      options.signal.throwIfAborted();
      const current = { ...input, plan: receipt.text };
      receipts.set(current, receipt);
      try { return await original(name, current, options); }
      finally { receipts.delete(current); }
    };
  };
  Agent.prototype.requestPermissionFromClient = async function(params, name, signal, parent, owner, input, preview) {
    const response = await requestPermission.call(this, params, name, signal, parent, owner, input, preview);
    const receipt = receipts.get(input);
    const selected = params.options.find(value => value.optionId === response?.outcome?.optionId);
    if (receipt && response?.outcome?.outcome === 'selected' && !selected?.kind?.startsWith('reject')) {
      signal.throwIfAborted();
      const current = await readPlanReceipt(input.planFilePath, directory);
      if (current.identity !== receipt.identity || current.text !== receipt.text) throw new Error('The plan changed while approval was open. Review a fresh plan before continuing.');
      signal.throwIfAborted();
    }
    return response;
  };
}

async function readPlanReceipt(file, directory) {
  if (typeof file !== 'string' || !path.isAbsolute(file) || path.extname(file) !== '.md') throw new Error('The plan file cannot be verified.');
  let handle;
  try {
    const parent = await realpath(directory);
    if (await realpath(path.dirname(file)) !== parent) throw new Error('The plan file is outside the agent plan folder.');
    handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const before = await handle.stat({ bigint: true }), limit = 1024 * 1024;
    if (!before.isFile() || before.size > BigInt(limit)) throw new Error('The plan file is not a supported text file.');
    const identity = stat => [stat.dev, stat.ino, stat.size, stat.mtimeNs, stat.ctimeNs].join(':');
    const bytes = Buffer.alloc(limit + 1); let count = 0;
    while (count < bytes.length) {
      const read = await handle.read(bytes, count, bytes.length - count, count);
      if (read.bytesRead === 0) break;
      count += read.bytesRead;
    }
    const after = await handle.stat({ bigint: true });
    const current = await lstat(file, { bigint: true });
    if (count > limit || BigInt(count) !== before.size || identity(before) !== identity(after)
      || !current.isFile() || identity(current) !== identity(after) || await realpath(path.dirname(file)) !== parent) throw new Error('The plan changed while it was being read.');
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, count));
    if (!text.trim()) throw new Error('The current plan is empty.');
    return { text, identity: identity(after) };
  } catch (error) { throw new Error(`Cannot verify the current plan: ${error.message}`, { cause: error }); }
  finally { await handle?.close(); }
}

export function installNativeSubagentCapabilityBridge(Agent) {
  const initialize = Agent.prototype.initialize;
  Agent.prototype.initialize = function(request) {
    if (request.clientInfo?.name === 'ccode' && request.clientCapabilities?._meta?.ccode?.nativeSubagents === true) {
      request = { ...request, clientCapabilities: { ...request.clientCapabilities, subagents: {} } };
    }
    return initialize.call(this, request);
  };
}

// The pinned official consumer already implements per-task lifecycle and Stop,
// but gates runtime creation on AIR (which also removes standard Read results).
// Select that same runtime only for an explicit ccode request; leave every
// ordinary capability and tool/permission renderer untouched.
export function installAsyncTaskBridge(Agent, AsyncTaskRuntime, asNotification) {
  const enabled = new WeakSet();
  const initialize = Agent.prototype.initialize, runConsumer = Agent.prototype.runConsumer;
  Agent.prototype.initialize = async function(request) {
    const response = await initialize.call(this, request);
    if (request.clientInfo?.name !== 'ccode' || request.clientCapabilities?._meta?.ccode?.asyncTasks !== true) return response;
    enabled.add(this);
    return { ...response, _meta: { ...response._meta, ccode: { ...response._meta?.ccode, asyncTasks: { version: 1, stopMethod: '_session/async_task/stop' } } } };
  };
  Agent.prototype.runConsumer = function(session, params) {
    if (enabled.has(this) && !session.asyncTaskRuntime) {
      session.asyncTaskRuntime = new AsyncTaskRuntime(true, params.sessionId, notification => this.client.sessionUpdate(asNotification(notification)), {
        routeOf: toolCallId => session.nativeSubagentRuntime?.routeOfToolCall(toolCallId, session.eagerToolCallSessions?.get(toolCallId)),
      });
    }
    return runConsumer.call(this, session, params);
  };
}

// Reuse the pinned adapter's registered task-control route, with an opaque
// private handle explicitly announced for one native child generation. SDK
// task IDs are reusable; they must never be accepted as child control handles.
export function installNativeSubagentStopBridge(Agent, asNotification) {
  const states = new WeakMap(), prefix = 'ccode-subagent:';
  const initialize = Agent.prototype.initialize, stop = Agent.prototype.stopAsyncTask;
  Agent.prototype.initialize = async function(request) {
    const response = await initialize.call(this, request);
    let state = states.get(this);
    if (!state) {
      state = { enabled: false, handles: new WeakMap(), stopping: new WeakSet() };
      states.set(this, state);
      const publish = this.client.sessionUpdate, agent = this;
      this.client.sessionUpdate = async function(notification) {
        if (state.enabled && notification.update?.sessionUpdate === 'subagent_spawned') {
          for (const session of Object.values(agent.sessions)) {
            if (typeof session?.query?.stopTask !== 'function') continue;
            const child = session.nativeSubagentRuntime?.childOfSession(notification.update.subagentSessionId);
            if (!child || child.parentSessionId !== notification.sessionId || child.terminalState !== undefined) continue;
            let handle = state.handles.get(child);
            if (!handle) { handle = prefix + randomUUID(); state.handles.set(child, handle); }
            const capabilities = notification.update.capabilities ?? {};
            notification = { ...notification, update: { ...notification.update, capabilities: { ...capabilities,
              _meta: { ...capabilities._meta, ccode: { ...capabilities._meta?.ccode,
                stopTask: { version: 1, method: '_session/async_task/stop', taskId: handle } } } } } };
            break;
          }
        }
        return publish.call(this, notification);
      };
    }
    state.enabled = request.clientInfo?.name === 'ccode'
      && request.clientCapabilities?._meta?.ccode?.nativeSubagents === true
      && request.clientCapabilities?._meta?.ccode?.nativeSubagentStop === true;
    if (!state.enabled) return response;
    return { ...response, _meta: { ...response._meta, ccode: { ...response._meta?.ccode,
      nativeSubagentStop: { version: 1, stopMethod: '_session/async_task/stop' } } } };
  };
  Agent.prototype.stopAsyncTask = async function(params) {
    if (!params.asyncTaskId?.startsWith(prefix)) return stop.call(this, params);
    const state = states.get(this);
    const session = Object.hasOwn(this.sessions, params.sessionId) ? this.sessions[params.sessionId] : undefined;
    const runtime = session?.nativeSubagentRuntime;
    if (!state?.enabled || !runtime || typeof session.query?.stopTask !== 'function') return { stopped: false };
    for (const [taskId, child] of session.nativeSubagentsByTaskId) {
      if (state.handles.get(child) !== params.asyncTaskId || !child.announced || child.terminalState !== undefined || state.stopping.has(child)) continue;
      // A namespace collision must never redirect an ordinary async control.
      if (session.asyncTaskRuntime?.canStop?.(params.asyncTaskId)) return { stopped: false };
      state.stopping.add(child);
      try {
        await session.query.stopTask(taskId);
        if (session.nativeSubagentsByTaskId.get(taskId) === child && child.terminalState === undefined) {
          const deliver = async notification => {
            const routed = await runtime.route(notification, deliver);
            if (routed) await this.client.sessionUpdate(asNotification(routed));
          };
          await runtime.finishTask(taskId, 'stopped', deliver);
        }
        return { stopped: true };
      } finally { state.stopping.delete(child); }
    }
    return { stopped: false };
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [, , entry, ...args] = process.argv;
  if (!entry) throw new Error('An official adapter entry path is required.');
  const pkg = JSON.parse(await readFile(path.join(path.dirname(entry), '..', 'package.json'), 'utf8'));
  if (pkg.name !== '@agentclientprotocol/claude-agent-acp' || pkg.version !== '0.84.0') {
    throw new Error('Reverify native-subagent compatibility before using another adapter version.');
  }
  const { ClaudeAcpAgent } = await import(pathToFileURL(path.join(path.dirname(entry), 'acp-agent.js')).href);
  const { AsyncTaskRuntime } = await import(pathToFileURL(path.join(path.dirname(entry), 'async-tasks.js')).href);
  const { asSdkSessionNotification } = await import(pathToFileURL(path.join(path.dirname(entry), 'acp-subagents.js')).href);
  installNativeSubagentCapabilityBridge(ClaudeAcpAgent);
  installAsyncTaskBridge(ClaudeAcpAgent, AsyncTaskRuntime, asSdkSessionNotification);
  installNativeSubagentStopBridge(ClaudeAcpAgent, asSdkSessionNotification);
  installPlanFreshnessBridge(ClaudeAcpAgent);
  // Resolve the same public SDK instance the pinned adapter imports.
  const { AgentApp, RequestError } = await import(pathToFileURL(createRequire(pathToFileURL(entry)).resolve('@agentclientprotocol/sdk')).href);
  installFileCheckpointBridge(ClaudeAcpAgent, AgentApp, RequestError);
  installConfigurationBridge(ClaudeAcpAgent, AgentApp, RequestError);
  const sdkRequire=createRequire(pathToFileURL(entry));
  const sdkEntry=sdkRequire.resolve('@anthropic-ai/claude-agent-sdk');
  const sdkPackage=JSON.parse(await readFile(path.join(path.dirname(sdkEntry),'package.json'),'utf8'));
  let verifiedSideQuestions=false;
  if(!process.env.CLAUDE_CODE_EXECUTABLE&&process.platform==='darwin'&&process.arch==='arm64'&&sdkPackage.version==='0.3.284'){
    const nativeRequire=createRequire(pathToFileURL(sdkEntry));
    const cli=nativeRequire.resolve('@anthropic-ai/claude-agent-sdk-darwin-arm64/claude');
    const cliPackage=JSON.parse(await readFile(path.join(path.dirname(cli),'package.json'),'utf8'));
    verifiedSideQuestions=cliPackage.version==='0.3.284';
  }
  installSideQuestionBridge(ClaudeAcpAgent,AgentApp,RequestError,verifiedSideQuestions);
  process.argv = [process.argv[0], entry, ...args];
  await import(pathToFileURL(entry).href);
}
