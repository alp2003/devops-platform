import json
import threading
import urllib.error
import urllib.request

import pytest

import main


@pytest.fixture(scope="module")
def base_url():
    server = main.make_server(0)  # port 0 = any free port
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()


def get(url):
    try:
        with urllib.request.urlopen(url) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def test_healthz(base_url):
    code, body = get(f"{base_url}/healthz")
    assert code == 200 and json.loads(body) == {"status": "ok"}


def test_version_reports_build_info(base_url):
    code, body = get(f"{base_url}/version")
    assert code == 200 and set(json.loads(body)) == {"version", "commit"}


def test_metrics_expose_build_info(base_url):
    code, body = get(f"{base_url}/metrics")
    assert code == 200 and "web_build_info{" in body


def test_unknown_path_is_404_and_label_is_bounded(base_url):
    code, _ = get(f"{base_url}/random-scanner-path-123")
    assert code == 404
    _, metrics = get(f"{base_url}/metrics")
    assert 'path="other"' in metrics and "random-scanner-path-123" not in metrics


def test_server_header_hides_python_version(base_url):
    with urllib.request.urlopen(f"{base_url}/healthz") as r:
        assert "Python" not in r.headers.get("Server", "")
