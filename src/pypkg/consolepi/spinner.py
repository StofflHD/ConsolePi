#!/etc/ConsolePi/venv/bin/python3
"""Halo spinner wrapper that degrades to ASCII on non UTF-8 terminals.

Halo's default spinners (braille dots) and log symbols are unicode.  On a terminal
whose encoding can't represent them (e.g. LANG=C / latin-1 locale, some serial or
bluetooth terminals) writing them raises UnicodeEncodeError and crashes the menu (#227).
"""
import codecs
import sys

from halo import Halo
from log_symbols import LogSymbols

ASCII_SPINNER = {"interval": 120, "frames": ["-", "\\", "|", "/"]}

_ASCII_SYMBOLS = {
    "success": "[OK]",
    "error": "[X]",
    "warning": "[!]",
    "info": "[i]",
}


def supports_unicode(stream=None) -> bool:
    """True if stream's encoding can represent the unicode spinner/symbol characters."""
    stream = stream or sys.stdout
    encoding = getattr(stream, "encoding", None)
    if not encoding:
        return False
    try:
        codecs.lookup(encoding)
        "⠋✔✖⚠".encode(encoding)
    except (LookupError, UnicodeEncodeError):
        return False
    return True


def symbol(name: str, stream=None) -> str:
    """Return the log symbol (success/error/warning/info), ASCII if the terminal needs it."""
    if supports_unicode(stream):
        return getattr(LogSymbols, name.upper()).value
    return _ASCII_SYMBOLS[name]


class Spinner(Halo):
    """Drop-in replacement for halo.Halo with an ASCII fallback."""

    def __init__(self, text="", spinner=None, **kwargs):
        self._ascii = not supports_unicode(kwargs.get("stream", sys.stdout))
        if self._ascii:
            spinner = ASCII_SPINNER
        super().__init__(text=text, spinner=spinner, **kwargs)

    def succeed(self, text=None):
        if self._ascii:
            return self.stop_and_persist(symbol=_ASCII_SYMBOLS["success"], text=text)
        return super().succeed(text)

    def fail(self, text=None):
        if self._ascii:
            return self.stop_and_persist(symbol=_ASCII_SYMBOLS["error"], text=text)
        return super().fail(text)

    def warn(self, text=None):
        if self._ascii:
            return self.stop_and_persist(symbol=_ASCII_SYMBOLS["warning"], text=text)
        return super().warn(text)

    def info(self, text=None):
        if self._ascii:
            return self.stop_and_persist(symbol=_ASCII_SYMBOLS["info"], text=text)
        return super().info(text)
