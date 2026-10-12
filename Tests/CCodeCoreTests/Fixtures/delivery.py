import json
import re
from pathlib import Path
import sys

# Controlled turn boundaries; tests exercise the actual stdio/AppStore path.
active = None
active_review_id = None
calls = []
audit = next((Path(flag.split('=', 1)[1]) for flag in sys.argv if flag.startswith('--audit-log=')), None)
if audit:
    audit.write_text(json.dumps(calls))
steers = []
delayed_steer = None
user_chunks = 0
deferred_load = None
setting_calls = []
timeline = []
delayed_setting = None
authenticated = False
config = [
    dict(id='model', name='Model', category='model', type='select', currentValue='large' if '--initial-large' in sys.argv else 'small', options=[dict(value='small', name='Small'), dict(value='large', name='Large')]),
    dict(id='effort', name='Effort', category='thought_level', type='select', currentValue='normal', options=[dict(value='normal', name='Normal'), dict(value='high', name='High')]),
    dict(id='fast', name='Fast mode', type='boolean', currentValue=False),
]
legacy = dict(modelId='small', modeId='default')

def session_state():
    if '--legacy-settings' in sys.argv:
        return dict(modes=dict(currentModeId=legacy['modeId'], availableModes=[dict(id='default', name='Manual'), dict(id='plan', name='Plan')]), models=dict(currentModelId=legacy['modelId'], availableModels=[dict(modelId='small', name='Small'), dict(modelId='large', name='Large')]))
    return dict(configOptions=config) if '--config-workflow' in sys.argv else {}

def apply_setting(method, params):
    if method == 'session/set_config_option':
        for option in config:
            if option['id'] == params['configId']:
                option['currentValue'] = params['value']
        if params['configId'] == 'model' and params['value'] == 'small' and '--model-hides-effort' in sys.argv:
            config[1]['options'] = [dict(value='normal', name='Normal')]
            config[1]['currentValue'] = 'normal'
        return dict(configOptions=config)
    legacy['modelId' if method == 'session/set_model' else 'modeId'] = params['modelId' if method == 'session/set_model' else 'modeId']
    return {}

def send(value):
    value['jsonrpc'] = '2.0'
    print(json.dumps(value), flush=True)

