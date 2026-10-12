import assert from 'node:assert/strict';
import { installSideQuestionBridge } from './claude-acp-side-question.mjs';
const connection = '22222222-2222-4222-8222-222222222222';
const sessionId = '11111111-1111-4111-8111-111111111111';
const questionId = '33333333-3333-4333-8333-333333333333';
class RequestError extends Error { static invalidParams(_, text) { return new RequestError(text); } static methodNotFound(text) { return new RequestError(text); } }
class Agent { async initialize() { return {protocolVersion:1}; } }
class AgentApp { handlers = new Map(); onRequest(name, parser, handler) { this.handlers.set(name, handler ? async ctx=>handler({...ctx,params:parser.parse(ctx.params)}) : parser); } }
installSideQuestionBridge(Agent, AgentApp, RequestError, true);
const agent = new Agent(); let calls=0;
agent.sessions = {[sessionId]: {query:{async askSideQuestion(question, options) { calls++; assert.equal(question,'Read context'); assert.deepEqual(options.history,[{question:'First',response:'Answer'}]); return {response:'Retained answer',synthetic:false}; }}, abortController:new AbortController()}};
const app=new AgentApp();app.onRequest('initialize', ctx=>agent.initialize(ctx.params));
const initialize=await app.handlers.get('initialize')({params:{clientInfo:{name:'ccode'},clientCapabilities:{_meta:{ccode:{sideQuestions:true}}}}});
assert.equal(initialize._meta.ccode.sideQuestions.version,1);
const receipt=initialize._meta.ccode.sideQuestions.connectionId;
const invoke=params=>app.handlers.get('_ccode/side_question')({params,signal:new AbortController().signal});
const params={sessionId,connectionId:receipt.toUpperCase(),questionId,question:'Read context',history:[{question:'First',response:'Answer'}]};
const result=await invoke(params);
assert.equal(result.answer,'Retained answer');assert.equal(result.sessionId,sessionId);assert.equal(result.questionId,questionId);assert.equal(calls,1);
for(const bad of [{...params,connectionId:connection},{...params,sessionId:questionId},{...params,history:[{question:'First',response:7}]},{...params,extra:true},{...params,question:'x'.repeat(8193)}]) await assert.rejects(invoke(bad));
assert.equal(calls,1,'Rejected requests never invoke the provider');
agent.sessions[sessionId].query.askSideQuestion=async()=>({response:'x'.repeat(24577),synthetic:false});
await assert.rejects(invoke(params));
let release;const pending=new Promise(resolve=>release=resolve);
agent.sessions[sessionId].query.askSideQuestion=async()=>{await pending;return{response:'late',synthetic:false}};
const old=invoke(params);await Promise.resolve();
await assert.rejects(invoke(params),'Only one side question belongs to this root at once');
agent.sessions[sessionId].query={};release();await assert.rejects(old,'A replaced query cannot publish a stale answer');
console.log('Side-question ownership, schema, limits, concurrency and stale-query checks passed');

agent.sessions[sessionId].query={askSideQuestion:async(_,options)=>new Promise((resolve,reject)=>options.signal.addEventListener('abort',()=>reject(Error('cancelled')),{once:true}))};
const active=invoke(params);await Promise.resolve();
const cancel=params=>app.handlers.get('_ccode/side_question/cancel')({params,signal:new AbortController().signal});
await assert.rejects(cancel({sessionId,connectionId:receipt,questionId:connection}));
const cancelled=await cancel({sessionId,connectionId:receipt,questionId});assert.equal(cancelled.cancelled,true);
await assert.rejects(active);
assert.equal((await cancel({sessionId,connectionId:receipt,questionId})).cancelled,false);
console.log('Cancellation aborts exactly the owned side question');
