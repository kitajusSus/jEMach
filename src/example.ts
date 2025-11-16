#!/usr/bin/env node
/**
 * Example usage of the jemach Julia Parser
 * 
 * This demonstrates how to use the TypeScript bindings to parse Julia code
 */

import { JuliaParser } from './index';

// Example Julia code
const juliaCode = `
function hello(name)
    println("Hello, $name!")
    x = 42
    y = x * 2
    return y
end

module MyModule
    struct Point
        x::Float64
        y::Float64
    end
end
`;

console.log('=== jemach Julia Parser Example ===\n');

// Create a parser instance
const parser = new JuliaParser();

// Detect a block at line 1 (inside the function)
console.log('1. Detecting block at line 1:');
const blockResult = parser.detectBlock(juliaCode, 1);
if (blockResult.found) {
    console.log(`   Found block from line ${blockResult.startLine} to ${blockResult.endLine}`);
    
    // Get the block content
    const content = parser.getBlockContent(
        juliaCode,
        blockResult.startLine!,
        blockResult.endLine!
    );
    console.log('   Block content:');
    console.log('   ' + content.split('\n').join('\n   '));
}

console.log('\n2. Detecting block types:');
const lines = juliaCode.split('\n');
lines.forEach((line, index) => {
    const blockType = parser.detectBlockType(line);
    if (blockType !== null) {
        console.log(`   Line ${index}: ${line.trim()} -> ${blockType}`);
    }
});

console.log('\n3. Extracting variables:');
const variables = parser.extractVariables(juliaCode);
console.log('   Found variables:', variables);

console.log('\n4. Checking for block end:');
const endLine = 'end';
const notEndLine = 'println("test")';
console.log(`   "${endLine}" is block end: ${parser.isBlockEnd(endLine)}`);
console.log(`   "${notEndLine}" is block end: ${parser.isBlockEnd(notEndLine)}`);

console.log('\n=== Example Complete ===');
