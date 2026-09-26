pragma Singleton
import QtQuick
// Never a real path: the harness must not touch ~/.local/state.
QtObject { function env(name) { return name === "HOME" ? "/nonexistent/omaqbt-harness" : "" } }
