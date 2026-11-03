"""Read-only GitHub reports for an allow-list of repositories.

Only GET requests to the GitHub REST API, only for the repositories listed in
NEXORA_GITHUB_REPOS. The optional token is read from a file (never from .env or
logs); without it, public repositories only, within GitHub's anonymous limit
(60 requests per hour), hence a five-minute cache.
"""

import logging
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx
from pydantic import BaseModel

from app.config import Settings

logger = logging.getLogger("nexora")

API = "https://api.github.com"
CACHE_SECONDS = 300
ITEMS = 5


class Commit(BaseModel):
    sha: str
    message: str
    author: str | None
    date: datetime | None


class Issue(BaseModel):
    number: int
    title: str
    created_at: datetime


class WorkflowRun(BaseModel):
    name: str | None
    branch: str | None
    status: str | None
    conclusion: str | None
    created_at: datetime


class RepoReport(BaseModel):
    repo: str
    available: bool
    error: str | None = None
    default_branch: str | None = None
    private: bool | None = None
    pushed_at: datetime | None = None
    open_issues: int | None = None
    open_issues_capped: bool = False
    commits: list[Commit] = []
    issues: list[Issue] = []
    workflow_runs: list[WorkflowRun] = []
    fetched_at: datetime


class GitHubReport(BaseModel):
    configured: bool
    authenticated: bool
    repos: list[RepoReport]


class GitHubError(Exception):
    pass


def _first_line(text: str | None, limit: int = 200) -> str:
    line = (text or "").strip().splitlines()[0] if (text or "").strip() else ""
    return line[:limit]


class GitHubReader:
    def __init__(self, settings: Settings, transport: httpx.BaseTransport | None = None) -> None:
        self.repos = settings.github_repos
        token = self._token(settings.nexora_github_token_file)
        self.authenticated = token is not None
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "nexora-backend",
        }
        if token:
            headers["Authorization"] = f"Bearer {token}"
        self._client = httpx.Client(
            base_url=API, headers=headers, timeout=10, transport=transport, follow_redirects=False
        )
        self._cache: dict[str, tuple[float, RepoReport]] = {}
        self._lock = threading.Lock()

    @staticmethod
    def _token(path: str) -> str | None:
        try:
            value = Path(path).read_text().strip()
        except OSError:
            return None
        return value or None

    def _get(self, path: str, **params: str | int) -> object:
        try:
            response = self._client.get(path, params=params)
        except httpx.HTTPError as error:
            logger.warning("github_request_failed type=%s", type(error).__name__)
            raise GitHubError("GitHub injoignable") from None
        if response.status_code == 404:
            raise GitHubError("Dépôt introuvable, ou privé sans jeton d’accès")
        if response.status_code in (401, 403, 429):
            remaining = response.headers.get("x-ratelimit-remaining")
            if remaining == "0" or response.status_code == 429:
                raise GitHubError("Limite de requêtes GitHub atteinte, réessayer plus tard")
            raise GitHubError("Accès GitHub refusé (jeton absent, expiré ou insuffisant)")
        if response.status_code != 200:
            raise GitHubError(f"Réponse GitHub inattendue (HTTP {response.status_code})")
        try:
            return response.json()
        except ValueError:
            raise GitHubError("Réponse GitHub illisible") from None

    def _fetch(self, repo: str) -> RepoReport:
        now = datetime.now(timezone.utc)
        try:
            meta = self._get(f"/repos/{repo}")
            commits = self._get(f"/repos/{repo}/commits", per_page=ITEMS)
            # The issues endpoint also returns pull requests: they are filtered out.
            issues = self._get(f"/repos/{repo}/issues", state="open", per_page=100)
            runs = self._get(f"/repos/{repo}/actions/runs", per_page=ITEMS)
            open_issues = [item for item in issues if "pull_request" not in item]
            return RepoReport(
                repo=repo,
                available=True,
                default_branch=meta.get("default_branch"),
                private=meta.get("private"),
                pushed_at=meta.get("pushed_at"),
                open_issues=len(open_issues),
                open_issues_capped=len(issues) >= 100,
                commits=[
                    Commit(
                        sha=item["sha"][:7],
                        message=_first_line(item["commit"]["message"]),
                        author=(item["commit"].get("author") or {}).get("name"),
                        date=(item["commit"].get("author") or {}).get("date"),
                    )
                    for item in commits[:ITEMS]
                ],
                issues=[
                    Issue(
                        number=item["number"],
                        title=_first_line(item["title"]),
                        created_at=item["created_at"],
                    )
                    for item in open_issues[:ITEMS]
                ],
                workflow_runs=[
                    WorkflowRun(
                        name=item.get("name"),
                        branch=item.get("head_branch"),
                        status=item.get("status"),
                        conclusion=item.get("conclusion"),
                        created_at=item["created_at"],
                    )
                    for item in runs.get("workflow_runs", [])[:ITEMS]
                ],
                fetched_at=now,
            )
        except GitHubError as error:
            return RepoReport(repo=repo, available=False, error=str(error), fetched_at=now)
        except (KeyError, TypeError, AttributeError, ValueError):
            return RepoReport(
                repo=repo, available=False, error="Réponse GitHub inattendue", fetched_at=now
            )

    def report(self) -> GitHubReport:
        reports = []
        for repo in self.repos:
            with self._lock:
                cached = self._cache.get(repo)
            if cached and time.monotonic() - cached[0] < CACHE_SECONDS:
                reports.append(cached[1])
                continue
            fresh = self._fetch(repo)
            if fresh.available:
                with self._lock:
                    self._cache[repo] = (time.monotonic(), fresh)
            reports.append(fresh)
        return GitHubReport(
            configured=bool(self.repos), authenticated=self.authenticated, repos=reports
        )

    def close(self) -> None:
        self._client.close()
