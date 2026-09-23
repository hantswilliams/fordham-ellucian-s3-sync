"""
Example transfer script: Fordham <-> Ellucian.

Placeholder showing the shape of a transfer job. Replace the body of
`run()` with the real logic (SFTP, Ellucian Ethos API, etc.).
Credentials come from environment variables or AWS Secrets Manager,
never from the code itself.
"""

import logging
import os
from datetime import datetime, timezone

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("transfer")


def get_config() -> dict:
    """Read connection settings from environment variables."""
    return {
        "source": os.getenv("TRANSFER_SOURCE", "fordham"),
        "destination": os.getenv("TRANSFER_DEST", "ellucian"),
        "dry_run": os.getenv("DRY_RUN", "true").lower() == "true",
    }


def run() -> None:
    cfg = get_config()
    stamp = datetime.now(timezone.utc).isoformat()
    log.info("Starting transfer %s -> %s at %s", cfg["source"], cfg["destination"], stamp)

    if cfg["dry_run"]:
        log.info("DRY_RUN is on; no files moved.")
        return

    # TODO: connect to source, pull files, push to destination.
    raise NotImplementedError("Add the real transfer logic here.")


if __name__ == "__main__":
    run()
