/**
 * Configuration validation and type definitions for jemach
 */

export interface BackendConfig {
  backend: 'toggleterm' | 'vim-slime' | 'auto';
  slime_target?: 'tmux' | 'screen';
  slime_default_config?: {
    socket_name: string;
    target_pane: string;
  };
}

export interface PerformanceConfig {
  workspace_update_debounce: number;
  use_cache: boolean;
  cache_ttl: number;
}

export interface WorkspaceConfig {
  activate_project_on_start: boolean;
  auto_update_workspace: boolean;
  workspace_width: number;
  workspace_style: 'detailed' | 'compact';
  auto_save_workspace: boolean;
  save_on_exit: boolean;
}

export interface TerminalConfig {
  terminal_direction: 'horizontal' | 'vertical' | 'float';
  terminal_size: number;
}

export interface JemachConfig extends BackendConfig, PerformanceConfig, WorkspaceConfig, TerminalConfig {
  max_history_size: number;
  smart_block_detection: boolean;
  use_revise: boolean;
}

export const defaultConfig: JemachConfig = {
  activate_project_on_start: true,
  auto_update_workspace: true,
  workspace_width: 50,
  max_history_size: 500,
  smart_block_detection: true,
  use_revise: true,
  terminal_direction: 'horizontal',
  terminal_size: 15,
  workspace_style: 'detailed',
  auto_save_workspace: false,
  save_on_exit: true,
  backend: 'auto',
  slime_target: 'tmux',
  slime_default_config: {
    socket_name: 'default',
    target_pane: '{right-of}',
  },
  workspace_update_debounce: 300,
  use_cache: true,
  cache_ttl: 5000,
};

/**
 * Validates a user configuration object
 */
export function validateConfig(config: Partial<JemachConfig>): {
  valid: boolean;
  errors: string[];
  warnings: string[];
} {
  const errors: string[] = [];
  const warnings: string[] = [];

  // Validate backend
  if (config.backend && !['toggleterm', 'vim-slime', 'auto'].includes(config.backend)) {
    errors.push(`Invalid backend: ${config.backend}. Must be 'toggleterm', 'vim-slime', or 'auto'`);
  }

  // Validate slime_target
  if (config.slime_target && !['tmux', 'screen'].includes(config.slime_target)) {
    errors.push(`Invalid slime_target: ${config.slime_target}. Must be 'tmux' or 'screen'`);
  }

  // Validate terminal_direction
  if (config.terminal_direction && !['horizontal', 'vertical', 'float'].includes(config.terminal_direction)) {
    errors.push(`Invalid terminal_direction: ${config.terminal_direction}`);
  }

  // Validate workspace_style
  if (config.workspace_style && !['detailed', 'compact'].includes(config.workspace_style)) {
    errors.push(`Invalid workspace_style: ${config.workspace_style}`);
  }

  // Validate numeric ranges
  if (config.workspace_width !== undefined && (config.workspace_width < 20 || config.workspace_width > 200)) {
    warnings.push('workspace_width should be between 20 and 200');
  }

  if (config.terminal_size !== undefined && (config.terminal_size < 5 || config.terminal_size > 50)) {
    warnings.push('terminal_size should be between 5 and 50');
  }

  if (config.max_history_size !== undefined && config.max_history_size < 0) {
    errors.push('max_history_size must be non-negative');
  }

  if (config.workspace_update_debounce !== undefined && config.workspace_update_debounce < 0) {
    errors.push('workspace_update_debounce must be non-negative');
  }

  if (config.cache_ttl !== undefined && config.cache_ttl < 0) {
    errors.push('cache_ttl must be non-negative');
  }

  return {
    valid: errors.length === 0,
    errors,
    warnings,
  };
}

/**
 * Merges user config with defaults, with validation
 */
export function mergeConfig(userConfig: Partial<JemachConfig>): JemachConfig {
  const validation = validateConfig(userConfig);
  
  if (!validation.valid) {
    throw new Error(`Configuration validation failed:\n${validation.errors.join('\n')}`);
  }

  if (validation.warnings.length > 0) {
    console.warn('Configuration warnings:\n' + validation.warnings.join('\n'));
  }

  return { ...defaultConfig, ...userConfig };
}
