#!/usr/bin/env node
/*
 * Version-specific local bridge for the Codex VS Code extension.
 *
 * It uses VS Code's existing local Node Inspector endpoint to reach the
 * extension's already-initialized Codex app-server client and observe
 * activity for the Groupy status dots.
 */

'use strict';

const bridgeArgs = process.argv.slice(2);
const [operation, inspectorUrl] = bridgeArgs;
const parentPidIndex = bridgeArgs.indexOf('--parent-pid');
const parentPid = parentPidIndex >= 0 ? Number(bridgeArgs[parentPidIndex + 1]) : null;

if (!['prepare', 'watch-activity', 'trace-activity'].includes(operation) || !inspectorUrl) {
  process.stderr.write('Usage: CodexVsCodeLiveRenameBridge.js <prepare|watch-activity|trace-activity> <inspector-url> [--parent-pid <pid>]\n');
  process.exit(2);
}

class Inspector {
  constructor(url) {
    this.socket = new WebSocket(url);
    this.nextId = 1;
    this.pending = new Map();
    this.ready = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('Inspector connection timed out.')), 8000);
      this.socket.addEventListener('open', () => { clearTimeout(timeout); resolve(); }, { once: true });
      this.socket.addEventListener('error', () => {
        clearTimeout(timeout);
        reject(new Error('Could not connect to the VS Code extension-host Inspector.'));
      }, { once: true });
    });
    this.socket.addEventListener('message', event => {
      let message;
      try { message = JSON.parse(event.data); } catch { return; }
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timeout);
      if (message.error) pending.reject(new Error(message.error.message || 'Inspector request failed.'));
      else pending.resolve(message.result);
    });
  }

  async call(method, params = {}) {
    await this.ready;
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error('Inspector request timed out: ' + method));
      }, 8000);
      this.pending.set(id, { resolve, reject, timeout });
      try { this.socket.send(JSON.stringify({ id, method, params })); }
      catch (error) {
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  close() {
    try { this.socket.close(); } catch { /* no-op */ }
  }
}

function property(properties, name) {
  const found = properties.result.find(item => item.name === name);
  if (!found || !found.value || !found.value.objectId) throw new Error(`Inspector property '${name}' was unavailable.`);
  return found.value;
}

async function prepareConnection(client) {
  const activationExpression = String.raw`(function(){
    const Module = process.getBuiltinModule('module');
    const requireFromBootstrap = Module.createRequire(process.argv[1]);
    const extensionPath = Object.keys(requireFromBootstrap.cache).find(path => /openai\.chatgpt-.*\\out\\extension\.js$/i.test(path));
    return extensionPath ? requireFromBootstrap.cache[extensionPath].exports.activate : null;
  })()`;
  const activation = await client.call('Runtime.evaluate', { expression: activationExpression });
  if (!activation.result || !activation.result.objectId) return { prepared: false, reason: 'Codex extension is not loaded in this extension host.' };

  const activationProperties = await client.call('Runtime.getProperties', { objectId: activation.result.objectId, ownProperties: true });
  const scopes = activationProperties.internalProperties?.find(item => item.name === '[[Scopes]]')?.value;
  if (!scopes?.objectId) return { prepared: false, reason: 'Could not inspect Codex extension scope.' };

  const scopeList = await client.call('Runtime.getProperties', { objectId: scopes.objectId, ownProperties: true });
  const closure = property(scopeList, '0');
  const closureProperties = await client.call('Runtime.getProperties', { objectId: closure.objectId, ownProperties: true });
  const webviewProviderClass = closureProperties.result.find(item => item.value?.objectId && item.value.description?.includes('CodexWebviewProvider'))?.value;
  if (!webviewProviderClass?.objectId) return { prepared: false, reason: 'Could not find CodexWebviewProvider in the loaded extension.' };

  const classProperties = await client.call('Runtime.getProperties', { objectId: webviewProviderClass.objectId, ownProperties: true });
  const prototype = property(classProperties, 'prototype');
  const objects = await client.call('Runtime.queryObjects', { prototypeObjectId: prototype.objectId });
  const provider = await client.call('Runtime.callFunctionOn', {
    objectId: objects.objects.objectId,
    functionDeclaration: 'function(){ return Array.from(this).find(item => item && item.codexMcpConnection); }'
  });
  if (!provider.result?.objectId) return { prepared: false, reason: 'No live Codex webview provider exists in this extension host.' };

  const providerProperties = await client.call('Runtime.getProperties', { objectId: provider.result.objectId, ownProperties: true });
  const connection = property(providerProperties, 'codexMcpConnection');
  const result = await client.call('Runtime.callFunctionOn', {
    objectId: connection.objectId,
    functionDeclaration: 'function(){ globalThis.__codexGroupyLiveAppServerConnection = this; return { initialized: this.initialized === true, processId: this.proc?.pid ?? null }; }',
    returnByValue: true
  });
  if (!result.result?.value?.initialized) return { prepared: false, reason: 'The VS Code Codex app-server client is not initialized.' };
  return { prepared: true, processId: result.result.value.processId };
}

