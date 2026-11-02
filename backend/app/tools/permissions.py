from dataclasses import dataclass

from app.tools.registry import ToolSpec


@dataclass(frozen=True)
class Principal:
    """Caller identity. The personal key is the only principal in this lot."""

    name: str
    permissions: frozenset[str]


class PermissionDenied(Exception):
    def __init__(self, missing: set[str]) -> None:
        self.missing = sorted(missing)
        super().__init__("Permission manquante : " + ", ".join(self.missing))


def authorize(principal: Principal, spec: ToolSpec) -> None:
    """Single checkpoint before any tool runs or is proposed for approval."""
    missing = set(spec.permissions - principal.permissions)
    if missing:
        raise PermissionDenied(missing)
