"""Bounded, explicitly pinned transport for a read-only Emby API audit.

The certificate exception is scoped to the configured origin and exact leaf
certificate. No request bytes are sent before that certificate is checked.
Credentials, session identifiers, response bodies and URLs are never included in
exceptions. Callers must separately sanitize any response data they publish.
"""

from dataclasses import dataclass, field
import hashlib
import hmac
import http.client
import ipaddress
import json
import re
import socket
import ssl
import threading
import time
from collections.abc import Mapping
from urllib.parse import urlencode, urlsplit


MAX_RESPONSE_BYTES = 4 * 1024 * 1024
TIMEOUT_SECONDS = 10
MAX_REQUEST_SECONDS = 20
_SEGMENT = re.compile(r"[A-Za-z0-9_.~-]+\Z")
_SAFE_HEADERS = {
    "range", "if-range", "if-none-match", "if-modified-since", "if-match",
    "if-unmodified-since", "cache-control",
}
_AUTHORIZATION = (
    'MediaBrowser Client="SeatSix Capability Audit", Device="Mac", '
    'DeviceId="theater-readonly-capability-audit", Version="0.1"'
)
_ID = r"[A-Za-z0-9_.~-]+"
_READ_ROUTES = {
    "GET": (
        r"System/Info", r"Items/Counts", r"Genres", r"Persons", r"Search/Hints",
        r"Sessions", r"LiveTv/Channels", r"Sync/Jobs", r"Shows/NextUp",
        r"Movies/Recommendations", rf"Users/{_ID}", rf"Users/{_ID}/Views",
        rf"Users/{_ID}/Items", rf"Users/{_ID}/Items/{_ID}",
        rf"Users/{_ID}/Items/{_ID}/(?:SpecialFeatures|LocalTrailers)",
        rf"Items/{_ID}/Similar", rf"Shows/{_ID}/(?:Seasons|Episodes)",
        rf"Videos/{_ID}/AdditionalParts", rf"MediaSegments/{_ID}",
    ),
    "HEAD": (
        rf"Items/{_ID}/Download",
        rf"Items/{_ID}/Images/(?:Primary|Backdrop|Logo|Chapter/[0-9]+)",
    ),
}


class AuditError(Exception):
    """A sanitized configuration, policy, transport or authentication failure."""


@dataclass(frozen=True)
class AuditResponse:
    status: int
    # Avoid accidentally exposing private server metadata in debug repr output.
    data: object = field(repr=False)
    body: bytes = field(repr=False)
    headers: dict = field(repr=False)


def _valid_segments(path):
    return bool(path) and all(
        segment not in (".", "..") and _SEGMENT.fullmatch(segment)
        for segment in path.split("/")
    )


def _origin(address):
    if not isinstance(address, str) or any(ord(c) <= 32 or ord(c) == 127 for c in address):
        raise AuditError("Invalid HTTPS server address")
    try:
        parsed = urlsplit(address)
        port = parsed.port if parsed.port is not None else 443
        host = parsed.hostname
        if (parsed.scheme != "https" or not host or parsed.username is not None
                or parsed.password is not None or "?" in address or "#" in address
                or "\\" in address or not 1 <= port <= 65535):
            raise ValueError()
        authority = rf"\[{re.escape(host)}\]" if ":" in host else re.escape(host)
        if not re.fullmatch(authority + r"(?::[0-9]+)?", parsed.netloc, flags=re.IGNORECASE):
            raise ValueError()
        try:
            ipaddress.ip_address(host)
        except ValueError:
            if len(host) > 253 or not all(
                re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                for label in host.rstrip(".").split(".")
            ):
                raise ValueError()
        base = parsed.path.strip("/")
        if (parsed.path and not parsed.path.startswith("/")) or (base and not _valid_segments(base)):
            raise ValueError()
        # Reject ambiguous double leading/trailing slashes rather than normalize
        # a potentially distinct proxy route.
        if "//" in parsed.path:
            raise ValueError()
        return host, port, "/" + base if base else ""
    except (ValueError, TypeError):
        raise AuditError("Invalid HTTPS server address") from None


