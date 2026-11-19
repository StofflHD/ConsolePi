# ConsolePi web terminal (ttyd): open the menu right after login, like AirConsole.
# Leaving the menu drops to a normal shell; 'exit' closes the session.
if [ "${CONSOLEPI_WEB:-}" = "1" ]; then
    unset CONSOLEPI_WEB
    case $- in
        *i*) command -v consolepi-menu >/dev/null 2>&1 && consolepi-menu ;;
    esac
fi
