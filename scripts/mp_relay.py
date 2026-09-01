"""mp_relay.py -- LAN multiplayer relay for the Powder RPG (ADR-018/ADR-019).

Why this exists: R.net.listen (the engine's only Lua TCP-accept binding) is hardcoded to
INADDR_LOOPBACK and is a one-shot HTTP request/response listener (see LuaSocketNet.cpp) -- it
can never accept a real LAN peer. Outbound socket.tcp() from Lua is NOT loopback-restricted, so
every game instance (host and guest) connects OUT to this relay, which is the only process that
actually binds a LAN-reachable port. Host-authoritative: this process never simulates anything,
it is a dumb byte pipe between exactly two sockets, gated by a shared session code.

Wire format (matches netlink.lua's Link:send / parseFrames exactly):
    "<byte-length>\n<json-body>"  repeated, no trailing separator after the body.

Protocol:
    - First connection's first frame must be {"kind":"hello","code":<str>,"role":"host"}.
      That code becomes this session's password.
    - Second connection's first frame must be {"kind":"hello","code":<str>,"role":"guest"}
      with a matching code. Anything else (wrong code, wrong role, wrong shape, third
      connection, malformed frame) gets {"kind":"reject","why":...} and is dropped -- never
      registered, never forwarded to or from.
    - Once both sides are authed: raw frame bytes are piped host<->guest, unmodified. This
      relay never parses pos/chat frames beyond the byte-length prefix; it doesn't need to.
    - If the host disconnects, the guest gets {"kind":"host_left"} then is closed. If the
      guest disconnects, the host just keeps running (can accept a new guest hello next).

ponytail: exactly 2 peers, no N-player fan-out -- more than 2 concurrent players is an
explicit non-goal (ADR-019 SS6). Add real multi-guest fan-out only if that changes.
"""
import json
import os
import socket
import sys
import threading
import time

DEFAULT_PORT = 9899
MAX_FRAME = 1024 * 256
HELLO_TIMEOUT = 10.0
PID_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mp_relay.pid")


def log(msg):
    sys.stderr.write("[mp_relay] %s\n" % msg)
    sys.stderr.flush()


def read_frame(sock, timeout=None):
    """Read one '<len>\\n<json>' frame. Returns dict, or None on EOF/error/timeout."""
    if timeout is not None:
        sock.settimeout(timeout)
    buf = b""
    try:
        while b"\n" not in buf:
            chunk = sock.recv(16)
            if not chunk:
                return None
            buf += chunk
            if len(buf) > 32:  # length prefix is never this long
                return None
        length_str, rest = buf.split(b"\n", 1)
        n = int(length_str)
        if n <= 0 or n > MAX_FRAME:
            return None
        body = rest
        while len(body) < n:
            chunk = sock.recv(min(4096, n - len(body)))
            if not chunk:
                return None
            body += chunk
        return json.loads(body[:n].decode("utf-8"))
    except (socket.timeout, ValueError, UnicodeDecodeError, json.JSONDecodeError, OSError):
        return None
    finally:
        if timeout is not None:
            try:
                sock.settimeout(None)
            except OSError:
                pass


def send_frame(sock, obj):
    body = json.dumps(obj).encode("utf-8")
    try:
        sock.sendall(str(len(body)).encode("ascii") + b"\n" + body)
        return True
    except OSError:
        return False


def pipe(src, dst, other_name, on_src_gone):
    """Forward raw length-prefixed frames from src to dst until src closes or errors."""
    try:
        while True:
            frame = read_frame(src)
            if frame is None:
                break
            if not send_frame(dst, frame):
                break
    finally:
        on_src_gone(other_name)


