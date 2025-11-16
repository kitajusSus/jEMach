#include <string>
#include <vector>
#include <cstring>
#include <algorithm>
#include <cctype>

extern "C" {

// Trim whitespace from string
static std::string trim(const std::string& str) {
    size_t start = 0;
    size_t end = str.length();
    
    while (start < end && std::isspace(static_cast<unsigned char>(str[start]))) {
        start++;
    }
    
    while (end > start && std::isspace(static_cast<unsigned char>(str[end - 1]))) {
        end--;
    }
    
    return str.substr(start, end - start);
}

// Check if a line starts a Julia block
static bool is_block_start(const std::string& line) {
    std::string trimmed = trim(line);
    
    // Check for various Julia block starters
    const char* patterns[] = {
        "function ", "macro ", "module ", "struct ", "mutable struct ",
        "begin", "quote", "let ", "for ", "while ", "if ", "try"
    };
    
    for (const char* pattern : patterns) {
        if (trimmed.find(pattern) == 0) {
            return true;
        }
    }
    
    return false;
}

// Check if a line is a block end
static bool is_block_end(const std::string& line) {
    std::string trimmed = trim(line);
    return trimmed == "end" || 
           trimmed.find("end ") == 0 ||
           trimmed.find("end,") == 0 ||
           trimmed.find("end;") == 0;
}

/**
 * Detect a Julia code block at the given cursor position
 * 
 * @param lines_ptr Pointer to array of line pointers
 * @param lines_len Number of lines
 * @param current_line Current cursor line (0-indexed)
 * @param out_start Output: start line of block
 * @param out_end Output: end line of block
 * @return 1 if block found, 0 otherwise
 */
int julia_detect_block(
    const char** lines_ptr,
    size_t lines_len,
    size_t current_line,
    size_t* out_start,
    size_t* out_end
) {
    if (current_line >= lines_len) {
        return 0;
    }
    
    // Convert C strings to C++ strings for easier manipulation
    std::vector<std::string> lines;
    lines.reserve(lines_len);
    for (size_t i = 0; i < lines_len; i++) {
        lines.push_back(std::string(lines_ptr[i]));
    }
    
    // Search backwards from current line to find block start
    size_t start_line = current_line;
    bool found_start = false;
    
    // Check current line first
    if (is_block_start(lines[current_line])) {
        start_line = current_line;
        found_start = true;
    } else {
        // Search backwards
        for (size_t i = current_line; i > 0; i--) {
            if (is_block_start(lines[i - 1])) {
                start_line = i - 1;
                found_start = true;
                break;
            }
        }
    }
    
    // If no block start found, return current line only
    if (!found_start) {
        *out_start = current_line;
        *out_end = current_line;
        return 1;
    }
    
    // Search forward for matching 'end'
    size_t end_line = start_line;
    int depth = 1;
    
    for (size_t i = start_line + 1; i < lines_len; i++) {
        if (is_block_start(lines[i])) {
            depth++;
        } else if (is_block_end(lines[i])) {
            depth--;
            if (depth == 0) {
                end_line = i;
                break;
            }
        }
    }
    
    *out_start = start_line;
    *out_end = end_line;
    
    return 1;
}

/**
 * Extract variables from Julia code
 * 
 * @param code_ptr Pointer to code string
 * @param code_len Length of code
 * @param out_count Output: number of variables found
 * @return 1 on success, 0 on failure
 */
int julia_extract_variables(
    const char* code_ptr,
    size_t code_len,
    size_t* out_count
) {
    std::string code(code_ptr, code_len);
    size_t count = 0;
    
    // Simple variable extraction - count assignment statements
    size_t pos = 0;
    while ((pos = code.find('=', pos)) != std::string::npos) {
        // Check if this is an assignment (not ==, !=, <=, >=)
        if (pos > 0 && pos < code.length() - 1) {
            char before = code[pos - 1];
            char after = code[pos + 1];
            
            if (before != '=' && before != '!' && before != '<' && before != '>' &&
                after != '=') {
                count++;
            }
        }
        pos++;
    }
    
    *out_count = count;
    return 1;
}

} // extern "C"
