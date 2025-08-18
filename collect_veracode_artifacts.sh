#!/bin/bash

# Java and .NET Artifact Collector
# This script analyzes artifact folders and collects Java compiled applications (.jar, .war, .ear)
# and .NET compiled applications (.dll) while excluding test artifacts and 3rd party libraries
# Language detection is automatic based on file types found

set -euo pipefail

# Configuration
SCRIPT_NAME=$(basename "$0")
DEBUG=${DEBUG:-false}
VERBOSE=${VERBOSE:-false}

# Initialize global arrays
COMPILED_APPS=()
THIRD_PARTY_LIBS=()
TEST_ARTIFACTS=()
INVALID_ARCHIVES=()

# .NET specific arrays
DOTNET_DLLS=()
DOTNET_PDBS=()
MISSING_PDBS=()

# Language detection
DETECTED_LANGUAGE=""

# Initialize count variables
COMPILED_COUNT=0
THIRD_PARTY_COUNT=0
TEST_COUNT=0
INVALID_COUNT=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] <artifact_folder>

This script automatically detects and collects Java (.jar, .war, .ear) and .NET (.dll) artifacts
from Azure DevOps artifact folders. Language detection is automatic based on file types found.

Options:
    -d, --debug          Enable debug output
    -v, --verbose        Enable verbose output
    -h, --help           Show this help message
    -o, --output         Specify output folder (default: ./collected_artifacts)

Arguments:
    artifact_folder       Path to the Azure DevOps artifact folder to analyze
    output_folder         Optional: Path where to collect the artifacts

Examples:
    $SCRIPT_NAME -d /path/to/artifacts
    $SCRIPT_NAME -v -o /custom/output /path/to/artifacts
    $SCRIPT_NAME --debug --verbose /path/to/artifacts

Environment Variables:
    DEBUG=true           Enable debug mode
    VERBOSE=true         Enable verbose mode

Supported Languages:
    Java: .jar, .war, .ear files
    .NET: .dll files (with .pdb files when available)
EOF
}

# Function to check if a file is a valid Java archive
is_valid_java_archive() {
    local file_path="$1"
    local file_type="$2"
    
    log_debug "Validating Java archive: $file_path (type: $file_type)"
    
    if [[ ! -f "$file_path" ]]; then
        log_debug "File does not exist: $file_path"
        return 1
    fi
    
    # Check if file is readable
    if [[ ! -r "$file_path" ]]; then
        log_debug "File is not readable: $file_path"
        return 1
    fi
    
    # Check file size (skip empty files)
    local file_size=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null || echo "0")
    if [[ "$file_size" -eq 0 ]]; then
        log_debug "File is empty: $file_path"
        return 1
    fi
    
    # Validate archive structure based on type
    case "$file_type" in
        "jar")
            # Check if it's a valid ZIP/JAR file
            if unzip -t "$file_path" >/dev/null 2>&1; then
                log_debug "Valid JAR file: $file_path"
                return 0
            else
                log_debug "Invalid JAR file (not a valid ZIP): $file_path"
                return 1
            fi
            ;;
        "war")
            # Check if it's a valid ZIP/WAR file
            if unzip -t "$file_path" >/dev/null 2>&1; then
                log_debug "Valid WAR file: $file_path"
                return 0
            else
                log_debug "Invalid WAR file (not a valid ZIP): $file_path"
                return 1
            fi
            ;;
        "ear")
            # Check if it's a valid ZIP/EAR file
            if unzip -t "$file_path" >/dev/null 2>&1; then
                log_debug "Valid EAR file: $file_path"
                return 0
            else
                log_debug "Invalid EAR file (not a valid ZIP): $file_path"
                return 1
            fi
            ;;
        *)
            log_debug "Unknown file type: $file_type"
            return 1
            ;;
    esac
}

