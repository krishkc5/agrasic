"""Invoke YoWASP Yosys installed in the workspace, or a normal Python environment."""
import sys
from pathlib import Path

workspace_tools = Path(__file__).resolve().parents[3] / ".tools/power-python"
if workspace_tools.is_dir():
    sys.path.insert(0, str(workspace_tools))
from yowasp_yosys import run_yosys
raise SystemExit(run_yosys(sys.argv[1:]))
