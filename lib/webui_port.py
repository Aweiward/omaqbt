"""Choose a localhost WebUI port while qBittorrent is stopped."""
import errno
import socket
import sys


def choose_port(preferred):
    if not 1 <= preferred <= 65535:
        raise ValueError("WebUI port must be between 1 and 65535")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        # Allow a restart while old connections are in TIME_WAIT, but
        # never share a listening socket with another service.
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            listener.bind(("127.0.0.1", preferred))
        except OSError as exc:
            if exc.errno not in (errno.EADDRINUSE, errno.EACCES):
                raise
            listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


if __name__ == "__main__":
    print(choose_port(int(sys.argv[1])))
