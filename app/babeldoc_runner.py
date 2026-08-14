from __future__ import annotations

import json
import sys


def main() -> None:
    """Launch BabelDOC while receiving credentials outside the process arguments."""
    payload = json.load(sys.stdin)
    api_key = str(payload.get("api_key") or "")
    if not api_key:
        raise SystemExit("BabelDOC API key was not provided")

    sys.argv.extend(["--openai-api-key", api_key])
    from babeldoc.main import cli

    cli()


if __name__ == "__main__":
    main()
