#!/bin/bash
set -euo pipefail
local input_folder="YOUR_INPUT_FOLDER_PATH"
log_info "Renaming package manager files to prevent conflicts..."
local renamed_count=0
local skipped_count=0

# Define package manager files to copy and rename
local package_files=(
    "Makefile"
    "makefile"
    "CMakeLists.txt"
)

# Rename exact filename matches (search recursively)
for filename in "${package_files[@]}"; do
    log_debug "Checking for fixed filename: $filename (recursively)"
    
    # Search recursively for the file
    while IFS= read -r -d '' file; do
        local backup_name="${filename}_backup"
        local backup_path="${file%/*}/$backup_name"
        
        # Skip if already renamed
        if [[ "$filename" == *"_backup" ]]; then
            log_debug "Skipping already renamed file: $filename"
            continue
        fi
        
        # Check if backup already exists
        if [[ -f "$backup_path" ]]; then
            log_warning "Backup already exists for: $file"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        # Rename the file
        if mv "$file" "$backup_path" 2>/dev/null; then
            log_success "Renamed: $file → $backup_name"
            renamed_count=$((renamed_count + 1))
        else
            log_error "Failed to rename: $file"
        fi
    done < <(find "$input_folder" -name "$filename" -type f -print0 2>/dev/null)
done