async function installActivityRequestObserver(client, traceNotifications = false) {
  const connection = await client.call('Runtime.evaluate', { expression: 'globalThis.__codexGroupyLiveAppServerConnection' });
  if (!connection.result?.objectId) return { ok: false, needsPrepare: true, error: 'Live connection is not prepared.' };
  const install = String.raw`function() {
    const connection = this;
    const key = '__codexGroupyActivityRequestState';
    let state = globalThis[key];
    if (!state || state.version !== 2 || state.connection !== connection) {
      const previous = state?.connection && state.connection !== connection ? null : state;
      state?.registration?.dispose();
      state?.wake?.();
      state = {
        version: 2, connection, events: previous?.events ?? [],
        pendingByRequest: previous?.pendingByRequest ?? new Map(),
        traceNotifications: false, wake: null, overflowed: false,
        lifecycleByThread: previous?.lifecycleByThread ?? new Map(),
        providerName: 'CodexGroupyActivityDots' + Date.now() + Math.random().toString(16).slice(2)
      };
      const pushEvent = event => {
        const observed = { ...event, observedAtMs: Date.now() };
        if (event.type === 'notification' && event.threadId) {
          state.lifecycleByThread.delete(event.threadId);
          state.lifecycleByThread.set(event.threadId, observed);
          if (state.lifecycleByThread.size > 500) {
            state.lifecycleByThread.delete(state.lifecycleByThread.keys().next().value);
          }
        }
        state.events.push(observed);
        if (state.events.length > 500) {
          state.events.shift();
          state.overflowed = true;
        }
        state.wake?.();
      };
      const kindFor = request => {
        const method = String(request?.method || '');
        if (method === 'item/tool/requestUserInput') return 'user-input';
        if (method === 'mcpServer/elicitation/request') return 'elicitation';
        if (/approval|permission/i.test(method)) return 'approval';
        return null;
      };
      state.registration = connection.registerProvider(state.providerName, {
        onRequest(request) {
          const threadId = request?.params?.threadId;
          const kind = kindFor(request);
          if (!threadId || !kind || request?.id == null) return;
          const requestId = String(request.id);
          const pending = { threadId: String(threadId), requestId, kind };
          state.pendingByRequest.set(requestId, pending);
          pushEvent({ type: 'pending', ...pending });
        },
        onRawNotification(notification) {
          if (state.traceNotifications) {
            const method = String(notification?.method || '');
            const keepForLifecycle =
              /^(turn|task)\/(started|completed|complete|aborted|cancelled|canceled|failed|error)$/.test(method) ||
              /^thread\/status\/(updated|changed)$/.test(method);
            if (!keepForLifecycle) {
              if (notification?.method !== 'serverRequest/resolved') return;
            } else {
            const params = notification?.params && typeof notification.params === 'object' ? notification.params : {};
            const item = params.item && typeof params.item === 'object' ? params.item : {};
            pushEvent({
              type: 'notification',
              method,
              threadId: params.threadId ?? params.thread_id ?? item.threadId ?? null,
              turnId: params.turnId ?? params.turn_id ?? item.turnId ?? null,
              status: params.status ?? item.status ?? null,
              itemType: item.type ?? item.kind ?? null,
              paramKeys: Object.keys(params).slice(0, 16)
            });
            }
          }
          if (notification?.method !== 'serverRequest/resolved') return;
          const requestId = String(notification?.params?.requestId ?? '');
          const pending = state.pendingByRequest.get(requestId);
          if (!pending) return;
          state.pendingByRequest.delete(requestId);
          pushEvent({ type: 'resolved', ...pending });
        }
      });
      globalThis[key] = state;
    }
    state.traceNotifications = state.traceNotifications || ${traceNotifications ? 'true' : 'false'};
    return { ok: true, pending: Array.from(state.pendingByRequest.values()), lifecycle: Array.from(state.lifecycleByThread.values()) };
  }`;
  const result = await client.call('Runtime.callFunctionOn', {
    objectId: connection.result.objectId,
    functionDeclaration: install,
    awaitPromise: true,
    returnByValue: true
  });
  return result.result?.value ?? { ok: false, error: 'VS Code did not return an activity-observer result.' };
}

