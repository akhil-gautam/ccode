// Disk-backed checkpoint conflict checks and recovery copies. No file contents
// are retained in previews; hashing reads at most 64 KiB at a time.
import { constants } from 'node:fs';
import { lstat, realpath, open, mkdtemp, copyFile, writeFile, chmod, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';

const within = (root, target) => { const relative = path.relative(root, target); return relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative); };
const directoryIdentity = stat => `${stat.dev}:${stat.ino}:${stat.mode}`;
const fileIdentity = stat => `${stat.dev}:${stat.ino}:${stat.mode}:${stat.nlink}:${stat.size}:${stat.mtimeNs}:${stat.ctimeNs}`;

export async function checkpointRecoveryRoot(value) {
  if (typeof value !== 'string' || !path.isAbsolute(value) || value.includes('\0')) return undefined;
  try {
    const location = await realpath(value), stat = await lstat(location, { bigint: true });
    if (!stat.isDirectory() || (Number(stat.mode) & 0o077) !== 0 || Number(stat.uid) !== process.getuid?.()) return undefined;
    return { location, identity: directoryIdentity(stat) };
  } catch { return undefined; }
}

export async function checkpointFileSnapshot(session, files) {
  const roots = [];
  for (const selected of [session.cwd, ...(session.creationParams?.additionalDirectories ?? [])]) {
    const canonical = await realpath(selected), stat = await lstat(canonical, { bigint: true });
    if (!stat.isDirectory()) throw Error('Workspace root changed.');
    roots.push({ selected: path.resolve(selected), canonical, identity: directoryIdentity(stat) });
  }
  const seen = new Set(), snapshots = [];
  for (const file of files) {
    const target = path.resolve(session.cwd, file);
    const root = roots.filter(value => within(value.selected, target) || within(value.canonical, target))
      .sort((a, b) => b.canonical.length - a.canonical.length)[0];
    if (!root) throw Error('Checkpoint path is outside the workspace.');
    const relative = path.relative(within(root.canonical, target) ? root.canonical : root.selected, target);
    const location = path.resolve(root.canonical, relative);
    if (!relative || seen.has(location)) throw Error('Checkpoint contains an ambiguous or duplicate file path.');
    seen.add(location);
    const parents = [];
    let current = root.canonical;
    for (const component of relative.split(path.sep).slice(0, -1)) {
      current = path.join(current, component);
      try {
        const stat = await lstat(current, { bigint: true });
        if (!stat.isDirectory() || stat.isSymbolicLink()) throw Error('Checkpoint parent is a link or non-directory.');
        parents.push([current, directoryIdentity(stat)]);
      } catch (error) { if (error.code !== 'ENOENT') throw error; parents.push([current, null]); }
    }
    const fingerprint = await readCheckpointFile(location);
    snapshots.push({ location, parents, ...fingerprint });
  }
  return { roots, files: snapshots.sort((a, b) => a.location.localeCompare(b.location)) };
}

async function readCheckpointFile(location) {
  let initial;
  try { initial = await lstat(location, { bigint: true }); }
  catch (error) { if (error.code === 'ENOENT') return { identity: null, hash: null, mode: null, size: null }; throw error; }
  if (!initial.isFile() || initial.isSymbolicLink() || initial.nlink !== 1n) throw Error('Checkpoint file is a link or non-regular file.');
  const handle = await open(location, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const opened = await handle.stat({ bigint: true });
    if (fileIdentity(opened) !== fileIdentity(initial)) throw Error('File changed during checkpoint inspection.');
    const hash = createHash('sha256'), buffer = Buffer.alloc(64 * 1024);
    for (;;) { const { bytesRead } = await handle.read(buffer, 0, buffer.length, null); if (!bytesRead) break; hash.update(buffer.subarray(0, bytesRead)); }
    const final = await handle.stat({ bigint: true }), current = await lstat(location, { bigint: true });
    if (fileIdentity(final) !== fileIdentity(initial) || fileIdentity(current) !== fileIdentity(initial)) throw Error('File changed during checkpoint inspection.');
    return { identity: fileIdentity(initial), hash: hash.digest('hex'), mode: Number(initial.mode) & 0o777, size: initial.size.toString() };
  } finally { await handle.close(); }
}

export function sameCheckpointSnapshot(a, b) { return JSON.stringify(a) === JSON.stringify(b); }

export async function prepareCheckpointRecovery(recovery, snapshot, identity) {
  const current = await checkpointRecoveryRoot(recovery.location);
  if (!current || current.identity !== recovery.identity || snapshot.roots.some(root => within(root.canonical, current.location))) {
    throw Error('Recovery storage changed or is inside the workspace.');
  }
  const directory = await mkdtemp(path.join(current.location, 'restore-'));
  try {
    await chmod(directory, 0o700);
    const files = [];
    for (const [index, file] of snapshot.files.entries()) {
      const backup = file.identity === null ? null : `${index}.before`;
      if (backup) {
        const target = path.join(directory, backup);
        await copyFile(file.location, target, constants.COPYFILE_EXCL); await chmod(target, 0o600);
        const copied = await readCheckpointFile(target);
        if (copied.hash !== file.hash || copied.size !== file.size) throw Error('File changed while making the recovery copy.');
        const handle = await open(target, 'r');
        try { await handle.sync(); } finally { await handle.close(); }
      }
      files.push({ path: file.location, backup, mode: file.mode, hash: file.hash, size: file.size });
    }
    await recordCheckpointRecovery(directory, { version: 1, ...identity, status: 'prepared', files });
    return { directory, files };
  } catch (error) { await rm(directory, { recursive: true, force: true }); throw error; }
}

export async function recordCheckpointRecovery(directory, manifest) {
  const handle = await open(path.join(directory, 'manifest.json'), 'w', 0o600);
  try { await handle.writeFile(JSON.stringify(manifest, null, 2) + '\n'); await handle.sync(); }
  finally { await handle.close(); }
}