# Function to check if a JAR contains 3rd party libraries
contains_third_party_libs() {
    local jar_path="$1"
    
    log_debug "Checking if JAR contains 3rd party libraries: $jar_path"
    
    # Extract and check for common 3rd party library patterns
    local temp_dir=$(mktemp -d)
    local has_third_party=false
    
    if unzip -q "$jar_path" -d "$temp_dir" 2>/dev/null; then
        # First, check if this looks like a compiled application
        local has_main_class=false
        local has_application_structure=false
        
        # Check for main class in manifest
        if [[ -f "$temp_dir/META-INF/MANIFEST.MF" ]]; then
            if grep -q "Main-Class:" "$temp_dir/META-INF/MANIFEST.MF" >/dev/null 2>&1; then
                has_main_class=true
                log_debug "JAR has a main class - likely a compiled application"
            fi
        fi
        
        # Check for application-like structure (not just library classes)
        local class_files=($(find "$temp_dir" -name "*.class" -type f))
        local total_classes=${#class_files[@]}
        
        if [[ $total_classes -gt 0 ]]; then
            # Count classes that look like application classes vs library classes
            local app_like_classes=0
            local lib_like_classes=0
            
            for class_file in "${class_files[@]}"; do
                local class_name=$(basename "$class_file" .class)
                # Simple heuristic: application classes often have descriptive names
                if [[ "$class_name" =~ ^[A-Z][a-zA-Z0-9]*$ ]] && [[ ! "$class_name" =~ (Util|Helper|Factory|Manager|Service|Config|Constants)$ ]]; then
                    ((app_like_classes++))
                else
                    ((lib_like_classes++))
                fi
            done
            
            # If it has more application-like classes, it's likely a compiled app
            if [[ $app_like_classes -gt $lib_like_classes ]]; then
                has_application_structure=true
                log_debug "JAR has more application-like classes ($app_like_classes) than library-like classes ($lib_like_classes)"
            fi
        fi
        
        # If it looks like a compiled application, it's not a 3rd party library
        if [[ "$has_main_class" == "true" ]] || [[ "$has_application_structure" == "true" ]]; then
            has_third_party=false
            log_debug "JAR appears to be a compiled application, not a 3rd party library"
        else
            # Check for common 3rd party library patterns
            if [[ -d "$temp_dir/META-INF" ]]; then
                if [[ -d "$temp_dir/META-INF/maven" ]] || [[ -d "$temp_dir/META-INF/services" ]]; then
                    has_third_party=true
                    log_debug "JAR contains Maven or services information, likely a 3rd party library"
                fi
            fi
            
            # Check for common 3rd party package names (but exclude if it has application structure)
            if find "$temp_dir" -name "*.class" -type f | grep -q -E "(org\.|com\.|net\.|io\.|java\.|javax\.)" >/dev/null 2>&1; then
                has_third_party=true
                log_debug "JAR contains classes with common 3rd party package names"
            fi
        fi
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    if [[ "$has_third_party" == "true" ]]; then
        log_debug "JAR $jar_path contains 3rd party libraries"
        return 0
    else
        log_debug "JAR $jar_path does not contain 3rd party libraries"
        return 1
    fi
}

# Function to check if a file is a test artifact (works for both Java and .NET)
is_test_artifact() {
    local file_path="$1"
    local file_type="${2:-auto}"  # "jar", "dll", or "auto" for automatic detection
    
    log_debug "Checking if file is a test artifact: $file_path (type: $file_type)"
    
    # Auto-detect file type if not specified
    if [[ "$file_type" == "auto" ]]; then
        local extension="${file_path##*.}"
        if [[ "$extension" == "dll" ]]; then
            file_type="dll"
        elif [[ "$extension" == "jar" ]]; then
            file_type="jar"
        else
            file_type="unknown"
        fi
    fi
    
    # Check filename patterns that suggest test artifacts (common for both Java and .NET)
    local filename=$(basename "$file_path")
    if [[ "$filename" =~ test ]] || \
       [[ "$filename" =~ Test ]] || \
       [[ "$filename" =~ TEST ]] || \
       [[ "$filename" =~ -test ]] || \
       [[ "$filename" =~ -tests ]] || \
       [[ "$filename" =~ -test- ]] || \
       [[ "$filename" =~ -tests- ]]; then
        log_debug "File appears to be a test artifact based on filename: $filename"
        return 0
    fi
    
    # For .NET DLLs, also check if it's in a test-related directory
    if [[ "$file_type" == "dll" ]]; then
        local relative_path="${file_path#$ARTIFACT_FOLDER/}"
        if [[ "$relative_path" =~ [Tt]est ]] || \
           [[ "$relative_path" =~ [Tt]ests ]] || \
           [[ "$relative_path" =~ [Tt]esting ]]; then
            log_debug ".NET DLL is in a test-related directory: $relative_path"
            return 0
        fi
    fi
    
    # For Java JARs, check if it's a valid JAR and look inside for test indicators
    if [[ "$file_type" == "jar" ]] && is_valid_java_archive "$file_path" "jar"; then
        local temp_dir=$(mktemp -d)
        local is_test=false
        
        if unzip -q "$file_path" -d "$temp_dir" 2>/dev/null; then
            # Look for test-related patterns in the JAR - be more specific
            local test_class_count=$(find "$temp_dir" -name "*.class" -type f | grep -E "(Test|test|TEST)" | wc -l)
            local total_class_count=$(find "$temp_dir" -name "*.class" -type f | wc -l)
            
            # Only consider it a test artifact if it's primarily test classes
            if [[ $test_class_count -gt 0 ]] && [[ $((test_class_count * 100 / total_class_count)) -gt 50 ]]; then
                is_test=true
                log_debug "JAR contains primarily test-related classes ($test_class_count/$total_class_count)"
            fi
            
            # Check for test dependencies in META-INF - be more specific
            if [[ -f "$temp_dir/META-INF/MANIFEST.MF" ]]; then
                if grep -q -E "(test|Test|TEST)" "$temp_dir/META-INF/MANIFEST.MF" | grep -v -E "(Created-By|Built-By|Build-By)" >/dev/null 2>&1; then
                    is_test=true
                    log_debug "JAR manifest contains test-related information"
                fi
            fi
        fi
        
        # Cleanup
        rm -rf "$temp_dir"
        
        if [[ "$is_test" == "true" ]]; then
            log_debug "JAR $file_path is identified as a test artifact"
            return 0
        fi
    fi
    
    log_debug "File $file_path is not identified as a test artifact"
    return 1
}

# Function to check if a .NET DLL is a 3rd party library
is_third_party_dotnet() {
    local dll_path="$1"
    
    log_debug "Checking if .NET DLL is a 3rd party library: $dll_path"
    
    local filename=$(basename "$dll_path")
    local relative_path="${dll_path#$ARTIFACT_FOLDER/}"
    
    # Check if it's in a lib or packages directory (likely 3rd party)
    if [[ "$relative_path" =~ lib/ ]] || \
       [[ "$relative_path" =~ packages/ ]] || \
       [[ "$relative_path" =~ bin/.*/lib ]] || \
       [[ "$relative_path" =~ obj/.*/lib ]]; then
        log_debug ".NET DLL is in a library directory: $relative_path"
        return 0
    fi
    
    # Check for common 3rd party DLL patterns
    if [[ "$filename" =~ ^(System\.|Microsoft\.|Newtonsoft\.|log4net|NUnit|MSTest|Moq|Castle\.|Autofac|Unity|Ninject|StructureMap) ]]; then
        log_debug ".NET DLL appears to be a 3rd party library based on filename: $filename"
        return 0
    fi
    
    # Check if it's a NuGet package (look for version numbers in filename)
    if [[ "$filename" =~ \.[0-9]+\.[0-9]+ ]]; then
        log_debug ".NET DLL appears to be a NuGet package based on version in filename: $filename"
        return 0
    fi
    
    log_debug ".NET DLL $dll_path is not identified as a 3rd party library"
    return 1
}

# Function to find corresponding PDB files for .NET DLLs
find_pdb_files() {
    local dll_path="$1"
    
    log_debug "Looking for PDB file for: $dll_path"
    
    local dll_dir=$(dirname "$dll_path")
    local dll_name=$(basename "$dll_path" .dll)
    local pdb_path="$dll_dir/$dll_name.pdb"
    
    if [[ -f "$pdb_path" ]]; then
        log_debug "Found PDB file: $pdb_path"
        DOTNET_PDBS+=("$pdb_path")
        return 0
    else
        log_debug "No PDB file found for: $dll_path"
        MISSING_PDBS+=("$dll_path")
        return 0  # Don't treat missing PDB as an error
    fi
}

# Function to analyze artifact folder
analyze_artifact_folder() {
    local artifact_folder="$1"
    
    log_info "Analyzing artifact folder: $artifact_folder"
    
    if [[ ! -d "$artifact_folder" ]]; then
        log_error "Artifact folder does not exist: $artifact_folder"
        exit 1
    fi
    
    # Find all Java archive files
    local jar_files=()
    local war_files=()
    local ear_files=()
    local all_archives=()
    
    # Find all .NET DLL files
    local dll_files=()
    
    log_debug "Searching for Java and .NET files..."
    
    # Find JAR files
    while IFS= read -r -d '' file; do
        jar_files+=("$file")
        all_archives+=("$file")
        log_verbose "Found JAR file: $file"
    done < <(find "$artifact_folder" -name "*.jar" -type f -print0 2>/dev/null)
    
    # Find WAR files
    while IFS= read -r -d '' file; do
        war_files+=("$file")
        all_archives+=("$file")
        log_verbose "Found WAR file: $file"
    done < <(find "$artifact_folder" -name "*.war" -type f -print0 2>/dev/null)
    
    # Find EAR files
    while IFS= read -r -d '' file; do
        ear_files+=("$file")
        all_archives+=("$file")
        log_verbose "Found EAR file: $file"
    done < <(find "$artifact_folder" -name "*.ear" -type f -print0 2>/dev/null)
    
    # Find DLL files
    while IFS= read -r -d '' file; do
        dll_files+=("$file")
        log_verbose "Found DLL file: $file"
    done < <(find "$artifact_folder" -name "*.dll" -type f -print0 2>/dev/null)
    
    # Determine detected language
    if [[ ${#dll_files[@]} -gt 0 ]] && [[ ${#all_archives[@]} -gt 0 ]]; then
        DETECTED_LANGUAGE="mixed"
        log_info "Detected mixed Java and .NET project"
    elif [[ ${#dll_files[@]} -gt 0 ]]; then
        DETECTED_LANGUAGE="dotnet"
        log_info "Detected .NET project"
    elif [[ ${#all_archives[@]} -gt 0 ]]; then
        DETECTED_LANGUAGE="java"
        log_info "Detected Java project"
    else
        DETECTED_LANGUAGE="none"
        log_info "No Java or .NET artifacts found"
    fi
    
    log_info "Found ${#jar_files[@]} JAR files, ${#war_files[@]} WAR files, ${#ear_files[@]} EAR files, ${#dll_files[@]} DLL files"
    
    # Analyze Java archives if present
    if [[ ${#all_archives[@]} -gt 0 ]]; then
        analyze_java_artifacts "$artifact_folder" "${all_archives[@]}"
    fi
    
    # Analyze .NET DLLs if present
    if [[ ${#dll_files[@]} -gt 0 ]]; then
        analyze_dotnet_artifacts "$artifact_folder" "${dll_files[@]}"
    fi
}

# Function to analyze Java artifacts
analyze_java_artifacts() {
    local artifact_folder="$1"
    shift
    local all_archives=("$@")
    
    log_info "=== Analyzing Java Artifacts ==="
    
    # Analyze each archive
    local compiled_apps=()
    local third_party_libs=()
    local test_artifacts=()
    local invalid_archives=()
    
    # Ensure local arrays are properly initialized
    compiled_apps=()
    third_party_libs=()
    test_artifacts=()
    invalid_archives=()
    
    # Check if we have any archives to analyze
    if [[ ${#all_archives[@]} -eq 0 ]]; then
        log_info "No Java archive files found in the artifact folder."
        return
    fi
    
    for archive in "${all_archives[@]}"; do
        local filename=$(basename "$archive")
        local extension="${filename##*.}"
        local relative_path="${archive#$artifact_folder/}"
        
        log_debug "Analyzing Java archive: $relative_path"
        
        # Validate the archive
        if ! is_valid_java_archive "$archive" "$extension"; then
            log_warning "Invalid or corrupted archive: $relative_path"
            invalid_archives+=("$archive")
            continue
        fi
        
        # Check if it's a test artifact
        if is_test_artifact "$archive" "jar"; then
            log_info "Skipping test artifact: $relative_path"
            test_artifacts+=("$archive")
            continue
        fi
        
        # For JAR files, determine if they're 3rd party libraries or compiled applications
        if [[ "$extension" == "jar" ]]; then
            # Check if this JAR is in a WEB-INF/lib directory (likely a 3rd party dependency)
            if [[ "$relative_path" =~ WEB-INF/lib/ ]] || [[ "$relative_path" =~ lib/ ]]; then
                log_info "Skipping dependency JAR (already included in main application): $relative_path"
                third_party_libs+=("$archive")
            # Check if this is a build tool JAR (Maven wrapper, Gradle wrapper, etc.)
            elif [[ "$relative_path" =~ \.mvn/wrapper/ ]] || \
                 [[ "$relative_path" =~ gradle/wrapper/ ]] || \
                 [[ "$relative_path" =~ gradle-wrapper\.jar$ ]] || \
                 [[ "$relative_path" =~ maven-wrapper\.jar$ ]] || \
                 [[ "$relative_path" =~ gradle-wrapper\.jar$ ]] || \
                 [[ "$filename" =~ ^gradle-wrapper\.jar$ ]] || \
                 [[ "$filename" =~ ^maven-wrapper\.jar$ ]]; then
                log_info "Skipping build tool JAR: $relative_path"
                third_party_libs+=("$archive")
            elif contains_third_party_libs "$archive"; then
                log_info "Archive contains 3rd party libraries: $relative_path"
                third_party_libs+=("$archive")
            else
                log_info "Compiled application found: $relative_path"
                compiled_apps+=("$archive")
            fi
        else
            # WAR and EAR files are always compiled applications
            log_info "Compiled application found: $relative_path"
            compiled_apps+=("$archive")
        fi
    done
    
    # Summary
    log_info "=== Java Analysis Summary ==="
    log_info "Total Java archives found: ${#all_archives[@]}"
    
    # Count arrays safely
    local compiled_count=${#compiled_apps[@]:-0}
    local third_party_count=${#third_party_libs[@]:-0}
    local test_count=${#test_artifacts[@]:-0}
    local invalid_count=${#invalid_archives[@]:-0}
    
    log_info "Compiled applications: $compiled_count"
    log_info "3rd party libraries: $third_party_count"
    log_info "Test artifacts (skipped): $test_count"
    log_info "Invalid archives: $invalid_count"
    
    # Store results for collection (safely)
    if [[ ${#compiled_apps[@]} -gt 0 ]]; then
        COMPILED_APPS=("${compiled_apps[@]}")
    else
        COMPILED_APPS=()
    fi
    
    if [[ ${#third_party_libs[@]} -gt 0 ]]; then
        THIRD_PARTY_LIBS=("${third_party_libs[@]}")
    else
        THIRD_PARTY_LIBS=()
    fi
    
    if [[ ${#test_artifacts[@]} -gt 0 ]]; then
        TEST_ARTIFACTS=("${test_artifacts[@]}")
    else
        TEST_ARTIFACTS=()
    fi
    
    if [[ ${#invalid_archives[@]} -gt 0 ]]; then
        INVALID_ARCHIVES=("${invalid_archives[@]}")
    else
        INVALID_ARCHIVES=()
    fi
    
    # Store counts for summary
    COMPILED_COUNT=$compiled_count
    THIRD_PARTY_COUNT=$third_party_count
    TEST_COUNT=$test_count
    INVALID_COUNT=$invalid_count
}

# Function to analyze .NET artifacts
analyze_dotnet_artifacts() {
    local artifact_folder="$1"
    shift
    local dll_files=("$@")
    
    log_info "=== Analyzing .NET Artifacts ==="
    
    # Analyze each DLL
    local compiled_apps=()
    local third_party_libs=()
    local test_artifacts=()
    
    # Ensure local arrays are properly initialized
    compiled_apps=()
    third_party_libs=()
    test_artifacts=()
    
    # Check if we have any DLLs to analyze
    if [[ ${#dll_files[@]} -eq 0 ]]; then
        log_info "No .NET DLL files found in the artifact folder."
        return
    fi
    
    for dll in "${dll_files[@]}"; do
        local filename=$(basename "$dll")
        local relative_path="${dll#$artifact_folder/}"
        
        log_debug "Analyzing .NET DLL: $relative_path"
        
        # Check if it's a test artifact
        if is_test_artifact "$dll" "dll"; then
            log_info "Skipping test artifact: $relative_path"
            test_artifacts+=("$dll")
            continue
        fi
        
        # Check if it's a 3rd party library (for classification only)
        if is_third_party_dotnet "$dll"; then
            log_info "3rd party library identified: $relative_path (will be collected)"
            third_party_libs+=("$dll")
            # IMPORTANT: 3rd party DLLs are still collected for .NET applications
            compiled_apps+=("$dll")
        else
            # If it's not a test artifact or 3rd party library, it's a 1st party compiled application
            log_info "1st party compiled .NET application found: $relative_path"
            compiled_apps+=("$dll")
        fi
        
        # Look for corresponding PDB file for ALL DLLs (both 1st and 3rd party)
        find_pdb_files "$dll"
    done
    
    # Summary
    log_info "=== .NET Analysis Summary ==="
    log_info "Total .NET DLLs found: ${#dll_files[@]}"
    
    # Count arrays safely
    local compiled_count=${#compiled_apps[@]:-0}
    local third_party_count=${#third_party_libs[@]:-0}
    local test_count=${#test_artifacts[@]:-0}
    local pdb_count=${#DOTNET_PDBS[@]:-0}
    local missing_pdb_count=${#MISSING_PDBS[@]:-0}
    
    log_info "Compiled applications (1st + 3rd party): $compiled_count"
    log_info "3rd party libraries: $third_party_count"
    log_info "Test artifacts (skipped): $test_count"
    log_info "PDB files found: $pdb_count"
    log_info "Missing PDB files: $missing_pdb_count"
    
    # Store results for collection (safely)
    if [[ ${#compiled_apps[@]} -gt 0 ]]; then
        DOTNET_DLLS=("${compiled_apps[@]}")
    else
        DOTNET_DLLS=()
    fi
    
    # Add .NET DLLs to the main compiled apps array
    if [[ ${#compiled_apps[@]} -gt 0 ]]; then
        COMPILED_APPS+=("${compiled_apps[@]}")
        # Update the count (ensure it's initialized)
        COMPILED_COUNT=${COMPILED_COUNT:-0}
        COMPILED_COUNT=$((COMPILED_COUNT + compiled_count))
    fi
    
    # Add .NET 3rd party libs to the main array
    if [[ ${#third_party_libs[@]} -gt 0 ]]; then
        THIRD_PARTY_LIBS+=("${third_party_libs[@]}")
        # Update the count (ensure it's initialized)
        THIRD_PARTY_COUNT=${THIRD_PARTY_COUNT:-0}
        THIRD_PARTY_COUNT=$((THIRD_PARTY_COUNT + third_party_count))
    fi
    
    # Add .NET test artifacts to the main array
    if [[ ${#test_artifacts[@]} -gt 0 ]]; then
        TEST_ARTIFACTS+=("${test_artifacts[@]}")
        # Update the count (ensure it's initialized)
        TEST_COUNT=${TEST_COUNT:-0}
        TEST_COUNT=$((TEST_COUNT + test_count))
    fi
    
    # Store .NET specific counts
    DOTNET_COMPILED_COUNT=$compiled_count
    DOTNET_THIRD_PARTY_COUNT=$third_party_count
    DOTNET_TEST_COUNT=$test_count
    DOTNET_PDB_COUNT=$pdb_count
    DOTNET_MISSING_PDB_COUNT=$missing_pdb_count
}

# Function to collect artifacts
collect_artifacts() {
    local output_folder="$1"
    
    log_info "Collecting artifacts to: $output_folder"
    
    # Create output directory
    mkdir -p "$output_folder"
    
    local collected_count=0
    
    # Collect compiled applications (both Java and .NET)
    if [[ ${#COMPILED_APPS[@]} -gt 0 ]]; then
        log_info "Collecting ${#COMPILED_APPS[@]} compiled applications..."
        
        # Track unique filenames to avoid duplicates
        local duplicate_count=0
        local unique_files=()
        
        for app in "${COMPILED_APPS[@]}"; do
            local filename=$(basename "$app")
            local dest_path="$output_folder/$filename"
            
            # Check if we already have this filename in the output directory
            if [[ -f "$dest_path" ]]; then
                log_info "Skipping duplicate: $filename (already collected)"
                ((duplicate_count++))
                continue
            fi
            
            if cp "$app" "$dest_path" 2>/dev/null; then
                log_success "Collected: $filename"
                unique_files+=("$filename")
                ((collected_count++))
            else
                log_error "Failed to collect: $filename"
            fi
        done
        
        if [[ $duplicate_count -gt 0 ]]; then
            log_info "Skipped $duplicate_count duplicate files"
        fi
        
        # Update the count to reflect actual unique files collected
        collected_count=${#unique_files[@]}
    fi
    
    # Collect .NET PDB files if available
    if [[ ${#DOTNET_PDBS[@]} -gt 0 ]]; then
        log_info "Collecting ${#DOTNET_PDBS[@]} PDB files..."
        
        for pdb in "${DOTNET_PDBS[@]}"; do
            local filename=$(basename "$pdb")
            local dest_path="$output_folder/$filename"
            
            # Check if we already have this filename in the output directory
            if [[ -f "$dest_path" ]]; then
                log_info "Skipping duplicate PDB: $filename (already collected)"
                continue
            fi
            
            if cp "$pdb" "$dest_path" 2>/dev/null; then
                log_success "Collected PDB: $filename"
                ((collected_count++))
            else
                log_error "Failed to collect PDB: $filename"
            fi
        done
    fi
    
    # Show warnings about missing PDB files
    if [[ ${#MISSING_PDBS[@]} -gt 0 ]]; then
        log_warning "=== PDB Files Missing ==="
        log_warning "The following .NET DLLs are missing PDB files:"
        for dll in "${MISSING_PDBS[@]}"; do
            local filename=$(basename "$dll")
            log_warning "  - $filename"
        done
        log_warning "Scan accuracy may be affected without PDB files."
        log_warning "Consider enabling PDB generation in your build configuration."
    fi
    
    # If no compiled applications found, finish gracefully
    if [[ ${#COMPILED_APPS[@]} -eq 0 ]]; then
        log_warning "No compiled applications found in the artifact folder."
        log_info "3rd party libraries are not collected when no compiled applications are present."
        log_info "Script will finish gracefully."
    else
        # Check if we have main application files that contain dependencies
        local has_main_app=false
        for app in "${COMPILED_APPS[@]}"; do
            local app_ext="${app##*.}"
            if [[ "$app_ext" == "war" ]] || [[ "$app_ext" == "ear" ]]; then
                has_main_app=true
                log_info "Main application found: $(basename "$app") - this contains all dependencies"
                break
            fi
        done
        
        if [[ "$has_main_app" == "true" ]]; then
            log_info "Dependency JARs in WEB-INF/lib are already included in the main application"
            log_info "Only the main application file(s) will be collected"
        fi
    fi
    
    # Create collection summary
    local summary_file="$output_folder/collection_summary.txt"
    {
        echo "Java and .NET Artifact Collection Summary"
        echo "Generated: $(date)"
        echo "Source folder: $ARTIFACT_FOLDER"
        echo "Detected language: $DETECTED_LANGUAGE"
        echo ""
        echo "Compiled applications collected: $collected_count"
        if [[ "$DETECTED_LANGUAGE" == "dotnet" ]] || [[ "$DETECTED_LANGUAGE" == "mixed" ]]; then
            echo "3rd party libraries collected: ${THIRD_PARTY_COUNT:-0}"
        else
            echo "3rd party libraries collected: 0"
        fi
        echo "Test artifacts skipped: ${TEST_COUNT:-0}"
        echo "Invalid archives found: ${INVALID_COUNT:-0}"
        
        # Add .NET specific information
        if [[ "$DETECTED_LANGUAGE" == "dotnet" ]] || [[ "$DETECTED_LANGUAGE" == "mixed" ]]; then
            echo ""
            echo "=== .NET Specific Information ==="
            echo "PDB files collected: ${DOTNET_PDB_COUNT:-0}"
            echo "Missing PDB files: ${DOTNET_MISSING_PDB_COUNT:-0}"
        fi
        
        echo ""
        echo "Total files collected: $collected_count"
        echo ""
        if [[ $collected_count -gt 0 ]]; then
            echo "Compiled applications:"
            # Show only unique collected files, not all discovered files
            local temp_file=$(mktemp)
            for app in "${COMPILED_APPS[@]}"; do
                local filename=$(basename "$app")
                echo "$filename" >> "$temp_file"
            done
            # Sort and show unique filenames
            sort -u "$temp_file" | while read -r filename; do
                echo "  - $filename"
            done
            rm -f "$temp_file"
            
            # Show PDB files if any were collected
            if [[ ${#DOTNET_PDBS[@]} -gt 0 ]]; then
                echo ""
                echo "PDB files:"
                for pdb in "${DOTNET_PDBS[@]}"; do
                    local filename=$(basename "$pdb")
                    echo "  - $filename"
                done
            fi
        else
            echo "No compiled applications found - script completed gracefully"
        fi
        
        # Show 3rd party libraries (should always be 0 since we don't collect them)
        echo ""
        echo "3rd party libraries:"
        if [[ "$DETECTED_LANGUAGE" == "dotnet" ]] || [[ "$DETECTED_LANGUAGE" == "mixed" ]]; then
            if [[ ${#THIRD_PARTY_LIBS[@]} -gt 0 ]]; then
                echo "  - All 3rd party DLLs are collected for .NET applications:"
                for third_party_lib in "${THIRD_PARTY_LIBS[@]}"; do
                    echo "    * $(basename "$third_party_lib")"
                done
            else
                echo "  - All 3rd party DLLs are collected for .NET applications"
            fi
        else
            echo "  - None collected (dependencies are included in main applications)"
        fi
        
        # Show test artifacts that were skipped
        echo ""
        echo "Test artifacts skipped:"
        if [[ ${#TEST_ARTIFACTS[@]} -gt 0 ]]; then
            for test_artifact in "${TEST_ARTIFACTS[@]}"; do
                echo "  - $(basename "$test_artifact")"
            done
        else
            echo "  - None found"
        fi
        
        # Show invalid archives that were found
        echo ""
        echo "Invalid archives found:"
        if [[ ${#INVALID_ARCHIVES[@]} -gt 0 ]]; then
            for invalid_archive in "${INVALID_ARCHIVES[@]}"; do
                echo "  - $(basename "$invalid_archive")"
            done
        else
            echo "  - None found"
        fi
        
        # Show missing PDB warnings if applicable
        if [[ ${#MISSING_PDBS[@]} -gt 0 ]]; then
            echo ""
            echo "=== WARNING: Missing PDB Files ==="
            echo "The following .NET DLLs are missing PDB files:"
            for dll in "${MISSING_PDBS[@]}"; do
                echo "  - $(basename "$dll")"
            done
            echo ""
            echo "Scan accuracy may be affected without PDB files."
            echo "Consider enabling PDB generation in your build configuration."
        fi
    } > "$summary_file"
    
    if [[ $collected_count -gt 0 ]]; then
        log_success "Collection complete! Collected $collected_count files"
    else
        log_warning "No files were collected - no compiled applications found"
    fi
    log_info "Summary written to: $summary_file"
}

# Main function
main() {
    # Parse command line arguments
    local artifact_folder=""
    local output_folder="./collected_artifacts"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--debug)
                DEBUG=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -o|--output)
                output_folder="$2"
                shift 2
                ;;
            -*)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [[ -z "$artifact_folder" ]]; then
                    artifact_folder="$1"
                else
                    log_error "Unexpected argument: $1"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # Check required arguments
    if [[ -z "$artifact_folder" ]]; then
        log_error "Artifact folder is required"
        show_usage
        exit 1
    fi
    
    # Store artifact folder globally
    ARTIFACT_FOLDER="$artifact_folder"
    
    log_info "=== Java and .NET Artifact Collector ==="
    log_info "Artifact folder: $artifact_folder"
    log_info "Output folder: $output_folder"
    log_info "Debug mode: $DEBUG"
    log_info "Verbose mode: $VERBOSE"
    log_info ""
    
    # Check dependencies
    if ! command -v unzip >/dev/null 2>&1; then
        log_error "Required dependency 'unzip' not found. Please install it first."
        exit 1
    fi
    
    # Analyze the artifact folder
    analyze_artifact_folder "$artifact_folder"
    
    # Collect artifacts
    collect_artifacts "$output_folder"
    
    log_success "Script completed successfully!"
    if [[ "$DETECTED_LANGUAGE" == "dotnet" ]] || [[ "$DETECTED_LANGUAGE" == "mixed" ]]; then
        if [[ ${#MISSING_PDBS[@]} -gt 0 ]]; then
            log_warning "Note: Some .NET DLLs are missing PDB files, which may affect scan accuracy."
        fi
    fi
}

# Run main function with all arguments
main "$@" 