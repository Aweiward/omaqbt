"""Choose a localhost WebUI port while qBittorrent is stopped."""
import errno
import socket
import sys

FALLBACK_PORTS = range(18080, 19000)


def choose_port(preferred):
    if not 1 <= preferred <= 65535:
        raise ValueError("WebUI port must be between 1 and 65535")
    for port in (preferred, *FALLBACK_PORTS):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            # Allow a restart while old connections are in TIME_WAIT, but
            # never share a listening socket with another service.
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                listener.bind(("127.0.0.1", port))
            except OSError as exc:
                if exc.errno not in (errno.EADDRINUSE, errno.EACCES):
                    raise
                continue
            return port
    raise OSError(errno.EADDRINUSE, "No available WebUI port in 18080-18999")


if __name__ == "__main__":
    print(choose_port(int(sys.argv[1])))
