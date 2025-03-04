{.warning: "gonet is completly untested. Please remove this line, use at your own risk and tell me if it works".}
## This is a simple wrapper the socket defined std/net, with our own buffer component and added async features
## So all operations are not guaranteed to has been asyncified

import ./[eventdispatcher, gotaskscomplete]
import ./private/buffer
import std/[nativesockets, net, options, oserrors]

export net


type
    GoSocket* = ref object
        pollFd: PollFd
        socket: Socket
        buffer: Buffer
        closed: bool


proc newGoSocket*(domain: Domain = AF_INET; sockType: SockType = SOCK_STREAM;
                    protocol: Protocol = IPPROTO_TCP; buffered = true;
                    inheritable = defined(nimInheritHandles)): GoSocket =
    let socket = newSocket(domain, sockType, protocol, false, inheritable)
    GoSocket(
        socket: socket,
        pollFd: registerHandle(socket.getFd(), {Event.Read, Event.Write}),
        buffer: if buffered: newBuffer() else: nil,
    )


when defined(ssl):
    proc sslHandle*(gosocket: GoSocke): SslPtr =
        gosocket.socket.sslHandle

    proc wrapSocket*(ctx: SslContext, gosocket: GoSocket) =
        wrapSocket(ctx, gosocket.socket)


    proc wrapConnectedSocket*(ctx: SslContext, gosocket: GoSocke,
                            handshake: SslHandshakeType,
                            hostname: string = "") =
        wrapConnectedSocket(ctx, gosocket.socket, handshake, hostname)

    proc getPeerCertificates*(gosocket: GoSocket): seq[Certificate] =
        gosocket.socket.getPeerCertificates()

proc accept*(gosocket: GoSocket, flags = {SafeDisconn};
            inheritable = defined(nimInheritHandles), canceller: GoTaskUntyped = nil): GoSocket =
    if not suspendUntilRead(gosocket.pollFd, canceller, true):
        raise newException(ValueError, "Timeout occured")
    var client: Socket
    accept(gosocket.socket, client, flags, inheritable)
    return GoSocket(
        socket: client,
        pollFd: registerHandle(client.getFd(), {Event.Read, Event.Write}),
        buffer: if gosocket.buffer != nil: newBuffer() else: nil,
    )

proc acceptAddr*(gosocket: GoSocket; flags = {SafeDisconn};
                    inheritable = defined(nimInheritHandles), canceller: GoTaskUntyped = nil): tuple[address: string, client: GoSocket] =
    if not suspendUntilRead(gosocket.pollFd, canceller, true):
        raise newException(ValueError, "Timeout occured")
    var client: Socket
    var address = ""
    acceptAddr(gosocket.socket, client, address, flags, inheritable)
    return (
        address,
        GoSocket(socket: client, pollFd: registerHandle(client.getFd(), {Event.Read, Event.Write}))
    )

proc bindAddr*(gosocket: GoSocket; port = Port(0); address = "") =
    gosocket.socket.bindAddr(port, address)

proc bindUnix*(gosocket: GoSocket; path: string) =
    gosocket.socket.bindUnix(path)

proc close*(gosocket: GoSocket) =
    gosocket.pollFd.unregister()
    gosocket.socket.close()
    gosocket.closed = true

proc connect*(gosocket: GoSocket; address: string; port: Port, canceller: GoTaskUntyped = nil) =
    if not suspendUntilRead(gosocket.pollFd, canceller, true):
        raise newException(ValueError, "Timeout occured")
    connect(gosocket.socket, address, port)

proc connectUnix*(gosocket: GoSocket; path: string, canceller: GoTaskUntyped = nil) =
    if not suspendUntilRead(gosocket.pollFd, canceller, true):
        raise newException(ValueError, "Timeout occured")
    connectUnix(gosocket.socket, path)

proc dial*(address: string; port: Port; protocol = IPPROTO_TCP; buffered = true): GoSocket =
    # https://github.com/nim-lang/Nim/blob/version-2-0/lib/pure/net.nim#L1989
    let sockType = protocol.toSockType()

    let aiList = getAddrInfo(address, port, AF_UNSPEC, sockType, protocol)

    var fdPerDomain: array[low(Domain).ord..high(Domain).ord, SocketHandle]
    for i in low(fdPerDomain)..high(fdPerDomain):
        fdPerDomain[i] = osInvalidSocket
    template closeUnusedFds(domainToKeep = -1) {.dirty.} =
        for i, fd in fdPerDomain:
            if fd != osInvalidSocket and i != domainToKeep:
                fd.close()

    var success = false
    var lastError: OSErrorCode
    var it = aiList
    var domain: Domain
    var lastFd: SocketHandle
    var pollFd: PollFd
    while it != nil:
        let domainOpt = it.ai_family.toKnownDomain()
        if domainOpt.isNone:
            it = it.ai_next
            continue
        domain = domainOpt.unsafeGet()
        lastFd = fdPerDomain[ord(domain)]
        if lastFd == osInvalidSocket:
            lastFd = createNativeSocket(domain, sockType, protocol)
            if lastFd == osInvalidSocket:
                # we always raise if socket creation failed, because it means a
                # network system problem (e.g. not enough FDs), and not an unreachable
                # address.
                let err = osLastError()
                freeAddrInfo(aiList)
                closeUnusedFds()
                raiseOSError(err)
            fdPerDomain[ord(domain)] = lastFd
        pollFd = registerHandle(lastFd, {Event.Read, Event.Write})
        discard suspendUntilRead(pollFd, nil, true)
        if connect(lastFd, it.ai_addr, it.ai_addrlen.SockLen) == 0'i32:
            success = true
            break
        pollFd.unregister()
        lastError = osLastError()
        it = it.ai_next
    freeAddrInfo(aiList)
    closeUnusedFds(ord(domain))

    if success:
        result = GoSocket(
            socket: newSocket(lastFd, domain, sockType, protocol, buffered),
            pollFd: pollFd)
    elif lastError != 0.OSErrorCode:
        raiseOSError(lastError)
    else:
        raise newException(IOError, "Couldn't resolve address: " & address)

