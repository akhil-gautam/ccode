// Resolve using the exact SDK installed beside the selected ACP adapter.
// This is a read-only cascade view, not a replacement for the provider's policy.
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
const [entry, cwd] = process.argv.slice(2);
const output = process.stdout.write.bind(process.stdout);
// SDK/file warnings may contain configuration text. Keep diagnostics private.
process.stdout.write = () => true;
process.stderr.write = () => true;
function redact(value, key = '') {
  if (/^(env|headers)$/i.test(key) && value && typeof value === 'object')
    return Object.fromEntries(Object.keys(value).map(name => [name, '[redacted]']));
  if (/secret|password|token|credential|api.?key|authorization/i.test(key)) return '[redacted]';
  if (Array.isArray(value)) return value.map(item => redact(item));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([name, item]) => [name, redact(item, name)]));
  return value;
}
try {
  const require = createRequire(entry);
  const sdk = await import(pathToFileURL(require.resolve('@anthropic-ai/claude-agent-sdk')).href);
  if (typeof sdk.resolveSettings !== 'function' || typeof sdk.filterEscalatingDefaultMode !== 'function') throw new Error();
  const resolved = await sdk.resolveSettings({ cwd });
  const snapshot = { effective: sdk.filterEscalatingDefaultMode(resolved), provenance: resolved.provenance, sources: resolved.sources,
    notice: 'Provider SDK cascade; policyHelper is not executed. Session flags, environment overrides and live agent policy may differ.' };
  output(JSON.stringify(redact(snapshot)));
} catch { output(JSON.stringify({ error: 'The selected Claude SDK could not resolve configuration.' })); process.exitCode = 1; }
