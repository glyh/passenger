"""Imperative shell: the learned-signature store on disk.

The only place signatures.json is parsed or written. Everything else takes
already-typed Signature values.
"""
import json

from .config import SIGNATURES_FILE
from .detect import BUILTIN
from .errors import AgentBrowserError, ErrorCode, RegistryError
from .models import Registry, Signature


def load() -> Registry:
    if not SIGNATURES_FILE.exists():
        return Registry()
    try:
        return Registry.model_validate_json(SIGNATURES_FILE.read_text())
    except (OSError, ValueError) as exc:
        raise RegistryError(ErrorCode.REGISTRY_CORRUPT,
                            f"cannot read {SIGNATURES_FILE}",
                            detail=str(exc)) from exc


def save(registry: Registry) -> None:
    SIGNATURES_FILE.parent.mkdir(parents=True, exist_ok=True)
    SIGNATURES_FILE.write_text(registry.model_dump_json(indent=2, exclude_none=True))


def active() -> tuple[Signature, ...]:
    """Signatures allowed to match: builtins plus approved learned ones.

    Pending proposals are excluded by construction, not by a caller remembering
    to filter -- that filter is the whole safeguard against a rule guessed from
    one page blocking a site forever.
    """
    return BUILTIN + tuple(s for s in load().learned if not s.pending_review)


def listing() -> tuple[Signature, ...]:
    """Everything, pending included, for display and curation."""
    return BUILTIN + tuple(load().learned)


def approve(name: str) -> Signature:
    registry = load()
    for index, signature in enumerate(registry.learned):
        if signature.name == name:
            promoted = signature.model_copy(update={"pending_review": False})
            registry.learned[index] = promoted
            save(registry)
            return promoted
    raise RegistryError(ErrorCode.SIGNATURE_NOT_FOUND,
                        f"no learned signature named {name!r}")


def forget(name: str) -> None:
    registry = load()
    kept = [s for s in registry.learned if s.name != name]
    if len(kept) == len(registry.learned):
        raise RegistryError(ErrorCode.SIGNATURE_NOT_FOUND,
                            f"no learned signature named {name!r}")
    registry.learned = kept
    save(registry)


__all__ = ["load", "save", "active", "listing", "approve", "forget",
           "AgentBrowserError"]
