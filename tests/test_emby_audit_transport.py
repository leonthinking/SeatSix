"""Offline regression coverage for certificate-pinned read-only audit transport."""

import hashlib
import http.client
import io
import json
import socket
import ssl
import threading
import time
import unittest
from unittest.mock import patch

from scripts.emby_audit.transport import (
    AuditClient, AuditError, MAX_RESPONSE_BYTES, TIMEOUT_SECONDS,
)


CERTIFICATE = b"offline synthetic certificate"
CONFIG = {
    "address": "https://nas.example.test:9443/emby/",
    "approvedFingerprint": hashlib.sha256(CERTIFICATE).hexdigest(),
    "username": "test-user",
    "password": "private-test-password",
}


class FakeResponse:
    def __init__(self, status=200, body=b"{}", headers=None):
        self.status = status
        self.body = body
        self.headers = headers or {"Content-Type": "application/json"}
        self.offset = 0
        self.read_sizes = []

    def getheaders(self):
        return list(self.headers.items())

    def read(self, size):
        self.read_sizes.append(size)
        part = self.body[self.offset:self.offset + size]
        self.offset += len(part)
        return part

    read1 = read


class FakeConnection:
    def __init__(self, response=None, certificate=CERTIFICATE, failure=None):
        self.response = response or FakeResponse()
        self.certificate = certificate
        self.failure = failure
        self.events = []
        self.requests = []
        self.sock = self
        self.auto_open = 1
        self.timeouts = []

    def connect(self):
        self.events.append("connect")
        if self.failure:
            raise self.failure

    def getpeercert(self, binary_form):
        assert binary_form
        self.events.append("certificate")
        return self.certificate

    def settimeout(self, timeout):
        self.timeouts.append(timeout)

    def shutdown(self, how):
        self.events.append("shutdown")

    def request(self, method, target, body=None, headers=None):
        self.events.append("request")
        self.requests.append((method, target, body, headers, self.auto_open))

    def getresponse(self):
        self.events.append("response")
        return self.response

    def close(self):
        self.events.append("close")


class FakeFactory:
    def __init__(self, *connections):
        self.connections = list(connections)
        self.calls = []

    def __call__(self, host, port, **kwargs):
        self.calls.append((host, port, kwargs))
        return self.connections[len(self.calls) - 1]


def auth_response(**overrides):
    data = {"AccessToken": "private-test-token", "User": {"Id": "private-user-id"}}
    data.update(overrides)
    return FakeResponse(body=json.dumps(data).encode())


