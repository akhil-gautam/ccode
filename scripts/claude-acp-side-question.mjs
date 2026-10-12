// Version-scoped access to SDK0.3.284 / CLI2.1.284's built-in deny-all-tools
// side question. This is negotiated ccode metadata, not a general ACP claim.
import { randomUUID } from 'node:crypto';
const method = '_ccode/side_question';
const cancelMethod = '_ccode/side_question/cancel';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function installSideQuestionBridge(Agent, AgentApp, RequestError, verifiedRuntime) {
  const states = new WeakMap(), initializing = new Map();
  const initialize = Agent.prototype.initialize, onRequest = AgentApp.prototype.onRequest;
  Agent.prototype.initialize = async function(request) {
    const response = await initialize.call(this, request);
    if (!verifiedRuntime || request.clientInfo?.name !== 'ccode' || request.clientCapabilities?._meta?.ccode?.sideQuestions !== true) { states.delete(this); return response; }
    const state = {id:randomUUID(),busy:new WeakSet(),active:new WeakMap()};states.set(this,state);initializing.set(state.id,this);
    while(initializing.size>512)initializing.delete(initializing.keys().next().value);
    return {...response,_meta:{...response._meta,ccode:{...response._meta?.ccode,sideQuestions:{version:1,connectionId:state.id,method,cancelMethod}}}};
  };
  AgentApp.prototype.onRequest = function(name, parser, handler) {
    if(name!=='initialize'||handler)return onRequest.call(this,name,parser,handler);
    let owner, connection;
    onRequest.call(this,cancelMethod,{parse:params=>{
      if(!params||Array.isArray(params)||Object.keys(params).some(key=>!['sessionId','connectionId','questionId'].includes(key))||!['sessionId','connectionId','questionId'].every(key=>typeof params[key]==='string'&&uuid.test(params[key])))throw RequestError.invalidParams(undefined,'Invalid side-question cancellation.');
      return params;
    }},async ctx=>{
      const state=owner&&states.get(owner),p=ctx.params;
      if(!state||state.id!==connection||p.connectionId.toLowerCase()!==connection)throw RequestError.methodNotFound(cancelMethod);
      const session=Object.hasOwn(owner.sessions??{},p.sessionId)?owner.sessions[p.sessionId]:undefined;
      const active=session&&state.active.get(session);
      if(active&&active.id!==p.questionId.toLowerCase())throw RequestError.invalidParams(undefined,'This cancellation belongs to a different side question.');
      active?.controller.abort();
      return {version:1,sessionId:p.sessionId,connectionId:state.id,questionId:p.questionId,cancelled:!!active};
    });
    onRequest.call(this,method,{parse:params=>{
      if (!params || Array.isArray(params) || Object.keys(params).some(key=>!['sessionId','connectionId','questionId','question','history'].includes(key)) ||
        !['sessionId','connectionId','questionId'].every(key=>typeof params[key]==='string'&&uuid.test(params[key])) || !text(params.question,8192) ||
        !Array.isArray(params.history)||params.history.length>4||params.history.some(item=>!item||Array.isArray(item)||Object.keys(item).some(key=>!['question','response'].includes(key))||!text(item.question,8192)||!text(item.response,24576)) ||
        Buffer.byteLength(JSON.stringify(params))>160*1024) throw RequestError.invalidParams(undefined,'Invalid side question.');
      return params;
    }},async ctx=>{
      const state=owner&&states.get(owner), params=ctx.params;
      if(!state||state.id!==connection||params.connectionId.toLowerCase()!==connection)throw RequestError.methodNotFound(method);
      const session=Object.hasOwn(owner.sessions??{},params.sessionId)?owner.sessions[params.sessionId]:undefined, query=session?.query;
      const current=()=>{
        ctx.signal.throwIfAborted();
        if(!session||session.queryClosed||session.abortController?.signal.aborted||owner.sessions[params.sessionId]!==session||session.query!==query||states.get(owner)!==state)
          throw RequestError.invalidParams(undefined,'The conversation connection changed. Ask again in its current context.');
      };
      current();
      if(state.busy.has(session))throw RequestError.invalidParams(undefined,'A side question is already running in this conversation.');
      if(typeof query?.askSideQuestion!=='function')throw RequestError.methodNotFound(method);
      state.busy.add(session);
      const controller=new AbortController(),cancel=()=>controller.abort();
      ctx.signal.addEventListener('abort',cancel,{once:true});
      const deadline=setTimeout(cancel,180000);
      state.active.set(session,{id:params.questionId.toLowerCase(),controller});
      try {
        const result=await query.askSideQuestion(params.question,{history:params.history,signal:controller.signal});current();controller.signal.throwIfAborted();
        if(result!==null&&(!result||typeof result.synthetic!=='boolean'||!text(result.response,24576)))throw Error('Invalid answer');
        return {version:1,sessionId:params.sessionId,connectionId:state.id,questionId:params.questionId,answer:result?.response??null,synthetic:result?.synthetic??false};
      }catch(error){ctx.signal.throwIfAborted();if(error instanceof RequestError)throw error;throw RequestError.invalidParams(undefined,'Claude could not answer this side question. The main conversation continues.');}
      finally{clearTimeout(deadline);ctx.signal.removeEventListener('abort',cancel);state.active.delete(session);state.busy.delete(session);}
    });
    return onRequest.call(this,name,async ctx=>{
      const response=await parser(ctx);connection=response._meta?.ccode?.sideQuestions?.connectionId;
      owner=initializing.get(connection);initializing.delete(connection);return response;
    });
  };
}
function text(value,limit){return typeof value==='string'&&value.trim().length>0&&Buffer.byteLength(value)<=limit&&!value.includes('\0');}
