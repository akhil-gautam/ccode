import json,sys,time,threading
from pathlib import Path
connection='76659112-0d94-4a67-8235-48032b7f8601'
root='b61a1450-0838-4976-bcfe-1ce982df9a69'
status='connected';delay=0;bad=False;directory=None;prompts=0;flow=None;auth_calls=0
lock=threading.Lock()
def send(**message):
    with lock: print(json.dumps(dict(jsonrpc='2.0',**message)),flush=True)
def config(message):
    global status,flow,auth_calls
    params=message['params'];operation=params['operation']
    time.sleep(delay)
    if operation=='toggle': status='connected' if params['enabled'] else 'disabled'
    elif operation=='reconnect': status='connected'
    authentication={}
    if operation=='beginAuthentication':
        auth_calls+=1;flow='0bf71c25-8ea5-4449-8ab4-df6fbd14f181'
        authentication=dict(authentication=dict(id=flow,name='fixture',state='pending',url='https://issuer.example/authorize?state=private-fixture'))
    elif operation=='authenticationStatus': authentication=dict(authentication=dict(id=flow,name='fixture',state='connected' if status=='connected' else 'pending',**({} if status=='connected' else dict(url='https://issuer.example/authorize?state=private-fixture'))))
    elif operation=='cancelAuthentication':
        authentication=dict(authentication=dict(id=flow,name='fixture',state='cancelled'));flow=None
    send(id=message['id'],result=dict(**authentication,version=1,connectionId=connection,sessionId='a8bcb97d-5f8a-4b67-bba2-d349989fb59a' if bad else root,operation=operation,servers=[dict(name='fixture',status=status,source='project',scope='project',tools=['read_fixture'])]))
for line in sys.stdin:
    message=json.loads(line);method=message.get('method');ident=message.get('id');params=message.get('params',{})
    if method=='initialize': send(id=ident,result=dict(protocolVersion=1,agentInfo=dict(name='@agentclientprotocol/claude-agent-acp',version='0.84.0'),agentCapabilities={},_meta=dict(ccode=dict(configurationManagement=dict(version=1,connectionId=connection,method='_ccode/configuration',authenticationVersion=1)))))
    elif method=='session/new': directory=Path(params['cwd']);send(id=ident,result=dict(sessionId=root))
    elif method=='_ccode/configuration': threading.Thread(target=config,args=(message,),daemon=True).start()
    elif method=='fixture/auth-required': status='needs-auth';send(id=ident,result={})
    elif method=='fixture/auth-complete': status='connected';send(id=ident,result={})
    elif method=='fixture/hold': delay=0.3;send(id=ident,result={})
    elif method=='fixture/bad-response': bad=True;send(id=ident,result={})
    elif method=='fixture/state': send(id=ident,result=dict(prompts=prompts,status=status,auth_calls=auth_calls,flow=flow))
    elif method=='session/prompt':
        prompts+=1;directory.joinpath('prompts.txt').write_text(str(prompts))
        send(method='session/update',params=dict(sessionId=root,update=dict(sessionUpdate='agent_message_chunk',content=dict(type='text',text='Completed after configuration'))))
        send(id=ident,result=dict(stopReason='end_turn'))
    elif ident is not None: send(id=ident,result={})