def finish(reason='end_turn'):
    global active, active_review_id
    if active is not None:
        if active_review_id:
            report = dict(reviewId=active_review_id, findings=[dict(path='answer.py', startLine=2, endLine=2, side='new', priority=1, title='Addition subtracts', body='Return a + b so add(2, 3) is 5.')])
            if '--file-review-report' in sys.argv:
                report['findings'][0].update(startLine=None, endLine=None, side=None)
            if '--no-findings' in sys.argv:
                report['findings'] = []
            if '--foreign-review' in sys.argv:
                report['reviewId'] = '00000000-0000-0000-0000-000000000001'
            text = 'Addition has a concrete bug.\n```ccode-review\n' + json.dumps(report) + '\n```'
            if '--plain-review' in sys.argv:
                text = 'Please inspect answer.py line 2. This is ordinary prose.'
            # Split inside the JSON to verify streaming aggregation before parse.
            chunks = [text[:len(text)//2], text[len(text)//2:]]
        else:
            chunks = ['Completed actual turn']
        for chunk in chunks:
            send(dict(method='session/update', params=dict(sessionId='delivery-session', update=dict(sessionUpdate='agent_message_chunk', messageId='answer-' + str(active), content=dict(type='text', text=chunk)))))
        send(dict(id=active, result=dict(stopReason=reason)))
        active = None
        active_review_id = None

for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    ident = message.get('id')
    params = message.get('params', {})
    if method == 'initialize':
        send(dict(id=ident, result=dict(protocolVersion=1, agentInfo=dict(name='@agentclientprotocol/claude-agent-acp', version='0.84.0'), agentCapabilities=dict(loadSession=True, promptCapabilities=dict(image=True)), authMethods=[dict(id='fixture-login', name='Fixture login', type='agent')] if '--auth-setup' in sys.argv else [], _meta=dict(steering=dict(supported='--no-steering' not in sys.argv)))))
    elif method == 'authenticate':
        authenticated = True
        send(dict(id=ident, result={}))
    elif method in ('session/new', 'session/load', 'session/resume'):
        if method != 'session/new' and '--load-hides-effort' in sys.argv:
            config[1]['options'] = [dict(value='normal', name='Normal')]
            config[1]['currentValue'] = 'normal'
        if '--auth-setup' in sys.argv and not authenticated:
            send(dict(id=ident, error=dict(code=-32000, message='Authentication required')))
            continue
        if method == 'session/load' and '--question-load' in sys.argv:
            deferred_load = ident
            send(dict(id='setup-question', method='elicitation/create', params=dict(requestId=ident, mode='form', message='Confirm reconnect', requestedSchema=dict(type='object', properties=dict(ready=dict(type='boolean')), required=['ready']))))
        else:
            send(dict(id=ident, result=dict(sessionId='delivery-session', **session_state())))
            if '--commands' in sys.argv:
                send(dict(method='session/update', params=dict(sessionId='delivery-session', update=dict(sessionUpdate='available_commands_update', availableCommands=[dict(name='compact', description='Summarize context'), dict(name='clear', description='Clear context'), dict(name='local-skill', description='Run the project skill', input=dict(hint='Task arguments'))]))))
    elif method == 'session/prompt':
        calls.append(params)
        if audit:
            audit.write_text(json.dumps(calls))
        if active is not None:
            send(dict(id=ident, error=dict(code=-32603, message='Concurrent prompt is forbidden')))
            continue
        active = ident
        timeline.append(dict(kind='prompt', params=params, config={v['id']: v['currentValue'] for v in config}, legacy=dict(legacy)))
        text = next((b.get('text', '') for b in params['prompt'] if b.get('type') == 'text'), '')
        review_match = re.search(r'^CCODE_REVIEW_ID: ([0-9A-Fa-f-]{36})$', text, re.MULTILINE) if '--review-report' in sys.argv else None
        active_review_id = review_match.group(1) if review_match else None
        failure_kind = next((flag.split('=', 1)[1] for flag in sys.argv if flag.startswith('--fail-prompt=')), None)
        if failure_kind:
            send(dict(id=ident, error=dict(code=-32603, message='Exact provider explanation', data=dict(errorKind=failure_kind))))
            active = None
            continue
        if not text.startswith('hold') and not (active_review_id and '--hold-review' in sys.argv):
            finish()
    elif method == '_session/steering':
        steers.append(params)
        if '--lose-steering' in sys.argv:
            sys.exit(0)
        if '--reject-steering' in sys.argv:
            send(dict(id=ident, error=dict(code=-32601, message='Not supported')))
        elif '--idle-race' in sys.argv or active is None:
            finish()
            send(dict(id=ident, result=dict(outcome='promptRequired', reason='noRunningTurn')))
        elif '--delay-steering' in sys.argv:
            delayed_steer = ident
        else:
            send(dict(id=ident, result=dict(outcome='injected')))
    elif method == 'session/cancel':
        finish('cancelled')
    elif method in ('session/set_config_option', 'session/set_model', 'session/set_mode'):
        setting_calls.append(dict(method=method, params=params))
        timeline.append(dict(kind='setting', method=method, params=params))
        if active is not None:
            send(dict(id=ident, error=dict(code=-32000, message='Cannot change configuration during a turn')))
        elif '--reject-config' in sys.argv:
            send(dict(id=ident, error=dict(code=-32000, message='Managed policy forbids this setting')))
        elif '--delay-config' in sys.argv:
            delayed_setting = (ident, method, params)
        elif '--lose-config' in sys.argv:
            apply_setting(method, params)
            sys.exit(0)
        else:
            send(dict(id=ident, result=apply_setting(method, params)))
    elif method == 'fixture/state':
        send(dict(id=ident, result=dict(prompts=calls, steers=steers, active=active, settingCalls=setting_calls, timeline=timeline)))
    elif method == 'fixture/ack-config':
        if delayed_setting is not None:
            saved_id, saved_method, saved_params = delayed_setting
            result = apply_setting(saved_method, saved_params)
            if 'configOptions' in result:
                send(dict(method='session/update', params=dict(sessionId='delivery-session', update=dict(sessionUpdate='config_option_update', **result))))
            send(dict(id=saved_id, result=result))
            delayed_setting = None
        send(dict(id=ident, result={}))
    elif method == 'fixture/finish':
        finish()
        send(dict(id=ident, result={}))
    elif method == 'fixture/ack-steering':
        if delayed_steer is not None:
            send(dict(id=delayed_steer, result=dict(outcome='injected')))
            delayed_steer = None
        send(dict(id=ident, result={}))
    elif method == 'fixture/user-update':
        chunk = 'Actual provider-side ' if user_chunks == 0 else 'follow-up'
        user_chunks += 1
        send(dict(method='session/update', params=dict(sessionId='delivery-session', update=dict(sessionUpdate='user_message_chunk', messageId='external-user-1', content=dict(type='text', text=chunk)))))
        send(dict(id=ident, result={}))
    elif method is None and ident == 'setup-question' and deferred_load is not None:
        send(dict(id=deferred_load, result=dict(sessionId='delivery-session')))
        deferred_load = None
    elif ident is not None:
        send(dict(id=ident, error=dict(code=-32601, message='Unknown method')))
