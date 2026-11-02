import shutil
import stat
import subprocess
import sys
from pathlib import Path


def test_init_creates_secrets_once_without_printing_them(tmp_path):
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    original = Path(__file__).resolve().parents[2] / "scripts/init_env.py"
    script = scripts / "init_env.py"
    shutil.copyfile(original, script)
    result = subprocess.run([sys.executable, str(script)], capture_output=True, text=True)
    assert result.returncode == 0
    env = tmp_path / ".env"
    content = env.read_text()
    values = dict(line.split("=", 1) for line in content.splitlines())
    assert len(values["NEXORA_API_KEY"]) == 64
    assert values["NEXORA_API_KEY"] != values["POSTGRES_PASSWORD"]
    assert values["NEXORA_API_KEY"] not in result.stdout + result.stderr
    assert stat.S_IMODE(env.stat().st_mode) == 0o600
    assert (tmp_path / ".runtime/host-disk").is_dir()
    again = subprocess.run([sys.executable, str(script)], capture_output=True)
    assert again.returncode != 0
    assert env.read_text() == content
