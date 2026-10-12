// Verify the installed Claude adapter preserves rendered PDF pages without model requests.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { promptToClaude } from "../.build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/acp-agent.js";

const path = process.argv[2];
assert(path, "Pass the wire JSON emitted by CCODE_ATTACHMENT_WIRE_PATH AttachmentTests.");
const prompt = JSON.parse(await readFile(path, "utf8"));
const converted = promptToClaude({ sessionId: "attachment-wire-check", prompt }).message.content;
assert.equal(prompt.filter(block => block.type === "image").length, 2);
assert.equal(converted.length, prompt.length);
assert(converted[0].text.includes("2 pages"));
for (let i = 1; i < converted.length; i++) {
  assert.equal(converted[i].type, "image");
  assert.equal(converted[i].source.type, "base64");
  assert.equal(converted[i].source.media_type, "image/jpeg");
  assert.equal(converted[i].source.data, prompt[i].data);
  assert(Buffer.from(converted[i].source.data, "base64").subarray(0, 2).equals(Buffer.from([0xff, 0xd8])));
}
console.log("Claude adapter PDF conversion: caption and both ordered JPEG pages preserved; zero model requests.");
