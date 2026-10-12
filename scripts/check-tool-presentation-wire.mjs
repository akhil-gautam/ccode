import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { AcpToolCallRenderer } from '../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/tool-calls/renderer.js';

const pkg = JSON.parse(await readFile(new URL('../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/package.json', import.meta.url), 'utf8'));
assert.equal(pkg.version, '0.84.0');
const renderer = AcpToolCallRenderer.for({ subagents: {} });
const read = { id: 'read', name: 'Read', input: { file_path: '/tmp/project/file.swift', offset: 20, limit: 2 } };
const start = renderer.toolCall(read, { cwd: '/tmp/project' });
assert.equal(start.kind, 'read');
assert.deepEqual(start.locations, [{ path: '/tmp/project/file.swift', line: 20 }]);
const result = renderer.result(read, { tool_use_id: 'read', content: 'model copy\n<system-reminder>model-only note</system-reminder>' }, {
  structured: { type: 'text', file: { content: 'let value = 1\nprint(value)\n', startLine: 20, numLines: 2, totalLines: 40 } }
}).at(-1);
assert.equal(result.status, 'completed');
assert.equal(result.content[0].content.text, '```\n20\tlet value = 1\n21\tprint(value)\n```');
assert.ok(result.rawOutput.includes('system-reminder'), 'The native view must choose canonical content over the model-facing copy');

const edit = renderer.toolCall({ id: 'edit', name: 'Edit', input: { file_path: '/tmp/project/file.swift', old_string: 'before', new_string: '' } });
assert.deepEqual(edit.content[0], { type: 'diff', path: '/tmp/project/file.swift', oldText: 'before', newText: '' });
const write = renderer.toolCall({ id: 'write', name: 'Write', input: { path: '/tmp/project/new.swift', file_text: 'created' } });
assert.equal(write.content[0].path, '/tmp/project/new.swift');
assert.equal(write.content[0].newText, 'created');
const partial = JSON.parse(JSON.stringify(renderer.toolCall({ id: 'partial', name: 'Write', input: { file_path: '/tmp/project/new.swift' } }, { inputComplete: false })));
assert.equal(partial.content[0].type, 'diff');
assert.equal(partial.content[0].newText, undefined, 'Absent content must not appear as a deletion');
const grep = renderer.toolCall({ id: 'grep', name: 'Grep', input: { pattern: 'TODO|FIXME', path: '/tmp/project', glob: '*.swift', '-i': true, '-n': true } });
assert.equal(grep.kind, 'search');
assert.equal(grep.rawInput.pattern, 'TODO|FIXME');
const matches = renderer.result({ id: 'grep', name: 'Grep', input: grep.rawInput }, { content: 'src/file.swift:8:TODO' }).at(-1);
assert.equal(matches.content[0].content.text, 'src/file.swift:8:TODO');
console.log('Pinned tool renderer: clean numbered Read, model-only raw duplication, scoped search, authoritative/partial diffs and Write aliases verified.');
