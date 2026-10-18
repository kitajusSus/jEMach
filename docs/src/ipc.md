# IPC & Socket Architecture

Overview of communication mechanics implemented between `jEMach.jl` and UI consumers (`jl-assist` TUI and Zig broker).

## Dual Sync Mechanism

`jEMach.jl` uses a hybrid communication model combining **UNIX Domain Socket Event Broadcasting** and **Filesystem State Backup**.

```
                       +-------------------------------+
                       |    jEMach Julia Engine        |
                       +---------------+---------------+
                                       |
                     +-----------------+-----------------+
                     |                                   |
           UNIX Socket Listener                  File State Output
     /tmp/jemach_<project_hash>.sock         /tmp/jl_tui_state_<hash>.json
                     |                                   |
            +--------+--------+                 +--------+--------+
            |                 |                 |                 |
     jl-assist TUI       Zig Broker       Fallback Reader   Offline Inspector
```

## UNIX Domain Socket Broadcasting

- **Socket Path**: `/tmp/jemach_<project_safe_name>.sock`
- **Protocol**: Single-line JSON objects terminated with `\n`.
- **Subscriber Connection**:
  1. Consumer connects to socket and writes `SUB\n`.
  2. `jEMach` registers client socket in active subscriber set `_socket_clients`.
  3. Immediately sends the latest serialized workspace JSON.
  4. Subsequent state refreshes write JSON payloads directly across open sockets.

#### Automatic Fallback File

In addition to socket streaming, state updates are written to `/tmp/jl_tui_state_<project_safe_name>.json` to ensure recovery if socket connections reset or close.