async function waitForActivityRequestEvents(client) {
  const result = await client.call('Runtime.evaluate', {
    expression: `(() => {
      const state = globalThis.__codexGroupyActivityRequestState;
      if (!state) return { ok: false, error: 'Activity observer is not installed.' };
      const drain = () => {
        const queued = state.events.splice(0);
        const events = state.overflowed ? Array.from(state.lifecycleByThread.values()) : queued;
        state.overflowed = false;
        return { ok: true, events, pending: Array.from(state.pendingByRequest.values()) };
      };
      if (state.events.length) return drain();
      return new Promise(resolve => {
        let batch;
        const finish = () => {
          clearTimeout(timeout);
          clearTimeout(batch);
          if (state.wake === wake) state.wake = null;
          resolve(drain());
        };
        const wake = () => { if (!batch) batch = setTimeout(finish, 25); };
        const timeout = setTimeout(finish, 4000);
        state.wake = wake;
      });
    })()`,
    awaitPromise: true,
    returnByValue: true
  });
  return result.result?.value ?? { ok: false, error: 'Could not read activity-request events.' };
}

async function watchActivityRequests(client, traceNotifications = false) {
  const prepared = await prepareConnection(client);
  if (!prepared.prepared) throw new Error(prepared.reason || 'Could not prepare the live Codex connection.');
  const installed = await installActivityRequestObserver(client, traceNotifications);
  if (!installed.ok) throw new Error(installed.error || 'Could not install the live activity observer.');
  process.stdout.write(`${JSON.stringify({ type: 'ready', pending: installed.pending ?? [], lifecycle: installed.lifecycle ?? [], processId: prepared.processId ?? null })}\n`);
  const parentCheck = setInterval(() => {
    if (!Number.isInteger(parentPid) || parentPid <= 0) return;
    try { process.kill(parentPid, 0); } catch { process.exit(0); }
  }, 1000);
  parentCheck.unref();
  try {
    let pendingSignature = JSON.stringify(installed.pending ?? []);
    while (true) {
      const update = await waitForActivityRequestEvents(client);
      if (!update.ok) throw new Error(update.error || 'The live activity observer was removed.');
      const signature = JSON.stringify(update.pending ?? []);
      if (update.events?.length || signature !== pendingSignature) {
        process.stdout.write(JSON.stringify({ type: 'activity-batch', events: update.events ?? [], pending: update.pending ?? [] }) + '\n');
      }
      pendingSignature = signature;
    }
  } finally {
    clearInterval(parentCheck);
  }
}

async function main() {
  const client = new Inspector(inspectorUrl);
  try {
    if (operation === 'prepare') {
      const result = await prepareConnection(client);
      process.stdout.write(`${JSON.stringify(result)}\n`);
      process.exitCode = result.ok === false ? 1 : 0;
    } else {
      await watchActivityRequests(client, operation === 'trace-activity');
    }
  } finally {
    client.close();
  }
}

main().catch(error => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