class AuditClient:
    """One origin, one approved certificate; only audit-safe HTTP methods.

    ``connection_factory`` is an optional local-test seam with the same call
    signature as ``http.client.HTTPSConnection``. Production callers omit it.
    Each request creates and closes its own connection, so certificate changes
    are checked on every handshake and redirects cannot change the origin.
    Socket I/O has a 20-second total deadline and a 10-second idle timeout.
    The operating system's synchronous DNS resolver cannot be interrupted by
    closing a socket; after a late DNS result, the deadline is checked before
    sending any request bytes. A numerical NAS address avoids that resolver case.
    """

    def __init__(self, config, *, connection_factory=None):
        if not isinstance(config, Mapping):
            raise AuditError("Invalid audit configuration")
        self._host, self._port, self._base = _origin(config.get("address"))
        fingerprint = config.get("approvedFingerprint")
        if not isinstance(fingerprint, str):
            raise AuditError("Invalid approved certificate fingerprint")
        compact = fingerprint.replace(":", "")
        if not re.fullmatch(r"[A-Fa-f0-9]{64}", compact):
            raise AuditError("Invalid approved certificate fingerprint")
        self._fingerprint = bytes.fromhex(compact)
        self._username = config.get("username")
        self._password = config.get("password")
        if not isinstance(self._username, str) or not isinstance(self._password, str):
            raise AuditError("Invalid audit credentials")
        self._token = None
        self._user_id = None
        self._closed = False
        self._connection_factory = connection_factory or http.client.HTTPSConnection

    @property
    def user_id(self):
        """Private server identifier for constructing authenticated read paths."""
        return self._user_id

    def login(self):
        if self._closed or self._password is None:
            raise AuditError("Audit credentials are unavailable")
        response = self.request(
            "Users/AuthenticateByName", method="POST",
            body={"Username": self._username, "Pw": self._password},
        )
        try:
            if response.status != 200 or not isinstance(response.data, dict):
                raise ValueError()
            token = response.data["AccessToken"]
            user_id = response.data["User"]["Id"]
            if (not isinstance(token, str) or not token
                    or any(ord(c) < 33 or ord(c) > 126 for c in token)
                    or not isinstance(user_id, str) or not _valid_segments(user_id)
                    or "/" in user_id):
                raise ValueError()
        except (KeyError, TypeError, ValueError):
            raise AuditError("Authentication failed") from None
        self._token, self._user_id = token, user_id
        # No need to retain the password after exchanging it for a session.
        self._password = None
        self._username = None

    def request(self, path, query=None, method="GET", body=None, headers=None):
        if self._closed:
            raise AuditError("Audit client is closed")
        if not isinstance(path, str) or not _valid_segments(path):
            raise AuditError("Invalid relative API path")
        if method not in ("GET", "HEAD", "POST"):
            raise AuditError("HTTP method is not allowed for this audit")
        if method in _READ_ROUTES and not any(re.fullmatch(pattern, path) for pattern in _READ_ROUTES[method]):
            # GET can also start encoders or contact external subtitle providers.
            # Only explicitly enumerated metadata and HEAD routes are permitted.
            raise AuditError("API route is not allowed for this audit")
        if method == "POST" and not (
            path == "Users/AuthenticateByName"
            or re.fullmatch(r"Items/[A-Za-z0-9_.~-]+/PlaybackInfo", path)
        ):
            raise AuditError("API mutation is not allowed for this audit")
        if method != "POST" and body is not None:
            raise AuditError("Read requests cannot include a body")
        if method == "POST" and path != "Users/AuthenticateByName":
            if (not isinstance(body, dict)
                    or any(key not in ("IsPlayback", "AutoOpenLiveStream") or value is not False
                           for key, value in body.items())
                    or query):
                raise AuditError("Playback information request must not open playback")
            # Do not depend on a compatible server's defaults. Also exclude
            # query overrides or additional body fields that could open a stream.
            body = {"IsPlayback": False, "AutoOpenLiveStream": False}

        request_headers = {"Accept": "application/json", "X-Emby-Authorization": _AUTHORIZATION}
        if self._token:
            request_headers["X-Emby-Token"] = self._token
        if headers is not None:
            if not isinstance(headers, Mapping):
                raise AuditError("Invalid audit request headers")
            for key, value in headers.items():
                if (not isinstance(key, str) or key.lower() not in _SAFE_HEADERS
                        or not isinstance(value, str)
                        or any(ord(c) < 32 or ord(c) > 126 for c in value)):
                    raise AuditError("Request header is not allowed for this audit")
                request_headers[key] = value
        try:
            target = self._base + "/" + path
            if query is not None:
                if not isinstance(query, Mapping):
                    raise ValueError()
                encoded_query = urlencode(query, doseq=True)
                if encoded_query:
                    target += "?" + encoded_query
            encoded_body = None
            if body is not None:
                encoded_body = json.dumps(body, allow_nan=False, separators=(",", ":")).encode("utf-8")
                request_headers["Content-Type"] = "application/json"
        except (TypeError, ValueError, UnicodeError, RecursionError, OverflowError):
            raise AuditError("Invalid audit request parameters") from None

        connection = None
        checked_socket = None
        deadline = time.monotonic() + MAX_REQUEST_SECONDS
        expired = threading.Event()

        def remaining():
            duration = deadline - time.monotonic()
            if expired.is_set() or duration <= 0:
                raise AuditError("Audit request deadline exceeded")
            return min(TIMEOUT_SECONDS, duration)

        def update_timeout():
            budget = remaining()
            active_socket = checked_socket or getattr(connection, "sock", None)
            if active_socket is not None:
                active_socket.settimeout(budget)

        def abort_at_deadline():
            expired.set()
            # A socket timeout alone resets for each read and cannot stop a
            # peer trickling response-header bytes forever. Shutdown interrupts
            # the current SSL/socket read, including response.begin().
            active_socket = checked_socket or getattr(connection, "sock", None)
            if active_socket is not None:
                try:
                    active_socket.shutdown(socket.SHUT_RDWR)
                except Exception:
                    pass
            if connection is not None:
                try:
                    connection.close()
                except Exception:
                    pass

        watchdog = threading.Timer(MAX_REQUEST_SECONDS, abort_at_deadline)
        watchdog.daemon = True
        watchdog.start()
        try:
            # This context is local to this connection. Disabling CA validation
            # is coupled to exact leaf pinning below, never to system trust.
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            connection = self._connection_factory(
                self._host, self._port, context=context, timeout=remaining(),
            )
            connection.connect()
            checked_socket = connection.sock
            update_timeout()
            certificate = checked_socket.getpeercert(binary_form=True)
            if not certificate or not hmac.compare_digest(hashlib.sha256(certificate).digest(), self._fingerprint):
                raise AuditError("Server certificate does not match the approved fingerprint")
            # Prevent http.client from opening an unverified replacement socket
            # if the checked socket disappeared before sending the request.
            connection.auto_open = 0
            update_timeout()
            connection.request(method, target, body=encoded_body, headers=request_headers)
            update_timeout()
            response = connection.getresponse()
            remaining()
            response_headers = {key.lower(): value for key, value in response.getheaders()}
            length = response_headers.get("content-length")
            has_body = method != "HEAD" and response.status not in (204, 304) and not 100 <= response.status < 200
            chunked = "chunked" in [value.strip().lower() for value in response_headers.get("transfer-encoding", "").split(",")]
            declared_length = None
            if has_body and not chunked and length is not None:
                if not isinstance(length, str) or not re.fullmatch(r"[0-9]+", length.strip()):
                    raise AuditError("Invalid audit response framing")
                declared_length = int(length)
                if declared_length > MAX_RESPONSE_BYTES:
                    raise AuditError("Audit response exceeded the size limit")
            chunks = []
            received = 0
            while has_body:
                update_timeout()
                chunk = response.read1(min(64 * 1024, MAX_RESPONSE_BYTES + 1 - received))
                remaining()
                if not chunk:
                    break
                received += len(chunk)
                if received > MAX_RESPONSE_BYTES:
                    raise AuditError("Audit response exceeded the size limit")
                chunks.append(chunk)
            if declared_length is not None and received != declared_length:
                raise AuditError("Audit response was incomplete")
            raw = b"".join(chunks)
            try:
                data = json.loads(raw) if raw else None
            except (ValueError, UnicodeError, RecursionError):
                data = None
            remaining()
            return AuditResponse(status=response.status, data=data, body=raw, headers=response_headers)
        except AuditError:
            if expired.is_set():
                raise AuditError("Audit request deadline exceeded") from None
            raise
        except Exception:
            if expired.is_set() or time.monotonic() >= deadline:
                raise AuditError("Audit request deadline exceeded") from None
            raise AuditError("Audit transport failed") from None
        finally:
            watchdog.cancel()
            if connection is not None:
                try:
                    connection.close()
                except Exception:
                    pass

    def close(self):
        """Drop private credentials and session state; no remote logout call."""
        self._token = self._user_id = self._username = self._password = None
        self._closed = True
