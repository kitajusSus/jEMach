#!/usr/bin/env bun
/**
 * jemach TypeScript CLI and utilities
 *
 * This provides command-line tools and utilities for enhanced Julia development
 * in Neovim with tmux integration.
 */

import { Command } from 'commander';
import * as tmux from './tmux-utils';
import * as julia from './julia-parser';
import * as config from './config';
import { readFileSync, writeFileSync } from 'fs';

const program = new Command();

program.name('jemach').description('jemach TypeScript utilities').version('1.0.0');

// Config validation command
program
  .command('validate-config')
  .description('Validate a jemach configuration file')
  .argument('<file>', 'Configuration file to validate (JSON)')
  .action((file: string) => {
    try {
      const content = readFileSync(file, 'utf-8');
      const userConfig = JSON.parse(content);
      const validation = config.validateConfig(userConfig);

      if (validation.valid) {
        console.log('✓ Configuration is valid');
        if (validation.warnings.length > 0) {
          console.log('\nWarnings:');
          validation.warnings.forEach(w => console.log(`  ⚠ ${w}`));
        }
        process.exit(0);
      } else {
        console.log('✗ Configuration has errors:');
        validation.errors.forEach(e => console.log(`  ✗ ${e}`));
        process.exit(1);
      }
    } catch (error) {
      console.error('Error reading or parsing config file:', error);
      process.exit(1);
    }
  });

// Tmux workspace setup
program
  .command('setup-tmux')
  .description('Setup a tmux workspace for Julia development')
  .option('-s, --session <name>', 'Session name', 'julia-dev')
  .option('-l, --layout <layout>', 'Split layout (horizontal|vertical|grid)', 'horizontal')
  .action(async options => {
    if (!tmux.isTmuxAvailable()) {
      console.error('✗ tmux is not available');
      process.exit(1);
    }

    console.log('Setting up Julia tmux workspace...');
    const success = await tmux.setupJuliaWorkspace({
      sessionName: options.session,
      splitLayout: options.layout,
    });

    if (success) {
      console.log('✓ Workspace setup complete');
      process.exit(0);
    } else {
      console.error('✗ Failed to setup workspace');
      process.exit(1);
    }
  });

// List Julia panes
program
  .command('list-julia-panes')
  .description('List tmux panes running Julia')
  .action(async () => {
    if (!tmux.isInTmuxSession()) {
      console.error('✗ Not in a tmux session');
      process.exit(1);
    }

    const panes = await tmux.findJuliaPanes();
    if (panes.length === 0) {
      console.log('No Julia panes found');
    } else {
      console.log('Julia panes:');
      panes.forEach(p => {
        console.log(`  ${p.id} (${p.current_command}) - ${p.width}x${p.height}`);
      });
    }
  });

// Validate Julia syntax
program
  .command('validate-julia')
  .description('Validate Julia code syntax')
  .argument('<file>', 'Julia file to validate')
  .action((file: string) => {
    try {
      const code = readFileSync(file, 'utf-8');
      const result = julia.validateJuliaSyntax(code);

      if (result.valid) {
        console.log('✓ Julia syntax is valid');
        process.exit(0);
      } else {
        console.log('✗ Julia syntax errors:');
        result.errors.forEach(e => {
          console.log(`  Line ${e.line + 1}: ${e.message}`);
        });
        process.exit(1);
      }
    } catch (error) {
      console.error('Error reading file:', error);
      process.exit(1);
    }
  });

// Format Julia code
program
  .command('format-julia')
  .description('Format Julia code')
  .argument('<file>', 'Julia file to format')
  .option('-i, --indent <size>', 'Indentation size', '4')
  .option('-o, --output <file>', 'Output file (defaults to input file)')
  .action((file: string, options) => {
    try {
      const code = readFileSync(file, 'utf-8');
      const formatted = julia.formatJuliaCode(code, {
        indentSize: parseInt(options.indent, 10),
      });

      const outputFile = options.output || file;
      writeFileSync(outputFile, formatted);
      console.log(`✓ Formatted ${file} -> ${outputFile}`);
      process.exit(0);
    } catch (error) {
      console.error('Error formatting file:', error);
      process.exit(1);
    }
  });

// Detect Julia blocks
program
  .command('detect-blocks')
  .description('Detect Julia code blocks in a file')
  .argument('<file>', 'Julia file to analyze')
  .action((file: string) => {
    try {
      const code = readFileSync(file, 'utf-8');
      const lines = code.split('\n');
      const blocks: julia.JuliaBlock[] = [];

      for (let i = 0; i < lines.length; i++) {
        const block = julia.detectJuliaBlock(lines, i);
        if (block && block.type !== 'unknown') {
          blocks.push(block);
          i = block.endLine; // Skip to end of block
        }
      }

      if (blocks.length === 0) {
        console.log('No code blocks found');
      } else {
        console.log(`Found ${blocks.length} code blocks:`);
        blocks.forEach(b => {
          console.log(`  ${b.type}: lines ${b.startLine + 1}-${b.endLine + 1}`);
        });
      }
    } catch (error) {
      console.error('Error reading file:', error);
      process.exit(1);
    }
  });

// Send code to Julia pane
program
  .command('send-to-julia')
  .description('Send code to a Julia tmux pane')
  .argument('<code>', 'Code to send')
  .option('-p, --pane <id>', 'Target pane ID (auto-detect if not specified)')
  .action(async (code: string, options) => {
    if (!tmux.isInTmuxSession()) {
      console.error('✗ Not in a tmux session');
      process.exit(1);
    }

    let paneId = options.pane;
    if (!paneId) {
      // Auto-detect Julia pane
      paneId = await tmux.getOrCreateJuliaPane();
      if (!paneId) {
        console.error('✗ Could not find or create Julia pane');
        process.exit(1);
      }
    }

    const success = await tmux.sendToPane(paneId, code);
    if (success) {
      console.log(`✓ Code sent to pane ${paneId}`);
      process.exit(0);
    } else {
      console.error('✗ Failed to send code');
      process.exit(1);
    }
  });

program.parse();
