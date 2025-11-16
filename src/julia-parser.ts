/**
 * Julia code parsing and analysis utilities
 */

export interface JuliaBlock {
  type: 'function' | 'module' | 'struct' | 'if' | 'for' | 'while' | 'try' | 'begin' | 'unknown';
  startLine: number;
  endLine: number;
  content: string;
}

/**
 * Detects Julia code blocks with smart detection
 */
export function detectJuliaBlock(lines: string[], currentLine: number): JuliaBlock | null {
  const line = lines[currentLine].trim();

  // Keywords that start blocks
  const blockStarters = {
    function: /^\s*function\s+/,
    module: /^\s*module\s+/,
    struct: /^\s*(?:mutable\s+)?struct\s+/,
    if: /^\s*if\s+/,
    for: /^\s*for\s+/,
    while: /^\s*while\s+/,
    try: /^\s*try\s*$/,
    begin: /^\s*begin\s*$/,
  };

  // Find block type
  let blockType: JuliaBlock['type'] = 'unknown';
  for (const [type, pattern] of Object.entries(blockStarters)) {
    if (pattern.test(line)) {
      blockType = type as JuliaBlock['type'];
      break;
    }
  }

  if (blockType === 'unknown') {
    // Single line expression
    return {
      type: 'unknown',
      startLine: currentLine,
      endLine: currentLine,
      content: lines[currentLine],
    };
  }

  // Find matching 'end'
  let depth = 1;
  let endLine = currentLine;

  for (let i = currentLine + 1; i < lines.length; i++) {
    const l = lines[i].trim();
    
    // Check for nested block starters
    for (const pattern of Object.values(blockStarters)) {
      if (pattern.test(l)) {
        depth++;
        break;
      }
    }

    // Check for 'end'
    if (/^\s*end\s*$/.test(l) || /^\s*end\s*[,;]/.test(l)) {
      depth--;
      if (depth === 0) {
        endLine = i;
        break;
      }
    }
  }

  return {
    type: blockType,
    startLine: currentLine,
    endLine: endLine,
    content: lines.slice(currentLine, endLine + 1).join('\n'),
  };
}

/**
 * Extracts variable definitions from Julia code
 */
export function extractVariables(code: string): Array<{ name: string; line: number }> {
  const variables: Array<{ name: string; line: number }> = [];
  const lines = code.split('\n');

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    
    // Simple assignment pattern: var = value
    const match = line.match(/^\s*([a-zA-Z_][a-zA-Z0-9_!]*)\s*=/);
    if (match) {
      variables.push({
        name: match[1],
        line: i,
      });
    }
  }

  return variables;
}

/**
 * Validates Julia syntax (basic check)
 */
export function validateJuliaSyntax(code: string): {
  valid: boolean;
  errors: Array<{ line: number; message: string }>;
} {
  const errors: Array<{ line: number; message: string }> = [];
  const lines = code.split('\n');

  let blockDepth = 0;
  const blockStack: Array<{ type: string; line: number }> = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();

    // Track block depth
    if (/^\s*(?:function|module|struct|if|for|while|try|begin)\s+/.test(line)) {
      const type = line.match(/^\s*(\w+)/)?.[1] || 'unknown';
      blockStack.push({ type, line: i });
      blockDepth++;
    }

    if (/^\s*end\s*$/.test(line)) {
      blockDepth--;
      blockStack.pop();
      
      if (blockDepth < 0) {
        errors.push({
          line: i,
          message: 'Unexpected "end" without matching block start',
        });
      }
    }
  }

  // Check for unclosed blocks
  if (blockDepth > 0) {
    for (const block of blockStack) {
      errors.push({
        line: block.line,
        message: `Unclosed ${block.type} block`,
      });
    }
  }

  return {
    valid: errors.length === 0,
    errors,
  };
}

/**
 * Formats Julia code (basic formatting)
 */
export function formatJuliaCode(code: string, options: { indentSize: number } = { indentSize: 4 }): string {
  const lines = code.split('\n');
  const formatted: string[] = [];
  let indentLevel = 0;

  for (const line of lines) {
    const trimmed = line.trim();

    // Decrease indent for 'end'
    if (/^\s*end\s*$/.test(line)) {
      indentLevel = Math.max(0, indentLevel - 1);
    }

    // Add formatted line
    const indent = ' '.repeat(indentLevel * options.indentSize);
    formatted.push(indent + trimmed);

    // Increase indent for block starters
    if (/^\s*(?:function|module|struct|if|for|while|try|begin)\s+/.test(line)) {
      indentLevel++;
    }
  }

  return formatted.join('\n');
}
