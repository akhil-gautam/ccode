#!/usr/bin/env python3
"""Run one app-scoped iOS input operation via Apple's XCTest tooling."""
import base64, fcntl, hashlib, json, os, pathlib, plistlib, shutil, subprocess, sys, tempfile, uuid

def command(argv, log):
    with log.open('wb') as output:
        result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT, check=False)
    if result.returncode:
        with log.open('rb') as output:
            output.seek(max(0, log.stat().st_size-3500))
            detail=output.read().decode('utf8','replace')
        raise RuntimeError('XCTest simulator operation failed; no automatic input retry. '+detail)

def main():
    cache=pathlib.Path(sys.argv[1]).resolve(); cache.mkdir(parents=True,exist_ok=True)
    source=pathlib.Path(__file__).resolve().parent/'SimulatorControl'
    identity=hashlib.sha256(b''.join(p.read_bytes() for p in sorted(source.rglob('*')) if p.is_file())).hexdigest()
    developer=subprocess.check_output(['/usr/bin/xcode-select','-p'],text=True).strip()
    version=subprocess.check_output(['/usr/bin/xcodebuild','-version'])
    build=cache/('helper-'+hashlib.sha256(identity.encode()+developer.encode()+version).hexdigest()[:16])
    build.mkdir(parents=True,exist_ok=True)
    with (build/'build.lock').open('w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        products=build/'Build/Products'
        if not list(products.glob('*.xctestrun')):
            command(['/usr/bin/xcodebuild','-project',str(source/'Control.xcodeproj'),'-scheme','Control','-destination','generic/platform=iOS Simulator','-derivedDataPath',str(build),'CODE_SIGNING_ALLOWED=NO','build-for-testing'],build/'build.log')
    if sys.argv[2]=='--build-only':
        print(str(build));return
    device=str(uuid.UUID(sys.argv[2])).upper()
    request=json.loads(sys.argv[3]);request['nonce']=str(uuid.uuid4())
    payload=base64.b64encode(json.dumps(request,ensure_ascii=False).encode()).decode()
    original=next(products.glob('*.xctestrun'))
    def expand(value):
        if isinstance(value,str): return value.replace('__TESTROOT__',str(products))
        if isinstance(value,list): return [expand(x) for x in value]
        if isinstance(value,dict): return {k:expand(v) for k,v in value.items()}
        return value
    spec=expand(plistlib.loads(original.read_bytes()))
    targets=[target for cfg in spec.get('TestConfigurations',[]) for target in cfg.get('TestTargets',[])]
    if not targets: targets=[v for k,v in spec.items() if isinstance(v,dict) and 'TestBundlePath' in v]
    if not targets: raise RuntimeError('Xcode emitted an unsupported xctestrun layout.')
    for target in targets:
        target.setdefault('EnvironmentVariables',{})['CCODE_SIMULATOR_ACTION']=payload
    job=pathlib.Path(tempfile.mkdtemp(prefix='operation-',dir=cache))
    try:
        run=job/'Control.xctestrun';run.write_bytes(plistlib.dumps(spec))
        command(['/usr/bin/xcodebuild','test-without-building','-xctestrun',str(run),'-destination','platform=iOS Simulator,id='+device,'-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1','-resultBundlePath',str(job/'result.xcresult')],job/'test.log')
        command(['/usr/bin/xcrun','xcresulttool','export','attachments','--path',str(job/'result.xcresult'),'--output-path',str(job/'attachments')],job/'export.log')
        for file in (job/'attachments').iterdir():
            if file.is_file() and file.stat().st_size<1024*1024:
                try: result=json.loads(file.read_bytes())
                except (ValueError,UnicodeDecodeError): continue
                if isinstance(result,dict) and result.get('ccode_result') is True and result.get('nonce')==request['nonce']:
                    print('CCODE_SIM_RESULT='+base64.b64encode(json.dumps(result,ensure_ascii=False).encode()).decode());return
        raise RuntimeError('XCTest finished without a matching ccode result attachment.')
    finally: shutil.rmtree(job)

if __name__=='__main__':
    try: main()
    except Exception as error:
        print(str(error),file=sys.stderr);sys.exit(1)
