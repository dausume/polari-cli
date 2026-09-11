"""python -m prodguide — run the Textual production guide (pol prod guide launches this)."""
import sys

from .app import ProdGuide


def main() -> int:
    app = ProdGuide()
    rc = app.run()
    return int(rc or 0) if isinstance(rc, int) else 0


if __name__ == "__main__":
    sys.exit(main())
