import json,sys,threading,time,uuid
session=str(uuid.uuid4());connection=str(uuid.uuid4());counts=dict(prompts=0,sideQuestions=0,cancels=0,sideCancels=0);pending=None
lock=threading.Lock()
def send(value):
    value['jsonrpc']='2.0'
    with lock: print(json.dumps(value),flush=True)
for line in sys.stdin:
    message=json.loads(line);method=message.get('method');ident=message.get('id');params=message.get('params',{})
    if method=='initialize':send(dict(id=ident,result=dict(protocolVersion=1,agentCapabilities={},_meta=dict(ccode=dict(sideQuestions=dict(version=1,method='_ccode/side_question',cancelMethod='_ccode/side_question/cancel',connectionId=connection))))))
    elif method=='session/new':send(dict(id=ident,result=dict(sessionId=session)))
    elif method=='session/prompt':
        pending=ident;counts['prompts']+=1
        send(dict(id='approval',method='session/request_permission',params=dict(sessionId=session,toolCall=dict(toolCallId='main',title='Main work',kind='execute'),options=[dict(optionId='allow',name='Allow',kind='allow_once')])))
    elif ident=='approval':send(dict(id=pending,result=dict(stopReason='cancelled')));pending=None
    elif method=='_ccode/side_question':
        counts['sideQuestions']+=1
        def reply(ident=ident,params=params):
            if params['question']=='Delayed':time.sleep(.25)
            if params['question']=='Failure':
                send(dict(id=ident,error=dict(code=-32603,message='Temporary failure')));return
            send(dict(id=ident,result=dict(version=1,sessionId=session,connectionId=connection,questionId=params['questionId'],answer='Answer: '+params['question'],synthetic=False)))
        threading.Thread(target=reply,daemon=True).start()
    elif method=='_ccode/side_question/cancel':
        counts['sideCancels']+=1;send(dict(id=ident,result=dict(cancelled=True)))
    elif method=='fixture/counts':send(dict(id=ident,result=counts))
    elif method=='session/cancel':counts['cancels']+=1
    elif method and ident is not None:send(dict(id=ident,error=dict(code=-32601,message='Unknown method')))
