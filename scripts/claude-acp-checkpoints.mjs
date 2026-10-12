// Version-scoped adapter 0.84.0 extension. Uses the public ACP handler builder
// and supported SDK rewindFiles; restoration needs a fresh, one-use preview.
import { AsyncLocalStorage } from 'node:async_hooks';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { realpathSync } from 'node:fs';
import { checkpointRecoveryRoot, checkpointFileSnapshot, sameCheckpointSnapshot,
  prepareCheckpointRecovery, recordCheckpointRecovery } from './claude-acp-checkpoint-files.mjs';

const previewMethod = '_ccode/checkpoint/preview', notificationMethod = '_ccode/checkpoint';
const restoreMethod = '_ccode/checkpoint/restore';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const maximumCheckpoints = 4096;

export function installFileCheckpointBridge(Agent, AgentApp, RequestError) {
  const states = new WeakMap(), initializing = new Map(), promptContext = new AsyncLocalStorage();
  const originalInitialize = Agent.prototype.initialize;
  const originalOnRequest = AgentApp.prototype.onRequest;
  AgentApp.prototype.onRequest = function(method, handlerOrParser, handler) {
    if (method !== 'initialize' || handler) return originalOnRequest.call(this, method, handlerOrParser, handler);
    let owner, connectionId;
    const identityParser = { parse: value => {
      if (!value || typeof value !== 'object' || Array.isArray(value)
          || !['sessionId', 'checkpointId', 'promptId', 'connectionId'].every(key => typeof value[key] === 'string' && uuid.test(value[key]))) {
        throw RequestError.invalidParams(undefined, 'Invalid checkpoint identity.');
      }
      return value;
    } };
    originalOnRequest.call(this, previewMethod, identityParser, ctx => {
      if (!owner || connectionId !== ctx.params.connectionId) throw RequestError.methodNotFound(previewMethod);
      return preview(owner, ctx.params, ctx.signal);
    });
    originalOnRequest.call(this, restoreMethod, { parse: value => {
      identityParser.parse(value);
      if (typeof value.previewToken !== 'string' || !uuid.test(value.previewToken)) throw RequestError.invalidParams(undefined, 'Invalid checkpoint preview token.');
      return value;
    } }, ctx => {
      if (!owner || connectionId !== ctx.params.connectionId || !states.get(owner)?.recovery) throw RequestError.methodNotFound(restoreMethod);
      return restore(owner, ctx.params, ctx.signal);
    });
    return originalOnRequest.call(this, method, async ctx => {
      const response = await handlerOrParser(ctx);
      const id = response._meta?.ccode?.fileCheckpoints?.connectionId;
      owner = initializing.get(id); connectionId = id; initializing.delete(id);
      return response;
    });
  };
  Agent.prototype.initialize = async function(request) {
    const response = await originalInitialize.call(this, request);
    const enabled = request.clientInfo?.name === 'ccode' && request.clientCapabilities?._meta?.ccode?.fileCheckpoints === true;
    if (!enabled) { states.delete(this); return response; }
    const recovery = await checkpointRecoveryRoot(request.clientCapabilities?._meta?.ccode?.fileCheckpointRecoveryDirectory);
    const state = { id: randomUUID(), sessions: new WeakMap(), recovery };
    states.set(this, state); initializing.set(state.id, this);
    const publish = this.client.extNotification, agent = this;
    this.client.extNotification = async function(method, params) {
      const currentState = states.get(agent);
      const session = agent.sessions?.[params?.sessionId];
      const tracked = currentState?.sessions.get(session);
      if (method === '_claude/sdkMessage' && tracked && session.query === tracked.query) {
        const message = params.message;
        const checkpoint = message?.type === 'user' && !message.parent_tool_use_id ? tracked.checkpoints.get(message.uuid) : undefined;
        if (checkpoint && !checkpoint.echoed) {
          checkpoint.echoed = true;
          await publish.call(this, notificationMethod, { version: 1, connectionId: currentState.id,
            sessionId: params.sessionId, promptId: checkpoint.promptId, checkpointId: message.uuid });
        }
        // A small private echo is used for identity. Never forward full content
        // merely because checkpoint tracking requested SDK user messages.
        if (!rawRequested(tracked.raw, message)) return;
      }
      return publish.call(this, method, params);
    };
    return { ...response, _meta: { ...response._meta, ccode: { ...response._meta?.ccode,
      fileCheckpoints: { version: 1, connectionId: state.id, previewMethod, notificationMethod,
        ...(recovery ? { restoreMethod } : {}) } } } };
  };
  for (const name of ['newSession', 'loadSession', 'resumeSession']) {
    const original = Agent.prototype[name];
    if (typeof original !== 'function') continue;
    Agent.prototype[name] = function(params) {
      assertNoRestore(this, params);
      if (states.has(this)) params = { ...params, _meta: { ...params._meta,
        claudeCode: { ...params._meta?.claudeCode, options: { ...params._meta?.claudeCode?.options, enableFileCheckpointing: true } } } };
      return original.call(this, params);
    };
  }
  const originalPrompt = Agent.prototype.prompt;
  Agent.prototype.prompt = function(params) {
    assertNoRestore(this, params);
    const promptId = params._meta?.ccode?.promptId;
    return promptContext.run(states.has(this) && typeof promptId === 'string' && uuid.test(promptId)
      ? { agent: this, sessionId: params.sessionId, promptId } : undefined, () => originalPrompt.call(this, params));
  };
  const originalEnsureConsumer = Agent.prototype.ensureConsumer;
  Agent.prototype.ensureConsumer = function(session, sessionId) {
    const state = states.get(this), context = promptContext.getStore();
    if (state && context?.agent === this && context.sessionId === sessionId && typeof session.query?.rewindFiles === 'function') {
      let tracked = state.sessions.get(session);
      if (!tracked || tracked.query !== session.query) {
        tracked = { query: session.query, checkpoints: new Map(), previews: new Map(), raw: session.emitRawSDKMessages ?? false };
        state.sessions.set(session, tracked);
      }
      const turn = session.turnQueue?.at(-1);
      if (turn && uuid.test(turn.promptUuid) && !turn.settled && !tracked.checkpoints.has(turn.promptUuid)
          && ![...tracked.checkpoints.values()].some(value => value.promptId === context.promptId)) {
        tracked.checkpoints.set(turn.promptUuid, { promptId: context.promptId, echoed: false });
        while (tracked.checkpoints.size > maximumCheckpoints) tracked.checkpoints.delete(tracked.checkpoints.keys().next().value);
      }
      if (tracked.raw !== true) {
        session.emitRawSDKMessages = [...(Array.isArray(tracked.raw) ? tracked.raw : []), { type: 'user' }];
      }
    }
    return originalEnsureConsumer.call(this, session, sessionId);
  };
  for (const name of ['steer', 'closeSession', 'setSessionMode', 'setSessionConfigOption', 'unstable_forkSession']) {
    const original = Agent.prototype[name];
    if (typeof original === 'function') Agent.prototype[name] = function(params) {
      assertNoRestore(this, params); return original.call(this, params);
    };
  }
  const originalDispose = Agent.prototype.dispose;
  if (typeof originalDispose === 'function') Agent.prototype.dispose = function(...args) {
    const state = states.get(this); if (state) initializing.delete(state.id);
    states.delete(this); return originalDispose.apply(this, args);
  };

  function bound(agent, params) {
    const state = states.get(agent);
    const session = Object.hasOwn(agent.sessions ?? {}, params.sessionId) ? agent.sessions[params.sessionId] : undefined;
    const tracked = session && state?.sessions.get(session);
    const checkpoint = tracked?.checkpoints.get(params.checkpointId);
    if (!state || state.id !== params.connectionId || !checkpoint?.echoed || checkpoint.promptId !== params.promptId
        || session.query !== tracked.query || session.queryClosed || typeof tracked.query.rewindFiles !== 'function') {
      throw RequestError.invalidParams(undefined, 'Checkpoint is unavailable or its query changed.');
    }
    if (tracked.restoring) throw RequestError.invalidParams(undefined, 'File restoration is already in progress.');
    return { state, session, tracked };
  }
  function assertCurrent(agent, params, session, tracked) {
    if (agent.sessions[params.sessionId] !== session || session.query !== tracked.query || session.queryClosed
        || Object.values(agent.sessions).some(other => overlaps(session, other) && liveWork(other))) {
      throw RequestError.invalidParams(undefined, 'Session or workspace work changed while inspecting the checkpoint.');
    }
  }
  function assertNoRestore(agent, params) {
    const state = states.get(agent), selected = agent.sessions?.[params?.sessionId];
    if (!state) return;
    const target = selected ?? { cwd: params?.cwd, creationParams: params };
    if (Object.values(agent.sessions ?? {}).some(session => state.sessions.get(session)?.restoring && (!target.cwd || overlaps(session, target)))) {
      throw RequestError.invalidParams(undefined, 'Wait for file restoration to finish.');
    }
  }
  async function inspect(agent, params, session, tracked, signal) {
    assertCurrent(agent, params, session, tracked);
    if (signal.aborted) throw RequestError.requestCancelled();
    const result = await tracked.query.rewindFiles(params.checkpointId, { dryRun: true });
    if (signal.aborted) throw RequestError.requestCancelled();
    assertCurrent(agent, params, session, tracked);
    if (typeof result?.canRewind !== 'boolean' || (result.filesChanged !== undefined && !Array.isArray(result.filesChanged))) {
      throw RequestError.internalError(undefined, 'Invalid checkpoint preview response.');
    }
    const files = result.filesChanged ?? [];
    if (files.length > 1024 || files.some(value => typeof value !== 'string' || !value.length || Buffer.byteLength(value) > 4096 || value.includes('\0')
        || !insideWorkspace(session, value)) || files.reduce((bytes, value) => bytes + Buffer.byteLength(value), 0) > 256 * 1024) {
      throw RequestError.internalError(undefined, 'Checkpoint paths are invalid or outside the selected workspace.');
    }
    return { version: 1, ...identity(params), canRewind: result.canRewind, filesChanged: files,
      insertions: count(result.insertions), deletions: count(result.deletions), declaredComplete: false };
  }
  async function preview(agent, params, signal) {
    const { state, session, tracked } = bound(agent, params);
    const result = await inspect(agent, params, session, tracked, signal);
    if (!state.recovery || !result.canRewind || !result.filesChanged.length) return result;
    let snapshot;
    try { snapshot = await checkpointFileSnapshot(session, result.filesChanged); }
    catch (error) { return { ...result, restoreUnavailable: error.message }; }
    assertCurrent(agent, params, session, tracked);
    if (tracked.restoring) throw RequestError.invalidParams(undefined, 'File restoration began while inspecting the checkpoint.');
    if (signal.aborted) throw RequestError.requestCancelled();
    const previewToken = randomUUID();
    tracked.previews.set(previewToken, { identity: identity(params), result, snapshot, expires: Date.now() + 10 * 60 * 1000 });
    while (tracked.previews.size > 4) tracked.previews.delete(tracked.previews.keys().next().value);
    return { ...result, previewToken };
  }
  async function restore(agent, params, signal) {
    const { state, session, tracked } = bound(agent, params);
    const prior = tracked.previews.get(params.previewToken);
    if (!prior || prior.expires < Date.now() || JSON.stringify(prior.identity) !== JSON.stringify(identity(params))) {
      throw RequestError.invalidParams(undefined, 'Checkpoint preview is unavailable or expired. Refresh before restoring.');
    }
    tracked.previews.delete(params.previewToken); tracked.restoring = true;
    let mutationStarted = false;
    try {
      const fresh = await inspect(agent, params, session, tracked, signal);
      const snapshot = await checkpointFileSnapshot(session, fresh.filesChanged);
      if (!fresh.canRewind || fresh.insertions !== prior.result.insertions || fresh.deletions !== prior.result.deletions
          || !sameCheckpointSnapshot(prior.snapshot, snapshot)) {
        throw RequestError.invalidParams(undefined, 'File or checkpoint changes conflict with the preview. Refresh before restoring.');
      }
      const backup = await prepareCheckpointRecovery(state.recovery, snapshot, identity(params));
      // Backup copying is asynchronous. Recheck content, inode and parent/root
      // identities immediately before crossing the actual mutation boundary.
      if (!sameCheckpointSnapshot(snapshot, await checkpointFileSnapshot(session, fresh.filesChanged))) {
        throw RequestError.invalidParams(undefined, 'Files changed while preparing restoration. Nothing was restored.');
      }
      assertCurrent(agent, params, session, tracked);
      if (signal.aborted) throw RequestError.requestCancelled();
      let status = 'uncertain', details, skippedLinks = 0;
      try {
        // Once called, cancellation cannot promise the SDK stopped its writes.
        // Keep ownership and recovery copies until the actual operation settles.
        mutationStarted = true;
        const result = await tracked.query.rewindFiles(params.checkpointId);
        skippedLinks = count(result?.skippedLinks);
        if (result?.canRewind === true && result.error === undefined
            && (result.skippedLinks === undefined || Number.isSafeInteger(result.skippedLinks) && result.skippedLinks >= 0)) {
          status = skippedLinks ? 'partial' : 'completed';
        } else details = typeof result?.error === 'string' ? result.error.slice(0, 4096) : 'The provider did not confirm restoration.';
        if (agent.sessions[params.sessionId] !== session || session.query !== tracked.query) { status = 'uncertain'; details = 'The query changed during restoration.'; }
      } catch (error) { details = String(error.message ?? error).slice(0, 4096); }
      await recordCheckpointRecovery(backup.directory, { version: 1, ...identity(params), status, files: backup.files, skippedLinks, details });
      tracked.previews.clear();
      return { version: 1, ...identity(params), status, recoveryDirectory: backup.directory,
        skippedLinks, declaredComplete: false, ...(details ? { details } : {}) };
    } catch (error) {
      if (!mutationStarted && error.code !== -32602) throw RequestError.invalidParams(undefined, String(error.message ?? error).slice(0, 4096));
      throw error;
    } finally { tracked.restoring = false; }
  }
}
function identity(params) { return Object.fromEntries(['sessionId', 'checkpointId', 'promptId', 'connectionId'].map(key => [key, params[key]])); }
function overlaps(a, b) {
  try {
    const roots = value => [value.cwd, ...(value.creationParams?.additionalDirectories ?? [])].map(root => realpathSync(root));
    return roots(a).some(left => roots(b).some(right => within(left, right) || within(right, left)));
  } catch { return true; }
}
function count(value) { return Number.isSafeInteger(value) && value >= 0 ? value : 0; }
function insideWorkspace(session, value) {
  const target = path.resolve(session.cwd, value);
  const roots = [session.cwd, ...(session.creationParams?.additionalDirectories ?? [])];
  return roots.some(root => {
    if (typeof root !== 'string' || !path.isAbsolute(root)) return false;
    try {
      const canonicalRoot = realpathSync(root);
      // SDK file paths can use the real name while cwd retains a selected alias.
      // Check both spellings before touching metadata, then reject nested escapes.
      return (within(root, target) || within(canonicalRoot, target)) && within(canonicalRoot, canonicalPath(target));
    } catch { return false; }
  });
}
function within(root, target) {
  const relative = path.relative(root, target);
  return relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative);
}
function canonicalPath(target) {
  const missing = [];
  let current = target;
  for (;;) {
    try { return path.join(realpathSync(current), ...missing.reverse()); }
    catch (error) {
      if (!['ENOENT', 'ENOTDIR'].includes(error.code) || current === path.dirname(current)) throw error;
      missing.push(path.basename(current)); current = path.dirname(current);
    }
  }
}
function liveWork(session) {
  return (session.turnQueue ?? []).some(turn => !turn.settled)
    || [...(session.nativeSubagentsByTaskId?.values() ?? [])].some(child => child.terminalState === undefined)
    || [...(session.asyncTaskRuntime?.tasks?.values() ?? [])].some(task => !task.ignored && !['completed', 'failed', 'stopped'].includes(task.state));
}
function rawRequested(config, message) {
  return config === true || (Array.isArray(config) && config.some(filter => filter.type === message?.type
    && (filter.subtype === undefined || filter.subtype === message.subtype)
    && (filter.origin === undefined || filter.origin === message.origin?.kind)));
}
