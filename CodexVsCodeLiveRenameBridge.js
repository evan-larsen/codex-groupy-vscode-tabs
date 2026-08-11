#!/usr/bin/env node
/*
 * Version-specific local bridge for the Codex VS Code extension.
 *
 * It uses VS Code's existing local Node Inspector endpoint to reach the
 * extension's already-initialized Codex app-server client.  A separately
 * started `codex app-server` can update a persisted rollout, but cannot
 * notify the already-open VS Code webview.  This bridge deliberately uses
 * that existing client instead.
 */

'use strict';

const bridgeArgs = process.argv.slice(2);
const [operation, inspectorUrl, threadId, name] = bridgeArgs;
const parentPidIndex = bridgeArgs.indexOf('--parent-pid');
const parentPid = parentPidIndex >= 0 ? Number(bridgeArgs[parentPidIndex + 1]) : null;

if (!['prepare', 'rename', 'watch-activity', 'trace-activity'].includes(operation) || !inspectorUrl) {
  process.stderr.write('Usage: CodexVsCodeLiveRenameBridge.js <prepare|rename|watch-activity|trace-activity> <inspector-url> [thread-id] [name]\n');
  process.exit(2);
}

class Inspector {
  constructor(url) {
    this.socket = new WebSocket(url);
    this.nextId = 1;
    this.pending = new Map();
    this.ready = new Promise((resolve, reject) => {
      this.socket.addEventListener('open', resolve, { once: true });
      this.socket.addEventListener('error', () => reject(new Error('Could not connect to the VS Code extension-host Inspector.')), { once: true });
    });
    this.socket.addEventListener('message', event => {
      let message;
      try { message = JSON.parse(event.data); } catch { return; }
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message || 'Inspector request failed.'));
      else pending.resolve(message.result);
    });
  }

  async call(method, params = {}) {
    await this.ready;
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
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

async function renameThroughPreparedConnection(client, requestedThreadId, requestedName) {
  const connection = await client.call('Runtime.evaluate', { expression: 'globalThis.__codexGroupyLiveAppServerConnection' });
  if (!connection.result?.objectId) return { ok: false, needsPrepare: true, error: 'Live connection is not prepared.' };

  const callback = `function(threadId, nextName) {
    const connection = this;
    const providerName = 'CodexGroupyLiveRename' + Date.now() + Math.random().toString(16).slice(2);
    const requestId = 'rename-' + Date.now();
    return new Promise(resolve => {
      let finished = false;
      const registration = connection.registerProvider(providerName, {
        onResult(message) {
          if (finished) return;
          finished = true;
          registration.dispose();
          resolve({ ok: !message.error, error: message.error?.message ?? null });
        }
      });
      connection.sendRequest(providerName, requestId, 'thread/name/set', { threadId, name: nextName });
      setTimeout(() => {
        if (finished) return;
        finished = true;
        registration.dispose();
        resolve({ ok: false, error: 'Timed out waiting for the VS Code Codex app-server response.' });
      }, 7000);
    });
  }`;
  const result = await client.call('Runtime.callFunctionOn', {
    objectId: connection.result.objectId,
    functionDeclaration: callback,
    arguments: [{ value: requestedThreadId }, { value: requestedName }],
    awaitPromise: true,
    returnByValue: true
  });
  return result.result?.value ?? { ok: false, error: 'VS Code did not return a rename result.' };
}

async function installActivityRequestObserver(client, traceNotifications = false) {
  const connection = await client.call('Runtime.evaluate', { expression: 'globalThis.__codexGroupyLiveAppServerConnection' });
  if (!connection.result?.objectId) return { ok: false, needsPrepare: true, error: 'Live connection is not prepared.' };
  const install = `function() {
    const connection = this;
    const key = '__codexGroupyActivityRequestState';
    let state = globalThis[key];
    if (!state) {
      state = { events: [], pendingByRequest: new Map(), traceNotifications: false, providerName: 'CodexGroupyActivityDots' + Date.now() + Math.random().toString(16).slice(2) };
      const pushEvent = event => {
        state.events.push(event);
        if (state.events.length > 500) state.events.splice(0, state.events.length - 500);
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
    return { ok: true, pending: Array.from(state.pendingByRequest.values()) };
  }`;
  const result = await client.call('Runtime.callFunctionOn', {
    objectId: connection.result.objectId,
    functionDeclaration: install,
    awaitPromise: true,
    returnByValue: true
  });
  return result.result?.value ?? { ok: false, error: 'VS Code did not return an activity-observer result.' };
}

async function drainActivityRequestEvents(client) {
  const result = await client.call('Runtime.evaluate', {
    expression: `(() => {
      const state = globalThis.__codexGroupyActivityRequestState;
      if (!state) return { ok: false, error: 'Activity observer is not installed.' };
      return { ok: true, events: state.events.splice(0), pending: Array.from(state.pendingByRequest.values()) };
    })()`,
    returnByValue: true
  });
  return result.result?.value ?? { ok: false, error: 'Could not read activity-request events.' };
}

async function watchActivityRequests(client, traceNotifications = false) {
  const prepared = await prepareConnection(client);
  if (!prepared.prepared) throw new Error(prepared.reason || 'Could not prepare the live Codex connection.');
  const installed = await installActivityRequestObserver(client, traceNotifications);
  if (!installed.ok) throw new Error(installed.error || 'Could not install the live activity observer.');
  process.stdout.write(`${JSON.stringify({ type: 'ready', pending: installed.pending ?? [], processId: prepared.processId ?? null })}\n`);
  while (true) {
    await new Promise(resolve => setTimeout(resolve, 175));
    if (Number.isInteger(parentPid) && parentPid > 0) {
      try { process.kill(parentPid, 0); } catch { return; }
    }
    const update = await drainActivityRequestEvents(client);
    if (!update.ok) throw new Error(update.error || 'The live activity observer was removed.');
    for (const event of update.events ?? []) process.stdout.write(`${JSON.stringify(event)}\n`);
  }
}

async function main() {
  const client = new Inspector(inspectorUrl);
  try {
    let result;
    if (operation === 'prepare') {
      result = await prepareConnection(client);
      process.stdout.write(`${JSON.stringify(result)}\n`);
      process.exitCode = result.ok === false ? 1 : 0;
    } else if (operation === 'rename') {
      if (!threadId || name == null) throw new Error('Rename requires both a thread id and a title.');
      result = await renameThroughPreparedConnection(client, threadId, name);
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
