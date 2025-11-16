/**
 * TypeScript bindings for jemach Julia Native library
 * Provides Julia code parsing and block detection functionality
 */

export enum BlockType {
  Function = "function",
  Macro = "macro",
  Module = "module",
  Struct = "struct",
  MutableStruct = "mutable_struct",
  Begin = "begin",
  Quote = "quote",
  Let = "let",
  For = "for",
  While = "while",
  If = "if",
  Try = "try",
  Unknown = "unknown",
}

export interface Block {
  blockType: BlockType;
  startLine: number;
  endLine: number;
  content: string;
}

export interface BlockDetectionResult {
  found: boolean;
  startLine?: number;
  endLine?: number;
}

/**
 * Julia parser class for code analysis
 */
export class JuliaParser {
  /**
   * Detect the type of Julia block at the given line
   */
  public detectBlockType(line: string): BlockType | null {
    const trimmed = line.trim();

    if (trimmed.startsWith("function ")) return BlockType.Function;
    if (trimmed.startsWith("macro ")) return BlockType.Macro;
    if (trimmed.startsWith("module ")) return BlockType.Module;
    if (trimmed.startsWith("mutable struct ")) return BlockType.MutableStruct;
    if (trimmed.startsWith("struct ")) return BlockType.Struct;
    if (trimmed.startsWith("begin")) return BlockType.Begin;
    if (trimmed.startsWith("quote")) return BlockType.Quote;
    if (trimmed.startsWith("let ")) return BlockType.Let;
    if (trimmed.startsWith("for ")) return BlockType.For;
    if (trimmed.startsWith("while ")) return BlockType.While;
    if (trimmed.startsWith("if ")) return BlockType.If;
    if (trimmed.startsWith("try")) return BlockType.Try;

    return null;
  }

  /**
   * Check if a line marks the end of a block
   */
  public isBlockEnd(line: string): boolean {
    return line.trim() === "end";
  }

  /**
   * Detect a Julia code block at the given cursor position
   */
  public detectBlock(code: string, cursorLine: number): BlockDetectionResult {
    const lines = code.split("\n");

    if (cursorLine >= lines.length) {
      return { found: false };
    }

    // Search backwards for block start
    let startLine = cursorLine;
    let blockType: BlockType | null = null;

    while (startLine >= 0) {
      blockType = this.detectBlockType(lines[startLine]);
      if (blockType !== null) break;
      startLine--;
    }

    if (blockType === null) {
      return { found: false };
    }

    // Search forwards for block end
    let endLine = cursorLine;
    let depth = 1;

    endLine++;
    while (endLine < lines.length) {
      if (this.detectBlockType(lines[endLine]) !== null) {
        depth++;
      } else if (this.isBlockEnd(lines[endLine])) {
        depth--;
        if (depth === 0) break;
      }
      endLine++;
    }

    if (depth !== 0) {
      return { found: false };
    }

    return {
      found: true,
      startLine,
      endLine,
    };
  }

  /**
   * Get the content of a block
   */
  public getBlockContent(
    code: string,
    startLine: number,
    endLine: number
  ): string {
    const lines = code.split("\n");

    if (endLine >= lines.length || startLine > endLine) {
      return "";
    }

    return lines.slice(startLine, endLine + 1).join("\n");
  }

  /**
   * Extract variable names from Julia code
   */
  public extractVariables(code: string): string[] {
    const variables: string[] = [];
    const lines = code.split("\n");

    for (const line of lines) {
      const trimmed = line.trim();

      // Simple variable detection (looking for assignments)
      const eqPos = trimmed.indexOf("=");
      if (eqPos > 0) {
        const varPart = trimmed.substring(0, eqPos).trim();

        // Skip if it's in a string
        if (!varPart.includes('"') && !varPart.includes("'")) {
          variables.push(varPart);
        }
      }
    }

    return variables;
  }
}

/**
 * Create a new Julia parser instance
 */
export function createParser(): JuliaParser {
  return new JuliaParser();
}

// Default export
export default {
  JuliaParser,
  createParser,
  BlockType,
};
