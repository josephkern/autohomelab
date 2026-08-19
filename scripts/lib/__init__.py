"""autohomelab helper library.

Only `validity` lives here so far — the single source of truth for
docs/validity-contract.md. Import it either way:

    import sys; sys.path.insert(0, "<repo>/scripts")
    from lib.validity import RESULTS_HEADER, verdicts        # via the package
    # or, when only the module matters:
    sys.path.insert(0, "<repo>/scripts/lib"); import validity

The re-export below keeps `from lib import RESULTS_HEADER` working too. It is guarded so
that importing the package never fails just because someone loaded `validity.py` directly
as a top-level module first.
"""

from __future__ import annotations

try:  # pragma: no cover - convenience re-export only
    from . import validity as validity  # noqa: F401
    from .validity import *  # noqa: F401,F403
    from .validity import __all__ as _validity_all

    __all__ = list(_validity_all) + ["validity"]
except ImportError:  # pragma: no cover
    __all__ = []