class Session:
    def __init__(self):
        self.lock = threading.Lock()
        self.code = None
        self.host_sock = None
        self.guest_sock = None
        self.closed = False

    def try_register(self, sock, hello):
        with self.lock:
            if not isinstance(hello, dict) or hello.get("kind") != "hello":
                return False, "bad hello"
            role = hello.get("role")
            code = hello.get("code")
            if not isinstance(code, str) or not code:
                return False, "bad code"
            if role == "host":
                if self.host_sock is not None:
                    return False, "already hosting"
                self.code = code
                self.host_sock = sock
                return True, None
            elif role == "guest":
                if self.host_sock is None:
                    return False, "no host"
                if self.guest_sock is not None:
                    return False, "already full"
                if code != self.code:
                    return False, "bad code"
                self.guest_sock = sock
                return True, None
            return False, "bad role"

    def on_gone(self, who):
        with self.lock:
            if who == "host" and self.guest_sock is not None:
                send_frame(self.guest_sock, {"kind": "host_left"})
                try:
                    self.guest_sock.close()
                except OSError:
                    pass
                self.guest_sock = None
                self.host_sock = None
            elif who == "guest":
                self.guest_sock = None


def handle_conn(sock, addr, session):
    hello = read_frame(sock, timeout=HELLO_TIMEOUT)
    ok, why = session.try_register(sock, hello)
    if not ok:
        send_frame(sock, {"kind": "reject", "why": why})
        try:
            sock.close()
        except OSError:
            pass
        log("rejected %s: %s" % (str(addr), why))
        return
    role = hello.get("role")
    log("%s connected from %s" % (role, addr))
    send_frame(sock, {"kind": "welcome"})
    if role == "guest":
        # tell the (already-connected) host a peer just showed up, so it can push
        # {"kind":"world",...} down to the guest -- see netlink.lua onPeerJoined().
        with session.lock:
            host_sock = session.host_sock
        if host_sock is not None:
            send_frame(host_sock, {"kind": "peer_joined"})
    # Wait until the other side exists (guest may connect after or before this thread
    # starts piping -- poll briefly rather than adding another lock/condvar).
    other = None
    for _ in range(int(HELLO_TIMEOUT * 20)):
        with session.lock:
            other = session.guest_sock if role == "host" else session.host_sock
        if other is not None:
            break
        time.sleep(0.05)
    if other is None:
        return  # nobody ever showed up; this side's read loop below will just idle/EOF
    pipe(sock, other, role, session.on_gone)


def main():
    port = DEFAULT_PORT
    if "--port" in sys.argv:
        port = int(sys.argv[sys.argv.index("--port") + 1])

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(("0.0.0.0", port))
    except OSError as e:
        # ponytail: a relay already bound here is success, not failure -- don't steal the
        # port or spawn a second one. Exit quietly, "Stop Hosting" still finds the real pid.
        log("port %d already bound (%s) -- assuming a relay is already running, exiting" % (port, e))
        sys.exit(0)
    srv.listen(4)

    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    log("listening on 0.0.0.0:%d, pid %d" % (port, os.getpid()))
    session = Session()
    # Accept until BOTH sides are actually registered -- not until 2 raw sockets have
    # connected. A rejected attempt (wrong code, port scanner, malformed hello) must not
    # burn a "slot" and permanently lock out the real guest for the rest of the session.
    # ponytail: unbounded accept loop is an acceptable DoS ceiling for a LAN-only V1 (each
    # attempt still needs a full TCP handshake + waits out HELLO_TIMEOUT before dying);
    # add a rate limit if that ever matters.
    srv.settimeout(1.0)
    try:
        while True:
            with session.lock:
                if session.host_sock is not None and session.guest_sock is not None:
                    break
            try:
                sock, addr = srv.accept()
            except socket.timeout:
                continue
            threading.Thread(target=handle_conn, args=(sock, addr, session), daemon=True).start()
        # Both sides registered; keep the process alive so the two pipe threads keep running.
        # Exits when killed (Stop Hosting -> taskkill by PID_FILE's pid) or on host_left.
        while True:
            time.sleep(1)
            with session.lock:
                if session.host_sock is None:
                    break
    finally:
        try:
            os.remove(PID_FILE)
        except OSError:
            pass


if __name__ == "__main__":
    main()
