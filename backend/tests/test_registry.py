import pytest
from app.tools.builtin import NoParameters, build_registry
from app.tools.permissions import PermissionDenied, Principal, authorize
from app.tools.registry import ToolRegistry, ToolSpec


def spec(**overrides):
    values = dict(
        name="sample_tool",
        description="Exemple",
        parameters=NoParameters,
        result=NoParameters,
        permissions=frozenset({"sample:read"}),
        risk="low",
        requires_approval=False,
        timeout_seconds=1,
        handler=lambda context, params: NoParameters(),
        summarize=lambda params: "Exemple",
    )
    values.update(overrides)
    return ToolSpec(**values)


def test_builtin_tools_are_declared_with_their_controls():
    tools = {tool.name: tool for tool in build_registry().all()}
    assert set(tools) == {"server_metrics", "database_status", "test_action"}
    assert not tools["server_metrics"].requires_approval
    assert tools["test_action"].requires_approval
    for tool in tools.values():
        public = tool.public()
        assert public["parameters_schema"]["type"] == "object"
        assert public["result_schema"]["type"] == "object"
        assert public["permissions"] and public["timeout_seconds"] > 0


def test_only_permitted_tools_are_exposed_to_the_model():
    registry = build_registry()
    allowed = registry.allowed(frozenset({"server:read"}))
    assert [tool.name for tool in allowed] == ["server_metrics"]
    schema = allowed[0].function_schema()
    assert schema["function"]["name"] == "server_metrics"
    assert registry.allowed(frozenset()) == []


@pytest.mark.parametrize(
    "overrides",
    [
        {"name": "Bad.Name"},
        {"name": "x"},
        {"permissions": frozenset()},
        {"timeout_seconds": 0},
        {"timeout_seconds": 600},
        {"risk": "high", "requires_approval": False},
    ],
)
def test_registry_rejects_unsafe_declarations(overrides):
    with pytest.raises(ValueError):
        ToolRegistry().register(spec(**overrides))


def test_registry_rejects_duplicates():
    registry = ToolRegistry()
    registry.register(spec())
    with pytest.raises(ValueError):
        registry.register(spec())


def test_authorize_reports_missing_permissions():
    principal = Principal("personal", frozenset({"server:read"}))
    authorize(principal, spec(permissions=frozenset({"server:read"})))
    with pytest.raises(PermissionDenied, match="sample:read"):
        authorize(principal, spec())
