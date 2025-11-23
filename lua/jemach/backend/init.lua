local M = {}

-- Abstract backend interface
-- All backends must implement these methods:
-- - is_available(): boolean
-- - is_running(): boolean
-- - start(cmd, opts): boolean/id
-- - send(text): boolean
-- - show(): boolean
-- - hide(): boolean
-- - toggle(): boolean
-- - get_window(): win_id/nil

return M
