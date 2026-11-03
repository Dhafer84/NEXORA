import httpx
import pytest
from app.config import Settings
from app.github import GitHubReader
from app.main import create_app
from app.tools.builtin import build_registry
from conftest import KEY, PASSWORD, auth
from fastapi.testclient import TestClient

REPO = "Dhafer84/NEXORA"


def settings(tmp_path, repos=REPO, token: str | None = None, **values) -> Settings:
    token_file = tmp_path / "github_token"
    if token is not None:
        token_file.write_text(token + "\n")
    return Settings(
        nexora_api_key=KEY,
        postgres_password=PASSWORD,
        nexora_github_repos=repos,
        nexora_github_token_file=str(token_file),
        **values,
    )


class FakeGitHub:
    """Simulated GitHub REST API: no network access in tests."""

    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.status = 200
        self.headers: dict[str, str] = {}

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.status != 200:
            return httpx.Response(self.status, headers=self.headers, json={"message": "x"})
        path = request.url.path
        if path.endswith("/commits"):
            return httpx.Response(
                200,
                json=[
                    {
                        "sha": f"{i:040x}",
                        "commit": {
                            "message": f"Commit {i}\n\nDétail",
                            "author": {"name": "Dhafer", "date": "2026-11-03T08:00:00Z"},
                        },
                    }
                    for i in range(1, 8)
                ],
            )
        if path.endswith("/issues"):
            return httpx.Response(
                200,
                json=[
                    {"number": 4, "title": "Bug", "created_at": "2026-11-01T10:00:00Z"},
                    {
                        "number": 5,
                        "title": "PR",
                        "created_at": "2026-11-02T10:00:00Z",
                        "pull_request": {},
                    },
                ],
            )
        if path.endswith("/actions/runs"):
            return httpx.Response(
                200,
                json={
                    "workflow_runs": [
                        {
                            "name": "Backend checks",
                            "head_branch": "main",
                            "status": "completed",
                            "conclusion": "success",
                            "created_at": "2026-11-03T08:01:00Z",
                        }
                    ]
                },
            )
        return httpx.Response(
            200,
            json={"default_branch": "main", "private": False, "pushed_at": "2026-11-03T08:00:00Z"},
        )


def reader(tmp_path, fake, **kwargs) -> GitHubReader:
    return GitHubReader(settings(tmp_path, **kwargs), transport=httpx.MockTransport(fake))


def test_report_summarises_commits_issues_and_actions(tmp_path):
    fake = FakeGitHub()
    report = reader(tmp_path, fake).report()
    assert report.configured and not report.authenticated
    [repo] = report.repos
    assert repo.available and repo.default_branch == "main"
    assert [c.message for c in repo.commits] == [f"Commit {i}" for i in range(1, 6)]
    assert repo.commits[0].sha == "0000000"
    # Pull requests are not counted as issues.
    assert repo.open_issues == 1 and [i.number for i in repo.issues] == [4]
    assert repo.workflow_runs[0].conclusion == "success"


def test_only_get_requests_to_allowed_repositories(tmp_path):
    fake = FakeGitHub()
    reader(tmp_path, fake, repos="Dhafer84/NEXORA,Dhafer84/colonie").report()
    assert {r.method for r in fake.requests} == {"GET"}
    repos = {"/".join(r.url.path.split("/")[2:4]) for r in fake.requests}
    assert repos == {"Dhafer84/NEXORA", "Dhafer84/colonie"}
    assert all(r.url.host == "api.github.com" for r in fake.requests)


def test_token_is_sent_only_as_header_and_cache_limits_calls(tmp_path):
    fake = FakeGitHub()
    github = reader(tmp_path, fake, token="github_pat_test_value")
    assert github.authenticated
    github.report()
    github.report()
    assert len(fake.requests) == 4  # Second report served from the cache
    assert fake.requests[0].headers["Authorization"] == "Bearer github_pat_test_value"
    assert all("github_pat" not in str(r.url) for r in fake.requests)


@pytest.mark.parametrize(
    ("status", "headers", "message"),
    [
        (404, {}, "Dépôt introuvable, ou privé sans jeton d’accès"),
        (403, {"x-ratelimit-remaining": "0"}, "Limite de requêtes GitHub atteinte"),
        (401, {}, "Accès GitHub refusé"),
        (500, {}, "Réponse GitHub inattendue (HTTP 500)"),
    ],
)
def test_errors_are_reported_per_repository(tmp_path, status, headers, message):
    fake = FakeGitHub()
    fake.status, fake.headers = status, headers
    [repo] = reader(tmp_path, fake).report().repos
    assert not repo.available and repo.error.startswith(message)
    fake.status = 200
    # Failures are not cached: the next report retries.
    assert reader(tmp_path, fake).report().repos[0].available


def test_network_failure_does_not_leak_details(tmp_path, caplog):
    def down(request):
        raise httpx.ConnectError("token github_pat_secret in message")

    github = GitHubReader(settings(tmp_path), transport=httpx.MockTransport(down))
    [repo] = github.report().repos
    assert repo.error == "GitHub injoignable"
    assert "github_pat_secret" not in caplog.text


@pytest.mark.parametrize("repos", ["../etc", "owner/name/extra", "a b/c", ",".join(["a/b"] * 11)])
def test_invalid_allow_list_rejected(tmp_path, repos):
    with pytest.raises(ValueError):
        settings(tmp_path, repos=repos)


def test_not_configured_by_default(tmp_path):
    github = reader(tmp_path, FakeGitHub(), repos="")
    assert github.report().model_dump() == {
        "configured": False,
        "authenticated": False,
        "repos": [],
    }
    assert build_registry(github).get("github_report") is None


def test_tool_registered_when_repositories_are_allowed(tmp_path):
    spec = build_registry(reader(tmp_path, FakeGitHub())).get("github_report")
    assert spec.permissions == {"github:read"} and not spec.requires_approval


def test_route_requires_permission_and_takes_no_repository(tmp_path, monkeypatch):
    app = create_app(settings(tmp_path))
    app.state.github = reader(tmp_path, FakeGitHub())
    with TestClient(app) as client:
        response = client.get("/api/v1/github", headers=auth())
        assert response.status_code == 200
        assert response.json()["repos"][0]["repo"] == REPO
        other = client.get("/api/v1/github?repo=torvalds/linux", headers=auth())
        assert [r["repo"] for r in other.json()["repos"]] == [REPO]
    limited = create_app(settings(tmp_path, nexora_permissions="server:read"))
    with TestClient(limited) as client:
        assert client.get("/api/v1/github", headers=auth()).status_code == 403
