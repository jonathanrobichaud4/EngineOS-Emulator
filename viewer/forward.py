"""A plain TCP forwarder into the deck's network namespace."""
import socket
import threading


def forward(listen_port, target):
    """Plain TCP forwarder: the deck runs in its own network namespace, so its web console
    isn't on the PC's localhost (which is what Windows forwards). This puts it back there."""
    host, port = target.rsplit(":", 1)

    def pipe(a, b):
        try:
            while True:
                d = a.recv(65536)
                if not d:
                    break
                b.sendall(d)
        except OSError:
            pass
        for x in (a, b):
            try:
                x.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def serve():
        ls = socket.socket()
        ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        ls.bind(("0.0.0.0", listen_port))
        ls.listen(64)
        while True:
            c, _ = ls.accept()
            try:
                u = socket.create_connection((host, int(port)), timeout=5)
                u.settimeout(None)
            except OSError:
                c.close()
                continue
            threading.Thread(target=pipe, args=(c, u), daemon=True).start()
            threading.Thread(target=pipe, args=(u, c), daemon=True).start()

    threading.Thread(target=serve, daemon=True).start()