proc getFd*(gosocket: GoSocket): SocketHandle =
    getFd(gosocket.socket)

proc getLocalAddr*(gosocket: GoSocket): (string, Port) =
    getLocalAddr(gosocket.socket)

proc getPeerAddr*(gosocket: GoSocket): (string, Port) =
    getPeerAddr(gosocket.socket)

proc getSelectorFileHandle*(gosocket: GoSocket): PollFd =
    gosocket.pollFd

proc getSockOpt*(gosocket: GoSocket; opt: SOBool; level = SOL_SOCKET): bool =
    getSockOpt(gosocket.socket, opt, level)

proc hasDataBuffered*(gosocket: GoSocket): bool =
    gosocket.buffer != nil and not gosocket.buffer.empty()

proc isClosed*(gosocket: GoSocket): bool =
    gosocket.closed

proc isSsl*(gosocket: GoSocket): bool =
    isSsl(gosocket.socket)

proc listen*(gosocket: GoSocket; backlog = SOMAXCONN) =
    listen(gosocket.socket, backlog)

proc recvBufferImpl(s: GoSocket; data: pointer, size: int, canceller: GoTaskUntyped = nil): int =
    ## Bypass the buffer
    if not suspendUntilRead(s.pollFd, canceller, true):
        return -1
    assert(not s.closed, "Cannot `recv` on a closed socket")
    let bytesCount = recv(s.socket, data, size)
    return bytesCount

proc recvImpl(s: GoSocket, size: Positive, canceller: GoTaskUntyped = nil): string =
    result = newStringOfCap(size)
    result.setLen(1)
    let bytesCount = s.recvBufferImpl(addr(result[0]), size, canceller)
    if bytesCount <= 0:
        return ""
    result.setLen(bytesCount)

proc recv*(s: GoSocket; size: int, canceller: GoTaskUntyped = nil): string =
    if s.buffer != nil:
        if s.buffer.len() < size:
            let data = s.recvImpl(max(size, DefaultBufferSize), canceller)
            if data != "":
                s.buffer.write(data)
        return s.buffer.read(size)
    else:
        return s.recvImpl(size, canceller)

proc recvFrom*[T: string | IpAddress](s: GoSocket; data: var string;
            length: int; address: var T;
            port: var Port; flags = 0'i32, canceller: GoTaskUntyped = nil): int =
    ## Always unbuffered, ignore if data is already in buffer
    ## Can raise exception
    if not suspendUntilRead(s.pollFd, canceller, true):
        return -1
    return recvFrom(s.socket, data, length, address, port, flags)

proc recvLine*(s: GoSocket; keepNewLine = false,
              canceller: GoTaskUntyped = nil): string =
    if s.buffer != nil:
        while true:
            let line = s.buffer.readLine(keepNewLine)
            if line.len() != 0:
                return line
            let data = s.recvImpl(DefaultBufferSize, canceller)
            if data.len() == 0:
                return s.buffer.readAll()
            s.buffer.write(data)
    else:
        const BufSizeLine = 100
        var line = newString(BufSizeLine)
        var length = 0
        while true:
            var c: char
            let readCount = s.recvBufferImpl(addr(c), 1, canceller)
            if readCount <= 0:
                line.setLen(length)
                return line
            if c == '\c':
                discard s.recvBufferImpl(addr(c), 1, canceller)
                if keepNewLine:
                    line[length] = '\n'
                    line.setLen(length + 1)
                else:
                    line.setLen(length)
                return line
            if c == '\L':
                if keepNewLine:
                    line[length] = '\n'
                    line.setLen(length + 1)
                else:
                    line.setLen(length)
                return line
            if length == line.len():
                line.setLen(line.len() * 2)
            line[length] = c
            length += 1

proc sendImpl(s: GoSocket; data: string, canceller: GoTaskUntyped = nil): int =
    ## Bypass the buffer
    if data.len() == 0:
        return 0
    if not suspendUntilWrite(s.pollFd, canceller, true):
        return -1
    let bytesCount = send(s.socket, addr(data[0]), data.len())
    return bytesCount

proc send*(s: GoSocket; data: string, canceller: GoTaskUntyped = nil): int =
    ## Send is unbuffered
    return sendImpl(s, data, canceller)

proc sendTo*(s: GoSocket; address: IpAddress; port: Port; data: string,
            flags = 0'i32, canceller: GoTaskUntyped = nil): int {.discardable.} =
    ## Always unbuffered
    ## Can raise exception
    if data.len() == 0:
        return 0
    if not suspendUntilWrite(s.pollFd, canceller, true):
        return -1
    return sendTo(s.socket, address, port, data, flags)

proc setSockOpt*(gosocket: GoSocket; opt: SOBool; value: bool;
                level = SOL_SOCKET) =
    setSockOpt(gosocket.socket, opt, value, level)
