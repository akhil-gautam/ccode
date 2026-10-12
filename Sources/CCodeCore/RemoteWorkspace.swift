import Foundation

// A remote path never enters Foundation file APIs. Python3 is a checked remote
// dependency; the helper is ephemeral stdin JSON, with no remote installation.
public struct RemoteWorkspace: Sendable {
    public let root: String
    public let transport: SSHTransport
    public init(root: String, transport: SSHTransport) throws {
        _ = try WorkspaceLocation(environment: .ssh(transport.configuration), path: root)
        self.root = root; self.transport = transport
    }
    public func resolve(_ path: String, directory: Bool = false) async throws -> String {
        try await operation(directory ? "directory" : "resolve", ["path": .string(path)])["path"].string
    }
    public func metadata(_ path: String) async throws -> (path: String, isDirectory: Bool) {
        let response = try await operation("metadata", ["path": .string(path)])
        return (response["path"].string, response["isDirectory"].bool)
    }
    public func read(_ path: String, line: Int? = nil, limit: Int? = nil) async throws -> String {
        guard (line ?? 1) >= 1, (limit ?? 0) >= 0 else { throw ACPError.workspace("Invalid remote line range.") }
        var args: JSONValue = ["path": .string(path)]
        if let line { args["line"] = .number(Double(line)) }; if let limit { args["limit"] = .number(Double(limit)) }
        return try await operation("read", args)["text"].string
    }
    public func write(_ path: String, content: String, expecting original: String? = nil) async throws {
        guard content.utf8.count <= 1024 * 1024, (original?.utf8.count ?? 0) <= 1024 * 1024 else { throw ACPError.workspace("Remote editor text exceeds 1 MB.") }
        var args: JSONValue = ["path": .string(path), "text": .string(content)]
        if let original { args["expected"] = .string(original) }
        _ = try await operation("write", args, mutation: true)
    }
    public func files(limit: Int = 3000) async throws -> [String] {
        guard limit > 0, limit <= 3000 else { throw ACPError.workspace("Remote file catalog limit must be 1–3000.") }
        return try await operation("files", ["limit": .number(Double(limit))])["files"].array.map(\.string)
    }
    public func upload(_ bytes: Data, to path: String) async throws {
        guard bytes.count <= Self.transferLimit else { throw ACPError.workspace("Remote transfer exceeds 3 MB.") }
        _ = try await operation("upload", ["path": .string(path), "data": .string(bytes.base64EncodedString())], mutation: true)
    }
    public func download(_ path: String) async throws -> Data {
        let result = try await operation("download", ["path": .string(path)])
        guard let bytes = Data(base64Encoded: result["data"].string), bytes.count <= Self.transferLimit else { throw ACPError.protocolViolation("Invalid or oversized remote transfer response.") }
        return bytes
    }
    public func run(executable: String, arguments: [String] = [], directory: String? = nil, mutation: Bool = false, acceptDiff: Bool = false) async throws -> String {
        let target = directory ?? root
        let scoped = try await operation("directory", ["path": .string(target)])["path"].string
        guard !scoped.isEmpty else { throw ACPError.protocolViolation("Remote directory identity is missing.") }
        return try await transport.run(executable: executable, arguments: arguments, directory: scoped, mutation: mutation, acceptDiff: acceptDiff)
    }
    // Git argv stays literal (including filenames/ref names). The caller owns
    // mutation receipts; remote transport never repeats a failed invocation.
    public func git(_ arguments: [String], directory: String? = nil, mutation: Bool = false, acceptDiff: Bool = false) async throws -> String {
        try await run(executable: "git", arguments: ["--literal-pathspecs", "--no-optional-locks", "-c", "diff.autoRefreshIndex=false"] + arguments, directory: directory, mutation: mutation, acceptDiff: acceptDiff)
    }
    private static let transferLimit = 3 * 1024 * 1024 - 1024
    private func operation(_ name: String, _ arguments: JSONValue, mutation: Bool = false) async throws -> JSONValue {
        try Task.checkCancellation()
        var request = arguments; request["operation"] = .string(name); request["root"] = .string(root)
        let data = try JSONEncoder().encode(request)
        let output = try await transport.run(executable: "python3", arguments: ["-c", Self.helper], directory: root, input: data, mutation: mutation)
        let response: JSONValue
        do { response = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)) }
        catch { throw SSHTransportError(kind: mutation ? .uncertainMutation : .operation, detail: "Remote file helper returned an invalid response.") }
        guard response["version"].exactInteger == 1, response["operation"].string == name, response["root"].string == root else {
            throw SSHTransportError(kind: mutation ? .uncertainMutation : .operation, detail: "Remote file helper response belongs to a different operation or workspace.")
        }
        if let error = response["error"].optionalString { throw SSHTransportError(kind: response["uncertain"].bool ? .uncertainMutation : .operation, detail: error) }
        guard response["ok"].bool else { throw SSHTransportError(kind: mutation ? .uncertainMutation : .operation, detail: "Remote operation was not acknowledged.") }
        return response
    }

    private static let helper = #"""