class AuditTransportTests(unittest.TestCase):
    def client(self, *connections, config=None):
        factory = FakeFactory(*connections)
        return AuditClient(config or CONFIG, connection_factory=factory), factory

    def test_pin_is_checked_before_any_login_credentials_are_sent(self):
        connection = FakeConnection(auth_response())
        client, factory = self.client(connection)
        client.login()
        self.assertEqual(connection.events, ["connect", "certificate", "request", "response", "close"])
        method, target, body, headers, auto_open = connection.requests[0]
        self.assertEqual((method, target), ("POST", "/emby/Users/AuthenticateByName"))
        self.assertEqual(json.loads(body), {"Username": CONFIG["username"], "Pw": CONFIG["password"]})
        self.assertNotIn("X-Emby-Token", headers)
        self.assertEqual(auto_open, 0)
        host, port, options = factory.calls[0]
        self.assertEqual((host, port, options["timeout"]), ("nas.example.test", 9443, TIMEOUT_SECONDS))
        self.assertEqual(options["context"].verify_mode, ssl.CERT_NONE)
        self.assertFalse(options["context"].check_hostname)
        self.assertEqual(client.user_id, "private-user-id")
        self.assertIsNone(client._password)

    def test_changed_or_absent_certificate_never_sends_request(self):
        for certificate in (b"changed", None, b""):
            with self.subTest(certificate=certificate):
                connection = FakeConnection(certificate=certificate)
                client, _ = self.client(connection)
                with self.assertRaisesRegex(AuditError, "approved fingerprint"):
                    client.login()
                self.assertEqual(connection.events, ["connect", "certificate", "close"])
                self.assertEqual(connection.requests, [])

    def test_each_new_connection_checks_pin_before_sending_session_token(self):
        login = FakeConnection(auth_response())
        first_read = FakeConnection()
        changed = FakeConnection(certificate=b"changed")
        client, factory = self.client(login, first_read, changed)
        client.login()
        client.request("Users/private-user-id/Views")
        self.assertEqual(first_read.requests[0][3]["X-Emby-Token"], "private-test-token")
        self.assertEqual(first_read.events[:3], ["connect", "certificate", "request"])
        with self.assertRaises(AuditError):
            client.request("System/Info")
        self.assertEqual(len(factory.calls), 3)
        self.assertEqual(changed.requests, [])

    def test_rejects_unsafe_origin_before_connecting(self):
        invalid = [
            "http://nas.example.test", "https:///missing", "https://user:secret@nas.example.test",
            "https://nas.example.test?token=secret", "https://nas.example.test#fragment",
            "https://nas.example.test?", "https://nas.example.test#", "https://nas.example.test:0",
            "https://nas.example.test:65536", "https://nas.example.test/../admin",
            "https://nas.example.test/%2e%2e", "https://nas.example.test//emby",
            "https://nas.example.test\\other", "https://nas.example.test\n", "https://%65xample.test",
            "https://[::1]ignored", "https://[::1]:", "https://nas.example.test:",
        ]
        for address in invalid:
            with self.subTest(address=address), self.assertRaises(AuditError):
                AuditClient({**CONFIG, "address": address})

    def test_accepts_ipv6_and_preserves_explicit_base_path(self):
        connection = FakeConnection()
        client, factory = self.client(connection, config={**CONFIG, "address": "https://[::1]:9443/proxy/emby"})
        client.request("System/Info")
        self.assertEqual(factory.calls[0][:2], ("::1", 9443))
        self.assertEqual(connection.requests[0][1], "/proxy/emby/System/Info")

    def test_rejects_absolute_encoded_and_traversal_api_paths(self):
        client, factory = self.client()
        for path in ("", "/Items", "https://other.test/Items", "//other.test/Items", "../Items",
                     "Items/../Delete", "Items/./Read", "Items//Read", "Items%2fDelete", "Items?x=y",
                     "Items#x", "Items\\Delete", "Items/", "Items/\n"):
            with self.subTest(path=path), self.assertRaises(AuditError):
                client.request(path)
        self.assertEqual(factory.calls, [])

    def test_only_two_post_routes_are_allowed_and_other_write_methods_are_blocked(self):
        client, factory = self.client()
        for method, path in (("DELETE", "Items/a"), ("PUT", "Users/a"), ("PATCH", "Items/a"),
                             ("POST", "Users/a/PlayedItems/b"), ("POST", "Sessions/Playing"),
                             ("POST", "Users/AuthenticateByName/extra"), ("POST", "Items/a/b/PlaybackInfo"),
                             ("POST", "Items/../PlaybackInfo"), ("POST", "Items/a/PlaybackInfo/extra")):
            with self.subTest(method=method, path=path), self.assertRaises(AuditError):
                client.request(path, method=method, body={})
        self.assertEqual(factory.calls, [])
        connection = FakeConnection()
        client, _ = self.client(connection)
        client.request("Items/sample-id/PlaybackInfo", method="POST", body={"AutoOpenLiveStream": False})
        self.assertEqual(connection.requests[0][0], "POST")

    def test_read_body_and_unsafe_headers_are_rejected_before_connect(self):
        client, factory = self.client()
        for method in ("GET", "HEAD"):
            with self.assertRaises(AuditError):
                client.request("Items/Counts", method=method, body={})
        for headers in ({"X-Emby-Token": "replacement"}, {"x-emby-authorization": "replacement"},
                        {"Authorization": "secret"}, {"Host": "other.test"}, {"Cookie": "secret"},
                        {"Range": "bytes=0-1\r\nAuthorization: secret"}):
            with self.subTest(headers=headers), self.assertRaises(AuditError):
                client.request("Items/Counts", headers=headers)
        self.assertEqual(factory.calls, [])

    def test_range_cache_headers_and_query_encoding_are_supported(self):
        connection = FakeConnection(FakeResponse(206, b"ab", {"ETag": '"sample"'}))
        client, _ = self.client(connection)
        result = client.request("Users/sample/Items", query={"Tag": "a&x=y", "Type": [1, 2]},
                                headers={"Range": "bytes=0-1", "If-None-Match": '"sample"'})
        self.assertEqual(connection.requests[0][1], "/emby/Users/sample/Items?Tag=a%26x%3Dy&Type=1&Type=2")
        self.assertEqual(result.status, 206)
        self.assertEqual(result.body, b"ab")
        self.assertIsNone(result.data)
        self.assertEqual(result.headers, {"etag": '"sample"'})

    def test_non_success_and_redirect_are_returned_without_following(self):
        for status in (302, 401, 403, 404, 500):
            with self.subTest(status=status):
                connection = FakeConnection(FakeResponse(status, b'{"error":true}', {"Location": "https://other.test"}))
                client, factory = self.client(connection)
                result = client.request("System/Info")
                self.assertEqual((result.status, result.data), (status, {"error": True}))
                self.assertEqual(len(factory.calls), 1)
                self.assertEqual(len(connection.requests), 1)

    def test_size_limit_uses_actual_body_even_without_content_length(self):
        connection = FakeConnection(FakeResponse(body=b"x" * (MAX_RESPONSE_BYTES + 1)))
        client, _ = self.client(connection)
        with self.assertRaisesRegex(AuditError, "size limit"):
            client.request("Items/Counts")
        self.assertEqual(connection.response.offset, MAX_RESPONSE_BYTES + 1)
        self.assertEqual(connection.events[-1], "close")

    def test_declared_oversize_is_rejected_without_reading_body(self):
        response = FakeResponse(headers={"Content-Length": str(MAX_RESPONSE_BYTES + 1)})
        client, _ = self.client(FakeConnection(response))
        with self.assertRaisesRegex(AuditError, "size limit"):
            client.request("Items/Counts")
        self.assertEqual(response.read_sizes, [])

    def test_head_accepts_large_media_metadata_without_reading_body(self):
        response = FakeResponse(headers={"Content-Length": str(MAX_RESPONSE_BYTES * 1000)})
        client, _ = self.client(FakeConnection(response))
        result = client.request("Items/sample/Download", method="HEAD")
        self.assertEqual((result.status, result.body, result.data), (200, b"", None))
        self.assertEqual(response.read_sizes, [])

    def test_exactly_at_size_limit_is_allowed(self):
        response = FakeResponse(body=b"x" * MAX_RESPONSE_BYTES)
        client, _ = self.client(FakeConnection(response))
        result = client.request("Items/Counts")
        self.assertEqual(len(result.body), MAX_RESPONSE_BYTES)

    def test_login_and_transport_failures_do_not_expose_server_details(self):
        for response in (
            FakeResponse(401, b'{"message":"private-test-password https://nas.example.test"}'),
            FakeResponse(body=b"private-test-password"), auth_response(AccessToken="bad\r\ntoken"),
            auth_response(User={"Id": "../private-user-id"}),
        ):
            client, _ = self.client(FakeConnection(response))
            with self.subTest(response=response.status), self.assertRaisesRegex(AuditError, "^Authentication failed$"):
                client.login()
            self.assertIsNone(client.user_id)
        client, _ = self.client(FakeConnection(failure=OSError("private-test-token https://nas.example.test")))
        with self.assertRaisesRegex(AuditError, "^Audit transport failed$"):
            client.login()

    def test_response_repr_and_closed_client_do_not_expose_private_state(self):
        client, factory = self.client(FakeConnection(auth_response()))
        response = client.request("Users/AuthenticateByName", method="POST", body={})
        self.assertEqual(repr(response), "AuditResponse(status=200)")
        client.close()
        self.assertIsNone(client.user_id)
        self.assertIsNone(client._token)
        self.assertIsNone(client._password)
        with self.assertRaisesRegex(AuditError, "closed"):
            client.request("Items/Counts")
        self.assertEqual(len(factory.calls), 1)

    def test_metadata_route_allowlist_covers_the_audit_without_allowing_streams(self):
        routes = (
            "System/Info", "Items/Counts", "Genres", "Persons", "Search/Hints", "Sessions",
            "LiveTv/Channels", "Sync/Jobs", "Shows/NextUp", "Movies/Recommendations", "Users/user",
            "Users/user/Views", "Users/user/Items", "Users/user/Items/Latest", "Users/user/Items/Resume",
            "Users/user/Items/Suggestions", "Users/user/Items/movie", "Users/user/Items/movie/SpecialFeatures",
            "Users/user/Items/movie/LocalTrailers", "Items/movie/Similar", "Shows/show/Seasons",
            "Shows/show/Episodes", "Videos/movie/AdditionalParts", "MediaSegments/episode",
        )
        for path in routes:
            with self.subTest(path=path):
                client, factory = self.client(FakeConnection())
                client.request(path)
                self.assertEqual(len(factory.calls), 1)
        client, factory = self.client()
        for method, path in (
            ("GET", "Videos/movie/stream"), ("HEAD", "Videos/movie/stream"),
            ("GET", "Videos/movie/stream.mp4"), ("GET", "Videos/movie/master.m3u8"),
            ("GET", "Items/movie/RemoteSearch/Subtitles/eng"), ("GET", "Providers/Subtitles/Subtitles/key"),
            ("GET", "Items/movie/Download"), ("GET", "Items/movie/Images/Primary"),
            ("GET", "System/Restart"), ("GET", "unknownPlugin/mutation"), ("HEAD", "Sessions"),
        ):
            with self.subTest(method=method, path=path), self.assertRaisesRegex(AuditError, "route"):
                client.request(path, method=method)
        self.assertEqual(factory.calls, [])

    def test_only_explicit_head_metadata_routes_are_allowed(self):
        for path in ("Items/movie/Download", "Items/movie/Images/Primary", "Items/movie/Images/Backdrop",
                     "Items/movie/Images/Logo", "Items/movie/Images/Chapter/0"):
            with self.subTest(path=path):
                client, factory = self.client(FakeConnection())
                client.request(path, method="HEAD")
                self.assertEqual(len(factory.calls), 1)

    def test_playback_info_always_disables_playback_and_live_stream_opening(self):
        for body in ({}, {"IsPlayback": False}, {"AutoOpenLiveStream": False},
                     {"IsPlayback": False, "AutoOpenLiveStream": False}):
            with self.subTest(body=body):
                connection = FakeConnection()
                client, _ = self.client(connection)
                client.request("Items/movie/PlaybackInfo", method="POST", body=body)
                self.assertEqual(json.loads(connection.requests[0][2]),
                                 {"IsPlayback": False, "AutoOpenLiveStream": False})
        client, factory = self.client()
        for body in (None, [], {"IsPlayback": True}, {"AutoOpenLiveStream": True}, {"IsPlayback": 0},
                     {"AutoOpenLiveStream": "false"}, {"StartTimeTicks": 1}, {"LiveStreamId": "sample"}):
            with self.subTest(body=body), self.assertRaisesRegex(AuditError, "must not open"):
                client.request("Items/movie/PlaybackInfo", method="POST", body=body)
        with self.assertRaisesRegex(AuditError, "must not open"):
            client.request("Items/movie/PlaybackInfo", method="POST", body={}, query={"AutoOpenLiveStream": "true"})
        self.assertEqual(factory.calls, [])

    def test_truncated_content_length_is_rejected_with_real_http_response(self):
        class MemorySocket:
            def makefile(self, mode):
                return io.BytesIO(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{}")
        response = http.client.HTTPResponse(MemorySocket())
        response.begin()
        client, _ = self.client(FakeConnection(response))
        with self.assertRaisesRegex(AuditError, "incomplete"):
            client.request("Items/Counts")

    def test_content_length_is_not_applied_to_no_body_status_or_chunked_data(self):
        for status in (204, 304):
            with self.subTest(status=status):
                response = FakeResponse(status, b"", {"Content-Length": str(MAX_RESPONSE_BYTES * 1000)})
                client, _ = self.client(FakeConnection(response))
                self.assertEqual(client.request("Items/Counts").body, b"")
                self.assertEqual(response.read_sizes, [])
        response = FakeResponse(body=b"{}", headers={"Transfer-Encoding": "chunked", "Content-Length": "100"})
        client, _ = self.client(FakeConnection(response))
        self.assertEqual(client.request("Items/Counts").data, {})

    def test_invalid_content_length_is_rejected(self):
        for length in ("-1", "invalid", "2, 10"):
            with self.subTest(length=length):
                response = FakeResponse(headers={"Content-Length": length})
                client, _ = self.client(FakeConnection(response))
                with self.assertRaisesRegex(AuditError, "framing"):
                    client.request("Items/Counts")

    def test_slow_headers_and_body_cannot_extend_total_socket_deadline(self):
        # Real local socket I/O and HTTPResponse parsing, no listener or network
        # server. Each byte arrives within the idle timeout, but the complete
        # response exceeds the separate wall-clock budget.
        for phase in ("headers", "body"):
            with self.subTest(phase=phase):
                receiver, sender = socket.socketpair()
                stop = threading.Event()

                class PinnedSocket:
                    def getpeercert(self, binary_form):
                        return CERTIFICATE

                    def settimeout(self, timeout):
                        receiver.settimeout(timeout)

                    def shutdown(self, how):
                        receiver.shutdown(how)

                    def makefile(self, mode):
                        return receiver.makefile(mode)

                class SocketConnection(FakeConnection):
                    def __init__(self):
                        super().__init__()
                        self.sock = PinnedSocket()

                    def getresponse(self):
                        self.response = http.client.HTTPResponse(self.sock)
                        self.response.begin()
                        return self.response

                    def close(self):
                        super().close()
                        self.response.close() if hasattr(self.response, "close") else None
                        receiver.close()

                def trickle():
                    try:
                        if phase == "body":
                            sender.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n")
                            payload = b"x" * 100
                        else:
                            payload = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"
                        for value in payload:
                            if stop.wait(0.01):
                                break
                            sender.sendall(bytes([value]))
                    except OSError:
                        pass
                    finally:
                        sender.close()

                producer = threading.Thread(target=trickle, daemon=True)
                producer.start()
                client, _ = self.client(SocketConnection())
                started = time.monotonic()
                try:
                    with patch("scripts.emby_audit.transport.MAX_REQUEST_SECONDS", 0.08):
                        with self.assertRaisesRegex(AuditError, "deadline"):
                            client.request("Items/Counts")
                    self.assertLess(time.monotonic() - started, 0.5)
                finally:
                    stop.set()
                    producer.join(timeout=0.5)
                    receiver.close()
                    sender.close()

    def test_late_connect_cannot_send_credentials_after_deadline(self):
        class DelayedConnection(FakeConnection):
            def connect(self):
                time.sleep(0.04)
                super().connect()
        connection = DelayedConnection(auth_response())
        client, _ = self.client(connection)
        with patch("scripts.emby_audit.transport.MAX_REQUEST_SECONDS", 0.01):
            with self.assertRaisesRegex(AuditError, "deadline"):
                client.login()
        self.assertEqual(connection.requests, [])


if __name__ == "__main__":
    unittest.main()
