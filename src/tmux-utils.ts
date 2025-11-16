export interface TmuxPane {
  id: string;
  index: number;
  active: boolean;
  width: number;
  height: number;
  title: string;
  current_command: string;
}

export interface TmuxWindow {
  id: string;
  index: number;
  name: string;
  active: boolean;
  panes: TmuxPane[];
}

export interface TmuxSession {
  id: string;
  name: string;
  windows: TmuxWindow[];
}

/**
 * Helper to run shell commands asynchronously and get stdout
 */
async function execAsync(command: string[]): Promise<{ stdout: string; stderr: string }> {
  const proc = Bun.spawn(command, {
    stdout: 'pipe',
    stderr: 'pipe',
  });
  const stdout = await new Response(proc.stdout).text();
  const stderr = await new Response(proc.stderr).text();
  return { stdout, stderr };
}

/**
 * Helper to run shell commands synchronously
 */
function execSync(command: string[]): string {
  const proc = Bun.spawnSync(command);
  if (proc.exitCode !== 0) {
    throw new Error(
      `Command failed: ${command.join(' ')}\n${new TextDecoder().decode(proc.stderr)}`
    );
  }
  return new TextDecoder().decode(proc.stdout);
}

/**
 * Checks if tmux is available
 */
export function isTmuxAvailable(): boolean {
  try {
    // Bun.spawnSync rzuci błąd, jeśli komenda nie istnieje
    Bun.spawnSync(['which', 'tmux']);
    return true;
  } catch {
    return false;
  }
}

/**
 * Checks if currently inside a tmux session
 */
export function isInTmuxSession(): boolean {
  return process.env.TMUX !== undefined;
}

/**
 * Gets the current tmux session ID
 */
export function getCurrentSessionId(): string | null {
  if (!isInTmuxSession()) {
    return null;
  }
  try {
    const output = execSync(['tmux', 'display-message', '-p', '#{session_id}']);
    return output.trim();
  } catch {
    return null;
  }
}

/**
 * Lists all tmux sessions
 */
export async function listSessions(): Promise<TmuxSession[]> {
  if (!isTmuxAvailable()) {
    return [];
  }
  try {
    const { stdout } = await execAsync([
      'tmux',
      'list-sessions',
      '-F',
      '#{session_id}:#{session_name}',
    ]);
    const sessions: TmuxSession[] = [];
    for (const line of stdout.trim().split('\n')) {
      if (!line) continue;
      const [id, name] = line.split(':');
      sessions.push({
        id,
        name,
        windows: [],
      });
    }
    return sessions;
  } catch {
    return [];
  }
}

/**
 * Lists panes in the current window
 */
export async function listPanes(): Promise<TmuxPane[]> {
  if (!isInTmuxSession()) {
    return [];
  }
  try {
    const { stdout } = await execAsync([
      'tmux',
      'list-panes',
      '-F',
      '#{pane_id}:#{pane_index}:#{pane_active}:#{pane_width}:#{pane_height}:#{pane_title}:#{pane_current_command}',
    ]);
    const panes: TmuxPane[] = [];
    for (const line of stdout.trim().split('\n')) {
      if (!line) continue;
      const [id, index, active, width, height, title, current_command] = line.split(':');
      panes.push({
        id,
        index: parseInt(index, 10),
        active: active === '1',
        width: parseInt(width, 10),
        height: parseInt(height, 10),
        title,
        current_command,
      });
    }
    return panes;
  } catch {
    return [];
  }
}

/**
 * Finds Julia REPL panes in the current session
 */
export async function findJuliaPanes(): Promise<TmuxPane[]> {
  const panes = await listPanes();
  return panes.filter(
    pane =>
      pane.current_command.toLowerCase().includes('julia') ||
      pane.title.toLowerCase().includes('julia')
  );
}
