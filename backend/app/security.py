import secrets
from typing import Annotated

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.tools.permissions import Principal

bearer = HTTPBearer(auto_error=False)


def require_api_key(
    request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
) -> None:
    expected = request.app.state.settings.nexora_api_key.get_secret_value()
    if credentials is None or not secrets.compare_digest(
        credentials.credentials.encode("utf-8"), expected.encode("utf-8")
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentification requise ou clé invalide",
            headers={"WWW-Authenticate": "Bearer"},
        )


def get_principal(request: Request, _: Annotated[None, Depends(require_api_key)]) -> Principal:
    # One personal key for now; mobile accounts and sessions come in a later lot.
    return Principal(name="personal", permissions=request.app.state.settings.permissions)


def require_permission(permission: str):
    """Dependency for routes outside the tool registry that expose the same data."""

    def check(principal: Annotated[Principal, Depends(get_principal)]) -> Principal:
        if permission not in principal.permissions:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail={
                    "code": "permission_denied",
                    "message": f"Permission manquante : {permission}",
                },
            )
        return principal

    return check
