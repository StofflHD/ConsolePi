# ConsolePi web terminal (ttyd): open the menu right after login, like AirConsole.
#
# The session survives a lost connection (WiFi gone, page reloaded, tab closed): it runs under dtach,
# and logging in again in the browser (same user) takes you back into it - with a running serial
# connection.  Leaving the menu drops to a normal shell; 'exit' ends the session for good.
# Several browser tabs of the same user share one session.
if [ "${CONSOLEPI_WEB:-}" = "1" ]; then
    unset CONSOLEPI_WEB
    case $- in
    *i*)
        consolepi_web_sock="${HOME:-}/.consolepi-web.sock"
        if command -v dtach >/dev/null 2>&1 && [ -d "${HOME:-}" ] && [ -w "$HOME" ]; then
            [ -S "$consolepi_web_sock" ] && printf '\r\nResuming your web terminal session ...\r\n'
            # -A attach or start, -E no detach key, -z no suspend key, -r winch: redraw on attach
            CONSOLEPI_WEB_SESSION=1 dtach -A "$consolepi_web_sock" -E -z -r winch "${SHELL:-/bin/bash}" -l
            exit 0          # the session ended ('exit' inside it): back to the login prompt
        fi
        command -v consolepi-menu >/dev/null 2>&1 && consolepi-menu ;;
    esac
elif [ "${CONSOLEPI_WEB_SESSION:-}" = "1" ] && [ -z "${CONSOLEPI_WEB_STARTED:-}" ]; then
    # first shell inside the session: open the menu once (not again in nested shells)
    export CONSOLEPI_WEB_STARTED=1
    case $- in
        *i*) command -v consolepi-menu >/dev/null 2>&1 && consolepi-menu ;;
    esac
fi