import os,sys,json,base64,uuid,stat
MAX_TEXT=1024*1024
MAX_TRANSFER=3*1024*1024-1024
q=json.loads(sys.stdin.buffer.read(5*1024*1024+1))
op=q['operation']; root=q['root']; result={'version':1,'operation':op,'root':root}
mutating=False
try:
    if not isinstance(root,str) or not root.startswith('/') or '\x00' in root: raise ValueError('Invalid remote root')
    canonical=os.path.realpath(root)
    rootfd=os.open(canonical,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    def scoped(path):
        if not isinstance(path,str) or not path.startswith('/') or '\x00' in path: raise ValueError('Remote paths must be absolute')
        full=os.path.realpath(path)
        if os.path.commonpath([canonical,full])!=canonical: raise ValueError('Path is outside the remote workspace')
        return full
    def parent(path,create=False):
        global mutating
        full=scoped(path)
        relative=os.path.relpath(full,canonical)
        if relative=='.': raise ValueError('Expected a file, not the remote workspace root')
        parts=relative.split(os.sep); fd=os.dup(rootfd)
        try:
            for part in parts[:-1]:
                if create:
                    try: os.mkdir(part,dir_fd=fd); mutating=True
                    except FileExistsError: pass
                child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
                os.close(fd); fd=child
            return fd,parts[-1]
        except: os.close(fd); raise
    def read_bytes(fd,name,limit):
        f=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=fd)
        with os.fdopen(f,'rb') as stream:
            if not stat.S_ISREG(os.fstat(f).st_mode): raise ValueError('Only regular remote files are supported')
            data=stream.read(limit+1)
            if len(data)>limit: raise ValueError('Remote file exceeds its byte limit')
            return data
    if op in ('read','download'):
        fd,name=parent(q['path'])
        try: data=read_bytes(fd,name,MAX_TEXT if op=='read' else MAX_TRANSFER)
        finally: os.close(fd)
        if op=='download': result['data']=base64.b64encode(data).decode('ascii')
        else:
            text=data.decode('utf-8')
            if 'line' in q or 'limit' in q:
                line=q.get('line',1); limit=q.get('limit')
                if type(line)!=int or line<1 or (limit is not None and (type(limit)!=int or limit<0)): raise ValueError('Invalid line range')
                lines=text.split('\n'); text='\n'.join(lines[line-1:] if limit is None else lines[line-1:line-1+limit])
            result['text']=text
    elif op in ('write','upload'):
        data=q['text'].encode('utf-8') if op=='write' else base64.b64decode(q['data'],validate=True)
        if len(data)>(MAX_TEXT if op=='write' else MAX_TRANSFER): raise ValueError('Remote input exceeds its byte limit')
        if 'expected' in q and not isinstance(q['expected'],str): raise ValueError('Invalid original text')
        fd,name=parent(q['path'],op=='upload' or 'expected' not in q); temp='.ccode-write-'+uuid.uuid4().hex
        try:
            original=read_bytes(fd,name,MAX_TEXT) if 'expected' in q else None
            if original is not None and original.decode('utf-8')!=q['expected']: raise ValueError('File changed remotely. Reload before saving.')
            if op=='upload':
                f=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=fd)
                mutating=True
            else:
                f=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=fd)
                try: os.fchmod(f,stat.S_IMODE(os.stat(name,dir_fd=fd,follow_symlinks=False).st_mode))
                except FileNotFoundError: pass
            with os.fdopen(f,'wb') as stream: stream.write(data); stream.flush(); os.fsync(stream.fileno())
            if op=='write':
                if original is not None and read_bytes(fd,name,MAX_TEXT)!=original: raise ValueError('File changed remotely while saving. Reload before saving.')
                mutating=True; os.replace(temp,name,src_dir_fd=fd,dst_dir_fd=fd)
        finally:
            try: os.unlink(temp,dir_fd=fd)
            except FileNotFoundError: pass
            os.close(fd)
    elif op=='files':
        limit=q['limit']
        if type(limit)!=int or not 1<=limit<=3000: raise ValueError('Invalid catalog limit')
        ignored={'.git','.build','node_modules','.swiftpm','vendor','dist'}; paths=[]
        for folder,dirs,files in os.walk(canonical,followlinks=False):
            dirs[:]=sorted(d for d in dirs if d not in ignored and not os.path.islink(os.path.join(folder,d)))
            for name in sorted(files):
                full=os.path.join(folder,name)
                if os.path.islink(full) or not os.path.isfile(full): continue
                paths.append(os.path.relpath(full,canonical))
                if len(paths)>=limit: break
            if len(paths)>=limit: break
        result['files']=paths
    elif op in ('resolve','metadata'):
        full=scoped(q['path'])
        fd,name=parent(full) if full!=canonical else (os.dup(rootfd),'.')
        try:
            info=os.stat(name,dir_fd=fd,follow_symlinks=False)
            if op=='metadata' and not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)): raise ValueError('Select a regular file or directory')
            result['path']=full; result['isDirectory']=stat.S_ISDIR(info.st_mode)
        except FileNotFoundError:
            if op=='metadata': raise
            result['path']=full
        finally: os.close(fd)
    elif op=='directory':
        full=scoped(q['path'])
        if not os.path.isdir(full): raise ValueError('Remote directory does not exist')
        result['path']=full
    else: raise ValueError('Unknown remote file operation')
    result['ok']=True
except Exception as error:
    result['error']=str(error)[:2048]; result['uncertain']=mutating
print(json.dumps(result,ensure_ascii=False))
"""#
}
