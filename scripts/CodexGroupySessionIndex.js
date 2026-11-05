'use strict';

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');

const [codexRoot, outputPath, parentId] = process.argv.slice(2);
const sessions = path.join(codexRoot, 'sessions');
const indexPath = path.join(codexRoot, 'session_index.jsonl');
const rolloutPattern = /([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\.jsonl$/i;
const changedPaths = new Set();
const watchers = new Map();
let files = new Map();
let titles = {};
let needsReconcile = true;
let needsTitles = true;
let lastSnapshot = '';
let timer;
let flushing = false;

function wake(delay = 200) {
  if (timer || flushing) return;
  timer = setTimeout(() => {
    timer = undefined;
    void refresh();
  }, delay);
}

async function reconcile() {
  const next = new Map();
  const directories = [sessions];
  while (directories.length) {
    const directory = directories.pop();
    let children;
    try {
      children = await fsp.readdir(directory, { withFileTypes: true });
    } catch (error) {
      if (error.code === 'ENOENT') continue;
      throw error;
    }
    for (const entry of children) {
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) directories.push(absolute);
      else if (entry.isFile()) {
        const match = rolloutPattern.exec(entry.name);
        if (match) next.set(absolute, match[1].toLowerCase());
      }
    }
  }
  files = next;
}

async function refreshTitles() {
  let contents;
  try {
    contents = await fsp.readFile(indexPath, 'utf8');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    contents = '';
  }
  const next = Object.create(null);
  for (const line of contents.replace(/^\uFEFF/, '').split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const { id, thread_name } = JSON.parse(line);
      if (typeof id === 'string' && typeof thread_name === 'string') {
        next[id.toLowerCase()] = thread_name;
      }
    } catch { /* A writer may still be appending a partial record. */ }
  }
  titles = next;
}

function watch(root, recursive, onChange) {
  if (watchers.has(root)) return;
  try {
    const watcher = fs.watch(root, { recursive }, onChange);
    watchers.set(root, watcher);
    watcher.on('error', () => {
      watcher.close();
      watchers.delete(root);
      needsReconcile = true;
      needsTitles = true;
      wake(1000);
    });
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}

async function refresh() {
  flushing = true;
  let failed = false;
  try {
    watch(codexRoot, false, (event, name) => {
      if (!name || name.toLowerCase() === 'session_index.jsonl') {
        needsTitles = true;
        wake();
      } else if (event === 'rename' && name.toLowerCase() === 'sessions') {
        watchers.get(sessions)?.close();
        watchers.delete(sessions);
        needsReconcile = true;
        wake();
      }
    });
    watch(sessions, true, (event, name) => {
      if (!name || !rolloutPattern.test(name)) {
        if (event !== 'rename') return;
        // Date directories can be added or moved as a unit.
        needsReconcile = true;
      } else {
        const absolute = path.resolve(sessions, name);
        const relative = path.relative(sessions, absolute);
        if (path.isAbsolute(relative) || relative.startsWith('..')) return;
        if (event !== 'rename' && files.has(absolute)) return;
        changedPaths.add(absolute);
      }
      wake();
    });
    if (needsReconcile) {
      needsReconcile = false;
      await reconcile();
    }
    if (needsTitles) {
      needsTitles = false;
      await refreshTitles();
    }
    const changes = [...changedPaths];
    changedPaths.clear();
    for (const absolute of changes) {
      try {
        const stat = await fsp.lstat(absolute);
        if (stat.isFile()) files.set(absolute, rolloutPattern.exec(absolute)[1].toLowerCase());
        else files.delete(absolute);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
        files.delete(absolute);
      }
    }
    const paths = Object.create(null);
    for (const [absolute, id] of files) {
      // Prefer the newest dated rollout if the same thread has multiple files.
      if (!paths[id] || absolute > paths[id]) paths[id] = absolute;
    }
    const snapshot = JSON.stringify({ Titles: titles, Paths: paths });
    if (snapshot !== lastSnapshot) {
      const temporary = outputPath + '.' + process.pid + '.tmp';
      try {
        await fsp.writeFile(temporary, snapshot, 'utf8');
        await fsp.rename(temporary, outputPath);
      } finally {
        await fsp.rm(temporary, { force: true });
      }
      lastSnapshot = snapshot;
    }
  } catch (error) {
    failed = true;
    needsReconcile = true;
    needsTitles = true;
    process.stderr.write('Session index refresh failed: ' + error.code + '\n');
  } finally {
    flushing = false;
    if (needsReconcile || needsTitles || changedPaths.size) wake(failed ? 5000 : 200);
  }
}

// Reconcile infrequently in case a filesystem notification was dropped.
setInterval(() => {
  needsReconcile = true;
  needsTitles = true;
  wake();
}, 5 * 60 * 1000);
setInterval(() => {
  try { process.kill(Number(parentId), 0); } catch { process.exit(0); }
}, 1000);
void refresh();
