import base64,hashlib,json,os,pathlib,secrets,sys,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import parse_qs,urlparse,urlencode
root=pathlib.Path(sys.argv[1]);clients={};codes={};tokens=set();events=[]
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def reply(self,status,body,headers={}):
        data=json.dumps(body).encode();self.send_response(status)
        self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)))
        for key,value in headers.items(): self.send_header(key,value)
        self.end_headers();self.wfile.write(data)
    def record(self,event):
        events.append(event);root.joinpath('events.json').write_text(json.dumps(events))
    def unauthorized(self):
        self.reply(401,{}, {'WWW-Authenticate':'Bearer resource_metadata="'+base+'/.well-known/oauth-protected-resource"'})
    def do_GET(self):
        route=urlparse(self.path);query=parse_qs(route.query)
        if route.path.startswith('/.well-known/oauth-protected-resource'):
            self.reply(200,dict(resource=base+'/mcp',authorization_servers=[base],scopes_supported=['mcp']))
        elif route.path.startswith('/.well-known/oauth-authorization-server') or route.path.startswith('/.well-known/openid-configuration'):
            self.reply(200,dict(issuer=base,authorization_endpoint=base+'/authorize',token_endpoint=base+'/token',registration_endpoint=base+'/register',response_types_supported=['code'],grant_types_supported=['authorization_code'],code_challenge_methods_supported=['S256'],token_endpoint_auth_methods_supported=['none'],scopes_supported=['mcp']))
        elif route.path=='/authorize':
            required=['client_id','redirect_uri','state','code_challenge']
            if not all(query.get(key) for key in required) or query['client_id'][0] not in clients: self.reply(400,{});return
            uri=query['redirect_uri'][0]
            if uri not in clients[query['client_id'][0]]['redirect_uris'] or query.get('code_challenge_method')!=['S256']: self.reply(400,{});return
            code=secrets.token_urlsafe(24);codes[code]={key:value[0] for key,value in query.items()}
            self.record(dict(event='authorization',pkce='S256'))
            self.send_response(302);self.send_header('Location',uri+('?' if '?' not in uri else '&')+urlencode(dict(code=code,state=query['state'][0])));self.send_header('Content-Length','0');self.end_headers()
        elif route.path=='/mcp':
            if self.headers.get('Authorization','').removeprefix('Bearer ') not in tokens: self.unauthorized()
            else: self.reply(405,{})
        else: self.reply(404,{})
    def do_POST(self):
        route=urlparse(self.path).path
        length=int(self.headers.get('Content-Length','0'));raw=self.rfile.read(length)
        if route=='/register':
            body=json.loads(raw);client=secrets.token_urlsafe(12);clients[client]=body
            self.record(dict(event='registration'))
            self.reply(201,dict(**body,client_id=client,client_id_issued_at=int(time.time())))
        elif route=='/token':
            query=parse_qs(raw.decode());code=query.get('code',[''])[0];receipt=codes.pop(code,None)
            challenge=base64.urlsafe_b64encode(hashlib.sha256(query.get('code_verifier',[''])[0].encode()).digest()).decode().rstrip('=')
            if not receipt or receipt['code_challenge']!=challenge or receipt['redirect_uri']!=query.get('redirect_uri',[''])[0]: self.reply(400,dict(error='invalid_grant'));return
            token=secrets.token_urlsafe(24);tokens.add(token);self.record(dict(event='token',pkce_verified=True))
            self.reply(200,dict(access_token=token,token_type='Bearer',expires_in=3600,scope='mcp'))
        elif route=='/mcp':
            if self.headers.get('Authorization','').removeprefix('Bearer ') not in tokens: self.unauthorized();return
            request=json.loads(raw);method=request.get('method');self.record(dict(event='mcp',method=method))
            if 'id' not in request: self.reply(202,{});return
            if method=='initialize': result=dict(protocolVersion='2025-06-18',capabilities=dict(tools={}),serverInfo=dict(name='owned-oauth-fixture',version='1'))
            elif method=='tools/list': result=dict(tools=[dict(name='oauth_fixture_tool',description='Disposable proof',inputSchema=dict(type='object',properties={}))])
            elif method=='ping': result={}
            else: self.reply(200,dict(jsonrpc='2.0',id=request['id'],error=dict(code=-32601,message='Unsupported method')));return
            self.reply(200,dict(jsonrpc='2.0',id=request['id'],result=result))
        else: self.reply(404,{})
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);base='http://127.0.0.1:'+str(server.server_port)
root.joinpath('server.json').write_text(json.dumps(dict(url=base,pid=os.getpid())))
server.serve_forever()
