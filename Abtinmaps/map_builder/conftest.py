"""Guarantee the project root is importable for every test, every time.

Several tests do `from release_packaging.create_abm import ...`, `from routing... import
...`, etc. That only resolves if the project root happens to already be on
sys.path, which depends on *how* pytest was invoked (cwd, install mode,
whether `python -m pytest` vs the `pytest` console script was used, IDE
runners, etc.) — not on anything guaranteed by pytest itself. That made the
suite pass in some invocation modes and fail in others.

pytest always imports the nearest conftest.py directly (bypassing normal
package import machinery) before collecting any tests, so inserting the
project root here makes the imports resolve identically no matter how the
suite is run.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
